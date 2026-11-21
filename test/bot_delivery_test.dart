// `bot_delivery.list` (Hermes `tui_gateway/methods_bot_relay.py`) and the
// «Waiting on teammates» strip above a bot's Bot Chat composer (Desktop
// `plugins/hermes-bots/teammate-waits.tsx`): the request frame, every
// delivery state as the user sees it, the refresh policy, and a gateway that
// predates the method (no strip, no error).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_delivery.dart';
import 'package:hermes_android/core/bots/state/bot_delivery_watch.dart';
import 'package:hermes_android/core/bots/ui/teammate_waits_strip.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final DateTime _now = DateTime.utc(2026, 11, 20, 12);

Map<String, dynamic> _wire(
  String id,
  String state, {
  String target = 'bob',
  String handle = '',
  int ageSeconds = 300,
  String preview = 'write the report',
  String? waitingOn,
  String? reason,
  String? error,
}) => {
  'delivery_id': id,
  'target': target,
  'target_handle': handle,
  'state': state,
  'since': _now.millisecondsSinceEpoch / 1000 - ageSeconds,
  'preview': preview,
  'waiting_on': waitingOn,
  'reason': reason,
  'error': error,
};

BotDelivery _row(
  String id,
  String state, {
  String target = 'bob',
  String handle = '',
  int ageSeconds = 300,
  String? waitingOn,
  String? reason,
  String? error,
}) => BotDelivery.tryParse(
  _wire(
    id,
    state,
    target: target,
    handle: handle,
    ageSeconds: ageSeconds,
    waitingOn: waitingOn,
    reason: reason,
    error: error,
  ),
)!;

final class _DashboardTicket extends DashboardClient {
  _DashboardTicket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
}

/// A loopback `/api/ws` that records every request frame and answers the
/// ones [answer] knows; [answer] returns `{'result': …}` or `{'error': …}`.
final class _Server {
  _Server._(this.http, this.answer) {
    http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-1'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        final method = frame['method'];
        if (method is! String) continue;
        final params = (frame['params'] as Map?)?.cast<String, dynamic>() ?? {};
        final reply =
            answer(method, params) ??
            switch (method) {
              'client.capabilities' => {
                'result': {
                  'server_requests': ['approval'],
                },
              },
              'gateway.capabilities' => {
                'result': {'per_session_exclusive_submit': true},
              },
              _ => {
                'result': {'status': 'ok'},
              },
            };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], ...reply}),
        );
      }
    });
  }

  final HttpServer http;
  final Map<String, dynamic>? Function(String method, Map<String, dynamic> p)
  answer;
  final frames = <Map<String, dynamic>>[];

  static Future<_Server> start(
    Map<String, dynamic>? Function(String method, Map<String, dynamic> p)
    answer,
  ) async => _Server._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    answer,
  );

  List<Map<String, dynamic>> framesOf(String method) =>
      frames.where((frame) => frame['method'] == method).toList();
}

Future<TuiGatewayClient> _client(_Server server) async {
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'conn-bot-delivery',
      label: 'bot delivery',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:${server.http.port}',
    ),
    dashboard: _DashboardTicket(),
  );
  addTearDown(() async {
    await client.close();
    await server.http.close(force: true);
  });
  await client.connect();
  return client;
}

final class _FakeGateway implements BotDeliveryGateway {
  final profiles = <String>[];
  List<BotDelivery> rows = const [];
  Object? failure;

  @override
  Future<List<BotDelivery>> listBotDeliveries(String profile) async {
    profiles.add(profile);
    final error = failure;
    if (error != null) throw error;
    return rows;
  }
}

final class _MemoryDismissals implements BotDeliveryDismissals {
  _MemoryDismissals([Set<String> initial = const {}]) : stored = {...initial};

  Set<String> stored;

  @override
  Future<Set<String>> load() async => {...stored};

  @override
  Future<void> save(Set<String> ids) async => stored = {...ids};
}

const _methodNotFound = TuiGatewayRpcError(
  'bot_delivery.list',
  'method not found',
  code: -32601,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('model', () {
    test('every wire state parses with its fields', () {
      final row = BotDelivery.tryParse(
        _wire(
          'd1',
          'waiting_on_you',
          target: 'bob',
          handle: '@bob',
          waitingOn: 'approval',
        ),
      )!;
      expect(row.deliveryId, 'd1');
      expect(row.target, 'bob');
      expect(row.targetHandle, '@bob');
      expect(row.state, BotDeliveryState.waitingOnYou);
      expect(row.waitingOn, 'approval');
      expect(row.preview, 'write the report');
      for (final state in BotDeliveryState.values) {
        expect(
          BotDelivery.tryParse(_wire('x', state.wire))!.state,
          state,
          reason: state.wire,
        );
      }
    });

    test('a row this build cannot show is left out', () {
      expect(BotDelivery.tryParse(_wire('x', 'teleporting')), isNull);
      expect(BotDelivery.tryParse(_wire('', 'queued')), isNull);
      expect(BotDelivery.tryParse(_wire('x', 'queued', target: '')), isNull);
      expect(
        BotDelivery.tryParse({..._wire('x', 'queued'), 'since': 'now'}),
        isNull,
      );
      expect(BotDelivery.tryParse('queued'), isNull);
    });

    test('only a failed unknown_outcome row is an unknown outcome', () {
      expect(
        _row('a', 'failed', reason: 'unknown_outcome').isUnknownOutcome,
        isTrue,
      );
      expect(
        _row('b', 'failed', reason: 'delivery_timeout').isUnknownOutcome,
        isFalse,
      );
      expect(
        _row('c', 'working', reason: 'unknown_outcome').isUnknownOutcome,
        isFalse,
      );
    });

    test('the age is the coarsest unit, floored', () {
      String age(num seconds) => compactDeliveryAge(
        _now.millisecondsSinceEpoch / 1000 - seconds,
        _now,
      );
      expect(age(42.9), '42s');
      expect(age(300), '5m');
      expect(age(3 * 3600 + 59), '3h');
      expect(age(2 * 86400 + 5), '2d');
      expect(age(-30), '0s', reason: 'a clock ahead of the gateway');
    });
  });

  group('wire', () {
    test('the request names the sender bot and nothing else', () async {
      final server = await _Server.start(
        (method, params) => method == 'bot_delivery.list'
            ? {
                'result': {
                  'sender': 'ana',
                  'deliveries': [
                    _wire('d1', 'queued', target: 'bob'),
                    _wire('d2', 'failed', reason: 'provider_quota_limit'),
                    _wire('d3', 'teleporting'),
                  ],
                },
              }
            : null,
      );
      final client = await _client(server);

      final rows = await client.listBotDeliveries(' ana ');

      final frames = server.framesOf('bot_delivery.list');
      expect(frames, hasLength(1));
      expect(frames.single['params'], {'profile': 'ana'});
      expect(rows.map((r) => r.deliveryId), ['d1', 'd2']);
      expect(rows.last.state, BotDeliveryState.failed);
    });

    test('a profile that is not a profile name sends no frame', () async {
      final server = await _Server.start((_, _) => null);
      final client = await _client(server);

      await expectLater(
        client.listBotDeliveries('../x'),
        throwsA(isA<FormatException>()),
      );

      expect(server.framesOf('bot_delivery.list'), isEmpty);
    });

    test('an older gateway answers method not found, typed', () async {
      final server = await _Server.start(
        (method, _) => method == 'bot_delivery.list'
            ? {
                'error': {'code': -32601, 'message': 'method not found'},
              }
            : null,
      );
      final client = await _client(server);

      Object? caught;
      try {
        await client.listBotDeliveries('ana');
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<TuiGatewayRpcError>());
      expect(isBotDeliveryUnsupported(caught!), isTrue);
      expect((caught as TuiGatewayRpcError).code, -32601);
    });

    test('another failure is not an unsupported gateway', () {
      expect(
        isBotDeliveryUnsupported(
          const TuiGatewayRpcError('bot_delivery.list', 'storage', code: 5096),
        ),
        isFalse,
      );
      expect(isBotDeliveryUnsupported(TimeoutException('slow')), isFalse);
    });

    test('an answer without a list is an error, not no rows', () async {
      final server = await _Server.start(
        (method, _) => method == 'bot_delivery.list'
            ? {
                'result': {'sender': 'ana'},
              }
            : null,
      );
      final client = await _client(server);

      await expectLater(
        client.listBotDeliveries('ana'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
    });
  });

  group('dismissals', () {
    test('survive a restart', () async {
      SharedPreferences.setMockInitialValues({});
      await const PrefsBotDeliveryDismissals().save({'b', 'a'});
      expect(await const PrefsBotDeliveryDismissals().load(), {'a', 'b'});
    });

    test('one bot pruning its settled failures keeps the other bots\' '
        'dismissals', () async {
      SharedPreferences.setMockInitialValues({});
      final ana = _FakeGateway()..rows = [_row('a1', 'failed')];
      final anaWatch = BotDeliveryWatch(gateway: () => ana, profile: 'ana');
      addTearDown(anaWatch.dispose);
      await anaWatch.refresh();
      await anaWatch.dismiss('a1');

      // Another bot's chat opens: its list has none of ana's deliveries.
      final bob = _FakeGateway()..rows = [_row('b1', 'failed')];
      final bobWatch = BotDeliveryWatch(gateway: () => bob, profile: 'bob');
      addTearDown(bobWatch.dispose);
      await bobWatch.refresh();
      await bobWatch.dismiss('b1');
      bob.rows = const [];
      await bobWatch.refresh();

      expect(
        await const PrefsBotDeliveryDismissals(profile: 'ana').load(),
        {'a1'},
      );
      final again = BotDeliveryWatch(gateway: () => ana, profile: 'ana');
      addTearDown(again.dispose);
      await again.refresh();
      expect(again.rows, isEmpty, reason: 'the dismissed failure stays out');
    });

    test('a dismissal stored by an earlier version is still honoured', () async {
      SharedPreferences.setMockInitialValues({
        PrefsBotDeliveryDismissals.key: '["old"]',
      });
      expect(
        await const PrefsBotDeliveryDismissals(profile: 'ana').load(),
        {'old'},
      );
    });

    test('a damaged value is an empty set', () async {
      SharedPreferences.setMockInitialValues({
        PrefsBotDeliveryDismissals.key: '{not json',
      });
      expect(await const PrefsBotDeliveryDismissals().load(), isEmpty);
    });
  });

  group('strip', () {
    late _FakeGateway gateway;
    late _MemoryDismissals store;
    late BotDeliveryWatch watch;
    late List<String> opened;

    Widget host() => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: TeammateWaitsStrip(
            watch: watch,
            onOpenTeammate: opened.add,
          ),
        ),
      ),
    );

    Future<void> mount(
      WidgetTester tester, {
      Set<String> dismissed = const {},
    }) async {
      store = _MemoryDismissals(dismissed);
      watch = BotDeliveryWatch(
        gateway: () => gateway,
        profile: 'ana',
        clock: () => _now,
        dismissals: store,
      );
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.pump();
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      watch.dispose();
    }

    Future<void> elapse(WidgetTester tester, Duration by) async {
      await tester.pump(by);
      await tester.pump();
      await tester.pump();
    }

    setUp(() {
      gateway = _FakeGateway();
      opened = [];
    });

    testWidgets('asks for the sender bot as soon as it is on screen', (
      tester,
    ) async {
      gateway.rows = [_row('d1', 'queued')];
      await mount(tester);
      expect(gateway.profiles, ['ana']);
      await unmount(tester);
    });

    testWidgets('a chat covered by another route stops asking, and asks at '
        'once when it is back on top', (tester) async {
      gateway.rows = [_row('d1', 'queued')];
      await mount(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => const Scaffold(body: Text('teammate')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final asked = gateway.profiles.length;

      await elapse(tester, const Duration(seconds: 30));
      expect(
        gateway.profiles,
        hasLength(asked),
        reason: 'nobody is looking at the covered chat',
      );

      navigator.pop();
      await tester.pump();
      await tester.pump();
      expect(gateway.profiles, hasLength(asked + 1));
      await elapse(tester, const Duration(seconds: 5));
      expect(gateway.profiles, hasLength(asked + 2), reason: 'polling again');
      await unmount(tester);
    });

    testWidgets('each delivery state says where the delivery stands', (
      tester,
    ) async {
      gateway.rows = [
        _row('q', 'queued', target: 'q-bot', handle: '@q-bot'),
        _row('c', 'claimed', target: 'c-bot', ageSeconds: 7200),
        _row('w', 'working', target: 'w-bot', ageSeconds: 42),
        _row(
          'wa',
          'waiting_on_you',
          target: 'wa-bot',
          waitingOn: 'approval',
        ),
        _row(
          'wc',
          'waiting_on_you',
          target: 'wc-bot',
          waitingOn: 'clarify',
          ageSeconds: 3 * 86400,
        ),
        _row('f1', 'failed', target: 'f1-bot', reason: 'provider_quota_limit'),
        _row(
          'f2',
          'failed',
          target: 'f2-bot',
          reason: 'something_new',
          error: ' provider said no ',
        ),
        _row('f3', 'failed', target: 'f3-bot', reason: 'unknown'),
        _row('f4', 'failed', target: 'f4-bot', reason: 'unknown_outcome'),
      ];
      await mount(tester);

      expect(find.text('Waiting on teammates'), findsOneWidget);
      expect(find.text('@q-bot'), findsOneWidget, reason: 'the handle');
      expect(find.text('c-bot'), findsOneWidget, reason: 'else the target');
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('Picked up'), findsOneWidget);
      expect(find.text('Working on it'), findsOneWidget);
      expect(
        find.text('Waiting on you — approve or deny'),
        findsOneWidget,
      );
      expect(
        find.text('Waiting on you — answer its question'),
        findsOneWidget,
      );
      expect(
        find.text('Failed: its provider is out of credits'),
        findsOneWidget,
        reason: 'a typed reason in plain words',
      );
      expect(
        find.text('Failed: provider said no'),
        findsOneWidget,
        reason: 'a code with no words shows the owner line, never the code',
      );
      expect(find.textContaining('something_new'), findsNothing);
      expect(
        find.text('Failed: unknown error'),
        findsOneWidget,
        reason: 'unknown with no owner line',
      );
      expect(find.text('Outcome unknown'), findsOneWidget);
      expect(find.text('2h'), findsOneWidget);
      expect(find.text('42s'), findsOneWidget);
      expect(find.text('3d'), findsOneWidget);
      expect(
        find.textContaining('Nothing here is ever resent'),
        findsOneWidget,
        reason: 'the unknown outcome carries the do-not-resend rule',
      );
      expect(find.byTooltip('Dismiss'), findsNWidgets(4), reason: 'failures');
      expect(find.text('Open'), findsNWidgets(9));
      await unmount(tester);
    });

    testWidgets('a strip without an unknown outcome has no resend rule', (
      tester,
    ) async {
      gateway.rows = [
        _row('f1', 'failed', reason: 'delivery_timeout'),
        _row('w', 'working'),
      ];
      await mount(tester);
      expect(find.text('Failed: timed out'), findsOneWidget);
      expect(find.textContaining('Nothing here is ever resent'), findsNothing);
      await unmount(tester);
    });

    testWidgets('no deliveries, no strip', (tester) async {
      gateway.rows = const [];
      await mount(tester);
      expect(find.byKey(const ValueKey('teammate-waits')), findsNothing);
      await unmount(tester);
    });

    testWidgets('a gateway without the method shows nothing, asks once and '
        'raises nothing', (tester) async {
      gateway.failure = _methodNotFound;
      await mount(tester);
      await elapse(tester, const Duration(seconds: 30));
      expect(find.byKey(const ValueKey('teammate-waits')), findsNothing);
      expect(find.text('Waiting on teammates'), findsNothing);
      expect(gateway.profiles, ['ana'], reason: 'it does not keep asking');
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('asks again every five seconds and follows the answer', (
      tester,
    ) async {
      gateway.rows = [_row('d1', 'queued')];
      await mount(tester);
      expect(find.text('Queued'), findsOneWidget);

      await elapse(tester, const Duration(seconds: 4));
      expect(gateway.profiles, hasLength(1));

      gateway.rows = [_row('d1', 'working')];
      await elapse(tester, const Duration(seconds: 1));
      expect(gateway.profiles, hasLength(2));
      expect(find.text('Working on it'), findsOneWidget);
      expect(find.text('Queued'), findsNothing);

      gateway.rows = const [];
      await elapse(tester, const Duration(seconds: 5));
      expect(gateway.profiles, hasLength(3));
      expect(find.byKey(const ValueKey('teammate-waits')), findsNothing);
      await unmount(tester);
    });

    testWidgets('a failed poll keeps the last rows, greyed and labelled', (
      tester,
    ) async {
      gateway.rows = [_row('d1', 'working')];
      await mount(tester);
      expect(find.byKey(const ValueKey('teammate-waits-stale')), findsNothing);

      gateway.failure = const TuiGatewayRpcError(
        'bot_delivery.list',
        'timed out',
        failureKind: TuiGatewayRpcFailureKind.connectionLost,
      );
      await elapse(tester, const Duration(seconds: 5));

      expect(find.text('Working on it'), findsOneWidget);
      expect(
        find.text("Couldn't refresh — showing the last known state."),
        findsOneWidget,
      );
      final rows = find.byKey(const ValueKey('teammate-waits-rows'));
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: rows, matching: find.byType(Opacity)).first,
            )
            .opacity,
        lessThan(1),
      );

      gateway.failure = null;
      await elapse(tester, const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('teammate-waits-stale')), findsNothing);
      expect(find.text('Working on it'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Open fronts the chat of that teammate', (tester) async {
      gateway.rows = [
        _row('d1', 'working', target: 'bob'),
        _row('d2', 'queued', target: 'carol'),
      ];
      await mount(tester);

      await tester.tap(find.text('Open').last);
      await tester.pump();

      expect(opened, ['carol']);
      await unmount(tester);
    });

    testWidgets('Dismiss hides a failure for good, and only a failure', (
      tester,
    ) async {
      gateway.rows = [
        _row('f1', 'failed', reason: 'provider_quota_limit'),
        _row('w1', 'working'),
      ];
      await mount(tester);
      expect(find.byTooltip('Dismiss'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Failed'), findsNothing);
      expect(find.text('Working on it'), findsOneWidget);
      expect(store.stored, {'f1'});

      // The same failure on the next answer stays hidden.
      await elapse(tester, const Duration(seconds: 5));
      expect(find.textContaining('Failed'), findsNothing);

      // Once it leaves the gateway's window its dismissal is forgotten.
      gateway.rows = [_row('w1', 'working')];
      await elapse(tester, const Duration(seconds: 5));
      expect(store.stored, isEmpty);
      await unmount(tester);
    });

    testWidgets('a dismissal from an earlier run is still honoured', (
      tester,
    ) async {
      gateway.rows = [
        _row('f1', 'failed', reason: 'provider_quota_limit'),
        _row('f2', 'failed', reason: 'delivery_timeout'),
      ];
      await mount(tester, dismissed: {'f1'});
      expect(find.text('Failed: its provider is out of credits'), findsNothing);
      expect(find.text('Failed: timed out'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a backgrounded app stops asking and asks again on return', (
      tester,
    ) async {
      gateway.rows = [_row('d1', 'working')];
      await mount(tester);
      expect(gateway.profiles, hasLength(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await elapse(tester, const Duration(seconds: 30));
      expect(gateway.profiles, hasLength(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(gateway.profiles, hasLength(2));

      await elapse(tester, const Duration(seconds: 5));
      expect(gateway.profiles, hasLength(3));
      await unmount(tester);
    });

    testWidgets('a chat with no gateway yet asks nothing and shows nothing', (
      tester,
    ) async {
      store = _MemoryDismissals();
      watch = BotDeliveryWatch(
        gateway: () => null,
        profile: 'ana',
        clock: () => _now,
        dismissals: store,
      );
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('teammate-waits')), findsNothing);
      expect(gateway.profiles, isEmpty);
      await unmount(tester);
    });
  });
}
