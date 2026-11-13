import 'dart:async';
import 'dart:io';

import 'package:app/models/conversation.dart';
import 'package:app/services/store.dart';
import 'package:app/util/errors.dart';
import 'package:app/util/format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

void main() {
  group('ConversationStore', () {
    test('round-trips conversations and entries', () async {
      final dir = await Directory.systemTemp.createTemp('llmmbc_store_');
      addTearDown(() => dir.delete(recursive: true));
      final store = ConversationStore(dir);
      expect(await store.load(), isEmpty);

      final now = DateTime.now();
      final conversation = Conversation(
        id: 'c1',
        title: 'Hello cluster',
        modelRef: 'qwen3:0.6b',
        entries: [
          ChatEntry(role: 'user', content: 'hi', createdAt: now),
          ChatEntry(role: 'assistant', content: '**hello**', createdAt: now, servedBy: 'Studio PC'),
          ChatEntry(
            role: 'error',
            content: 'no worker',
            createdAt: now,
            errorCode: 'no_candidates',
            errorTitle: 'No node can serve this model',
          ),
        ],
        createdAt: now,
        updatedAt: now,
      );

      await store.save([conversation]);
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.first.id, 'c1');
      expect(loaded.first.entries, hasLength(3));
      expect(loaded.first.entries[1].servedBy, 'Studio PC');
      expect(loaded.first.entries[2].errorCode, 'no_candidates');
      expect(loaded.first.entries[2].errorTitle, 'No node can serve this model');
      expect(store.file.path, endsWith('conversations.json'));
    });

    test('ignores corrupt JSON', () async {
      final dir = await Directory.systemTemp.createTemp('llmmbc_store_bad_');
      addTearDown(() => dir.delete(recursive: true));
      final store = ConversationStore(dir);
      await store.file.writeAsString('{not json');
      expect(await store.load(), isEmpty);
    });

    test('preferences are best effort', () async {
      final dir = await Directory.systemTemp.createTemp('llmmbc_prefs_');
      addTearDown(() => dir.delete(recursive: true));
      final prefs = AppPreferences(dir);
      expect(await prefs.load(), isEmpty);
      await prefs.save({'themeMode': 'dark'});
      expect((await prefs.load())['themeMode'], 'dark');
    });
  });

  group('Conversation.titleFor', () {
    test('collapses whitespace and truncates', () {
      expect(Conversation.titleFor('  hello   world '), 'hello world');
      expect(Conversation.titleFor(''), 'New conversation');
      final long = Conversation.titleFor('x' * 80);
      expect(long.length, 48);
      expect(long, endsWith('…'));
    });
  });

  group('describeChatError', () {
    test('maps the documented codes', () {
      expect(describeChatError(LlmmbcException('no_candidates', '')).title, 'No node can serve this model');
      expect(describeChatError(LlmmbcException('busy', '')).title, 'Coordinator is busy');
      expect(describeChatError(LlmmbcException('does_not_fit', '')).title, 'Model does not fit in the cluster');
      expect(describeChatError(LlmmbcException('engine_error', 'boom')).title, 'Engine failed to start');
      expect(describeChatError(LlmmbcException('weird', 'x')).code, 'weird');
      expect(describeChatError(const SocketException('nope')).code, 'network');
      expect(describeChatError(TimeoutException('slow')).code, 'timeout');
    });
  });

  group('format helpers', () {
    test('bytes and time', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1024), '1.0 KiB');
      expect(formatBytes(1536), '1.5 KiB');
      expect(formatBytes(12 * 1024 * 1024 * 1024), '12.0 GiB');
      expect(formatPercent(0.8), '80%');
      expect(pluralize(1, 'peer'), '1 peer');
      expect(pluralize(3, 'peer'), '3 peers');
      expect(shortId('abcdef123456'), 'abcdef12');
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      expect(formatRelativeTime(now, now: now), 'just now');
      expect(formatRelativeTime(now.subtract(const Duration(seconds: 30)), now: now), '30s ago');
      expect(formatRelativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5m ago');
      expect(formatClock(now), '12:00');
    });
  });
}
