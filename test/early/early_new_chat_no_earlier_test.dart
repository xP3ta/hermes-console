// SPDX-License-Identifier: GPL-3.0-only
// EARLY: a brand new chat with one exchange has nothing earlier. «Faltan
// mensajes» / «Cargar mensajes anteriores» must not appear.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/in_memory_compression_restore_storage.dart';
import 'early_hermes_server.dart';

Future<void> _until(bool Function() done, {String? reason}) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason);
}

Future<ActiveChat> _newChatWithOneExchange(
  EarlyHermes hermes, {
  String profile = 'default',
}) async {
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );
  await hermes.start();
  addTearDown(hermes.stop);
  final connection = SavedConnection(
    id: 'early-$profile',
    label: 'EARLY',
    host: '127.0.0.1',
    port: hermes.port,
    apiKey: 'k',
    dashboardUrl: 'http://127.0.0.1:${hermes.port}',
    kind: InstanceKind.vps,
  );
  final service = ActiveChatService(
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  addTearDown(service.dispose);
  final chat = service.attach(
    connection: connection,
    sessionId: 'draft-early',
    sessionTitle: 'New',
    sessionProfile: profile,
    attachDesktopRuntimeOnLoad: true,
    allowUnownedDesktopSnapshotForTesting: true,
    disableForegroundKeepAlive: true,
  );
  chat.markStoredSessionMissing();
  await chat.warmDesktopGateway();
  final sent = await chat.send(fullText: 'Hola', model: 'm', history: const []);
  expect(sent, isTrue);
  await _until(
    () => chat.messages.any((m) => m['role'] == 'assistant'),
    reason: 'the reply arrived',
  );
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return chat;
}

/// Reopen reads (the live session omits its history) and the first
/// «earlier» request the chat screen makes while the list is short.
Future<void> _openAndAskEarlier(ActiveChat chat, {int? expected}) async {
  await chat.loadMessages(expectedMessageCount: expected);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await chat.loadEarlierMessages();
}

const _named = 'social-writer';

/// Transcript reads the chat made, as URIs.
Iterable<Uri> _messageReads(EarlyHermes hermes) => hermes.restRequests
    .map(Uri.parse)
    .where((uri) => uri.path.endsWith('/messages'));

Map<String, Object?> _page(Uri uri, List<Map<String, Object?>> rows) {
  final limit = int.parse(uri.queryParameters['limit'] ?? '500');
  final offset = int.parse(uri.queryParameters['offset'] ?? '0');
  final end = (rows.length - offset).clamp(0, rows.length);
  final page = rows.sublist((end - limit).clamp(0, end), end);
  return {
    'session_id': 'stored-early',
    'profile': _named,
    'messages': page,
    'pagination': {
      'limit': limit,
      'offset': offset,
      'order': 'latest',
      'returned': page.length,
    },
  };
}

/// The stored transcript once Hermes has written this chat's one exchange,
/// after [before] older rows.
List<Map<String, Object?>> _written({int before = 0}) => [
  for (var i = 1; i <= before; i++)
    {'id': i, 'role': i.isOdd ? 'user' : 'assistant', 'content': 'old $i'},
  {'id': before + 1, 'role': 'user', 'content': 'Hola'},
  {
    'id': before + 2,
    'role': 'assistant',
    'content': 'Hola, ¿en qué te ayudo?',
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new chat, Dashboard 404 «Session not found» (row not written yet): '
      'nothing earlier, no warning', () async {
    final hermes = EarlyHermes(); // default REST answer: 404
    final chat = await _newChatWithOneExchange(hermes);
    await _openAndAskEarlier(chat);
    expect(hermes.restRequests, isNotEmpty, reason: 'REST was really read');
    expect(chat.earlierMessagesLoadFailed, isFalse);
    expect(chat.hasEarlierMessages, isFalse);
  });

  test('new chat, REST 5xx on the tail read: still a real failure', () async {
    final hermes = EarlyHermes()
      ..rest = (_) => (status: 503, body: {'detail': 'busy'});
    final chat = await _newChatWithOneExchange(hermes);
    await _openAndAskEarlier(chat);
    expect(chat.earlierMessagesLoadFailed, isTrue);
    expect(chat.hasEarlierMessages, isTrue);
  });

  test(
    'history announced by the open, REST 404: still a real failure',
    () async {
      final hermes = EarlyHermes();
      final chat = await _newChatWithOneExchange(hermes);
      await _openAndAskEarlier(chat, expected: 40);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  group('a named profile ($_named) read from its Dashboard store', () {
    // The Dashboard answers 404 «Session not found» for a session the
    // profile's store has not written yet; the client reports a named
    // profile's 404 as profileUnavailable (or, read straight from the
    // Dashboard, as its HTTP 404). On the tail read of a chat whose open
    // announced no history that is «nothing earlier» too.
    test('new chat, 404 before the row is written: nothing earlier, no '
        'warning', () async {
      final hermes = EarlyHermes();
      final chat = await _newChatWithOneExchange(hermes, profile: _named);
      await _openAndAskEarlier(chat);
      expect(_messageReads(hermes), isNotEmpty, reason: 'REST was read');
      expect(
        _messageReads(hermes).map((uri) => uri.queryParameters['profile']),
        everyElement(_named),
      );
      expect(chat.earlierMessagesLoadFailed, isFalse);
      expect(chat.hasEarlierMessages, isFalse);
    });

    test('new chat, REST 5xx on the tail read: still a real failure', () async {
      final hermes = EarlyHermes()
        ..rest = (_) => (status: 503, body: {'detail': 'busy'});
      final chat = await _newChatWithOneExchange(hermes, profile: _named);
      await _openAndAskEarlier(chat);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      expect(chat.hasEarlierMessages, isTrue);
    });

    test('history announced by the open, 404: still a real failure', () async {
      final hermes = EarlyHermes();
      final chat = await _newChatWithOneExchange(hermes, profile: _named);
      await _openAndAskEarlier(chat, expected: 40);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      expect(chat.hasEarlierMessages, isTrue);
    });

    test('the race ends: once the row is written the exchange is its durable '
        'rows', () async {
      final hermes = EarlyHermes();
      final chat = await _newChatWithOneExchange(hermes, profile: _named);
      await _openAndAskEarlier(chat);
      expect(chat.earlierMessagesLoadFailed, isFalse);

      hermes.rest = (uri) => uri.path.endsWith('/messages')
          ? (status: 200, body: _page(uri, _written()))
          : (status: 404, body: {'detail': 'Session not found'});
      await chat.loadMessages();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final turns = chat.messages.reversed
          .where((row) => row['role'] == 'user' || row['role'] == 'assistant')
          .toList();
      expect(turns.map((row) => row['content']), [
        'Hola',
        'Hola, ¿en qué te ayudo?',
      ]);
      expect(turns.map((row) => row['id']).toSet(), {1, 2});
      expect(chat.earlierMessagesLoadFailed, isFalse);
      expect(chat.hasEarlierMessages, isFalse);
    });

    test('a 404 on a real earlier page (not the tail): still a real '
        'failure', () async {
      final rows = _written(before: 118);
      final hermes = EarlyHermes()
        ..rest = (uri) {
          if (!uri.path.endsWith('/messages')) {
            return (status: 404, body: {'detail': 'Session not found'});
          }
          final offset = int.parse(uri.queryParameters['offset'] ?? '0');
          return offset == 0
              ? (status: 200, body: _page(uri, rows))
              : (status: 404, body: {'detail': 'Session not found'});
        };
      final chat = await _newChatWithOneExchange(hermes, profile: _named);
      await chat.loadMessages();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The open announced 2 rows and the store holds 120, so the first
      // «earlier» request may first repair the tail (offset 0, answered 200);
      // the next one reads the real earlier page.
      bool readEarlierPage() => _messageReads(
        hermes,
      ).any((uri) => uri.queryParameters['offset'] == '120');
      for (var i = 0; i < 3 && !readEarlierPage(); i++) {
        expect(chat.earlierMessagesLoadFailed, isFalse);
        await chat.loadEarlierMessages();
      }

      expect(readEarlierPage(), isTrue);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      expect(chat.hasEarlierMessages, isTrue);
    });

    // A Dashboard that refused the client once (401) is read straight, so
    // its 404 arrives as the Dashboard's own HTTP error.
    ({int status, Object? body}) Function(Uri) refusedOnceThen(int status) {
      var reads = 0;
      return (uri) {
        if (!uri.path.endsWith('/messages')) {
          return (status: 404, body: {'detail': 'Session not found'});
        }
        reads += 1;
        // The client's own Dashboard retries a 401 once.
        if (reads <= 2) return (status: 401, body: {'detail': 'Unauthorized'});
        return (
          status: status,
          body: {'detail': status == 404 ? 'Session not found' : 'busy'},
        );
      };
    }

    test('read straight from the Dashboard, 404: nothing earlier, no '
        'warning', () async {
      final hermes = EarlyHermes()..rest = refusedOnceThen(404);
      final chat = await _newChatWithOneExchange(hermes, profile: _named);
      await _openAndAskEarlier(chat);
      expect(_messageReads(hermes).length, greaterThan(2));
      expect(chat.profileTranscriptAccessBlocked, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
      expect(chat.hasEarlierMessages, isFalse);
    });

    test('read straight from the Dashboard, 5xx: still a real '
        'failure', () async {
      final hermes = EarlyHermes()..rest = refusedOnceThen(503);
      final chat = await _newChatWithOneExchange(hermes, profile: _named);
      await _openAndAskEarlier(chat);
      expect(_messageReads(hermes).length, greaterThan(2));
      expect(chat.earlierMessagesLoadFailed, isTrue);
      expect(chat.hasEarlierMessages, isTrue);
    });
  });
}
