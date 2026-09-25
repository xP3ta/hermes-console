import '../models/transcript_privacy_state.dart';

/// Owns the accepted evidence revision shared by every transcript projection.
/// Transport and session admission remain the caller's responsibility.
final class TranscriptPublicationCoordinator {
  TranscriptPrivacyGraph _graph = TranscriptPrivacyGraph();
  int _revision = 0;
  int _generation = 0;
  bool _suppressedWindow = false;

  TranscriptPrivacyGraph get graph => _graph;
  int get revision => _revision;

  /// Changes whenever [project] could return a different result, including a
  /// [restore] to an older or equal [revision]. Projection caches key off it.
  int get generation => _generation;
  bool get hasSuppressedWindow => _suppressedWindow;

  void reduce(Iterable<TranscriptPrivacyObservation> observations) {
    final evidence = observations.toList(growable: false);
    if (evidence.any((observation) => observation.negative)) {
      _suppressedWindow = true;
    }
    final next = _graph.union(evidence);
    if (next.facts.length == _graph.facts.length) return;
    _graph = next;
    _revision++;
    _generation++;
  }

  List<Map<String, dynamic>> project(List<Map<String, dynamic>> source) {
    final next = source
        .where(
          (row) => !_graph.excludes(TranscriptPrivacyObservation.fromRaw(row)),
        )
        .toList();
    if (next.length != source.length) _suppressedWindow = true;
    return next.length == source.length ? source : next;
  }

  TranscriptPrivacyCheckpoint checkpoint({
    required String connectionId,
    required String profile,
    required String storedSessionId,
    required TranscriptPrivacyCoverage coverage,
  }) => TranscriptPrivacyCheckpoint(
    connectionId: connectionId,
    profile: profile,
    storedSessionId: storedSessionId,
    revision: _revision,
    coverage: coverage,
    suppressedWindow: _suppressedWindow,
    facts: _graph.facts,
  );

  void restore(TranscriptPrivacyCheckpoint checkpoint) {
    _graph = TranscriptPrivacyGraph(checkpoint.facts);
    _revision = checkpoint.revision;
    _suppressedWindow = checkpoint.suppressedWindow;
    _generation++;
  }
}
