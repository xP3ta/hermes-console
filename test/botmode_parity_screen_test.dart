import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/room_mirror_avatar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'botmode_parity_model_test.dart'
    show mirrorPng, mirroredProfile, parityRoom;

class _Source implements MissionControlDataSource {
  final MissionBackendSnapshot snapshot;
  _Source(List<AgentProfile> profiles)
    : snapshot = MissionBackendSnapshot(
        profiles: profiles,
        board: const KanbanBoard(columns: []),
        profilesCapability: MissionCapabilityState.available,
        sessionsCapability: MissionCapabilityState.available,
        kanbanCapability: MissionCapabilityState.available,
        hostedGroupsCapability: MissionCapabilityState.available,
        hostedGroups: HostedGroupsSnapshot(
          capabilities: GroupsCapabilities.tryParse(
            {
              'protocol_version': 2,
              'driver': true,
              'max_log_limit': 50,
              'methods': [
                'groups.capabilities',
                'groups.list',
                'groups.state',
                'groups.log',
              ],
            },
            connectionId: 'parity-test',
            generation: 1,
          ),
          rooms: [parityRoom()],
          logs: const [],
        ),
        loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
      );
  @override
  Future<MissionBackendSnapshot> load() async => snapshot;
  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() {}
}

Widget _host(
  ConnectionManager manager,
  List<AgentProfile> profiles, {
  String connectionId = 'parity-test',
  String locale = 'es',
}) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: RepaintBoundary(
    key: const ValueKey('parity-frame'),
    child: MissionControlScreen(
      connection: SavedConnection(
        id: connectionId,
        label: 'Test',
        host: 'hermes.local',
        port: 8642,
        apiKey: '',
        readOnly: true,
      ),
      connManager: manager,
      dataSource: _Source(profiles),
    ),
  ),
);

Future<List<int>> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('parity-frame')),
  );
  final image = await boundary.toImage();
  try {
    return (await image.toByteData())!.buffer.asUint8List().toList();
  } finally {
    image.dispose();
  }
}

void main() {
  late ConnectionManager manager;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
  });
  tearDown(() => manager.dispose());

  testWidgets('malformed sections or mirror render the same pixels as none', (
    tester,
  ) async {
    Future<List<int>> frame({bool malformed = false}) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _host(manager, [
          AgentProfile.fromJson({
            'name': 'default',
            'ui_meta': {
              'hermes-bots': {
                'pinned': true,
                if (malformed) 'sectionId': [],
                if (malformed) 'sectionName': 42,
              },
              if (malformed)
                'hermes-bots-groups': {'version': 3, 'rooms': false},
            },
          }),
          const AgentProfile(name: 'builder'),
        ]),
      );
      await tester.pumpAndSettle();
      // Dots home: the main bot on top, the rest in the team grid.
      expect(find.byKey(const ValueKey('dots-main')), findsOneWidget);
      expect(find.byKey(const ValueKey('dots-tile-builder')), findsOneWidget);
      expect(find.text('Sin sección'), findsNothing);
      expect(find.byType(RoomMirrorAvatar), findsNothing);
      return (await tester.runAsync(() => _pixels(tester)))!;
    }

    expect(await frame(malformed: true), await frame());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Desktop sections do not split the team grid; pins lead their tier and '
    'hidden bots stay out',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final profiles = [
        const AgentProfile(
          name: 'pinned',
          botModeUiMeta: {
            'pinned': true,
            'sectionId': 'team',
            'sectionName': 'Team',
          },
        ),
        const AgentProfile(
          name: 'builder',
          botModeUiMeta: {'sectionId': 'team', 'sectionName': 'Team'},
        ),
        const AgentProfile(name: 'aloose'),
        const AgentProfile(
          name: 'hidden',
          botModeUiMeta: {
            'hidden': true,
            'sectionId': 'secret',
            'sectionName': 'Hidden section',
          },
        ),
      ];
      await tester.pumpWidget(_host(manager, profiles));
      await tester.pumpAndSettle();
      expect(find.text('Team'), findsNothing);
      expect(find.text('Hidden section'), findsNothing);
      expect(find.byKey(const ValueKey('dots-tile-hidden')), findsNothing);
      double x(String name) =>
          tester.getTopLeft(find.byKey(ValueKey('dots-tile-$name'))).dx;
      // Same tier and no activity: the pin leads, then by name.
      expect(x('pinned'), lessThan(x('aloose')));
      expect(x('aloose'), lessThan(x('builder')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('search over a sectioned roster stays one flat grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(manager, const [
        AgentProfile(
          name: 'visible',
          botModeUiMeta: {'sectionId': 'team', 'sectionName': 'Team'},
        ),
        AgentProfile(name: 'other'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('roster-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mission-bot-search')),
      'visible',
    );
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsNothing);
    expect(
      find.byKey(const ValueKey('mission-bot-row-visible')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mission-bot-row-other')), findsNothing);
  });

  testWidgets(
    'mirrored room image and name appear in list and header, never pseudo rooms or messages',
    (tester) async {
      await tester.pumpWidget(
        _host(manager, [
          mirroredProfile({
            'id:room-one': {
              'roomId': 'room-one',
              'name': 'Team picture',
              'image': mirrorPng,
              'log': [
                {'text': 'MIRROR ONLY MESSAGE'},
              ],
            },
            'id:local-only': {'roomId': 'local-only', 'name': 'Desktop only'},
          }),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Team picture'), findsOneWidget);
      // A Desktop-only room is listed by the roster as a read-only Desktop
      // projection row, never as a hosted (writable) room.
      expect(find.text('Desktop only'), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('roster-room-desktop-');
        }),
        findsOneWidget,
      );
      expect(find.text('MIRROR ONLY MESSAGE'), findsNothing);
      expect(find.byType(RoomMirrorAvatar), findsOneWidget);
      await tester.tap(find.text('Team picture'));
      await tester.pumpAndSettle();
      expect(find.text('Team picture'), findsOneWidget);
      expect(find.byType(RoomMirrorAvatar), findsOneWidget);
      expect(find.text('MIRROR ONLY MESSAGE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('damaged raster payload falls back without an exception', (
    tester,
  ) async {
    final parsed = AgentProfileAvatar.fromDataUri(mirrorPng);
    final broken = AgentProfileAvatar(
      mimeType: 'image/png',
      bytes: parsed.bytes.sublist(0, 24),
      width: 1,
      height: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RoomMirrorAvatar(
          image: broken,
          fallback: const Icon(Icons.groups_outlined),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
