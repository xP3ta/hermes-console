import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/home_prompt_composer.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/in_memory_compression_restore_storage.dart';
import '../support/spec070_fixtures.dart';

final _clock = DateTime(2026, 10, 6, 16, 30);
double _ago(Duration d) => _clock.subtract(d).millisecondsSinceEpoch / 1000;

Session _session(
  String id,
  String title, {
  Duration ago = const Duration(days: 3),
  bool? unread,
  String preview = '',
}) => Session(
  id: id,
  title: title,
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: preview,
  startedAt: _ago(ago),
  unread: unread,
);

class _HomeClient extends ApiClient {
  _HomeClient(this.sessions)
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

/// The chat's own approval path: `POST /v1/runs/{id}/approval`.
class _ApprovalApi extends ApiClient {
  _ApprovalApi()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final List<(String runId, String choice, String? requestId)> answers = [];

  @override
  Future<Map<String, dynamic>> resolveRunApproval(
    String runId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
    String? profile,
  }) async {
    answers.add((runId, choice, requestId));
    return const {'ok': true};
  }
}

final class _Harness {
  final ConnectionManager manager;
  final SharedPreferences prefs;
  final ActiveChatService chats;
  final MissionSnapshotCache cache;
  final BotRosterRegistry roster;
  final List<MissionControlOpenTarget> opened = [];
  final List<(String roomId, String requestId, String choice)> roomAnswers = [];

  _Harness(this.manager, this.prefs, this.chats, this.cache, this.roster);

  SavedConnection get connection => manager.getConnections().single;
}

HostedGroupsSnapshot _groups({bool withApproval = true}) =>
    HostedGroupsSnapshot(
      capabilities: spec070Capabilities(),
      rooms: [spec070Room()],
      logs: [
        HostedGroupLogPage.append(
          spec070LogPage('groups_log_page1'),
          spec070LogPage('groups_log_page2'),
        ),
      ],
      driverStatuses: {if (withApproval) 'room-devs': spec070DriverStatus()},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

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
            case 'delete':
              secure.remove(args['key']);
            case 'readAll':
              return Map<String, String>.from(secure);
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<_Harness> harness(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = (await tester.runAsync(
      () => ConnectionManager.create(prefs),
    ))!;
    await tester.runAsync(
      () => manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      ),
    );
    await tester.runAsync(
      () => manager.setActiveConnection(manager.getConnections().single.id),
    );
    final chats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      globalActivity: GlobalActivityAggregate.inMemory(),
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(chats.dispose);
    return _Harness(
      manager,
      prefs,
      chats,
      MissionSnapshotCache(),
      BotRosterRegistry(),
    );
  }

  Future<void> pumpHome(
    WidgetTester tester,
    _Harness h, {
    List<Session> sessions = const [],
    List<CronJob>? cron,
    DesktopActiveSessionList? activeList,
    Size size = const Size(390, 844),
    double textScale = 1,
    bool reduceMotion = false,
    String locale = 'es',
    String theme = 'dark',
  }) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        theme: AppTheme.fromId(theme),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: HomeDashboardScreen(
          connManager: h.manager,
          clientFactory: (_) => _HomeClient(sessions),
          activeChatsOverride: h.chats,
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          activeSessionListLoader: () async =>
              activeList ?? const DesktopActiveSessionList(),
          eventStreamOverride: const Stream.empty(),
          cronJobsLoader: (_, _) async => cron ?? const [],
          missionSnapshotCacheOverride: h.cache,
          rosterRegistryOverride: h.roster,
          roomApproveOverride:
              (_, {required roomId, required action, required choice}) async {
                h.roomAnswers.add((roomId, action.requestId, choice));
              },
          botsOpenOverride: h.opened.add,
          clockOverride: () => _clock,
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  ActiveChat attachApproval(
    _Harness h,
    String sessionId,
    String title, {
    required _ApprovalApi api,
    List<String> choices = const ['once', 'session', 'deny'],
  }) {
    final chat = h.chats.attach(
      connection: h.connection,
      sessionId: sessionId,
      sessionTitle: title,
      sessionProfile: 'default',
      api: api,
      disableForegroundKeepAlive: true,
    );
    chat
      ..currentRunId = 'run-1'
      ..state = ChatPipelineState.executing
      ..pendingApproval = {
        'request_id': 'req-1',
        'command': 'git push origin fix/dock',
        'choices': choices,
      };
    return chat;
  }

  group('calm', () {
    testWidgets('greeting, all calm, the composer; nothing else to show', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      expect(find.text('Buenas tardes'), findsOneWidget);
      expect(find.text('Todo en calma.'), findsOneWidget);
      expect(find.byType(HomePromptComposer), findsOneWidget);
      expect(find.byKey(const ValueKey('home-hero-calm')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-retomar')), findsNothing);
      expect(find.byKey(const ValueKey('home-proximo')), findsNothing);
      await unmount(tester);
    });

    testWidgets('an idle Home settles: no frame and no face ticker after 1 s', (
      tester,
    ) async {
      debugLivingBotFacesStill = false;
      addTearDown(() => debugLivingBotFacesStill = true);
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      await pumpHome(
        tester,
        h,
        sessions: [_session('a', 'Plan de la semana')],
        activeList: DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'rt-astra',
              storedSessionId: '20260901_120000_astra1',
              status: 'working',
              title: 'Bot Chat',
              startedAt: _clock.subtract(const Duration(minutes: 1)),
            ),
          ],
        ),
      );
      // The team faces are on screen, still: the line says what they do.
      expect(
        find.byKey(const ValueKey('home-team-face-astra')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(livingBotFaceActiveTickers, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await unmount(tester);
    });

    testWidgets('a recent chat is offered as «Seguir con…», not repeated in '
        'Retomar; a failed automation is offered for review', (tester) async {
      final h = await harness(tester);
      await pumpHome(
        tester,
        h,
        sessions: [
          _session(
            'recent',
            'Plan de marketing',
            ago: const Duration(hours: 1),
          ),
          _session('older', 'Resumen del DevDays'),
        ],
        cron: [
          CronJob.fromJson({
            'id': 'j1',
            'name': 'Backup',
            'last_status': 'error',
          }),
          CronJob.fromJson({
            'id': 'j2',
            'name': 'Resumen diario',
            'next_run_at': _clock
                .add(const Duration(hours: 2))
                .toIso8601String(),
          }),
        ],
      );
      expect(find.text('Seguir con «Plan de marketing»'), findsOneWidget);
      expect(find.text('Revisar «Backup»'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-retomar-chat:recent')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-retomar-chat:older')),
        findsOneWidget,
      );
      // The failure is already a starter: Próximo shows the next run.
      expect(find.text('Próximo: Resumen diario, 18:30'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-proximo-failed')), findsNothing);
      await unmount(tester);
    });
  });

  group('needs you', () {
    testWidgets('a chat approval leads; Permitir answers it once through '
        'the chat itself', (tester) async {
      final h = await harness(tester);
      final api = _ApprovalApi();
      final sessions = [
        _session('s-approve', 'Despliegue'),
        _session('s-other', 'Otra charla'),
      ];
      attachApproval(h, 's-approve', 'Despliegue', api: api);
      await pumpHome(
        tester,
        h,
        sessions: sessions,
        cron: [
          CronJob.fromJson({
            'id': 'j2',
            'name': 'Resumen diario',
            'next_run_at': _clock
                .add(const Duration(hours: 2))
                .toIso8601String(),
          }),
        ],
      );
      expect(find.text('Hermes te necesita para seguir.'), findsOneWidget);
      expect(find.text('Te necesita'), findsOneWidget);
      expect(find.text('git push origin fix/dock'), findsOneWidget);
      expect(find.text('en «Despliegue»'), findsOneWidget);
      // Retomar leaves out the chat of the card; Próximo hides.
      expect(
        find.byKey(const ValueKey('home-retomar-chat:s-approve')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-retomar-chat:s-other')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-proximo')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('home-approval-allow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.answers, [('run-1', 'once', 'req-1')]);
      h.chats
          .dispose(); // resolving starts its watchdog; close it in this test.
      await unmount(tester);
    });

    testWidgets('Rechazar denies it through the chat', (tester) async {
      final h = await harness(tester);
      final api = _ApprovalApi();
      attachApproval(h, 's-approve', 'Despliegue', api: api);
      await pumpHome(
        tester,
        h,
        sessions: [_session('s-approve', 'Despliegue')],
      );
      await tester.tap(find.byKey(const ValueKey('home-approval-deny')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.answers, [('run-1', 'deny', 'req-1')]);
      h.chats
          .dispose(); // resolving starts its watchdog; close it in this test.
      await unmount(tester);
    });

    testWidgets('no Permitir when the request does not offer it', (
      tester,
    ) async {
      final h = await harness(tester);
      attachApproval(
        h,
        's-approve',
        'Despliegue',
        api: _ApprovalApi(),
        choices: const ['deny'],
      );
      await pumpHome(
        tester,
        h,
        sessions: [_session('s-approve', 'Despliegue')],
      );
      expect(find.byKey(const ValueKey('home-approval-allow')), findsNothing);
      expect(find.byKey(const ValueKey('home-approval-deny')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a room approval from the Bots read: Permitir answers the '
        'exact request; Ver opens the room', (tester) async {
      final h = await harness(tester);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(hostedGroups: _groups(), loadedAt: _clock),
      );
      await pumpHome(tester, h);
      expect(find.text('Astra quiere ejecutar un comando'), findsOneWidget);
      expect(find.text('en «Console Devs»'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-approval-view')));
      await tester.pump();
      expect(h.opened.single.roomId, 'room-devs');
      await tester.tap(find.byKey(const ValueKey('home-approval-allow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.roomAnswers, [('room-devs', 'apr-1', 'once')]);
      // Answered here: the card moves on although the cached read still
      // lists it.
      expect(find.byKey(const ValueKey('home-hero-calm')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an old Bots read offers no room approval', (tester) async {
      final h = await harness(tester);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(
          hostedGroups: _groups(),
          loadedAt: _clock.subtract(const Duration(minutes: 6)),
        ),
      );
      await pumpHome(tester, h);
      expect(find.byKey(const ValueKey('home-approval-allow')), findsNothing);
      expect(find.byKey(const ValueKey('home-hero-calm')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a Bots read published while Home is shown repaints it', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(tester, h);
      expect(find.byKey(const ValueKey('home-hero-calm')), findsOneWidget);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(hostedGroups: _groups(), loadedAt: _clock),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Astra quiere ejecutar un comando'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('working and finished', () {
    testWidgets('a working chat: «Trabajando en …», m:ss and Abrir', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(
        tester,
        h,
        sessions: [
          _session('w1', 'Revisar la PR', ago: const Duration(minutes: 2)),
          _session('older', 'Resumen'),
        ],
        activeList: DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'rt-w1',
              storedSessionId: 'w1',
              status: 'working',
              startedAt: _clock.subtract(const Duration(seconds: 75)),
            ),
          ],
        ),
      );
      expect(
        find.text('Hermes está trabajando en «Revisar la PR».'),
        findsOneWidget,
      );
      expect(find.text('Trabajando en «Revisar la PR»'), findsOneWidget);
      expect(find.text('1:15'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-hero-open')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-retomar-chat:w1')), findsNothing);
      await unmount(tester);
    });

    testWidgets('a chat that finished unread: its line and Abrir', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(
        tester,
        h,
        sessions: [
          _session(
            'u1',
            'PR #134 revisada',
            ago: const Duration(minutes: 20),
            unread: true,
            preview: '3 comentarios, nada bloqueante.',
          ),
          _session('older', 'Resumen'),
        ],
      );
      expect(find.text('Hermes terminó «PR #134 revisada».'), findsOneWidget);
      expect(find.text('Terminó mientras no estabas'), findsOneWidget);
      expect(find.text('3 comentarios, nada bloqueante.'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-hero-open')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-retomar-chat:u1')), findsNothing);
      await unmount(tester);
    });
  });

  group('team and rooms', () {
    testWidgets('bots whose Bot Chat works: faces, one line, a sheet that '
        'opens that Bot Chat', (tester) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      await pumpHome(
        tester,
        h,
        activeList: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'rt-astra',
              storedSessionId: '20260901_120000_astra1',
              status: 'working',
              title: 'Bot Chat',
            ),
          ],
        ),
      );
      expect(find.textContaining('trabajando'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-status-team')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-team-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-team-bot-astra')));
      await tester.pumpAndSettle();
      expect(h.opened.single.profile, 'astra');
      expect(h.opened.single.sessionId, '20260901_120000_astra1');
      await unmount(tester);
    });

    testWidgets('a room with news is a Retomar row that opens the room', (
      tester,
    ) async {
      final h = await harness(tester);
      final room = spec070Room();
      await SharedPreferencesRoomPrefs(
        h.prefs,
      ).setLastSeenSeq(roomPrefsKey(room), 2);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(
          hostedGroups: _groups(withApproval: false),
          loadedAt: _clock,
        ),
      );
      await pumpHome(tester, h, sessions: [_session('a', 'Resumen')]);
      final row = find.byKey(const ValueKey('home-retomar-room:room-devs'));
      expect(row, findsOneWidget);
      expect(
        find.textContaining('Console Devs · 1 nuevo', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pump();
      expect(h.opened.single.roomId, 'room-devs');
      await unmount(tester);
    });
  });

  group('layout', () {
    Future<void> everyState(
      WidgetTester tester,
      Future<void> Function(_Harness h, List<Session> sessions) pump,
    ) async {
      final h = await harness(tester);
      h.roster.publish(h.connection.id, 'QA', spec070Profiles());
      final long = 'Una conversación con un título muy largo ' * 3;
      attachApproval(h, 's-approve', long, api: _ApprovalApi());
      await pump(h, [
        _session('s-approve', long),
        for (var i = 0; i < 4; i++) _session('r$i', '$long $i', preview: long),
      ]);
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('320 dp at ${scale}x: no overflow with an approval and '
          'long titles', (tester) async {
        await everyState(tester, (h, sessions) async {
          await pumpHome(
            tester,
            h,
            sessions: sessions,
            size: const Size(320, 640),
            textScale: scale,
          );
        });
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('home-approval-allow')),
          findsOneWidget,
        );
        await unmount(tester);
      });
    }

    testWidgets('320 dp at 2x: the calm card and its starters fit', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(
        tester,
        h,
        sessions: [
          _session(
            'r',
            'Un título de conversación bastante largo para el arranque',
            ago: const Duration(minutes: 5),
          ),
        ],
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(HomePromptComposer), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('tablet: hero and status on the left, Retomar on the right', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(
        tester,
        h,
        sessions: [_session('a', 'Resumen'), _session('b', 'Notas')],
        size: const Size(1280, 800),
      );
      final hero = tester.getRect(find.byKey(const ValueKey('home-hero-calm')));
      final retomar = tester.getRect(
        find.byKey(const ValueKey('home-retomar')),
      );
      expect(retomar.left, greaterThan(hero.right));
      expect(retomar.top, lessThan(hero.bottom));
      await unmount(tester);
    });

    testWidgets('phone: Retomar sits under the hero', (tester) async {
      final h = await harness(tester);
      await pumpHome(
        tester,
        h,
        sessions: [_session('a', 'Resumen'), _session('b', 'Notas')],
      );
      final hero = tester.getRect(find.byKey(const ValueKey('home-hero-calm')));
      final retomar = tester.getRect(
        find.byKey(const ValueKey('home-retomar')),
      );
      expect(retomar.top, greaterThanOrEqualTo(hero.bottom));
      await unmount(tester);
    });

    testWidgets('reduced motion: a state change lands in one frame', (
      tester,
    ) async {
      final h = await harness(tester);
      await pumpHome(tester, h, reduceMotion: true);
      h.cache.write(
        h.connection,
        MissionBackendSnapshot(hostedGroups: _groups(), loadedAt: _clock),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('home-hero-calm')), findsNothing);
      expect(find.text('Astra quiere ejecutar un comando'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await unmount(tester);
    });
  });
}
