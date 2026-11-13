/// First-run node naming. Core seeds settings from `Platform.localHostname`,
/// which is `localhost` on Android, so the app renames such nodes to something
/// a peer can recognise (the Android device model).
library;

/// Names that are not useful in a LAN peer list.
const Set<String> _genericNames = {'localhost', 'unknown', 'unset', 'llmmbc-node'};

bool isGenericNodeName(String? name) {
  final value = (name ?? '').trim().toLowerCase();
  return value.isEmpty || _genericNames.contains(value);
}

/// Picks the best display name available to the app:
/// device model → hostname → `LLMMBC node`.
String resolveNodeName({String? deviceName, String? hostname}) {
  final device = (deviceName ?? '').trim();
  if (!isGenericNodeName(device)) return device;
  final host = (hostname ?? '').trim();
  if (!isGenericNodeName(host)) return host;
  return 'LLMMBC node';
}
