import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import 'connection_manager.dart';
import 'secure_storage.dart';

/// Método de autenticación SSH elegido por instancia.
enum SshAuthMethod {
  key('key', 'Private key'),
  password('password', 'Password');

  const SshAuthMethod(this.id, this.label);

  final String id;
  final String label;

  static SshAuthMethod fromId(String? v) =>
      values.firstWhere((m) => m.id == v, orElse: () => SshAuthMethod.key);
}

/// Configuración SSH (metadata no secreta) de una instancia. Los secretos
/// (contraseña / clave / passphrase) nunca salen del Keystore.
class SshConfig {
  final String host;
  final int port;
  final String username;
  final SshAuthMethod method;

  const SshConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.method,
  });

  String get target => '$username@$host:$port';
}

/// Datos del prompt de verificación de host key (TOFU). La pantalla decide si
/// confía: primera vez ([isNew]) o el fingerprint cambió ([changed], posible
/// MITM).
class SshHostKeyPrompt {
  final String type;
  final String fingerprint;
  final bool isNew;
  final bool changed;

  const SshHostKeyPrompt({
    required this.type,
    required this.fingerprint,
    required this.isNew,
    required this.changed,
  });
}

/// Error de configuración (no de red) al preparar una conexión SSH.
class SshConfigException implements Exception {
  final String message;
  const SshConfigException(this.message);
  @override
  String toString() => message;
}

/// Resuelve credenciales, deriva el host del gateway, gestiona el TOFU de host
/// keys y construye el [SSHClient] para terminal/SFTP. Centraliza todo el SSH
/// igual que [BridgeManager] hace con el Mobile Bridge.
///
/// Autodetección: si el usuario no fija un host, se usa el del gateway de la
/// instancia (puerto 22 por defecto). Solo se teclea usuario + credencial.
class SshManager {
  final SecureStorage _secure;
  final ConnectionManager _connections;

  SshManager(this._secure, this._connections);

  static const int defaultPort = 22;

  SavedConnection? _conn(String id) {
    for (final c in _connections.getConnections()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Host que se derivaría del gateway de la instancia (sin mirar lo guardado).
  String? derivedHostFor(String connectionId) => _conn(connectionId)?.host;

  /// true si la instancia es solo lectura (SFTP no debe escribir).
  bool isReadOnly(String connectionId) => _conn(connectionId)?.readOnly ?? false;

  /// Carga la config SSH guardada, o null si la instancia no tiene SSH.
  Future<SshConfig?> loadConfig(String connectionId) async {
    final user = (await _secure.readSsh(connectionId, 'user'))?.trim();
    if (user == null || user.isEmpty) return null;
    final storedHost = (await _secure.readSsh(connectionId, 'host'))?.trim();
    final host = (storedHost != null && storedHost.isNotEmpty)
        ? storedHost
        : (derivedHostFor(connectionId) ?? '');
    final port =
        int.tryParse((await _secure.readSsh(connectionId, 'port')) ?? '') ??
            defaultPort;
    final method = SshAuthMethod.fromId(
      await _secure.readSsh(connectionId, 'method'),
    );
    return SshConfig(host: host, port: port, username: user, method: method);
  }

  /// Guarda config + credencial. Pasa solo el secreto del método elegido.
  Future<void> saveConfig(
    String connectionId, {
    required String host,
    required int port,
    required String username,
    required SshAuthMethod method,
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) async {
    await _secure.writeSsh(connectionId, 'user', username.trim());
    await _secure.writeSsh(connectionId, 'host', host.trim());
    await _secure.writeSsh(connectionId, 'port', '$port');
    await _secure.writeSsh(connectionId, 'method', method.id);
    if (password != null) {
      await _secure.writeSsh(connectionId, 'password', password);
    }
    if (privateKeyPem != null) {
      await _secure.writeSsh(connectionId, 'privkey', privateKeyPem);
    }
    // Passphrase siempre se escribe (vacío = clave sin passphrase) para que al
    // editar no quede una vieja colgando.
    await _secure.writeSsh(connectionId, 'passphrase', passphrase ?? '');
  }

  Future<void> clear(String connectionId) => _secure.deleteSsh(connectionId);

  // ── TOFU host keys ────────────────────────────────────────────────────

  Future<String?> knownFingerprint(String connectionId) async {
    final fp = await _secure.readSsh(connectionId, 'hostkey');
    return (fp == null || fp.isEmpty) ? null : fp;
  }

  Future<void> saveFingerprint(String connectionId, String fp) =>
      _secure.writeSsh(connectionId, 'hostkey', fp);

  Future<void> forgetFingerprint(String connectionId) =>
      _secure.writeSsh(connectionId, 'hostkey', '');

  /// Decodifica el fingerprint que dartssh2 entrega al verificador. dartssh2 YA
  /// computa el canónico (`SHA256:base64(sha256(hostkey))`) y lo pasa como bytes
  /// UTF-8 — así coincide con `ssh-keygen -lf … -E sha256`. Solo hay que
  /// decodificarlo (no re-hashearlo). Fallback defensivo si llegara en crudo.
  static String decodeFingerprint(Uint8List raw) {
    try {
      final s = utf8.decode(raw);
      if (s.startsWith('SHA256:') || s.startsWith('MD5:')) return s;
    } catch (_) {/* cae al hash de los bytes crudos */}
    return 'SHA256:${base64.encode(sha256.convert(raw).bytes).replaceAll('=', '')}';
  }

  // ── Validación de clave (sin red) ─────────────────────────────────────

  /// true si el PEM está cifrado y por tanto necesita passphrase.
  static bool isEncryptedKey(String pem) {
    try {
      return SSHKeyPair.isEncryptedPem(pem.trim());
    } catch (e) {
      debugPrint('[ssh-manager] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  /// Devuelve null si la clave parsea bien; si no, un mensaje legible. No toca
  /// la red — solo intenta decodificar el PEM con la passphrase dada.
  static String? validateKey(String pem, String? passphrase) {
    final text = pem.trim();
    if (text.isEmpty) return 'Paste or import a private key.';
    try {
      final pairs = SSHKeyPair.fromPem(
        text,
        (passphrase == null || passphrase.isEmpty) ? null : passphrase,
      );
      if (pairs.isEmpty) return 'No key found in the text.';
      return null;
    } on SSHKeyDecryptError {
      return 'Incorrect passphrase for this key.';
    } on SSHKeyDecodeError {
      return 'Unrecognized key format (use PEM OpenSSH or RSA).';
    } catch (e) {
      return 'Invalid key: $e';
    }
  }

  // ── Conexión ──────────────────────────────────────────────────────────

  /// Construye un [SSHClient] listo para autenticar. [onHostKey] se invoca solo
  /// cuando el fingerprint es nuevo o cambió; devolver true lo confía (y se
  /// guarda). El llamador debe `await client.authenticated` para forzar el
  /// handshake y capturar errores de auth/red, y cerrar el cliente al terminar.
  Future<SSHClient> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async {
    final cfg = await loadConfig(connectionId);
    if (cfg == null) {
      throw const SshConfigException('No SSH credentials configured.');
    }
    if (cfg.host.isEmpty) {
      throw const SshConfigException('Server host is missing.');
    }
    if (cfg.username.isEmpty) {
      throw const SshConfigException('Username is missing.');
    }

    List<SSHKeyPair>? identities;
    SSHPasswordRequestHandler? onPassword;
    if (cfg.method == SshAuthMethod.key) {
      final pem = (await _secure.readSsh(connectionId, 'privkey')) ?? '';
      final pass = await _secure.readSsh(connectionId, 'passphrase');
      identities = SSHKeyPair.fromPem(
        pem.trim(),
        (pass == null || pass.isEmpty) ? null : pass,
      );
    } else {
      final pw = (await _secure.readSsh(connectionId, 'password')) ?? '';
      onPassword = () => pw;
    }

    final socket = await SSHSocket.connect(
      cfg.host,
      cfg.port,
      timeout: const Duration(seconds: 12),
    );

    return SSHClient(
      socket,
      username: cfg.username,
      identities: identities,
      // U-11 (spec 028): el default de dartssh2 es un keepalive cada 10s —
      // un wakeup de radio constante mientras haya sesión viva en 2º plano.
      keepAliveInterval: const Duration(seconds: 60),
      onPasswordRequest: onPassword,
      onVerifyHostKey: (type, fingerprint) async {
        final fp = decodeFingerprint(fingerprint);
        final known = await knownFingerprint(connectionId);
        if (known != null && known == fp) return true;
        final accepted = await onHostKey(
          SshHostKeyPrompt(
            type: type,
            fingerprint: fp,
            isNew: known == null,
            changed: known != null,
          ),
        );
        if (accepted) await saveFingerprint(connectionId, fp);
        return accepted;
      },
    );
  }

  /// Traduce excepciones de dartssh2/socket a mensajes en español para la UI.
  static String describeError(Object e) {
    if (e is SshConfigException) return e.message;
    if (e is SSHAuthFailError) {
      return 'Authentication rejected: check username, key or password.';
    }
    if (e is SSHKeyDecryptError) return 'Incorrect passphrase for the key.';
    if (e is SSHKeyDecodeError) return 'Invalid private key.';
    if (e is SSHHandshakeError) {
      return 'SSH handshake failed (is this an SSH server?).';
    }
    final s = e.toString().toLowerCase();
    if (s.contains('refused')) return 'Connection refused (is SSH running?).';
    if (s.contains('timed out') || s.contains('timeout')) {
      return 'Tiempo de espera agotado (host/puerto inalcanzable).';
    }
    if (s.contains('failed host lookup') || s.contains('no address')) {
      return 'Could not resolve the host.';
    }
    return 'Connection error: $e';
  }
}
