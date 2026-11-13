/// LLMMBC core library. CONTRACT – export list owned by the orchestrator.
library;

export 'src/constants.dart';
export 'src/models.dart';
export 'src/interfaces.dart';

// core-data
export 'src/hardware/hardware_probe.dart';
export 'src/registry/gguf.dart';
export 'src/registry/model_store.dart';

// engine
export 'src/engine/engine_locator.dart';
export 'src/engine/planner.dart';
export 'src/engine/llama_cpp_engine.dart';

// core-net
export 'src/discovery/lan_discovery.dart';
export 'src/api/node_client.dart';
export 'src/api/node_api_server.dart';
export 'src/node/node_service.dart';
