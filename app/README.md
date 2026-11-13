# LLMMBC app

Flutter client for LLMMBC (LLM Mobile Cluster). One app runs on Android, iOS, Linux,
Windows and macOS; every device can be a pure client or a worker that lends memory to
the cluster.

```
app/
├── lib/
│   ├── app/            # root widget, theme, session state, startup gate
│   ├── dev/            # FakeNodeService (simulated peers/models/chat)
│   ├── models/         # conversation model
│   ├── services/       # bootstrap, platform channel, degraded node service, stores
│   ├── ui/             # shell + Chat / Models / Cluster / Settings screens
│   └── util/           # formatting + error copy
├── android/            # MethodChannel, foreground service, jniLibs packaging
├── ios/ linux/ macos/ windows/
├── test/               # widget tests for every screen + unit tests
└── docs/screenshots/   # emulator screenshots referenced by the PR
```

## Run

```bash
export PATH=/opt/flutter/bin:$PATH

# Real node: LocalNodeService.create(...) from llmmbc_core
flutter run

# Simulated cluster: no cores, no LAN, no downloads
flutter run --dart-define=LLMMBC_FAKE=1

# Slow the simulated startup phases down (useful for demo screenshots)
flutter run --dart-define=LLMMBC_FAKE=1 --dart-define=LLMMBC_FAKE_PHASE_MS=5000

# QA the runtime-failure banner + Retry: the first runtime construction fails
flutter run --dart-define=LLMMBC_SIMULATE_RUNTIME_FAILURE=1
```

The default build wires:

```dart
LocalNodeService.create(
  settingsPath: '<appSupportDir>/settings.json',
  defaultDataDir: '<appSupportDir>',
  platform: PlatformBridge.hooks(), // nativeLibraryDir, multicastLock, gpuRenderer
)
```

First-run naming: core seeds `NodeSettings.name` from `Platform.localHostname` (which is
`localhost` on Android). The app seeds/renames generic names to the Android `Build.MODEL`
(read over the `dev.llmmbc/platform` channel) or the desktop hostname, so peers are
distinguishable in the Cluster list, `servedBy` and `GET /v1/node`.

If `LocalNodeService` cannot be constructed or started, the app falls back to
`DegradedNodeService` and shows a `RuntimeFailureBanner` with the real error message, an
expandable details dialog (phase, type, stack trace, engine log tail, copy button) and a
working **Retry** that rebuilds the real runtime. The fallback uses core's
`LocalHardwareProbe(hooks:)` and `FileModelStore` catalog — the app only supplies
`PlatformHooks`, so degraded numbers match `GET /v1/node`. It has no engine and no
downloads. Peers reported by `GET /v1/peers` include this node itself; the UI filters it
out and shows it as "This device". `AppSession.refreshModels()` calls
`LocalNodeService.refreshModels()` so the Models screen reflects pulls/deletes immediately.
`--dart-define=LLMMBC_FAKE=1` always wins and uses `FakeNodeService`.

## Screens

| Screen | Contents |
|---|---|
| Startup | settings → hardware scan → model scan → node API → network scan progress, retry on failure |
| Chat | `clusterModels()` picker with MoE/dense + candidate + cluster-memory badges, streamed Markdown answers, stop button, served-by + coordinator/worker session strip, JSON-persisted conversation list, error UX for `no_candidates` / `busy` / `does_not_fit` |
| Models | MoE-first catalog, download progress/cancel/resume, pull by name, local GGUF metadata, delete |
| Cluster | this device's `HardwareProfile` (RAM, CPU, GPUs, tags incl. `emulator`), peers with status/worker mode/models/usable memory, `discovery.scan()` refresh, add peer by `host:port` |
| Settings | worker mode (default ON, forced OFF on iOS), node name, memory-share slider, manual peers, data dir, engine availability + log tail, theme |

Phones get a bottom navigation bar; widths ≥ 840 px get a navigation rail.

## Android specifics

* `MainActivity` implements the `dev.llmmbc/platform` MethodChannel:
  `nativeLibraryDir`, `multicastLock(bool)` (`WifiManager.MulticastLock`), `gpuRenderer`
  (EGL pbuffer), plus `deviceTags` (`emulator`) and `startForeground`/`stopForeground`.
* `WorkerService` is a `dataSync` foreground service that keeps the node API and discovery
  reachable while worker mode is enabled — independent of engine availability. It starts on
  app startup and on every worker-mode change; `POST_NOTIFICATIONS` is requested on Android
  13+ (`requestNotificationPermission`) and Settings reports whether the service and its
  notification are actually running.
* `minSdk 28`, `android:extractNativeLibs="true"`,
  `packaging.jniLibs.useLegacyPackaging = true` and cleartext HTTP for the LAN node API.
* The APK builds without engine binaries; `jniLibs/<abi>/libllama_server.so` is added by
  CI (`scripts/fetch_engine.sh android-*`). Without it `engineAvailable` is false and the
  node is never a candidate.

`iOS` is client-only (no process spawning), enforced by `PlatformHooks(clientOnly: true)`.
Desktop looks for the engine in `<executable dir>/engine/` (docs/ARCHITECTURE.md §6).

## Verify

```bash
flutter analyze
flutter test
flutter build apk --debug
flutter build linux
```
