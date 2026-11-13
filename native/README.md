# Native engine binaries (llama.cpp)

LLMMBC does not require an Ollama install: it runs two llama.cpp executables per device.

| Binary | Role |
|---|---|
| `llama-server` | OpenAI-compatible inference server, coordinator only |
| `rpc-server` | ggml RPC backend, one per worker (`ggml-rpc-server` upstream) |

The pinned upstream tag lives in [`LLAMA_CPP_VERSION`](LLAMA_CPP_VERSION) (`b12360` at the time of
writing; it builds with `-DGGML_RPC=ON` and still ships all desktop/server release archives).

## Fetch or build

```bash
scripts/fetch_engine.sh <target> [outdir]
scripts/build_engine.sh <target> [outdir]
```

Targets: `linux-x64`, `linux-arm64`, `windows-x64`, `macos-arm64`, `macos-x64`,
`android-arm64`, `android-x64`. Default outdir: `native/out/<target>/`.

`fetch_engine.sh` downloads the official prebuilt archive when it contains both
`llama-server` and an RPC server, renames upstream's `ggml-rpc-server` to `rpc-server`, and
falls back to `build_engine.sh` otherwise (`android-x64` has no official archive).

Output layout is flat so a single directory can be shipped next to the app or mounted into a
container:

```
desktop: llama-server[.exe]  rpc-server[.exe]  *.so* / *.dylib / *.dll
android: libllama_server.so  librpc_server.so  lib*.so
```

Android binaries are renamed to `lib*.so` (executables are still ELF PIE executables) so the
Flutter app can package them in `android/app/src/main/jniLibs/<abi>/`; `DefaultEngineLocator`
looks them up through `PlatformHooks.nativeLibraryDir`.

## Environment

| Variable | Used by | Meaning |
|---|---|---|
| `LLAMA_CPP_VERSION` | both | Override the pinned tag |
| `JOBS` | both | Build parallelism (default 4; keep low on shared CI hosts) |
| `ANDROID_NDK_HOME` | android builds | NDK root; auto-detected from `ANDROID_SDK_ROOT/ndk/<newest>`, `ANDROID_HOME/ndk/<newest>`, `/root/android-sdk/ndk/<newest>` |
| `ANDROID_SDK_ROOT` / `ANDROID_HOME` | android builds | Used to find the NDK when `ANDROID_NDK_HOME` is unset |
| `LLAMA_SRC_DIR` | builds | Reuse an existing llama.cpp checkout |
| `LLAMA_REPO` | builds | Git URL (default `https://github.com/ggml-org/llama.cpp.git`) |
| `CMAKE_EXTRA_ARGS` | builds | Extra CMake configure arguments (cross toolchain, Vulkan, ...) |
| `LLAMA_RELEASE_BASE` | fetch | Release download base (GitHub by default) |
| `LLMMBC_ENGINE_DIR` | runtime | First engine location checked by `DefaultEngineLocator` |

Android requirements: Node 27+ / NDK `27.2.12479018` is what CI and this repository use:

```bash
sdkmanager "ndk;27.2.12479018"
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/27.2.12479018"
scripts/fetch_engine.sh android-x64
```

The Android build uses the NDK CMake toolchain with `-DANDROID_ABI=arm64-v8a|x86_64`,
`-DANDROID_PLATFORM=android-28`, `-DGGML_OPENMP=OFF`, `-DGGML_RPC=ON`,
`-DLLAMA_CURL=OFF`, `-DBUILD_SHARED_LIBS=ON`. Vulkan is off by default; add
`-DGGML_VULKAN=ON` via `CMAKE_EXTRA_ARGS` if desired.

GitHub Actions notes: the fetch script needs `curl`, `tar`, and `unzip` (or `powershell.exe` on
Windows for `.zip` archives). Builds need `cmake`, `ninja`/`make`, a C/C++ toolchain, and `git`.
Desktop builds must run on a host matching the target unless a cross toolchain is passed via
`CMAKE_EXTRA_ARGS`.

**Linux baseline:** the official `ubuntu-x64` prebuilt requires **glibc >= 2.34** (Ubuntu 22.04+,
Debian 12+, RHEL 9+). Ubuntu 20.04 / Debian 11 / RHEL 8 need a source build
(`scripts/build_engine.sh linux-x64`) on that distro. The `ubuntu-arm64` prebuilt needs a
glibc >= 2.34 userland as well (Pi 4/5 on bookworm is fine; Pi 3 / ARMv7 has no target).

## Process supervision

On Linux/macOS/Android `LlamaCppEngine` launches each binary through a tiny shell supervisor (`/system/bin/sh` on Android, `/bin/sh` elsewhere)
that forwards TERM/INT and watches the Dart parent PID. A bare `exit(0)` (no `stop()`) therefore
terminates both `llama-server` and `rpc-server` within a couple of seconds. Signal subscriptions
(SIGINT/SIGTERM) are installed only while a child is running and cancelled on stop, so an idle
engine never pins the Dart VM's event loop. Windows has no portable parent-death signal; call
`dispose()`/`stopCoordinator()`/`stopRpcWorker()` before exiting (the stop path uses
`taskkill /T /F`).

## Runtime lookup

`DefaultEngineLocator` checks, in order:

1. `LLMMBC_ENGINE_DIR`
2. `NodeSettings.engineDir`
3. Android `nativeLibraryDir` (`libllama_server.so` / `librpc_server.so`)
4. desktop `<directory of running executable>/engine`
5. dev fallback `<repo>/native/out/<platform>-<arch>`

`native/out/` is gitignored: never commit binaries.

## llama.cpp b12360 details

* Upstream renamed `rpc-server` to `ggml-rpc-server`; both scripts normalize the name.
* `--override-tensor` buffer types are `CPU` and `RPC<device>[host:port]` (for example
  `RPC0[192.168.1.10:47102]`), **not** the older `RPC[host:port]` spelling. The planner emits the
  working `RPC0[...]` form; see the comment in `lib/src/engine/planner.dart`.
* `rpc-server` ports: the requested port is used when free, otherwise the next free port in
  `47102..47131` is chosen, skipping `47103` (reserved for the local `llama-server`); an
  OS-assigned port is the final fallback. `startRpcWorker` only returns after the child is
  alive and accepting TCP, so two nodes on one host never report the same RPC port.
* RPC devices are registered before local devices, but llama.cpp ignores the local entry in
  `--tensor-split` and only offloads via `-ngl`. `DefaultClusterPlanner.llamaServerArgsForModel`
  therefore sets `-ngl = rpcLayers + 1` (the offset is the output layer) and passes a tensor
  split over the RPC devices only; the coordinator keeps `blockCount - rpcLayers` layers and
  their KV locally. The integration test asserts the resulting KV placement.
* `--no-webui` and `-lv 4` are supported and used by `LlamaCppEngine`; the latter keeps loader /
  device-placement lines in `logTail` for diagnostics.

## Manual smoke test

```bash
scripts/fetch_engine.sh linux-x64
native/out/linux-x64/llama-server --version
native/out/linux-x64/rpc-server --help
```

Integration test (downloads qwen3:0.6b and granite3.1-moe:1b GGUFs from `registry.ollama.ai`
into `${TMPDIR}/llmmbc-engine-it`, override with `LLMMBC_IT_MODEL_DIR`):

```bash
cd packages/llmmbc_core
LLMMBC_ENGINE_IT=1 dart test test/engine
```
