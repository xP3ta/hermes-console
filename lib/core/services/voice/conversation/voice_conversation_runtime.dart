import 'package:flutter/foundation.dart';

import '../voice_phase.dart';

/// Lifecycle authority for one manual voice-conversation session.
enum VoiceRuntimeLifecycle {
  inactive,
  running,
  userPaused,
  privacyPaused,
  exiting,
}

/// The single Android AudioRecord owner visible to the conversation runtime.
enum VoiceCaptureOwner {
  none,
  normalStarting,
  normal,
  fullDuplexStarting,
  fullDuplex,
}

enum VoiceTranscriptionOwner { none, normal, fullDuplex }

/// The single response-audio owner. `preparing` is not presented as audible.
enum VoicePlaybackOwner {
  none,
  preparing,
  streaming,
  fallback,
  paused,
  draining,
}

enum VoiceBackendState {
  idle,
  submitting,
  queued,
  running,
  interrupting,
  waitingInput,
}

enum _VoiceOperationKind { normalCapture, fullDuplexCapture, playback }

/// Frozen owner identity shared by every effect in one voice conversation.
///
/// Session ids may be unknown while Desktop is still binding a provisional
/// chat. [VoiceConversationRuntime.rebindIdentity] is the only supported way
/// to adopt the resolved ids without accepting callbacks from the old owner.
@immutable
final class VoiceConversationIdentity {
  const VoiceConversationIdentity({
    this.connectionId = '',
    this.ownerProfile = '',
    this.storedSessionId = '',
    this.runtimeSessionId = '',
  });

  static const unknown = VoiceConversationIdentity();

  final String connectionId;
  final String ownerProfile;
  final String storedSessionId;
  final String runtimeSessionId;

  @override
  bool operator ==(Object other) =>
      other is VoiceConversationIdentity &&
      other.connectionId == connectionId &&
      other.ownerProfile == ownerProfile &&
      other.storedSessionId == storedSessionId &&
      other.runtimeSessionId == runtimeSessionId;

  @override
  int get hashCode => Object.hash(
    connectionId,
    ownerProfile,
    storedSessionId,
    runtimeSessionId,
  );
}

@immutable
final class VoiceTurnBinding {
  const VoiceTurnBinding(
    this.conversationEpoch,
    this.operationEpoch,
    this.turn, {
    this.identity = VoiceConversationIdentity.unknown,
  });

  final int conversationEpoch;
  final int operationEpoch;
  final int turn;
  final VoiceConversationIdentity identity;

  @override
  bool operator ==(Object other) =>
      other is VoiceTurnBinding &&
      other.conversationEpoch == conversationEpoch &&
      other.operationEpoch == operationEpoch &&
      other.turn == turn &&
      other.identity == identity;

  @override
  int get hashCode =>
      Object.hash(conversationEpoch, operationEpoch, turn, identity);

  @override
  String toString() =>
      'VoiceTurnBinding($conversationEpoch:$operationEpoch:$turn)';
}

@immutable
final class VoiceRuntimeToken {
  const VoiceRuntimeToken._({
    required this.operationEpoch,
    required this.serial,
    required this.turn,
    required this._kind,
  });

  final int operationEpoch;
  final int serial;
  final VoiceTurnBinding turn;
  final _VoiceOperationKind _kind;

  @override
  bool operator ==(Object other) =>
      other is VoiceRuntimeToken &&
      other.operationEpoch == operationEpoch &&
      other.serial == serial &&
      other.turn == turn &&
      other._kind == _kind;

  @override
  int get hashCode => Object.hash(operationEpoch, serial, turn, _kind);
}

@immutable
final class VoiceManualInterruptionClaim {
  const VoiceManualInterruptionClaim({
    required this.captureToken,
    required this.playbackDrainToken,
    required this.binding,
    required this.shouldInterruptBackend,
    required this.cancelledPlayback,
  });

  final VoiceRuntimeToken captureToken;
  final VoiceRuntimeToken? playbackDrainToken;
  final VoiceTurnBinding binding;
  final bool shouldInterruptBackend;
  final bool cancelledPlayback;
}

@immutable
final class VoicePauseClaim {
  const VoicePauseClaim({
    required this.binding,
    required this.playbackDrainToken,
    required this.playbackPreserved,
  });

  final VoiceTurnBinding binding;
  final VoiceRuntimeToken? playbackDrainToken;
  final bool playbackPreserved;
}

@immutable
final class VoicePendingInputClaim {
  const VoicePendingInputClaim({
    required this.binding,
    required this.playbackDrainToken,
  });

  final VoiceTurnBinding binding;
  final VoiceRuntimeToken? playbackDrainToken;
}

@immutable
final class VoiceConversationSnapshot {
  const VoiceConversationSnapshot({
    required this.lifecycle,
    required this.captureOwner,
    required this.transcriptionOwner,
    required this.playbackOwner,
    required this.backendState,
    required this.currentTurn,
    required this.toolActive,
    required this.rearmRequested,
    required this.bargeSpeechActive,
  });

  factory VoiceConversationSnapshot.inactive() =>
      const VoiceConversationSnapshot(
        lifecycle: VoiceRuntimeLifecycle.inactive,
        captureOwner: VoiceCaptureOwner.none,
        transcriptionOwner: VoiceTranscriptionOwner.none,
        playbackOwner: VoicePlaybackOwner.none,
        backendState: VoiceBackendState.idle,
        currentTurn: null,
        toolActive: false,
        rearmRequested: false,
        bargeSpeechActive: false,
      );

  final VoiceRuntimeLifecycle lifecycle;
  final VoiceCaptureOwner captureOwner;
  final VoiceTranscriptionOwner transcriptionOwner;
  final VoicePlaybackOwner playbackOwner;
  final VoiceBackendState backendState;
  final VoiceTurnBinding? currentTurn;
  final bool toolActive;
  final bool rearmRequested;
  final bool bargeSpeechActive;

  bool get rearmReady =>
      lifecycle == VoiceRuntimeLifecycle.running &&
      rearmRequested &&
      captureOwner == VoiceCaptureOwner.none &&
      transcriptionOwner == VoiceTranscriptionOwner.none &&
      playbackOwner == VoicePlaybackOwner.none &&
      backendState == VoiceBackendState.idle &&
      !bargeSpeechActive;

  bool get hasSingleOwnerInvariant =>
      !(captureOwner != VoiceCaptureOwner.none &&
          transcriptionOwner != VoiceTranscriptionOwner.none);

  VoicePhase get phase {
    if (lifecycle != VoiceRuntimeLifecycle.running) return VoicePhase.idle;
    if (backendState == VoiceBackendState.waitingInput) {
      return VoicePhase.waitingPermission;
    }
    if (transcriptionOwner != VoiceTranscriptionOwner.none) {
      return VoicePhase.transcribing;
    }
    if (captureOwner == VoiceCaptureOwner.normal) {
      return VoicePhase.listening;
    }
    if (toolActive &&
        (backendState == VoiceBackendState.submitting ||
            backendState == VoiceBackendState.queued ||
            backendState == VoiceBackendState.running ||
            backendState == VoiceBackendState.interrupting)) {
      return VoicePhase.toolCall;
    }
    if (playbackOwner == VoicePlaybackOwner.streaming ||
        playbackOwner == VoicePlaybackOwner.fallback ||
        (bargeSpeechActive && playbackOwner == VoicePlaybackOwner.draining)) {
      return VoicePhase.speaking;
    }
    if (backendState == VoiceBackendState.submitting ||
        backendState == VoiceBackendState.queued ||
        backendState == VoiceBackendState.running ||
        backendState == VoiceBackendState.interrupting ||
        bargeSpeechActive) {
      return toolActive ? VoicePhase.toolCall : VoicePhase.thinking;
    }
    if (playbackOwner == VoicePlaybackOwner.draining) {
      return VoicePhase.speaking;
    }
    return VoicePhase.idle;
  }

  VoiceConversationSnapshot copyWith({
    VoiceRuntimeLifecycle? lifecycle,
    VoiceCaptureOwner? captureOwner,
    VoiceTranscriptionOwner? transcriptionOwner,
    VoicePlaybackOwner? playbackOwner,
    VoiceBackendState? backendState,
    Object? currentTurn = _unset,
    bool? toolActive,
    bool? rearmRequested,
    bool? bargeSpeechActive,
  }) => VoiceConversationSnapshot(
    lifecycle: lifecycle ?? this.lifecycle,
    captureOwner: captureOwner ?? this.captureOwner,
    transcriptionOwner: transcriptionOwner ?? this.transcriptionOwner,
    playbackOwner: playbackOwner ?? this.playbackOwner,
    backendState: backendState ?? this.backendState,
    currentTurn: identical(currentTurn, _unset)
        ? this.currentTurn
        : currentTurn as VoiceTurnBinding?,
    toolActive: toolActive ?? this.toolActive,
    rearmRequested: rearmRequested ?? this.rearmRequested,
    bargeSpeechActive: bargeSpeechActive ?? this.bargeSpeechActive,
  );

  static const Object _unset = Object();
}

/// Deterministic ownership/FSM authority for manual voice conversation.
///
/// It deliberately owns no plugin or network object. The controller performs
/// effects and must present their causal ACKs with the token returned here.
/// Stop, Pause, App Lock and Exit rotate the operation epoch before resources
/// are released, so a late callback cannot reopen capture or playback.
final class VoiceConversationRuntime {
  VoiceConversationSnapshot _state = VoiceConversationSnapshot.inactive();
  int _conversationEpoch = 0;
  int _operationEpoch = 0;
  int _turn = 0;
  int _serial = 0;
  VoiceConversationIdentity _identity = VoiceConversationIdentity.unknown;
  VoiceRuntimeToken? _captureToken;
  VoiceRuntimeToken? _transcriptionToken;
  VoiceRuntimeToken? _playbackToken;
  VoicePlaybackOwner? _pausedPlaybackOwner;

  VoiceConversationSnapshot get state => _state;

  VoiceTurnBinding start({
    bool backendRunning = false,
    VoiceConversationIdentity identity = VoiceConversationIdentity.unknown,
  }) {
    final current = _state.currentTurn;
    if (_state.lifecycle != VoiceRuntimeLifecycle.inactive && current != null) {
      return current;
    }
    _conversationEpoch++;
    _operationEpoch++;
    _turn = 0;
    _identity = identity;
    _clearTokens();
    final binding = _binding();
    _state = VoiceConversationSnapshot(
      lifecycle: VoiceRuntimeLifecycle.running,
      captureOwner: VoiceCaptureOwner.none,
      transcriptionOwner: VoiceTranscriptionOwner.none,
      playbackOwner: VoicePlaybackOwner.none,
      backendState: backendRunning
          ? VoiceBackendState.running
          : VoiceBackendState.idle,
      currentTurn: binding,
      toolActive: false,
      rearmRequested: !backendRunning,
      bargeSpeechActive: false,
    );
    return binding;
  }

  /// Adopts ids resolved by Desktop while preserving this conversation.
  ///
  /// Rebinding is deliberately rejected while any logical audio/STT owner is
  /// live. The controller must first obtain the physical teardown ACK; this
  /// method never hides an owner merely to make the identity update succeed.
  VoiceTurnBinding? rebindIdentity(
    VoiceTurnBinding current,
    VoiceConversationIdentity identity,
  ) {
    if (_state.lifecycle != VoiceRuntimeLifecycle.running ||
        !_ownsTurn(current) ||
        _state.captureOwner != VoiceCaptureOwner.none ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.none ||
        _state.playbackOwner != VoicePlaybackOwner.none ||
        _state.bargeSpeechActive) {
      return null;
    }
    if (_identity == identity) return current;

    _operationEpoch++;
    _identity = identity;
    _clearTokens();
    final rebound = _binding();
    _state = _state.copyWith(currentTurn: rebound);
    return rebound;
  }

  VoiceRuntimeToken? claimNormalCapture() {
    if (!_state.rearmReady) return null;
    final binding = _state.currentTurn;
    if (binding == null) return null;
    final token = _token(_VoiceOperationKind.normalCapture, binding);
    _captureToken = token;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.normalStarting,
      rearmRequested: false,
    );
    return token;
  }

  /// Reserves the one normal recorder used by an explicit Stop-and-talk.
  ///
  /// Unlike an automatic rearm this is a causal user action, so it may claim
  /// capture while the backend is busy. It deliberately preserves that run so
  /// the transcript can use the normal redirect/queue contract; hard backend
  /// interruption belongs to spoken barge-in or an explicit cancel. Existing
  /// monitor/playback tokens are fenced first, and cancelled output remains
  /// `draining` until the controller acknowledges its physical teardown with
  /// [finishPlaybackDrain].
  VoiceManualInterruptionClaim? requestManualInterruptionCapture(
    VoiceTurnBinding binding,
  ) {
    if (!_ownsTurn(binding) ||
        _state.lifecycle != VoiceRuntimeLifecycle.running ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.none ||
        _state.captureOwner == VoiceCaptureOwner.normalStarting ||
        _state.captureOwner == VoiceCaptureOwner.normal ||
        _state.backendState == VoiceBackendState.waitingInput) {
      return null;
    }

    final cancelledPlayback = _state.playbackOwner != VoicePlaybackOwner.none;

    _operationEpoch++;
    _clearTokens();
    final nextBinding = _binding();
    final captureToken = _token(_VoiceOperationKind.normalCapture, nextBinding);
    final playbackDrainToken = cancelledPlayback
        ? _token(_VoiceOperationKind.playback, nextBinding)
        : null;
    _captureToken = captureToken;
    _playbackToken = playbackDrainToken;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.normalStarting,
      transcriptionOwner: VoiceTranscriptionOwner.none,
      playbackOwner: cancelledPlayback
          ? VoicePlaybackOwner.draining
          : VoicePlaybackOwner.none,
      backendState: _state.backendState,
      currentTurn: nextBinding,
      toolActive: _state.toolActive,
      rearmRequested: false,
      bargeSpeechActive: false,
    );
    return VoiceManualInterruptionClaim(
      captureToken: captureToken,
      playbackDrainToken: playbackDrainToken,
      binding: nextBinding,
      shouldInterruptBackend: false,
      cancelledPlayback: cancelledPlayback,
    );
  }

  bool confirmNormalCapture(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.normalCapture) ||
        _state.captureOwner != VoiceCaptureOwner.normalStarting ||
        _state.lifecycle != VoiceRuntimeLifecycle.running) {
      return false;
    }
    _state = _state.copyWith(captureOwner: VoiceCaptureOwner.normal);
    return true;
  }

  bool failNormalCapture(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.normalCapture) ||
        (_state.captureOwner != VoiceCaptureOwner.normalStarting &&
            _state.captureOwner != VoiceCaptureOwner.normal)) {
      return false;
    }
    _captureToken = null;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.none,
      rearmRequested: false,
    );
    return true;
  }

  bool finishNormalSilence(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.normalCapture) ||
        _state.captureOwner != VoiceCaptureOwner.normal) {
      return false;
    }
    _captureToken = null;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.none,
      rearmRequested: true,
    );
    return true;
  }

  bool beginNormalTranscription(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.normalCapture) ||
        _state.captureOwner != VoiceCaptureOwner.normal) {
      return false;
    }
    _captureToken = null;
    _transcriptionToken = token;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.none,
      transcriptionOwner: VoiceTranscriptionOwner.normal,
      rearmRequested: false,
    );
    return true;
  }

  VoiceTurnBinding? finishNormalTranscription(
    VoiceRuntimeToken token,
    String transcript,
  ) {
    if (!_ownsTranscription(token, _VoiceOperationKind.normalCapture) ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.normal) {
      return null;
    }
    _transcriptionToken = null;
    if (transcript.trim().isEmpty) {
      _state = _state.copyWith(
        transcriptionOwner: VoiceTranscriptionOwner.none,
        rearmRequested: true,
      );
      return null;
    }
    return _beginSubmittedTurn();
  }

  /// Puts a message that did not reach Hermes back into submission, as a new
  /// turn. Only while nothing else owns the conversation (a failed submit
  /// leaves it idle), so a retry can never overlap a capture or a playback.
  VoiceTurnBinding? beginResubmission() {
    if (_state.lifecycle != VoiceRuntimeLifecycle.running ||
        _state.backendState != VoiceBackendState.idle ||
        _state.captureOwner != VoiceCaptureOwner.none ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.none ||
        _state.playbackOwner != VoicePlaybackOwner.none ||
        _state.bargeSpeechActive) {
      return null;
    }
    return _beginSubmittedTurn();
  }

  bool failTranscription(VoiceRuntimeToken token, {bool rearm = true}) {
    if (!_ownsTranscription(token, token._kind) ||
        _state.transcriptionOwner == VoiceTranscriptionOwner.none) {
      return false;
    }
    _transcriptionToken = null;
    _state = _state.copyWith(
      transcriptionOwner: VoiceTranscriptionOwner.none,
      rearmRequested:
          rearm &&
          _state.lifecycle == VoiceRuntimeLifecycle.running &&
          _state.backendState == VoiceBackendState.idle &&
          _state.playbackOwner == VoicePlaybackOwner.none,
    );
    return true;
  }

  bool markBackendRunning(VoiceTurnBinding binding) {
    if (!_ownsTurn(binding) ||
        (_state.backendState != VoiceBackendState.submitting &&
            _state.backendState != VoiceBackendState.queued &&
            _state.backendState != VoiceBackendState.running)) {
      return false;
    }
    _state = _state.copyWith(
      backendState: VoiceBackendState.running,
      rearmRequested: false,
    );
    return true;
  }

  bool markSubmissionQueued(VoiceTurnBinding binding) {
    if (!_ownsTurn(binding) ||
        _state.backendState != VoiceBackendState.submitting) {
      return false;
    }
    _state = _state.copyWith(
      backendState: VoiceBackendState.queued,
      rearmRequested: false,
    );
    return true;
  }

  bool failSubmission(VoiceTurnBinding binding, {bool rearm = true}) {
    if (!_ownsTurn(binding) ||
        (_state.backendState != VoiceBackendState.submitting &&
            _state.backendState != VoiceBackendState.queued)) {
      return false;
    }
    _state = _state.copyWith(
      backendState: VoiceBackendState.idle,
      toolActive: false,
      // Owners gate [VoiceConversationSnapshot.rearmReady]. Keep the user's
      // intent while a full-duplex monitor or playback drain is still closing
      // instead of losing it at the failure boundary.
      rearmRequested:
          rearm && _state.lifecycle == VoiceRuntimeLifecycle.running,
    );
    return true;
  }

  bool markBackendInterrupting(VoiceTurnBinding binding) {
    if (!_ownsTurn(binding) ||
        (_state.backendState != VoiceBackendState.submitting &&
            _state.backendState != VoiceBackendState.queued &&
            _state.backendState != VoiceBackendState.running)) {
      return false;
    }
    _state = _state.copyWith(
      backendState: VoiceBackendState.interrupting,
      toolActive: false,
      rearmRequested: false,
    );
    return true;
  }

  bool settleBackendInterrupt(
    VoiceTurnBinding binding, {
    required bool backendRunning,
  }) {
    if (!_ownsTurn(binding) ||
        _state.backendState != VoiceBackendState.interrupting) {
      return false;
    }
    _state = _state.copyWith(
      backendState: backendRunning
          ? VoiceBackendState.running
          : VoiceBackendState.idle,
      rearmRequested:
          !backendRunning &&
          _state.captureOwner == VoiceCaptureOwner.none &&
          _state.transcriptionOwner == VoiceTranscriptionOwner.none &&
          _state.playbackOwner == VoicePlaybackOwner.none &&
          !_state.bargeSpeechActive,
    );
    return true;
  }

  bool failBackendInterrupt(VoiceTurnBinding binding) =>
      settleBackendInterrupt(binding, backendRunning: true);

  bool markBackendTerminal(VoiceTurnBinding binding) {
    if (!_ownsTurn(binding) ||
        _state.backendState == VoiceBackendState.idle ||
        _state.backendState == VoiceBackendState.waitingInput) {
      return false;
    }
    _state = _state.copyWith(
      backendState: VoiceBackendState.idle,
      toolActive: false,
      rearmRequested: true,
    );
    return true;
  }

  bool markToolActive(VoiceTurnBinding binding, {required bool active}) {
    if (!_ownsTurn(binding) ||
        (_state.backendState != VoiceBackendState.submitting &&
            _state.backendState != VoiceBackendState.queued &&
            _state.backendState != VoiceBackendState.running)) {
      return false;
    }
    _state = _state.copyWith(toolActive: active);
    return true;
  }

  VoiceRuntimeToken? preparePlayback(VoiceTurnBinding binding) {
    if (!_ownsTurn(binding) ||
        _state.lifecycle != VoiceRuntimeLifecycle.running ||
        _state.captureOwner == VoiceCaptureOwner.normalStarting ||
        _state.captureOwner == VoiceCaptureOwner.normal ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.none ||
        _state.playbackOwner != VoicePlaybackOwner.none ||
        _state.backendState == VoiceBackendState.waitingInput ||
        _state.bargeSpeechActive) {
      return null;
    }
    final token = _token(_VoiceOperationKind.playback, binding);
    _playbackToken = token;
    _state = _state.copyWith(
      playbackOwner: VoicePlaybackOwner.preparing,
      rearmRequested: false,
    );
    return token;
  }

  bool confirmPlayback(
    VoiceRuntimeToken token, {
    VoicePlaybackOwner owner = VoicePlaybackOwner.streaming,
  }) {
    if (!_ownsPlayback(token) ||
        _state.playbackOwner != VoicePlaybackOwner.preparing ||
        (owner != VoicePlaybackOwner.streaming &&
            owner != VoicePlaybackOwner.fallback)) {
      return false;
    }
    _state = _state.copyWith(playbackOwner: owner);
    return true;
  }

  bool failPlaybackPreparation(VoiceRuntimeToken token, {bool rearm = true}) {
    if (!_ownsPlayback(token) ||
        _state.playbackOwner != VoicePlaybackOwner.preparing) {
      return false;
    }
    _playbackToken = null;
    _state = _state.copyWith(
      playbackOwner: VoicePlaybackOwner.none,
      rearmRequested:
          rearm &&
          _state.lifecycle == VoiceRuntimeLifecycle.running &&
          _state.backendState == VoiceBackendState.idle &&
          _state.captureOwner == VoiceCaptureOwner.none &&
          _state.transcriptionOwner == VoiceTranscriptionOwner.none &&
          !_state.bargeSpeechActive,
    );
    return true;
  }

  bool beginPlaybackDrain(VoiceRuntimeToken token) {
    if (!_ownsPlayback(token) ||
        (_state.playbackOwner != VoicePlaybackOwner.streaming &&
            _state.playbackOwner != VoicePlaybackOwner.fallback)) {
      return false;
    }
    _state = _state.copyWith(
      playbackOwner: VoicePlaybackOwner.draining,
      rearmRequested: false,
    );
    return true;
  }

  bool abortPlayback(VoiceRuntimeToken token) {
    if (!_ownsPlayback(token) ||
        (_state.playbackOwner != VoicePlaybackOwner.preparing &&
            _state.playbackOwner != VoicePlaybackOwner.streaming &&
            _state.playbackOwner != VoicePlaybackOwner.fallback)) {
      return false;
    }
    _state = _state.copyWith(
      playbackOwner: VoicePlaybackOwner.draining,
      rearmRequested: false,
    );
    return true;
  }

  bool finishPlaybackDrain(VoiceRuntimeToken token) {
    if (!_ownsPlayback(token) ||
        _state.playbackOwner != VoicePlaybackOwner.draining) {
      return false;
    }
    _playbackToken = null;
    _state = _state.copyWith(
      playbackOwner: VoicePlaybackOwner.none,
      rearmRequested:
          _state.rearmRequested ||
          _state.backendState == VoiceBackendState.idle,
    );
    return true;
  }

  VoiceRuntimeToken? requestBargeMonitor(VoiceTurnBinding binding) {
    if (!_ownsTurn(binding) ||
        _state.lifecycle != VoiceRuntimeLifecycle.running ||
        _state.captureOwner != VoiceCaptureOwner.none ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.none ||
        _state.backendState == VoiceBackendState.waitingInput ||
        !(_state.backendState == VoiceBackendState.submitting ||
            _state.backendState == VoiceBackendState.queued ||
            _state.backendState == VoiceBackendState.running ||
            _state.playbackOwner != VoicePlaybackOwner.none)) {
      return null;
    }
    final token = _token(_VoiceOperationKind.fullDuplexCapture, binding);
    _captureToken = token;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.fullDuplexStarting,
      rearmRequested: false,
    );
    return token;
  }

  bool confirmBargeMonitor(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.fullDuplexCapture) ||
        _state.captureOwner != VoiceCaptureOwner.fullDuplexStarting ||
        !_ownsTurn(token.turn)) {
      return false;
    }
    _state = _state.copyWith(captureOwner: VoiceCaptureOwner.fullDuplex);
    return true;
  }

  bool releaseBargeMonitor(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.fullDuplexCapture)) {
      return false;
    }
    _captureToken = null;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.none,
      rearmRequested:
          _state.rearmRequested ||
          _state.backendState == VoiceBackendState.idle,
    );
    return true;
  }

  bool beginBargeSpeech(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.fullDuplexCapture) ||
        _state.captureOwner != VoiceCaptureOwner.fullDuplex ||
        !_ownsTurn(token.turn) ||
        _state.bargeSpeechActive) {
      return false;
    }
    final shouldInterruptBackend =
        _state.backendState == VoiceBackendState.submitting ||
        _state.backendState == VoiceBackendState.queued ||
        _state.backendState == VoiceBackendState.running;
    _state = _state.copyWith(
      playbackOwner: _state.playbackOwner == VoicePlaybackOwner.none
          ? VoicePlaybackOwner.none
          : VoicePlaybackOwner.draining,
      backendState: shouldInterruptBackend
          ? VoiceBackendState.interrupting
          : _state.backendState,
      toolActive: shouldInterruptBackend ? false : _state.toolActive,
      rearmRequested: false,
      bargeSpeechActive: true,
    );
    return true;
  }

  bool beginBargeTranscription(VoiceRuntimeToken token) {
    if (!_ownsCapture(token, _VoiceOperationKind.fullDuplexCapture) ||
        _state.captureOwner != VoiceCaptureOwner.fullDuplex ||
        !_state.bargeSpeechActive) {
      return false;
    }
    _captureToken = null;
    _transcriptionToken = token;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.none,
      transcriptionOwner: VoiceTranscriptionOwner.fullDuplex,
      bargeSpeechActive: false,
    );
    return true;
  }

  VoiceTurnBinding? finishBargeTranscription(
    VoiceRuntimeToken token,
    String transcript,
  ) {
    if (!_ownsTranscription(token, _VoiceOperationKind.fullDuplexCapture) ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.fullDuplex) {
      return null;
    }
    _transcriptionToken = null;
    if (transcript.trim().isEmpty) {
      _state = _state.copyWith(
        transcriptionOwner: VoiceTranscriptionOwner.none,
        rearmRequested: _state.backendState == VoiceBackendState.idle,
      );
      return null;
    }
    return _beginSubmittedTurn();
  }

  VoicePendingInputClaim? waitForInput(VoiceTurnBinding binding) {
    if (!_ownsTurn(binding) ||
        (_state.backendState != VoiceBackendState.submitting &&
            _state.backendState != VoiceBackendState.queued &&
            _state.backendState != VoiceBackendState.running)) {
      return null;
    }
    final hadPlayback =
        _state.playbackOwner != VoicePlaybackOwner.none &&
        _playbackToken != null;
    _operationEpoch++;
    _clearTokens();
    final nextBinding = _binding();
    final playbackDrainToken = hadPlayback
        ? _token(_VoiceOperationKind.playback, nextBinding)
        : null;
    _playbackToken = playbackDrainToken;
    _state = _state.copyWith(
      captureOwner: VoiceCaptureOwner.none,
      transcriptionOwner: VoiceTranscriptionOwner.none,
      playbackOwner: hadPlayback
          ? VoicePlaybackOwner.draining
          : VoicePlaybackOwner.none,
      backendState: VoiceBackendState.waitingInput,
      currentTurn: nextBinding,
      toolActive: false,
      rearmRequested: false,
      bargeSpeechActive: false,
    );
    return VoicePendingInputClaim(
      binding: nextBinding,
      playbackDrainToken: playbackDrainToken,
    );
  }

  bool resolveInput(VoiceTurnBinding binding, {required bool backendRunning}) {
    if (!_ownsTurn(binding) ||
        _state.backendState != VoiceBackendState.waitingInput) {
      return false;
    }
    _state = _state.copyWith(
      backendState: backendRunning
          ? VoiceBackendState.running
          : VoiceBackendState.idle,
      rearmRequested: !backendRunning,
    );
    return true;
  }

  bool requestRearmAfterFailure() {
    if (_state.lifecycle != VoiceRuntimeLifecycle.running ||
        _state.backendState != VoiceBackendState.idle ||
        _state.captureOwner != VoiceCaptureOwner.none ||
        _state.transcriptionOwner != VoiceTranscriptionOwner.none ||
        _state.playbackOwner != VoicePlaybackOwner.none ||
        _state.bargeSpeechActive) {
      return false;
    }
    if (_state.rearmRequested) return false;
    _state = _state.copyWith(rearmRequested: true);
    return true;
  }

  VoicePauseClaim? pauseByUser({bool preservePlayback = false}) {
    if (_state.lifecycle != VoiceRuntimeLifecycle.running) return null;
    final binding = _state.currentTurn;
    if (binding == null) return null;
    _captureToken = null;
    _transcriptionToken = null;
    final canPreservePlayback =
        preservePlayback &&
        _playbackToken != null &&
        (_state.playbackOwner == VoicePlaybackOwner.preparing ||
            _state.playbackOwner == VoicePlaybackOwner.streaming ||
            _state.playbackOwner == VoicePlaybackOwner.fallback);
    final playbackDrainToken =
        !canPreservePlayback && _state.playbackOwner != VoicePlaybackOwner.none
        ? _playbackToken
        : null;
    _pausedPlaybackOwner = canPreservePlayback ? _state.playbackOwner : null;
    if (!canPreservePlayback && playbackDrainToken == null) {
      _playbackToken = null;
    }
    _state = _state.copyWith(
      lifecycle: VoiceRuntimeLifecycle.userPaused,
      captureOwner: VoiceCaptureOwner.none,
      transcriptionOwner: VoiceTranscriptionOwner.none,
      playbackOwner: canPreservePlayback
          ? VoicePlaybackOwner.paused
          : playbackDrainToken != null
          ? VoicePlaybackOwner.draining
          : VoicePlaybackOwner.none,
      rearmRequested: false,
      bargeSpeechActive: false,
    );
    return VoicePauseClaim(
      binding: binding,
      playbackDrainToken: playbackDrainToken,
      playbackPreserved: canPreservePlayback,
    );
  }

  VoiceTurnBinding? resumeByUser({bool resumePlayback = false}) {
    if (_state.lifecycle != VoiceRuntimeLifecycle.userPaused ||
        _state.playbackOwner == VoicePlaybackOwner.draining) {
      return null;
    }
    if (_state.playbackOwner == VoicePlaybackOwner.paused && !resumePlayback) {
      return null;
    }
    final restoredPlayback =
        resumePlayback &&
            _state.playbackOwner == VoicePlaybackOwner.paused &&
            _playbackToken != null
        ? _pausedPlaybackOwner
        : VoicePlaybackOwner.none;
    if (resumePlayback && restoredPlayback == null) return null;
    if (restoredPlayback == VoicePlaybackOwner.none) _playbackToken = null;
    _pausedPlaybackOwner = null;
    _state = _state.copyWith(
      lifecycle: VoiceRuntimeLifecycle.running,
      playbackOwner: restoredPlayback ?? VoicePlaybackOwner.none,
      rearmRequested:
          (restoredPlayback == null ||
              restoredPlayback == VoicePlaybackOwner.none) &&
          _state.backendState == VoiceBackendState.idle,
    );
    return _state.currentTurn;
  }

  VoiceTurnBinding? hardPauseForPrivacy() {
    if (_state.lifecycle == VoiceRuntimeLifecycle.inactive) return null;
    if (_state.lifecycle == VoiceRuntimeLifecycle.exiting ||
        _state.lifecycle == VoiceRuntimeLifecycle.privacyPaused) {
      return _state.currentTurn;
    }
    _conversationEpoch++;
    _operationEpoch++;
    _clearTokens();
    final nextBinding = _binding();
    _state = _state.copyWith(
      lifecycle: VoiceRuntimeLifecycle.privacyPaused,
      captureOwner: VoiceCaptureOwner.none,
      transcriptionOwner: VoiceTranscriptionOwner.none,
      playbackOwner: VoicePlaybackOwner.none,
      currentTurn: nextBinding,
      rearmRequested: false,
      bargeSpeechActive: false,
    );
    return nextBinding;
  }

  /// Unlock only removes the privacy fence. Explicit Play is still required.
  VoiceTurnBinding? releasePrivacyFence() {
    if (_state.lifecycle != VoiceRuntimeLifecycle.privacyPaused) return null;
    _state = _state.copyWith(
      lifecycle: VoiceRuntimeLifecycle.userPaused,
      rearmRequested: false,
    );
    return _state.currentTurn;
  }

  VoiceTurnBinding? beginExit() {
    if (_state.lifecycle == VoiceRuntimeLifecycle.inactive) return null;
    if (_state.lifecycle == VoiceRuntimeLifecycle.exiting) {
      return _state.currentTurn;
    }
    _conversationEpoch++;
    _operationEpoch++;
    _clearTokens();
    final fence = _binding();
    _state = _state.copyWith(
      lifecycle: VoiceRuntimeLifecycle.exiting,
      backendState: VoiceBackendState.idle,
      currentTurn: fence,
      toolActive: false,
      rearmRequested: false,
      bargeSpeechActive: false,
    );
    return fence;
  }

  bool finishExit(VoiceTurnBinding fence) {
    if (_state.lifecycle != VoiceRuntimeLifecycle.exiting ||
        _state.currentTurn != fence) {
      return false;
    }
    _turn = 0;
    _state = VoiceConversationSnapshot.inactive();
    return true;
  }

  void exit() {
    final fence = beginExit();
    if (fence != null) finishExit(fence);
  }

  VoiceTurnBinding _beginSubmittedTurn() {
    _turn++;
    final binding = _binding();
    _state = _state.copyWith(
      transcriptionOwner: VoiceTranscriptionOwner.none,
      backendState: VoiceBackendState.submitting,
      currentTurn: binding,
      toolActive: false,
      rearmRequested: false,
      bargeSpeechActive: false,
    );
    return binding;
  }

  VoiceTurnBinding _binding() => VoiceTurnBinding(
    _conversationEpoch,
    _operationEpoch,
    _turn,
    identity: _identity,
  );

  VoiceRuntimeToken _token(
    _VoiceOperationKind kind,
    VoiceTurnBinding binding,
  ) => VoiceRuntimeToken._(
    operationEpoch: _operationEpoch,
    serial: ++_serial,
    turn: binding,
    kind: kind,
  );

  bool _ownsTurn(VoiceTurnBinding binding) =>
      _state.lifecycle != VoiceRuntimeLifecycle.inactive &&
      binding == _state.currentTurn;

  bool _ownsCapture(VoiceRuntimeToken token, _VoiceOperationKind kind) =>
      token.operationEpoch == _operationEpoch &&
      token._kind == kind &&
      token == _captureToken;

  bool _ownsTranscription(VoiceRuntimeToken token, _VoiceOperationKind kind) =>
      token.operationEpoch == _operationEpoch &&
      token._kind == kind &&
      token == _transcriptionToken;

  bool _ownsPlayback(VoiceRuntimeToken token) =>
      token.operationEpoch == _operationEpoch &&
      token._kind == _VoiceOperationKind.playback &&
      token == _playbackToken;

  void _clearTokens() {
    _captureToken = null;
    _transcriptionToken = null;
    _playbackToken = null;
    _pausedPlaybackOwner = null;
  }
}
