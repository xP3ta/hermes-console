// The state behind Settings › Messaging, without widgets: reads that are
// slower than the poll, and writes that overlap.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/messaging_platforms_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/messaging_pairing.dart';
import 'package:hermes_android/core/services/messaging_platforms.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _field(String key, {bool password = false}) => {
  'key': key,
  'required': false,
  'is_set': false,
  'is_password': password,
  'is_list': false,
  'advanced': false,
  'prompt': key,
  'description': '',
  'url': null,
  'redacted_value': null,
  'value': null,
};

class _Server {
  final requests = <http.Request>[];

  /// One gate per platform list read, in order: the read answers when its
  /// gate completes. No gate: it answers at once.
  final listGates = <Completer<void>>[];
  int listReads = 0;
  Completer<void>? holdPut;

  static http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/messaging/platforms') {
      final index = listReads++;
      if (index < listGates.length) await listGates[index].future;
      return _json({
        'platforms': [
          {
            'id': 'telegram',
            'name': 'Telegram',
            'description': '',
            'enabled': true,
            'configured': true,
            'gateway_running': true,
            'state': 'connected',
            'env_vars': [
              _field('TELEGRAM_BOT_TOKEN', password: true),
              _field('TELEGRAM_HOME_CHANNEL'),
            ],
          },
        ],
      });
    }
    if (request.method == 'PUT') {
      await holdPut?.future;
      return _json({'ok': true, 'platform': 'telegram', 'hot_served': true});
    }
    if (path.endsWith('/test')) {
      return _json({'ok': true, 'state': 'connected', 'message': 'ok'});
    }
    if (path == '/api/pairing') {
      return _json({'pending': const [], 'approved': const []});
    }
    return http.Response('{"detail":"Not Found"}', 404);
  }
}

void main() {
  late _Server server;
  late MessagingSetupController controller;

  setUp(() {
    server = _Server();
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient(server.handle),
    );
    addTearDown(dashboard.close);
    controller = MessagingSetupController(
      client: MessagingPlatformsClient(dashboard),
      pairingClient: MessagingPairingClient(dashboard),
      profile: 'research',
      settleDelay: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
  });

  test('answers slower than the poll still load the page: a tick never '
      'supersedes the read already on the wire', () async {
    final first = Completer<void>();
    server.listGates.add(first);
    // The first load, then two poll ticks while it has not answered.
    final load = controller.refresh();
    final tickOne = controller.refresh(silent: true);
    final tickTwo = controller.refresh(silent: true);
    await pumpEventQueue();
    expect(server.listReads, 1, reason: 'the ticks joined the read');
    expect(controller.platforms, isNull);

    first.complete();
    await Future.wait([load, tickOne, tickTwo]);
    expect(controller.platforms, hasLength(1));

    // With nothing on the wire the next tick reads again.
    await controller.refresh(silent: true);
    expect(server.listReads, 2);
  });

  test('a read the user asked for still supersedes a silent one', () async {
    final slow = Completer<void>();
    server.listGates.add(slow);
    final silent = controller.refresh(silent: true);
    await pumpEventQueue();
    await controller.refresh();
    expect(controller.platforms, hasLength(1));
    slow.complete();
    await silent;
    expect(server.listReads, 2);
  });

  test('a second write while a save is pending is refused, and the save '
      'drops only the edits it sent', () async {
    await controller.refresh();
    final telegram = controller.platformById('telegram')!;
    controller.edit('telegram', 'TELEGRAM_HOME_CHANNEL', '-1001');
    server.holdPut = Completer<void>();
    final saving = controller.save(telegram);
    await pumpEventQueue();
    expect(controller.busy, 'env:telegram');

    // Test is asked for while the save is on the wire.
    await expectLater(
      controller.test(telegram),
      throwsA(isA<MessagingBusy>()),
    );
    expect(controller.busy, 'env:telegram', reason: 'the form stays locked');

    // An edit that arrives anyway while the save is pending was never sent.
    controller.edit('telegram', 'TELEGRAM_BOT_TOKEN', 'typed-later');
    server.holdPut!.complete();
    await saving;

    expect(controller.busy, isNull);
    expect(controller.draftOf('telegram'), {
      'TELEGRAM_BOT_TOKEN': 'typed-later',
    });
    final put = server.requests.singleWhere((r) => r.method == 'PUT');
    expect((jsonDecode(put.body) as Map)['env'], {
      'TELEGRAM_HOME_CHANNEL': '-1001',
    });
  });
}
