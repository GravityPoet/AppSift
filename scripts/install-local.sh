#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this installer requires macOS." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_SCRIPT="$ROOT_DIR/scripts/ensure-local-codesign-cert.sh"
APP_NAME="AppSift.app"
BUNDLE_ID="com.gravitypoet.appsift"
EXECUTABLE_NAME="AppSift"
INSTALL_APP="/Applications/$APP_NAME"
ARCHS="${ARCHS:-arm64 x86_64}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PROCESS_PATTERN='^/Applications/AppSift\.app/Contents/MacOS/AppSift( |$)'
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/appsift-install.XXXXXX")"
DERIVED_DATA="$TEMP_ROOT/DerivedData.noindex"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
INSTALL_STAGING="/Applications/.appsift-staging-$$"
DISPLACED_APP="/Applications/.appsift-displaced-$$"
BACKUP_ZIP=""
OLD_REQUIREMENT=""
NEW_REQUIREMENT=""
REPLACEMENT_STARTED=0
HAD_PREVIOUS=0

unregister_app_bundle() {
  local app_bundle="$1"
  if [[ -d "$app_bundle/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
    done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

designated_requirement() {
  codesign -d -r- "$1" 2>&1 \
    | awk '/^designated =>/ && !printed { print; printed = 1 }'
}

verify_app() {
  local app_bundle="$1"
  local identity="$2"
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$app_bundle/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_id" == "$BUNDLE_ID" ]] || {
    echo "Error: unexpected bundle identifier in $app_bundle: $bundle_id" >&2
    return 1
  }
  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  codesign -dvv "$app_bundle" 2>&1 \
    | grep -F "Authority=$identity" >/dev/null || {
      echo "Error: $app_bundle was not signed by $identity." >&2
      return 1
    }
  designated_requirement "$app_bundle" \
    | grep -F 'certificate leaf = H"' >/dev/null || {
      echo "Error: $app_bundle has a content-bound code requirement." >&2
      return 1
    }
  local arch
  for arch in $ARCHS; do
    lipo "$app_bundle/Contents/MacOS/$EXECUTABLE_NAME" -verify_arch "$arch"
  done
}

stop_installed_app() {
  /usr/bin/swift -e '
    import AppKit
    for app in NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.gravitypoet.appsift"
    ) {
      _ = app.terminate()
    }
  ' >/dev/null 2>&1 || true

  local attempt
  for attempt in 1 2 3 4 5; do
    pgrep -f "$PROCESS_PATTERN" >/dev/null || return 0
    sleep 1
  done
  pkill -TERM -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
  sleep 1
  if pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    echo "Error: AppSift did not quit cleanly." >&2
    return 1
  fi
}

start_installed_app() {
  open "$INSTALL_APP"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if pgrep -f "$PROCESS_PATTERN" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "Error: AppSift did not start from /Applications." >&2
  return 1
}

restore_displaced_app() {
  [[ -d "$DISPLACED_APP" ]] || return 1
  [[ ! -e "$INSTALL_APP" ]] || return 1
  mv "$DISPLACED_APP" "$INSTALL_APP"
  "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
  open "$INSTALL_APP" >/dev/null 2>&1 || true
}

cleanup_or_rollback() {
  local status=$?
  trap - EXIT INT TERM
  unregister_app_bundle "$BUILT_APP"
  unregister_app_bundle "$INSTALL_STAGING"
  if [[ "$status" -ne 0 && "$REPLACEMENT_STARTED" -eq 1 ]]; then
    stop_installed_app >/dev/null 2>&1 || true
    unregister_app_bundle "$INSTALL_APP"
    case "$INSTALL_APP" in
      /Applications/AppSift.app) /bin/rm -rf -- "$INSTALL_APP" ;;
    esac
    if [[ "$HAD_PREVIOUS" -eq 1 ]] && restore_displaced_app; then
      echo "Restored the previous AppSift installation after failure." >&2
    elif [[ "$HAD_PREVIOUS" -eq 1 ]]; then
      echo "Error: automatic AppSift rollback failed; use $BACKUP_ZIP." >&2
    fi
  fi
  case "$INSTALL_STAGING" in
    /Applications/.appsift-staging-*) /bin/rm -rf -- "$INSTALL_STAGING" ;;
  esac
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/appsift-install.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
  esac
  exit "$status"
}
trap cleanup_or_rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: >"$TEMP_ROOT/.metadata_never_index"
case "$INSTALL_STAGING" in
  /Applications/.appsift-staging-*) /bin/rm -rf -- "$INSTALL_STAGING" ;;
esac
case "$DISPLACED_APP" in
  /Applications/.appsift-displaced-*) /bin/rm -rf -- "$DISPLACED_APP" ;;
esac

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

verify_app "$BUILT_APP" "$SIGN_IDENTITY"
NEW_REQUIREMENT="$(designated_requirement "$BUILT_APP")"

if [[ -d "$INSTALL_APP" ]]; then
  HAD_PREVIOUS=1
  OLD_REQUIREMENT="$(designated_requirement "$INSTALL_APP" || true)"
  backup_stamp="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="$HOME/Library/Application Support/Codex/Backups/AppSift/$backup_stamp"
  BACKUP_ZIP="$backup_dir/AppSift.app.zip"
  backup_verify="$TEMP_ROOT/backup-verification"
  mkdir -p "$backup_dir" "$backup_verify"
  chmod 700 "$backup_dir"
  ditto -c -k --sequesterRsrc --keepParent "$INSTALL_APP" "$BACKUP_ZIP"
  chmod 600 "$BACKUP_ZIP"
  unzip -tq "$BACKUP_ZIP" >/dev/null
  ditto -x -k "$BACKUP_ZIP" "$backup_verify"
  codesign --verify --deep --strict "$backup_verify/$APP_NAME"
fi

ditto --noextattr --noqtn "$BUILT_APP" "$INSTALL_STAGING"
xattr -cr "$INSTALL_STAGING"
verify_app "$INSTALL_STAGING" "$SIGN_IDENTITY"

stop_installed_app
REPLACEMENT_STARTED=1
if [[ "$HAD_PREVIOUS" -eq 1 ]]; then
  unregister_app_bundle "$INSTALL_APP"
  mv "$INSTALL_APP" "$DISPLACED_APP"
  unregister_app_bundle "$DISPLACED_APP"
fi
mv "$INSTALL_STAGING" "$INSTALL_APP"
xattr -cr "$INSTALL_APP"
verify_app "$INSTALL_APP" "$SIGN_IDENTITY"
"$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
start_installed_app

unregister_app_bundle "$BUILT_APP"
case "$TEMP_ROOT" in
  "${TMPDIR:-/tmp}"/appsift-install.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
esac

if [[ -e "$TEMP_ROOT" || -e "$INSTALL_STAGING" ]]; then
  echo "Error: AppSift-owned build or staging paths were not removed." >&2
  exit 1
fi

read_physical_paths() {
  # Scan only roots owned by this product. Unrelated builds can mutate the
  # system temporary directory while find is walking it and cause a false
  # installer failure; this installer's exact temporary root is checked above.
  for search_root in /Applications "$ROOT_DIR"; do
    [[ -d "$search_root" ]] || continue
    if ! find "$search_root" -type d -name '*.app' -prune -print0 2>/dev/null; then
      echo "Error: could not scan AppSift path root: $search_root" >&2
      return 1
    fi
  done | while IFS= read -r -d '' app_bundle; do
    plist="$app_bundle/Contents/Info.plist"
    [[ -f "$plist" ]] || continue
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    if [[ "$app_id" == "$BUNDLE_ID" ]]; then
      printf '%s\n' "$app_bundle"
    fi
  done | sort -u
}

if ! physical_paths="$(read_physical_paths)"; then
  echo "Error: AppSift physical-path verification failed." >&2
  exit 1
fi
if [[ "$physical_paths" != "$INSTALL_APP" ]]; then
  echo "Error: duplicate AppSift bundles remain on disk:" >&2
  printf '%s\n' "${physical_paths:-<none>}" >&2
  exit 1
fi

spotlight_paths=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  spotlight_paths="$(mdfind 'kMDItemCFBundleIdentifier == "com.gravitypoet.appsift"c' | sort -u)"
  [[ "$spotlight_paths" == "$INSTALL_APP" ]] && break
  sleep 1
done
if [[ "$spotlight_paths" != "$INSTALL_APP" ]]; then
  echo "Error: Spotlight reports unexpected AppSift paths:" >&2
  printf '%s\n' "${spotlight_paths:-<none>}" >&2
  exit 1
fi

launchservices_paths="$(
  APPSIFT_FINAL_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
    import Foundation
    import CoreServices
    let identifier = ProcessInfo.processInfo.environment["APPSIFT_FINAL_BUNDLE_ID"]! as CFString
    let urls = (LSCopyApplicationURLsForBundleIdentifier(identifier, nil)?.takeRetainedValue()
      as? [URL]) ?? []
    for url in urls.sorted(by: { $0.path < $1.path }) { print(url.path) }
  ' | sort -u
)"
if [[ "$launchservices_paths" != "$INSTALL_APP" ]]; then
  echo "Error: LaunchServices reports unexpected AppSift paths:" >&2
  printf '%s\n' "${launchservices_paths:-<none>}" >&2
  exit 1
fi

read_dock_paths() {
  APPSIFT_FINAL_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
    import Foundation
    let bundleID = ProcessInfo.processInfo.environment["APPSIFT_FINAL_BUNDLE_ID"]!
    let plistURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dictionary = root as? [String: Any],
          let apps = dictionary["persistent-apps"] as? [[String: Any]] else { exit(0) }
    for app in apps {
      guard let tile = app["tile-data"] as? [String: Any],
            tile["bundle-identifier"] as? String == bundleID,
            let file = tile["file-data"] as? [String: Any],
            let raw = file["_CFURLString"] as? String else { continue }
      if let url = URL(string: raw), url.isFileURL { print(url.path) } else { print(raw) }
    }
  ' | sort -u
}

dock_paths="$(read_dock_paths)"
if [[ -n "$dock_paths" && "$dock_paths" != "$INSTALL_APP" ]]; then
  killall Dock >/dev/null 2>&1 || true
  sleep 2
  dock_paths="$(read_dock_paths)"
fi
if [[ -n "$dock_paths" && "$dock_paths" != "$INSTALL_APP" ]]; then
  echo "Error: Dock points AppSift at a non-canonical path:" >&2
  printf '%s\n' "$dock_paths" >&2
  exit 1
fi

FDA_REAUTH_REQUIRED=0
if [[ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]]; then
  FDA_REAUTH_REQUIRED=1
fi

unregister_app_bundle "$DISPLACED_APP"
case "$DISPLACED_APP" in
  /Applications/.appsift-displaced-*) /bin/rm -rf -- "$DISPLACED_APP" ;;
esac
REPLACEMENT_STARTED=0

if [[ "$FDA_REAUTH_REQUIRED" -eq 1 ]]; then
  /usr/bin/tccutil reset SystemPolicyAllFiles "$BUNDLE_ID"
  stop_installed_app
  start_installed_app
  sleep 1
  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles' \
    >/dev/null 2>&1 || true
fi

trap - EXIT INT TERM

printf 'INSTALLED_APP=%s\n' "$INSTALL_APP"
printf 'SIGN_IDENTITY=%s\n' "$SIGN_IDENTITY"
printf 'DESIGNATED_REQUIREMENT=%s\n' "$NEW_REQUIREMENT"
printf 'FDA_REAUTH_REQUIRED=%s\n' "$FDA_REAUTH_REQUIRED"
if [[ -n "$BACKUP_ZIP" ]]; then
  printf 'BACKUP_ZIP=%s\n' "$BACKUP_ZIP"
fi
