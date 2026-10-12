import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/connection_request.dart';
import '../theme/app_theme.dart';

/// The connector prompt of the running turn, above the composer: one row per
/// target with its state, an open-link and a "Not now" action for targets
/// still waiting, and one "Continue" for the whole operation. Actions are
/// absent when [canAct] is false (read-only chat) or the operation settled;
/// state only changes through the server's `connection.update`.
class ChatConnectionCard extends StatelessWidget {
  final ConnectionRequest request;
  final bool canAct;
  final ValueChanged<Uri> onOpenLink;
  final ValueChanged<String> onSkip;
  final VoidCallback onContinue;

  const ChatConnectionCard({
    required this.request,
    required this.canAct,
    required this.onOpenLink,
    required this.onSkip,
    required this.onContinue,
    super.key,
  });

  static bool _open(ConnectionTargetState state) =>
      state == ConnectionTargetState.pending ||
      state == ConnectionTargetState.initiated ||
      state == ConnectionTargetState.failed ||
      state == ConnectionTargetState.expired;

  static String _stateLabel(Strings s, ConnectionTargetState state) =>
      switch (state) {
        ConnectionTargetState.pending => s.cxnStatePending,
        ConnectionTargetState.initiated => s.cxnStateInitiated,
        ConnectionTargetState.connected => s.cxnStateConnected,
        ConnectionTargetState.skipped => s.cxnStateSkipped,
        ConnectionTargetState.failed => s.cxnStateFailed,
        ConnectionTargetState.expired => s.cxnStateExpired,
        ConnectionTargetState.notConnected => s.cxnStateNotConnected,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final acting = canAct && !request.settled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Semantics(
        container: true,
        label: s.cxnTitle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.link_rounded, size: 20, color: colors.textSecondary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    s.cxnTitle,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            for (final target in request.targets)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            target.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.textPrimary),
                          ),
                          Text(
                            _stateLabel(s, target.state),
                            key: ValueKey('cxn-state-${target.name}'),
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (acting && _open(target.state)) ...[
                      if (target.connectUrl != null)
                        TextButton(
                          key: ValueKey('cxn-open-${target.name}'),
                          onPressed: () => onOpenLink(target.connectUrl!),
                          child: Text(s.cxnOpen),
                        ),
                      TextButton(
                        key: ValueKey('cxn-skip-${target.name}'),
                        onPressed: () => onSkip(target.name),
                        child: Text(s.cxnSkip),
                      ),
                    ],
                  ],
                ),
              ),
            if (acting)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('cxn-continue'),
                  onPressed: onContinue,
                  child: Text(s.cxnContinue),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
