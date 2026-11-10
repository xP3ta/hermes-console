// The chats of the profiles the list of chats is NOT scoped to, for the
// agent rail. The list reads one profile (the active one); without this the
// rail could only count that profile's chats and every other face said
// «0 chats» even when the profile had conversations (tablet, 9852:
// «hay perfiles con chats y no salen»).
//
// Bounded on purpose: one sweep per connection and list scope at most every
// [ProfileRailChats.ttl], one request on the wire at a time, a short pause
// between them, at most [ProfileRailChats.maxProfiles] profiles. A profile
// that fails (403, a profile gone) is skipped and keeps its previous value;
// a few failures in a row (the server is down) end the sweep. Values live
// in memory only (titles never touch the disk) and are painted at once when
// the rail is built again. Nothing is read while App Lock is on.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/session.dart';

/// One profile's first page of chats and whether the server has more.
///
/// No count of the server's rides along: its `total` also counts rows the
/// page never carries (hidden on the server, auxiliary, children), so a
/// face said «7» over a panel of two chats (Fold, 9960). The rail
/// counts the rows it lists, «N+» when [more].
@immutable
final class ProfileRailPage {
  const ProfileRailPage({required this.sessions, this.more = false});

  final List<Session> sessions;

  /// Whether the same query has rows past this page.
  final bool more;
}

typedef ProfileRailPageLoader =
    Future<ProfileRailPage> Function(String profileOwner);

/// Per-connection cache of [ProfileRailPage]s under one list scope.
final class ProfileRailChats extends ChangeNotifier {
  ProfileRailChats({
    this.ttl = const Duration(minutes: 1),
    this.spacing = const Duration(milliseconds: 300),
    this.maxProfiles = 16,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Shortest time between two sweeps of the same scope.
  final Duration ttl;

  /// Pause between two requests of one sweep.
  final Duration spacing;

  /// Most profiles one sweep reads.
  final int maxProfiles;

  /// Failures in a row that end a sweep: past one profile that refuses, the
  /// server itself is likely down.
  static const int maxConsecutiveFailures = 3;
  final DateTime Function() _now;

  static final Map<String, ProfileRailChats> _shared = {};

  /// The cache of [connectionId], shared by every Chats screen of it.
  static ProfileRailChats of(String connectionId) =>
      _shared.putIfAbsent(connectionId, ProfileRailChats.new);

  @visibleForTesting
  static void debugReset() {
    for (final cache in _shared.values) {
      cache.cancel();
    }
    _shared.clear();
  }

  String? _scope;
  final Map<String, ProfileRailPage> _pages = {};
  DateTime? _sweptAt;
  int _generation = 0;
  Future<void>? _sweep;

  /// Who started the running sweep: another screen of the same connection
  /// does not cut it ([cancel]).
  Object? _sweepOwner;

  /// The last sweep started, cancelled or not: the next one waits for it,
  /// so a request a cancel left on the wire is never joined by another.
  Future<void> _tail = Future<void>.value();

  /// The pause between two requests, cut short by [cancel] (no timer
  /// outlives the screen that started the sweep).
  Timer? _pauseTimer;
  Completer<void>? _pauseDone;

  /// Requests made since creation (tests bound them).
  @visibleForTesting
  int debugRequests = 0;

  /// Whether a sweep is on its way.
  bool get sweeping => _sweep != null;

  /// [owner]'s page under [scope], if one was read.
  ProfileRailPage? page(String scope, String owner) =>
      scope == _scope ? _pages[owner] : null;

  /// Every page under [scope].
  Iterable<ProfileRailPage> pages(String scope) =>
      scope == _scope ? _pages.values : const [];

  /// Starts a sweep of [owners] (most wanted first) under [scope], unless
  /// one is running or ran within [ttl] for this scope. Never notifies
  /// synchronously, so a build may call it. A new [scope] (another category,
  /// the archived view) drops the previous scope's pages and its sweep.
  /// A sweep counts as done for [ttl] once it read a page, or once it ended
  /// on its own; one cancelled before any page does not hold the next.
  /// [requester] is who asks (the screen): only it cancels its sweep.
  void refresh({
    required String scope,
    required List<String> owners,
    required ProfileRailPageLoader load,
    ValueListenable<bool>? locked,
    Object? requester,
  }) {
    if (scope != _scope) {
      cancel();
      _scope = scope;
      _pages.clear();
      _sweptAt = null;
    }
    if (_sweep != null || owners.isEmpty || locked?.value == true) return;
    final last = _sweptAt;
    if (last != null && _now().difference(last) < ttl) return;
    final generation = ++_generation;
    final batch = owners.take(maxProfiles).toList(growable: false);
    final previous = _tail;
    late final Future<void> sweep;
    sweep = _run(generation, scope, batch, load, locked, previous).whenComplete(
      () {
        if (identical(_sweep, sweep)) {
          _sweep = null;
          _sweepOwner = null;
        }
      },
    );
    _sweep = _tail = sweep;
    _sweepOwner = requester;
  }

  /// Stops the sweep after the request on the wire (whose answer is
  /// dropped). The pages already read stay. With a [requester], only a
  /// sweep it started stops: a screen going away does not cut the sweep of
  /// another screen of the same connection.
  void cancel([Object? requester]) {
    if (requester != null &&
        _sweep != null &&
        !identical(requester, _sweepOwner)) {
      return;
    }
    _generation++;
    _sweep = null;
    _sweepOwner = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final pause = _pauseDone;
    _pauseDone = null;
    pause?.complete();
  }

  Future<void> _pause() {
    final done = _pauseDone = Completer<void>();
    _pauseTimer = Timer(spacing, () {
      if (identical(_pauseDone, done)) {
        _pauseDone = null;
        _pauseTimer = null;
      }
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  Future<void> _run(
    int generation,
    String scope,
    List<String> owners,
    ProfileRailPageLoader load,
    ValueListenable<bool>? locked,
    Future<void> previous,
  ) async {
    await previous;
    bool live() =>
        generation == _generation && scope == _scope && locked?.value != true;
    var failures = 0;
    for (var i = 0; i < owners.length; i++) {
      if (i > 0 && spacing > Duration.zero) await _pause();
      if (!live()) return;
      final ProfileRailPage page;
      try {
        debugRequests++;
        page = await load(owners[i]);
      } catch (_) {
        if (!live()) return;
        // This profile keeps what was read before; the others are still
        // read. Several in a row: the server is down, ask after [ttl].
        if (++failures >= maxConsecutiveFailures) {
          _sweptAt = _now();
          return;
        }
        continue;
      }
      if (!live()) return;
      failures = 0;
      _sweptAt = _now();
      _pages[owners[i]] = page;
      notifyListeners();
    }
    // Ended on its own (even with no page): the next one waits for [ttl].
    if (live()) _sweptAt = _now();
  }
}
