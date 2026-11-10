// The semantics flags are read with the long-standing API, which every SDK
// the project builds with still has.
// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/characters/character_library.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';
import 'package:hermes_android/core/characters/studio_painter.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/screens/characters/character_editor_screen.dart';
import 'package:hermes_android/core/screens/characters/character_studio_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(ThemeData theme, Widget child, [String locale = 'en']) =>
    MaterialApp(
      locale: Locale(locale),
      theme: theme,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: child,
    );

/// The Android tap-target guideline, with one exception: the finish picker
/// is the design system's segmented control, whose segments are 44 dp tall
/// everywhere in the app. Anything else under 48 dp fails.
Future<void> expectTapTargets(WidgetTester tester) async {
  final result = await androidTapTargetGuideline.evaluate(tester);
  if (result.passed) return;
  final reason = result.reason ?? '';
  final offenders = RegExp(
    r'label: "([^"]*)"',
  ).allMatches(reason).map((m) => m.group(1)).toSet();
  const segments = {'Flat', 'Matte', 'Soft', 'Glossy'};
  expect(
    offenders.difference(segments),
    isEmpty,
    reason: 'Only the finish segments may be under 48 dp. $reason',
  );
}

final _themes = {
  'dark': AppTheme.hermesRedDark,
  'light': AppTheme.hermesRedLight,
};

void main() {
  late BotCharacterStore store;
  late BotCharacterLibrary library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await BotCharacterStore.load(await SharedPreferences.getInstance());
    library = BotCharacterLibrary.memory();
  });
  tearDown(() => BotCharacterStore.debugUse(null));

  Widget editor() => CharacterEditorScreen(
    profileName: 'ana',
    connectionId: 'c1',
    store: store,
    library: library,
  );

  Future<void> open(WidgetTester tester, ThemeData theme, Widget screen) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(theme, screen));
    await tester.pump();
  }

  group('touch targets and labels', () {
    for (final entry in _themes.entries) {
      for (final tab in ['shape', 'eyes', 'pieces', 'color']) {
        testWidgets('editor, ${entry.key}, $tab tab', (tester) async {
          final handle = tester.ensureSemantics();
          await open(tester, entry.value, editor());
          await tester.tap(find.byKey(ValueKey('studio-tab-$tab')));
          await tester.pump();
          if (tab == 'pieces') {
            await tester.tap(
              find.byKey(const ValueKey('studio-piece-add-bow')),
            );
            await tester.pump();
          }
          await expectTapTargets(tester);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          handle.dispose();
        });
      }

      testWidgets('studio screen, ${entry.key}', (tester) async {
        final handle = tester.ensureSemantics();
        await library.add('Blue', BotCharacter.fresh);
        await open(
          tester,
          entry.value,
          CharacterStudioScreen(
            profileName: 'ana',
            connectionId: 'c1',
            store: store,
            library: library,
          ),
        );
        await expectTapTargets(tester);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  });

  testWidgets('the controls speak: buttons, sliders, tiles and the canvas', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester, _themes['dark']!, editor());
    // Icon buttons speak through their tooltip.
    for (final entry in {
      'studio-undo': 'Undo',
      'studio-more': 'More options',
      'studio-confirm': 'Apply to profile',
      'studio-pan': 'Pan canvas',
      'studio-zoom-out': 'Zoom out',
      'studio-zoom-in': 'Zoom in',
    }.entries) {
      final node = tester.getSemantics(find.byKey(ValueKey(entry.key)));
      expect(
        '${node.label} ${node.tooltip}',
        contains(entry.value),
        reason: entry.key,
      );
    }
    expect(find.bySemanticsLabel(RegExp('Character canvas')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Preview state: ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Range')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Strength')), findsWidgets);
    final tile = tester.getSemantics(
      find.byKey(const ValueKey('studio-form-round')),
    );
    expect(tile.label, 'Round');
    expect(tile.hasFlag(SemanticsFlag.isSelected), isTrue);
    expect(tile.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('studio-form-boxy')))
          .hasFlag(SemanticsFlag.isSelected),
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('studio-tab-pieces')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('studio-piece-add-star')));
    await tester.pump();
    // The switch and the unfolding row are announced by name.
    expect(find.bySemanticsLabel(RegExp('^Flip')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Position')), findsWidgets);
    handle.dispose();
  });

  group('contrast', () {
    for (final entry in _themes.entries) {
      test('${entry.key}: text and controls meet AA with the tokens', () {
        final c = entry.value.extension<HermesThemeColors>()!;
        void aa(String what, Color fg, Color bg, [double min = 4.5]) {
          expect(
            ThemeContrast.ratio(fg, bg),
            greaterThanOrEqualTo(min),
            reason: '$what (${entry.key})',
          );
        }

        aa('primary text on the page', c.textPrimary, c.background);
        aa('secondary text on the page', c.textSecondary, c.background);
        aa('label on the accent pill', c.onAccent, c.accent);
        aa('primary text on surface', c.textPrimary, c.surface);
        // The preview overlays (zz, drops) are graphics: 3:1.
        aa('overlay ink on the canvas', c.textSecondary, c.surface, 3);
        // The selection frame and handles against the canvas.
        aa('selection on the canvas', c.textPrimary, c.surface, 3);
      });
    }

    test('automatic eye colour reads on every body colour', () {
      final bodies = <String, Color>{
        for (final hex in ClassicFaceIdentity.colors) hex: colorFromHex(hex),
        for (final gradient in botGradients)
          gradient.id: studioBodyColor(
            BotCharacter.fresh.copyWith(gradient: gradient.id),
            const Color(0xff000000),
          ),
      };
      for (final entry in bodies.entries) {
        final ink = ThemeContrast.bestBlackOrWhite(entry.value);
        expect(
          ThemeContrast.ratio(ink, entry.value),
          greaterThanOrEqualTo(3),
          reason: entry.key,
        );
      }
    });
  });

  testWidgets('every language builds the editor without overflow', (
    tester,
  ) async {
    for (final locale in Strings.supportedLocales) {
      await open(tester, _themes['dark']!, editor());
      await tester.pumpWidget(
        _host(_themes['dark']!, editor(), locale.languageCode),
      );
      await tester.pump();
      for (final tab in ['eyes', 'pieces', 'color']) {
        await tester.tap(find.byKey(ValueKey('studio-tab-$tab')));
        await tester.pump();
      }
      expect(tester.takeException(), isNull, reason: locale.languageCode);
    }
  });
}
