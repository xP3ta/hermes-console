// Renders the Home widget board for design review. Writes PNGs to
// build/home-widgets only with --dart-define=HOME_RENDER=true; otherwise it
// is a plain layout test that fails on overflow.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_store.dart';
import 'package:hermes_android/core/home/home_feed_cache.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/account_usage_fixtures.dart';
import '../support/design_shots.dart' show loadDesignFonts;
import '../support/in_memory_compression_restore_storage.dart';
import '../support/spec070_fixtures.dart';

final _clock = DateTime.now().copyWith(hour: 16, minute: 30, second: 0);
double _ago(Duration d) => _clock.subtract(d).millisecondsSinceEpoch / 1000;

Session _session(
  String id,
  String title, {
  Duration ago = const Duration(hours: 3),
  bool? unread,
  String? reply,
  int messages = 6,
  int tools = 3,
}) => Session.fromJson({
  'id': id,
  'title': title,
  'model': 'hermes-agent',
  'source': 'mobile',
  'message_count': messages,
  'tool_call_count': tools,
  'is_active': false,
  'preview': reply ?? '',
  'last_assistant_preview': ?reply,
  'started_at': _ago(ago),
  'unread': ?unread,
});

class _Client extends ApiClient {
  _Client(this.sessions)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );
  final List<Session> sessions;
  @override
  Future<bool> healthCheck() async => true;
  @override
  Future<bool> healthReachable() => healthCheck();
  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => List.of(sessions);
  @override
  void close() {}
}

Map<String, dynamic> _event(
  String room,
  int seq,
  String kind,
  Map<String, dynamic> actor,
  Map<String, dynamic> payload,
  Duration ago,
) => {
  'room_id': room,
  'seq': seq,
  'event_id': '$room-$seq',
  'kind': kind,
  'actor': actor,
  'authority_epoch': 2,
  'payload': payload,
  'created_at': _clock.subtract(ago).millisecondsSinceEpoch / 1000,
  'idempotent': false,
};

const _user = {'kind': 'user', 'id': 'desktop'};
const _gw = {'kind': 'gateway', 'id': 'gw-home-1'};
Map<String, dynamic> _member(String id) => {
  'kind': 'member',
  'id': 'member-$id',
  'profile': id,
  'display_name': id[0].toUpperCase() + id.substring(1),
};

HostedGroupRoom _room(String id, String name) {
  final json =
      jsonDecode(jsonEncode(spec070Result('groups_state')['room']))
          as Map<String, dynamic>;
  json['room_id'] = id;
  json['name'] = name;
  return HostedGroupRoom.fromJson(json);
}

HostedGroupLogPage _log(String room, List<Map<String, dynamic>> events) =>
    HostedGroupLogPage.fromJson(
      {
        'events': events,
        'cursor': events.length,
        'latest_seq': events.length,
        'has_more': false,
        'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
      },
      expectedRoomId: room,
      sinceSeq: 0,
    );

HostedGroupsSnapshot _richGroups() {
  final devs = [
    _event('room-devs', 1, 'message.user', _user, {
      'text': '@astra @radar revisad la PR del login',
      'thread_id': 't1',
    }, const Duration(minutes: 40)),
    _event('room-devs', 2, 'message.member', _member('astra'), {
      'text': 'Revisada: dos comentarios menores, nada bloqueante.',
      'member_id': 'member-astra',
      'discussion_event_id': 'room-devs-1',
      'thread_id': 't1',
    }, const Duration(minutes: 31)),
    _event('room-devs', 3, 'message.member', _member('radar'), {
      'text': 'Tests en verde en Android y Web.',
      'member_id': 'member-radar',
      'discussion_event_id': 'room-devs-1',
      'thread_id': 't1',
    }, const Duration(minutes: 12)),
    _event('room-devs', 4, 'turn.started', _gw, {
      'discussion_event_id': 'room-devs-1',
      'member_id': 'member-astra',
      'member_index': 0,
      'round_index': 1,
      'task_id': 'task-a2',
      'thread_id': 't1',
      'turn_id': 'turn-a2',
    }, const Duration(seconds: 20)),
  ];
  final ops = [
    _event('room-ops', 1, 'message.user', _user, {
      'text': '¿Cómo va la copia del NAS?',
      'thread_id': 't2',
    }, const Duration(hours: 2)),
    _event('room-ops', 2, 'message.member', _member('radar'), {
      'text': 'Copia completada: 214 GB, sin errores.',
      'member_id': 'member-radar',
      'thread_id': 't2',
    }, const Duration(hours: 1)),
    _event('room-ops', 3, 'message.member', _member('astra'), {
      'text': 'Dejo programada la verificación para las 03:00.',
      'member_id': 'member-astra',
      'thread_id': 't2',
    }, const Duration(minutes: 50)),
  ];
  return HostedGroupsSnapshot(
    capabilities: spec070Capabilities(),
    rooms: [
      _room('room-devs', 'Console Devs'),
      _room('room-ops', 'Ops nocturno'),
    ],
    logs: [_log('room-devs', devs), _log('room-ops', ops)],
  );
}

List<CronJob> _cron() => [
  CronJob.fromJson({
    'id': 'daily',
    'name': 'Resumen diario',
    'last_status': 'ok',
    'last_run_at': _clock.subtract(const Duration(hours: 22)).toIso8601String(),
    'next_run_at': _clock
        .add(const Duration(hours: 2, minutes: 30))
        .toIso8601String(),
  }),
  CronJob.fromJson({
    'id': 'nas',
    'name': 'Copia del NAS',
    'last_status': 'ok',
    'last_run_at': _clock.subtract(const Duration(hours: 14)).toIso8601String(),
    'next_run_at': _clock
        .add(const Duration(hours: 9, minutes: 30))
        .toIso8601String(),
  }),
  CronJob.fromJson({
    'id': 'deps',
    'name': 'Revisar dependencias',
    'last_status': 'error',
    'last_run_at': _clock.subtract(const Duration(hours: 3)).toIso8601String(),
  }),
];

List<Session> _sessions() => [
  _session(
    'plan',
    'Plan de marketing de Console',
    ago: const Duration(minutes: 3),
    reply: 'Tengo el borrador del calendario de publicaciones para octubre.',
  ),
  _session(
    'pr',
    'PR #134 revisada',
    ago: const Duration(minutes: 25),
    unread: true,
    reply: 'Tres comentarios, nada bloqueante. ¿Lo fusiono?',
  ),
  _session('notes', 'Notas de la reunión', ago: const Duration(hours: 5)),
  _session('trip', 'Viaje a Lisboa', ago: const Duration(days: 2)),
];

const _active = DesktopActiveSessionList(
  sessions: [
    DesktopActiveSession(
      runtimeSessionId: 'rt-plan',
      storedSessionId: 'plan',
      status: 'working',
    ),
    DesktopActiveSession(
      runtimeSessionId: 'rt-astra',
      storedSessionId: '20260901_120000_astra1',
      status: 'working',
      title: 'Revisando la PR del login',
    ),
  ],
);

HomeWidgetInstance _w(
  String id,
  HomeWidgetKind kind,
  HomeWidgetSize size, [
  Map<String, Object?> options = const {},
]) => HomeWidgetInstance(id: id, kind: kind, size: size, options: options);

/// More than a phone holds (the tall render shows it all).
HomeBoardLayout _rich() => HomeBoardLayout([
  _w('g', HomeWidgetKind.now, HomeWidgetSize.wide),
  _w('r1', HomeWidgetKind.room, HomeWidgetSize.wide, {
    'rooms': ['room-devs', 'room-ops'],
  }),
  _w('b', HomeWidgetKind.bot, HomeWidgetSize.small, {'bot': 'astra'}),
  _w('s', HomeWidgetKind.server, HomeWidgetSize.small),
  _w('r2', HomeWidgetKind.room, HomeWidgetSize.large),
  _w('l', HomeWidgetKind.planLimits, HomeWidgetSize.wide),
  _w('a', HomeWidgetKind.cron, HomeWidgetSize.wide),
  _w('n', HomeWidgetKind.cron, HomeWidgetSize.small),
  _w('t', HomeWidgetKind.today, HomeWidgetSize.small),
  _w('k', HomeWidgetKind.tasks, HomeWidgetSize.wide),
  _w('c', HomeWidgetKind.continueChats, HomeWidgetSize.large),
  _w('e', HomeWidgetKind.team, HomeWidgetSize.large),
]);

/// A board with room left, for edit mode.
HomeBoardLayout _roomy() => HomeBoardLayout([
  _w('g', HomeWidgetKind.now, HomeWidgetSize.wide),
  _w('r1', HomeWidgetKind.room, HomeWidgetSize.wide, {
    'rooms': ['room-devs', 'room-ops'],
  }),
  _w('b', HomeWidgetKind.bot, HomeWidgetSize.small, {'bot': 'astra'}),
  _w('s', HomeWidgetKind.server, HomeWidgetSize.small),
]);

Future<void> _shot(WidgetTester tester, String name) async {
  const render = bool.fromEnvironment('HOME_RENDER');
  if (!render) return;
  const dir = 'build/home-widgets';
  final boundary =
      tester.renderObject(find.byKey(const ValueKey('render-root')))
          as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUpAll(loadDesignFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = (call.arguments as Map?) ?? const {};
          switch (call.method) {
            case 'read':
              return secure[args['key']];
            case 'write':
              secure[args['key'] as String] = args['value'] as String;
            case 'readAll':
              return Map<String, String>.from(secure);
          }
          return null;
        });
  });

  Future<void> pump(
    WidgetTester tester, {
    required HomeBoardLayout? layout,
    required bool rich,
    String theme = 'console',
    Size size = const Size(390, 844),
    bool editing = false,
  }) async {
    // QA 9494: the gesture dock is the app's dock.
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    addTearDown(FeatureFlags.instance.resetToDefaultForTesting);
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(),
    );
    addTearDown(GestureDockController.instance.resetForTesting);
    final prefs = await SharedPreferences.getInstance();
    final manager = (await tester.runAsync(
      () => ConnectionManager.create(prefs),
    ))!;
    await tester.runAsync(
      () => manager.saveConnection(
        'Hermes',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      ),
    );
    final conn = manager.getConnections().single;
    await tester.runAsync(() => manager.setActiveConnection(conn.id));
    if (layout != null) {
      await prefs.setString(
        HomeBoardStore.keyFor(conn.id, 'default'),
        layout.encode(),
      );
    }
    final chats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      globalActivity: GlobalActivityAggregate.inMemory(),
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(chats.dispose);
    final roster = BotRosterRegistry();
    final cache = MissionSnapshotCache();
    if (rich) {
      roster.publish(conn.id, 'Hermes', spec070Profiles());
      final groups = _richGroups();
      cache.write(
        conn,
        MissionBackendSnapshot(hostedGroups: groups, loadedAt: _clock),
      );
      final roomPrefs = SharedPreferencesRoomPrefs(prefs);
      for (final room in groups.rooms) {
        await roomPrefs.setLastSeenSeq(
          roomPrefsKey(room),
          room.roomId == 'room-devs' ? 1 : 2,
        );
      }
    }
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('render-root'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('es'),
          theme: AppTheme.fromId(theme),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => _Client(rich ? _sessions() : const []),
            activeChatsOverride: chats,
            dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
            activeSessionListLoader: () async =>
                rich ? _active : const DesktopActiveSessionList(),
            eventStreamOverride: const Stream.empty(),
            cronJobsLoader: (_, _) async => rich ? _cron() : const [],
            tasksLoader: (_) async => rich
                ? KanbanBoard.fromJson({
                    'columns': [
                      {
                        'name': 'running',
                        'tasks': [
                          {
                            'id': 'k1',
                            'title': 'Publicar 1.2.15',
                            'status': 'running',
                            'assignee': 'astra',
                          },
                        ],
                      },
                      {
                        'name': 'todo',
                        'tasks': [
                          {
                            'id': 'k2',
                            'title': 'Notas de la versión',
                            'status': 'todo',
                          },
                        ],
                      },
                    ],
                  })
                : const KanbanBoard(columns: []),
            feedCacheOverride: HomeFeedCache(),
            missionSnapshotCacheOverride: cache,
            rosterRegistryOverride: roster,
            botsOpenOverride: (_) {},
            clockOverride: () => _clock,
            serverInfoLoader: (_) async => (version: '0.12.3', update: true),
            limitsLoader: (_) async => rich
                ? AccountUsageLimits.fromGateway(usage(account: claudeLines))
                : null,
            initiallyEditingBoard: editing,
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  for (final (theme, tag) in const [
    ('console', 'dark'),
    ('console-light', 'light'),
  ]) {
    testWidgets('default home, new user ($tag)', (tester) async {
      await pump(tester, layout: null, rich: false, theme: theme);
      expect(tester.takeException(), isNull);
      await _shot(tester, 'home-default-$tag');
    });

    testWidgets('default home with data ($tag)', (tester) async {
      await pump(tester, layout: null, rich: true, theme: theme);
      expect(tester.takeException(), isNull);
      await _shot(tester, 'home-default-data-$tag');
    });

    testWidgets('rich dashboard, whole board ($tag)', (tester) async {
      await pump(
        tester,
        layout: _rich(),
        rich: true,
        theme: theme,
        size: const Size(390, 2700),
      );
      expect(tester.takeException(), isNull);
      await _shot(tester, 'home-rich-full-$tag');
    });

    testWidgets('rich dashboard, phone viewport ($tag)', (tester) async {
      await pump(tester, layout: _rich(), rich: true, theme: theme);
      expect(tester.takeException(), isNull);
      await _shot(tester, 'home-rich-$tag');
    });

    testWidgets('edit mode, gallery and configure sheet ($tag)', (
      tester,
    ) async {
      await pump(
        tester,
        layout: _roomy(),
        rich: true,
        editing: true,
        theme: theme,
      );
      expect(tester.takeException(), isNull);
      await _shot(tester, 'home-edit-$tag');
      await tester.tap(find.byKey(const ValueKey('home-edit-add')));
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('home-gallery')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-gallery-room')), findsOneWidget);
      await _shot(tester, 'home-gallery-$tag');
      Navigator.of(
        tester.element(find.byKey(const ValueKey('home-gallery'))),
      ).pop();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('home-gallery')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-tile-room-r1')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('home-configure')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _shot(tester, 'home-configure-$tag');
    });
  }

  for (final theme in const [
    'claude',
    'claude-light',
    'amber',
    'dracula',
    'gruvbox',
    'catppuccin',
  ]) {
    testWidgets('theme $theme', (tester) async {
      await pump(tester, layout: _rich(), rich: true, theme: theme);
      expect(tester.takeException(), isNull);
      await _shot(tester, 'theme-$theme');
    });
  }
}
