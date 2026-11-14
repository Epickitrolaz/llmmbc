#!/usr/bin/env bash
#
# Build the llama.cpp engine binaries for one target from source, with the LLMMBC
# patches in native/patches/ applied (docs/ARCHITECTURE.md §6 and §6.1).
#
#   scripts/fetch_engine.sh <target> [outdir]
#
# Every target is built from the pinned tag in native/LLAMA_CPP_VERSION. Upstream
# release archives are not used: they lack the SET_TENSOR_FROM_FILE /
# --lazy-weights support that lets workers load weights from their own disk.
#
# Output is a flat directory (default native/out/<target>/) containing:
#   llama-server, rpc-server                desktop
#   llama-server.exe, rpc-server.exe        windows
#   libllama_server.so, librpc_server.so    android (+ shared lib*.so deps)
#
# Environment:
#   LLAMA_CPP_VERSION   Overrides native/LLAMA_CPP_VERSION.
#   JOBS                Passed to build_engine.sh (default 4).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${LLAMA_CPP_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/native/LLAMA_CPP_VERSION")}"
JOBS="${JOBS:-4}"

usage() {
  echo "usage: $0 <target> [outdir]" >&2
  echo "targets: linux-x64 linux-arm64 windows-x64 macos-arm64 macos-x64 android-arm64 android-x64" >&2
  exit 2
}

TARGET="${1:-}"
[ -n "$TARGET" ] || usage
OUTDIR="${2:-$REPO_ROOT/native/out/$TARGET}"

case "$TARGET" in
  linux-x64|linux-arm64|windows-x64|macos-arm64|macos-x64|android-arm64|android-x64) ;;
  *) echo "error: unknown target '$TARGET'" >&2; usage ;;
esac

log() { printf '[fetch_engine] %s\n' "$*" >&2; }

log "building $TARGET from source ($VERSION, patches in native/patches/)"
LLAMA_CPP_VERSION="$VERSION" JOBS="$JOBS" "$SCRIPT_DIR/build_engine.sh" "$TARGET" "$OUTDIR"

have_engine() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  case "$TARGET" in
    android-arm64|android-x64)
      [ -f "$dir/libllama_server.so" ] && [ -f "$dir/librpc_server.so" ] ;;
    *)
      [ -f "$dir/llama-server" ] || [ -f "$dir/llama-server.exe" ] || return 1
      [ -f "$dir/rpc-server" ] || [ -f "$dir/rpc-server.exe" ] ;;
  esac
}

if ! have_engine "$OUTDIR"; then
  echo "error: engine output at $OUTDIR is incomplete" >&2
  ls -l "$OUTDIR" >&2 || true
  exit 1
fi

log "engine ready in $OUTDIR"
ls -l "$OUTDIR" >&2
