/// Shared constants. CONTRACT – see docs/ARCHITECTURE.md §7.
library;

const int kProtocolVersion = 1;
const int kDiscoveryPort = 47100;
const int kNodeApiPort = 47101;
const int kRpcServerPort = 47102;
const int kLlamaServerPort = 47103;
const String kMulticastGroup = '239.255.47.100';
const String kOllamaRegistry = 'https://registry.ollama.ai';

const Duration kBeaconInterval = Duration(seconds: 3);
const Duration kPeerStaleAfter = Duration(seconds: 15);
const Duration kPeerDropAfter = Duration(seconds: 120);
const Duration kSessionIdleTimeout = Duration(minutes: 10);

const String kHeaderProtocol = 'X-LLMMBC-Protocol';
const String kHeaderNode = 'X-LLMMBC-Node';

const String kMediaTypeModel = 'application/vnd.ollama.image.model';
const String kMediaTypeTemplate = 'application/vnd.ollama.image.template';
const String kMediaTypeParams = 'application/vnd.ollama.image.params';
const String kMediaTypeSystem = 'application/vnd.ollama.image.system';
const String kMediaTypeLicense = 'application/vnd.ollama.image.license';
