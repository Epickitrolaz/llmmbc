# Release pipeline

`.github/workflows/release.yml` runs on every push to `main`, on pushed `v*`
tags, and on manual dispatch.

## Artifacts

| Artifact | Platform | Notes |
|---|---|---|
| `llmmbc-node-linux-x64.tar.gz` | Linux x64 | `llmmbc_node` + `engine/` |
| `llmmbc-node-linux-arm64.tar.gz` | Linux arm64 | `llmmbc_node` + `engine/` |
| `llmmbc-node-windows-x64.zip` | Windows x64 | `llmmbc_node.exe` + `engine/` |
| `llmmbc-node-macos-arm64.tar.gz` | macOS arm64 | optional, see below |
| `llmmbc-android.apk` | Android | release APK, engine in `jniLibs/{arm64-v8a,x86_64}` |
| `llmmbc-app-linux-x64.tar.gz` | Linux desktop app | engine in `engine/` |
| `llmmbc-app-windows-x64.zip` | Windows desktop app | engine in `engine/` |
| `llmmbc-app-macos-arm64.zip` | macOS desktop app | optional, engine in `Contents/MacOS/engine/` |
| `llmmbc-ios-unsigned.zip` | iOS | optional, unsigned `.app` |

The `docker` job also pushes `ghcr.io/<owner>/llmmbc-node:<version>` (plus
`:latest` on `main`) when the CLI smoke test passes.

## macOS / iOS are opt-in

GitHub does not provide macOS runners for every account (in particular, private
repositories without macOS minutes). To keep Linux/Windows/Android releases
working, the macOS engine, macOS CLI bundle, macOS app and unsigned iOS build
are **disabled by default**. Enable them with a repository variable:

```bash
gh variable set LLMMBC_ENABLE_MACOS --body true
```

Unset it (or set it to anything other than `true`) to disable them again.
When disabled, those jobs are not scheduled at all, so an unavailable macOS
runner cannot cancel the workflow run.

## Failure handling

- Each downstream job (`cli`, app bundles) uses `always() && !cancelled()` and
  then downloads its own engine artifact with `continue-on-error`. A missing or
  failed engine target skips only that target with a notice; other targets and
  the release continue.
- The `Publish GitHub Release` job runs whenever at least one `llmmbc-*`
  artifact exists. Its notes list the included platforms, the skipped
  platforms, and the published assets.
- If nothing was produced, the publish step is skipped with a notice instead of
  failing the run.

## Secrets

None required. The workflow uses `GITHUB_TOKEN` with `contents: write` for the
release and `packages: write` for GHCR.
