import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/render/spritesheet_renderer.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/services/profile_pet_visual_adapter.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';

const _imageDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const _otherImageDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _FakePetVisualMaterializer implements ProfilePetVisualMaterializer {
  _FakePetVisualMaterializer({this.log, this.avatarDataUri = _imageDataUri});

  final List<String>? log;
  final String avatarDataUri;
  int calls = 0;

  @override
  Future<ProfilePetVisual> materialize(
    ProfilePetInfo info, {
    required String connectionId,
    required String profileId,
  }) async {
    calls++;
    log?.add('materialize-pet');
    final file = File(
      '${Directory.systemTemp.path}/hermes-pet-$connectionId.png',
    );
    if (!file.existsSync()) {
      file.writeAsBytesSync(base64Decode(_imageDataUri.split(',').last));
    }
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
      avatar: AgentProfileAvatar.fromDataUri(avatarDataUri),
    );
  }
}

class _FakeAssetsGateway implements HermesDesktopProfileAssetsGateway {
  _FakeAssetsGateway({
    this.avatar,
    this.log,
    this.failClear = false,
    this.failSet = false,
    this.saveGate,
  });

  final AgentProfileAvatar? avatar;
  final List<String>? log;
  final bool failClear;
  final bool failSet;
  final Completer<void>? saveGate;
  final List<Map<String, Object?>> savedMeta = [];
  final List<String> avatars = [];
  final List<String> cleared = [];

  @override
  Future<AgentProfileAvatar?> profileAvatar(String profileName) async => avatar;

  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    BotVisualIdentity? identity,
  }) async {
    log?.add('save');
    savedMeta.add({
      'profile': profile,
      'title': title,
      'shape': shape,
      'colorHex': colorHex,
      'identity': identity,
    });
    await saveGate?.future;
  }

  @override
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  }) async {
    log?.add('set-avatar');
    if (failSet) throw const TuiGatewayRpcError('profiles.set_asset', 'failed');
    avatars.add(dataUri);
  }

  @override
  Future<void> clearProfileAvatar(String profile) async {
    log?.add('clear-avatar');
    if (failClear) {
      throw const TuiGatewayRpcError('profiles.set_asset', 'failed');
    }
    cleared.add(profile);
  }
}

class _FakePetGateway implements HermesDesktopPetGateway {
  _FakePetGateway({
    this.active = '',
    this.enabled = false,
    this.log,
    this.disableResult = true,
  });

  String active;
  bool enabled;
  final List<String>? log;
  final bool disableResult;
  final List<String> selected = [];
  final List<String> selectedProfiles = [];
  final List<String> infoProfiles = [];
  final List<String> galleryProfiles = [];
  int disableCalls = 0;

  ProfilePetGallery get galleryPayload => ProfilePetGallery(
    enabled: enabled,
    active: active,
    pets: const [
      ProfilePetGalleryEntry(
        slug: 'nimbus',
        displayName: 'Nimbus',
        installed: true,
      ),
      ProfilePetGalleryEntry(slug: 'pixel', displayName: 'Pixel'),
    ],
  );

  @override
  Stream<TuiGatewayEvent> get events => const Stream.empty();

  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async {
    infoProfiles.add(profile);
    return enabled
        ? ProfilePetInfo(enabled: true, slug: active)
        : ProfilePetInfo.disabled;
  }

  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async {
    galleryProfiles.add(profile);
    return galleryPayload;
  }

  @override
  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  }) async => _imageDataUri;

  @override
  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  }) async {
    log?.add('select-pet');
    selected.add(slug);
    selectedProfiles.add(profile);
    active = slug;
    enabled = true;
    return ProfilePetSelection(slug: slug, displayName: slug);
  }

  @override
  Future<bool> profilePetDisable({String profile = ''}) async {
    log?.add('disable-pet');
    disableCalls++;
    if (disableResult) {
      active = '';
      enabled = false;
    }
    return disableResult;
  }
}

SavedConnection get _connection => SavedConnection(
  id: 'conn-test',
  label: 'Test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'key',
  dashboardUrl: 'http://127.0.0.1:1',
);

AgentProfile _profile({
  String name = 'infra',
  bool hasAvatar = false,
  Map<String, dynamic> botMeta = const {},
}) => AgentProfile.fromJson({
  'name': name,
  'has_avatar': hasAvatar,
  'ui_meta': {'hermes-bots': botMeta},
});

Future<void> _pumpEditor(
  WidgetTester tester, {
  required _FakeAssetsGateway assets,
  _FakePetGateway? pets,
  AgentProfile? profile,
  ProfileEditorImagePicker? imagePicker,
  ProfilePetVisualMaterializer? petVisualMaterializer,
  Size size = const Size(1000, 2600),
  double textScale = 1,
  double keyboardInset = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-editor'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ProfileEditorScreen(
                  connection: _connection,
                  profile: profile ?? _profile(),
                  gateway: assets,
                  petService: ProfilePetService(pets ?? _FakePetGateway()),
                  imagePicker: imagePicker,
                  imageNormalizer: (_) async =>
                      AgentProfileAvatar.fromDataUri(_imageDataUri),
                  petVisualMaterializer:
                      petVisualMaterializer ?? _FakePetVisualMaterializer(),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-editor')));
  // La preview Blobatar tiene motion continuo opt-in; avanzar la transición
  // de ruta de forma acotada evita esperar a que un ticker infinito termine.
  await _pumpUi(tester);
}

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
  await tester.pump();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('profile-editor-save')));
  await _pumpUi(tester);
}

void main() {
  testWidgets(
    'Blobatar guardado manda sobre una mascota activa hasta elegirla',
    (tester) async {
      final log = <String>[];
      final assets = _FakeAssetsGateway(log: log);
      final pets = _FakePetGateway(active: 'nimbus', enabled: true, log: log);
      await _pumpEditor(
        tester,
        assets: assets,
        pets: pets,
        petVisualMaterializer: _FakePetVisualMaterializer(log: log),
        profile: _profile(
          name: 'default',
          botMeta: const {
            'shape': 'blobatar:default:organic',
            'imageKind': 'shape',
            'custom': true,
          },
        ),
      );

      expect(
        find.byKey(const ValueKey('profile-editor-blobatar-organic')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-sprite-nimbus')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-clean')),
        findsOneWidget,
      );

      log.clear();
      await _tapVisible(tester, const ValueKey('profile-editor-mode-pet'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('profile-editor-sprite-nimbus')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-dirty')),
        findsOneWidget,
      );
      await _save(tester);

      expect(log, ['select-pet', 'materialize-pet', 'set-avatar', 'save']);
      expect(pets.galleryProfiles, ['default']);
      expect(pets.selectedProfiles, ['default']);
      expect(pets.infoProfiles, isNotEmpty);
      expect(pets.infoProfiles, everyElement('default'));
      expect(assets.savedMeta.single['identity'], isA<PetSpriteIdentity>());
    },
  );

  testWidgets('mascota sin avatar persistido requiere volver a guardarse', (
    tester,
  ) async {
    final log = <String>[];
    final assets = _FakeAssetsGateway(log: log);
    final pets = _FakePetGateway(active: 'nimbus', enabled: true, log: log);
    await _pumpEditor(
      tester,
      assets: assets,
      pets: pets,
      petVisualMaterializer: _FakePetVisualMaterializer(log: log),
      profile: _profile(
        name: 'default',
        botMeta: const {'imageKind': 'photo', 'custom': true},
      ),
    );

    expect(
      find.byKey(const ValueKey('profile-editor-blobatar-auto')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-sprite-nimbus')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('profile-editor-clean')), findsOneWidget);

    log.clear();
    await _tapVisible(tester, const ValueKey('profile-editor-mode-pet'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);
    await _save(tester);

    expect(log, ['select-pet', 'materialize-pet', 'set-avatar', 'save']);
    expect(pets.selectedProfiles, ['default']);
    expect(assets.savedMeta.single['identity'], isA<PetSpriteIdentity>());
  });

  testWidgets('muestra un selector único y el Guardar queda fijo', (
    tester,
  ) async {
    final assets = _FakeAssetsGateway();
    await _pumpEditor(tester, assets: assets);

    expect(
      find.byKey(const ValueKey('profile-editor-mode-pet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-mode-image')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-mode-face')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-face-classic')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-shape-squircle')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-color-#8b5cf6')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-blobatar-auto')),
      findsOneWidget,
    );
    final previewFace = tester.widget<HermesBotFace>(
      find.descendant(
        of: find.byKey(const ValueKey('profile-editor-preview')),
        matching: find.byType(HermesBotFace),
      ),
    );
    final tileFace = tester.widget<HermesBotFace>(
      find.descendant(
        of: find.byKey(const ValueKey('profile-editor-blobatar-auto')),
        matching: find.byType(HermesBotFace),
      ),
    );
    expect(previewFace.animate, isTrue);
    expect(tileFace.animate, isFalse);
    expect(
      find.byKey(const ValueKey('profile-editor-fixed-save')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('profile-editor-clean')), findsOneWidget);

    await _tapVisible(tester, const ValueKey('profile-editor-mode-pet'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile-editor-sprite-nimbus')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-blobatar-auto')),
      findsNothing,
    );

    await _tapVisible(tester, const ValueKey('profile-editor-mode-image'));
    expect(
      find.byKey(const ValueKey('profile-editor-pick-image')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-sprite-nimbus')),
      findsNothing,
    );
  });

  testWidgets('cara Blobatar desactiva pet, limpia avatar y guarda identity', (
    tester,
  ) async {
    final log = <String>[];
    final assets = _FakeAssetsGateway(log: log);
    final pets = _FakePetGateway(log: log);
    await _pumpEditor(tester, assets: assets, pets: pets);

    await _tapVisible(tester, const ValueKey('profile-editor-mode-face'));
    await _tapVisible(tester, const ValueKey('profile-editor-blobatar-sun'));
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);
    await _save(tester);

    expect(log, ['disable-pet', 'save']);
    final identity = assets.savedMeta.single['identity'];
    expect(identity, isA<ProceduralFaceIdentity>());
    expect((identity! as ProceduralFaceIdentity).shapeWire, 'blobatar::sun');
    expect(find.byType(ProfileEditorScreen), findsNothing);
  });

  testWidgets(
    'cara legacy abre como Blobatar sin RPC y migra al guardado explícito',
    (tester) async {
      final log = <String>[];
      final assets = _FakeAssetsGateway(log: log);
      final pets = _FakePetGateway(log: log);
      await _pumpEditor(
        tester,
        assets: assets,
        pets: pets,
        profile: _profile(
          botMeta: const {
            'shape': 'cloud',
            'color': '#38bdf8',
            'imageKind': 'shape',
          },
        ),
      );

      expect(log, isEmpty);
      expect(assets.savedMeta, isEmpty);
      expect(
        find.byKey(const ValueKey('profile-editor-clean')),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<HermesBotFace>(find.byType(HermesBotFace))
            .every((face) => face.visual is HermesBlobatarFaceVisual),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('profile-editor-face-classic')),
        findsNothing,
      );
      expect(find.text('Clásica'), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'Legacy migrated');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('profile-editor-dirty')),
        findsOneWidget,
      );
      await _save(tester);

      expect(log, ['disable-pet', 'save']);
      final identity = assets.savedMeta.single['identity'];
      expect(identity, isA<ProceduralFaceIdentity>());
      final procedural = identity! as ProceduralFaceIdentity;
      expect(procedural.shapeWire, 'blobatar');
      expect(procedural.dormantColorHex, '#38bdf8');
      expect(assets.savedMeta.single['title'], 'Legacy migrated');
    },
  );

  testWidgets('mascota aplica select, frame raster y metadata en ese orden', (
    tester,
  ) async {
    final log = <String>[];
    final assets = _FakeAssetsGateway(log: log);
    final pets = _FakePetGateway(log: log);
    await _pumpEditor(
      tester,
      assets: assets,
      pets: pets,
      petVisualMaterializer: _FakePetVisualMaterializer(log: log),
    );

    await _tapVisible(tester, const ValueKey('profile-editor-mode-pet'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, const ValueKey('profile-editor-sprite-nimbus'));
    await _save(tester);

    expect(log, ['select-pet', 'materialize-pet', 'set-avatar', 'save']);
    expect(assets.avatars, [_imageDataUri]);
    final identity = assets.savedMeta.single['identity'];
    expect(identity, isA<PetSpriteIdentity>());
    expect((identity! as PetSpriteIdentity).slug, 'nimbus');
  });

  testWidgets(
    'mascota activa anima idle y candidata usa thumb sin seleccionar',
    (tester) async {
      final avatar = AgentProfileAvatar.fromDataUri(_imageDataUri);
      final assets = _FakeAssetsGateway(avatar: avatar);
      final pets = _FakePetGateway(active: 'nimbus', enabled: true);
      final materializer = _FakePetVisualMaterializer();
      await _pumpEditor(
        tester,
        assets: assets,
        pets: pets,
        profile: _profile(
          hasAvatar: true,
          botMeta: const {'imageKind': 'photo', 'custom': true},
        ),
        petVisualMaterializer: materializer,
      );

      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-editor-pet-animated-preview')),
        findsOneWidget,
      );
      expect(find.byType(SpritesheetRenderer), findsOneWidget);
      expect(pets.selected, isEmpty);

      await _tapVisible(tester, const ValueKey('profile-editor-sprite-pixel'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-editor-pet-static-preview')),
        findsOneWidget,
      );
      expect(find.byType(SpritesheetRenderer), findsNothing);
      expect(pets.selected, isEmpty);
    },
  );

  testWidgets('imagen valida raster y aplica disable, asset y metadata', (
    tester,
  ) async {
    final log = <String>[];
    final assets = _FakeAssetsGateway(log: log);
    final pets = _FakePetGateway(log: log);
    final bytes = base64Decode(_imageDataUri.split(',').last);
    await _pumpEditor(
      tester,
      assets: assets,
      pets: pets,
      imagePicker: () async =>
          XFile.fromData(bytes, mimeType: 'image/png', name: 'avatar.png'),
    );

    await _tapVisible(tester, const ValueKey('profile-editor-mode-image'));
    await _tapVisible(tester, const ValueKey('profile-editor-pick-image'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);
    await _save(tester);

    expect(log, ['disable-pet', 'set-avatar', 'save']);
    expect(assets.avatars.single, startsWith('data:image/png;base64,'));
    expect(assets.savedMeta.single['identity'], isA<ProfileImageIdentity>());
  });

  testWidgets(
    'pet y foto muestran conflicto y Usar imagen respeta precedencia',
    (tester) async {
      final log = <String>[];
      final avatar = AgentProfileAvatar.fromDataUri(_imageDataUri);
      final assets = _FakeAssetsGateway(avatar: avatar, log: log);
      final pets = _FakePetGateway(active: 'nimbus', enabled: true, log: log);
      await _pumpEditor(
        tester,
        assets: assets,
        pets: pets,
        profile: _profile(
          hasAvatar: true,
          botMeta: const {'imageKind': 'photo', 'custom': true},
        ),
        petVisualMaterializer: _FakePetVisualMaterializer(
          avatarDataUri: _otherImageDataUri,
        ),
      );

      expect(
        find.byKey(const ValueKey('profile-editor-pet-image-conflict')),
        findsOneWidget,
      );
      await _tapVisible(tester, const ValueKey('profile-editor-use-image'));
      await _save(tester);

      expect(log, ['disable-pet', 'save']);
      expect(assets.avatars, isEmpty);
      expect(assets.savedMeta.single['identity'], isA<ProfileImageIdentity>());
    },
  );

  testWidgets('pet propio no se anuncia como foto en conflicto', (
    tester,
  ) async {
    final avatar = AgentProfileAvatar.fromDataUri(_imageDataUri);
    final assets = _FakeAssetsGateway(avatar: avatar);
    final pets = _FakePetGateway(active: 'nimbus', enabled: true);
    await _pumpEditor(
      tester,
      assets: assets,
      pets: pets,
      profile: _profile(
        hasAvatar: true,
        botMeta: const {'imageKind': 'photo', 'custom': true},
      ),
      petVisualMaterializer: _FakePetVisualMaterializer(),
    );

    expect(
      find.byKey(const ValueKey('profile-editor-pet-image-conflict')),
      findsNothing,
    );
  });

  testWidgets('Back confirma cuando hay cambios sin guardar', (tester) async {
    final assets = _FakeAssetsGateway();
    await _pumpEditor(tester, assets: assets);

    await tester.enterText(find.byType(TextField).first, 'Infra Lead');
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await _pumpUi(tester);

    expect(find.text('¿Descartar cambios?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-editor-keep-editing')));
    await _pumpUi(tester);
    expect(find.byType(ProfileEditorScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('profile-editor-discard')));
    await _pumpUi(tester);
    expect(find.byType(ProfileEditorScreen), findsNothing);
  });

  testWidgets('Guardar es single-flight', (tester) async {
    final gate = Completer<void>();
    final assets = _FakeAssetsGateway(saveGate: gate);
    await _pumpEditor(tester, assets: assets);
    await tester.enterText(find.byType(TextField).first, 'Infra Lead');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('profile-editor-save')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('profile-editor-save')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(assets.savedMeta, hasLength(1));
    expect(find.text('Guardando…'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(assets.savedMeta, hasLength(1));
  });

  testWidgets('fallo parcial conserva dirty y expone estado incierto', (
    tester,
  ) async {
    final log = <String>[];
    final avatar = AgentProfileAvatar.fromDataUri(_imageDataUri);
    final assets = _FakeAssetsGateway(
      avatar: avatar,
      log: log,
      failClear: true,
      failSet: true,
    );
    final pets = _FakePetGateway(log: log);
    await _pumpEditor(
      tester,
      assets: assets,
      pets: pets,
      profile: _profile(hasAvatar: true),
    );

    await _tapVisible(tester, const ValueKey('profile-editor-mode-face'));
    await _tapVisible(tester, const ValueKey('profile-editor-blobatar-auto'));
    await _save(tester);

    expect(log, ['disable-pet', 'clear-avatar', 'set-avatar']);
    expect(find.byType(ProfileEditorScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-editor-uncertain')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsNothing);
  });

  testWidgets('pet.disable false no anuncia éxito ni limpia cambios', (
    tester,
  ) async {
    final log = <String>[];
    final assets = _FakeAssetsGateway(log: log);
    final pets = _FakePetGateway(log: log, disableResult: false);
    await _pumpEditor(tester, assets: assets, pets: pets);

    await _tapVisible(tester, const ValueKey('profile-editor-blobatar-auto'));
    await _save(tester);

    expect(log, ['disable-pet', 'clear-avatar', 'save', 'disable-pet']);
    expect(assets.savedMeta, hasLength(1));
    // La mutación no se confirmó: la compensación restaura la identidad
    // legacy previa aunque esa variante ya no se exponga en la UI.
    expect(assets.savedMeta.single['identity'], isA<ClassicFaceIdentity>());
    expect(
      find.byKey(const ValueKey('profile-editor-uncertain')),
      findsOneWidget,
    );
  });

  testWidgets('fallo de asset compensado conserva dirty sin falso éxito', (
    tester,
  ) async {
    final log = <String>[];
    final assets = _FakeAssetsGateway(log: log, failSet: true);
    final pets = _FakePetGateway(log: log);
    await _pumpEditor(
      tester,
      assets: assets,
      pets: pets,
      petVisualMaterializer: _FakePetVisualMaterializer(log: log),
    );

    await _tapVisible(tester, const ValueKey('profile-editor-mode-pet'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, const ValueKey('profile-editor-sprite-nimbus'));
    await _save(tester);

    expect(log, [
      'select-pet',
      'materialize-pet',
      'set-avatar',
      'clear-avatar',
      'save',
      'disable-pet',
    ]);
    expect(assets.savedMeta, hasLength(1));
    expect(
      find.byKey(const ValueKey('profile-editor-uncertain')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('profile-editor-dirty')), findsOneWidget);
  });

  testWidgets('320dp, texto 200% y teclado conservan CTA sin overflow', (
    tester,
  ) async {
    final assets = _FakeAssetsGateway();
    await _pumpEditor(
      tester,
      assets: assets,
      size: const Size(320, 720),
      textScale: 2,
      keyboardInset: 220,
    );
    await tester.enterText(find.byType(TextField).first, 'Infra Lead');
    await tester.pump();

    final save = find.byKey(const ValueKey('profile-editor-save'));
    expect(save, findsOneWidget);
    final rect = tester.getRect(save);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(720));
    expect(tester.takeException(), isNull);
  });
}
