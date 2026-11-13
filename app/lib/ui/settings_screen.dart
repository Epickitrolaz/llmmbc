/// Worker mode, node identity, memory share, manual peers, paths and engine
/// diagnostics.
library;

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:flutter/material.dart';

import '../app/app_session.dart';
import '../util/format.dart';
import 'widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSession _session;
  final TextEditingController _name = TextEditingController();
  final TextEditingController _peerField = TextEditingController();
  bool _hydrated = false;
  double _share = 0.8;
  List<String> _logLines = const [];
  String? _peerError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = AppScope.of(context);
    if (!_hydrated) {
      _hydrated = true;
      final settings = _session.service.settings;
      _name.text = settings.name;
      _share = settings.memoryShare;
      _logLines = _session.service.engine.logTail;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _peerField.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final value = _name.text.trim();
    if (value.isEmpty) {
      _name.text = _session.service.settings.name;
      return;
    }
    await _session.setNodeName(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Node renamed to $value')));
  }

  Future<void> _addPeer() async {
    final raw = _peerField.text.trim();
    if (raw.isEmpty) {
      setState(() => _peerError = 'Enter host:port');
      return;
    }
    final node = await _session.addManualPeer(raw);
    if (!mounted) return;
    if (node == null) {
      setState(() => _peerError = 'No node answered on $raw');
    } else {
      _peerField.clear();
      setState(() => _peerError = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = _session.service.settings;
    final hardware = _session.hardware;
    final self = _session.service.self;
    final clientOnly = _session.clientOnly;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PanelCard(
                  title: 'Node',
                  subtitle: 'Identity and worker role',
                  icon: Icons.tune,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('settings-name'),
                              controller: _name,
                              decoration: const InputDecoration(labelText: 'Node name'),
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _saveName(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: FilledButton.tonal(
                              key: const Key('settings-name-save'),
                              onPressed: _saveName,
                              child: const Text('Save'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Node id ${settings.nodeId}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
                        ),
                        child: SwitchListTile.adaptive(
                          key: const Key('worker-toggle'),
                          value: settings.workerEnabled && !clientOnly,
                          onChanged: clientOnly
                              ? null
                              : (value) async {
                                  await _session.setWorkerEnabled(value);
                                  if (mounted) setState(() {});
                                },
                          title: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('Worker mode', style: theme.textTheme.titleSmall),
                              StatusPill(
                                label: settings.workerEnabled && !clientOnly ? 'ON' : 'OFF',
                                color: settings.workerEnabled && !clientOnly ? scheme.primary : scheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                          subtitle: Text(
                            clientOnly
                                ? 'iOS cannot spawn llama.cpp processes: this device is client-only.'
                                : settings.workerEnabled
                                    ? 'This device lends up to ${formatBytes(_session.usableShareBytes)} '
                                        '(${formatPercent(settings.memoryShare)} of usable memory) to sessions. '
                                        'It never runs a model it does not have downloaded.'
                                    : 'Client-only: this device can start chats but never hosts a model. '
                                        'Its models disappear from the cluster model picker.',
                          ),
                          isThreeLine: true,
                          secondary: Icon(
                            settings.workerEnabled && !clientOnly ? Icons.memory : Icons.phone_iphone,
                            color: settings.workerEnabled && !clientOnly ? scheme.primary : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (_session.android) ...[
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              settings.workerEnabled && !clientOnly
                                  ? Icons.notifications_active_outlined
                                  : Icons.notifications_off_outlined,
                              size: 16,
                              color: settings.workerEnabled && !clientOnly
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _workerServiceCopy(_session, settings.workerEnabled && !clientOnly),
                                key: const Key('worker-service-copy'),
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PanelCard(
                  title: 'Resources',
                  subtitle: 'How much memory this node offers',
                  icon: Icons.memory,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('Memory share', style: theme.textTheme.titleSmall)),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '${formatPercent(_share)} · ${formatBytes((hardware.usableMemoryBytes * _share).round())}',
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        key: const Key('memory-slider'),
                        value: _share,
                        min: 0.1,
                        max: 1.0,
                        divisions: 18,
                        label: formatPercent(_share),
                        onChanged: (value) => setState(() => _share = value),
                        onChangeEnd: (value) async {
                          await _session.setMemoryShare(value);
                          setState(() => _share = _session.service.settings.memoryShare);
                        },
                      ),
                      Text(
                        'Usable memory here is ${formatBytes(hardware.usableMemoryBytes)}: available RAM '
                        '(${formatBytes(hardware.availableRamBytes)}) minus the safety reserve, plus VRAM. '
                        'The cluster planner never assigns more than this budget.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PanelCard(
                  title: 'Network',
                  subtitle: 'Discovery and manual peers',
                  icon: Icons.lan_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatGrid(
                        children: [
                          InfoStat(label: 'Node API', value: 'TCP ${settings.apiPort}'),
                          InfoStat(label: 'Discovery', value: 'UDP $kDiscoveryPort'),
                          InfoStat(label: 'Peer name', value: settings.name),
                          InfoStat(label: 'Reachable peers', value: '${_session.peers.where((p) => p.reachable).length}'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text('Manual peers', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        'Needed for the Android emulator (host = 10.0.2.2) and networks that block broadcast.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 10),
                      if (settings.manualPeers.isEmpty)
                        Text('None added.', style: theme.textTheme.bodySmall)
                      else
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final peer in settings.manualPeers)
                              InputChip(
                                key: Key('manual-peer-$peer'),
                                avatar: const Icon(Icons.lan, size: 14),
                                label: Text(peer, style: const TextStyle(fontSize: 11.5)),
                                onDeleted: () => _session.removeManualPeer(peer),
                              ),
                          ],
                        ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('settings-peer-field'),
                              controller: _peerField,
                              autocorrect: false,
                              decoration: InputDecoration(
                                hintText: '192.168.1.20:47101',
                                errorText: _peerError,
                              ),
                              onSubmitted: (_) => _addPeer(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.tonal(
                            key: const Key('settings-peer-add'),
                            onPressed: _addPeer,
                            child: const Text('Add'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PanelCard(
                  title: 'Storage',
                  subtitle: 'Where settings and models live',
                  icon: Icons.folder_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PathRow(label: 'Data directory', value: settings.dataDir),
                      const SizedBox(height: 10),
                      _PathRow(label: 'Models', value: '${settings.dataDir}/models/blobs'),
                      const SizedBox(height: 10),
                      _PathRow(label: 'Settings file', value: '${settings.dataDir}/settings.json'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PanelCard(
                  title: 'Engine',
                  subtitle: 'llama.cpp availability and log tail',
                  icon: Icons.developer_board,
                  trailing: IconButton(
                    key: const Key('engine-log-refresh'),
                    tooltip: 'Refresh log',
                    onPressed: () => setState(() => _logLines = _session.service.engine.logTail),
                    icon: const Icon(Icons.refresh),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatGrid(
                        children: [
                          InfoStat(
                            label: 'Binaries',
                            value: self.engineAvailable ? 'available' : 'not installed',
                            caption: self.engineAvailable ? 'llama-server + rpc-server' : 'app runs without them',
                          ),
                          InfoStat(
                            label: 'Worker',
                            value: _session.service.engine.rpcWorkerRunning ? 'rpc-server running' : 'idle',
                          ),
                          InfoStat(
                            label: 'Coordinator',
                            value: _session.service.engine.coordinatorRunning ? 'llama-server running' : 'idle',
                          ),
                        ],
                      ),
                      if (!self.engineAvailable) ...[
                        const SizedBox(height: 12),
                        Text(
                          'This build has no engine binaries for this platform. The node is never a candidate; '
                          'desktop looks in <executable dir>/engine/, Android in nativeLibraryDir.',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 12),
                      CodeBlock(lines: _logLines, emptyLabel: 'No engine output yet.'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PanelCard(
                  title: 'Appearance',
                  subtitle: 'Material 3 light and dark themes',
                  icon: Icons.contrast,
                  child: SegmentedButton<ThemeMode>(
                    key: const Key('theme-mode'),
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                      ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                    ],
                    selected: {_session.themeMode},
                    onSelectionChanged: (selection) => _session.setThemeMode(selection.first),
                  ),
                ),
                const SizedBox(height: 16),
                PanelCard(
                  title: 'About',
                  subtitle: 'LLMMBC',
                  icon: Icons.info_outline,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          const MetaChip(label: 'version 0.1.0', icon: Icons.sell_outlined),
                          MetaChip(label: 'protocol v$kProtocolVersion', icon: Icons.verified_outlined),
                          MetaChip(label: _session.buildModeLabel, icon: Icons.science_outlined),
                          MetaChip(label: '${settings.apiPort}/tcp · $kDiscoveryPort/udp', icon: Icons.lan_outlined),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Devices on the LAN pair automatically through UDP discovery: no account, no cloud. '
                        'Every node can be a client; worker mode decides whether it also lends memory.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _workerServiceCopy(AppSession session, bool workerEnabled) {
  if (!workerEnabled) {
    return 'Worker mode is off: no foreground service runs and this node is not discovered.';
  }
  if (!session.workerServiceActive) {
    return 'The worker foreground service is not running. Check app notifications and try toggling worker mode.';
  }
  if (!session.notificationsAllowed) {
    return 'Worker foreground service is running. Notifications are disabled '
        '(Android 13+ permission), so the persistent notification may be hidden.';
  }
  return 'Worker foreground service is running — the persistent notification keeps the node '
      'discoverable and serving while the app is in the background.';
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 0.8,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11.5),
        ),
      ],
    );
  }
}
