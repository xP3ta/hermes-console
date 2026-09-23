import 'package:shared_preferences/shared_preferences.dart';

import '../models/companion_display_settings.dart';
import '../models/companion_presence_level.dart';
import '../models/companion_scale.dart';

/// Persistencia local de la preferencia de mascota: slug seleccionado, on/off y
/// escala. Usa `shared_preferences`, el mecanismo de settings ya empleado en el
/// proyecto.
///
/// La identidad de la mascota es **por perfil** (como el `display.pet.*` del
/// gateway): [selectedSlugFor], [enabledFor], [scaleFor] y
/// [sizeMultiplierFor] leen/escriben keys con scope
/// `companion.<pref>.<connId>.<profileId>` (`default` = perfil por defecto de
/// la conexión). Las keys globales originales se conservan una versión como
/// último fallback legado; [migrateLegacyToScope] copia su valor al scope del
/// perfil activo una sola vez. Los ajustes de presentación de la app
/// (velocidad por slug, nivel de presencia, paseo, visibilidad en Inicio)
/// siguen siendo globales.
class CompanionPreferences {
  static const String slugKey = 'companion.selected_slug';
  static const String enabledKey = 'companion.enabled';
  static const String scaleKey = 'companion.scale';
  static const String sizeMultiplierKey = 'companion.size_multiplier';
  static const String animationSpeedKeyPrefix = 'companion.animation_speed.';
  static const String presenceLevelKey = 'companion.presence_level';
  static const String roamingEnabledKey = 'companion.roaming_enabled';
  static const String showOnHomeKey = 'companion.show_on_home';

  final SharedPreferences _prefs;

  CompanionPreferences(this._prefs);

  /// Carga la instancia respaldada por [SharedPreferences].
  static Future<CompanionPreferences> load() async {
    return CompanionPreferences(await SharedPreferences.getInstance());
  }

  /// Slug seleccionado, o `null` (→ mascota por defecto).
  String? get selectedSlug => _prefs.getString(slugKey);

  /// Si la mascota está activada. Default: `true`.
  bool get enabled => _prefs.getBool(enabledKey) ?? true;

  /// Preset de escala de la mascota. Default/valor inválido → `medium`.
  CompanionScale get scale => CompanionScale.fromId(_prefs.getString(scaleKey));

  /// Tamaño continuo. Si aún no existe, migra de forma transparente desde el
  /// antiguo preset S/M/L sin cambiar visualmente instalaciones existentes.
  double get sizeMultiplier {
    final stored = _prefs.get(sizeMultiplierKey);
    if (stored is num) {
      return CompanionDisplaySettings.clampSizeMultiplier(stored);
    }
    return scale.multiplier;
  }

  /// Velocidad propia de una mascota. El Spark por defecto y slugs vacíos usan
  /// 1× porque no tienen un spritesheet configurable.
  double animationSpeedFor(String? slug) {
    if (slug == null || slug.trim().isEmpty) {
      return CompanionDisplaySettings.defaultAnimationSpeed;
    }
    final stored = _prefs.get(_animationSpeedKey(slug));
    if (stored is! num) {
      return CompanionDisplaySettings.defaultAnimationSpeed;
    }
    return CompanionDisplaySettings.clampAnimationSpeed(stored);
  }

  /// Nivel de presencia (006). Por defecto `minimal`.
  CompanionPresenceLevel get presenceLevel =>
      companionPresenceLevelFromId(_prefs.getString(presenceLevelKey));

  /// Paseo decorativo por Inicio. Opt-in para conservar el comportamiento
  /// estable y no introducir movimiento en instalaciones existentes.
  bool get roamingEnabled => _prefs.getBool(roamingEnabledKey) ?? false;

  /// Si la mascota aparece sobre el compositor de Inicio. Es independiente de
  /// la presencia global: ocultarla aquí no afecta Chat, Runs ni modo voz.
  bool get showOnHome => _prefs.getBool(showOnHomeKey) ?? true;

  Future<void> setSelectedSlug(String? slug) async {
    if (slug == null) {
      await _prefs.remove(slugKey);
    } else {
      await _prefs.setString(slugKey, slug);
    }
  }

  Future<void> setEnabled(bool value) async {
    await _prefs.setBool(enabledKey, value);
  }

  Future<void> setScale(CompanionScale value) async {
    await _prefs.setString(scaleKey, value.id);
    await _prefs.setDouble(sizeMultiplierKey, value.multiplier);
  }

  Future<void> setSizeMultiplier(double value) async {
    final safe = CompanionDisplaySettings.clampSizeMultiplier(value);
    final nearest = CompanionScale.values.reduce(
      (a, b) =>
          (a.multiplier - safe).abs() <= (b.multiplier - safe).abs() ? a : b,
    );
    // Se conserva el preset aproximado para una posible vuelta a una versión
    // antigua, pero el valor continuo es la fuente autoritativa actual.
    await _prefs.setString(scaleKey, nearest.id);
    await _prefs.setDouble(sizeMultiplierKey, safe);
  }

  Future<void> setAnimationSpeed(String slug, double value) async {
    if (slug.trim().isEmpty) return;
    await _prefs.setDouble(
      _animationSpeedKey(slug),
      CompanionDisplaySettings.clampAnimationSpeed(value),
    );
  }

  Future<void> setPresenceLevel(CompanionPresenceLevel value) async {
    await _prefs.setString(presenceLevelKey, value.id);
  }

  Future<void> setRoamingEnabled(bool value) async {
    await _prefs.setBool(roamingEnabledKey, value);
  }

  Future<void> setShowOnHome(bool value) async {
    await _prefs.setBool(showOnHomeKey, value);
  }

  // ── Variantes con scope por (conexión, perfil) ────────────────────────
  //
  // La mascota existe y se gestiona SOLO por perfil. Lectura: scoped →
  // fallback a la key global legada (una versión). Escritura: solo scoped.

  /// Key scoped del slug seleccionado: `companion.selected_slug.<connId>.<profileId>`.
  static String scopedSlugKey(String connId, String profileId) =>
      '$slugKey.${_scopeSegment(connId)}.${_scopeSegment(profileId)}';

  static String _scopedEnabledKey(String connId, String profileId) =>
      '$enabledKey.${_scopeSegment(connId)}.${_scopeSegment(profileId)}';

  static String _scopedScaleKey(String connId, String profileId) =>
      '$scaleKey.${_scopeSegment(connId)}.${_scopeSegment(profileId)}';

  static String _scopedSizeMultiplierKey(String connId, String profileId) =>
      '$sizeMultiplierKey.${_scopeSegment(connId)}.${_scopeSegment(profileId)}';

  /// Segmento de key para un connId (UUID) o profileId (`[a-z0-9_-]`); el
  /// perfil por defecto (vacío) usa `default`, la misma normalización que
  /// aplica ConnectionManager al perfil activo.
  static String _scopeSegment(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? 'default' : Uri.encodeComponent(trimmed);
  }

  /// Migración one-shot: copia las keys globales con valor al scope indicado
  /// (el del perfil activo en ese momento) sin borrar las globales, que
  /// quedan como último fallback legado durante una versión. No pisa valores
  /// scoped ya existentes.
  Future<void> migrateLegacyToScope(String connId, String profileId) async {
    Future<void> copy(String globalKey, String scopedKey) async {
      if (_prefs.containsKey(scopedKey)) return;
      final value = _prefs.get(globalKey);
      if (value is String) {
        await _prefs.setString(scopedKey, value);
      } else if (value is bool) {
        await _prefs.setBool(scopedKey, value);
      } else if (value is num) {
        await _prefs.setDouble(scopedKey, value.toDouble());
      }
    }

    await copy(slugKey, scopedSlugKey(connId, profileId));
    await copy(enabledKey, _scopedEnabledKey(connId, profileId));
    await copy(scaleKey, _scopedScaleKey(connId, profileId));
    await copy(sizeMultiplierKey, _scopedSizeMultiplierKey(connId, profileId));
  }

  /// Flag de la migración one-shot (una vez por instalación, no por scope).
  static const String scopedMigrationKey = 'companion.scoped_migration.v1';

  /// [migrateLegacyToScope] ejecutada una sola vez por instalación: la copia
  /// va al scope del perfil activo en ese momento; los demás scopes leen el
  /// fallback legado hasta tener valor propio.
  Future<void> migrateLegacyToScopeOnce(String connId, String profileId) async {
    if (_prefs.getBool(scopedMigrationKey) == true) return;
    await _prefs.setBool(scopedMigrationKey, true);
    await migrateLegacyToScope(connId, profileId);
  }

  /// Slug seleccionado en el scope (con fallback legado a la key global).
  String? selectedSlugFor(String connId, String profileId) {
    final key = scopedSlugKey(connId, profileId);
    if (_prefs.containsKey(key)) {
      final scoped = _prefs.getString(key);
      return scoped == null || scoped.isEmpty ? null : scoped;
    }
    return _prefs.getString(slugKey);
  }

  Future<void> setSelectedSlugFor(
    String connId,
    String profileId,
    String? slug,
  ) async {
    await _prefs.setString(scopedSlugKey(connId, profileId), slug ?? '');
  }

  bool enabledFor(String connId, String profileId) =>
      _prefs.getBool(_scopedEnabledKey(connId, profileId)) ??
      _prefs.getBool(enabledKey) ??
      true;

  Future<void> setEnabledFor(
    String connId,
    String profileId,
    bool value,
  ) async {
    await _prefs.setBool(_scopedEnabledKey(connId, profileId), value);
  }

  CompanionScale scaleFor(String connId, String profileId) =>
      CompanionScale.fromId(
        _prefs.getString(_scopedScaleKey(connId, profileId)) ??
            _prefs.getString(scaleKey),
      );

  Future<void> setScaleFor(
    String connId,
    String profileId,
    CompanionScale value,
  ) async {
    await _prefs.setString(_scopedScaleKey(connId, profileId), value.id);
    await _prefs.setDouble(
      _scopedSizeMultiplierKey(connId, profileId),
      value.multiplier,
    );
  }

  double sizeMultiplierFor(String connId, String profileId) {
    final stored =
        _prefs.get(_scopedSizeMultiplierKey(connId, profileId)) ??
        _prefs.get(sizeMultiplierKey);
    if (stored is num) {
      return CompanionDisplaySettings.clampSizeMultiplier(stored);
    }
    return scaleFor(connId, profileId).multiplier;
  }

  Future<void> setSizeMultiplierFor(
    String connId,
    String profileId,
    double value,
  ) async {
    final safe = CompanionDisplaySettings.clampSizeMultiplier(value);
    final nearest = CompanionScale.values.reduce(
      (a, b) =>
          (a.multiplier - safe).abs() <= (b.multiplier - safe).abs() ? a : b,
    );
    await _prefs.setString(_scopedScaleKey(connId, profileId), nearest.id);
    await _prefs.setDouble(_scopedSizeMultiplierKey(connId, profileId), safe);
  }

  static String _animationSpeedKey(String slug) {
    return '$animationSpeedKeyPrefix${Uri.encodeComponent(slug.trim())}';
  }
}
