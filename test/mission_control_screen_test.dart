import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:hermes_android/core/bots/state/bot_chat_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/widgets/remote_bot_roster.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_bot_chat_store.dart';
import 'package:hermes_android/core/services/mission_organization_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bot_chat_title_lookup.dart';

final _connection = SavedConnection(
  id: 'mission-widget',
  label: 'Mission QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
);

Session _session(String id, String profile) => Session(
  id: id,
  title: '$profile session',
  model: 'model-$profile',
  source: 'gateway',
  messageCount: 3,
  isActive: true,
  preview: 'Recent work',
  startedAt: 100,
  updatedAt: 120,
  profile: profile,
  inputTokens: 120,
  outputTokens: 30,
);

MissionBackendSnapshot _snapshot({
  List<AgentProfile> profiles = const [],
  List<Session> sessions = const [],
  KanbanBoard? board,
  MissionCapabilityState profilesCapability = MissionCapabilityState.available,
  MissionCapabilityState kanbanCapability = MissionCapabilityState.available,
}) => MissionBackendSnapshot(
  profiles: profiles,
  sessions: sessions,
  board: board,
  profilesCapability: profilesCapability,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: kanbanCapability,
  loadedAt: DateTime.fromMillisecondsSinceEpoch(120000),
);

class _FakeSource implements MissionControlDataSource {
  final MissionBackendSnapshot snapshot;

  _FakeSource(this.snapshot);

  @override
  Future<MissionBackendSnapshot> load() async => snapshot;

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

class _SequenceSource implements MissionControlDataSource {
  final List<Future<MissionBackendSnapshot>> loads;
  var loadCount = 0;

  _SequenceSource(this.loads);

  @override
  Future<MissionBackendSnapshot> load() => loads[loadCount++];

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

class _WatchSource implements MissionControlDataSource {
  final MissionBackendSnapshot snapshot;
  final events = StreamController<KanbanEvent>.broadcast();
  int loadCount = 0;
  int watchCount = 0;

  _WatchSource(this.snapshot);

  @override
  Future<MissionBackendSnapshot> load() async {
    loadCount++;
    return snapshot;
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) {
    watchCount++;
    return events.stream;
  }

  @override
  void close() {}
}

/// Doble del contrato de creación de bots (paridad CreateAgentDialog).
class _FakeBotCreateGateway
    implements
        HermesDesktopBotCreationGateway,
        HermesDesktopProfileAssetsGateway,
        HermesDesktopPetGateway {
  final List<String> calls = [];
  Map<String, Object?>? createdProfile;
  String? metaProfile;
  String? metaTitle;
  int? metaCreatedAtMs;
  bool? metaHidden;
  bool? metaPinned;
  List<String>? disabledSkills;
  List<DesktopProfileSkill>? skills;

  @override
  Future<void> createProfileNative({
    required String name,
    String? cloneFrom,
    String description = '',
    String soul = '',
    String model = '',
    String provider = '',
    bool noSkills = false,
    bool shareAuth = true,
  }) async {
    calls.add('create');
    createdProfile = {
      'name': name,
      'cloneFrom': cloneFrom,
      'description': description,
      'soul': soul,
      'model': model,
      'provider': provider,
      'noSkills': noSkills,
      'shareAuth': shareAuth,
    };
  }

  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    int? createdAtMs,
    BotVisualIdentity? identity,
  }) async {
    calls.add(identity == null ? 'meta' : 'identity-meta');
    metaProfile = profile;
    if (title != null) metaTitle = title;
    if (createdAtMs != null) metaCreatedAtMs = createdAtMs;
    if (hidden != null) metaHidden = hidden;
    if (pinned != null) metaPinned = pinned;
  }

  @override
  Future<List<DesktopProfileSkill>?> describeProfileSkills(
    String profile,
  ) async {
    calls.add('describe:$profile');
    return skills;
  }

  @override
  Future<void> setProfileDisabledSkills({
    required String profile,
    required List<String> disabledSkills,
  }) async {
    calls.add('disabled-skills');
    this.disabledSkills = disabledSkills;
  }

  @override
  Stream<TuiGatewayEvent> get events => const Stream.empty();

  @override
  Future<AgentProfileAvatar?> profileAvatar(String profileName) async => null;

  @override
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  }) async {
    calls.add('set-avatar');
  }

  @override
  Future<void> clearProfileAvatar(String profile) async {
    calls.add('clear-avatar');
  }

  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async => ProfilePetInfo.disabled;

  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async => const ProfilePetGallery(enabled: false, active: '', pets: []);

  @override
  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  }) async => null;

  @override
  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  }) async => ProfilePetSelection(slug: slug);

  @override
  Future<bool> profilePetDisable({String profile = ''}) async {
    calls.add('pet.disable');
    return true;
  }
}

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget _host({
  required ConnectionManager manager,
  required MissionBackendSnapshot snapshot,
  MissionOrganizationStoreContract? store,
  MissionBotChatStore? botChatStore,
  ActiveChatService? activeChats,
  MissionControlDataSource? dataSource,
  double textScale = 1,
  // These are interaction/layout tests; live avatar motion is tested separately.
  bool disableAnimations = true,
  EdgeInsets viewInsets = EdgeInsets.zero,
  EdgeInsets viewPadding = EdgeInsets.zero,
  SavedConnection? connection,
  ValueChanged<Session>? botChatOpenObserver,
  RemoteBotLoader? remoteBotLoader,
  MissionControlOpenTarget? initialOpenTarget,
  HermesDesktopBotCreationGateway? botCreateGateway,
  HermesDesktopProfileAssetsGateway? profileAssetsGateway,
  BotChatTitleLookup? botChatTitleLookup,
  BotProfileGateway? botProfileGateway,
  Future<void> Function(String name)? profileDeleteOverride,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
      viewInsets: viewInsets,
      viewPadding: viewPadding,
      padding: viewPadding.copyWith(
        bottom: viewInsets.bottom > 0 ? 0 : viewPadding.bottom,
      ),
    ),
    child: child!,
  ),
  home: MissionControlScreen(
    connection: connection ?? _connection,
    connManager: manager,
    dataSource: dataSource ?? _FakeSource(snapshot),
    organizationStore: store,
    botChatStore: botChatStore,
    activeChats: activeChats,
    initialOpenTarget: initialOpenTarget,
    botChatOpenObserver: botChatOpenObserver,
    remoteBotLoader: remoteBotLoader,
    botCreateGateway: botCreateGateway,
    profileAssetsGateway: profileAssetsGateway,
    botChatTitleLookup: botChatTitleLookup ?? FakeBotChatTitleLookup(),
    botProfileGateway: botProfileGateway,
    modelOptionsLoader: botCreateGateway == null ? null : (_) async => const [],
    profileDeleteOverride: profileDeleteOverride,
  ),
);

final class _UiMetaGateway implements BotProfileGateway {
  final patches = <(String, Map<String, dynamic>, Set<String>)>[];

  @override
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  }) async => patches.add((profile, patch, remove));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The header "New" menu (round + button): new bot / room, task board,
/// workspaces and roster management.
Future<void> _openNewMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mission-create-agent')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('mission-create-chooser')), findsOneWidget);
}

/// Workspaces moved from the header switcher into the "New" menu.
Future<void> _openWorkspaces(WidgetTester tester) async {
  await _openNewMenu(tester);
  final item = find.byKey(const ValueKey('mission-create-chooser-workspaces'));
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
}

/// Spec 070 S1: mantener pulsada la fila abre las acciones (fijar,
/// sección, ocultar, abrir ficha); "Abrir ficha" lleva a la ficha del bot
/// (S4, `BotProfileScreen`).
Future<void> _openAgentDetail(WidgetTester tester, String profile) async {
  await _openRosterActions(tester, profile);
  final item = find.byKey(const ValueKey('roster-action-profile'));
  await tester.scrollUntilVisible(
    item,
    80,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('roster-bot-actions')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

Future<void> _openRosterActions(WidgetTester tester, String profile) async {
  final row = find.byKey(ValueKey('mission-bot-$profile'));
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('mission-bots')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.longPress(row);
  await tester.pumpAndSettle();
}

/// Spec 070 S1: the roster refreshes by pull-to-refresh (and every 30 s
/// while visible); the header keeps only search and "New".
Future<void> _pullToRefresh(WidgetTester tester) async {
  await tester.fling(
    find.byKey(const ValueKey('mission-bots')),
    const Offset(0, 400),
    1000,
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Spec 070 S1: tocar una fila de bot abre su Bot Chat canónico.
Future<void> _openBotChat(WidgetTester tester, String profile) async {
  await tester.tap(find.byKey(ValueKey('mission-bot-$profile')));
  await tester.pumpAndSettle();
}

/// El formulario de creación es más alto que la ventana de test: los
/// controles inferiores no existen hasta hacerlos visibles. El primer
/// Scrollable descendiente es el ListView del formulario (los TextField
/// internos también son Scrollables). [up] invierte el arrastre para
/// objetos situados por encima de la posición actual.
Future<void> _scrollCreateFormTo(
  WidgetTester tester,
  String key, {
  bool up = false,
}) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    up ? -220 : 220,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('bot-create-form')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

Future<void> _enterCreateName(WidgetTester tester, String name) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('bot-create-name')),
      matching: find.byType(TextField),
    ),
    name,
  );
  await _pumpCreateUi(tester);
}

Future<void> _pumpCreateUi(WidgetTester tester) async {
  // La preview Blobatar usa motion continuo opt-in. Avanzamos animaciones y
  // futures de forma acotada en vez de esperar a que un ticker infinito pare.
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// El botón "+" de la cabecera de Bots ya no crea un bot directamente: abre
/// un selector con "Nuevo bot"/"Nueva sala" (para que crear una sala siga
/// siendo posible con el dock apagado). Los tests que solo cubren el flujo
/// de bot pasan por ese selector primero.
Future<void> _openCreateBot(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mission-create-agent')));
  await _pumpCreateUi(tester);
  await tester.tap(find.byKey(const ValueKey('mission-create-chooser-bot')));
  await _pumpCreateUi(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  var failSecureReads = false;
  var secureWrites = 0;
  var secureDeletes = 0;

  setUp(() {
    secureStore.clear();
    failSecureReads = false;
    secureWrites = 0;
    secureDeletes = 0;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureWrites++;
                secureStore[args['key'] as String] = args['value'] as String;
              case 'read':
                if (failSecureReads) {
                  throw PlatformException(code: 'secure_unavailable');
                }
                return secureStore[args['key'] as String];
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'delete':
                secureDeletes++;
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

  test('Bot Chat destinations reuse the caller connection writably for every '
      'canonical state', () {
    const profile = AgentProfile(name: 'infra');
    for (final fixture in <({Session session, String? storedSessionId})>[
      (
        session: _session('existing-bot-chat', 'infra'),
        storedSessionId: 'existing-bot-chat',
      ),
      (
        session: _session('stored-pinned-bot-chat', 'infra'),
        storedSessionId: 'stored-pinned-bot-chat',
      ),
      (session: _session('mob-bot-infra', 'infra'), storedSessionId: null),
    ]) {
      final destination = buildBotChatDestination(
        connection: _connection,
        session: fixture.session,
        initialStoredSessionId: fixture.storedSessionId,
        profile: profile,
      );

      expect(destination.connection.readOnly, isFalse);
      expect(destination.session, same(fixture.session));
      expect(destination.initialStoredSessionId, fixture.storedSessionId);
      expect(destination.initialPrompt, isNull);
      expect(destination.requestComposerFocus, isFalse);
      expect(destination.missionBotProfile, same(profile));
    }
  });

  testWidgets('opens on the Bots roster with no Work destination', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'manager')],
          sessions: [_session('manager-session', 'manager')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mission-bots')), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-rooms')), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(
      find.byKey(const ValueKey('mission-destination-bots')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mission-destination-rooms')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mission-destination-team')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mission-destination-work')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('mission-goto-work')), findsNothing);
    expect(find.byKey(const ValueKey('mission-work-feed')), findsNothing);
    expect(find.byKey(const ValueKey('mission-workspace-button')), findsNothing);
    expect(find.text('Resumen'), findsNothing);
  });

  testWidgets('initial Bot notification reconstructs canonical Bot Chat', (
    tester,
  ) async {
    final manager = await _manager();
    Session? opened;
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(
              name: 'builder',
              canonicalSession: AgentProfileSessionSummary(id: 'stored-bot-1'),
            ),
          ],
          sessions: [_session('stored-bot-1', 'builder')],
        ),
        initialOpenTarget: const MissionControlOpenTarget.bot(
          sessionId: 'stored-bot-1',
          profile: 'builder',
        ),
        botChatOpenObserver: (session) => opened = session,
      ),
    );
    await tester.pumpAndSettle();

    expect(opened, isNotNull);
    expect(opened!.profile, 'builder');
    expect(opened!.lineageRootId, 'stored-bot-1');
    expect(opened!.source, 'bot-mode-canonical');
  });

  testWidgets('bot row opens its Bot Chat; long-press reaches the profile', (
    tester,
  ) async {
    final manager = await _manager();
    Session? opened;
    await tester.pumpWidget(
      _host(
        manager: manager,
        botChatOpenObserver: (session) => opened = session,
        snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mission-bots')), findsOneWidget);
    // Spec 070 S1: like a messenger, tapping the row opens the Bot Chat.
    await _openBotChat(tester, 'infra');
    expect(opened?.profile, 'infra');
    expect(opened?.title, 'Bot Chat');

    opened = null;
    await _openAgentDetail(tester, 'infra');
    expect(opened, isNull);
    expect(find.byKey(const ValueKey('bot-profile')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bot-profile-chat')));
    await tester.pumpAndSettle();
    expect(opened?.profile, 'infra');
  });

  testWidgets('working bot row prioritizes its task over chat preview', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          sessions: [_session('s-infra', 'infra')],
          board: const KanbanBoard(
            columns: [
              KanbanColumn(
                name: 'running',
                tasks: [
                  KanbanTask(
                    id: 'task-live',
                    title: 'Desplegar el gateway',
                    body: '',
                    status: 'running',
                    assignee: 'infra',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('mission-bot-infra'));
    expect(
      find.descendant(of: row, matching: find.textContaining('Desplegar')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('Recent work')),
      findsNothing,
    );
  });

  testWidgets('bot profile counts every assigned task', (tester) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          board: const KanbanBoard(
            columns: [
              KanbanColumn(
                name: 'running',
                tasks: [
                  KanbanTask(
                    id: 'task-a',
                    title: 'Desplegar gateway',
                    body: '',
                    status: 'running',
                    assignee: 'infra',
                  ),
                ],
              ),
              KanbanColumn(
                name: 'ready',
                tasks: [
                  KanbanTask(
                    id: 'task-b',
                    title: 'Revisar backups',
                    body: '',
                    status: 'ready',
                    assignee: 'infra',
                  ),
                  KanbanTask(
                    id: 'task-c',
                    title: 'Rotar certificados',
                    body: '',
                    status: 'ready',
                    assignee: 'infra',
                  ),
                  KanbanTask(
                    id: 'task-d',
                    title: 'Documentar recuperación',
                    body: '',
                    status: 'ready',
                    assignee: 'other',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openAgentDetail(tester, 'infra');

    final tasks = find.byKey(const ValueKey('bot-profile-tasks'));
    await tester.scrollUntilVisible(tasks, 200);
    expect(
      find.descendant(of: tasks, matching: find.text('3')),
      findsOneWidget,
    );
  });

  testWidgets('bot profile groups every action around the bot', (
    tester,
  ) async {
    final manager = await _manager();
    Session? opened;
    await tester.pumpWidget(
      _host(
        manager: manager,
        botChatOpenObserver: (session) => opened = session,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'infra', botModeUiMeta: {'title': 'Infra'}),
          ],
          sessions: [_session('s-infra', 'infra')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openAgentDetail(tester, 'infra');

    expect(find.byKey(const ValueKey('bot-profile')), findsOneWidget);
    expect(find.text('Infra'), findsWidgets);
    for (final key in const [
      'bot-profile-chat',
      'bot-profile-rooms',
      'bot-profile-routines',
      'bot-profile-now',
      'bot-profile-model',
      'bot-profile-reasoning',
      'bot-profile-soul',
      'bot-profile-skills',
      'bot-profile-memory',
      'bot-profile-tasks',
      'bot-profile-machine',
    ]) {
      await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 200);
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bot-profile-chat')),
      -200,
    );
    await tester.tap(find.byKey(const ValueKey('bot-profile-chat')));
    await tester.pumpAndSettle();
    expect(opened?.profile, 'infra');
  });

  testWidgets('long-press persists pin and hidden roster metadata', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _FakeBotCreateGateway();
    await tester.pumpWidget(
      _host(
        manager: manager,
        profileAssetsGateway: gateway,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openRosterActions(tester, 'infra');
    await tester.tap(find.byKey(const ValueKey('roster-action-togglePin')));
    await tester.pumpAndSettle();
    expect(gateway.metaPinned, isTrue);

    await _openRosterActions(tester, 'infra');
    await tester.tap(find.byKey(const ValueKey('roster-action-toggleHidden')));
    await tester.pumpAndSettle();
    expect(gateway.metaHidden, isTrue);
  });

  testWidgets('long-press writes pin, hidden and section to ui_meta', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _UiMetaGateway();
    await tester.pumpWidget(
      _host(
        manager: manager,
        botProfileGateway: gateway,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'infra'),
            AgentProfile(
              name: 'qa',
              botModeUiMeta: {'sectionId': 'ops', 'sectionName': 'Ops'},
            ),
          ],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openRosterActions(tester, 'infra');
    await tester.tap(find.byKey(const ValueKey('roster-action-togglePin')));
    await tester.pumpAndSettle();
    await _openRosterActions(tester, 'infra');
    await tester.tap(find.byKey(const ValueKey('roster-action-toggleHidden')));
    await tester.pumpAndSettle();
    await _openRosterActions(tester, 'infra');
    await tester.tap(find.byKey(const ValueKey('roster-action-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ops').last);
    await tester.pumpAndSettle();

    // Desktop-compatible keys in ui_meta['hermes-bots']; every write drops
    // the legacy `chat` pointer (T208).
    expect(gateway.patches.map((p) => p.$1), ['infra', 'infra', 'infra']);
    expect(gateway.patches.map((p) => p.$2).toList(), [
      {'pinned': true},
      {'hidden': true},
      {'sectionId': 'ops', 'sectionName': 'Ops'},
    ]);
    expect(gateway.patches.every((p) => p.$3.contains('chat')), isTrue);
  });

  testWidgets('header offers New bot / New room without a floating button', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Trabajo · 0 salas'), findsNothing);
    final newButton = find.byKey(const ValueKey('mission-create-agent'));
    expect(
      find.ancestor(of: newButton, matching: find.byType(AppBar)),
      findsOneWidget,
    );
    await tester.tap(newButton);
    await tester.pumpAndSettle();
    final chooserBot = find.byKey(const ValueKey('mission-create-chooser-bot'));
    expect(chooserBot, findsOneWidget);
    // "New profile" wears the profile icon, as Profiles and the switcher do.
    expect(
      find.descendant(
        of: chooserBot,
        matching: find.byIcon(Icons.account_circle_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chooserBot,
        matching: find.byIcon(Icons.smart_toy_outlined),
      ),
      findsNothing,
    );
  });

  testWidgets('bot profile reads as hero identity, Now and model', (
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
              model: 'gpt-5.5',
              provider: 'openai',
              botModeUiMeta: {'title': 'Infra'},
            ),
          ],
          sessions: [_session('s-infra', 'infra')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openAgentDetail(tester, 'infra');

    expect(find.byKey(const ValueKey('bot-profile-hero')), findsOneWidget);
    expect(find.text('Infra'), findsWidgets);
    expect(find.textContaining('@infra'), findsOneWidget);
    expect(find.text('Ahora mismo no está trabajando'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bot-profile-model')),
      200,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bot-profile-model')),
        matching: find.text('openai · gpt-5.5'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('rooms and the task board stay reachable with the dock off', (
    tester,
  ) async {
    final manager = await _manager();
    final dock = DockPreferencesController.instance;
    await dock.setUseDock(false);
    addTearDown(() => dock.setUseDock(true));
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'infra'),
            AgentProfile(name: 'qa'),
          ],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Sin dock no hay tiles de destino…
    expect(find.byKey(const ValueKey('bot-mode-floating-dock')), findsNothing);
    expect(
      find.byKey(const ValueKey('mission-destination-work')),
      findsNothing,
    );

    // …and nothing is lost: the header "New" menu still reaches new rooms,
    // room management and the shared task board.
    expect(find.byKey(const ValueKey('mission-goto-work')), findsNothing);
    await _openNewMenu(tester);
    expect(
      find.byKey(const ValueKey('mission-create-chooser-board')),
      findsOneWidget,
    );
    expect(find.text('Tablero de tareas'), findsOneWidget);
    expect(find.text('Gestionar salas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bot row shows the canonical Bot Chat preview and time', (
    tester,
  ) async {
    final manager = await _manager();
    // Preview/time come from profiles.list canonical_session (spec 070 T206),
    // never from the legacy ui_meta pin nor a local session list.
    final official = AgentProfile.fromJson({
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {'chat': 'legacy-ignored'},
      },
      'canonical_session': {
        'id': 'stored-official',
        'title': 'Bot Chat',
        'preview': 'Última respuesta del bot',
        'last_active': 120,
        'message_count': 4,
      },
    });
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: [official],
          sessions: [
            Session(
              id: 'stored-official',
              title: 'Bot Chat',
              model: 'model-infra',
              source: 'bot-mode',
              messageCount: 4,
              isActive: true,
              preview: 'Última respuesta del bot',
              startedAt: 100,
              updatedAt: 120,
              profile: 'infra',
            ),
          ],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Última respuesta del bot'), findsOneWidget);
    expect(find.text('Inactivo · Última respuesta del bot'), findsNothing);
    expect(find.text('Bot Chat'), findsNothing);
  });

  testWidgets('destination semantics expose the current place', (tester) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'manager')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();

    final bots = find.byKey(const ValueKey('mission-destination-bots'));
    expect(
      tester.getSemantics(bots).getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'Bots debe publicar la acción tap en Android',
    );
    expect(tester.getSemantics(bots).getSemanticsData().label, 'Bots');
    expect(
      tester.getSemantics(bots).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    // Bots is the only destination of this screen: no Work tile.
    expect(
      find.byKey(const ValueKey('mission-destination-work')),
      findsNothing,
    );
    semantics.dispose();
  });

  testWidgets('degrades cleanly with one backend profile and no Kanban', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(
              name: 'default',
              isDefault: true,
              model: 'qwen',
              provider: 'local',
            ),
          ],
          sessions: [_session('s-default', 'default')],
          kanbanCapability: MissionCapabilityState.unsupported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bots'), findsWidgets);
    expect(find.text('default'), findsWidgets);
    // Spec 070 S1: no Activo/Inactivo labels; idle rows show the preview.
    expect(find.text('Inactivo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'organization selection filters real profiles without cloning them',
    (tester) async {
      final manager = await _manager();
      final store = MissionOrganizationStore(manager.prefs);
      await store.save(
        connectionId: _connection.id,
        name: 'Homelab',
        profileNames: const ['infra'],
        managerProfile: 'infra',
      );
      final snapshot = _snapshot(
        profiles: const [
          AgentProfile(name: 'infra', model: 'qwen', provider: 'local'),
          AgentProfile(name: 'security', model: 'cloud', provider: 'router'),
        ],
        sessions: [_session('s-infra', 'infra'), _session('s-sec', 'security')],
        board: const KanbanBoard(columns: []),
      );
      await tester.pumpWidget(
        _host(manager: manager, snapshot: snapshot, store: store),
      );
      await tester.pumpAndSettle();

      expect(find.text('infra'), findsWidgets);
      expect(find.text('security'), findsWidgets);
      await _openWorkspaces(tester);
      await tester.tap(find.text('Homelab').last);
      await tester.pumpAndSettle();
      expect(find.text('infra'), findsWidgets);
      expect(find.text('security'), findsNothing);
    },
  );

  testWidgets('workspace without manager never renders a null handle', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionOrganizationStore(manager.prefs);
    await store.save(
      connectionId: _connection.id,
      name: 'Sin manager',
      profileNames: const ['infra'],
    );
    await tester.pumpWidget(
      _host(
        manager: manager,
        store: store,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openWorkspaces(tester);
    expect(find.text('Sin manager'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-workspace-sheet')),
        matching: find.text('1 perfil'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('@null'), findsNothing);
  });

  testWidgets(
    'Console-local Bot Chat pins are retired, never used as identity',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      await botStore.save(
        connectionId: _connection.id,
        profile: 'infra',
        sessionId: 'stored-local-keep',
      );
      Session? opened;
      final appearanceOnly = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {'title': 'Infra', 'shape': 'blobatar'},
        },
      });
      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [appearanceOnly]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');
      // Desktop invariant: the only identity is the "Bot Chat" title row.
      expect(opened?.lineageRootId, isNull);
      expect(opened?.source, 'mobile-bot');
      expect(await botStore.load(_connection.id, 'infra'), isNull);
    },
  );

  testWidgets(
    'legacy ui_meta chat pin or explicit null reset is ignored and local pins retired',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      await botStore.save(
        connectionId: _connection.id,
        profile: 'infra',
        sessionId: 'stored-local-old',
      );
      Session? opened;
      final official = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {'chat': 'stored-official'},
        },
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [official]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');

      expect(opened?.lineageRootId, isNull);
      expect(opened?.source, 'mobile-bot');
      expect(await botStore.load(_connection.id, 'infra'), isNull);

      await botStore.save(
        connectionId: _connection.id,
        profile: 'infra',
        sessionId: 'stored-must-not-resurrect',
      );
      opened = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final officialAbsence = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': <String, dynamic>{'chat': null},
        },
      });
      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [officialAbsence]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');

      expect(opened?.lineageRootId, isNull);
      expect(opened?.source, 'mobile-bot');
      expect(await botStore.load(_connection.id, 'infra'), isNull);
    },
  );

  testWidgets(
    'appearance-only metadata resumes the existing hidden Bot Chat via '
    'canonical_session instead of orphaning it (issue #11)',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      Session? opened;
      // Stock Hermes Agent install: `hermes-bots` carries appearance only
      // (no `chat` key at all — not even `null`), but the profile already
      // has a hidden "Bot Chat" session with real history. The gateway
      // resolves it server-side by title and reports it as
      // `canonical_session` on `profiles.list`.
      final appearanceOnlyWithHistory = AgentProfile.fromJson({
        'name': 'self-hosted',
        'ui_meta': {
          'hermes-bots': {'title': 'Ops', 'shape': 'cloud'},
        },
        'canonical_session': {
          'id': 'canon-bot-chat-1',
          'root_title': 'Bot Chat',
          'title': 'Bot Chat',
          'message_count': 340,
        },
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [appearanceOnlyWithHistory]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'self-hosted');

      // Resumes the existing canonical row instead of minting a new,
      // zero-message hidden session on every attempt.
      expect(opened?.lineageRootId, 'canon-bot-chat-1');
      expect(opened?.source, 'bot-mode-canonical');
    },
  );

  testWidgets(
    'canonical Bot Chat tip supersedes a stale official metadata pin',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      Session? opened;
      final profile = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {'chat': 'stale-official'},
        },
        'canonical_session': {
          'id': 'canonical-root',
          'resolved_id': 'canonical-tip',
        },
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [profile]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');

      expect(opened?.lineageRootId, 'canonical-tip');
      expect(opened?.source, 'bot-mode-canonical');
    },
  );

  testWidgets(
    'canonical Bot Chat bypasses a corrupt stale local compatibility pin',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      await botStore.save(
        connectionId: _connection.id,
        profile: 'infra',
        sessionId: 'stale-local',
      );
      secureStore[secureStore.keys.single] = 'bad\nsession';
      Session? opened;
      final profile = AgentProfile.fromJson({
        'name': 'infra',
        'canonical_session': {'id': 'canonical-root'},
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [profile]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');

      expect(opened?.lineageRootId, 'canonical-root');
      expect(opened?.source, 'bot-mode-canonical');
      expect(
        find.textContaining('No se pudo verificar el Bot Chat'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'canonical Bot Chat remains usable when deprecated pin metadata is malformed',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      Session? opened;
      final profile = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {'chat': 42},
        },
        'canonical_session': {'id': 'canonical-root'},
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [profile]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');

      expect(opened?.lineageRootId, 'canonical-root');
      expect(opened?.source, 'bot-mode-canonical');
      expect(
        find.textContaining('No se pudo verificar el Bot Chat'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'remote Bot Chat also opens the server-resolved canonical lineage tip',
    (tester) async {
      final manager = await _manager();
      final remote = SavedConnection(
        id: 'remote-canonical',
        label: 'Remote Lab',
        host: 'remote.invalid',
        port: 8642,
        apiKey: 'test-only',
      );
      await manager.upsertConnection(remote);
      Session? opened;
      final remoteProfile = AgentProfile.fromJson({
        'name': 'remote-infra',
        'ui_meta': {
          'hermes-bots': {
            'title': 'Remote Canonical',
            'chat': 'stale-remote-pin',
          },
        },
        'canonical_session': {'id': 'remote-root', 'resolved_id': 'remote-tip'},
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatOpenObserver: (session) => opened = session,
          remoteBotLoader: (_) async => [remoteProfile],
          snapshot: _snapshot(profiles: const [AgentProfile(name: 'local')]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remote Canonical'));
      await tester.pumpAndSettle();

      expect(opened?.lineageRootId, 'remote-tip');
      expect(opened?.source, 'bot-mode-canonical');
      expect(opened?.profile, 'remote-infra');
    },
  );

  testWidgets(
    'an explicit null official pin opens the Bot Chat instead of blocking',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      Session? opened;
      // Desktop resets a lost canonical pin by writing `chat: null`; the
      // gateway returns that null verbatim. Opening must defer to the
      // create-on-first-submit flow, not block with the verification snackbar.
      final officialNull = AgentProfile.fromJson({
        'name': 'codex-qa',
        'ui_meta': {
          'hermes-bots': {'chat': null, 'title': 'QA'},
        },
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [officialNull]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'codex-qa');

      expect(opened, isNotNull);
      expect(opened?.lineageRootId, isNull);
      expect(opened?.source, 'mobile-bot');
      expect(
        find.textContaining('No se pudo verificar el Bot Chat'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'explicit null legacy metadata cannot suppress the canonical Bot Chat',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      Session? opened;
      final profile = AgentProfile.fromJson({
        'name': 'codex-qa',
        'ui_meta': {
          'hermes-bots': {'chat': null, 'title': 'QA'},
        },
        'canonical_session': {
          'id': 'canonical-root',
          'resolved_id': 'canonical-tip',
        },
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [profile]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'codex-qa');

      expect(opened?.lineageRootId, 'canonical-tip');
      expect(opened?.source, 'bot-mode-canonical');
    },
  );

  testWidgets('read-only Bot Chat open performs no local mutation', (
    tester,
  ) async {
    final manager = await _manager();
    final botStore = MissionBotChatStore(manager.prefs);
    await botStore.save(
      connectionId: _connection.id,
      profile: 'infra',
      sessionId: 'stored-local-must-remain',
    );
    secureWrites = 0;
    secureDeletes = 0;
    Session? opened;
    final official = AgentProfile.fromJson({
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {'chat': 'stored-official'},
      },
    });

    await tester.pumpWidget(
      _host(
        manager: manager,
        connection: _connection.copyWith(readOnly: true),
        botChatStore: botStore,
        botChatOpenObserver: (session) => opened = session,
        snapshot: _snapshot(profiles: [official]),
      ),
    );
    await tester.pumpAndSettle();
    await _openBotChat(tester, 'infra');

    expect(opened?.lineageRootId, isNull);
    expect(opened?.source, 'mobile-bot');
    expect(secureWrites, 0);
    expect(secureDeletes, 0);
    expect(secureStore.values, contains('stored-local-must-remain'));
  });

  testWidgets('Bot Chat registry failure blocks creation instead of forking', (
    tester,
  ) async {
    final manager = await _manager();
    Session? opened;
    final lookup = FakeBotChatTitleLookup()..fail = true;

    await tester.pumpWidget(
      _host(
        manager: manager,
        botChatOpenObserver: (session) => opened = session,
        botChatTitleLookup: lookup,
        snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
      ),
    );
    await tester.pumpAndSettle();
    await _openBotChat(tester, 'infra');

    expect(lookup.calls, ['infra']);
    expect(opened, isNull);
    expect(
      find.textContaining('No se pudo verificar el Bot Chat'),
      findsOneWidget,
    );
  });

  testWidgets(
    'without canonical_session the title registry row is opened, not forked',
    (tester) async {
      final manager = await _manager();
      Session? opened;
      final lookup = FakeBotChatTitleLookup({
        'infra': const AgentProfileSessionSummary(
          id: 'registry-root',
          resolvedId: 'registry-tip',
          title: 'Bot Chat',
        ),
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatOpenObserver: (session) => opened = session,
          botChatTitleLookup: lookup,
          snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');

      expect(opened?.lineageRootId, 'registry-tip');
      expect(opened?.source, 'bot-mode-canonical');
    },
  );

  testWidgets('Bot Chat refreshes its canonical pin before it is reopened', (
    tester,
  ) async {
    final manager = await _manager();
    final before = AgentProfile.fromJson({
      'name': 'manager',
      'ui_meta': {
        'hermes-bots': {'group': 'Homelab'},
      },
    });
    final after = AgentProfile.fromJson({
      'name': 'manager',
      'ui_meta': {
        'hermes-bots': {'group': 'Homelab'},
      },
      'canonical_session': {'id': 'stored-canonical-manager'},
    });
    final initial = _snapshot(profiles: [before]);
    final refreshed = _snapshot(profiles: [after]);
    final source = _SequenceSource([
      Future.value(initial),
      Future.value(refreshed),
      Future.value(refreshed),
    ]);
    final opened = <Session>[];

    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: initial,
        dataSource: source,
        botChatOpenObserver: opened.add,
      ),
    );
    await tester.pumpAndSettle();

    Future<void> openManagerChat() async {
      await _openBotChat(tester, 'manager');
    }

    await openManagerChat();
    await openManagerChat();

    expect(opened, hasLength(2));
    expect(opened.first.source, 'mobile-bot');
    expect(opened.first.lineageRootId, isNull);
    expect(opened.last.source, 'bot-mode-canonical');
    expect(opened.last.lineageRootId, 'stored-canonical-manager');
    expect(source.loadCount, 3);
  });

  testWidgets('observed Hermes approval appears in the attention rail', (
    tester,
  ) async {
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final session = _session('s-approval', 'infra');
    final chat = chats.attach(
      connection: _connection,
      sessionId: session.id,
      sessionTitle: session.title,
      sessionProfile: 'infra',
      sessionSnapshot: session,
      disableForegroundKeepAlive: true,
    );
    chat.state = ChatPipelineState.executing;
    chat.pendingApproval = {
      'request_id': 'approval-1',
      'description': 'Restart Proxmox node',
      'risk': 'high',
    };

    Session? opened;

    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          sessions: [session],
          board: const KanbanBoard(columns: []),
        ),
        botChatOpenObserver: (session) => opened = session,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Te necesitan'), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-attention')), findsOneWidget);
    expect(find.text('Restart Proxmox node'), findsNothing);
    expect(find.textContaining('approval-1'), findsNothing);
    // One approval: the row opens that Bot's chat directly (no Work feed).
    await tester.tap(find.byKey(const ValueKey('mission-attention')));
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened!.profile, 'infra');
    expect(find.byKey(const ValueKey('mission-work-feed')), findsNothing);
  });

  testWidgets('Bot approval opens canonical Bot Chat and returns to Bots', (
    tester,
  ) async {
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final session = _session('stored-bot-approval', 'infra');
    final chat = chats.attach(
      connection: _connection,
      sessionId: 'mob-bot-infra',
      sessionTitle: 'Bot Chat',
      sessionProfile: 'infra',
      sessionSnapshot: session,
      initialStoredSessionId: session.id,
      notificationSurface: NotificationChatSurface.bot,
      disableForegroundKeepAlive: true,
    );
    chat
      ..state = ChatPipelineState.executing
      ..pendingApproval = {
        'request_id': 'approval-bot',
        'description': 'Review release',
      };
    Session? opened;

    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(
              name: 'infra',
              canonicalSession: AgentProfileSessionSummary(
                id: 'stored-bot-approval',
              ),
            ),
          ],
          sessions: [session],
          board: const KanbanBoard(columns: []),
        ),
        botChatOpenObserver: (session) => opened = session,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mission-attention')));
    await tester.pumpAndSettle();

    expect(opened, isNotNull);
    expect(opened!.source, 'bot-mode-canonical');
    expect(opened!.lineageRootId, 'stored-bot-approval');
    expect(find.byKey(const ValueKey('mission-bots')), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-work-feed')), findsNothing);
  });

  testWidgets('multiple approvals open a chooser instead of one request', (
    tester,
  ) async {
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final infraSession = _session('s-approval-infra', 'infra');
    final qaSession = _session('s-approval-qa', 'qa');
    final infraChat = chats.attach(
      connection: _connection,
      sessionId: infraSession.id,
      sessionTitle: infraSession.title,
      sessionProfile: 'infra',
      sessionSnapshot: infraSession,
      disableForegroundKeepAlive: true,
    );
    final qaChat = chats.attach(
      connection: _connection,
      sessionId: qaSession.id,
      sessionTitle: qaSession.title,
      sessionProfile: 'qa',
      sessionSnapshot: qaSession,
      disableForegroundKeepAlive: true,
    );
    infraChat
      ..state = ChatPipelineState.executing
      ..pendingApproval = {
        'request_id': 'approval-infra',
        'description': 'Restart node',
      };
    qaChat
      ..state = ChatPipelineState.executing
      ..pendingApproval = {
        'request_id': 'approval-qa',
        'description': 'Publish release',
      };

    Session? opened;
    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'infra'),
            AgentProfile(name: 'qa'),
          ],
          sessions: [infraSession, qaSession],
          board: const KanbanBoard(columns: []),
        ),
        botChatOpenObserver: (session) => opened = session,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 aprobaciones · 0 bloqueados'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mission-attention')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-attention-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-work-feed')), findsNothing);
    expect(find.text('Aprobación pendiente'), findsNWidgets(2));
    expect(find.text('Restart node'), findsNothing);
    expect(find.text('Publish release'), findsNothing);
    expect(opened, isNull);

    await tester.tap(
      find.byKey(const ValueKey('mission-attention-approval-qa')),
    );
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened!.profile, 'qa');
  });

  testWidgets('empty and incompatible profile states remain actionable', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profilesCapability: MissionCapabilityState.unsupported,
          kanbanCapability: MissionCapabilityState.unsupported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Esta instalación de Hermes no publica perfiles.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mission-create-agent')), findsOneWidget);
  });

  testWidgets('unknown usage is not rendered as a published zero', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          sessions: const [],
          board: const KanbanBoard(
            columns: [
              KanbanColumn(
                name: 'ready',
                tasks: [
                  KanbanTask(
                    id: 'ready-1',
                    title: 'Audit services',
                    body: '',
                    status: 'ready',
                    assignee: 'infra',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tokens no publicados'), findsNothing);
    expect(find.text('Uso'), findsNothing);
    expect(find.text('Coste no publicado'), findsNothing);
    expect(find.text(r'$0.0000'), findsNothing);
    // Tasks live on the shared board, never as a pending tray in Bots.
    expect(find.text('OTROS PENDIENTES'), findsNothing);
  });

  testWidgets('the shared task board opens from the New menu', (tester) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          sessions: [_session('session-infra', 'infra')],
          board: const KanbanBoard(
            columns: [
              KanbanColumn(
                name: 'blocked',
                tasks: [
                  KanbanTask(
                    id: 'task-blocked',
                    title: 'Repair backup',
                    body: '',
                    status: 'blocked',
                    assignee: 'infra',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No task tray or board section on the Bots screen any more.
    expect(find.text('Repair backup'), findsNothing);
    expect(find.text('TABLERO DE TAREAS'), findsNothing);
    expect(
      find.byKey(const ValueKey('mission-open-global-kanban')),
      findsNothing,
    );

    await _openNewMenu(tester);
    final board = find.byKey(const ValueKey('mission-create-chooser-board'));
    expect(
      find.descendant(of: board, matching: find.text('Tablero de tareas')),
      findsOneWidget,
    );
    await tester.tap(board);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TasksScreen), findsOneWidget);
  });

  testWidgets('partial refresh retains last good source and marks it stale', (
    tester,
  ) async {
    final manager = await _manager();
    final initial = _snapshot(
      profiles: const [AgentProfile(name: 'infra')],
      sessions: [_session('s-infra', 'infra')],
      board: const KanbanBoard(
        columns: [
          KanbanColumn(
            name: 'running',
            tasks: [
              KanbanTask(
                id: 'cached-task',
                title: 'Cached native task',
                body: '',
                status: 'running',
                assignee: 'infra',
              ),
            ],
          ),
        ],
      ),
    );
    final partial = MissionBackendSnapshot(
      sessions: initial.sessions,
      profilesCapability: MissionCapabilityState.unavailable,
      sessionsCapability: MissionCapabilityState.available,
      kanbanCapability: MissionCapabilityState.unavailable,
      failures: {
        'profiles': StateError('temporary failure'),
        'kanban': StateError('temporary failure'),
      },
      loadedAt: DateTime.fromMillisecondsSinceEpoch(121000),
    );
    final source = _SequenceSource([
      Future.value(initial),
      Future.value(partial),
    ]);
    await tester.pumpWidget(
      _host(manager: manager, snapshot: initial, dataSource: source),
    );
    await tester.pumpAndSettle();

    await _pullToRefresh(tester);
    await tester.pumpAndSettle();

    expect(find.text('infra'), findsWidgets);
    expect(
      find.text('Algunos datos de los perfiles pueden estar desactualizados.'),
      findsOneWidget,
    );
  });

  testWidgets('unsupported refresh discards cached data without saying offline', (
    tester,
  ) async {
    final manager = await _manager();
    final initial = _snapshot(
      profiles: const [AgentProfile(name: 'infra')],
      sessions: [_session('s-infra', 'infra')],
      board: const KanbanBoard(
        columns: [
          KanbanColumn(
            name: 'running',
            tasks: [
              KanbanTask(
                id: 'old-task',
                title: 'Old cached task',
                body: '',
                status: 'running',
                assignee: 'infra',
              ),
            ],
          ),
        ],
      ),
    );
    final unsupported = MissionBackendSnapshot(
      profilesCapability: MissionCapabilityState.unsupported,
      sessionsCapability: MissionCapabilityState.unsupported,
      kanbanCapability: MissionCapabilityState.unsupported,
      failures: const {
        'profiles': 'HTTP 404',
        'sessions': 'HTTP 404',
        'kanban': 'HTTP 404',
      },
      loadedAt: DateTime.fromMillisecondsSinceEpoch(122000),
    );
    final source = _SequenceSource([
      Future.value(initial),
      Future.value(unsupported),
    ]);
    await tester.pumpWidget(
      _host(manager: manager, snapshot: initial, dataSource: source),
    );
    await tester.pumpAndSettle();

    await _pullToRefresh(tester);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Hermes no está disponible. Los datos de los perfiles que ya tienes siguen visibles.',
      ),
      findsNothing,
    );
    expect(
      find.text('Esta instalación de Hermes no publica perfiles.'),
      findsOneWidget,
    );
    expect(find.text('Old cached task'), findsNothing);
  });

  testWidgets('read-only Mission Control disables profile management', (
    tester,
  ) async {
    final manager = await _manager();
    final readOnlyConnection = SavedConnection(
      id: 'mission-read-only',
      label: 'Mission read only',
      host: 'hermes.local',
      port: 8642,
      apiKey: 'test-only',
      readOnly: true,
    );
    await tester.pumpWidget(
      _host(
        manager: manager,
        connection: readOnlyConnection,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          sessions: [_session('s-infra', 'infra')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openWorkspaces(tester);
    expect(find.text('Crear espacio de trabajo'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Read-only: long-press offers no mutation, the profile opens but its
    // model/reasoning rows and identity editing are not interactive.
    await _openRosterActions(tester, 'infra');
    expect(find.byKey(const ValueKey('roster-action-togglePin')), findsNothing);
    expect(
      find.byKey(const ValueKey('roster-action-toggleHidden')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('roster-action-section')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('roster-action-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-profile')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bot-profile-edit-identity')),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bot-profile-model')),
      200,
    );
    final modelRow = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('bot-profile-model')),
        matching: find.byType(InkWell),
      ),
    );
    expect(modelRow.onTap, isNull);
  });

  testWidgets('Kanban live updates debounce and pause with Android lifecycle', (
    tester,
  ) async {
    final manager = await _manager();
    final source = _WatchSource(
      _snapshot(
        profiles: const [AgentProfile(name: 'infra')],
        board: const KanbanBoard(columns: [], latestEventId: 10),
      ),
    );
    addTearDown(source.events.close);
    await tester.pumpWidget(
      _host(manager: manager, snapshot: source.snapshot, dataSource: source),
    );
    await tester.pumpAndSettle();
    expect(source.loadCount, 1);
    expect(source.watchCount, 1);

    source.events
      ..add(const KanbanEvent(id: 11, kind: 'task.updated'))
      ..add(const KanbanEvent(id: 12, kind: 'task.updated'));
    await tester.pump(const Duration(milliseconds: 349));
    expect(source.loadCount, 1);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();
    expect(source.loadCount, 2);
    expect(source.watchCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    source.events.add(const KanbanEvent(id: 13, kind: 'task.updated'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(source.loadCount, 2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(source.loadCount, 3);
    expect(source.watchCount, 2);
  });

  testWidgets('roster refresh sleeps in background and restarts on resume', (
    tester,
  ) async {
    final manager = await _manager();
    final source = _WatchSource(
      _snapshot(
        profiles: const [AgentProfile(name: 'infra')],
        board: const KanbanBoard(columns: [], latestEventId: 10),
      ),
    );
    addTearDown(source.events.close);
    await tester.pumpWidget(
      _host(manager: manager, snapshot: source.snapshot, dataSource: source),
    );
    await tester.pumpAndSettle();
    expect(source.loadCount, 1);

    await tester.pump(const Duration(seconds: 10));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 25));
    expect(source.loadCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(source.loadCount, 2);

    // The stale background tick (t=60 s) must not reload 25 s after resume.
    await tester.pump(const Duration(seconds: 28));
    expect(source.loadCount, 2);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(source.loadCount, 3);
  });

  testWidgets('newer refresh wins when loads complete out of order', (
    tester,
  ) async {
    final manager = await _manager();
    final first = Completer<MissionBackendSnapshot>();
    final second = Completer<MissionBackendSnapshot>();
    final source = _SequenceSource([first.future, second.future]);
    final placeholder = _snapshot();
    await tester.pumpWidget(
      _host(manager: manager, snapshot: placeholder, dataSource: source),
    );
    await tester.pump();

    // Initial load still pending: a lifecycle resume starts the newer read.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    second.complete(_snapshot(profiles: const [AgentProfile(name: 'newer')]));
    await tester.pumpAndSettle();
    first.complete(_snapshot(profiles: const [AgentProfile(name: 'older')]));
    await tester.pumpAndSettle();

    expect(find.text('newer'), findsWidgets);
    expect(find.text('older'), findsNothing);
  });

  testWidgets('overview fits 320 dp at 200 percent text scale', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        textScale: 2,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(
              name: 'infra',
              model: 'local-model-with-a-long-name',
              provider: 'local-endpoint',
            ),
          ],
          sessions: [_session('s-infra', 'infra')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openNewMenu(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('mission-create-chooser-board')),
      findsOneWidget,
    );
  });

  testWidgets('large teams scroll the full bot roster on the first surface', (
    tester,
  ) async {
    final manager = await _manager();
    final profiles = List.generate(
      8,
      (index) => AgentProfile(name: 'agent_$index'),
    );
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: profiles,
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('agent_0'), findsOneWidget);
    expect(find.text('agent_1'), findsOneWidget);
    expect(find.text('agent_7'), findsNothing);
    final rosterScroll = find
        .descendant(
          of: find.byKey(const ValueKey('mission-bots')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('agent_7'),
      180,
      scrollable: rosterScroll,
    );
    expect(find.text('agent_7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '50 profiles, bots roster, detail and editor fit 320 dp at 200 percent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final manager = await _manager();
      final profiles = List.generate(
        50,
        (index) =>
            AgentProfile(name: 'agent_${index.toString().padLeft(2, '0')}'),
      );
      final sessions = List.generate(
        50,
        (index) => _session(
          'session-$index',
          'agent_${index.toString().padLeft(2, '0')}',
        ),
      );
      await tester.pumpWidget(
        _host(
          manager: manager,
          textScale: 2,
          disableAnimations: true,
          snapshot: _snapshot(
            profiles: profiles,
            sessions: sessions,
            board: const KanbanBoard(columns: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mission-bots')), findsOneWidget);
      await _openAgentDetail(tester, 'agent_00');
      // El nombre del profile ya no se pinta como fila "Profile · valor": vive
      // en la cabecera de identidad como `@handle` (ficha rediseñada).
      expect(find.text('@agent_00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await _openWorkspaces(tester);
      expect(
        find.byKey(const ValueKey('mission-workspace-sheet')),
        findsOneWidget,
      );
      final workspaceScroll = find.descendant(
        of: find.byKey(const ValueKey('mission-workspace-sheet')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mission-workspace-create')),
        120,
        scrollable: workspaceScroll,
      );
      await tester.drag(workspaceScroll, const Offset(0, -80));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mission-workspace-create')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('organization-name')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bots roster sorts by recent activity like Bot Mode', (
    tester,
  ) async {
    final manager = await _manager();
    Session sessionAt(String id, String profile, double updatedAt) => Session(
      id: id,
      title: '$profile session',
      model: 'model-$profile',
      source: 'gateway',
      messageCount: 3,
      isActive: true,
      preview: 'Recent work',
      startedAt: updatedAt - 20,
      updatedAt: updatedAt,
      profile: profile,
    );
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'alpha'),
            AgentProfile(name: 'zeta'),
            AgentProfile(
              name: 'newborn',
              botModeUiMeta: {'created': 9999999999999},
            ),
          ],
          sessions: [
            sessionAt('s-alpha', 'alpha', 3000),
            sessionAt('s-zeta', 'zeta', 100),
          ],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final newbornY = tester.getTopLeft(
      find.byKey(const ValueKey('mission-bot-row-newborn')),
    );
    final alphaY = tester.getTopLeft(
      find.byKey(const ValueKey('mission-bot-row-alpha')),
    );
    final zetaY = tester.getTopLeft(
      find.byKey(const ValueKey('mission-bot-row-zeta')),
    );
    // El sello `created` de ui_meta encabeza la lista (Desktop: activityOf);
    // después manda la sesión más reciente, no la prioridad de estado.
    expect(newbornY.dy, lessThan(alphaY.dy));
    expect(alphaY.dy, lessThan(zetaY.dy));
  });

  testWidgets('bot waiting on the user carries the needs-you badge', (
    tester,
  ) async {
    final manager = await _manager();
    final chats = ActiveChatService();
    addTearDown(chats.dispose);
    final session = _session('s-approval', 'infra');
    final chat = chats.attach(
      connection: _connection,
      sessionId: session.id,
      sessionTitle: session.title,
      sessionProfile: 'infra',
      sessionSnapshot: session,
      disableForegroundKeepAlive: true,
    );
    chat.state = ChatPipelineState.executing;
    chat.pendingApproval = {
      'request_id': 'approval-1',
      'description': 'Restart Proxmox node',
      'risk': 'high',
    };

    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'infra'),
            AgentProfile(name: 'qa'),
          ],
          sessions: [session, _session('s-qa', 'qa')],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Spec 070 S1: one state signal on the face (attention ring) and the
    // bot listed under "Needs you" — no extra badge or dot on the row.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-bot-row-infra')),
        matching: find.byKey(const ValueKey('living-face-ring-attention')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-bot-row-qa')),
        matching: find.byKey(const ValueKey('living-face-ring-attention')),
      ),
      findsNothing,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('mission-bot-row-infra')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('roster-section-recent')))
            .dy,
      ),
    );
  });

  testWidgets(
    'creating an agent keeps the Bot Mode contract and opens Bot Chat history',
    (tester) async {
      final manager = await _manager();
      final gateway = _FakeBotCreateGateway();
      Session? opened;
      final empty = _snapshot(board: const KanbanBoard(columns: []));
      final withBot = _snapshot(
        profiles: const [AgentProfile(name: 'research-bot')],
        board: const KanbanBoard(columns: []),
      );
      final source = _SequenceSource([
        Future.value(empty),
        Future.value(withBot),
        Future.value(withBot),
      ]);
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: empty,
          dataSource: source,
          botCreateGateway: gateway,
          botChatOpenObserver: (session) => opened = session,
        ),
      );
      await tester.pumpAndSettle();

      // Empty state con CTA siempre visible, además del botón de cabecera.
      expect(
        find.text(
          'Un perfil tiene nombre, memoria, skills y chat propios. Crea el '
          'primero para empezar.',
        ),
        findsOneWidget,
      );
      await _openCreateBot(tester);
      expect(find.byKey(const ValueKey('bot-create-form')), findsOneWidget);

      await _enterCreateName(tester, 'Research Bot');
      // Slug estilo Desktop visible como handle y envío habilitado.
      expect(find.text('@research-bot'), findsOneWidget);

      await _scrollCreateFormTo(tester, 'bot-create-submit');
      await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
      await tester.pumpAndSettle();

      expect(gateway.calls, ['create', 'pet.disable', 'identity-meta', 'meta']);
      final created = gateway.createdProfile;
      expect(created, isNotNull);
      expect(created?['name'], 'research-bot');
      expect(created?['cloneFrom'], 'default');
      expect(created?['shareAuth'], true);
      expect(created?['noSkills'], false);
      expect(created?['model'], '');
      final soul = created?['soul'] as String? ?? '';
      expect(soul, contains('# research-bot'));
      expect(
        soul,
        contains(
          'You are research-bot, a persistent named agent '
          '(profile `research-bot`) on this machine.',
        ),
      );
      expect(gateway.metaProfile, 'research-bot');
      expect(gateway.metaCreatedAtMs, isNotNull);

      // After creation, Mission Control opens the canonical Bot Chat history
      // destination without submitting a kickoff turn.
      expect(opened, isNotNull);
      expect(opened?.profile, 'research-bot');
      expect(opened?.title, 'Bot Chat');
      expect(find.textContaining('@research-bot'), findsWidgets);
    },
  );

  testWidgets('create dialog disables submission for a taken slug', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _FakeBotCreateGateway();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          board: const KanbanBoard(columns: []),
        ),
        botCreateGateway: gateway,
      ),
    );
    await tester.pumpAndSettle();

    await _openCreateBot(tester);
    await _enterCreateName(tester, 'Infra');

    expect(find.text('Ya existe un perfil con este nombre.'), findsOneWidget);
    await _scrollCreateFormTo(tester, 'bot-create-submit');
    final submit = tester.widget<HermesPrimaryButton>(
      find.byKey(const ValueKey('bot-create-submit')),
    );
    expect(submit.onTap, isNull);
    await tester.binding.handlePopRoute();
    await _pumpCreateUi(tester);
    expect(find.text('¿Descartar cambios?'), findsOneWidget);
    expect(gateway.calls, isEmpty);
  });

  testWidgets(
    'skill selection degrades without profiles.describe and applies toggles',
    (tester) async {
      // "Personalizar" agrupa varias filas colapsables (mockup de crear
      // bot); un viewport más alto que el tamaño de prueba por defecto
      // evita que la fila "Skills" quede solo parcialmente visible tras
      // desplazar, que es suficiente para fallar el hit-test del tap.
      await tester.binding.setSurfaceSize(const Size(390, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final manager = await _manager();
      final gateway = _FakeBotCreateGateway()
        ..skills = const [
          DesktopProfileSkill(name: 'web', enabled: true),
          DesktopProfileSkill(name: 'shell', enabled: true),
        ];
      final withBot = _snapshot(
        profiles: const [
          AgentProfile(name: 'infra'),
          AgentProfile(name: 'ops'),
        ],
        board: const KanbanBoard(columns: []),
      );
      final source = _SequenceSource([
        Future.value(
          _snapshot(
            profiles: const [AgentProfile(name: 'infra')],
            board: const KanbanBoard(columns: []),
          ),
        ),
        Future.value(withBot),
        Future.value(withBot),
      ]);
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: withBot,
          dataSource: source,
          botCreateGateway: gateway,
          botChatOpenObserver: (_) {},
        ),
      );
      await tester.pumpAndSettle();

      await _openCreateBot(tester);
      // Skills es su propia fila colapsable en "Personalizar" (mockup de
      // Editar/Crear bot); ya no depende de expandir "Avanzado".
      await _scrollCreateFormTo(tester, 'bot-create-skills-row');
      await tester.tap(find.byKey(const ValueKey('bot-create-skills-row')));
      await _pumpCreateUi(tester);

      expect(gateway.calls, ['describe:default']);
      await _scrollCreateFormTo(tester, 'bot-create-skill-web');
      expect(
        find.byKey(const ValueKey('bot-create-skill-web')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('bot-create-skill-web')));
      await _pumpCreateUi(tester);

      await _scrollCreateFormTo(tester, 'bot-create-name', up: true);
      await _enterCreateName(tester, 'ops');
      await _scrollCreateFormTo(tester, 'bot-create-submit');
      await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
      await tester.pumpAndSettle();

      expect(gateway.calls, [
        'describe:default',
        'create',
        'disabled-skills',
        'pet.disable',
        'identity-meta',
        'meta',
      ]);
      expect(gateway.disabledSkills, ['web']);

      // Sin catálogo (gateway antiguo), la sección degrada con aviso.
      // The success notice floats over the header "New" button; let it go.
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      await _openCreateBot(tester);
      gateway.skills = null;
      await _scrollCreateFormTo(tester, 'bot-create-skills-row');
      await tester.tap(find.byKey(const ValueKey('bot-create-skills-row')));
      await _pumpCreateUi(tester);
      // La nota de degradación vive dentro de la fila "Skills".
      await _scrollCreateFormTo(tester, 'bot-create-skills-row');
      expect(
        find.text(
          'El catálogo de skills necesita un gateway más reciente '
          '(actualiza Hermes y reinícialo).',
        ),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('V13 dock expands real create actions without a route overlay', (
    tester,
  ) async {
    final manager = await _manager();
    final gateway = _FakeBotCreateGateway();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        manager: manager,
        botCreateGateway: gateway,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'infra'),
            AgentProfile(name: 'qa'),
          ],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('bot-mode-floating-dock')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('bot-mode-dock-create')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('bot-mode-create-actions')),
      findsOneWidget,
    );
    final orbitBot = find.byKey(const ValueKey('bot-mode-create-bot'));
    expect(orbitBot, findsOneWidget);
    expect(
      find.descendant(
        of: orbitBot,
        matching: find.byIcon(Icons.account_circle_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: orbitBot,
        matching: find.byIcon(Icons.smart_toy_outlined),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('bot-mode-create-room')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.byKey(const ValueKey('bot-mode-create-bot')));
    await _pumpCreateUi(tester);
    expect(find.byKey(const ValueKey('bot-create-form')), findsOneWidget);
  });

  // Antes, sin la capacidad `groups.create`, este mismo botón caía a crear
  // una "sala local" (spec 061: un chat de 1 bot disfrazado de sala, sin
  // interacción de equipo real). Ahora no hay sustituto: sin esa capacidad
  // el botón se deshabilita, tal cual, en vez de fingir una sala que
  // funciona distinto por debajo.
  testWidgets(
    'V13 Nueva sala action is disabled without the create capability',
    (tester) async {
      final manager = await _manager();
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: _snapshot(
            profiles: const [
              AgentProfile(name: 'infra'),
              AgentProfile(name: 'qa'),
            ],
            board: const KanbanBoard(columns: []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
      await tester.pumpAndSettle();
      final roomAction = find.byKey(const ValueKey('bot-mode-create-room'));
      expect(find.text('Nueva sala'), findsOneWidget);
      expect(tester.widget<InkWell>(roomAction).onTap, isNull);
    },
  );

  testWidgets(
    'V13 owning screen create orbs share the painted plus X and a vertical trajectory',
    (tester) async {
      final manager = await _manager();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          manager: manager,
          disableAnimations: false,
          snapshot: _snapshot(
            profiles: const [
              AgentProfile(name: 'infra'),
              AgentProfile(name: 'qa'),
            ],
            board: const KanbanBoard(columns: []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final plus = find.byKey(const ValueKey('bot-mode-dock-create'));
      final plusCenter = tester.getCenter(plus);
      await tester.tap(plus);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final bot = find.byKey(const ValueKey('bot-mode-create-bot'));
      final room = find.byKey(const ValueKey('bot-mode-create-room'));
      final botCenter = tester.getCenter(bot);
      final roomCenter = tester.getCenter(room);
      expect(botCenter.dx, plusCenter.dx);
      expect(roomCenter.dx, plusCenter.dx);
      expect(botCenter.dy, lessThan(roomCenter.dy));
      expect(tester.getRect(bot).overlaps(tester.getRect(room)), isFalse);
      expect(roomCenter.dy, lessThan(plusCenter.dy));

      await tester.pump(const Duration(milliseconds: 35));
      final laterBot = tester.getCenter(bot);
      expect(laterBot.dx, plusCenter.dx);
      expect(laterBot.dy, lessThan(botCenter.dy));
      expect(find.byKey(const ValueKey('bot-mode-create-bot')), findsOneWidget);

      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bot-mode-create-actions')),
        findsOneWidget,
      );
      expect(tester.getCenter(bot).dx, plusCenter.dx);
    },
  );

  for (final size in const [Size(360, 800), Size(390, 844)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets(
        'V13 owning screen coordinates safe viewport $size at ${scale}x with IME',
        (tester) async {
          final manager = await _manager();
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            _host(
              manager: manager,
              textScale: scale,
              viewInsets: const EdgeInsets.only(bottom: 280),
              viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
              snapshot: _snapshot(
                profiles: const [
                  AgentProfile(name: 'infra'),
                  AgentProfile(name: 'qa'),
                ],
                board: const KanbanBoard(columns: []),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final dock = find.byKey(const ValueKey('bot-mode-floating-dock'));
          expect(
            tester.getRect(dock).bottom,
            lessThanOrEqualTo(size.height - 290),
          );
          for (final key in const ['home', 'bots', 'create']) {
            final target = find.byKey(ValueKey('bot-mode-dock-$key'));
            expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
          }
          await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
          await tester.pumpAndSettle();
          final bot = find.byKey(const ValueKey('bot-mode-create-bot'));
          final room = find.byKey(const ValueKey('bot-mode-create-room'));
          expect(tester.getRect(bot).overlaps(tester.getRect(room)), isFalse);
          expect(
            tester.getRect(room).bottom,
            lessThan(tester.getRect(dock).top),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('V13 dock is absent from detail and modal routes', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'infra'),
            AgentProfile(name: 'qa'),
          ],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openAgentDetail(tester, 'infra');
    expect(find.byKey(const ValueKey('bot-profile')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-mode-floating-dock')), findsNothing);
    // La sala local (con su propio modal "mission-room-editor") ya no existe
    // (spec 061). Reconstruir aquí la capacidad `groups.create` solo para
    // repetir esta misma comprobación de "el dock no vive en el modal, vive
    // en la pantalla que lo empuja" contra la sala real sería duplicar un
    // fixture completo (ver `mission_control_hosted_groups_test.dart`) por
    // una propiedad genérica del `Navigator`, ya probada arriba contra la
    // ficha de agente.
  });

  testWidgets(
    'V13 mechanical owning-screen slop audit has only allowed surfaces',
    (tester) async {
      final manager = await _manager();
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: _snapshot(
            profiles: const [
              AgentProfile(name: 'infra'),
              AgentProfile(name: 'qa'),
            ],
            board: const KanbanBoard(
              boardId: 'ops',
              columns: [
                KanbanColumn(
                  name: 'running',
                  tasks: [
                    KanbanTask(
                      id: 'task-running',
                      title: 'Deploy services',
                      body: '',
                      status: 'running',
                      assignee: 'infra',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final root = find.byType(MissionControlScreen);
      expect(
        find.descendant(of: root, matching: find.byType(GridView)),
        findsNothing,
        reason: 'feature-card-grid',
      );
      for (final key in const ['mission-bot-row-infra', 'mission-bot-row-qa']) {
        expect(
          find.ancestor(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(HermesCard),
          ),
          findsNothing,
          reason: 'unearthed-box/wrong-surface: $key',
        );
      }
      expect(
        find.byKey(const ValueKey('bot-mode-floating-dock')),
        findsOneWidget,
        reason: 'allowed contained dock exception',
      );
    },
  );

  testWidgets('a7: SOUL on a bot card opens that bot\'s SOUL, not the active '
      'profile\'s', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = await _manager();
    // The user is working in another profile. A read-only connection has no
    // advanced editor, so the card opens the SOUL screen directly.
    await manager.setActiveProfile(_connection.id, 'ana');
    await tester.pumpWidget(
      _host(
        manager: manager,
        connection: _connection.copyWith(readOnly: true),
        snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
      ),
    );
    await tester.pumpAndSettle();
    await _openAgentDetail(tester, 'infra');
    final soul = find.byKey(const ValueKey('bot-profile-soul'));
    await tester.ensureVisible(soul);
    await tester.tap(soul);
    await tester.pumpAndSettle();
    expect(find.text('Perfil: infra'), findsOneWidget);
    expect(find.text('Perfil: ana'), findsNothing);
  });

  testWidgets('deleting a bot deletes its profile in place, with the same '
      'confirmation as Profiles', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = await _manager();
    await manager.setActiveProfile(_connection.id, 'infra');
    final deleted = <String>[];
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
        profileDeleteOverride: (name) async => deleted.add(name),
      ),
    );
    await tester.pumpAndSettle();
    await _openAgentDetail(tester, 'infra');
    await tester.tap(find.byKey(const ValueKey('bot-profile-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-profile-delete')));
    await tester.pumpAndSettle();
    // No jump to another screen: the confirmation opens over the card.
    expect(find.byType(ProfilesScreen), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-delete-confirm')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('profile-delete-confirm-yes')));
    await tester.pumpAndSettle();
    expect(deleted, ['infra']);
    expect(find.byKey(const ValueKey('bot-profile')), findsNothing);
    // It was the active profile: the app is back on the default one.
    expect(manager.activeProfileFor(_connection.id), '');
  });

  testWidgets('after deleting a bot, a screen pushed over Mission Control '
      'and popped back does not rebuild it', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = await _manager();
    // A bot no earlier test deleted: the roster registry is shared.
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(profiles: const [AgentProfile(name: 'scout')]),
        profileDeleteOverride: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    await _openAgentDetail(tester, 'scout');
    await tester.tap(find.byKey(const ValueKey('bot-profile-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-profile-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-delete-confirm-yes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-profile')), findsNothing);

    // The delete flow needs Mission Control's own route; reading it must not
    // subscribe the whole screen to the route status.
    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is MissionControlScreen) rebuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    final navigator = Navigator.of(
      tester.element(find.byType(MissionControlScreen)),
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('destination')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    debugOnRebuildDirtyWidget = null;

    expect(rebuilds, 0);
  });
}
