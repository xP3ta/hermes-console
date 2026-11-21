import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/hicons.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../data/bot_delivery.dart';
import '../state/bot_delivery_watch.dart';

/// Compact age of a delivery as Desktop prints it: the coarsest unit, floored
/// (`apps/desktop/src/lib/time.ts` `coarseElapsed`, first letter of the
/// unit): `42s`, `5m`, `3h`, `2d`.
String compactDeliveryAge(double sinceEpochSeconds, DateTime now) {
  final elapsed = now.millisecondsSinceEpoch - sinceEpochSeconds * 1000;
  final ms = elapsed < 0 ? 0 : elapsed;
  const second = 1000;
  const minute = 60 * second;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (ms >= day) return '${(ms / day).floor()}d';
  if (ms >= hour) return '${(ms / hour).floor()}h';
  if (ms >= minute) return '${(ms / minute).floor()}m';
  return '${(ms / second).floor()}s';
}

/// Plain words for a failed row's typed reason (`tools/bot_failure_reasons.py`
/// codes). A code this build has no words for, or the owner's `unknown`,
/// shows the owner's own error line instead, never the raw code (Desktop
/// `failureReasonText`).
String botDeliveryFailureReason(Strings s, BotDelivery row) {
  final text = switch (row.reason) {
    'provider_auth_or_access' => s.botDelivReasonProviderAuth,
    'provider_quota_limit' => s.botDelivReasonProviderQuota,
    'provider_rate_limit' => s.botDelivReasonProviderRateLimit,
    'provider_server_error' => s.botDelivReasonProviderServer,
    'missing_config' => s.botDelivReasonMissingConfig,
    'model_unavailable' => s.botDelivReasonModelUnavailable,
    'context_overflow' => s.botDelivReasonContextOverflow,
    'runtime_offline' => s.botDelivReasonRuntimeOffline,
    'queued_expired' => s.botDelivReasonQueuedExpired,
    'delivery_timeout' => s.botDelivReasonTimeout,
    'agent_blocked' => s.botDelivReasonBlocked,
    'cancelled' => s.botDelivReasonCancelled,
    _ => null,
  };
  if (text != null) return text;
  final error = row.error?.trim() ?? '';
  return error.isNotEmpty ? error : s.botDelivReasonUnknown;
}

/// What a row says about where its delivery stands.
String botDeliveryLabel(Strings s, BotDelivery row) => switch (row.state) {
  BotDeliveryState.queued => s.botDelivQueued,
  BotDeliveryState.claimed => s.botDelivClaimed,
  BotDeliveryState.working => s.botDelivWorking,
  BotDeliveryState.waitingOnYou =>
    row.waitingOn == 'approval'
        ? s.botDelivWaitingApproval
        : s.botDelivWaitingClarify,
  BotDeliveryState.failed =>
    row.isUnknownOutcome
        ? s.botDelivUnknownOutcome
        : s.botDelivFailed(botDeliveryFailureReason(s, row)),
};

/// «Waiting on teammates»: a compact card above a Bot Chat composer listing
/// every `message_agent` delivery from THIS bot that has not settled yet: who
/// it went to, where it stands (queued / picked up / working / waiting on you
/// / failed with its typed reason) and for how long. Open fronts the
/// teammate's chat (where its question or approval card is); Dismiss hides a
/// failure. Read-only: nothing here can resend (Desktop
/// `plugins/hermes-bots/teammate-waits.tsx` `TeammateWaits`).
class TeammateWaitsStrip extends StatefulWidget {
  const TeammateWaitsStrip({
    super.key,
    required this.watch,
    required this.onOpenTeammate,
  });

  final BotDeliveryWatch watch;

  /// Fronts the chat of the teammate named [target] (a profile name).
  final void Function(String target) onOpenTeammate;

  @override
  State<TeammateWaitsStrip> createState() => _TeammateWaitsStripState();
}

class _TeammateWaitsStripState extends State<TeammateWaitsStrip>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      widget.watch.start();
    }
  }

  @override
  void didUpdateWidget(TeammateWaitsStrip old) {
    super.didUpdateWidget(old);
    if (!identical(old.watch, widget.watch)) {
      old.watch.pause();
      widget.watch.start();
    }
  }

  /// Delivery state is for someone looking at the chat: a backgrounded app
  /// stops asking (react-query's `refetchIntervalInBackground` is off in
  /// Desktop) and asks again at once on the way back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.watch.start();
      unawaited(widget.watch.refresh());
    } else {
      widget.watch.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.watch.pause();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.watch,
    builder: (context, _) {
      final watch = widget.watch;
      final rows = watch.rows;
      if (watch.unsupported || rows.isEmpty) return const SizedBox.shrink();
      final s = Strings.of(context);
      final colors = Theme.of(context).hermes;
      final now = watch.asOf ?? DateTime.now();
      final anyUnknown = rows.any((row) => row.isUnknownOutcome);
      final quiet = TextStyle(fontSize: 12, color: colors.textSecondary);
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.x1,
          HermesSpace.pageH,
          0,
        ),
        child: Semantics(
          container: true,
          label: s.botDelivTitle,
          child: DecoratedBox(
            key: const ValueKey('teammate-waits'),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border.all(color: colors.divider),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x2,
                vertical: HermesSpace.x1,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: s.botDelivNeverResent,
                    child: Row(
                      children: [
                        Icon(
                          HIcons.forum_outlined,
                          size: 14,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: HermesSpace.x1),
                        Text(
                          s.botDelivTitle,
                          style: quiet.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Opacity(
                    opacity: watch.stale ? 0.6 : 1,
                    child: Column(
                      key: const ValueKey('teammate-waits-rows'),
                      children: [
                        for (final row in rows)
                          _DeliveryRow(
                            key: ValueKey('teammate-wait-${row.deliveryId}'),
                            row: row,
                            now: now,
                            onOpen: () => widget.onOpenTeammate(row.target),
                            onDismiss: () =>
                                unawaited(watch.dismiss(row.deliveryId)),
                          ),
                      ],
                    ),
                  ),
                  if (watch.stale)
                    Text(
                      s.botDelivStale,
                      key: const ValueKey('teammate-waits-stale'),
                      style: quiet,
                    ),
                  if (anyUnknown)
                    Text(
                      s.botDelivNeverResent,
                      key: const ValueKey('teammate-waits-never-resent'),
                      style: quiet,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _DeliveryRow extends StatelessWidget {
  const _DeliveryRow({
    super.key,
    required this.row,
    required this.now,
    required this.onOpen,
    required this.onDismiss,
  });

  final BotDelivery row;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final label = botDeliveryLabel(s, row);
    final tip = (row.error ?? '').isNotEmpty
        ? row.error!
        : row.preview.isNotEmpty
        ? row.preview
        : label;
    final labelColor = switch (row.state) {
      BotDeliveryState.waitingOnYou => colors.accentText,
      BotDeliveryState.failed => colors.error,
      _ => colors.textSecondary,
    };
    final name = row.targetHandle.isNotEmpty ? row.targetHandle : row.target;
    return Row(
      key: ValueKey('teammate-wait-row-${row.state.wire}'),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: HermesSpace.x2),
        Expanded(
          child: Tooltip(
            message: tip,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: row.state == BotDeliveryState.waitingOnYou
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: labelColor,
              ),
            ),
          ),
        ),
        Text(
          compactDeliveryAge(row.since, now),
          style: TextStyle(fontSize: 12, color: colors.textTertiary),
        ),
        TextButton(
          onPressed: onOpen,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x2),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(s.botDelivOpen, style: const TextStyle(fontSize: 12)),
        ),
        if (row.state == BotDeliveryState.failed)
          IconButton(
            tooltip: s.botDelivDismiss,
            onPressed: onDismiss,
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(HIcons.close),
          ),
      ],
    );
  }
}
