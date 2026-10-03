import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/composer_reference.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/composer_completion_scheduler.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/large_paste.dart';
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
      final result = answer(frame);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': frame['id'],
          if (result['__error'] case final int code)
            'error': {'code': code, 'message': 'Method not found'}
          else
            'result': result,
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

  group('@ references', () {
    TextEditingValue caretAtEnd(String text) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );

    test('complete.path rows keep only file, folder and url references', () {
      final batch = PathCompletionBatch.fromJson({
        'items': [
          {'text': '@diff', 'meta': 'git diff'},
          {'text': '@file:', 'meta': 'attach file'},
          {'text': '@git:', 'meta': 'git log'},
          {'text': '@alice', 'meta': 'agent profile'},
          {'text': '@folder:lib/', 'display': 'lib/', 'meta': 'dir'},
          {'text': '@file:lib/main.dart', 'display': 'main.dart'},
          {'text': '@url:', 'meta': 'fetch url'},
          {'text': '@jira:ABC-1', 'meta': 'plugin'},
        ],
      });
      expect(batch.items.map((item) => item.rawText), [
        '@file:',
        '@folder:lib/',
        '@file:lib/main.dart',
        '@url:',
      ]);
      expect(batch.items.first.isStarter, isTrue);
    });

    test('the token under the caret drives the query', () {
      expect(composerReferenceQuery(caretAtEnd('@'))?.word, '@');
      expect(
        composerReferenceQuery(caretAtEnd('see @lib/ma'))?.query,
        'lib/ma',
      );
      expect(composerReferenceQuery(caretAtEnd('@folder'))?.word, '@folder:');
      expect(composerReferenceQuery(caretAtEnd('mail@host')), isNull);
      expect(composerReferenceQuery(caretAtEnd('`@lib')), isNull);
      expect(composerReferenceQuery(caretAtEnd('@file:`a.dart`')), isNull);
      expect(composerReferenceQuery(caretAtEnd('@url:https://x.io')), isNull);
      expect(
        composerReferenceQuery(
          const TextEditingValue(
            text: '@libx',
            selection: TextSelection.collapsed(offset: 3),
          ),
        ),
        isNull,
      );
    });

    test('picks serialize exactly like Desktop chips', () {
      const file = PathCompletionItem(
        kind: ComposerReferenceKind.file,
        value: 'lib/main.dart',
        display: 'main.dart',
        meta: '',
      );
      const folder = PathCompletionItem(
        kind: ComposerReferenceKind.folder,
        value: 'lib/core/',
        display: 'core/',
        meta: 'dir',
      );
      const starter = PathCompletionItem(
        kind: ComposerReferenceKind.url,
        value: '',
        display: '@url:',
        meta: '',
      );
      final value = caretAtEnd('read @lib/ma');
      final query = composerReferenceQuery(value)!;

      expect(
        applyReferencePick(value, query, file).text,
        'read @file:`lib/main.dart` ',
      );
      expect(
        applyReferencePick(value, query, folder).text,
        'read @folder:`lib/core/` ',
      );
      expect(applyReferencePick(value, query, starter).text, 'read @url:');
      expect(
        applyReferenceDescend(value, query, folder).text,
        'read @lib/core/',
      );
      final scoped = caretAtEnd('@folder:li');
      expect(
        applyReferenceDescend(
          scoped,
          composerReferenceQuery(scoped)!,
          folder,
        ).text,
        '@folder:lib/core/',
      );
      expect(quoteRefValue('a`b'), '"a`b"');
    });

    test('a space commits typed paths and links like Desktop', () {
      String? typeSpace(String before) => promoteTypedReferenceOnSpace(
        caretAtEnd(before),
        caretAtEnd('$before '),
      )?.text;

      expect(typeSpace('see @lib/a.dart'), 'see @file:`lib/a.dart` ');
      expect(typeSpace('@src/'), '@folder:`src` ');
      expect(typeSpace('@url:https://x.io/a'), '@url:`https://x.io/a` ');
      expect(typeSpace('go https://x.io/a.'), 'go @url:`https://x.io/a`. ');
      expect(typeSpace('@alice'), isNull);
      expect(typeSpace('`https://x.io'), isNull);
      expect(typeSpace('@file:`a.dart`'), isNull);
      final formatter = ComposerReferenceFormatter(enabled: () => false);
      expect(
        formatter
            .formatEditUpdate(caretAtEnd('@a/b'), caretAtEnd('@a/b '))
            .text,
        '@a/b ',
      );
    });

    test('complete.path sends word + session and honours -32601', () async {
      var answerUnsupported = false;
      final (client, requests) = await _recordingClient((frame) {
        if (answerUnsupported) return {'__error': -32601};
        return {
          'items': [
            {'text': '@file:lib/main.dart', 'display': 'main.dart'},
          ],
        };
      });
      await client.connect();
      final batch = await client.completePath(
        '@lib/ma',
        runtimeSessionId: 'runtime-t1215',
      );
      expect(requests.last['method'], 'complete.path');
      expect(requests.last['params'], {
        'word': '@lib/ma',
        'session_id': 'runtime-t1215',
      });
      expect(batch.items.single.value, 'lib/main.dart');
      expect(
        DesktopGatewayCapability.values,
        contains(DesktopGatewayCapability.composerPathCompletion),
      );
      answerUnsupported = true;
      await expectLater(
        client.completePath('@lib/x', runtimeSessionId: 'runtime-t1215'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      final sent = requests.length;
      // Known unsupported: no further frame reaches the server.
      await expectLater(
        client.completePath('@lib/y', runtimeSessionId: 'runtime-t1215'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(requests, hasLength(sent));
    });
  });

  group('large paste', () {
    TextEditingValue at(String text, [int? caret]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    );

    test('Desktop threshold, file name and size label', () {
      expect(shouldConvertPasteToAttachment('x' * 3000), isFalse);
      expect(shouldConvertPasteToAttachment('x' * 3001), isTrue);
      final name = pastedContentFileName(now: DateTime.utc(2026, 10, 3, 9, 5));
      expect(name, startsWith('pasted_content_2026-10-03_09-05-00-000_'));
      expect(isPastedContentName(name), isTrue);
      expect(isPastedContentName('notes.txt'), isFalse);
      expect(pasteSizeLabel('a' * 2048), '2.0 KB');
    });

    test('the formatter keeps the field and hands over the paste', () {
      final pasted = <String>[];
      var enabled = true;
      final formatter = LargePasteFormatter(
        enabled: () => enabled,
        onLargePaste: pasted.add,
      );
      final big = 'y' * 3500;
      final before = at('hi there', 3);
      final result = formatter.formatEditUpdate(
        before,
        at('hi ${big}there', 3 + big.length),
      );
      expect(result, before);
      expect(pasted, [big]);

      final small = at('hi ${'y' * 10}there');
      expect(formatter.formatEditUpdate(before, small), small);

      enabled = false;
      final inline = at('hi ${big}there');
      expect(formatter.formatEditUpdate(before, inline), inline);
      expect(pasted, hasLength(1));
      expect(insertedChunk(at('abc'), at('aXYbc')), 'XY');
    });
  });
}
