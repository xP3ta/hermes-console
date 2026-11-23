import 'package:flutter/material.dart';
import 'package:hermes_android/core/design/hicons.dart';

import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../../theme/readable_ink.dart';

/// The quiet receipt at the foot of an answer: a small icon, one
/// support-size label and a chevron, with no capsule around them. The
/// memory receipt, the self-improvement notice and the settled turn summary
/// are all this row, so they read as one family.
class TurnReceiptPill extends StatelessWidget {
  const TurnReceiptPill({
    required this.onTap,
    this.icon,
    this.label,
    this.leading,
    this.text,
    this.trailing,
    this.inkKey,
    this.semanticLabel,
    this.singleLine = false,
    this.semantics = true,
    super.key,
  }) : assert((icon == null) != (leading == null)),
       assert((label == null) != (text == null));

  /// The least height of the row at the default text size.
  static const double height = 28;

  /// The ink of the row's icon, label and chevron.
  static Color inkOf(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return readableInkOnTint(colors.textSecondary, colors.surface, colors);
  }

  /// The style of the row's label.
  static TextStyle styleOf(BuildContext context) =>
      HermesType.support.copyWith(color: inkOf(context));

  final VoidCallback onTap;

  /// The leading icon, in the row's ink; or [leading] for a widget.
  final IconData? icon;
  final Widget? leading;

  /// The label, in the row's style; or [text] for a widget that lays its
  /// own line out (it may not be asked for its intrinsic width).
  final String? label;
  final Widget? text;

  /// What ends the row; a right chevron when null.
  final Widget? trailing;
  final Key? inkKey;

  /// What a screen reader says; the visible label when null.
  final String? semanticLabel;

  /// Keeps a label of unknown length on one line, ending in an ellipsis.
  final bool singleLine;

  /// False when an ancestor already announces the row.
  final bool semantics;

  @override
  Widget build(BuildContext context) {
    final ink = inkOf(context);
    Widget row = Material(
      color: Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: inkKey,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: height),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x1,
              vertical: 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading ?? Icon(icon, size: HermesIcon.sm, color: ink),
                const SizedBox(width: HermesSpace.x1),
                Flexible(
                  child:
                      text ??
                      Text(
                        label!,
                        maxLines: singleLine ? 1 : null,
                        overflow: singleLine ? TextOverflow.ellipsis : null,
                        softWrap: singleLine ? false : null,
                        style: styleOf(context),
                      ),
                ),
                const SizedBox(width: HermesSpace.x1),
                trailing ??
                    Icon(
                      HIcons.chevron_right_rounded,
                      size: HermesIcon.sm,
                      color: ink,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
    if (semantics) {
      row = Semantics(
        button: true,
        label: semanticLabel ?? label,
        onTap: onTap,
        excludeSemantics: true,
        child: row,
      );
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: text == null ? null : 1,
      heightFactor: text == null ? null : 1,
      child: text == null ? IntrinsicWidth(child: row) : row,
    );
  }
}
