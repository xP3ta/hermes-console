import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_theme.dart';
import 'component_profile.dart';
import 'theme_profile.dart';
import 'theme_profile_adapter.dart';
import 'theme_profile_codec.dart';
import 'theme_profile_validator.dart';

enum ThemeImportStatus { added, replaced, alreadyImported }

final class ThemeProfileStoreException implements Exception {
  final String code;
  final String message;

  const ThemeProfileStoreException(this.code, this.message);

  @override
  String toString() => 'ThemeProfileStoreException($code): $message';
}

final class ThemeImportResult {
  final ThemeImportStatus status;
  final ThemeProfile profile;
  final ThemeValidationResult validation;
  final List<ThemeProfileWarning> warnings;

  const ThemeImportResult({
    required this.status,
    required this.profile,
    required this.validation,
    this.warnings = const [],
  });
}

final class ThemeProfileStoreSnapshot {
  final List<ThemeProfile> customProfiles;
  final String activeProfileId;
  final String activeComponentProfileId;
  final String? quarantinedPayload;
  final bool hasFutureSchema;
  final List<ThemeProfileWarning> warnings;

  /// "Auto": the active built-in family follows the system appearance
  /// (light variant by day, dark by night). Never set for custom themes.
  final bool followSystem;

  const ThemeProfileStoreSnapshot({
    required this.customProfiles,
    required this.activeProfileId,
    required this.activeComponentProfileId,
    this.quarantinedPayload,
    this.hasFutureSchema = false,
    this.warnings = const [],
    this.followSystem = false,
  });

  ThemeProfile? customById(String id) {
    for (final profile in customProfiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }
}

/// SharedPreferences persistence for non-secret, local theme documents.
///
/// Built-ins remain in [ThemeProfileAdapter] and are never copied into storage
/// until the user explicitly creates or imports a custom profile.
final class ThemeProfileStore {
  static const int maxCustomProfiles = 16;
  static const String schemaVersionKey = 'theme_profile_schema_version';
  static const String customProfilesKey = 'custom_theme_profiles_v1';
  static const String activeProfileKey = 'active_theme_profile_id';
  static const String activeComponentProfileKey = 'active_component_profile_id';
  static const String draftsKey = 'theme_drafts_v1';
  static const String quarantineKey = 'quarantined_theme_v1';
  static const String legacyThemeKey = 'theme_mode';
  static const String followSystemKey = 'theme_follow_system';

  final SharedPreferences _prefs;
  final String Function() _newId;

  bool _loaded = false;
  List<ThemeProfile> _profiles = const [];
  List<Object?> _futureDocuments = const [];
  String _activeProfileId = AppTheme.defaultThemeId;
  String _activeComponentProfileId = ComponentProfiles.minimal.id;
  bool _hasFutureSchema = false;
  bool _followSystem = false;
  List<ThemeProfileWarning> _warnings = const [];

  ThemeProfileStore(this._prefs, {String Function()? idFactory})
    : _newId = idFactory ?? const Uuid().v4;

  Future<ThemeProfileStoreSnapshot> load({bool force = false}) async {
    if (_loaded && !force) return _snapshot();

    _profiles = const [];
    _futureDocuments = const [];
    _warnings = const [];
    _hasFutureSchema = false;
    _followSystem = _prefs.getBool(followSystemKey) ?? false;

    final storedEnvelopeSchema = _prefs.getInt(schemaVersionKey);
    final rawProfiles = _prefs.getString(customProfilesKey);
    if (storedEnvelopeSchema != null &&
        storedEnvelopeSchema > themeProfileSchemaVersion) {
      _hasFutureSchema = true;
      final requested = _prefs.getString(activeProfileKey);
      _activeProfileId =
          requested != null && ThemeProfileAdapter.isBuiltinId(requested)
          ? requested
          : ThemeProfileAdapter.resolveLegacyBuiltinId(
              _prefs.getString(legacyThemeKey),
            );
      await _prefs.setString(activeProfileKey, _activeProfileId);
      _activeComponentProfileId = await _readComponentProfile();
      _loaded = true;
      return _snapshot();
    }

    final valid = <ThemeProfile>[];
    final future = <Object?>[];
    final warnings = <ThemeProfileWarning>[];
    String? quarantine;
    var needsRewrite = false;

    if (rawProfiles != null) {
      Object? decodedList;
      try {
        decodedList = jsonDecode(rawProfiles);
      } on FormatException {
        quarantine = _safeQuarantine(rawProfiles);
        decodedList = const [];
        needsRewrite = true;
      }
      if (decodedList is! List) {
        quarantine ??= _safeQuarantine(rawProfiles);
        decodedList = const [];
        needsRewrite = true;
      }

      for (final item in decodedList) {
        if (valid.length + future.length >= maxCustomProfiles) {
          quarantine ??= _safeQuarantine(jsonEncode(item));
          needsRewrite = true;
          continue;
        }
        final document = _normalizeStoredDocument(item);
        if (document == null) {
          quarantine ??= _safeQuarantine(jsonEncode(item));
          needsRewrite = true;
          continue;
        }
        final rawDocument = jsonEncode(document);
        try {
          final result = ThemeProfileCodec.decode(
            rawDocument,
            mode: ThemeProfileDecodeMode.persisted,
          );
          if (valid.any((profile) => profile.id == result.profile.id)) {
            quarantine ??= _safeQuarantine(rawDocument);
            needsRewrite = true;
            continue;
          }
          valid.add(result.profile);
          warnings.addAll(result.warnings);
        } on UnsupportedThemeSchemaException {
          // Preserve a bounded, structurally safe future document byte-for-byte
          // at the JSON-value level. It is not treated as corrupt or rewritten.
          future.add(document);
          _hasFutureSchema = true;
        } on ThemeProfileCodecException {
          quarantine ??= _safeQuarantine(rawDocument);
          needsRewrite = true;
        }
      }
    }

    _profiles = List.unmodifiable(valid);
    _futureDocuments = List.unmodifiable(future);
    _warnings = List.unmodifiable(warnings);

    final requestedActive =
        _prefs.getString(activeProfileKey) ?? _prefs.getString(legacyThemeKey);
    _activeProfileId = _resolveActive(requestedActive);
    if (_activeProfileId != requestedActive && requestedActive != null) {
      // Migrated once: both keys carry the survivor, so the first frame of
      // the next start reads it directly and nothing migrates again.
      await _prefs.setString(activeProfileKey, _activeProfileId);
      await _prefs.setString(legacyThemeKey, _activeProfileId);
    }
    _activeComponentProfileId = await _readComponentProfile();

    if (quarantine != null) {
      await _prefs.setString(quarantineKey, quarantine);
    }
    if (needsRewrite && !_hasFutureSchema) {
      await _persistProfiles();
    }
    // If any future-schema document is present, keep the original envelope
    // byte-for-byte. Re-encoding the list from an older app could silently
    // downgrade or discard fields it does not understand.
    _loaded = true;
    return _snapshot();
  }

  Future<ThemeProfile> save(ThemeProfile profile, {String? replaceId}) async {
    await _ensureLoaded();
    if (profile.isBuiltin) {
      throw const ThemeProfileStoreException(
        'builtin_immutable',
        'Built-in themes are immutable; duplicate before saving',
      );
    }
    final validation = ThemeProfileValidator.validate(profile);
    if (!validation.isDraftSavable ||
        (!profile.draft && !validation.isActivatable)) {
      throw const ThemeProfileStoreException(
        'invalid_profile',
        'Invalid themes must be saved explicitly as drafts',
      );
    }

    final profiles = [..._profiles];
    final targetId = replaceId ?? profile.id;
    final index = profiles.indexWhere((item) => item.id == targetId);
    if (replaceId != null && index < 0) {
      throw const ThemeProfileStoreException(
        'replace_target_missing',
        'The selected replacement theme no longer exists',
      );
    }
    final storedProfile = profile.copyWith(id: targetId);
    if (index >= 0) {
      profiles[index] = storedProfile;
    } else {
      if (profiles.length + _futureDocuments.length >= maxCustomProfiles) {
        throw const ThemeProfileStoreException(
          'profile_limit',
          'The maximum of 16 custom themes has been reached',
        );
      }
      if (ThemeProfileAdapter.isBuiltinId(profile.id)) {
        throw const ThemeProfileStoreException(
          'builtin_collision',
          'A custom theme cannot overwrite a built-in id',
        );
      }
      profiles.add(storedProfile);
    }
    _profiles = List.unmodifiable(profiles);
    await _persistProfiles();
    await _fallbackIfActiveProfileIsUnsafe();
    return storedProfile;
  }

  Future<ThemeImportResult> importProfile(
    String raw, {
    String? replaceId,
  }) async {
    await _ensureLoaded();
    final decoded = ThemeProfileCodec.decode(raw);
    var incoming = decoded.profile;
    final initialValidation = ThemeProfileValidator.validate(incoming);
    if (!initialValidation.isDraftSavable) {
      throw const ThemeProfileStoreException(
        'invalid_profile',
        'The imported theme cannot be saved safely',
      );
    }
    if (!initialValidation.isActivatable && !incoming.draft) {
      incoming = incoming.copyWith(draft: true);
    }

    final sameId = _profileById(incoming.id);
    if (replaceId == null &&
        sameId != null &&
        _fingerprint(sameId) == _fingerprint(incoming)) {
      return ThemeImportResult(
        status: ThemeImportStatus.alreadyImported,
        profile: sameId,
        validation: ThemeProfileValidator.validate(sameId),
        warnings: decoded.warnings,
      );
    }

    ThemeImportStatus status;
    if (replaceId != null) {
      final target = _profileById(replaceId);
      if (target == null) {
        throw const ThemeProfileStoreException(
          'replace_target_missing',
          'The selected replacement theme no longer exists',
        );
      }
      incoming = incoming.copyWith(id: replaceId);
      status = ThemeImportStatus.replaced;
    } else {
      if (sameId != null || ThemeProfileAdapter.isBuiltinId(incoming.id)) {
        incoming = incoming.copyWith(id: _uniqueId());
      }
      incoming = incoming.copyWith(name: _uniqueName(incoming.name));
      if (_profiles.length + _futureDocuments.length >= maxCustomProfiles) {
        throw const ThemeProfileStoreException(
          'profile_limit',
          'The maximum of 16 custom themes has been reached',
        );
      }
      status = ThemeImportStatus.added;
    }

    final validation = ThemeProfileValidator.validate(incoming);
    final profiles = [..._profiles];
    final index = profiles.indexWhere((profile) => profile.id == incoming.id);
    if (index >= 0) {
      profiles[index] = incoming;
    } else {
      profiles.add(incoming);
    }
    _profiles = List.unmodifiable(profiles);
    await _persistProfiles();
    await _fallbackIfActiveProfileIsUnsafe();
    return ThemeImportResult(
      status: status,
      profile: incoming,
      validation: validation,
      warnings: List.unmodifiable([
        ...decoded.warnings,
        ...validation.warnings,
      ]),
    );
  }

  /// Activates [id]. [followSystem] ("Auto") only applies to built-in
  /// themes; any manual pick or custom theme turns it off.
  Future<void> activate(String id, {bool followSystem = false}) async {
    await _ensureLoaded();
    await _useUnifiedComponentProfile();
    if (ThemeProfileAdapter.isBuiltinId(id)) {
      _activeProfileId = id;
      await _prefs.setString(activeProfileKey, id);
      // Keep the legacy key synchronized until main.dart adopts ThemeProfile.
      await _prefs.setString(legacyThemeKey, id);
      await _setFollowSystem(followSystem);
      return;
    }
    final profile = _profileById(id);
    if (profile == null) {
      throw const ThemeProfileStoreException(
        'profile_missing',
        'Theme profile does not exist',
      );
    }
    final validation = ThemeProfileValidator.validate(profile);
    if (profile.draft || !validation.isActivatable) {
      throw const ThemeProfileStoreException(
        'profile_not_activatable',
        'Draft or invalid themes cannot be activated',
      );
    }
    _activeProfileId = id;
    await _prefs.setString(activeProfileKey, id);
    await _setFollowSystem(false);
  }

  Future<void> _setFollowSystem(bool value) async {
    _followSystem = value;
    if (value) {
      await _prefs.setBool(followSystemKey, true);
    } else {
      await _prefs.remove(followSystemKey);
    }
  }

  Future<void> delete(String id) async {
    await _ensureLoaded();
    if (ThemeProfileAdapter.isBuiltinId(id)) {
      throw const ThemeProfileStoreException(
        'builtin_immutable',
        'Built-in themes cannot be deleted',
      );
    }
    final profiles = [..._profiles];
    final before = profiles.length;
    profiles.removeWhere((profile) => profile.id == id);
    if (profiles.length == before) return;
    _profiles = List.unmodifiable(profiles);
    if (_activeProfileId == id) {
      _activeProfileId = AppTheme.defaultThemeId;
      await _prefs.setString(activeProfileKey, _activeProfileId);
      await _prefs.setString(legacyThemeKey, _activeProfileId);
    }
    await _persistProfiles();
  }

  Future<void> clearQuarantine() async {
    await _prefs.remove(quarantineKey);
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> _fallbackIfActiveProfileIsUnsafe() async {
    if (ThemeProfileAdapter.isBuiltinId(_activeProfileId)) return;
    final active = _profileById(_activeProfileId);
    if (active != null &&
        !active.draft &&
        ThemeProfileValidator.validate(active).isActivatable) {
      return;
    }
    _activeProfileId = AppTheme.defaultThemeId;
    await _prefs.setString(activeProfileKey, _activeProfileId);
    await _prefs.setString(legacyThemeKey, _activeProfileId);
  }

  ThemeProfileStoreSnapshot _snapshot() => ThemeProfileStoreSnapshot(
    customProfiles: List.unmodifiable(_profiles),
    activeProfileId: _activeProfileId,
    activeComponentProfileId: _activeComponentProfileId,
    quarantinedPayload: _prefs.getString(quarantineKey),
    hasFutureSchema: _hasFutureSchema,
    warnings: List.unmodifiable(_warnings),
    followSystem:
        _followSystem && ThemeProfileAdapter.isBuiltinId(_activeProfileId),
  );

  String _resolveActive(String? requested) {
    if (requested != null) {
      if (ThemeProfileAdapter.isBuiltinId(requested)) return requested;
      final custom = _profileById(requested);
      if (custom != null &&
          !custom.draft &&
          ThemeProfileValidator.validate(custom).isActivatable) {
        return requested;
      }
      final migrated = ThemeProfileAdapter.resolveLegacyBuiltinId(requested);
      if (ThemeProfileAdapter.isBuiltinId(migrated)) return migrated;
    }
    return AppTheme.defaultThemeId;
  }

  Future<String> _readComponentProfile() async {
    final requested = _prefs.getString(activeComponentProfileKey);
    if (requested != ComponentProfiles.minimal.id) {
      await _prefs.setString(
        activeComponentProfileKey,
        ComponentProfiles.minimal.id,
      );
    }
    return ComponentProfiles.minimal.id;
  }

  Future<void> _useUnifiedComponentProfile() async {
    _activeComponentProfileId = ComponentProfiles.minimal.id;
    if (_prefs.getString(activeComponentProfileKey) !=
        ComponentProfiles.minimal.id) {
      await _prefs.setString(
        activeComponentProfileKey,
        ComponentProfiles.minimal.id,
      );
    }
  }

  ThemeProfile? _profileById(String id) {
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  String _uniqueId() {
    for (var attempt = 0; attempt < 32; attempt++) {
      final candidate = _newId();
      if (!ThemeProfileAdapter.isBuiltinId(candidate) &&
          _profileById(candidate) == null) {
        return candidate;
      }
    }
    throw const ThemeProfileStoreException(
      'id_collision',
      'Could not allocate a unique theme id',
    );
  }

  String _uniqueName(String proposed) {
    final names = _profiles.map((profile) => profile.name).toSet();
    if (!names.contains(proposed)) return proposed;
    for (var suffix = 2; suffix <= maxCustomProfiles + 1; suffix++) {
      final maxBaseRunes = 48 - ' ($suffix)'.runes.length;
      final baseRunes = proposed.runes.take(maxBaseRunes).toList();
      final candidate = '${String.fromCharCodes(baseRunes)} ($suffix)';
      if (!names.contains(candidate)) return candidate;
    }
    return '${String.fromCharCodes(proposed.runes.take(44))} copy';
  }

  String _fingerprint(ThemeProfile profile) {
    final normalized = profile.copyWith(source: ThemeProfileSource.imported);
    return jsonEncode(ThemeProfileCodec.toProfileMap(normalized));
  }

  Future<void> _persistProfiles() async {
    final documents = <Object?>[
      ..._profiles.map(ThemeProfileCodec.toDocument),
      ..._futureDocuments,
    ];
    await _prefs.setInt(schemaVersionKey, themeProfileSchemaVersion);
    await _prefs.setString(customProfilesKey, jsonEncode(documents));
  }

  static Map<String, dynamic>? _normalizeStoredDocument(Object? value) {
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        return _normalizeStoredDocument(decoded);
      } on FormatException {
        return null;
      }
    }
    if (value is! Map) return null;
    final map = value.map((key, item) => MapEntry(key.toString(), item));
    if (map['format'] == ThemeProfileCodec.format &&
        map.containsKey('profile')) {
      return map;
    }
    if (map.containsKey('id') && map.containsKey('palette')) {
      return {
        'format': ThemeProfileCodec.format,
        'schema_version': themeProfileSchemaVersion,
        'profile': map,
      };
    }
    return map;
  }

  static String? _safeQuarantine(String raw) {
    if (utf8.encode(raw).length > ThemeProfileCodec.maxBytes) return null;
    final forbiddenKey = RegExp(
      r'"(?:token|api_key|authorization|cookie|connection|connection_id|session|session_id|prompt|transcript|host|cwd|path|url|css_url|device_id|username|author_email|[^"\\]*_url)"\s*:',
      caseSensitive: false,
    );
    if (forbiddenKey.hasMatch(raw)) return null;
    return raw;
  }
}
