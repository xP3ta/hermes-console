// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import 'dashboard_setup_screen.dart';

/// Opens the existing Dashboard sign-in for a saved instance and stores what
/// it returns exactly where the instance editor stores it: the auth mode in
/// the connection, the secrets in the Dashboard Keystore slots. Returns true
/// when the instance ends up signed in. Nothing is created or rotated on the
/// server.
Future<bool> signInToDashboard(
  NavigatorState navigator,
  ConnectionManager manager,
  SavedConnection connection,
) async {
  final id = connection.id;
  final revision = manager.connectionRevisionFor(id).value;
  final profile = manager.activeProfileRevisionFor(id).value;
  bool current() =>
      manager.connectionRevisionFor(id).value == revision &&
      manager.activeProfileRevisionFor(id).value == profile;
  final result = await navigator.push<DashboardCredsResult>(
    MaterialPageRoute(
      builder: (_) => DashboardSetupScreen(
        connection: connection,
        authorityCurrent: current,
      ),
    ),
  );
  if (result == null || !current()) return false;
  SavedConnection? latest;
  for (final saved in manager.getConnections()) {
    if (saved.id == id) latest = saved;
  }
  if (latest == null) return false;
  await storeDashboardSignIn(manager, latest, result);
  return true;
}

/// Mode first, then secrets. When the secrets cannot be stored the previous
/// mode comes back, so an instance that still holds its password is not left
/// in session-token mode with nothing to use.
@visibleForTesting
Future<void> storeDashboardSignIn(
  ConnectionManager manager,
  SavedConnection latest,
  DashboardCredsResult result,
) async {
  await manager.upsertConnection(
    latest.copyWith(dashboardAuthMode: result.mode),
  );
  try {
    await manager.setDashboardSecrets(
      latest.id,
      sessionToken: result.sessionToken.isEmpty ? null : result.sessionToken,
      username: result.username.isEmpty ? null : result.username,
      password: result.password.isEmpty ? null : result.password,
    );
  } catch (_) {
    try {
      await manager.upsertConnection(latest);
    } catch (_) {
      // Keep the original failure; the revision bump already refreshed readers.
    }
    rethrow;
  }
}
