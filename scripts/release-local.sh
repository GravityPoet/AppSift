#!/usr/bin/env bash
#
# Local mirror of .github/workflows/release.yml. Use for emergency hotfixes
# when CI is unavailable. Requires:
#   - Developer ID Application identity in your login keychain. Set
#       APPSIFT_TEAM_ID=<Apple team id>
#       APPSIFT_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
#   - notarytool keychain profile already stored, e.g.:
#       xcrun notarytool store-credentials AC_NOTARY \
#         --key /secure/path/AuthKey_<KEY_ID>.p8 \
#         --key-id <KEY_ID> --issuer <ISSUER_UUID>
#   - xcodegen + create-dmg installed (brew install xcodegen create-dmg)
#
# Usage: scripts/release-local.sh <version> [notary_profile]
#        scripts/release-local.sh 2.2.0
#        scripts/release-local.sh 2.2.0 AC_NOTARY
#
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [notary_profile]}"
NOTARY_PROFILE="${2:-AC_NOTARY}"
TEAM_ID="${APPSIFT_TEAM_ID:-${DEVELOPMENT_TEAM_ID:-}}"
SIGN_ID="${APPSIFT_SIGNING_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
: "${TEAM_ID:?Set APPSIFT_TEAM_ID (or DEVELOPMENT_TEAM_ID) before releasing}"
: "${SIGN_ID:?Set APPSIFT_SIGNING_IDENTITY (or DEVELOPER_ID_APPLICATION) before releasing}"
SCHEME="AppSift"
PROJECT="AppSift.xcodeproj"
APP="build/export/AppSift.app"
DMG="build/AppSift-${VERSION}.dmg"
ZIP="build/AppSift-${VERSION}.zip"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$(dirname "$0")/.."

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [[ -d "${APP}/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "${LSREGISTER}" -u "${nested_app}" >/dev/null 2>&1 || true
    done < <(find "${APP}/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  "${LSREGISTER}" -u "${APP}" >/dev/null 2>&1 || true
  rm -rf "${APP}" build/AppSift.xcarchive
  rm -f build/AppSift-app.zip build/ExportOptions.plist build/.metadata_never_index
  rmdir build/export >/dev/null 2>&1 || true
  if [[ "${status}" -ne 0 ]]; then
    rm -f "${DMG}" "${ZIP}"
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PROJ_VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
if [[ "${PROJ_VERSION}" != "${VERSION}" ]]; then
  echo "ERROR: project.yml MARKETING_VERSION (${PROJ_VERSION}) != ${VERSION}" >&2
  exit 1
fi

rm -rf build
mkdir -p build
: > build/.metadata_never_index

echo "==> xcodegen"
xcodegen generate

echo "==> archive"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/AppSift.xcarchive \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGN_ID}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  archive

echo "==> export"
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath build/AppSift.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist

echo "==> verify codesign"
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign -dvv "${APP}" 2>&1 | grep -E "Identifier|TeamIdentifier|flags|Authority"
codesign -dvv "${APP}" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "Hardened runtime missing"; exit 1; }
lipo -archs "${APP}/Contents/MacOS/AppSift"

echo "==> dmg"
create-dmg \
  --volname "AppSift ${VERSION}" \
  --window-size 540 360 \
  --icon-size 100 \
  --icon "AppSift.app" 140 180 \
  --hide-extension "AppSift.app" \
  --app-drop-link 400 180 \
  --no-internet-enable \
  "${DMG}" \
  build/export/AppSift.app
codesign --sign "${SIGN_ID}" --timestamp "${DMG}"

echo "==> notarize app zip (profile: ${NOTARY_PROFILE})"
ditto -c -k --keepParent --sequesterRsrc "${APP}" build/AppSift-app.zip
xcrun notarytool submit build/AppSift-app.zip \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${APP}"

echo "==> notarize dmg"
xcrun notarytool submit "${DMG}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"
spctl --assess --type install --verbose=4 "${DMG}"

echo "==> final zip with stapled app"
ditto -c -k --keepParent --sequesterRsrc "${APP}" "${ZIP}"

DMG_SHA=$(shasum -a 256 "${DMG}" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "${ZIP}" | awk '{print $1}')

echo ""
echo "===================="
echo "AppSift ${VERSION} signed + notarized"
echo "===================="
echo "DMG: ${DMG}"
echo "  sha256: ${DMG_SHA}"
echo "ZIP: ${ZIP}"
echo "  sha256: ${ZIP_SHA}"
echo ""
echo "Next: gh release create v${VERSION} ${DMG} ${ZIP} --title \"AppSift v${VERSION}\""
echo "Then: bump homebrew/appsift.rb sha256 to ${ZIP_SHA}"
