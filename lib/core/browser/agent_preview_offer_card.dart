import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/ambient_backdrop.dart' show hermesTonalButtonStyle;
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import 'agent_browser_bridge.dart';

/// The agent's `preview.open` as an offer in the chat: «Hermes quiere
/// enseñarte una página», the page, «Ver» and «Descartar». Nothing opens until
/// the user taps «Ver» (Desktop AGENTS.md: offer, don't hijack).
class AgentPreviewOfferCard extends StatelessWidget {
  const AgentPreviewOfferCard({
    required this.bridge,
    required this.connectionId,
    required this.sessionId,
    required this.onOpen,
    super.key,
  });

  final AgentBrowserBridge bridge;

  /// This chat's connection and runtime session; a null session shows
  /// nothing.
  final String connectionId;
  final String? sessionId;
  final ValueChanged<AgentPreviewOffer> onOpen;

  @override
  Widget build(BuildContext context) {
    final id = sessionId;
    if (id == null || id.isEmpty) return const SizedBox.shrink();
    return ValueListenableBuilder<Map<String, AgentPreviewOffer>>(
      valueListenable: bridge.offers,
      builder: (context, _, _) {
        final offer = bridge.offerFor(connectionId, id);
        if (offer == null) return const SizedBox.shrink();
        final strings = Strings.of(context);
        final colors = Theme.of(context).hermes;
        // The host is always shown: the agent's label alone could name any
        // page «Tu banco» (REVIEW-R5-B #22).
        final host = offer.url.host;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.x3,
            HermesSpace.x2,
            HermesSpace.x3,
            0,
          ),
          child: Material(
            key: const ValueKey('agent-preview-offer'),
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(HermesRadius.group),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x3,
                HermesSpace.x2,
                HermesSpace.x2,
                HermesSpace.x2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.language_rounded, color: colors.accent),
                      const SizedBox(width: HermesSpace.x3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              strings.brwAgentOffer,
                              style: HermesType.style(
                                HermesType.body,
                                colors.textPrimary,
                              ),
                            ),
                            if (offer.label.isNotEmpty)
                              Text(
                                offer.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HermesType.style(
                                  HermesType.support,
                                  colors.textSecondary,
                                ),
                              ),
                            Text(
                              host,
                              key: const ValueKey('agent-preview-offer-host'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HermesType.style(
                                HermesType.support,
                                colors.textSecondary,
                              ).copyWith(fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Side by side when they fit, stacked at large text.
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: HermesSpace.x2,
                    children: [
                      TextButton(
                        key: const ValueKey('agent-preview-offer-dismiss'),
                        onPressed: () => bridge.dismissOffer(connectionId, id),
                        child: Text(strings.brwAgentOfferDismiss),
                      ),
                      FilledButton.tonal(
                        style: hermesTonalButtonStyle,
                        key: const ValueKey('agent-preview-offer-open'),
                        onPressed: () {
                          bridge.dismissOffer(connectionId, id);
                          onOpen(offer);
                        },
                        child: Text(strings.brwAgentOfferOpen),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
