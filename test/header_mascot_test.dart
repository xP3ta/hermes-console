import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/mascot/header_mascot.dart';
import 'package:hermes_android/core/widgets/mascot/mascot.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _theme = AppTheme.hermesRedDark;

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: _theme,
  home: Scaffold(body: child),
);

Widget _header(HeaderMascotRequest request) => HeaderMascotScope(
  builder: buildHeaderMascot,
  child: FloatingChatHeader(
    faces: const SizedBox.square(
      key: ValueKey('default-face'),
      dimension: FloatingChatHeader.faceSize,
    ),
    mascot: request,
    pill: const FloatingHeaderPill(
      key: ValueKey('test-pill'),
      text: 'Hermes',
      semanticsLabel: 'Hermes',
    ),
  ),
);

const _tool = ActivityStep(
  id: 'step-1',
  kind: ActivityStepKind.tool,
  label: 'terminal',
  status: ActivityStepStatus.running,
);

void main() {
  group('header mascot wiring (#187 seam × #189 engine)', () {
    testWidgets('a chat header draws one MascotSprite for the profile, from '
        'the activity snapshot, in the header slot', (tester) async {
      await tester.pumpWidget(
        _app(
          _header(
            const HeaderMascotRequest(
              identity: 'forja',
              state: HeaderMascotState.thinking,
              activity: ActivitySnapshot(turnActive: true, current: _tool),
              name: 'Forja',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('default-face')), findsNothing);
      final sprite = tester.widget<MascotSprite>(
        find.descendant(
          of: find.byKey(const ValueKey('floating-header-mascot-box')),
          matching: find.byType(MascotSprite),
        ),
      );
      // A running tool wins over the coarse "thinking" the header passed.
      expect(sprite.state, MascotState.tool);
      expect(sprite.identity, MascotIdentity.forProfile('forja'));
      expect(sprite.header, isTrue);
      expect(sprite.name, 'Forja');
      expect(sprite.size, FloatingChatHeader.faceSize);
    });

    testWidgets('offline, error, needs-you and just-finished map through '
        'mascotStateFor', (tester) async {
      Future<MascotState> stateOf(HeaderMascotRequest request) async {
        await tester.pumpWidget(_app(_header(request)));
        return tester.widget<MascotSprite>(find.byType(MascotSprite)).state;
      }

      const live = ActivitySnapshot(turnActive: true, current: _tool);
      expect(
        await stateOf(
          const HeaderMascotRequest(
            identity: 'qa',
            state: HeaderMascotState.offline,
            activity: live,
          ),
        ),
        MascotState.offline,
      );
      expect(
        await stateOf(
          const HeaderMascotRequest(
            identity: 'qa',
            state: HeaderMascotState.idle,
            activity: ActivitySnapshot.idle,
            error: true,
          ),
        ),
        MascotState.error,
      );
      expect(
        await stateOf(
          const HeaderMascotRequest(
            identity: 'qa',
            state: HeaderMascotState.waiting,
            activity: ActivitySnapshot(
              turnActive: true,
              waitingForUser: true,
              current: _tool,
            ),
          ),
        ),
        MascotState.needsYou,
      );
      expect(
        await stateOf(
          const HeaderMascotRequest(
            identity: 'qa',
            state: HeaderMascotState.idle,
            activity: ActivitySnapshot.idle,
            justFinished: true,
          ),
        ),
        MascotState.done,
      );
      // The default chat identity keeps Hermes' own sprite.
      await stateOf(
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.idle,
        ),
      );
      expect(
        tester.widget<MascotSprite>(find.byType(MascotSprite)).identity,
        MascotIdentity.hermes,
      );
    });

    testWidgets('a room header draws a MascotCluster with each member\'s own '
        'state, inside the slot', (tester) async {
      await tester.pumpWidget(
        _app(
          _header(
            const HeaderMascotRequest(
              identity: 'Sala',
              state: HeaderMascotState.working,
              members: ['forja', 'qa', 'ceo', 'ops', 'docs'],
              memberStates: [
                HeaderMascotState.working,
                HeaderMascotState.waiting,
                HeaderMascotState.idle,
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final cluster = tester.widget<MascotCluster>(find.byType(MascotCluster));
      expect(cluster.members.map((m) => m.state), [
        MascotState.tool,
        MascotState.needsYou,
        MascotState.idle,
        // No own state: the room's.
        MascotState.tool,
        MascotState.tool,
      ]);
      expect(
        cluster.members.first.identity,
        MascotIdentity.forProfile('forja'),
      );
      expect(find.byKey(const ValueKey('mascot-cluster-more')), findsOneWidget);
      final slot = tester.getRect(
        find.byKey(const ValueKey('floating-header-mascot-box')),
      );
      final drawn = tester.getRect(find.byType(MascotCluster));
      expect(slot.contains(drawn.topLeft), isTrue);
      expect(drawn.right, lessThanOrEqualTo(slot.right + 0.01));
      expect(tester.takeException(), isNull);
    });
  });
}
