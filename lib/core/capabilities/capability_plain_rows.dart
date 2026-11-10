// The list of skills as the reader expects it: no card, one row per skill
// with the name in bold and at most two lines of description, the switch
// always at the same end, and a hairline between rows that starts where the
// text starts.
import 'package:flutter/material.dart';

import '../design/tokens.dart' show HermesSpace;
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart' show HermesListRow;

/// Horizontal inset of the text; the separators use the same one so they line
/// up with it.
const double _kInset = 12;

class CapabilityPlainList extends StatelessWidget {
  final List<Widget> children;

  const CapabilityPlainList({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).hermes.divider.withValues(alpha: 0.62);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i < children.length - 1)
            Divider(
              height: 1,
              thickness: 1,
              indent: _kInset,
              endIndent: _kInset,
              color: divider,
            ),
        ],
      ],
    );
  }
}

class CapabilityPlainRow extends StatelessWidget {
  final String title;
  final String description;

  /// The one control at the end (a switch slot or a status word).
  final Widget? trailing;
  final VoidCallback? onTap;

  /// A skill the user has just taught the agent: tinted, and read as selected.
  final bool highlighted;
  final String? semanticHint;

  const CapabilityPlainRow({
    super.key,
    required this.title,
    this.description = '',
    this.trailing,
    this.onTap,
    this.highlighted = false,
    this.semanticHint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    return Semantics(
      button: onTap != null,
      selected: highlighted,
      hint: semanticHint,
      child: Material(
        color: highlighted
            ? colors.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _kInset,
                vertical: HermesSpace.x2,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HermesListRow.titleStyle(
                            theme,
                            color: colors.textPrimary,
                          )?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (description.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HermesListRow.subtitleStyle(
                              theme,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 10),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
