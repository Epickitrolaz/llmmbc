/// Model catalog, downloads (progress / cancel / resume / delete) and the local
/// GGUF store.
library;

import 'dart:async';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:flutter/material.dart';

import '../app/app_session.dart';
import '../util/format.dart';
import 'widgets/common.dart';

class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  final TextEditingController _pullField = TextEditingController();
  final Map<String, DownloadProgress> _downloads = {};
  final Map<String, StreamSubscription<DownloadProgress>> _subscriptions = {};

  late AppSession _session;
  bool _hydrated = false;
  bool _loading = true;
  String? _loadError;
  String? _pullError;
  List<LocalModel> _local = [];
  List<CatalogEntry> _catalog = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = AppScope.of(context);
    if (!_hydrated) {
      _hydrated = true;
      _load();
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _pullField.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await _session.refreshModels(force: force);
      final results = await Future.wait([
        _session.service.models.list(),
        Future.value(_session.service.models.catalog()),
      ]);
      if (!mounted) return;
      setState(() {
        _local = [...results[0] as List<LocalModel>]
          ..sort((a, b) => a.ref.toString().compareTo(b.ref.toString()));
        _catalog = results[1] as List<CatalogEntry>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  bool _isLocal(ModelRef ref) => _local.any((model) => model.ref == ref);

  DownloadProgress? _progressFor(ModelRef ref) => _downloads[ref.toString()];

  /// Downloads started by name that have no catalog row of their own.
  List<DownloadProgress> get _orphanDownloads {
    final catalogRefs = _catalog.map((entry) => entry.ref.toString()).toSet();
    return [
      for (final entry in _downloads.entries)
        if (!catalogRefs.contains(entry.key)) entry.value,
    ];
  }

  void _startDownload(ModelRef ref) {
    final key = ref.toString();
    _subscriptions.remove(key)?.cancel();
    setState(() {
      _pullError = null;
      _downloads[key] = DownloadProgress(ref, DownloadState.resolving);
    });
    final subscription = _session.service.models.pull(ref).listen(
      (progress) {
        if (!mounted) return;
        setState(() => _downloads[key] = progress);
        if (progress.state == DownloadState.done || progress.state == DownloadState.failed) {
          _load(force: true);
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        final message = error is LlmmbcException ? error.message : error.toString();
        setState(() {
          _downloads[key] = DownloadProgress(
            ref,
            DownloadState.failed,
            receivedBytes: _downloads[key]?.receivedBytes ?? 0,
            totalBytes: _downloads[key]?.totalBytes ?? 0,
            error: message,
          );
        });
      },
      onDone: () => _subscriptions.remove(key),
    );
    _subscriptions[key] = subscription;
  }

  Future<void> _cancelDownload(ModelRef ref) async {
    await _session.service.models.cancel(ref);
    final key = ref.toString();
    final current = _downloads[key];
    if (mounted && current != null) {
      setState(() {
        _downloads[key] = DownloadProgress(
          ref,
          DownloadState.cancelled,
          receivedBytes: current.receivedBytes,
          totalBytes: current.totalBytes,
        );
      });
    }
  }

  Future<void> _pullByName() async {
    final value = _pullField.text.trim();
    if (value.isEmpty) {
      setState(() => _pullError = 'Enter a model reference such as qwen3:0.6b');
      return;
    }
    ModelRef ref;
    try {
      ref = ModelRef.parse(value);
    } on FormatException {
      setState(() => _pullError = 'Not a valid model reference. Use [namespace/]name[:tag].');
      return;
    }
    if (!_session.downloadsEnabled) {
      setState(() => _pullError = 'Downloads need the core runtime, which is unavailable in this build.');
      return;
    }
    setState(() => _pullError = null);
    _pullField.clear();
    _startDownload(ref);
  }

  Future<void> _delete(LocalModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${model.ref}?'),
        content: const Text(
          'The manifest and every blob that no other model references are removed from the local store.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _session.service.models.delete(model.ref);
      await _load(force: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Pull any GGUF from the Ollama registry by name.',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      IconButton(
                        key: const Key('models-refresh'),
                        tooltip: 'Refresh',
                        onPressed: () => _load(force: true),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  if (!_session.downloadsEnabled) ...[
                    NoticeBanner(
                      message: 'The core runtime is unavailable in this build, so downloads, deletes and '
                          'GGUF inspection are disabled. The catalog below is reference data.',
                      tone: scheme.error,
                      icon: Icons.warning_amber_outlined,
                    ),
                    const SizedBox(height: 12),
                  ],
                  _PullCard(
                    controller: _pullField,
                    error: _pullError,
                    enabled: true,
                    onPull: _pullByName,
                  ),
                  const SizedBox(height: 16),
                  if (_orphanDownloads.isNotEmpty) ...[
                    _ActiveDownloadsCard(
                      downloads: _orphanDownloads,
                      onCancel: _cancelDownload,
                      onResume: _startDownload,
                    ),
                    const SizedBox(height: 16),
                  ],
                  _CatalogCard(
                    catalog: _catalog,
                    loading: _loading,
                    error: _loadError,
                    downloadsEnabled: _session.downloadsEnabled,
                    isLocal: _isLocal,
                    progressFor: _progressFor,
                    onDownload: _startDownload,
                    onCancel: _cancelDownload,
                  ),
                  const SizedBox(height: 16),
                  _LocalCard(
                    models: _local,
                    loading: _loading,
                    onDelete: _delete,
                    downloadsEnabled: _session.downloadsEnabled,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PullCard extends StatelessWidget {
  const _PullCard({
    required this.controller,
    required this.error,
    required this.enabled,
    required this.onPull,
  });

  final TextEditingController controller;
  final String? error;
  final bool enabled;
  final Future<void> Function() onPull;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PanelCard(
      title: 'Pull by name',
      subtitle: 'Ollama reference: [namespace/]name[:tag]',
      icon: Icons.cloud_download_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('models-pull-field'),
                  controller: controller,
                  enabled: enabled,
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'qwen3:0.6b'),
                  onSubmitted: (_) => onPull(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                key: const Key('models-pull-button'),
                onPressed: onPull,
                child: const Text('Pull'),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              key: const Key('models-pull-error'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _CatalogCard extends StatelessWidget {
  const _CatalogCard({
    required this.catalog,
    required this.loading,
    required this.error,
    required this.downloadsEnabled,
    required this.isLocal,
    required this.progressFor,
    required this.onDownload,
    required this.onCancel,
  });

  final List<CatalogEntry> catalog;
  final bool loading;
  final String? error;
  final bool downloadsEnabled;
  final bool Function(ModelRef) isLocal;
  final DownloadProgress? Function(ModelRef) progressFor;
  final void Function(ModelRef) onDownload;
  final Future<void> Function(ModelRef) onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sorted = [...catalog]..sort((a, b) {
        if (a.isMoe != b.isMoe) return a.isMoe ? -1 : 1;
        return a.ref.toString().compareTo(b.ref.toString());
      });

    Widget body;
    if (loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error));
    } else if (sorted.isEmpty) {
      body = Text('The catalog is empty.', style: theme.textTheme.bodySmall);
    } else {
      body = Column(
        children: [
          for (var i = 0; i < sorted.length; i++) ...[
            _CatalogRow(
              entry: sorted[i],
              downloaded: isLocal(sorted[i].ref),
              progress: progressFor(sorted[i].ref),
              downloadsEnabled: downloadsEnabled,
              onDownload: () => onDownload(sorted[i].ref),
              onCancel: () => onCancel(sorted[i].ref),
            ),
            if (i != sorted.length - 1) const Divider(height: 18),
          ],
        ],
      );
    }

    return PanelCard(
      title: 'Catalog',
      subtitle: 'Curated models, MoE first',
      icon: Icons.storefront_outlined,
      child: body,
    );
  }
}

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    required this.entry,
    required this.downloaded,
    required this.progress,
    required this.downloadsEnabled,
    required this.onDownload,
    required this.onCancel,
  });

  final CatalogEntry entry;
  final bool downloaded;
  final DownloadProgress? progress;
  final bool downloadsEnabled;
  final VoidCallback onDownload;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = progress?.state;
    final active = state != null &&
        state != DownloadState.done &&
        state != DownloadState.failed &&
        state != DownloadState.cancelled;
    final key = entry.ref.toString();

    Widget trailing;
    if (downloaded) {
      trailing = const MetaChip(label: 'downloaded', icon: Icons.check_circle_outline, highlighted: true);
    } else if (active) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(value: progress!.totalBytes > 0 ? progress!.fraction : null),
          ),
          const SizedBox(width: 10),
          Text(
            progress!.totalBytes > 0 ? formatPercent(progress!.fraction) : '…',
            style: theme.textTheme.labelSmall,
          ),
          IconButton(
            key: Key('download-cancel-$key'),
            tooltip: 'Cancel',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onCancel,
          ),
        ],
      );
    } else {
      final label = state == DownloadState.cancelled
          ? 'Resume'
          : state == DownloadState.failed
              ? 'Retry'
              : 'Download';
      trailing = FilledButton.tonal(
        key: Key('download-btn-$key'),
        onPressed: downloadsEnabled ? onDownload : null,
        child: Text(label),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(entry.title, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    ModelKindBadge(isMoe: entry.isMoe),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.description,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    MetaChip(label: key, icon: Icons.tag),
                    MetaChip(label: formatBytes(entry.approxSizeBytes), icon: Icons.sd_storage_outlined),
                  ],
                ),
                if (state == DownloadState.failed && progress?.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    progress!.error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

class _LocalCard extends StatelessWidget {
  const _LocalCard({
    required this.models,
    required this.loading,
    required this.onDelete,
    required this.downloadsEnabled,
  });

  final List<LocalModel> models;
  final bool loading;
  final Future<void> Function(LocalModel) onDelete;
  final bool downloadsEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget body;
    if (loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (models.isEmpty) {
      body = const EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No downloaded models',
        message: 'Pulled models land in <data dir>/models/blobs and appear here with their GGUF metadata.',
        compact: true,
      );
    } else {
      body = Column(
        children: [
          for (var i = 0; i < models.length; i++) ...[
            _LocalRow(
              model: models[i],
              onDelete: () => onDelete(models[i]),
              downloadsEnabled: downloadsEnabled,
            ),
            if (i != models.length - 1) const Divider(height: 16),
          ],
        ],
      );
    }

    return PanelCard(
      title: 'Downloaded',
      subtitle: '${models.length} model${models.length == 1 ? '' : 's'} in the local store',
      icon: Icons.inventory_2_outlined,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: scheme.onSurface),
        child: body,
      ),
    );
  }
}

class _LocalRow extends StatelessWidget {
  const _LocalRow({required this.model, required this.onDelete, required this.downloadsEnabled});

  final LocalModel model;
  final VoidCallback onDelete;
  final bool downloadsEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = model.metadata;
    final isMoe = meta?.isMoe ?? false;
    return Padding(
      key: Key('local-model-${model.ref}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(isMoe ? Icons.account_tree_outlined : Icons.linear_scale, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        model.ref.toString(),
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ModelKindBadge(isMoe: isMoe),
                  ],
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    MetaChip(label: formatBytes(model.sizeBytes), icon: Icons.sd_storage_outlined),
                    if (meta != null) ...[
                      MetaChip(label: meta.architecture, icon: Icons.category_outlined),
                      MetaChip(label: '${meta.blockCount} layers', icon: Icons.layers_outlined),
                      if (meta.isMoe)
                        MetaChip(
                          label: '${meta.expertCount} experts · ${meta.expertUsedCount} active',
                          icon: Icons.hub_outlined,
                          highlighted: true,
                        ),
                      if (meta.contextLength > 0)
                        MetaChip(label: 'ctx ${meta.contextLength}', icon: Icons.width_normal),
                      if (meta.totalTensorBytes > 0)
                        MetaChip(label: 'fftype ${meta.fileType}', icon: Icons.description_outlined),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  model.ggufPath,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('delete-model-${model.ref}'),
            tooltip: downloadsEnabled ? 'Delete' : 'Delete needs the core runtime',
            onPressed: downloadsEnabled ? onDelete : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}


class _ActiveDownloadsCard extends StatelessWidget {
  const _ActiveDownloadsCard({
    required this.downloads,
    required this.onCancel,
    required this.onResume,
  });

  final List<DownloadProgress> downloads;
  final Future<void> Function(ModelRef) onCancel;
  final void Function(ModelRef) onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PanelCard(
      title: 'Downloads',
      subtitle: 'Pulled by name, outside the curated catalog',
      icon: Icons.downloading,
      child: Column(
        children: [
          for (var i = 0; i < downloads.length; i++) ...[
            Builder(
              builder: (context) {
                final progress = downloads[i];
                final ref = progress.ref;
                final state = progress.state;
                final active = state != DownloadState.done &&
                    state != DownloadState.failed &&
                    state != DownloadState.cancelled;
                return Row(
                  key: Key('download-row-$ref'),
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(ref.toString(), style: theme.textTheme.titleSmall),
                          const SizedBox(height: 4),
                          if (active)
                            LinearProgressIndicator(
                              value: progress.totalBytes > 0 ? progress.fraction : null,
                            )
                          else
                            Text(
                              state == DownloadState.done
                                  ? 'Downloaded'
                                  : state == DownloadState.cancelled
                                      ? 'Cancelled — partial blobs are kept for resume'
                                      : progress.error ?? 'Failed',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (active)
                      IconButton(
                        key: Key('download-cancel-$ref'),
                        tooltip: 'Cancel',
                        icon: const Icon(Icons.close),
                        onPressed: () => onCancel(ref),
                      )
                    else if (state != DownloadState.done)
                      FilledButton.tonal(
                        key: Key('download-btn-$ref'),
                        onPressed: () => onResume(ref),
                        child: Text(state == DownloadState.cancelled ? 'Resume' : 'Retry'),
                      ),
                  ],
                );
              },
            ),
            if (i != downloads.length - 1) const Divider(height: 16),
          ],
        ],
      ),
    );
  }
}
