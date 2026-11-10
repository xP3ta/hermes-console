import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../design/gel_surface.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';

/// A pill of the studio in the gel material: a label, an optional icon, a
/// 48 dp target. [accent] paints the accent gel; [selected] marks a choice
/// (spoken to screen readers).
class StudioPill extends StatelessWidget {
  final String label;
  final String? semanticLabel;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool accent;
  final bool selected;

  const StudioPill({
    super.key,
    required this.label,
    this.semanticLabel,
    this.icon,
    this.onTap,
    this.accent = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final enabled = onTap != null;
    final ink = accent ? colors.onAccent : colors.textPrimary;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: HermesSpace.tap,
            minWidth: HermesSpace.tap,
          ),
          child: Center(
            widthFactor: 1,
            child: HermesGelSurface(
              shape: const StadiumBorder(),
              tone: accent ? HermesGelTone.accent : HermesGelTone.glass,
              paintFill: true,
              hairline: true,
              enabled: enabled,
              sheenScale: 0.5,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x4,
                  vertical: HermesSpace.x2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: HermesSpace.x5, color: ink),
                      const SizedBox(width: HermesSpace.x2),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.style(
                          HermesType.body,
                          enabled ? ink : colors.textDisabled,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab of [StudioTabs].
@immutable
class StudioTabItem<T> {
  final T value;
  final String label;
  final Key? key;

  const StudioTabItem({required this.value, required this.label, this.key});
}

/// The tabs of the editor: gel pills, each a 48 dp target, that wrap onto a
/// second line when the text is large. The chosen one wears the accent.
class StudioTabs<T> extends StatelessWidget {
  final T value;
  final List<StudioTabItem<T>> items;
  final ValueChanged<T> onChanged;
  final String semanticLabel;

  const StudioTabs({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: semanticLabel,
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: HermesSpace.x2,
      children: [
        for (final item in items)
          StudioPill(
            key: item.key,
            label: item.label,
            accent: item.value == value,
            selected: item.value == value,
            onTap: () => onChanged(item.value),
          ),
      ],
    ),
  );
}

/// A choice of the studio: a [preview] in a rounded frame with a [label]
/// underneath. The frame is at least 48 dp; the choice in force wears the
/// accent border and is announced as selected.
class StudioTile extends StatelessWidget {
  final String label;
  final Widget preview;
  final bool selected;
  final VoidCallback? onTap;
  final double extent;

  /// A long press, and the same as a screen-reader custom action
  /// ([longPressLabel] names it).
  final VoidCallback? onLongPress;
  final String? longPressLabel;

  const StudioTile({
    super.key,
    required this.label,
    required this.preview,
    required this.onTap,
    this.selected = false,
    this.extent = 64,
    this.onLongPress,
    this.longPressLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: onLongPress == null || longPressLabel == null
          ? null
          : {CustomSemanticsAction(label: longPressLabel!): onLongPress!},
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          width: extent + HermesSpace.x2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: extent,
                height: extent,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(HermesRadius.row),
                  border: Border.all(
                    color: selected ? colors.accent : colors.divider,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: preview,
              ),
              const SizedBox(height: HermesSpace.x1),
              Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: HermesType.style(
                  HermesType.caption.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: 0,
                  ),
                  selected ? colors.textPrimary : colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A labelled slider row: the title and its value on one line, the slider
/// under it. [onStart] and [onEnd] bracket a drag so that it is one undo
/// step.
class StudioSliderRow extends StatelessWidget {
  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;
  final int? divisions;

  const StudioSliderRow({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.onStart,
    this.onEnd,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: HermesSpace.x2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: HermesType.style(HermesType.body, colors.textPrimary),
                ),
              ),
              Text(
                valueText,
                style: HermesType.style(HermesType.value, colors.textSecondary),
              ),
            ],
          ),
        ),
        Semantics(
          container: true,
          label: label,
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            semanticFormatterCallback: (_) => valueText,
            onChangeStart: onStart == null ? null : (_) => onStart!(),
            onChangeEnd: onEnd == null ? null : (_) => onEnd!(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// A round colour swatch for a [StudioTile] preview.
class StudioSwatch extends StatelessWidget {
  final Color? color;
  final Gradient? gradient;
  final Widget? child;

  const StudioSwatch({super.key, this.color, this.gradient, this.child});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: HermesSpace.x8,
      height: HermesSpace.x8,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        gradient: gradient,
      ),
      child: child,
    ),
  );
}
