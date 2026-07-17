#!/bin/bash
set -euo pipefail

# Compatibility entry point. Current customer releases intentionally use the
# same dedicated self-signed identity as Debug and installed Release builds.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/scripts/release-self-signed.sh"

if [[ "$#" -gt 1 ]]; then
  echo "Error: notarization profiles are not accepted by the current self-signed release flow." >&2
  echo "A Developer ID migration must use the explicitly gated GitHub workflow." >&2
  exit 2
fi

if [[ "$#" -eq 1 ]]; then
  exec "$RELEASE_SCRIPT" "$1"
fi
exec "$RELEASE_SCRIPT"
