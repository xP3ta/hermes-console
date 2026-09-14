import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
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
  final String details;
  final String cron;
  final String? recovery;
  final String? extensions;
  final String delete;
  final String readOnly;
  final String releaseDesktop;
  final String releaseUnavailable;

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
  });
}

/// Centro de ajustes de una conversación. Solo proyecta estado y callbacks:
/// no crea servicios ni duplica la configuración autoritativa de Hermes.
class ChatControlSheet extends StatelessWidget {
  final ChatControlLabels labels;
  final String conversationTitle;
  final bool readOnly;
  final bool showDetails;
  final bool showCron;
  final VoidCallback onPermissions;
  final VoidCallback onRefresh;
  final VoidCallback onArtifacts;
  final VoidCallback? onDetails;
  final VoidCallback? onCron;
  final VoidCallback? onRecovery;
  final VoidCallback? onExtensions;
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
    this.onDelete,
    this.readOnly = false,
    this.showDetails = false,
    this.showCron = false,
    this.onDetails,
    this.onCron,
    this.onRecovery,
    this.onExtensions,
    this.showReleaseDesktop = false,
    this.releaseDesktopEnabled = false,
    this.releaseInFlight = false,
    this.onReleaseDesktop,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;

    return SafeArea(
      top: false,
      child: ListView(
        key: const ValueKey('chat-control-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        children: [
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
                        fontSize: 20,
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
            children: [
              _ActionRow(
                icon: Icons.verified_user_outlined,
                title: labels.permissions,
                onTap: onPermissions,
              ),
            ],
          ),
          HermesSectionHeader(
            labels.toolsSection,
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
          ),
          HermesGroup(
            children: [
              _ActionRow(
                icon: Icons.refresh_rounded,
                title: labels.refresh,
                onTap: onRefresh,
              ),
              if (showReleaseDesktop)
                _ActionRow(
                  key: const ValueKey('chat-control-release-desktop'),
                  icon: Icons.desktop_windows_outlined,
                  title: labels.releaseDesktop,
                  subtitle: releaseDesktopEnabled
                      ? null
                      : labels.releaseUnavailable,
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
              if (showCron && onCron != null)
                _ActionRow(
                  icon: Icons.schedule_outlined,
                  title: labels.cron,
                  onTap: onCron!,
                ),
              _ActionRow(
                icon: Icons.inventory_2_outlined,
                title: labels.artifacts,
                onTap: onArtifacts,
              ),
              if (showDetails && onDetails != null)
                _ActionRow(
                  icon: Icons.info_outline,
                  title: labels.details,
                  onTap: onDetails!,
                ),
              if (labels.recovery != null && onRecovery != null)
                _ActionRow(
                  icon: Icons.restore_page_outlined,
                  title: labels.recovery!,
                  onTap: onRecovery!,
                ),
              if (labels.extensions != null && onExtensions != null)
                _ActionRow(
                  icon: Icons.extension_outlined,
                  title: labels.extensions!,
                  onTap: onExtensions!,
                ),
            ],
          ),
          if (onDelete != null) ...[
            HermesSectionHeader(
              labels.dangerSection,
              padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
            ),
            HermesGroup(
              children: [
                _ActionRow(
                  key: const ValueKey('chat-control-delete'),
                  icon: Icons.delete_outline,
                  title: labels.delete,
                  color: colors.error,
                  onTap: readOnly ? null : onDelete,
                ),
              ],
            ),
          ],
        ],
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
