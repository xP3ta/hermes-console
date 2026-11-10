import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/characters/character_face.dart';
import 'package:hermes_android/core/characters/character_library.dart';
import 'package:hermes_android/core/characters/character_presets.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';
import 'package:hermes_android/core/characters/studio_painter.dart';
import 'package:hermes_android/core/screens/characters/character_studio_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

void main() {
  late BotCharacterStore store;
  late BotCharacterLibrary library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await BotCharacterStore.load(await SharedPreferences.getInstance());
    var n = 0;
    library = BotCharacterLibrary.memory(newId: () => 'id${n++}');
  });
  tearDown(() => BotCharacterStore.debugUse(null));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        CharacterStudioScreen(
          profileName: 'ana',
          connectionId: 'c1',
          store: store,
          library: library,
        ),
      ),
    );
    await tester.pump();
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

  testWidgets('shows the current character, an empty collection and presets', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(const ValueKey('studio-current')), findsOneWidget);
    expect(find.text('You haven’t saved any character yet.'), findsOneWidget);
    for (final preset in botPresets) {
      expect(
        find.byKey(ValueKey('studio-preset-${preset.id}'), skipOffstage: false),
        findsOneWidget,
        reason: preset.id,
      );
    }
    expect(find.byKey(const ValueKey('studio-customize')), findsOneWidget);
    expect(find.byType(StudioCharacterFace), findsWidgets);
  });

  testWidgets('a preset becomes the profile character', (tester) async {
    await open(tester);
    expect(store.characterFor('c1', 'ana'), isNull);
    await tapKey(tester, 'studio-preset-kitten');
    final kitten = botPresets.firstWhere((p) => p.id == 'kitten').character;
    expect(store.characterFor('c1', 'ana'), kitten);
    expect(store.characterFor('c1', 'bob'), isNull);
    expect(
      tester
          .widget<CharacterFace>(find.byKey(const ValueKey('studio-current')))
          .character,
      kitten,
    );
  });

  testWidgets('a saved character is in Studio after the app restarts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final before = await BotCharacterLibrary.load(prefs);
    addTearDown(() => BotCharacterLibrary.debugUse(null));
    final saved = await before.add(
      'Persisted',
      BotCharacter.fresh.copyWith(gradient: 'bay'),
    );

    // New process: the library is read again from the same preferences and
    // Studio takes the shared one, as the app does.
    await BotCharacterLibrary.load(prefs);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        CharacterStudioScreen(
          profileName: 'ana',
          connectionId: 'c1',
          store: store,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Persisted'), findsOneWidget);
    expect(find.byKey(ValueKey('studio-mine-${saved.id}')), findsOneWidget);
  });

  test('the character a profile wears is kept per connection', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final first = await BotCharacterStore.load(prefs);
    final red = BotCharacter.fresh.copyWith(bodyColor: '#ef4444');
    await first.save('c1', 'ana', red);

    final again = await BotCharacterStore.load(prefs);
    expect(again.characterFor('c1', 'ana'), red);
    expect(again.characterFor('c2', 'ana'), isNull);
    expect(again.characterFor('c1', 'bob'), isNull);
    expect(again.characterFor(null, 'ana'), isNull);
  });

  testWidgets('saved characters are used, duplicated, edited and deleted', (
    tester,
  ) async {
    final a = await library.add(
      'Blue',
      BotCharacter.fresh.copyWith(gradient: 'bay'),
    );
    await library.add('Red', BotCharacter.fresh.copyWith(bodyColor: '#ef4444'));
    await open(tester);
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Red'), findsOneWidget);

    await tapKey(tester, 'studio-mine-${a.id}');
    expect(store.characterFor('c1', 'ana'), a.character);

    await tester.longPress(find.byKey(ValueKey('studio-mine-${a.id}')));
    await settle(tester);
    await tapKey(tester, 'studio-saved-duplicate');
    await settle(tester);
    expect(library.items.map((e) => e.name), ['Blue', 'Blue (copy)', 'Red']);

    await tester.longPress(find.byKey(ValueKey('studio-mine-${a.id}')));
    await settle(tester);
    await tapKey(tester, 'studio-saved-delete');
    await settle(tester);
    await tapKey(tester, 'studio-saved-delete-confirm');
    await settle(tester);
    expect(library.items.map((e) => e.name), ['Blue (copy)', 'Red']);

    await tester.longPress(find.text('Red'));
    await settle(tester);
    await tapKey(tester, 'studio-saved-edit');
    await settle(tester);
    expect(find.byKey(const ValueKey('studio-tabs')), findsOneWidget);
    expect(
      tester
          .widget<StudioCharacterFace>(
            find.byKey(const ValueKey('character-preview')),
          )
          .character
          .bodyColor,
      '#ef4444',
    );
  });

  testWidgets('customize opens the editor on the profile character', (
    tester,
  ) async {
    await store.save('c1', 'ana', BotCharacter.fresh.copyWith(fur: true));
    await open(tester);
    await tapKey(tester, 'studio-customize');
    await settle(tester);
    expect(find.byKey(const ValueKey('studio-tabs')), findsOneWidget);
    expect(
      tester
          .widget<StudioCharacterFace>(
            find.byKey(const ValueKey('character-preview')),
          )
          .character
          .fur,
      isTrue,
    );
  });

  testWidgets('the original face comes back', (tester) async {
    await store.save('c1', 'ana', BotCharacter.fresh);
    await open(tester);
    await tapKey(tester, 'studio-original-face');
    await tester.pump();
    expect(store.characterFor('c1', 'ana'), isNull);
    expect(
      tester
          .widget<CharacterFace>(find.byKey(const ValueKey('studio-current')))
          .character,
      BotCharacter.standard,
    );
  });

  testWidgets('presets are complete studio characters', (tester) async {
    expect(botPresets.map((p) => p.id).toSet().length, botPresets.length);
    for (final preset in botPresets) {
      expect(preset.character.isStudio, isTrue, reason: preset.id);
      expect(preset.character.seed, isNotEmpty);
      expect(
        preset.character.bodyColor != null || preset.character.gradient != null,
        isTrue,
        reason: preset.id,
      );
    }
    expect(BotStudioState.values.length, 14);
  });
}
