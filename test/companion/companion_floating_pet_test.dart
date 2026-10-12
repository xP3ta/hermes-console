import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/models/companion_presence_level.dart';
import 'package:hermes_android/core/companion/render/companion_floating_pet.dart';
import 'package:hermes_android/core/companion/render/spritesheet_renderer.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The active profile's pet as the floating mascot: when it is on, and
/// what it draws for each state with the drawings the pet really has.

const _idle = CompanionAnimationState.idle;

Companion _pet(String slug, Map<CompanionAnimationState, RowSpec> states) =>
    Companion(
      slug: slug,
      name: slug == 'zoro' ? 'Zoro' : slug,
      author: 'team',
      license: 'CC0-1.0',
      spritesheetAsset: 'assets/companions/nimbus/spritesheet.webp',
      frameWidth: 192,
      frameHeight: 208,
      cols: 8,
      rows: 9,
      fps: 8,
      states: states,
    );

/// A full Petdex sheet.
final _full = _pet('zoro', const {
  CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 6, loop: true),
  CompanionAnimationState.run: RowSpec(row: 1, frameCount: 8, loop: true),
  CompanionAnimationState.review: RowSpec(row: 2, frameCount: 6, loop: false),
  CompanionAnimationState.waiting: RowSpec(row: 3, frameCount: 6, loop: true),
  CompanionAnimationState.wave: RowSpec(row: 4, frameCount: 4, loop: false),
  CompanionAnimationState.jump: RowSpec(row: 5, frameCount: 5, loop: false),
  CompanionAnimationState.failed: RowSpec(row: 6, frameCount: 8, loop: false),
});

/// A pet with only its idle sheet.
final _plain = _pet('plain', const {
  CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 6, loop: true),
});

/// Idle and a jump, nothing else.
final _jumper = _pet('jumper', const {
  CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 6, loop: true),
  CompanionAnimationState.jump: RowSpec(row: 5, frameCount: 5, loop: false),
});

class _Repo extends CompanionRepository {
  _Repo(this._all);
  final List<Companion> _all;

  @override
  Future<List<Companion>> loadAll() async => _all;
}

Future<CompanionController> _controller([List<Companion>? pets]) async {
  final c = CompanionController(
    _Repo(pets ?? [_full, _plain]),
    await CompanionPreferences.load(),
  );
  await c.init();
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugMascotSpritesStill = true;
  });

  group('each state, with the drawings the pet has', () {
    test('a full sheet: its own drawing for everything', () {
      PetPlan plan(MascotState s, {bool asleep = false, bool look = false}) =>
          petPlanFor(_full, s, asleep: asleep, looking: look);
      expect(plan(MascotState.idle), const PetPlan(row: _idle));
      expect(
        plan(MascotState.idle, look: true),
        const PetPlan(row: CompanionAnimationState.review, loop: false),
      );
      expect(
        plan(MascotState.thinking),
        const PetPlan(row: CompanionAnimationState.review, loop: true),
      );
      expect(
        plan(MascotState.tool),
        const PetPlan(row: CompanionAnimationState.run, loop: true),
      );
      expect(
        plan(MascotState.needsYou),
        const PetPlan(row: CompanionAnimationState.waiting, loop: true),
      );
      expect(
        plan(MascotState.done),
        const PetPlan(row: CompanionAnimationState.wave, loop: false),
      );
      expect(
        plan(MascotState.error),
        const PetPlan(row: CompanionAnimationState.failed, loop: false),
      );
      expect(
        plan(MascotState.offline),
        const PetPlan(row: _idle, still: true, dim: true),
      );
      // Asleep: its resting drawing, one frame, whatever it was doing.
      for (final state in MascotState.values) {
        if (state == MascotState.offline) continue;
        expect(
          plan(state, asleep: true),
          const PetPlan(row: _idle, still: true),
        );
      }
    });

    test('only an idle sheet: the whole sprite moves instead', () {
      PetPlan plan(MascotState s, {bool look = false}) =>
          petPlanFor(_plain, s, looking: look);
      expect(plan(MascotState.idle), const PetPlan(row: _idle));
      expect(
        plan(MascotState.idle, look: true),
        const PetPlan(row: _idle, reaction: PetReaction.hop),
      );
      expect(
        plan(MascotState.thinking),
        const PetPlan(row: _idle, reaction: PetReaction.sway),
      );
      expect(
        plan(MascotState.tool),
        const PetPlan(row: _idle, reaction: PetReaction.bob),
      );
      expect(
        plan(MascotState.needsYou),
        const PetPlan(row: _idle, reaction: PetReaction.hops),
      );
      expect(
        plan(MascotState.done),
        const PetPlan(row: _idle, reaction: PetReaction.hop),
      );
      expect(
        plan(MascotState.error),
        const PetPlan(row: _idle, reaction: PetReaction.shake),
      );
      expect(
        plan(MascotState.offline),
        const PetPlan(row: _idle, still: true, dim: true),
      );
    });

    test('in the air (the fall to the dock): its jump, or just the fall', () {
      for (final state in [MascotState.idle, MascotState.tool]) {
        expect(
          petPlanFor(_full, state, airborne: true),
          const PetPlan(row: CompanionAnimationState.jump, loop: true),
        );
        expect(
          petPlanFor(_plain, state, airborne: true),
          const PetPlan(row: _idle),
          reason: 'no drawing for it: the whole sprite is what moves',
        );
      }
      // Asleep or offline it shows nothing of it.
      expect(
        petPlanFor(_full, MascotState.idle, airborne: true, asleep: true),
        const PetPlan(row: _idle, still: true),
      );
      expect(
        petPlanFor(_full, MascotState.offline, airborne: true),
        const PetPlan(row: _idle, still: true, dim: true),
      );
    });

    test('the closest drawing it has: a jump for "needs you" and "done"', () {
      expect(
        petPlanFor(_jumper, MascotState.needsYou),
        const PetPlan(row: CompanionAnimationState.jump, loop: true),
      );
      expect(
        petPlanFor(_jumper, MascotState.done),
        const PetPlan(row: CompanionAnimationState.jump, loop: false),
      );
    });
  });

  group('when it floats', () {
    test(
      'only with "En toda la app"; "Ocultar" leaves it in the chat',
      () async {
        final c = await _controller();
        final pet = CompanionFloatingPet(c);
        var notified = 0;
        pet.addListener(() => notified++);
        expect(pet.shown, isTrue, reason: 'on for everyone by default');

        await pet.hide();
        expect(c.presence, CompanionPresenceLevel.chat);
        expect(c.enabled, isTrue);
        expect(pet.shown, isFalse);
        expect(notified, greaterThan(0));

        await c.setVisibilityLevel(CompanionPresenceLevel.full);
        expect(pet.shown, isTrue);
        await c.setVisibilityLevel(CompanionPresenceLevel.off);
        expect(pet.shown, isFalse);
      },
    );

    test('not before the pet is loaded', () async {
      final c = CompanionController(
        _Repo([_full]),
        await CompanionPreferences.load(),
      );
      final pet = CompanionFloatingPet(c);
      expect(pet.shown, isFalse);
      await c.init();
      expect(pet.shown, isTrue);
    });

    test('the old stored choices', () async {
      Future<bool> shownWith(String? stored) async {
        SharedPreferences.setMockInitialValues({
          CompanionPreferences.presenceLevelKey: ?stored,
        });
        return CompanionFloatingPet(await _controller()).shown;
      }

      expect(await shownWith(null), isTrue);
      expect(await shownWith('minimal'), isTrue);
      expect(await shownWith('full'), isTrue);
      expect(await shownWith('off'), isFalse);
      expect(await shownWith('chat'), isFalse);
    });

    test('its name and size are the pet\'s', () async {
      final c = await _controller();
      final pet = CompanionFloatingPet(c);
      expect(pet.name, 'Hermes', reason: 'no pet, the default profile');
      await c.select('zoro');
      expect(pet.name, 'Zoro');
      await c.setSizeMultiplier(1.25);
      expect(pet.scale, closeTo(1.25, 0.001));
    });
  });

  group('standing on its feet', () {
    // A 2 x 1 sheet of 64 px cells whose resting drawing ends 16 px above
    // the bottom of its cell.
    final sheet = Companion(
      slug: 'boxy',
      name: 'Boxy',
      author: 'team',
      license: 'CC0-1.0',
      spritesheetAsset: 'memory://boxy.png',
      frameWidth: 64,
      frameHeight: 64,
      cols: 2,
      rows: 1,
      fps: 8,
      states: const {
        CompanionAnimationState.idle: RowSpec(
          row: 0,
          frameCount: 2,
          loop: true,
        ),
      },
    );

    Future<MemoryImage> drawing() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(16, 10, 32, 38),
        Paint()..color = const Color(0xFF22AA66),
      );
      final image = await recorder.endRecording().toImage(128, 64);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return MemoryImage(png!.buffer.asUint8List());
    }

    testWidgets('the air under a pet\'s feet is measured once per sheet', (
      tester,
    ) async {
      PetFootline.resetForTesting();
      expect(PetFootline.of(sheet), isNull);
      final gap = await tester.runAsync(
        () async => PetFootline.measure(sheet, source: await drawing()),
      );
      expect(gap, closeTo(16 / 64, 0.02));
      expect(PetFootline.of(sheet), gap);
    });

    testWidgets('and its drawing is moved down by it, feet on the edge', (
      tester,
    ) async {
      PetFootline.resetForTesting();
      await tester.runAsync(
        () async => PetFootline.measure(sheet, source: await drawing()),
      );
      final c = await _controller([sheet]);
      await c.select('boxy');
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: CompanionFloatingBody(
              controller: c,
              state: MascotState.idle,
              size: 48,
              asleep: true,
              look: 0,
            ),
          ),
        ),
      );
      final feet = tester.widget<Transform>(
        find.byKey(const ValueKey('floating-pet-feet')),
      );
      expect(feet.transform.getTranslation().y, closeTo(12, 1));
      await tester.pumpWidget(const SizedBox());
      PetFootline.resetForTesting();
    });

    testWidgets('a sheet that cannot be read leaves the pet where it is', (
      tester,
    ) async {
      PetFootline.resetForTesting();
      final gap = await tester.runAsync(
        () => PetFootline.measure(
          sheet,
          source: MemoryImage(Uint8List.fromList(const [1, 2, 3])),
        ),
      );
      expect(gap, 0);
      PetFootline.resetForTesting();
    });
  });

  group('what it draws', () {
    Future<void> pump(
      WidgetTester tester,
      CompanionController c, {
      MascotState state = MascotState.idle,
      bool asleep = false,
      int look = 0,
      bool reduce = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Center(
            child: CompanionFloatingPet(c).build(
              tester.element(find.byType(Center).first),
              state: state,
              size: 48,
              asleep: asleep,
              look: look,
            ),
          ),
        ),
      ),
    );

    Future<void> mount(WidgetTester tester) =>
        tester.pumpWidget(const MaterialApp(home: Center(child: SizedBox())));

    testWidgets('no pet, default profile: Hermes\' own sprite', (tester) async {
      final c = await _controller();
      await mount(tester);
      await pump(tester, c);
      expect(find.byKey(const ValueKey('floating-pet-hermes')), findsOneWidget);
      expect(tester.getSize(find.byType(MascotSprite)), const Size.square(48));
      expect(find.byType(SpritesheetRenderer), findsNothing);
    });

    testWidgets('the chosen pet, in its box, on the row of the state', (
      tester,
    ) async {
      final c = await _controller();
      await c.select('zoro');
      await mount(tester);
      await pump(tester, c, state: MascotState.tool);
      var sprite = tester.widget<SpritesheetRenderer>(
        find.byType(SpritesheetRenderer),
      );
      expect(sprite.companion.slug, 'zoro');
      expect(sprite.size, 48);
      expect(sprite.state, CompanionAnimationState.run);
      expect(sprite.animate, isTrue);
      // A one-shot row of the sheet, looped while it thinks.
      await pump(tester, c, state: MascotState.thinking);
      sprite = tester.widget(find.byType(SpritesheetRenderer));
      expect(sprite.state, CompanionAnimationState.review);
      expect(sprite.overrideRow?.loop, isTrue);
      // Asleep: one frame, no clock.
      await pump(tester, c, state: MascotState.tool, asleep: true);
      sprite = tester.widget(find.byType(SpritesheetRenderer));
      expect(sprite.state, _idle);
      expect(sprite.animate, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a look around is one run of "review", then back to idle', (
      tester,
    ) async {
      final c = await _controller();
      await c.select('zoro');
      await mount(tester);
      await pump(tester, c);
      await pump(tester, c, look: 1);
      var sprite = tester.widget<SpritesheetRenderer>(
        find.byType(SpritesheetRenderer),
      );
      expect(sprite.state, CompanionAnimationState.review);
      expect(sprite.overrideRow, isNull, reason: 'once, as the sheet says');
      // 6 frames at 8 fps, and a breath.
      await tester.pump(const Duration(milliseconds: 1000));
      sprite = tester.widget(find.byType(SpritesheetRenderer));
      expect(sprite.state, _idle);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an idle-only pet reacts by moving, and stops when it rests', (
      tester,
    ) async {
      final c = await _controller();
      await c.select('plain');
      await mount(tester);
      await pump(tester, c, state: MascotState.tool);
      Matrix4 transform() => tester
          .widget<Transform>(
            find.byKey(const ValueKey('floating-pet-reaction')),
          )
          .transform;
      final seen = <double>{};
      for (var i = 0; i < 12; i++) {
        await tester.pump(PetReactionMotion.frame);
        seen.add(transform().getTranslation().y);
      }
      expect(seen.length, greaterThan(3), reason: 'it bobs');
      expect(seen.every((y) => y <= 0 && y > -5), isTrue, reason: 'a little');
      // The sprite under it is the same one all along.
      final sprite = tester.state(find.byType(SpritesheetRenderer));
      await pump(tester, c);
      expect(tester.state(find.byType(SpritesheetRenderer)), same(sprite));
      await tester.pump(const Duration(seconds: 3));
      expect(transform(), Matrix4.identity());
      // Asleep or with reduced motion nothing moves and no clock runs.
      await pump(tester, c, state: MascotState.tool, asleep: true);
      await tester.pump(const Duration(seconds: 2));
      expect(transform(), Matrix4.identity());
      await pump(tester, c, state: MascotState.tool, reduce: true);
      await tester.pump(const Duration(seconds: 2));
      expect(transform(), Matrix4.identity());
      await tester.pumpWidget(const SizedBox());
    });
  });
}
