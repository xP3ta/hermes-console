import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'modal.dart';

/// A field that shows the value chosen and, on a tap, opens the shared
/// options surface ([showHermesOptions]) to change it: the select of a form
/// or of a row.
///
/// It stands where Material's dropdown stood. That one opens a popup of its
/// own, with none of what every other choice in the app has: the floating
/// tone, the scrim, the exit that recedes and the drag away.
///
/// A null [onChanged] disables it. With [inline] it is the bare value and
/// its arrow, for the end of a row; otherwise it is drawn as a text field
/// with [decoration].
class HermesSelectField<T> extends StatelessWidget {
  const HermesSelectField({
    required this.value,
    required this.options,
    required this.onChanged,
    this.decoration,
    this.title,
    this.hint,
    this.style,
    this.icon,
    this.inline = false,
    super.key,
  });

  final T? value;
  final List<HermesOption<T>> options;
  final ValueChanged<T>? onChanged;
  final InputDecoration? decoration;

  /// Title of the options surface; the decoration's label by default.
  final String? title;

  /// Shown, muted, while nothing is chosen.
  final String? hint;
  final TextStyle? style;
  final Widget? icon;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final enabled = onChanged != null;
    HermesOption<T>? current;
    for (final option in options) {
      if (option.value == value) {
        current = option;
        break;
      }
    }
    final name = title ?? decoration?.labelText;
    final base =
        style ??
        theme.dropdownMenuTheme.textStyle ??
        theme.textTheme.bodyLarge ??
        const TextStyle();
    final text = Text(
      current?.label ?? hint ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base.copyWith(
        fontFamily: current?.fontFamily,
        color: !enabled
            ? colors.textDisabled
            : current == null
            ? colors.textTertiary
            : base.color ?? colors.textPrimary,
      ),
    );
    final arrow = IconTheme.merge(
      data: IconThemeData(
        size: 22,
        color: enabled ? colors.textSecondary : colors.textDisabled,
      ),
      child: icon ?? const Icon(Icons.keyboard_arrow_down_rounded),
    );

    Future<void> open() async {
      final picked = await showHermesOptions<T>(
        context: context,
        options: options,
        selected: value,
        title: name,
      );
      if (picked != null) onChanged?.call(picked);
    }

    final Widget field;
    if (inline) {
      field = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: text),
            const SizedBox(width: 4),
            arrow,
          ],
        ),
      );
    } else {
      field = InputDecorator(
        decoration: (decoration ?? const InputDecoration())
            .applyDefaults(theme.inputDecorationTheme)
            .copyWith(enabled: enabled, suffixIcon: arrow),
        isEmpty: current == null && hint == null,
        child: text,
      );
    }
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: name,
      value: current?.label ?? hint,
      onTap: enabled ? open : null,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: enabled ? open : null,
          borderRadius: BorderRadius.circular(inline ? 10 : 14),
          child: field,
        ),
      ),
    );
  }
}
