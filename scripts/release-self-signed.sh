#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this release builder requires macOS." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_VERSION="$(
  sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ROOT_DIR/project.yml"
)"
VERSION="${1:-$PROJECT_VERSION}"
APP_NAME="AppSift.app"
BUNDLE_ID="com.gravitypoet.appsift"
EXECUTABLE_NAME="AppSift"
SIGNING_NAME="AppSift Local Code Signing"
SIGNING_SHA1="90F1896851E020316315F97A149EABA00F9CFD8C"
SIGNING_SHA256="D3C9F51F87A9826C44F53999C2D2F535F0CA921D6982C54939AF3DF30B5E797D"
EXPECTED_REQUIREMENT='designated => identifier "com.gravitypoet.appsift" and certificate leaf = H"90f1896851e020316315f97a149eaba00f9cfd8c"'
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ARCHS="${ARCHS:-arm64 x86_64}"
OUTPUT_DIR="$ROOT_DIR/build"
DMG="$OUTPUT_DIR/AppSift-$VERSION-self-signed.dmg"
ZIP="$OUTPUT_DIR/AppSift-$VERSION-self-signed.zip"
STATUS_FILE="$OUTPUT_DIR/AppSift-$VERSION-self-signed.txt"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/appsift-customer-release.XXXXXX")"
DERIVED_DATA="$TEMP_ROOT/DerivedData.noindex"
GENERATED_PROJECT_DIR="$TEMP_ROOT/project"
GENERATED_PROJECT="$GENERATED_PROJECT_DIR/AppSift.xcodeproj"
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
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen is required to build the release project from project.yml." >&2
  exit 1
fi

IDENTITY_MATCHES="$(
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | /usr/bin/grep -F "\"$SIGNING_NAME\"" || true
)"
if [[ "$IDENTITY_MATCHES" != *"$SIGNING_SHA1"* ]]; then
  echo "Error: the pinned AppSift release identity is missing or changed." >&2
  echo "Expected SHA-1: $SIGNING_SHA1" >&2
  echo "Release builds must not create or replace the customer signing identity." >&2
  exit 1
fi
CERTIFICATE_INFO="$(
  /usr/bin/security find-certificate -Z -c "$SIGNING_NAME" "$KEYCHAIN" 2>/dev/null || true
)"
if [[ "$CERTIFICATE_INFO" != *"SHA-256 hash: $SIGNING_SHA256"* ]]; then
  echo "Error: the AppSift release certificate does not match the pinned SHA-256 fingerprint." >&2
  exit 1
fi
if [[ -d "/Applications/$APP_NAME/Contents" ]]; then
  INSTALLED_REQUIREMENT="$(
    /usr/bin/codesign -d -r- "/Applications/$APP_NAME" 2>&1 \
      | /usr/bin/awk '/^designated =>/ && !printed { print; printed = 1 }'
  )"
  if [[ "$INSTALLED_REQUIREMENT" != "$EXPECTED_REQUIREMENT" ]]; then
    echo "Error: /Applications/$APP_NAME does not match the pinned release identity." >&2
    echo "Refusing to publish an update that would silently break macOS privacy permissions." >&2
    exit 1
  fi
fi

mkdir -p \
  "$OUTPUT_DIR" \
  "$DMG_ROOT" \
  "$VERIFY_ROOT" \
  "$DMG_VERIFY_MOUNT" \
  "$GENERATED_PROJECT_DIR"
: >"$TEMP_ROOT/.metadata_never_index"
: >"$VERIFY_ROOT/.metadata_never_index"
/bin/rm -f -- "$DMG" "$ZIP" "$STATUS_FILE" "$DMG_TEMP" "$ZIP_TEMP" "$STATUS_TEMP"

/bin/ln -s "$ROOT_DIR/AppSift" "$GENERATED_PROJECT_DIR/AppSift"
/bin/ln -s "$ROOT_DIR/AppSiftTests" "$GENERATED_PROJECT_DIR/AppSiftTests"
xcodegen generate \
  --no-env \
  --spec "$ROOT_DIR/project.yml" \
  --project "$GENERATED_PROJECT_DIR" \
  --project-root "$ROOT_DIR"

xcodebuild \
  -quiet \
  -project "$GENERATED_PROJECT" \
  -scheme AppSift \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_SHA1" \
  DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  build

codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
if ! codesign -dvv "$BUILT_APP" 2>&1 \
    | grep -F "Authority=$SIGNING_NAME" >/dev/null; then
  echo "Error: customer build did not use $SIGNING_NAME." >&2
  exit 1
fi
REQUIREMENT="$(
  codesign -d -r- "$BUILT_APP" 2>&1 \
    | awk '/^designated =>/ && !printed { print; printed = 1 }'
)"
if [[ "$REQUIREMENT" != "$EXPECTED_REQUIREMENT" ]]; then
  echo "Error: customer build does not match the pinned designated requirement." >&2
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
codesign --force --sign "$SIGNING_SHA1" --timestamp=none "$DMG_TEMP" >/dev/null
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
Certificate SHA-256: $SIGNING_SHA256
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
