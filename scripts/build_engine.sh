#!/usr/bin/env bash
#
# Build llama.cpp (llama-server + ggml-rpc-server) from source for one target.
#
#   scripts/build_engine.sh <target> [outdir]
#
# Targets: linux-x64 linux-arm64 windows-x64 macos-arm64 macos-x64
#          android-arm64 android-x64
#
# Environment:
#   ANDROID_NDK_HOME     Android NDK root (required for android-* targets).
#                        Defaults to $ANDROID_SDK_ROOT/ndk/<newest>, $ANDROID_HOME/ndk/<newest>
#                        or /root/android-sdk/ndk/<newest>.
#   LLAMA_CPP_VERSION    Overrides native/LLAMA_CPP_VERSION.
#   JOBS                 Parallel build jobs (default: 4; keep it low on shared hosts).
#   CMAKE_EXTRA_ARGS     Extra arguments appended to the cmake configure step.
#   LLAMA_SRC_DIR        Reuse an existing llama.cpp checkout instead of cloning.
#   LLAMA_REPO           Git URL (default https://github.com/ggml-org/llama.cpp.git).
#
# The produced directory is flat and contains:
#   desktop: llama-server[.exe], rpc-server[.exe] and the shared libraries
#   android: libllama_server.so, librpc_server.so and the shared lib*.so dependencies
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/native/LLAMA_CPP_VERSION"
VERSION="${LLAMA_CPP_VERSION:-$(tr -d '[:space:]' < "$VERSION_FILE")}"
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
  linux-x64)      HOST_KIND=linux;   HOST_ARCH=x64 ;;
  linux-arm64)    HOST_KIND=linux;   HOST_ARCH=arm64 ;;
  windows-x64)    HOST_KIND=windows; HOST_ARCH=x64 ;;
  macos-arm64)    HOST_KIND=macos;   HOST_ARCH=arm64 ;;
  macos-x64)      HOST_KIND=macos;   HOST_ARCH=x64 ;;
  android-arm64)  HOST_KIND=android; ANDROID_ABI=arm64-v8a ;;
  android-x64)    HOST_KIND=android; ANDROID_ABI=x86_64 ;;
  *) echo "error: unknown target '$TARGET'" >&2; usage ;;
esac

log() { printf '[build_engine] %s\n' "$*" >&2; }

find_ndk() {
  if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    echo "$ANDROID_NDK_HOME"
    return 0
  fi
  local root
  for root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" /root/android-sdk; do
    [ -n "$root" ] || continue
    if [ -d "$root/ndk" ]; then
      # Newest installed NDK (version sort).
      local newest
      newest="$(find "$root/ndk" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n 1)"
      if [ -n "$newest" ]; then
        echo "$newest"
        return 0
      fi
    fi
  done
  return 1
}

# --- fetch sources ---------------------------------------------------------
SRC_DIR="${LLAMA_SRC_DIR:-$REPO_ROOT/native/src/llama.cpp}"
if [ ! -f "$SRC_DIR/CMakeLists.txt" ]; then
  log "cloning llama.cpp $VERSION into $SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --depth 1 --branch "$VERSION" "${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}" "$SRC_DIR"
else
  log "using existing checkout $SRC_DIR"
fi

BUILD_PARENT="$REPO_ROOT/native/src/build-$TARGET"
BUILD_DIR="$BUILD_PARENT/llama.cpp"
mkdir -p "$BUILD_DIR"

CMAKE_ARGS=(
  -S "$SRC_DIR"
  -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_TOOLS=ON
  -DLLAMA_BUILD_SERVER=ON
  -DLLAMA_CURL=OFF
  -DGGML_RPC=ON
  -DBUILD_SHARED_LIBS=ON
)

if [ "$HOST_KIND" = "android" ]; then
  NDK="$(find_ndk || true)"
  if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
    echo "error: Android NDK not found. Install one, e.g.:" >&2
    echo "  sdkmanager 'ndk;27.2.12479018'" >&2
    echo "then export ANDROID_NDK_HOME=/path/to/ndk" >&2
    exit 1
  fi
  log "using NDK $NDK (ABI $ANDROID_ABI)"
  CMAKE_ARGS+=(
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
    -DANDROID_ABI="$ANDROID_ABI"
    -DANDROID_PLATFORM=android-28
    -DGGML_OPENMP=OFF
  )
else
  # Native builds must run on a matching host; CMAKE_EXTRA_ARGS can provide a
  # cross toolchain file for the rare cross-compile case.
  HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  HOST_CPU="$(uname -m)"
  case "$HOST_OS" in darwin) HOST_OS=macos ;; mingw*|msys*|cygwin*) HOST_OS=windows ;; esac
  case "$HOST_CPU" in x86_64|amd64) HOST_CPU=x64 ;; aarch64|arm64) HOST_CPU=arm64 ;; esac
  if [ -z "${CMAKE_EXTRA_ARGS:-}" ] && { [ "$HOST_OS" != "$HOST_KIND" ] || [ "$HOST_CPU" != "$HOST_ARCH" ]; }; then
    echo "error: target $TARGET needs a $HOST_KIND-$HOST_ARCH host (this is $HOST_OS-$HOST_CPU)." >&2
    echo "       Pass a cross toolchain via CMAKE_EXTRA_ARGS or build on a matching runner." >&2
    exit 1
  fi
  # Portable CPU build: avoids -march=native binaries that SIGILL on older CPUs.
  CMAKE_ARGS+=(-DGGML_NATIVE=OFF)
fi

if [ -n "${CMAKE_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  CMAKE_ARGS+=(${CMAKE_EXTRA_ARGS})
fi

log "configuring: cmake ${CMAKE_ARGS[*]}"
cmake "${CMAKE_ARGS[@]}"

log "building with -j$JOBS"
if ! cmake --build "$BUILD_DIR" --config Release -j "$JOBS" --target llama-server ggml-rpc-server; then
  log "target-specific build failed; building the default target"
  cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
fi

# --- collect outputs -------------------------------------------------------
BIN_DIR="$BUILD_DIR/bin"
[ -d "$BIN_DIR" ] || BIN_DIR="$BUILD_DIR"

find_one() {
  # $1 = name; searches bin then the whole build tree
  if [ -f "$BIN_DIR/$1" ]; then echo "$BIN_DIR/$1"; return 0; fi
  local hit
  hit="$(find "$BUILD_DIR" -type f -name "$1" | head -n 1)"
  [ -n "$hit" ] && { echo "$hit"; return 0; }
  return 1
}

LLAMA_BIN="$(find_one llama-server || find_one llama-server.exe || true)"
RPC_BIN="$(find_one ggml-rpc-server || find_one rpc-server || find_one ggml-rpc-server.exe || find_one rpc-server.exe || true)"
if [ -z "$LLAMA_BIN" ] || [ -z "$RPC_BIN" ]; then
  echo "error: build finished but llama-server/rpc-server were not found under $BUILD_DIR" >&2
  exit 1
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

copy_libs() {
  local from="$1"
  [ -d "$from" ] || return 0
  find "$from" -maxdepth 1 \( -type f -o -type l \) \
    \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dll' \) \
    -exec cp -a {} "$OUTDIR"/ \;
}

if [ "$HOST_KIND" = "android" ]; then
  cp -a "$LLAMA_BIN" "$OUTDIR/libllama_server.so"
  cp -a "$RPC_BIN" "$OUTDIR/librpc_server.so"
  copy_libs "$BIN_DIR"
  # Some CMake layouts put the shared libs in the build root / ggml subdirs.
  copy_libs "$BUILD_DIR"
  find "$BUILD_DIR" \( -type f -o -type l \) -name 'lib*.so*' -not -path '*/CMakeFiles/*' -exec cp -a {} "$OUTDIR"/ \;
else
  cp -a "$LLAMA_BIN" "$OUTDIR/llama-server$( [[ "$LLAMA_BIN" == *.exe ]] && echo .exe )"
  cp -a "$RPC_BIN" "$OUTDIR/rpc-server$( [[ "$RPC_BIN" == *.exe ]] && echo .exe )"
  copy_libs "$BIN_DIR"
  copy_libs "$BUILD_DIR"
  find "$BUILD_DIR" \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dll' \) \
    -not -path '*/CMakeFiles/*' -exec cp -a {} "$OUTDIR"/ \;
fi

log "wrote $OUTDIR"
ls -l "$OUTDIR" >&2
