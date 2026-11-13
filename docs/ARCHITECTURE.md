# LLMMBC architecture (contract)

LLMMBC (LLM Mobile Cluster) turns every device running it (Android phone, Linux/Windows/macOS
PC, Raspberry Pi, headless server/container) into a node of a LAN cluster that runs open LLMs
pulled from the Ollama registry. MoE models are the primary target; dense models are supported.

This document is the **contract** shared by all work streams. Do not change it without the
orchestrator's approval.

## 1. Repository layout and ownership

| Path | What | Owner stream |
|---|---|---|
| `docs/**` | Contracts (this file) | orchestrator |
| `packages/llmmbc_core/lib/llmmbc_core.dart`, `lib/src/models.dart`, `lib/src/interfaces.dart`, `lib/src/constants.dart` | Shared types + interfaces | orchestrator (contract) |
| `packages/llmmbc_core/lib/src/hardware/**`, `lib/src/registry/**` (+ matching `test/hardware/**`, `test/registry/**`) | Hardware probe, Ollama registry downloader, model store, GGUF reader, model catalog | **core-data** |
| `packages/llmmbc_core/lib/src/discovery/**`, `lib/src/api/**`, `lib/src/node/**`, `bin/**` (+ matching tests) | LAN discovery, node HTTP API server/client, cluster/session manager, `NodeService` facade, headless CLI | **core-net** |
| `packages/llmmbc_core/lib/src/engine/**` (+ `test/engine/**`), `native/**`, `scripts/build_engine.sh`, `scripts/fetch_engine.sh` | llama.cpp engine: build/fetch binaries for every platform, process management, shard planner | **engine** |
| `app/**` | Flutter app (android, ios, linux, windows, macos) | **app** |
| `.github/**`, `docker/**` | CI build + release, Docker image of the headless node, docker E2E test | **delivery** |

`packages/llmmbc_core/pubspec.yaml`: any stream may **add** dependencies it needs (append-only);
merge conflicts there are resolved by the orchestrator.

## 2. Runtime model

* **Engine** = llama.cpp, pinned to the tag in `native/LLAMA_CPP_VERSION`. Two executables per platform:
  * `llama-server` – OpenAI-compatible inference server, run only on the **coordinator** of a session.
  * `rpc-server` – ggml RPC backend, run on every **worker** of a session (except the coordinator).
* Model files are GGUF blobs pulled straight from the Ollama registry (`registry.ollama.ai`), no Ollama install needed.
* Every node runs `NodeService` (in-process in the Flutter app, or via the headless CLI `llmmbc_node`).

### 2.1 Startup sequence (every node)
1. Load settings (`NodeSettings`); generate and persist a stable `nodeId` (UUID v4) on first run.
2. **Hardware scan** → `HardwareProfile` (RAM total/available, CPU model/cores/arch, GPUs + VRAM + backend).
3. **Local model scan** → `LocalModel` list from the model store.
4. Start the node HTTP API (TCP `47101`) and the discovery beacon/listener (UDP `47100`).
5. **Network scan**: listen for beacons, broadcast a probe, plus an HTTP sweep of the local /24
   subnet(s) on port 47101 (`GET /v1/node`) and any manually added peers. Results → `PeerDirectory`.

### 2.2 Worker eligibility (the core rule)
A node is a *candidate* for model `M` iff `settings.workerEnabled == true` **and** `M` is fully
downloaded on it. This applies to the requesting node too. A node that is not a candidate does
nothing for that model (it may still act as a pure client that sends the chat request).

### 2.3 Chat request flow
1. Requester R lists models available in the cluster = union of `NodeInfo.models` over reachable
   nodes with `workerEnabled` (incl. self), grouped by model ref, with the candidate list.
2. R picks the **coordinator** C = candidate with the largest `NodeInfo.effectiveBudgetBytes` (§2.5)
   (tie-break: lexicographically smallest `nodeId`). If C is busy with another model, R still sends
   to C (C answers 409 `busy` and R shows the error).
3. R sends `POST /v1/chat/completions` (OpenAI format, `stream: true` supported) to C's node API.
4. C ensures a **session** for M:
   * Candidate set S = all reachable candidates for M (C's own view, refreshed).
   * For each other s in S: `POST /v1/rpc/start` → s starts `rpc-server` and returns its port + memory budget.
     Nodes that fail/timeout are dropped from S.
   * `ClusterPlanner.plan(model, S)` → `ClusterPlan` (per-node weights; for MoE optional expert
     placement overrides).
   * C starts `llama-server` locally (127.0.0.1:47103) with `--rpc` = workers, `--tensor-split` and
     `--override-tensor` derived from the plan; waits until `/health` is ok.
5. C proxies the request to llama-server and streams the response back to R unchanged (SSE).
6. Session idle timeout: 10 min without requests → C stops llama-server and sends
   `POST /v1/rpc/stop` to every worker. A node participates in at most one session at a time.

### 2.4 MoE vs dense planning
* Dense: split layers proportional to each node's usable memory (`--tensor-split`).
* MoE (`GgufMetadata.expertCount > 0`): same proportional layer split, **plus** the planner may keep
  attention/shared tensors on the coordinator and spread `ffn_*_exps` tensors across workers via
  `--override-tensor <regex>=RPC[host:port]` so that each forward pass only touches the active experts'
  shards. The planner must always produce a plan whose per-node bytes ≤ that node's budget, or fail
  with `PlanError` ("model does not fit in cluster memory").

### 2.5 Memory budget
* Each node lends `budget = HardwareProfile.memoryBudgetBytes(settings.memoryBasis, settings.memoryShare)`:
  * `total` basis (**default**): (total RAM + dedicated VRAM) × share. Phones keep most RAM "used"
    by cached apps, so free-memory estimates badly understate what the OS can reclaim.
  * `available` basis (opt-in): `usableMemoryBytes` (free RAM minus a small reserve, + VRAM) × share.
  * Default share = 0.7. Settings files without `settingsVersion: 2` are migrated to total/0.7.
* The node advertises `budget` as `NodeInfo.memoryBudgetBytes` (recomputed when settings or the
  hardware refresh change), returns it as `budgetBytes` from `/v1/rpc/start`, and uses it as its own
  `PlanNode.budgetBytes` when coordinating. Coordinator choice and UI totals use `effectiveBudgetBytes`.
* CLI: `serve --memory-basis total|available --memory-share 0.7`; env `LLMMBC_MEMORY_BASIS`, `LLMMBC_MEMORY_SHARE`.

## 3. Wire protocol (node API, HTTP/1.1 JSON, TCP 47101)

All JSON bodies use the `toJson()` shapes in `lib/src/models.dart`. Errors: `{"error": {"code": "<code>", "message": "..."}}` with codes `bad_request`, `not_found`, `busy`, `not_candidate`, `no_candidates`, `does_not_fit`, `engine_error`, `internal`.

| Method & path | Body | Response |
|---|---|---|
| `GET /v1/node` | – | `NodeInfo` |
| `GET /v1/peers` | – | `{"peers": [NodeInfo...]}` (this node's directory **plus the node itself**, marked `isSelf: true`) |
| `GET /v1/models` | – | `{"models": [LocalModel...]}` |
| `POST /v1/rpc/start` | `{"sessionId": str, "model": str, "coordinatorId": str}` | `{"host": str, "port": int, "budgetBytes": int}` (409 `busy`, 403 `not_candidate`) |
| `POST /v1/rpc/stop` | `{"sessionId": str}` | `{"ok": true}` |
| `POST /v1/chat/completions` | OpenAI chat request (`model` = Ollama ref e.g. `qwen3:30b-a3b`) | OpenAI response / SSE stream |
| `GET /v1/session` | – | `SessionInfo` or `{"session": null}` |

Headers: every response carries `X-LLMMBC-Protocol: 1` and `X-LLMMBC-Node: <nodeId>`.

**Chat routing on the API.** `POST /v1/chat/completions` may be sent to *any* node (e.g. a
client-only node, or the CLI `chat --node`). Without the request header `X-LLMMBC-Route: coordinator`
the receiving node acts as requester R and routes per §2.3 (`NodeService.chat`): if it is itself the
chosen coordinator it serves locally, otherwise it forwards to C adding `X-LLMMBC-Route: coordinator`.
A request carrying that header is served locally as coordinator or rejected (`not_candidate` /
`busy`), never forwarded again (no routing loops).

**Reasoning output.** Reasoning models emit `reasoning_content` deltas. The node passes them through
unchanged on the wire; `HttpNodeClient`/`NodeService.chat` surface them inside `ChatDelta.content`
wrapped in `<think>` … `</think>` so clients that only read `content` still get a non-empty answer.
Chat calls use a long first-byte timeout (≥ 10 min; model load on the coordinator), not the 5 s API
timeout.

## 4. Discovery protocol (UDP 47100)

* Beacon: every 3 s, each node sends a UTF-8 JSON datagram
  `{"t":"llmmbc.beacon","v":1,"id":<nodeId>,"name":<str>,"port":47101}` to the broadcast address(es)
  of every IPv4 interface **and** to multicast group `239.255.47.100`.
* Probe: on start / manual refresh a node sends `{"t":"llmmbc.probe","v":1,"id":<nodeId>}`; receivers
  reply unicast with a beacon.
* On beacon from an unknown id: fetch `GET http://<sender-ip>:<port>/v1/node` and add to `PeerDirectory`.
* Peers not seen for 15 s are marked `reachable=false`; dropped after 120 s (manual peers are never dropped).
* Subnet sweep fallback (Docker, emulator, networks that block broadcast): `GET /v1/node` on every
  host of each local /24, 300 ms timeout, ≤ 64 concurrent, on start and on manual refresh.
* Manual peers: `host[:port]` strings in `NodeSettings.manualPeers` (needed for the Android emulator,
  which reaches the host as `10.0.2.2`).

## 5. Model store

* Model ref syntax: `[namespace/]name[:tag]`, defaults `library` and `latest` (Ollama semantics).
* Registry: `GET https://registry.ollama.ai/v2/<ns>/<name>/manifests/<tag>` with
  `Accept: application/vnd.docker.distribution.manifest.v2+json`; GGUF layer mediaType
  `application/vnd.ollama.image.model`; blobs at `/v2/<ns>/<name>/blobs/<digest>`. Also keep
  `application/vnd.ollama.image.template`, `.params`, `.license`, `.system`.
* On-disk layout under `<dataDir>/models/`:
  `manifests/<ns>/<name>/<tag>.json` (raw manifest) and `blobs/sha256-<hex>` (content-addressed).
  Partial downloads: `blobs/sha256-<hex>.partial`, resumed with HTTP `Range`. sha256 verified before rename.
* **Never block the calling isolate.** The digest is computed incrementally while bytes stream in
  (no full re-read at the end). Hashing an existing `.partial` on resume, or any other full-file
  hash, runs in a background isolate (`Isolate.run`) and reports `verifying` progress.
* Progress (`DownloadProgress`): `receivedBytes/totalBytes` over all layers, `bytesPerSecond`
  (smoothed over ~5 s), `eta`; at most ~10 events/s, always ≥ 1 `downloading` event and a final
  `done`/`failed`/`cancelled`.
* A model counts as downloaded only when the manifest file exists and every layer blob is complete.

## 6. Engine binaries

* Located by `EngineLocator` in this order: env `LLMMBC_ENGINE_DIR`; `NodeSettings.engineDir`;
  Android: the app's `nativeLibraryDir` (binaries packaged as `libllama_server.so` / `librpc_server.so`);
  desktop: `<dir of running executable>/engine/`; dev fallback `<repo>/native/out/<platform>-<arch>/`.
* Desktop/Linux names: `llama-server`, `rpc-server` (`.exe` on Windows), shared libs next to them.
* `scripts/fetch_engine.sh <target> <outdir>` downloads/builds binaries for a target in
  {`linux-x64`, `linux-arm64`, `windows-x64`, `macos-arm64`, `macos-x64`, `android-arm64`, `android-x64`}.
* iOS cannot spawn processes: on iOS the app is **client-only** (worker mode forced off, UI says why).

## 7. Ports and constants

See `lib/src/constants.dart`: discovery UDP 47100, node API TCP 47101, rpc-server TCP 47102,
local llama-server 127.0.0.1:47103.

## 8. Headless node CLI (`packages/llmmbc_core/bin/llmmbc_node.dart`)

```
llmmbc_node serve   [--data-dir DIR] [--name NAME] [--no-worker] [--peer host:port]... [--port 47101]
llmmbc_node pull    <model-ref> [--data-dir DIR]
llmmbc_node list    [--data-dir DIR]
llmmbc_node rm      <model-ref> [--data-dir DIR]
llmmbc_node hw                                   # print HardwareProfile JSON
llmmbc_node peers   [--node http://host:47101]   # print discovered peers
llmmbc_node chat    <model-ref> <prompt> [--node http://host:47101]   # route via cluster, stream to stdout
```
Env overrides: `LLMMBC_DATA_DIR`, `LLMMBC_ENGINE_DIR`, `LLMMBC_NAME`, `LLMMBC_WORKER` (`0`/`1`), `LLMMBC_PEERS` (comma list).

## 9. Dev environment and verification

* Host tools: Flutter/Dart at `/opt/flutter/bin` (`export PATH=/opt/flutter/bin:$PATH`; the "running as
  root" warning is harmless), Android SDK at `/root/android-sdk` (KVM available), Docker.
* Core package checks (run from `packages/llmmbc_core`): `dart pub get && dart analyze && dart test`.
* Every concrete class exported by `lib/llmmbc_core.dart` already exists as a **stub** in its owner
  directory. Owners replace stub bodies; class names, constructors and the export list are contract.
* Lightweight test model for E2E: `qwen3:0.6b` (dense, ~520 MB). Small MoE for planner/E2E checks:
  `granite3.1-moe:1b` (~1.4 GB).
