import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps flutter_secure_storage for API key storage using Android Keystore.
class SecureStorage {
  final FlutterSecureStorage _storage;

  // flutter_secure_storage ≥10.x migrates to custom AES-256 ciphers
  // automatically on first access — no AndroidOptions needed.
  SecureStorage() : _storage = const FlutterSecureStorage();

  static String _key(String connectionId) => 'api_key_$connectionId';
  static String _dashKey(String connectionId, String field) =>
      'dash_${field}_$connectionId';

  Future<String?> readApiKey(String connectionId) =>
      _storage.read(key: _key(connectionId));

  Future<void> writeApiKey(String connectionId, String apiKey) =>
      _storage.write(key: _key(connectionId), value: apiKey);

  Future<void> deleteApiKey(String connectionId) =>
      _storage.delete(key: _key(connectionId));

  // ── Secretos del Dashboard/Admin (session token / basic auth) ─────────

  Future<String?> readDashboardSecret(String connectionId, String field) =>
      _storage.read(key: _dashKey(connectionId, field));

  Future<void> writeDashboardSecret(
    String connectionId,
    String field,
    String value,
  ) => _storage.write(key: _dashKey(connectionId, field), value: value);

  Future<void> deleteDashboardSecrets(String connectionId) async {
    for (final f in const ['token', 'user', 'pass']) {
      await _storage.delete(key: _dashKey(connectionId, f));
    }
  }

  // ── Mobile Bridge (url + token, opcional por instancia) ───────────────

  static String _bridgeKey(String connectionId, String field) =>
      'bridge_${field}_$connectionId';

  Future<String?> readBridge(String connectionId, String field) =>
      _storage.read(key: _bridgeKey(connectionId, field));

  Future<void> writeBridge(String connectionId, String field, String value) =>
      _storage.write(key: _bridgeKey(connectionId, field), value: value);

  Future<void> deleteBridge(String connectionId) async {
    for (final f in const ['url', 'token']) {
      await _storage.delete(key: _bridgeKey(connectionId, f));
    }
  }

  // ── SSH (usuario/host/puerto/método + secretos + host key TOFU) ───────
  //
  // Todo lo de SSH vive aquí por simplicidad y porque la credencial (clave
  // privada / contraseña / passphrase) es sensible y debe ir al Keystore.
  // Campos: user, host, port, method, password, privkey, passphrase, hostkey.

  static String _sshKey(String connectionId, String field) =>
      'ssh_${field}_$connectionId';

  Future<String?> readSsh(String connectionId, String field) =>
      _storage.read(key: _sshKey(connectionId, field));

  Future<void> writeSsh(String connectionId, String field, String value) =>
      _storage.write(key: _sshKey(connectionId, field), value: value);

  Future<void> deleteSsh(String connectionId) async {
    for (final f in const [
      'user',
      'host',
      'port',
      'method',
      'password',
      'privkey',
      'passphrase',
      'hostkey',
    ]) {
      await _storage.delete(key: _sshKey(connectionId, f));
    }
  }

  // ── Secretos app-level (no por conexión), p.ej. clave de ElevenLabs ───

  static String _appKey(String name) => 'app_secret_$name';

  Future<String?> readAppSecret(String name) =>
      _storage.read(key: _appKey(name));

  Future<void> writeAppSecret(String name, String value) =>
      _storage.write(key: _appKey(name), value: value);

  Future<void> deleteAppSecret(String name) =>
      _storage.delete(key: _appKey(name));

  Future<void> clearAllConnectionSecrets() async {
    final all = await _storage.readAll();
    final keys = all.keys
        .where(
          (k) =>
              k.startsWith('api_key_') ||
              k.startsWith('dash_') ||
              k.startsWith('bridge_') ||
              k.startsWith('ssh_'),
        )
        .toList(growable: false);
    for (final k in keys) {
      await _storage.delete(key: k);
    }
  }
}
