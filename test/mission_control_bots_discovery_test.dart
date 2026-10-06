import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bot_chat_title_lookup.dart';
import 'support/spec070_fixtures.dart';

final _connection = SavedConnection(
  id: 'mission-bots-discovery',
  label: 'Mission QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
  readOnly: true,
);

Session _session(String id, String profile, {double updatedAt = 120}) =>
    Session(
      id: id,
      title: '$profile session',
      model: 'model-$profile',
      source: 'gateway',
      messageCount: 3,
      isActive: true,
      preview: 'Recent work',
      startedAt: 100,
      updatedAt: updatedAt,
      profile: profile,
      inputTokens: 120,
      outputTokens: 30,
    );

MissionBackendSnapshot _snapshot({
  required List<AgentProfile> profiles,
  List<Session> sessions = const [],
}) => MissionBackendSnapshot(
  profiles: profiles,
  sessions: sessions,
  board: const KanbanBoard(columns: []),
  profilesCapability: MissionCapabilityState.available,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
  loadedAt: DateTime.fromMillisecondsSinceEpoch(120000),
);

class _FakeSource implements MissionControlDataSource {
  final MissionBackendSnapshot snapshot;

  const _FakeSource(this.snapshot);

  @override
  Future<MissionBackendSnapshot> load() async => snapshot;

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget _host({
  required ConnectionManager manager,
  required MissionBackendSnapshot snapshot,
  ActiveChatService? activeChats,
  ValueChanged<Session>? botChatOpenObserver,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: MissionControlScreen(
    connection: _connection,
    connManager: manager,
    dataSource: _FakeSource(snapshot),
    activeChats: activeChats,
    botChatOpenObserver: botChatOpenObserver,
    botChatTitleLookup: FakeBotChatTitleLookup(),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  setUp(() {
    secureStore.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
              case 'read':
                return secureStore[args['key'] as String];
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'delete':
                secureStore.remove(args['key'] as String);
            }
            return null;
          },
        );
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  testWidgets('Bots search normalizes case whitespace and diacritics', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(
              name: 'alpha_ops',
              botModeUiMeta: {'title': 'Álpha Ops'},
            ),
            AgentProfile(
              name: 'quality_assurance',
              botModeUiMeta: {'title': 'Quality Assurance'},
            ),
            AgentProfile(name: 'research'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Spec 070 S1: search is a round header button.
    await tester.tap(find.byKey(const ValueKey('roster-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mission-bot-search')),
      '  ALPHA   ops  ',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('mission-bot-row-alpha_ops')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mission-bot-row-quality_assurance')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mission-bot-row-research')),
      findsNothing,
    );
  });

  testWidgets('Hidden Bots stay out of the roster until explicitly revealed', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(
              name: 'infra',
              botModeUiMeta: {'hidden': true},
              botModeMetadataPublished: true,
            ),
            AgentProfile(name: 'quality_assurance'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mission-bot-row-infra')), findsNothing);
    expect(
      find.byKey(const ValueKey('mission-bot-row-quality_assurance')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('mission-show-hidden')));
    await tester.pump();

    expect(find.byKey(const ValueKey('mission-bot-row-infra')), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-bot-infra')), findsOneWidget);
  });

  testWidgets('Executing Bot Chats carry the working signal on their face', (
    tester,
  ) async {
    // This test checks grouping; steady live motion has no settled frame.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final infraSession = _session('s-infra', 'infra');
    final chat = chats.attach(
      connection: _connection,
      sessionId: infraSession.id,
      sessionTitle: infraSession.title,
      sessionProfile: 'infra',
      sessionSnapshot: infraSession,
      disableForegroundKeepAlive: true,
    );
    chat.state = ChatPipelineState.executing;

    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [
            // The running chat is infra's canonical Bot Chat: only that chat
            // lights the avatar.
            AgentProfile(
              name: 'infra',
              canonicalSession: AgentProfileSessionSummary(id: 's-infra'),
            ),
            AgentProfile(name: 'quality_assurance'),
          ],
          sessions: [infraSession],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Spec 070 S1: no "Active now" section; the face carries the state.
    expect(find.byKey(const ValueKey('mission-active-now')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-bot-row-infra')),
        matching: find.byKey(const ValueKey('living-face-ring-working')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-bot-row-quality_assurance')),
        matching: find.byKey(const ValueKey('living-face-ring-working')),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'A fresh worker alone leaves the avatar calm, like an idle bot face',
    (tester) async {
      debugLivingBotFacesStill = false;
      addTearDown(() => debugLivingBotFacesStill = true);
      final manager = await _manager();
      addTearDown(manager.dispose);
      final snapshot = _snapshot(
        profiles: [
          AgentProfile(
            name: 'forja',
            workerSession: AgentProfileWorkerSession(
              id: 'w',
              source: 'tool',
              title: 'Revisando PR #38',
              lastActive: DateTime.now().millisecondsSinceEpoch / 1000,
            ),
          ),
          const AgentProfile(name: 'idle'),
        ],
      );
      await tester.pumpWidget(_host(manager: manager, snapshot: snapshot));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 300));
      // The avatar opens the Bot Chat, so its aura reflects that chat only;
      // a background worker is other work (Desktop's canonical-chat rule).
      final row = find.byKey(const ValueKey('mission-bot-row-forja'));
      expect(find.text('Trabajando · Revisando PR #38'), findsNothing);
      expect(
        find.descendant(
          of: row,
          matching: find.byKey(const ValueKey('living-face-ring-working')),
        ),
        findsNothing,
      );
      final idle = find.byKey(const ValueKey('mission-bot-row-idle'));
      expect(
        find.descendant(
          of: idle,
          matching: find.byKey(const ValueKey('living-face-ring-working')),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<HermesBotFace>(
              find.descendant(of: idle, matching: find.byType(HermesBotFace)),
            )
            .motionState,
        HermesBotFaceMotionState.idle,
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Bots home with only idle bots stops producing frames', (
    tester,
  ) async {
    debugLivingBotFacesStill = false;
    addTearDown(() => debugLivingBotFacesStill = true);
    final manager = await _manager();
    addTearDown(manager.dispose);
    final snapshot = _snapshot(
      profiles: const [
        AgentProfile(name: 'argos'),
        AgentProfile(name: 'astra'),
        AgentProfile(name: 'radar'),
      ],
    );
    await tester.pumpWidget(_host(manager: manager, snapshot: snapshot));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(LivingBotFace), findsWidgets);
    expect(livingBotFaceActiveTickers, 0);
    var busy = 0;
    const steps = 200;
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (tester.binding.transientCallbackCount > 0) busy++;
    }
    expect(
      busy,
      lessThan(steps ~/ 4),
      reason: 'idle Bots home kept ticking in $busy of $steps samples',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // QA 9491: each idle face blinked on its own 4.2-8 s timer, so ten bots
  // interleaved into a near-continuous ~33 fps. A list now blinks one face
  // every 12-20 s through one shared scheduler.
  testWidgets('ten idle bots blink rarely, not ten interleaved blinks', (
    tester,
  ) async {
    debugLivingBotFacesStill = false;
    addTearDown(() => debugLivingBotFacesStill = true);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = await _manager();
    addTearDown(manager.dispose);
    final snapshot = _snapshot(
      profiles: [
        // Ten grid tiles (four pinned): every face shares the one blink.
        for (var i = 0; i < 10; i++)
          AgentProfile(
            name: 'quiet_bot_$i',
            botModeUiMeta: {if (i < 4) 'pinned': true},
          ),
      ],
    );
    await tester.pumpWidget(_host(manager: manager, snapshot: snapshot));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(LivingBotFace).evaluate().length, greaterThan(8));
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('dots-tile-'),
      ),
      findsNWidgets(10),
    );
    expect(livingBotFaceActiveTickers, 0);
    // Count wake-ups: rising edges of "a frame callback is pending" over one
    // minute of fake time. One edge per blink (220 ms, sampled every 100 ms).
    var wakeUps = 0;
    var wasBusy = false;
    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final busy = tester.binding.transientCallbackCount > 0;
      if (busy && !wasBusy) wakeUps++;
      wasBusy = busy;
    }
    expect(
      wakeUps,
      lessThanOrEqualTo(6),
      reason: 'idle Bots list woke up $wakeUps times in 60 s',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Room attention marks the room row, not the bots seated in that room',
    (tester) async {
      final manager = await _manager();
      final log = HostedGroupLogPage.append(
        spec070LogPage('groups_log_page1'),
        spec070LogPage('groups_log_page2'),
      );
      final session = _session('s-radar-new', 'radar', updatedAt: 120);
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: MissionBackendSnapshot(
            profiles: const [
              AgentProfile(name: 'astra'),
              AgentProfile(name: 'radar'),
            ],
            sessions: [session],
            profilesCapability: MissionCapabilityState.available,
            sessionsCapability: MissionCapabilityState.available,
            hostedGroups: HostedGroupsSnapshot(
              rooms: [spec070Room()],
              logs: [log],
              // No pending actions: radar's failed turn is the only signal.
              driverStatuses: {
                'room-devs': const RoomDriverStatus(
                  running: false,
                  working: false,
                  blocked: false,
                ),
              },
            ),
            loadedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // radar (failed room turn) and astra (@user mention) need the user in
      // the room: the room sits under "Needs you", while their avatars stay
      // calm because their Bot Chats wait on nothing.
      for (final name in const ['radar', 'astra']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('mission-bot-row-$name')),
            matching: find.byKey(const ValueKey('living-face-ring-attention')),
          ),
          findsNothing,
        );
      }
      expect(
        find.byKey(const ValueKey('mission-bot-unread-radar')),
        findsNothing,
      );
      // The room card carries the amber "waiting for you" dot instead.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'roster-room-needs-you-',
              ),
        ),
        findsOneWidget,
      );
    },
  );
}
