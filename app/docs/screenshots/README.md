# Android emulator screenshots

Captured on the `Poco_X6_Pro` emulator (Android, x86_64, KVM) with the debug APK.

| File | Build | Screen |
|---|---|---|
| `01-startup.png` | `--dart-define=LLMMBC_FAKE=1 --dart-define=LLMMBC_FAKE_PHASE_MS=6000` | Startup: settings → hardware scan → model scan → network scan |
| `02-chat-empty.png` | `--dart-define=LLMMBC_FAKE=1` | Chat empty state with the cluster model picker |
| `03-chat-answer.png` | `--dart-define=LLMMBC_FAKE=1` | Chat: streamed Markdown answer, served-by node, coordinator/worker session |
| `04-models.png` | `--dart-define=LLMMBC_FAKE=1` | Models: MoE-first catalog, local GGUF store, pull by name |
| `05-cluster.png` | `--dart-define=LLMMBC_FAKE=1` | Cluster: this device's hardware profile and peers |
| `06-settings.png` | `--dart-define=LLMMBC_FAKE=1` | Settings: worker mode, memory share, peers, paths, engine log |
| `07-real-cluster.png` | plain `flutter build apk --debug` (no fake) | Cluster from the real `LocalNodeService`: real hardware profile, `emulator` tag, engine binaries absent |
| `08-real-settings.png` | plain `flutter build apk --debug` (no fake) | Settings: worker mode toggle off in the real node build |
| `09-settings-worker-service.png` | plain `flutter build apk --debug` | Settings: worker foreground service running after the POST_NOTIFICATIONS grant |
| `10-runtime-error.png` | `--dart-define=LLMMBC_SIMULATE_RUNTIME_FAILURE=1` | Runtime-failure banner with the real error, Details and Retry |
| `11-runtime-error-details.png` | `--dart-define=LLMMBC_SIMULATE_RUNTIME_FAILURE=1` | Error details dialog: phase, type, stack trace, engine log tail, Copy |
| `12-runtime-recovered.png` | `--dart-define=LLMMBC_SIMULATE_RUNTIME_FAILURE=1` | After Retry: real `LocalNodeService` running (node API back, banner gone) |

The slow-start build only paces `FakeNodeService`'s startup phases so the transient startup
screen can be captured; it uses the same app code (`LLMMBC_FAKE_PHASE_MS`).
