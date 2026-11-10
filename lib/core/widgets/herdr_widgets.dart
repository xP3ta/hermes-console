// Estado de Herdr en el terminal (1.4.0, F5), según la maqueta v25: banner
// del agente del panel enfocado sobre el terminal y panel «Herdr» con los
// espacios y sus agentes. Solo muestra lo que `herdr api snapshot` da de
// verdad (tipo y nombre del agente, estado y carpeta); el modelo, el
// contexto y Aprobar/Denegar de la maqueta no salen de Herdr y no están.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/herdr_status.dart';
import '../services/ssh_session_kind.dart';
import '../theme/app_theme.dart';

String herdrStatusLabel(Strings strings, HerdrAgentStatus status) =>
    switch (status) {
      HerdrAgentStatus.working => strings.herdrStatusWorking,
      HerdrAgentStatus.blocked => strings.herdrStatusBlocked,
      HerdrAgentStatus.idle => strings.herdrStatusIdle,
      HerdrAgentStatus.done => strings.herdrStatusDone,
      HerdrAgentStatus.unknown => strings.herdrStatusUnknown,
    };

Color herdrStatusColor(HermesThemeColors colors, HerdrAgentStatus status) =>
    switch (status) {
      HerdrAgentStatus.working => colors.accent,
      HerdrAgentStatus.blocked => colors.warning,
      HerdrAgentStatus.done => colors.success,
      HerdrAgentStatus.idle || HerdrAgentStatus.unknown => colors.textDisabled,
    };

/// Title of a pane: the agent's name, else its kind, else «Shell».
String herdrPaneTitle(Strings strings, HerdrPane pane) =>
    pane.name ?? pane.agent ?? strings.herdrShell;

class HerdrStatusDot extends StatelessWidget {
  const HerdrStatusDot({required this.status, super.key});

  final HerdrAgentStatus status;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: herdrStatusColor(Theme.of(context).hermes, status),
    ),
  );
}

/// Banner over the terminal: the agent in Herdr's focused pane and its
/// state, or why there is nothing to show.
class HerdrAgentBanner extends StatelessWidget {
  const HerdrAgentBanner({required this.view, super.key});

  final HerdrView view;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final snapshot = view.snapshot;
    final String? problem = view.notRunning
        ? strings.herdrServerNotRunning
        : view.failed
        ? strings.herdrUnreachable
        : null;
    if (snapshot == null && problem == null) return const SizedBox.shrink();
    final pane = snapshot?.focusedPane;
    final Widget body;
    if (pane == null || snapshot == null) {
      body = Text(
        problem ?? strings.herdrNoAgent,
        style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            herdrPaneTitle(strings, pane),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (pane.hasAgent) ...[
                HerdrStatusDot(status: pane.status),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  problem ??
                      (pane.hasAgent
                          ? herdrStatusLabel(strings, pane.status)
                          : strings.herdrNoAgent),
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
            ],
          ),
        ],
      );
    }
    // Announced by TalkBack only when the agent needs you or has finished:
    // as a live region in every state, each poll that flips working and
    // idle was read out, every 5 s (review R5A P3-B4-3).
    final status = pane != null && pane.hasAgent ? pane.status : null;
    return Semantics(
      container: true,
      liveRegion:
          status == HerdrAgentStatus.blocked || status == HerdrAgentStatus.done,
      child: Container(
        key: const ValueKey('herdr-agent-banner'),
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              pane?.hasAgent ?? false
                  ? Icons.smart_toy_outlined
                  : Icons.terminal_rounded,
              size: 20,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// App bar button that opens the Herdr panel; the badge counts the agents
/// waiting on an approval or a question.
class HerdrPanelButton extends StatelessWidget {
  const HerdrPanelButton({
    required this.needsYou,
    required this.onPressed,
    super.key,
  });

  final int needsYou;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return IconButton(
      key: const ValueKey('herdr-panel-button'),
      tooltip: needsYou > 0
          ? '${strings.herdrPanelTooltip} · '
                '${strings.herdrNeedsYouCount(needsYou)}'
          : strings.herdrPanelTooltip,
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: needsYou > 0,
        backgroundColor: colors.warning,
        label: Text('$needsYou'),
        child: const Icon(Icons.tag),
      ),
    );
  }
}

/// Herdr's workspaces and the panes in each, with the agent state. Tapping
/// an agent focuses it in Herdr (`herdr agent focus`).
class HerdrPanel extends StatelessWidget {
  const HerdrPanel({required this.view, required this.onOpenAgent, super.key});

  final HerdrView view;
  final ValueChanged<HerdrPane> onOpenAgent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final snapshot = view.snapshot;
    final String? problem = view.notRunning
        ? strings.herdrServerNotRunning
        : view.failed
        ? strings.herdrUnreachable
        : snapshot != null && snapshot.workspaces.isEmpty
        ? strings.herdrEmpty
        : null;
    return Column(
      key: const ValueKey('herdr-panel'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Icon(Icons.tag, size: 20, color: colors.textSecondary),
              const SizedBox(width: 8),
              Text(
                SshSessionKind.herdr.programName ?? SshSessionKind.herdr.id,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              problem,
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
          ),
        if (snapshot != null)
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                for (final workspace in snapshot.workspaces) ...[
                  _WorkspaceHeader(workspace: workspace, colors: colors),
                  for (final pane in workspace.panes)
                    _PaneRow(
                      pane: pane,
                      colors: colors,
                      onTap: pane.hasAgent ? () => onOpenAgent(pane) : null,
                    ),
                ],
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
            ),
          ),
          child: Text(
            strings.herdrKeepsAgentsAlive,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({required this.workspace, required this.colors});

  final HerdrWorkspace workspace;
  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    // The roll-up is only a coloured dot on screen: say it too (review
    // P2-F5-4, WCAG 1.4.1).
    container: true,
    header: true,
    label:
        '${workspace.label}, '
        '${herdrStatusLabel(Strings.of(context), workspace.status)}',
    excludeSemantics: true,
    child: Padding(
      key: ValueKey('herdr-workspace-${workspace.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              workspace.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ),
          HerdrStatusDot(status: workspace.status),
        ],
      ),
    ),
  );
}

class _PaneRow extends StatelessWidget {
  const _PaneRow({required this.pane, required this.colors, this.onTap});

  final HerdrPane pane;
  final HermesThemeColors colors;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final subtitle = pane.hasAgent
        ? herdrStatusLabel(strings, pane.status)
        : (pane.cwd ?? strings.herdrNoAgent);
    return InkWell(
      key: ValueKey('herdr-pane-${pane.paneId}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                pane.hasAgent ? Icons.smart_toy_outlined : Icons.terminal,
                size: 18,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      herdrPaneTitle(strings, pane),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (pane.hasAgent) ...[
                const SizedBox(width: 8),
                HerdrStatusDot(status: pane.status),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
