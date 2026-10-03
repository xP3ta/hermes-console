import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
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

  /// What `profiles.list` answers now; a read returns the list current when
  /// it was asked, so a read on the wire before a change misses it.
  List<AgentProfile> profiles = spec070Profiles();

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
    profilesLoader: () => _read('profiles.list', profiles),
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

/// [_HeldServer]'s repository whose full load can be made to fail, to reach
/// the screen's failed-load path while the roster reads keep working.
final class _FailingFullLoad
    implements MissionControlDataSource, MissionLiveRefreshDataSource {
  _FailingFullLoad(this.inner);

  final MissionControlRepository inner;
  bool failFullLoad = false;

  @override
  Future<MissionBackendSnapshot> load() async {
    final snapshot = await inner.load();
    if (failFullLoad) throw StateError('full load failed');
    return snapshot;
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) =>
      inner.watchKanban(since: since);

  @override
  void close() => inner.close();

  @override
  Stream<TuiGatewayEvent>? watchLiveChanges() => inner.watchLiveChanges();

  @override
  bool get liveChangesHealthy => inner.liveChangesHealthy;

  @override
  Future<MissionRosterRead> loadRoster() => inner.loadRoster();

  @override
  Future<HostedGroupsSnapshot> refreshHostedGroups(
    HostedGroupsSnapshot previous,
  ) => inner.refreshHostedGroups(previous);
}

/// The roster after a change event: `astra` was replaced by `nova` (same
/// slot, so it is on screen in the lazily built list).
List<AgentProfile> _changedRoster() => [
  for (final profile in spec070Profiles())
    profile.name == 'astra'
        ? AgentProfile.fromJson({
            ...Map<String, dynamic>.from(
              (spec070Result('profiles_list')['profiles'] as List)[1] as Map,
            ),
            'name': 'nova',
          })
        : profile,
];

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

  testWidgets(
    'sessions.changed during the opening refresh is read right after it',
    (tester) async {
      final manager = await _manager();
      final server = _HeldServer();
      addTearDown(server.close);
      final cache = MissionSnapshotCache()..write(_connection, _lastSeen());
      await tester.pumpWidget(_host(manager, server.repository(), cache));
      expect(server.count('profiles.list'), 1);

      // A bot appears while the opening refresh is still on the wire: that
      // read predates the change, so it must not swallow the event.
      server.profiles = _changedRoster();
      server.sessionsChanged();
      await tester.pump();
      server.network.complete();
      await tester.pump();
      await tester.pump();
      expect(
        server.count('profiles.list'),
        2,
        reason: 'roster re-read now, not at the 120 s backstop',
      );
      expect(server.count('kanban.board'), 1, reason: 'only the roster');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('roster-line-nova')),
        findsOneWidget,
        reason: 'the re-read roster must reach the screen',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('sessions.changed during a full load that fails is still read', (
    tester,
  ) async {
    final manager = await _manager();
    final server = _HeldServer();
    addTearDown(server.close);
    server.network.complete();
    final source = _FailingFullLoad(server.repository());
    final cache = MissionSnapshotCache()..write(_connection, _lastSeen());
    await tester.pumpWidget(_host(manager, source, cache));
    await tester.pump();
    await tester.pump();

    // A user refresh over a healthy event stream fails, and a bot appeared
    // while it was on the wire.
    server.network = Completer<void>();
    source.failFullLoad = true;
    final pull = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator).first,
    );
    unawaited(pull.show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    server.profiles = _changedRoster();
    server.sessionsChanged();
    await tester.pump();
    server.network.complete();
    await tester.pump();
    await tester.pump();
    source.failFullLoad = false;
    server.calls.clear();
    expect(find.byKey(const ValueKey('roster-line-nova')), findsNothing);

    // The next roster tick reads it, not the 120 s backstop.
    await _idle(tester, const Duration(seconds: 31));
    expect(server.count('profiles.list'), 1);
    expect(server.count('kanban.board'), 0, reason: 'a roster read');
    await tester.pump();
    expect(find.byKey(const ValueKey('roster-line-nova')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'nothing starts a second read while the quiet revalidation is on the wire',
    (tester) async {
      final manager = await _manager();
      final server = _HeldServer();
      addTearDown(server.close);
      final cache = MissionSnapshotCache()..write(_connection, _lastSeen());
      await tester.pumpWidget(_host(manager, server.repository(), cache));
      expect(server.count('profiles.list'), 1);
      expect(server.count('kanban.board'), 1);

      // A change event and the 30 s tick both land while it is held: the
      // quiet read still excludes every other read, or two answers could
      // land out of order.
      server.sessionsChanged();
      await tester.pump();
      await _idle(tester, const Duration(seconds: 31));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(server.count('profiles.list'), 1, reason: 'no concurrent read');
      expect(server.count('kanban.board'), 1, reason: 'no concurrent read');

      server.network.complete();
      await tester.pump();
      await tester.pump();
      expect(server.count('kanban.board'), 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a pull during the quiet revalidation joins it: one read, the pull ends '
    'with it, and a change seen meanwhile is read once afterwards',
    (tester) async {
      final manager = await _manager();
      final server = _HeldServer();
      addTearDown(server.close);
      final cache = MissionSnapshotCache()..write(_connection, _lastSeen());
      await tester.pumpWidget(_host(manager, server.repository(), cache));
      expect(server.count('profiles.list'), 1);
      expect(server.count('kanban.board'), 1);

      // The user pulls while the opening revalidation is still held.
      final pull = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator).first,
      );
      var pullDone = false;
      unawaited(pull.show().then((_) => pullDone = true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        server.count('kanban.board'),
        1,
        reason: 'the pull must not start a second full read',
      );
      expect(server.count('profiles.list'), 1);
      expect(pullDone, isFalse, reason: 'the pull waits for the read');
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
        reason: 'the user asked, so the joined read is no longer quiet',
      );

      // A bot appears while that single read is on the wire.
      server.profiles = _changedRoster();
      server.sessionsChanged();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(server.count('kanban.board'), 1);
      expect(pullDone, isFalse);

      server.network.complete();
      await tester.pumpAndSettle();
      expect(pullDone, isTrue, reason: 'the pull ends with the joined read');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(server.count('kanban.board'), 1, reason: 'still one full read');
      expect(
        server.count('profiles.list'),
        2,
        reason: 'exactly one follow-up roster read for the change',
      );
      expect(find.byKey(const ValueKey('roster-line-nova')), findsOneWidget);

      // Nothing else trails behind it.
      await tester.pump(const Duration(seconds: 5));
      expect(server.count('profiles.list'), 2);
      expect(server.count('kanban.board'), 1);

      // With nothing on the wire, the next pull reads the server again.
      unawaited(pull.show());
      await tester.pumpAndSettle();
      expect(server.count('kanban.board'), 2, reason: 'a later pull reads');
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
