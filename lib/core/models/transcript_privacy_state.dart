import '../utils/assistant_content.dart';
import '../utils/chat_turn.dart';

/// Identity evidence is a set of exact typed facts, never `matches` equality.
/// No body, timestamp or remote ordinal is part of an identity fact.
final class TranscriptPrivacyObservation {
  final int? rowId;
  final String? messageId;
  final bool negative;
  final Set<int> invalidRowClaims;
  final Set<String> invalidMessageClaims;

  TranscriptPrivacyObservation({
    this.rowId,
    this.messageId,
    required this.negative,
    Iterable<int> invalidRowClaims = const [],
    Iterable<String> invalidMessageClaims = const [],
  }) : invalidRowClaims = Set.unmodifiable(invalidRowClaims),
       invalidMessageClaims = Set.unmodifiable(invalidMessageClaims);

  factory TranscriptPrivacyObservation.fromRaw(Map<String, dynamic> row) {
    final identity = canonicalTranscriptIdentity(row);
    final consistent = transcriptIdentityAliasesAreConsistent(row);
    // Parse every claim using the canonical policy, including aliases from an
    // invalid observation. Such claims block inference but never create links.
    final claims = [
      if (!consistent)
        for (final key in const [
          '_desktopRowId',
          '_desktopMessageId',
          'row_id',
          '_row_id',
          'message_id',
          'id',
        ])
          ?canonicalTranscriptIdentity({key: row[key]}),
    ];
    return TranscriptPrivacyObservation(
      rowId: identity?.rowId,
      messageId: identity?.messageId,
      negative:
          hasPrivateTranscriptClassifier(row) ||
          row['display_kind'] == 'hidden',
      invalidRowClaims: claims.map((c) => c.rowId).whereType<int>(),
      invalidMessageClaims: claims.map((c) => c.messageId).whereType<String>(),
    );
  }

  bool get invalid =>
      invalidRowClaims.isNotEmpty || invalidMessageClaims.isNotEmpty;
  bool get addressable => rowId != null || messageId != null;
  (int?, String?) get tuple => (rowId, messageId);

  bool exactlyEquals(TranscriptPrivacyObservation other) =>
      tuple == other.tuple &&
      negative == other.negative &&
      invalidRowClaims.length == other.invalidRowClaims.length &&
      invalidRowClaims.containsAll(other.invalidRowClaims) &&
      invalidMessageClaims.length == other.invalidMessageClaims.length &&
      invalidMessageClaims.containsAll(other.invalidMessageClaims);

  Map<String, Object?> toJson() => {
    if (rowId != null) 'row_id': rowId,
    if (messageId != null) 'message_id': messageId,
    'negative': negative,
    if (invalidRowClaims.isNotEmpty)
      'invalid_rows': invalidRowClaims.toList()..sort(),
    if (invalidMessageClaims.isNotEmpty)
      'invalid_messages': invalidMessageClaims.toList()..sort(),
  };

  static TranscriptPrivacyObservation? fromJson(Object? value) {
    if (value is! Map) return null;
    final row = value['row_id'];
    final message = value['message_id'];
    final negative = value['negative'];
    final invalidRows = value['invalid_rows'];
    final invalidMessages = value['invalid_messages'];
    if ((row != null && (row is! int || row <= 0)) ||
        (message != null && (message is! String || message.isEmpty)) ||
        negative is! bool ||
        (invalidRows != null && invalidRows is! List) ||
        (invalidMessages != null && invalidMessages is! List)) {
      return null;
    }
    final parsedRows = invalidRows is List
        ? invalidRows.whereType<int>().where((id) => id > 0).toList()
        : const <int>[];
    final parsedMessages = invalidMessages is List
        ? invalidMessages
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toList()
        : const <String>[];
    if ((invalidRows is List && parsedRows.length != invalidRows.length) ||
        (invalidMessages is List &&
            parsedMessages.length != invalidMessages.length)) {
      return null;
    }
    return TranscriptPrivacyObservation(
      rowId: row as int?,
      messageId: message as String?,
      negative: negative,
      invalidRowClaims: parsedRows,
      invalidMessageClaims: parsedMessages,
    );
  }
}

enum TranscriptPrivacyCoverage { complete, partial, omitted, unknown }

final class TranscriptPrivacyCheckpoint {
  final String connectionId;
  final String profile;
  final String storedSessionId;
  final int revision;
  final TranscriptPrivacyCoverage coverage;
  final bool suppressedWindow;
  final List<TranscriptPrivacyObservation> facts;

  const TranscriptPrivacyCheckpoint({
    required this.connectionId,
    required this.profile,
    required this.storedSessionId,
    required this.revision,
    required this.coverage,
    required this.suppressedWindow,
    required this.facts,
  });

  Map<String, Object?> toJson() => {
    'connection_id': connectionId,
    'profile': profile,
    'stored_session_id': storedSessionId,
    'revision': revision,
    'coverage': coverage.name,
    'suppressed_window': suppressedWindow,
    'facts': facts.map((fact) => fact.toJson()).toList(),
  };

  static TranscriptPrivacyCheckpoint? fromJson(Object? value) {
    if (value is! Map ||
        value['connection_id'] is! String ||
        value['profile'] is! String ||
        value['stored_session_id'] is! String ||
        value['revision'] is! int ||
        (value['revision'] as int) < 0 ||
        value['suppressed_window'] is! bool ||
        value['coverage'] is! String ||
        value['facts'] is! List) {
      return null;
    }
    TranscriptPrivacyCoverage? coverage;
    for (final item in TranscriptPrivacyCoverage.values) {
      if (item.name == value['coverage']) coverage = item;
    }
    if (coverage == null) return null;
    final rawFacts = value['facts'] as List;
    final facts = rawFacts
        .map(TranscriptPrivacyObservation.fromJson)
        .whereType<TranscriptPrivacyObservation>()
        .toList();
    if (facts.length != rawFacts.length) return null;
    return TranscriptPrivacyCheckpoint(
      connectionId: value['connection_id'] as String,
      profile: value['profile'] as String,
      storedSessionId: value['stored_session_id'] as String,
      revision: value['revision'] as int,
      coverage: coverage,
      suppressedWindow: value['suppressed_window'] as bool,
      facts: List.unmodifiable(facts),
    );
  }
}

/// Monotonic facts and recalculable conflict islands have separate lifetimes.
/// A contradictory island is used only to stop partial inference, not to merge
/// the entities that happen to share one coordinate.
final class TranscriptPrivacyGraph {
  final List<TranscriptPrivacyObservation> facts;
  final Map<int, Set<String>> _messagesByRow = {};
  final Map<String, Set<int>> _rowsByMessage = {};
  final Set<int> _invalidRows = {};
  final Set<String> _invalidMessages = {};

  TranscriptPrivacyGraph([
    Iterable<TranscriptPrivacyObservation> source = const [],
  ]) : facts = _exactFacts(source) {
    for (final fact in facts) {
      _invalidRows.addAll(fact.invalidRowClaims);
      _invalidMessages.addAll(fact.invalidMessageClaims);
      if (!fact.invalid && fact.rowId != null && fact.messageId != null) {
        (_messagesByRow[fact.rowId!] ??= {}).add(fact.messageId!);
        (_rowsByMessage[fact.messageId!] ??= {}).add(fact.rowId!);
      }
    }
  }

  static List<TranscriptPrivacyObservation> _exactFacts(
    Iterable<TranscriptPrivacyObservation> source,
  ) {
    final result = <TranscriptPrivacyObservation>[];
    for (final fact in source) {
      if (!fact.addressable && !fact.invalid) continue;
      if (!result.any(fact.exactlyEquals)) result.add(fact);
    }
    return List.unmodifiable(result);
  }

  TranscriptPrivacyGraph union(Iterable<TranscriptPrivacyObservation> source) =>
      TranscriptPrivacyGraph([...facts, ...source]);

  ({Set<int> rows, Set<String> messages, bool unambiguous}) _island(
    TranscriptPrivacyObservation query,
  ) {
    final rows = <int>{if (query.rowId != null) query.rowId!};
    final messages = <String>{if (query.messageId != null) query.messageId!};
    var changed = true;
    while (changed) {
      final before = (rows.length, messages.length);
      for (final row in rows.toList()) {
        messages.addAll(_messagesByRow[row] ?? const {});
      }
      for (final message in messages.toList()) {
        rows.addAll(_rowsByMessage[message] ?? const {});
      }
      changed = before != (rows.length, messages.length);
    }
    return (
      rows: rows,
      messages: messages,
      unambiguous:
          rows.length <= 1 &&
          messages.length <= 1 &&
          !rows.any(_invalidRows.contains) &&
          !messages.any(_invalidMessages.contains),
    );
  }

  bool permitsPartialInference(TranscriptPrivacyObservation query) =>
      !query.invalid && query.addressable && _island(query).unambiguous;

  bool excludes(TranscriptPrivacyObservation query) {
    if (query.negative) return true;
    if (query.invalid || !query.addressable) return false;
    if (facts.any((f) => f.negative && !f.invalid && f.tuple == query.tuple)) {
      return true;
    }
    final island = _island(query);
    if (!island.unambiguous) return false;
    return facts.any(
      (f) =>
          f.negative &&
          !f.invalid &&
          ((f.rowId != null && island.rows.contains(f.rowId)) ||
              (f.messageId != null && island.messages.contains(f.messageId))),
    );
  }
}
