import 'dart:async';

import '../models/agent_profile.dart';
import '../models/connection.dart';
import '../services/tui_gateway_client.dart';
import 'bot_character.dart';
import 'bot_character_store.dart';

/// Carries the Studio characters between this device and the profiles on the
/// server, so a face made on one device is the face on every other.
///
/// The character lives in Console's own `ui_meta` namespace of the profile
/// (`ui_meta['hermes-console'].character`): `profiles.configure` merges
/// `ui_meta` key-wise with one revision per key
/// (tui_gateway/methods_profiles.py:604), and `profiles.list` returns it with
/// every roster (methods_profiles.py:257). Rules, per profile:
///
///  * changed here and not yet confirmed: this device's character goes up
///    (or the server's is removed, when it was reset here);
///  * otherwise the server's character, when it has one, is the one shown;
///  * the server has none and this device has one never sent: it goes up
///    (the first run after updating);
///  * the server has none and this device's was sent before: another device
///    reset it, so it is reset here too.
final class CharacterSync {
  CharacterSync._();

  static final shared = CharacterSync._();

  /// Writes [character] (null removes) for [profile] of [connection].
  /// Replaced in tests.
  Future<void> Function(
    SavedConnection connection,
    String profile,
    Map<String, dynamic>? character,
  )
  push = _pushThroughGateway;

  SavedConnection? Function(String connectionId)? _connectionOf;
  final Set<String> _inFlight = {};

  static Future<void> _pushThroughGateway(
    SavedConnection connection,
    String profile,
    Map<String, dynamic>? character,
  ) async {
    final gateway = TuiGatewayClient(connection);
    try {
      await gateway.setConsoleCharacter(profile, character);
    } finally {
      unawaited(gateway.close());
    }
  }

  /// Starts sending this device's changes as they are made.
  void attach(SavedConnection? Function(String connectionId) connectionOf) {
    _connectionOf = connectionOf;
    BotCharacterStore.onLocalChange = (connectionId, profileName) {
      final connection = connectionId == null
          ? null
          : connectionOf(connectionId);
      if (connection == null) return;
      unawaited(_send(connection, profileName));
    };
  }

  /// A roster just read from the server for [connectionId].
  void onRoster(String connectionId, List<AgentProfile> profiles) {
    final connection = _connectionOf?.call(connectionId);
    final store = BotCharacterStore.shared;
    for (final profile in profiles) {
      if (!profile.consoleMetaKnown || profile.name.isEmpty) continue;
      final name = profile.name;
      final local = store.characterFor(connectionId, name);
      final remote = BotCharacter.fromJson(profile.consoleCharacter);
      final remoteValue = remote == null || remote.isStandard ? null : remote;
      if (store.isDirty(connectionId, name)) {
        if (connection != null) unawaited(_send(connection, name));
        continue;
      }
      if (remoteValue != null) {
        if (local != remoteValue || !store.isSynced(connectionId, name)) {
          unawaited(store.applyRemote(connectionId, name, remoteValue));
        }
        continue;
      }
      if (local == null) continue;
      if (store.isSynced(connectionId, name)) {
        unawaited(store.applyRemote(connectionId, name, null));
      } else if (connection != null) {
        unawaited(_send(connection, name));
      }
    }
  }

  Future<void> _send(SavedConnection connection, String profileName) async {
    if (connection.readOnly) return;
    final id = BotCharacterStore.entryKey(connection.id, profileName);
    if (!_inFlight.add(id)) return;
    try {
      final store = BotCharacterStore.shared;
      final sent = store.characterFor(connection.id, profileName);
      await push(connection, profileName.trim(), sent?.toJson());
      // Changed again meanwhile: stays pending for the next roster.
      if (store.characterFor(connection.id, profileName) == sent) {
        await store.markSynced(connection.id, profileName);
      }
    } on Object {
      // Offline or an older gateway: it stays pending and is retried with
      // the next roster.
    } finally {
      _inFlight.remove(id);
    }
  }
}
