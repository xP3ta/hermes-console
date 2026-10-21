// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/transport_privacy.dart';
import 'connection_manager.dart';
import 'mobile_oauth.dart';
import 'native_session_store.dart';
import 'secure_storage.dart';

/// What one silent probe learned about an instance's Dashboard.
enum DashboardAccess {
  /// The Dashboard answered and the login this phone holds works.
  ready('ready'),

  /// The Dashboard answered and wants a sign-in this phone does not have.
  needsSignIn('needs_sign_in'),

  /// No verdict (unreachable, refused by transport policy, rate limited).
  unknown('unknown');

  const DashboardAccess(this.storageKey);

  final String storageKey;

  static DashboardAccess fromStorage(Object? value) => values.firstWhere(
    (access) => access.storageKey == value,
    orElse: () => DashboardAccess.unknown,
  );
}

typedef DashboardAccessProbe =
    Future<DashboardAccess> Function(SavedConnection connection);

/// One silent look at [connection]'s Dashboard with the credentials it has:
/// the public `/api/status`, then the sign-in the app already performs and
/// one authenticated read. Never a `/bridge/*` request, never a write.
Future<DashboardAccess> probeDashboardAccess(
  SavedConnection connection, {
  http.Client? httpClient,
}) async {
  final url = connection.effectiveDashboardUrl;
  if (TransportPrivacy.classify(url) == TransportPrivacyClass.publicCleartext) {
    return DashboardAccess.unknown; // Policy refusal: nothing is sent.
  }
  final client = httpClient ?? http.Client();
  DashboardClient? dashboard;
  try {
    final base = TransportPrivacy.requireAllowed(url);
    final request = http.Request('GET', Uri.parse('$base/api/status'))
      ..followRedirects = false;
    final response = await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return DashboardAccess.unknown;
    final payload = jsonDecode(response.body);
    if (payload is! Map || payload['auth_required'] is! bool) {
      return DashboardAccess.unknown;
    }
    final gated = payload['auth_required'] as bool;
    dashboard = DashboardClient.lazy(
      connection,
      httpClientOverride: httpClient,
    );
    final verified = await dashboard.apiGet(gated ? 'auth/me' : 'profiles');
    if (!gated && verified['profiles'] is! List) {
      return DashboardAccess.needsSignIn;
    }
    return DashboardAccess.ready;
  } on DashboardAuthException catch (error) {
    return error.code == DashboardAuthFailureCode.rateLimited
        ? DashboardAccess.unknown
        : DashboardAccess.needsSignIn;
  } on MobileOAuthException catch (error) {
    // Only a session that is over needs a sign-in; a refresh that could not
    // be tried (provider down, no network, storage busy) says nothing.
    return error is NativeSessionExpired ||
            error.runtimeType == MobileOAuthException
        ? DashboardAccess.needsSignIn
        : DashboardAccess.unknown;
  } on DashboardHttpException catch (error) {
    return error.statusCode == 401 || error.statusCode == 403
        ? DashboardAccess.needsSignIn
        : DashboardAccess.unknown;
  } catch (_) {
    // Type only would still be noise here: no verdict is a normal outcome.
    return DashboardAccess.unknown;
  } finally {
    dashboard?.close();
    if (httpClient == null) client.close();
  }
}

/// Retires what a bridge-era install (≤ 1.2.14) left on this phone.
///
/// A legacy install is recognised by exactly these leftovers:
///  * Keystore `bridge_url_<connectionId>` and `bridge_token_<connectionId>`;
///  * the loose preference `bridge_auto_update`.
///
/// The first run after updating probes each instance's Dashboard once with
/// the credentials it has, stores what it learned, and only then deletes
/// those leftovers (every Keystore and preference key that starts with
/// `bridge_`: nothing else uses the prefix). Every step is written down
/// before the next one starts, so an app killed at any point repeats at most
/// the step it was in: it never forgets that this was a legacy install and
/// never deletes before the verdicts are stored.
/// What it learned is kept so the notices are said once and never again.
class LegacyBridgeRetirement {
  LegacyBridgeRetirement({
    required this.prefs,
    SecureStorage? secureStorage,
    DashboardAccessProbe? probe,
  }) : _secure = secureStorage ?? SecureStorage(),
       _probe = probe ?? probeDashboardAccess;

  static const stateKey = 'legacy_bridge_retirement_v1';
  static const legacyPrefix = 'bridge_';

  /// The exact leftovers of ≤ 1.2.14, for the record and the tests.
  static const legacyPreference = 'bridge_auto_update';
  static String legacyUrlKey(String connectionId) => 'bridge_url_$connectionId';
  static String legacyTokenKey(String connectionId) =>
      'bridge_token_$connectionId';

  /// A phone that is off its private network at the first launch gets a few
  /// more silent tries on later launches; then it stops asking.
  static const maxProbeAttempts = 4;

  final SharedPreferences prefs;
  final SecureStorage _secure;
  final DashboardAccessProbe _probe;

  Map<String, Object?> _read() {
    final raw = prefs.getString(stateKey);
    if (raw == null) return <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Unreadable state is no state: the leftovers are looked for again.
    }
    return <String, Object?>{};
  }

  Future<void> _write(Map<String, Object?> state) =>
      prefs.setString(stateKey, jsonEncode(state));

  /// Null until [run] has looked once.
  bool? get legacyInstall => _read()['legacy'] as bool?;

  bool get removalNoticeDone => _read()['removal_done'] == true;

  /// True once the leftovers are deleted. Nothing looks for them again.
  bool get leftoversDeleted => _read()['purged'] == true;

  Map<String, DashboardAccess> get access => {
    for (final entry in _accessOf(_read()).entries)
      entry.key: DashboardAccess.fromStorage(entry.value),
  };

  Set<String> get signInNoticeDone => _doneOf(_read());

  static Map<String, Object?> _accessOf(Map<String, Object?> state) {
    final value = state['access'];
    return value is Map ? value.cast<String, Object?>() : <String, Object?>{};
  }

  static Set<String> _doneOf(Map<String, Object?> state) {
    final value = state['sign_in_done'];
    return value is List ? value.whereType<String>().toSet() : <String>{};
  }

  /// Looks for the leftovers (first time only), probes what still has no
  /// verdict and deletes the leftovers. Safe to call on every launch: once
  /// there is nothing left to learn it reads its own state and does nothing.
  Future<void> run(List<SavedConnection> connections) async {
    final state = _read();
    var legacy = state['legacy'] as bool?;
    if (legacy == false) return;
    if (legacy == null) {
      final secrets = await _secure.legacyBridgeKeys();
      final loose = prefs.getKeys().where((k) => k.startsWith(legacyPrefix));
      legacy = secrets.isNotEmpty || loose.isNotEmpty;
      state['legacy'] = legacy;
      // Written before anything else happens: from here on the leftovers
      // are no longer the only record that this was a bridge-era install.
      await _write(state);
      if (!legacy) return;
    }
    final access = _accessOf(state);
    final attempts = (state['attempts'] as num?)?.toInt() ?? 0;
    final pending = connections
        .where(
          (c) =>
              DashboardAccess.fromStorage(access[c.id]) ==
              DashboardAccess.unknown,
        )
        .toList(growable: false);
    if (pending.isNotEmpty && attempts < maxProbeAttempts) {
      for (final connection in pending) {
        DashboardAccess verdict;
        try {
          verdict = await _probe(connection);
        } catch (_) {
          verdict = DashboardAccess.unknown;
        }
        access[connection.id] = verdict.storageKey;
      }
      state['access'] = access;
      state['attempts'] = attempts + 1;
      await _write(state);
    }
    if (state['purged'] == true) return;
    // Only now: the verdicts above are already stored. The probe never needs
    // the leftovers and nothing else reads them.
    await _secure.deleteLegacyBridgeKeys();
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(legacyPrefix)).toList()) {
      await prefs.remove(key);
    }
    state['purged'] = true;
    await _write(state);
  }

  /// The instance to say "one step left" about, if any: one that answered
  /// without a working sign-in and was not said yet. The active one first.
  SavedConnection? signInCandidate(
    List<SavedConnection> connections,
    String? activeConnectionId,
  ) {
    if (legacyInstall != true) return null;
    final verdicts = access;
    final done = signInNoticeDone;
    final waiting = connections
        .where(
          (c) =>
              verdicts[c.id] == DashboardAccess.needsSignIn &&
              !done.contains(c.id),
        )
        .toList(growable: false);
    if (waiting.isEmpty) return null;
    return waiting.firstWhere(
      (c) => c.id == activeConnectionId,
      orElse: () => waiting.first,
    );
  }

  /// True when the phone talks to Hermes directly and the old bridge can be
  /// told goodbye: a legacy install, nothing waiting for a step, at least
  /// one instance verified, and not said before.
  bool shouldOfferRemoval(List<SavedConnection> connections) {
    if (legacyInstall != true || removalNoticeDone) return false;
    if (signInCandidate(connections, null) != null) return false;
    final verdicts = access;
    return connections.any((c) => verdicts[c.id] == DashboardAccess.ready);
  }

  /// The "one step left" notice of [connectionId] was dismissed or solved.
  Future<void> markSignInNoticeDone(
    String connectionId, {
    bool solved = false,
  }) async {
    final state = _read();
    state['sign_in_done'] = ({..._doneOf(state), connectionId}).toList()
      ..sort();
    if (solved) {
      state['access'] = _accessOf(state)
        ..[connectionId] = DashboardAccess.ready.storageKey;
    }
    await _write(state);
  }

  Future<void> markRemovalNoticeDone() async {
    final state = _read();
    state['removal_done'] = true;
    await _write(state);
  }
}
