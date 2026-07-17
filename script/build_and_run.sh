#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AppSift"
BUNDLE_ID="com.gravitypoet.appsift"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_SIGNING_SCRIPT="$ROOT_DIR/scripts/ensure-local-codesign-cert.sh"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
DERIVED_DATA="$TMP_ROOT/.AppSift-RunDerivedData-$UID.noindex"
LEGACY_DERIVED_DATA="$TMP_ROOT/.AppSift-RunDerivedData-$UID"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/AppSift.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AppSift"
LEGACY_APP_BUNDLE="$LEGACY_DERIVED_DATA/Build/Products/Debug/AppSift.app"
LEGACY_APP_BINARY="$LEGACY_APP_BUNDLE/Contents/MacOS/AppSift"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

is_development_command() {
  [[ "$1" == "$APP_BINARY" || "$1" == "$APP_BINARY "* ||
    "$1" == "$LEGACY_APP_BINARY" || "$1" == "$LEGACY_APP_BINARY "* ]]
}

unregister_app_bundle() {
  local app_bundle="$1"
  if [[ -d "$app_bundle/Contents" ]]; then
    while IFS= read -r -d '' nested_app; do
      "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
    done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
  fi
  # Also clear the known Sparkle helper path when a prior cleanup already
  # removed the bundle before LaunchServices finished compacting its database.
  "$LSREGISTER" -u "$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

unregister_build() {
  unregister_app_bundle "$APP_BUNDLE"
  unregister_app_bundle "$LEGACY_APP_BUNDLE"
  if [[ -d /Applications/AppSift.app ]]; then
    "$LSREGISTER" -f /Applications/AppSift.app >/dev/null 2>&1 || true
  fi
}

cleanup_generated_app() {
  unregister_build
  case "$APP_BUNDLE" in
    "$DERIVED_DATA"/Build/Products/Debug/AppSift.app) ;;
    *)
      echo "Refusing to remove unexpected app path: $APP_BUNDLE" >&2
      return 2
      ;;
  esac
  rm -rf -- "$APP_BUNDLE"
  case "$LEGACY_APP_BUNDLE" in
    "$LEGACY_DERIVED_DATA"/Build/Products/Debug/AppSift.app) ;;
    *)
      echo "Refusing to remove unexpected legacy app path: $LEGACY_APP_BUNDLE" >&2
      return 2
      ;;
  esac
  rm -rf -- "$LEGACY_APP_BUNDLE"
  "$LSREGISTER" -gc >/dev/null 2>&1 || true
}

stop_launched_app() {
  if [[ -n "${LAUNCHED_PID:-}" ]] && kill -0 "$LAUNCHED_PID" >/dev/null 2>&1; then
    kill "$LAUNCHED_PID" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      kill -0 "$LAUNCHED_PID" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if kill -0 "$LAUNCHED_PID" >/dev/null 2>&1; then
      kill -KILL "$LAUNCHED_PID" >/dev/null 2>&1 || true
    fi
  fi
}

cleanup_on_exit() {
  stop_launched_app
  cleanup_generated_app
}

wait_for_launched_app() {
  while kill -0 "$LAUNCHED_PID" >/dev/null 2>&1 &&
      is_development_command "$(ps -p "$LAUNCHED_PID" -o command= 2>/dev/null || true)"; do
    sleep 1
  done
}

stop_existing_development_app() {
  local candidate
  local command
  local found=0
  for candidate in $(pgrep -x "$APP_NAME" || true); do
    command=$(ps -p "$candidate" -o command= 2>/dev/null || true)
    if is_development_command "$command"; then
      kill "$candidate" >/dev/null 2>&1 || true
      found=1
    fi
  done
  [[ "$found" -eq 0 ]] && return 0

  for _ in {1..30}; do
    found=0
    for candidate in $(pgrep -x "$APP_NAME" || true); do
      command=$(ps -p "$candidate" -o command= 2>/dev/null || true)
      if is_development_command "$command"; then
        found=1
        break
      fi
    done
    [[ "$found" -eq 0 ]] && return 0
    sleep 0.1
  done

  for candidate in $(pgrep -x "$APP_NAME" || true); do
    command=$(ps -p "$candidate" -o command= 2>/dev/null || true)
    if is_development_command "$command"; then
      kill -KILL "$candidate" >/dev/null 2>&1 || true
    fi
  done
}

stop_existing_development_app
unregister_build

if [[ "$MODE" == "clean" || "$MODE" == "--clean" ]]; then
  case "$DERIVED_DATA" in
    "$TMP_ROOT"/.AppSift-RunDerivedData-*.noindex) ;;
    *)
      echo "Refusing to remove unexpected build path: $DERIVED_DATA" >&2
      exit 2
      ;;
  esac
  case "$LEGACY_DERIVED_DATA" in
    "$TMP_ROOT"/.AppSift-RunDerivedData-*) ;;
    *)
      echo "Refusing to remove unexpected legacy build path: $LEGACY_DERIVED_DATA" >&2
      exit 2
      ;;
  esac
  rm -rf -- "$DERIVED_DATA" "$LEGACY_DERIVED_DATA"
  "$LSREGISTER" -gc >/dev/null 2>&1 || true
  echo "Removed $DERIVED_DATA and legacy cache $LEGACY_DERIVED_DATA"
  exit 0
fi

# A force-killed prior runner may have missed its EXIT trap. The process is
# confirmed stopped above, so removing only the generated app bundle is safe
# and keeps package/build caches reusable.
cleanup_generated_app
trap cleanup_generated_app EXIT

SIGN_IDENTITY="$("$LOCAL_SIGNING_SCRIPT")"

xcodebuild \
  -quiet \
  -project "$ROOT_DIR/AppSift.xcodeproj" \
  -scheme AppSift \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  build

codesign --verify --deep --strict "$APP_BUNDLE"
if ! codesign -dvv "$APP_BUNDLE" 2>&1 \
    | grep -F "Authority=$SIGN_IDENTITY" >/dev/null; then
  echo "AppSift development build did not use $SIGN_IDENTITY." >&2
  exit 1
fi
if ! codesign -d -r- "$APP_BUNDLE" 2>&1 \
    | grep -F 'certificate leaf = H"' >/dev/null; then
  echo "AppSift development build has an unstable code requirement." >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
  LAUNCHED_PID=""
  for _ in {1..30}; do
    for candidate in $(pgrep -x "$APP_NAME" || true); do
      command=$(ps -p "$candidate" -o command= 2>/dev/null || true)
      if is_development_command "$command"; then
        LAUNCHED_PID="$candidate"
        break 2
      fi
    done
    sleep 0.1
  done
  if [[ -z "$LAUNCHED_PID" ]]; then
    echo "AppSift development process did not start." >&2
    return 1
  fi
  # LaunchServices keeps a running bundle registered. Keep the runner attached
  # so its EXIT trap can always unregister and remove the generated app after
  # the exact development process exits (or the runner is interrupted).
  trap cleanup_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

case "$MODE" in
  run)
    open_app
    wait_for_launched_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    kill -0 "$LAUNCHED_PID" >/dev/null 2>&1
    stop_launched_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--clean]" >&2
    exit 2
    ;;
esac
