#!/usr/bin/env bash
#
# Fetch (or build) llama.cpp engine binaries for one target.
#
#   scripts/fetch_engine.sh <target> [outdir]
#
# Prefers the official prebuilt llama.cpp release archive when it contains both
# llama-server and an RPC server (upstream renamed rpc-server to ggml-rpc-server
# in 2025). Falls back to scripts/build_engine.sh for targets without a usable
# prebuilt archive (currently android-x64).
#
# Output is a flat directory (default native/out/<target>/) containing:
#   llama-server, rpc-server                desktop
#   llama-server.exe, rpc-server.exe        windows
#   libllama_server.so, librpc_server.so    android (+ shared lib*.so deps)
#
# Environment:
#   LLAMA_CPP_VERSION   Overrides native/LLAMA_CPP_VERSION.
#   LLAMA_RELEASE_BASE  Release download base URL (default GitHub releases).
#   JOBS                Passed to build_engine.sh (default 4).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${LLAMA_CPP_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/native/LLAMA_CPP_VERSION")}"
RELEASE_BASE="${LLAMA_RELEASE_BASE:-https://github.com/ggml-org/llama.cpp/releases/download}"
JOBS="${JOBS:-4}"

usage() {
  echo "usage: $0 <target> [outdir]" >&2
  echo "targets: linux-x64 linux-arm64 windows-x64 macos-arm64 macos-x64 android-arm64 android-x64" >&2
  exit 2
}

TARGET="${1:-}"
[ -n "$TARGET" ] || usage
OUTDIR="${2:-$REPO_ROOT/native/out/$TARGET}"

# target -> release asset suffix (empty = no prebuilt)
ASSET=""
case "$TARGET" in
  linux-x64)     ASSET="ubuntu-x64.tar.gz" ;;
  linux-arm64)   ASSET="ubuntu-arm64.tar.gz" ;;
  windows-x64)   ASSET="win-cpu-x64.zip" ;;
  macos-arm64)   ASSET="macos-arm64.tar.gz" ;;
  macos-x64)     ASSET="macos-x64.tar.gz" ;;
  android-arm64) ASSET="android-arm64.tar.gz" ;;
  android-x64)   ASSET="" ;;
  *) echo "error: unknown target '$TARGET'" >&2; usage ;;
esac

log() { printf '[fetch_engine] %s\n' "$*" >&2; }

have_engine() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  if [ "$TARGET" = "android-arm64" ] || [ "$TARGET" = "android-x64" ]; then
    [ -f "$dir/libllama_server.so" ] && [ -f "$dir/librpc_server.so" ]
  else
    { [ -f "$dir/llama-server" ] || [ -f "$dir/llama-server.exe" ]; } &&
      { [ -f "$dir/rpc-server" ] || [ -f "$dir/rpc-server.exe" ]; }
  fi
}

extract_zip() {
  local zip="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip" -d "$dest"
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -NonInteractive -Command \
      "Expand-Archive -LiteralPath '$(cygpath -w "$zip" 2>/dev/null || echo "$zip")' -DestinationPath '$(cygpath -w "$dest" 2>/dev/null || echo "$dest")' -Force"
  else
    echo "error: neither unzip nor powershell.exe is available to extract $zip" >&2
    exit 1
  fi
}

fetch_prebuilt() {
  local asset_name="llama-${VERSION}-bin-${ASSET}"
  local url="$RELEASE_BASE/$VERSION/$asset_name"
  local cache_dir="$REPO_ROOT/native/src/downloads"
  local archive="$cache_dir/$asset_name"
  local extract_dir="$REPO_ROOT/native/src/extracted/${VERSION}-${TARGET}"
  mkdir -p "$cache_dir"

  if [ ! -s "$archive" ]; then
    log "downloading $url"
    if ! curl -fL --retry 3 --retry-delay 2 -o "$archive.part" "$url"; then
      rm -f "$archive.part"
      return 1
    fi
    mv "$archive.part" "$archive"
  else
    log "using cached $archive"
  fi

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  case "$archive" in
    *.zip) extract_zip "$archive" "$extract_dir" ;;
    *)     tar -xzf "$archive" -C "$extract_dir" ;;
  esac

  local llama rpc
  llama="$(find "$extract_dir" -type f \( -name llama-server -o -name llama-server.exe \) | head -n 1 || true)"
  rpc="$(find "$extract_dir" -type f \( -name ggml-rpc-server -o -name rpc-server -o \
    -name ggml-rpc-server.exe -o -name rpc-server.exe \) | head -n 1 || true)"
  if [ -z "$llama" ] || [ -z "$rpc" ]; then
    log "prebuilt archive $asset_name lacks llama-server/rpc-server; building from source"
    rm -rf "$extract_dir"
    return 1
  fi

  rm -rf "$OUTDIR"
  mkdir -p "$OUTDIR"

  if [ "$TARGET" = "android-arm64" ]; then
    cp -a "$llama" "$OUTDIR/libllama_server.so"
    cp -a "$rpc" "$OUTDIR/librpc_server.so"
  else
    case "$llama" in *.exe) cp -a "$llama" "$OUTDIR/llama-server.exe"; cp -a "$rpc" "$OUTDIR/rpc-server.exe" ;;
      *) cp -a "$llama" "$OUTDIR/llama-server"; cp -a "$rpc" "$OUTDIR/rpc-server" ;; esac
  fi

  # Shared libraries live next to the binaries in official archives. Copy
  # symlinks too (libggml.so -> libggml.so.1 -> libggml.so.1.0.0) with -a.
  local root
  root="$(dirname "$llama")"
  find "$root" -maxdepth 1 \( -type f -o -type l \) \
    \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dll' \) \
    -exec cp -a {} "$OUTDIR"/ \;
  # Preserve symlinks that point at versioned libraries (cp -a above does), but make
  # sure dangling links are not kept if their target was not in the archive.
  find "$OUTDIR" -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null || true
  chmod +x "$OUTDIR"/* 2>/dev/null || true
  return 0
}

if [ -n "$ASSET" ] && fetch_prebuilt; then
  log "fetched prebuilt $TARGET ($VERSION)"
else
  log "building $TARGET from source ($VERSION)"
  LLAMA_CPP_VERSION="$VERSION" JOBS="$JOBS" "$SCRIPT_DIR/build_engine.sh" "$TARGET" "$OUTDIR"
fi

if ! have_engine "$OUTDIR"; then
  echo "error: engine output at $OUTDIR is incomplete" >&2
  ls -l "$OUTDIR" >&2 || true
  exit 1
fi

log "engine ready in $OUTDIR"
ls -l "$OUTDIR" >&2
