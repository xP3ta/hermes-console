// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'connection_manager.dart';

/// «Your Hermes is starting»: a Dashboard answering 502/503/504 (or refusing
/// right after answering) is booting, not refusing the credential. Desktop
/// waits a bounded time on a short probe and never reads a 5xx as reauth
/// (`backend-health.ts:7-14`, `:126-180`). Console: `GET /api/health` every 1 s
/// for 10 s, then every 3 s (battery), 5 s per probe, 180 s in total.

const serverWarmupBudget = Duration(seconds: 180);
const serverWarmupFastWindow = Duration(seconds: 10);
const serverWarmupFastInterval = Duration(seconds: 1);
const serverWarmupSlowInterval = Duration(seconds: 3);
const serverWarmupProbeTimeout = Duration(seconds: 5);

/// 502/503/504 only (401/403 are credentials; 500/404/429 something else). A
/// refresh 503 ([NativeRefreshTransient]) is not one: it keeps S1's cooldown.
bool isServerStartingError(Object error) {
  final code = switch (error) {
    DashboardHttpException(:final statusCode) => statusCode,
    DashboardWebSocketAuthException(:final statusCode) => statusCode,
    _ => null,
  };
  return code == 502 || code == 503 || code == 504;
}

/// ECONNREFUSED (Linux/Android 111, macOS 61, Windows 10061).
bool isConnectionRefused(Object error) =>
    error is SocketException &&
    const {111, 61, 10061}.contains(error.osError?.errorCode);

/// Desktop `isNousCloudAgentUrl` (backend-health.ts:168-176).
bool isNousCloudHost(String host) {
  final h = host.toLowerCase();
  return h.endsWith('.agents.nousresearch.com') &&
      h.length > '.agents.nousresearch.com'.length;
}

/// `GET /api/health` (public) answered 200. Never follows redirects.
Future<bool> dashboardHealthOk(http.Client client, String base) async {
  try {
    final request = http.Request('GET', Uri.parse('$base/api/health'))
      ..followRedirects = false;
    final response = await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(serverWarmupProbeTimeout);
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

enum ServerWarmupPhase { idle, waiting, gaveUp, ready }

/// Test seam for time.
class ServerWarmupClock {
  const ServerWarmupClock({required this.now, required this.delay});
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
}

/// One bounded wait; nothing is probed (or counted) while the app is hidden.
class ServerWarmup extends ChangeNotifier {
  ServerWarmup({
    required this.probe,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    bool foreground = true,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed {
    _foreground = foreground;
  }

  final Future<bool> Function() probe;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  ServerWarmupPhase _phase = ServerWarmupPhase.idle;
  ServerWarmupPhase get phase => _phase;

  bool _foreground = true;
  int _generation = 0;
  Completer<void>? _resume;
  Duration _accum = Duration.zero;
  DateTime? _activeSince;

  Duration get _elapsed =>
      _accum +
      (_activeSince == null ? Duration.zero : _now().difference(_activeSince!));

  void _set(ServerWarmupPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    notifyListeners();
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      if (_phase == ServerWarmupPhase.waiting) _activeSince = _now();
      final resume = _resume;
      _resume = null;
      if (resume != null && !resume.isCompleted) resume.complete();
    } else if (_activeSince != null) {
      _accum += _now().difference(_activeSince!);
      _activeSince = null;
    }
  }

  void cancel() {
    _generation++;
    _activeSince = null;
    final resume = _resume;
    _resume = null;
    if (resume != null && !resume.isCompleted) resume.complete();
    if (_phase == ServerWarmupPhase.waiting) _set(ServerWarmupPhase.idle);
  }

  /// A fresh 180 s wait: true when the server answered 200, false when the
  /// budget ended or [cancel] was called.
  Future<bool> run() async {
    final generation = ++_generation;
    _accum = Duration.zero;
    _activeSince = _foreground ? _now() : null;
    _set(ServerWarmupPhase.waiting);
    while (true) {
      if (generation != _generation) return false;
      if (!_foreground) {
        final resume = _resume ??= Completer<void>();
        await resume.future;
        continue;
      }
      var ok = false;
      try {
        ok = await probe().timeout(serverWarmupProbeTimeout);
      } catch (_) {}
      if (generation != _generation) return false;
      if (ok) {
        _activeSince = null;
        _set(ServerWarmupPhase.ready);
        return true;
      }
      if (!_foreground) continue;
      final elapsed = _elapsed;
      if (elapsed >= serverWarmupBudget) {
        _activeSince = null;
        _set(ServerWarmupPhase.gaveUp);
        return false;
      }
      await _delay(
        elapsed < serverWarmupFastWindow
            ? serverWarmupFastInterval
            : serverWarmupSlowInterval,
      );
    }
  }
}
