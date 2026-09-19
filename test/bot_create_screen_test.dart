import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/services/profile_pet_visual_adapter.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';

const _imageDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

class _FakeCreationGateway implements HermesDesktopBotCreationGateway {
  _FakeCreationGateway({required this.log});

  final List<String> log;
  int createCalls = 0;
  final List<Map<String, Object?>> created = [];
  final List<Map<String, Object?>> stamped = [];

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
  }) async {
    createCalls++;
    log.add('create');
    created.add({
      'name': name,
      'cloneFrom': cloneFrom,
      'description': description,
      'soul': soul,
      'model': model,
      'provider': provider,
      'noSkills': noSkills,
      'shareAuth': shareAuth,
    });
  }

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
  }) async {
    log.add('stamp');
    stamped.add({
      'profile': profile,
      'title': title,
      'createdAtMs': createdAtMs,
      'identity': identity,
    });
  }

  @override
  Future<void> setProfileDisabledSkills({
    required String profile,
    required List<String> disabledSkills,
  }) async {}
}

class _FakeAssetsGateway implements HermesDesktopProfileAssetsGateway {
  _FakeAssetsGateway({
    required this.log,
    this.failSet = false,
    this.failClear = false,
  });

  final List<String> log;
  final bool failSet;
  final bool failClear;
  final List<Map<String, Object?>> saved = [];
  final List<String> avatars = [];

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
  }) async {
    log.add('save-identity');
    saved.add({'profile': profile, 'title': title, 'identity': identity});
  }

  @override
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  }) async {
    log.add('set-avatar');
    if (failSet) {
      throw const TuiGatewayRpcError('profiles.set_asset', 'failed');
    }
    avatars.add(dataUri);
  }

  @override
  Future<void> clearProfileAvatar(String profile) async {
    log.add('clear-avatar');
    if (failClear) {
      throw const TuiGatewayRpcError('profiles.set_asset', 'failed');
    }
  }
}

class _FakePetGateway implements HermesDesktopPetGateway {
  _FakePetGateway({required this.log});

  final List<String> log;
  String active = '';
  bool enabled = false;
  int selectCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => const Stream.empty();

  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async => enabled
      ? ProfilePetInfo(
          enabled: true,
          slug: active,
          spritesheetRevision: 'rev-1',
        )
      : ProfilePetInfo.disabled;

  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async => const ProfilePetGallery(
    enabled: false,
    active: '',
    pets: [
      ProfilePetGalleryEntry(
        slug: 'nimbus',
        displayName: 'Nimbus',
        installed: true,
      ),
      ProfilePetGalleryEntry(slug: 'pixel', displayName: 'Pixel'),
    ],
  );

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
    log.add('select-pet');
    selectCalls++;
    active = slug;
    enabled = true;
    return ProfilePetSelection(slug: slug);
  }

  @override
  Future<bool> profilePetDisable({String profile = ''}) async {
    log.add('disable-pet');
    active = '';
    enabled = false;
    return true;
  }
}

class _FakePetVisualMaterializer implements ProfilePetVisualMaterializer {
  _FakePetVisualMaterializer({required this.log});

  final List<String> log;
  int calls = 0;

  @override
  Future<ProfilePetVisual> materialize(
    ProfilePetInfo info, {
    required String connectionId,
    required String profileId,
  }) async {
    calls++;
    log.add('materialize-pet');
    final file = File(
      '${Directory.systemTemp.path}/hermes-create-$connectionId-$profileId.png',
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

SavedConnection get _connection => SavedConnection(
  id: 'conn-create',
  label: 'Test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'key',
  dashboardUrl: 'http://127.0.0.1:1',
);

Future<void> _pumpCreate(
  WidgetTester tester, {
  required _FakeCreationGateway creation,
  required _FakeAssetsGateway assets,
  required _FakePetGateway pets,
  required _FakePetVisualMaterializer materializer,
  BotCreateImagePicker? imagePicker,
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
            key: const ValueKey('open-create'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<String>(
                builder: (_) => BotCreateScreen(
                  connection: _connection,
                  existing: const {'default'},
                  gateway: creation,
                  assetsGateway: assets,
                  petService: ProfilePetService(pets),
                  petVisualMaterializer: materializer,
                  modelOptionsLoader: (_) async => const [],
                  imagePicker: imagePicker,
                  imageNormalizer: (_) async =>
                      AgentProfileAvatar.fromDataUri(_imageDataUri),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-create')));
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

Future<void> _enterName(WidgetTester tester, String name) async {
  await tester.ensureVisible(find.byKey(const ValueKey('bot-create-name')));
  await tester.pump();
  final field = find.descendant(
    of: find.byKey(const ValueKey('bot-create-name')),
    matching: find.byType(TextField),
  );
  await tester.enterText(field, name);
  await tester.pump();
}

void main() {
  testWidgets('selector único, cara controlada y Crear fijo', (tester) async {
    final log = <String>[];
    await _pumpCreate(
      tester,
      creation: _FakeCreationGateway(log: log),
      assets: _FakeAssetsGateway(log: log),
      pets: _FakePetGateway(log: log),
      materializer: _FakePetVisualMaterializer(log: log),
    );

    // "Identidad visual" es una fila colapsable de "Personalizar" (mockup
    // de crear/editar bot): hay que abrirla antes de tocar sus controles.
    await _tapVisible(tester, const ValueKey('bot-create-identity-row'));

    expect(find.byKey(const ValueKey('bot-create-mode-pet')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-create-mode-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-create-mode-face')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-create-face-classic')), findsNothing);
    expect(
      find.byKey(const ValueKey('bot-create-shape-squircle')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('bot-create-color-#8b5cf6')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('bot-create-blobatar-auto')),
      findsOneWidget,
    );
    final previewFace = tester.widget<HermesBotFace>(
      find.descendant(
        of: find.byKey(const ValueKey('bot-create-preview')),
        matching: find.byType(HermesBotFace),
      ),
    );
    final tileFace = tester.widget<HermesBotFace>(
      find.descendant(
        of: find.byKey(const ValueKey('bot-create-blobatar-auto')),
        matching: find.byType(HermesBotFace),
      ),
    );
    expect(previewFace.animate, isTrue);
    expect(tileFace.animate, isFalse);
    expect(find.byType(HermesBotFace), findsWidgets);
    expect(
      find.byKey(const ValueKey('bot-create-fixed-submit')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('bot-create-clean')), findsOneWidget);

    await _tapVisible(tester, const ValueKey('bot-create-mode-pet'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('bot-create-sprite-nimbus')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bot-create-blobatar-auto')),
      findsNothing,
    );
    expect(petsNeverSelected(log), isTrue);
  });

  testWidgets('crea primero y aplica Blobatar tipado antes de cerrar', (
    tester,
  ) async {
    final log = <String>[];
    final creation = _FakeCreationGateway(log: log);
    final assets = _FakeAssetsGateway(log: log);
    await _pumpCreate(
      tester,
      creation: creation,
      assets: assets,
      pets: _FakePetGateway(log: log),
      materializer: _FakePetVisualMaterializer(log: log),
    );

    await _enterName(tester, 'Infra Lead');
    await _tapVisible(tester, const ValueKey('bot-create-identity-row'));
    await _tapVisible(tester, const ValueKey('bot-create-blobatar-sun'));
    await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
    await tester.pumpAndSettle();

    expect(log, ['create', 'disable-pet', 'save-identity', 'stamp']);
    expect(creation.created.single['name'], 'infra-lead');
    final identity = assets.saved.single['identity'];
    expect(identity, isA<ProceduralFaceIdentity>());
    expect((identity! as ProceduralFaceIdentity).shapeWire, 'blobatar::sun');
    expect(find.byType(BotCreateScreen), findsNothing);
  });

  testWidgets('imagen valida raster tras profiles.create', (tester) async {
    final log = <String>[];
    final assets = _FakeAssetsGateway(log: log);
    final bytes = base64Decode(_imageDataUri.split(',').last);
    await _pumpCreate(
      tester,
      creation: _FakeCreationGateway(log: log),
      assets: assets,
      pets: _FakePetGateway(log: log),
      materializer: _FakePetVisualMaterializer(log: log),
      imagePicker: () async =>
          XFile.fromData(bytes, mimeType: 'image/png', name: 'avatar.png'),
    );

    await _enterName(tester, 'vision');
    await _tapVisible(tester, const ValueKey('bot-create-identity-row'));
    await _tapVisible(tester, const ValueKey('bot-create-mode-image'));
    await _tapVisible(tester, const ValueKey('bot-create-pick-image'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
    await tester.pumpAndSettle();

    expect(log, [
      'create',
      'disable-pet',
      'set-avatar',
      'save-identity',
      'stamp',
    ]);
    expect(assets.avatars, [_imageDataUri]);
    expect(assets.saved.single['identity'], isA<ProfileImageIdentity>());
  });

  testWidgets('mascota usa thumb solo en preview y materializa tras select', (
    tester,
  ) async {
    final log = <String>[];
    final pets = _FakePetGateway(log: log);
    final assets = _FakeAssetsGateway(log: log);
    final materializer = _FakePetVisualMaterializer(log: log);
    await _pumpCreate(
      tester,
      creation: _FakeCreationGateway(log: log),
      assets: assets,
      pets: pets,
      materializer: materializer,
    );

    await _enterName(tester, 'nimbus-bot');
    await _tapVisible(tester, const ValueKey('bot-create-identity-row'));
    await _tapVisible(tester, const ValueKey('bot-create-mode-pet'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, const ValueKey('bot-create-sprite-nimbus'));
    expect(pets.selectCalls, 0);
    expect(materializer.calls, 0);

    await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
    await tester.pumpAndSettle();

    expect(log, [
      'create',
      'select-pet',
      'materialize-pet',
      'set-avatar',
      'save-identity',
      'stamp',
    ]);
    expect(assets.avatars, [_imageDataUri]);
    expect(materializer.calls, 1);
  });

  testWidgets('estado incierto no cierra ni recrea el perfil al reintentar', (
    tester,
  ) async {
    final log = <String>[];
    final creation = _FakeCreationGateway(log: log);
    final bytes = base64Decode(_imageDataUri.split(',').last);
    await _pumpCreate(
      tester,
      creation: creation,
      assets: _FakeAssetsGateway(log: log, failSet: true, failClear: true),
      pets: _FakePetGateway(log: log),
      materializer: _FakePetVisualMaterializer(log: log),
      imagePicker: () async => XFile.fromData(bytes, name: 'avatar.png'),
    );

    await _enterName(tester, 'vision');
    await _tapVisible(tester, const ValueKey('bot-create-identity-row'));
    await _tapVisible(tester, const ValueKey('bot-create-mode-image'));
    await _tapVisible(tester, const ValueKey('bot-create-pick-image'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
    await tester.pumpAndSettle();

    expect(find.byType(BotCreateScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-create-uncertain')), findsOneWidget);
    expect(creation.createCalls, 1);

    await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
    await tester.pumpAndSettle();
    expect(creation.createCalls, 1);
  });

  testWidgets('Back confirma cambios y 320dp mantiene CTA con teclado', (
    tester,
  ) async {
    final log = <String>[];
    await _pumpCreate(
      tester,
      creation: _FakeCreationGateway(log: log),
      assets: _FakeAssetsGateway(log: log),
      pets: _FakePetGateway(log: log),
      materializer: _FakePetVisualMaterializer(log: log),
      size: const Size(320, 720),
      textScale: 2,
    );
    await _enterName(tester, 'infra');
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pump();

    final submit = find.byKey(const ValueKey('bot-create-submit'));
    final rect = tester.getRect(submit);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(720));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(BackButton));
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('bot-create-discard-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('bot-create-keep-editing')));
    await _pumpUi(tester);
    expect(find.byType(BotCreateScreen), findsOneWidget);
  });
}

bool petsNeverSelected(List<String> log) => !log.contains('select-pet');
