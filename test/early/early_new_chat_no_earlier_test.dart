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

Future<ActiveChat> _newChatWithOneExchange(EarlyHermes hermes) async {
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
    id: 'early',
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
    sessionProfile: 'default',
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
}
