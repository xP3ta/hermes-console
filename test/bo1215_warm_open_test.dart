import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/services/mission_snapshot_prewarm.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bot_chat_title_lookup.dart';
import 'support/spec070_fixtures.dart';

final _connection = SavedConnection(
  id: 'bo1215-warm-open',
  label: 'Warm open',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

/// Every server read waits on [network] until the test releases it, so the
/// first frame provably paints without any read having answered.
final class _HeldServer {
  Completer<void> network = Completer<void>();
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final calls = <String>[];
  var answered = 0;

  int count(String read) => calls.where((call) => call == read).length;

  Future<T> _read<T>(String name, T value) async {
    calls.add(name);
    await network.future;
    answered++;
    return value;
  }

  void sessionsChanged() => _events.add(
    const TuiGatewayEvent(type: 'sessions.changed', sessionId: '', payload: {}),
  );

  MissionControlRepository repository() => MissionControlRepository(
    profilesLoader: () => _read('profiles.list', spec070Profiles()),
    sessionsLoader: () => _read('sessions', const []),
    boardLoader: () =>
        _read('kanban.board', const KanbanBoard(columns: <KanbanColumn>[])),
    // Change events announced and the socket up: 4a9e546's policy, where
    // the 30 s tick no longer reloads and sessions.changed drives the roster.
    liveChanges: () => _events.stream,
    liveChangesAvailable: () => true,
  );

  void close() => unawaited(_events.close());
}

MissionBackendSnapshot _lastSeen() => MissionBackendSnapshot(
  profiles: spec070Profiles(),
  profilesCapability: MissionCapabilityState.available,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
  board: const KanbanBoard(columns: <KanbanColumn>[]),
  loadedAt: DateTime(2026),
);

Finder get _rosterLines => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('roster-line-'),
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget _host(
  ConnectionManager manager,
  MissionControlDataSource source,
  MissionSnapshotCache cache,
) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: MissionControlScreen(
    connection: _connection,
    connManager: manager,
    dataSource: source,
    snapshotCache: cache,
    prewarm: MissionSnapshotPrewarm(cache: cache),
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

  testWidgets(
    'warm open with live change events: first frame is the roster, no '
    'spinner, and it still refreshes in the background',
    (tester) async {
      final manager = await _manager();
      final server = _HeldServer();
      addTearDown(server.close);
      final cache = MissionSnapshotCache()..write(_connection, _lastSeen());

      await tester.pumpWidget(_host(manager, server.repository(), cache));

      // First frame: painted from the snapshot with no read answered.
      expect(server.answered, 0, reason: 'nothing awaited before paint');
      expect(_rosterLines, findsWidgets);
      expect(find.text('Reading team state…'), findsNothing);
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'a warm open revalidates quietly, like Desktop',
      );
      // The background revalidation is already on the wire.
      expect(server.count('profiles.list'), 1);
      expect(server.count('kanban.board'), 1);

      // It stays quiet while the server takes its time.
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      server.network.complete();
      await tester.pump();
      await tester.pump();
      expect(_rosterLines, findsWidgets);

      // The change-event policy is in charge: a quiet 30 s tick reads
      // nothing, and sessions.changed refreshes the roster at once.
      server.calls.clear();
      await _idle(tester, const Duration(seconds: 31));
      expect(server.calls, isEmpty, reason: 'no 30 s full reload');
      server.sessionsChanged();
      await tester.pump();
      expect(server.count('profiles.list'), 1);
      expect(server.count('kanban.board'), 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a cold open still says it is reading the team', (tester) async {
    final manager = await _manager();
    final server = _HeldServer();
    addTearDown(server.close);
    await tester.pumpWidget(
      _host(manager, server.repository(), MissionSnapshotCache()),
    );
    expect(find.text('Reading team state…'), findsOneWidget);
    server.network.complete();
    await tester.pump();
    await tester.pump();
    expect(_rosterLines, findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refresh the user asked for still shows its spinner', (
    tester,
  ) async {
    final manager = await _manager();
    final server = _HeldServer();
    addTearDown(server.close);
    final cache = MissionSnapshotCache()..write(_connection, _lastSeen());
    await tester.pumpWidget(_host(manager, server.repository(), cache));
    server.network.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    server.network = Completer<void>();
    final pull = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator).first,
    );
    unawaited(pull.show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    server.network.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
