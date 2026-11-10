import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/component_profile.dart';
import '../theme/motion.dart';
import '../design/ambient_backdrop.dart' show HermesGlassLook;
import '../design/box_edge.dart' show HermesBoxEdges;
import '../theme/glass_look.dart' show GlassMaterial;
import '../theme/lines.dart';
import '../design/floating.dart';
import '../design/gel_surface.dart';
import '../design/glass_strip.dart';
import '../design/liquid_glass.dart';
import '../design/liquid_sheen.dart';
import '../design/modal.dart' show showHermesSurface;
import '../design/tokens.dart'
    show HermesChrome, HermesGel, HermesRadius, HermesSpace, HermesType;
import 'hermes_ui.dart' show HermesSoftLight;

/// Legacy entry point of the ONE floating modal container (spec 080).
///
/// Delegates to [showHermesSurface]: rounded 22, content-sized, scrim,
/// IME-aware, clamped inner scrolling, anchored to [anchorKey]/[originRect]
/// when given and centred otherwise. Never a bottom sheet. Legacy callers are
/// mostly forms and details that become pages in spec 080 steps 6–8, so this
/// wrapper keeps their 0.88 height cap; new pickers use [showHermesSurface]
/// (70 %) or [showHermesOptions].
Future<T?> showHermesFloatingSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Key surfaceKey = const ValueKey('hermes-floating-surface'),
  double maxWidth = 560,
  double maxHeightFactor = 0.88,
  bool barrierDismissible = true,
  bool systemDismissible = true,
  bool useRootNavigator = false,
  GlobalKey? anchorKey,
  Rect? originRect,
}) => showHermesSurface<T>(
  context: context,
  builder: builder,
  surfaceKey: surfaceKey,
  maxWidth: maxWidth,
  maxHeightFactor: maxHeightFactor,
  barrierDismissible: barrierDismissible,
  systemDismissible: systemDismissible,
  useRootNavigator: useRootNavigator,
  anchorKey: anchorKey,
  originRect: originRect,
);

/// Disposes [controllers] exactly when this widget actually leaves the
/// tree, instead of on a fixed delay guessed to outlast whatever route
/// closing animation currently wraps it.
///
/// `Navigator.push`'s returned future completes the instant `pop()` is
/// called — not when the route's reverse transition finishes removing its
/// widget subtree. A form's own `TextEditingController`s are commonly local
/// variables owned by the function that opened the route (not by a widget
/// with its own lifecycle), so disposing them right after that future
/// resolves races the still-mounted `TextField` against its now-disposed
/// controller. Wrapping the route content here ties disposal to the actual
/// unmount instead of a magic duration.
class DisposeControllersOnUnmount extends StatefulWidget {
  const DisposeControllersOnUnmount({
    super.key,
    required this.controllers,
    required this.child,
  });

  final List<ChangeNotifier> controllers;
  final Widget child;

  @override
  State<DisposeControllersOnUnmount> createState() =>
      _DisposeControllersOnUnmountState();
}

class _DisposeControllersOnUnmountState
    extends State<DisposeControllersOnUnmount> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// Floating confirmation dialog: the app's one confirm-dialog shell.
///
/// Reuses [showHermesFloatingSurface] for the actual chrome (opaque surface,
/// radius 22, soft shadow) so every confirmation in the app shares the same
/// shell instead of hand-rolling `AlertDialog`. No divider sits above the
/// actions; the destructive action renders as a filled pill in
/// [HermesThemeColors.error] rather than a boxed Material button.
Future<bool> showHermesConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
  bool destructive = false,
  bool useRootNavigator = false,
}) async {
  final result = await showHermesFloatingSurface<bool>(
    context: context,
    surfaceKey: const ValueKey('hermes-confirm-dialog'),
    maxWidth: 400,
    maxHeightFactor: 0.5,
    useRootNavigator: useRootNavigator,
    builder: (dialogCtx) => _HermesConfirmDialogBody(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
    ),
  );
  return result == true;
}

class _HermesConfirmDialogBody extends StatelessWidget {
  const _HermesConfirmDialogBody({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _HermesDialogTextPill(
                key: const ValueKey('hermes-confirm-dialog-cancel'),
                label: cancelLabel,
                foreground: colors.textPrimary,
                onTap: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(width: 4),
              _HermesDialogTextPill(
                key: const ValueKey('hermes-confirm-dialog-confirm'),
                label: confirmLabel,
                foreground: destructive
                    ? _contrastOn(colors.error)
                    : colors.onAccent,
                background: destructive ? colors.error : colors.accent,
                onTap: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Color _contrastOn(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

class _HermesDialogTextPill extends StatelessWidget {
  const _HermesDialogTextPill({
    required this.label,
    required this.foreground,
    required this.onTap,
    this.background,
    super.key,
  });

  final String label;
  final Color foreground;
  final Color? background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: background == null ? 16 : 22,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: background == null
                  ? FontWeight.w500
                  : FontWeight.w600,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared calm, accessible primitives for root screens and grouped settings.
///
/// These widgets intentionally do not introduce a second theme system. They
/// consume [HermesThemeColors] and the active [ComponentProfile], so every
/// built-in/custom theme keeps its identity while navigation and hierarchy
/// remain consistent.
class HermesEmptyState extends StatelessWidget {
  final IconData? icon;
  final Widget? visual;
  final String title;
  final String body;
  final String? primaryLabel;
  final IconData? primaryIcon;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Widget? footer;
  final bool compact;
  final EdgeInsetsGeometry padding;

  const HermesEmptyState({
    required this.title,
    required this.body,
    this.icon,
    this.visual,
    this.primaryLabel,
    this.primaryIcon,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.footer,
    this.compact = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final shape = Theme.of(context).hermesComponents.profile.shape;
    final children = <Widget>[
      if (visual != null)
        visual!
      else if (icon != null)
        Container(
          width: compact ? 44 : 52,
          height: compact ? 44 : 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceVariant.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(shape.cardRadius),
          ),
          child: ExcludeSemantics(
            child: Icon(
              icon,
              size: compact ? 22 : 25,
              color: colors.textSecondary,
            ),
          ),
        ),
      if (visual != null || icon != null) SizedBox(height: compact ? 14 : 18),
      Semantics(
        header: true,
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: colors.textPrimary,
            fontSize: compact ? 16 : 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
      ),
      const SizedBox(height: 7),
      Text(
        body,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: colors.textSecondary,
          height: 1.42,
        ),
      ),
      if (primaryLabel != null && onPrimary != null) ...[
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: onPrimary,
          icon: Icon(primaryIcon ?? Icons.add_rounded, size: 19),
          label: Text(primaryLabel!),
        ),
      ],
      if (secondaryLabel != null && onSecondary != null) ...[
        const SizedBox(height: 4),
        TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
      ],
      if (footer != null) ...[const SizedBox(height: 18), footer!],
    ];

    return Padding(
      padding: padding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 410),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

class HermesListSection extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry titlePadding;
  final bool showDividers;

  /// Where a divider starts; null lines it up with the text of the rows:
  /// past the icon slot when any row has a leading icon, at the row's own
  /// padding when none has (a divider starting 54 dp in, next to rows
  /// whose text started at 14, read as a misplaced line on the device).
  final double? dividerIndent;

  const HermesListSection({
    required this.children,
    this.title,
    this.trailing,
    this.margin = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: HermesSpace.x1,
    ),
    this.titlePadding = const EdgeInsets.fromLTRB(4, 16, 4, 8),
    this.showDividers = true,
    this.dividerIndent,
    super.key,
  });

  /// Where the text of the rows starts: the icon slot's end when any of
  /// [children] is a [HermesListRow] with a leading icon, else the row's
  /// horizontal padding.
  static double textIndentOf(List<Widget> children) {
    final withLead = children.any(
      (child) =>
          child is HermesListRow &&
          (child.icon != null || child.leading != null),
    );
    return withLead ? HermesListRow.iconIndent : HermesSpace.rowH;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final profile = theme.hermesComponents.profile;
    final glass = HermesGlassLook.of(context);
    final rows = <Widget>[];
    final indent = dividerIndent ?? textIndentOf(children);
    // The least line that is seen on the body ([HermesLines.dividerRatio]).
    final divider = HermesLines.of(colors).divider;
    for (var index = 0; index < children.length; index++) {
      rows.add(children[index]);
      if (showDividers && index < children.length - 1) {
        rows.add(
          Divider(
            height: 1,
            thickness: profile.border.width,
            indent: indent,
            endIndent: HermesSpace.rowH,
            color: divider,
          ),
        );
      }
    }

    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || trailing != null)
            Padding(
              padding: titlePadding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (title != null)
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          HermesGlassLook.sectionText(context, title!),
                          semanticsLabel: HermesGlassLook.sectionSemantics(
                            context,
                            title!,
                          ),
                          style: HermesGlassLook.sectionLabel(
                            context,
                            (theme.textTheme.labelLarge ?? const TextStyle())
                                .copyWith(
                                  color: colors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0,
                                ),
                            glass: glass,
                          ),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  ?trailing,
                ],
              ),
            ),
          if (glass != null)
            HermesGlassLook.body(
              glass,
              BorderRadius.circular(profile.shape.groupRadius),
              fill: glass.groupFill,
              lifted: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rows,
              ),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                color: HermesSoftLight.solid(context)
                    ? HermesSoftLight.fill(context)
                    : colors.surfaceVariant.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(profile.shape.groupRadius),
                border: profile.border.outlinesRestingControls
                    ? Border.all(
                        color: colors.divider.withValues(alpha: 0.68),
                        width: profile.border.width,
                      )
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(profile.shape.groupRadius),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class HermesListRow extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final String title;

  /// Lines the title may take before it ends in an ellipsis.
  final int titleMaxLines;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool destructive;
  final bool enabled;
  final String? semanticLabel;
  final String? semanticHint;
  final EdgeInsetsGeometry padding;

  const HermesListRow({
    required this.title,
    this.titleMaxLines = 2,
    this.icon,
    this.iconColor,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.destructive = false,
    this.enabled = true,
    this.semanticLabel,
    this.semanticHint,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    super.key,
  });

  /// Title text style of a list row. Rows that cannot be a
  /// [HermesListRow] (e.g. an [ExpansionTile] header) use it so they match
  /// their sibling rows.
  static TextStyle? titleStyle(
    ThemeData theme, {
    required Color color,
    bool selected = false,
  }) => theme.textTheme.bodyLarge?.copyWith(
    color: color,
    fontSize: 15,
    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    height: 1.2,
    letterSpacing: -0.1,
  );

  /// Subtitle text style of a list row; see [titleStyle].
  static TextStyle? subtitleStyle(ThemeData theme, {required Color color}) =>
      theme.textTheme.bodySmall?.copyWith(color: color, height: 1.3);

  /// Width of the leading icon slot of a list row.
  static const double leadingExtent = 30;

  /// Gap between the leading icon and the text of a list row.
  static const double leadingGap = 11;

  /// Where the text of a row with a leading icon starts, from the row's
  /// edge: the divider of its section starts there too.
  static const double iconIndent =
      HermesSpace.rowH + leadingExtent + leadingGap;

  /// Gives a [ListTile]-based row (e.g. an [ExpansionTile] header) whose
  /// leading is a [leadingExtent] icon slot the same gap as a
  /// [HermesListRow], so its text starts where the sibling rows' does.
  /// ListTile's default 16 dp gap pushed it to the right.
  static Widget alignTile({required Widget child}) =>
      ListTileTheme.merge(horizontalTitleGap: leadingGap, child: child);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    // A disabled row still reads (3:1 on the bodies of the boxes).
    final disabledInk = HermesLines.of(colors).disabledInk;
    final foreground = !enabled
        ? disabledInk
        : destructive
        ? colors.error
        : colors.textPrimary;
    final secondary = !enabled
        ? disabledInk
        : destructive
        ? colors.error.withValues(alpha: 0.82)
        : colors.textSecondary;
    final effectiveIconColor =
        iconColor ??
        (selected
            ? colors.accentHover
            : destructive
            ? colors.error
            : secondary);

    return Semantics(
      button: onTap != null,
      enabled: enabled,
      selected: selected,
      label: semanticLabel,
      hint: semanticHint,
      child: Material(
        color: selected
            ? colors.accent.withValues(alpha: 0.085)
            : Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: componentMinimumTapTarget + 4,
            ),
            child: Padding(
              padding: padding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (leading != null)
                    leading!
                  else if (icon != null)
                    SizedBox.square(
                      dimension: leadingExtent,
                      child: ExcludeSemantics(
                        child: Icon(icon, size: 21, color: effectiveIconColor),
                      ),
                    ),
                  if (leading != null || icon != null)
                    const SizedBox(width: leadingGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: titleMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle(
                            theme,
                            color: foreground,
                            selected: selected,
                          ),
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: subtitleStyle(theme, color: secondary),
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

class HermesSearchField extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hintText;
  final String clearTooltip;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool enabled;

  const HermesSearchField({
    required this.hintText,
    required this.clearTooltip,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    super.key,
  });

  @override
  State<HermesSearchField> createState() => _HermesSearchFieldState();
}

class _HermesSearchFieldState extends State<HermesSearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onStateChanged);
    _focusNode.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onStateChanged);
    _focusNode.removeListener(_onStateChanged);
    if (widget.controller == null) _controller.dispose();
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  void _clear() {
    _controller.clear();
    widget.onChanged?.call('');
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final profile = theme.hermesComponents.profile;
    final focused = _focusNode.hasFocus;
    final glass = HermesGlassLook.of(context);
    final borderColor = focused
        ? (glass == null
              ? colors.accent.withValues(alpha: 0.48)
              : glass.selectedLine)
        : (glass?.line ?? colors.divider.withValues(alpha: 0.44));

    final fieldRadius = BorderRadius.circular(profile.shape.fieldRadius);
    final field = AnimatedContainer(
      duration: Duration(
        milliseconds: MediaQuery.disableAnimationsOf(context)
            ? 0
            : profile.motion.stateDurationMs.clamp(0, 220),
      ),
      constraints: const BoxConstraints(minHeight: componentMinimumTapTarget),
      // On glass the contour, rims and shadow are the box's finish
      // ([HermesBoxEdges]); the body leaves the pixel of the contour.
      padding: glass == null ? null : const EdgeInsets.all(HermesGel.rimWidth),
      decoration: BoxDecoration(
        color:
            glass?.groupFill ??
            (HermesSoftLight.solid(context)
                ? HermesSoftLight.fill(context)
                : colors.surfaceVariant.withValues(alpha: 0.52)),
        borderRadius: fieldRadius,
        border: glass != null
            ? null
            : Border.all(
                color: borderColor,
                width: focused
                    ? profile.border.emphasizedWidth
                    : profile.border.width,
              ),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        textInputAction: TextInputAction.search,
        style: theme.textTheme.bodyMedium?.copyWith(color: colors.textPrimary),
        decoration: InputDecoration(
          hintText: widget.hintText,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textSecondary,
            fontSize: HermesType.hintSize,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 20,
            color: focused ? colors.accentHover : colors.textSecondary,
          ),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: widget.clearTooltip,
                  onPressed: _clear,
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 13,
          ),
        ),
      ),
    );
    if (glass == null) return field;
    return HermesBoxEdges(
      glass: glass,
      radius: fieldRadius,
      lifted: true,
      compact: true,
      line: focused ? glass.selectedLine : null,
      child: field,
    );
  }
}

@immutable
class HermesSegment<T> {
  final T value;
  final String label;
  final int? count;
  final Key? key;
  final int flex;
  final double horizontalPadding;

  /// A segment that is shown but cannot be chosen right now. A disabled
  /// segment may still be the selected one.
  final bool enabled;

  const HermesSegment({
    required this.value,
    required this.label,
    this.count,
    this.key,
    this.flex = 1,
    this.horizontalPadding = 13,
    this.enabled = true,
  }) : assert(flex > 0),
       assert(horizontalPadding >= 0);
}

class HermesSegmentedControl<T> extends StatelessWidget {
  final T value;
  final List<HermesSegment<T>> segments;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  /// True paints the track as floating chrome: for a view switch that stays
  /// in place over a list scrolling under it.
  final bool floating;

  const HermesSegmentedControl({
    required this.value,
    required this.segments,
    required this.onChanged,
    this.semanticLabel,
    this.floating = false,
    super.key,
  });

  /// Pill: the track and the selected segment are fully round.
  static final BorderRadius pill = BorderRadius.circular(HermesRadius.tag);

  /// The body of the selected segment, a pill: the soft accent fill with the
  /// accent as its border where the theme wears glass ([GlassMaterial.selected]
  /// is certified for the main ink); the raised surface with an accent border
  /// where it does not.
  static BoxDecoration selectedDecoration(
    ThemeData theme,
    GlassMaterial? glass,
  ) {
    final colors = theme.hermes;
    final profile = theme.hermesComponents.profile;
    return BoxDecoration(
      color: glass == null
          ? colors.surface.withValues(alpha: 0.94)
          : glass.selected,
      borderRadius: pill,
      border: Border.all(
        color: glass == null
            ? colors.accent.withValues(alpha: 0.6)
            : glass.selectedLine,
      ),
      boxShadow: glass == null && profile.elevation.resting > 0
          ? [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.13),
                blurRadius: 5,
                offset: const Offset(0, 1),
              ),
            ]
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final useScrollable = scale > 1.35;
    final glass = HermesGlassLook.of(context);
    final selectedIndex = [for (final s in segments) s.value].indexOf(value);
    // The selected pill slides from segment to segment (short, none with
    // reduced motion). With the reader's large text the segments scroll and
    // each one wears its own selected body instead.
    final slides = !useScrollable && selectedIndex >= 0;
    final children = [
      for (final segment in segments)
        _HermesSegmentButton<T>(
          key: segment.key,
          segment: segment,
          selected: segment.value == value,
          glass: glass,
          paintsSelected: !slides,
          onTap: segment.enabled ? () => onChanged(segment.value) : null,
        ),
    ];

    final Widget row = useScrollable
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: children),
          )
        : Row(
            children: [
              for (var index = 0; index < children.length; index++)
                Expanded(flex: segments[index].flex, child: children[index]),
            ],
          );
    final Widget inner = !slides
        ? row
        : LayoutBuilder(
            builder: (context, box) {
              var total = 0;
              var before = 0;
              for (var i = 0; i < segments.length; i++) {
                total += segments[i].flex;
                if (i < selectedIndex) before += segments[i].flex;
              }
              final width = box.maxWidth.isFinite ? box.maxWidth : 0.0;
              return Stack(
                children: [
                  AnimatedPositionedDirectional(
                    key: const ValueKey('hermes-segmented-indicator'),
                    duration: HermesMotion.duration(context, HermesMotion.base),
                    curve: HermesMotion.standard,
                    top: 0,
                    bottom: 0,
                    start: width * before / total,
                    width: width * segments[selectedIndex].flex / total,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: selectedDecoration(theme, glass),
                      ),
                    ),
                  ),
                  row,
                ],
              );
            },
          );
    final track = Padding(padding: const EdgeInsets.all(3), child: inner);
    return Semantics(
      container: true,
      label: semanticLabel,
      child: floating
          // Floating, it is a pill like every other floating piece.
          ? HermesFloatingSurface(
              key: const ValueKey('hermes-segmented-floating'),
              child: track,
            )
          : glass != null
          ? HermesGlassLook.body(
              glass,
              pill,
              fill: glass.pieceFill,
              lifted: true,
              compact: true,
              child: track,
            )
          : DecoratedBox(
              decoration: BoxDecoration(
                color: theme.hermes.surfaceVariant.withValues(alpha: 0.46),
                borderRadius: pill,
              ),
              child: track,
            ),
    );
  }
}

class _HermesSegmentButton<T> extends StatelessWidget {
  final HermesSegment<T> segment;
  final bool selected;
  final VoidCallback? onTap;

  /// The glass the selected segment is lifted out of, if the theme wears any.
  final GlassMaterial? glass;

  /// True: the segment paints its own selected body (the track does not
  /// slide a pill under it).
  final bool paintsSelected;

  const _HermesSegmentButton({
    required this.segment,
    required this.selected,
    required this.onTap,
    this.glass,
    this.paintsSelected = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final profile = theme.hermesComponents.profile;
    final label = segment.count == null
        ? segment.label
        : '${segment.label} ${segment.count}';
    final corner = HermesSegmentedControl.pill;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelLarge?.copyWith(
        color: selected ? colors.textPrimary : colors.textSecondary,
        // The chosen one is bold, in every look.
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        letterSpacing: 0,
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      // Only a segment that cannot be chosen says so; the rest keep the
      // semantics they always had.
      enabled: onTap == null ? false : null,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: corner,
          child: AnimatedContainer(
            duration: Duration(
              milliseconds: MediaQuery.disableAnimationsOf(context)
                  ? 0
                  : profile.motion.stateDurationMs.clamp(0, 220),
            ),
            constraints: const BoxConstraints(
              minHeight: componentMinimumTapTarget - 4,
              minWidth: 92,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: segment.horizontalPadding,
              vertical: 9,
            ),
            decoration: selected && paintsSelected
                ? HermesSegmentedControl.selectedDecoration(theme, glass)
                : BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: corner,
                  ),
            alignment: Alignment.center,
            child: ExcludeSemantics(
              // Only a segment that cannot be chosen is dimmed; every other
              // segment is built exactly as before.
              child: onTap == null ? Opacity(opacity: 0.45, child: text) : text,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bloque editorial para decisiones que requieren contexto y acciones.
///
/// Es deliberadamente presentacional: el consumidor conserva el estado, la
/// autorización y los callbacks. [detail] queda siempre visible si no se
/// proporciona [onExpansionChanged]; con callback, [expanded] lo controla.
class HermesDecisionBlock extends StatelessWidget {
  const HermesDecisionBlock({
    required this.title,
    this.summary,
    this.leading,
    this.status,
    this.detail,
    this.actions = const [],
    this.expanded = false,
    this.onExpansionChanged,
    this.disclosureLabel,
    this.semanticLabel,
    this.semanticHint,
    this.enabled = true,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 10),
    super.key,
  }) : assert(
         onExpansionChanged == null || detail != null,
         'A controlled disclosure requires detail content.',
       ),
       assert(
         onExpansionChanged == null || disclosureLabel != null,
         'A controlled disclosure requires a localized label.',
       );

  final String title;
  final String? summary;
  final Widget? leading;
  final Widget? status;
  final Widget? detail;
  final List<Widget> actions;
  final bool expanded;
  final ValueChanged<bool>? onExpansionChanged;
  final String? disclosureLabel;
  final String? semanticLabel;
  final String? semanticHint;
  final bool enabled;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return _HermesEditorialBlock(
      title: title,
      summary: summary,
      leading: leading,
      status: status,
      detail: detail,
      actions: actions,
      expanded: expanded,
      onExpansionChanged: onExpansionChanged,
      disclosureLabel: disclosureLabel,
      semanticLabel: semanticLabel,
      semanticHint: semanticHint,
      enabled: enabled,
      padding: padding,
      density: _HermesEditorialDensity.decision,
    );
  }
}

/// Fila editorial ligera para actividad técnica o de subagentes.
///
/// Acepta la misma composición controlada que [HermesDecisionBlock], pero con
/// una jerarquía más compacta y las acciones alineadas con el hilo.
class HermesInlineActivity extends StatelessWidget {
  const HermesInlineActivity({
    required this.title,
    this.summary,
    this.titleMaxLines,
    this.summaryMaxLines,
    this.leading,
    this.status,
    this.detail,
    this.actions = const [],
    this.expanded = false,
    this.onExpansionChanged,
    this.disclosureLabel,
    this.semanticLabel,
    this.semanticHint,
    this.enabled = true,
    this.flexibleDetail = false,
    this.flexibleDetailFit = FlexFit.tight,
    this.padding = const EdgeInsets.fromLTRB(12, 4, 12, 6),
    this.floating = false,
    super.key,
  }) : assert(
         onExpansionChanged == null || detail != null,
         'A controlled disclosure requires detail content.',
       ),
       assert(
         onExpansionChanged == null || disclosureLabel != null,
         'A controlled disclosure requires a localized label.',
       );

  final String title;
  final String? summary;
  final int? titleMaxLines;
  final int? summaryMaxLines;
  final Widget? leading;
  final Widget? status;
  final Widget? detail;
  final List<Widget> actions;
  final bool expanded;
  final ValueChanged<bool>? onExpansionChanged;
  final String? disclosureLabel;
  final String? semanticLabel;
  final String? semanticHint;
  final bool enabled;
  final bool flexibleDetail;

  /// How a [flexibleDetail] takes the height left: all of it (tight, the
  /// default) or up to its own size (loose: a card that grows with its
  /// content and scrolls it once the room runs out).
  final FlexFit flexibleDetailFit;
  final EdgeInsetsGeometry padding;

  /// When true, renders as a self-contained floating pill (opaque surface,
  /// rounded shell, soft shadow) instead of the flat inline block, and
  /// cross-fades its text in place when [title]/[summary] change. Used to
  /// host this row as an overlay anchored above other content instead of a
  /// `Column` child, without altering the default flat presentation used
  /// elsewhere.
  final bool floating;

  @override
  Widget build(BuildContext context) {
    return _HermesEditorialBlock(
      title: title,
      summary: summary,
      titleMaxLines: titleMaxLines,
      summaryMaxLines: summaryMaxLines,
      leading: leading,
      status: status,
      detail: detail,
      actions: actions,
      expanded: expanded,
      onExpansionChanged: onExpansionChanged,
      disclosureLabel: disclosureLabel,
      semanticLabel: semanticLabel,
      semanticHint: semanticHint,
      enabled: enabled,
      flexibleDetail: flexibleDetail,
      flexibleDetailFit: flexibleDetailFit,
      padding: padding,
      floating: floating,
      density: _HermesEditorialDensity.activity,
    );
  }
}

/// Cross-fades the header title/summary for the `floating` pill variant of
/// [HermesInlineActivity] (e.g. the rotating "tip" text shown while a
/// subagent works).
///
/// The naive approach — keying the switched child by `'$title|$summary'`
/// alone — breaks when the rotation cycles back to a value that's still
/// fading out from an earlier step: `AnimatedSwitcher`'s custom
/// `layoutBuilder` here stacks `[...previousChildren, ?currentChild]`, and
/// two entries sharing the same `ValueKey` crash with "Duplicate keys
/// found" (surfaced in tests as an uncaught `FlutterError` that aborts the
/// test mid-animation, leaking its `Ticker`/`AnimationController` into
/// later tests in the same run). Tracking a monotonic `_revision` bumped
/// only when the content actually changes keeps every switch's key unique
/// regardless of repeats.
class _HermesRotatingHeaderText extends StatefulWidget {
  const _HermesRotatingHeaderText({
    required this.title,
    required this.summary,
    required this.titleMaxLines,
    required this.summaryMaxLines,
    required this.titleStyle,
    required this.summaryStyle,
    required this.isDecision,
    required this.reduceMotion,
  });

  final String title;
  final String? summary;
  final int? titleMaxLines;
  final int? summaryMaxLines;
  final TextStyle? titleStyle;
  final TextStyle? summaryStyle;
  final bool isDecision;
  final bool reduceMotion;

  @override
  State<_HermesRotatingHeaderText> createState() =>
      _HermesRotatingHeaderTextState();
}

/// One value the rotating header has shown, tracked so a repeat can be
/// told apart from a genuinely new one — see [_HermesRotatingHeaderTextState].
class _HermesRotatingHeaderTextState extends State<_HermesRotatingHeaderText> {
  int _revision = 0;

  @override
  void didUpdateWidget(covariant _HermesRotatingHeaderText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.summary != widget.summary) {
      _revision++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: widget.reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previousChildren, ?currentChild],
      ),
      child: _HermesEditorialHeaderText(
        // Keyed by a monotonic revision (bumped only when content actually
        // changes from the immediately preceding build) rather than by
        // content alone: a rotating tip can legitimately repeat a value
        // while an earlier occurrence of that same text is still fading
        // out, and two Stack children can never share a key. This can
        // still show the same text twice for a brief moment when a value
        // reverts within a couple of rapid, same-frame rebuilds (see the
        // "actividad nativa..." test in chat_screen_test.dart), which is
        // an acceptable, narrow cosmetic tradeoff against ever crashing
        // the tree.
        key: ValueKey('$_revision:${widget.title}|${widget.summary}'),
        title: widget.title,
        summary: widget.summary,
        titleMaxLines: widget.titleMaxLines,
        summaryMaxLines: widget.summaryMaxLines,
        titleStyle: widget.titleStyle,
        summaryStyle: widget.summaryStyle,
        isDecision: widget.isDecision,
      ),
    );
  }
}

enum _HermesEditorialDensity { decision, activity }

class _HermesEditorialBlock extends StatelessWidget {
  const _HermesEditorialBlock({
    required this.title,
    required this.summary,
    this.titleMaxLines,
    this.summaryMaxLines,
    required this.leading,
    required this.status,
    required this.detail,
    required this.actions,
    required this.expanded,
    required this.onExpansionChanged,
    required this.disclosureLabel,
    required this.semanticLabel,
    required this.semanticHint,
    required this.enabled,
    this.flexibleDetail = false,
    this.flexibleDetailFit = FlexFit.tight,
    required this.padding,
    required this.density,
    this.floating = false,
  });

  final String title;
  final String? summary;
  final Widget? leading;
  final Widget? status;
  final Widget? detail;
  final List<Widget> actions;
  final bool expanded;
  final ValueChanged<bool>? onExpansionChanged;
  final String? disclosureLabel;
  final String? semanticLabel;
  final String? semanticHint;
  final bool enabled;
  final bool flexibleDetail;
  final FlexFit flexibleDetailFit;
  final EdgeInsetsGeometry padding;
  final _HermesEditorialDensity density;
  final int? titleMaxLines;
  final int? summaryMaxLines;
  final bool floating;

  bool get _hasDisclosure =>
      detail != null && onExpansionChanged != null && disclosureLabel != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final profile = theme.hermesComponents.profile;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    // A detail that fills the block lays the status over the header; one
    // that only takes its own height keeps the status in the row.
    final overlayStatus =
        status != null && flexibleDetail && flexibleDetailFit == FlexFit.tight;
    final stackStatus = status != null && textScale > 1.3 && !overlayStatus;
    final isDecision = density == _HermesEditorialDensity.decision;
    final showDetail = detail != null && (!_hasDisclosure || expanded);
    final titleStyle =
        (isDecision ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium)
            ?.copyWith(
              color: colors.textPrimary,
              fontSize: isDecision ? 14.5 : 13,
              height: 1.28,
              fontWeight: FontWeight.w600,
              letterSpacing: isDecision ? -0.1 : 0,
            );
    final summaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: colors.textSecondary,
      fontSize: HermesType.subtitleSize,
      height: 1.38,
    );

    Widget header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leading != null) ...[
          SizedBox.square(
            dimension: isDecision ? 32 : 30,
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(
                  size: isDecision ? 21 : 19,
                  color: colors.textSecondary,
                ),
                child: leading!,
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: !floating
              ? _HermesEditorialHeaderText(
                  title: title,
                  summary: summary,
                  titleMaxLines: titleMaxLines,
                  summaryMaxLines: summaryMaxLines,
                  titleStyle: titleStyle,
                  summaryStyle: summaryStyle,
                  isDecision: isDecision,
                )
              : _HermesRotatingHeaderText(
                  title: title,
                  summary: summary,
                  titleMaxLines: titleMaxLines,
                  summaryMaxLines: summaryMaxLines,
                  titleStyle: titleStyle,
                  summaryStyle: summaryStyle,
                  isDecision: isDecision,
                  reduceMotion: reduceMotion,
                ),
        ),
        if (status != null && !stackStatus && !overlayStatus) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Align(
              alignment: AlignmentDirectional.topEnd,
              child: _HermesEditorialStatus(child: status!),
            ),
          ),
        ],
      ],
    );

    if (status != null && stackStatus) {
      header = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 7),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _HermesEditorialStatus(child: status!),
          ),
        ],
      );
    } else if (overlayStatus) {
      header = Stack(
        children: [
          header,
          PositionedDirectional(
            top: 7,
            end: 0,
            child: _HermesEditorialStatus(child: status!),
          ),
        ],
      );
    }

    final content = Semantics(
      container: true,
      explicitChildNodes: true,
      enabled: enabled,
      label: semanticLabel,
      hint: semanticHint,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            header,
            if (_hasDisclosure) ...[
              const SizedBox(height: 4),
              Semantics(
                button: true,
                enabled: enabled,
                expanded: expanded,
                label: disclosureLabel,
                excludeSemantics: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: enabled
                        ? () => onExpansionChanged!.call(!expanded)
                        : null,
                    borderRadius: BorderRadius.circular(
                      profile.shape.fieldRadius,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: componentMinimumTapTarget,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                disclosureLabel!,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            AnimatedRotation(
                              turns: expanded ? 0.5 : 0,
                              duration: reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 160),
                              child: Icon(
                                Icons.expand_more_rounded,
                                size: 19,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (detail != null && flexibleDetail)
              Flexible(
                fit: flexibleDetailFit,
                child: AnimatedSize(
                  duration: reduceMotion ? Duration.zero : Motion.base,
                  curve: Motion.enter,
                  alignment: AlignmentDirectional.topStart,
                  child: showDetail
                      ? Padding(
                          padding: EdgeInsets.only(
                            top: _hasDisclosure ? 2 : 10,
                          ),
                          child: DefaultTextStyle.merge(
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.textSecondary,
                              height: 1.42,
                            ),
                            child: detail!,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              )
            else if (detail != null)
              AnimatedSize(
                duration: reduceMotion ? Duration.zero : Motion.base,
                curve: Motion.enter,
                alignment: AlignmentDirectional.topStart,
                child: showDetail
                    ? Padding(
                        padding: EdgeInsets.only(top: _hasDisclosure ? 2 : 10),
                        child: DefaultTextStyle.merge(
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
                            height: 1.42,
                          ),
                          child: detail!,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                alignment: isDecision ? WrapAlignment.end : WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final action in actions)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: componentMinimumTapTarget,
                        minWidth: componentMinimumTapTarget,
                      ),
                      child: action,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );

    if (!floating) return content;

    // Floating chrome: an opaque, shadowed shell so this row can be
    // anchored as an overlay (e.g. above a chat composer) instead of
    // sitting flat inside a Column. Radius 22 mirrors the app's other
    // floating surfaces and still reads as a pill at a compact height.
    // The shadow lives on an outer, unclipped box so the inner Material's
    // antialiased clip never crops it.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.32),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }
}

class _HermesEditorialHeaderText extends StatelessWidget {
  const _HermesEditorialHeaderText({
    required this.title,
    required this.summary,
    required this.titleMaxLines,
    required this.summaryMaxLines,
    required this.titleStyle,
    required this.summaryStyle,
    required this.isDecision,
    super.key,
  });

  final String title;
  final String? summary;
  final int? titleMaxLines;
  final int? summaryMaxLines;
  final TextStyle? titleStyle;
  final TextStyle? summaryStyle;
  final bool isDecision;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: isDecision,
          child: Text(
            title,
            maxLines: titleMaxLines,
            overflow: titleMaxLines == null ? null : TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        if (summary != null && summary!.trim().isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            summary!,
            maxLines: summaryMaxLines,
            overflow: summaryMaxLines == null ? null : TextOverflow.ellipsis,
            style: summaryStyle,
          ),
        ],
      ],
    );
  }
}

class _HermesEditorialStatus extends StatelessWidget {
  const _HermesEditorialStatus({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DefaultTextStyle.merge(
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: colors.textSecondary,
        fontWeight: FontWeight.w600,
      ),
      child: IconTheme.merge(
        data: IconThemeData(size: 16, color: colors.textSecondary),
        child: child,
      ),
    );
  }
}

/// Texto de estado con una franja de luz lenta, sin duplicar el contenido.
///
/// La animación es puramente visual: TalkBack recibe el [text] una sola vez y
/// `disableAnimations` conserva exactamente el mismo layout con color estático.
class HermesShimmerText extends StatefulWidget {
  const HermesShimmerText(
    this.text, {
    this.style,
    this.enabled = true,
    this.semanticLabel,
    this.period = const Duration(milliseconds: 1800),
    super.key,
  });

  final String text;
  final TextStyle? style;
  final bool enabled;
  final String? semanticLabel;
  final Duration period;

  @override
  State<HermesShimmerText> createState() => _HermesShimmerTextState();
}

class _HermesShimmerTextState extends State<HermesShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.period);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant HermesShimmerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) {
      _controller.duration = widget.period;
    }
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.enabled && !_reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final baseStyle =
        widget.style ??
        Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: colors.textSecondary,
          fontWeight: FontWeight.w600,
        );
    final staticText = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: baseStyle,
    );

    return Semantics(
      label: widget.semanticLabel ?? widget.text,
      excludeSemantics: true,
      child: !widget.enabled || _reduceMotion
          ? staticText
          : RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                child: staticText,
                builder: (context, child) {
                  final position = (_controller.value * 2.4) - 1.2;
                  return ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment(position - 0.75, 0),
                      end: Alignment(position + 0.75, 0),
                      colors: [
                        colors.textSecondary.withValues(alpha: 0.58),
                        colors.textPrimary,
                        colors.textSecondary.withValues(alpha: 0.58),
                      ],
                      stops: const [0.22, 0.5, 0.78],
                    ).createShader(bounds),
                    child: child,
                  );
                },
              ),
            ),
    );
  }
}

/// Superficie compartida del composer de Inicio y Chat.
///
/// La cápsula visible es deliberadamente fina: los controles mantienen su
/// área táctil de 48 dp, pero no se añade relleno vertical alrededor. La doble
/// sombra crea separación real sobre fondos OLED sin dibujar otra tarjeta.
class HermesComposerSurface extends StatelessWidget {
  const HermesComposerSurface({
    required this.child,
    this.focused = false,
    this.padding = EdgeInsets.zero,
    this.unfocusedHorizontalInset = 4,
    this.material,
    super.key,
  }) : assert(unfocusedHorizontalInset >= 0);

  /// How solid the capsule is: what scrolls behind it must not read through
  /// what is written in it. Ola 3 paints it with [HermesChrome.opaque], which
  /// is solid; this stays the floor `chat_bottom_scrim_test` models.
  static const double fillOpacity = 0.97;

  final Widget child;
  final bool focused;
  final EdgeInsetsGeometry padding;
  final double unfocusedHorizontalInset;

  /// Shared edge-only finish. The opaque text surface and its geometry stay
  /// unchanged; null leaves Home and other callers on their existing surface.
  final HermesLiquid? material;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Ola 3 (AUDITORIA-PULIDO T2/T3): the one tone of what floats.
    final chrome = HermesChrome.of(colors);
    final duration = HermesMotion.duration(context, HermesMotion.fast);
    // OPUS-CRISTAL: a piece of the chat foot's toned strip when it sits in
    // one. The strip hands a veil only where its smoked glass reads;
    // otherwise, and anywhere else (Home, rooms, a header's or an overlay's
    // strip), the opaque chrome of before.
    final glass = HermesGlassStrip.toneOf(context);
    final piece = HermesGlassStrip.tonedAround(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(HermesRadius.pane),
    );
    final body = AnimatedContainer(
      key: const ValueKey('hermes-composer-visible-surface'),
      duration: duration,
      curve: HermesMotion.standard,
      constraints: const BoxConstraints(minHeight: HermesSpace.tap),
      padding: padding,
      decoration: BoxDecoration(
        color: glass?.veil ?? chrome.opaque,
        borderRadius: BorderRadius.circular(HermesRadius.pane),
        border: Border.all(
          // Focus still reads: the secondary ink, a hair thicker.
          color: focused
              ? colors.textSecondary.withValues(alpha: 0.58)
              // Over glass the rim is a thin light edge, as on a lit pane.
              : (glass == null ? chrome.line : HermesGlassRim.edgeOf(chrome)),
          width: focused ? 1.15 : 1,
        ),
        // Over the glass a shadow would darken what shows through.
        boxShadow: glass == null ? chrome.shadow : null,
      ),
      child: child,
    );
    // The gel of the buttons (rims and sheen) over the opaque grey fill: the
    // foot is as liquid as the rest, never darker.
    final surface = HermesGelSurface(
      key: const ValueKey('hermes-composer-gel'),
      shape: shape,
      pressable: false,
      sheenScale: HermesGel.textSheenScale(colors),
      child: body,
    );
    final role = material;
    final finished = role == null
        ? surface
        : HermesSheen(liquid: role, shape: shape, child: surface);
    // A veto (policy, a lock) drops the blur in one frame while the fill
    // above eases from the veil to opaque: never a bare veil over sharp
    // text. A base under it turns opaque at once. It sits 1.5 dp inside
    // the outline, so at rest the opaque fill hides it entirely and the
    // fallback paints exactly as before.
    final based = piece
        ? CustomPaint(
            key: const ValueKey('hermes-composer-glass-base'),
            painter: glass == null
                ? _OpaqueBase(chrome.opaque, HermesRadius.pane)
                : null,
            child: finished,
          )
        : finished;
    return AnimatedPadding(
      duration: duration,
      curve: HermesMotion.standard,
      padding: EdgeInsets.symmetric(
        horizontal: focused ? 0 : unfocusedHorizontalInset,
      ),
      child: piece ? HermesGlassPiece(shape: shape, child: based) : finished,
    );
  }
}

/// The composer's opaque base under a fading fill (OPUS-CRISTAL).
class _OpaqueBase extends CustomPainter {
  const _OpaqueBase(this.color, this.radius);

  final Color color;
  final double radius;

  static const double inset = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius - inset)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_OpaqueBase oldDelegate) =>
      color != oldDelegate.color || radius != oldDelegate.radius;
}

enum HermesTactileActionVisual { filled, quiet }

/// Acción circular con respuesta táctil de profundidad y luz.
///
/// En reposo no mantiene ticker. Al pulsar comprime el gel un 4 %, reduce el
/// resplandor y desplaza el brillo (`HermesGelSurface`); con reducir movimiento cambia
/// de estado sin interpolación.
class HermesTactileAction extends StatefulWidget {
  const HermesTactileAction({
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    this.onLongPress,
    this.backgroundColor,
    this.foregroundColor,
    this.size = 44,
    this.iconSize = 21,
    this.enabled = true,
    this.visual = HermesTactileActionVisual.filled,
    super.key,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double size;
  final double iconSize;
  final bool enabled;
  final HermesTactileActionVisual visual;

  @override
  State<HermesTactileAction> createState() => _HermesTactileActionState();
}

class _HermesTactileActionState extends State<HermesTactileAction> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final enabled = widget.enabled && widget.onPressed != null;
    final hitExtent = widget.size < 48 ? 48.0 : widget.size;
    final background =
        widget.backgroundColor ??
        (enabled ? colors.accent : colors.surfaceVariant);
    final foreground =
        widget.foregroundColor ??
        (enabled ? colors.onAccent : colors.textDisabled);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 150);
    final quiet = widget.visual == HermesTactileActionVisual.quiet;
    // The filled, enabled action is the accent gel: gradient, glow and sheen.
    final gel = !quiet && enabled && background.a >= 0.5;

    final content = AnimatedOpacity(
      opacity: quiet && _pressed && enabled ? 0.68 : 1,
      duration: duration,
      child: Center(
        child: AnimatedSlide(
          duration: duration,
          offset: _pressed && enabled ? const Offset(0, 0.04) : Offset.zero,
          child: ExcludeSemantics(
            child: Icon(widget.icon, size: widget.iconSize, color: foreground),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: Tooltip(
        message: widget.semanticLabel,
        child: SizedBox.square(
          dimension: hitExtent,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              canRequestFocus: enabled,
              focusColor: foreground.withValues(alpha: 0.18),
              onHighlightChanged: enabled ? _setPressed : null,
              onTap: enabled ? widget.onPressed : null,
              onLongPress: enabled ? widget.onLongPress : null,
              child: Center(
                child: AnimatedScale(
                  scale: _pressed && enabled ? HermesGel.pressScale : 1,
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: duration,
                    width: widget.size,
                    height: widget.size,
                    decoration: quiet || gel
                        ? null
                        : BoxDecoration(
                            shape: BoxShape.circle,
                            color: background,
                            border: Border.all(
                              color: colors.divider.withValues(alpha: 0.45),
                            ),
                          ),
                    child: gel
                        ? HermesGelSurface(
                            accent: background,
                            ink: foreground,
                            tone: HermesGelTone.accent,
                            pressed: _pressed,
                            child: content,
                          )
                        : quiet
                        ? content
                        // A filled action that cannot be used keeps the
                        // gel's rims and sheen over its flat disc.
                        : HermesGelSurface(
                            key: const ValueKey('hermes-tactile-gel-idle'),
                            enabled: false,
                            pressable: false,
                            child: content,
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
