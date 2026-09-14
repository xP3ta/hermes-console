import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_mode_v13.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/room_avatar_stack.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'official stack orders display handles and keeps owner keys opaque',
    (tester) async {
      const members = [
        RoomAvatarOfficialMember(
          owner: AvatarOwner(connectionId: 'source-secret', profile: 'zeta'),
          displayName: 'same',
          handle: 'zeta-handle',
        ),
        RoomAvatarOfficialMember(
          owner: AvatarOwner(connectionId: 'source-secret', profile: 'alpha'),
          displayName: 'Same',
          handle: 'alpha-handle',
        ),
        RoomAvatarOfficialMember(
          owner: AvatarOwner(connectionId: 'source-secret', profile: 'beta'),
          displayName: 'Álpha',
          handle: 'beta-handle',
        ),
      ];
      expect(
        sortedOfficialRoomAvatarMembers(members).map((member) => member.handle),
        ['beta-handle', 'alpha-handle', 'zeta-handle'],
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: const Scaffold(
            body: RoomAvatarStack.official(members: members),
          ),
        ),
      );
      final publicKeys = tester.allWidgets
          .map((widget) => '${widget.key}')
          .join('\n');
      expect(publicKeys, isNot(contains('source-secret')));
      expect(publicKeys, isNot(contains('alpha')));
      expect(find.byType(RoomAvatarStack), findsOneWidget);
    },
  );

  testWidgets(
    'work row render visibility and tap retain one destination instance',
    (tester) async {
      const destination = TaskDestination(
        connectionId: 'owner-a',
        boardId: 'board-a',
        taskId: 'task-a',
        mode: WorkRouteMode.read,
      );
      const item = WorkItem.task(
        stableKey: 'private-key',
        title: 'Review release',
        decisionCopy: 'Ready',
        attention: WorkAttention.ready,
        taskRef: BoardTaskRef(boardId: 'board-a', taskId: 'task-a'),
        destination: destination,
      );
      WorkDestination? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MissionWorkItemAction(
              item: item,
              icon: Icons.work_outline,
              color: Colors.blue,
              onDestination: (value) => tapped = value,
            ),
          ),
        ),
      );
      final row = tester.widget<MissionWorkItemAction>(
        find.byType(MissionWorkItemAction),
      );
      expect(row.item.destination, same(destination));
      await tester.tap(find.byType(MissionWorkItemAction));
      expect(tapped, same(destination));
    },
  );

  test('room avatar ordering is stable and ignores local manager', () {
    const profiles = [
      AgentProfile(name: 'zeta', botModeUiMeta: {'title': 'Same'}),
      AgentProfile(name: 'alpha', botModeUiMeta: {'title': 'same'}),
      AgentProfile(name: 'beta', botModeUiMeta: {'title': 'Álpha'}),
    ];
    final first = sortedRoomAvatarMembers(
      connectionId: 'owner-a',
      profiles: profiles,
    );
    final shuffled = sortedRoomAvatarMembers(
      connectionId: 'owner-a',
      profiles: profiles.reversed,
    );

    expect(first.map((member) => member.owner.profile), [
      'beta',
      'alpha',
      'zeta',
    ]);
    expect(shuffled.map((member) => member.owner.profile), [
      'beta',
      'alpha',
      'zeta',
    ]);
    expect(first.map((member) => member.owner).toSet(), hasLength(3));
  });

  for (final count in [0, 1, 2, 3, 5]) {
    testWidgets('RoomAvatarStack renders $count members with exact semantics', (
      tester,
    ) async {
      final profiles = List.generate(
        count,
        (index) => AgentProfile(
          name: 'private_name_$index',
          botModeUiMeta: {'title': 'Bot $index'},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: Scaffold(
            body: RoomAvatarStack(connectionId: 'owner-a', profiles: profiles),
          ),
        ),
      );
      final semantics = tester.ensureSemantics();
      final stack = find.byKey(const ValueKey('room-avatar-stack'));

      expect(tester.getSize(stack), const Size(58, 48));
      expect(
        find.byKey(const ValueKey('room-avatar-neutral-group')),
        count == 0 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('room-avatar-incomplete')),
        count == 1 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('room-avatar-overflow')),
        count > 3 ? findsOneWidget : findsNothing,
      );
      if (count > 3) expect(find.text('+${count - 3}'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'room-avatar-member-',
              ),
        ),
        findsNWidgets(count.clamp(0, 3)),
      );

      final data = tester.getSemantics(stack).getSemanticsData();
      expect(
        data.label,
        count == 1 ? '1 miembro, equipo incompleto' : '$count miembros',
      );
      expect(data.flagsCollection.isImage, isTrue);
      for (final profile in profiles) {
        expect(data.label, isNot(contains(profile.name)));
      }
      final actualKeys = tester.allWidgets
          .map((widget) => '${widget.key}')
          .join('\n');
      expect(actualKeys, isNot(contains('owner-a')));
      expect(actualKeys, isNot(contains('private_name_')));
      semantics.dispose();
    });
  }
}
