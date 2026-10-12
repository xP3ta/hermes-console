import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_board_model.dart';

/// Board layout on this device, one per connection + profile, as
/// versioned JSON in shared preferences. Only widget kinds, sizes and
/// target ids are stored (no titles, no content), so reading it before
/// App Lock is lifted reveals nothing.
class HomeBoardStore {
  HomeBoardStore(this._prefs, {String Function()? newId})
    : _newId = newId ?? _defaultId;

  final SharedPreferences _prefs;
  final String Function() _newId;

  static int _counter = 0;
  static String _defaultId() =>
      'w${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${(_counter++).toRadixString(36)}';

  static String _scope(String connectionId, String profile) =>
      '$connectionId.${profile.isEmpty ? 'default' : profile}';

  static String keyFor(String connectionId, String profile) =>
      'home_board.v${HomeBoardLayout.version}.${_scope(connectionId, profile)}';

  /// Which default a board nobody arranged shows (true: with bots or
  /// rooms). A flag, no content.
  static String teamKeyFor(String connectionId, String profile) =>
      'home_board.default_team.${_scope(connectionId, profile)}';

  String newId() => _newId();

  /// Tests of other screens that only mean "Home lists these chats" use a
  /// board whose Chats lists them all.
  @visibleForTesting
  static HomeBoardLayout Function()? debugDefaultLayout;

  /// The layout the user arranged, or null when there is none: nothing
  /// stored, nothing readable, or the former default left as it was.
  HomeBoardLayout? read(String connectionId, String profile) {
    final raw = _prefs.getString(keyFor(connectionId, profile));
    return raw == null ? null : HomeBoardLayout.decode(raw);
  }

  /// Whether this scope was last seen with bots or rooms; null before the
  /// first Bots read on this device.
  bool? team(String connectionId, String profile) =>
      _prefs.getBool(teamKeyFor(connectionId, profile));

  Future<void> rememberTeam(String connectionId, String profile, bool team) =>
      _prefs.setBool(teamKeyFor(connectionId, profile), team);

  /// The board to show: the user's own, else the default for [team]
  /// (the remembered one when null; one agent when nothing is known yet).
  HomeBoardLayout load(String connectionId, String profile, {bool? team}) =>
      read(connectionId, profile) ??
      debugDefaultLayout?.call() ??
      HomeBoardLayout.defaults(
        team: team ?? this.team(connectionId, profile) ?? false,
      );

  Future<void> save(
    String connectionId,
    String profile,
    HomeBoardLayout layout,
  ) => _prefs.setString(keyFor(connectionId, profile), layout.encode());
}
