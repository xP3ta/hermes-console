// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'connection_manager.dart';
import 'legacy_bridge_retirement.dart';
import 'secure_storage.dart';

/// The one notice for connections that came from the Gateway era.
///
/// The first launch that has this class takes a photo of the connections
/// that already held a Gateway key; only those can ever be told. Each one
/// is said once (or never, if its Dashboard already answers).
class GatewayEraNotice {
  GatewayEraNotice({
    required this.prefs,
    SecureStorage? secureStorage,
    DashboardAccessProbe? probe,
  }) : _secure = secureStorage ?? SecureStorage(),
       _probe = probe ?? probeDashboardAccess;

  static const stateKey = 'gateway_era_notice_v1';

  final SharedPreferences prefs;
  final SecureStorage _secure;
  final DashboardAccessProbe _probe;

  Map<String, Object?> _read() {
    try {
      final decoded = jsonDecode(prefs.getString(stateKey) ?? '{}');
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, Object?>{};
  }

  Set<String> _ids(String field) {
    final value = _read()[field];
    return value is List ? value.whereType<String>().toSet() : <String>{};
  }

  Future<void> _put(String field, Set<String> ids) =>
      prefs.setString(stateKey, jsonEncode(_read()..[field] = ids.toList()));

  /// Written before anything is probed. Read from the Keystore itself, not
  /// from the manager's cache, which may still be loading.
  Future<void> snapshotIfNeeded(List<SavedConnection> connections) async {
    if (_read()['snapshot'] is List) return;
    final ids = <String>{};
    for (final c in connections) {
      final key = await _secure.readApiKey(c.id);
      if (key != null && key.trim().isNotEmpty) ids.add(c.id);
    }
    await _put('snapshot', ids);
  }

  bool hasPending(List<SavedConnection> connections) {
    final snapshot = _ids('snapshot');
    final done = _ids('done');
    return connections.any(
      (c) => snapshot.contains(c.id) && !done.contains(c.id),
    );
  }

  Future<void> markDone(String id) => _put('done', {..._ids('done'), id});

  Future<DashboardAccess> check(SavedConnection connection) async {
    try {
      return await _probe(connection);
    } catch (_) {
      return DashboardAccess.unknown;
    }
  }

  /// At most one connection per launch, the active one first: the one to
  /// tell and what its Dashboard said. [resolved] (already handled by the
  /// bridge notices) and a Dashboard that answers are closed in silence.
  Future<({SavedConnection connection, DashboardAccess access})?> candidate(
    List<SavedConnection> connections,
    String? activeId, {
    Set<String> resolved = const {},
  }) async {
    final snapshot = _ids('snapshot');
    final done = _ids('done');
    final waiting = <SavedConnection>[];
    for (final c in connections) {
      if (!snapshot.contains(c.id) || done.contains(c.id)) continue;
      resolved.contains(c.id) ? await markDone(c.id) : waiting.add(c);
    }
    if (waiting.isEmpty) return null;
    final pick = waiting.firstWhere(
      (c) => c.id == activeId,
      orElse: () => waiting.first,
    );
    final access = await check(pick);
    if (access != DashboardAccess.ready) {
      return (connection: pick, access: access);
    }
    await markDone(pick.id);
    return null;
  }
}
