import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/component_profile.dart';

/// Abre una superficie modal centrada sin depender de `showDialog`.
///
/// La ruta conserva un [FocusScopeNode] propio y lo libera antes de cerrarse.
/// Esto permite alojar buscadores y editores sin mantener un `EditableText`
/// enlazado al overlay que ya se está desmontando. La geometría es la misma en
/// móvil y tablet: margen seguro, ancho acotado y scroll a cargo del contenido.
Future<T?> showHermesFloatingSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Key surfaceKey = const ValueKey('hermes-floating-surface'),
  double maxWidth = 560,
  double maxHeightFactor = 0.88,
  bool barrierDismissible = true,
  bool systemDismissible = true,
  bool useRootNavigator = false,
}) {
  assert(maxWidth > 0);
  assert(maxHeightFactor > 0 && maxHeightFactor <= 1);
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final focusScopeNode = FocusScopeNode(debugLabel: 'HermesFloatingSurface');
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _HermesFloatingSurfaceRoute<T>(
      builder: builder,
      focusScopeNode: focusScopeNode,
      surfaceKey: surfaceKey,
      maxWidth: maxWidth,
      maxHeightFactor: maxHeightFactor,
      barrierDismissible: barrierDismissible,
      systemDismissible: systemDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: reduceMotion,
    ),
  );
}

class _HermesFloatingSurfaceRoute<T> extends PageRouteBuilder<T> {
  _HermesFloatingSurfaceRoute({
    required WidgetBuilder builder,
    required FocusScopeNode focusScopeNode,
    required Key surfaceKey,
    required double maxWidth,
    required double maxHeightFactor,
    required super.barrierDismissible,
    required bool systemDismissible,
    required String barrierLabel,
    required bool reduceMotion,
  }) : _focusScopeNode = focusScopeNode,
       super(
         opaque: false,
         barrierColor: Colors.black.withValues(alpha: 0.56),
         barrierLabel: barrierLabel,
         maintainState: true,
         transitionDuration: reduceMotion
             ? Duration.zero
             : const Duration(milliseconds: 220),
         reverseTransitionDuration: reduceMotion
             ? Duration.zero
             : const Duration(milliseconds: 170),
         pageBuilder: (context, animation, secondaryAnimation) => PopScope(
           canPop: systemDismissible,
           child: FocusScope(
             node: focusScopeNode,
             child: _HermesFloatingSurfaceFrame(
               surfaceKey: surfaceKey,
               maxWidth: maxWidth,
               maxHeightFactor: maxHeightFactor,
               reduceMotion: reduceMotion,
               child: builder(context),
             ),
           ),
         ),
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           if (reduceMotion) return child;
           final curved = CurvedAnimation(
             parent: animation,
             curve: Curves.easeOutCubic,
             reverseCurve: Curves.easeInCubic,
           );
           return FadeTransition(
             opacity: curved,
             child: ScaleTransition(
               scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
               child: child,
             ),
           );
         },
       );

  final FocusScopeNode _focusScopeNode;

  @override
  bool didPop(T? result) {
    _focusScopeNode.unfocus(disposition: UnfocusDisposition.scope);
    return super.didPop(result);
  }

  @override
  void dispose() {
    _focusScopeNode.dispose();
    super.dispose();
  }
}

class _HermesFloatingSurfaceFrame extends StatelessWidget {
  const _HermesFloatingSurfaceFrame({
    required this.surfaceKey,
    required this.maxWidth,
    required this.maxHeightFactor,
    required this.reduceMotion,
    required this.child,
  });

  final Key surfaceKey;
  final double maxWidth;
  final double maxHeightFactor;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight =
        media.size.height -
        media.viewInsets.bottom -
        media.padding.vertical -
        32;
    final maxHeight = availableHeight <= 0
        ? 0.0
        : availableHeight * maxHeightFactor;
    final theme = Theme.of(context);
    final shape =
        theme.dialogTheme.shape ??
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(22));

    return AnimatedPadding(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: Material(
              key: surfaceKey,
              color: theme.dialogTheme.backgroundColor,
              surfaceTintColor: Colors.transparent,
              elevation: theme.dialogTheme.elevation ?? 12,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ),
      ),
    );
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

  const HermesListSection({
    required this.children,
    this.title,
    this.trailing,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
    this.titlePadding = const EdgeInsets.fromLTRB(4, 16, 4, 8),
    this.showDividers = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final profile = theme.hermesComponents.profile;
    final rows = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      rows.add(children[index]);
      if (showDividers && index < children.length - 1) {
        rows.add(
          Divider(
            height: 1,
            thickness: profile.border.width,
            indent: 54,
            color: colors.divider.withValues(alpha: 0.62),
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
                          title!,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: colors.textSecondary,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
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
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceVariant.withValues(alpha: 0.42),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final foreground = !enabled
        ? colors.textDisabled
        : destructive
        ? colors.error
        : colors.textPrimary;
    final secondary = !enabled
        ? colors.textDisabled
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
                      dimension: 30,
                      child: ExcludeSemantics(
                        child: Icon(icon, size: 21, color: effectiveIconColor),
                      ),
                    ),
                  if (leading != null || icon != null)
                    const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: foreground,
                            fontSize: 15,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            height: 1.2,
                            letterSpacing: -0.1,
                          ),
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: secondary,
                              height: 1.3,
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
    final borderColor = focused
        ? colors.accent.withValues(alpha: 0.48)
        : colors.divider.withValues(alpha: 0.44);

    return AnimatedContainer(
      duration: Duration(
        milliseconds: MediaQuery.disableAnimationsOf(context)
            ? 0
            : profile.motion.stateDurationMs.clamp(0, 220),
      ),
      constraints: const BoxConstraints(minHeight: componentMinimumTapTarget),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(profile.shape.fieldRadius),
        border: Border.all(
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

  const HermesSegment({
    required this.value,
    required this.label,
    this.count,
    this.key,
    this.flex = 1,
    this.horizontalPadding = 13,
  }) : assert(flex > 0),
       assert(horizontalPadding >= 0);
}

class HermesSegmentedControl<T> extends StatelessWidget {
  final T value;
  final List<HermesSegment<T>> segments;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  const HermesSegmentedControl({
    required this.value,
    required this.segments,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final useScrollable = scale > 1.35;
    final children = [
      for (final segment in segments)
        _HermesSegmentButton<T>(
          key: segment.key,
          segment: segment,
          selected: segment.value == value,
          onTap: () => onChanged(segment.value),
        ),
    ];

    return Semantics(
      container: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).hermes.surfaceVariant.withValues(alpha: 0.46),
          borderRadius: BorderRadius.circular(
            Theme.of(context).hermesComponents.profile.shape.fieldRadius,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: useScrollable
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: children),
                )
              : Row(
                  children: [
                    for (var index = 0; index < children.length; index++)
                      Expanded(
                        flex: segments[index].flex,
                        child: children[index],
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _HermesSegmentButton<T> extends StatelessWidget {
  final HermesSegment<T> segment;
  final bool selected;
  final VoidCallback onTap;

  const _HermesSegmentButton({
    required this.segment,
    required this.selected,
    required this.onTap,
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

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(profile.shape.fieldRadius - 3),
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
            decoration: BoxDecoration(
              color: selected
                  ? colors.surface.withValues(alpha: 0.94)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(
                profile.shape.fieldRadius - 3,
              ),
              boxShadow: selected && profile.elevation.resting > 0
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.13),
                        blurRadius: 5,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: ExcludeSemantics(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected ? colors.textPrimary : colors.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
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
class _HermesRotatingHeaderTextState
    extends State<_HermesRotatingHeaderText> {
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
    final overlayStatus = status != null && flexibleDetail;
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
      fontSize: isDecision ? 12.5 : 11.5,
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
              Expanded(
                child: AnimatedSize(
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
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
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
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
          : AnimatedBuilder(
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
    super.key,
  }) : assert(unfocusedHorizontalInset >= 0);

  final Widget child;
  final bool focused;
  final EdgeInsetsGeometry padding;
  final double unfocusedHorizontalInset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return AnimatedPadding(
      duration: duration,
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.symmetric(
        horizontal: focused ? 0 : unfocusedHorizontalInset,
      ),
      child: AnimatedContainer(
        key: const ValueKey('hermes-composer-visible-surface'),
        duration: duration,
        curve: Curves.easeOutCubic,
        constraints: const BoxConstraints(minHeight: 48),
        padding: padding,
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withValues(alpha: 0.90),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: focused
                ? colors.textSecondary.withValues(alpha: 0.58)
                : colors.divider.withValues(alpha: 0.48),
            width: focused ? 1.15 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.38),
              blurRadius: 22,
              spreadRadius: -4,
              offset: const Offset(0, 9),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

enum HermesTactileActionVisual { filled, quiet }

/// Acción circular con respuesta táctil de profundidad y luz.
///
/// En reposo no mantiene ticker. Al pulsar comprime dos puntos, reduce la
/// sombra y desplaza ligeramente el highlight; con reducir movimiento cambia
/// de estado sin interpolación.
class HermesTactileAction extends StatefulWidget {
  const HermesTactileAction({
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
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
              child: Center(
                child: AnimatedScale(
                  scale: _pressed && enabled ? 0.94 : 1,
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: duration,
                    width: widget.size,
                    height: widget.size,
                    decoration: quiet
                        ? null
                        : BoxDecoration(
                            shape: BoxShape.circle,
                            color: background,
                            border: Border.all(
                              color: enabled
                                  ? Colors.white.withValues(
                                      alpha: _pressed ? 0.16 : 0.08,
                                    )
                                  : colors.divider.withValues(alpha: 0.45),
                            ),
                            boxShadow: enabled
                                ? [
                                    BoxShadow(
                                      color: background.withValues(
                                        alpha: _pressed ? 0.14 : 0.28,
                                      ),
                                      blurRadius: _pressed ? 5 : 11,
                                      offset: Offset(0, _pressed ? 1 : 4),
                                    ),
                                  ]
                                : null,
                          ),
                    child: AnimatedOpacity(
                      opacity: quiet && _pressed && enabled ? 0.68 : 1,
                      duration: duration,
                      child: Center(
                        child: AnimatedSlide(
                          duration: duration,
                          offset: _pressed && enabled
                              ? const Offset(0, 0.04)
                              : Offset.zero,
                          child: ExcludeSemantics(
                            child: Icon(
                              widget.icon,
                              size: widget.iconSize,
                              color: foreground,
                            ),
                          ),
                        ),
                      ),
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
