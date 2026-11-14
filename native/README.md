# Native engine binaries (llama.cpp)

LLMMBC does not require an Ollama install: it runs two llama.cpp executables per device.

| Binary | Role |
|---|---|
| `llama-server` | OpenAI-compatible inference server, coordinator only |
| `rpc-server` | ggml RPC backend, one per worker (`ggml-rpc-server` upstream) |

The pinned upstream tag lives in [`LLAMA_CPP_VERSION`](LLAMA_CPP_VERSION) (`b12360` at the time of
writing). Every target is built **from source** with the patches in [`patches/`](patches) applied:
upstream release archives lack the load-weights-from-file support in §6.1 of the architecture
contract.

## Fetch or build

```bash
scripts/fetch_engine.sh <target> [outdir]
scripts/build_engine.sh <target> [outdir]
```

Targets: `linux-x64`, `linux-arm64`, `windows-x64`, `macos-arm64`, `macos-x64`,
`android-arm64`, `android-x64`. Default outdir: `native/out/<target>/`.

`fetch_engine.sh` always calls `build_engine.sh`; it never downloads upstream binaries.
`build_engine.sh` clones the pinned tag into `native/src/llama.cpp` (or reuses `LLAMA_SRC_DIR`),
switches an existing checkout back to the pinned tag, then applies `native/patches/*.patch` in
order. Re-running a build is idempotent: already-applied patches are detected and skipped.

Output layout is flat so a single directory can be shipped next to the app or mounted into a
container:

```
desktop: llama-server[.exe]  rpc-server[.exe]  *.so* / *.dylib / *.dll
android: libllama_server.so  librpc_server.so  lib*.so
```

Android binaries are renamed to `lib*.so` (executables are still ELF PIE executables) so the
Flutter app can package them in `android/app/src/main/jniLibs/<abi>/`; `DefaultEngineLocator`
looks them up through `PlatformHooks.nativeLibraryDir`.

## Patch: load weights from the worker's own disk (`patches/0001-rpc-load-weights-from-file.patch`)

Implements [`docs/ARCHITECTURE.md` §6.1](../docs/ARCHITECTURE.md). Four files, ~440 lines:

* `ggml/include/ggml-rpc.h` — protocol `10.0.0 → 10.0.1` (patch version only: the new command is
  flag-gated, so old coordinators can still use a new rpc-server and vice versa); new
  `ggml_backend_rpc_set_tensor_from_file(tensor, offset, file_offset, size)` (also exported through
  the backend registry proc-address table) and `model_file`/`lazy_weights` parameters for
  `ggml_backend_rpc_start_server`.
* `ggml/src/ggml-rpc/ggml-rpc.cpp` — new `SET_TENSOR_FROM_FILE` command (appended, so existing
  command numbers are unchanged) advertised through a new HELLO flag. The server:
  * opens `--model-file` once and bounds-checks every `{offset, file_offset, size}` request against
    both the tensor and the file;
  * reads regions with `pread` in 16 MiB chunks (no full-tensor heap copy), and on Windows falls
    back to seek+read;
  * with `--lazy-weights` on POSIX, maps the GGUF once (`MAP_PRIVATE`, file opened `O_RDONLY`, so
    writes are copy-on-write and never reach the file) and points each loaded CPU-buffer weight
    tensor at the mapping. A per-server remap table translates the client-visible buffer address
    range to the mapped pointer inside `deserialize_tensor`, which covers graph compute,
    `get_tensor`, `set_tensor`, `memset_tensor` and `copy_tensor`. Deserialization never remaps a
    tensor twice, so writes into a mapped region are COW and never reach the GGUF;
  * allocates CPU buffers with `mmap(MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE)` so a buffer larger
    than RAM is accepted and untouched ranges cost no RSS. The RPC protocol does not carry buffer
    usage, so this applies to every CPU buffer the server hands out; compute buffers are small and
    fully touched. GPU buffers and Windows keep the copying path.
* `tools/rpc/rpc-server.cpp` — `-m/--model-file FILE` and `--lazy-weights` (requires
  `--model-file`; POSIX only), validated before the server starts.
* `src/llama-model-loader.cpp` — for weight tensors in an RPC buffer whose server advertises the
  flag, calls the new API with the tensor's GGUF data offset (`weight->offs`) instead of
  `ggml_backend_tensor_set` with the bytes. The check runs before the coordinator's mmap pointer
  is computed, so remote weight pages are never touched on the coordinator. Unpatched servers,
  servers without `--model-file`, GPU buffers and split GGUFs keep the old byte path.

Server log lines used by the integration test (one every 16 MiB, plus exact totals on disconnect).
`from_file_bytes` counts bytes served from the file (mapped or pread); `socket_bytes` is what
actually crossed the network and is the number that must stay far below the model size:

```
[rpc_server] SET_TENSOR_FROM_FILE: blk.0.ffn_gate_exps.weight, totals: from_file_bytes=... from_file_tensors=... socket_bytes=...
[rpc_server] totals: from_file_bytes=... from_file_tensors=... socket_bytes=...
```

The Dart side passes the flags from `LlamaCppEngine.startRpcWorker(modelPath:, lazyWeights:)`; the
legacy hash cache (`-c`) is only enabled when `cacheDir` is given.

## Environment

| Variable | Used by | Meaning |
|---|---|---|
| `LLAMA_CPP_VERSION` | both | Override the pinned tag |
| `JOBS` | both | Build parallelism (default 4; keep low on shared CI hosts) |
| `ANDROID_NDK_HOME` | android builds | NDK root; auto-detected from `ANDROID_SDK_ROOT/ndk/<newest>`, `ANDROID_HOME/ndk/<newest>`, `/root/android-sdk/ndk/<newest>` |
| `ANDROID_SDK_ROOT` / `ANDROID_HOME` | android builds | Used to find the NDK when `ANDROID_NDK_HOME` is unset |
| `LLAMA_SRC_DIR` | builds | Reuse an existing llama.cpp checkout (must be a git checkout at the pinned tag) |
| `LLAMA_REPO` | builds | Git URL (default `https://github.com/ggml-org/llama.cpp.git`) |
| `CMAKE_EXTRA_ARGS` | builds | Extra CMake configure arguments (cross toolchain, Vulkan, ...) |
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
* The patch adds `rpc-server --model-file` and `--lazy-weights`. On Windows the flags are accepted
  but `--lazy-weights` degrades to reading from the file (no `MAP_NORESERVE`/mmap path).
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
native/out/linux-x64/rpc-server --help   # includes --model-file / --lazy-weights
```

Integration test (downloads qwen3:0.6b and granite3.1-moe:1b GGUFs from `registry.ollama.ai`
into `${TMPDIR}/llmmbc-engine-it`, override with `LLMMBC_IT_MODEL_DIR`):

```bash
cd packages/llmmbc_core
LLMMBC_ENGINE_IT=1 dart test test/engine
```
