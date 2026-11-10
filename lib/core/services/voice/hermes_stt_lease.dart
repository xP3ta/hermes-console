// STT warm-up lease, copied from Hermes Desktop `lib/stt-lease.ts`.
//
// A voice-input session (dictation, or each listening start of a voice
// conversation) tells the host STT is about to be needed: acquiring
// `POST /api/audio/stt-lease` pre-loads the host's local faster-whisper model
// so the transcription starts hot instead of paying the cold load inside its
// timeout; releasing drops the lease and the host keeps the model resident
// (`hermes_cli/web_routers/audio.py:482-513`, `tools/stt_lease.py`). Warm-up
// is an optimization: it never fails and recording never waits on it.

/// `POST /api/audio/stt-lease` of the bound Dashboard and profile.
typedef HermesSttLeaseRequest =
    Future<Map<String, dynamic>> Function(String lease, bool active);

/// One lease name on one Dashboard binding (Desktop `syncSttLease`,
/// `stt-lease.ts:57-95`): calls are serialized so a fast on→off→on cannot be
/// reordered on the wire, an acquire coalesces onto a queued acquire that is
/// still the latest intent, a release of a lease never acquired sends
/// nothing, and a failed call is forgotten so the next one retries.
class HermesSttLease {
  HermesSttLease({
    required this.name,
    required this.request,
    this.staleAfter = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String name;

  /// The `POST /api/audio/stt-lease` of this binding.
  final HermesSttLeaseRequest request;

  /// An acquire still on the wire after this long is not a readiness
  /// barrier any more (a dropped network can leave it hanging until its
  /// 180 s deadline): later acquires do not wait on it.
  final Duration staleAfter;
  final DateTime Function() _now;

  /// Latest requested state: true = acquire, false = release.
  bool? _intent;
  ({bool active, Future<void> future, DateTime startedAt})? _tail;

  /// Brings the host's view in line with [active]. The future settles when
  /// this call settled on the wire (the readiness barrier before
  /// transcribing) and never fails.
  Future<void> sync(bool active) {
    final tail = _tail;
    if (!active && _intent != true) {
      return tail?.future ?? Future<void>.value();
    }
    if (active && tail != null && tail.active && _intent == true) {
      return _now().difference(tail.startedAt) >= staleAfter
          ? Future<void>.value()
          : tail.future;
    }
    _intent = active;
    late final Future<void> future;
    future = (tail?.future ?? Future<void>.value())
        .then((_) async {
          // Latest intent wins: flipped again while queued, the newer call
          // sends its own state.
          if (_intent == active) await request(name, active);
        })
        .catchError((Object _) {
          // Older host without the route, or no network: forget what was
          // "sent" so the next flip retries honestly.
          if (_intent == active) _intent = null;
        })
        .whenComplete(() {
          if (identical(_tail?.future, future)) _tail = null;
        });
    _tail = (active: active, future: future, startedAt: _now());
    return future;
  }
}
