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
            AgentProfile(name: 'infra'),
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
    'Working bot row is alive with its worker title; idle face stays calm',
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
      final row = find.byKey(const ValueKey('mission-bot-row-forja'));
      expect(find.text('Trabajando · Revisando PR #38'), findsOneWidget);
      final working = tester.widget<HermesBotFace>(
        find.descendant(of: row, matching: find.byType(HermesBotFace)),
      );
      expect(working.animate, isTrue);
      expect(working.clock, isNotNull, reason: 'one shared ticker per face');
      expect(
        find.descendant(
          of: row,
          matching: find.byKey(const ValueKey('living-face-ring-working')),
        ),
        findsOneWidget,
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

  testWidgets(
    'Bot row attention comes from server room state, not local unread marks',
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

      // radar (failed room turn) and astra (@user mention) both carry the
      // single attention signal and sit under "Needs you" — server state,
      // no local unread watermark, no dots.
      for (final name in const ['radar', 'astra']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('mission-bot-row-$name')),
            matching: find.byKey(const ValueKey('living-face-ring-attention')),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('mission-bot-unread-radar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('roster-section-needs-you')),
        findsOneWidget,
      );
    },
  );
}
