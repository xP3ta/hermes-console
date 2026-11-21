// One look for every panel of the workspace (1.4.3): the Terminal's two
// pieces (mock 136 v2-A), its context line over a rounded card with a
// hairline edge, now also for Files, Git and the Terminal's prompt when
// the connection has no SSH profile yet. The pane's frame and its one bar
// stay the host's (chat_workspace_host.dart); this is what goes inside.
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import 'chat_workspace_host.dart'
    show ChatWorkspacePaneScope, ChatWorkspaceTokens;

/// The context line over a panel's card, with the Terminal's metrics
/// (`ssh_terminal_screen.dart`, `_paneHeader`): an icon, what the panel
/// shows ([title], in mono when it is a path or a host), the connection
/// beside it ([detail]) and, at the end, how it is reached ([tag]: SSH,
/// SFTP, the server).
class ChatWorkspacePanelHeader extends StatelessWidget {
  const ChatWorkspacePanelHeader({
    required this.icon,
    required this.title,
    this.detail,
    this.tag,
    this.mono = true,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final String? tag;

  /// [title] is a path or a host.
  final bool mono;

  /// Under the line, before the card: the Terminal's own.
  static const double below = 6;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final ink = colors.textSecondary;
    final plain = HermesType.support.copyWith(color: ink);
    final detail = this.detail;
    final tag = this.tag;
    return Padding(
      key: const ValueKey('workspace-panel-header'),
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        HermesSpace.x2,
        HermesSpace.x4,
        below,
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: HermesIcon.sm, color: ink),
          ),
          const SizedBox(width: HermesSpace.x2),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: title,
                    style: mono
                        ? plain.copyWith(fontFamily: HermesType.monoFamily)
                        : null,
                  ),
                  if (detail != null && detail.isNotEmpty) ...[
                    const TextSpan(text: ' · '),
                    TextSpan(text: detail),
                  ],
                ],
              ),
              key: const ValueKey('workspace-panel-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: plain,
            ),
          ),
          if (tag != null) ...[
            const SizedBox(width: HermesSpace.x2),
            Text(
              tag,
              key: const ValueKey('workspace-panel-tag'),
              maxLines: 1,
              style: plain,
            ),
          ],
        ],
      ),
    );
  }
}

/// A panel's card: the Terminal's rounded card inside the pane, with its
/// margin and its hairline drawn over the content (an opaque body would
/// cover an edge drawn under it).
class ChatWorkspacePanelCard extends StatelessWidget {
  const ChatWorkspacePanelCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(ChatWorkspaceTokens.cardRadius);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ChatWorkspaceTokens.inset,
        HermesSpace.x1,
        ChatWorkspaceTokens.inset,
        HermesSpace.x2,
      ),
      child: DecoratedBox(
        key: const ValueKey('workspace-panel-card'),
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: HermesChrome.of(colors).line),
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// A context line over the panel content inside the workspace pane.
/// The host supplies the surrounding frame. [insetCard] adds an inner card
/// for panels that need one. Outside the pane this displays [child] alone.
class ChatWorkspacePanel extends StatelessWidget {
  const ChatWorkspacePanel({
    required this.header,
    required this.child,
    this.insetCard = true,
    super.key,
  });

  final ChatWorkspacePanelHeader header;
  final Widget child;
  final bool insetCard;

  @override
  Widget build(BuildContext context) {
    if (!ChatWorkspacePaneScope.isInPane(context)) return child;
    return Column(
      key: const ValueKey('workspace-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: insetCard ? ChatWorkspacePanelCard(child: child) : child,
        ),
      ],
    );
  }
}
