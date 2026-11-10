import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/character_face.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';
import 'package:hermes_android/core/characters/studio_eyes.dart';
import 'package:hermes_android/core/characters/studio_motion.dart';
import 'package:hermes_android/core/characters/studio_painter.dart';
import 'package:hermes_android/core/characters/studio_pieces.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';

const _studio = BotCharacter(form: BotForm.round, seed: 'ana');

Future<List<int>> _render(StudioCharacterPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(64, 64));
  final image = await recorder.endRecording().toImage(64, 64);
  final data = await image.toByteData();
  return data!.buffer.asUint8List().toList();
}

StudioCharacterPainter _painter(
  BotCharacter character, {
  BotStudioState state = BotStudioState.still,
}) => StudioCharacterPainter(
  character: character,
  seed: character.seed.isEmpty ? 'ana' : character.seed,
  seededColor: Colors.teal,
  state: state,
);

Widget _host({
  required Widget child,
  bool disableAnimations = false,
  bool tickerEnabled = true,
}) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: TickerMode(
      enabled: tickerEnabled,
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

void main() {
  testWidgets('every body, eye style, piece and finish paints', (tester) async {
    await tester.runAsync(() async {
      for (final form in BotForm.values) {
        for (final finish in BotFinish.values) {
          final bytes = await _render(
            _painter(
              BotCharacter(
                form: form,
                finish: finish,
                fur: true,
                gradient: 'borealis',
                pieces: [
                  for (final kind in BotPieceKind.values) BotPiece.placed(kind),
                ],
              ),
            ),
          );
          expect(bytes.any((b) => b != 0), isTrue, reason: '$form $finish');
        }
      }
      for (final eyes in BotEyeStyle.values) {
        final bytes = await _render(
          _painter(BotCharacter(form: BotForm.round, eyeStyle: eyes)),
        );
        expect(bytes.any((b) => b != 0), isTrue, reason: eyes.name);
      }
    });
  });

  testWidgets(
    'rendering is deterministic by seed and responds to every field',
    (tester) async {
      await tester.runAsync(() async {
        final base = await _render(_painter(_studio));
        expect(await _render(_painter(_studio)), base);
        final variants = <String, BotCharacter>{
          'seed': _studio.copyWith(seed: 'bruno'),
          'form': _studio.copyWith(form: BotForm.boxy),
          'range': _studio.copyWith(range: 1, strength: 1),
          'strength': _studio.copyWith(strength: 0),
          'eyes': _studio.copyWith(eyeStyle: BotEyeStyle.lantern),
          'eye size': _studio.copyWith(eyeSize: 1.6),
          'eye colour': _studio.copyWith(eyeColor: '#dc2626'),
          'colour': _studio.copyWith(bodyColor: '#f87171'),
          'gradient': _studio.copyWith(gradient: 'sunrise'),
          'finish': _studio.copyWith(finish: BotFinish.glossy),
          'fur': _studio.copyWith(fur: true),
          'piece': _studio.copyWith(
            pieces: [BotPiece.placed(BotPieceKind.crown)],
          ),
        };
        for (final entry in variants.entries) {
          expect(
            await _render(_painter(entry.value)),
            isNot(base),
            reason: entry.key,
          );
        }
        // The four finishes differ from each other.
        final finishes = <List<int>>[
          for (final finish in BotFinish.values)
            await _render(_painter(_studio.copyWith(finish: finish))),
        ];
        for (var i = 0; i < finishes.length; i++) {
          for (var j = i + 1; j < finishes.length; j++) {
            expect(finishes[i], isNot(finishes[j]), reason: '$i $j');
          }
        }
      });
    },
  );

  testWidgets('the fourteen states each paint, still ones too', (tester) async {
    await tester.runAsync(() async {
      for (final state in BotStudioState.values) {
        final bytes = await _render(_painter(_studio, state: state));
        expect(bytes.any((b) => b != 0), isTrue, reason: state.name);
      }
      // Sleep and love read differently from plain idle even when still.
      final idle = await _render(_painter(_studio, state: BotStudioState.idle));
      for (final state in [
        BotStudioState.sleep,
        BotStudioState.love,
        BotStudioState.celebrate,
        BotStudioState.oops,
      ]) {
        expect(
          await _render(_painter(_studio, state: state)),
          isNot(idle),
          reason: state.name,
        );
      }
    });
  });

  group('one motion engine', () {
    test('the five engine states are the face engine own frames', () {
      final sampler = StudioPoseSampler('ana');
      const pairs = {
        BotStudioState.idle: HermesBotFaceMotionState.idle,
        BotStudioState.listen: HermesBotFaceMotionState.listening,
        BotStudioState.think: HermesBotFaceMotionState.thinking,
        BotStudioState.work: HermesBotFaceMotionState.working,
        BotStudioState.speak: HermesBotFaceMotionState.speaking,
      };
      for (final entry in pairs.entries) {
        for (final ms in [0, 900, 4300, 12345]) {
          final at = Duration(milliseconds: ms);
          final mine = sampler.sample(entry.key, at).face;
          final theirs = hermesBlobatarMotionSnapshot(
            'ana',
            at,
            state: entry.value,
          );
          expect(mine.bobY, theirs.bobY, reason: '${entry.key} $ms');
          expect(mine.eyeOffsetX, theirs.eyeOffsetX);
          expect(mine.eyeOffsetY, theirs.eyeOffsetY);
          expect(mine.blinkScaleY, theirs.blinkScaleY);
          expect(mine.headTiltRadians, theirs.headTiltRadians);
          expect(mine.breatheScaleX, theirs.breatheScaleX);
          expect(StudioPoseSampler.fromEngine(entry.value), entry.key);
        }
      }
    });

    test('the other states move the body and the still ones do not', () {
      final sampler = StudioPoseSampler('ana');
      for (final state in [
        BotStudioState.celebrate,
        BotStudioState.bounce,
        BotStudioState.dance,
        BotStudioState.spin,
        BotStudioState.love,
        BotStudioState.oops,
        BotStudioState.sleep,
        BotStudioState.curious,
      ]) {
        final a = sampler.sample(state, const Duration(milliseconds: 310));
        final b = sampler.sample(state, const Duration(milliseconds: 790));
        final moved =
            a.dx != b.dx ||
            a.dy != b.dy ||
            a.rotation != b.rotation ||
            a.scaleX != b.scaleX ||
            a.face.eyeOffsetX != b.face.eyeOffsetX ||
            a.phase != b.phase;
        expect(moved, isTrue, reason: state.name);
      }
      final rest = sampler.sample(
        BotStudioState.still,
        const Duration(seconds: 3),
      );
      expect(rest.dx, 0);
      expect(rest.rotation, 0);
      expect(rest.face, HermesBotFaceMotionSnapshot.staticFrame);
    });

    test('with motion off every state is a still expression', () {
      final sampler = StudioPoseSampler('ana');
      for (final state in BotStudioState.values) {
        final pose = sampler.sample(
          state,
          const Duration(seconds: 7),
          moving: false,
        );
        expect(pose.dx, 0, reason: state.name);
        expect(pose.dy, 0, reason: state.name);
        expect(pose.scaleX, 1, reason: state.name);
        expect(pose.scaleY, 1, reason: state.name);
        expect(pose.face.bobY, 0, reason: state.name);
        expect(pose.rotation.abs(), lessThan(0.1), reason: state.name);
      }
      expect(
        sampler.sample(BotStudioState.sleep, Duration.zero, moving: false).mood,
        BotEyeMood.closed,
      );
      expect(
        sampler
            .sample(BotStudioState.sleep, Duration.zero, moving: false)
            .overlay,
        BotOverlay.zzz,
      );
      expect(
        sampler.sample(BotStudioState.love, Duration.zero, moving: false).mood,
        BotEyeMood.heart,
      );
    });
  });

  group('pieces', () {
    test('every kind has art, a frame and a consistent geometry', () {
      for (final kind in BotPieceKind.values) {
        final art = StudioPieces.of(kind);
        expect(art.fill != null || art.line != null, isTrue, reason: kind.name);
        expect(art.bounds.isEmpty, isFalse, reason: kind.name);
        const piece = BotPiece(
          kind: BotPieceKind.star,
          x: 0.4,
          y: 0.3,
          rotation: 33,
          scale: 1.7,
          flip: true,
        );
        final turned = piece.copyWith();
        final local = StudioPieces.toLocal(
          BotPiece(
            kind: kind,
            x: turned.x,
            y: turned.y,
            rotation: turned.rotation,
            scale: turned.scale,
            flip: turned.flip,
          ),
          const Offset(61, 17),
        );
        final back = StudioPieces.toCanvas(
          BotPiece(
            kind: kind,
            x: turned.x,
            y: turned.y,
            rotation: turned.rotation,
            scale: turned.scale,
            flip: turned.flip,
          ),
          local,
        );
        expect((back - const Offset(61, 17)).distance, lessThan(1e-6));
      }
    });

    test('a piece is hit inside its frame, not far outside it', () {
      final piece = BotPiece.placed(BotPieceKind.star);
      expect(
        StudioPieces.hits(piece, Offset(piece.x * 100, piece.y * 100)),
        isTrue,
      );
      expect(StudioPieces.hits(piece, const Offset(2, 98)), isFalse);
      final big = piece.copyWith(scale: 2.5);
      expect(
        StudioPieces.hits(big, Offset(piece.x * 100 + 30, piece.y * 100)),
        isTrue,
      );
      expect(
        StudioPieces.hits(piece, Offset(piece.x * 100 + 30, piece.y * 100)),
        isFalse,
      );
      final corners = StudioPieces.corners(piece);
      expect(corners.length, 4);
    });

    test('flip mirrors a piece across its own vertical axis', () {
      final piece = BotPiece.placed(BotPieceKind.wing);
      final mirrored = piece.copyWith(flip: true);
      final a = StudioPieces.toCanvas(piece, const Offset(10, 4));
      final b = StudioPieces.toCanvas(mirrored, const Offset(10, 4));
      expect(a.dx - piece.x * 100, closeTo(-(b.dx - piece.x * 100), 1e-9));
      expect(a.dy, closeTo(b.dy, 1e-9));
    });
  });

  group('eyes', () {
    test('every style paints in every mood', () {
      for (final style in BotEyeStyle.values) {
        for (final mood in BotEyeMood.values) {
          final recorder = ui.PictureRecorder();
          paintStudioEyes(
            Canvas(recorder),
            style: style,
            color: Colors.black,
            size: 1.3,
            mood: mood,
          );
          recorder.endRecording().dispose();
        }
      }
    });
  });

  group('widget', () {
    testWidgets(
      'a studio character takes the studio painter, an old one the old face',
      (tester) async {
        await tester.pumpWidget(
          _host(
            child: const CharacterFace(
              profileName: 'ana',
              character: _studio,
              size: 120,
            ),
          ),
        );
        expect(find.byType(StudioCharacterFace), findsOneWidget);
        expect(find.byType(HermesBotFace), findsNothing);
        await tester.pumpWidget(
          _host(
            child: const CharacterFace(
              profileName: 'ana',
              character: BotCharacter(kind: 'sun', seed: 'tea'),
              size: 120,
            ),
          ),
        );
        expect(find.byType(StudioCharacterFace), findsNothing);
        expect(find.byType(HermesBotFace), findsOneWidget);
      },
    );

    testWidgets(
      'animating runs one ticker; reduced motion or still holds none',
      (tester) async {
        Future<void> mount({
          bool reduce = false,
          bool animate = true,
          BotStudioState? state,
          bool tickers = true,
        }) async {
          await tester.pumpWidget(
            _host(
              disableAnimations: reduce,
              tickerEnabled: tickers,
              child: StudioCharacterFace(
                character: _studio,
                profileName: 'ana',
                size: 120,
                animate: animate,
                state: state ?? BotStudioState.dance,
              ),
            ),
          );
          // Long enough for the page transition of the host to be over.
          await tester.pump(const Duration(milliseconds: 400));
        }

        await mount();
        expect(tester.binding.transientCallbackCount, greaterThan(0));
        await mount(reduce: true);
        expect(tester.binding.transientCallbackCount, 0);
        await mount(animate: false);
        expect(tester.binding.transientCallbackCount, 0);
        await mount(state: BotStudioState.still);
        expect(tester.binding.transientCallbackCount, 0);
        await mount(tickers: false);
        final held =
            tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('studio-character-paint')),
                    )
                    .painter!
                as StudioCharacterPainter;
        expect(held.moving, isFalse);
        expect(held.clock, isNull);
        // And it starts again when motion is allowed.
        await mount();
        expect(tester.binding.transientCallbackCount, greaterThan(0));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.binding.transientCallbackCount, 0);
      },
    );

    testWidgets('a shared roster clock drives it without a ticker of its own', (
      tester,
    ) async {
      final controller = AnimationController(
        vsync: tester,
        duration: HermesBotFace.clockDuration,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          child: CharacterFace(
            profileName: 'ana',
            character: _studio,
            size: 60,
            animate: true,
            clock: controller,
            motionState: HermesBotFaceMotionState.thinking,
          ),
        ),
      );
      expect(tester.binding.transientCallbackCount, 0);
    });
  });
}
