// A bot's model is chosen, never typed, and choosing it never locks the
// card: on the bot's card and in the create form.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_model_picker.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/model_active_info.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/services/model_catalog_cache.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';

import '../support/bot_roster_fakes.dart';
import '../support/profile_model_fakes.dart';

Future<void> _pumpCard(WidgetTester tester, FakeModelGateway gateway) async {
  phoneView(tester);
  await tester.pumpWidget(
    modelApp(
      BotProfileScreen(
        data: () =>
            const BotProfileData(profile: modelBot, signal: BotFaceSignal.idle),
        modelGateway: gateway,
        profileGateway: gateway,
        catalogScope: 'conn',
        modelCatalogs: ProfileModelCatalogs(),
        machineLabel: 'homelab',
        onChat: () {},
        onRoutines: () {},
        onSoul: () {},
        onSkills: () {},
        onMemory: () {},
      ),
    ),
  );
  await pumpModelUi(tester);
}

const _modelRow = ValueKey('bot-profile-model');
const _mini = ValueKey('bot-profile-model-openai-gpt-5.5-mini');

Finder _loaderIn(Key row) =>
    find.descendant(of: find.byKey(row), matching: find.byType(ConsoleLoader));

void main() {
  group('a bot\'s card, its model', () {
    testWidgets('a catalog that does not answer never locks the card, and '
        'the read is given up after 20 s', (tester) async {
      final gateway = FakeModelGateway()..hang = true;
      await _pumpCard(tester, gateway);
      await tester.tap(find.byKey(_modelRow));
      await pumpModelUi(tester);
      // Only the row waits.
      expect(_loaderIn(_modelRow), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bot-profile-reasoning')));
      await pumpModelUi(tester);
      expect(
        find.byKey(const ValueKey('bot-profile-reasoning-picker')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await pumpModelUi(tester);

      await tester.pump(const Duration(seconds: 20));
      await pumpModelUi(tester);
      expect(_loaderIn(_modelRow), findsNothing);
      expect(
        find.byKey(const ValueKey('bot-profile-model-picker')),
        findsNothing,
      );
      // One read served the card's opening and the tap; the next tap asks
      // again.
      expect(gateway.catalogReads, ['builder']);
      await tester.tap(find.byKey(_modelRow));
      await pumpModelUi(tester);
      expect(gateway.catalogReads, ['builder', 'builder']);
      await tester.pump(const Duration(seconds: 60));
    });

    testWidgets('the catalog is read when the card opens: the picker opens '
        'at once and the choice is saved', (tester) async {
      var changed = 0;
      final gateway = FakeModelGateway();
      phoneView(tester);
      await tester.pumpWidget(
        modelApp(
          BotProfileScreen(
            data: () => const BotProfileData(
              profile: modelBot,
              signal: BotFaceSignal.idle,
            ),
            modelGateway: gateway,
            profileGateway: gateway,
            catalogScope: 'conn',
            modelCatalogs: ProfileModelCatalogs(),
            machineLabel: 'homelab',
            onChat: () {},
            onRoutines: () {},
            onSoul: () {},
            onSkills: () {},
            onMemory: () {},
            onChanged: () => changed++,
          ),
        ),
      );
      await pumpModelUi(tester);
      expect(gateway.catalogReads, ['builder']);

      await tester.tap(find.byKey(_modelRow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('bot-profile-model-picker')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(_mini));
      await pumpModelUi(tester);

      expect(gateway.configures.single.$1, 'builder');
      expect(gateway.configures.single.$2, {
        'model': 'gpt-5.5-mini',
        'provider': 'openai',
      });
      expect(find.text('openai · gpt-5.5-mini'), findsOneWidget);
      expect(changed, 1);
      expect(gateway.catalogReads, ['builder']);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a catalog that arrives while something else is open does '
        'not open over it', (tester) async {
      final gateway = FakeModelGateway()..hang = true;
      await _pumpCard(tester, gateway);
      await tester.tap(find.byKey(_modelRow));
      await pumpModelUi(tester);
      await tester.tap(find.byKey(const ValueKey('bot-profile-reasoning')));
      await pumpModelUi(tester);
      gateway.pending!.complete(modelCatalog());
      await pumpModelUi(tester);

      expect(
        find.byKey(const ValueKey('bot-profile-reasoning-picker')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bot-profile-model-picker')),
        findsNothing,
      );
      expect(_loaderIn(_modelRow), findsNothing);
    });
  });

  group('a new bot, its model', () {
    testWidgets('without a catalog nothing is typed: the row asks for it '
        'again and then it is a picker', (tester) async {
      phoneView(tester);
      final gateway = FakeModelGateway();
      var reads = 0;
      await tester.pumpWidget(
        modelApp(
          BotCreateScreen(
            connection: connection,
            existing: const {'default'},
            gateway: gateway,
            assetsGateway: gateway,
            petService: ProfilePetService(gateway),
            modelOptionsLoader: (_) async {
              if (++reads == 1) throw StateError('no catalog');
              return const [
                ModelProvider(
                  slug: 'openai',
                  name: 'OpenAI',
                  isCurrent: true,
                  authenticated: true,
                  authType: 'api_key',
                  oauthProviderId: '',
                  keyEnv: '',
                  warning: '',
                  models: ['gpt-5.5', 'gpt-5.5-mini'],
                ),
              ];
            },
          ),
        ),
      );
      await pumpModelUi(tester);
      const tile = ValueKey('bot-create-model-tile');
      expect(find.byKey(const ValueKey('bot-create-provider')), findsNothing);
      expect(find.byKey(const ValueKey('bot-create-model')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(tile),
          matching: find.byIcon(Icons.refresh_rounded),
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.byKey(tile));
      await tester.pump();
      await tester.tap(find.byKey(tile));
      await pumpModelUi(tester);
      expect(reads, 2);
      await tester.tap(find.byKey(tile));
      await pumpModelUi(tester);
      expect(
        find.byKey(const ValueKey('bot-create-model-picker')),
        findsOneWidget,
      );
    });
  });

  // QA 9529: the chat of that profile must not paint or use the model the
  // profile had.
  group('a model saved on the card reaches the profile\'s chat', () {
    setUp(ProfileModelEdits.shared.clear);
    tearDown(ProfileModelEdits.shared.clear);

    ModelPickerResult cached() => const ModelPickerResult(
      info: ModelActiveInfo(
        model: 'gpt-5.5',
        provider: 'openai',
        effectiveContextLength: 0,
      ),
      providers: [],
      source: ModelPickerSource.socket,
    );

    testWidgets('the chat\'s cached catalog names the new model at once '
        'and is read again; its 2 min catalog is dropped', (tester) async {
      phoneView(tester);
      final gateway = FakeModelGateway();
      final picker = ModelPickerCache();
      final catalog = ModelCatalogCache();
      final key = ModelPickerCache.key('conn', 'builder');
      picker.write(key, cached());
      catalog.write('conn', 'builder', modelCatalog());
      await tester.pumpWidget(
        modelApp(
          Scaffold(
            body: ProfileModelPicker(
              profile: 'builder',
              scope: 'conn',
              provider: 'openai',
              model: 'gpt-5.5',
              catalogGateway: gateway,
              writer: gateway,
              keyPrefix: 'card-model',
              catalogs: ProfileModelCatalogs(),
              chatCatalogs: (picker: picker, catalog: catalog),
              builder: (context, row) => TextButton(
                key: const ValueKey('card-model-row'),
                onPressed: row.onTap,
                child: Text(row.model),
              ),
            ),
          ),
        ),
      );
      await pumpModelUi(tester);
      await tester.tap(find.byKey(const ValueKey('card-model-row')));
      await pumpModelUi(tester);
      await tester.tap(
        find.byKey(const ValueKey('card-model-openai-gpt-5.5-mini')),
      );
      await pumpModelUi(tester);

      expect(gateway.configures.single.$2['model'], 'gpt-5.5-mini');
      final entry = picker.peek(key)!;
      expect(entry.result.info.model, 'gpt-5.5-mini');
      expect(entry.result.info.provider, 'openai');
      expect(entry.fresh, isFalse);
      expect(catalog.read('conn', 'builder'), isNull);
      expect(ProfileModelEdits.shared.latest('conn', 'builder'), (
        provider: 'openai',
        model: 'gpt-5.5-mini',
      ));
      expect(ProfileModelEdits.shared.latest('other', 'builder'), isNull);
      await tester.pump(const Duration(seconds: 5));
    });

    test('a profile without a cached catalog has nothing to patch', () {
      final picker = ModelPickerCache();
      picker.profileModelChanged(
        ModelPickerCache.key('conn', 'builder'),
        provider: 'openai',
        model: 'gpt-5.5-mini',
      );
      expect(picker.peek(ModelPickerCache.key('conn', 'builder')), isNull);
    });
  });

  group('ProfileModelCatalogs', () {
    test(
      'one read at a time per profile; the answer is kept and ages',
      () async {
        var now = DateTime(2026, 10, 12, 9);
        final catalogs = ProfileModelCatalogs(now: () => now);
        final gateway = FakeModelGateway()..hang = true;
        final first = catalogs.read(gateway, 'conn', 'builder');
        final second = catalogs.read(gateway, 'conn', 'builder');
        expect(identical(first, second), isTrue);
        expect(gateway.catalogReads, ['builder']);
        expect(catalogs.peek('conn', 'builder'), isNull);

        gateway.pending!.complete(modelCatalog());
        await first;
        expect(catalogs.peek('conn', 'builder'), isNotNull);
        expect(catalogs.peek('other', 'builder'), isNull);
        expect(catalogs.isFresh('conn', 'builder'), isTrue);
        now = now.add(const Duration(minutes: 3));
        expect(catalogs.isFresh('conn', 'builder'), isFalse);
        expect(catalogs.peek('conn', 'builder'), isNotNull);
        // The read is over: the next one goes to the server again.
        gateway.hang = false;
        await catalogs.read(gateway, 'conn', 'builder');
        expect(gateway.catalogReads, ['builder', 'builder']);
      },
    );

    test('a read that fails keeps nothing', () async {
      final catalogs = ProfileModelCatalogs(
        settle: const Duration(milliseconds: 20),
      );
      final gateway = FakeModelGateway()..hang = true;
      await expectLater(
        catalogs.read(gateway, 'conn', 'builder'),
        throwsA(isA<TimeoutException>()),
      );
      expect(catalogs.peek('conn', 'builder'), isNull);
    });
  });
}
