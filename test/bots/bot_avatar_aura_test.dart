import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/bot_presence.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/room_member_status.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_bot_chat_title_lookup.dart';

// Desktop parity: a Bots avatar opens the profile's canonical Bot Chat, so
// its working/waiting aura reflects that chat alone. A turn the main profile
// runs in an ordinary Chats session must not light it (QA 9489: the ring said
// "working" and the tap landed in an empty Bot Chat).

final _connection = SavedConnection(
  id: 'bot-aura',
  label: 'Aura QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

Session _session(String id, String profile, {double updatedAt = 120}) =>
    Session(
      id: id,
      title: 'Chat $id',
      model: 'model',
      source: 'gateway',
      messageCount: 3,
      isActive: true,
      preview: 'Recent work',
      startedAt: 100,
      updatedAt: updatedAt,
      profile: profile,
      isDefaultProfile: profile == 'default',
    );

class _Source implements MissionControlDataSource {
  final MissionBackendSnapshot snapshot;
  _Source(this.snapshot);

  @override
  Future<MissionBackendSnapshot> load() async => snapshot;

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

MissionBackendSnapshot _snapshot({
  required List<AgentProfile> profiles,
  List<Session> sessions = const [],
  List<DesktopActiveSession> activeSessions = const [],
}) => MissionBackendSnapshot(
  profiles: profiles,
  sessions: sessions,
  board: const KanbanBoard(columns: []),
  profilesCapability: MissionCapabilityState.available,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
  activeSessions: activeSessions,
  activeSessionsObservedAt: DateTime.now(),
  loadedAt: DateTime.now(),
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget _host({
  required ConnectionManager manager,
  required MissionBackendSnapshot snapshot,
  ActiveChatService? activeChats,
  required ValueChanged<Session> opened,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: MissionControlScreen(
    connection: _connection,
    connManager: manager,
    dataSource: _Source(snapshot),
    activeChats: activeChats,
    botChatOpenObserver: opened,
    botChatTitleLookup: FakeBotChatTitleLookup(),
  ),
);

ActiveChat _running(
  ActiveChatService chats,
  Session session, {
  String? chatId,
}) {
  final chat = chats.attach(
    connection: _connection,
    sessionId: chatId ?? session.id,
    initialStoredSessionId: chatId == null ? null : session.id,
    sessionTitle: session.title,
    sessionProfile: session.profile,
    sessionSnapshot: session,
    disableForegroundKeepAlive: true,
  );
  chat.state = ChatPipelineState.executing;
  return chat;
}

const _mainWithBotChat = AgentProfile(
  name: 'default',
  isDefault: true,
  canonicalSession: AgentProfileSessionSummary(id: 's-botchat'),
);

Finder _ring(String profile, String signal) => find.descendant(
  of: find.byKey(ValueKey('mission-bot-row-$profile')),
  matching: find.byKey(ValueKey('living-face-ring-$signal')),
);

void main() {
  // Opening a Bot Chat retires a legacy secure-storage pin first.
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (call) async => null);
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
  });

  testWidgets(
    'a turn in an ordinary Chats session leaves the avatar quiet and the tap '
    'still opens the Bot Chat',
    (tester) async {
      final manager = await _manager();
      final chats = ActiveChatService();
      addTearDown(chats.dispose);
      final main = _session('s-main', 'default');
      _running(chats, main);
      Session? opened;

      await tester.pumpWidget(
        _host(
          manager: manager,
          activeChats: chats,
          snapshot: _snapshot(
            profiles: const [_mainWithBotChat],
            sessions: [main],
          ),
          opened: (s) => opened = s,
        ),
      );
      await tester.pumpAndSettle();

      expect(_ring('default', 'working'), findsNothing);
      expect(_ring('default', 'attention'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mission-bot-default')));
      await tester.pumpAndSettle();
      expect(opened?.source, 'bot-mode-canonical');
      expect(opened?.lineageRootId, 's-botchat');
    },
  );

  testWidgets('a turn running in the Bot Chat itself lights the avatar', (
    tester,
  ) async {
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final botChat = _session('s-botchat', 'default');
    _running(chats, botChat, chatId: 'mob-bot-default');
    Session? opened;

    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [_mainWithBotChat],
          sessions: [botChat],
        ),
        opened: (s) => opened = s,
      ),
    );
    await tester.pumpAndSettle();

    expect(_ring('default', 'working'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mission-bot-default')));
    await tester.pumpAndSettle();
    expect(opened?.lineageRootId, 's-botchat');
  });

  testWidgets('a new Bot Chat not registered yet still lights its avatar', (
    tester,
  ) async {
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final draft = _session('mob-bot-astra', 'astra');
    _running(chats, draft);
    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        // Listed so Mission Control finds the chat without a live event.
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'astra')],
          sessions: [draft],
        ),
        opened: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(_ring('astra', 'working'), findsOneWidget);
  });

  testWidgets('a pending approval in the Bot Chat shows the waiting aura', (
    tester,
  ) async {
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final botChat = _session('s-botchat', 'default');
    _running(chats, botChat, chatId: 'mob-bot-default').pendingApproval = {
      'request_id': 'approval-1',
      'description': 'Restart',
    };

    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [_mainWithBotChat],
          sessions: [botChat],
        ),
        opened: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(_ring('default', 'attention'), findsOneWidget);
  });

  testWidgets(
    'session.active_list counts only the canonical Bot Chat row, never '
    'another chat of the profile',
    (tester) async {
      final manager = await _manager();
      final now = DateTime.now();
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: _snapshot(
            profiles: const [
              AgentProfile(
                name: 'forja',
                canonicalSession: AgentProfileSessionSummary(
                  id: 's-forja-bot',
                  resolvedId: 's-forja-tip',
                ),
              ),
              AgentProfile(
                name: 'astra',
                canonicalSession: AgentProfileSessionSummary(id: 's-astra'),
                lastSession: AgentProfileSessionSummary(id: 's-astra-other'),
              ),
              AgentProfile(
                name: 'argos',
                canonicalSession: AgentProfileSessionSummary(id: 's-argos'),
              ),
            ],
            activeSessions: [
              // Forja's Bot Chat tip, moved by another client.
              DesktopActiveSession(
                runtimeSessionId: 'rt-1',
                storedSessionId: 's-forja-tip',
                status: 'working',
                lastActiveAt: now,
              ),
              // Astra works in another chat, not in its Bot Chat.
              DesktopActiveSession(
                runtimeSessionId: 'rt-2',
                storedSessionId: 's-astra-other',
                status: 'working',
                lastActiveAt: now,
              ),
              // Argos waits on a question in its Bot Chat.
              DesktopActiveSession(
                runtimeSessionId: 'rt-3',
                storedSessionId: 's-argos',
                status: 'waiting',
                lastActiveAt: now,
              ),
            ],
          ),
          opened: (_) {},
        ),
      );
      await tester.pumpAndSettle();
      expect(_ring('forja', 'working'), findsOneWidget);
      expect(_ring('astra', 'working'), findsNothing);
      expect(_ring('argos', 'attention'), findsOneWidget);
    },
  );

  test('an ambiguous Bot Chat id lights no avatar', () {
    final projection = MissionProjector.build(
      snapshot: _snapshot(
        profiles: const [
          AgentProfile(
            name: 'forja',
            canonicalSession: AgentProfileSessionSummary(id: 's-shared'),
          ),
          AgentProfile(
            name: 'astra',
            canonicalSession: AgentProfileSessionSummary(id: 's-shared'),
          ),
        ],
        activeSessions: const [
          DesktopActiveSession(
            runtimeSessionId: 'rt',
            storedSessionId: 's-shared',
            status: 'working',
          ),
        ],
      ),
    );
    for (final agent in projection.agents) {
      expect(
        agent.botChatPresence,
        BotPresence.idle,
        reason: agent.profile.name,
      );
    }
  });

  test('the aura follows the Bot Chat turn and goes off when it ends', () {
    BotFaceSignal signal(MissionLivePhase phase, {bool botChat = true}) {
      final agent = MissionProjector.build(
        snapshot: _snapshot(profiles: const [_mainWithBotChat]),
        liveChats: [
          MissionLiveChat(
            profileName: 'default',
            sessionId: botChat ? 's-botchat' : 's-main',
            title: 'chat',
            phase: phase,
          ),
        ],
      ).agents.single;
      return BotRosterEntry.from(
        agent: agent,
        live: const BotLiveStatus(RoomPresence.idle),
      ).signal;
    }

    expect(signal(MissionLivePhase.working), BotFaceSignal.working);
    expect(signal(MissionLivePhase.thinking), BotFaceSignal.thinking);
    expect(signal(MissionLivePhase.approvalRequired), BotFaceSignal.attention);
    expect(signal(MissionLivePhase.idle), BotFaceSignal.idle);
    expect(
      signal(MissionLivePhase.working, botChat: false),
      BotFaceSignal.idle,
    );
  });
}
