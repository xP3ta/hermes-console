import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';
import 'connection_manager.dart';
import 'hermes_update_monitor.dart';

/// Data sources that follow a server update of [connection]. They use their
/// own Dashboard client (closed with the session), because the session
/// outlives the screen that started it.
HermesUpdateProbes hermesUpdateProbesFor(
  SavedConnection connection,
  HermesUpdateSession session,
) {
  final client = DashboardClient.lazy(connection);
  session.result.whenComplete(client.close);
  Future<Map<String, dynamic>?> publicStatus() async {
    try {
      final base = connection.effectiveDashboardUrl.replaceAll(
        RegExp(r'/+$'),
        '',
      );
      final res = await http
          .get(Uri.parse(TransportPrivacy.requireAllowed('$base/api/status')))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  return HermesUpdateProbes(
    actionStatus: () async {
      try {
        return await client.getUpdateActionStatus();
      } on DashboardHttpException catch (e) {
        if (e.statusCode == 404) throw const HermesUpdateEndpointMissing();
        rethrow;
      }
    },
    serverStatus: publicStatus,
    updateStillAvailable: () async {
      try {
        final check = await client.checkUpdate(force: true);
        final available = check['update_available'];
        return available is bool ? available : null;
      } catch (_) {
        return null;
      }
    },
  );
}

/// Resumes every server update persisted before Android killed the process
/// (cold start, back to foreground, App Lock opened). Updates of deleted
/// connections are dropped. Callers gate this on App Lock.
Future<void> resumePersistedHermesUpdates(
  Iterable<SavedConnection> connections,
) async {
  try {
    for (final id in await HermesUpdateSession.persistedConnectionIds()) {
      SavedConnection? connection;
      for (final candidate in connections) {
        if (candidate.id == id) connection = candidate;
      }
      if (connection == null) {
        await HermesUpdateSession.discardPersisted(id);
        continue;
      }
      final session = await HermesUpdateSession.resumePersisted(id);
      if (session == null) continue;
      unawaited(session.track(hermesUpdateProbesFor(connection, session)));
    }
  } catch (error) {
    debugPrint('[hermes-update] resume failed (${error.runtimeType})');
  }
}
