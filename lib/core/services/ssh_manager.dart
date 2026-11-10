import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart' show Locale;

import '../../l10n/app_localizations.dart';

import 'connection_manager.dart';
import 'secure_storage.dart';
import 'ssh_keepalive.dart';
import 'ssh_profile_presence.dart';
import 'ssh_session_kind.dart';
import 'voice/voice_lang.dart';

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

  /// What the terminal runs after the shell opens (1.4.0). Not a secret;
  /// stored with the rest of the profile.
  final SshSessionKind sessionKind;

  const SshConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.method,
    this.sessionKind = SshSessionKind.shell,
  });

  String get target => '$username@$host:$port';
}

/// The secrets of one SSH login, kept in memory. Only what the chosen method
/// uses is set.
class SshCredentials {
  const SshCredentials({this.password, this.privateKeyPem, this.passphrase});

  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
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

/// Typed SSH failure. Services return or throw codes; the UI localizes them
/// with `localizedSshFailure` (lib/core/utils/ssh_error.dart).
enum SshFailure {
  notConfigured,
  missingHost,
  missingUser,
  emptyKey,
  noKeyFound,
  wrongPassphrase,
  unrecognizedKey,
  invalidKey,
  authRejected,
  handshakeFailed,
  refused,
  timeout,
  hostLookup,

  /// The user (or the automatic reconnection) did not trust the server key.
  hostKeyRejected,

  /// SFTP: the user cannot read or change that path.
  permissionDenied,

  /// SFTP: the path is gone (deleted or moved).
  noSuchFile,
  unknown,
}

/// Error de configuración (no de red) al preparar una conexión SSH.
class SshConfigException implements Exception {
  final SshFailure failure;
  const SshConfigException(this.failure);
  @override
  String toString() => 'SshConfigException(${failure.name})';
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

  /// Strings in the app language, for services that have no BuildContext.
  Strings get appStrings =>
      lookupStrings(Locale(effectiveVoiceLang(_connections.prefs)));

  SavedConnection? _conn(String id) {
    for (final c in _connections.getConnections()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Host que se derivaría del gateway de la instancia (sin mirar lo guardado).
  String? derivedHostFor(String connectionId) => _conn(connectionId)?.host;

  /// true si la instancia es solo lectura (SFTP no debe escribir).
  bool isReadOnly(String connectionId) =>
      _conn(connectionId)?.readOnly ?? false;

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
    final sessionKind = SshSessionKind.fromStored(
      await _secure.readSsh(connectionId, 'session'),
    );
    return SshConfig(
      host: host,
      port: port,
      username: user,
      method: method,
      sessionKind: sessionKind,
    );
  }

  /// Session type of the profile for the terminal. Any read failure falls
  /// back to the plain shell, which is what the terminal did before 1.4.0.
  Future<SshSessionKind> loadSessionKind(String connectionId) async {
    try {
      return SshSessionKind.fromStored(
        await _secure.readSsh(connectionId, 'session'),
      );
    } catch (e) {
      debugPrint('[ssh-manager] session type unreadable (${e.runtimeType})');
      return SshSessionKind.shell;
    }
  }

  /// Guarda config + credencial. Pasa solo el secreto del método elegido.
  Future<void> saveConfig(
    String connectionId, {
    required String host,
    required int port,
    required String username,
    required SshAuthMethod method,
    SshSessionKind? sessionKind,
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) async {
    await _secure.writeSsh(connectionId, 'user', username.trim());
    await _secure.writeSsh(connectionId, 'host', host.trim());
    await _secure.writeSsh(connectionId, 'port', '$port');
    await _secure.writeSsh(connectionId, 'method', method.id);
    // An omitted session type keeps the stored one.
    if (sessionKind != null) {
      await _secure.writeSsh(connectionId, 'session', sessionKind.storedId);
    }
    if (password != null) {
      await _secure.writeSsh(connectionId, 'password', password);
    }
    if (privateKeyPem != null) {
      await _secure.writeSsh(connectionId, 'privkey', privateKeyPem);
    }
    // An omitted secret preserves the stored one. Replacing a key without a
    // passphrase explicitly clears the old key's passphrase.
    if (privateKeyPem != null || passphrase != null) {
      await _secure.writeSsh(connectionId, 'passphrase', passphrase ?? '');
    }
    SshProfilePresence.instance.noteSaved();
  }

  /// The secrets saved for [connectionId]; what was not kept comes back null.
  Future<SshCredentials> loadCredentials(String connectionId) async {
    String? read(String? v) => (v == null || v.isEmpty) ? null : v;
    return SshCredentials(
      password: read(await _secure.readSsh(connectionId, 'password')),
      privateKeyPem: read(await _secure.readSsh(connectionId, 'privkey')),
      passphrase: read(await _secure.readSsh(connectionId, 'passphrase')),
    );
  }

  /// A connection that reaches its Dashboard through an SSH tunnel keeps the
  /// Dashboard as the SSH server sees it ("host:port").
  Future<void> saveTunnelTarget(String connectionId, String host, int port) =>
      _secure.writeSsh(connectionId, 'tunnel', '$host:$port');

  /// The Dashboard behind the tunnel of [connectionId], or null when it is
  /// not a tunnel connection.
  Future<({String host, int port})?> loadTunnelTarget(
    String connectionId,
  ) async {
    final raw = await _secure.readSsh(connectionId, 'tunnel');
    if (raw == null) return null;
    final cut = raw.lastIndexOf(':');
    if (cut <= 0) return null;
    final port = int.tryParse(raw.substring(cut + 1));
    if (port == null) return null;
    return (host: raw.substring(0, cut), port: port);
  }

  Future<void> clear(String connectionId) async {
    await _secure.deleteSsh(connectionId);
    SshProfilePresence.instance.noteCleared();
  }

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
    } catch (_) {
      /* cae al hash de los bytes crudos */
    }
    return 'SHA256:${base64.encode(sha256.convert(raw).bytes).replaceAll('=', '')}';
  }

  // ── Validación de clave (sin red) ─────────────────────────────────────

  /// true si el PEM está cifrado y por tanto necesita passphrase.
  static bool isEncryptedKey(String pem) {
    try {
      return SSHKeyPair.isEncryptedPem(pem.trim());
    } catch (e) {
      debugPrint('[ssh-manager] invalid key (${e.runtimeType})');
      return false;
    }
  }

  /// Devuelve null si la clave parsea bien; si no, el motivo tipado. No toca
  /// la red — solo intenta decodificar el PEM con la passphrase dada.
  static SshFailure? validateKey(String pem, String? passphrase) {
    final text = pem.trim();
    if (text.isEmpty) return SshFailure.emptyKey;
    try {
      final pairs = SSHKeyPair.fromPem(
        text,
        (passphrase == null || passphrase.isEmpty) ? null : passphrase,
      );
      if (pairs.isEmpty) return SshFailure.noKeyFound;
      return null;
    } on SSHKeyDecryptError {
      return SshFailure.wrongPassphrase;
    } on SSHKeyDecodeError {
      return SshFailure.unrecognizedKey;
    } catch (_) {
      return SshFailure.invalidKey;
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
      throw const SshConfigException(SshFailure.notConfigured);
    }
    if (cfg.host.isEmpty) {
      throw const SshConfigException(SshFailure.missingHost);
    }
    if (cfg.username.isEmpty) {
      throw const SshConfigException(SshFailure.missingUser);
    }

    final SshCredentials credentials;
    if (cfg.method == SshAuthMethod.key) {
      credentials = SshCredentials(
        privateKeyPem: (await _secure.readSsh(connectionId, 'privkey')) ?? '',
        passphrase: await _secure.readSsh(connectionId, 'passphrase'),
      );
    } else {
      credentials = SshCredentials(
        password: (await _secure.readSsh(connectionId, 'password')) ?? '',
      );
    }
    return connectWith(
      cfg,
      credentials,
      hostKeyScopes: [connectionId],
      onHostKey: onHostKey,
    );
  }

  /// Same as [connect] with the config and the secrets in hand (nothing is
  /// read from the Keystore), for callers that may not keep them. The server
  /// key is looked up in every scope of [hostKeyScopes] and saved to all of
  /// them; a tunnel passes [serverScope] so the key belongs to the server.
  Future<SSHClient> connectWith(
    SshConfig cfg,
    SshCredentials credentials, {
    required List<String> hostKeyScopes,
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async {
    List<SSHKeyPair>? identities;
    SSHPasswordRequestHandler? onPassword;
    if (cfg.method == SshAuthMethod.key) {
      final pass = credentials.passphrase;
      identities = SSHKeyPair.fromPem(
        (credentials.privateKeyPem ?? '').trim(),
        (pass == null || pass.isEmpty) ? null : pass,
      );
    } else {
      final pw = credentials.password ?? '';
      onPassword = () => pw;
    }

    final socket = await SSHSocket.connect(
      cfg.host,
      cfg.port,
      timeout: const Duration(seconds: 12),
    );

    final client = SSHClient(
      socket,
      username: cfg.username,
      identities: identities,
      // U-11 (spec 028): un keepalive por minuto, no cada 10 s. M2: el de
      // dartssh2 espera la respuesta sin plazo y nunca detecta un enlace
      // medio abierto; lo sustituye el vigilante con plazo.
      keepAliveInterval: null,
      onPasswordRequest: onPassword,
      onVerifyHostKey: (type, fingerprint) =>
          verifyHostKey(hostKeyScopes, type, fingerprint, onHostKey),
    );
    watchSshKeepAlive(client);
    return client;
  }

  /// TOFU: a key equal to the saved one passes unasked; a new or changed one
  /// goes to [onHostKey] and is saved to every scope only when trusted. A
  /// refused key never overwrites the one on record.
  Future<bool> verifyHostKey(
    List<String> scopes,
    String type,
    Uint8List fingerprint,
    Future<bool> Function(SshHostKeyPrompt) onHostKey,
  ) async {
    final fp = decodeFingerprint(fingerprint);
    String? known;
    for (final scope in scopes) {
      known = await knownFingerprint(scope);
      if (known != null) break;
    }
    if (known != null && known == fp) return true;
    final accepted = await onHostKey(
      SshHostKeyPrompt(
        type: type,
        fingerprint: fp,
        isNew: known == null,
        changed: known != null,
      ),
    );
    if (accepted) {
      for (final scope in scopes) {
        await saveFingerprint(scope, fp);
      }
    }
    return accepted;
  }

  /// Where a server's key is kept apart from any connection.
  static String serverScope(String host, int port) =>
      'srv:${host.trim().toLowerCase()}:$port';

  /// true when [text] is a public key (or a certificate) rather than the
  /// private key an SSH login needs.
  static bool looksLikePublicKey(String text) {
    final t = text.trimLeft();
    return t.startsWith('ssh-') ||
        t.startsWith('ecdsa-sha2-') ||
        t.startsWith('sk-ssh-') ||
        t.startsWith('sk-ecdsa-') ||
        t.startsWith('-----BEGIN PUBLIC KEY-----') ||
        t.startsWith('-----BEGIN RSA PUBLIC KEY-----') ||
        t.startsWith('---- BEGIN SSH2 PUBLIC KEY ----');
  }

  /// Clasifica excepciones de dartssh2/socket en un [SshFailure] tipado; la UI
  /// lo traduce al idioma de la app.
  static SshFailure classifyError(Object e) {
    if (e is SshConfigException) return e.failure;
    // A refused host key closes the transport before authentication, so it
    // can also arrive wrapped as the abort's reason.
    if (e is SSHHostkeyError ||
        e is SSHAuthAbortError && e.reason is SSHHostkeyError) {
      return SshFailure.hostKeyRejected;
    }
    if (e is SftpStatusError) {
      if (e.code == SftpStatusCode.permissionDenied) {
        return SshFailure.permissionDenied;
      }
      if (e.code == SftpStatusCode.noSuchFile) return SshFailure.noSuchFile;
    }
    if (e is SSHAuthFailError) return SshFailure.authRejected;
    if (e is SSHKeyDecryptError) return SshFailure.wrongPassphrase;
    if (e is SSHKeyDecodeError) return SshFailure.invalidKey;
    if (e is SSHHandshakeError) return SshFailure.handshakeFailed;
    final s = e.toString().toLowerCase();
    if (s.contains('refused')) return SshFailure.refused;
    if (s.contains('timed out') || s.contains('timeout')) {
      return SshFailure.timeout;
    }
    if (s.contains('failed host lookup') || s.contains('no address')) {
      return SshFailure.hostLookup;
    }
    debugPrint('[ssh-manager] unclassified failure (${e.runtimeType})');
    return SshFailure.unknown;
  }

  /// true when [e] looks like the network (worth an automatic retry) rather
  /// than configuration, credentials or keys, which a retry cannot fix. A
  /// host key that failed verification is never transient (TOFU).
  static bool isTransientFailure(Object e) {
    if (e is SSHHostkeyError) return false;
    return switch (classifyError(e)) {
      SshFailure.refused ||
      SshFailure.timeout ||
      SshFailure.hostLookup ||
      SshFailure.handshakeFailed ||
      SshFailure.unknown => true,
      _ => false,
    };
  }
}
