#!/bin/bash
# Builds, bundles, signs, notarizes, and packages a distributable tp7-station.dmg.
#
# Usage: scripts/build-release.sh <version> [notary-profile]
#   version         e.g. 1.0.0 — used only for the DMG filename
#   notary-profile  keychain profile from `xcrun notarytool store-credentials`
#                   (default: tp7-station-notary)
#
# Requires: a "Developer ID Application" certificate in the login keychain,
# and notarization credentials already stored under the given profile name.
# Everything else (build, bundling, signing, packaging) needs no credentials
# and can be re-run freely to test the pipeline.
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [notary-profile]}"
NOTARY_PROFILE="${2:-tp7-station-notary}"

APP_NAME="tp7-station"
SCHEME="TP7Companion"
TEAM_ID="7F2B946ZC5"
SIGN_IDENTITY="Developer ID Application: Starkly Pty Ltd ($TEAM_ID)"
CLI_SOURCE="/opt/homebrew/bin/tp7"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.release-build"
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Checking prerequisites"
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
  || { echo "Missing signing identity: $SIGN_IDENTITY"; exit 1; }
[ -x "$CLI_SOURCE" ] || { echo "tp7 CLI not found at $CLI_SOURCE"; exit 1; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$PROJECT_DIR"
xcodegen generate

echo "==> Building Release configuration"
xcodebuild -project TP7Companion.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  build

echo "==> Bundling the tp7 CLI into Resources"
cp "$CLI_SOURCE" "$APP_PATH/Contents/Resources/tp7"
chmod +x "$APP_PATH/Contents/Resources/tp7"

echo "==> Signing (inner binary first, then the app)"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Resources/tp7"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_PATH"

echo "==> Building DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "==> Submitting for notarization (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Final Gatekeeper check"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo "==> Checksum"
shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

# The README's download link is the stable, version-free
# .../releases/latest/download/tp7-station.dmg URL, so it never needs
# editing on a new release — the asset filename must stay constant to
# match it. The versioned copy above stays too, for the release notes.
STABLE_PATH="$BUILD_DIR/${APP_NAME}.dmg"
cp "$DMG_PATH" "$STABLE_PATH"
shasum -a 256 "$STABLE_PATH" | tee "$STABLE_PATH.sha256"

echo ""
echo "Done: $DMG_PATH"
echo "Stable-named copy for the release asset: $STABLE_PATH"
echo "Attach BOTH files (plus their .sha256s) to the GitHub Release."
