import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Infraestructura que una función puede necesitar antes de estar disponible.
enum FeatureDependencyKind {
  dashboard,
  bridge,
  gateway,
  permission,
  serverVersion,
  serverPackage,
}

/// Aviso no intrusivo que explica una dependencia junto a la función afectada.
///
/// El descarte solo vive durante el proceso actual: evita repetir banners al
/// navegar, pero no oculta para siempre una dependencia que siga sin resolver.
class FeatureDependencyNotice extends StatefulWidget {
  final String noticeId;
  final FeatureDependencyKind kind;
  final String title;
  final String message;
  final String? primaryActionLabel;
  final Future<void> Function()? onPrimaryAction;
  final String? retryLabel;
  final Future<void> Function()? onRetry;
  final bool dismissible;

  const FeatureDependencyNotice({
    required this.noticeId,
    required this.kind,
    required this.title,
    required this.message,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.retryLabel,
    this.onRetry,
    this.dismissible = true,
    super.key,
  });

  @visibleForTesting
  static void resetSessionDismissals() =>
      _FeatureDependencyNoticeState._dismissed.clear();

  @override
  State<FeatureDependencyNotice> createState() =>
      _FeatureDependencyNoticeState();
}

class _FeatureDependencyNoticeState extends State<FeatureDependencyNotice> {
  static final Set<String> _dismissed = <String>{};
  bool _busy = false;

  IconData get _icon => switch (widget.kind) {
    FeatureDependencyKind.dashboard => Icons.space_dashboard_outlined,
    FeatureDependencyKind.bridge => Icons.cable_outlined,
    FeatureDependencyKind.gateway => Icons.hub_outlined,
    FeatureDependencyKind.permission => Icons.admin_panel_settings_outlined,
    FeatureDependencyKind.serverVersion => Icons.system_update_alt,
    FeatureDependencyKind.serverPackage => Icons.inventory_2_outlined,
  };

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed.contains(widget.noticeId)) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).hermes;
    // Bug real: mezclaba Theme.of(context).colorScheme.secondaryContainer
    // (Material 3 por defecto) con `hermes.surface` en vez de usar solo
    // colores del theme extension de la app.
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${widget.title}. ${widget.message}',
      child: Material(
        key: ValueKey('dependency-notice-${widget.noticeId}'),
        color: Color.alphaBlend(
          colors.accent.withValues(alpha: 0.08),
          colors.surface,
        ),
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.32),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.accent.withValues(alpha: 0.2)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 12, 8, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(_icon, size: 19, color: colors.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.message,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    if (widget.onPrimaryAction != null ||
                        widget.onRetry != null) ...[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (widget.onPrimaryAction != null &&
                              widget.primaryActionLabel != null)
                            TextButton(
                              key: ValueKey(
                                'dependency-primary-${widget.noticeId}',
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _run(widget.onPrimaryAction!),
                              child: Text(widget.primaryActionLabel!),
                            ),
                          if (widget.onRetry != null &&
                              widget.retryLabel != null)
                            TextButton(
                              key: ValueKey(
                                'dependency-retry-${widget.noticeId}',
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _run(widget.onRetry!),
                              child: Text(widget.retryLabel!),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (widget.dismissible)
                IconButton(
                  key: ValueKey('dependency-dismiss-${widget.noticeId}'),
                  visualDensity: VisualDensity.compact,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () {
                    _dismissed.add(widget.noticeId);
                    setState(() {});
                  },
                  icon: Icon(
                    Icons.close,
                    size: 17,
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
