import 'dart:async';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_artifacts.dart';

Session fakeArtifactSession(
  String id, {
  String profile = 'default',
  double at = 1000,
}) => Session.tryParse({
  'id': id,
  'title': 'Chat $id',
  'profile': profile,
  'started_at': at,
})!;

Map<String, dynamic> fakeMediaRow(String path, {num? ts}) => {
  'role': 'assistant',
  'content': 'MEDIA:$path',
  'timestamp': ?ts,
};

/// A [GlobalArtifactsSource] over fixed transcripts, recording every page
/// asked for. While [gate] is set, every page waits for it.
class FakeGlobalArtifactsSource implements GlobalArtifactsSource {
  FakeGlobalArtifactsSource(this.sessions, this.transcripts);

  final List<Session> sessions;

  /// Chronological rows per conversation id.
  final Map<String, List<Map<String, dynamic>>> transcripts;
  final failing = <String>{};
  final tooLarge = <String>{};
  final pages = <String>[];
  int listCalls = 0;
  bool listFails = false;
  Completer<void>? gate;

  @override
  Future<List<Session>> recentSessions(int limit) async {
    listCalls++;
    if (listFails) throw StateError('offline');
    return sessions;
  }

  @override
  Future<SessionMessagesPage> page(
    Session session, {
    required int offset,
    required int limit,
  }) async {
    pages.add('${session.id}@$offset');
    await Future<void>.value();
    final wait = gate;
    if (wait != null) await wait.future;
    if (failing.contains(session.id)) throw StateError('read failed');
    if (tooLarge.contains(session.id)) {
      throw const SessionTranscriptTooLargeException();
    }
    final rows = transcripts[session.id] ?? const [];
    final slice = rows.skip(offset).take(limit).toList();
    return SessionMessagesPage(
      messages: slice,
      pagination: {'limit': limit, 'offset': offset, 'returned': slice.length},
    );
  }
}
