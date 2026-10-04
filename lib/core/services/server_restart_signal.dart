import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Remembers, in memory and per host, that the server said its process runs
/// older code than the checkout on disk ("Restart required").
///
/// Nothing is requested to learn it: the model calls Console already makes
/// fail with REST 503 `Restart required: …` (`/api/model/options`,
/// `/api/model/set`) or RPC error 5098 (`model.options`), and those handlers
/// only report what they saw. Diagnostics shows the note. Never persisted.
abstract final class ServerRestartSignals {
  static final Map<String, String> _byHost = {};

  /// REST: a 503 whose `detail` starts with `Restart required:`.
  static void noteHttp(String host, int statusCode, String body) {
    if (statusCode != 503) return;
    try {
      final decoded = jsonDecode(body);
      final detail = decoded is Map ? decoded['detail'] : null;
      if (detail is String && detail.trim().startsWith('Restart required:')) {
        _remember(host, detail);
      }
    } catch (_) {
      // Not the server's JSON error body: nothing to remember.
    }
  }

  /// RPC: error 5098 (`model.options` on a stale process).
  static void noteRpc(String host, int? code, String message) {
    if (code == 5098) _remember(host, message);
  }

  /// The note for the first of [hosts] that has one.
  static String? textFor(Iterable<String> hosts) {
    for (final host in hosts) {
      final text = _byHost[_key(host)];
      if (text != null) return text;
    }
    return null;
  }

  @visibleForTesting
  static void resetForTesting() => _byHost.clear();

  static String _key(String host) => host.trim().toLowerCase();

  /// One bounded line without paths: tokens holding a `/` or `\` go.
  static void _remember(String host, String raw) {
    final text = raw
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .where((word) => !word.contains('/') && !word.contains(r'\'))
        .join(' ');
    final bounded = text.length <= 240 ? text : text.substring(0, 240);
    _byHost[_key(host)] = bounded.isEmpty ? 'Restart required' : bounded;
  }
}
