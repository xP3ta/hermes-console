
import 'package:flutter/foundation.dart';

import 'tui_gateway_client.dart';

// «Contraseñas e inicios de sesión»: the Hermes server's credential vault,
// managed from Settings as Hermes Desktop does (Settings → Passwords &
// Logins, `apps/desktop/src/app/settings/vault-settings.tsx`). Console keeps
// NO vault of its own: the list is metadata only (the server never sends a
// password, card or 2FA key), and a secret typed here travels once, in the
// `vault.add` / `vault.unlock` params, and is not kept, logged or cached.

/// One saved item as `vault.list` reports it: metadata only.
@immutable
class VaultItem {
  const VaultItem({
    required this.id,
    required this.kind,
    required this.label,
    this.origin,
    this.createdAt = '',
    this.identifier,
    this.identifierType,
    this.hasOtp = false,
    this.backend = 'local',
  });

  final String id;

  /// `login`, `payment` or `address` (anything else is shown as is).
  final String kind;
  final String label;
  final String? origin;
  final String createdAt;

  /// The login's visible identifier (email, phone or username): metadata by
  /// design on the server, never a secret.
  final String? identifier;
  final String? identifierType;

  /// The login has an authenticator key: Hermes makes its codes («2FA auto»).
  final bool hasOtp;

  /// `local` (Hermes' own vault) or the password manager it comes from.
  final String backend;

  bool get isLocal => backend == 'local';

  static VaultItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? text(String key) {
      final value = raw[key];
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final id = text('id');
    final kind = text('kind');
    final label = text('label');
    if (id == null || kind == null || label == null) return null;
    return VaultItem(
      id: id,
      kind: kind,
      label: label,
      origin: text('origin'),
      createdAt: text('created_at') ?? '',
      identifier: text('identifier'),
      identifierType: text('identifier_type'),
      hasOtp: raw['has_otp'] == true,
      backend: text('backend') ?? 'local',
    );
  }
}

/// One login source as `vault.sources` reports it (the server is the
/// authority for enabled / unlocked).
@immutable
class VaultSource {
  const VaultSource({
    required this.name,
    required this.displayName,
    required this.enabled,
    required this.needsUnlock,
    required this.unlocked,
    required this.installed,
  });

  final String name;
  final String displayName;
  final bool enabled;
  final bool needsUnlock;
  final bool unlocked;
  final bool installed;

  static VaultSource? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final display = raw['display_name'];
    return VaultSource(
      name: name.trim(),
      displayName: display is String && display.trim().isNotEmpty
          ? display.trim()
          : name.trim(),
      enabled: raw['enabled'] == true,
      needsUnlock: raw['needs_unlock'] == true,
      unlocked: raw['unlocked'] == true,
      installed: raw['installed'] == true,
    );
  }
}

/// What kind of item the Add form saves (the server's `VAULT_KINDS`).
enum VaultKind {
  login('login'),
  payment('payment'),
  address('address');

  const VaultKind(this.wire);

  final String wire;
}

/// How a login identifies the user (the server's `LOGIN_IDENTIFIER_TYPES`).
enum VaultIdentifierType {
  email('email'),
  phone('phone'),
  username('username');

  const VaultIdentifierType(this.wire);

  final String wire;
}

/// Why a vault call failed. Never carries Hermes' text: `vault.add` and
/// `vault.unlock` errors may echo what was typed, so only the kind is kept.
enum VaultFailureKind {
  /// This Hermes has no vault methods (an older server).
  unsupported,

  /// The server could not be reached.
  unavailable,

  /// The server refused the request (bad data, wrong master password…).
  rejected,

  /// A read-only connection asked for a change.
  readOnly,
}

class VaultFailure implements Exception {
  const VaultFailure(this.kind);

  final VaultFailureKind kind;

  @override
  String toString() => 'VaultFailure(${kind.name})';
}

/// The vault methods of one (connection, profile). Implementations scope
/// every call to that owner.
abstract interface class VaultGateway {
  bool get readOnly;

  Future<List<VaultItem>> list();

  Future<List<VaultSource>> sources();

  /// Saves an item. [secret] is the payload `vault.add` stores encrypted;
  /// the caller wipes its own copy right after.
  Future<void> add({
    required VaultKind kind,
    required String label,
    String? origin,
    required Map<String, String> secret,
  });

  Future<void> remove(String id);

  Future<void> setSourceEnabled(String name, {required bool enabled});

  /// Hands [masterPassword] to the server's password manager CLI once.
  Future<void> unlock(String name, String masterPassword);

  Future<void> lock(String name);
}

/// [VaultGateway] over the connection's gateway socket.
class TuiVaultGateway implements VaultGateway {
  TuiVaultGateway(
    this._client, {
    required this.profile,
    required this.readOnly,
  });

  final TuiGatewayClient _client;

  /// The Settings profile; `default` (or empty) sends no `profile` param,
  /// like the Capabilities hub.
  final String profile;

  @override
  final bool readOnly;

  Map<String, dynamic> _scoped([Map<String, dynamic>? params]) {
    final value = profile.trim();
    return {
      ...?params,
      if (value.isNotEmpty && value != 'default') 'profile': value,
    };
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    if (!TuiGatewayClient.vaultRpcAllowed(method, readOnly: readOnly)) {
      throw const VaultFailure(VaultFailureKind.readOnly);
    }
    try {
      return await _client.vaultRequest(method, _scoped(params));
    } on TuiGatewayRpcError catch (error) {
      // Kind only: the message may be a refusal that echoes typed input.
      if (error.code == -32601) {
        throw const VaultFailure(VaultFailureKind.unsupported);
      }
      if (error.code != null &&
          error.failureKind != TuiGatewayRpcFailureKind.timeout &&
          error.failureKind != TuiGatewayRpcFailureKind.connectionLost) {
        throw const VaultFailure(VaultFailureKind.rejected);
      }
      throw const VaultFailure(VaultFailureKind.unavailable);
    } on VaultFailure {
      rethrow;
    } catch (error) {
      debugPrint('[vault] $method failed (${error.runtimeType})');
      throw const VaultFailure(VaultFailureKind.unavailable);
    }
  }

  @override
  Future<List<VaultItem>> list() async {
    final result = await _call('vault.list');
    final raw = result['items'];
    return [
      if (raw is List)
        for (final entry in raw) ?VaultItem.fromJson(entry),
    ];
  }

  @override
  Future<List<VaultSource>> sources() async {
    final result = await _call('vault.sources');
    final raw = result['sources'];
    return [
      if (raw is List)
        for (final entry in raw) ?VaultSource.fromJson(entry),
    ];
  }

  @override
  Future<void> add({
    required VaultKind kind,
    required String label,
    String? origin,
    required Map<String, String> secret,
  }) => _call('vault.add', {
    'kind': kind.wire,
    'label': label,
    if (origin != null && origin.isNotEmpty) 'origin': origin,
    'secret': Map<String, String>.of(secret),
  });

  @override
  Future<void> remove(String id) => _call('vault.remove', {'id': id});

  @override
  Future<void> setSourceEnabled(String name, {required bool enabled}) =>
      _call('vault.source.set', {'name': name, 'enabled': enabled});

  @override
  Future<void> unlock(String name, String masterPassword) =>
      _call('vault.unlock', {'name': name, 'password': masterPassword});

  @override
  Future<void> lock(String name) => _call('vault.lock', {'name': name});
}

/// What the page shows instead of the list.
enum VaultPhase { loading, ready, unsupported, failed }

/// The state of the vault page for one (connection, profile): the saved
/// items and the password managers, read together. Reads that land after a
/// newer one (or after [dispose]) are dropped. Holds metadata only.
class VaultController extends ChangeNotifier {
  VaultController(this.gateway);

  final VaultGateway gateway;

  VaultPhase _phase = VaultPhase.loading;
  VaultPhase get phase => _phase;

  List<VaultItem> _items = const [];
  List<VaultItem> get items => _items;

  /// Only the managers (the local vault is the list itself).
  List<VaultSource> _sources = const [];
  List<VaultSource> get sources => _sources;

  /// `vault.sources` answered; an older server may list items without it.
  bool _sourcesKnown = false;
  bool get sourcesKnown => _sourcesKnown;

  VaultFailureKind? _failure;
  VaultFailureKind? get failure => _failure;

  bool _busy = false;

  /// A change is running: the page disables every action.
  bool get busy => _busy;

  int _seq = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    // Nothing is asked once the page is gone (its lease is released).
    if (_disposed) return;
    final seq = ++_seq;
    if (_phase != VaultPhase.ready) {
      _phase = VaultPhase.loading;
      _notify();
    }
    try {
      final items = await gateway.list();
      List<VaultSource>? sources;
      try {
        sources = await gateway.sources();
      } on VaultFailure {
        sources = null;
      }
      if (seq != _seq || _disposed) return;
      _items = List.unmodifiable(items);
      _sourcesKnown = sources != null;
      _sources = List.unmodifiable([
        for (final source in sources ?? const <VaultSource>[])
          if (source.needsUnlock) source,
      ]);
      _failure = null;
      _phase = VaultPhase.ready;
    } on VaultFailure catch (failure) {
      if (seq != _seq || _disposed) return;
      _failure = failure.kind;
      _phase = failure.kind == VaultFailureKind.unsupported
          ? VaultPhase.unsupported
          : VaultPhase.failed;
    } finally {
      if (seq == _seq) _notify();
    }
  }

  /// Runs one change, then re-reads, also when it failed: a change that
  /// timed out may have been applied, and a second try would apply it
  /// twice. The page stays busy until the list is read again. Throws the
  /// [VaultFailure] for the page to say why; nothing runs while another
  /// change is busy.
  Future<void> run(Future<void> Function() change) async {
    if (_busy) return;
    _busy = true;
    _notify();
    try {
      await change();
    } finally {
      try {
        await refresh();
      } finally {
        _busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _seq++;
    super.dispose();
  }
}

/// A valid `http`/`https` site origin (Desktop's `isValidOrigin`): the
/// server fills every saved item only on that origin.
bool isValidVaultOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

final RegExp _notBase32 = RegExp(r'[^A-Z2-7]');

/// An authenticator key the server accepts (`normalize_otp_secret`): a
/// base32 seed (spaces, dashes and case ignored) or an `otpauth://totp/`
/// link. Empty is fine: the key is optional.
bool isValidVaultOtp(String value) {
  final text = value.trim();
  if (text.isEmpty) return true;
  if (text.toLowerCase().startsWith('otpauth://')) {
    final uri = Uri.tryParse(text);
    return uri != null && uri.host.toLowerCase() == 'totp';
  }
  final seed = text
      .replaceAll(RegExp(r'[\s-]'), '')
      .toUpperCase()
      .replaceAll(RegExp(r'=+$'), '');
  return seed.isNotEmpty && !_notBase32.hasMatch(seed);
}
