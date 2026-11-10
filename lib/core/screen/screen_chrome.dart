import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart';

/// Whether [error] is the gateway refusing because a person holds the
/// screen (`display.stop` without `force`).
bool displayHeldByHuman(Object error) =>
    error is TuiGatewayRpcError && error.data['code'] == 'viewer_mismatch';

/// How a [ScreenPill] reads.
enum ScreenPillKind {
  /// A plain action.
  neutral,

  /// The main action of the screen.
  primary,

  /// Switching something off (border and text in the error colour).
  danger,
}

/// A text pill of the bot-screen controls: at least 44 dp tall and 48 wide,
/// text only (no loose icons). [selected] outlines it in the accent.
class ScreenPill extends StatelessWidget {
  /// Creates a pill. A null [onTap] dims it.
  const ScreenPill({
    required this.label,
    required this.onTap,
    this.kind = ScreenPillKind.neutral,
    this.selected = false,
    this.semanticLabel,
    this.minHeight = 44,
    super.key,
  });

  /// Smallest height of the pill.
  final double minHeight;

  /// Visible text.
  final String label;

  /// Tap action; null disables the pill.
  final VoidCallback? onTap;

  /// Look of the pill.
  final ScreenPillKind kind;

  /// Whether the pill shows an active toggle.
  final bool selected;

  /// Label for screen readers when it should say more than [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final enabled = onTap != null;
    final primary = kind == ScreenPillKind.primary;
    final danger = kind == ScreenPillKind.danger;
    final fg = primary
        ? colors.onAccent
        : danger
        ? colors.error
        : colors.textPrimary;
    final border = selected
        ? colors.accent
        : danger
        ? colors.error.withValues(alpha: .55)
        : colors.divider;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : .4,
        child: Material(
          color: primary
              ? colors.accent
              : selected
              ? colors.surfaceVariant
              : colors.surface,
          shape: StadiumBorder(
            side: BorderSide(
              color: primary ? Colors.transparent : border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The state pill of the header: a dot and one word («Apagado», «Encendido»,
/// «Controlando»). The dot is lit while the desktop is on.
class ScreenStatusPill extends StatelessWidget {
  /// Creates a status pill.
  const ScreenStatusPill({required this.label, required this.on, super.key});

  /// State word.
  final String label;

  /// Whether the desktop is on.
  final bool on;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: ShapeDecoration(
        color: colors.surface,
        shape: StadiumBorder(side: BorderSide(color: colors.divider)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? colors.success : colors.textDisabled,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Header of the bot-screen pages: a back button, «Pantalla de `<bot>`», a
/// one-line status subtitle and the state pill.
class ScreenHeader extends StatelessWidget {
  /// Creates the header.
  const ScreenHeader({
    required this.title,
    required this.subtitle,
    required this.on,
    this.stateLabel,
    this.subtitleKey,
    super.key,
  });

  /// «Pantalla de `<bot>`».
  final String title;

  /// What is going on, in one line.
  final String subtitle;

  /// Word of the state pill; null while the state is not known yet.
  final String? stateLabel;

  /// Whether the desktop is on.
  final bool on;

  /// Key of the subtitle text, for tests.
  final Key? subtitleKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
      child: Row(
        children: [
          Tooltip(
            message: MaterialLocalizations.of(context).backButtonTooltip,
            child: Semantics(
              button: true,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              excludeSemantics: true,
              child: Material(
                color: colors.surface,
                shape: CircleBorder(side: BorderSide(color: colors.divider)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).maybePop(),
                  child: SizedBox.square(
                    dimension: 44,
                    child: Icon(
                      Icons.arrow_back_rounded,
                      size: 20,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  subtitle,
                  key: subtitleKey,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (stateLabel != null) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: ScreenStatusPill(label: stateLabel!, on: on),
            ),
          ],
        ],
      ),
    );
  }
}

/// «¿Apagar el ordenador de `<bot>`?» as a sheet of pills. Resolves true only
/// when the person confirms.
Future<bool> confirmPowerOff(
  BuildContext context, {
  required String bot,
}) async {
  final strings = Strings.of(context);
  final answer = await showHermesFloatingSurface<bool>(
    context: context,
    surfaceKey: const ValueKey('screen-power-surface'),
    maxWidth: 420,
    builder: (sheetContext) {
      final colors = Theme.of(sheetContext).hermes;
      return Padding(
        key: const ValueKey('screen-power-sheet'),
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.bsaPowerOffTitle(bot),
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              strings.bsaPowerOffBody,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ScreenPill(
                    key: const ValueKey('screen-power-cancel'),
                    label: strings.commonCancel,
                    onTap: () => Navigator.pop(sheetContext, false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ScreenPill(
                    key: const ValueKey('screen-power-confirm'),
                    label: strings.bsaPowerOff,
                    kind: ScreenPillKind.danger,
                    onTap: () => Navigator.pop(sheetContext, true),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  return answer ?? false;
}
