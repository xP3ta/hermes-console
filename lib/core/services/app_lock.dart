import 'dart:convert';
import 'dart:math';

import 'app_lock_sensitive_read_fence.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bloqueo local opcional de la app: PIN propio (hash+salt en Keystore) con
/// desbloqueo biométrico opcional encima.
///
/// El PIN nunca se guarda en claro: PBKDF2-HMAC-SHA256(pin, salt, 100k) en
/// flutter_secure_storage (prefijo `pbkdf2:`). Los PINs antiguos en SHA-256 se
/// migran de forma transparente al verificarse. La biometría la verifica el
/// sistema vía local_auth; la app no toca datos biométricos.
class AppLockService {
  static const _kEnabled = 'app_lock_enabled';
  static const _kBiometric = 'app_lock_biometric';
  static const _kTimeoutSeconds = 'app_lock_timeout_s';

  static const _kPinSalt = 'app_lock_pin_salt';
  static const _kPinHash = 'app_lock_pin_hash';
  static const _kCooldownUntil = 'app_lock_cooldown_until';

  /// Intentos fallidos consecutivos antes de aplicar espera.
  static const maxAttemptsBeforeCooldown = 5;
  static const cooldown = Duration(seconds: 30);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _storage;
  final LocalAuthentication _localAuth;

  /// Estado observable: true mientras la app está bloqueada.
  late final ValueNotifier<bool> locked = _DisclosureLockNotifier(
    () => AppLockSensitiveReadFence.configurationChanged(this),
  );

  int _failedAttempts = 0;
  DateTime? _cooldownUntil;
  DateTime? _backgroundedAt;

  /// true mientras el prompt biométrico del sistema está abierto — evita que
  /// el ciclo inactive/resumed que provoca el propio prompt re-bloquee la app.
  bool authInProgress = false;

  AppLockService(
    this._prefs, {
    FlutterSecureStorage? storage,
    LocalAuthentication? localAuth,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _localAuth = localAuth ?? LocalAuthentication() {
    locked.value = enabled;
    AppLockSensitiveReadFence.bind(this, _prefs, locked);
    _loadCooldown();
  }

  /// Restaura el cooldown persistido tras un reinicio: si la app se mató durante
  /// la espera por intentos fallidos, el rate-limit del PIN no debe resetearse.
  Future<void> _loadCooldown() async {
    try {
      final saved = await _storage.read(key: _kCooldownUntil);
      if (saved == null) return;
      final until = DateTime.tryParse(saved);
      if (until != null && until.isAfter(DateTime.now())) {
        _cooldownUntil = until;
      } else {
        await _storage.delete(key: _kCooldownUntil);
      }
    } catch (e) {
      debugPrint('[app-lock] excepción silenciada (se ignora sin más): $e');
    }
  }

  bool get enabled => _prefs.getBool(_kEnabled) ?? false;
  bool get biometricEnabled => _prefs.getBool(_kBiometric) ?? false;

  /// Segundos en segundo plano antes de volver a bloquear. 0 = al instante.
  int get timeoutSeconds => _prefs.getInt(_kTimeoutSeconds) ?? 60;

  Future<void> setTimeoutSeconds(int seconds) =>
      _prefs.setInt(_kTimeoutSeconds, seconds);

  Future<void> setBiometricEnabled(bool value) =>
      _prefs.setBool(_kBiometric, value);

  /// Activa el bloqueo. El PIN debe haberse configurado antes con [setPin].
  Future<void> enable() async {
    assert(await hasPin(), 'enable() requiere un PIN configurado');
    AppLockSensitiveReadFence.configurationChanged(this);
    await _prefs.setBool(_kEnabled, true);
    AppLockSensitiveReadFence.configurationChanged(this);
  }

  /// Desactiva el bloqueo y elimina el PIN y sus flags.
  Future<void> disable() async {
    AppLockSensitiveReadFence.configurationChanged(this);
    await _prefs.setBool(_kEnabled, false);
    AppLockSensitiveReadFence.configurationChanged(this);
    await _prefs.setBool(_kBiometric, false);
    await _storage.delete(key: _kPinSalt);
    await _storage.delete(key: _kPinHash);
    locked.value = false;
  }

  Future<bool> hasPin() async {
    final hash = await _storage.read(key: _kPinHash);
    return hash != null && hash.isNotEmpty;
  }

  /// Hash legado SHA-256(salt || pin). Se conserva solo para verificar y migrar
  /// PINs creados antes de PBKDF2.
  static String _hashPin(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt$pin')).toString();

  /// PBKDF2-HMAC-SHA256: 100 000 iteraciones, output 32 bytes.
  /// Implementado sobre el paquete `crypto` ya disponible (sin dependencias
  /// nuevas).
  static List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, password);
    // Bloque 1 (DK len ≤ 32 bytes → un solo bloque)
    final saltBlock = Uint8List(salt.length + 4)
      ..setAll(0, salt)
      ..[salt.length] = 0
      ..[salt.length + 1] = 0
      ..[salt.length + 2] = 0
      ..[salt.length + 3] = 1;
    var u = hmac.convert(saltBlock).bytes;
    final dk = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < dk.length; j++) {
        dk[j] ^= u[j];
      }
    }
    return dk;
  }

  static String _hashPinPbkdf2(String salt, String pin) {
    final saltBytes = base64Decode(salt);
    final pinBytes = utf8.encode(pin);
    final dk = _pbkdf2(pinBytes, saltBytes, 100000);
    return 'pbkdf2:${base64Encode(dk)}'; // prefijo para distinguir del antiguo
  }

  Future<void> setPin(String pin) async {
    final saltBytes = List<int>.generate(
      16,
      (_) => Random.secure().nextInt(256),
    );
    final salt = base64Encode(saltBytes);
    await _storage.write(key: _kPinSalt, value: salt);
    await _storage.write(key: _kPinHash, value: _hashPinPbkdf2(salt, pin));
  }

  /// Segundos restantes de espera por intentos fallidos; 0 si se puede probar.
  int get cooldownRemaining {
    final until = _cooldownUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 0;
  }

  Future<bool> verifyPin(String pin) async {
    if (cooldownRemaining > 0) return false;
    final salt = await _storage.read(key: _kPinSalt);
    final hash = await _storage.read(key: _kPinHash);
    if (salt == null || hash == null) return false;

    bool ok;
    if (hash.startsWith('pbkdf2:')) {
      ok = _hashPinPbkdf2(salt, pin) == hash;
    } else {
      // Hash antiguo SHA-256 — verifica y migra si es correcto.
      ok = _hashPin(salt, pin) == hash;
      if (ok) {
        // Regenera salt y migra a PBKDF2.
        final saltBytes = List<int>.generate(
          16,
          (_) => Random.secure().nextInt(256),
        );
        final newSalt = base64Encode(saltBytes);
        await _storage.write(key: _kPinSalt, value: newSalt);
        await _storage.write(
          key: _kPinHash,
          value: _hashPinPbkdf2(newSalt, pin),
        );
      }
    }

    if (ok) {
      _failedAttempts = 0;
      _cooldownUntil = null;
      await _storage.delete(key: _kCooldownUntil);
    } else {
      _failedAttempts++;
      if (_failedAttempts >= maxAttemptsBeforeCooldown) {
        _cooldownUntil = DateTime.now().add(cooldown);
        _failedAttempts = 0;
        await _storage.write(
          key: _kCooldownUntil,
          value: _cooldownUntil!.toIso8601String(),
        );
      }
    }
    return ok;
  }

  /// ¿Hay biometría utilizable en este dispositivo?
  Future<bool> canUseBiometrics() async {
    try {
      final supported = await _localAuth.isDeviceSupported();
      final canCheck = await _localAuth.canCheckBiometrics;
      return supported && canCheck;
    } catch (e) {
      debugPrint('[app-lock] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  /// Lanza el prompt biométrico del sistema. true si el usuario verificó.
  Future<bool> authenticateBiometric({required String reason}) async {
    authInProgress = true;
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (e) {
      debugPrint('[app-lock] excepción silenciada (se asume false): $e');
      return false;
    } finally {
      authInProgress = false;
    }
  }

  void unlock() {
    _failedAttempts = 0;
    locked.value = false;
  }

  void lockNow() {
    if (enabled) locked.value = true;
  }

  // ── Ciclo de vida (llamado por AppLockGate) ───────────────────────────

  void releaseDisclosure() => AppLockSensitiveReadFence.unbind(this);

  void onAppPaused() {
    AppLockSensitiveReadFence.foreground(this, false);
    if (!enabled || authInProgress) return;
    _backgroundedAt ??= DateTime.now();
  }

  void onAppResumed() {
    final at = _backgroundedAt;
    _backgroundedAt = null;
    if (!enabled || authInProgress || at == null) {
      AppLockSensitiveReadFence.foreground(this, true);
      return;
    }
    final elapsed = DateTime.now().difference(at).inSeconds;
    if (elapsed >= timeoutSeconds) locked.value = true;
    AppLockSensitiveReadFence.foreground(this, true);
  }
}

class _DisclosureLockNotifier extends ValueNotifier<bool> {
  _DisclosureLockNotifier(this._changed) : super(false);
  final VoidCallback _changed;
  bool _state = false;
  @override
  bool get value => _state;
  @override
  set value(bool value) {
    if (_state == value) return;
    _state = value;
    _changed();
    notifyListeners();
  }
}
