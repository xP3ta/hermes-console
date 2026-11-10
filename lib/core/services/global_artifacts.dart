import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/byte_bounded_lru_cache.dart' show PrivateRenderCaches;
import 'app_error_log.dart';
import 'chat_content_extractor.dart';
import 'connection_manager.dart';

/// What «Artefactos» reads across conversations, as Hermes Desktop's
/// Artifacts page does (`app/artifacts/index.tsx`, `refreshArtifacts`, and
/// `artifact-utils.ts`, `loadArtifactsForSessions`).
abstract interface class GlobalArtifactsSource {
  /// Desktop `listAllProfileSessions(limit, 1)`: the most recent
  /// conversations of every profile with at least one message.
  Future<List<Session>> recentSessions(int limit);

  /// Desktop `getSessionMessages(id, profile, {limit, offset,
  /// order: 'oldest', includeCompacted: true})`: one page of a transcript.
  Future<SessionMessagesPage> page(
    Session session, {
    required int offset,
    required int limit,
  });
}

/// [GlobalArtifactsSource] over the Dashboard of one connection.
final class DashboardGlobalArtifactsSource implements GlobalArtifactsSource {
  DashboardGlobalArtifactsSource(
    this.client, {
    this.maxPageBytes = defaultMaxPageBytes,
  });

  /// A page is read only up to this many bytes; a larger one skips its
  /// conversation, like Desktop's safe-load limit (32M characters there,
  /// far less here: a phone, and pages come without inline images).
  static const int defaultMaxPageBytes = 4 * 1024 * 1024;

  final DashboardClient client;
  final int maxPageBytes;

  @override
  Future<List<Session>> recentSessions(int limit) async {
    final query = Uri(
      queryParameters: {
        'limit': '$limit',
        'offset': '0',
        'min_messages': '1',
        'archived': 'exclude',
        'order': 'recent',
        'profile': 'all',
      },
    ).query;
    final data = await client.apiGet('profiles/sessions?$query');
    final raw = data['sessions'] ?? data['data'];
    if (raw is! List) {
      throw const FormatException('Malformed aggregate session response');
    }
    // A row must say its owner profile, as Mission Control requires of the
    // same list: the chat opens in that profile, never the active one by
    // default (REVIEW-R4 P2-B6). A row without one is left out.
    return [
      for (final value in raw)
        if (Session.tryParse(value) case final session?)
          if (!session.id.startsWith('mob-aux-') &&
              (session.profile?.trim() ?? '').isNotEmpty)
            session,
    ];
  }

  @override
  Future<SessionMessagesPage> page(
    Session session, {
    required int offset,
    required int limit,
  }) => client.getSessionMessagesPage(
    session.id,
    profile: Session.profileOwner(session.profile),
    limit: limit,
    offset: offset,
    oldestFirst: true,
    // Kilobytes instead of every stored image's bytes; an image the agent
    // delivered is still listed by its path or URL.
    inlineImages: false,
    maxBodyBytes: maxPageBytes,
  );
}

/// One item of the view across conversations and the conversation it came
/// from (Desktop's `ArtifactRecord.sessionId/sessionTitle`).
@immutable
class GlobalArtifact {
  const GlobalArtifact({required this.item, required this.session});

  final ChatContentItem item;
  final Session session;

  /// Unique in the view: one file can come from two conversations.
  String get key => '${session.id}:${item.value}';
}

enum GlobalArtifactsPhase { idle, listing, indexing, ready, failed }

/// What the view shows. Immutable; the controller replaces it.
@immutable
class GlobalArtifactsState {
  const GlobalArtifactsState({
    this.phase = GlobalArtifactsPhase.idle,
    this.artifacts = const [],
    this.listed = 0,
    this.indexed = 0,
    this.batchEnd = 0,
    this.skipped = 0,
    this.skippedTooLarge = 0,
    this.skippedTimedOut = 0,
    this.truncated = 0,
    this.capped = false,
    this.budgetReached = false,
  });

  final GlobalArtifactsPhase phase;

  /// Newest first (Desktop sorts by timestamp; equal times keep the order
  /// they were found in).
  final List<GlobalArtifact> artifacts;

  /// Recent conversations in the window.
  final int listed;

  /// Conversations read so far (indexed or skipped).
  final int indexed;

  /// Where the running batch stops.
  final int batchEnd;

  /// Conversations that could not be read (Desktop «Skipped N of M»), of
  /// which [skippedTooLarge] had a page past the safe-load limit and
  /// [skippedTimedOut] a page that did not arrive in time.
  final int skipped;
  final int skippedTooLarge;
  final int skippedTimedOut;

  /// Conversations read only up to the page cap.
  final int truncated;

  /// The view hit its item cap; older items were not kept.
  final bool capped;

  /// The last batch stopped at its byte budget; the next batch goes on.
  final bool budgetReached;

  bool get busy =>
      phase == GlobalArtifactsPhase.listing ||
      phase == GlobalArtifactsPhase.indexing;

  /// More recent conversations remain to read, on request.
  bool get hasMore => !busy && indexed < listed;

  GlobalArtifactsState copyWith({
    GlobalArtifactsPhase? phase,
    List<GlobalArtifact>? artifacts,
    int? listed,
    int? indexed,
    int? batchEnd,
    int? skipped,
    int? skippedTooLarge,
    int? skippedTimedOut,
    int? truncated,
    bool? capped,
    bool? budgetReached,
  }) => GlobalArtifactsState(
    phase: phase ?? this.phase,
    artifacts: artifacts ?? this.artifacts,
    listed: listed ?? this.listed,
    indexed: indexed ?? this.indexed,
    batchEnd: batchEnd ?? this.batchEnd,
    skipped: skipped ?? this.skipped,
    skippedTooLarge: skippedTooLarge ?? this.skippedTooLarge,
    skippedTimedOut: skippedTimedOut ?? this.skippedTimedOut,
    truncated: truncated ?? this.truncated,
    capped: capped ?? this.capped,
    budgetReached: budgetReached ?? this.budgetReached,
  );
}

/// What one connection's view had read, kept in memory so reopening it
/// shows the same list without reading again.
class _Snapshot {
  _Snapshot(this.sessions, this.next, this.state);

  final List<Session> sessions;

  /// The next conversation to read.
  final int next;

  /// Holds the view's items: already capped at
  /// [GlobalArtifactsController.maxArtifacts].
  final GlobalArtifactsState state;
}

/// Indexes the artifacts of the recent conversations, Desktop's way: one
/// conversation after another, each transcript in pages of [pageSize]
/// oldest first, one page in memory at a time.
///
/// Bounded for a phone's data and battery, where Desktop reads its 30 most
/// recent sessions in one go:
/// - the window is the same [sessionWindow] (30) conversations, read
///   [batchSize] (10) at a time; the next batch only on request
///   ([loadMore]);
/// - a conversation is read up to [maxPagesPerSession] pages (2000 messages
///   by default) and [maxItemsPerSession] items; past that it counts as
///   [GlobalArtifactsState.truncated];
/// - a batch reads at most [batchByteBudget] bytes of transcript (32 MiB);
///   past that it stops after the conversation in hand
///   ([GlobalArtifactsState.budgetReached]) and the next batch goes on;
/// - the view, and what is kept in memory after leaving it, hold at most
///   [maxArtifacts] items;
/// - [cancel] (leaving the view) stops after the page in flight and drops
///   the half-read conversation; [loadMore] resumes from it.
class GlobalArtifactsController extends ChangeNotifier {
  GlobalArtifactsController({
    required this.source,
    required this.cacheKey,
    this.sessionWindow = 30,
    this.batchSize = 10,
    this.pageSize = 100,
    this.maxPagesPerSession = 20,
    this.maxItemsPerSession = 500,
    this.batchByteBudget = 32 * 1024 * 1024,
    this.maxArtifacts = 3000,
  }) {
    final snapshot = _memory[cacheKey];
    if (snapshot != null) {
      _sessions = snapshot.sessions;
      _next = snapshot.next;
      _state = snapshot.state.busy
          ? snapshot.state.copyWith(phase: GlobalArtifactsPhase.ready)
          : snapshot.state;
    }
  }

  final GlobalArtifactsSource source;

  /// Which connection's memory this view reads and writes.
  final String cacheKey;
  final int sessionWindow;
  final int batchSize;
  final int pageSize;
  final int maxPagesPerSession;
  final int maxItemsPerSession;
  final int batchByteBudget;
  final int maxArtifacts;

  /// The last views read, by connection; a few at most. Emptied with the
  /// app's private caches (a connection removed, its keys revoked, the
  /// profile changed) and per connection when its credentials or authority
  /// change ([forget]). A map literal keeps insertion order: the first key
  /// is the oldest.
  static final Map<String, _Snapshot> _memory = () {
    PrivateRenderCaches.register(clearMemory);
    PrivateRenderCaches.registerConnection(forget);
    return <String, _Snapshot>{};
  }();
  static const int _memoryEntries = 2;

  /// Forgets every view read.
  static void clearMemory() => _memory.clear();

  /// Forgets what was read for [connectionId].
  static void forget(String connectionId) => _memory.remove(connectionId);

  GlobalArtifactsState _state = const GlobalArtifactsState();
  GlobalArtifactsState get state => _state;

  List<Session> _sessions = const [];
  int _next = 0;
  int _generation = 0;
  bool _disposed = false;

  /// Something was read before, in this view or an earlier one.
  bool get hasRead => _state.phase != GlobalArtifactsPhase.idle;

  void _set(GlobalArtifactsState next) {
    _state = next;
    _remember();
    if (!_disposed) notifyListeners();
  }

  void _remember() {
    _memory.remove(cacheKey);
    _memory[cacheKey] = _Snapshot(_sessions, _next, _state);
    while (_memory.length > _memoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// Lists the recent conversations again and reads the first batch
  /// (Desktop's refresh button).
  Future<void> refresh() async {
    final generation = ++_generation;
    _set(const GlobalArtifactsState(phase: GlobalArtifactsPhase.listing));
    final List<Session> sessions;
    try {
      sessions = await source.recentSessions(sessionWindow);
    } catch (_) {
      if (generation != _generation) return;
      _set(const GlobalArtifactsState(phase: GlobalArtifactsPhase.failed));
      return;
    }
    if (generation != _generation) return;
    _sessions = sessions.take(sessionWindow).toList(growable: false);
    _next = 0;
    _set(
      GlobalArtifactsState(
        phase: GlobalArtifactsPhase.ready,
        listed: _sessions.length,
      ),
    );
    await _readBatch(generation);
  }

  /// Reads the next batch of conversations of the window.
  Future<void> loadMore() async {
    if (!_state.hasMore) return;
    await _readBatch(++_generation);
  }

  /// Stops reading after the page in flight (the view was left).
  void cancel() {
    _generation++;
    if (_state.busy) {
      _set(
        _state.copyWith(
          phase: _state.phase == GlobalArtifactsPhase.listing
              ? GlobalArtifactsPhase.idle
              : GlobalArtifactsPhase.ready,
        ),
      );
    }
  }

  Future<void> _readBatch(int generation) async {
    final start = _next;
    final end = (start + batchSize).clamp(0, _sessions.length);
    if (start >= end) return;
    _set(
      _state.copyWith(
        phase: GlobalArtifactsPhase.indexing,
        batchEnd: end,
        budgetReached: false,
      ),
    );
    var bytes = 0;
    for (var index = start; index < end; index++) {
      final session = _sessions[index];
      final items = <String, GlobalArtifact>{};
      var skipped = false, tooLarge = false, truncated = false;
      var timedOut = false;
      var overBudget = false;
      var offset = 0;
      for (var pages = 0; ; pages++) {
        if (pages >= maxPagesPerSession) {
          truncated = true;
          break;
        }
        final SessionMessagesPage page;
        try {
          page = await source.page(session, offset: offset, limit: pageSize);
        } on SessionTranscriptTooLargeException {
          skipped = tooLarge = true;
          break;
        } on TimeoutException {
          skipped = timedOut = true;
          break;
        } catch (_) {
          skipped = true;
          break;
        }
        if (generation != _generation || _disposed) return;
        try {
          bytes += _bytesOf(page);
          // The page is read oldest first; the extractor takes newest first.
          for (final item in collectChatContentChronological(
            page.messages.reversed.toList(growable: false),
          )) {
            if (items.length >= maxItemsPerSession &&
                !items.containsKey(item.value)) {
              truncated = true;
              break;
            }
            items.putIfAbsent(
              item.value,
              () => GlobalArtifact(item: item, session: session),
            );
          }
        } catch (error) {
          // Desktop `loadArtifactsForSessions`: a conversation that cannot
          // be read is a failure and is left out; the others still list.
          AppErrorLog.record('artifacts', error);
          skipped = true;
          break;
        }
        if (truncated) break;
        if (bytes >= batchByteBudget) {
          overBudget = true;
          break;
        }
        final returned = page.rawMessageCount;
        final limit = page.limit;
        // Desktop stops on a legacy reply, an empty page or a short page.
        if (!page.paginationProvided ||
            returned == 0 ||
            limit == null ||
            returned < limit) {
          break;
        }
        offset += returned;
      }
      if (generation != _generation || _disposed) return;
      _next = index + 1;
      final (artifacts, dropped) = _merged(
        skipped ? const <GlobalArtifact>[] : items.values.toList(),
      );
      _set(
        _state.copyWith(
          artifacts: artifacts,
          indexed: _next,
          skipped: _state.skipped + (skipped ? 1 : 0),
          skippedTooLarge: _state.skippedTooLarge + (tooLarge ? 1 : 0),
          skippedTimedOut: _state.skippedTimedOut + (timedOut ? 1 : 0),
          truncated: _state.truncated + (truncated || overBudget ? 1 : 0),
          capped: _state.capped || dropped,
          budgetReached: overBudget,
        ),
      );
      if (overBudget) break;
    }
    _set(_state.copyWith(phase: GlobalArtifactsPhase.ready));
  }

  /// What a page cost on the wire, near enough: its rows as JSON (pages
  /// come without inline images, so the rows are the body).
  static int _bytesOf(SessionMessagesPage page) =>
      utf8.encode(jsonEncode(page.messages)).length;

  /// [found] (one conversation, in the order found) merged into the view:
  /// newest first by the item's time, else its conversation's (Desktop
  /// `artifactTimestamp(message, session)`); equal times keep the order
  /// they were found in, earlier conversations first. Only [maxArtifacts]
  /// are kept; the second value says whether any was dropped.
  (List<GlobalArtifact>, bool) _merged(List<GlobalArtifact> found) {
    double timeOf(GlobalArtifact artifact) {
      final when = artifact.item.timestamp;
      if (when != null) return when.millisecondsSinceEpoch / 1000;
      return artifact.session.updatedAt ?? artifact.session.startedAt;
    }

    final order = List<int>.generate(found.length, (index) => index)
      ..sort((a, b) {
        final byTime = timeOf(found[b]).compareTo(timeOf(found[a]));
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    final current = _state.artifacts;
    final merged = <GlobalArtifact>[];
    var i = 0, j = 0;
    while (merged.length < maxArtifacts &&
        (i < current.length || j < order.length)) {
      final takeCurrent =
          j >= order.length ||
          (i < current.length &&
              timeOf(current[i]) >= timeOf(found[order[j]]));
      merged.add(takeCurrent ? current[i++] : found[order[j++]]);
    }
    final dropped = i < current.length || j < order.length;
    return (List<GlobalArtifact>.unmodifiable(merged), dropped);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
