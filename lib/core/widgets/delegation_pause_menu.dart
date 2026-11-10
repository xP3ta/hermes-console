// «Pausar subagentes nuevos» menu shared by the subagent list and detail.
// One `delegation.status` read per open; the item states its scope (the
// whole server; running subagents continue).
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../feedback/feedback_policy.dart';
import '../services/delegation_control.dart';
import '../services/tui_gateway_client.dart' show TuiGatewayRpcError;

enum DelegationPauseOutcome { changed, dismissed, unsupported, failed }

Future<DelegationPauseOutcome> showDelegationPauseMenu({
  required BuildContext context,
  required GlobalKey anchorKey,
  required HermesDelegationGateway control,
  Key actionKey = const ValueKey('subagent-detail-pause'),
}) async {
  final s = Strings.of(context);
  final notices = AppFeedback.of(context);
  try {
    final paused = await control.delegationPaused();
    if (!context.mounted) return DelegationPauseOutcome.dismissed;
    final chosen = await showHermesMenu<bool>(
      context: context,
      anchorKey: anchorKey,
      title: s.subagentUiPauseScope,
      actions: [
        HermesAction(
          key: actionKey,
          value: !paused,
          label: paused ? s.subagentUiResumeNew : s.subagentUiPauseNew,
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
        ),
      ],
    );
    if (chosen == null || !context.mounted) {
      return DelegationPauseOutcome.dismissed;
    }
    final now = await control.setDelegationPaused(chosen);
    if (context.mounted) {
      notices.notify(
        FeedbackKind.routine,
        now ? s.subagentUiPausedNotice : s.subagentUiResumedNotice,
      );
    }
    return DelegationPauseOutcome.changed;
  } on TuiGatewayRpcError catch (error) {
    if (error.code == -32601) return DelegationPauseOutcome.unsupported;
    if (context.mounted) {
      notices.notify(FeedbackKind.error, s.subagentUiPauseFailed);
    }
    return DelegationPauseOutcome.failed;
  } catch (_) {
    if (context.mounted) {
      notices.notify(FeedbackKind.error, s.subagentUiPauseFailed);
    }
    return DelegationPauseOutcome.failed;
  }
}
