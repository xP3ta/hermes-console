import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bot_chat_title_lookup.dart';

final _connection = SavedConnection(
  id: 'mission-active',
  label: 'Mission QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

/// The Gateway's global event channel and its health, under test control.
final class FakeChangeFeed {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  var healthy = true;

  Stream<TuiGatewayEvent> get stream => _events.stream;

  void sessionsChanged() => _events.add(
    const TuiGatewayEvent(type: 'sessions.changed', sessionId: '', payload: {}),
  );

  void drop() {
    healthy = false;
    _events.addError(StateError('Hermes Desktop WebSocket closed'));
  }

  void close() => unawaited(_events.close());
}

DesktopActiveSessionList _list(String status, {String title = 'Migrar'}) =>
    DesktopActiveSessionList.fromJson({
      'sessions': [
        {
          'id': 'rt-1',
          'session_key': 'canon-1',
          'status': status,
          'title': title,
          'preview': null,
        },
      ],
    });

/// One bot over a fake socket: counts what reaches the wire, and the
/// `session.active_list` answer is under test control.
final class _Wire {
  final calls = <String>[];
  Future<DesktopActiveSessionList> Function() activeList = () async =>
      const DesktopActiveSessionList();

  int count(String call) => calls.where((c) => c == call).length;

  MissionControlRepository repository({
    FakeChangeFeed? feed,
    bool withActiveList = true,
  }) => MissionControlRepository(
    profilesLoader: () async {
      calls.add('profiles.list');
      return [
        AgentProfile.fromJson({
          'name': 'infra',
          'canonical_session': {'id': 'canon-1', 'title': 'Bot Chat'},
        }),
      ];
    },
    sessionsLoader: () async {
      calls.add('sessions');
      return const [];
    },
    boardLoader: () async {
      calls.add('kanban.board');
      return const KanbanBoard(columns: []);
    },
    activeSessionsLoader: withActiveList
        ? () {
            calls.add('session.active_list');
            return activeList();
          }
        : null,
    liveChanges: feed == null ? null : () => feed.stream,
    liveChangesAvailable: feed == null ? null : () => feed.healthy,
  );
}

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget _host(ConnectionManager manager, MissionControlDataSource source) =>
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: MissionControlScreen(
        connection: _connection,
        connManager: manager,
        dataSource: source,
        botChatTitleLookup: FakeBotChatTitleLookup(),
      ),
    );

Future<void> _idle(WidgetTester tester, Duration span) async {
  for (var elapsed = Duration.zero; elapsed < span;) {
    await tester.pump(const Duration(seconds: 1));
    elapsed += const Duration(seconds: 1);
  }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  group('repository', () {
    test('the full read and the roster read both carry active_list', () async {
      final wire = _Wire()..activeList = () async => _list('working');
      final repository = wire.repository();

      final full = await repository.load();
      expect(wire.count('session.active_list'), 1);
      expect(full.activeSessions.single.storedSessionId, 'canon-1');
      expect(full.activeSessionsObservedAt, isNotNull);

      final roster = await repository.loadRoster();
      expect(wire.count('session.active_list'), 2);
      expect(roster.activeSessions.single.status, 'working');
      expect(roster.activeSessionsObservedAt, isNotNull);
    });

    test(
      'a server without session.active_list answers an authoritative empty',
      () async {
        final wire = _Wire()
          ..activeList = () => Future.error(
            const TuiGatewayRpcError(
              'session.active_list',
              'Method not found',
              code: -32601,
            ),
          );
        final repository = wire.repository();

        final full = await repository.load();
        final roster = await repository.loadRoster();

        expect(full.activeSessions, isEmpty);
        expect(full.activeSessionsAuthoritative, isTrue);
        expect(roster.activeSessionsAuthoritative, isTrue);
        expect(full.failures, isEmpty, reason: 'silent degradation');
        expect(full.profiles, hasLength(1));
      },
    );

    test('a timeout or a cut socket is a failed read, not an absence', () async {
      for (final failure in <Object>[
        TimeoutException('active_list timed out'),
        StateError('Hermes Desktop WebSocket closed'),
        const TuiGatewayRpcError('session.active_list', 'boom', code: -32000),
        // Messages that merely mention a 404 or 405 are not «method not found».
        const TuiGatewayRpcError(
          'session.active_list',
          'HTTP 404 from upstream',
          code: -32000,
        ),
        const TuiGatewayRpcError(
          'session.active_list',
          'http 405 method not allowed',
        ),
        Exception('http 404'),
        // A typed HTTP status is a transient failure too, never an absence.
        const DashboardHttpException(404),
        const DashboardHttpException(405),
      ]) {
        final wire = _Wire()..activeList = () => Future.error(failure);
        final repository = wire.repository();

        final full = await repository.load();
        final roster = await repository.loadRoster();

        expect(full.activeSessionsAuthoritative, isFalse, reason: '$failure');
        expect(full.activeSessionsObservedAt, isNull);
        expect(roster.activeSessionsAuthoritative, isFalse);
        expect(roster.activeSessionsObservedAt, isNull);
        expect(full.failures, isEmpty, reason: 'still no noisy failure');
      }
    });

    test(
      'an empty answer is authoritative and sealed with its read time',
      () async {
        final wire = _Wire();
        final repository = wire.repository();

        final full = await repository.load();

        expect(full.activeSessions, isEmpty);
        expect(full.activeSessionsAuthoritative, isTrue);
        expect(full.activeSessionsObservedAt, isNotNull);
      },
    );

    test('a source without the loader reads nothing extra', () async {
      final wire = _Wire();
      final repository = wire.repository(withActiveList: false);

      final full = await repository.load();

      expect(full.activeSessions, isEmpty);
      expect(wire.count('session.active_list'), 0);
    });
  });

  group('screen', () {
    testWidgets(
      'idle: one active_list per roster read and no timer of its own',
      (tester) async {
        final manager = await _manager();
        final wire = _Wire()..activeList = () async => _list('working');
        final feed = FakeChangeFeed();
        addTearDown(feed.close);
        await tester.pumpWidget(_host(manager, wire.repository(feed: feed)));
        await tester.pump();
        await tester.pump();

        await _idle(tester, const Duration(minutes: 5));

        // Roster reads that existed before: the opening one and the 120 s
        // backstop reloads. Every one of them now carries the active list.
        expect(wire.count('profiles.list'), greaterThanOrEqualTo(3));
        expect(
          wire.count('session.active_list'),
          wire.count('profiles.list'),
          reason: 'active_list rides the existing reads, never its own cadence',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('sessions.changed adds exactly one active_list', (
      tester,
    ) async {
      final manager = await _manager();
      final wire = _Wire();
      final feed = FakeChangeFeed();
      addTearDown(feed.close);
      await tester.pumpWidget(_host(manager, wire.repository(feed: feed)));
      await tester.pump();
      await tester.pump();
      await _idle(tester, const Duration(seconds: 31));
      wire.calls.clear();

      feed.sessionsChanged();
      await tester.pump();
      await tester.pump();

      expect(wire.count('profiles.list'), 1);
      expect(wire.count('session.active_list'), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a bot working in a chat Console has not opened says so', (
      tester,
    ) async {
      final manager = await _manager();
      final wire = _Wire()..activeList = () async => _list('working');
      await tester.pumpWidget(_host(manager, wire.repository()));
      await tester.pump();
      await tester.pump();

      expect(find.text('Trabajando · Migrar'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a pending question reads as waiting for you', (tester) async {
      final manager = await _manager();
      final wire = _Wire()
        ..activeList = () async => _list('waiting', title: 'Desplegar');
      await tester.pumpWidget(_host(manager, wire.repository()));
      await tester.pump();
      await tester.pump();

      expect(find.text('Esperando tu respuesta · Desplegar'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed active_list keeps the last confirmed activity', (
      tester,
    ) async {
      final manager = await _manager();
      final wire = _Wire()..activeList = () async => _list('working');
      final feed = FakeChangeFeed();
      addTearDown(feed.close);
      await tester.pumpWidget(_host(manager, wire.repository(feed: feed)));
      await tester.pump();
      await tester.pump();
      expect(find.text('Trabajando · Migrar'), findsOneWidget);

      // The roster refresh after sessions.changed times out on active_list.
      wire.activeList = () => Future.error(TimeoutException('timed out'));
      await _idle(tester, const Duration(seconds: 31));
      feed.sessionsChanged();
      await tester.pump();
      await tester.pump();
      expect(find.text('Trabajando · Migrar'), findsOneWidget);

      // A full reload that fails the same way keeps it too.
      await _idle(tester, const Duration(seconds: 125));
      expect(find.text('Trabajando · Migrar'), findsOneWidget);

      // Only an answer, even an empty one, ends it.
      wire.activeList = () async => const DesktopActiveSessionList();
      await _idle(tester, const Duration(seconds: 125));
      expect(find.text('Trabajando · Migrar'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an answer that lands after the screen is gone does nothing', (
      tester,
    ) async {
      final manager = await _manager();
      final gate = Completer<DesktopActiveSessionList>();
      final wire = _Wire()..activeList = () => gate.future;
      await tester.pumpWidget(_host(manager, wire.repository()));
      await tester.pump();
      expect(wire.count('session.active_list'), 1);

      await tester.pumpWidget(const SizedBox());
      gate.complete(_list('working'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a read from before a socket drop cannot bring the old state back',
      (tester) async {
        final manager = await _manager();
        final wire = _Wire()..activeList = () async => _list('working');
        final feed = FakeChangeFeed();
        addTearDown(feed.close);
        await tester.pumpWidget(_host(manager, wire.repository(feed: feed)));
        await tester.pump();
        await tester.pump();
        expect(find.text('Trabajando · Migrar'), findsOneWidget);

        // A roster refresh starts and its active_list answer is held back.
        final stale = Completer<DesktopActiveSessionList>();
        wire.activeList = () => stale.future;
        await _idle(tester, const Duration(seconds: 31));
        feed.sessionsChanged();
        await tester.pump();

        // The socket drops; the first event after it reloads everything, and
        // the turn has ended by then.
        feed.drop();
        await tester.pump(const Duration(seconds: 5));
        wire.activeList = () async => const DesktopActiveSessionList();
        feed.healthy = true;
        feed.sessionsChanged();
        await tester.pump();
        await tester.pump();
        expect(find.text('Trabajando · Migrar'), findsNothing);

        // The pre-drop answer finally arrives: it must not repaint «working».
        stale.complete(_list('working'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Trabajando · Migrar'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
