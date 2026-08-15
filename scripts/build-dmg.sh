#!/bin/bash
set -euo pipefail

# Builds a DMG through Xcode (needs full Xcode + a generated Crisp.xcodeproj).
#
# This is the *local testing* path: it is here because building through the real
# Xcode target catches project-level breakage the Command Line Tools path cannot
# see. It does not sign for distribution and does not notarize.
#
# For anything a user will download, use scripts/release.sh — that is the only
# path that signs with Developer ID, notarizes, staples and verifies the result.
# Run `./scripts/release.sh --preflight` to see whether this machine can.

# Configuration
APP_NAME="Crisp"
SCHEME="Crisp"
BUILD_DIR="$(pwd)/build"
DMG_NAME="${APP_NAME}.dmg"

echo "=== Building ${APP_NAME} Release ==="
echo "    (local testing build — not signed for distribution, not notarized;"
echo "     use ./scripts/release.sh for a releasable DMG)"

# Clean and build Release (skip Xcode's codesign; we'll sign manually after stripping xattrs)
xcodebuild -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 | tail -20

# Find the .app
APP_PATH=$(find "$BUILD_DIR" -name "${APP_NAME}.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: ${APP_NAME}.app not found in build output"
  exit 1
fi
echo "Found app: $APP_PATH"

# Strip extended attributes (resource forks, .DS_Store detritus) before signing
echo "=== Stripping extended attributes ==="
xattr -cr "$APP_PATH"

# Sign with a stable identity when one is given, ad-hoc otherwise. Stable
# matters even for a test build: an ad-hoc signature changes the code hash every
# time, which silently invalidates the Accessibility (TCC) grant the brightness
# keys need. CRISP_SIGN_ID takes any identity here — including an Apple
# Development certificate — because nothing on this path is distributed.
echo "=== Signing ==="
if [ -n "${CRISP_SIGN_ID:-}" ]; then
  echo "    identity: $CRISP_SIGN_ID"
  codesign --force --deep --sign "$CRISP_SIGN_ID" \
    --entitlements Crisp/Crisp.entitlements "$APP_PATH"
else
  echo "    ad-hoc (set CRISP_SIGN_ID to keep the Accessibility grant across builds)"
  codesign --force --deep --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

# The monitor quirks database has to be inside the bundle. project.yml adds
# Crisp/Resources/quirks as a folder reference so the JSON keeps its directory
# (MonitorQuirksService looks for Contents/Resources/quirks/*.json). Its absence
# is not a crash — the app silently falls back to MCCS defaults — so it is
# checked rather than assumed.
echo "=== Verifying the quirks database in the bundle ==="
SRC_QUIRKS=$(find Crisp/Resources/quirks -name '*.json' | wc -l | tr -d ' ')
APP_QUIRKS=$(find "$APP_PATH/Contents/Resources/quirks" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$APP_QUIRKS" != "$SRC_QUIRKS" ] || [ "$SRC_QUIRKS" = "0" ]; then
  echo "ERROR: bundle has $APP_QUIRKS quirks file(s), source has $SRC_QUIRKS" >&2
  exit 1
fi
echo "    $APP_QUIRKS quirks file(s)"

# Create staging directory for DMG
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Create DMG
echo "=== Creating DMG ==="
DMG_OUTPUT="$(pwd)/${DMG_NAME}"
rm -f "$DMG_OUTPUT"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_OUTPUT"

echo "=== Done ==="
echo "DMG: $DMG_OUTPUT"
ls -lh "$DMG_OUTPUT"
