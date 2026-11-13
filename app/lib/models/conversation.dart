/// Local chat history persisted as JSON in the app support directory.
library;

/// One message bubble in a conversation.
class ChatEntry {
  /// `user`, `assistant` or `error`.
  final String role;
  final String content;

  /// Human readable name of the node that served the answer, if known.
  final String? servedBy;
  final DateTime createdAt;

  /// Set for error bubbles: wire error code (`busy`, `no_candidates`, ...).
  final String? errorCode;

  /// Short title for an error bubble.
  final String? errorTitle;
  final bool stopped;

  const ChatEntry({
    required this.role,
    required this.content,
    required this.createdAt,
    this.servedBy,
    this.errorCode,
    this.errorTitle,
    this.stopped = false,
  });

  bool get isUser => role == 'user';
  bool get isError => role == 'error';

  ChatEntry copyWith({
    String? content,
    String? servedBy,
    String? errorCode,
    String? errorTitle,
    bool? stopped,
  }) =>
      ChatEntry(
        role: role,
        content: content ?? this.content,
        createdAt: createdAt,
        servedBy: servedBy ?? this.servedBy,
        errorCode: errorCode ?? this.errorCode,
        errorTitle: errorTitle ?? this.errorTitle,
        stopped: stopped ?? this.stopped,
      );

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'servedBy': servedBy,
        'createdAt': createdAt.toIso8601String(),
        'errorCode': errorCode,
        'errorTitle': errorTitle,
        'stopped': stopped,
      };

  factory ChatEntry.fromJson(Map<String, dynamic> json) => ChatEntry(
        role: json['role'] as String? ?? 'assistant',
        content: json['content'] as String? ?? '',
        servedBy: json['servedBy'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        errorCode: json['errorCode'] as String?,
        errorTitle: json['errorTitle'] as String?,
        stopped: json['stopped'] as bool? ?? false,
      );
}

/// A chat thread. Bounded to what the UI needs: model, entries, title.
class Conversation {
  final String id;
  final String title;
  final String modelRef;
  final List<ChatEntry> entries;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Conversation({
    required this.id,
    required this.title,
    required this.modelRef,
    required this.entries,
    required this.createdAt,
    required this.updatedAt,
  });

  Conversation copyWith({
    String? title,
    String? modelRef,
    List<ChatEntry>? entries,
    DateTime? updatedAt,
  }) =>
      Conversation(
        id: id,
        title: title ?? this.title,
        modelRef: modelRef ?? this.modelRef,
        entries: entries ?? this.entries,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'modelRef': modelRef,
        'entries': entries.map((e) => e.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        title: json['title'] as String? ?? 'New conversation',
        modelRef: json['modelRef'] as String? ?? '',
        entries: [
          for (final item in (json['entries'] as List? ?? const []))
            ChatEntry.fromJson(item as Map<String, dynamic>),
        ],
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      );

  /// Title derived from the first user message.
  static String titleFor(String firstMessage) {
    final clean = firstMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return 'New conversation';
    return clean.length <= 48 ? clean : '${clean.substring(0, 47)}…';
  }
}
