import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_bot_activity_store.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  MissionBotActivityStore? botActivityStore,
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
    botActivityStore: botActivityStore,
    botChatOpenObserver: botChatOpenObserver,
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

  testWidgets('Executing Bot Chats are grouped under Active now', (
    tester,
  ) async {
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

    expect(find.byKey(const ValueKey('mission-active-now')), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-bot-row-infra')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mission-bot-row-quality_assurance')),
      findsOneWidget,
    );
  });

  testWidgets('Opening a Bot Chat clears its scoped unread watermark', (
    tester,
  ) async {
    final manager = await _manager();
    final activityStore = MissionBotActivityStore(manager.prefs);
    await activityStore.markRead(
      connectionId: _connection.id,
      profile: 'infra',
      activityAtMs: 110000,
    );
    final session = _session('s-infra-new', 'infra', updatedAt: 120);
    final opened = Completer<Session>();

    await tester.pumpWidget(
      _host(
        manager: manager,
        botActivityStore: activityStore,
        botChatOpenObserver: (value) {
          if (!opened.isCompleted) opened.complete(value);
        },
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(
              name: 'infra',
              botModeUiMeta: {'chat': null},
              botModeMetadataPublished: true,
            ),
          ],
          sessions: [session],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mission-bot-unread-infra')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('mission-bot-infra')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-detail-chat')));
    final openedSession = await tester.runAsync(
      () => opened.future.timeout(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();

    expect(openedSession?.profile, 'infra');
    expect(
      find.byKey(const ValueKey('mission-bot-unread-infra')),
      findsNothing,
    );
    expect(
      activityStore.watermark(_connection.id, 'infra'),
      greaterThanOrEqualTo(120000),
    );
  });
}
