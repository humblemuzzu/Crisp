# Releasing

How a build gets from this repository to something a stranger can install
without macOS refusing to open it.

Two facts shape everything below:

1. **The version lives in exactly one place:** `MARKETING_VERSION` in
   `project.yml`. The Makefile, `dev.sh`, `scripts/make-app.sh`, the Xcode
   project and `scripts/release.sh` all read that line. A tag is a *label* for
   that version, never a second definition of it — `release.sh --publish` and
   the release workflow both refuse a tag that disagrees.
2. **Distribution needs a "Developer ID Application" certificate.** An "Apple
   Development" certificate signs builds for machines registered to your
   developer account; it is not a distribution certificate and notarytool
   rejects it. Without the right certificate the release path refuses to run
   rather than producing a DMG that Gatekeeper will block on every machine but
   the one that built it.

## One-time setup

Check where you stand first — this prints, in detail, whatever is missing:

```sh
./scripts/release.sh --preflight
```

### 1. Developer ID Application certificate

Needs a paid Apple Developer Program membership and the Account Holder or Admin
role in the team.

1. Keychain Access → Certificate Assistant → *Request a Certificate From a
   Certificate Authority…* → **Saved to disk**. That file is the CSR.
2. <https://developer.apple.com/account/resources/certificates/add> → choose
   **Developer ID Application** → upload the CSR → download the `.cer`.
3. Double-click the `.cer` to install it into your login keychain.
4. Confirm:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
5. Optionally pin it: `export CRISP_SIGN_ID="Developer ID Application: Name (TEAMID)"`.

### 2. Notarization credentials

Apple's notary service authenticates with an **app-specific password**, not your
Apple ID password.

1. <https://account.apple.com> → Sign-In and Security → App-Specific Passwords →
   create one.
2. Store it once, in the keychain:
   ```sh
   xcrun notarytool store-credentials crisp-notary \
     --apple-id you@example.com --team-id TEAMID --password abcd-efgh-ijkl-mnop
   ```
3. `export CRISP_NOTARY_PROFILE=crisp-notary`

`--preflight` then asks Apple for your submission history as proof the stored
credentials really work.

## Cutting a release

```sh
# 1. Bump the version in project.yml (MARKETING_VERSION), commit it.
# 2. Confirm the machine can produce a notarized build.
./scripts/release.sh --preflight

# 3. Dry run: builds, signs, notarizes, staples, verifies — publishes nothing.
./scripts/release.sh v1.5.0

# 4. Publish: same build, plus the GitHub release and the cask update.
./scripts/release.sh v1.5.0 docs/RELEASE_NOTES_1.5.0.md --publish

# 5. Tag, which triggers .github/workflows/release.yml.
git tag v1.5.0 && git push origin v1.5.0
```

Step 4 and step 5 both publish; use one or the other. The tag route is the
normal one (it runs `make check` on a clean checkout first); the local route
exists for when a release has to be cut from a machine rather than from CI.

What `release.sh` does, in order:

- compiles a universal binary (arm64 + x86_64) with the Command Line Tools,
- builds the icon, **copies the quirks database and then verifies it landed** —
  file count against the source directory, no stray `README.md`, and every JSON
  file parsed (a bundle with no quirks JSON does not crash, it silently falls
  back to MCCS defaults, which is invisible until someone reports wrong input
  labels),
- compiles the String Catalog into `.lproj` bundles,
- signs with Developer ID + hardened runtime + secure timestamp,
- notarizes the app, staples it, builds the DMG, signs/notarizes/staples the DMG
  too (the DMG is the file that gets downloaded and quarantined),
- verifies: `codesign --verify --deep --strict`, `spctl -a -vvv -t exec` on the
  app, `spctl -a -vvv -t install` on the DMG, and `stapler validate` on both.

Without credentials it still builds a DMG — ad-hoc signed, clearly labelled
`NOT DISTRIBUTABLE`, for local testing. That is also what CI's dry run
(`./scripts/release.sh v0.0.0-ci`) exercises on every push.

## The Homebrew cask

`Casks/crisp-ddc.rb` is the cask definition. It ships here as a template with a
deliberately invalid `sha256` placeholder: there is no published release to hash
yet, and a plausible-looking wrong hash is worse than an obviously missing one.
`release.sh … --publish` rewrites the `version` and `sha256` lines from the DMG
it just uploaded; commit the result.

Homebrew 4.6.4 removed installing a cask from a file path or URL
([Homebrew/brew#18371](https://github.com/Homebrew/brew/issues/18371)), so the
cask has to be served from a tap. To publish one:

```sh
# Create the tap repository (github.com/<you>/homebrew-tap), then:
brew tap-new <you>/tap
cp Casks/crisp-ddc.rb "$(brew --repo <you>/tap)/Casks/"
# commit and push that repo, after which users install with:
brew install --cask <you>/tap/crisp-ddc
```

Once the tap exists, point the release script at it and it will bump the cask
there on every publish:

```sh
export CRISP_TAP_REPO=<you>/homebrew-tap
export CRISP_TAP_CASK=Casks/crisp-ddc.rb
```

The cask token is `crisp-ddc`, not `crisp`: upstream's tap already ships a
`crisp` cask for upstream's app, and someone may reasonably have both taps.

## CI (`.github/workflows/release.yml`)

Pushing a `v*` tag runs: the tag/`project.yml` version guard, the full
`make check`, the build, and the publish. Signing is driven by repository
secrets (Settings → Secrets and variables → Actions):

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | The Developer ID Application certificate + private key, exported from Keychain Access as a `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password set when exporting that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID email of the developer account |
| `NOTARY_TEAM_ID` | Team ID (the parenthesised code in the identity name) |
| `NOTARY_PASSWORD` | The app-specific password |

When those secrets are absent — a fork, most likely — the workflow **does not
fail**. It warns, builds an unsigned DMG, uploads it as a workflow artifact, and
marks the release body with a warning that macOS will refuse the build. A fork
still gets a working CI build; nobody gets a silently broken download.

## What is not automated

- Release notes. `--publish` requires a notes file; the workflow falls back to
  GitHub's generated notes.
- Committing the updated cask. The script writes it, you review and commit it.
- Any hardware verification. The tests are headless by construction; brightness,
  contrast, volume and input-source behaviour are checked by hand with
  `crispctl` against a real monitor (AGENTS.md §5).
