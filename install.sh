#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/Cargo.toml"
TARGET_DIR="$SCRIPT_DIR/target/simpletree-install"
LIB_DIR="$SCRIPT_DIR/lib"
DESTINATION="$LIB_DIR/simpletree-daemon"
TEMP_DESTINATION=""

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
  echo "error: Rust 1.85 or newer and Cargo are required." >&2
  exit 1
fi

rustc_version="$(rustc --version)"
if [[ "$rustc_version" =~ ^rustc[[:space:]]+([0-9]+)\.([0-9]+)\. ]]; then
  rustc_major="${BASH_REMATCH[1]}"
  rustc_minor="${BASH_REMATCH[2]}"
  if (( rustc_major < 1 || (rustc_major == 1 && rustc_minor < 85) )); then
    echo "error: Rust 1.85 or newer is required; found $rustc_version." >&2
    exit 1
  fi
else
  echo "error: could not determine the Rust version from: $rustc_version" >&2
  exit 1
fi

rustc_host="$(rustc -vV | sed -n 's/^host: //p')"
if [[ -z "$rustc_host" ]]; then
  echo "error: could not determine the native Rust target." >&2
  exit 1
fi
BUILD_OUTPUT="$TARGET_DIR/$rustc_host/release/simpletree-daemon"

# Pin both target directory and native target so Cargo environment/config
# overrides cannot make the successful build land somewhere unexpected.
cargo build --manifest-path "$MANIFEST" --release --locked \
  --target-dir "$TARGET_DIR" --target "$rustc_host"

# Refuse to install an executable that cannot identify itself. This catches a
# stale path or incomplete build before the currently installed daemon changes.
if ! backend_version="$("$BUILD_OUTPUT" --version)"; then
  echo "error: built SimpleTree backend failed its version check." >&2
  exit 1
fi
if [[ "$backend_version" != simpletree-daemon* ]]; then
  echo "error: unexpected backend version output: $backend_version" >&2
  exit 1
fi

mkdir -p "$LIB_DIR"
cleanup() {
  if [[ -n "$TEMP_DESTINATION" ]]; then
    rm -f "$TEMP_DESTINATION"
  fi
}
trap cleanup EXIT

TEMP_DESTINATION="$(mktemp "$LIB_DIR/.simpletree-daemon.XXXXXX")"
cp "$BUILD_OUTPUT" "$TEMP_DESTINATION"
chmod 0755 "$TEMP_DESTINATION"
mv -f "$TEMP_DESTINATION" "$DESTINATION"
trap - EXIT

echo "Installed $backend_version to $DESTINATION"
echo "Ensure $SCRIPT_DIR is on Vim's 'runtimepath'."
