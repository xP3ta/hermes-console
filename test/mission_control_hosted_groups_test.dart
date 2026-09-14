import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/core/widgets/room_avatar_stack.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'repository loads official list state and log under capability generation',
    () async {
      final calls = <String>[];
      final caps = GroupsCapabilities.tryParse(
        {
          'protocol_version': 2,
          'driver': true,
          'methods': [
            'groups.capabilities',
            'groups.list',
            'groups.state',
            'groups.log',
          ],
          'max_log_limit': 50,
        },
        connectionId: 'connection-private',
        generation: 7,
      )!;
      final listed = _room(name: 'Listed', revision: 1);
      final state = _room(name: 'Authoritative', revision: 2);
      final log = HostedGroupLogPage.fromJson(
        {
          'events': [_event(text: 'Safe public message')],
          'cursor': 1,
          'latest_seq': 1,
          'has_more': false,
          'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
        },
        expectedRoomId: 'room-private',
        sinceSeq: 0,
      );
      final gateway = MissionHostedGroupsGateway.callbacks(
        capabilities: () async {
          calls.add('capabilities');
          return caps;
        },
        list: ({required generation}) async {
          calls.add('list:$generation');
          return [listed];
        },
        state: (roomId, {required generation}) async {
          calls.add('state:$generation');
          return state;
        },
        log: (roomId, {required generation}) async {
          calls.add('log:$generation');
          return log;
        },
      );
      final repository = MissionControlRepository(
        profilesLoader: () async => const <AgentProfile>[],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: gateway,
      );

      final snapshot = await repository.load();

      expect(calls, ['capabilities', 'list:7', 'state:7', 'log:7']);
      expect(snapshot.hostedGroupsCapability, MissionCapabilityState.available);
      expect(snapshot.hostedGroups.capabilities, same(caps));
      expect(snapshot.hostedGroups.rooms.single.name, 'Authoritative');
      expect(
        snapshot.hostedGroups.logs.single.events.single.publicText,
        'Safe public message',
      );
      expect(snapshot.failures, isNot(contains('hostedGroups')));
    },
  );

  test(
    'repository exposes every enabled official mutation only through generation',
    () async {
      final calls = <String>[];
      final caps = GroupsCapabilities.tryParse(
        {
          'protocol_version': 2,
          'driver': true,
          'methods': GroupMethod.values
              .where((method) => method != GroupMethod.promote)
              .map((method) => method.wire)
              .toList(),
          'max_log_limit': 50,
        },
        connectionId: 'connection-private',
        generation: 11,
      )!;
      final room = _room(name: 'Shared', revision: 2);
      final log = HostedGroupLogPage.fromJson(
        {
          'events': [_event(text: 'sent')],
          'cursor': 1,
          'latest_seq': 1,
          'has_more': false,
          'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
        },
        expectedRoomId: 'room-private',
        sinceSeq: 0,
      );
      final gateway = MissionHostedGroupsGateway.callbacks(
        capabilities: () async => caps,
        list: ({required generation}) async => [room],
        state: (roomId, {required generation}) async => room,
        log: (roomId, {required generation}) async => log,
        create: ({required name, required members, required generation}) async {
          calls.add('create:$generation:$name:${members.length}');
          return room;
        },
        send:
            (
              roomId, {
              required text,
              required attempt,
              required generation,
            }) async {
              calls.add('send:$generation:$text:${attempt.threadId}');
              return log;
            },
        rename: (roomId, {required name, required generation}) async {
          calls.add('rename:$generation:$name');
          return room;
        },
        stop: (roomId, {required generation}) async {
          calls.add('stop:$generation');
          return room;
        },
        disband: (roomId, {required generation}) async {
          calls.add('disband:$generation');
          return _room(name: 'Shared', revision: 3, disbanded: true);
        },
      );
      final repository = MissionControlRepository(
        profilesLoader: () async => const [],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: gateway,
      );
      final members = [
        HostedGroupCreateMember.localProfile(profile: 'one', handle: 'one'),
        HostedGroupCreateMember.localProfile(profile: 'two', handle: 'two'),
      ];

      await repository.createHostedGroup(
        name: 'Shared',
        members: members,
        generation: 11,
      );
      await repository.renameHostedGroup(room, name: 'Renamed', generation: 11);
      await repository.stopHostedGroup(room, generation: 11);
      await repository.disbandHostedGroup(room, generation: 11);

      expect(calls, [
        'create:11:Shared:2',
        'rename:11:Renamed',
        'stop:11',
        'disband:11',
      ]);
    },
  );

  testWidgets(
    'real screen renders official rooms and hides unsupported controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final caps = _capabilities([
        GroupMethod.capabilities,
        GroupMethod.list,
        GroupMethod.state,
        GroupMethod.log,
        GroupMethod.send,
        GroupMethod.rename,
        GroupMethod.stop,
        GroupMethod.disband,
      ]);
      final room = _room(name: 'Shared room', revision: 2);
      final source = _HostedScreenSource(
        MissionBackendSnapshot(
          profiles: const [
            AgentProfile(name: 'one'),
            AgentProfile(name: 'two'),
          ],
          board: const KanbanBoard(columns: []),
          profilesCapability: MissionCapabilityState.available,
          sessionsCapability: MissionCapabilityState.available,
          kanbanCapability: MissionCapabilityState.available,
          hostedGroupsCapability: MissionCapabilityState.available,
          hostedGroups: HostedGroupsSnapshot(
            capabilities: caps,
            rooms: [room],
            logs: [
              HostedGroupLogPage.fromJson(
                {
                  'events': [_event(text: 'Safe public message')],
                  'cursor': 1,
                  'latest_seq': 1,
                  'has_more': false,
                  'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
                },
                expectedRoomId: 'room-private',
                sinceSeq: 0,
              ),
            ],
          ),
          loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: MissionControlScreen(
            connection: _connection,
            connManager: manager,
            dataSource: source,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mission-destination-work')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('mission-shared-rooms')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-room-0')),
        findsOneWidget,
      );
      expect(find.text('Shared room'), findsOneWidget);
      expect(find.text('Safe public message'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('mission-hosted-room-0')),
          matching: find.byType(RoomAvatarStack),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('mission-hosted-room-0')),
          matching: find.byType(HermesCard),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('mission-hosted-send-0')), findsNothing);
      expect(
        find.byKey(const ValueKey('mission-hosted-more-0')),
        findsOneWidget,
      );
      for (final action in const ['more']) {
        final target = find.byKey(ValueKey('mission-hosted-$action-0'));
        expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      }
      await tester.tap(find.byKey(const ValueKey('mission-hosted-more-0')));
      await tester.pumpAndSettle();
      for (final action in const ['rename', 'stop', 'disband']) {
        final target = find.byKey(ValueKey('mission-hosted-$action-0'));
        expect(target, findsOneWidget);
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-retry-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-approve-0')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('mission-local-rooms')), findsOneWidget);

      final publicTree = tester.allWidgets
          .map((widget) => '${widget.key} $widget')
          .join('\n');
      expect(publicTree, isNot(contains('room-private')));
      expect(publicTree, isNot(contains('event-private')));
      expect(publicTree, isNot(contains('connection-private')));
    },
  );

  testWidgets(
    'disbanded official room is removed and exposes no mutation controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _HostedScreenSource(
        MissionBackendSnapshot(
          profiles: const [],
          board: const KanbanBoard(columns: []),
          profilesCapability: MissionCapabilityState.available,
          sessionsCapability: MissionCapabilityState.available,
          kanbanCapability: MissionCapabilityState.available,
          hostedGroupsCapability: MissionCapabilityState.available,
          hostedGroups: HostedGroupsSnapshot(
            capabilities: _capabilities(GroupMethod.values),
            rooms: [
              _room(name: 'Disbanded room', revision: 3, disbanded: true),
            ],
            logs: const [],
          ),
          loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );

      await _pumpHostedScreen(tester, manager, source);

      expect(find.text('Disbanded room'), findsNothing);
      expect(find.byKey(const ValueKey('mission-hosted-room-0')), findsNothing);
      for (final action in const ['send', 'rename', 'stop', 'disband']) {
        expect(
          find.byKey(ValueKey('mission-hosted-$action-0')),
          findsNothing,
          reason: action,
        );
      }
    },
  );

  testWidgets(
    'authoritative disband read-back removes the room and its controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _HostedScreenSource(
        MissionBackendSnapshot(
          profiles: const [],
          board: const KanbanBoard(columns: []),
          profilesCapability: MissionCapabilityState.available,
          sessionsCapability: MissionCapabilityState.available,
          kanbanCapability: MissionCapabilityState.available,
          hostedGroupsCapability: MissionCapabilityState.available,
          hostedGroups: HostedGroupsSnapshot(
            capabilities: _capabilities(GroupMethod.values),
            rooms: [_room(name: 'Active room', revision: 2)],
            logs: const [],
          ),
          loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );
      await _pumpHostedScreen(tester, manager, source);

      await tester.tap(find.byKey(const ValueKey('mission-hosted-more-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mission-hosted-disband-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm').last);
      await tester.pumpAndSettle();

      expect(source.calls, ['disband:3']);
      expect(find.text('Active room'), findsNothing);
      expect(find.byKey(const ValueKey('mission-hosted-room-0')), findsNothing);
      for (final action in const ['send', 'rename', 'stop', 'disband']) {
        expect(find.byKey(ValueKey('mission-hosted-$action-0')), findsNothing);
      }
    },
  );

  testWidgets(
    'actual text tooltip and Semantics trees never project opaque or local authority fields',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _HostedScreenSource(
        MissionBackendSnapshot(
          profiles: const [],
          board: const KanbanBoard(columns: []),
          profilesCapability: MissionCapabilityState.available,
          sessionsCapability: MissionCapabilityState.available,
          kanbanCapability: MissionCapabilityState.available,
          hostedGroupsCapability: MissionCapabilityState.available,
          hostedGroups: HostedGroupsSnapshot(
            capabilities: _capabilities([
              GroupMethod.capabilities,
              GroupMethod.list,
              GroupMethod.state,
              GroupMethod.log,
              GroupMethod.send,
              GroupMethod.retry,
              GroupMethod.approve,
            ]),
            rooms: [_room(name: 'Public room', revision: 2)],
            logs: [
              HostedGroupLogPage.fromJson(
                {
                  'events': [_event(text: 'Public event text')],
                  'cursor': 1,
                  'latest_seq': 1,
                  'has_more': false,
                  'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
                },
                expectedRoomId: 'room-private',
                sinceSeq: 0,
              ),
            ],
          ),
          loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: MissionControlScreen(
            connection: _connection,
            connManager: manager,
            dataSource: source,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mission-destination-work')));
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();

      final actualText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
          .join('\n');
      final actualTooltips = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((widget) => widget.message ?? '')
          .join('\n');
      final semanticTree = tester
          .getSemantics(find.byKey(const ValueKey('mission-shared-rooms')))
          .toStringDeep();
      final exposed = '$actualText\n$actualTooltips\n$semanticTree';
      for (final secret in const [
        'room-private',
        'event-private',
        'member-private',
        'actor-private',
        'display-private',
        'profile-private',
        'actor-connection-private',
        'gateway-private',
        'connection-private',
        'manager-private',
        'summary-private',
      ]) {
        expect(exposed, isNot(contains(secret)), reason: secret);
      }
      expect(find.text('Public room'), findsOneWidget);
      expect(find.text('Public event text'), findsNothing);
      expect(
        find.byKey(const ValueKey('mission-hosted-retry-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-approve-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-rename-0')),
        findsNothing,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'retired hosted conversation never presents a bounded log or send control',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _workspaceSource();
      await _pumpHostedScreen(tester, manager, source);

      expect(find.byKey(const ValueKey('mission-hosted-send-0')), findsNothing);
      expect(find.text('Before'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-room-workspace')),
        findsOneWidget,
      );
      expect(find.text('View members'), findsOneWidget);
      await tester.tap(find.text('View members'));
      await tester.pumpAndSettle();
      expect(find.text('@builder'), findsOneWidget);
      expect(find.text('Before'), findsNothing);
      expect(find.text('Conversation'), findsNothing);
      expect(
        find.byKey(const ValueKey('mission-hosted-composer')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-composer-send')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-reply-0')),
        findsNothing,
      );
      expect(source.calls.where((call) => call.startsWith('send:')), isEmpty);
    },
  );

  testWidgets(
    'route rename stop and disband converge then close authoritatively',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _workspaceSource();
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename shared room'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, 'Renamed route');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(find.text('Renamed route'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop shared room?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disband shared room?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm').last);
      await tester.pumpAndSettle();

      expect(
        source.calls,
        containsAllInOrder(['rename:3:Renamed route', 'stop:3', 'disband:3']),
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-room-workspace')),
        findsNothing,
      );
      expect(find.text('Renamed route'), findsNothing);
    },
  );

  testWidgets('retired retry never reaches the owning hosted workspace', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final source = _workspaceSource(deferred: true);
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();

    expect(find.text('A room task can be retried.'), findsNothing);
    expect(find.byKey(const ValueKey('mission-hosted-retry-0')), findsNothing);
    expect(source.calls.where((call) => call.startsWith('retry:')), isEmpty);
  });

  testWidgets(
    'dock creates an official room independently of profiles capability',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _HostedScreenSource(
        MissionBackendSnapshot(
          profiles: const [
            AgentProfile(name: 'builder', botModeUiMeta: {'title': 'Builder'}),
            AgentProfile(
              name: 'reviewer',
              botModeUiMeta: {'title': 'Reviewer'},
            ),
          ],
          board: const KanbanBoard(columns: []),
          profilesCapability: MissionCapabilityState.unavailable,
          sessionsCapability: MissionCapabilityState.unavailable,
          kanbanCapability: MissionCapabilityState.unavailable,
          hostedGroupsCapability: MissionCapabilityState.available,
          hostedGroups: HostedGroupsSnapshot(
            capabilities: _capabilities([
              GroupMethod.capabilities,
              GroupMethod.list,
              GroupMethod.state,
              GroupMethod.log,
              GroupMethod.create,
            ]),
          ),
          loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: MissionControlScreen(
            connection: _connection,
            connManager: manager,
            dataSource: source,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
      await tester.pumpAndSettle();
      final roomOrb = find.byKey(const ValueKey('bot-mode-create-room'));
      expect(tester.widget<InkWell>(roomOrb).onTap, isNotNull);
      await tester.tap(roomOrb);
      await tester.pumpAndSettle();
      expect(find.text('Create shared room'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('mission-hosted-create-name')),
        'Release room',
      );
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      final confirm = find.byKey(
        const ValueKey('mission-hosted-create-confirm'),
      );
      expect(tester.widget<TextButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(source.calls, contains('create:3:Release room:builder,reviewer'));
      expect(source.loadCount, greaterThan(1));
      expect(source.createdMembers.first.toWire(memberId: 'member-fixture'), {
        'member_id': 'member-fixture',
        'profile': 'builder',
        'handle': 'builder',
        'target': {'kind': 'local', 'profile': 'builder'},
      });
    },
  );
}

final _connection = SavedConnection(
  id: 'screen-connection',
  label: 'Screen',
  host: 'localhost',
  port: 8642,
  apiKey: 'unused',
);

Future<void> _pumpHostedScreen(
  WidgetTester tester,
  ConnectionManager manager,
  _HostedScreenSource source,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: MissionControlScreen(
        connection: _connection,
        connManager: manager,
        dataSource: source,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('mission-destination-work')));
  await tester.pumpAndSettle();
}

GroupsCapabilities _capabilities(List<GroupMethod> methods) =>
    GroupsCapabilities.tryParse(
      {
        'protocol_version': 2,
        'driver': true,
        'methods': methods.map((method) => method.wire).toList(),
        'max_log_limit': 50,
      },
      connectionId: 'screen-connection',
      generation: 3,
    )!;

_HostedScreenSource _workspaceSource({
  int remainingSendFailures = 0,
  int? resultGeneration,
  List<GroupMethod>? methods,
  bool deferred = false,
}) => _HostedScreenSource(
  MissionBackendSnapshot(
    profiles: const [],
    board: const KanbanBoard(columns: []),
    profilesCapability: MissionCapabilityState.available,
    sessionsCapability: MissionCapabilityState.available,
    kanbanCapability: MissionCapabilityState.available,
    hostedGroupsCapability: MissionCapabilityState.available,
    hostedGroups: HostedGroupsSnapshot(
      capabilities: _capabilities(
        methods ??
            [
              GroupMethod.capabilities,
              GroupMethod.list,
              GroupMethod.state,
              GroupMethod.log,
              GroupMethod.send,
              GroupMethod.rename,
              GroupMethod.stop,
              GroupMethod.disband,
              if (deferred) GroupMethod.retry,
            ],
      ),
      rooms: [_room(name: 'Shared', revision: 2)],
      logs: [deferred ? _deferredLog() : _log(text: 'Before')],
    ),
    loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
  ),
  remainingSendFailures: remainingSendFailures,
  resultGeneration: resultGeneration,
);

final class _HostedScreenSource
    implements MissionControlDataSource, MissionHostedGroupsDataSource {
  final MissionBackendSnapshot snapshot;
  int remainingSendFailures;
  final int? resultGeneration;
  final List<String> calls = [];
  final List<HostedGroupSendAttempt> attempts = [];
  final List<HostedGroupCreateMember> createdMembers = [];
  int loadCount = 0;

  _HostedScreenSource(
    this.snapshot, {
    this.remainingSendFailures = 0,
    this.resultGeneration,
  });

  @override
  Future<MissionBackendSnapshot> load() async {
    loadCount += 1;
    return snapshot;
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() {}
  @override
  Future<HostedGroupRoom> createHostedGroup({
    required String name,
    required List<HostedGroupCreateMember> members,
    required int generation,
  }) async {
    calls.add(
      'create:$generation:$name:${members.map((member) => member.profile).join(',')}',
    );
    createdMembers.addAll(members);
    return _room(name: name, revision: 1);
  }

  @override
  Future<HostedGroupWorkspaceReadback> disbandHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  }) async {
    calls.add('disband:$generation');
    return HostedGroupWorkspaceReadback(
      room: _room(
        name: room.name,
        revision: room.revision + 1,
        disbanded: true,
      ),
      log: null,
      capabilityGeneration: generation,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> renameHostedGroup(
    HostedGroupRoom room, {
    required String name,
    required int generation,
  }) async {
    calls.add('rename:$generation:$name');
    return HostedGroupWorkspaceReadback(
      room: _room(name: name, revision: room.revision + 1),
      log: _log(text: 'Before'),
      capabilityGeneration: generation,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> sendHostedGroupText(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) async {
    calls.add('send:$generation:$text');
    attempts.add(attempt);
    if (remainingSendFailures > 0) {
      if (remainingSendFailures > 0) remainingSendFailures -= 1;
      throw StateError('transport-secret room-private');
    }
    return HostedGroupWorkspaceReadback(
      room: _room(name: room.name, revision: room.revision + 1),
      log: _log(text: text),
      capabilityGeneration: resultGeneration ?? generation,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> stopHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  }) async {
    calls.add('stop:$generation');
    return HostedGroupWorkspaceReadback(
      room: _room(name: room.name, revision: room.revision + 1),
      log: _log(text: 'Before'),
      capabilityGeneration: generation,
    );
  }
}

HostedGroupLogPage _log({required String text}) => HostedGroupLogPage.fromJson(
  {
    'events': [_event(text: text)],
    'cursor': 1,
    'latest_seq': 1,
    'has_more': false,
    'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
  },
  expectedRoomId: 'room-private',
  sinceSeq: 0,
);

HostedGroupLogPage _deferredLog() => HostedGroupLogPage.fromJson(
  {
    'events': [
      {
        'room_id': 'room-private',
        'seq': 1,
        'event_id': 'deferred-private',
        'kind': 'turn.deferred',
        'actor': {'kind': 'gateway', 'id': 'gateway-private'},
        'authority_epoch': 1,
        'payload': {
          'discussion_event_id': 'discussion-private',
          'member_id': 'member-private',
          'member_index': 0,
          'round_index': 0,
          'task_id': 'task-private-marker',
          'thread_id': 'thread-private',
          'turn_id': 'turn-private',
          'seen_through_seq': 1,
          'execution_generation': 1,
          'reason': 'reason-private-marker',
        },
        'created_at': 2,
        'idempotent': false,
      },
    ],
    'cursor': 1,
    'latest_seq': 1,
    'has_more': false,
    'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
  },
  expectedRoomId: 'room-private',
  sinceSeq: 0,
);

HostedGroupRoom _room({
  required String name,
  required int revision,
  bool disbanded = false,
}) => HostedGroupRoom.fromJson({
  'room_id': 'room-private',
  'name': name,
  'manager': 'manager-private',
  'public_summary': 'summary-private',
  'members': [
    {
      'member_id': 'member-private',
      'handle': 'builder',
      'profile': 'builder',
      'target': {'kind': 'local', 'profile': 'builder'},
    },
  ],
  'authority_gateway_id': 'gateway-private',
  'authority_epoch': 1,
  'revision': revision,
  'created_at': 1,
  'updated_at': 2,
  'latest_seq': 1,
  if (disbanded) 'disbanded_at': 3,
});

Map<String, Object?> _event({required String text}) => {
  'room_id': 'room-private',
  'seq': 1,
  'event_id': 'event-private',
  'kind': 'message.user',
  'actor': {
    'kind': 'user',
    'id': 'actor-private',
    'display_name': 'display-private',
    'profile': 'profile-private',
    'connection_id': 'actor-connection-private',
  },
  'authority_epoch': 1,
  'payload': {'text': text, 'thread_id': 'thread-event-private'},
  'created_at': 2,
  'idempotent': false,
};
