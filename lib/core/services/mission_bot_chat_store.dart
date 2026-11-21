import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mission_store_mutation_queue.dart';
import 'secure_storage.dart';

enum MissionBotChatPinState { absent, available, corrupt, unavailable }

final class MissionBotChatPinLookup {
  final MissionBotChatPinState state;
  final String? sessionId;

  const MissionBotChatPinLookup._(this.state, [this.sessionId]);

  static const absent = MissionBotChatPinLookup._(
    MissionBotChatPinState.absent,
  );
  static const corrupt = MissionBotChatPinLookup._(
    MissionBotChatPinState.corrupt,
  );
  static const unavailable = MissionBotChatPinLookup._(
    MissionBotChatPinState.unavailable,
  );

  factory MissionBotChatPinLookup.available(String sessionId) =>
      MissionBotChatPinLookup._(MissionBotChatPinState.available, sessionId);

  bool get isAvailable => state == MissionBotChatPinState.available;
}

/// Local compatibility pins used only when the official Hermes Bot Mode
/// metadata RPC is unavailable. Pins live in Android Keystore-backed storage;
/// the old SharedPreferences map is read once for migration and then removed.
final class MissionBotChatStore {
  static const _legacyPrefix = 'mission_control.bot_chat_pins.v1.';
  static const _securePrefix = 'mission_control.bot_chat_pins.v2.';
  static final RegExp _profile = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  MissionBotChatStore(
    this._prefs, {
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _secure = secureStorage;

  static String _scope(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  String _secureKey(String connectionId, String profile) =>
      '$_securePrefix${_scope(connectionId)}.${_scope(profile)}';
  String _legacyKey(String connectionId) => '$_legacyPrefix$connectionId';

  Future<MissionBotChatPinLookup> lookup(
    String connectionId,
    String profile, {
    bool migrateLegacy = true,
  }) => MissionStoreMutationQueue.run(() async {
    final normalizedProfile = profile.trim();
    if (!_profile.hasMatch(normalizedProfile)) {
      return MissionBotChatPinLookup.corrupt;
    }
    final key = _secureKey(connectionId, normalizedProfile);
    String? rawSecure;
    try {
      rawSecure = await _secure.read(key: key);
    } catch (_) {
      return MissionBotChatPinLookup.unavailable;
    }
    if (rawSecure != null) {
      final stored = _safeSessionId(rawSecure);
      if (stored == null) return MissionBotChatPinLookup.corrupt;
      if (migrateLegacy && _prefs.containsKey(_legacyKey(connectionId))) {
        try {
          await _removeLegacyProfile(connectionId, normalizedProfile);
        } catch (_) {
          return MissionBotChatPinLookup.unavailable;
        }
      }
      return MissionBotChatPinLookup.available(stored);
    }

    // One-way migration from the original plaintext compatibility map.
    final legacyLookup = _legacyPin(connectionId, normalizedProfile);
    if (!legacyLookup.isAvailable || !migrateLegacy) return legacyLookup;
    final legacy = legacyLookup.sessionId!;
    try {
      await _secure.write(key: key, value: legacy);
      try {
        await _removeLegacyProfile(connectionId, normalizedProfile);
      } catch (_) {
        try {
          await _secure.delete(key: key);
        } catch (_) {}
        rethrow;
      }
      return MissionBotChatPinLookup.available(legacy);
    } catch (_) {
      return MissionBotChatPinLookup.unavailable;
    }
  });

  Future<String?> load(String connectionId, String profile) async =>
      (await lookup(connectionId, profile)).sessionId;

  Future<void> save({
    required String connectionId,
    required String profile,
    required String sessionId,
  }) => MissionStoreMutationQueue.run(() async {
    final normalizedProfile = profile.trim();
    final normalizedSession = _safeSessionId(sessionId);
    if (!_profile.hasMatch(normalizedProfile) || normalizedSession == null) {
      throw const FormatException('Invalid Bot Chat pin');
    }
    await _secure.write(
      key: _secureKey(connectionId, normalizedProfile),
      value: normalizedSession,
    );
    await _removeLegacyProfile(connectionId, normalizedProfile);
  });

  Future<void> clear({required String connectionId, required String profile}) =>
      MissionStoreMutationQueue.run(() async {
        final normalizedProfile = profile.trim();
        if (!_profile.hasMatch(normalizedProfile)) return;
        await _secure.delete(key: _secureKey(connectionId, normalizedProfile));
        await _removeLegacyProfile(connectionId, normalizedProfile);
      });

  Future<int> deleteForConnection(String connectionId) =>
      MissionStoreMutationQueue.run(() async {
        final securePrefix = '$_securePrefix${_scope(connectionId)}.';
        final keys = await SecureStorage.listKeys(_secure);
        var removed = 0;
        for (final key in keys.where((key) => key.startsWith(securePrefix))) {
          await _secure.delete(key: key);
          removed++;
        }
        final legacyKey = _legacyKey(connectionId);
        if (_prefs.containsKey(legacyKey)) {
          final success = await _prefs.remove(legacyKey);
          if (!success && _prefs.containsKey(legacyKey)) {
            throw StateError('Bot Chat legacy cleanup was not persisted');
          }
          removed++;
        }
        return removed;
      });

  MissionBotChatPinLookup _legacyPin(String connectionId, String profile) {
    final key = _legacyKey(connectionId);
    final raw = _prefs.getString(key);
    if (raw == null) return MissionBotChatPinLookup.absent;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return MissionBotChatPinLookup.corrupt;
      if (!decoded.containsKey(profile)) return MissionBotChatPinLookup.absent;
      final sessionId = _safeSessionId(decoded[profile]);
      return sessionId == null
          ? MissionBotChatPinLookup.corrupt
          : MissionBotChatPinLookup.available(sessionId);
    } catch (_) {
      return MissionBotChatPinLookup.corrupt;
    }
  }

  Future<void> _removeLegacyProfile(String connectionId, String profile) async {
    final key = _legacyKey(connectionId);
    Object? decoded;
    try {
      decoded = jsonDecode(_prefs.getString(key) ?? '');
    } catch (_) {
      decoded = null;
    }
    if (decoded is! Map) {
      final success = await _prefs.remove(key);
      if (!success && _prefs.containsKey(key)) {
        throw StateError('Bot Chat legacy cleanup was not persisted');
      }
      return;
    }
    final remaining = <String, String>{};
    for (final entry in decoded.entries) {
      final candidateProfile = entry.key.toString();
      final candidateSession = _safeSessionId(entry.value);
      if (candidateProfile != profile &&
          _profile.hasMatch(candidateProfile) &&
          candidateSession != null &&
          remaining.length < 100) {
        remaining[candidateProfile] = candidateSession;
      }
    }
    if (remaining.isEmpty) {
      final success = await _prefs.remove(key);
      if (!success && _prefs.containsKey(key)) {
        throw StateError('Bot Chat legacy cleanup was not persisted');
      }
    } else {
      final success = await _prefs.setString(key, jsonEncode(remaining));
      if (!success) {
        throw StateError('Bot Chat legacy cleanup was not persisted');
      }
    }
  }

  static String? _safeSessionId(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    if (value.isEmpty ||
        value.startsWith('mob-') ||
        value.length > 512 ||
        value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return value;
  }
}
