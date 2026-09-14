import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';

/// Exhaustive audit of ActiveChat's public/user-triggered mutation surface.
/// `none` means ActiveChat exposes no mutation in that category.
const runtimeMutationReleaseAudit =
    <
      ({
        String mutation,
        String admissionGuard,
        String inFlightAuthority,
        String releaseBlocker,
      })
    >[
      (
        mutation: 'prompt submit/send',
        admissionGuard: 'ownership/release fence + queue admission token',
        inFlightAuthority: 'pipeline + ActiveTurnDelivery',
        releaseBlocker: 'submit/delivery/streaming',
      ),
      (
        mutation: 'queue enqueue/save/restore/cancel/drain',
        admissionGuard: 'ownership/release fence + queue freeze',
        inFlightAuthority: 'queues, owners, pending ids/cancels, drain flags',
        releaseBlocker: 'queue/drain',
      ),
      (
        mutation: 'config.set model/reasoning/fast and revert-to-normal',
        admissionGuard: 'ownership/release fence',
        inFlightAuthority: 'request counter + PendingSessionConfigChange',
        releaseBlocker: 'mutation until terminal reducer state',
      ),
      (
        mutation: 'config.set expensive-model confirmation',
        admissionGuard: 'current confirmRequired request + release fence',
        inFlightAuthority: 'request counter + reducer request epoch',
        releaseBlocker: 'mutation until confirmed/rejected/superseded',
      ),
      (
        mutation: 'session.compress and presentation adapter',
        admissionGuard: 'ownership/release fence + authority token',
        inFlightAuthority: 'mutation counter + RPC/fence/pending state',
        releaseBlocker: 'mutation/compression/reconciliation',
      ),
      (
        mutation: 'approval.resolve including automatic policy answer',
        admissionGuard: 'ownership/release fence + request identity',
        inFlightAuthority: 'pendingApproval + approval generation',
        releaseBlocker: 'approval',
      ),
      (
        mutation: 'clarify/sudo/secret/terminal-read answer',
        admissionGuard: 'ownership/release fence + prompt identity',
        inFlightAuthority: 'nonterminal prompt status + batch lock',
        releaseBlocker: 'interactivePrompt',
      ),
      (
        mutation: 'session.interrupt/stop and voice barge interrupt',
        admissionGuard: 'ownership/release fence + stop coordinator',
        inFlightAuthority: 'cancel flight/stop state/interrupt drain',
        releaseBlocker: 'stop/streaming',
      ),
      (
        mutation: 'session.rewind/rewrite',
        admissionGuard: 'ownership/release fence + rewrite reservation',
        inFlightAuthority: '_activeRewrite + delivery/pipeline',
        releaseBlocker: 'mutation/submit/delivery/stop',
      ),
      (
        mutation: 'session.redirect/legacy steer',
        admissionGuard: 'ownership/release fence + active turn',
        inFlightAuthority: 'streaming turn + accepted queue state',
        releaseBlocker: 'streaming/queue/reconciliation',
      ),
      (
        mutation: 'subagent steer',
        admissionGuard: 'ownership/release fence + control authority',
        inFlightAuthority: 'mutation counter + activity identity',
        releaseBlocker: 'mutation/toolOrSubagent',
      ),
      (
        mutation: 'subagent interrupt',
        admissionGuard: 'ownership/release fence + control authority',
        inFlightAuthority: 'pendingSubagentInterrupts',
        releaseBlocker: 'toolOrSubagent',
      ),
      (
        mutation: 'active attachment upload/attach',
        admissionGuard: 'submit admission + attachment attempt fence',
        inFlightAuthority: 'ActiveTurnDelivery and prepared owner',
        releaseBlocker: 'delivery/queue/submit',
      ),
      (
        mutation: 'active attachment remove/detach',
        admissionGuard: 'ownership/release fence',
        inFlightAuthority: 'mutation counter + delivery mutation tail',
        releaseBlocker: 'mutation/delivery',
      ),
      (
        mutation: 'slash.exec/command.dispatch',
        admissionGuard: 'ownership/release fence + dedicated adapters',
        inFlightAuthority: 'mutation counter',
        releaseBlocker: 'mutation',
      ),
      (
        mutation: 'runtime attach/activate/resume/recheck',
        admissionGuard: 'release fence + compression authority/ownership state',
        inFlightAuthority:
            'bind/session epochs + reconcile reservations/flight',
        releaseBlocker: 'reconciliation/ownership/origin',
      ),
      (
        mutation: 'legacy applyReasoningEffort run creation',
        admissionGuard: 'ownership/release fence',
        inFlightAuthority: 'mutation counter through startRun settlement',
        releaseBlocker: 'mutation',
      ),
      (
        mutation: 'artifact mutations',
        admissionGuard: 'none exposed by ActiveChat',
        inFlightAuthority: 'artifact index is projection-only',
        releaseBlocker: 'not applicable',
      ),
      (
        mutation: 'session.close release',
        admissionGuard: 'all release blockers clear',
        inFlightAuthority: 'runtimeReleaseInFlight central fence',
        releaseBlocker: 'blocks every new mutation admission',
      ),
    ];

void main() {
  test('audit matrix covers every admitted mutation family exactly once', () {
    final names = runtimeMutationReleaseAudit
        .map((row) => row.mutation)
        .toSet();
    expect(names, hasLength(runtimeMutationReleaseAudit.length));
    for (final required in const [
      'prompt submit/send',
      'queue enqueue/save/restore/cancel/drain',
      'config.set model/reasoning/fast and revert-to-normal',
      'session.compress and presentation adapter',
      'approval.resolve including automatic policy answer',
      'clarify/sudo/secret/terminal-read answer',
      'session.interrupt/stop and voice barge interrupt',
      'session.rewind/rewrite',
      'session.redirect/legacy steer',
      'subagent steer',
      'subagent interrupt',
      'active attachment upload/attach',
      'active attachment remove/detach',
      'slash.exec/command.dispatch',
      'runtime attach/activate/resume/recheck',
      'legacy applyReasoningEffort run creation',
      'artifact mutations',
      'session.close release',
    ]) {
      expect(names, contains(required), reason: required);
    }
    for (final row in runtimeMutationReleaseAudit) {
      expect(row.admissionGuard, isNotEmpty, reason: row.mutation);
      expect(row.inFlightAuthority, isNotEmpty, reason: row.mutation);
      expect(row.releaseBlocker, isNotEmpty, reason: row.mutation);
    }
  });

  RuntimeReleaseSafetyState safe() => const RuntimeReleaseSafetyState(
    exactUniqueRuntimeAndDurable: true,
    current: true,
    idle: true,
    noStreaming: true,
    noSubmit: true,
    noDelivery: true,
    noQueue: true,
    noDrain: true,
    noApproval: true,
    noInteractivePrompt: true,
    noToolOrSubagent: true,
    noCompression: true,
    noReconciliation: true,
    noStop: true,
    noMutation: true,
    epochsCurrent: true,
  );

  test('release exacto acepta únicamente todas las pruebas simultáneas', () {
    expect(runtimeReleaseBlockers(safe()), isEmpty);

    final cases = <RuntimeReleaseSafetyState, RuntimeReleaseBlocker>{
      safe().copyWith(exactUniqueRuntimeAndDurable: false):
          RuntimeReleaseBlocker.exactIdentity,
      safe().copyWith(current: false): RuntimeReleaseBlocker.notCurrent,
      safe().copyWith(idle: false): RuntimeReleaseBlocker.notIdle,
      safe().copyWith(noStreaming: false): RuntimeReleaseBlocker.streaming,
      safe().copyWith(noSubmit: false): RuntimeReleaseBlocker.submit,
      safe().copyWith(noDelivery: false): RuntimeReleaseBlocker.delivery,
      safe().copyWith(noQueue: false): RuntimeReleaseBlocker.queue,
      safe().copyWith(noDrain: false): RuntimeReleaseBlocker.drain,
      safe().copyWith(noApproval: false): RuntimeReleaseBlocker.approval,
      safe().copyWith(noInteractivePrompt: false):
          RuntimeReleaseBlocker.interactivePrompt,
      safe().copyWith(noToolOrSubagent: false):
          RuntimeReleaseBlocker.toolOrSubagent,
      safe().copyWith(noCompression: false): RuntimeReleaseBlocker.compression,
      safe().copyWith(noReconciliation: false):
          RuntimeReleaseBlocker.reconciliation,
      safe().copyWith(noStop: false): RuntimeReleaseBlocker.stop,
      safe().copyWith(noMutation: false): RuntimeReleaseBlocker.mutation,
      safe().copyWith(epochsCurrent: false): RuntimeReleaseBlocker.staleEpoch,
    };

    for (final entry in cases.entries) {
      expect(
        runtimeReleaseBlockers(entry.key),
        contains(entry.value),
        reason: entry.value.name,
      );
    }
  });
}
