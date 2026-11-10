import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'liquid_sheen.dart';
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

  /// Divider indent; null lines the divider up with the text of the rows:
  /// [HermesSpace.rowDividerIndent] (past the icon slot) when any row has a
  /// leading icon, the row's own padding when none has.
  final double? dividerIndent;

  const HermesListGroup({
    super.key,
    required this.children,
    this.dividerIndent,
  });

  /// Where the text of the rows starts.
  static double textIndentOf(List<Widget> children) {
    final withLead = children.any(
      (child) =>
          child is HermesListRow &&
          (child.icon != null || child.leading != null),
    );
    return withLead ? HermesSpace.rowDividerIndent : HermesSpace.rowH;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final indent = dividerIndent ?? textIndentOf(children);
    return HermesSheen(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.group),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: HermesSurfaces.group(colors),
          borderRadius: BorderRadius.circular(HermesRadius.group),
        ),
        clipBehavior: Clip.antiAlias,
        // The rows' ink paints over the body, inside its rounded clip (on
        // the page's Material it went under the body: square corners).
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    indent: indent,
                    endIndent: HermesSpace.rowH,
                    color: HermesSurfaces.divider(colors),
                  ),
                children[i],
              ],
            ],
          ),
        ),
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

  static const double _valueGap = 10;

  /// The value ends where the row's text ends, next to the arrow: it has its
  /// own width, and the title has all the rest. The title takes what one
  /// line of it needs first; a value too long for what is left ends in an
  /// ellipsis, but never gets less than two fifths of the row's text, so a
  /// long title wraps (two lines, then its own ellipsis) instead of hiding
  /// it.
  double _valueMaxWidth(BuildContext context, double area) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double oneLine(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    var needed = oneLine(title, HermesType.body);
    final under = subtitle;
    if (under != null && under.isNotEmpty) {
      final width = oneLine(under, HermesType.support);
      if (width > needed) needed = width;
    }
    final rest = area - _valueGap - needed.ceilToDouble();
    final least = area * 0.4;
    final share = rest < least ? least : rest;
    // ... but never so much that the title's longest word breaks in two
    // («Razonamient / o» at 200 %): the value takes the ellipsis instead.
    var longestWord = 0.0;
    for (final word in title.split(' ')) {
      final width = oneLine(word, HermesType.body);
      if (width > longestWord) longestWord = width;
    }
    final wordRoom = area - _valueGap - longestWord.ceilToDouble();
    final floor = area * 0.2;
    if (share <= wordRoom) return share;
    return wordRoom < floor ? floor : wordRoom;
  }

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
    final label = Column(
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
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
      ],
    );
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
                child: value == null || value!.isEmpty
                    ? label
                    : LayoutBuilder(
                        builder: (context, area) => Row(
                          children: [
                            Expanded(child: label),
                            const SizedBox(width: _valueGap),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: _valueMaxWidth(
                                  context,
                                  area.maxWidth,
                                ),
                              ),
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
                        ),
                      ),
              ),
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
      // excludeSemantics drops the InkWell's tap too: the labelled node
      // carries it again, or TalkBack announces a button it cannot press.
      row = Semantics(
        button: onTap != null,
        label: semanticLabel,
        onTap: onTap,
        excludeSemantics: true,
        child: row,
      );
    }
    return row;
  }
}
