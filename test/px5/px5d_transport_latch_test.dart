// SPDX-License-Identifier: GPL-3.0-only
// PX5D: a chat whose recovery loop left on a silent exit (Stop while the
// socket was down) kept its transport on offline/reconnecting for good: a
// healthy link never cleared it, nor did «Retry». Real loopback HttpServer +
// WebSocket shaped like Hermes; the backoff is injected short.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
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
  _Rig(this.hermes, this.chat, this.gateway, this.transport);
  final RestartableHermes hermes;
  final ActiveChat chat;
  final TuiGatewayClient gateway;
  final List<ChatTransportState> transport;
}

Future<_Rig> _rig({
  Duration base = const Duration(milliseconds: 20),
  Map<String, Object?>? resumeError,
}) async {
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );
  final hermes = RestartableHermes()..advertised.add('stored-px5d');
  if (resumeError != null) hermes.resumeErrorAfterRestart = resumeError;
  await hermes.start();
  addTearDown(hermes.stop);
  final connection = SavedConnection(
    id: 'px5d',
    label: 'PX5D',
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
      reconnectBackoff: GatewayReconnectBackoff(base: base, random: () => 1.0),
    ),
  );
  addTearDown(service.dispose);
  final chat = service.attach(
    connection: connection,
    sessionId: 'stored-px5d',
    sessionTitle: 'Luna',
    sessionProfile: 'default',
    storedMessageLoader: (_, _) async => const [],
    attachDesktopRuntimeOnLoad: true,
    disableForegroundKeepAlive: true,
  );
  // The chat screen stays open on it.
  final screen = chat.changes.listen((_) {});
  addTearDown(screen.cancel);
  await chat.warmDesktopGateway();
  await chat.loadMessages();
  await _until(() => gateway.isConnected, reason: 'first socket');
  await _until(() => chat.transportStatus.isConnected, reason: 'connected');
  ConnectionStatusRegistry.instance.bind(connection.id, gateway);
  final transport = <ChatTransportState>[];
  chat.transportStatusListenable.addListener(
    () => transport.add(chat.transportStatus.state),
  );
  return _Rig(hermes, chat, gateway, transport);
}

/// A turn in flight loses its socket (a network cut: the server keeps its
/// state) and the user presses Stop while it is still down.
Future<void> _stopDuringRecovery(_Rig rig, {bool queued = false}) async {
  final sent = await rig.chat.send(
    fullText: 'hola',
    model: 'm',
    history: const [],
  );
  expect(sent, isTrue);
  await _until(() => rig.hermes.methods.contains('prompt.submit'));
  if (queued) expect(rig.chat.enqueue('después'), isTrue);
  await rig.hermes.stop();
  await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
  await _until(
    () => !rig.chat.transportStatus.isConnected,
    reason: 'the loss is published',
  );
  // The interrupt cannot reach a server that is down; Stop still settles.
  unawaited(rig.chat.cancel().then((_) {}, onError: (Object _) {}));
  await _until(() => rig.chat.state == ChatPipelineState.cancelled);
  // The recovery loop sees the Stop and leaves while the socket is down.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  debugPrint(
    'PX5D after stop: ${rig.transport} socket=${rig.gateway.isConnected} '
    '${rig.chat.state}',
  );

}

/// The network comes back: same server, same state (not a restart).
Future<void> _networkBack(_Rig rig) async {
  rig.hermes.epoch = 0;
  await rig.hermes.start();
  await _until(
    () => rig.gateway.isConnected,
    timeout: const Duration(seconds: 5),
    reason: 'the chat socket redialled alone (PX5A)',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('T1 Stop during the recovery: the link comes back and the chat '
      'transport follows, without a send', () async {
    final rig = await _rig();
    await _stopDuringRecovery(rig);
    await _networkBack(rig);
    expect(
      ConnectionStatusRegistry.instance.current('px5d')?.isConnected,
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    debugPrint('PX5D T1: ${rig.transport} methods=${rig.hermes.methods}');
    expect(rig.chat.transportStatus.isConnected, isTrue);
    expect(rig.chat.transportStatus.disconnectedSince, isNull);
  });

  test('T2 «Retry» with the socket already alive clears the stale loss', () async {
    final rig = await _rig();
    await _stopDuringRecovery(rig);
    await _networkBack(rig);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    debugPrint('PX5D T2 before retry: ${rig.chat.transportStatus.state}');
    await rig.chat.retryConnectionNow();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    debugPrint('PX5D T2: ${rig.transport}');
    expect(rig.chat.transportStatus.isConnected, isTrue);
  });

  test('T3 queue paused after Stop: connected with no new send', () async {
    final rig = await _rig();
    await _stopDuringRecovery(rig, queued: true);
    expect(rig.chat.queueParked, isTrue);
    await _networkBack(rig);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    debugPrint('PX5D T3: ${rig.transport} methods=${rig.hermes.methods}');
    expect(rig.chat.queuedMessages, isNotEmpty, reason: 'still queued');
    expect(
      rig.hermes.methods.where((m) => m == 'prompt.submit'),
      hasLength(1),
      reason: 'no new send',
    );
    expect(rig.chat.transportStatus.isConnected, isTrue);
  });

  test('T4 the server really is down: Retry never says connected', () async {
    final rig = await _rig();
    await _stopDuringRecovery(rig);
    await rig.chat.retryConnectionNow();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    debugPrint('PX5D T4: ${rig.transport}');
    expect(rig.gateway.isConnected, isFalse);
    expect(rig.chat.transportStatus.isConnected, isFalse);
  });

  test('a reattach still working keeps saying reconnecting when the link '
      'comes back (no loop owner is settled)', () async {
    final rig = await _rig(resumeError: {'code': 5001, 'message': 'busy'});
    await rig.hermes.stop();
    await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
    final since = rig.transport.length;
    await rig.hermes.start(); // a restart: the transient resume keeps failing
    await _until(
      () => rig.hermes.methods.contains('session.resume'),
      reason: 'the reattach loop resumes on the live socket',
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(rig.gateway.isConnected, isTrue);
    expect(rig.chat.transportStatus.state, ChatTransportState.reconnecting);
    expect(
      rig.transport.skip(since),
      isNot(contains(ChatTransportState.connected)),
      reason: 'the socket edge must not settle a loss the loop still owns',
    );
  });

  test('a turn recovery still working is not settled by the link: connected '
      'only once it has resumed', () async {
    final rig = await _rig();
    expect(
      await rig.chat.send(fullText: 'hola', model: 'm', history: const []),
      isTrue,
    );
    await _until(() => rig.hermes.methods.contains('prompt.submit'));
    final before = rig.hermes.methods.length;
    final resumedFirst = <bool>[];
    rig.chat.transportStatusListenable.addListener(() {
      if (!rig.chat.transportStatus.isConnected) return;
      resumedFirst.add(
        rig.hermes.methods.skip(before).contains('session.resume'),
      );
    });
    await rig.hermes.stop();
    await _until(() => !rig.chat.transportStatus.isConnected);
    await _networkBack(rig);
    await _until(
      () => rig.chat.transportStatus.isConnected,
      timeout: const Duration(seconds: 10),
    );
    debugPrint('PX5D owner: ${rig.transport} ${rig.hermes.methods}');
    expect(resumedFirst.first, isTrue, reason: 'no connected before resume');
  });

  test('the reattach loop leaves silently (the stored session is gone) on a '
      'live socket: connected, not reconnecting for good', () async {
    final rig = await _rig(resumeError: {'code': 5001, 'message': 'busy'});
    await rig.hermes.stop();
    await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
    await rig.hermes.start();
    await _until(() => rig.hermes.methods.contains('session.resume'));
    await _until(
      () => rig.chat.transportStatus.state == ChatTransportState.reconnecting,
    );
    // What the chat screen does once the stored session answers 404.
    rig.chat.markStoredSessionGone();
    rig.chat.requestImmediateTransportRecovery();
    await _until(
      () => rig.chat.transportStatus.isConnected,
      timeout: const Duration(seconds: 10),
      reason: 'the loop that owned the loss is gone and the socket is live',
    );
  });
}
