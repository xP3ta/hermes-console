import 'package:flutter/material.dart';

import '../theme/component_profile.dart';

/// Permitir / Denegar of an agent approval: the one button the chat card
/// and Home share. Both answers have the same visual weight; only the
/// semantic tint changes. [busy] disables it while an answer is in flight.
class ApprovalChoiceButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool busy;
  final VoidCallback onTap;

  /// Fills the width it is given (the chat card); otherwise it is as wide
  /// as its label.
  final bool expand;

  /// Only the icon, for a narrow place; the label stays the tooltip and
  /// the accessible name.
  final bool iconOnly;

  const ApprovalChoiceButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.busy,
    required this.onTap,
    this.expand = true,
    this.iconOnly = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final style =
        FilledButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.14),
          foregroundColor: color,
          minimumSize: expand
              ? const Size.fromHeight(componentMinimumTapTarget)
              : const Size(
                  componentMinimumTapTarget,
                  componentMinimumTapTarget,
                ),
          padding: iconOnly
              ? EdgeInsets.zero
              : expand
              ? null
              : const EdgeInsets.symmetric(horizontal: 16),
          shape: const StadiumBorder(),
        ).copyWith(
          overlayColor: WidgetStatePropertyAll(color.withValues(alpha: 0.12)),
        );
    final onPressed = busy ? null : onTap;
    if (iconOnly) {
      return Tooltip(
        message: label,
        child: Semantics(
          label: label,
          button: true,
          enabled: onPressed != null,
          excludeSemantics: true,
          child: FilledButton(
            onPressed: onPressed,
            style: style,
            child: Icon(icon, size: 18),
          ),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 16),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }
}
