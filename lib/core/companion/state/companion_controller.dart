import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/profile_pet.dart';
import '../../models/profile_identity.dart';
import '../../services/profile_pet_service.dart';
import '../../widgets/mission_profile_avatar.dart';
import '../data/companion_import_service.dart';
import '../data/companion_preferences.dart';
import '../data/companion_repository.dart';
import '../hatch/hatch_provider.dart';
import '../hatch/hatch_service.dart';
import '../models/companion.dart';
import '../models/companion_display_settings.dart';
import '../models/companion_presence_level.dart';
import '../models/companion_scale.dart';

/// Ámbito (conexión, perfil) al que pertenece la selección de mascota. Las
/// mascotas nativas de Hermes viven en la config del perfil (`display.pet.*`),
/// así que la app guarda su espejo local con este mismo scope.
class CompanionScope {
  final String connId;

  /// Nombre del perfil activo; '' = perfil por defecto de la conexión.
  final String profileId;

  const CompanionScope(this.connId, this.profileId);
}

/// Whether the companion of [scope] is THIS chat's own companion (QA 9493):
/// same connection and same profile ('' and 'default' are the default
/// profile). Without a scope (legacy global companion) it belongs only to
/// the default chat, never to a bot or a named profile.
bool companionScopeMatchesChat(
  CompanionScope? scope, {
  required String connectionId,
  required String? profileName,
  required bool botSurface,
}) {
  String key(String? name) {
    final value = name?.trim() ?? '';
    return value.isEmpty ? 'default' : value;
  }

  if (scope == null) return !botSurface && profileName == null;
  return scope.connId == connectionId &&
      key(scope.profileId) == key(profileName);
}

/// Resuelve el ámbito actual, o `null` si no hay conexión activa (→
/// comportamiento global legado).
typedef CompanionScopeResolver = CompanionScope? Function();

/// Resuelve el servicio `pet.*` de una conexión, o `null` si no aplica (sin
/// gateway, instancia de solo lectura, etc.).
typedef ProfilePetServiceResolver = ProfilePetService? Function(String connId);

/// Caché de avatares de la instancia [connId], para pintar la foto del perfil
/// cuando no hay mascota.
typedef ProfileAvatarCacheResolver =
    MissionProfileAvatarCache? Function(String connId);

/// Estado de la galería de mascotas "Companion".
///
/// Mantiene la lista de mascotas disponibles (locales), el slug seleccionado y
/// el flag de activación, persistidos vía [CompanionPreferences]. Es una capa
/// puramente cosmética: no interactúa con voz ni runtime (FR-010).
///
/// Con [bindProfileScope] la selección pasa a ser **por perfil**: el espejo
/// local se guarda con scope `(connId, profileId)` y, cuando el gateway
/// soporta los RPCs nativos `pet.*`, el servidor es la autoridad (`pet.info`
/// al resolver + `pet.changed` como señal de re-lectura; `pet.select` /
/// `pet.disable` al elegir). Sin gateway o sin mascota de perfil en el
/// servidor manda el espejo local scoped. Sin mascota válida se pinta la cara
/// original del perfil ([scope] + [avatarCacheFor]).
class CompanionController extends ChangeNotifier {
  final CompanionRepository _repository;
  final CompanionPreferences _preferences;
  final CompanionImportService importService;
  final HatchService hatchService;

  /// Proveedor de generación ("Hatch") activo, o `null` si no hay ninguno
  /// disponible (→ la UI deriva al import de ZIP, US3). Inyectable para tests.
  final HatchProvider? hatchProvider;
  final bool appPet;
  final bool publishProfileIdentity;

  CompanionController(
    this._repository,
    this._preferences, {
    this.importService = const CompanionImportService(),
    this.hatchService = const HatchService(),
    this.hatchProvider,
    this.appPet = false,
    this.publishProfileIdentity = false,
  });

  /// Device-only app selection, seeded once from what the old floating pet
  /// showed. A remote atlas is pinned to that revision, never re-synced.
  Future<void> initAppFromProfile(CompanionController source) async {
    assert(appPet);
    // The raw stored choices, not the profile controller's getters: those
    // report a profile's identity, which no app setting switches off.
    final originalSlug = source._selectedSlug;
    final originalEnabled = source._enabled;
    final originalSize = source._sizeMultiplier;
    final originalScope = source._scope;
    final originalRevision = source._remoteCompanionRevision;
    final originalPet = source._legacyPet;
    final originalPresence = source._presence;
    _available = await _repository.loadAll();
    await _preferences.migrateAppPet(
      slug: originalSlug,
      enabled: originalEnabled,
      size: originalSize,
      presence: originalPresence,
      connection: originalScope?.connId,
      profile: originalScope?.profileId,
      revision: originalRevision,
    );
    _scope = null;
    _selectedSlug = _preferences.appSlug;
    _enabled = _preferences.appEnabled;
    _sizeMultiplier = _preferences.appSize;
    _scale = CompanionScale.values.reduce(
      (a, b) =>
          (a.multiplier - _sizeMultiplier).abs() <=
              (b.multiplier - _sizeMultiplier).abs()
          ? a
          : b,
    );
    _presence = _preferences.appPresence;
    final connection = _preferences.appSourceConnection;
    final profile = _preferences.appSourceProfile;
    final slug = _selectedSlug;
    if (originalPet?.slug == slug &&
        originalPet?.isRemote == true &&
        originalRevision == _preferences.appSourceRevision) {
      _remoteCompanion = originalPet;
      _remoteCompanionScope = null;
      _remoteCompanionRevision = originalRevision;
    } else if (connection != null &&
        profile != null &&
        slug != null &&
        slug.isNotEmpty) {
      final revision =
          _preferences.appSourceRevision ??
          await _repository.cachedProfilePetRevision(
            connectionId: connection,
            profileId: profile,
            slug: slug,
          );
      if (revision != null) {
        _remoteCompanion = await _repository.loadCachedProfilePet(
          connectionId: connection,
          profileId: profile,
          slug: slug,
          revision: revision,
        );
        _remoteCompanionScope = null;
        _remoteCompanionRevision = revision;
      }
    }
    _initialized = true;
    notifyListeners();
  }

  CompanionScopeResolver? _scopeResolver;
  ProfilePetServiceResolver? _petServiceResolver;
  Listenable? _scopeChanges;
  CompanionScope? _scope;

  /// The (connection, profile) this companion belongs to; null without an
  /// active connection (legacy global companion). Lets a chat tell its own
  /// profile's companion from another profile's.
  CompanionScope? get scope => _scope;
  ProfilePetService? _petService;
  StreamSubscription<void>? _petChangedSub;

  /// Época de resolución: las lecturas asíncronas (migración, `pet.info`) de
  /// un ámbito anterior se descartan al cambiar de conexión/perfil.
  int _resolutionEpoch = 0;

  /// Ordena también sincronizaciones concurrentes dentro del mismo scope.
  int _serverSyncGeneration = 0;

  /// Fotos de perfil por instancia para la cara que sustituye a la mascota.
  ProfileAvatarCacheResolver? _avatarCacheResolver;

  Companion? _remoteCompanion;
  CompanionScope? _remoteCompanionScope;
  String? _remoteCompanionRevision;

  List<Companion> _available = const [];
  bool _enabled = true;
  String? _selectedSlug;
  CompanionScale _scale = CompanionScale.medium;
  double _sizeMultiplier = CompanionDisplaySettings.defaultSizeMultiplier;
  CompanionPresenceLevel _presence = CompanionPresenceLevel.full;
  bool _legacyFullPresence = false;
  bool _initialized = false;

  /// Mascotas locales válidas disponibles para elegir.
  List<Companion> get available => List.unmodifiable(_available);

  /// Si la mascota está activada por el usuario. The controller that holds
  /// the profiles' identities ([publishProfileIdentity]) is never off: a
  /// profile's pet is its identity, not the app's floating mascot, and no
  /// app setting switches it off.
  bool get enabled => publishProfileIdentity || _enabled;

  /// Slug seleccionado (puede no resolver a una mascota válida).
  String? get selectedSlug => _selectedSlug;

  /// Preset de escala (S/M/L) aplicado al render de la mascota.
  CompanionScale get scale => _scale;

  /// Tamaño continuo aplicado al render de la mascota.
  double get sizeMultiplier => _sizeMultiplier;

  /// Velocidad de la mascota seleccionada. Cada slug conserva la suya.
  double get animationSpeed =>
      _preferences.animationSpeedFor(activeCompanion?.slug);

  /// Where the user wants the pet: off, only in the chat, or everywhere.
  /// The Mascotas screen and the floating mascot read this.
  CompanionPresenceLevel get presence =>
      publishProfileIdentity ? CompanionPresenceLevel.full : _presence;

  /// What the chats read. It is [presence], except while the presence is on
  /// and the profile has no pet of its own: then it is
  /// [CompanionPresenceLevel.ambient], and the chat's island keeps the face
  /// it always had instead of a stand-in. Whoever stored the old "Completa"
  /// keeps the stand-in he had.
  CompanionPresenceLevel get presenceLevel {
    final presence = this.presence;
    if (presence == CompanionPresenceLevel.off) return presence;
    if (_legacyFullPresence || activeCompanion != null) return presence;
    return CompanionPresenceLevel.ambient;
  }

  bool get isInitialized => _initialized;

  /// Caché de avatares de [connId] (foto del perfil), si la app la provee.
  MissionProfileAvatarCache? avatarCacheFor(String connId) =>
      _avatarCacheResolver?.call(connId);

  /// Mascota efectiva a renderizar, o `null` si debe usarse el fallback
  /// (la cara original del perfil): desactivada, sin selección, o slug
  /// inválido.
  Companion? get activeCompanion => enabled ? _materializedPet : null;

  /// The pet this controller stands for. The controller of the profiles'
  /// identities answers from [ProfileIdentities] (what the profile's own
  /// stores say), never from the device selection; the app's controller
  /// answers from its own device selection.
  Companion? get _materializedPet {
    if (!publishProfileIdentity) return _legacyPet;
    final scope = _scope;
    if (scope == null) return null;
    final pet = ProfileIdentities.instance.pet(scope.connId, scope.profileId);
    return pet != null && pet.isValid ? pet : null;
  }

  /// The device-side selection (slug mirror plus its cached atlas). For the
  /// profiles' controller it is only the record the app pet was migrated
  /// from; nothing draws it.
  Companion? get _legacyPet {
    if (_selectedSlug == null) return null;
    final remote = _remoteCompanion;
    if (remote != null &&
        _sameScope(_remoteCompanionScope, _scope) &&
        remote.slug == _selectedSlug &&
        remote.isValid) {
      return remote;
    }
    for (final companion in _available) {
      if (companion.slug == _selectedSlug && companion.isValid) {
        return companion;
      }
    }
    return null;
  }

  /// Carga las mascotas empaquetadas y la preferencia persistida.
  Future<void> init() async {
    _available = await _repository.loadAll();
    var epoch = _resolutionEpoch;
    while (!await _reloadScopeState(epoch)) {
      epoch = _resolutionEpoch;
    }
    _attachPetService();
    await _restoreCachedRemote(epoch);
    _presence = _preferences.presenceLevel;
    // The stand-in the old "Completa" kept for a profile without a pet is
    // the app pet's business; a profile without one draws its own face.
    _legacyFullPresence =
        !publishProfileIdentity && _preferences.presenceIsLegacyFull;
    _initialized = true;
    notifyListeners();
    // Revalida el scope y consulta la autoridad servidor sin bloquear la
    // primera pintura. También cubre un cambio ocurrido durante init().
    unawaited(_resolveScope());
  }

  /// Vincula el controller al perfil activo de la conexión. Sin binding se
  /// mantiene el comportamiento global legado. [changes] debe disparar al
  /// cambiar la conexión activa o su perfil; ante cada cambio se re-resuelve
  /// la mascota (espejo local scoped + `pet.info` cuando hay gateway).
  void bindProfileScope({
    required CompanionScopeResolver resolveScope,
    required ProfilePetServiceResolver resolvePetService,
    required Listenable changes,
    ProfileAvatarCacheResolver? resolveAvatarCache,
  }) {
    if (_scopeResolver != null) return; // binding único (singleton de app)
    _scopeResolver = resolveScope;
    _petServiceResolver = resolvePetService;
    _avatarCacheResolver = resolveAvatarCache;
    _scopeChanges = changes..addListener(_onScopeChanged);
    if (publishProfileIdentity) {
      ProfileIdentities.instance.addListener(notifyListeners);
    }
  }

  void _onScopeChanged() {
    unawaited(_resolveScope());
  }

  Future<void> _resolveScope() async {
    final epoch = ++_resolutionEpoch;
    _serverSyncGeneration++;
    if (!await _reloadScopeState(epoch)) return;
    _attachPetService();
    if (!_initialized) return;
    await _restoreCachedRemote(epoch);
    if (epoch != _resolutionEpoch) return;
    if (publishProfileIdentity) {
      // The profile's pet is read from the profile's own stores, not from
      // the device selection this controller mirrors.
      final scope = _scope;
      if (scope != null) {
        ProfileIdentities.instance.requestAfterPaint(
          scope.connId,
          scope.profileId,
        );
      }
      notifyListeners();
      return;
    }
    notifyListeners();
    await _syncWithServer(epoch);
  }

  /// Recarga la selección desde el espejo local del ámbito actual (o de las
  /// keys globales legadas cuando no hay binding/scope).
  Future<bool> _reloadScopeState(int epoch) async {
    final scope = _scopeResolver?.call();
    if (scope != null) {
      // Migración one-shot: la selección global previa se copia al scope del
      // perfil activo (las globales se conservan como fallback legado).
      await _preferences.migrateLegacyToScopeOnce(
        scope.connId,
        scope.profileId,
      );
    }
    if (epoch != _resolutionEpoch ||
        !_sameScope(scope, _scopeResolver?.call())) {
      return false;
    }

    final enabled = scope == null
        ? _preferences.enabled
        : _preferences.enabledFor(scope.connId, scope.profileId);
    final selectedSlug = scope == null
        ? _preferences.selectedSlug
        : _preferences.selectedSlugFor(scope.connId, scope.profileId);
    final scale = scope == null
        ? _preferences.scale
        : _preferences.scaleFor(scope.connId, scope.profileId);
    final sizeMultiplier = scope == null
        ? _preferences.sizeMultiplier
        : _preferences.sizeMultiplierFor(scope.connId, scope.profileId);

    // Publicación única: ninguna lectura de un perfil viejo puede mutar el
    // estado visible después de que el usuario haya cambiado de scope.
    if (!_sameScope(_remoteCompanionScope, scope)) {
      _remoteCompanion = null;
      _remoteCompanionScope = null;
      _remoteCompanionRevision = null;
    }
    _scope = scope;
    _enabled = enabled;
    _selectedSlug = selectedSlug;
    _scale = scale;
    _sizeMultiplier = sizeMultiplier;
    return true;
  }

  void _attachPetService() {
    final scope = _scope;
    final service = scope == null
        ? null
        : _petServiceResolver?.call(scope.connId);
    if (identical(service, _petService)) return;
    unawaited(_petChangedSub?.cancel());
    _petService = service;
    _petChangedSub = service?.petChanged.listen((_) => _onServerPetChanged());
  }

  void _onServerPetChanged() {
    if (publishProfileIdentity) {
      final scope = _scope;
      if (scope != null) ProfileIdentities.instance.refresh(scope.connId);
      return;
    }
    unawaited(_syncWithServer(_resolutionEpoch));
  }

  Future<void> _restoreCachedRemote(int epoch) async {
    final scope = _scope;
    final slug = _selectedSlug;
    if (scope == null || slug == null || slug.isEmpty) return;
    final revision = await _repository.cachedProfilePetRevision(
      connectionId: scope.connId,
      profileId: scope.profileId,
      slug: slug,
    );
    if (revision == null || epoch != _resolutionEpoch) return;
    final cached = await _repository.loadCachedProfilePet(
      connectionId: scope.connId,
      profileId: scope.profileId,
      slug: slug,
      revision: revision,
    );
    if (cached == null ||
        epoch != _resolutionEpoch ||
        !_sameScope(scope, _scope)) {
      return;
    }
    _remoteCompanion = cached;
    _remoteCompanionScope = scope;
    _remoteCompanionRevision = revision;
  }

  /// Cruza con `pet.info` del servidor como autoridad. Fail-closed: gateway
  /// sin `pet.*` o error → manda el espejo local. Si el perfil no tiene
  /// mascota activa en el servidor, también manda el espejo local scoped (la
  /// autoridad solo sobreescribe cuando el perfil TIENE mascota).
  Future<void> _syncWithServer(int epoch) async {
    final scope = _scope;
    final service = _petService;
    if (scope == null || service == null || !_initialized) return;
    final generation = ++_serverSyncGeneration;
    String? knownRevision;
    final selected = _selectedSlug;
    if (selected != null && selected.isNotEmpty) {
      if (_sameScope(_remoteCompanionScope, scope) &&
          _remoteCompanion?.slug == selected) {
        knownRevision = _remoteCompanionRevision;
      }
      knownRevision ??= await _repository.cachedProfilePetRevision(
        connectionId: scope.connId,
        profileId: scope.profileId,
        slug: selected,
      );
    }
    if (!_serverSyncIsCurrent(scope, epoch, generation)) return;

    var info = await service.activePet(
      profile: scope.profileId,
      knownRevision: knownRevision,
    );
    if (!_serverSyncIsCurrent(scope, epoch, generation) ||
        info == null ||
        !info.hasPet) {
      return;
    }

    Companion? candidate;
    try {
      candidate = await _candidateForServerInfo(info, scope);
      if (candidate == null && info.usesCachedSpritesheet) {
        // El índice decía que había caché, pero el fichero ya no es válido.
        // Repite una sola vez sin revisión para recuperar el payload completo.
        info = await service.activePet(profile: scope.profileId);
        if (!_serverSyncIsCurrent(scope, epoch, generation) ||
            info == null ||
            !info.hasPet) {
          return;
        }
        candidate = await _candidateForServerInfo(info, scope);
      }
    } catch (error) {
      debugPrint(
        '[companion] pet.info no se pudo materializar; se conserva el activo (${error.runtimeType})',
      );
      return;
    }
    if (candidate == null ||
        !candidate.isValid ||
        !_serverSyncIsCurrent(scope, epoch, generation)) {
      return;
    }

    if (candidate.isRemote) {
      try {
        await _repository.promoteProfilePetRevision(
          connectionId: scope.connId,
          profileId: scope.profileId,
          slug: info.slug,
          revision: info.spritesheetRevision,
        );
      } on CompanionImportException catch (error) {
        debugPrint(
          '[companion] revisión remota no promovida; se conserva el activo (${error.runtimeType})',
        );
        return;
      }
      if (!_serverSyncIsCurrent(scope, epoch, generation)) return;
    }

    await _preferences.setSelectedSlugFor(
      scope.connId,
      scope.profileId,
      info.slug,
    );
    if (!_serverSyncIsCurrent(scope, epoch, generation)) return;
    _selectedSlug = info.slug;
    if (candidate.isRemote) {
      _remoteCompanion = candidate;
      _remoteCompanionScope = scope;
      _remoteCompanionRevision = info.spritesheetRevision;
    } else {
      _remoteCompanion = null;
      _remoteCompanionScope = null;
      _remoteCompanionRevision = null;
    }
    notifyListeners();
  }

  Future<Companion?> _candidateForServerInfo(
    ProfilePetInfo info,
    CompanionScope scope,
  ) async {
    if (info.spritesheetRevision.isEmpty) {
      for (final companion in _available) {
        if (companion.slug == info.slug && companion.isValid) return companion;
      }
      return null;
    }
    try {
      return await _repository.materializeProfilePet(
        info,
        connectionId: scope.connId,
        profileId: scope.profileId,
      );
    } on CompanionImportException {
      return null;
    }
  }

  bool _serverSyncIsCurrent(CompanionScope scope, int epoch, int generation) =>
      epoch == _resolutionEpoch &&
      generation == _serverSyncGeneration &&
      _sameScope(scope, _scope);

  /// A profile's pet as its own stores say, after paint: the server's
  /// `pet.info` for that profile, kept on this device (under its own key,
  /// not the selection Mascotas used to write) to paint it at the next
  /// start. Offline, the copy of its last answer stands in. Never selects a
  /// pet, never touches the app's choice.
  Future<ProfileIdentityRead> loadIdentityFor(
    String connection,
    String owner,
  ) async {
    final profile = owner == 'default' ? '' : owner;
    final scope = CompanionScope(connection, profile);
    final info = await _petServiceResolver
        ?.call(connection)
        ?.activePet(profile: profile);
    if (info == null) return cachedIdentityFor(connection, owner);
    if (!info.hasPet) {
      await _preferences.setIdentitySlugFor(connection, profile, null);
      return (known: true, pet: null);
    }
    final pet = await _candidateForServerInfo(info, scope);
    if (pet == null) return cachedIdentityFor(connection, owner);
    if (pet.isRemote) {
      await _repository.promoteProfilePetRevision(
        connectionId: connection,
        profileId: profile,
        slug: info.slug,
        revision: info.spritesheetRevision,
      );
    }
    await _preferences.setIdentitySlugFor(connection, profile, pet.slug);
    return (known: true, pet: pet);
  }

  /// The last pet the profile's stores gave, from this device only.
  Future<ProfileIdentityRead> cachedIdentityFor(
    String connection,
    String owner,
  ) async {
    final profile = owner == 'default' ? '' : owner;
    final slug = _preferences.identitySlugFor(connection, profile);
    if (slug == null) return (known: false, pet: null);
    if (slug.isEmpty) return (known: true, pet: null);
    for (final pet in _available) {
      if (pet.slug == slug && pet.isValid) return (known: true, pet: pet);
    }
    final revision = await _repository.cachedProfilePetRevision(
      connectionId: connection,
      profileId: profile,
      slug: slug,
    );
    if (revision == null) return (known: false, pet: null);
    final cached = await _repository.loadCachedProfilePet(
      connectionId: connection,
      profileId: profile,
      slug: slug,
      revision: revision,
    );
    return cached == null
        ? (known: false, pet: null)
        : (known: true, pet: cached);
  }

  static bool _sameScope(CompanionScope? a, CompanionScope? b) =>
      identical(a, b) ||
      (a != null &&
          b != null &&
          a.connId == b.connId &&
          a.profileId == b.profileId);

  /// Selecciona una mascota (o `null` → mascota por defecto/fallback).
  ///
  /// Escribe primero el espejo local (scoped si hay ámbito) y luego, con un
  /// gateway que soporte `pet.*`, aplica la selección en el servidor como
  /// autoridad (best-effort): `pet.select` para un slug y `pet.disable` para
  /// `null`, la misma semántica del picker de Hermes Desktop.
  Future<void> select(String? slug) async {
    // La elección explícita del usuario invalida cualquier `pet.info` en
    // vuelo: una respuesta anterior no debe sobreescribirla.
    _resolutionEpoch++;
    _serverSyncGeneration++;
    _selectedSlug = slug;
    if (_remoteCompanion?.slug != slug ||
        !_sameScope(_remoteCompanionScope, _scope)) {
      _remoteCompanion = null;
      _remoteCompanionScope = null;
      _remoteCompanionRevision = null;
    }
    final scope = _scope;
    if (appPet) {
      await _preferences.setAppSlug(slug);
    } else if (scope == null) {
      await _preferences.setSelectedSlug(slug);
    } else {
      await _preferences.setSelectedSlugFor(
        scope.connId,
        scope.profileId,
        slug,
      );
    }
    notifyListeners();
    final service = _petService;
    if (scope != null && service != null) {
      if (slug == null) {
        unawaited(service.disablePet(profile: scope.profileId));
      } else {
        unawaited(service.selectPet(profile: scope.profileId, slug: slug));
      }
    }
  }

  /// Activa o desactiva la mascota.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final scope = _scope;
    if (appPet) {
      await _preferences.setAppEnabled(value);
    } else if (scope == null) {
      await _preferences.setEnabled(value);
    } else {
      await _preferences.setEnabledFor(scope.connId, scope.profileId, value);
    }
    notifyListeners();
  }

  /// Ajusta el preset de escala (S/M/L) y lo persiste.
  Future<void> setScale(CompanionScale value) async {
    if (value == _scale && value.multiplier == _sizeMultiplier) return;
    _scale = value;
    _sizeMultiplier = value.multiplier;
    final scope = _scope;
    if (appPet) {
      await _preferences.setAppSize(value.multiplier);
    } else if (scope == null) {
      await _preferences.setScale(value);
    } else {
      await _preferences.setScaleFor(scope.connId, scope.profileId, value);
    }
    notifyListeners();
  }

  /// Ajusta el tamaño continuo y conserva un preset aproximado para
  /// compatibilidad con versiones anteriores.
  Future<void> setSizeMultiplier(double value) async {
    final safe = CompanionDisplaySettings.clampSizeMultiplier(value);
    if ((safe - _sizeMultiplier).abs() < 0.001) return;
    _sizeMultiplier = safe;
    _scale = CompanionScale.values.reduce(
      (a, b) =>
          (a.multiplier - safe).abs() <= (b.multiplier - safe).abs() ? a : b,
    );
    final scope = _scope;
    if (appPet) {
      await _preferences.setAppSize(safe);
    } else if (scope == null) {
      await _preferences.setSizeMultiplier(safe);
    } else {
      await _preferences.setSizeMultiplierFor(
        scope.connId,
        scope.profileId,
        safe,
      );
    }
    notifyListeners();
  }

  /// Ajusta únicamente la mascota indicada, evitando que un sprite rápido
  /// obligue a ralentizar todos los demás.
  Future<void> setAnimationSpeed(double value, {String? slug}) async {
    final target = slug ?? activeCompanion?.slug;
    if (target == null || target.isEmpty) return;
    final safe = CompanionDisplaySettings.clampAnimationSpeed(value);
    if ((safe - _preferences.animationSpeedFor(target)).abs() < 0.001) return;
    await _preferences.setAnimationSpeed(target, safe);
    notifyListeners();
  }

  /// The one "Presencia" choice: [value] is off, chat or full. Off also
  /// switches this profile's pet off; the other two switch it on.
  Future<void> setVisibilityLevel(CompanionPresenceLevel value) async {
    assert(value != CompanionPresenceLevel.ambient);
    final shouldEnable = value != CompanionPresenceLevel.off;
    if (_enabled == shouldEnable && _presence == value) return;
    _enabled = shouldEnable;
    _presence = value;
    _legacyFullPresence = false;
    final scope = _scope;
    if (appPet) {
      await _preferences.setAppEnabled(shouldEnable);
    } else if (scope == null) {
      await _preferences.setEnabled(shouldEnable);
    } else {
      await _preferences.setEnabledFor(
        scope.connId,
        scope.profileId,
        shouldEnable,
      );
    }
    if (appPet) {
      await _preferences.setAppPresence(value);
    } else {
      await _preferences.setPresenceLevel(value);
    }
    notifyListeners();
  }

  /// Sets where the pet shows without touching whether this profile's pet
  /// is on.
  Future<void> setPresenceLevel(CompanionPresenceLevel value) async {
    assert(value != CompanionPresenceLevel.ambient);
    if (value == _presence) return;
    _presence = value;
    _legacyFullPresence = false;
    if (appPet) {
      await _preferences.setAppPresence(value);
    } else {
      await _preferences.setPresenceLevel(value);
    }
    notifyListeners();
  }

  /// Indica si la importación local está disponible (hay almacenamiento
  /// configurado). En entornos sin almacenamiento (algunos tests) es `false`.
  Future<bool> canImport() async => (await _repository.importedRoot()) != null;

  /// Importa una mascota custom **local** desde los bytes de un ZIP. Valida y
  /// copia al sandbox vía [CompanionImportService] (sin red), recarga el
  /// catálogo y selecciona la nueva mascota. Devuelve la mascota importada.
  /// Propaga [CompanionImportException] ante datos inválidos.
  Future<Companion> importFromZipBytes(
    Uint8List zipBytes, {
    String? authorOverride,
  }) async {
    final root = await _repository.importedRoot();
    if (root == null) {
      throw CompanionImportException('importación no disponible');
    }
    final protected = <String>{
      for (final c in _available)
        if (c.origin == CompanionOrigin.base) c.slug,
    };
    final imported = await importService.importFromZipBytes(
      zipBytes,
      storageRoot: root,
      protectedSlugs: protected,
      authorOverride: authorOverride,
    );
    _available = await _repository.loadAll();
    await select(imported.slug); // persiste selección + notifica
    return imported;
  }

  /// Disponibilidad del proveedor de "Hatch" activo (incluye su probe). Si no
  /// hay proveedor o no hay almacenamiento, devuelve no disponible con razón.
  Future<HatchAvailability> hatchAvailability() async {
    final provider = hatchProvider;
    if (provider == null) {
      return const HatchAvailability.unavailable(
        'La generación de mascotas no está disponible en esta conexión.',
      );
    }
    if (await _repository.importedRoot() == null) {
      return const HatchAvailability.unavailable(
        'No hay almacenamiento disponible para guardar la mascota.',
      );
    }
    try {
      return await provider.availability();
    } catch (e) {
      debugPrint(
        '[companion] excepción silenciada (se continúa sin propagar): $e',
      );
      return const HatchAvailability.unavailable(
        'No se pudo comprobar la generación de mascotas.',
      );
    }
  }

  /// `true` si se puede incubar ahora mismo.
  Future<bool> canHatch() async => (await hatchAvailability()).available;

  /// Incuba una mascota **estática** (`generated`) a partir de un [prompt].
  /// Modera el prompt, genera vía el proveedor activo, materializa en el
  /// sandbox (reutilizando el import service), recarga el catálogo y la
  /// selecciona. Propaga [PromptRejectedException]/[HatchException].
  Future<Companion> hatch(String prompt) async {
    final provider = hatchProvider;
    if (provider == null) {
      throw HatchException('La generación de mascotas no está disponible.');
    }
    final root = await _repository.importedRoot();
    if (root == null) {
      throw HatchException('No hay almacenamiento disponible.');
    }
    final protected = <String>{
      for (final c in _available)
        if (c.origin == CompanionOrigin.base) c.slug,
    };
    final existing = <String>{for (final c in _available) c.slug};
    final created = await hatchService.hatch(
      provider: provider,
      prompt: prompt,
      storageRoot: root,
      protectedSlugs: protected,
      existingSlugs: existing,
    );
    _available = await _repository.loadAll();
    await select(created.slug); // persiste selección + notifica
    return created;
  }

  /// Elimina una mascota **importada** del catálogo. Las mascotas base están
  /// protegidas: borrarlas es un **no-op seguro** (nunca se eliminan, FR-011).
  ///
  /// Si se borrara la mascota activa (caso de importadas en Fase B.2), la
  /// selección recae en una base válida, o en `null` → cara del perfil (FR-012).
  /// En Fase B inicial no hay importadas, así que esta operación nunca borra
  /// nada de facto. Devuelve `true` solo si hubo borrado real.
  Future<bool> delete(String slug) async {
    Companion? target;
    for (final c in _available) {
      if (c.slug == slug) {
        target = c;
        break;
      }
    }
    // No existe, o es base/protegida → no-op seguro (jamás borra una base).
    if (target == null || target.isProtected) return false;

    // Borra los ficheros de la mascota del sandbox (importada o generada;
    // best-effort: si falla el borrado en disco, igual la quitamos del catálogo).
    if (target.isFileBacked) {
      final root = await _repository.importedRoot();
      if (root != null) {
        final dir = Directory('${root.path}/$slug');
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {
          /* best-effort */
        }
      }
    }

    _available = _available.where((c) => c.slug != slug).toList();
    if (_selectedSlug == slug) {
      String? fallback;
      for (final c in _available) {
        if (c.origin == CompanionOrigin.base) {
          fallback = c.slug;
          break;
        }
      }
      await select(fallback); // persiste selección; null → cara del perfil
    } else {
      notifyListeners();
    }
    return true;
  }

  @override
  void dispose() {
    if (publishProfileIdentity) {
      ProfileIdentities.instance.removeListener(notifyListeners);
    }
    _resolutionEpoch++;
    _serverSyncGeneration++;
    _scopeChanges?.removeListener(_onScopeChanged);
    unawaited(_petChangedSub?.cancel());
    super.dispose();
  }
}
