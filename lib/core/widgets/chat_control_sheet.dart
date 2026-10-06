import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'chat/chat_notch.dart';
import 'hermes_ui.dart';

class ChatControlLabels {
  final String title;
  final String scope;
  final String sessionSection;
  final String toolsSection;
  final String dangerSection;
  final String permissions;
  final String refresh;
  final String artifacts;
  final String? content;
  final String? prompts;
  final String? showPinnedPrompt;
  final String? branch;
  final String details;
  final String cron;
  final String? recovery;
  final String? extensions;
  final String? skills;
  final String? memory;
  final String delete;
  final String readOnly;
  final String releaseDesktop;
  final String releaseUnavailable;

  /// "Ir a" row (notch sheet). The row only renders when every label is set
  /// and the sheet has an [ChatControlSheet.onNavigate].
  final String? goTo;
  final String? chats;
  final String? home;
  final String? projects;
  final String? settings;
  final String? searchChats;

  /// "Buscar en este chat": the in-chat find bar (moved from the header).
  final String? findInChat;

  /// Model and reasoning (Bot Chat only: its header overflow moved here).
  final String? model;
  final String? previousChat;
  final String? nextChat;

  const ChatControlLabels({
    required this.title,
    required this.scope,
    required this.sessionSection,
    required this.toolsSection,
    required this.dangerSection,
    required this.permissions,
    required this.refresh,
    required this.artifacts,
    required this.details,
    required this.cron,
    required this.delete,
    required this.readOnly,
    required this.releaseDesktop,
    required this.releaseUnavailable,
    this.recovery,
    this.extensions,
    this.skills,
    this.memory,
    this.content,
    this.prompts,
    this.showPinnedPrompt,
    this.branch,
    this.goTo,
    this.chats,
    this.home,
    this.projects,
    this.settings,
    this.searchChats,
    this.findInChat,
    this.model,
    this.previousChat,
    this.nextChat,
  });

  String? destination(ChatNotchDestination destination) =>
      switch (destination) {
        ChatNotchDestination.chats => chats,
        ChatNotchDestination.home => home,
        ChatNotchDestination.projects => projects,
        ChatNotchDestination.settings => settings,
        ChatNotchDestination.searchChats => searchChats,
      };
}

/// Ajustes de una conversación (la hoja de la rayita). Solo proyecta estado y
/// callbacks: no crea servicios ni duplica la configuración autoritativa de
/// Hermes.
///
/// Order (owner design, GUIA-CHAT §5): "Ir a" with four equal grey tiles,
/// then the conversation's own actions grouped as Sesión, Herramientas and
/// Zona sensible.
class ChatControlSheet extends StatelessWidget {
  final ChatControlLabels labels;
  final String conversationTitle;
  final bool readOnly;
  final bool showDetails;
  final bool showCron;
  final bool initialGoTo;
  final ValueChanged<ChatNotchDestination>? onNavigate;
  final VoidCallback? onFindInChat;
  final VoidCallback? onModel;
  final VoidCallback? onPreviousChat;
  final VoidCallback? onNextChat;
  final VoidCallback onPermissions;
  final VoidCallback onRefresh;
  final VoidCallback onArtifacts;
  final VoidCallback? onContent;
  final VoidCallback? onPrompts;

  /// Shows the pinned prompt again; null while it is not hidden here.
  final VoidCallback? onShowPinnedPrompt;
  final VoidCallback? onBranch;
  final VoidCallback? onDetails;
  final VoidCallback? onCron;
  final VoidCallback? onRecovery;
  final VoidCallback? onExtensions;
  final VoidCallback? onSkills;
  final VoidCallback? onMemory;
  final VoidCallback? onDelete;
  final bool showReleaseDesktop;
  final bool releaseDesktopEnabled;
  final bool releaseInFlight;
  final VoidCallback? onReleaseDesktop;

  const ChatControlSheet({
    required this.labels,
    required this.conversationTitle,
    required this.onPermissions,
    required this.onRefresh,
    required this.onArtifacts,
    this.onNavigate,
    this.onFindInChat,
    this.onModel,
    this.onPreviousChat,
    this.onNextChat,
    this.onDelete,
    this.onContent,
    this.onPrompts,
    this.onShowPinnedPrompt,
    this.onBranch,
    this.readOnly = false,
    this.showDetails = false,
    this.showCron = false,
    this.initialGoTo = false,
    this.onDetails,
    this.onCron,
    this.onRecovery,
    this.onExtensions,
    this.onSkills,
    this.onMemory,
    this.showReleaseDesktop = false,
    this.releaseDesktopEnabled = false,
    this.releaseInFlight = false,
    this.onReleaseDesktop,
    super.key,
  });

  bool get _hasGoTo =>
      onNavigate != null &&
      labels.goTo != null &&
      ChatNotchDestination.values.every(
        (destination) => labels.destination(destination) != null,
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final dangerRows = <Widget>[
      if (showReleaseDesktop)
        _ActionRow(
          key: const ValueKey('chat-control-release-desktop'),
          icon: Icons.desktop_windows_outlined,
          title: labels.releaseDesktop,
          subtitle: releaseDesktopEnabled ? null : labels.releaseUnavailable,
          onTap: releaseDesktopEnabled && !releaseInFlight
              ? onReleaseDesktop
              : null,
        ),
      if (releaseInFlight)
        const Padding(
          key: ValueKey('chat-runtime-release-progress'),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LinearProgressIndicator(),
        ),
      if (onDelete != null)
        _ActionRow(
          key: const ValueKey('chat-control-delete'),
          icon: Icons.delete_outline,
          title: labels.delete,
          color: colors.error,
          onTap: readOnly ? null : onDelete,
        ),
    ];

    return SafeArea(
      top: false,
      child: ListView(
        key: const ValueKey('chat-control-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        children: [
          if (_hasGoTo && initialGoTo) ...[
            HermesSectionHeader(
              labels.goTo!,
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            ),
            _GoToRow(labels: labels, onNavigate: onNavigate!),
            const SizedBox(height: 14),
          ],
          if (labels.findInChat != null && onFindInChat != null) ...[
            HermesGroup(
              key: const ValueKey('chat-control-group-find'),
              children: [
                _ActionRow(
                  key: const ValueKey('chat-control-find'),
                  icon: Icons.search_rounded,
                  title: labels.findInChat!,
                  onTap: onFindInChat,
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (_hasGoTo && !initialGoTo) ...[
            HermesSectionHeader(
              labels.goTo!,
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            ),
            _GoToRow(labels: labels, onNavigate: onNavigate!),
            const SizedBox(height: 14),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      labels.title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      conversationTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      labels.scope,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (readOnly) HermesBadge(labels.readOnly, color: colors.warning),
            ],
          ),
          HermesSectionHeader(
            labels.sessionSection,
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
          ),
          HermesGroup(
            key: const ValueKey('chat-control-group-session'),
            children: [
              if (labels.model != null && onModel != null)
                _ActionRow(
                  key: const ValueKey('chat-control-model'),
                  icon: Icons.tune_rounded,
                  title: labels.model!,
                  onTap: onModel,
                ),
              if (labels.previousChat != null && onPreviousChat != null)
                _ActionRow(
                  key: const ValueKey('chat-control-previous-chat'),
                  icon: Icons.chevron_left_rounded,
                  title: labels.previousChat!,
                  onTap: onPreviousChat,
                ),
              if (labels.nextChat != null && onNextChat != null)
                _ActionRow(
                  key: const ValueKey('chat-control-next-chat'),
                  icon: Icons.chevron_right_rounded,
                  title: labels.nextChat!,
                  onTap: onNextChat,
                ),
              _ActionRow(
                key: const ValueKey('chat-control-permissions'),
                icon: Icons.verified_user_outlined,
                title: labels.permissions,
                onTap: onPermissions,
              ),
              _ActionRow(
                key: const ValueKey('chat-control-refresh'),
                icon: Icons.refresh_rounded,
                title: labels.refresh,
                onTap: onRefresh,
              ),
              if (showDetails && onDetails != null)
                _ActionRow(
                  key: const ValueKey('chat-control-details'),
                  icon: Icons.info_outline,
                  title: labels.details,
                  onTap: onDetails!,
                ),
              if (labels.prompts != null && onPrompts != null)
                _ActionRow(
                  key: const ValueKey('chat-control-prompts'),
                  icon: Icons.chat_bubble_outline_rounded,
                  title: labels.prompts!,
                  onTap: onPrompts,
                ),
              if (labels.showPinnedPrompt != null && onShowPinnedPrompt != null)
                _ActionRow(
                  key: const ValueKey('chat-control-show-pinned-prompt'),
                  icon: Icons.vertical_align_top_rounded,
                  title: labels.showPinnedPrompt!,
                  onTap: onShowPinnedPrompt,
                ),
              if (labels.branch != null && onBranch != null)
                _ActionRow(
                  key: const ValueKey('chat-control-branch'),
                  icon: Icons.call_split_rounded,
                  title: labels.branch!,
                  onTap: onBranch,
                ),
            ],
          ),
          HermesSectionHeader(
            labels.toolsSection,
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
          ),
          HermesGroup(
            key: const ValueKey('chat-control-group-tools'),
            children: [
              _ActionRow(
                key: const ValueKey('chat-control-artifacts'),
                icon: Icons.inventory_2_outlined,
                title: labels.artifacts,
                onTap: onArtifacts,
              ),
              if (labels.content != null && onContent != null)
                _ActionRow(
                  key: const ValueKey('chat-control-content'),
                  icon: Icons.perm_media_outlined,
                  title: labels.content!,
                  onTap: onContent,
                ),
              if (showCron && onCron != null)
                _ActionRow(
                  key: const ValueKey('chat-control-cron'),
                  icon: Icons.schedule_outlined,
                  title: labels.cron,
                  onTap: onCron!,
                ),
              if (labels.extensions != null && onExtensions != null)
                _ActionRow(
                  key: const ValueKey('chat-control-extensions'),
                  icon: Icons.extension_outlined,
                  title: labels.extensions!,
                  onTap: onExtensions!,
                ),
              if (labels.skills != null && onSkills != null)
                _ActionRow(
                  key: const ValueKey('chat-control-skills'),
                  icon: Icons.auto_awesome_outlined,
                  title: labels.skills!,
                  onTap: onSkills!,
                ),
              if (labels.memory != null && onMemory != null)
                _ActionRow(
                  key: const ValueKey('chat-control-memory'),
                  icon: Icons.psychology_outlined,
                  title: labels.memory!,
                  onTap: onMemory!,
                ),
              if (labels.recovery != null && onRecovery != null)
                _ActionRow(
                  key: const ValueKey('chat-control-recovery'),
                  icon: Icons.restore_page_outlined,
                  title: labels.recovery!,
                  onTap: onRecovery!,
                ),
            ],
          ),
          if (dangerRows.isNotEmpty) ...[
            HermesSectionHeader(
              labels.dangerSection,
              padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
            ),
            HermesGroup(
              key: const ValueKey('chat-control-group-danger'),
              children: dangerRows,
            ),
          ],
        ],
      ),
    );
  }
}

/// Equal, neutral tiles (no colours), same glyphs as the dock. At large text
/// sizes they wrap two per row so every label stays readable.
class _GoToRow extends StatelessWidget {
  const _GoToRow({required this.labels, required this.onNavigate});

  final ChatControlLabels labels;
  final ValueChanged<ChatNotchDestination> onNavigate;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final perRow = scale > 1.3 ? 2 : ChatNotchDestination.values.length;
    final tiles = [
      for (final destination in ChatNotchDestination.values)
        _GoToTile(
          key: ValueKey('chat-notch-go-${destination.name}'),
          icon: chatNotchDestinationIcon(destination),
          label: labels.destination(destination)!,
          onTap: () => onNavigate(destination),
        ),
    ];
    final rows = <Widget>[];
    for (var start = 0; start < tiles.length; start += perRow) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = start; i < start + perRow; i++) ...[
              if (i > start) const SizedBox(width: 8),
              // Keeps the last row's tiles the same width as the others.
              Expanded(
                child: i < tiles.length ? tiles[i] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return Column(
      key: const ValueKey('chat-notch-go-to'),
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

class _GoToTile extends StatelessWidget {
  const _GoToTile({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                key: const ValueKey('chat-notch-go-face'),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: SizedBox(
                  height: 54,
                  width: double.infinity,
                  child: Center(
                    child: Icon(icon, size: 23, color: colors.textPrimary),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? color;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final enabled = onTap != null;
    final foreground = enabled
        ? (color ?? colors.textPrimary)
        : colors.textDisabled;
    return Semantics(
      button: true,
      enabled: enabled,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: foreground),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (enabled) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
