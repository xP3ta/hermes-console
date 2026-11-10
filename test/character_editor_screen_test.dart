import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/characters/character_export.dart';
import 'package:hermes_android/core/characters/character_face.dart';
import 'package:hermes_android/core/characters/character_library.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';
import 'package:hermes_android/core/characters/studio_painter.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/screens/characters/character_editor_screen.dart';
import 'package:hermes_android/core/screens/characters/studio_canvas.dart';
import 'package:hermes_android/core/screens/characters/studio_view.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

StudioCharacterFace _face(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('character-preview')));

BotCharacter _preview(WidgetTester tester) => _face(tester).character;

void main() {
  late BotCharacterStore store;
  late BotCharacterLibrary library;
  final shared = <Uint8List>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = await BotCharacterStore.load(prefs);
    library = BotCharacterLibrary.memory();
    shared.clear();
  });
  tearDown(() => BotCharacterStore.debugUse(null));

  Widget editor() => CharacterEditorScreen(
    profileName: 'ana',
    connectionId: 'c1',
    store: store,
    library: library,
    sharer: (png, name) async => shared.add(png),
  );

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(editor()));
    await tester.pump();
  }

  /// The editor pushed over a first page, so that leaving it can be seen.
  Future<void> openFromPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('host-open'),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => editor())),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('host-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 450));

  Finder sliderOf(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(Slider),
  );

  /// Where the thumb of the slider under [key] is.
  Offset thumbOf(WidgetTester tester, String key) {
    final slider = tester.widget<Slider>(sliderOf(key));
    final rect = tester.getRect(sliderOf(key));
    final fraction = (slider.value - slider.min) / (slider.max - slider.min);
    return Offset(
      rect.left + 24 + fraction * (rect.width - 48),
      rect.center.dy,
    );
  }

  /// A finger on the thumb, dragged [dx] pixels.
  Future<void> dragSlider(WidgetTester tester, String key, double dx) async {
    await tester.ensureVisible(sliderOf(key));
    await tester.pump();
    await tester.dragFrom(thumbOf(tester, key), Offset(dx, 0));
    await tester.pump();
  }

  group('editor', () {
    testWidgets('opens on a studio body and the shape tab drives it', (
      tester,
    ) async {
      await open(tester);
      expect(_preview(tester).isStudio, isTrue);
      expect(_preview(tester).form, BotForm.round);
      await tapKey(tester, 'studio-form-boxy');
      expect(_preview(tester).form, BotForm.boxy);
      await tapKey(tester, 'studio-form-cloud');
      expect(_preview(tester).form, BotForm.cloud);

      await dragSlider(tester, 'studio-range', 120);
      expect(_preview(tester).range, greaterThan(0.6));
      await dragSlider(tester, 'studio-strength', -150);
      expect(_preview(tester).strength, lessThan(0.4));

      await tester.enterText(
        find.byKey(const ValueKey('character-seed-field')),
        'Good-1',
      );
      await tester.pump();
      expect(_preview(tester).seed, 'good-1');
      await tester.enterText(
        find.byKey(const ValueKey('character-seed-field')),
        'bad seed!',
      );
      await tester.pump();
      expect(find.textContaining('Lowercase letters'), findsOneWidget);
      expect(_preview(tester).seed, 'good-1');
      await tapKey(tester, 'character-seed-random');
      expect(_preview(tester).seed, isNotEmpty);
    });

    testWidgets('the eyes tab changes style, colour and size', (tester) async {
      await open(tester);
      await tapKey(tester, 'studio-tab-eyes');
      for (final style in BotEyeStyle.values) {
        await tapKey(tester, 'studio-eyes-${style.name}');
        expect(_preview(tester).eyeStyle, style);
      }
      await tapKey(tester, 'studio-eye-color-#dc2626');
      expect(_preview(tester).eyeColor, '#dc2626');
      await tapKey(tester, 'studio-eye-color-auto');
      expect(_preview(tester).eyeColor, isNull);
      await tapKey(tester, 'studio-eye-color-custom');
      expect(_preview(tester).eyeColor, isNotNull);
      expect(find.byKey(const ValueKey('studio-color-picker')), findsOneWidget);
      await dragSlider(tester, 'studio-eye-size', 200);
      expect(_preview(tester).eyeSize, greaterThan(1.3));
    });

    testWidgets('pieces are placed, changed, repeated and removed', (
      tester,
    ) async {
      await open(tester);
      await tapKey(tester, 'studio-tab-pieces');
      await tapKey(tester, 'studio-piece-add-crown');
      await tapKey(tester, 'studio-piece-add-wing');
      await tapKey(tester, 'studio-piece-add-wing');
      expect(_preview(tester).pieces.map((p) => p.kind), [
        BotPieceKind.crown,
        BotPieceKind.wing,
        BotPieceKind.wing,
      ]);
      // The last one added is the selected one.
      await dragSlider(tester, 'studio-piece-rotation', 80);
      expect(_preview(tester).pieces[2].rotation, greaterThan(20));
      expect(_preview(tester).pieces[1].rotation, 0);
      await dragSlider(tester, 'studio-piece-size', 120);
      expect(_preview(tester).pieces[2].scale, greaterThan(1.3));
      await tapKey(tester, 'studio-piece-flip');
      expect(_preview(tester).pieces[2].flip, isTrue);
      await tapKey(tester, 'studio-piece-position');
      await dragSlider(tester, 'studio-piece-across', -100);
      expect(
        _preview(tester).pieces[2].x,
        lessThan(BotPiece.placed(BotPieceKind.wing).x),
      );
      await dragSlider(tester, 'studio-piece-height', 100);
      expect(
        _preview(tester).pieces[2].y,
        greaterThan(BotPiece.placed(BotPieceKind.wing).y),
      );
      // Pick the first one from the list, then remove it.
      await tapKey(tester, 'studio-piece-placed-0');
      await tapKey(tester, 'studio-piece-delete');
      expect(_preview(tester).pieces.map((p) => p.kind), [
        BotPieceKind.wing,
        BotPieceKind.wing,
      ]);
    });

    testWidgets('twelve pieces at most', (tester) async {
      await open(tester);
      await tapKey(tester, 'studio-tab-pieces');
      for (var i = 0; i < BotStudioLimits.maxPieces + 3; i++) {
        await tapKey(tester, 'studio-piece-add-star');
      }
      expect(_preview(tester).pieces.length, BotStudioLimits.maxPieces);
      expect(
        find.text('You’ve reached the maximum number of parts'),
        findsOneWidget,
      );
    });

    testWidgets('colour: fur, finish, solid, custom and gradient', (
      tester,
    ) async {
      await open(tester);
      await tapKey(tester, 'studio-tab-color');
      await tapKey(tester, 'studio-fur');
      expect(_preview(tester).fur, isTrue);
      for (final finish in BotFinish.values) {
        await tapKey(tester, 'studio-finish-${finish.name}');
        expect(_preview(tester).finish, finish);
      }
      final swatch = ClassicFaceIdentity.colors.first;
      await tapKey(tester, 'character-color-$swatch');
      expect(_preview(tester).bodyColor, swatch);
      await tapKey(tester, 'studio-color-custom');
      expect(find.byKey(const ValueKey('studio-color-picker')), findsOneWidget);
      await tapKey(tester, 'studio-gradient-borealis');
      expect(_preview(tester).gradient, 'borealis');
      expect(find.byKey(const ValueKey('studio-color-picker')), findsNothing);
      await tapKey(tester, 'character-color-auto');
      expect(_preview(tester).gradient, isNull);
      expect(_preview(tester).bodyColor, isNull);
      expect(botGradients.length, greaterThanOrEqualTo(12));
    });

    testWidgets('undo and redo go back and forth, a drag is one step', (
      tester,
    ) async {
      await open(tester);
      await tapKey(tester, 'studio-form-boxy');
      await dragSlider(tester, 'studio-range', 120);
      final dragged = _preview(tester).range;
      await tapKey(tester, 'studio-undo');
      expect(_preview(tester).range, 0.5);
      expect(_preview(tester).form, BotForm.boxy);
      await tapKey(tester, 'studio-undo');
      expect(_preview(tester).form, BotForm.round);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('studio-undo')))
            .onPressed,
        isNull,
      );
      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-redo');
      await settle(tester);
      expect(_preview(tester).form, BotForm.boxy);
      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-redo');
      await settle(tester);
      expect(_preview(tester).range, dragged);
    });

    testWidgets(
      'the preview state menu lists fourteen states and applies one',
      (tester) async {
        await open(tester);
        expect(_face(tester).state, BotStudioState.idle);
        await tapKey(tester, 'studio-state-pill');
        await settle(tester);
        expect(
          tester
              .widget<HermesOptionList<BotStudioState>>(
                find.byType(HermesOptionList<BotStudioState>),
              )
              .options
              .length,
          14,
        );
        await tapKey(tester, 'studio-state-sleep');
        await settle(tester);
        expect(_face(tester).state, BotStudioState.sleep);
        expect(find.text('Sleep'), findsOneWidget);
      },
    );

    testWidgets('zoom buttons, 100 % and fit', (tester) async {
      await open(tester);
      expect(find.text('100%'), findsOneWidget);
      await tapKey(tester, 'studio-zoom-in');
      await tapKey(tester, 'studio-zoom-in');
      expect(find.text('150%'), findsOneWidget);
      await tapKey(tester, 'studio-zoom-out');
      expect(find.text('125%'), findsOneWidget);
      await tapKey(tester, 'studio-zoom-level');
      expect(find.text('100%'), findsOneWidget);
      for (var i = 0; i < 20; i++) {
        await tapKey(tester, 'studio-zoom-in');
      }
      expect(find.text('400%'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('studio-zoom-in')))
            .onPressed,
        isNull,
      );
      await tapKey(tester, 'studio-fit');
      expect(find.text('100%'), findsOneWidget);
      await tapKey(tester, 'studio-pan');
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('studio-pan')))
            .isSelected,
        isTrue,
      );
    });

    testWidgets('a pinch zooms the canvas and a pan moves it when zoomed', (
      tester,
    ) async {
      await open(tester);
      final area = find.byKey(const ValueKey('studio-canvas-gestures'));
      final centre = tester.getCenter(area);
      final one = await tester.startGesture(centre - const Offset(20, 0));
      final two = await tester.startGesture(centre + const Offset(20, 0));
      await one.moveBy(const Offset(-60, 0));
      await two.moveBy(const Offset(60, 0));
      await one.up();
      await two.up();
      await tester.pump();
      expect(find.text('100%'), findsNothing);
      await tapKey(tester, 'studio-zoom-in');
      await tester.dragFrom(centre, const Offset(40, 30));
      await tester.pump();
    });

    testWidgets(
      'dragging a slider repaints the canvas without rebuilding the screen',
      (tester) async {
        await open(tester);
        final before = CharacterEditorScreen.debugBuilds;
        await dragSlider(tester, 'studio-strength', 100);
        await dragSlider(tester, 'studio-range', 100);
        expect(_preview(tester).strength, greaterThan(0.5));
        expect(_preview(tester).range, greaterThan(0.5));
        expect(CharacterEditorScreen.debugBuilds, before);
      },
    );

    testWidgets('the canvas has no backdrop filter', (tester) async {
      await open(tester);
      expect(
        find.descendant(
          of: find.byType(StudioCanvas),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      for (final path in [
        'lib/core/screens/characters/studio_canvas.dart',
        'lib/core/characters/studio_painter.dart',
        'lib/core/characters/studio_pieces.dart',
        'lib/core/characters/studio_eyes.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains('BackdropFilter')),
        );
      }
    });

    testWidgets('a piece is dragged, turned and resized on the canvas', (
      tester,
    ) async {
      await open(tester);
      await tapKey(tester, 'studio-tab-pieces');
      await tapKey(tester, 'studio-piece-add-star');
      final start = _preview(tester).pieces.single;
      final area = find.byKey(const ValueKey('studio-canvas-gestures'));
      final rect = tester.getRect(area);
      final k = rect.width / 100;
      Offset at(double x, double y) => rect.topLeft + Offset(x * k, y * k);

      // Move: one finger on the piece.
      await tester.dragFrom(
        at(start.x * 100, start.y * 100),
        const Offset(-60, 50),
      );
      await tester.pump();
      final moved = _preview(tester).pieces.single;
      expect(moved.x, closeTo(start.x - 60 / rect.width, 0.02));
      expect(moved.y, closeTo(start.y + 50 / rect.height, 0.02));

      // Turn: the handle above the frame, dragged to the right of the piece.
      final viewport = StudioViewport(side: rect.width);
      final handle = rect.topLeft + studioRotateHandle(viewport, moved);
      final centre = at(moved.x * 100, moved.y * 100);
      await tester.dragFrom(handle, centre + const Offset(120, 0) - handle);
      await tester.pump();
      expect(_preview(tester).pieces.single.rotation, closeTo(90, 2));

      // Size: the corner handle, dragged farther from the centre.
      final turned = _preview(tester).pieces.single;
      final corner = rect.topLeft + studioScaleHandle(viewport, turned);
      final far = centre + (corner - centre) * 2;
      await tester.dragFrom(corner, far - corner);
      await tester.pump();
      expect(_preview(tester).pieces.single.scale, greaterThan(1.6));

      // One undo per gesture.
      await tapKey(tester, 'studio-undo');
      expect(_preview(tester).pieces.single.scale, 1);
      expect(_preview(tester).pieces.single.rotation, closeTo(90, 2));
      await tapKey(tester, 'studio-undo');
      expect(_preview(tester).pieces.single.rotation, 0);
      await tapKey(tester, 'studio-undo');
      expect(_preview(tester).pieces.single.x, start.x);
    });

    testWidgets(
      'a tap on the canvas selects a piece and a tap outside clears it',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await open(tester);
        await tapKey(tester, 'studio-tab-pieces');
        await tapKey(tester, 'studio-piece-add-star');
        await tapKey(tester, 'studio-piece-add-moon');
        bool selected(int i) => tester
            .getSemantics(find.byKey(ValueKey('studio-piece-placed-$i')))
            // ignore: deprecated_member_use
            .hasFlag(SemanticsFlag.isSelected);
        expect(selected(1), isTrue);
        final rect = tester.getRect(
          find.byKey(const ValueKey('studio-canvas-gestures')),
        );
        final star = BotPiece.placed(BotPieceKind.star);
        await tester.tapAt(
          rect.topLeft + Offset(star.x * rect.width, star.y * rect.height),
        );
        await tester.pump();
        expect(selected(0), isTrue);
        expect(selected(1), isFalse);
        await tester.tapAt(
          rect.topLeft + Offset(rect.width * 0.1, rect.height * 0.9),
        );
        await tester.pump();
        expect(selected(0), isFalse);
        expect(selected(1), isFalse);
        expect(find.byKey(const ValueKey('studio-piece-delete')), findsNothing);
        semantics.dispose();
      },
    );

    testWidgets('confirm applies the character to the profile only', (
      tester,
    ) async {
      await openFromPage(tester);
      await tapKey(tester, 'studio-form-organic');
      expect(store.characterFor('c1', 'ana'), isNull);
      await tapKey(tester, 'studio-confirm');
      await settle(tester);
      expect(store.characterFor('c1', 'ana')!.form, BotForm.organic);
      expect(store.characterFor('c1', 'bob'), isNull);
      expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
    });

    testWidgets('leaving with unapplied changes asks first', (tester) async {
      await openFromPage(tester);
      // Nothing changed: it just leaves.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byKey(const ValueKey('host-open')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('host-open')));
      await tester.pump();
      await settle(tester);
      await tapKey(tester, 'studio-form-boxy');
      expect(
        tester
            .widgetList(find.byWidgetPredicate((w) => w is PopScope))
            .map((w) => (w as PopScope).canPop),
        contains(false),
      );
      await tester.binding.handlePopRoute();
      await settle(tester);
      await settle(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('studio-keep-editing')));
      await settle(tester);
      expect(find.byKey(const ValueKey('studio-form-boxy')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('studio-discard')));
      await settle(tester);
      expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
      expect(store.characterFor('c1', 'ana'), isNull);
    });

    testWidgets('a saved legacy character opens as its closest studio look', (
      tester,
    ) async {
      await store.save(
        'c1',
        'ana',
        const BotCharacter(kind: 'cloud', topper: BotCharacterTopper.crown),
      );
      await open(tester);
      expect(_preview(tester).form, BotForm.cloud);
      expect(_preview(tester).pieces.single.kind, BotPieceKind.crown);
    });

    testWidgets('menu: save under a name, saved list, duplicate, new, reset', (
      tester,
    ) async {
      await open(tester);
      await tapKey(tester, 'studio-form-boxy');
      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-save');
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('studio-name-field')),
        '  Blue   kitten ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('studio-name-save')));
      await settle(tester);
      expect(library.items.single.name, 'Blue kitten');
      expect(library.items.single.character.form, BotForm.boxy);

      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-duplicate');
      await settle(tester);
      expect(library.items.map((e) => e.name), [
        'Blue kitten',
        'Blue kitten (copy)',
      ]);

      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-new');
      await settle(tester);
      expect(_preview(tester).form, BotForm.round);

      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-saved');
      await settle(tester);
      await tester.tap(
        find.byKey(ValueKey('studio-saved-${library.items.first.id}')),
      );
      await settle(tester);
      expect(_preview(tester).form, BotForm.boxy);

      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-reset');
      await settle(tester);
      expect(_preview(tester), BotCharacter.fresh);
    });

    testWidgets('menu: share renders a PNG of the character alone', (
      tester,
    ) async {
      await open(tester);
      await tapKey(tester, 'studio-more');
      await settle(tester);
      await tapKey(tester, 'studio-menu-share');
      // The image is produced by the engine, off the fake clock: give it
      // real time between pumps.
      for (var i = 0; i < 12 && shared.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(shared.length, 1);
      expect(shared.single.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    });

    testWidgets('the PNG capture is square at the export size', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        _host(
          Center(
            child: RepaintBoundary(
              key: key,
              child: const SizedBox.square(
                dimension: 120,
                child: ColoredBox(color: Colors.teal),
              ),
            ),
          ),
        ),
      );
      final png = await tester.runAsync(
        () => captureCharacterPng(key, side: 256),
      );
      expect(png, isNotNull);
      expect(png!.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      // IHDR width and height, big-endian, at bytes 16..23.
      final data = ByteData.sublistView(png);
      expect(data.getUint32(16), 256);
      expect(data.getUint32(20), 256);
      expect(characterFileName('Blue Kitten!'), 'blue-kitten');
      expect(characterFileName('***'), 'character');
    });

    testWidgets('the generate block is off and says why', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('studio-generate')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('studio-generate-field')),
      );
      expect(field.enabled, isFalse);
      expect(find.byKey(const ValueKey('studio-generate-why')), findsOneWidget);
      final button = find.byKey(const ValueKey('studio-generate-button'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays the canvas beside the controls when wide', (
      tester,
    ) async {
      await open(tester, size: const Size(1000, 700));
      final canvas = tester.getTopLeft(
        find.byKey(const ValueKey('studio-canvas-gestures')),
      );
      final tabs = tester.getTopLeft(find.byKey(const ValueKey('studio-tabs')));
      expect(canvas.dx, lessThan(tabs.dx));
    });

    testWidgets('large text does not overflow', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await open(tester, size: const Size(360, 740));
      for (final tab in ['eyes', 'pieces', 'color', 'shape']) {
        await tapKey(tester, 'studio-tab-$tab');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('where the character shows', () {
    MissionProfileAvatarCache cacheFor(String connectionId) =>
        MissionProfileAvatarCache(
          connectionId: connectionId,
          loader: (_) async => null,
        );

    testWidgets('a character applied from the editor shows in ProfileFace', (
      tester,
    ) async {
      await store.save(
        'c1',
        'ana',
        BotCharacter.fresh.copyWith(form: BotForm.boxy),
      );
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: Column(
              children: [
                // A profile without a photo: the cache is not handed down to
                // the avatar, so the connection has to travel on its own.
                ProfileFace(profileName: 'ana', avatarCache: cacheFor('c1')),
                ProfileFace(profileName: 'ana', connectionId: 'c1'),
                ProfileFace(profileName: 'bob', avatarCache: cacheFor('c1')),
                ProfileFace(profileName: 'ana', avatarCache: cacheFor('c2')),
                const ProfileFace(profileName: 'ana'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final saved = find.byKey(const ValueKey('mission-avatar-character-ana'));
      expect(saved, findsNWidgets(2));
      expect(
        tester.widget<CharacterFace>(saved.first).character,
        store.characterFor('c1', 'ana'),
      );
      expect(find.byType(StudioCharacterFace), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('mission-avatar-character-bob')),
        findsNothing,
      );
      // Another connection's `ana`, and one without connection, keep the face.
      expect(
        find.byKey(const ValueKey('mission-avatar-geometry-ana')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('mission-avatar-geometry-bob')),
        findsOneWidget,
      );
    });

    testWidgets('a saved character replaces the seeded face of a profile', (
      tester,
    ) async {
      await store.save('c1', 'ana', const BotCharacter(kind: 'sun'));
      await tester.pumpWidget(
        _host(
          const Scaffold(
            body: Column(
              children: [
                MissionProfileAvatar(
                  profileName: 'ana',
                  hasAvatar: false,
                  cache: null,
                  connectionId: 'c1',
                  allowPet: false,
                ),
                MissionProfileAvatar(
                  profileName: 'bob',
                  hasAvatar: false,
                  cache: null,
                  connectionId: 'c1',
                  allowPet: false,
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('mission-avatar-character-ana')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-avatar-geometry-bob')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-avatar-character-bob')),
        findsNothing,
      );
    });

    testWidgets(
      'LivingBotFace paints the saved studio character of its connection',
      (tester) async {
        await store.save('c1', 'ana', BotCharacter.fresh.copyWith(fur: true));
        await tester.pumpWidget(
          _host(
            Scaffold(
              body: Column(
                children: [
                  LivingBotFace(
                    profileName: 'ana',
                    signal: BotFaceSignal.idle,
                    avatarCache: cacheFor('c1'),
                    animate: false,
                    entrance: false,
                  ),
                  const LivingBotFace(
                    profileName: 'ana',
                    signal: BotFaceSignal.idle,
                    connectionId: 'c1',
                    animate: false,
                    entrance: false,
                  ),
                  LivingBotFace(
                    profileName: 'ana',
                    signal: BotFaceSignal.idle,
                    avatarCache: cacheFor('c2'),
                    animate: false,
                    entrance: false,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        final faces = find.byType(CharacterFace);
        expect(faces, findsNWidgets(2));
        for (final face in tester.widgetList<CharacterFace>(faces)) {
          expect(face.character, store.characterFor('c1', 'ana'));
        }
        expect(find.byType(StudioCharacterFace), findsNWidgets(2));
      },
    );

    testWidgets(
      'a first-generation character still takes the first-generation face',
      (tester) async {
        await store.save('c1', 'ana', const BotCharacter(kind: 'sun'));
        await tester.pumpWidget(
          _host(
            const Scaffold(
              body: LivingBotFace(
                profileName: 'ana',
                signal: BotFaceSignal.idle,
                connectionId: 'c1',
                animate: false,
                entrance: false,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(CharacterFace), findsOneWidget);
        expect(find.byType(StudioCharacterFace), findsNothing);
      },
    );
  });
}
