/// This device's hardware profile, the peer directory, manual refresh and
/// adding peers by `host:port`.
library;

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:flutter/material.dart';

import '../app/app_session.dart';
import '../util/format.dart';
import 'widgets/add_peer_dialog.dart';
import 'widgets/common.dart';

class ClusterScreen extends StatefulWidget {
  const ClusterScreen({super.key});

  @override
  State<ClusterScreen> createState() => _ClusterScreenState();
}

class _ClusterScreenState extends State<ClusterScreen> {
  late AppSession _session;
  bool _hydrated = false;
  bool _scanning = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = AppScope.of(context);
    if (!_hydrated) {
      _hydrated = true;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      await _session.refreshPeers();
    } catch (_) {
      // A failed sweep leaves the previous directory in place.
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _addPeer() async {
    final added = await showAddPeerDialog(
      context,
      onAdd: (hostPort) => _session.addManualPeer(hostPort),
    );
    if (added != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${added.name} (${added.host})')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hardware = _session.hardware;
    final settings = _session.service.settings;
    final self = _session.service.self;
    final peers = _session.peers;
    final reachable = peers.where((peer) => peer.reachable).length;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PanelCard(
                    title: 'This device',
                    subtitle: '${settings.name} · ${settings.nodeId}',
                    icon: Icons.smartphone,
                    trailing: StatusPill(
                      label: !self.engineAvailable
                          ? 'no engine'
                          : settings.workerEnabled
                              ? 'worker'
                              : 'client only',
                      color: !self.engineAvailable
                          ? scheme.error
                          : settings.workerEnabled
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!self.engineAvailable) ...[
                          NoticeBanner(
                            message: 'No llama.cpp engine binaries were found on this device, so it can '
                                'never be a candidate for a model. It still works as a client. '
                                'On Android the binaries are packaged as jniLibs/libllama_server.so.',
                            tone: scheme.error,
                            icon: Icons.warning_amber_outlined,
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (_session.clientOnly) ...[
                          const NoticeBanner(
                            message: 'iOS cannot spawn llama.cpp processes: this device is a client-only node '
                                'with worker mode forced off.',
                            icon: Icons.phone_iphone,
                          ),
                          const SizedBox(height: 14),
                        ],
                        StatGrid(
                          children: [
                            InfoStat(
                              label: 'Total RAM',
                              value: formatBytes(hardware.totalRamBytes),
                              caption: '${hardware.cpuCores} CPU cores',
                            ),
                            InfoStat(
                              label: 'Available RAM',
                              value: formatBytes(hardware.availableRamBytes),
                              caption: 'right now',
                            ),
                            InfoStat(
                              label: 'Session budget',
                              value: formatBytes(_session.memoryBudgetBytes),
                              caption: '${settings.memoryBasis == MemoryBasis.total ? 'total' : 'free'} RAM '
                                  '× ${formatPercent(settings.memoryShare)}',
                            ),
                            InfoStat(
                              label: 'Memory lent',
                              value: formatPercent(settings.memoryShare),
                              caption: 'of ${formatBytes(_session.memoryBasisBytes)} '
                                  '(${settings.memoryBasis == MemoryBasis.total ? 'Total RAM' : 'Free RAM estimate'})',
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                        const SizedBox(height: 14),
                        StatGrid(
                          children: [
                            InfoStat(label: 'CPU', value: hardware.cpuModel),
                            InfoStat(label: 'Platform', value: '${hardware.os} · ${hardware.arch}'),
                            InfoStat(
                              label: 'GPU',
                              value: hardware.gpus.isEmpty
                                  ? 'None detected'
                                  : hardware.gpus.map((gpu) => gpu.name).join(', '),
                              caption: hardware.gpus.isEmpty
                                  ? null
                                  : hardware.gpus
                                      .map((gpu) =>
                                          '${gpu.backend.name}${gpu.vramBytes > 0 ? ' · ${formatBytes(gpu.vramBytes)} VRAM' : ' · shared memory'}')
                                      .join('\n'),
                            ),
                            InfoStat(label: 'Node id', value: settings.nodeId),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final tag in hardware.tags)
                              MetaChip(
                                label: tag,
                                icon: tag == 'emulator' ? Icons.developer_mode : Icons.label_outline,
                                highlighted: tag == 'emulator',
                              ),
                            if (hardware.tags.isEmpty) const MetaChip(label: 'no tags'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  PanelCard(
                    title: 'Engine and session',
                    subtitle: 'llama.cpp processes on this node',
                    icon: Icons.developer_board,
                    child: StatGrid(
                      children: [
                        InfoStat(
                          label: 'Engine binaries',
                          value: self.engineAvailable ? 'available' : 'not installed',
                          caption: self.engineAvailable ? 'engine/ or nativeLibraryDir' : 'download or build the engine',
                        ),
                        InfoStat(
                          label: 'Coordinator',
                          value: _session.service.engine.coordinatorRunning ? 'running' : 'stopped',
                          caption: 'llama-server on 127.0.0.1:47103',
                        ),
                        InfoStat(
                          label: 'RPC worker',
                          value: _session.service.engine.rpcWorkerRunning ? 'running' : 'stopped',
                          caption: 'rpc-server on :47102',
                        ),
                        InfoStat(
                          label: 'Session',
                          value: _session.service.currentSession == null
                              ? 'none'
                              : _session.service.currentSession!.sessionId,
                          caption: _session.service.currentSession == null
                              ? 'idle timeout 10 min'
                              : '${_session.service.currentSession!.model}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  PanelCard(
                    title: 'Peers',
                    subtitle: '${pluralize(peers.length, 'peer')} known · $reachable reachable',
                    icon: Icons.hub_outlined,
                    trailing: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('cluster-refresh'),
                          onPressed: _scanning ? null : _refresh,
                          icon: _scanning
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.wifi_find, size: 16),
                          label: Text(_scanning ? 'Scanning…' : 'Refresh'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('cluster-add-peer'),
                          onPressed: _addPeer,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add peer'),
                        ),
                      ],
                    ),
                    child: peers.isEmpty
                        ? const EmptyState(
                            icon: Icons.wifi_tethering_off,
                            title: 'No peers yet',
                            message: 'The UDP beacon and the /24 sweep found nothing. Add a peer by host:port — '
                                'inside the Android emulator the host machine is 10.0.2.2.',
                            compact: true,
                          )
                        : Column(
                            children: [
                              for (var i = 0; i < peers.length; i++) ...[
                                _PeerRow(peer: peers[i], session: _session),
                                if (i != peers.length - 1) const Divider(height: 16),
                              ],
                            ],
                          ),
                  ),
                  if (settings.manualPeers.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Manual peers are probed on every scan. Manage them in Settings.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({required this.peer, required this.session});

  final NodeInfo peer;
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = statusAppearance(context, peer);
    return Padding(
      key: Key('peer-${peer.nodeId}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: status.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              peer.workerEnabled ? Icons.dns_outlined : Icons.phone_iphone,
              size: 18,
              color: status.color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(peer.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    StatusPill(label: status.label, color: status.color),
                  ],
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    MetaChip(label: '${peer.host}:${peer.apiPort}', icon: Icons.lan_outlined),
                    MetaChip(
                      label: peer.workerEnabled ? 'worker mode' : 'client only',
                      icon: peer.workerEnabled ? Icons.memory : Icons.phone_iphone,
                      highlighted: peer.workerEnabled,
                    ),
                    if (!peer.engineAvailable)
                      const MetaChip(label: 'no engine', icon: Icons.warning_amber_outlined),
                    MetaChip(
                      label: '${formatBytes(peer.effectiveBudgetBytes)} budget',
                      icon: Icons.memory,
                    ),
                    MetaChip(label: formatRelativeTime(peer.lastSeen), icon: Icons.schedule),
                  ],
                ),
                const SizedBox(height: 5),
                if (peer.models.isEmpty)
                  Text(
                    'No models downloaded',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final model in peer.models)
                        MetaChip(
                          label: '${model.ref} · ${formatBytes(model.sizeBytes)}',
                          icon: (model.metadata?.isMoe ?? false) ? Icons.account_tree_outlined : Icons.linear_scale,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
