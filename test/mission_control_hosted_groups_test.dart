import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/core/widgets/room_team_row.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/inter_font.dart';

void main() {
  setUpAll(loadInterFont);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Bots header and New menu fit 360dp in es and en', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final locale in ['es', 'en']) {
      for (final scale in [1.0, 1.3]) {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        addTearDown(manager.dispose);
        await _pumpHostedScreen(
          tester,
          manager,
          _workspaceSource(),
          locale: locale,
          scale: scale,
        );
        // No Work destination, pill or header switcher.
        expect(find.byKey(const ValueKey('mission-goto-bots')), findsNothing);
        expect(find.byKey(const ValueKey('mission-goto-work')), findsNothing);
        expect(_roomRow(), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('mission-create-agent')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('mission-create-chooser-board')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('a seen room stops asking for the user in the Bots list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final mention = HostedGroupLogPage.fromJson(
      {
        'events': [
          {
            'room_id': 'room-private',
            'seq': 1,
            'event_id': 'mention-1',
            'kind': 'message.member',
            'actor': {
              'kind': 'member',
              'id': 'member-private',
              'profile': 'builder',
            },
            'authority_epoch': 1,
            'payload': {
              'discussion_event_id': 'user:d1',
              'member_id': 'member-private',
              'member_index': 0,
              'round_index': 0,
              'task_id': 'task-1',
              'thread_id': 'thread-1',
              'turn_id': 'turn-1',
              'text': 'Done. @user FYI the build is green.',
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
    await _pumpHostedScreen(tester, manager, _workspaceSource(log: mention));
    final needs = find.byKey(const ValueKey('roster-section-needs-you'));
    expect(needs, findsOneWidget);

    // Leaving the room writes the seen marker, exactly as RoomScreen does.
    await tester.runAsync(
      () => SharedPreferencesRoomPrefs(
        manager.prefs,
      ).setLastSeenSeq('gateway-private:room-private', 1),
    );
    await tester.pumpAndSettle();
    expect(needs, findsNothing);
  });

  for (final missingMethod in [false, true]) {
    test(
      'unsupported hosted surface is explicit, missing RPC=$missingMethod',
      () async {
        final gateway = MissionHostedGroupsGateway.callbacks(
          capabilities: () async {
            if (missingMethod) {
              throw const TuiGatewayRpcError(
                'groups.capabilities',
                'unsupported',
                code: -32601,
              );
            }
            return GroupsCapabilities.tryParse(
              {
                'protocol_version': 2,
                'driver': false,
                'max_log_limit': 500,
                'methods': ['groups.capabilities', 'groups.list'],
              },
              connectionId: 'fixture',
              generation: 1,
            )!;
          },
          list: ({required generation}) async =>
              throw StateError('must not list'),
          state: (_, {required generation}) async =>
              throw StateError('must not read'),
          log: (_, {required generation}) async =>
              throw StateError('must not read'),
        );
        final repository = MissionControlRepository(
          profilesLoader: () async => [],
          sessionsLoader: () async => [],
          boardLoader: () async => const KanbanBoard(columns: []),
          hostedGroupsGateway: gateway,
        );
        final snapshot = await repository.load();
        expect(
          snapshot.hostedGroupsCapability,
          MissionCapabilityState.unsupported,
        );
        expect(snapshot.hostedGroups.rooms, isEmpty);
      },
    );
  }

  test(
    'room readback fetches later replies and send retains the complete log',
    () async {
      final calls = <String>[];
      final room = _room(name: 'Room', revision: 2);
      final caps = GroupsCapabilities.tryParse(
        {
          'protocol_version': 2,
          'driver': true,
          'max_log_limit': 500,
          'methods': [
            'groups.capabilities',
            'groups.list',
            'groups.state',
            'groups.log',
            'groups.send',
          ],
        },
        connectionId: 'fixture',
        generation: 1,
      )!;
      final complete = _log(text: 'Later bot reply');
      final gateway = MissionHostedGroupsGateway.callbacks(
        capabilities: () async => caps,
        list: ({required generation}) async => [room],
        state: (_, {required generation}) async {
          calls.add('state');
          return room;
        },
        log: (_, {required generation}) async {
          calls.add('log');
          return complete;
        },
        send:
            (_, {required text, required attempt, required generation}) async {
              calls.add('send');
              return _log(text: 'acknowledgement only');
            },
      );
      final repository = MissionControlRepository(
        profilesLoader: () async => [],
        sessionsLoader: () async => [],
        boardLoader: () async => const KanbanBoard(columns: []),
        hostedGroupsGateway: gateway,
      );
      expect(
        (await repository.readHostedGroup(room, generation: 1)).log,
        same(complete),
      );
      expect(calls, ['state', 'log']);
      calls.clear();
      final sent = await repository.sendHostedGroupText(
        room,
        text: '@all reply',
        attempt: HostedGroupSendAttempt.forClientEvent('test-send'),
        generation: 1,
      );
      expect(sent.log, same(complete));
      expect(calls, ['send', 'state', 'log']);
    },
  );

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

      expect(_roomRow(), findsOneWidget);
      expect(find.text('Shared room'), findsOneWidget);
      expect(
        find.ancestor(of: _roomRow(), matching: find.byType(HermesCard)),
        findsNothing,
      );
      // The room actions that lived on the Work card are on the row's
      // long-press sheet, gated by the same official capabilities.
      await _openRoomActions(tester);
      for (final action in const [
        'open',
        'members',
        'rename',
        'stop',
        'disband',
      ]) {
        final target = find.byKey(ValueKey('roster-room-action-$action'));
        expect(target, findsOneWidget, reason: action);
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
      expect(
        find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('roster-room-row-');
        }),
        findsNothing,
      );
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

      await _openRoomActions(tester);
      await tester.tap(find.byKey(const ValueKey('roster-room-action-disband')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('roster-room-confirm')));
      await tester.pumpAndSettle();

      expect(source.calls, ['disband:3']);
      expect(find.text('Active room'), findsNothing);
      expect(
        find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('roster-room-row-');
        }),
        findsNothing,
      );
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
          .getSemantics(find.byKey(const ValueKey('mission-bots')))
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
      expect(
        find.byKey(const ValueKey('mission-hosted-retry-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-approve-0')),
        findsNothing,
      );
      await _openRoomActions(tester);
      expect(
        find.byKey(const ValueKey('roster-room-action-rename')),
        findsNothing,
      );
      semantics.dispose();
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
    await tester.tap(_roomRow());
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
      expect(find.text('Create room'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('mission-hosted-create-name')),
        'Release room',
      );
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-create-member-builder')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-create-member-reviewer')),
      );
      await tester.pump();
      final confirm = find.byKey(
        const ValueKey('mission-hosted-create-confirm'),
      );
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
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

  // El diálogo se abre con `autofocus` en el nombre, así que el teclado ya
  // está fuera en el primer frame real. La superficie flotante descuenta ese
  // inset por su cuenta (desplazamiento + `maxHeight`); cuando el diálogo lo
  // volvía a sumar como padding interno, el contenido se quedaba sin altura
  // utilizable y el resultado era la "ventana trabada" reportada en el Pixel.
  testWidgets('the create-room dialog stays usable with the keyboard open', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    const size = Size(390, 844);
    const keyboard = 320.0;
    // `setSurfaceSize` cambia el lienzo pero no lo que `MediaQuery` publica
    // (`MediaQueryData.fromView` lee la vista), y la superficie flotante mide
    // con `MediaQuery`: hay que configurar la vista, no el lienzo.
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final source = _HostedScreenSource(
      MissionBackendSnapshot(
        profiles: const [
          AgentProfile(name: 'builder', botModeUiMeta: {'title': 'Builder'}),
          AgentProfile(name: 'reviewer', botModeUiMeta: {'title': 'Reviewer'}),
        ],
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewInsets: const EdgeInsets.only(bottom: keyboard),
            disableAnimations: true,
          ),
          child: child!,
        ),
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
    await tester.tap(find.byKey(const ValueKey('bot-mode-create-room')));
    await tester.pumpAndSettle();

    // Nada desborda y todo el diálogo cabe por encima del teclado.
    expect(tester.takeException(), isNull);
    final dialog = find.byKey(const ValueKey('mission-hosted-create-dialog'));
    expect(dialog, findsOneWidget);
    expect(
      tester.getRect(dialog).bottom,
      lessThanOrEqualTo(size.height - keyboard),
    );

    // El campo de nombre, la lista y los botones siguen existiendo, con alto
    // real y dentro de la superficie (antes quedaban aplastados a ~0 px).
    final name = find.byKey(const ValueKey('mission-hosted-create-name'));
    final confirm = find.byKey(const ValueKey('mission-hosted-create-confirm'));
    expect(tester.getSize(name).height, greaterThan(24));
    expect(tester.getSize(confirm).height, greaterThanOrEqualTo(36));
    expect(tester.getRect(name).top, greaterThanOrEqualTo(0));
    expect(
      tester.getRect(confirm).bottom,
      lessThanOrEqualTo(tester.getRect(dialog).bottom),
    );
    // El scroll del contenido conserva alto real: con el inset del teclado
    // contado dos veces se quedaba en ~0 px y era lo que hacía que el diálogo
    // se viera "trabado".
    // El scroll del contenido conserva alto real: con el inset del teclado
    // contado dos veces se quedaba en ~100 px o menos y era lo que hacía que
    // el diálogo se viera "trabado".
    expect(
      tester
          .getSize(
            find
                .descendant(of: dialog, matching: find.byType(Scrollable))
                .first,
          )
          .height,
      greaterThan(240),
    );

    // Y la selección responde al tacto con el teclado abierto.
    await tester.enterText(name, 'Release room');
    final builderRow = find.byKey(
      const ValueKey('mission-hosted-create-member-builder'),
    );
    await tester.ensureVisible(builderRow);
    await tester.pumpAndSettle();
    await tester.tap(builderRow);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-create-selected-count')),
      findsOneWidget,
    );
    expect(find.text('1 member'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  // The Work area (its "ROOMS" section, the "whole team sees it" line and
  // the stacked-face cards) is gone: rooms are rows of the Bots roster.
  testWidgets('rooms are roster rows, never a separate Work section', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await _pumpHostedScreen(tester, manager, _workspaceSource());

    expect(find.text('ROOMS'), findsNothing);
    expect(find.textContaining('The whole team sees it'), findsNothing);
    expect(find.byKey(const ValueKey('mission-shared-rooms')), findsNothing);
    expect(find.byKey(const ValueKey('mission-work-feed')), findsNothing);
    expect(_roomRow(), findsOneWidget);
    expect(
      find.ancestor(of: _roomRow(), matching: find.byType(HermesCard)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a room action keeps every room\'s driver status', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    final base = source.snapshot;
    source.snapshot = MissionBackendSnapshot(
      profiles: base.profiles,
      board: base.board,
      profilesCapability: base.profilesCapability,
      sessionsCapability: base.sessionsCapability,
      kanbanCapability: base.kanbanCapability,
      hostedGroupsCapability: base.hostedGroupsCapability,
      hostedGroups: HostedGroupsSnapshot(
        capabilities: base.hostedGroups.capabilities,
        rooms: base.hostedGroups.rooms,
        logs: base.hostedGroups.logs,
        driverStatuses: {
          'room-private': RoomDriverStatus.tryParse({
            'running': true,
            'working': false,
            'blocked': false,
            'pending_actions': [
              {
                'kind': 'approval',
                'task_id': 't-approve',
                'member_id': 'member-private',
                'execution_generation': 1,
                'request_id': 'r-approve',
              },
            ],
          })!,
        },
      ),
      loadedAt: base.loadedAt,
    );
    await _pumpHostedScreen(tester, manager, source);
    expect(
      find.byKey(const ValueKey('roster-section-needs-you')),
      findsOneWidget,
    );

    await _openRoomActions(tester);
    await tester.tap(find.byKey(const ValueKey('roster-room-action-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('roster-room-rename-field')),
      'Renamed room',
    );
    await tester.tap(find.byKey(const ValueKey('roster-room-rename-save')));
    await tester.pumpAndSettle();
    expect(source.calls, contains('rename:3:Renamed room'));

    // The pending approval did not go anywhere: the room still needs you.
    expect(
      find.byKey(const ValueKey('roster-section-needs-you')),
      findsOneWidget,
    );
  });

  testWidgets('room actions from the roster rename and stop the room', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);

    await _openRoomActions(tester);
    await tester.tap(find.byKey(const ValueKey('roster-room-action-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('roster-room-rename-field')),
      'Renamed room',
    );
    await tester.tap(find.byKey(const ValueKey('roster-room-rename-save')));
    await tester.pumpAndSettle();
    expect(source.calls, contains('rename:3:Renamed room'));

    await _openRoomActions(tester);
    await tester.tap(find.byKey(const ValueKey('roster-room-action-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('roster-room-confirm')));
    await tester.pumpAndSettle();
    expect(source.calls, contains('stop:3'));

    await _openRoomActions(tester);
    await tester.tap(find.byKey(const ValueKey('roster-room-action-members')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-members-sheet')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _openRoomActions(tester);
    await tester.tap(find.byKey(const ValueKey('roster-room-action-open')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-room-workspace')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // "Todos aparecen apilados en un montón": la lista de bots no daba ninguna
  // estructura. Ahora los elegidos suben arriba como pills quitables y, con
  // un roster largo, hay buscador. El filtro solo afecta a lo que se pinta:
  // un bot ya elegido que el filtro esconda sigue entrando en la sala.
  testWidgets('the member picker surfaces chosen bots and never loses one', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final source = _HostedScreenSource(
      MissionBackendSnapshot(
        profiles: [
          const AgentProfile(
            name: 'builder',
            botModeUiMeta: {'title': 'Builder'},
          ),
          const AgentProfile(
            name: 'reviewer',
            botModeUiMeta: {'title': 'Reviewer'},
          ),
          for (var index = 0; index < 9; index++)
            AgentProfile(name: 'filler_$index'),
        ],
        board: const KanbanBoard(columns: []),
        profilesCapability: MissionCapabilityState.available,
        sessionsCapability: MissionCapabilityState.available,
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
    await _pumpHostedScreen(tester, manager, source);
    await _openCreateRoom(tester);

    await tester.enterText(
      find.byKey(const ValueKey('mission-hosted-create-name')),
      'Release room',
    );
    await tester.pump();

    // Sin nadie elegido, el diálogo dice qué hacer en vez de dejar la
    // franja vacía.
    expect(
      find.byKey(const ValueKey('mission-hosted-create-chosen-empty')),
      findsOneWidget,
    );

    Future<void> tapMember(String profile) async {
      final row = find.byKey(ValueKey('mission-hosted-create-member-$profile'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    await tapMember('builder');
    expect(
      find.byKey(const ValueKey('mission-hosted-create-chosen-builder')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mission-hosted-create-chosen-empty')),
      findsNothing,
    );

    // Con 11 bots el buscador sí aparece.
    final filter = find.byKey(const ValueKey('mission-hosted-create-filter'));
    expect(filter, findsOneWidget);
    await tester.enterText(filter, 'reviewer');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-create-member-builder')),
      findsNothing,
    );
    // Escondido de la lista, pero su pill sigue arriba: la selección no se
    // pierde al filtrar.
    expect(
      find.byKey(const ValueKey('mission-hosted-create-chosen-builder')),
      findsOneWidget,
    );

    await tapMember('reviewer');
    expect(find.text('2 members'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-create-confirm')),
    );
    await tester.pumpAndSettle();
    expect(source.calls, contains('create:3:Release room:builder,reviewer'));
    expect(tester.takeException(), isNull);
  });

  // La pill de un elegido se toca para quitarlo, así que corregir un toque
  // mal dado no obliga a volver a buscar su fila en la lista.
  testWidgets('a chosen pill removes that bot from the room draft', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final source = _HostedScreenSource(
      MissionBackendSnapshot(
        profiles: const [
          AgentProfile(name: 'builder', botModeUiMeta: {'title': 'Builder'}),
          AgentProfile(name: 'reviewer', botModeUiMeta: {'title': 'Reviewer'}),
        ],
        board: const KanbanBoard(columns: []),
        profilesCapability: MissionCapabilityState.available,
        sessionsCapability: MissionCapabilityState.available,
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
    await _pumpHostedScreen(tester, manager, source);
    await _openCreateRoom(tester);

    // Con menos de 9 bots el buscador no aparece: la lista ya cabe.
    expect(
      find.byKey(const ValueKey('mission-hosted-create-filter')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-create-member-builder')),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 member'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-create-chosen-builder')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-create-selected-count')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mission-hosted-create-chosen-empty')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  // ── Spec 070: the hosted room opens the group-chat RoomScreen ───────────

  Finder roomField() => find.descendant(
    of: find.byKey(const ValueKey('room-composer')),
    matching: find.byType(TextField),
  );

  Future<void> tapSend(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('composer-primary-action-switcher')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a hosted room opens RoomScreen with transcript and composer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(_roomRow());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-room-workspace')),
      findsOneWidget,
    );
    expect(find.byType(RoomScreen), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);
    // No legacy team strip or summary pill.
    expect(find.byKey(const ValueKey('room-summary-pill')), findsNothing);
    expect(find.byKey(const ValueKey('mission-hosted-members')), findsNothing);
    await tester.enterText(roomField(), 'hello there');
    await tapSend(tester);
    expect(source.calls, contains('send:3:hello there'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('room draft survives immediate back and reopen', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);
    final room = _roomRow();
    await tester.tap(room);
    await tester.pumpAndSettle();
    await tester.enterText(roomField(), 'First line\nSecond line');
    Navigator.of(tester.element(roomField())).pop();
    await tester.pumpAndSettle();
    await tester.tap(room);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(roomField()).controller!.text,
      'First line\nSecond line',
    );
    await tapSend(tester);
    Navigator.of(tester.element(roomField())).pop();
    await tester.pumpAndSettle();
    await tester.tap(room);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(roomField()).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final handle in ['builder', 'everyone', 'all']) {
    testWidgets('@ palette inserts @$handle and sends it', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final source = _workspaceSource();
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(_roomRow());
      await tester.pumpAndSettle();
      await tester.tap(roomField());
      await tester.enterText(roomField(), '@${handle.substring(0, 1)}');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('room-mention-$handle')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(roomField()).controller!.text,
        '@$handle ',
      );
      await tester.enterText(roomField(), '@$handle reply once');
      await tapSend(tester);
      expect(
        source.calls.where((call) => call.startsWith('send:')).single,
        endsWith(':@$handle reply once'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('open room polls later replies and stops polling on disposal', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _RefreshingHostedSource(_workspaceSource().snapshot);
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(_roomRow());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(source.reads, greaterThanOrEqualTo(1));
    expect(find.text('Later bot reply'), findsOneWidget);
    source.failRead = true;
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-error')), findsOneWidget);
    expect(find.textContaining('private remote failure'), findsNothing);
    final reads = source.reads;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
    expect(source.reads, reads);
  });

  testWidgets('overflow rename, stop and disband converge then close', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(_roomRow());
    await tester.pumpAndSettle();

    Future<void> menu(String item) async {
      await tester.tap(find.byKey(const ValueKey('room-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('room-menu-$item')));
      await tester.pumpAndSettle();
    }

    await menu('settings');
    await tester.enterText(
      find.byKey(const ValueKey('room-settings-name')),
      'Renamed route',
    );
    await tester.tap(find.byKey(const ValueKey('room-settings-save')));
    await tester.pumpAndSettle();
    expect(find.text('Renamed route'), findsOneWidget);

    await menu('stop');
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
    );
    await tester.pumpAndSettle();

    await menu('disband');
    await tester.tap(
      find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
    );
    await tester.pumpAndSettle();
    expect(
      source.calls,
      containsAllInOrder(['rename:3:Renamed route', 'stop:3', 'disband:3']),
    );
    expect(
      find.byKey(const ValueKey('mission-hosted-room-workspace')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local members show their face; peers never borrow a local one', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final events = [
      _event(text: 'Before'),
      {
        ..._event(text: 'Local reply'),
        'seq': 2,
        'event_id': 'local-event',
        'payload': {'text': 'Local reply', 'thread_id': 'local-thread'},
        'kind': 'message.member',
        'actor': {'kind': 'member', 'id': 'member-local'},
      },
      {
        ..._event(text: 'Peer reply'),
        'seq': 3,
        'event_id': 'peer-event',
        'kind': 'message.member',
        'actor': {
          'kind': 'member',
          'id': 'peer-actor',
          'profile': 'peer-profile',
          'connection_id': 'peer-connection',
        },
      },
    ];
    final log = HostedGroupLogPage.fromJson(
      {
        'events': events,
        'cursor': 3,
        'latest_seq': 3,
        'has_more': false,
        'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
      },
      expectedRoomId: 'room-private',
      sinceSeq: 0,
    );
    final source = _workspaceSource(
      room: _mixedMemberRoom(latestSeq: 3),
      log: log,
      profiles: const [
        AgentProfile(name: 'builder'),
        AgentProfile(name: 'peer-profile'),
      ],
    );
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(_roomRow());
    await tester.pumpAndSettle();
    final local = tester.widget<RoomMemberAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('room-face-local-event')),
        matching: find.byType(RoomMemberAvatar),
      ),
    );
    expect(local.profile?.name, 'builder');
    final peer = tester.widget<RoomMemberAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('room-face-peer-event')),
        matching: find.byType(RoomMemberAvatar),
      ),
    );
    expect(peer.profile, isNull);
    expect(find.text('Builder bot'), findsOneWidget);
    expect(find.text('Peer bot'), findsOneWidget);
    // Cross-gateway room: attachments are disabled with a reason (G1).
    expect(
      find.byKey(const ValueKey('room-attach-disabled-reason')),
      findsOneWidget,
    );
    // Reply-in-thread targets the original event thread.
    await tester.tap(find.byKey(const ValueKey('room-reply-local-event')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-thread-banner')), findsOneWidget);
    await tester.enterText(roomField(), 'Thread reply');
    await tapSend(tester);
    expect(source.attempts.single.threadId, 'local-thread');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the room leaves the thread from its banner', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(_roomRow());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-reply-event-private')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-thread-banner')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('room-thread-leave')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-thread-banner')), findsNothing);
    await tester.enterText(roomField(), 'Back to the room');
    await tapSend(tester);
    expect(source.attempts.single.threadId, isNot('thread-event-private'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in const [Size(360, 800), Size(740, 360)]) {
    testWidgets('room composer stays docked with the keyboard at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final source = _workspaceSource(room: _crowdedRoom(14));
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(_roomRow());
      await tester.pumpAndSettle();
      final screen = tester.getRect(
        find.byKey(const ValueKey('mission-hosted-room-workspace')),
      );
      final composer = tester.getRect(
        find.byKey(const ValueKey('room-composer')),
      );
      expect(screen.bottom - composer.bottom, lessThan(24));
      for (final inset in const [140.0, 180.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pumpAndSettle();
        expect(roomField(), findsOneWidget, reason: 'inset $inset');
        expect(tester.takeException(), isNull, reason: 'inset $inset');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'member replies and passes: reply shown, pass is one quiet line',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final source = _presenceSource();
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(_roomRow());
      await tester.pumpAndSettle();
      await tester.enterText(roomField(), '@builder @reviewer please reply');
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('composer-primary-action-switcher')),
      );
      await tester.pumpAndSettle();
      source.events.add(
        _presenceEvent(2, 'message.member', text: 'Here is the answer'),
      );
      source.events.add(
        _presenceEvent(
          3,
          'turn.settled',
          member: 'reviewer',
          payload: {'passed': true},
        ),
      );
      // Idle rooms back off (3 s → 15 s ceiling); one idle interval later.
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('Here is the answer'), findsOneWidget);
      expect(find.text('reviewer passed · Activity ›'), findsOneWidget);
      expect(find.text('reviewer passed'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

/// Sala compartida con `count` miembros locales, para el tope de filas en
/// línea del desplegable de equipo y para el alto del desplegable.
HostedGroupRoom _crowdedRoom(int count) => HostedGroupRoom.fromJson({
  'room_id': 'room-private',
  'name': 'Crowded room',
  'members': [
    for (var index = 0; index < count; index++)
      {
        'member_id': 'member-$index',
        'handle': 'bot-$index',
        'profile': 'bot-$index',
        'target': {'kind': 'local', 'profile': 'bot-$index'},
      },
  ],
  'authority_gateway_id': 'gateway-private',
  'authority_epoch': 1,
  'revision': 1,
  'created_at': 1,
  'updated_at': 2,
  'latest_seq': 0,
});

/// Sala compartida con un miembro local a esta conexión y otro federado, los
/// dos con `display_name` publicado por el servidor.
HostedGroupRoom _mixedMemberRoom({int latestSeq = 0}) =>
    HostedGroupRoom.fromJson({
      'room_id': 'room-private',
      'name': 'Mixed room',
      'members': [
        {
          'member_id': 'member-local',
          'handle': 'builder',
          'display_name': 'Builder bot',
          'profile': 'builder',
          'target': {'kind': 'local', 'profile': 'builder'},
        },
        {
          'member_id': 'member-peer',
          'handle': 'peer-handle',
          'display_name': 'Peer bot',
          'profile': 'peer-profile',
          'target': {
            'kind': 'peer',
            'peer_id': 'peer-connection',
            'installation_id': 'peer-installation',
            'profile': 'peer-profile',
            'capability_digest': 'a' * 64,
          },
        },
      ],
      'authority_gateway_id': 'gateway-private',
      'authority_epoch': 1,
      'revision': 1,
      'created_at': 1,
      'updated_at': 2,
      'latest_seq': latestSeq,
    });

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
  _HostedScreenSource source, {
  String themeId = 'dark',
  String locale = 'en',
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId(themeId),
      home: MissionControlScreen(
        connection: _connection,
        connManager: manager,
        dataSource: source,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The first hosted room row of the Bots roster (rooms live there now; the
/// separate Work destination is gone).
Finder _roomRow() => find
    .byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('roster-room-row-');
    })
    .first;

/// Long-press a room row to open its actions sheet.
Future<void> _openRoomActions(WidgetTester tester) async {
  await tester.longPress(_roomRow());
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('roster-room-actions')), findsOneWidget);
}

/// Header "New" menu → New room.
Future<void> _openCreateRoom(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mission-create-agent')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('mission-create-chooser-room')));
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
  HostedGroupRoom? room,
  HostedGroupLogPage? log,
  List<AgentProfile> profiles = const [],
}) => _HostedScreenSource(
  MissionBackendSnapshot(
    profiles: profiles,
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
      rooms: [room ?? _room(name: 'Shared', revision: 2)],
      logs: [log ?? (deferred ? _deferredLog() : _log(text: 'Before'))],
    ),
    loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
  ),
  remainingSendFailures: remainingSendFailures,
  resultGeneration: resultGeneration,
);

class _HostedScreenSource
    implements MissionControlDataSource, MissionHostedGroupsDataSource {
  MissionBackendSnapshot snapshot;
  int remainingSendFailures;
  final int? resultGeneration;
  final List<String> calls = [];
  final List<HostedGroupSendAttempt> attempts = [];
  final List<HostedGroupCreateMember> createdMembers = [];
  int loadCount = 0;
  Completer<void>? sendGate;

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
    await sendGate?.future;
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
  String roomId = 'room-private',
}) => HostedGroupRoom.fromJson({
  'room_id': roomId,
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

final class _RefreshingHostedSource extends _HostedScreenSource
    implements MissionHostedGroupsReadDataSource {
  _RefreshingHostedSource(super.snapshot);
  int reads = 0;
  bool failRead = false;

  @override
  Future<HostedGroupWorkspaceReadback> readHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  }) async {
    reads++;
    if (failRead) throw StateError('private remote failure');
    return HostedGroupWorkspaceReadback(
      room: room,
      // A later reply advances the log (a real server never rewrites seq 1).
      log: HostedGroupLogPage.fromJson(
        {
          'events': [
            _event(text: 'Before'),
            {
              ..._event(text: 'Later bot reply'),
              'seq': 2,
              'event_id': 'event-later',
              'payload': {'text': 'Later bot reply', 'thread_id': 'later'},
            },
          ],
          'cursor': 2,
          'latest_seq': 2,
          'has_more': false,
          'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
        },
        expectedRoomId: 'room-private',
        sinceSeq: 0,
      ),
      capabilityGeneration: generation,
    );
  }
}

HostedGroupRoom _presenceRoom() => HostedGroupRoom.fromJson({
  'room_id': 'room-private',
  'name': 'Team presence',
  'members': [
    for (final name in ['builder', 'reviewer', 'default'])
      {
        'member_id': 'member-$name',
        'handle': name,
        'profile': name,
        'target': name == 'default'
            ? {
                'kind': 'peer',
                'peer_id': 'peer',
                'installation_id': 'peer-install',
                'profile': name,
                'capability_digest': 'a' * 64,
              }
            : {'kind': 'local', 'profile': name},
      },
  ],
  'authority_gateway_id': 'gateway-private',
  'authority_epoch': 1,
  'revision': 2,
  'created_at': 1,
  'updated_at': 2,
  'latest_seq': 0,
});
Map<String, Object?> _presenceEvent(
  int seq,
  String kind, {
  String member = 'builder',
  String discussion = 'event-1',
  String text = 'Hello',
  num? at,
  Map<String, Object?> payload = const {},
}) => {
  'room_id': 'room-private',
  'seq': seq,
  'event_id': 'event-$seq',
  'kind': kind,
  'actor': {
    'kind': kind == 'message.user' ? 'user' : 'member',
    'id': 'member-$member',
  },
  'authority_epoch': 1,
  'created_at': at ?? DateTime.now().millisecondsSinceEpoch / 1000,
  'idempotent': false,
  'payload': kind == 'message.user'
      ? {'text': text, 'thread_id': 'thread'}
      : {
          'member_id': 'member-$member',
          'discussion_event_id': discussion,
          'thread_id': 'thread',
          'task_id': 'task-$member',
          if (kind == 'message.member') 'text': text,
          ...payload,
        },
};
_PresenceSource _presenceSource() => _PresenceSource(
  _workspaceSource(
    room: _presenceRoom(),
    profiles: [
      AgentProfile(
        name: 'builder',
        lastSession: AgentProfileSessionSummary(
          id: 'recent',
          lastActive: DateTime.now().millisecondsSinceEpoch / 1000,
        ),
      ),
      const AgentProfile(name: 'reviewer'),
      const AgentProfile(name: 'default', gatewayRunning: true),
    ],
    log: HostedGroupLogPage.fromJson(
      {
        'events': [],
        'cursor': 0,
        'latest_seq': 0,
        'has_more': false,
        'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
      },
      expectedRoomId: 'room-private',
      sinceSeq: 0,
    ),
  ).snapshot,
);

class _PresenceSource extends _HostedScreenSource
    implements MissionHostedGroupsReadDataSource {
  _PresenceSource(super.snapshot);
  final events = <Map<String, Object?>>[];
  HostedGroupLogPage get log => HostedGroupLogPage.fromJson(
    {
      'events': events,
      'cursor': events.length,
      'latest_seq': events.length,
      'has_more': false,
      'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
    },
    expectedRoomId: 'room-private',
    sinceSeq: 0,
  );
  @override
  Future<HostedGroupWorkspaceReadback> readHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  }) async => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: generation,
  );
  @override
  Future<HostedGroupWorkspaceReadback> sendHostedGroupText(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) async {
    events.add(_presenceEvent(events.length + 1, 'message.user', text: text));
    return readHostedGroup(room, generation: generation);
  }
}
