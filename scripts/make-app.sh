#!/bin/bash
# make-app.sh — assemble a runnable /Applications/Crisp.app from the current
# source build (no Xcode needed), for machines without the official DMG.
# Compiles, builds the icns from the xcassets PNGs, signs ad-hoc, and launches.
# Re-runs are safe: it replaces the binary in place (dev.sh-compatible).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${CRISP_APP:-/Applications/Crisp.app}"
VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

echo "==> Compiling..."
swiftc -O -swift-version 5 -strict-concurrency=minimal -parse-as-library \
    -import-objc-header Crisp/Crisp-Bridging-Header.h \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    Crisp/App/*.swift Crisp/Intents/*.swift Crisp/Models/*.swift \
    Crisp/Services/*.swift Crisp/Views/*.swift Crisp/Utilities/*.swift \
    -o Crisp-bin

echo "==> Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Crisp-bin "$APP/Contents/MacOS/Crisp"

# Build AppIcon.icns from the xcassets PNGs via a temporary iconset.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_16.png  "$ICONSET/icon_16x16.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_32.png  "$ICONSET/icon_16x16@2x.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_32.png  "$ICONSET/icon_32x32.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_64.png  "$ICONSET/icon_32x32@2x.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_128.png "$ICONSET/icon_128x128.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_256.png "$ICONSET/icon_128x128@2x.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_256.png "$ICONSET/icon_256x256.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_512.png "$ICONSET/icon_256x256@2x.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_512.png "$ICONSET/icon_512x512.png"
cp Crisp/Assets.xcassets/AppIcon.appiconset/icon_1024.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Monitor quirks database. Copied as a directory, not flattened: the loader
# looks for Contents/Resources/quirks/*.json (MonitorQuirksService). Missing
# files are not fatal — the app falls back to MCCS defaults — so this stays a
# plain copy with no verification step.
cp -R Crisp/Resources/quirks "$APP/Contents/Resources/quirks"
# The contributor guide is documentation, not a resource the app reads.
rm -f "$APP/Contents/Resources/quirks/README.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Crisp</string>
	<key>CFBundleExecutable</key>
	<string>Crisp</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.crisp.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Crisp</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<!-- The crisp:// automation scheme (Crisp/Models/CrispURL.swift). Registering
	     it is what lets anything on the machine hand Crisp a URL, which is why the
	     parser refuses everything outside its grammar and why a destructive write
	     (VCP 0x60 and friends) can only be applied through the confirmation dialog
	     in AutomationService — there is no URL parameter that skips it. -->
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.crisp.app.automation</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>crisp</string>
			</array>
		</dict>
	</array>
	<key>NSAppleEventsUsageDescription</key>
	<string>Crisp uses System Events to switch Dark Mode with the system's animated transition.</string>
	<key>NSHumanReadableCopyright</key>
	<string>Crisp - Free &amp; Open Source</string>
</dict>
</plist>
PLIST

echo "==> Signing..."
# Sign with a stable identity so the Accessibility TCC grant survives rebuilds.
# Ad-hoc signing changes the code hash every build, which silently invalidates
# the CGEventTap permission and forces a re-grant after every deploy.
# Preferred: the user's Apple Development identity (stable cert); fall back to a
# "Crisp Dev" self-signed cert, then ad hoc.
SIGN_ID="${CRISP_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    APPLE_DEV=$(security find-identity -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -n "$APPLE_DEV" ]; then
        SIGN_ID="$APPLE_DEV"
    elif security find-identity -p codesigning 2>/dev/null | grep -qF "Crisp Dev"; then
        SIGN_ID="Crisp Dev"
    fi
fi
if [ -n "$SIGN_ID" ]; then
    echo "==> Signing with identity: $SIGN_ID"
    codesign --force -s "$SIGN_ID" --entitlements Crisp/Crisp.entitlements "$APP"
else
    echo "==> Signing ad hoc (Accessibility will reset each build)"
    codesign --force -s - --entitlements Crisp/Crisp.entitlements "$APP"
fi

echo "==> Launching..."
# Kill the running instance first: `open` on an already-running app just
# activates it, which would keep the OLD binary alive (no logging, no fixes).
pkill -x Crisp 2>/dev/null || true
sleep 1
open "$APP"
echo "Done. Crisp $VERSION running from $APP."
