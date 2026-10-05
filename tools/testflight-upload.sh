#!/bin/bash
# Builds Glucose and uploads it to TestFlight. Run on a Mac with Xcode, signed in to the
# Apple Developer account in Xcode → Settings → Accounts.
#
#   ./tools/testflight-upload.sh <TEAM_ID>
#
# TEAM_ID is the 10-character Team ID from https://developer.apple.com/account → Membership.
# BUNDLE_ID (optional) is the App Store Connect app's bundle ID; the widget gets the same plus .widget.
# Each run gets a new build number (date and time), so nothing needs editing between uploads.
set -euo pipefail

TEAM_ID="${1:-${TEAM_ID:-}}"
if [ -z "$TEAM_ID" ]; then
  echo "Usage: $0 <TEAM_ID>   (find it at developer.apple.com/account → Membership)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
BUILD_DIR="build/testflight"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
BUNDLE_ID="${BUNDLE_ID:-com.ncatechsolutions.glucoseapp}"

command -v xcodegen >/dev/null || { echo "Installing XcodeGen…"; brew install xcodegen; }
# Build with the App Store Connect app's bundle IDs, leaving project.yml (and the app group) as is.
SPEC="App/.project.testflight.yml"
sed "s/PRODUCT_BUNDLE_IDENTIFIER: com.leonidasantoniadis.glucoseapp/PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID/" App/project.yml > "$SPEC"
trap 'rm -f "$SPEC"' EXIT
xcodegen generate --spec "$SPEC"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "Archiving build ${BUILD_NUMBER}…"
xcodebuild archive \
  -project App/GlucoseApp.xcodeproj \
  -scheme GlucoseApp \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$BUILD_DIR/GlucoseApp.xcarchive" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | grep -E "error:|warning: .*GlucoseApp|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$BUILD_DIR/GlucoseApp.xcarchive" ] || { echo "Archive failed. Run without the grep filter to see details." >&2; exit 1; }

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/GlucoseApp.xcarchive" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$BUILD_DIR/export" \
  -allowProvisioningUpdates

echo
echo "Uploaded build ${BUILD_NUMBER}. It appears in App Store Connect → TestFlight after processing (5-15 minutes)."
