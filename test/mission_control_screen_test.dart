import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/widgets/room_member_status.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
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
  MissionControlOpenTarget? initialOpenTarget,
  HermesDesktopBotCreationGateway? botCreateGateway,
  HermesDesktopProfileAssetsGateway? profileAssetsGateway,
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
    botCreateGateway: botCreateGateway,
    profileAssetsGateway: profileAssetsGateway,
    modelOptionsLoader: botCreateGateway == null ? null : (_) async => const [],
  ),
);

Future<void> _openDestination(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey('mission-destination-$key')));
  await tester.pumpAndSettle();
}

Future<void> _openWork(WidgetTester tester) => _openDestination(tester, 'work');

/// El ⋯ (o mantener pulsada la fila) abre la hoja de acciones rápidas; su
/// ítem "Detalles del bot" es el que lleva a la ficha completa
/// (`_AgentDetail`). Reemplaza al tap directo sobre la fila, que ahora abre
/// el chat (ver [_openBotChat]).
Future<void> _openAgentDetail(WidgetTester tester, String profile) async {
  await tester.tap(find.byKey(ValueKey('mission-bot-details-$profile')));
  await tester.pumpAndSettle();
  final detailsItem = find.byKey(const ValueKey('bot-quick-details'));
  await tester.scrollUntilVisible(
    detailsItem,
    80,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('mission-bot-quick-actions')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(detailsItem);
  await tester.pumpAndSettle();
}

/// Tocar la fila abre el detalle del bot; abrir su Bot Chat pasa por el
/// "Abrir chat" de la hoja de acciones rápidas (mantener pulsada la fila o
/// tocar el ⋯), según la especificación del mockup "Bots con fijados".
Future<void> _openBotChat(WidgetTester tester, String profile) async {
  await tester.tap(find.byKey(ValueKey('mission-bot-details-$profile')));
  await tester.pumpAndSettle();
  final openChatItem = find.byKey(const ValueKey('bot-quick-open-chat'));
  await tester.ensureVisible(openChatItem);
  await tester.pumpAndSettle();
  await tester.tap(openChatItem);
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

  testWidgets('opens on a bots-first roster with rooms and work shell', (
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
      findsOneWidget,
    );
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
              botChatSessionId: 'stored-bot-1',
              botModeUiMeta: {'chat': 'stored-bot-1'},
              botModeMetadataPublished: true,
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
    expect(opened!.source, 'bot-mode');
  });

  testWidgets('bot row opens detail; quick actions reach chat directly', (
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
    await tester.tap(find.byKey(const ValueKey('mission-bot-infra')));
    await tester.pumpAndSettle();

    // Tocar la fila sigue abriendo el detalle del bot, como especifica la
    // nota de interacción del mockup "Bots con fijados": el chat directo ya
    // no es el gesto primario de la fila.
    expect(opened, isNull);
    expect(find.byKey(const ValueKey('mission-agent-detail')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-detail-chat')), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('mission-agent-detail'))),
    ).pop();
    await tester.pumpAndSettle();

    // Mantener pulsada la fila (o tocar el ⋯) abre en cambio la hoja de
    // acciones rápidas, cuyo "Abrir chat" explícito sigue llevando al Bot
    // Chat directamente.
    await _openBotChat(tester, 'infra');
    expect(opened?.profile, 'infra');
    expect(opened?.title, 'Bot Chat');
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

  testWidgets('bot detail lists every assigned task', (tester) async {
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
    await _openAgentDetail(tester, 'infra');

    expect(find.text('Tareas asignadas (4)'), findsOneWidget);
    expect(find.text('Desplegar gateway'), findsOneWidget);
    expect(find.text('Revisar backups'), findsOneWidget);
    expect(find.text('Rotar certificados'), findsOneWidget);
    expect(find.text('Documentar recuperación'), findsOneWidget);
  });

  testWidgets('bot sheet groups every action around the bot', (tester) async {
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

    expect(find.byKey(const ValueKey('mission-agent-detail')), findsOneWidget);
    expect(find.text('Infra'), findsWidgets);
    expect(find.byKey(const ValueKey('bot-detail-chat')), findsOneWidget);
    final sheetScroll = find.byType(Scrollable).last;
    for (final key in const [
      'bot-detail-edit-profile',
      'bot-detail-routines',
      'bot-detail-tasks',
      'bot-detail-memory',
      'bot-detail-skills',
      'bot-detail-soul',
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(key)),
        240,
        scrollable: sheetScroll,
      );
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bot-detail-chat')),
      -240,
      scrollable: sheetScroll,
    );
    await tester.tap(find.byKey(const ValueKey('bot-detail-chat')));
    await tester.pumpAndSettle();
    expect(opened?.profile, 'infra');
  });

  testWidgets('bot sheet persists pin and hidden roster metadata', (
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

    await _openAgentDetail(tester, 'infra');
    var sheetScroll = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bot-detail-toggle-pinned')),
      240,
      scrollable: sheetScroll,
    );
    await tester.tap(find.byKey(const ValueKey('bot-detail-toggle-pinned')));
    await tester.pumpAndSettle();
    expect(gateway.metaPinned, isTrue);

    await _openAgentDetail(tester, 'infra');
    sheetScroll = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bot-detail-toggle-hidden')),
      240,
      scrollable: sheetScroll,
    );
    await tester.tap(find.byKey(const ValueKey('bot-detail-toggle-hidden')));
    await tester.pumpAndSettle();
    expect(gateway.metaHidden, isTrue);
  });

  testWidgets('bot sheet reads as identity, actions and one quiet usage line', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
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

    // Addendum 2: nombre + handle + una línea de estado sin badge ni caja.
    // No como filas
    // "Profile"/"Modelo" de etiqueta y valor.
    expect(find.text('Infra'), findsWidgets);
    expect(find.text('@infra'), findsOneWidget);
    expect(find.text('Profile'), findsNothing);
    expect(find.text('Modelo'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-agent-detail')),
        matching: find.byType(BotStatusLine),
      ),
      findsOneWidget,
    );

    // Las 8 acciones ya no son una parrilla de botones: van en dos grupos de
    // filas (`HermesGroup`), y ninguna se perdió por el camino.
    final sheetScroll = find.byType(Scrollable).last;
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-agent-detail')),
        matching: find.byType(HermesSecondaryButton),
      ),
      findsNothing,
    );
    for (final key in const [
      'bot-detail-edit-profile',
      'bot-detail-routines',
      'bot-detail-tasks',
      'bot-detail-memory',
      'bot-detail-skills',
      'bot-detail-soul',
      'bot-detail-toggle-pinned',
      'bot-detail-toggle-hidden',
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(key)),
        240,
        scrollable: sheetScroll,
      );
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }

    // El uso baja a una única línea tenue (input/output/caché ya no se pintan
    // como cifras grandes que compiten con las acciones del bot).
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bot-detail-usage')),
      240,
      scrollable: sheetScroll,
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('bot-detail-usage'))).data,
      '150 tokens',
    );
    expect(find.text('input'), findsNothing);
    expect(find.text('output'), findsNothing);
  });

  testWidgets('rooms list and bots stay reachable with the dock switched off', (
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

    // …y aun así la pantalla lleva a las salas y de vuelta a Bots: apagar el
    // dock nunca puede quitar funcionalidad.
    final toWork = find.byKey(const ValueKey('mission-goto-work'));
    expect(toWork, findsOneWidget);
    expect(find.byKey(const ValueKey('mission-goto-bots')), findsNothing);
    await tester.tap(toWork);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-work-feed')), findsOneWidget);

    final toBots = find.byKey(const ValueKey('mission-goto-bots'));
    expect(toBots, findsOneWidget);
    expect(find.byKey(const ValueKey('mission-goto-work')), findsNothing);
    await tester.tap(toBots);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-bots')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bot row shows the pinned Bot Chat preview and time', (
    tester,
  ) async {
    final manager = await _manager();
    final official = AgentProfile.fromJson({
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {'chat': 'stored-official'},
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

    expect(find.text('Inactivo · Última respuesta del bot'), findsOneWidget);
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

    for (final destination in const {
      'Bots': 'bots',
      'Trabajo': 'work',
    }.entries) {
      expect(
        tester
            .getSemantics(
              find.byKey(ValueKey('mission-destination-${destination.value}')),
            )
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
        reason: '${destination.key} debe publicar la acción tap en Android',
      );
    }
    // El dock real pinta solo iconos (ver dock.dart): la etiqueta
    // ya no es un Text visible en la barra, así que la cobertura de
    // accesibilidad se comprueba por el `label` semántico publicado, no por
    // `find.text` (que sí sigue encontrando "Bots" en otras superficies de
    // la pantalla, como la lista de agentes).
    expect(find.text('Bots'), findsWidgets);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('mission-destination-work')))
          .getSemanticsData()
          .label,
      'Trabajo',
    );

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('mission-destination-bots')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('mission-destination-work')));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('mission-destination-work')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('mission-destination-bots')))
          .flagsCollection
          .isSelected,
      Tristate.isFalse,
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
    // Even without Kanban, a known profile now has an explicit idle status.
    expect(find.text('Inactivo'), findsWidgets);

    await _openWork(tester);
    expect(
      find.text(
        'El tablero de tareas no está disponible en esta instalación de Hermes.',
      ),
      findsOneWidget,
    );
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
      await tester.tap(find.byKey(const ValueKey('mission-workspace-button')));
      await tester.pumpAndSettle();
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

    await tester.tap(find.byKey(const ValueKey('mission-workspace-button')));
    await tester.pumpAndSettle();
    expect(find.text('Sin manager'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-workspace-sheet')),
        matching: find.text('1 agente'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('@null'), findsNothing);
  });

  testWidgets(
    'appearance-only Bot metadata preserves the known local conversation',
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
      expect(opened?.lineageRootId, 'stored-local-keep');
      expect(opened?.source, 'bot-mode-local');
      expect(await botStore.load(_connection.id, 'infra'), 'stored-local-keep');
    },
  );

  testWidgets(
    'official Bot metadata with a pin or explicit null reset retires stale local pins',
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

      expect(opened?.lineageRootId, 'stored-official');
      expect(opened?.source, 'bot-mode');
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
      // Not yet an official ui_meta pin: goes through the local-pin send
      // path so the first prompt promotes it to one.
      expect(opened?.source, 'bot-mode-local');
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
    'an explicit null official pin ignores a stale canonical_session too',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      Session? opened;
      // Desktop is mid-recreation of the pin (`chat: null`): even if the
      // registry still reports the about-to-be-replaced row, this is a real
      // reset and must defer to create-on-first-submit, not resume the old row.
      final resetMidFlight = AgentProfile.fromJson({
        'name': 'codex-qa',
        'ui_meta': {
          'hermes-bots': {'chat': null, 'title': 'QA'},
        },
        'canonical_session': {'id': 'stale-before-recreate'},
      });

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: [resetMidFlight]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'codex-qa');

      expect(opened, isNotNull);
      expect(opened?.lineageRootId, isNull);
      expect(opened?.source, 'mobile-bot');
    },
  );

  testWidgets('read-only official Bot Chat performs no local mutation', (
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

    expect(opened?.lineageRootId, 'stored-official');
    expect(opened?.source, 'bot-mode');
    expect(secureWrites, 0);
    expect(secureDeletes, 0);
    expect(secureStore.values, contains('stored-local-must-remain'));
  });

  testWidgets('corrupt local Bot pin blocks creation instead of forking chat', (
    tester,
  ) async {
    final manager = await _manager();
    final botStore = MissionBotChatStore(manager.prefs);
    await botStore.save(
      connectionId: _connection.id,
      profile: 'infra',
      sessionId: 'stored-valid-first',
    );
    secureStore[secureStore.keys.single] = 'bad\nsession';
    Session? opened;

    await tester.pumpWidget(
      _host(
        manager: manager,
        botChatStore: botStore,
        botChatOpenObserver: (session) => opened = session,
        snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
      ),
    );
    await tester.pumpAndSettle();
    await _openBotChat(tester, 'infra');

    expect(opened, isNull);
    expect(
      find.textContaining('No se pudo verificar el Bot Chat'),
      findsOneWidget,
    );
  });

  testWidgets(
    'unavailable Bot pin storage blocks creation instead of forking chat',
    (tester) async {
      final manager = await _manager();
      final botStore = MissionBotChatStore(manager.prefs);
      failSecureReads = true;
      Session? opened;

      await tester.pumpWidget(
        _host(
          manager: manager,
          botChatStore: botStore,
          botChatOpenObserver: (session) => opened = session,
          snapshot: _snapshot(profiles: const [AgentProfile(name: 'infra')]),
        ),
      );
      await tester.pumpAndSettle();
      await _openBotChat(tester, 'infra');

      expect(opened, isNull);
      expect(
        find.textContaining('No se pudo verificar el Bot Chat'),
        findsOneWidget,
      );
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
        'hermes-bots': {'group': 'Homelab', 'chat': 'stored-canonical-manager'},
      },
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
    expect(opened.last.source, 'bot-mode');
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

    await tester.pumpWidget(
      _host(
        manager: manager,
        activeChats: chats,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          sessions: [session],
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Necesita tu atención'), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-attention')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mission-attention')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-work-feed')), findsOneWidget);
    expect(find.text('Aprobación pendiente'), findsOneWidget);
    expect(find.text('Decide si quieres continuar'), findsOneWidget);
    expect(find.text('Restart Proxmox node'), findsNothing);
    expect(find.textContaining('approval-1'), findsNothing);
    final semantics = tester.ensureSemantics();
    final publicApproval = tester
        .getSemantics(find.byKey(const ValueKey('mission-global-approval-0')))
        .getSemanticsData()
        .label;
    expect(publicApproval, contains('Aprobación pendiente'));
    expect(publicApproval, contains('Decide si quieres continuar'));
    expect(publicApproval, isNot(contains('Restart Proxmox node')));
    expect(publicApproval, isNot(contains('approval-1')));
    semantics.dispose();
    expect(
      find.byKey(const ValueKey('mission-global-work-tray')),
      findsOneWidget,
    );
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
              botChatSessionId: 'stored-bot-approval',
              botModeUiMeta: {'chat': 'stored-bot-approval'},
              botModeMetadataPublished: true,
            ),
          ],
          sessions: [session],
          board: const KanbanBoard(columns: []),
        ),
        botChatOpenObserver: (session) => opened = session,
      ),
    );
    await tester.pumpAndSettle();
    await _openWork(tester);
    await tester.tap(find.byKey(const ValueKey('mission-global-approval-0')));
    await tester.pumpAndSettle();

    expect(opened, isNotNull);
    expect(opened!.source, 'bot-mode');
    expect(opened!.lineageRootId, 'stored-bot-approval');
    expect(find.byKey(const ValueKey('mission-bots')), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-work-feed')), findsNothing);
  });

  testWidgets('multiple approvals open the overview instead of one request', (
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
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 aprobaciones · 0 bloqueados'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mission-attention')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-work-feed')), findsOneWidget);
    expect(find.text('Aprobación pendiente'), findsNWidgets(2));
    expect(find.text('Decide si quieres continuar'), findsNWidgets(2));
    expect(find.text('Restart node'), findsNothing);
    expect(find.text('Publish release'), findsNothing);
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
      find.text('Esta instalación de Hermes no publica profiles.'),
      findsOneWidget,
    );
    await _openDestination(tester, 'work');
    expect(
      find.text(
        'Hermes no puede verificar el equipo ahora. Las salas guardadas siguen visibles en modo consulta.',
      ),
      findsOneWidget,
    );
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

    await _openWork(tester);
    expect(find.text('Tokens no publicados'), findsNothing);
    expect(find.text('Uso'), findsNothing);
    expect(find.text('Coste no publicado'), findsNothing);
    expect(find.text(r'$0.0000'), findsNothing);

    // La cabecera de sección del área de Trabajo va en mayúsculas desde el
    // rediseño (mismo lenguaje que las secciones de Conversaciones).
    expect(find.text('OTROS PENDIENTES'), findsOneWidget);
  });

  testWidgets(
    'work is one feed with three exact actionable tasks and no bot duplicate',
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
            sessions: [_session('session-infra', 'infra')],
            board: const KanbanBoard(
              boardId: 'operations',
              columns: [
                KanbanColumn(
                  name: 'ready',
                  tasks: [
                    KanbanTask(
                      id: 'task-ready',
                      title: 'Prepare release notes',
                      body: '',
                      status: 'ready',
                      assignee: 'qa',
                      createdAt: 116,
                    ),
                  ],
                ),
                KanbanColumn(
                  name: 'running',
                  tasks: [
                    KanbanTask(
                      id: 'task-running',
                      title: 'Deploy services',
                      body: '',
                      status: 'running',
                      assignee: 'infra',
                      startedAt: 119,
                    ),
                  ],
                ),
                KanbanColumn(
                  name: 'blocked',
                  tasks: [
                    KanbanTask(
                      id: 'task-blocked',
                      title: 'Repair backup',
                      body: '',
                      status: 'blocked',
                      assignee: 'infra',
                      createdAt: 118,
                    ),
                  ],
                ),
                KanbanColumn(
                  name: 'review',
                  tasks: [
                    KanbanTask(
                      id: 'task-review',
                      title: 'Review firewall',
                      body: '',
                      status: 'review',
                      assignee: 'qa',
                      createdAt: 117,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openWork(tester);

      expect(find.byKey(const ValueKey('mission-work-feed')), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(TabBarView), findsNothing);
      expect(find.byKey(const ValueKey('mission-bot-infra')), findsNothing);
      expect(
        find.byKey(
          const ValueKey('mission-global-task-operations-task-blocked'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('mission-global-task-operations-task-running'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('mission-global-task-operations-task-review'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-global-task-operations-task-ready')),
        findsNothing,
      );

      final blockedTask = find.byKey(
        const ValueKey('mission-global-task-operations-task-blocked'),
      );
      await tester.scrollUntilVisible(
        blockedTask,
        160,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('mission-work-feed')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(blockedTask);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('work hides an empty global tray and keeps activity contextual', (
    tester,
  ) async {
    final manager = await _manager();
    final sessions = List.generate(
      7,
      (index) => Session(
        id: 'activity-$index',
        title: 'Activity $index',
        model: 'model',
        source: 'gateway',
        messageCount: 2,
        isActive: true,
        preview: 'Recent work',
        startedAt: 100 + index.toDouble(),
        updatedAt: 110 + index.toDouble(),
        profile: 'infra',
      ),
    );
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'infra')],
          sessions: sessions,
          board: const KanbanBoard(columns: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openWork(tester);

    expect(
      find.byKey(const ValueKey('mission-global-work-tray')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mission-open-global-kanban')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mission-work-activity')), findsNothing);
    expect(find.text('Uso'), findsNothing);
  });

  // El tablero era un `TextButton` suelto llamado "Tablero completo" colgado
  // del final de "Otros pendientes": ni decía qué abría ni es un pendiente.
  // Ahora es su propia sección explicada, fuera de la bandeja, con la misma
  // clave y el mismo destino.
  testWidgets('the task board is its own explained section outside the tray', (
    tester,
  ) async {
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
                name: 'ready',
                tasks: [
                  KanbanTask(
                    id: 'task-ready',
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
    await _openWork(tester);

    final feed = find.descendant(
      of: find.byKey(const ValueKey('mission-work-feed')),
      matching: find.byType(Scrollable),
    );
    final board = find.byKey(const ValueKey('mission-open-global-kanban'));
    await tester.scrollUntilVisible(board, 180, scrollable: feed);
    expect(board, findsOneWidget);

    // Ya no cuelga de la bandeja de pendientes.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mission-global-work-tray')),
        matching: board,
      ),
      findsNothing,
    );

    // Y dice qué es y qué abre, en vez de solo "Tablero completo".
    expect(find.text('TABLERO DE TAREAS'), findsOneWidget);
    expect(find.text('Abrir el tablero compartido'), findsOneWidget);
    expect(
      find.text('Todas las tareas del equipo en un tablero, por columnas.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
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

    await tester.tap(find.byIcon(Icons.refresh_rounded).last);
    await tester.pumpAndSettle();

    expect(find.text('infra'), findsWidgets);
    expect(
      find.text('Algunos datos del equipo pueden estar desactualizados.'),
      findsOneWidget,
    );
    await _openWork(tester);
    await tester.drag(
      find.byKey(const ValueKey('mission-work-feed')),
      const Offset(0, -320),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cached native task'), findsOneWidget);
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

    await tester.tap(find.byIcon(Icons.refresh_rounded).last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Hermes no está disponible. Los datos existentes del equipo siguen visibles.',
      ),
      findsNothing,
    );
    await _openDestination(tester, 'work');
    expect(
      find.text(
        'Hermes no puede verificar el equipo ahora. Las salas guardadas siguen visibles en modo consulta.',
      ),
      findsOneWidget,
    );
    await _openWork(tester);
    expect(find.text('Old cached task'), findsNothing);
    expect(
      find.text(
        'El tablero de tareas no está disponible en esta instalación de Hermes.',
      ),
      findsOneWidget,
    );
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

    await tester.tap(find.byKey(const ValueKey('mission-workspace-button')));
    await tester.pumpAndSettle();
    expect(find.text('Crear espacio de trabajo'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _openAgentDetail(tester, 'infra');
    expect(find.byKey(const ValueKey('mission-agent-detail')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Editar profile'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    final manageLabel = find.text('Editar profile');
    expect(manageLabel, findsOneWidget);
    // La ficha rediseñada agrupa las acciones en filas (`HermesGroup`), no en
    // una parrilla de botones: en modo consulta la fila sigue visible pero sin
    // `onTap`, igual que antes hacía el botón deshabilitado.
    final manageRow = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('bot-detail-edit-profile')),
        matching: find.byType(InkWell),
      ),
    );
    expect(manageRow.onTap, isNull);
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

    await tester.tap(find.byIcon(Icons.refresh_rounded).last);
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

    await _openWork(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('mission-work-feed')), findsOneWidget);
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

      await tester.tap(find.byKey(const ValueKey('mission-workspace-button')));
      await tester.pumpAndSettle();
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

      await _openWork(tester);
      expect(find.byKey(const ValueKey('mission-work-feed')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mission-open-global-kanban')),
        180,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('mission-work-feed')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.byKey(const ValueKey('mission-global-work-tray')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-open-global-kanban')),
        findsOneWidget,
      );
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

    expect(
      find.byKey(const ValueKey('mission-bot-needs-you-infra')),
      findsOneWidget,
    );
    expect(find.text('te necesita'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mission-bot-needs-you-qa')),
      findsNothing,
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
          'Un bot es un compañero con nombre propio, memoria, skills y chat '
          'propios. Crea el primero para empezar.',
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

    expect(find.text('Ya existe un agente con este nombre.'), findsOneWidget);
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
    expect(find.byKey(const ValueKey('bot-mode-create-bot')), findsOneWidget);
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
          for (final key in const ['bots', 'create', 'work']) {
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
    expect(find.byKey(const ValueKey('mission-agent-detail')), findsOneWidget);
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

      await _openWork(tester);
      const key = 'mission-global-task-ops-task-running';
      final target = find.byKey(const ValueKey(key));
      expect(target, findsOneWidget);
      expect(
        find.ancestor(of: target, matching: find.byType(HermesCard)),
        findsNothing,
        reason: 'accent-rail/unearthed-box/wrong-surface: $key',
      );
    },
  );
}
