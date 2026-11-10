// SPDX-License-Identifier: GPL-3.0-only
// PX5B: the Dashboard process dies and returns on the same port with an empty
// state and a new replay epoch. An empty chat at rest has nothing to rejoin:
// when Hermes answers its resume with a stop that is not transient while the
// socket itself is healthy, the chat must publish connected (the draft stays
// and the next send creates a session), not stay on "Reconnecting…".
// Real loopback HttpServer + WebSocket shaped like Hermes; backoff injected.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/in_memory_compression_restore_storage.dart';
import 'restartable_hermes_fixture.dart';

Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 8),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason);
}

class _Rig {
  _Rig(this.hermes, this.chat, this.gateway);
  final RestartableHermes hermes;
  final ActiveChat chat;
  final TuiGatewayClient gateway;
}

Future<_Rig> _rig({Map<String, Object?>? resumeError}) async {
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );
  final hermes = RestartableHermes()..advertised.add('stored-px5b');
  if (resumeError != null) hermes.resumeErrorAfterRestart = resumeError;
  await hermes.start();
  addTearDown(hermes.stop);
  final connection = SavedConnection(
    id: 'px5b',
    label: 'PX5B',
    host: '127.0.0.1',
    port: hermes.port,
    apiKey: 'fixture',
    dashboardUrl: 'http://127.0.0.1:${hermes.port}',
    kind: InstanceKind.vps,
  );
  late TuiGatewayClient gateway;
  final service = ActiveChatService(
    compressionRestoreStore: testCompressionRestoreStore(),
    desktopGatewayFactory: (c) => gateway = TuiGatewayClient(
      c,
      reconnectBackoff: GatewayReconnectBackoff(
        base: const Duration(milliseconds: 20),
        random: () => 1.0,
      ),
    ),
  );
  addTearDown(service.dispose);
  // An empty chat at rest that already has its durable session.
  final chat = service.attach(
    connection: connection,
    sessionId: 'stored-px5b',
    sessionTitle: 'New',
    sessionProfile: 'default',
    storedMessageLoader: (_, _) async => const [],
    attachDesktopRuntimeOnLoad: true,
    disableForegroundKeepAlive: true,
  );
  await chat.warmDesktopGateway();
  await chat.loadMessages();
  await _until(() => gateway.isConnected, reason: 'first socket');
  await _until(
    () => chat.transportStatus.isConnected,
    reason: 'chat connected before the cut',
  );
  return _Rig(hermes, chat, gateway);
}

Future<void> _cutAndReturn(_Rig rig) async {
  await rig.hermes.stop();
  await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
  await rig.hermes.start(); // same port, empty state, new epoch
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The session is advertised yet Hermes cannot resume it (4007) and its
  // durable row answers 404: nothing exists to wait for.
  test('empty chat, resume 4007 and row 404: connected, next send creates a '
      'session', () async {
    final rig = await _rig();
    await _cutAndReturn(rig);
    // REVISION-4 A: the chat is connected as soon as the socket is up, so
    // wait for the row check itself before sending.
    await _until(
      () => rig.hermes.restPaths.isNotEmpty,
      timeout: const Duration(seconds: 3),
      reason: 'the row was verified',
    );
    await _until(
      () => rig.chat.storedSessionKnownMissing,
      timeout: const Duration(seconds: 3),
      reason: 'the 404 row made the chat a draft',
    );
    expect(rig.chat.transportStatus.isConnected, isTrue);
    expect(rig.gateway.isConnected, isTrue);
    expect(rig.hermes.methods, contains('session.resume'));
    final sent = await rig.chat.send(
      fullText: 'hi',
      model: 'm',
      history: const [],
    );
    expect(sent, isTrue, reason: 'the next send must be accepted');
    expect(rig.hermes.methods, contains('session.create'));
  });

  // The row survived the restart: publishing connected would make the next
  // send fork a session beside the live one. Stay honest.
  // REVISION-4 A: a socket that is up is never «reconnecting» (Desktop's
    // status pill mirrors the socket: use-statusbar-items.tsx:376-407); the
    // loop keeps reconciling behind a connected chat.
  test('empty chat, resume 4007 but the row answers 200: connected socket, '
      'no session.create', () async {
    final rig = await _rig();
    rig.hermes.rowSurvives = true;
    await _cutAndReturn(rig);
    await _until(
      () => rig.hermes.restPaths.isNotEmpty,
      reason: 'the row was verified',
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(rig.chat.transportStatus.state, ChatTransportState.connected);
    expect(rig.chat.storedSessionKnownMissing, isFalse);
    expect(rig.hermes.methods, isNot(contains('session.create')));
  });

  // Codes other than 4007 never reach the verification: no REST read, no
  // connected.
  for (final stop in <String, Map<String, Object?>>{
    '-32602 invalid params': {'code': -32602, 'message': 'invalid params'},
    '5009 unclassified': {'code': 5009, 'message': 'unclassified'},
  }.entries) {
    test('empty chat, resume ${stop.key}: connected socket, no REST read, no '
        'session.create', () async {
      final rig = await _rig(resumeError: stop.value);
      await _cutAndReturn(rig);
      await _until(
        () => rig.hermes.methods.contains('session.resume'),
        reason: 'resume attempted',
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      // REVISION-4 A: a socket that is up is never «reconnecting» (Desktop's
      // status pill mirrors the socket: use-statusbar-items.tsx:376-407); the
      // loop keeps reconciling behind a connected chat.
      expect(rig.chat.transportStatus.state, ChatTransportState.connected);
      expect(rig.hermes.restPaths, isEmpty);
      expect(rig.hermes.methods, isNot(contains('session.create')));
    });
  }

  test(
    'the roster no longer lists the session: connected (unchanged)',
    () async {
      final rig = await _rig();
      rig.hermes.advertised.clear();
      await _cutAndReturn(rig);
      await _until(
        () => rig.chat.transportStatus.isConnected,
        timeout: const Duration(seconds: 3),
      );
    },
  );

  // REVISION-4 A: a socket that is up is never «reconnecting» (Desktop's
    // status pill mirrors the socket: use-statusbar-items.tsx:376-407); the
    // loop keeps reconciling behind a connected chat.
  test('a transient resume failure retries behind a connected socket', () async {
    final rig = await _rig(resumeError: {'code': 5001, 'message': 'try again'});
    await _cutAndReturn(rig);
    await _until(
      () => rig.hermes.methods.contains('session.resume'),
      reason: 'resume attempted',
    );
    final resumes = rig.hermes.methods.where((m) => m == 'session.resume').length;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(rig.chat.transportStatus.state, ChatTransportState.connected);
    await _until(
      () =>
          rig.hermes.methods.where((m) => m == 'session.resume').length >
          resumes,
      reason: 'a transient failure is not a stop: it keeps retrying',
    );
  });
}
