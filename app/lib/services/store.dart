/// JSON persistence for chat history and UI preferences.
///
/// Uses synchronous file I/O on purpose: the payloads are a few kilobytes and
/// this keeps the async surface (and widget tests) simple.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/conversation.dart';

/// Reads/writes `<support dir>/conversations.json` atomically.
class ConversationStore {
  ConversationStore(this.directory);

  final Directory directory;

  File get file => File(p.join(directory.path, 'conversations.json'));

  Future<List<Conversation>> load() async {
    try {
      final f = file;
      if (!f.existsSync()) return [];
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final items = <Conversation>[];
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          items.add(Conversation.fromJson(entry));
        }
      }
      items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return items;
    } catch (_) {
      // Corrupt history must never block the app.
      return [];
    }
  }

  Future<void> save(List<Conversation> conversations) async {
    try {
      directory.createSync(recursive: true);
      final payload = jsonEncode([for (final c in conversations) c.toJson()]);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(payload, flush: true);
      tmp.renameSync(file.path);
    } catch (_) {
      // History is best effort; the chat keeps working in memory.
    }
  }
}

/// UI preferences (theme mode). Kept separate from [ConversationStore].
class AppPreferences {
  AppPreferences(this.directory);

  final Directory directory;

  File get file => File(p.join(directory.path, 'prefs.json'));

  Future<Map<String, dynamic>> load() async {
    try {
      final f = file;
      if (!f.existsSync()) return const {};
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> save(Map<String, dynamic> values) async {
    try {
      directory.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(values), flush: true);
    } catch (_) {
      // Preferences are best effort.
    }
  }
}
