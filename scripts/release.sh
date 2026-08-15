#!/bin/bash
set -euo pipefail

# Crisp release script: builds a signed universal DMG with the Command Line
# Tools only (no Xcode), and optionally publishes the GitHub release and bumps
# the Homebrew cask. Default is a dry run: it builds and verifies the DMG but
# publishes nothing. Pass --publish to actually release.
#
# Usage:
#   ./scripts/release.sh --preflight                # check release credentials, build nothing
#   ./scripts/release.sh                            # dry run at project.yml's version
#   ./scripts/release.sh v1.0.4                     # dry run at an explicit tag
#   ./scripts/release.sh v1.0.4 notes.md --publish  # build + notarize + release + cask
#
# notes.md is the release body (required for --publish; optional for dry run).
#
# ---------------------------------------------------------------------------
# Distribution rules this script enforces
# ---------------------------------------------------------------------------
# A dry run signs ad-hoc when no Developer ID certificate is available, because
# CI and contributors must still be able to build the DMG. That artifact is NOT
# distributable: Gatekeeper blocks it on every machine except the one that built
# it. So the script says so, loudly, and `--publish` refuses to run at all
# without a real Developer ID certificate plus stored notarization credentials.
# Shipping a build that Gatekeeper will block is worse than refusing to build one.
#
# Environment:
#   CRISP_SIGN_ID         "Developer ID Application: Name (TEAMID)". Auto-detected
#                         from the keychain when unset.
#   CRISP_NOTARY_PROFILE  notarytool keychain profile name (see --preflight output).
#   CRISP_NOTARY_APPLE_ID / CRISP_NOTARY_TEAM_ID / CRISP_NOTARY_PASSWORD
#                         alternative to the profile, for CI: the same three
#                         values store-credentials would have saved. Used only
#                         when CRISP_NOTARY_PROFILE is unset.
#   CRISP_TAP_REPO        optional "owner/homebrew-tap" to bump on publish. Unset
#                         by default: this fork has no tap of its own, and it
#                         cannot write to upstream's. The in-repo cask template
#                         (Casks/crisp-ddc.rb) is updated instead.
#   CRISP_TAP_CASK        path of the cask inside CRISP_TAP_REPO (default Casks/crisp.rb).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- Arguments -------------------------------------------------------------
# Flags may appear anywhere; the first bare argument is the tag, the second the
# notes file. (The old positional form still works verbatim.)
PUBLISH=false
PREFLIGHT_ONLY=false
TAG=""
NOTES=""
for arg in "$@"; do
    case "$arg" in
        --publish)   PUBLISH=true ;;
        --preflight) PREFLIGHT_ONLY=true ;;
        -h|--help)   sed -n '4,32p' "$0"; exit 0 ;;
        -*)          echo "ERROR: unknown flag: $arg" >&2; exit 2 ;;
        *)           if [ -z "$TAG" ]; then TAG="$arg"; else NOTES="$arg"; fi ;;
    esac
done

# --- Version: one source of truth -----------------------------------------
# project.yml's MARKETING_VERSION is it (the Makefile, make-app.sh, dev.sh and
# the Xcode build all read the same line). The tag is a label for that version,
# never a second place to define it: --publish fails on a mismatch rather than
# rewriting project.yml behind the maintainer's back.
PROJECT_VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$PROJECT_VERSION" ] || { echo "ERROR: no MARKETING_VERSION in project.yml" >&2; exit 1; }
TAG="${TAG:-v$PROJECT_VERSION}"
VERSION="${TAG#v}"                       # strip leading v for Info.plist

BUILD="$ROOT/build"
APP="$BUILD/Crisp.app"
DMG="$ROOT/Crisp.dmg"
TAP_REPO="${CRISP_TAP_REPO:-}"
TAP_CASK="${CRISP_TAP_CASK:-Casks/crisp.rb}"
LOCAL_CASK="$ROOT/Casks/crisp-ddc.rb"

# ---------------------------------------------------------------------------
# Preflight: is this machine able to produce a distributable build?
# ---------------------------------------------------------------------------

# The signing identity, if a usable one exists. Prints nothing when there is none.
resolve_signing_identity() {
    if [ -n "${CRISP_SIGN_ID:-}" ]; then
        echo "$CRISP_SIGN_ID"
        return
    fi
    # `|| true`: no match is the normal case on a machine without the certificate,
    # and under `set -e` + pipefail an empty grep would abort the whole script
    # before it could explain itself.
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true
}

explain_missing_certificate() {
    cat >&2 <<'MSG'
ERROR: no "Developer ID Application" certificate is available.

  That certificate is what macOS requires to distribute an app outside the App
  Store, and notarytool rejects anything else. Without it this script can still
  build a DMG (dry run, ad-hoc signed) but Gatekeeper will block that DMG on
  every machine except the one that built it — so --publish refuses.

  Code-signing identities currently in this keychain:
MSG
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"'; then
        security find-identity -v -p codesigning 2>/dev/null \
            | grep '"' | sed -E 's/.*"([^"]+)".*/    - \1/' >&2 || true
    else
        echo "    (none)" >&2
    fi
    cat >&2 <<'MSG'

  Note "Apple Development: …" is NOT a distribution certificate: it signs builds
  that run on your own registered machines only.

  To create the right one (needs a paid Apple Developer Program membership, and
  the Account Holder or Admin role in that team):

    1. Keychain Access → Certificate Assistant → Request a Certificate From a
       Certificate Authority… → "Saved to disk". This produces the CSR file.
    2. https://developer.apple.com/account/resources/certificates/add
       → choose "Developer ID Application" → upload the CSR → download the .cer.
    3. Double-click the .cer to install it into your login keychain.
    4. Confirm it is there:
         security find-identity -v -p codesigning | grep "Developer ID Application"
    5. Optionally pin it for this script:
         export CRISP_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
MSG
}

# Fills NOTARY_ARGS with the credential flags notarytool needs, and returns 0
# when credentials exist at all. Two routes, because a keychain profile is right
# on a laptop and impossible on a fresh CI runner:
#   1. CRISP_NOTARY_PROFILE      — a profile saved by `notarytool store-credentials`
#   2. CRISP_NOTARY_APPLE_ID/... — the same values passed straight through (CI)
NOTARY_ARGS=()
resolve_notary_credentials() {
    NOTARY_ARGS=()
    if [ -n "${CRISP_NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$CRISP_NOTARY_PROFILE")
        return 0
    fi
    if [ -n "${CRISP_NOTARY_APPLE_ID:-}" ] && [ -n "${CRISP_NOTARY_TEAM_ID:-}" ] \
       && [ -n "${CRISP_NOTARY_PASSWORD:-}" ]; then
        # The password appears in this process's argv, which is readable by other
        # processes on the same machine. Acceptable on an ephemeral CI runner
        # holding a secret scoped to notarization; on a shared machine use the
        # keychain profile instead.
        NOTARY_ARGS=(--apple-id "$CRISP_NOTARY_APPLE_ID"
                     --team-id "$CRISP_NOTARY_TEAM_ID"
                     --password "$CRISP_NOTARY_PASSWORD")
        return 0
    fi
    return 1
}

explain_missing_notary_credentials() {
    cat >&2 <<'MSG'
ERROR: no notarization credentials (neither CRISP_NOTARY_PROFILE nor the
       CRISP_NOTARY_APPLE_ID / CRISP_NOTARY_TEAM_ID / CRISP_NOTARY_PASSWORD trio
       is set).

  Notarization needs an app-specific password stored once in the keychain as a
  notarytool profile. Your normal Apple ID password will not work.

    1. Create the app-specific password:
       https://account.apple.com → Sign-In and Security → App-Specific Passwords.
    2. Store it as a notarytool profile (one time, per machine):
         xcrun notarytool store-credentials crisp-notary \
           --apple-id you@example.com \
           --team-id TEAMID \
           --password abcd-efgh-ijkl-mnop
       (TEAMID is the parenthesised code in your Developer ID identity name.)
    3. Point this script at it:
         export CRISP_NOTARY_PROFILE=crisp-notary

  In CI, where there is no keychain to store a profile in, pass the same three
  values directly instead (from repository secrets):
    CRISP_NOTARY_APPLE_ID, CRISP_NOTARY_TEAM_ID, CRISP_NOTARY_PASSWORD
MSG
}

# Returns 0 when this machine can build a notarized, Gatekeeper-clean release.
# Prints an actionable explanation for every missing piece before returning.
preflight() {
    local ok=true identity
    echo "==> Release preflight"

    identity="$(resolve_signing_identity)"
    if [ -z "$identity" ]; then
        explain_missing_certificate
        ok=false
    elif ! printf '%s' "$identity" | grep -q '^Developer ID Application'; then
        echo "ERROR: CRISP_SIGN_ID is \"$identity\", which is not a Developer ID Application" >&2
        echo "       certificate. Only that kind can be notarized." >&2
        explain_missing_certificate
        ok=false
    elif ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity"; then
        # A CRISP_SIGN_ID naming a certificate this keychain does not hold would
        # otherwise sail through preflight and fail two minutes later, in codesign.
        echo "ERROR: CRISP_SIGN_ID is \"$identity\", but no such code-signing identity is" >&2
        echo "       in this keychain." >&2
        explain_missing_certificate
        ok=false
    else
        echo "    signing identity: $identity"
    fi

    if ! xcrun --find notarytool >/dev/null 2>&1; then
        echo "ERROR: notarytool is missing. Install Xcode 13 or newer (the Command Line" >&2
        echo "       Tools alone do not ship it) and re-run." >&2
        ok=false
    elif ! resolve_notary_credentials; then
        explain_missing_notary_credentials
        ok=false
    else
        if [ -n "${CRISP_NOTARY_PROFILE:-}" ]; then
            echo "    notarization credentials: keychain profile $CRISP_NOTARY_PROFILE"
        else
            echo "    notarization credentials: Apple ID ${CRISP_NOTARY_APPLE_ID} (team ${CRISP_NOTARY_TEAM_ID})"
        fi
        # Cheapest proof the credentials are real: ask Apple for this account's
        # submission history. Network-dependent, so a failure is reported as a
        # credential problem *or* connectivity, not asserted to be one of them.
        if ! xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
            echo "ERROR: the notarization credentials could not be used. Either they are" >&2
            echo "       wrong/expired, or this machine is offline. Re-store them with:" >&2
            echo "         xcrun notarytool store-credentials ${CRISP_NOTARY_PROFILE:-crisp-notary} \\" >&2
            echo "           --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>" >&2
            ok=false
        fi
    fi

    if [ "$ok" = true ]; then
        echo "    preflight OK: this machine can produce a notarized release."
        return 0
    fi
    echo "" >&2
    echo "Preflight failed. A dry run (./scripts/release.sh, no --publish) still works and" >&2
    echo "produces an ad-hoc signed DMG for local testing only." >&2
    return 1
}

if [ "$PREFLIGHT_ONLY" = true ]; then
    preflight
    exit $?
fi

# --publish is the path that must never produce a Gatekeeper-blocked artifact.
if [ "$PUBLISH" = true ]; then
    preflight || exit 1
    if [ "$VERSION" != "$PROJECT_VERSION" ]; then
        echo "ERROR: tag $TAG does not match project.yml's MARKETING_VERSION ($PROJECT_VERSION)." >&2
        echo "       project.yml is the single source of truth for the version. Bump it," >&2
        echo "       commit, and re-run with the matching tag." >&2
        exit 1
    fi
elif [ "$VERSION" != "$PROJECT_VERSION" ]; then
    echo "==> Note: building as $TAG, while project.yml says $PROJECT_VERSION (dry run, allowed)."
fi

SIGN_ID="$(resolve_signing_identity)"
# Only a Developer ID identity is used for signing here; anything else (an Apple
# Development cert, say) would produce a build that cannot be notarized, and
# silently pretending otherwise is the failure this script exists to prevent.
if [ -n "$SIGN_ID" ] && ! printf '%s' "$SIGN_ID" | grep -q '^Developer ID Application'; then
    echo "==> Ignoring signing identity \"$SIGN_ID\": not a Developer ID Application certificate."
    SIGN_ID=""
fi

# A real release must ship complete translations; the dry run (CI on every PR)
# skips this so adding an English string doesn't block contributors — the
# maintainer fills the gaps before publishing.
if [ "$PUBLISH" = true ]; then
    echo "==> Checking translation completeness…"
    python3 "$ROOT/scripts/check-translations.py" Crisp/Resources/Localizable.xcstrings
fi

rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling universal binary (arm64 + x86_64)…"
SRC=$(find Crisp -name '*.swift')
for a in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$a-apple-macos14.0" \
    -import-objc-header Crisp/Crisp-Bridging-Header.h \
    -Xlinker -U -Xlinker _SLSConfigureDisplayEnabled \
    -Xlinker -U -Xlinker _SLSGetDisplayList \
    $SRC -o "$BUILD/Crisp-$a"
done
lipo -create "$BUILD/Crisp-arm64" "$BUILD/Crisp-x86_64" -output "$APP/Contents/MacOS/Crisp"

echo "==> Building app icon from asset catalog…"
ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
ICONS="Crisp/Assets.xcassets/AppIcon.appiconset"
cp "$ICONS/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ICONS/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONS/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ICONS/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Copying the monitor quirks database…"
# Directory, not flattened: MonitorQuirksService looks in Resources/quirks.
# The README is the contributor guide, not something the app reads.
cp -R Crisp/Resources/quirks "$APP/Contents/Resources/quirks"
rm -f "$APP/Contents/Resources/quirks/README.md"

# …and then check it, because "the copy is in the script" is not evidence that
# the copy landed. A bundle that ships without the quirks JSON still runs — it
# silently falls back to MCCS defaults, which is exactly the class of failure
# that is invisible until a user reports wrong input labels.
echo "==> Verifying the quirks database in the bundle…"
SRC_QUIRKS=$(find Crisp/Resources/quirks -name '*.json' | wc -l | tr -d ' ')
APP_QUIRKS=$(find "$APP/Contents/Resources/quirks" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$SRC_QUIRKS" -gt 0 ] || { echo "ERROR: no quirks JSON in Crisp/Resources/quirks" >&2; exit 1; }
[ "$APP_QUIRKS" = "$SRC_QUIRKS" ] || {
    echo "ERROR: bundle has $APP_QUIRKS quirks file(s), source has $SRC_QUIRKS." >&2; exit 1; }
[ ! -e "$APP/Contents/Resources/quirks/README.md" ] || {
    echo "ERROR: the contributor README was bundled as an app resource." >&2; exit 1; }
# Every file must parse: a contributed file with a stray comma would be dropped
# at launch with only a log line to show for it.
for q in "$APP/Contents/Resources/quirks"/*.json; do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$q" \
        || { echo "ERROR: $q is not valid JSON" >&2; exit 1; }
done
echo "    $APP_QUIRKS quirks file(s), all valid JSON"

echo "==> Compiling localizations from the String Catalog…"
# The CLT ship no xcstringstool, so generate <lang>.lproj/Localizable.strings
# ourselves; without this the bundle has zero localizations and ships en-only.
LANGS=$(python3 "$ROOT/scripts/xcstrings-compile.py" Crisp/Resources/Localizable.xcstrings "$APP/Contents/Resources")
LOC_XML=""; for l in $LANGS; do LOC_XML="${LOC_XML}<string>${l}</string>"; done
echo "    languages: $LANGS"

echo "==> Writing Info.plist / PkgInfo…"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Crisp</string>
	<key>CFBundleDisplayName</key><string>Crisp</string>
	<key>CFBundleIdentifier</key><string>com.crisp.app</string>
	<key>CFBundleExecutable</key><string>Crisp</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array>${LOC_XML}</array>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>Crisp - Free &amp; Open Source</string>
	<key>NSAppleEventsUsageDescription</key><string>Crisp uses System Events to switch Dark Mode with the system's animated transition.</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST

# Sign with a Developer ID + hardened runtime when one is available (release),
# else ad-hoc so dry runs and contributor/CI builds still work without a cert. A
# notarizable build needs the hardened runtime (--options runtime) and a secure
# timestamp; ad-hoc gets neither and can't be notarized anyway. (b00d.0)
xattr -cr "$APP"
if [ -n "$SIGN_ID" ]; then
  echo "==> Signing (Developer ID: $SIGN_ID, hardened runtime)…"
  codesign --force --deep --options runtime --timestamp \
    --entitlements Crisp/Crisp.entitlements --sign "$SIGN_ID" "$APP"
else
  echo "==> Signing (ad-hoc — NOT DISTRIBUTABLE; run --preflight to see what is missing)…"
  codesign --force --deep --sign - --entitlements Crisp/Crisp.entitlements "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize the app and staple the ticket BEFORE packaging, so the app validates
# offline once dragged out of the DMG. The DMG itself is notarized and stapled
# afterwards, because that is the file a user actually downloads and the one
# Gatekeeper checks first. Runs only with a Developer ID signature plus a stored
# notarytool profile (see --preflight); skipped otherwise so unsigned dry runs
# still produce a DMG. (b00d.0)
NOTARIZED=false
if [ -n "$SIGN_ID" ] && resolve_notary_credentials; then
  echo "==> Notarizing the app…"
  ditto -c -k --keepParent "$APP" "$BUILD/Crisp.zip"
  xcrun notarytool submit "$BUILD/Crisp.zip" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  NOTARIZED=true
elif [ -n "$SIGN_ID" ]; then
  echo "==> WARNING: signed with Developer ID but no notarization credentials — NOT notarized."
fi

echo "==> Building DMG…"
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Crisp -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ "$NOTARIZED" = true ]; then
  echo "==> Signing, notarizing and stapling the DMG…"
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# Verification, on the artifact that will actually be downloaded rather than on
# the tree it was built from.
echo "==> Verifying the artifact…"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$NOTARIZED" = true ]; then
  # -t exec is the assessment an app gets when launched; -t install is the one a
  # disk image gets when mounted. Both have to pass for a download to be clean.
  spctl -a -vvv -t exec "$APP"
  spctl -a -vvv -t install "$DMG"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
  echo "    signed, notarized, stapled, and accepted by Gatekeeper."
else
  echo "    WARNING: this DMG is NOT notarized. Gatekeeper will refuse it on any"
  echo "             machine other than this one. Local testing only."
fi

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "==> Built $DMG"
echo "    version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"), archs $(lipo -archs "$APP/Contents/MacOS/Crisp"), sha256 $SHA"

if [ "$PUBLISH" != true ]; then
  echo "==> Dry run. Pass --publish to create the release and update the cask."
  exit 0
fi

[ -n "$NOTES" ] && [ -f "$NOTES" ] || { echo "ERROR: --publish needs a notes file: ./scripts/release.sh $TAG notes.md --publish"; exit 1; }

echo "==> Creating GitHub release ${TAG}…"
gh release create "$TAG" --title "Crisp ${TAG}" --notes-file "$NOTES" "$DMG"

# The cask that ships in this repo (docs/RELEASING.md explains why it is here
# rather than in a tap): fill in the version and the sha256 of the DMG that was
# just published. Committing it is a deliberate, reviewable step, so this only
# writes the file.
if [ -f "$LOCAL_CASK" ]; then
  echo "==> Updating $LOCAL_CASK…"
  sed -i '' \
    -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 .*/  sha256 \"${SHA}\"/" "$LOCAL_CASK"
  echo "    commit it:  git add Casks/crisp-ddc.rb && git commit -m \"cask: crisp-ddc ${VERSION}\""
fi

# Optional: bump a real Homebrew tap, when one exists and this account can write
# to it. Unset by default — the upstream tap belongs to upstream.
if [ -n "$TAP_REPO" ]; then
  echo "==> Bumping Homebrew tap ${TAP_REPO}…"
  SHA_FILE=$(gh api "repos/$TAP_REPO/contents/$TAP_CASK" --jq '.sha')
  gh api "repos/$TAP_REPO/contents/$TAP_CASK" --jq '.content' | base64 -d \
    | sed -e "s/version \"[^\"]*\"/version \"${VERSION}\"/" \
          -e "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" > "$BUILD/crisp.rb"
  gh api -X PUT "repos/$TAP_REPO/contents/$TAP_CASK" \
    -f message="crisp ${VERSION}" \
    -f content="$(base64 -i "$BUILD/crisp.rb")" \
    -f sha="$SHA_FILE" --jq '.commit.sha' >/dev/null
else
  echo "==> No CRISP_TAP_REPO set; skipping tap bump (see docs/RELEASING.md)."
fi

echo "==> Released ${TAG}."
