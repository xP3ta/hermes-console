// A bot's image, "Mascota": the pets the profile already has on Hermes and
// the Petdex catalogue with its search, from the bot's card (edit) and from
// the create form.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/data/petdex_remote_service.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/screens/companion/petdex_gallery_screen.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/services/profile_pet_visual_adapter.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _imageDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

const _installed = ProfilePetGallery(
  enabled: false,
  active: '',
  pets: [
    ProfilePetGalleryEntry(slug: 'boba', displayName: 'Boba', installed: true),
  ],
);

/// `pet.*` of a Hermes whose own fetch of the Petdex manifest did not work:
/// upstream `pet.gallery` is fail-open and answers with what is installed
/// in the profile, nothing else.
class _Pets implements HermesDesktopPetGateway {
  _Pets({this.galleryFails = 0, this.gallery = _installed, this.error});

  /// How many `pet.gallery` calls fail before one answers.
  int galleryFails;
  final ProfilePetGallery gallery;

  /// What a failing `pet.gallery` throws.
  final Object? error;
  int galleryCalls = 0;
  String active = '';
  bool enabled = false;
  final selected = <(String, String)>[];
  final thumbs = <(String, String)>[];

  @override
  Stream<TuiGatewayEvent> get events => const Stream.empty();

  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async => enabled
      ? ProfilePetInfo(enabled: true, slug: active, spritesheetRevision: 'r1')
      : ProfilePetInfo.disabled;

  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async {
    galleryCalls++;
    if (galleryFails > 0) {
      galleryFails--;
      throw error ?? const TuiGatewayRpcError('pet.gallery', 'socket closed');
    }
    return gallery;
  }

  @override
  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  }) async {
    thumbs.add((slug, url));
    return _imageDataUri;
  }

  @override
  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  }) async {
    selected.add((profile, slug));
    active = slug;
    enabled = true;
    return ProfilePetSelection(slug: slug, displayName: slug);
  }

  @override
  Future<bool> profilePetDisable({String profile = ''}) async {
    active = '';
    enabled = false;
    return true;
  }
}

class _Assets implements HermesDesktopProfileAssetsGateway {
  final identities = <BotVisualIdentity?>[];

  @override
  Future<AgentProfileAvatar?> profileAvatar(String profileName) async => null;

  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    BotVisualIdentity? identity,
  }) async => identities.add(identity);

  @override
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  }) async {}

  @override
  Future<void> clearProfileAvatar(String profile) async {}
}

class _Creation implements HermesDesktopBotCreationGateway {
  final created = <String>[];

  @override
  Future<void> createProfileNative({
    required String name,
    String? cloneFrom,
    String description = '',
    String soul = '',
    String model = '',
    String provider = '',
    bool noSkills = false,
    bool shareAuth = true,
  }) async => created.add(name);

  @override
  Future<List<DesktopProfileSkill>?> describeProfileSkills(
    String profile,
  ) async => const [];

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
  }) async {}

  @override
  Future<void> setProfileDisabledSkills({
    required String profile,
    required List<String> disabledSkills,
  }) async {}
}

class _Materializer implements ProfilePetVisualMaterializer {
  @override
  Future<ProfilePetVisual> materialize(
    ProfilePetInfo info, {
    required String connectionId,
    required String profileId,
  }) async {
    final file = File(
      '${Directory.systemTemp.path}/hermes-petdex-$connectionId-$profileId.png',
    );
    if (!file.existsSync()) {
      file.writeAsBytesSync(base64Decode(_imageDataUri.split(',').last));
    }
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    return ProfilePetVisual(
      companion: Companion(
        slug: info.slug,
        name: info.slug,
        author: 'Hermes',
        license: 'test',
        spritesheetAsset: file.path,
        frameWidth: 1,
        frameHeight: 1,
        cols: 1,
        rows: 1,
        fps: 8,
        states: const {
          CompanionAnimationState.idle: RowSpec(
            row: 0,
            frameCount: 1,
            loop: true,
          ),
        },
        origin: CompanionOrigin.remote,
      ),
      avatar: AgentProfileAvatar.fromDataUri(_imageDataUri),
    );
  }
}

/// The Petdex catalogue, counting what the app asks of it.
class _Petdex extends PetdexRemoteService {
  _Petdex({this.offlineFirst = 0, this.broken = false})
    : super(client: MockClient((_) async => http.Response('', 500)));

  /// How many reads find no network before one gets through.
  int offlineFirst;

  /// Petdex answers, but not with a catalogue.
  final bool broken;
  int manifestReads = 0;
  int zipDownloads = 0;

  static PetdexRemotePet _pet(
    String slug,
    String name,
    String by,
    String kind,
  ) => PetdexRemotePet(
    slug: slug,
    displayName: name,
    submittedBy: by,
    kind: kind,
    spritesheetUrl: Uri.parse(
      'https://assets.petdex.dev/pets/$slug/sprite.webp',
    ),
    petJsonUrl: Uri.parse('https://assets.petdex.dev/pets/$slug/petjson.json'),
    zipUrl: Uri.parse('https://assets.petdex.dev/pets/$slug/zip.zip'),
  );

  @override
  Future<List<PetdexRemotePet>> fetchManifest() async {
    manifestReads++;
    if (offlineFirst > 0) {
      offlineFirst--;
      throw PetdexRemoteException('fallo de red', offline: true);
    }
    if (broken) throw PetdexRemoteException('respuesta HTTP 503');
    return [
      _pet('boba', 'Boba', 'Ada', 'character'),
      _pet('chibi-zoro', 'Chibi Zoro', 'Lin', 'character'),
      _pet('nimbus', 'Nimbus', 'Petdex', 'creature'),
    ];
  }

  @override
  Future<Uint8List> downloadPetZip(PetdexRemotePet pet) async {
    zipDownloads++;
    throw PetdexRemoteException('not expected');
  }
}

SavedConnection get _connection => SavedConnection(
  id: 'conn-petdex',
  label: 'Test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'key',
  dashboardUrl: 'http://127.0.0.1:1',
);

const _bot = AgentProfile(
  name: 'builder',
  botModeUiMeta: {'title': 'Console Builder'},
);

Future<void> _pumpUi(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tapVisible(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _pumpUi(tester);
}

Widget _app({GlobalKey<NavigatorState>? nav, required Widget home}) =>
    MaterialApp(
      navigatorKey: nav,
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: home,
    );

void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The owner's path: Bots, a bot's card, its pencil (what Mission Control
/// opens for it), "Mascota".
Future<void> _openMascotaFromBotCard(
  WidgetTester tester, {
  required _Pets pets,
  required _Assets assets,
  _Petdex? petdex,
}) async {
  _tallView(tester);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    _app(
      nav: nav,
      home: BotProfileScreen(
        data: () =>
            const BotProfileData(profile: _bot, signal: BotFaceSignal.idle),
        machineLabel: 'homelab',
        onChat: () {},
        onRoutines: () {},
        onSoul: () {},
        onSkills: () {},
        onMemory: () {},
        onEditIdentity: () => nav.currentState!.push(
          MaterialPageRoute<bool>(
            builder: (_) => ProfileEditorScreen(
              connection: _connection,
              profile: _bot,
              gateway: assets,
              petService: ProfilePetService(pets),
              petVisualMaterializer: _Materializer(),
              petdexService: petdex,
            ),
          ),
        ),
      ),
    ),
  );
  await _pumpUi(tester);
  await tester.tap(find.byKey(const ValueKey('bot-profile-edit-identity')));
  await _pumpUi(tester);
  await _tapVisible(tester, const ValueKey('profile-editor-identity-row'));
  await _tapVisible(tester, const ValueKey('profile-editor-mode-pet'));
}

Future<void> _openMascotaFromCreate(
  WidgetTester tester, {
  required _Pets pets,
  required _Assets assets,
  required _Creation creation,
  _Petdex? petdex,
}) async {
  _tallView(tester);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(_app(nav: nav, home: const Scaffold()));
  unawaited(
    nav.currentState!.push(
      MaterialPageRoute<String>(
        builder: (_) => BotCreateScreen(
          connection: _connection,
          existing: const {'default'},
          gateway: creation,
          assetsGateway: assets,
          petService: ProfilePetService(pets),
          petVisualMaterializer: _Materializer(),
          modelOptionsLoader: (_) async => const [],
          petdexService: petdex,
        ),
      ),
    ),
  );
  await _pumpUi(tester);
  await _tapVisible(tester, const ValueKey('bot-create-identity-row'));
  await _tapVisible(tester, const ValueKey('bot-create-mode-pet'));
}

/// In the open catalogue: search "zoro", open the one result and use it.
Future<void> _searchAndUseZoro(WidgetTester tester) async {
  expect(find.byType(PetdexGalleryScreen), findsOneWidget);
  expect(find.text('3 mascotas'), findsOneWidget);
  await tester.enterText(find.byType(TextField), 'zoro');
  await _pumpUi(tester);
  expect(find.text('1 mascota'), findsOneWidget);
  expect(find.text('Boba'), findsNothing);
  await tester.tap(find.text('Chibi Zoro'));
  await _pumpUi(tester);
  expect(find.text('Usar esta mascota'), findsOneWidget);
  expect(find.text('Instalar mascota'), findsNothing);
  await tester.tap(find.byKey(const ValueKey('petdex-detail-action')));
  await _pumpUi(tester);
  expect(find.byType(PetdexGalleryScreen), findsNothing);
}

const _zoroSheet = 'https://assets.petdex.dev/pets/chibi-zoro/sprite.webp';

void main() {
  group('a bot\'s card, Mascota', () {
    testWidgets('shows the pets it has and the way into Petdex', (
      tester,
    ) async {
      await _openMascotaFromBotCard(tester, pets: _Pets(), assets: _Assets());

      expect(
        find.byKey(const ValueKey('profile-editor-sprite-boba')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-petdex')),
        findsOneWidget,
      );
    });

    testWidgets('Petdex: search, use one, and the bot is saved with it', (
      tester,
    ) async {
      final pets = _Pets();
      final assets = _Assets();
      final petdex = _Petdex();
      await _openMascotaFromBotCard(
        tester,
        pets: pets,
        assets: assets,
        petdex: petdex,
      );

      await _tapVisible(tester, const ValueKey('profile-editor-petdex'));
      await _searchAndUseZoro(tester);

      // Back on the bot, with that mascot chosen and still to be saved.
      expect(
        find.byKey(const ValueKey('profile-editor-sprite-chibi-zoro')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-sprite-boba')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-dirty')),
        findsOneWidget,
      );
      expect(pets.thumbs, contains(('chibi-zoro', _zoroSheet)));
      expect(pets.selected, isEmpty);

      await tester.tap(find.byKey(const ValueKey('profile-editor-save')));
      await _pumpUi(tester);

      // Hermes installs it in the bot's own profile; the device stores
      // nothing and no other profile is touched.
      expect(pets.selected, [('builder', 'chibi-zoro')]);
      expect(
        assets.identities.single,
        isA<PetSpriteIdentity>().having((i) => i.slug, 'slug', 'chibi-zoro'),
      );
      expect(petdex.manifestReads, 1);
      expect(petdex.zipDownloads, 0);
      expect(find.byType(ProfileEditorScreen), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('leaving Petdex without choosing changes nothing', (
      tester,
    ) async {
      final pets = _Pets();
      await _openMascotaFromBotCard(
        tester,
        pets: pets,
        assets: _Assets(),
        petdex: _Petdex(),
      );
      await _tapVisible(tester, const ValueKey('profile-editor-petdex'));
      expect(find.byType(PetdexGalleryScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _pumpUi(tester);

      expect(find.byType(PetdexGalleryScreen), findsNothing);
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-editor-sprite-chibi-zoro')),
        findsNothing,
      );
      expect(pets.selected, isEmpty);
    });

    testWidgets('a list that did not load says so, with a retry', (
      tester,
    ) async {
      final pets = _Pets(galleryFails: 1);
      await _openMascotaFromBotCard(tester, pets: pets, assets: _Assets());

      expect(
        find.text('Esta instalación de Hermes no admite sprites por perfil.'),
        findsNothing,
      );
      expect(find.text('No se pudo cargar la lista.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-editor-petdex')),
        findsOneWidget,
      );
      await _tapVisible(tester, const ValueKey('profile-editor-pets-retry'));
      expect(pets.galleryCalls, 2);
      expect(find.text('No se pudo cargar la lista.'), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-editor-sprite-boba')),
        findsOneWidget,
      );
    });

    testWidgets('a profile without pets says so; Petdex is still there', (
      tester,
    ) async {
      final pets = _Pets(
        gallery: const ProfilePetGallery(enabled: false, active: '', pets: []),
      );
      await _openMascotaFromBotCard(tester, pets: pets, assets: _Assets());

      expect(find.text('No hay sprites disponibles.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-editor-pets-retry')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-petdex')),
        findsOneWidget,
      );
    });

    testWidgets('a Hermes without pets per profile offers neither', (
      tester,
    ) async {
      final pets = _Pets(
        galleryFails: 1,
        error: const TuiGatewayRpcError(
          'pet.gallery',
          'Method not found',
          code: -32601,
        ),
      );
      await _openMascotaFromBotCard(tester, pets: pets, assets: _Assets());

      expect(
        find.text('Esta instalación de Hermes no admite sprites por perfil.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('profile-editor-petdex')), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-editor-pets-retry')),
        findsNothing,
      );
    });

    testWidgets('Petdex out of reach says so; the retry loads it', (
      tester,
    ) async {
      final petdex = _Petdex(offlineFirst: 1);
      await _openMascotaFromBotCard(
        tester,
        pets: _Pets(),
        assets: _Assets(),
        petdex: petdex,
      );
      await _tapVisible(tester, const ValueKey('profile-editor-petdex'));

      expect(find.text('Sin conexión con Petdex.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('petdex-retry')));
      await _pumpUi(tester);
      expect(find.text('Sin conexión con Petdex.'), findsNothing);
      expect(find.text('3 mascotas'), findsOneWidget);
      expect(petdex.manifestReads, 2);
    });

    testWidgets('Petdex answering badly says the catalogue did not load', (
      tester,
    ) async {
      await _openMascotaFromBotCard(
        tester,
        pets: _Pets(),
        assets: _Assets(),
        petdex: _Petdex(broken: true),
      );
      await _tapVisible(tester, const ValueKey('profile-editor-petdex'));

      expect(
        find.text('No se pudo cargar el catálogo de Petdex.'),
        findsOneWidget,
      );
      expect(find.text('Sin conexión con Petdex.'), findsNothing);
      expect(find.byKey(const ValueKey('petdex-retry')), findsOneWidget);
    });

    testWidgets('a search that finds nothing says so and can be cleared', (
      tester,
    ) async {
      await _openMascotaFromBotCard(
        tester,
        pets: _Pets(),
        assets: _Assets(),
        petdex: _Petdex(),
      );
      await _tapVisible(tester, const ValueKey('profile-editor-petdex'));
      await tester.enterText(find.byType(TextField), 'dragón');
      await _pumpUi(tester);

      expect(find.text('Sin resultados.'), findsOneWidget);
      await tester.tap(find.text('Limpiar filtros'));
      await _pumpUi(tester);
      expect(find.text('3 mascotas'), findsOneWidget);
    });
  });

  group('a new bot, Mascota', () {
    testWidgets('shows the pets it has and the way into Petdex', (
      tester,
    ) async {
      await _openMascotaFromCreate(
        tester,
        pets: _Pets(),
        assets: _Assets(),
        creation: _Creation(),
      );

      expect(
        find.byKey(const ValueKey('bot-create-sprite-boba')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('bot-create-petdex')), findsOneWidget);
    });

    testWidgets('Petdex: search, use one, and the bot is created with it', (
      tester,
    ) async {
      final pets = _Pets();
      final assets = _Assets();
      final creation = _Creation();
      final petdex = _Petdex();
      await _openMascotaFromCreate(
        tester,
        pets: pets,
        assets: assets,
        creation: creation,
        petdex: petdex,
      );

      await _tapVisible(tester, const ValueKey('bot-create-petdex'));
      await _searchAndUseZoro(tester);

      expect(
        find.byKey(const ValueKey('bot-create-sprite-chibi-zoro')),
        findsOneWidget,
      );
      expect(pets.thumbs, contains(('chibi-zoro', _zoroSheet)));
      expect(pets.selected, isEmpty);

      await tester.ensureVisible(find.byKey(const ValueKey('bot-create-name')));
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('bot-create-name')),
          matching: find.byType(TextField),
        ),
        'zoro-bot',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
      await _pumpUi(tester);

      expect(creation.created, ['zoro-bot']);
      expect(pets.selected, [('zoro-bot', 'chibi-zoro')]);
      expect(
        assets.identities.single,
        isA<PetSpriteIdentity>().having((i) => i.slug, 'slug', 'chibi-zoro'),
      );
      expect(petdex.manifestReads, 1);
      expect(petdex.zipDownloads, 0);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a list that did not load says so, with a retry', (
      tester,
    ) async {
      final pets = _Pets(galleryFails: 1);
      await _openMascotaFromCreate(
        tester,
        pets: pets,
        assets: _Assets(),
        creation: _Creation(),
      );

      expect(find.text('No se pudo cargar la lista.'), findsOneWidget);
      expect(find.byKey(const ValueKey('bot-create-petdex')), findsOneWidget);
      await _tapVisible(tester, const ValueKey('bot-create-pets-retry'));
      expect(pets.galleryCalls, 2);
      expect(
        find.byKey(const ValueKey('bot-create-sprite-boba')),
        findsOneWidget,
      );
    });
  });

  // Mascotas opens the same catalogue to install on the device: that is as
  // it was.
  testWidgets('from Mascotas the catalogue still installs', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _tallView(tester);
    final controller = CompanionController(
      _NoPets(),
      await CompanionPreferences.load(),
    );
    await controller.init();
    await tester.pumpWidget(
      _app(
        home: PetdexGalleryScreen(controller: controller, service: _Petdex()),
      ),
    );
    await _pumpUi(tester);
    await tester.tap(find.text('Chibi Zoro'));
    await _pumpUi(tester);

    expect(find.text('Instalar mascota'), findsOneWidget);
    expect(find.text('Usar esta mascota'), findsNothing);
  });
}

class _NoPets extends CompanionRepository {
  @override
  Future<List<Companion>> loadAll() async => const [];
}
