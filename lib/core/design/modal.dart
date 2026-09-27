import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/scroll_behavior.dart';
import 'tokens.dart';

// ── The ONE modal container ────────────────────────────────────────────────

/// Floating modal surface (spec 080). Never a bottom sheet
/// (`test/no_bottom_sheet_contract_test.dart`).
///
/// * Rounded 22, content-sized, capped at [maxHeightFactor] of the free
///   height (70 % by default: pickers never go full screen).
/// * Anchored popover under/over its origin when [anchorKey] or [originRect]
///   is given, centred otherwise.
/// * Scrim; tap-out dismisses when [barrierDismissible].
/// * IME and safe-area aware; scrollables inside clamp (no bounce).
Future<T?> showHermesSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Key surfaceKey = const ValueKey('hermes-floating-surface'),
  double maxWidth = 560,
  double maxHeightFactor = 0.7,
  bool barrierDismissible = true,
  bool systemDismissible = true,
  bool useRootNavigator = false,
  GlobalKey? anchorKey,
  Rect? originRect,
}) {
  assert(maxWidth > 0);
  assert(maxHeightFactor > 0 && maxHeightFactor <= 1);
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final focusScopeNode = FocusScopeNode(debugLabel: 'HermesFloatingSurface');
  Rect? origin = originRect;
  if (origin == null && anchorKey != null) {
    final box = anchorKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      origin = box.localToGlobal(Offset.zero) & box.size;
    }
  }
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _HermesSurfaceRoute<T>(
      builder: builder,
      focusScopeNode: focusScopeNode,
      surfaceKey: surfaceKey,
      maxWidth: maxWidth,
      maxHeightFactor: maxHeightFactor,
      barrierDismissible: barrierDismissible,
      systemDismissible: systemDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: reduceMotion,
      origin: origin,
    ),
  );
}

/// Global rect of the widget that owns [context] (for anchored surfaces).
Rect? hermesOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _HermesSurfaceRoute<T> extends PageRouteBuilder<T> {
  _HermesSurfaceRoute({
    required WidgetBuilder builder,
    required FocusScopeNode focusScopeNode,
    required Key surfaceKey,
    required double maxWidth,
    required double maxHeightFactor,
    required super.barrierDismissible,
    required bool systemDismissible,
    required String barrierLabel,
    required bool reduceMotion,
    required Rect? origin,
  }) : _focusScopeNode = focusScopeNode,
       super(
         opaque: false,
         barrierColor: Colors.black.withValues(alpha: 0.5),
         barrierLabel: barrierLabel,
         maintainState: true,
         transitionDuration: reduceMotion
             ? Duration.zero
             : const Duration(milliseconds: 200),
         reverseTransitionDuration: reduceMotion
             ? Duration.zero
             : const Duration(milliseconds: 150),
         pageBuilder: (context, animation, secondaryAnimation) => PopScope(
           canPop: systemDismissible,
           child: FocusScope(
             node: focusScopeNode,
             child: HermesModalScrollScope(
               child: _HermesSurfaceFrame(
                 surfaceKey: surfaceKey,
                 maxWidth: maxWidth,
                 maxHeightFactor: maxHeightFactor,
                 reduceMotion: reduceMotion,
                 origin: origin,
                 child: Builder(builder: builder),
               ),
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
               scale: Tween<double>(
                 begin: origin == null ? 0.97 : 0.92,
                 end: 1,
               ).animate(curved),
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

/// Pure geometry of an anchored surface, in global coordinates.
@visibleForTesting
Rect hermesAnchoredSurfaceRect({
  required Size screen,
  required EdgeInsets safe,
  required double keyboard,
  required Rect origin,
  required double width,
  required double height,
  double gap = 8,
  double margin = 12,
}) {
  final top = safe.top + margin;
  final bottom = screen.height - math.max(safe.bottom, keyboard) - margin;
  var left = origin.center.dx - width / 2;
  // Prefer aligning to the origin's leading edge for wide origins (rows).
  if (origin.width >= width) left = origin.left;
  left = left.clamp(margin, math.max(margin, screen.width - width - margin));
  final spaceBelow = bottom - origin.bottom - gap;
  final spaceAbove = origin.top - gap - top;
  double y;
  if (height <= spaceBelow || spaceBelow >= spaceAbove) {
    y = origin.bottom + gap;
  } else {
    y = origin.top - gap - height;
  }
  y = y.clamp(top, math.max(top, bottom - height));
  return Rect.fromLTWH(left, y, width, math.min(height, bottom - top));
}

class _HermesSurfaceFrame extends StatelessWidget {
  const _HermesSurfaceFrame({
    required this.surfaceKey,
    required this.maxWidth,
    required this.maxHeightFactor,
    required this.reduceMotion,
    required this.origin,
    required this.child,
  });

  final Key surfaceKey;
  final double maxWidth;
  final double maxHeightFactor;
  final bool reduceMotion;
  final Rect? origin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final keyboard = media.viewInsets.bottom;
    final free =
        media.size.height -
        math.max(media.padding.bottom, keyboard) -
        media.padding.top -
        32;
    final maxHeight = free <= 0 ? 0.0 : free * maxHeightFactor;
    final width = math.min(maxWidth, media.size.width - 32);
    final surface = Material(
      key: surfaceKey,
      color: theme.dialogTheme.backgroundColor ?? colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: .5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.floating),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
        child: child,
      ),
    );
    final anchor = origin;
    if (anchor == null) {
      return AnimatedPadding(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboard),
        child: SafeArea(
          minimum: const EdgeInsets.all(16),
          child: Center(child: surface),
        ),
      );
    }
    return CustomSingleChildLayout(
      delegate: _AnchoredLayout(
        origin: anchor,
        safe: media.padding,
        keyboard: keyboard,
      ),
      child: surface,
    );
  }
}

class _AnchoredLayout extends SingleChildLayoutDelegate {
  _AnchoredLayout({
    required this.origin,
    required this.safe,
    required this.keyboard,
  });

  final Rect origin;
  final EdgeInsets safe;
  final double keyboard;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      hermesAnchoredSurfaceRect(
        screen: size,
        safe: safe,
        keyboard: keyboard,
        origin: origin,
        width: childSize.width,
        height: childSize.height,
      ).topLeft;

  @override
  bool shouldRelayout(_AnchoredLayout old) =>
      old.origin != origin || old.safe != safe || old.keyboard != keyboard;
}

// ── Surface header ─────────────────────────────────────────────────────────

/// Title line of a floating surface (17 w600 textPrimary) with optional close.
class HermesSurfaceHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showClose;
  final List<Widget> actions;

  const HermesSurfaceHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showClose = false,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, showClose ? 8 : 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: HermesType.title.copyWith(color: colors.textPrimary),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...actions,
          if (showClose)
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }
}

// ── Option list ────────────────────────────────────────────────────────────

class HermesOption<T> {
  final T value;
  final String label;
  final String? subtitle;

  /// Group header (for example a provider). Consecutive equal groups share
  /// one header.
  final String? group;
  final IconData? icon;
  final Key? key;
  final bool enabled;

  const HermesOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.group,
    this.icon,
    this.key,
    this.enabled = true,
  });
}

/// Floating option list: check on the selected option, optional groups,
/// search when there are more than [searchThreshold] options.
Future<T?> showHermesOptions<T>({
  required BuildContext context,
  required List<HermesOption<T>> options,
  T? selected,
  String? title,
  String? subtitle,
  Key surfaceKey = const ValueKey('hermes-option-surface'),
  GlobalKey? anchorKey,
  Rect? originRect,
  int searchThreshold = 8,
  double maxWidth = 420,
  bool Function(T a, T b)? equals,
}) => showHermesSurface<T>(
  context: context,
  surfaceKey: surfaceKey,
  anchorKey: anchorKey,
  originRect: originRect,
  maxWidth: maxWidth,
  builder: (context) => HermesOptionList<T>(
    options: options,
    selected: selected,
    title: title,
    subtitle: subtitle,
    searchable: options.length > searchThreshold,
    equals: equals,
    onSelected: (value) => Navigator.of(context).pop(value),
  ),
);

class HermesOptionList<T> extends StatefulWidget {
  final List<HermesOption<T>> options;
  final T? selected;
  final String? title;
  final String? subtitle;
  final bool searchable;
  final ValueChanged<T> onSelected;
  final bool Function(T a, T b)? equals;

  const HermesOptionList({
    super.key,
    required this.options,
    required this.onSelected,
    this.selected,
    this.title,
    this.subtitle,
    this.searchable = false,
    this.equals,
  });

  @override
  State<HermesOptionList<T>> createState() => _HermesOptionListState<T>();
}

class _HermesOptionListState<T> extends State<HermesOptionList<T>> {
  String _query = '';

  bool _isSelected(T value) {
    final selected = widget.selected;
    if (selected == null) return false;
    return widget.equals?.call(value, selected) ?? value == selected;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? widget.options
        : widget.options
              .where(
                (o) =>
                    o.label.toLowerCase().contains(q) ||
                    (o.subtitle?.toLowerCase().contains(q) ?? false) ||
                    (o.group?.toLowerCase().contains(q) ?? false),
              )
              .toList();
    final rows = <Widget>[];
    String? lastGroup;
    for (final option in visible) {
      if (option.group != null && option.group != lastGroup) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              option.group!.toUpperCase(),
              style: HermesType.caption.copyWith(color: colors.textSecondary),
            ),
          ),
        );
      }
      lastGroup = option.group;
      final isSelected = _isSelected(option.value);
      rows.add(
        Semantics(
          selected: isSelected,
          button: true,
          child: InkWell(
            key: option.key,
            onTap: option.enabled
                ? () => widget.onSelected(option.value)
                : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 50),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    if (option.icon != null) ...[
                      Icon(option.icon, size: 20, color: colors.textSecondary),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            option.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.body.copyWith(
                              color: option.enabled
                                  ? colors.textPrimary
                                  : colors.textDisabled,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          if (option.subtitle != null &&
                              option.subtitle!.isNotEmpty)
                            Text(
                              option.subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: HermesType.support.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 20,
                      child: isSelected
                          ? Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: colors.accentText,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            s.designNoMatches,
            textAlign: TextAlign.center,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title != null)
          HermesSurfaceHeader(title: widget.title!, subtitle: widget.subtitle),
        if (widget.searchable)
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              widget.title == null ? 14 : 2,
              16,
              6,
            ),
            child: TextField(
              key: const ValueKey('hermes-option-search'),
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: s.designSearch,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor: colors.surfaceVariant.withValues(alpha: .6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HermesRadius.control),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        Flexible(
          child: ListView(
            key: const ValueKey('hermes-option-list'),
            shrinkWrap: true,
            padding: EdgeInsets.only(
              top: widget.title == null && !widget.searchable ? 8 : 0,
              bottom: 8,
            ),
            children: rows,
          ),
        ),
      ],
    );
  }
}

// ── Action list / menu ─────────────────────────────────────────────────────

class HermesAction<T> {
  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;
  final Key? key;

  const HermesAction({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
    this.key,
  });
}

/// Popover menu anchored to its button: 48 dp rows, destructive last in red.
/// Intended for ≤ 6 actions.
Future<T?> showHermesMenu<T>({
  required BuildContext context,
  required List<HermesAction<T>> actions,
  GlobalKey? anchorKey,
  Rect? originRect,
  Key surfaceKey = const ValueKey('hermes-menu'),
  String? title,
}) {
  final ordered = [
    ...actions.where((a) => !a.destructive),
    ...actions.where((a) => a.destructive),
  ];
  return showHermesSurface<T>(
    context: context,
    surfaceKey: surfaceKey,
    anchorKey: anchorKey,
    originRect:
        originRect ?? (anchorKey == null ? hermesOriginOf(context) : null),
    maxWidth: 280,
    builder: (context) {
      final colors = Theme.of(context).hermes;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) HermesSurfaceHeader(title: title),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (var i = 0; i < ordered.length; i++) ...[
                  if (ordered[i].destructive &&
                      i > 0 &&
                      !ordered[i - 1].destructive)
                    Divider(
                      height: 9,
                      indent: 16,
                      endIndent: 16,
                      color: HermesSurfaces.divider(colors),
                    ),
                  InkWell(
                    key: ordered[i].key,
                    onTap: () => Navigator.of(context).pop(ordered[i].value),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Row(
                          children: [
                            if (ordered[i].icon != null) ...[
                              Icon(
                                ordered[i].icon,
                                size: 20,
                                color: ordered[i].destructive
                                    ? colors.error
                                    : colors.textSecondary,
                              ),
                              const SizedBox(width: 14),
                            ],
                            Expanded(
                              child: Text(
                                ordered[i].label,
                                style: HermesType.body.copyWith(
                                  color: ordered[i].destructive
                                      ? colors.error
                                      : colors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );
}

// ── Dialog ─────────────────────────────────────────────────────────────────

enum HermesDialogActionStyle { cancel, primary, destructive }

class HermesDialogAction<T> {
  final String label;
  final T value;
  final HermesDialogActionStyle style;
  final Key? key;

  const HermesDialogAction({
    required this.label,
    required this.value,
    this.style = HermesDialogActionStyle.primary,
    this.key,
  });
}

/// Confirm/decide only: title 17 w600, message 14, 48 dp pill actions,
/// destructive in red. No long text, no forms.
Future<T?> showHermesDialog<T>({
  required BuildContext context,
  required String title,
  required List<HermesDialogAction<T>> actions,
  String? message,
  Key surfaceKey = const ValueKey('hermes-dialog'),
  bool useRootNavigator = false,
}) => showHermesSurface<T>(
  context: context,
  surfaceKey: surfaceKey,
  maxWidth: 400,
  maxHeightFactor: 0.6,
  useRootNavigator: useRootNavigator,
  builder: (context) {
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
              style: HermesType.title.copyWith(color: colors.textPrimary),
            ),
          ),
          if (message != null && message.isNotEmpty) ...[
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  message,
                  style: HermesType.text.copyWith(color: colors.textSecondary),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final action in actions)
                _DialogPill(
                  key: action.key,
                  label: action.label,
                  style: action.style,
                  onTap: () => Navigator.of(context).pop(action.value),
                ),
            ],
          ),
        ],
      ),
    );
  },
);

class _DialogPill extends StatelessWidget {
  final String label;
  final HermesDialogActionStyle style;
  final VoidCallback onTap;

  const _DialogPill({
    super.key,
    required this.label,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final (Color? bg, Color fg) = switch (style) {
      HermesDialogActionStyle.cancel => (null, colors.textPrimary),
      HermesDialogActionStyle.primary => (colors.accent, colors.onAccent),
      HermesDialogActionStyle.destructive => (
        colors.error,
        ThemeData.estimateBrightnessForColor(colors.error) == Brightness.dark
            ? Colors.white
            : Colors.black,
      ),
    };
    return Material(
      color: bg ?? Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: bg == null ? 16 : 22),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: bg == null ? FontWeight.w500 : FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Model picker ───────────────────────────────────────────────────────────

/// A provider and its models, the common shape of every model catalog.
class HermesModelGroup {
  final String slug;
  final String name;
  final List<String> models;

  const HermesModelGroup({
    required this.slug,
    required this.name,
    required this.models,
  });
}

/// A picked model. [isDefault] means "use the default" (profile/server).
class HermesModelChoice {
  final String provider;
  final String model;
  final bool isDefault;

  const HermesModelChoice(this.provider, this.model) : isDefault = false;
  const HermesModelChoice.defaultModel()
    : provider = '',
      model = '',
      isDefault = true;

  @override
  bool operator ==(Object other) =>
      other is HermesModelChoice &&
      other.isDefault == isDefault &&
      other.provider == provider &&
      other.model == model;

  @override
  int get hashCode => Object.hash(provider, model, isDefault);
}

/// The ONE model picker: floating, search, provider groups, check, optional
/// "Default" row. [keyPrefix] keeps per-screen test keys stable
/// (`$keyPrefix-$provider-$model`).
Future<HermesModelChoice?> showHermesModelPicker({
  required BuildContext context,
  required List<HermesModelGroup> groups,
  HermesModelChoice? current,
  String? defaultLabel,
  String? defaultSubtitle,
  String? title,
  String? subtitle,
  Key surfaceKey = const ValueKey('hermes-model-picker'),
  String keyPrefix = 'hermes-model',
  GlobalKey? anchorKey,
  Rect? originRect,
}) {
  final options = <HermesOption<HermesModelChoice>>[
    if (defaultLabel != null)
      HermesOption(
        key: ValueKey('$keyPrefix-default'),
        value: const HermesModelChoice.defaultModel(),
        label: defaultLabel,
        subtitle: defaultSubtitle,
        icon: Icons.auto_mode_rounded,
      ),
    for (final group in groups)
      for (final model in group.models)
        HermesOption(
          key: ValueKey('$keyPrefix-${group.slug}-$model'),
          value: HermesModelChoice(group.slug, model),
          label: model,
          group: group.name.isEmpty ? group.slug : group.name,
        ),
  ];
  return showHermesOptions<HermesModelChoice>(
    context: context,
    options: options,
    selected: current,
    title: title,
    subtitle: subtitle,
    surfaceKey: surfaceKey,
    anchorKey: anchorKey,
    originRect: originRect,
    maxWidth: 480,
    // A model matches on name when the current value has no provider.
    equals: (a, b) =>
        a == b ||
        (!a.isDefault &&
            !b.isDefault &&
            b.provider.isEmpty &&
            a.model == b.model),
  );
}
