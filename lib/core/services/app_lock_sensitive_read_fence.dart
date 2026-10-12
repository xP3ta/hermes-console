// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unavailable is not an empty draft or a successful mutation.
class SensitiveReadUnavailable implements Exception {
  const SensitiveReadUnavailable();
}

/// Isolate-local disclosure authority. A headless engine has no issuer and
/// therefore cannot inherit a foreground unlock. Tickets are never renewed.
class AppLockSensitiveReadFence {
  static Object? _issuer;
  static SharedPreferences? _prefs;
  static ValueListenable<bool>? _locked;
  static int _generation = 0;
  static bool _foreground = true;
  static final changes = _DisclosureChanges();
  static final Object _zoneKey = Object();

  static void bind(
    Object issuer,
    SharedPreferences prefs,
    ValueListenable<bool> locked,
  ) {
    _locked?.removeListener(_changed);
    _issuer = issuer;
    _prefs = prefs;
    _locked = locked;
    _foreground = true;
    _generation++;
    // AppLockService notifier advances generation before publishing changes.
    changes.changed();
  }

  static void configurationChanged(Object issuer) {
    if (identical(issuer, _issuer)) _changed();
  }

  static void foreground(Object issuer, bool value) {
    if (!identical(issuer, _issuer) || _foreground == value) return;
    _foreground = value;
    _changed();
  }

  static void unbind(Object issuer) {
    if (!identical(issuer, _issuer)) return;
    _locked?.removeListener(_changed);
    _issuer = null;
    _locked = null;
    _changed();
  }

  static void _changed() {
    _generation++;
    changes.changed();
  }

  static SensitiveReadTicket capture([SharedPreferences? prefs]) =>
      SensitiveReadTicket._(_issuer, _generation, prefs ?? _prefs);

  static SensitiveReadTicket get current =>
      Zone.current[_zoneKey] as SensitiveReadTicket? ?? capture();

  static Future<T> recover<T>(Future<T> Function() body) =>
      runZoned(() => Future<T>.sync(body), zoneValues: {_zoneKey: capture()});

  static Future<T> run<T>(SharedPreferences prefs, Future<T> Function() body) {
    final ticket =
        Zone.current[_zoneKey] as SensitiveReadTicket? ?? capture(prefs);
    return runWithTicket(ticket, body);
  }

  /// Carry the original execution authority across an explicit async boundary.
  /// Never capture a successor unlock on behalf of a revoked execution.
  static Future<T> runWithTicket<T>(
    SensitiveReadTicket ticket,
    Future<T> Function() body,
  ) => runZoned(
    () => Future<T>.sync(() {
      ticket.ensureCurrent();
      return body();
    }),
    zoneValues: {_zoneKey: ticket},
  );
}

class _DisclosureChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class SensitiveReadTicket {
  SensitiveReadTicket._(this._issuer, this._generation, this._prefs);
  final Object? _issuer;
  final int _generation;
  final SharedPreferences? _prefs;

  bool get issuerIsCurrent =>
      identical(_issuer, AppLockSensitiveReadFence._issuer);

  bool get isCurrent {
    if (_generation != AppLockSensitiveReadFence._generation ||
        !identical(_issuer, AppLockSensitiveReadFence._issuer)) {
      return false;
    }
    if (identical(_prefs, AppLockSensitiveReadFence._prefs) &&
        AppLockSensitiveReadFence._locked?.value == true) {
      return false;
    }
    final enabled = _prefs?.getBool('app_lock_enabled') ?? false;
    if (!enabled) return true;
    return _issuer != null &&
        AppLockSensitiveReadFence._foreground &&
        identical(_prefs, AppLockSensitiveReadFence._prefs) &&
        AppLockSensitiveReadFence._locked?.value == false;
  }

  void ensureCurrent() {
    if (!isCurrent) throw const SensitiveReadUnavailable();
  }
}
