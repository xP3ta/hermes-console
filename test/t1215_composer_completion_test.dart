import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/services/composer_completion_scheduler.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/slash_commands.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/rpc_frame_helpers.dart';

final class _TicketDashboard extends DashboardClient {
  _TicketDashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'x');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 't1215');
}

/// Real [TuiGatewayClient] over a WebSocket fake that records every frame.
Future<(TuiGatewayClient, List<Map<String, dynamic>>)> _recordingClient(
  Map<String, dynamic> Function(Map<String, dynamic> frame) answer,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final requests = <Map<String, dynamic>>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (isClientCapabilitiesFrame(frame)) {
        socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
        continue;
      }
      requests.add(frame);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': answer(frame),
        }),
      );
    }
  });
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'conn-t1215',
      label: 'T1215',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
    ),
    dashboard: _TicketDashboard(),
  );
  addTearDown(client.close);
  return (client, requests);
}

void main() {
  group('ComposerCompletionScheduler', () {
    test('a 10-keystroke burst sends one request for the last query', () {
      fakeAsync((async) {
        final asked = <String>[];
        final answered = <String>[];
        final scheduler = ComposerCompletionScheduler<String>(
          fetch: (query) async {
            asked.add(query);
            return 'answer:$query';
          },
        );
        const typed = '/abcdefghi';
        for (var index = 1; index <= typed.length; index++) {
          scheduler.schedule(
            typed.substring(0, index),
            (query, result) => answered.add(result!),
          );
          async.elapse(const Duration(milliseconds: 40));
        }
        async.elapse(const Duration(milliseconds: 400));

        expect(asked, [typed]);
        expect(scheduler.requestCount, 1);
        expect(answered, ['answer:$typed']);
      });
    });

    test('cancel drops the pending timer and a late in-flight answer', () {
      fakeAsync((async) {
        final gate = Completer<String>();
        var calls = 0;
        final delivered = <String?>[];
        final scheduler = ComposerCompletionScheduler<String>(
          fetch: (query) {
            calls++;
            return gate.future;
          },
        );

        scheduler.schedule('/a', (_, result) => delivered.add(result));
        scheduler.cancel();
        async.elapse(const Duration(milliseconds: 400));
        expect(calls, 0);

        scheduler.schedule('/b', (_, result) => delivered.add(result));
        async.elapse(const Duration(milliseconds: 200));
        expect(calls, 1);
        scheduler.cancel();
        gate.complete('late');
        async.flushMicrotasks();
        expect(delivered, isEmpty);
      });
    });

    test('a cached query answers synchronously without a request', () {
      fakeAsync((async) {
        final scheduler = ComposerCompletionScheduler<String>(
          fetch: (query) async => 'r:$query',
        );
        final delivered = <String?>[];
        scheduler.schedule('/x', (_, result) => delivered.add(result));
        async.elapse(const Duration(milliseconds: 300));
        scheduler.schedule('/x', (_, result) => delivered.add(result));

        expect(delivered, ['r:/x', 'r:/x']);
        expect(scheduler.requestCount, 1);
        expect(scheduler.hasPendingTimer, isFalse);
      });
    });
  });

  group('slash palette merge', () {
    late Strings s;
    setUpAll(() async {
      s = await Strings.delegate.load(const Locale('es'));
    });

    test('server commands lead skills; local rows keep their place', () {
      final completion = SlashCompletionBatch.fromJson({
        'replace_from': 1,
        'items': [
          {'text': '/review-pr', 'meta': 'Review a PR', 'kind': 'skill'},
          {'text': '/goal', 'meta': 'Run a goal', 'kind': 'command'},
          {'text': '/help', 'meta': 'server help', 'kind': 'command'},
        ],
      }, input: '/');
      final merged = mergeSlashSuggestions(
        input: '/',
        local: slashSuggestionsFor('/', s),
        completion: completion,
      );
      final names = merged.map((command) => command.name).toList();

      expect(names.first, 'help');
      expect(merged.first.action, SlashAction.help);
      expect(names.indexOf('goal'), lessThan(names.indexOf('review-pr')));
      expect(merged.last.name, 'review-pr');
      expect(merged.last.isSkill, isTrue);
      expect(merged.last.description, 'Review a PR');
      expect(names.where((name) => name == 'help'), hasLength(1));
    });

    test('without complete.slash the catalog prefix match is the fallback', () {
      final catalog = DesktopCommandCatalog.fromJson({
        'pairs': [
          ['/goal', 'Run a goal'],
          ['/gif-search', 'Search GIFs'],
          ['/usage', 'Show usage'],
        ],
        'skills': {
          '/gif-search': {'usage': 3, 'origin': 'local'},
        },
      });
      expect(catalog.skillNames, {'gif-search'});

      final merged = mergeSlashSuggestions(
        input: '/g',
        local: slashSuggestionsFor('/g', s),
        catalog: catalog,
      );
      expect(merged.map((command) => command.name), ['goal', 'gif-search']);
      expect(merged.last.isSkill, isTrue);
      expect(merged.last.description, 'Search GIFs');
    });

    test('the palette is bounded', () {
      final completion = SlashCompletionBatch.fromJson({
        'replace_from': 1,
        'items': [
          for (var index = 0; index < 50; index++)
            {'text': '/skill-$index', 'kind': 'skill'},
        ],
      }, input: '/');
      final merged = mergeSlashSuggestions(
        input: '/',
        local: const [],
        completion: completion,
      );
      expect(merged, hasLength(maxSlashPaletteRows));
    });
  });

  test('complete.slash carries the runtime like Desktop does', () async {
    final (client, requests) = await _recordingClient(
      (frame) => {
        'replace_from': 1,
        'items': [
          {'text': '/review-pr', 'meta': 'Review', 'kind': 'skill'},
        ],
      },
    );

    final scoped = await client.completeSlashInSession(
      '/rev',
      runtimeSessionId: 'runtime-t1215',
    );
    await client.completeSlashInSession('/rev');

    expect(requests.map((frame) => frame['params']), [
      {'text': '/rev', 'session_id': 'runtime-t1215'},
      {'text': '/rev'},
    ]);
    expect(scoped.suggestions.single.isSkill, isTrue);
  });
}
