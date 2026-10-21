// SPDX-License-Identifier: GPL-3.0-only
// PX5A: the Dashboard process dies and returns on the same port with an empty
// state and a new replay epoch. A chat at rest has nobody waiting on connect(),
// so the chat socket must redial by itself when its backoff gap ends (Desktop
// use-gateway-boot.ts reconnect timer), one dial per attempt, and stand down
// when parked or closed. Real loopback HttpServer + WebSocket shaped like
// Hermes; the backoff is injected short.
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
  _Rig(this.hermes, this.service, this.chat, this.gateway);
  final RestartableHermes hermes;
  final ActiveChatService service;
  final ActiveChat chat;
  final TuiGatewayClient gateway;
}

Future<_Rig> _rig(WidgetTester? _, {required Duration base}) async {
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );
  final hermes = RestartableHermes();
  await hermes.start();
  addTearDown(hermes.stop);
  final connection = SavedConnection(
    id: 'px5a',
    label: 'PX5A',
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
  // A new chat at rest: a draft with no stored session, nothing to reattach.
  final chat = service.attach(
    connection: connection,
    sessionId: 'draft-px5a',
    sessionTitle: 'New',
    sessionProfile: 'default',
    storedMessageLoader: (_, _) async => const [],
    attachDesktopRuntimeOnLoad: true,
    allowUnownedDesktopSnapshotForTesting: true,
    disableForegroundKeepAlive: true,
  );
  chat.markStoredSessionMissing();
  await chat.warmDesktopGateway();
  expect(gateway.isConnected, isTrue);
  return _Rig(hermes, service, chat, gateway);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('server dies and returns empty: the idle chat redials alone', () async {
    final rig = await _rig(null, base: const Duration(milliseconds: 20));
    await rig.hermes.stop();
    await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
    final before = rig.hermes.tickets;
    await rig.hermes.start(); // same port, empty state, new epoch
    // Nobody presses Retry and nobody awaits connect(): backoff cap of the
    // injected ladder (20 ms * 50 = 1 s) + 2 s.
    await _until(
      () => rig.gateway.isConnected,
      timeout: const Duration(seconds: 3),
      reason: 'the chat socket came back without help',
    );
    expect(rig.hermes.tickets, greaterThan(before), reason: 'fresh ticket');
    expect(rig.chat.transportStatus.isConnected, isTrue);
  });

  test('an owner waiting on connect() shares the redial: one ticket', () async {
    final rig = await _rig(null, base: const Duration(milliseconds: 400));
    await rig.hermes.stop();
    await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
    await rig.hermes.start();
    final before = rig.hermes.tickets;
    // The pooled keep-alive socket of the dead process may fail one attempt,
    // so count the attempts the client itself made: with an owner waiting and
    // our own timer armed there is still a single dial per attempt.
    await rig.gateway.connect();
    expect(rig.gateway.isConnected, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(rig.hermes.sockets.length, 1, reason: 'no second socket');
    expect(rig.hermes.tickets - before, lessThanOrEqualTo(2));
  });

  test(
    'network change + owner connect: the pending own timer dials no 2nd',
    () async {
      final rig = await _rig(null, base: const Duration(milliseconds: 400));
      await rig.hermes.stop();
      await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
      await rig.hermes.start();
      // A network change resets the gap; an owner dials at once. The timer armed
      // for the old gap must not dial again over the live socket.
      // (The first dial may meet the dead process's pooled keep-alive socket.)
      for (var i = 0; i < 5 && !rig.gateway.isConnected; i++) {
        rig.gateway.resetReconnectBackoffForNetworkChange();
        try {
          await rig.gateway.connect();
        } on Object {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(rig.gateway.isConnected, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(rig.gateway.isConnected, isTrue);
      expect(rig.hermes.sockets.length, 1, reason: 'one live socket');
    },
  );

  test('parked while the gap runs: the pending redial is cancelled', () async {
    final rig = await _rig(null, base: const Duration(milliseconds: 300));
    await rig.hermes.stop();
    await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
    await rig.gateway.disconnectIdle();
    expect(rig.gateway.linkParked, isTrue);
    await rig.hermes.start();
    final before = rig.hermes.tickets;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(rig.hermes.tickets, before, reason: 'parked: no ticket');
    expect(rig.gateway.isConnected, isFalse);
  });

  test('closed while the gap runs: the pending redial is cancelled', () async {
    final rig = await _rig(null, base: const Duration(milliseconds: 300));
    await rig.hermes.stop();
    await _until(() => !rig.gateway.isConnected, reason: 'socket noticed');
    await rig.gateway.close();
    await rig.hermes.start();
    final before = rig.hermes.tickets;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(rig.hermes.tickets, before, reason: 'closed: no ticket');
  });

  test('an observer socket (not a chat) keeps waiting for its owner', () async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final hermes = RestartableHermes();
    await hermes.start();
    addTearDown(hermes.stop);
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'px5a-obs',
        label: 'PX5A',
        host: '127.0.0.1',
        port: hermes.port,
        apiKey: 'fixture',
        dashboardUrl: 'http://127.0.0.1:${hermes.port}',
        kind: InstanceKind.vps,
      ),
      reconnectBackoff: GatewayReconnectBackoff(
        base: const Duration(milliseconds: 20),
        random: () => 1.0,
      ),
    );
    addTearDown(client.close);
    await client.connect();
    await hermes.stop();
    await _until(() => !client.isConnected, reason: 'socket noticed');
    await hermes.start();
    final before = hermes.tickets;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(hermes.tickets, before, reason: 'no owner, no flag: no dial');
  });
}
