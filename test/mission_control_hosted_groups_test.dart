import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'pill_copy_fit_test.dart' show expectPillLabelsFit;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/core/widgets/room_avatar_stack.dart';
import 'package:hermes_android/core/widgets/room_team_row.dart';
import 'package:hermes_android/core/widgets/room_member_status.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/models/room_member_status.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/inter_font.dart';

void main() {
  setUpAll(loadInterFont);

  TestWidgetsFlutterBinding.ensureInitialized();
  for (final surface in ['recipients', 'destinations']) {
    testWidgets('release $surface copy fits 360dp in es and en', (
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
          if (surface == 'destinations') {
            final bots = find.byKey(const ValueKey('mission-goto-bots'));
            expectPillLabelsFit(tester, bots);
            await tester.tap(bots);
            await tester.pumpAndSettle();
            expectPillLabelsFit(
              tester,
              find.byKey(const ValueKey('mission-goto-work')),
            );
          } else {
            await tester.tap(
              find.byKey(const ValueKey('mission-hosted-room-0')),
            );
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const ValueKey('mission-hosted-composer')),
              'hello',
            );
            await tester.pump();
            expectPillLabelsFit(
              tester,
              find.byKey(const ValueKey('room-recipients-preview')),
            );
          }
          await tester.pumpWidget(const SizedBox());
        }
      }
    });
  }

  for (final newerDraft in [false, true]) {
    testWidgets(
      'room ACK after leaving clears only its own draft, newer=$newerDraft',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        addTearDown(manager.dispose);
        final gate = Completer<void>();
        final source = _workspaceSource()..sendGate = gate;
        await _pumpHostedScreen(tester, manager, source);
        final room = find.byKey(const ValueKey('mission-hosted-room-0'));
        final composer = find.byKey(const ValueKey('mission-hosted-composer'));
        await tester.tap(room);
        await tester.pumpAndSettle();
        await tester.enterText(composer, 'Submitted draft');
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('mission-hosted-composer-send')),
        );
        await tester.pump();
        Navigator.of(tester.element(composer)).pop();
        await tester.pumpAndSettle();
        if (newerDraft) {
          await tester.tap(room);
          await tester.pumpAndSettle();
          await tester.enterText(composer, 'New draft');
          await tester.pump(const Duration(milliseconds: 400));
          Navigator.of(tester.element(composer)).pop();
          await tester.pumpAndSettle();
        }
        gate.complete();
        await tester.pumpAndSettle();
        await tester.tap(room);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(composer).controller!.text,
          newerDraft ? 'New draft' : '',
        );
      },
    );
  }

  testWidgets('room draft survives immediate back and reopen', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);
    final room = find.byKey(const ValueKey('mission-hosted-room-0'));
    final composer = find.byKey(const ValueKey('mission-hosted-composer'));
    await tester.tap(room);
    await tester.pumpAndSettle();
    await tester.enterText(composer, 'First line\nSecond line');
    Navigator.of(tester.element(composer)).pop();
    await tester.pumpAndSettle();
    await tester.tap(room);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'First line\nSecond line',
    );
    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-composer-send')),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(composer)).pop();
    await tester.pumpAndSettle();
    await tester.tap(room);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
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
      // Complete-history log loading is what unlocks `send` — see
      // `HostedGroupLogPage.loadComplete` and `GroupMethod.official` — so an
      // official `groups.send` capability now shows this quick-send action,
      // same as the other official mutation controls checked below.
      expect(
        find.byKey(const ValueKey('mission-hosted-send-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-more-0')),
        findsOneWidget,
      );
      for (final action in const ['send', 'more']) {
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
    'a fully-capable hosted room shows its team, transcript, and a working composer',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _workspaceSource();
      await _pumpHostedScreen(tester, manager, source);

      // The card-level quick-send action is only ever official once a
      // complete room log can back it up — see `HostedGroupLogPage.
      // loadComplete` — which this fixture's capabilities do provide.
      expect(
        find.byKey(const ValueKey('mission-hosted-send-0')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-room-workspace')),
        findsOneWidget,
      );
      // El desplegable "Ver miembros" con `ListTile`s vacíos ya no existe:
      // la sala tiene una sección "Equipo" plegada con su pila de avatares y
      // una fila real por miembro al abrirla.
      expect(
        find.byKey(const ValueKey('mission-hosted-members')),
        findsOneWidget,
      );
      expect(find.text('Team'), findsOneWidget);
      expect(find.text('1 member'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-members-header')),
      );
      await tester.pumpAndSettle();
      final memberRow = find.byKey(const ValueKey('room-team-member-builder'));
      expect(memberRow, findsOneWidget);
      // Sin perfil local (sala federada): la fila informa de dónde viene y
      // no finge un destino que la app no tiene.
      expect(find.textContaining('@builder'), findsOneWidget);
      expect(tester.widget<Semantics>(memberRow).properties.onTap, isNull);
      expect(tester.widget<Semantics>(memberRow).properties.button, isFalse);

      // A proven-complete log means the transcript, reply-in-thread and
      // composer are no longer withheld: `groups.send` is official here.
      //
      // El transcript ya no lleva un título de sección "Conversación" encima:
      // ningún chat real rotula su propio hilo, y esos ~44 dp se los queda la
      // conversación. La frontera con la tira de equipo la marca su línea.
      expect(find.text('Conversation'), findsNothing);
      expect(find.text('Before'), findsOneWidget);
      final message = find.byKey(const ValueKey('mission-hosted-message-0'));
      final bubble = find.descendant(
        of: message,
        matching: find.byType(Container),
      );
      final decoration =
          tester.widget<Container>(bubble).decoration! as BoxDecoration;
      final colors = Theme.of(tester.element(message)).hermes;
      expect(decoration.color, colors.surfaceVariant.withValues(alpha: 0.6));
      expect(decoration.borderRadius, BorderRadius.circular(20));
      expect(
        find.descendant(of: message, matching: find.text('user')),
        findsNothing,
      );
      expect(tester.getRect(bubble).right, tester.getRect(message).right - 12);
      expect(
        tester.getRect(bubble).left,
        greaterThanOrEqualTo(tester.getRect(message).left + 56),
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-reply-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-composer')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('mission-hosted-composer')),
        'hello there',
      );
      // Con el campo vacío la flecha de envío se pinta atenuada y no responde
      // (mismo criterio que `_SendButton` del chat real: antes lucía activa
      // sobre un tap que no hacía nada). `enterText` no bombea un frame, así
      // que el árbol pintado todavía es el del campo vacío; hace falta este
      // `pump` para que el botón ya esté habilitado al tocarlo.
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(source.calls, contains('send:3:hello there'));
    },
  );

  for (final themeId in ['dark', 'light']) {
    testWidgets('room member headers share team identity in $themeId', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
        {
          ..._event(text: 'Unknown reply'),
          'seq': 4,
          'event_id': 'unknown-event',
          'kind': 'message.member',
          'actor': {
            'kind': 'member',
            'id': 'unknown-private',
            'display_name': 'Guest bot',
            'profile': 'builder',
            'connection_id': 'unknown-connection-private',
          },
        },
      ];
      final log = HostedGroupLogPage.fromJson(
        {
          'events': events,
          'cursor': 4,
          'latest_seq': 4,
          'has_more': false,
          'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
        },
        expectedRoomId: 'room-private',
        sinceSeq: 0,
      );
      final source = _workspaceSource(
        room: _mixedMemberRoom(latestSeq: 4),
        log: log,
        profiles: const [
          AgentProfile(name: 'builder'),
          // A local profile with the same name must never claim a peer's avatar.
          AgentProfile(name: 'peer-profile'),
        ],
      );
      await _pumpHostedScreen(tester, manager, source, themeId: themeId);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();

      Finder message(int index) =>
          find.byKey(ValueKey('mission-hosted-message-$index'));
      final localAvatar = tester.widget<MissionProfileAvatar>(
        find.descendant(
          of: message(1),
          matching: find.byType(MissionProfileAvatar),
        ),
      );
      expect(localAvatar.profileName, 'builder');
      expect(localAvatar.size, 32);
      expect(find.text('>_ BUILDER BOT'), findsOneWidget);
      expect(find.text('Local reply'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Local reply')).dx, 12);
      final header = tester.widget<Text>(find.text('>_ BUILDER BOT'));
      expect(
        header.style!.color,
        Theme.of(tester.element(message(1))).hermes.accent,
      );
      expect(header.style!.fontSize, 12.5);
      expect(find.text('>_ PEER BOT'), findsOneWidget);
      expect(
        find.descendant(
          of: message(2),
          matching: find.byType(MissionProfileAvatar),
        ),
        findsNothing,
      );
      final peerAvatar = tester.widget<RoomMemberAvatar>(
        find.descendant(
          of: message(2),
          matching: find.byType(RoomMemberAvatar),
        ),
      );
      expect(peerAvatar.profileName, 'peer-handle');
      expect(peerAvatar.profile, isNull);
      // The transcript is reversed (newest message hugs the composer, like
      // any real chat), so the latest message — index 3 — is the one
      // nearest the bottom and already on-screen; no scroll needed for it.
      expect(find.text('>_ GUEST BOT'), findsOneWidget);
      expect(
        find.descendant(
          of: message(3),
          matching: find.byType(MissionProfileAvatar),
        ),
        findsNothing,
      );
      expect(find.textContaining('unknown-private'), findsNothing);
      expect(find.textContaining('unknown-connection-private'), findsNothing);

      // The restyled action still targets the original event's thread.
      await tester.tap(find.byKey(const ValueKey('mission-hosted-reply-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mission-hosted-composer')),
        'Thread reply',
      );
      // Ver la nota del envío de arriba: `enterText` no bombea, y la flecha
      // solo se habilita con texto.
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(source.attempts.single.threadId, 'local-thread');
      expect(source.calls, contains('send:3:Thread reply'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'typing @ in the room composer suggests and applies a matching member',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _workspaceSource();
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();

      final composer = find.byKey(const ValueKey('mission-hosted-composer'));
      await tester.enterText(composer, '@bui');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-mention-suggestions')),
        findsOneWidget,
      );
      final suggestion = find.byKey(
        const ValueKey('mission-hosted-mention-builder'),
      );
      expect(suggestion, findsOneWidget);

      await tester.tap(suggestion);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller!.text, '@builder ');
      // The resolved mention text closes the suggestion strip until another
      // in-progress `@fragment` starts.
      expect(
        find.byKey(const ValueKey('mission-hosted-mention-suggestions')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'open hosted room refreshes later replies and stops polling on disposal',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _RefreshingHostedSource(_workspaceSource().snapshot);
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(source.reads, 1);
      expect(find.text('Later bot reply'), findsOneWidget);
      source.failRead = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-room-error')),
        findsOneWidget,
      );
      expect(find.textContaining('private remote failure'), findsNothing);
      final reads = source.reads;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      expect(source.reads, reads);
    },
  );

  // Both equivalent server broadcast aliases are offered.
  for (final handle in ['everyone', 'all']) {
    testWidgets('broadcast autocomplete inserts @$handle and sends it', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final source = _workspaceSource();
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      final composer = find.byKey(const ValueKey('mission-hosted-composer'));
      await tester.enterText(composer, '@${handle.substring(0, 2)}');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('mission-hosted-mention-$handle')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller!.text, '@$handle ');
      await tester.enterText(composer, '@$handle reply once');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(
        source.calls.where((call) => call.startsWith('send:')).single,
        endsWith(':@$handle reply once'),
      );
    });
  }

  testWidgets('an open room cannot stop its replacement after a refresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();
    final old = source.snapshot;
    source.snapshot = MissionBackendSnapshot(
      profiles: old.profiles,
      board: old.board,
      profilesCapability: old.profilesCapability,
      sessionsCapability: old.sessionsCapability,
      kanbanCapability: old.kanbanCapability,
      hostedGroupsCapability: old.hostedGroupsCapability,
      hostedGroups: HostedGroupsSnapshot(
        capabilities: old.hostedGroups.capabilities,
        rooms: [_room(name: 'Replacement', revision: 1, roomId: 'replacement')],
      ),
      loadedAt: old.loadedAt,
    );
    // `tester.binding.handleAppLifecycleStateChanged` broadcasts to every
    // registered WidgetsBindingObserver, including an unrelated framework
    // AppLifecycleListener elsewhere in this pumped tree that asserts on its
    // own transition graph and throws regardless of the sequence given here.
    // The screen's own observer is what this test actually needs to drive,
    // so call it directly instead of going through the global broadcast.
    final observer =
        tester.state<State<MissionControlScreen>>(
              find.byType(MissionControlScreen, skipOffstage: false),
            )
            as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop room'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm').last);
    await tester.pumpAndSettle();
    expect(source.calls, isNot(contains('stop:3')));
    await tester.pumpWidget(const SizedBox.shrink());
    manager.dispose();
  });

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
      await tester.tap(find.text('Rename room'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, 'Renamed route');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(find.text('Renamed route'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      // El ítem del menú es imperativo ("Stop room"); el diálogo de
      // confirmación que abre sigue preguntando ("Stop room?") —
      // antes ambos compartían el mismo texto con "?", lo que leía como una
      // pregunta suelta en el menú (confirmado en dispositivo real).
      await tester.tap(find.text('Stop room'));
      await tester.pumpAndSettle();
      expect(find.text('Stop room?'), findsOneWidget);
      await tester.tap(find.text('Confirm').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disband room'));
      await tester.pumpAndSettle();
      expect(find.text('Disband room?'), findsOneWidget);
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

  // Las dos secciones eran títulos de 19 px idénticos y la única diferencia
  // era el texto, así que nada decía de un golpe qué salas viven en este
  // móvil y cuáles en el servidor. Ahora cada una lleva etiqueta en
  // mayúsculas, icono de ámbito, recuento, una línea de explicación y su
  // propia tarjeta redondeada.
  // Antes había dos secciones ("SHARED ROOMS"/"LOCAL ROOMS"): la sala local
  // se eliminó por completo (spec 061 — era un chat de 1 bot disfrazado de
  // sala, sin respaldo real de servidor ni en Desktop). Ahora solo existe
  // una sala, y su sección ya no lleva el calificador "compartida"/"shared".
  testWidgets('rooms read as a single labeled scoped section', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await _pumpHostedScreen(tester, manager, _workspaceSource());

    expect(find.text('ROOMS'), findsOneWidget);
    expect(
      find.text(
        'The whole team sees it, from any device — for working together '
        'in the open.',
      ),
      findsOneWidget,
    );
    expect(find.text('LOCAL ROOMS'), findsNothing);
    expect(find.textContaining('sala local'), findsNothing);
    expect(find.textContaining('local room'), findsNothing);

    // La fila de sala va dentro de una tarjeta redondeada de sección
    // (nunca una `HermesCard`, que es el contrato ya verificado arriba).
    final room = find.byKey(const ValueKey('mission-hosted-room-0'));
    expect(room, findsOneWidget);
    expect(
      find.ancestor(
        of: room,
        matching: find.byWidgetPredicate((widget) {
          if (widget is! DecoratedBox) return false;
          final decoration = widget.decoration;
          return decoration is BoxDecoration &&
              decoration.borderRadius != null &&
              decoration.color != null;
        }),
      ),
      findsWidgets,
    );
    expect(
      find.ancestor(of: room, matching: find.byType(HermesCard)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
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
    await tester.tap(find.byKey(const ValueKey('mission-hosted-create')));
    await tester.pumpAndSettle();

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
    await tester.tap(find.byKey(const ValueKey('mission-hosted-create')));
    await tester.pumpAndSettle();

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

  // El equipo de una sala compartida era un desplegable con `ListTile`s de
  // icono genérico y `@handle`: "entro en la sala, voy al equipo y no sale
  // nada". Ahora cada miembro es una fila real, y solo los que resuelven a un
  // perfil local de esta conexión llevan a algún sitio.
  testWidgets('shared room team rows resolve local bots and mark federated', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final source = _HostedScreenSource(
      MissionBackendSnapshot(
        profiles: const [AgentProfile(name: 'builder')],
        board: const KanbanBoard(columns: []),
        profilesCapability: MissionCapabilityState.available,
        sessionsCapability: MissionCapabilityState.available,
        kanbanCapability: MissionCapabilityState.available,
        hostedGroupsCapability: MissionCapabilityState.available,
        hostedGroups: HostedGroupsSnapshot(
          capabilities: _capabilities(const [
            GroupMethod.capabilities,
            GroupMethod.list,
            GroupMethod.state,
            GroupMethod.log,
          ]),
          rooms: [_mixedMemberRoom()],
          logs: const [],
        ),
        loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
      ),
    );
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-room-workspace')),
      findsOneWidget,
    );

    // Plegada por defecto: cabecera con pila de avatares y recuento.
    expect(
      find.byKey(const ValueKey('mission-hosted-members')),
      findsOneWidget,
    );
    expect(find.text('2 members'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('room-team-member-builder')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-members-header')),
    );
    await tester.pumpAndSettle();

    // Miembro local: nombre publicado por el servidor y ficha alcanzable.
    final local = find.byKey(const ValueKey('room-team-member-builder'));
    expect(local, findsOneWidget);
    expect(find.text('Builder bot'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('room-team-unavailable-builder')),
      findsNothing,
    );
    expect(tester.widget<Semantics>(local).properties.button, isTrue);

    // Miembro federado con nombre publicado: no es "no disponible", pero de
    // él no hay ficha local, así que su fila no es tocable.
    final peer = find.byKey(const ValueKey('room-team-member-peer-handle'));
    expect(peer, findsOneWidget);
    expect(find.text('Peer bot'), findsOneWidget);
    expect(tester.widget<Semantics>(peer).properties.onTap, isNull);
    expect(
      find.byKey(const ValueKey('room-team-unavailable-peer-handle')),
      findsNothing,
    );

    // Las salas compartidas no tienen coordinador: ninguna fila lleva rol.
    expect(find.byKey(const ValueKey('room-team-role-builder')), findsNothing);
    expect(
      find.byKey(const ValueKey('room-team-role-peer-handle')),
      findsNothing,
    );

    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-agent-detail')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // El modelo admite hasta 128 miembros por sala: el desplegable no puede
  // pintarlos todos en línea dentro del cuerpo de la sala.
  testWidgets('a crowded shared room caps inline rows and lists the rest', (
    tester,
  ) async {
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
          capabilities: _capabilities(const [
            GroupMethod.capabilities,
            GroupMethod.list,
            GroupMethod.state,
            GroupMethod.log,
          ]),
          rooms: [_crowdedRoom(14)],
          logs: const [],
        ),
        loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
      ),
    );
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();
    expect(find.text('14 members'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-members-header')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomTeamRow), findsNWidgets(12));
    final all = find.byKey(const ValueKey('mission-hosted-members-all'));
    expect(all, findsOneWidget);
    expect(find.text('See all 14 members'), findsOneWidget);

    // El desplegable tiene techo y se desplaza solo, para no comerle el alto
    // a la conversación de la sala.
    await Scrollable.ensureVisible(
      tester.element(all),
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-members-screen')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  // Con el equipo desplegado y el teclado abierto la columna de la sala
  // desbordaba (61 px en 360×640 con 300 px de IME) cuando el desplegable
  // tenía alto fijo.
  testWidgets('the expanded team yields height to the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
          capabilities: _capabilities(const [
            GroupMethod.capabilities,
            GroupMethod.list,
            GroupMethod.state,
            GroupMethod.log,
            GroupMethod.send,
          ]),
          rooms: [_crowdedRoom(14)],
          logs: const [],
        ),
        loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
      ),
    );
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-members-header')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mission-hosted-members-header')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  // La tira de equipo plegada mide ~69 dp. Cuando era un hijo `Flexible` de la
  // misma columna que el `Expanded` del transcript, se repartían el hueco
  // libre al 50 % y los ~250 dp de su mitad que no usaba NO volvían al
  // transcript: `RenderFlex` los dejaba como sobrante al final de la columna,
  // o sea un vacío negro debajo del composer (258 dp medidos en 360×800). Es
  // el "no se puede ver así" reportado en dispositivo real.
  // En horizontal con el teclado abierto al cuerpo de la sala le quedan poco
  // más de 100 dp. La tira de equipo mide ~69 dp y su cabecera no se puede
  // comprimir, así que acotarla a secas la hacía desbordar; ahora se desplaza
  // dentro de su techo y, si ni la cabecera cabe, se retira entera. Sea como
  // sea, la conversación y el composer siguen ahí y no hay `RenderFlex`
  // desbordado.
  testWidgets('the room survives landscape with the keyboard open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(740, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource(room: _crowdedRoom(14));
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-members-header')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    for (final inset in const [140.0, 180.0, 230.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-composer')),
        findsOneWidget,
        reason: 'inset $inset',
      );
      expect(tester.takeException(), isNull, reason: 'inset $inset');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the room composer sits at the bottom, with no dead space', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _workspaceSource();
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();

    final workspace = tester.getRect(
      find.byKey(const ValueKey('mission-hosted-room-workspace')),
    );
    final composer = tester.getRect(
      find.byKey(const ValueKey('mission-hosted-composer')),
    );
    // El relleno inferior del host del composer son 10 dp; cualquier cosa
    // mucho mayor que eso es hueco muerto otra vez.
    expect(workspace.bottom - composer.bottom, lessThan(24));
    // Y el transcript llega hasta el composer en vez de cortarse a media
    // pantalla.
    final transcript = tester.getRect(find.byType(ListView).last);
    final summary = tester.getRect(
      find.byKey(const ValueKey('room-summary-pill')),
    );
    expect(transcript.top - summary.bottom, inInclusiveRange(0, 8));
    expect(summary.height, lessThan(45));
    expect(composer.top - transcript.bottom, lessThan(24));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'both broadcasts, complete scrollable roster and live recipient preview',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final source = _presenceSource();
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      final header = find.byKey(const ValueKey('room-live-members'));
      expect(tester.widget<ListView>(header).scrollDirection, Axis.horizontal);
      for (final status in [
        'member-builder-active',
        'member-reviewer-idle',
        'member-default-unknown',
      ]) {
        expect(find.byKey(ValueKey('room-status-$status')), findsOneWidget);
      }
      final composer = find.byKey(const ValueKey('mission-hosted-composer'));
      await tester.enterText(composer, '@');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-mention-all')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-hosted-mention-everyone')),
        findsOneWidget,
      );
      final palette = find.byKey(
        const ValueKey('mission-hosted-mention-suggestions'),
      );
      final scroll = find.descendant(
        of: palette,
        matching: find.byType(ListView),
      );
      expect(tester.widget<ListView>(scroll).scrollDirection, Axis.horizontal);
      await tester.drag(scroll, const Offset(-450, 0));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-mention-default')),
        findsOneWidget,
      );
      for (final entry in {
        'Hello': 'Everyone (3)',
        '@everyone hello': 'Everyone (3)',
        '@all hello': 'Everyone (3)',
        '@unknown hello': 'Everyone (3)',
        '@builder hello': 'To 1 of 3',
        '@builder @reviewer hello': 'To 2 of 3',
      }.entries) {
        await tester.enterText(composer, entry.key);
        await tester.pumpAndSettle();
        final preview = find.byKey(const ValueKey('room-recipients-preview'));
        expect(
          find.descendant(of: preview, matching: find.text(entry.value)),
          findsOneWidget,
        );
      }
      await tester.enterText(composer, '@');
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(palette).bottom,
        lessThanOrEqualTo(tester.getRect(composer).top),
      );
      expect(tester.getRect(composer).bottom, lessThanOrEqualTo(844 - 320));
      final summary = find.byKey(const ValueKey('room-summary-pill'));
      if (summary.evaluate().isNotEmpty) {
        expect(
          tester.getRect(summary).bottom,
          lessThanOrEqualTo(
            tester
                .getRect(find.byKey(const ValueKey('room-recipients-preview')))
                .top,
          ),
        );
      }
      expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('room inline pending is replaced by reply and explicit pass', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final source = _presenceSource();
    await _pumpHostedScreen(tester, manager, source);
    await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('mission-hosted-composer'));
    await tester.enterText(composer, '@builder @reviewer please reply');
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('mission-hosted-composer-send')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('room-response-event-1-member-builder-pending'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('room-response-event-1-member-reviewer-pending'),
      ),
      findsOneWidget,
    );
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
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Here is the answer'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('room-response-event-1-member-builder-pending'),
      ),
      findsNothing,
    );
    expect(find.text('reviewer passed'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-summary-expanded')), findsOneWidget);
    expect(find.text('builder answered'), findsOneWidget);
    expect(find.text('reviewer passed'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'timeout is a muted inline line; summary merges the bounded durable activity',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final source = _presenceSource();
      source.events.addAll([
        _presenceEvent(
          1,
          'message.user',
          at: DateTime.now().millisecondsSinceEpoch / 1000 - 130,
        ),
        _presenceEvent(2, 'message.member', discussion: 'older-run'),
        for (var i = 3; i < 58; i++)
          _presenceEvent(
            i,
            'turn.settled',
            member: 'reviewer',
            payload: {'passed': true},
          ),
      ]);
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-room-refresh')),
      );
      await tester.pumpAndSettle();
      expect(find.text('builder did not reply'), findsOneWidget);
      expect(find.byKey(const ValueKey('room-activity-toggle')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Recent'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('room-summary-more-recent')),
        findsOneWidget,
      );
      expect(find.text('see more (44)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('room-summary-recent-event-2')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'working header uses existing face motion and unboxed detail; reduced motion stays still',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final source = _presenceSource();
      source.events.addAll([
        _presenceEvent(1, 'message.user'),
        _presenceEvent(
          2,
          'turn.started',
          payload: {'description': 'Review the requested changes'},
        ),
      ]);
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-room-refresh')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final faces = tester.widgetList<HermesBotFace>(
        find.byType(HermesBotFace),
      );
      expect(
        faces.any(
          (face) =>
              face.animate &&
              face.motionState == HermesBotFaceMotionState.thinking,
        ),
        isTrue,
      );
      expect(find.textContaining('Review the requested changes'), findsWidgets);
      final statuses = tester.widgetList<RoomStatusAvatar>(
        find.byType(RoomStatusAvatar),
      );
      expect(
        statuses.any(
          (avatar) => avatar.status.presence == RoomPresence.working,
        ),
        isTrue,
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

  // Tras tocar "Responder en hilo" el único indicio era que cambiaba el texto
  // de sugerencia del campo, y no había forma de salir del hilo salvo enviar.
  testWidgets(
    'the room says which thread it is replying to, and can leave it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final source = _workspaceSource();
      await _pumpHostedScreen(tester, manager, source);
      await tester.tap(find.byKey(const ValueKey('mission-hosted-room-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-thread-banner')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('mission-hosted-reply-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-thread-banner')),
        findsOneWidget,
      );
      expect(find.text('Replying in thread'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-thread-cancel')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-hosted-thread-banner')),
        findsNothing,
      );
      // Salir del hilo devuelve el envío a la sala: el intento estrena su
      // propio hilo derivado del `client_event_id` en vez de reusar el del
      // mensaje al que se había tocado "Responder en hilo".
      await tester.enterText(
        find.byKey(const ValueKey('mission-hosted-composer')),
        'Back to the room',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('mission-hosted-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(source.attempts.single.threadId, isNot('thread-event-private'));
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
      log: _log(text: 'Later bot reply'),
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
