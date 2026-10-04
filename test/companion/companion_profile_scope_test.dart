import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

Companion _pet(
  String slug, {
  CompanionOrigin origin = CompanionOrigin.base,
  String? spritesheetAsset,
}) => Companion(
  slug: slug,
  name: slug,
  author: 'team',
  license: 'CC0-1.0',
  spritesheetAsset:
      spritesheetAsset ?? 'assets/companions/$slug/spritesheet.webp',
  frameWidth: 192,
  frameHeight: 208,
  cols: 8,
  rows: 9,
  fps: 8,
  states: const {
    CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 8, loop: true),
  },
  origin: origin,
);

// PNG 1x1 real: mantiene pequeños los payloads pero obliga al materializador a
// pasar por base64, magic bytes y dimensiones de imagen reales.
const _transparentPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
const _opaquePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

ProfilePetInfo _remotePet(
  String slug, {
  String revision = 'rev-1',
  String spritesheetBase64 = _transparentPngBase64,
  bool unchanged = false,
}) => ProfilePetInfo(
  enabled: true,
  slug: slug,
  displayName: slug,
  mime: 'image/png',
  spritesheetBase64: unchanged ? '' : spritesheetBase64,
  spritesheetRevision: revision,
  spritesheetUnchanged: unchanged,
  frameW: 1,
  frameH: 1,
  framesPerState: 1,
  framesByState: const {'idle': 1},
  framesByRow: const {'0': 1},
  loopMs: 1000,
  scale: 1,
  stateRows: const ['idle'],
);

/// Repo de prueba que evita la carga real de assets.
class _FakeRepo extends CompanionRepository {
  final List<Companion> _all;
  _FakeRepo(this._all, {Directory? root})
    : super(importedRootProvider: root == null ? null : () async => root);

  @override
  Future<List<Companion>> loadAll() async => _all;
}

/// Permite observar la frontera crítica del controller sin acoplar el test a
/// detalles de IO: mientras no termina la materialización, la selección previa
/// debe seguir siendo la efectiva y la persistida.
class _DelayedProfileRepo extends _FakeRepo {
  _DelayedProfileRepo(super.all, {required Directory super.root});

  final Completer<Companion> materialized = Completer<Companion>();
  final Completer<void> materializeStarted = Completer<void>();
  final Completer<void> materializeReturned = Completer<void>();
  var materializeCalls = 0;

  @override
  Future<Companion> materializeProfilePet(
    ProfilePetInfo info, {
    required String connectionId,
    required String profileId,
  }) async {
    materializeCalls++;
    if (!materializeStarted.isCompleted) materializeStarted.complete();
    final companion = await materialized.future;
    if (!materializeReturned.isCompleted) materializeReturned.complete();
    return companion;
  }

  @override
  Future<void> promoteProfilePetRevision({
    required String connectionId,
    required String profileId,
    required String slug,
    required String revision,
  }) async {}
}

class _DelayedAlphaProfileRepo extends _FakeRepo {
  _DelayedAlphaProfileRepo(super.all, {required Directory super.root});

  final Completer<Companion> alphaMaterialized = Completer<Companion>();
  final Completer<void> alphaStarted = Completer<void>();
  final Completer<void> alphaReturned = Completer<void>();
  var alphaMaterializeCalls = 0;

  @override
  Future<Companion> materializeProfilePet(
    ProfilePetInfo info, {
    required String connectionId,
    required String profileId,
  }) async {
    if (profileId != 'alpha') {
      return super.materializeProfilePet(
        info,
        connectionId: connectionId,
        profileId: profileId,
      );
    }
    alphaMaterializeCalls++;
    if (!alphaStarted.isCompleted) alphaStarted.complete();
    final companion = await alphaMaterialized.future;
    if (!alphaReturned.isCompleted) alphaReturned.complete();
    return companion;
  }

  @override
  Future<void> promoteProfilePetRevision({
    required String connectionId,
    required String profileId,
    required String slug,
    required String revision,
  }) async {
    if (profileId == 'alpha') return;
    return super.promoteProfilePetRevision(
      connectionId: connectionId,
      profileId: profileId,
      slug: slug,
      revision: revision,
    );
  }
}

class _TrackingProfileRepo extends _FakeRepo {
  _TrackingProfileRepo(super.all, {required Directory super.root});

  final StreamController<int> _completed = StreamController<int>.broadcast();
  var materializeCalls = 0;
  var completedMaterializations = 0;

  @override
  Future<Companion> materializeProfilePet(
    ProfilePetInfo info, {
    required String connectionId,
    required String profileId,
  }) async {
    materializeCalls++;
    try {
      return await super.materializeProfilePet(
        info,
        connectionId: connectionId,
        profileId: profileId,
      );
    } finally {
      completedMaterializations++;
      _completed.add(completedMaterializations);
    }
  }

  Future<void> waitForCompleted(int count) async {
    if (completedMaterializations >= count) return;
    await _completed.stream
        .firstWhere((completed) => completed >= count)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TestFailure(
            'materialización $count no terminó dentro del límite',
          ),
        );
  }
}

/// Gateway `pet.*` programable. Por defecto se comporta como un perfil sin
/// mascota en el servidor (`pet.info` → disabled).
class _FakePetGateway implements HermesDesktopPetGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  /// Respuesta de `pet.info` por perfil ('' = perfil por defecto).
  final Map<String, ProfilePetInfo> infoByProfile = {};

  /// Error a lanzar en TODOS los métodos (p. ej. -32601 de gateway antiguo).
  Object? error;

  Future<ProfilePetInfo> Function(String profile, String? knownRevision)?
  infoHandler;

  final List<({String profile, String slug})> selectCalls = [];
  final List<String> disableCalls = [];
  var infoCalls = 0;
  var thumbCalls = 0;
  final List<({String profile, String? knownRevision})> infoRequests = [];

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  void emitPetChanged() {
    _events.add(
      const TuiGatewayEvent(
        type: 'pet.changed',
        sessionId: '',
        payload: {'enabled': true},
      ),
    );
  }

  Future<void> close() => _events.close();

  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async {
    infoCalls++;
    infoRequests.add((profile: profile, knownRevision: knownRevision));
    final e = error;
    if (e != null) throw e;
    final handler = infoHandler;
    if (handler != null) return handler(profile, knownRevision);
    return infoByProfile[profile] ?? const ProfilePetInfo(enabled: false);
  }

  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async {
    final e = error;
    if (e != null) throw e;
    return const ProfilePetGallery(enabled: false, active: '', pets: []);
  }

  @override
  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  }) async {
    thumbCalls++;
    final e = error;
    if (e != null) throw e;
    return null;
  }

  @override
  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  }) async {
    final e = error;
    if (e != null) throw e;
    selectCalls.add((profile: profile, slug: slug));
    // El servidor real activa la mascota al seleccionarla (pet.select escribe
    // display.pet.slug + enabled=true).
    infoByProfile[profile] = ProfilePetInfo(enabled: true, slug: slug);
    return ProfilePetSelection(slug: slug);
  }

  @override
  Future<bool> profilePetDisable({String profile = ''}) async {
    final e = error;
    if (e != null) throw e;
    disableCalls.add(profile);
    infoByProfile[profile] = const ProfilePetInfo(enabled: false);
    return true;
  }
}

/// Controller ligado a un scope mutable (conexión + perfil) y a un servicio
/// `pet.*` construido sobre el gateway fake.
class _Harness {
  final connId = ValueNotifier<String?>('conn-1');
  final profile = ValueNotifier<String?>('alpha');
  final gateway = _FakePetGateway();
  late final ProfilePetService service = ProfilePetService(gateway);
  late final CompanionController controller;
  late final Directory root;
  late final CompanionRepository repository;

  Future<void> init(
    List<Companion> pets, {
    bool withService = true,
    CompanionRepository Function(Directory root)? repositoryBuilder,
  }) async {
    root = await Directory.systemTemp.createTemp('profile_pet_scope_test');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    repository = repositoryBuilder?.call(root) ?? _FakeRepo(pets, root: root);
    final prefs = await CompanionPreferences.load();
    controller = CompanionController(repository, prefs);
    addTearDown(() async {
      controller.dispose();
      await gateway.close();
    });
    controller.bindProfileScope(
      resolveScope: () {
        final id = connId.value;
        if (id == null) return null;
        return CompanionScope(id, profile.value ?? '');
      },
      resolvePetService: (_) => withService ? service : null,
      changes: Listenable.merge([connId, profile]),
    );
    await controller.init();
    await _settle();
  }

  /// Deja correr las resoluciones asíncronas (migración + `pet.info`).
  Future<void> _settle() => pumpEventQueue();

  Future<void> switchProfile(String name) async {
    profile.value = name;
    await _settle();
  }
}

Future<void> _waitForController(
  CompanionController controller,
  bool Function() condition, {
  required String reason,
}) async {
  if (condition()) return;
  final reached = Completer<void>();
  void observe() {
    if (condition() && !reached.isCompleted) reached.complete();
  }

  controller.addListener(observe);
  final waited = Stopwatch()..start();
  try {
    observe();
    await reached.future.timeout(
      const Duration(seconds: 5),
      // Name what the controller published so a timeout can be told apart
      // from a sync that settled on the wrong pet.
      onTimeout: () => throw TestFailure(
        '$reason (after ${waited.elapsedMilliseconds} ms: '
        'selected=${controller.selectedSlug}, '
        'active=${controller.activeCompanion?.slug}, '
        'origin=${controller.activeCompanion?.origin.name})',
      ),
    );
  } finally {
    controller.removeListener(observe);
  }
}

Future<void> _waitForNextControllerNotification(
  CompanionController controller, {
  required String reason,
}) async {
  final reached = Completer<void>();
  void observe() {
    if (!reached.isCompleted) reached.complete();
  }

  controller.addListener(observe);
  try {
    await reached.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TestFailure(reason),
    );
  } finally {
    controller.removeListener(observe);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'dos perfiles del mismo dispositivo tienen mascotas distintas',
    () async {
      final h = _Harness();
      // Sin mascota de perfil en el servidor → manda el espejo local scoped.
      await h.init([_pet('nimbus'), _pet('jinx')]);

      await h.controller.select('nimbus');
      expect(h.controller.activeCompanion?.slug, 'nimbus');

      await h.switchProfile('beta');
      expect(h.controller.selectedSlug, isNull); // perfil nuevo: sin selección
      expect(h.controller.activeCompanion, isNull); // → fallback Spark

      await h.controller.select('jinx');
      expect(h.controller.activeCompanion?.slug, 'jinx');

      await h.switchProfile('alpha');
      expect(h.controller.activeCompanion?.slug, 'nimbus');
    },
  );

  test('migración one-shot de la key global al perfil activo', () async {
    SharedPreferences.setMockInitialValues({
      CompanionPreferences.slugKey: 'nimbus',
    });
    final h = _Harness();
    await h.init([_pet('nimbus')]);

    expect(h.controller.selectedSlug, 'nimbus');
    final raw = await SharedPreferences.getInstance();
    expect(
      raw.getString(CompanionPreferences.scopedSlugKey('conn-1', 'alpha')),
      'nimbus',
    );
    // La global se conserva como fallback legado.
    final prefs = await CompanionPreferences.load();
    expect(prefs.selectedSlug, 'nimbus');

    // Otro perfil hereda el legado hasta tener selección propia.
    await h.switchProfile('beta');
    expect(h.controller.selectedSlug, 'nimbus');
  });

  test('sin gateway la escritura es local scoped, como antes', () async {
    final h = _Harness();
    await h.init([_pet('nimbus')], withService: false);

    await h.controller.select('nimbus');
    expect(h.controller.activeCompanion?.slug, 'nimbus');
    expect(h.gateway.infoCalls, 0);
    expect(h.gateway.selectCalls, isEmpty);

    final prefs = await CompanionPreferences.load();
    expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');
  });

  test(
    'fail-closed: gateway sin pet.* (-32601) conserva la selección local',
    () async {
      final h = _Harness();
      h.gateway.error = const TuiGatewayRpcError(
        'pet.info',
        'Method not found',
        code: -32601,
      );
      await h.init([_pet('nimbus'), _pet('jinx')]);

      await h.controller.select('nimbus');
      await pumpEventQueue();
      expect(h.controller.activeCompanion?.slug, 'nimbus');

      // La autoridad local no se ve alterada por la ausencia de pet.*.
      await h.switchProfile('beta');
      await h.controller.select('jinx');
      await h.switchProfile('alpha');
      expect(h.controller.activeCompanion?.slug, 'nimbus');
    },
  );

  test('con gateway, pet.info del perfil es la autoridad', () async {
    final h = _Harness();
    h.gateway.infoByProfile['alpha'] = const ProfilePetInfo(
      enabled: true,
      slug: 'nimbus',
      displayName: 'Nimbus',
    );
    await h.init([_pet('nimbus'), _pet('jinx')]);

    // El espejo local no tenía selección, pero el servidor sí → gana el
    // servidor y queda espejada en local scoped.
    expect(h.controller.activeCompanion?.slug, 'nimbus');
    final prefs = await CompanionPreferences.load();
    expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');

    // El otro perfil no tiene mascota en el servidor → espejo local (vacío).
    await h.switchProfile('beta');
    expect(h.controller.selectedSlug, isNull);
  });

  test(
    'pet.changed dispara re-lectura de pet.info del perfil activo',
    () async {
      final h = _Harness();
      h.gateway.infoByProfile['alpha'] = const ProfilePetInfo(
        enabled: true,
        slug: 'nimbus',
      );
      await h.init([_pet('nimbus'), _pet('jinx')]);
      expect(h.controller.activeCompanion?.slug, 'nimbus');

      // Otro cliente (Desktop) cambia la mascota del perfil: el broadcast llega
      // y el controller re-lee.
      h.gateway.infoByProfile['alpha'] = const ProfilePetInfo(
        enabled: true,
        slug: 'jinx',
      );
      final callsBefore = h.gateway.infoCalls;
      h.gateway.emitPetChanged();
      await _waitForController(
        h.controller,
        () => h.controller.activeCompanion?.slug == 'jinx',
        reason: 'pet.changed no actualizó la mascota activa desde pet.info',
      );

      expect(h.gateway.infoCalls, greaterThan(callsBefore));
      expect(h.controller.activeCompanion?.slug, 'jinx');
    },
  );

  test(
    'seleccionar con gateway aplica pet.select / pet.disable en el perfil',
    () async {
      final h = _Harness();
      await h.init([_pet('nimbus')]);

      await h.controller.select('nimbus');
      await pumpEventQueue();
      expect(h.gateway.selectCalls, [(profile: 'alpha', slug: 'nimbus')]);

      // Volver al Spark por defecto equivale a apagar la mascota del perfil.
      await h.controller.select(null);
      await pumpEventQueue();
      expect(h.gateway.disableCalls, ['alpha']);
      expect(h.controller.activeCompanion, isNull);
    },
  );

  test(
    'pet.thumb roto se cachea por conexión: un solo intento y un solo aviso',
    () async {
      // Gateways antiguos (< 0.20.3) rompen pet.thumb con StateError en cada
      // tile de la galería; el servicio lo trata como capacidad ausente.
      final gateway = _FakePetGateway()..error = StateError('old gateway');
      final service = ProfilePetService(gateway);

      expect(await service.thumbnail(slug: 'nimbus'), isNull);
      expect(await service.thumbnail(slug: 'jinx'), isNull);
      expect(await service.thumbnail(slug: 'pixel'), isNull);
      expect(gateway.thumbCalls, 1);
    },
  );

  test(
    'mantiene selección y preferencia anteriores hasta materializar el remoto',
    () async {
      final h = _Harness();
      late _DelayedProfileRepo repo;
      await h.init(
        [_pet('nimbus')],
        repositoryBuilder: (root) =>
            repo = _DelayedProfileRepo([_pet('nimbus')], root: root),
      );
      await h.controller.select('nimbus');
      h.gateway.infoByProfile['alpha'] = _remotePet('zoro');

      h.gateway.emitPetChanged();
      await repo.materializeStarted.future.timeout(const Duration(seconds: 5));
      expect(repo.materializeCalls, 1);
      expect(h.controller.selectedSlug, 'nimbus');
      expect(h.controller.activeCompanion?.slug, 'nimbus');
      final prefsBefore = await CompanionPreferences.load();
      expect(prefsBefore.selectedSlugFor('conn-1', 'alpha'), 'nimbus');

      repo.materialized.complete(
        _pet(
          'zoro',
          origin: CompanionOrigin.remote,
          spritesheetAsset: '${h.root.path}/zoro/spritesheet.png',
        ),
      );
      await _waitForController(
        h.controller,
        () => h.controller.activeCompanion?.slug == 'zoro',
        reason: 'el remoto materializado no llegó a ser la mascota activa',
      );

      expect(h.controller.selectedSlug, 'zoro');
      expect(h.controller.activeCompanion?.slug, 'zoro');
      final prefsAfter = await CompanionPreferences.load();
      expect(prefsAfter.selectedSlugFor('conn-1', 'alpha'), 'zoro');
    },
  );

  test(
    'selección explícita durante materialización pendiente no se pisa',
    () async {
      final h = _Harness();
      late _DelayedProfileRepo repo;
      await h.init(
        [_pet('nimbus'), _pet('jinx')],
        repositoryBuilder: (root) => repo = _DelayedProfileRepo([
          _pet('nimbus'),
          _pet('jinx'),
        ], root: root),
      );
      await h.controller.select('nimbus');
      h.gateway.infoByProfile['alpha'] = _remotePet('zoro');
      h.gateway.emitPetChanged();
      await repo.materializeStarted.future.timeout(const Duration(seconds: 5));

      final observed = <String?>[];
      void recordSelection() => observed.add(h.controller.selectedSlug);
      h.controller.addListener(recordSelection);
      addTearDown(() => h.controller.removeListener(recordSelection));

      await h.controller.select('jinx');
      repo.materialized.complete(
        _pet(
          'zoro',
          origin: CompanionOrigin.remote,
          spritesheetAsset: '${h.root.path}/zoro/spritesheet.png',
        ),
      );
      await repo.materializeReturned.future.timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(h.controller.selectedSlug, 'jinx');
      expect(h.controller.activeCompanion?.slug, 'jinx');
      expect(observed, isNot(contains('zoro')));
      final prefs = await CompanionPreferences.load();
      expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'jinx');
    },
  );

  test('materializa un pet.info oficial antes de activar su slug', () async {
    final h = _Harness();
    await h.init([_pet('nimbus')]);
    await h.controller.select('nimbus');

    h.gateway.infoByProfile['alpha'] = _remotePet('zoro');
    h.gateway.emitPetChanged();
    await _waitForController(
      h.controller,
      () => h.controller.activeCompanion?.slug == 'zoro',
      reason: 'pet.info no terminó de materializar zoro',
    );

    final active = h.controller.activeCompanion;
    expect(active?.slug, 'zoro');
    expect(active?.origin, CompanionOrigin.remote);
    expect(active?.isFileBacked, isTrue);
    expect(active?.isProtected, isTrue);
    expect(File(active!.spritesheetAsset).existsSync(), isTrue);
    final prefs = await CompanionPreferences.load();
    expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'zoro');
  });

  test('payload remoto corrupto conserva activo, slug y preferencia', () async {
    final h = _Harness();
    await h.init([_pet('nimbus')]);
    await h.controller.select('nimbus');

    h.gateway.infoByProfile['alpha'] = _remotePet(
      'roto',
      revision: 'bad-rev',
      spritesheetBase64: '%%% no es base64 %%%',
    );
    h.gateway.emitPetChanged();
    await pumpEventQueue();

    expect(h.controller.selectedSlug, 'nimbus');
    expect(h.controller.activeCompanion?.slug, 'nimbus');
    final prefs = await CompanionPreferences.load();
    expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');
  });

  test('remoto válido se conserva ante reemplazo remoto corrupto', () async {
    final h = _Harness();
    late _TrackingProfileRepo repo;
    await h.init(
      [_pet('nimbus')],
      repositoryBuilder: (root) =>
          repo = _TrackingProfileRepo([_pet('nimbus')], root: root),
    );
    await h.controller.select('nimbus');

    h.gateway.infoByProfile['alpha'] = _remotePet('zoro', revision: 'zoro-1');
    h.gateway.emitPetChanged();
    await _waitForController(
      h.controller,
      () => h.controller.activeCompanion?.slug == 'zoro',
      reason: 'zoro no llegó a activarse antes del reemplazo corrupto',
    );
    final previous = h.controller.activeCompanion!;
    final previousPreference = await CompanionPreferences.load();
    expect(previousPreference.selectedSlugFor('conn-1', 'alpha'), 'zoro');

    h.gateway.infoByProfile['alpha'] = _remotePet(
      'yuki',
      revision: 'yuki-bad-1',
      spritesheetBase64: '%%% no es base64 %%%',
    );
    h.gateway.emitPetChanged();
    await repo.waitForCompleted(2);
    await pumpEventQueue();

    final current = h.controller.activeCompanion;
    expect(current?.slug, 'zoro');
    expect(current?.spritesheetAsset, previous.spritesheetAsset);
    expect(File(current!.spritesheetAsset).existsSync(), isTrue);
    final prefs = await CompanionPreferences.load();
    expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'zoro');
  });

  test(
    'spritesheetUnchanged reutiliza el cache revisionado sin payload',
    () async {
      final h = _Harness();
      await h.init([_pet('nimbus')]);
      await h.controller.select('nimbus');

      h.gateway.infoByProfile['alpha'] = _remotePet('zoro', revision: 'rev-1');
      h.gateway.emitPetChanged();
      await _waitForController(
        h.controller,
        () => h.controller.activeCompanion?.slug == 'zoro',
        reason: 'la primera revisión de zoro no llegó a activarse',
      );
      final first = h.controller.activeCompanion;
      expect(first?.slug, 'zoro');

      h.gateway.infoByProfile['alpha'] = _remotePet(
        'zoro',
        revision: 'rev-1',
        unchanged: true,
      );
      final synchronized = _waitForNextControllerNotification(
        h.controller,
        reason: 'la revisión unchanged no terminó de reutilizar la caché',
      );
      h.gateway.emitPetChanged();
      await synchronized;

      final second = h.controller.activeCompanion;
      expect(second?.slug, 'zoro');
      expect(second?.spritesheetAsset, first?.spritesheetAsset);
      expect(h.gateway.infoRequests.last.knownRevision, 'rev-1');
      expect(File(second!.spritesheetAsset).existsSync(), isTrue);
    },
  );

  test('misma slug con revisión nueva sustituye el atlas cacheado', () async {
    final h = _Harness();
    await h.init([_pet('nimbus')]);
    await h.controller.select('nimbus');

    h.gateway.infoByProfile['alpha'] = _remotePet('zoro', revision: 'rev-1');
    h.gateway.emitPetChanged();
    await _waitForController(
      h.controller,
      () => h.controller.activeCompanion?.slug == 'zoro',
      reason: 'la revisión inicial de zoro no llegó a activarse',
    );
    final firstPath = h.controller.activeCompanion!.spritesheetAsset;

    h.gateway.infoByProfile['alpha'] = _remotePet(
      'zoro',
      revision: 'rev-2',
      spritesheetBase64: _opaquePngBase64,
    );
    h.gateway.emitPetChanged();
    await _waitForController(
      h.controller,
      () {
        final active = h.controller.activeCompanion;
        return active?.slug == 'zoro' && active?.spritesheetAsset != firstPath;
      },
      reason: 'la revisión nueva de zoro no sustituyó el atlas anterior',
    );

    final second = h.controller.activeCompanion;
    expect(second?.slug, 'zoro');
    expect(second?.spritesheetAsset, isNot(firstPath));
    expect(
      File(second!.spritesheetAsset).readAsBytesSync(),
      base64Decode(_opaquePngBase64),
    );
  });

  test(
    'respuesta tardía de otro perfil no sustituye el activo actual',
    () async {
      final h = _Harness();
      await h.init([_pet('nimbus')]);
      await h.controller.select('nimbus');
      final lateAlpha = Completer<ProfilePetInfo>();
      h.gateway.infoHandler = (profile, _) {
        if (profile == 'alpha') return lateAlpha.future;
        return Future.value(_remotePet('beta-pet', revision: 'beta-1'));
      };

      h.gateway.emitPetChanged();
      await pumpEventQueue();
      expect(lateAlpha.isCompleted, isFalse);

      await h.switchProfile('beta');
      await _waitForController(
        h.controller,
        () => h.controller.activeCompanion?.slug == 'beta-pet',
        reason: 'beta-pet no llegó a activarse tras el cambio de perfil',
      );

      lateAlpha.complete(_remotePet('alpha-late', revision: 'alpha-late-1'));
      await pumpEventQueue();

      expect(h.controller.activeCompanion?.slug, 'beta-pet');
      expect(h.controller.selectedSlug, 'beta-pet');
      final prefs = await CompanionPreferences.load();
      expect(prefs.selectedSlugFor('conn-1', 'beta'), 'beta-pet');
    },
  );

  test('materialización tardía de alpha no contamina beta', () async {
    final h = _Harness();
    late _DelayedAlphaProfileRepo repo;
    await h.init(
      [_pet('nimbus')],
      repositoryBuilder: (root) =>
          repo = _DelayedAlphaProfileRepo([_pet('nimbus')], root: root),
    );
    await h.controller.select('nimbus');
    h.gateway.infoByProfile['alpha'] = _remotePet(
      'alpha-pet',
      revision: 'alpha-1',
    );
    h.gateway.emitPetChanged();
    await repo.alphaStarted.future.timeout(const Duration(seconds: 5));

    h.gateway.infoByProfile['beta'] = _remotePet(
      'beta-pet',
      revision: 'beta-1',
    );
    await h.switchProfile('beta');
    await _waitForController(
      h.controller,
      () => h.controller.activeCompanion?.slug == 'beta-pet',
      reason: 'beta-pet no llegó a activarse tras cambiar de perfil',
    );

    final observed = <String?>[];
    void recordSelection() => observed.add(h.controller.selectedSlug);
    h.controller.addListener(recordSelection);
    addTearDown(() => h.controller.removeListener(recordSelection));
    repo.alphaMaterialized.complete(
      _pet(
        'alpha-pet',
        origin: CompanionOrigin.remote,
        spritesheetAsset: '${h.root.path}/alpha-pet/spritesheet.png',
      ),
    );
    await repo.alphaReturned.future.timeout(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(repo.alphaMaterializeCalls, 1);
    expect(h.controller.selectedSlug, 'beta-pet');
    expect(h.controller.activeCompanion?.slug, 'beta-pet');
    expect(observed, isNot(contains('alpha-pet')));
    final prefs = await CompanionPreferences.load();
    expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');
    expect(prefs.selectedSlugFor('conn-1', 'beta'), 'beta-pet');
  });
}
