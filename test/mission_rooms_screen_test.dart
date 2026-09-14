import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/mission_room.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_room_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'mission-rooms-widget',
  label: 'Rooms QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
);

Session _session(String id, String profile) => Session(
  id: id,
  title: '$profile room',
  model: 'model-$profile',
  source: 'gateway',
  messageCount: 3,
  isActive: true,
  preview: 'Room history',
  startedAt: 100,
  updatedAt: 120,
  profile: profile,
);

MissionBackendSnapshot _snapshot({
  required List<AgentProfile> profiles,
  required List<Session> sessions,
  KanbanBoard board = const KanbanBoard(columns: []),
  MissionCapabilityState profilesCapability = MissionCapabilityState.available,
}) => MissionBackendSnapshot(
  profiles: profiles,
  sessions: sessions,
  board: board,
  profilesCapability: profilesCapability,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
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

class _MutableSource implements MissionControlDataSource {
  MissionBackendSnapshot snapshot;
  Object? error;

  _MutableSource(this.snapshot);

  @override
  Future<MissionBackendSnapshot> load() async {
    final failure = error;
    if (failure != null) throw failure;
    return snapshot;
  }

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
  required MissionRoomStoreContract roomStore,
  ChatDraftStore? chatDraftStore,
  SavedConnection? connection,
  Locale locale = const Locale('es'),
  double textScale = 1,
  bool disableAnimations = false,
  MissionControlDataSource? dataSource,
  void Function(MissionRoom room, Session session)? roomOpenObserver,
  MissionControlOpenTarget? initialOpenTarget,
  ValueChanged<MissionRoomTaskLink>? roomTaskOpenObserver,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
    ),
    child: child!,
  ),
  home: MissionControlScreen(
    connection: connection ?? _connection,
    connManager: manager,
    dataSource: dataSource ?? _FakeSource(snapshot),
    roomStore: roomStore,
    initialOpenTarget: initialOpenTarget,
    chatDraftStore: chatDraftStore,
    roomOpenObserver: roomOpenObserver,
    roomTaskOpenObserver: roomTaskOpenObserver,
  ),
);

Future<void> _openRooms(WidgetTester tester) async {
  final destination = find.byKey(const ValueKey('mission-destination-work'));
  await tester.tap(destination);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('mission-rooms')), findsOneWidget);
}

Future<void> _openCreateRoom(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mission-create-room')));
  await tester.pumpAndSettle();
}

Future<void> _selectManager(WidgetTester tester, String profile) async {
  final control = find.byKey(const ValueKey('room-manager'));
  await Scrollable.ensureVisible(
    tester.element(control),
    alignment: 0.35,
    duration: Duration.zero,
  );
  await tester.pumpAndSettle();
  await tester.tap(control);
  await tester.pumpAndSettle();
  await tester.tap(find.text('@$profile').last);
  await tester.pumpAndSettle();
}

Future<void> _saveRoomEditor(WidgetTester tester) async {
  final save = find.byKey(const ValueKey('room-save'));
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Future<void> _toggleRoomMember(WidgetTester tester, String profile) async {
  final member = find.byKey(ValueKey('room-member-$profile'));
  await Scrollable.ensureVisible(
    tester.element(member),
    alignment: 0.72,
    duration: Duration.zero,
  );
  await tester.pumpAndSettle();
  await tester.tap(member);
  await tester.pumpAndSettle();
}

Future<void> _openRoomEditorForEdit(
  WidgetTester tester, {
  String editLabel = 'Editar sala',
}) async {
  final detailMenu = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('room-detail-menu-'),
  );
  if (detailMenu.evaluate().isNotEmpty) {
    await tester.tap(detailMenu);
  } else {
    await tester.tap(find.byTooltip(editLabel));
  }
  await tester.pumpAndSettle();
  await tester.tap(find.text(editLabel).last);
  await tester.pumpAndSettle();
}

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

  testWidgets('initial Room notification opens owner chat from Trabajo', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    final room = await store.save(
      connectionId: _connection.id,
      name: 'Release room',
      managerProfile: 'manager',
      memberProfiles: const ['manager', 'builder'],
      managerSessionId: 'stored-room-1',
    );
    MissionRoom? openedRoom;
    Session? openedSession;
    final snapshot = _snapshot(
      profiles: const [
        AgentProfile(name: 'manager'),
        AgentProfile(name: 'builder'),
      ],
      sessions: [_session('stored-room-1', 'manager')],
    );

    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: snapshot,
        roomStore: store,
        initialOpenTarget: MissionControlOpenTarget.room(
          sessionId: 'stored-room-1',
          roomId: room.id,
          profile: 'manager',
        ),
        roomOpenObserver: (room, session) {
          openedRoom = room;
          openedSession = session;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(openedRoom?.id, room.id);
    expect(openedSession?.profile, 'manager');
    expect(openedSession?.lineageRootId, 'stored-room-1');
    expect(openedSession?.source, 'room-local');
  });

  testWidgets('room editor creates and edits a manager-owned room', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    final snapshot = _snapshot(
      profiles: const [
        AgentProfile(name: 'manager', model: 'cloud', provider: 'router'),
        AgentProfile(name: 'infra', model: 'local', provider: 'local'),
      ],
      sessions: [_session('manager-session', 'manager')],
    );
    MissionRoom? openedRoom;
    Session? openedSession;
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: snapshot,
        roomStore: store,
        roomOpenObserver: (room, session) {
          openedRoom = room;
          openedSession = session;
        },
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);

    expect(find.byKey(const ValueKey('mission-rooms')), findsOneWidget);
    await _openCreateRoom(tester);
    expect(find.byKey(const ValueKey('mission-room-editor')), findsOneWidget);
    final createAction = find.byKey(const ValueKey('room-save'));
    expect(
      find.widgetWithText(FilledButton, 'Crear sala local'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SingleChildScrollView).last,
        matching: createAction,
      ),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('room-name'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('room-purpose'))).dy,
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('room-purpose'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('room-manager'))).dy,
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('room-manager'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('room-member-search'))).dy,
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('room-name')), 'Homelab');
    await tester.enterText(
      find.byKey(const ValueKey('room-purpose')),
      'Coordinar backups y despliegues',
    );
    await _selectManager(tester, 'manager');
    await _toggleRoomMember(tester, 'infra');
    await _saveRoomEditor(tester);

    final created = store.load(_connection.id).single;
    expect(created.name, 'Homelab');
    expect(created.purposeLabel, 'Coordinar backups y despliegues');
    expect(created.managerProfile, 'manager');
    expect(created.memberProfiles, containsAll(['manager', 'infra']));
    expect(created.managerSessionId, isEmpty);
    expect(created.hasDurableManagerSession, isFalse);
    expect(openedRoom, isNull);
    expect(
      find.byKey(ValueKey('mission-room-detail-${created.id}')),
      findsOneWidget,
    );
    expect(find.text('#Homelab'), findsOneWidget);
    expect(find.text('Coordinar backups y despliegues'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('room-open-chat-${created.id}')));
    await tester.pumpAndSettle();
    expect(openedRoom?.id, created.id);
    expect(openedSession?.id, 'mob-room-${created.id}');
    expect(openedSession?.profile, 'manager');

    await _openRoomEditorForEdit(tester);
    expect(
      find.byKey(const ValueKey('room-member-choice-avatar-manager')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('room-selected-avatar-infra')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('room-name')),
      'Homelab Ops',
    );
    await tester.enterText(
      find.byKey(const ValueKey('room-purpose')),
      'Mantener la infraestructura estable',
    );
    await _saveRoomEditor(tester);

    final edited = store.load(_connection.id).single;
    expect(edited.id, created.id);
    expect(edited.name, 'Homelab Ops');
    expect(edited.purposeLabel, 'Mantener la infraestructura estable');
    expect(edited.managerSessionId, isEmpty);
    expect(find.text('#Homelab Ops'), findsOneWidget);
    expect(find.text('Mantener la infraestructura estable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guided room action builds a searchable named team room', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'manager', botModeUiMeta: {'title': 'Manager'}),
            AgentProfile(
              name: 'infra',
              description: 'Temporary release QA',
              botModeUiMeta: {'title': 'Infra'},
            ),
            AgentProfile(name: 'security'),
          ],
          sessions: const [],
        ),
        roomStore: store,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);

    // Bots-first: "Nuevo agente" vive solo en el destino Bots, no en Salas.
    expect(find.byKey(const ValueKey('mission-create-agent')), findsNothing);
    expect(find.byKey(const ValueKey('mission-create-room')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mission-create-room')));
    await tester.pumpAndSettle();

    final title = find.byKey(const ValueKey('room-editor-title'));
    final titleText = tester.widget<Text>(title);
    final titleTheme = Theme.of(tester.element(title));
    expect(titleText.style?.color, titleTheme.hermes.textPrimary);
    expect(titleText.style?.fontWeight, FontWeight.w700);
    expect(
      titleText.style?.fontSize,
      titleTheme.textTheme.titleMedium?.fontSize,
    );
    expect(find.text('Elige de 2 a 6 bots.'), findsOneWidget);
    expect(find.text('Buscar bots'), findsOneWidget);
    expect(find.text('Gestionar bots'), findsOneWidget);
    expect(
      find.text('Selecciona al menos 2 agentes (máximo 6).'),
      findsNothing,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('room-purpose')))
          .decoration
          ?.helperText,
      isNull,
    );
    final managerDropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('room-manager')),
    );
    expect(managerDropdown.decoration.helperText, isNull);
    final selectedManager = find.descendant(
      of: find.byKey(const ValueKey('room-manager')),
      matching: find.text('Manager · @manager'),
    );
    expect(selectedManager, findsOneWidget);
    final managerStyle = DefaultTextStyle.of(
      tester.element(selectedManager),
    ).style;
    expect(managerStyle.color, titleTheme.hermes.textPrimary);
    expect(managerStyle.fontWeight, FontWeight.w500);
    expect(find.text('@manager · Manager'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('room-member-choice-avatar-manager')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('room-member-choice-avatar-infra')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('room-member-choice-avatar-security')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('room-selected-avatar-manager')),
      findsOneWidget,
    );
    await _toggleRoomMember(tester, 'infra');
    expect(
      find.byKey(const ValueKey('room-selected-avatar-infra')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('room-member-infra')),
          )
          .value,
      isTrue,
    );
    expect(find.text('@infra'), findsOneWidget);
    expect(find.text('@infra · Temporary release QA'), findsNothing);
    final name = tester.widget<TextField>(
      find.byKey(const ValueKey('room-name')),
    );
    expect(name.controller!.text, 'Manager + Infra');
    expect(find.text('2 de 6 seleccionados'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('room-member-search')),
      'security',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('room-member-security')), findsOneWidget);
    expect(find.byKey(const ValueKey('room-member-infra')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('room editor closes only from its explicit action', (
    tester,
  ) async {
    final manager = await _manager();
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'manager'),
            AgentProfile(name: 'infra'),
          ],
          sessions: const [],
        ),
        roomStore: MissionRoomStore(manager.prefs),
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);
    await _openCreateRoom(tester);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-room-editor')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-room-editor')), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-room-editor')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'serialized room ignores manager and sorts members deterministically',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      await store.save(
        connectionId: _connection.id,
        name: 'Order',
        managerProfile: 'manager',
        memberProfiles: const ['zeta', 'manager', 'alpha'],
      );
      await tester.pumpWidget(
        _host(
          manager: manager,
          roomStore: store,
          snapshot: _snapshot(
            profiles: const [
              AgentProfile(name: 'zeta'),
              AgentProfile(name: 'manager'),
              AgentProfile(name: 'alpha'),
            ],
            sessions: const [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openRooms(tester);

      expect(
        find.byKey(const ValueKey('room-avatar-member-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-avatar-member-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-avatar-member-2')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'room mission card prioritizes purpose and real work with a team footer',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      final room = await store.save(
        connectionId: _connection.id,
        name: 'Release',
        purposeLabel: 'Preparar y publicar la próxima versión',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra', 'security'],
        managerSessionId: 'stored-manager',
      );
      await store.linkTask(
        _connection.id,
        room.id,
        'task-release-42',
        boardId: 'release',
      );
      await tester.pumpWidget(
        _host(
          manager: manager,
          roomStore: store,
          snapshot: _snapshot(
            profiles: const [
              AgentProfile(name: 'manager'),
              AgentProfile(name: 'infra'),
              AgentProfile(name: 'security'),
            ],
            sessions: [_session('stored-manager', 'manager')],
            board: const KanbanBoard(
              boardId: 'release',
              columns: [
                KanbanColumn(
                  name: 'running',
                  tasks: [
                    KanbanTask(
                      id: 'task-release-42',
                      title: 'Firmar candidata',
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
      await _openRooms(tester);

      final card = find.byKey(ValueKey('mission-room-${room.id}'));
      expect(find.text('#Release'), findsOneWidget);
      expect(find.byKey(ValueKey('room-purpose-${room.id}')), findsOneWidget);
      expect(
        find.text('Preparar y publicar la próxima versión'),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('room-work-${room.id}')), findsOneWidget);
      expect(find.text('@infra · en curso · Firmar candidata'), findsOneWidget);
      expect(find.byKey(ValueKey('room-footer-${room.id}')), findsOneWidget);
      expect(find.text('Coordinador'), findsNothing);
      expect(find.text('@manager'), findsNothing);
      expect(find.text('3 miembros'), findsNothing);
      expect(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.chevron_right_rounded),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending worker operation blocks member removal, manager change and deletion',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      final draftStore = ChatDraftStore(manager.prefs);
      final room = await store.save(
        connectionId: _connection.id,
        name: 'Protected room',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
      );
      final snapshot = _snapshot(
        profiles: const [
          AgentProfile(name: 'manager'),
          AgentProfile(name: 'infra'),
        ],
        sessions: const [],
      );
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: snapshot,
          roomStore: store,
          chatDraftStore: draftStore,
        ),
      );
      await tester.pumpAndSettle();
      await _openRooms(tester);

      Future<void> persistOperation(MissionRoomTaskPhase phase) =>
          draftStore.save(
            _connection.id,
            'mob-room-${room.id}',
            '@infra audit services',
            const [],
            profile: 'manager',
            missionRoomIntentId: 'intent-room-protected',
            missionRoomWorkerProfile: 'infra',
            missionRoomBoardId: 'homelab',
            missionRoomTaskPhase: phase,
          );

      // The operation appears while the editor is open. The post-editor guard
      // must still prevent removing its worker.
      await _openRoomEditorForEdit(tester);
      await _toggleRoomMember(tester, 'infra');
      await persistOperation(MissionRoomTaskPhase.prepared);
      await _saveRoomEditor(tester);
      var unchanged = store.load(_connection.id).single;
      expect(unchanged.memberProfiles, contains('infra'));
      expect(unchanged.managerProfile, 'manager');
      expect(find.textContaining('tarea pendiente'), findsOneWidget);

      await draftStore.clear(
        _connection.id,
        'mob-room-${room.id}',
        profile: 'manager',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      // Repeat with a manager change and an ambiguous post-crash phase.
      await _openRoomEditorForEdit(tester);
      await _selectManager(tester, 'infra');
      await persistOperation(MissionRoomTaskPhase.outcomeUnknown);
      await _saveRoomEditor(tester);
      unchanged = store.load(_connection.id).single;
      expect(unchanged.managerProfile, 'manager');
      expect(unchanged.memberProfiles, contains('infra'));

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.tap(find.byTooltip('Editar sala'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eliminar').last);
      await tester.pumpAndSettle();

      expect(find.text('¿Eliminar sala?'), findsNothing);
      expect(store.load(_connection.id), hasLength(1));
      final recovered = await draftStore.load(
        _connection.id,
        'mob-room-${room.id}',
        profile: 'manager',
      );
      expect(
        recovered.missionRoomTaskPhase,
        MissionRoomTaskPhase.outcomeUnknown,
      );
    },
  );

  testWidgets('hash-only room name stays inline and is never persisted', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [
            AgentProfile(name: 'manager'),
            AgentProfile(name: 'infra'),
          ],
          sessions: const [],
        ),
        roomStore: store,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);
    await _openCreateRoom(tester);
    await tester.enterText(find.byKey(const ValueKey('room-name')), '###');
    await tester.pump();

    expect(
      find.text('Escribe un nombre después del símbolo #.'),
      findsOneWidget,
    );
    await _saveRoomEditor(tester);
    expect(find.byKey(const ValueKey('mission-room-editor')), findsOneWidget);
    expect(store.load(_connection.id), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only rooms keep navigation but expose no mutations', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    final room = await store.save(
      connectionId: _connection.id,
      name: 'Homelab',
      purposeLabel: 'Operar la infraestructura local',
      managerProfile: 'manager',
      memberProfiles: const ['manager', 'infra'],
      managerSessionId: 'manager-session',
    );
    final snapshot = _snapshot(
      profiles: const [
        AgentProfile(name: 'manager'),
        AgentProfile(name: 'infra'),
      ],
      sessions: [_session('manager-session', 'manager')],
    );
    MissionRoom? openedRoom;
    Session? openedSession;
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: snapshot,
        roomStore: store,
        connection: _connection.copyWith(readOnly: true),
        roomOpenObserver: (room, session) {
          openedRoom = room;
          openedSession = session;
        },
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);

    expect(find.text('#Homelab'), findsOneWidget);
    expect(find.text('Operar la infraestructura local'), findsOneWidget);
    expect(find.text('Coordinador'), findsNothing);
    expect(find.text('2 miembros'), findsNothing);
    expect(find.byKey(const ValueKey('mission-create-agent')), findsNothing);
    expect(find.byKey(const ValueKey('mission-create-room')), findsNothing);
    expect(find.byTooltip('Editar sala'), findsNothing);

    await tester.tap(find.text('#Homelab'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('mission-room-detail-${room.id}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('room-open-chat-${room.id}')));
    await tester.pump();
    expect(openedRoom?.name, 'Homelab');
    expect(openedSession?.id, 'mob-room-${openedRoom!.id}');
    expect(openedSession?.logicalId, 'manager-session');
    expect(openedSession?.profile, 'manager');
  });

  testWidgets(
    'stale manager fails closed and unavailable roster hides writes',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      final room = await store.save(
        connectionId: _connection.id,
        name: 'Stale room',
        managerProfile: 'retired_manager',
        memberProfiles: const ['retired_manager'],
        managerSessionId: 'old-session',
      );
      final snapshot = _snapshot(
        profiles: const [],
        sessions: const [],
        profilesCapability: MissionCapabilityState.unavailable,
      );
      var openCalls = 0;
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: snapshot,
          roomStore: store,
          roomOpenObserver: (_, _) => openCalls++,
        ),
      );
      await tester.pumpAndSettle();
      await _openRooms(tester);

      expect(find.byKey(const ValueKey('mission-create-agent')), findsNothing);
      expect(find.byKey(const ValueKey('mission-create-room')), findsNothing);
      expect(find.byTooltip('Editar sala'), findsNothing);
      expect(find.textContaining('modo consulta'), findsOneWidget);
      await tester.tap(find.text('#Stale room'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('mission-room-detail-${room.id}')),
        findsOneWidget,
      );
      final chatButton = tester.widget<FilledButton>(
        find.byKey(ValueKey('room-open-chat-${room.id}')),
      );
      expect(chatButton.onPressed, isNull);
      expect(openCalls, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('create revalidates the roster after the editor closes', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    final initial = _snapshot(
      profiles: const [
        AgentProfile(name: 'manager'),
        AgentProfile(name: 'infra'),
      ],
      sessions: const [],
    );
    final source = _MutableSource(initial);
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: initial,
        dataSource: source,
        roomStore: store,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);
    await _openCreateRoom(tester);
    await tester.enterText(find.byKey(const ValueKey('room-name')), 'Fresh');
    await _selectManager(tester, 'manager');
    await _toggleRoomMember(tester, 'infra');

    source.snapshot = _snapshot(
      profiles: const [AgentProfile(name: 'infra')],
      sessions: const [],
    );
    await _saveRoomEditor(tester);

    expect(store.load(_connection.id), isEmpty);
    expect(
      find.textContaining('roster autoritativo no está disponible'),
      findsOneWidget,
    );
  });

  testWidgets('edit revalidates every selected member before save', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    await store.save(
      connectionId: _connection.id,
      name: 'Changing team',
      managerProfile: 'manager',
      memberProfiles: const ['manager', 'infra'],
    );
    final initial = _snapshot(
      profiles: const [
        AgentProfile(name: 'manager'),
        AgentProfile(name: 'infra'),
      ],
      sessions: const [],
    );
    final source = _MutableSource(initial);
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: initial,
        dataSource: source,
        roomStore: store,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);
    await _openRoomEditorForEdit(tester);
    await tester.enterText(
      find.byKey(const ValueKey('room-name')),
      'Must not persist',
    );
    source.snapshot = _snapshot(
      profiles: const [AgentProfile(name: 'manager')],
      sessions: const [],
    );
    await _saveRoomEditor(tester);

    final unchanged = store.load(_connection.id).single;
    expect(unchanged.name, 'Changing team');
    expect(unchanged.memberProfiles, contains('infra'));
    expect(
      find.textContaining('roster autoritativo no está disponible'),
      findsOneWidget,
    );
  });

  testWidgets('open revalidates a manager removed after the last snapshot', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    await store.save(
      connectionId: _connection.id,
      name: 'Stale open',
      managerProfile: 'manager',
      memberProfiles: const ['manager'],
    );
    final initial = _snapshot(
      profiles: const [AgentProfile(name: 'manager')],
      sessions: const [],
    );
    final source = _MutableSource(initial);
    var opens = 0;
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: initial,
        dataSource: source,
        roomStore: store,
        roomOpenObserver: (_, _) => opens++,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);
    source.snapshot = _snapshot(profiles: const [], sessions: const []);

    await tester.tap(find.text('#Stale open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'room-open-chat-',
            ),
      ),
    );
    await tester.pumpAndSettle();

    expect(opens, 0);
    expect(
      find.textContaining('roster autoritativo no está disponible'),
      findsOneWidget,
    );
  });

  testWidgets('open revalidates every room member after the last snapshot', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    await store.save(
      connectionId: _connection.id,
      name: 'Stale member open',
      managerProfile: 'manager',
      memberProfiles: const ['manager', 'infra'],
    );
    final initial = _snapshot(
      profiles: const [
        AgentProfile(name: 'manager'),
        AgentProfile(name: 'infra'),
      ],
      sessions: const [],
    );
    final source = _MutableSource(initial);
    var opens = 0;
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: initial,
        dataSource: source,
        roomStore: store,
        roomOpenObserver: (_, _) => opens++,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);
    source.snapshot = _snapshot(
      profiles: const [AgentProfile(name: 'manager')],
      sessions: const [],
    );

    await tester.tap(find.text('#Stale member open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'room-open-chat-',
            ),
      ),
    );
    await tester.pumpAndSettle();

    expect(opens, 0);
    expect(
      find.textContaining('roster autoritativo no está disponible'),
      findsOneWidget,
    );
  });

  testWidgets(
    'localhost endpoint is not rejected before chat capability gate',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      await store.save(
        connectionId: _connection.id,
        name: 'Local room',
        managerProfile: 'manager',
        memberProfiles: const ['manager'],
      );
      var openCalls = 0;
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: _snapshot(
            profiles: const [AgentProfile(name: 'manager')],
            sessions: const [],
          ),
          roomStore: store,
          connection: _connection.copyWith(
            kind: InstanceKind.localhost,
            onDeviceLoopback: true,
          ),
          locale: const Locale('en'),
          roomOpenObserver: (_, _) => openCalls++,
        ),
      );
      await tester.pumpAndSettle();
      await _openRooms(tester);

      expect(find.text('Coordinator'), findsNothing);
      expect(find.text('@manager'), findsNothing);
      expect(find.text('1 member'), findsNothing);
      await tester.tap(find.text('#Local room'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'room-open-chat-',
              ),
        ),
      );
      await tester.pump();

      expect(openCalls, 1);
      expect(store.load(_connection.id).single.managerSessionId, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'editing intersects saved members with the fresh profile roster',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      await store.save(
        connectionId: _connection.id,
        name: 'Changing team',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'retired_worker'],
        managerSessionId: 'stored-manager',
      );
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: _snapshot(
            profiles: const [AgentProfile(name: 'manager')],
            sessions: [_session('stored-manager', 'manager')],
          ),
          roomStore: store,
        ),
      );
      await tester.pumpAndSettle();
      await _openRooms(tester);
      await _openRoomEditorForEdit(tester);
      await _saveRoomEditor(tester);

      expect(store.load(_connection.id).single.memberProfiles, {'manager'});
    },
  );

  testWidgets('current multi-board task link renders authoritative status', (
    tester,
  ) async {
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    final room = await store.save(
      connectionId: _connection.id,
      name: 'Current board',
      managerProfile: 'manager',
      memberProfiles: const ['manager'],
      managerSessionId: 'stored-manager',
    );
    await store.linkTask(
      _connection.id,
      room.id,
      'task-current-42',
      boardId: 'homelab',
    );
    MissionRoomTaskLink? opened;
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: _snapshot(
          profiles: const [AgentProfile(name: 'manager')],
          sessions: [_session('stored-manager', 'manager')],
          board: const KanbanBoard(
            boardId: 'homelab',
            columns: [
              KanbanColumn(
                name: 'done',
                tasks: [
                  KanbanTask(
                    id: 'task-current-42',
                    title: 'Audit homelab',
                    body: '',
                    status: 'done',
                    assignee: 'infra',
                  ),
                ],
              ),
            ],
          ),
        ),
        roomStore: store,
        roomTaskOpenObserver: (link) => opened = link,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);

    final semantics = tester.ensureSemantics();
    expect(find.text('@infra · completada · Audit homelab'), findsOneWidget);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('room-task-homelab-task-current-42')),
          )
          .label,
      contains('task-current-42, completada'),
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('room-task-homelab-task-current-42')),
          )
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(
      find.text('TABLERO HOMELAB · TASK-CURRENT-42 · NO CARGADA'),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('room-task-homelab-task-current-42')),
    );
    await tester.pump();
    expect(opened?.boardId, 'homelab');
    expect(opened?.taskId, 'task-current-42');
    semantics.dispose();
  });

  testWidgets(
    'non-current board task links stay visible and keep their board',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      final room = await store.save(
        connectionId: _connection.id,
        name: 'Cross board',
        managerProfile: 'manager',
        memberProfiles: const ['manager'],
        managerSessionId: 'stored-manager',
      );
      await store.linkTask(
        _connection.id,
        room.id,
        'task-archive-42',
        boardId: 'archive',
      );
      MissionRoomTaskLink? opened;
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: _snapshot(
            profiles: const [AgentProfile(name: 'manager')],
            sessions: [_session('stored-manager', 'manager')],
            board: const KanbanBoard(
              boardId: 'homelab',
              columns: [
                KanbanColumn(
                  name: 'running',
                  tasks: [
                    KanbanTask(
                      id: 'task-archive-42',
                      title: 'Same id on current board',
                      body: '',
                      status: 'running',
                      assignee: 'wrong-board',
                    ),
                  ],
                ),
              ],
            ),
          ),
          roomStore: store,
          roomTaskOpenObserver: (link) => opened = link,
        ),
      );
      await tester.pumpAndSettle();
      await _openRooms(tester);

      expect(
        find.byKey(const ValueKey('room-task-archive-task-archive-42')),
        findsOneWidget,
      );
      expect(find.text('Trabajo enlazado no disponible'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('room-task-archive-task-archive-42')),
            )
            .label,
        contains('Tablero archive · task-archive-42 · no cargada'),
      );
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('room-task-archive-task-archive-42')),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(find.text('@WRONG-BOARD · EN CURSO'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('room-task-archive-task-archive-42')),
      );
      await tester.pump();
      expect(opened?.boardId, 'archive');
      expect(opened?.taskId, 'task-archive-42');
      semantics.dispose();
    },
  );

  testWidgets('50 profiles and room editor fit 320 dp at 200 percent text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final manager = await _manager();
    final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
    final profiles = List.generate(
      50,
      (index) =>
          AgentProfile(name: 'agent_${index.toString().padLeft(2, '0')}'),
    );
    await store.save(
      connectionId: _connection.id,
      name: 'Large team',
      managerProfile: 'agent_00',
      memberProfiles: profiles.map((profile) => profile.name),
      managerSessionId: 'manager-session',
    );
    final snapshot = _snapshot(
      profiles: profiles,
      sessions: [_session('manager-session', 'agent_00')],
    );
    await tester.pumpWidget(
      _host(
        manager: manager,
        snapshot: snapshot,
        roomStore: store,
        locale: const Locale('en'),
        textScale: 2,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    await _openRooms(tester);

    expect(find.byKey(const ValueKey('mission-rooms')), findsOneWidget);
    expect(find.text('#Large team'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _openRoomEditorForEdit(tester, editLabel: 'Edit room');
    expect(find.byKey(const ValueKey('mission-room-editor')), findsOneWidget);
    expect(find.text('Choose 2 to 6 bots.'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('room-purpose')), findsOneWidget);
    expect(find.byKey(const ValueKey('room-manager')), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsWidgets);

    final save = find.byKey(const ValueKey('room-save'));
    final scroll = find.byType(SingleChildScrollView).last;
    expect(save, findsOneWidget);
    expect(find.descendant(of: scroll, matching: save), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);

    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    await tester.enterText(
      find.byKey(const ValueKey('room-purpose')),
      'Coordinar un equipo grande sin perder el botón de guardar',
    );
    await tester.pumpAndSettle();

    expect(save, findsOneWidget);
    expect(tester.getBottomLeft(save).dy, lessThanOrEqualTo(720));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'V13 room rows are open and use a private-name-free avatar stack',
    (tester) async {
      final manager = await _manager();
      final store = MissionRoomStore(manager.prefs, nowMs: () => 123000);
      final room = await store.save(
        connectionId: _connection.id,
        name: 'Open editorial room',
        managerProfile: 'zeta',
        memberProfiles: const ['zeta', 'alpha', 'beta', 'gamma'],
      );
      await tester.pumpWidget(
        _host(
          manager: manager,
          snapshot: _snapshot(
            profiles: const [
              AgentProfile(name: 'zeta'),
              AgentProfile(name: 'alpha'),
              AgentProfile(name: 'beta'),
              AgentProfile(name: 'gamma'),
            ],
            sessions: const [],
          ),
          roomStore: store,
        ),
      );
      await tester.pumpAndSettle();
      await _openRooms(tester);

      final row = find.byKey(ValueKey('mission-room-${room.id}'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.byKey(ValueKey('room-spine-${room.id}')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byKey(const ValueKey('room-avatar-stack')),
        ),
        findsOneWidget,
      );
      expect(find.text('+1'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      final data = tester
          .getSemantics(find.byKey(const ValueKey('room-avatar-stack')))
          .getSemanticsData();
      expect(data.label, startsWith('4 miembros'));
      for (final name in const ['zeta', 'alpha', 'beta', 'gamma']) {
        expect(data.label, isNot(contains(name)));
      }
      semantics.dispose();
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    },
  );
}
