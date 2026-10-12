import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/material.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/mascot/header_mascot.dart';
import 'package:hermes_android/core/widgets/mascot/mascot.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart'
    show debugMascotActiveTimers;
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
    pill: const ChatIsland(name: 'Hermes', status: IslandStatus.idle),
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
    testWidgets('a chat header without an original face draws Hermes\' own '
        'sprite, never a sprite picked for the identity', (tester) async {
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
      // QA 9493: no sprite is ever invented for a profile or bot.
      expect(sprite.identity, MascotIdentity.hermes);
      expect(sprite.identity, isNot(MascotIdentity.forProfile('forja')));
      expect(sprite.header, isTrue);
      expect(sprite.name, 'Forja');
      expect(sprite.size, FloatingChatHeader.faceSize);
      expect(sprite.size, 48);
    });

    // Owner (1.2.15): «cuando trabaja va como dando brincos… lo dejaría en
    // reposo siempre». The sprite on the island is its resting drawing in
    // EVERY state and never produces a frame of motion.
    testWidgets('the sprite is the resting drawing, still, whatever Hermes is '
        'doing: working, needs you, offline, failed, just finished', (
      tester,
    ) async {
      debugMascotSpritesStill = false;
      addTearDown(() => debugMascotSpritesStill = true);
      const live = ActivitySnapshot(turnActive: true, current: _tool);
      final requests = <HeaderMascotRequest>[
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.idle,
        ),
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.thinking,
          activity: ActivitySnapshot(turnActive: true),
        ),
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.working,
          activity: live,
        ),
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.speaking,
          activity: live,
        ),
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.waiting,
          activity: ActivitySnapshot(
            turnActive: true,
            waitingForUser: true,
            current: _tool,
          ),
        ),
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.offline,
          activity: live,
        ),
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.idle,
          activity: ActivitySnapshot.idle,
          error: true,
        ),
        const HeaderMascotRequest(
          identity: 'hermes',
          state: HeaderMascotState.idle,
          activity: ActivitySnapshot.idle,
          justFinished: true,
        ),
      ];
      int? restingCell;
      for (final request in requests) {
        await tester.pumpWidget(_app(_header(request)));
        await tester.pump();
        final finder = find.byType(MascotSprite);
        final sprite = tester.widget<MascotSprite>(finder);
        final reason = '${request.state.name} error=${request.error}';
        expect(sprite.state, MascotState.idle, reason: reason);
        expect(sprite.still, isTrue, reason: reason);
        final view = tester.state(finder) as MascotSpriteDebugView;
        expect(view.debugMoving, isFalse, reason: reason);
        expect(view.debugPlaying, MascotState.idle, reason: reason);
        restingCell ??= view.debugCell;
        // Ten seconds on: the same cell, no timer ever armed.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          expect(view.debugCell, restingCell, reason: reason);
          expect(debugMascotActiveTimers, 0, reason: reason);
        }
      }
    });

    testWidgets('QA 9493: a room request keeps the members\' original faces; '
        'the engine is never asked', (tester) async {
      await tester.pumpWidget(
        _app(
          _header(
            const HeaderMascotRequest(
              identity: 'Sala',
              state: HeaderMascotState.working,
              members: ['forja', 'qa', 'ceo', 'ops', 'docs'],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('default-face')), findsOneWidget);
      expect(find.byType(MascotCluster), findsNothing);
      expect(find.byType(MascotSprite), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('QA 9493: an original face (bot, custom avatar) is shown as '
        'is; the engine is never asked', (tester) async {
      await tester.pumpWidget(
        _app(
          _header(
            const HeaderMascotRequest(
              identity: 'forja',
              state: HeaderMascotState.working,
              originalFace: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('default-face')), findsOneWidget);
      expect(find.byType(MascotSprite), findsNothing);
    });
  });
}
