#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this release builder requires macOS." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_SCRIPT="$ROOT_DIR/scripts/ensure-local-codesign-cert.sh"
PROJECT_VERSION="$(
  sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ROOT_DIR/project.yml"
)"
VERSION="${1:-$PROJECT_VERSION}"
APP_NAME="AppSift.app"
BUNDLE_ID="com.gravitypoet.appsift"
EXECUTABLE_NAME="AppSift"
ARCHS="${ARCHS:-arm64 x86_64}"
OUTPUT_DIR="$ROOT_DIR/build"
DMG="$OUTPUT_DIR/AppSift-$VERSION-self-signed.dmg"
ZIP="$OUTPUT_DIR/AppSift-$VERSION-self-signed.zip"
STATUS_FILE="$OUTPUT_DIR/AppSift-$VERSION-self-signed.txt"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/appsift-customer-release.XXXXXX")"
DERIVED_DATA="$TEMP_ROOT/DerivedData.noindex"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
DMG_ROOT="$TEMP_ROOT/dmg-root"
VERIFY_ROOT="$TEMP_ROOT/archive-verification"
DMG_VERIFY_MOUNT="$TEMP_ROOT/dmg-verification"
DMG_TEMP="$OUTPUT_DIR/.AppSift-$VERSION-self-signed.$$.dmg"
ZIP_TEMP="$OUTPUT_DIR/.AppSift-$VERSION-self-signed.$$.zip"
STATUS_TEMP="$OUTPUT_DIR/.AppSift-$VERSION-self-signed.$$.txt"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DMG_ATTACHED=0

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -d "$BUILT_APP/Contents" ]]; then
    "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
  fi
  if [[ "$DMG_ATTACHED" -eq 1 ]]; then
    hdiutil detach "$DMG_VERIFY_MOUNT" -quiet >/dev/null 2>&1 || true
  fi
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/appsift-customer-release.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
  esac
  /bin/rm -f -- "$DMG_TEMP" "$ZIP_TEMP" "$STATUS_TEMP"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$PROJECT_VERSION" || "$VERSION" != "$PROJECT_VERSION" ]]; then
  echo "Error: release version '$VERSION' does not match project.yml '$PROJECT_VERSION'." >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR" "$DMG_ROOT" "$VERIFY_ROOT" "$DMG_VERIFY_MOUNT"
: >"$TEMP_ROOT/.metadata_never_index"
: >"$VERIFY_ROOT/.metadata_never_index"
/bin/rm -f -- "$DMG" "$ZIP" "$STATUS_FILE" "$DMG_TEMP" "$ZIP_TEMP" "$STATUS_TEMP"

SIGN_IDENTITY="$("$SIGNING_SCRIPT")"

xcodebuild \
  -quiet \
  -project "$ROOT_DIR/AppSift.xcodeproj" \
  -scheme AppSift \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  build

codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
if ! codesign -dvv "$BUILT_APP" 2>&1 \
    | grep -F "Authority=$SIGN_IDENTITY" >/dev/null; then
  echo "Error: customer build did not use $SIGN_IDENTITY." >&2
  exit 1
fi
REQUIREMENT="$(
  codesign -d -r- "$BUILT_APP" 2>&1 \
    | awk '/^designated =>/ && !printed { print; printed = 1 }'
)"
if [[ "$REQUIREMENT" != *'certificate leaf = H"'* ]]; then
  echo "Error: customer build has a content-bound code requirement." >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$BUILT_APP/Contents/Info.plist")" != "$BUNDLE_ID" ]]; then
  echo "Error: customer build has the wrong bundle identifier." >&2
  exit 1
fi
for arch in $ARCHS; do
  lipo "$BUILT_APP/Contents/MacOS/$EXECUTABLE_NAME" -verify_arch "$arch"
done

ditto --noextattr --noqtn "$BUILT_APP" "$DMG_ROOT/$APP_NAME"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -quiet \
  -volname "AppSift $VERSION" \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -ov \
  "$DMG_TEMP"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DMG_TEMP" >/dev/null
codesign --verify --strict "$DMG_TEMP"
hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$DMG_VERIFY_MOUNT" \
  "$DMG_TEMP" \
  >/dev/null
DMG_ATTACHED=1
codesign --verify --deep --strict "$DMG_VERIFY_MOUNT/$APP_NAME"
if [[ "$(
    codesign -d -r- "$DMG_VERIFY_MOUNT/$APP_NAME" 2>&1 \
      | awk '/^designated =>/ && !printed { print; printed = 1 }'
  )" != "$REQUIREMENT" ]]; then
  echo "Error: DMG customer build changed its code requirement." >&2
  exit 1
fi
for arch in $ARCHS; do
  lipo "$DMG_VERIFY_MOUNT/$APP_NAME/Contents/MacOS/$EXECUTABLE_NAME" \
    -verify_arch "$arch"
done
hdiutil detach "$DMG_VERIFY_MOUNT" -quiet
DMG_ATTACHED=0

ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$ZIP_TEMP"
unzip -tq "$ZIP_TEMP" >/dev/null
ditto -x -k "$ZIP_TEMP" "$VERIFY_ROOT"
codesign --verify --deep --strict "$VERIFY_ROOT/$APP_NAME"
if [[ "$(
    codesign -d -r- "$VERIFY_ROOT/$APP_NAME" 2>&1 \
      | awk '/^designated =>/ && !printed { print; printed = 1 }'
  )" != "$REQUIREMENT" ]]; then
  echo "Error: archived customer build changed its code requirement." >&2
  exit 1
fi

DMG_SHA256="$(shasum -a 256 "$DMG_TEMP" | awk '{ print $1 }')"
ZIP_SHA256="$(shasum -a 256 "$ZIP_TEMP" | awk '{ print $1 }')"
cat >"$STATUS_TEMP" <<EOF
AppSift $VERSION
Signing: self-signed with AppSift Local Code Signing
Notarization: not notarized by Apple
Gatekeeper: customers may need to use Open from the Finder context menu
Bundle ID: $BUNDLE_ID
Designated requirement: $REQUIREMENT
DMG SHA-256: $DMG_SHA256
ZIP SHA-256: $ZIP_SHA256
EOF

mv "$DMG_TEMP" "$DMG"
mv "$ZIP_TEMP" "$ZIP"
mv "$STATUS_TEMP" "$STATUS_FILE"

printf 'DMG=%s\n' "$DMG"
printf 'DMG_SHA256=%s\n' "$DMG_SHA256"
printf 'ZIP=%s\n' "$ZIP"
printf 'ZIP_SHA256=%s\n' "$ZIP_SHA256"
printf 'STATUS=%s\n' "$STATUS_FILE"
printf 'SIGNING=self-signed\n'
printf 'NOTARIZATION=not-notarized\n'
printf 'DESIGNATED_REQUIREMENT=%s\n' "$REQUIREMENT"
