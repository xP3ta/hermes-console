// SPDX-License-Identifier: MIT
//
// Canonical session-authority adapter (client side only).
//
// Source of truth: the public Hermes Agent v0.22.5 contract
// (`tui_gateway/ws.py`, `tui_gateway/contracts/canonical_sessions.py`,
// `gateway/session_controls.py`, `gateway/session_events.py`,
// `gateway/session_pending_controls.py`). Everything here is pure and is only
// consulted after the CURRENT connection announced `session_authority: true`
// in its `gateway.ready`; a standalone connection never reaches this file.
import 'json_rpc_wire.dart';

/// What the current connection said about `gateway.ready.session_authority`.
enum SessionAuthorityCapability {
  /// No `gateway.ready` seen yet on this connection.
  unknown,

  /// The key is absent or null: a standalone endpoint.
  unsupported,

  /// The key is the boolean `false`.
  declaredFalse,

  /// The key is present with any other type. Never treated as supported.
  malformed,

  /// The key is the boolean `true`.
  supported;

  bool get isCanonical => this == supported;

  static SessionAuthorityCapability fromReadyPayload(
    Map<String, dynamic> payload,
  ) {
    if (!payload.containsKey('session_authority')) return unsupported;
    final value = payload['session_authority'];
    if (value == null) return unsupported;
    if (value is bool) return value ? supported : declaredFalse;
    return malformed;
  }
}

/// One open approval/clarify prompt of a canonical snapshot or event
/// (`CanonicalPendingPrompt`). Bound to the execution generation it was shown
/// for.
final class CanonicalPrompt {
  final String kind;
  final String promptId;
  final int executionGeneration;
  final Map<String, dynamic> raw;

  const CanonicalPrompt({
    required this.kind,
    required this.promptId,
    required this.executionGeneration,
    required this.raw,
  });

  bool get isApproval => kind == 'approval';

  static CanonicalPrompt parse(Object? json) {
    if (json is! Map) throw const FormatException('prompt is not an object');
    final map = Map<String, dynamic>.from(json);
    final kind = map['kind'];
    final id = map['prompt_id'];
    final generation = map['execution_generation'];
    final choices = map['choices'];
    if (kind != 'approval' && kind != 'clarify') {
      throw const FormatException('unknown prompt kind');
    }
    if (id is! String || id.isEmpty || id != id.trim()) {
      throw const FormatException('invalid prompt id');
    }
    if (generation is! int || generation < 0) {
      throw const FormatException('invalid prompt generation');
    }
    if (choices is! List || choices.any((c) => c is! String)) {
      throw const FormatException('invalid prompt choices');
    }
    return CanonicalPrompt(
      kind: kind as String,
      promptId: id,
      executionGeneration: generation,
      raw: Map<String, dynamic>.unmodifiable(map),
    );
  }

  /// The legacy-shaped request payload the chat reducers already render
  /// (`approval.request` / `clarify.request`), keyed by the prompt id.
  Map<String, dynamic> toLegacyRequestPayload() => {
    for (final entry in raw.entries)
      if (entry.key != 'kind' && entry.key != 'execution_generation')
        entry.key: entry.value,
    'request_id': promptId,
  };
}

/// One queued/started admission of `CanonicalSnapshot.pending`.
final class CanonicalAdmission {
  final String admissionId;
  final String inputId;
  final String status;
  final int? executionGeneration;
  final String text;

  const CanonicalAdmission({
    required this.admissionId,
    required this.inputId,
    required this.status,
    required this.executionGeneration,
    required this.text,
  });

  static CanonicalAdmission parse(Object? json) {
    if (json is! Map) throw const FormatException('admission is not an object');
    final id = json['admission_id'];
    final input = json['input_id'];
    final status = json['status'];
    final generation = json['execution_generation'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('invalid admission id');
    }
    if (status is! String ||
        !const {'queued', 'started', 'unknown', 'terminal'}.contains(status)) {
      throw const FormatException('invalid admission status');
    }
    if (generation != null && (generation is! int || generation < 0)) {
      throw const FormatException('invalid admission generation');
    }
    return CanonicalAdmission(
      admissionId: id,
      inputId: input is String ? input : '',
      status: status,
      executionGeneration: generation as int?,
      text: json['text'] is String ? json['text'] as String : '',
    );
  }
}

/// `AdmissionStatus` as `prompt.submit` / `prompt.receipt` answer it. An
/// acknowledgement proves ADMISSION, never completion.
final class CanonicalAdmissionReceipt {
  final String admissionId;
  final String status;
  final String? outcome;
  final int authorityEpoch;
  final int? executionGeneration;

  const CanonicalAdmissionReceipt({
    required this.admissionId,
    required this.status,
    required this.outcome,
    required this.authorityEpoch,
    required this.executionGeneration,
  });

  bool get isTerminal => status == 'terminal';

  static CanonicalAdmissionReceipt parse(Map<String, dynamic> json) {
    final id = json['admission_id'];
    final status = json['status'];
    final epoch = json['authority_epoch'];
    final generation = json['execution_generation'];
    final outcome = json['outcome'];
    if (id is! String ||
        id.isEmpty ||
        status is! String ||
        !const {'queued', 'started', 'unknown', 'terminal'}.contains(status) ||
        epoch is! int ||
        (generation != null && (generation is! int || generation < 0)) ||
        (outcome != null && outcome is! String)) {
      throw const FormatException('invalid admission receipt');
    }
    return CanonicalAdmissionReceipt(
      admissionId: id,
      status: status,
      outcome: outcome as String?,
      authorityEpoch: epoch,
      executionGeneration: generation as int?,
    );
  }
}

/// `CanonicalSnapshot` of `session.resume` / `session.create`. `lastSequence`
/// and `replayEpoch` are read under the same lock as the history, prompts and
/// pending rows, so they are a proven cut: no later guess about the latest
/// server sequence is needed.
final class CanonicalSnapshot {
  final String sessionId;
  final bool running;
  final int authorityEpoch;
  final String replayEpoch;
  final int lastSequence;
  final String subscriptionId;
  final int revision;
  final int executionGeneration;
  final List<CanonicalAdmission> pending;
  final List<CanonicalPrompt> prompts;

  const CanonicalSnapshot({
    required this.sessionId,
    required this.running,
    required this.authorityEpoch,
    required this.replayEpoch,
    required this.lastSequence,
    required this.subscriptionId,
    required this.revision,
    required this.executionGeneration,
    required this.pending,
    required this.prompts,
  });

  static String _text(Object? value, String what) {
    if (value is! String || value.isEmpty || value != value.trim()) {
      throw FormatException('invalid $what');
    }
    return value;
  }

  static int _count(Object? value, String what) {
    if (value is! int || value < 0 || value > maxSafeJsonInteger) {
      throw FormatException('invalid $what');
    }
    return value;
  }

  static CanonicalSnapshot parse(Map<String, dynamic> json) {
    final sessionId = _text(json['session_id'], 'session_id');
    final stored = _text(json['stored_session_id'], 'stored_session_id');
    if (stored != sessionId) {
      throw const FormatException('canonical identity mismatch');
    }
    if (json['messages'] is! List) throw const FormatException('messages');
    if (json['running'] is! bool) throw const FormatException('running');
    final pending = json['pending'];
    final prompts = json['prompts'];
    if (pending is! List || prompts is! List) {
      throw const FormatException('pending/prompts');
    }
    final parsedPrompts = prompts.map(CanonicalPrompt.parse).toList();
    final seen = <String>{};
    for (final prompt in parsedPrompts) {
      if (!seen.add(prompt.promptId)) {
        throw const FormatException('duplicate prompt id');
      }
    }
    return CanonicalSnapshot(
      sessionId: sessionId,
      running: json['running'] as bool,
      authorityEpoch: _count(json['authority_epoch'], 'authority_epoch'),
      replayEpoch: _text(json['replay_epoch'], 'replay_epoch'),
      lastSequence: _count(json['last_sequence'], 'last_sequence'),
      subscriptionId: _text(json['subscription_id'], 'subscription_id'),
      revision: _count(json['revision'], 'revision'),
      executionGeneration: _count(
        json['execution_generation'],
        'execution_generation',
      ),
      pending: pending.map(CanonicalAdmission.parse).toList(),
      prompts: parsedPrompts,
    );
  }

  /// The input of the standalone snapshot parser: the canonical identity is
  /// both ids, and the prompts become the authoritative `pending_approval` /
  /// `pending_clarify` fields (explicit null when none is open, so a stale
  /// card is cleared by the snapshot instead of lingering).
  Map<String, dynamic> toBindingJson(Map<String, dynamic> raw) {
    CanonicalPrompt? first(String kind) {
      for (final prompt in prompts) {
        if (prompt.kind == kind) return prompt;
      }
      return null;
    }

    final approval = first('approval');
    final clarify = first('clarify');
    return <String, dynamic>{
      ...raw,
      'status': running ? 'running' : 'idle',
      'pending_approval': approval?.toLegacyRequestPayload(),
      'pending_clarify': clarify?.toLegacyRequestPayload(),
    };
  }
}

/// What the ledger decided about one live frame.
enum CanonicalFrameDisposition {
  /// Project it into the chat.
  dispatch,

  /// Not for the current turn / already applied: advance, project nothing.
  drop,

  /// Replay or hydration not finished: kept in order for later.
  hold,

  /// Contiguity, epoch or ownership cannot be proven: stop projecting,
  /// the owner must re-attach from a fresh snapshot.
  snapshotRequired,
}

enum CanonicalLedgerPhase { hydrating, ready, snapshotRequired }

/// Per (connection, session) synchronization state of the canonical wire:
/// replay watermark, epochs, execution generation, subscription ownership and
/// which admission the chat is currently following.
final class CanonicalSessionLedger {
  static const int maxHeldFrames = 256;
  static const int maxClosedAdmissions = 64;
  static const Set<String> _turnTerminalTypes = {'message.complete'};

  final String sessionId;
  final String profile;

  CanonicalLedgerPhase phase = CanonicalLedgerPhase.hydrating;
  int authorityEpoch = -1;
  String replayEpoch = '';
  String subscriptionId = '';
  int revision = 0;
  int watermark = 0;
  int maxGeneration = 0;
  bool running = false;
  String? snapshotRequiredReason;

  /// Automatic re-attaches since the last frame that was proven and
  /// projected; bounds a flapping authority.
  int autoReattaches = 0;
  static const int maxAutoReattaches = 3;

  /// The admission whose events the chat is following (set by an own
  /// non-queued submit or by adopting a `message.start`).
  String? trackedAdmission;
  int? trackedGeneration;

  /// Own admissions that are queued behind the tracked turn.
  final Set<String> queuedAdmissions = <String>{};
  final List<String> _closed = <String>[];
  final Map<String, CanonicalPrompt> prompts = <String, CanonicalPrompt>{};
  final List<SessionGatewayEvent> _held = <SessionGatewayEvent>[];

  CanonicalSessionLedger({required this.sessionId, required this.profile});

  bool get isReady => phase == CanonicalLedgerPhase.ready;

  /// A snapshot that still awaits its owner is not send-ready: the chat has
  /// not applied it, and a submit on it would follow frames nobody adopted.
  bool get isSendReady => isReady && !awaitingAdoption;

  /// Identifies the adoption the owner owes for the current deferred
  /// snapshot (0: none). A newer hydration or a failure invalidates it, so a
  /// stale owner can neither commit nor release the newer one.
  int adoptionToken = 0;
  int _adoptionSeq = 0;

  /// The snapshot was cut but its owner has not applied it yet: live frames
  /// that follow it are held, in order, and judged only once the owner
  /// confirms the adoption ([commitAdoption]), so a terminal or a question
  /// can never be consumed before the chat is able to apply it.
  bool awaitingAdoption = false;

  bool isClosed(String admissionId) => _closed.contains(admissionId);

  void _close(String admissionId) {
    if (_closed.contains(admissionId)) return;
    _closed.add(admissionId);
    if (_closed.length > maxClosedAdmissions) _closed.removeAt(0);
    queuedAdmissions.remove(admissionId);
    if (trackedAdmission == admissionId) {
      trackedAdmission = null;
      trackedGeneration = null;
    }
  }

  /// A `session.resume` is in flight: live frames are kept, in order.
  void beginHydration() {
    phase = CanonicalLedgerPhase.hydrating;
    snapshotRequiredReason = null;
    awaitingAdoption = false;
    adoptionToken = 0;
  }

  /// Adopts the snapshot as the proven cut and returns the frames that were
  /// held meanwhile, to be judged again against the new watermark.
  List<SessionGatewayEvent> completeHydration(
    CanonicalSnapshot snapshot, {
    bool deferDispatch = false,
  }) {
    final sameStream =
        snapshot.replayEpoch == replayEpoch &&
        snapshot.authorityEpoch == authorityEpoch;
    authorityEpoch = snapshot.authorityEpoch;
    replayEpoch = snapshot.replayEpoch;
    subscriptionId = snapshot.subscriptionId;
    revision = snapshot.revision;
    watermark = snapshot.lastSequence;
    running = snapshot.running;
    if (!sameStream) {
      maxGeneration = snapshot.executionGeneration;
    } else if (snapshot.executionGeneration > maxGeneration) {
      maxGeneration = snapshot.executionGeneration;
    }
    prompts
      ..clear()
      ..addEntries(snapshot.prompts.map((p) => MapEntry(p.promptId, p)));
    for (final p in snapshot.prompts) {
      if (p.executionGeneration > maxGeneration) {
        maxGeneration = p.executionGeneration;
      }
    }
    // The snapshot is the authority on what is still pending: an admission
    // that is no longer listed has started or finished.
    final listed = {for (final a in snapshot.pending) a.admissionId};
    queuedAdmissions.removeWhere((id) => !listed.contains(id));
    // The pending rows (queued, started, unknown) are read in the same cut
    // as `running`. A tracked turn that the authority no longer lists as
    // started is over, whether or not something else is running now (its
    // final transcript is reconciled from the durable rows by the owner).
    final startedListed = <String, CanonicalAdmission>{
      for (final a in snapshot.pending)
        if (a.status == 'started') a.admissionId: a,
    };
    final tracked = trackedAdmission;
    if (!snapshot.running ||
        (tracked != null && !startedListed.containsKey(tracked))) {
      trackedAdmission = null;
      trackedGeneration = null;
    }
    if (trackedAdmission == null && snapshot.running) {
      // Follow the chat's own queued follow-up that began meanwhile: its
      // frames carry its admission id, so it can be attributed exactly.
      final own = [
        for (final id in queuedAdmissions)
          if (startedListed.containsKey(id)) startedListed[id]!,
      ];
      if (own.length == 1) {
        trackedAdmission = own.single.admissionId;
        trackedGeneration = own.single.executionGeneration;
        queuedAdmissions.remove(own.single.admissionId);
      }
    }
    phase = CanonicalLedgerPhase.ready;
    snapshotRequiredReason = null;
    if (deferDispatch) {
      // Frames held during the resume stay held until the owner commits.
      awaitingAdoption = true;
      adoptionToken = ++_adoptionSeq;
      return const <SessionGatewayEvent>[];
    }
    awaitingAdoption = false;
    final held = List<SessionGatewayEvent>.of(_held);
    _held.clear();
    return held;
  }

  /// The owner applied the snapshot: returns the frames held since the cut,
  /// to be judged again in arrival order.
  List<SessionGatewayEvent> commitAdoption({int? token}) {
    if (!awaitingAdoption || (token != null && token != adoptionToken)) {
      return const <SessionGatewayEvent>[];
    }
    awaitingAdoption = false;
    adoptionToken = 0;
    final held = List<SessionGatewayEvent>.of(_held);
    _held.clear();
    return held;
  }

  /// The owner gave the snapshot up without adopting it (a recovery that
  /// settled from the durable transcript, a stale attach): the frames held
  /// for it are dropped and the ledger is fail-closed until the next
  /// explicit attach. Returns false for a stale [token].
  bool releaseAdoption(int token) {
    if (!awaitingAdoption || token != adoptionToken) return false;
    requireSnapshot('owner adoption released');
    return true;
  }

  void requireSnapshot(String reason) {
    awaitingAdoption = false;
    adoptionToken = 0;
    phase = CanonicalLedgerPhase.snapshotRequired;
    snapshotRequiredReason = reason;
    _held.clear();
  }

  /// The chat submitted: an acknowledgement is an admission receipt.
  void noteReceipt(CanonicalAdmissionReceipt receipt, {required bool queued}) {
    final generation = receipt.executionGeneration;
    if (generation != null && generation > maxGeneration) {
      maxGeneration = generation;
    }
    if (receipt.isTerminal) {
      _close(receipt.admissionId);
      return;
    }
    // A late acknowledgement of a turn whose terminal was already applied
    // must not make the chat follow a finished admission again.
    if (isClosed(receipt.admissionId)) return;
    if (queued) {
      queuedAdmissions.add(receipt.admissionId);
      return;
    }
    trackedAdmission = receipt.admissionId;
    trackedGeneration = generation;
  }

  /// Judges one live frame. [dispatch] frames may be projected; the caller
  /// translates prompt frames to the legacy shape.
  CanonicalFrameDisposition judge(SessionGatewayEvent event) {
    if (phase == CanonicalLedgerPhase.snapshotRequired) {
      return CanonicalFrameDisposition.drop;
    }
    if (phase == CanonicalLedgerPhase.hydrating ||
        (phase == CanonicalLedgerPhase.ready && awaitingAdoption)) {
      if (_held.length >= maxHeldFrames) {
        requireSnapshot('held frame budget exceeded');
        return CanonicalFrameDisposition.snapshotRequired;
      }
      _held.add(event);
      return CanonicalFrameDisposition.hold;
    }
    if (event.type == 'session.replay_gap') {
      requireSnapshot('server reported a replay gap');
      return CanonicalFrameDisposition.snapshotRequired;
    }
    final envelope = event.envelope;
    final sequence = event.sequence;
    if (envelope.malformed ||
        sequence == null ||
        envelope.replayEpoch == null) {
      requireSnapshot('unproven canonical frame');
      return CanonicalFrameDisposition.snapshotRequired;
    }
    if (envelope.replayEpoch != replayEpoch) {
      requireSnapshot('replay epoch changed');
      return CanonicalFrameDisposition.snapshotRequired;
    }
    final authority = envelope.authorityEpoch;
    if (authority != null && authority != authorityEpoch) {
      requireSnapshot('authority epoch changed');
      return CanonicalFrameDisposition.snapshotRequired;
    }
    if (sequence <= watermark) return CanonicalFrameDisposition.drop;
    if (sequence != watermark + 1) {
      requireSnapshot('sequence gap');
      return CanonicalFrameDisposition.snapshotRequired;
    }
    watermark = sequence;
    final disposition = _attribute(event, envelope);
    if (disposition == CanonicalFrameDisposition.dispatch) autoReattaches = 0;
    return disposition;
  }

  CanonicalFrameDisposition _attribute(
    SessionGatewayEvent event,
    CanonicalEventEnvelope envelope,
  ) {
    final generation = envelope.executionGeneration;
    final admission = envelope.admissionId;
    final type = event.type;
    final promptId = event.payload['prompt_id'];

    if (type == 'approval.settled' || type == 'clarify.settled') {
      return promptId is String && prompts.remove(promptId) != null
          ? CanonicalFrameDisposition.dispatch
          : CanonicalFrameDisposition.drop;
    }
    if (type == 'approval.request' || type == 'clarify.request') {
      final CanonicalPrompt prompt;
      try {
        prompt = CanonicalPrompt.parse({
          ...event.payload,
          'kind': type == 'approval.request' ? 'approval' : 'clarify',
        });
      } on FormatException {
        requireSnapshot('malformed prompt frame');
        return CanonicalFrameDisposition.snapshotRequired;
      }
      if (prompt.executionGeneration < maxGeneration ||
          prompts.containsKey(prompt.promptId)) {
        return CanonicalFrameDisposition.drop;
      }
      prompts[prompt.promptId] = prompt;
      maxGeneration = prompt.executionGeneration;
      return CanonicalFrameDisposition.dispatch;
    }

    // A frame stamped with an admission that is not the one the chat follows
    // belongs to another turn (an earlier one finishing late, another
    // surface's): it must never open, feed or close the followed turn.
    if (admission != null && trackedAdmission != null) {
      if (admission != trackedAdmission) {
        if (_turnTerminalTypes.contains(type)) _close(admission);
        return CanonicalFrameDisposition.drop;
      }
    }
    if (admission != null && isClosed(admission)) {
      return CanonicalFrameDisposition.drop;
    }
    if (generation != null) {
      if (generation > maxGeneration) maxGeneration = generation;
    }
    if (_turnTerminalTypes.contains(type)) {
      if (admission == null && trackedAdmission != null) {
        // A terminal that names no turn cannot be attributed while the chat
        // follows one: ask the authority instead of guessing.
        requireSnapshot('unattributed terminal');
        return CanonicalFrameDisposition.snapshotRequired;
      }
      if (admission != null) _close(admission);
      return CanonicalFrameDisposition.dispatch;
    }
    if (type == 'message.start' && admission != null) {
      if (trackedAdmission == null) {
        trackedAdmission = admission;
        trackedGeneration = generation;
      }
      queuedAdmissions.remove(admission);
    }
    if (type == 'session.info') {
      final rev = event.payload['revision'];
      if (rev is int && rev > revision) revision = rev;
      final run = event.payload['running'];
      if (run is bool) running = run;
    }
    return CanonicalFrameDisposition.dispatch;
  }

  /// Execution generation the next control (interrupt, prompt answer) is
  /// bound to: the highest proven one.
  int get currentGeneration => maxGeneration;
}

/// Canonical request builders, derived from the closed key sets of
/// `canonical_sessions.py`.
abstract final class CanonicalWire {
  static Map<String, dynamic> resume(
    String sessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) => {
    'session_id': sessionId,
    'source': 'desktop',
    if (profile.trim().isNotEmpty) 'profile': profile.trim(),
    if (omitMessages) 'omit_messages': true,
    if (deferHistory) 'defer_history': true,
  };

  /// `prompt.submit`: only keys of `CanonicalSubmitParams`. [extra] are the
  /// optional presentation keys the chat already computed; keys the contract
  /// does not name are dropped by the caller via [allowedSubmitKeys].
  static const Set<String> allowedSubmitKeys = {
    'surface',
    'voice_context',
    'interrupted',
    'voice_turn',
    'display_kind',
    'title_preview',
    'attachments',
    'finite',
    'unattended',
    'turn_author',
    'api_text',
    'model_override',
    'clarify_batch',
  };

  static Map<String, dynamic> submit({
    required String sessionId,
    required String text,
    required String submissionId,
    String profile = '',
    bool queued = false,
    Map<String, dynamic> extra = const {},
  }) => {
    'session_id': sessionId,
    'text': text,
    'submission_id': submissionId,
    if (profile.trim().isNotEmpty) 'profile': profile.trim(),
    if (queued) 'queued': true,
    for (final entry in extra.entries)
      if (allowedSubmitKeys.contains(entry.key)) entry.key: entry.value,
  };

  static Map<String, dynamic> approval({
    required String sessionId,
    required int generation,
    required String promptId,
    required String choice,
    String profile = '',
  }) => {
    'session_id': sessionId,
    'execution_generation': generation,
    'prompt_id': promptId,
    'choice': choice,
    if (profile.trim().isNotEmpty) 'profile': profile.trim(),
  };

  static Map<String, dynamic> clarify({
    required String sessionId,
    required int generation,
    required String promptId,
    required String answer,
    String profile = '',
  }) => {
    'session_id': sessionId,
    'execution_generation': generation,
    'prompt_id': promptId,
    'answer': answer,
    if (profile.trim().isNotEmpty) 'profile': profile.trim(),
  };

  static Map<String, dynamic> interrupt({
    required String sessionId,
    required int generation,
    String profile = '',
  }) => {
    'session_id': sessionId,
    'execution_generation': generation,
    if (profile.trim().isNotEmpty) 'profile': profile.trim(),
  };
}
