import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_header.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/mascot/header_mascot.dart';
import 'package:hermes_android/core/widgets/mascot/mascot.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'bots/room/room_fixtures.dart';

/// QA 9493 owner report: the room's header pill showed invented CC0 sprites
/// instead of each bot's own face. These bots carry their own Bot Mode
/// faces (shape + colour), as the roster and the round sheet draw them.
const _bots = <String, AgentProfile>{
  'forja': AgentProfile(
    name: 'forja',
    botModeUiMeta: {
      'title': 'Forja',
      'shape': 'blobatar::boxy',
      'color': '#f08a24',
    },
  ),
  'astra': AgentProfile(
    name: 'astra',
    botModeUiMeta: {
      'title': 'Astra',
      'shape': 'blobatar::sun',
      'color': '#3b82f6',
    },
  ),
  'radar': AgentProfile(
    name: 'radar',
    botModeUiMeta: {
      'title': 'Radar',
      'shape': 'blobatar::hexagon',
      'color': '#14b8a6',
    },
  ),
  'argos': AgentProfile(
    name: 'argos',
    botModeUiMeta: {
      'title': 'Argos',
      'shape': 'blobatar::cloud',
      'color': '#8b5cf6',
    },
  ),
  'docs': AgentProfile(
    name: 'docs',
    botModeUiMeta: {
      'title': 'Docs',
      'shape': 'blobatar::droplet',
      'color': '#e11d48',
    },
  ),
};

HostedGroupMember _member(String handle) => HostedGroupMember.fromJson(
  memberJson('m-$handle', handle),
  authorityGatewayId: 'gw-test',
);

AgentProfile? _profileFor(HostedGroupMember member) => _bots[member.handle];

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: HeaderMascotScope(builder: buildHeaderMascot, child: child),
  ),
);

/// The round sheet's row face for [member] (room_sheets.dart: the members
/// list): the same [RoomMemberFace] fed by the same profile resolver.
Widget _sheetFace(HostedGroupMember member) => RoomMemberFace(
  key: ValueKey('sheet-face-${member.memberId}'),
  member: member,
  fallbackName: member.handle,
  profile: _profileFor(member),
  avatarCache: null,
  size: 32,
  signal: BotFaceSignal.idle,
);

LivingBotFace _faceUnder(WidgetTester tester, Finder of) =>
    tester.widget<LivingBotFace>(
      find.descendant(of: of, matching: find.byType(LivingBotFace)),
    );

void main() {
  group('room header pill wears the members\' original faces', () {
    final members = [
      for (final h in ['forja', 'astra', 'radar', 'argos', 'docs']) _member(h),
    ];
    const states = {
      'm-astra': RoomTurnState.working,
      'm-radar': RoomTurnState.needsYou,
    };

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              RoomHeaderBar(
                title: 'Sala',
                status: '',
                members: members,
                states: states,
                profileFor: _profileFor,
                avatarCache: null,
                onMore: () {},
              ),
              Row(children: [for (final m in members) _sheetFace(m)]),
            ],
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('no invented sprite: no MascotSprite or MascotCluster in the '
        'room header', (tester) async {
      await pump(tester);
      final header = find.byKey(const ValueKey('room-header-bar'));
      expect(header, findsOneWidget);
      expect(
        find.descendant(of: header, matching: find.byType(MascotSprite)),
        findsNothing,
      );
      expect(
        find.descendant(of: header, matching: find.byType(MascotCluster)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('each header face is the round sheet\'s face for that member: '
        'same widget, profile, shape and colour', (tester) async {
      await pump(tester);
      // Who needs you leads, then who works, then the rest in room order.
      const shown = ['radar', 'astra', 'forja', 'argos'];
      for (final handle in shown) {
        final headerFace = find.byKey(ValueKey('room-header-face-m-$handle'));
        expect(headerFace, findsOneWidget, reason: handle);
        final face = tester.widget<RoomMemberFace>(
          find.descendant(
            of: headerFace,
            matching: find.byType(RoomMemberFace),
          ),
        );
        expect(identical(face.profile, _bots[handle]), isTrue, reason: handle);
        // Both are the member's living face for the same profile, so the
        // same shape and colour; the one on the island rests and is still.
        final header = _faceUnder(tester, headerFace);
        final sheet = _faceUnder(
          tester,
          find.byKey(ValueKey('sheet-face-m-$handle')),
        );
        expect(header.profileName, sheet.profileName, reason: handle);
        expect(identical(header.profile, sheet.profile), isTrue);
        expect(header.profile!.botFaceShape, _bots[handle]!.botFaceShape);
        expect(header.profile!.botColorHex, _bots[handle]!.botColorHex);
        expect(header.stateMark, isFalse, reason: 'the cluster dots mark it');
        expect(header.signal, BotFaceSignal.idle, reason: handle);
        expect(header.animate, isFalse, reason: handle);
      }
      // Up to four faces (as in QA 9492), then "+N".
      expect(
        find.byKey(const ValueKey('room-header-face-m-docs')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('room-header-more')), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      // Left to right in that order.
      final xs = [
        for (final h in shown)
          tester.getTopLeft(find.byKey(ValueKey('room-header-face-m-$h'))).dx,
      ];
      expect(xs[0], lessThan(xs[1]));
      expect(xs[1], lessThan(xs[2]));
      expect(xs[2], lessThan(xs[3]));
      // The faces stand on the island, inside the header.
      final bar = tester.getRect(find.byKey(const ValueKey('room-header-bar')));
      final cluster = tester.getRect(
        find.byKey(const ValueKey('room-header-cluster')),
      );
      expect(bar.contains(cluster.center), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  // Owner (1.2.15): what stands on an island is always still. The members'
  // faces stay alive in the round and members sheets; on the island they
  // rest, and the dots say who works and who waits.
  group('room faces on the island never move', () {
    final members = [
      for (final h in ['forja', 'astra', 'radar', 'argos']) _member(h),
    ];
    const states = {
      'm-astra': RoomTurnState.working,
      'm-radar': RoomTurnState.needsYou,
    };

    testWidgets('no face clock runs for them, working or not', (tester) async {
      debugLivingBotFacesStill = false;
      addTearDown(() => debugLivingBotFacesStill = true);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              RoomHeaderBar(
                title: 'Sala',
                status: '',
                members: members,
                states: states,
                profileFor: _profileFor,
                avatarCache: null,
                onMore: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(livingBotFaceActiveTickers, 0);
      expect(livingBotFaceIdleFaces, 0);
      expect(livingBotFaceClockTimers, 0);
      // The cluster's own dots stay; no ring is added around the faces.
      expect(
        find.byKey(const ValueKey('room-header-dot-m-astra-working')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('living-face-ring-working')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(livingBotFaceClockTimers, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('header seam', () {
    testWidgets('a room request never reaches the sprite engine', (
      tester,
    ) async {
      HeaderMascotRequest? asked;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          home: Scaffold(
            body: FloatingChatHeader(
              headerMascotBuilder: (context, request) {
                asked = request;
                return const SizedBox.shrink(key: ValueKey('engine'));
              },
              faces: const SizedBox.square(
                key: ValueKey('original-faces'),
                dimension: FloatingChatHeader.faceSize,
              ),
              mascot: const HeaderMascotRequest(
                identity: 'Sala',
                state: HeaderMascotState.working,
                members: ['m-forja', 'm-astra'],
              ),
              pill: const ChatIsland(name: 'Sala', status: IslandStatus.idle),
            ),
          ),
        ),
      );
      expect(asked, isNull);
      expect(find.byKey(const ValueKey('engine')), findsNothing);
      expect(find.byKey(const ValueKey('original-faces')), findsOneWidget);
    });
  });
}
