import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'hermes_ui.dart';

enum HermesUpdateKind {
  checking,
  apiUnavailable,
  dashboardAccessRequired,
  checkFailed,
  current,
  available,
  external,
}

/// Interpreta el contrato de `/api/hermes/update/check` sin confundir
/// `update_available: false` con "al día". Docker y runtimes gestionados
/// devuelven ese valor porque el Dashboard no puede actualizarlos en sitio.
@immutable
final class HermesUpdatePresentation {
  const HermesUpdatePresentation({
    required this.kind,
    required this.currentVersion,
    required this.behind,
    required this.installMethod,
    required this.canApply,
    required this.updateCommand,
    required this.message,
    required this.hasUpdate,
  });

  factory HermesUpdatePresentation.fromPayload(
    Map<String, dynamic>? payload, {
    required String fallbackVersion,
  }) {
    if (payload == null) {
      return HermesUpdatePresentation(
        kind: HermesUpdateKind.apiUnavailable,
        currentVersion: fallbackVersion,
        behind: null,
        installMethod: '',
        canApply: false,
        updateCommand: '',
        message: '',
        hasUpdate: false,
      );
    }

    final current = (payload['current_version'] ?? fallbackVersion)
        .toString()
        .trim();
    final method = (payload['install_method'] ?? '').toString().trim();
    final behind = (payload['behind'] as num?)?.toInt();
    final available = payload['update_available'] == true;
    final canApply = payload['can_apply'] == true;
    final command = (payload['update_command'] ?? '').toString().trim();
    final message = (payload['message'] ?? '').toString().trim();
    final hasUpdate = available || (behind != null && behind != 0);
    final managedExternally = const {
      'docker',
      'nix',
      'nixos',
      'homebrew',
      'managed-runtime',
    }.contains(method.toLowerCase());

    final HermesUpdateKind kind;
    if (behind == 0) {
      kind = HermesUpdateKind.current;
    } else if (hasUpdate && canApply) {
      kind = HermesUpdateKind.available;
    } else if (managedExternally || (hasUpdate && !canApply)) {
      kind = HermesUpdateKind.external;
    } else {
      // `behind: null` significa que la comprobación no pudo ejecutarse. No es
      // evidencia de que la instalación esté actualizada.
      kind = HermesUpdateKind.checkFailed;
    }

    return HermesUpdatePresentation(
      kind: kind,
      currentVersion: current.isEmpty ? fallbackVersion : current,
      behind: behind,
      installMethod: method,
      canApply: canApply,
      updateCommand: command,
      message: message,
      hasUpdate: hasUpdate,
    );
  }

  factory HermesUpdatePresentation.dashboardAccessRequired({
    required String fallbackVersion,
  }) => HermesUpdatePresentation(
    kind: HermesUpdateKind.dashboardAccessRequired,
    currentVersion: fallbackVersion,
    behind: null,
    installMethod: '',
    canApply: false,
    updateCommand: '',
    message: '',
    hasUpdate: false,
  );

  /// The check is still in flight; the rest of the panel is already usable.
  factory HermesUpdatePresentation.checking({
    required String fallbackVersion,
  }) => HermesUpdatePresentation(
    kind: HermesUpdateKind.checking,
    currentVersion: fallbackVersion,
    behind: null,
    installMethod: '',
    canApply: false,
    updateCommand: '',
    message: '',
    hasUpdate: false,
  );

  factory HermesUpdatePresentation.checkFailed({
    required String fallbackVersion,
  }) => HermesUpdatePresentation(
    kind: HermesUpdateKind.checkFailed,
    currentVersion: fallbackVersion,
    behind: null,
    installMethod: '',
    canApply: false,
    updateCommand: '',
    message: '',
    hasUpdate: false,
  );

  final HermesUpdateKind kind;
  final String currentVersion;
  final int? behind;
  final String installMethod;
  final bool canApply;
  final String updateCommand;
  final String message;
  final bool hasUpdate;
}

/// Tarjeta pública para poder blindar con widget tests los estados del
/// actualizador sin levantar toda la pantalla de mantenimiento.
class HermesUpdateCard extends StatelessWidget {
  const HermesUpdateCard({
    required this.presentation,
    required this.isLocal,
    required this.busy,
    required this.onApply,
    this.onConfigureDashboard,
    this.onRetry,
    super.key,
  });

  final HermesUpdatePresentation presentation;
  final bool isLocal;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback? onConfigureDashboard;

  /// Re-asks the server (forced) from the `checkFailed` row.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final actionable =
        presentation.hasUpdate && (presentation.canApply || isLocal);
    final (icon, iconColor) = switch (presentation.kind) {
      HermesUpdateKind.checking => (
        Icons.system_update_alt,
        colors.textSecondary,
      ),
      HermesUpdateKind.current => (Icons.verified_outlined, colors.success),
      HermesUpdateKind.available => (Icons.system_update_alt, colors.accent),
      HermesUpdateKind.external => (Icons.terminal_rounded, colors.warning),
      HermesUpdateKind.dashboardAccessRequired => (
        Icons.lock_open_rounded,
        colors.warning,
      ),
      HermesUpdateKind.checkFailed => (
        Icons.sync_problem_outlined,
        colors.warning,
      ),
      HermesUpdateKind.apiUnavailable => (
        Icons.info_outline_rounded,
        colors.textSecondary,
      ),
    };

    return HermesPanel(
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(
          strings.setUpdateHermes,
          style: TextStyle(color: colors.textPrimary),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _summary(strings),
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
              if (presentation.kind ==
                      HermesUpdateKind.dashboardAccessRequired &&
                  onConfigureDashboard != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('hermes_update_configure_dashboard'),
                    onPressed: busy ? null : onConfigureDashboard,
                    icon: const Icon(Icons.settings_outlined, size: 17),
                    label: Text(strings.setConfigureDashboardAccess),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                  ),
                ),
              ],
              if (presentation.kind == HermesUpdateKind.external &&
                  presentation.message.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  presentation.message,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
              ],
              if (presentation.kind == HermesUpdateKind.external &&
                  presentation.updateCommand.isNotEmpty) ...[
                const SizedBox(height: 5),
                SelectionArea(
                  child: Text(
                    strings.setUpdateCommand(presentation.updateCommand),
                    key: const Key('hermes_update_command'),
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'JetBrainsMono',
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        trailing: actionable
            ? FilledButton(
                onPressed: busy ? null : onApply,
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(isLocal ? strings.setUpdate : strings.setApply),
              )
            : _statusIcon(context, colors),
      ),
    );
  }

  String _summary(Strings strings) => switch (presentation.kind) {
    HermesUpdateKind.checking => strings.setCheckingUpdate,
    HermesUpdateKind.apiUnavailable => strings.setNoRemoteUpdate,
    HermesUpdateKind.dashboardAccessRequired =>
      strings.setUpdateDashboardAccessRequired,
    HermesUpdateKind.checkFailed => strings.setUpdateCheckFailed(
      presentation.currentVersion,
    ),
    HermesUpdateKind.current => strings.setVersionCurrent(
      presentation.currentVersion,
    ),
    HermesUpdateKind.available => strings.setVersionBehind(
      presentation.currentVersion,
      presentation.behind ?? -1,
      presentation.installMethod.isEmpty
          ? ''
          : ' · ${presentation.installMethod}',
    ),
    HermesUpdateKind.external => strings.setUpdateExternal(
      presentation.currentVersion,
      presentation.installMethod.isEmpty
          ? strings.setUpdateExternalMethod
          : presentation.installMethod,
    ),
  };

  Widget _statusIcon(BuildContext context, HermesThemeColors colors) =>
      switch (presentation.kind) {
        HermesUpdateKind.current => Icon(Icons.check, color: colors.success),
        HermesUpdateKind.external => Icon(
          Icons.open_in_new_rounded,
          color: colors.warning,
        ),
        HermesUpdateKind.dashboardAccessRequired => Icon(
          Icons.lock_open_rounded,
          color: colors.warning,
        ),
        HermesUpdateKind.checkFailed =>
          onRetry == null
              ? Icon(Icons.refresh_rounded, color: colors.warning)
              : IconButton(
                  key: const Key('hermes_update_retry'),
                  icon: Icon(Icons.refresh_rounded, color: colors.warning),
                  tooltip: Strings.of(context).commonRetry,
                  onPressed: busy ? null : onRetry,
                ),
        HermesUpdateKind.checking => const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        HermesUpdateKind.apiUnavailable => Icon(
          Icons.remove_rounded,
          color: colors.textDisabled,
        ),
        HermesUpdateKind.available => Icon(
          Icons.system_update_alt,
          color: colors.accent,
        ),
      };
}
