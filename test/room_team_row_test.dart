import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/core/widgets/room_team_row.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  late MissionProfileAvatarCache avatarCache;

  setUp(() {
    avatarCache = MissionProfileAvatarCache(loader: (_) async => null);
  });

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(body: child),
  );

  RoomTeamRow row({
    String profileName = 'manager',
    String handle = 'manager',
    String displayName = 'Manager',
    AgentProfile? profile = const AgentProfile(name: 'manager'),
    bool manager = false,
    String? roleLabel,
    String? statusLabel,
    String? subtitle,
    bool needsYou = false,
    bool unavailable = false,
    VoidCallback? onTap,
  }) => RoomTeamRow(
    profileName: profileName,
    handle: handle,
    displayName: displayName,
    profile: profile,
    avatarCache: avatarCache,
    manager: manager,
    roleLabel: roleLabel,
    statusLabel: statusLabel,
    statusColor: Colors.green,
    subtitle: subtitle,
    needsYou: needsYou,
    unavailable: unavailable,
    onTap: onTap,
  );

  testWidgets('manager ring and role pill render', (tester) async {
    await tester.pumpWidget(host(row(manager: true, roleLabel: 'Coordinador')));

    final avatar = tester.widget<MissionProfileAvatar>(
      find.byType(MissionProfileAvatar),
    );
    expect(avatar.manager, isTrue);
    expect(find.text('Coordinador'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('room-team-role-manager')),
      findsOneWidget,
    );
  });

  testWidgets('role, status, and subtitle are independently optional', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Column(
          children: [
            row(
              profileName: 'no-role',
              handle: 'no-role',
              displayName: 'No role',
              profile: const AgentProfile(name: 'no-role'),
              statusLabel: 'Trabajando',
              subtitle: 'Task one',
            ),
            row(
              profileName: 'no-status',
              handle: 'no-status',
              displayName: 'No status',
              profile: const AgentProfile(name: 'no-status'),
              roleLabel: 'Worker',
              subtitle: 'Task two',
            ),
            row(
              profileName: 'no-subtitle',
              handle: 'no-subtitle',
              displayName: 'No subtitle',
              profile: const AgentProfile(name: 'no-subtitle'),
              roleLabel: 'Worker',
              statusLabel: 'Bloqueado',
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('room-team-role-no-role')), findsNothing);
    expect(
      find.byKey(const ValueKey('room-team-status-no-status')),
      findsNothing,
    );
    expect(find.text('@no-subtitle'), findsOneWidget);
    expect(find.text('@no-role · Task one'), findsOneWidget);
    expect(find.text('@no-status · Task two'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row without onTap has no InkWell and is not a button', (
    tester,
  ) async {
    await tester.pumpWidget(host(row()));

    final member = find.byKey(const ValueKey('room-team-member-manager'));
    expect(
      find.descendant(of: member, matching: find.byType(InkWell)),
      findsNothing,
    );
    final properties = tester.widget<Semantics>(member).properties;
    expect(properties.button, isFalse);
    expect(properties.onTap, isNull);
  });

  testWidgets('tapping an actionable row fires once', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(row(onTap: () => taps++)));

    await tester.tap(find.byKey(const ValueKey('room-team-member-manager')));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('unavailable rows are desaturated and less opaque', (
    tester,
  ) async {
    await tester.pumpWidget(host(row(unavailable: true)));

    final member = find.byKey(const ValueKey('room-team-member-manager'));
    final opacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('room-team-unavailable-manager')),
    );
    expect(opacity.opacity, 0.55);
    expect(
      find.descendant(of: member, matching: find.byType(ColorFiltered)),
      findsOneWidget,
    );
  });

  testWidgets('member and avatar ValueKeys are present', (tester) async {
    await tester.pumpWidget(host(row(profileName: 'infra')));

    expect(
      find.byKey(const ValueKey('room-team-member-infra')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('room-team-avatar-infra')),
      findsOneWidget,
    );
  });

  testWidgets('an unresolved member uses the neutral avatar', (tester) async {
    await tester.pumpWidget(
      host(row(profileName: 'peer-research', profile: null)),
    );

    final avatar = find.byKey(const ValueKey('room-team-avatar-peer-research'));
    expect(
      find.descendant(of: avatar, matching: find.byType(MissionProfileAvatar)),
      findsNothing,
    );
    expect(
      find.descendant(of: avatar, matching: find.byIcon(Icons.circle_outlined)),
      findsOneWidget,
    );
  });
}
