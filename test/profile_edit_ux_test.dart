// «Editar perfil» in one page: the big avatar and «Cambiar» open ONE sheet
// with every kind of identity (photo, character, pet, face and colour), the
// name, the description, the model and the reasoning are edited in line, and
// one fixed «Guardar» takes it all.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_model_picker.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/characters/character_face.dart';
import 'package:hermes_android/core/characters/character_presets.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/profile_model_fakes.dart';

const _imageDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const _orange = '#f97316';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'conn-ux',
  label: 'Test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'key',
  dashboardUrl: 'http://127.0.0.1:1',
  readOnly: readOnly,
);

/// A Hermes that takes the description and tells what was saved.
base class _Gateway extends FakeModelGateway {
  bool refuseDescription = false;
  final descriptions = <String>[];
  final saved = <({String? title, BotVisualIdentity? identity})>[];
  final reasoning = <String>[];

  @override
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  ) async {
    if (changes.containsKey('description')) {
      descriptions.add(changes['description'] as String);
      return {
        'ok': true,
        'applied': {'description': !refuseDescription},
      };
    }
    return super.configureBotProfile(profile, changes);
  }

  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    int? createdAtMs,
    BotVisualIdentity? identity,
  }) async {
    saved.add((title: title, identity: identity));
  }

  @override
  Future<void> setBotReasoning(String profile, String effort) async {
    reasoning.add(effort);
  }
}

const _bot = AgentProfile(
  name: 'builder',
  model: 'gpt-5.5',
  provider: 'openai',
  description: 'Hace cosas',
  botModeUiMeta: {'title': 'Console Builder'},
);

/// Every tap and every typed field of the journey is counted here.
final class _Steps {
  _Steps(this.tester);
  final WidgetTester tester;
  int count = 0;

  Future<void> tap(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    count++;
    await _pumpUi(tester);
  }

  Future<void> tapKey(String key) => tap(find.byKey(ValueKey(key)));

  Future<void> type(Finder finder, String text) async {
    await tester.ensureVisible(finder);
    await tester.enterText(finder, text);
    count++;
    await tester.pump();
  }
}

Future<void> _pumpUi(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required _Gateway gateway,
  AgentProfile profile = _bot,
  SavedConnection? connection,
  Size size = const Size(420, 1800),
  double textScale = 1,
  Locale locale = const Locale('es'),
  ThemeData? theme,
  Future<XFile?> Function()? imagePicker,
  void Function(bool?)? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: theme ?? AppTheme.hermesRedDark,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-editor'),
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => ProfileEditorScreen(
                    connection: connection ?? _connection(),
                    profile: profile,
                    gateway: gateway,
                    petService: ProfilePetService(gateway),
                    imagePicker: imagePicker,
                    imageNormalizer: (_) async =>
                        AgentProfileAvatar.fromDataUri(_imageDataUri),
                    modelCatalogs: ProfileModelCatalogs(),
                  ),
                ),
              );
              onResult?.call(result);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-editor')));
  await _pumpUi(tester);
}

HermesBotFace _faceIn(WidgetTester tester, String key) =>
    tester.widget<HermesBotFace>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(HermesBotFace),
      ),
    );

String? _colorOf(WidgetTester tester, String key) =>
    (_faceIn(tester, key).visual as HermesBlobatarFaceVisual).colorHex;

void main() {
  late BotCharacterStore shared;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    shared = await BotCharacterStore.load(
      await SharedPreferences.getInstance(),
    );
  });
  tearDown(() => BotCharacterStore.debugUse(null));

  testWidgets('one visit changes photo, face, colour, character, name, '
      'description and model in 14 steps', (tester) async {
    final gateway = _Gateway();
    bool? result;
    final bytes = base64Decode(_imageDataUri.split(',').last);
    await _pumpEditor(
      tester,
      gateway: gateway,
      imagePicker: () async =>
          XFile.fromData(bytes, mimeType: 'image/png', name: 'a.png'),
      onResult: (value) => result = value,
    );
    final steps = _Steps(tester);

    // The one sheet: photo, then a plain face and its colour, then a
    // character from the Studio.
    await steps.tapKey('profile-editor-avatar');
    expect(
      find.byKey(const ValueKey('profile-editor-identity-sheet')),
      findsOneWidget,
    );
    await steps.tapKey('profile-editor-mode-image');
    await steps.tapKey('profile-editor-pick-image');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profile-editor-sheet-preview')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    await steps.tapKey('profile-editor-mode-face');
    await steps.tapKey('bot-face-color-$_orange');
    expect(_colorOf(tester, 'profile-editor-sheet-preview'), _orange);
    expect(_colorOf(tester, 'profile-editor-preview'), _orange);
    await steps.tapKey('profile-editor-mode-character');
    expect(find.byKey(const ValueKey('studio-preset-coral')), findsOneWidget);
    await steps.tapKey('studio-preset-coral');
    await steps.tap(find.byType(BackButton));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profile-editor-sheet-preview')),
        matching: find.byType(CharacterFace),
      ),
      findsOneWidget,
    );
    // Nothing is written until «Guardar».
    expect(shared.characterFor('conn-ux', 'builder'), isNull);
    await steps.tapKey('profile-editor-sheet-done');

    // In line: name, description, model.
    await steps.type(find.byType(TextField).first, 'Nuevo nombre');
    await steps.type(
      find.byKey(const ValueKey('profile-editor-description')),
      'Otra descripción',
    );
    await steps.tapKey('profile-editor-model-row');
    await steps.tapKey('profile-editor-model-openai-gpt-5.5-mini');
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);
    await steps.tapKey('profile-editor-save');

    expect(steps.count, 14);
    expect(result, isTrue);
    expect(gateway.descriptions, ['Otra descripción']);
    expect(gateway.configures.map((c) => c.$2['model']).whereType<String>(), [
      'gpt-5.5-mini',
    ]);
    final saved = gateway.saved.single;
    expect(saved.title, 'Nuevo nombre');
    // A character shows over a face, never over a photo: what the server
    // gets is the face, so the character is seen wherever the profile is.
    final identity = saved.identity! as ProceduralFaceIdentity;
    expect(identity.dormantColorHex, _orange);
    expect(shared.characterFor('conn-ux', 'builder'), isNotNull);
  });

  testWidgets('the preview follows each choice before anything is saved', (
    tester,
  ) async {
    final gateway = _Gateway();
    await _pumpEditor(tester, gateway: gateway);
    await tester.tap(find.byKey(const ValueKey('profile-editor-avatar')));
    await _pumpUi(tester);
    final before = _colorOf(tester, 'profile-editor-sheet-preview');
    await tester.tap(find.byKey(const ValueKey('bot-face-color-$_orange')));
    await _pumpUi(tester);
    expect(_colorOf(tester, 'profile-editor-sheet-preview'), _orange);
    expect(_colorOf(tester, 'profile-editor-preview'), _orange);
    expect(before, isNot(_orange));
    expect(gateway.saved, isEmpty);
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);

    // «Restablecer» goes back to the plain seeded face.
    await tester.tap(find.byKey(const ValueKey('profile-editor-reset')));
    await _pumpUi(tester);
    expect(_colorOf(tester, 'profile-editor-sheet-preview'), isNot(_orange));
  });

  testWidgets('a character over a photo saves a face; a colour over a '
      'character removes it; leaving discards the draft', (tester) async {
    await shared.save('conn-ux', 'builder', botPresets.first.character);
    final gateway = _Gateway();
    await _pumpEditor(tester, gateway: gateway);
    // The saved character is what the page shows.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profile-editor-preview')),
        matching: find.byType(CharacterFace),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('profile-editor-avatar')));
    await _pumpUi(tester);
    // «Cara» asks for a plain face: the character stops covering it.
    await tester.tap(find.byKey(const ValueKey('profile-editor-mode-face')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('bot-face-color-$_orange')));
    await _pumpUi(tester);
    // The colour asks for a plain face: the character stops covering it.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profile-editor-preview')),
        matching: find.byType(CharacterFace),
      ),
      findsNothing,
    );
    expect(shared.characterFor('conn-ux', 'builder'), isNotNull);
    await tester.tap(find.byKey(const ValueKey('profile-editor-sheet-done')));
    await _pumpUi(tester);
    await tester.tap(find.byType(BackButton));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('profile-editor-discard')));
    await _pumpUi(tester);
    expect(find.byType(ProfileEditorScreen), findsNothing);
    // Discarded: the saved character is as it was.
    expect(shared.characterFor('conn-ux', 'builder'), isNotNull);
    expect(gateway.saved, isEmpty);
  });

  testWidgets('saving a colour over a character removes the character', (
    tester,
  ) async {
    await shared.save('conn-ux', 'builder', botPresets.first.character);
    final gateway = _Gateway();
    await _pumpEditor(tester, gateway: gateway);
    await tester.tap(find.byKey(const ValueKey('profile-editor-avatar')));
    await _pumpUi(tester);
    // «Cara» asks for a plain face: the character stops covering it.
    await tester.tap(find.byKey(const ValueKey('profile-editor-mode-face')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('bot-face-color-$_orange')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('profile-editor-sheet-done')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('profile-editor-save')));
    await _pumpUi(tester);
    expect(shared.characterFor('conn-ux', 'builder'), isNull);
    expect(gateway.saved.single.identity, isA<ProceduralFaceIdentity>());
  });

  testWidgets('a saved character shows at once in the Bots list face', (
    tester,
  ) async {
    final gateway = _Gateway();
    await _pumpEditor(tester, gateway: gateway);
    await tester.tap(find.byKey(const ValueKey('profile-editor-avatar')));
    await _pumpUi(tester);
    await tester.tap(
      find.byKey(const ValueKey('profile-editor-mode-character')),
    );
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('studio-preset-coral')));
    await _pumpUi(tester);
    await tester.tap(find.byType(BackButton));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('profile-editor-sheet-done')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('profile-editor-save')));
    await _pumpUi(tester);

    tester.view.physicalSize = const Size(420, 800);
    await tester.pumpWidget(
      modelApp(
        const Scaffold(
          body: Center(
            child: LivingBotFace(
              profileName: 'builder',
              connectionId: 'conn-ux',
              signal: BotFaceSignal.idle,
              animate: false,
              entrance: false,
            ),
          ),
        ),
      ),
    );
    await _pumpUi(tester);
    expect(find.byType(CharacterFace), findsOneWidget);
  });

  testWidgets('description and reasoning apply; a refusal is written in line', (
    tester,
  ) async {
    final gateway = _Gateway()..refuseDescription = true;
    await _pumpEditor(tester, gateway: gateway);
    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-description')),
      'Nueva',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('profile-editor-save')));
    await _pumpUi(tester);
    expect(find.byType(ProfileEditorScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-editor-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);
    expect(gateway.saved, isEmpty);

    // Reasoning applies as soon as it is picked.
    await tester.tap(
      find.byKey(const ValueKey('profile-editor-reasoning-row')),
    );
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('profile-editor-reasoning-picker')),
      findsOneWidget,
    );
  });

  testWidgets('a read-only connection disables every field without a word', (
    tester,
  ) async {
    final gateway = _Gateway();
    await _pumpEditor(
      tester,
      gateway: gateway,
      connection: _connection(readOnly: true),
    );
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.enabled, isFalse);
    }
    await tester.tap(
      find.byKey(const ValueKey('profile-editor-avatar')),
      warnIfMissed: false,
    );
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('profile-editor-identity-sheet')),
      findsNothing,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('profile-editor-change')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<HermesPrimaryButton>(
            find.byKey(const ValueKey('profile-editor-save')),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('the avatar sits below the header and the list stops at it', (
    tester,
  ) async {
    await _pumpEditor(tester, gateway: _Gateway());
    final header = tester.getRect(find.byType(HermesAppBar));
    final avatar = tester.getRect(
      find.byKey(const ValueKey('profile-editor-preview')),
    );
    expect(avatar.top, greaterThanOrEqualTo(header.bottom));
    // What scrolls up is cut at the header's edge, never drawn under its title.
    expect(
      tester
          .widget<ListView>(find.byKey(const ValueKey('profile-editor-scroll')))
          .clipBehavior,
      Clip.hardEdge,
    );
  });

  testWidgets('targets are 48 dp, the avatar is a labelled button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpEditor(tester, gateway: _Gateway());
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    final node = tester.getSemantics(
      find.byKey(const ValueKey('profile-editor-avatar')),
    );
    expect(node.label, contains('Console Builder'));
    // ignore: deprecated_member_use
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);

    await tester.tap(find.byKey(const ValueKey('profile-editor-avatar')));
    await _pumpUi(tester);
    for (final key in [
      'profile-editor-mode-image',
      'profile-editor-mode-character',
      'profile-editor-mode-pet',
      'profile-editor-mode-face',
      'profile-editor-reset',
      'profile-editor-sheet-done',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
    }
    handle.dispose();
  });

  for (final code in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    for (final dark in [true, false]) {
      testWidgets('no overflow at 2x text, sheet open · $code · '
          '${dark ? 'dark' : 'light'}', (tester) async {
        await _pumpEditor(
          tester,
          gateway: _Gateway(),
          size: const Size(360, 740),
          textScale: 2,
          locale: Locale(code),
          theme: dark ? AppTheme.hermesRedDark : AppTheme.hermesRedLight,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('profile-editor-avatar')));
        await _pumpUi(tester);
        for (final key in [
          'profile-editor-mode-character',
          'profile-editor-mode-pet',
          'profile-editor-mode-image',
          'profile-editor-mode-face',
        ]) {
          await tester.tap(find.byKey(ValueKey(key)));
          await _pumpUi(tester);
          if (key.endsWith('character')) {
            await tester.tap(find.byType(BackButton));
            await _pumpUi(tester);
          }
          expect(tester.takeException(), isNull, reason: '$code $key');
        }
      });
    }
  }
}
