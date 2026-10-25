// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import '../auth_notice/auth_notice_fakes.dart';

/// PROBE-FIX (EMU-VERIFY RC12): the companion listens to
/// `ProfilePetService.petChanged` with no error handler
/// (`companion_controller.dart`), and that stream is the shared observer
/// socket's `events`. When Android destroyed the app's sockets in the
/// background, the observer socket ended while connected, `events` carried
/// its transport loss («Hermes Desktop WebSocket closed») and the pet's
/// listener left it uncaught. A transport loss belongs to the socket's
/// owners (list, Home, chat), which still hear it; it is not a pet change.
/// Any other error still surfaces.
SavedConnection _conn() => SavedConnection(
  id: 'probe-fix',
  label: 'probe-fix',
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

class _Rig {
  _Rig({Duration probeNowDeadline = const Duration(seconds: 5)}) {
    client = TuiGatewayClient(
      _conn(),
      dashboard: FakeTickets(),
      heartbeatInterval: Duration.zero,
      probeNowDeadline: probeNowDeadline,
      probeNowRecentInbound: Duration.zero,
      channelFactory: (_, _) => channel,
    );
    addTearDown(client.close);
  }

  final ReadyChannel channel = ReadyChannel();
  late final TuiGatewayClient client;

  /// What the socket's owners hear.
  final List<Object> ownerErrors = [];

  /// Errors nobody caught, from the pet listener's zone.
  final List<Object> uncaught = [];
  int petChanges = 0;

  Future<void> connect() async {
    await client.connect();
    expect(client.isConnected, isTrue);
    final owner = client.events.listen((_) {}, onError: ownerErrors.add);
    addTearDown(owner.cancel);
    // As the companion listens: no error handler.
    runZonedGuarded(() {
      final pet = ProfilePetService(
        client,
      ).petChanged.listen((_) => petChanges++);
      addTearDown(pet.cancel);
    }, (error, _) => uncaught.add(error));
  }

  void petChanged() => channel.incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': 'pet.changed',
        'payload': {'enabled': true, 'slug': 'nimbus'},
      },
    }),
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  test('the observer socket ending while connected is not an uncaught '
      'error of the pet listener', () async {
    final rig = _Rig();
    await rig.connect();
    rig.petChanged();
    await rig.settle();
    expect(rig.petChanges, 1, reason: 'pet changes still reach it');

    // Android destroys the app's sockets in the background.
    rig.channel.drop();
    await rig.settle();

    expect(rig.client.isConnected, isFalse);
    expect(
      rig.ownerErrors.whereType<StateError>().map((e) => e.message),
      ['Hermes Desktop WebSocket closed'],
      reason: 'the owners still hear the loss',
    );
    expect(rig.uncaught, isEmpty, reason: 'nothing left uncaught');
  });

  test('a dead socket killed by the foreground probe is not an uncaught '
      'error of the pet listener', () async {
    final rig = _Rig(probeNowDeadline: const Duration(milliseconds: 50));
    await rig.connect();

    // The fake never answers: the probe times out and kills the socket.
    expect(await rig.client.probeNow(), isFalse);
    await rig.settle();

    expect(rig.client.isConnected, isFalse);
    expect(rig.ownerErrors, isNotEmpty, reason: 'the owners hear the loss');
    expect(rig.uncaught, isEmpty, reason: 'nothing left uncaught');
  });

  test('an error that is not a transport loss still surfaces', () async {
    final rig = _Rig();
    await rig.connect();

    rig.channel.incoming.addError(ArgumentError('not a transport loss'));
    await rig.settle();

    expect(rig.uncaught, hasLength(1));
    expect(rig.uncaught.single, isA<ArgumentError>());
  });
}
