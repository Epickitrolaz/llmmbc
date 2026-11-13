/// Chat with the cluster: model picker, streaming markdown answers, stop button,
/// persisted conversation list and coordinator/worker session details.
library;

import 'dart:async';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:flutter/material.dart';

import '../app/app_session.dart';
import '../app/theme.dart';
import '../models/conversation.dart';
import '../util/errors.dart';
import '../util/format.dart';
import 'widgets/common.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  late AppSession _session;
  bool _hydrated = false;
  bool _streaming = false;
  bool _showHistory = false;

  Conversation? _conversation;
  List<ChatEntry> _entries = [];
  ModelRef? _selectedRef;
  StreamSubscription<ChatDelta>? _subscription;
  int _streamSeq = 0;
  String? _servedBy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = AppScope.of(context);
    if (!_hydrated) {
      _hydrated = true;
      if (_session.history.isNotEmpty) {
        _conversation = _session.history.first;
        _entries = List.of(_conversation!.entries);
        _selectedRef = _tryParseRef(_conversation!.modelRef);
        _servedBy = _entries.where((e) => e.servedBy != null).lastOrNull?.servedBy;
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<ClusterModel> get _models => _session.service.clusterModels();

  ModelRef? get _effectiveModel {
    final models = _models;
    if (models.isEmpty) return null;
    if (_selectedRef != null && models.any((model) => model.ref == _selectedRef)) {
      return _selectedRef;
    }
    return models.first.ref;
  }

  ClusterModel? get _selectedModel {
    final ref = _effectiveModel;
    if (ref == null) return null;
    for (final model in _models) {
      if (model.ref == ref) return model;
    }
    return null;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _persist() async {
    final conversation = _conversation;
    if (conversation == null) return;
    final updated = conversation.copyWith(entries: List.of(_entries), updatedAt: DateTime.now());
    _conversation = updated;
    final items = [updated, ..._session.history.where((item) => item.id != updated.id)]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _session.setHistory(items);
  }

  void _startNewChat() {
    _streamSeq++;
    _subscription?.cancel();
    setState(() {
      _conversation = null;
      _entries = [];
      _servedBy = null;
      _streaming = false;
      _showHistory = false;
      _selectedRef = _effectiveModel;
    });
  }

  void _openConversation(Conversation conversation) {
    _streamSeq++;
    _subscription?.cancel();
    setState(() {
      _conversation = conversation;
      _entries = List.of(conversation.entries);
      _selectedRef = _tryParseRef(conversation.modelRef) ?? _selectedRef;
      _servedBy = _entries.where((entry) => entry.servedBy != null).lastOrNull?.servedBy;
      _streaming = false;
      _showHistory = false;
    });
    _scrollToBottom();
  }

  Future<void> _deleteConversation(Conversation conversation) async {
    final items = _session.history.where((item) => item.id != conversation.id).toList();
    await _session.setHistory(items);
    if (_conversation?.id == conversation.id) {
      _startNewChat();
    }
  }

  Future<void> _pickModel() async {
    final models = _models;
    if (models.isEmpty) return;
    final selected = await showModalBottomSheet<ModelRef>(
      context: context,
      showDragHandle: true,
      builder: (context) => _ModelPickerSheet(models: models, selected: _effectiveModel),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedRef = selected;
      if (_conversation != null) {
        _conversation = _conversation!.copyWith(modelRef: selected.toString(), updatedAt: DateTime.now());
      }
    });
    if (_conversation != null) await _persist();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _streaming) return;
    final ref = _effectiveModel;
    if (ref == null) return;

    final now = DateTime.now();
    final conversation = _conversation ??
        Conversation(
          id: 'conv-${now.microsecondsSinceEpoch}',
          title: Conversation.titleFor(text),
          modelRef: ref.toString(),
          entries: const [],
          createdAt: now,
          updatedAt: now,
        );

    _input.clear();
    setState(() {
      _conversation = conversation;
      _entries = [
        ..._entries,
        ChatEntry(role: 'user', content: text, createdAt: now),
        ChatEntry(role: 'assistant', content: '', createdAt: now),
      ];
      _streaming = true;
      _servedBy = null;
    });
    _scrollToBottom();

    final messages = <ChatMessage>[
      for (final entry in _entries)
        if (!entry.isError && entry.content.trim().isNotEmpty)
          ChatMessage(entry.role, entry.content),
    ];

    final streamId = ++_streamSeq;
    _subscription = _session.service.chat(ref, messages).listen(
      (delta) {
        if (!mounted || streamId != _streamSeq) return;
        setState(() {
          final index = _entries.length - 1;
          final current = _entries[index];
          _entries[index] = current.copyWith(
            content: current.content + delta.content,
            servedBy: delta.servedBy == null ? null : _session.nodeName(delta.servedBy),
          );
          _servedBy = _entries[index].servedBy ?? _servedBy;
        });
        _scrollToBottom();
      },
      onError: (Object error) {
        if (!mounted || streamId != _streamSeq) return;
        final info = describeChatError(error);
        setState(() {
          _entries[_entries.length - 1] = ChatEntry(
            role: 'error',
            content: info.message,
            createdAt: DateTime.now(),
            errorCode: info.code,
            errorTitle: info.title,
          );
          _streaming = false;
        });
        _persist();
      },
      onDone: () {
        if (!mounted || streamId != _streamSeq) return;
        setState(() {
          final index = _entries.length - 1;
          if (_entries[index].role == 'assistant' && _entries[index].content.isEmpty) {
            _entries[index] = _entries[index].copyWith(content: '_No output._');
          }
          _streaming = false;
        });
        _persist();
      },
      cancelOnError: true,
    );
  }

  Future<void> _stop() async {
    final subscription = _subscription;
    _subscription = null;
    // Stop accepting deltas immediately and update the UI; awaiting cancel() is
    // not needed for correctness and some stream controllers complete it late.
    _streamSeq++;
    if (mounted) {
      setState(() {
        if (_entries.isNotEmpty && _entries.last.role == 'assistant') {
          final last = _entries.last;
          _entries[_entries.length - 1] = last.copyWith(
            stopped: true,
            content: last.content.isEmpty ? '_Stopped before the first token._' : last.content,
          );
        }
        _streaming = false;
      });
    }
    await subscription?.cancel();
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = _selectedModel;
    final ready = _session.ready;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            children: [
              _ModelBar(
                model: model,
                onPick: _pickModel,
                onNewChat: _startNewChat,
                onToggleHistory: () => setState(() => _showHistory = !_showHistory),
                historyCount: _session.history.length,
              ),
              if (_showHistory) ...[
                const SizedBox(height: 10),
                _HistoryPanel(
                  conversations: _session.history,
                  activeId: _conversation?.id,
                  onOpen: _openConversation,
                  onDelete: _deleteConversation,
                ),
              ],
              if (_session.service.currentSession != null) ...[
                const SizedBox(height: 10),
                _SessionStrip(session: _session),
              ],
            ],
          ),
        ),
        Expanded(
          child: _entries.isEmpty
              ? _ChatEmptyState(
                  ready: ready,
                  hasModels: model != null,
                  onSuggestion: (text) {
                    _input.text = text;
                    _input.selection = TextSelection.collapsed(offset: text.length);
                    _focus.requestFocus();
                  },
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) => _MessageBubble(
                    entry: _entries[index],
                    streaming: _streaming && index == _entries.length - 1,
                  ),
                ),
        ),
        _Composer(
          controller: _input,
          focusNode: _focus,
          streaming: _streaming,
          enabled: model != null,
          hint: model == null
              ? 'No model in the cluster yet'
              : 'Ask ${model.ref} anything…',
          onSend: _send,
          onStop: _stop,
        ),
        if (model == null && _entries.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              _session.degraded
                  ? 'The node runtime is unavailable in this build, so there is no cluster to chat with.'
                  : 'Download a model in Models, or enable worker mode on a device that has one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _ModelBar extends StatelessWidget {
  const _ModelBar({
    required this.model,
    required this.onPick,
    required this.onNewChat,
    required this.onToggleHistory,
    required this.historyCount,
  });

  final ClusterModel? model;
  final VoidCallback onPick;
  final VoidCallback onNewChat;
  final VoidCallback onToggleHistory;
  final int historyCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = model;
    final memory = selected == null
        ? 0
        : selected.candidates.fold<int>(0, (sum, node) => sum + node.effectiveBudgetBytes);
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('chat-model-picker'),
        onTap: selected == null ? null : onPick,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.memory, size: 18, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            selected?.ref.toString() ?? 'No model available',
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (selected != null) ModelKindBadge(isMoe: selected.isMoe),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('chat-new'),
                    tooltip: 'New chat',
                    visualDensity: VisualDensity.compact,
                    onPressed: onNewChat,
                    icon: const Icon(Icons.add_comment_outlined),
                  ),
                  Badge(
                    isLabelVisible: historyCount > 0,
                    label: Text('$historyCount'),
                    child: IconButton(
                      key: const Key('chat-history'),
                      tooltip: 'Conversations',
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggleHistory,
                      icon: const Icon(Icons.history),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 46),
                child: selected == null
                    ? Text(
                        'Nothing in the cluster is downloaded and worker-enabled',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          MetaChip(label: formatBytes(selected.sizeBytes), icon: Icons.sd_storage_outlined),
                          MetaChip(
                            label: pluralize(selected.candidates.length, 'candidate'),
                            icon: Icons.hub_outlined,
                          ),
                          MetaChip(label: '${formatBytes(memory)} cluster budget', icon: Icons.memory),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({
    required this.conversations,
    required this.activeId,
    required this.onOpen,
    required this.onDelete,
  });

  final List<Conversation> conversations;
  final String? activeId;
  final ValueChanged<Conversation> onOpen;
  final ValueChanged<Conversation> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (conversations.isEmpty) {
      return PanelCard(
        child: Text(
          'No saved conversations yet. Start chatting and the thread is stored as JSON in the app support directory.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return PanelCard(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: conversations.length,
          itemBuilder: (context, index) {
            final conversation = conversations[index];
            final active = conversation.id == activeId;
            return ListTile(
              dense: true,
              selected: active,
              selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
              leading: const Icon(Icons.chat_bubble_outline, size: 18),
              title: Text(conversation.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${conversation.modelRef} · ${formatRelativeTime(conversation.updatedAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              trailing: IconButton(
                tooltip: 'Delete conversation',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => onDelete(conversation),
              ),
              onTap: () => onOpen(conversation),
            );
          },
        ),
      ),
    );
  }
}

class _SessionStrip extends StatelessWidget {
  const _SessionStrip({required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final info = session.service.currentSession;
    if (info == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final workers = info.workerIds.isEmpty ? 'none' : info.workerIds.map(session.nodeName).join(', ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.hub, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Session ${info.model} · coordinator ${session.nodeName(info.coordinatorId)} · workers $workers',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({required this.ready, required this.hasModels, required this.onSuggestion});

  final bool ready;
  final bool hasModels;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!ready) {
      return const EmptyState(
        icon: Icons.hourglass_top,
        title: 'Starting the node',
        message: 'Chat becomes available as soon as the startup sequence finishes.',
      );
    }
    if (!hasModels) {
      return const EmptyState(
        icon: Icons.hub_outlined,
        title: 'No models in the cluster',
        message: 'A model appears here when a reachable node has it fully downloaded and worker mode '
            'enabled. Download one from Models, or turn worker mode on in Settings.',
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const EmptyState(
                icon: Icons.forum_outlined,
                title: 'Ask the cluster anything',
                message: 'The request goes to the candidate with the largest memory budget. '
                    'Answers stream back token by token and markdown is rendered as it arrives.',
                compact: true,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final prompt in const [
                    'Which models fit my cluster?',
                    'Explain MoE expert offloading',
                    'Write a haiku about LAN clusters',
                  ])
                    ActionChip(
                      label: Text(prompt),
                      onPressed: () => onSuggestion(prompt),
                      labelStyle: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.entry, required this.streaming});

  final ChatEntry entry;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (entry.isError) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: const Key('chat-error'),
          constraints: const BoxConstraints(maxWidth: 720),
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, size: 17, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.errorTitle ?? 'Request failed',
                      style: theme.textTheme.titleSmall?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                  if (entry.errorCode != null)
                    MetaChip(label: entry.errorCode!, icon: Icons.code, highlighted: false),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                entry.content,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
              ),
            ],
          ),
        ),
      );
    }

    if (entry.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: SelectableText(
            entry.content,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onPrimary, height: 1.4),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.content.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Coordinator is thinking…',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            else
              MarkdownBody(
                data: entry.content,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  h1: theme.textTheme.titleLarge,
                  h2: theme.textTheme.titleMedium,
                  h3: theme.textTheme.titleSmall,
                  code: monoStyle(context, size: 12.5, color: scheme.onSurface),
                  codeblockDecoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  blockSpacing: 10,
                  listBullet: theme.textTheme.bodyMedium,
                ),
              ),
            if (streaming && entry.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: scheme.primary),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (entry.servedBy != null)
                        MetaChip(label: 'served by ${entry.servedBy}', icon: Icons.hub_outlined, highlighted: true),
                      if (entry.stopped)
                        MetaChip(label: 'stopped', icon: Icons.stop_circle_outlined),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatClock(entry.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.streaming,
    required this.enabled,
    required this.hint,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool streaming;
  final bool enabled;
  final String hint;
  final Future<void> Function() onSend;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('chat-input'),
                controller: controller,
                focusNode: focusNode,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(hintText: hint, hintStyle: theme.textTheme.bodySmall),
              ),
            ),
            const SizedBox(width: 10),
            if (streaming)
              FilledButton.tonalIcon(
                key: const Key('chat-stop'),
                onPressed: onStop,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stop'),
              )
            else
              IconButton.filled(
                key: const Key('chat-send'),
                onPressed: enabled ? onSend : null,
                tooltip: 'Send',
                icon: const Icon(Icons.arrow_upward),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelPickerSheet extends StatelessWidget {
  const _ModelPickerSheet({required this.models, required this.selected});

  final List<ClusterModel> models;
  final ModelRef? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cluster models', style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              'Union of every reachable worker that has the model downloaded.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: models.length,
                itemBuilder: (context, index) {
                  final model = models[index];
                  final active = model.ref == selected;
                  final memory = model.candidates.fold<int>(
                    0,
                    (sum, node) => sum + node.effectiveBudgetBytes,
                  );
                  return ListTile(
                    key: Key('model-option-${model.ref}'),
                    contentPadding: EdgeInsets.zero,
                    selected: active,
                    leading: Icon(
                      model.isMoe ? Icons.account_tree_outlined : Icons.linear_scale,
                      color: active ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            model.ref.toString(),
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ModelKindBadge(isMoe: model.isMoe),
                      ],
                    ),
                    subtitle: Text(
                      '${formatBytes(model.sizeBytes)} · ${pluralize(model.candidates.length, 'candidate')} · '
                      '${formatBytes(memory)} budget',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: active ? Icon(Icons.check, color: scheme.primary) : null,
                    onTap: () => Navigator.of(context).pop(model.ref),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

ModelRef? _tryParseRef(String value) {
  if (value.trim().isEmpty) return null;
  try {
    return ModelRef.parse(value);
  } on FormatException {
    return null;
  }
}
