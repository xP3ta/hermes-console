import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'tokens.dart';

/// Quiet uppercase section header (reference `_Header` of the Bot profile).
class HermesSectionHeader extends StatelessWidget {
  final String text;
  final Widget? trailing;

  /// Use for the first header right under a hero or at the page top.
  final EdgeInsetsGeometry padding;

  const HermesSectionHeader(
    this.text, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      6,
      HermesSpace.sectionTop,
      6,
      HermesSpace.sectionBottom,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text.toUpperCase(),
      style: HermesType.caption.copyWith(
        color: Theme.of(context).hermes.textSecondary,
      ),
    );
    return Padding(
      padding: padding,
      child: Semantics(
        header: true,
        child: trailing == null
            ? label
            : Row(
                children: [
                  Expanded(child: label),
                  trailing!,
                ],
              ),
      ),
    );
  }
}

/// Soft borderless group of rows (reference `_Card`): tinted surface, radius
/// 16, inset hairline dividers.
class HermesListGroup extends StatelessWidget {
  final List<Widget> children;

  /// Divider indent; 50 lines up with rows that have a leading icon.
  final double dividerIndent;

  const HermesListGroup({
    super.key,
    required this.children,
    this.dividerIndent = HermesSpace.rowDividerIndent,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      decoration: BoxDecoration(
        color: HermesSurfaces.group(colors),
        borderRadius: BorderRadius.circular(HermesRadius.group),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: dividerIndent,
                color: HermesSurfaces.divider(colors),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One 52 dp row of a [HermesListGroup] (reference `_Line`).
class HermesListRow extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;

  /// Custom leading widget (avatar, dot…). Takes precedence over [icon].
  final Widget? leading;
  final String title;
  final String? subtitle;
  final int subtitleMaxLines;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Secondary title colour (placeholders such as "Idle").
  final bool muted;

  /// Red title and icon for destructive rows.
  final bool destructive;
  final bool showChevron;
  final String? semanticLabel;

  const HermesListRow({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.leading,
    this.subtitle,
    this.subtitleMaxLines = 1,
    this.value,
    this.trailing,
    this.onTap,
    this.muted = false,
    this.destructive = false,
    this.showChevron = true,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final titleColor = destructive
        ? colors.error
        : muted
        ? colors.textSecondary
        : colors.textPrimary;
    final lead =
        leading ??
        (icon == null
            ? null
            : Icon(
                icon,
                size: 20,
                color: destructive
                    ? colors.error
                    : iconColor ?? colors.textSecondary,
              ));
    Widget row = InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: HermesSpace.rowMin),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.rowH,
            vertical: HermesSpace.rowV,
          ),
          child: Row(
            children: [
              if (lead != null) ...[
                lead,
                const SizedBox(width: HermesSpace.rowIconGap),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.body.copyWith(color: titleColor),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        maxLines: subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (value != null && value!.isNotEmpty) ...[
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: HermesType.value.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
              ?trailing,
              if (onTap != null && trailing == null && showChevron)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.textDisabled,
                ),
            ],
          ),
        ),
      ),
    );
    if (semanticLabel != null) {
      row = Semantics(
        button: onTap != null,
        label: semanticLabel,
        excludeSemantics: true,
        child: row,
      );
    }
    return row;
  }
}
