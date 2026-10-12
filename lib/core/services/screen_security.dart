import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Controla FLAG_SECURE en Android para impedir capturas, grabación de pantalla
/// y miniaturas recientes cuando el usuario lo activa.
class ScreenSecurityService {
  static const prefKey = 'security_block_screenshots';
  static const _channel = MethodChannel('hermes/security');

  final SharedPreferences _prefs;

  ScreenSecurityService(this._prefs);

  bool get enabled => _prefs.getBool(prefKey) ?? false;

  /// Pages that must never be captured (terminal, backups) holding a scope.
  /// Shared by every instance: the flag is a property of the window.
  static int _scopes = 0;

  /// Secure while the user asked for it or a sensitive page is visible.
  bool get effective => enabled || _scopes > 0;

  /// Forces FLAG_SECURE on until the returned lease is released, whatever the
  /// global preference says. Ref-counted so nested pages cannot turn it off
  /// early; the global preference itself is never changed.
  Future<SecureScopeLease> pushSecureScope() async {
    _scopes += 1;
    await apply();
    return SecureScopeLease._(this);
  }

  Future<void> apply() async {
    try {
      await _channel.invokeMethod<void>('setSecureScreen', effective);
    } on MissingPluginException {
      // Tests y plataformas no Android: la preferencia se conserva sin fallar.
    } on PlatformException {
      // Protección best-effort; nunca debe impedir abrir la app.
    }
  }

  Future<void> setEnabled(bool value) async {
    await _prefs.setBool(prefKey, value);
    await apply();
  }
}

/// Handle of one [ScreenSecurityService.pushSecureScope]; releasing it twice
/// is harmless.
class SecureScopeLease {
  SecureScopeLease._(this._service);

  final ScreenSecurityService _service;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    ScreenSecurityService._scopes -= 1;
    await _service.apply();
  }
}
