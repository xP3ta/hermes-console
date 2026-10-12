import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_header.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'bots/room/room_fixtures.dart';
import 'support/face_halo.dart';

/// QA 9494 owner report: the small bot faces on the room's activity pill
/// wore a black halo. Shared rule (lib/core/widgets/face_marks.dart): a face
/// is drawn straight on whatever holds it — no separator ring, no backing,
/// no shadow; its state is a plain dot. Every pixel in a 3 dp band around
/// each face that the face itself does not paint must be exactly what is
/// behind (ΔE ≤ 3), on dark and light themes and on every surface a face
/// sits on (page, card, sheet).
const _bots = <String, AgentProfile>{
  'forja': AgentProfile(
    name: 'forja',
    botModeUiMeta: {'shape': 'blobatar::boxy', 'color': '#f08a24'},
  ),
  'astra': AgentProfile(
    name: 'astra',
    botModeUiMeta: {'shape': 'blobatar::sun', 'color': '#3b82f6'},
  ),
  'radar': AgentProfile(
    name: 'radar',
    botModeUiMeta: {'shape': 'blobatar::hexagon', 'color': '#14b8a6'},
  ),
  'argos': AgentProfile(
    name: 'argos',
    botModeUiMeta: {'shape': 'blobatar::cloud', 'color': '#8b5cf6'},
  ),
};

HostedGroupMember _member(String handle) => HostedGroupMember.fromJson(
  memberJson('m-$handle', handle),
  authorityGatewayId: 'gw-test',
);

final _themes = <String, ThemeData Function()>{
  'dark': () => AppTheme.fromId('console'),
  'light': () => AppTheme.fromId('console-light'),
  'oled': () => AppTheme.hermesRedOled,
};

Widget _shell(ThemeData theme, Widget child, {Color? backing}) =>
    RepaintBoundary(
      key: haloShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        home: Scaffold(
          backgroundColor: backing,
          body: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    );

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('room pill faces: no halo', () {
    for (final entry in _themes.entries) {
      testWidgets('${entry.key}: around each face only the pill or the page '
          'shows, and the state dot is a plain dot', (tester) async {
        final theme = entry.value();
        final colors = theme.hermes;
        await _size(tester, const Size(390, 140));
        Widget header(List<HostedGroupMember> members) => _shell(
          theme,
          RoomHeaderBar(
            title: 'Sala de pruebas del equipo',
            status: '',
            members: members,
            states: const {'m-astra': RoomTurnState.working},
            profileFor: (m) => _bots[m.handle],
            avatarCache: null,
            onMore: () {},
          ),
        );
        // What is behind the faces: the same header with nobody in it.
        await tester.pumpWidget(header(const []));
        await tester.pump(const Duration(seconds: 1));
        final empty = await grabShot(tester);
        await tester.pumpWidget(
          header([for (final h in _bots.keys) _member(h)]),
        );
        await tester.pump(const Duration(seconds: 1));
        final report = await probeHalo(
          tester,
          faces: find.descendant(
            of: find.byKey(const ValueKey('room-header-cluster')),
            matching: find.byType(HermesBotFace),
          ),
          behind: empty.at,
          theme: theme,
          dots: [
            ExpectedDot(
              find.byKey(const ValueKey('room-header-dot-m-astra-working')),
              roomTurnDotColor(colors, RoomTurnState.working),
            ),
          ],
          saveAs: 'pill-${entry.key}',
        );
        expect(report.checked, greaterThan(2000), reason: '$report');
        expect(report.bad, lessThanOrEqualTo(report.checked ~/ 100),
            reason: '$report');
        expect(report.dotChecked, greaterThan(100), reason: '$report');
        expect(report.dotBad, lessThanOrEqualTo(report.dotChecked ~/ 50),
            reason: '$report');
      });
    }
  });
}
