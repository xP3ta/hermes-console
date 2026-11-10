import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/subagent_activity.dart';

/// Which subagents of each conversation the person closed in the chat.
///
/// Closing hides an agent from the group and stops nothing. It is remembered
/// PER AGENT (its id) and per conversation: an agent that was closed stays
/// hidden when another turn starts, an agent nobody closed shows the group
/// by itself. The chat menu («Subagentes · n») reaches the closed ones again.
///
/// The ids survive restarts (a bounded list in the preferences: so a closed
/// agent's completion marker stays covered); the last snapshot of each closed
/// agent is kept for the running process only, which is what lets the menu
/// open it again after the turn moved on. After a restart the snapshots are
/// gone; the roster rebuilt from the transcript still lists the closed
/// agents, and the chat menu's «Mostrar subagentes ocultos» ([reopen]) is
/// offered whenever a persisted id matches an agent of the conversation.
class SubagentGroupVisibility {
  SubagentGroupVisibility([this._prefs]) {
    final raw = _prefs?.getString(prefsKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          final ids = entry.value;
          if (ids is List) {
            _closed[entry.key] = {for (final id in ids) '$id'};
          }
        }
      }
    } catch (_) {
      // A damaged value is the same as none: nothing was closed.
    }
  }

  static const String prefsKey = 'subagent_group_closed_v1';

  static SubagentGroupVisibility _shared = SubagentGroupVisibility();

  /// The one the app uses.
  static SubagentGroupVisibility get shared => _shared;

  /// Replaces the shared store by one backed by [prefs] (at startup).
  static Future<SubagentGroupVisibility> load([
    SharedPreferences? prefs,
  ]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    return _shared = SubagentGroupVisibility(resolved);
  }

  static const int _maxChats = 64;
  static const int _maxIds = 96;

  final SharedPreferences? _prefs;
  final Map<String, Set<String>> _closed = <String, Set<String>>{};
  final Map<String, Map<String, SubagentActivity>> _snapshots =
      <String, Map<String, SubagentActivity>>{};

  /// This one agent was closed in [chatKey].
  bool isAgentClosed(String chatKey, String agentId) =>
      _closed[chatKey]?.contains(agentId) ?? false;

  /// The group of [agentIds] is closed in [chatKey]: every one of them was
  /// closed. An empty roster is never "closed".
  bool isClosed(String chatKey, Iterable<String> agentIds) {
    final closed = _closed[chatKey];
    if (closed == null || closed.isEmpty) return false;
    var any = false;
    for (final id in agentIds) {
      any = true;
      if (!closed.contains(id)) return false;
    }
    return any;
  }

  /// The last snapshot of every closed agent of [chatKey] this process saw.
  List<SubagentActivity> closedActivities(String chatKey) =>
      List.unmodifiable(_snapshots[chatKey]?.values ?? const []);

  /// Closes [agentIds] in [chatKey]; [activities] are kept so the menu can
  /// open them again later.
  void close(
    String chatKey,
    Iterable<String> agentIds, {
    Iterable<SubagentActivity> activities = const [],
  }) {
    final set = _closed.remove(chatKey) ?? <String>{};
    set.addAll(agentIds);
    while (set.length > _maxIds) {
      set.remove(set.first);
    }
    _closed[chatKey] = set; // most recently used last
    while (_closed.length > _maxChats) {
      _snapshots.remove(_closed.keys.first);
      _closed.remove(_closed.keys.first);
    }
    final kept = _snapshots.remove(chatKey) ?? <String, SubagentActivity>{};
    for (final a in activities) {
      if (set.contains(a.key.stableId)) kept[a.key.stableId] = a;
    }
    kept.removeWhere((id, _) => !set.contains(id));
    _snapshots[chatKey] = kept;
    _persist();
  }

  /// Opens every closed agent of [chatKey] again.
  void reopen(String chatKey) {
    _closed.remove(chatKey);
    _snapshots.remove(chatKey);
    _persist();
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    final value = jsonEncode({
      for (final e in _closed.entries) e.key: e.value.toList(),
    });
    unawaited(prefs.setString(prefsKey, value));
  }

  void debugReset() {
    _closed.clear();
    _snapshots.clear();
  }
}
