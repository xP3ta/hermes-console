import '../models/activity_snapshot.dart' show isInternalActivityLabel;
import '../services/session_reconciler.dart'
    show assistantActivityTraceKey, normalizeAssistantActivityTrace;
import '../utils/chat_turn.dart';
import '../widgets/agent_task_widgets.dart' show isAgentTaskToolLabel;

/// What a finished answer of the open conversation has already shown of its
/// turn: the settled tool steps and the thoughts of its «Trabajó · N pasos ›»
/// line. Once seen, that is not lost while the conversation stays open.
///
/// A re-read of the history (resume, `sessions.changed`, terminal recovery) can
/// hand back the same answer without the tool events it was first drawn with
/// (a page that starts mid-turn, a tool whose result row was not in the page,
/// a source that only holds the final text). Drawn as it comes, the line
/// vanished, the text under it jumped up by the line's height and the reader
/// lost their place. [settle] keeps the richer trace instead.
///
/// One memory belongs to one chat screen: it dies with the conversation.
class TurnActivityMemory {
  TurnActivityMemory({this.capacity = 256});

  /// Answers remembered at most; the oldest seen go first.
  final int capacity;

  final Map<String, _Known> _byId = {};
  final Map<String, _Known> _byText = {};
  // The map handed out for a source row, so a rebuild with the same source
  // gives the same map back (a map's identity is a widget key downstream).
  final Map<Map<String, dynamic>, Map<String, dynamic>> _handed =
      Map<Map<String, dynamic>, Map<String, dynamic>>.identity();

  /// Times a richer, remembered trace took the place of a poorer one.
  /// Debug and test builds only; it stays 0 in release.
  int carriedCount = 0;

  static const delegatedCountKey = '_activity_subagent_count';
  final Map<int, int> _delegatedByTurn = {};

  /// Presentation evidence only: remember an observed roster, never infer
  /// children from delegation calls or from a previous turn.
  void observeDelegates(int turnRevision, int count) {
    if (count <= (_delegatedByTurn[turnRevision] ?? 0)) return;
    _delegatedByTurn[turnRevision] = count;
    while (_delegatedByTurn.length > capacity) {
      _delegatedByTurn.remove(_delegatedByTurn.keys.first);
    }
  }

  Map<String, dynamic> withDelegates(
    Map<String, dynamic> row,
    int turnRevision,
  ) {
    final count = _delegatedByTurn[turnRevision] ?? 0;
    if (count <= (row[delegatedCountKey] as int? ?? 0)) return row;
    return Map<String, dynamic>.unmodifiable({
      ...row,
      delegatedCountKey: count,
    });
  }

  /// The finished answer [row] as it must be drawn. [row] itself when nothing
  /// was known to be lost; otherwise a copy that carries the remembered trace
  /// (and the measured working time, if the row lost it too).
  ///
  /// [textKey]: what pairs an answer that has no durable id yet (the one a
  /// turn just closed locally) with the saved copy that replaces it: the
  /// prompt it answers and its text. A row with a durable id is paired by that
  /// id alone; text never joins two rows that both have one.
  Map<String, dynamic> settle(Map<String, dynamic> row, {String? textKey}) {
    final handed = _handed[row];
    if (handed != null) return handed;
    final ids = _idKeys(row);
    final weight = _Weight.of(row);
    _Known? known;
    for (final id in ids) {
      known = _byId[id];
      if (known != null) break;
    }
    if (known == null && textKey != null) {
      // An answer without an id is the local one, or the saved copy of an
      // answer first seen without it: both are paired by prompt and text.
      final byText = _byText[textKey];
      if (byText != null && (ids.isEmpty || byText.local)) known = byText;
    }
    if (known != null &&
        (known.row[delegatedCountKey] as int? ?? 0) >
            (row[delegatedCountKey] as int? ?? 0)) {
      row = Map<String, dynamic>.unmodifiable({
        ...row,
        delegatedCountKey: known.row[delegatedCountKey],
      });
    }
    var result = row;
    if (known != null && known.weight.dominates(weight)) {
      result = _carry(row, known);
      assert(() {
        carriedCount++;
        return true;
      }());
      // The remembered entry stays the richest one; it only learns the ids.
      _remember(ids, textKey, known.weight, known.row, local: known.local);
    } else if (known != null && _lostTime(known.row, row)) {
      // The same steps, but the saved copy has no measured time: the line
      // would read «Trabajó · 3 pasos» where it said «Trabajó 1:12 · 3 pasos».
      result = _withTime(row, known.row);
      _remember(ids, textKey, weight, result, local: known.local);
    } else if (weight.hasSteps) {
      _remember(ids, textKey, weight, row, local: ids.isEmpty);
    }
    if (_handed.length > capacity) _handed.clear();
    if (!identical(result, row)) _handed[row] = result;
    return result;
  }

  Map<String, dynamic> _carry(Map<String, dynamic> row, _Known known) {
    final out = <String, dynamic>{...row};
    out[assistantActivityTraceKey] = known.row[assistantActivityTraceKey];
    if (known.row[delegatedCountKey] case final int count) {
      out[delegatedCountKey] = count;
    }
    if (_lostTime(known.row, row)) {
      out[_timeKey] = known.row[_timeKey];
    }
    return Map<String, dynamic>.unmodifiable(out);
  }

  static const _timeKey = '_activity_duration_seconds';

  static bool _hasTime(Map<String, dynamic> row) {
    final value = row[_timeKey];
    return value is num && value.isFinite && value > 0;
  }

  /// [known] measured the turn's time and [row] has none.
  static bool _lostTime(Map<String, dynamic> known, Map<String, dynamic> row) =>
      _hasTime(known) && !_hasTime(row);

  static Map<String, dynamic> _withTime(
    Map<String, dynamic> row,
    Map<String, dynamic> known,
  ) => Map<String, dynamic>.unmodifiable({...row, _timeKey: known[_timeKey]});

  void _remember(
    List<String> ids,
    String? textKey,
    _Weight weight,
    Map<String, dynamic> row, {
    required bool local,
  }) {
    final entry = _Known(weight, row, local: local);
    for (final id in ids) {
      _byId.remove(id);
      _byId[id] = entry;
    }
    if (textKey != null) {
      _byText.remove(textKey);
      _byText[textKey] = entry;
    }
    for (final map in [_byId, _byText]) {
      while (map.length > capacity) {
        map.remove(map.keys.first);
      }
    }
  }

  static List<String> _idKeys(Map<String, dynamic> row) {
    final identity = canonicalTranscriptIdentity(row);
    if (identity == null) return const [];
    return [
      if (identity.messageId != null) 'm:${identity.messageId}',
      if (identity.rowId != null) 'r:${identity.rowId}',
    ];
  }
}

class _Known {
  const _Known(this.weight, this.row, {required this.local});

  final _Weight weight;
  final Map<String, dynamic> row;

  /// First seen without a durable id: the answer a turn closed on this device.
  final bool local;
}

/// How much of a turn a trace shows: the settled tool steps and the thoughts
/// that have text. A running call is not drawn once the turn is over, so it
/// weighs nothing.
class _Weight {
  const _Weight(this.tools, this.thoughts);

  final int tools;
  final int thoughts;

  bool get hasSteps => tools > 0 || thoughts > 0;

  /// This weighs at least as much as [other] in both and more in one: showing
  /// [other] instead would take something away.
  bool dominates(_Weight other) =>
      tools >= other.tools &&
      thoughts >= other.thoughts &&
      (tools > other.tools || thoughts > other.thoughts);

  static _Weight of(Map<String, dynamic> row) {
    var tools = 0;
    var thoughts = 0;
    for (final step in normalizeAssistantActivityTrace(
      row[assistantActivityTraceKey],
    )) {
      if (step['kind'] == 'reasoning') {
        if ((step['text']?.toString().trim() ?? '').isNotEmpty) thoughts++;
        continue;
      }
      final label = step['label']?.toString() ?? '';
      if (step['status'] == 'running' ||
          isInternalActivityLabel(label) ||
          isAgentTaskToolLabel(label)) {
        continue;
      }
      tools++;
    }
    return _Weight(tools, thoughts);
  }
}
