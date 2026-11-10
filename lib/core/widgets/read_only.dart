import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../feedback/feedback_policy.dart';

/// Pill discreta que marca una instancia en modo solo lectura.
class ReadOnlyBadge extends StatelessWidget {
  /// Versión mini para AppBars y filas densas.
  final bool compact;

  /// Con el ancho que le den: si sus palabras no caben, queda en su icono
  /// (TalkBack sigue diciendo «solo lectura»). gint51: en la cabecera de la
  /// lista, a 390 dp y con letra grande, desbordaba.
  final bool fitWidth;

  const ReadOnlyBadge({this.compact = false, this.fitWidth = false, super.key});

  @override
  Widget build(BuildContext context) {
    if (!fitWidth) return _badge(context, words: true);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth;
        // One dp to spare: rounding never makes the words overflow.
        if (!constraints.hasBoundedWidth || room >= _wordsWidth(context) + 1) {
          return _badge(context, words: true);
        }
        if (room >= _iconWidth + 1) return _badge(context, words: false);
        // Not even its icon fits: nothing drawn, still said.
        return Semantics(
          key: const ValueKey('read-only-badge-icon'),
          label: Strings.of(context).readOnlyBadge,
          child: const SizedBox.shrink(),
        );
      },
    );
  }

  /// The badge with its icon only: padding, icon, border.
  double get _iconWidth => 2 * _padding + _iconSize + 2;

  double get _padding => compact ? 6 : 8;
  double get _iconSize => compact ? 10 : 11;
  static const double _iconGap = 4;

  TextStyle _style(Color color) => TextStyle(
    fontSize: compact ? 8.5 : 9.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: color,
  );

  /// The badge's width with its words: padding, icon, gap, words, border.
  double _wordsWidth(BuildContext context) {
    final words = TextPainter(
      text: TextSpan(
        text: Strings.of(context).readOnlyBadge,
        style: DefaultTextStyle.of(context).style.merge(_style(Colors.black)),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = words.width;
    words.dispose();
    return 2 * _padding + _iconSize + _iconGap + width + 2;
  }

  Widget _badge(BuildContext context, {required bool words}) {
    final colors = Theme.of(context).hermes;
    final label = Strings.of(context).readOnlyBadge;
    final badge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: _padding,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility_outlined,
            size: _iconSize,
            color: colors.warning,
          ),
          if (words) ...[
            const SizedBox(width: _iconGap),
            Text(
              label,
              // As it always was unless it has to fit a width.
              maxLines: fitWidth ? 1 : null,
              style: _style(colors.warning),
            ),
          ],
        ],
      ),
    );
    if (words) return badge;
    return Semantics(
      key: const ValueKey('read-only-badge-icon'),
      label: label,
      child: ExcludeSemantics(child: badge),
    );
  }
}

/// Aviso estándar al intentar una acción de escritura en una instancia
/// de solo lectura.
void showReadOnlyNotice(BuildContext context) {
  AppFeedback.of(context).notify(
    FeedbackKind.error,
    Strings.of(context).readOnlyNotice,
    warning: true,
    duration: const Duration(seconds: 2),
  );
}
