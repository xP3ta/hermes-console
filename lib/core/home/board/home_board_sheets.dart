/// Surfaces of the Home board's edit mode: «Añadir widget» (what fits, at
/// the sizes that fit), a widget's settings, the widgets that do not fit
/// on this screen, and the controls they share (the occupancy meter, the
/// size control).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/soft_tokens.dart';
import '../../widgets/hermes_premium_ui.dart' show showHermesFloatingSurface;
import 'home_board_catalog.dart';
import 'home_board_data.dart';
import 'home_board_kit.dart';
import 'home_board_model.dart';
import 'home_board_tiles.dart';

/// The board's floating surface (the app's one modal container, never a
/// bottom sheet): content-capped, scrollable, on the widgets' surface.
Future<T?> _sheet<T>(BuildContext context, WidgetBuilder builder) =>
    showHermesFloatingSurface<T>(
      context: context,
      maxHeightFactor: 0.9,
      builder: (context) => ColoredBox(
        color: SoftPalette.ofContext(context).surface,
        child: builder(context),
      ),
    );

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title, {this.trailing, this.onClose});
  final String title;
  final Widget? trailing;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HomeType.title(p),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Padding(padding: const EdgeInsets.only(right: 8), child: trailing),
          ],
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: DecoratedBox(
                decoration: ShapeDecoration(
                  color: p.inset,
                  shape: const CircleBorder(),
                ),
                child: SizedBox.square(
                  dimension: 32,
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: p.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// How full the board is: one pip per slot, and «Lleno» or the free slots
/// in words. When some widgets do not fit it also says how many, and
/// [onTap] opens them.
class HomeBoardMeter extends StatelessWidget {
  const HomeBoardMeter({
    super.key,
    required this.plan,
    this.onTap,
    this.compact = false,
  });
  final HomeBoardPlan plan;
  final VoidCallback? onTap;
  final bool compact;

  /// «Lleno», «1 hueco», and «+2» for what does not fit.
  static String label(Strings s, HomeBoardPlan plan) => [
    plan.full ? s.hwBoardFull : s.hwBoardFree(plan.free),
    if (plan.hidden.isNotEmpty) '+${plan.hidden.length}',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final accent = HomeType.live(p);
    final capacity = plan.capacity;
    final text = label(s, plan);
    final meter = compact
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 32,
                child: SoftCapsuleBar(
                  value: plan.used / capacity,
                  color: accent,
                  track: p.track,
                ),
              ),
              const SizedBox(width: 6),
              Text('${plan.used}/$capacity', style: HomeType.when(p)),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 52,
                child: SoftCapsuleBar(
                  value: plan.used / capacity,
                  color: accent,
                  track: p.track,
                ),
              ),
              const SizedBox(width: 8),
              // What the bar is about: how much room is left. The slots
              // used and the total are in its semantics label.
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: MediaQuery.textScalerOf(
                    context,
                  ).clamp(maxScaleFactor: 1.3),
                  style: HomeType.when(
                    p,
                  ).copyWith(color: plan.full ? accent : p.textMuted),
                ),
              ),
            ],
          );
    return Semantics(
      button: onTap != null,
      label: '${s.hwBoardSlots(plan.used, capacity)}, $text',
      excludeSemantics: true,
      child: onTap == null
          ? meter
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: meter,
            ),
    );
  }
}

/// Pequeño · Ancho · Grande of one widget on the board. A size that does
/// not fit is off (struck through).
class HomeSizeControl extends StatelessWidget {
  const HomeSizeControl({
    super.key,
    required this.id,
    required this.sizes,
    required this.selected,
    required this.fits,
    required this.onChanged,
  });
  final String id;
  final List<HomeWidgetSize> sizes;
  final HomeWidgetSize selected;
  final bool Function(HomeWidgetSize size) fits;
  final ValueChanged<HomeWidgetSize> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: p.inset,
        shape: SoftShapes.capsule(side: BorderSide(color: p.hairline)),
        shadows: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final size in sizes)
              _SizeChip(
                key: ValueKey('home-size-$id-${size.name}'),
                label: homeSizeName(s, size),
                current: size == selected,
                enabled: size == selected || fits(size),
                onTap: () => onChanged(size),
              ),
          ],
        ),
      ),
    );
  }
}

class _SizeChip extends StatelessWidget {
  const _SizeChip({
    super.key,
    required this.label,
    required this.current,
    required this.enabled,
    required this.onTap,
    this.outlined = false,
  });
  final String label;
  final bool current;
  final bool enabled;
  final VoidCallback onTap;

  /// The chips of «Añadir widget»: an outline instead of a filled segment.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    final accent = HomeType.live(p);
    final text = Text(
      label,
      maxLines: 1,
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
      style: TextStyle(
        fontSize: outlined ? 12 : 12.5,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: current
            ? p.onPrimary
            : outlined && enabled
            ? accent
            : p.text,
        decoration: enabled || outlined ? null : TextDecoration.lineThrough,
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      selected: current,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled && !current
            ? () {
                HapticFeedback.selectionClick();
                onTap();
              }
            : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: outlined ? 2 : 0,
            vertical: outlined ? 8 : 0,
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.32,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: current
                    ? p.primary
                    : outlined && enabled
                    ? accent.withValues(alpha: 0.08)
                    : Colors.transparent,
                shape: SoftShapes.capsule(
                  side: outlined
                      ? BorderSide(
                          color: enabled
                              ? accent.withValues(alpha: 0.75)
                              : p.hairline,
                        )
                      : BorderSide.none,
                ),
              ),
              child: SizedBox(
                height: outlined ? 28 : 34,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: outlined ? 9 : 12),
                  child: Center(widthFactor: 1, child: text),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The size chips at the end of a row. They keep their size while the row
/// has room for them; in a narrower one they shrink together instead of
/// pushing the row wider.
class _Chips extends StatelessWidget {
  const _Chips({required this.max, required this.children});

  /// The most the chips may take of their row.
  final double max;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: max < 0 ? 0 : max),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerEnd,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}

/// Capsule segmented control. A value [enabled] refuses is off.
class HomeSegmented<T> extends StatelessWidget {
  const HomeSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
    this.enabled,
  });
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  final bool Function(T)? enabled;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: p.inset, shape: SoftShapes.capsule()),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            for (final v in values)
              Expanded(
                child: Builder(
                  builder: (context) {
                    final on = v == selected || (enabled?.call(v) ?? true);
                    return Semantics(
                      button: true,
                      enabled: on,
                      selected: v == selected,
                      child: GestureDetector(
                        key: ValueKey('home-seg-$v'),
                        behavior: HitTestBehavior.opaque,
                        onTap: on
                            ? () {
                                HapticFeedback.selectionClick();
                                onChanged(v);
                              }
                            : null,
                        child: Opacity(
                          opacity: on ? 1 : 0.32,
                          child: AnimatedContainer(
                            duration: SoftMotion.of(context, SoftMotion.quick),
                            curve: SoftMotion.spring,
                            constraints: const BoxConstraints(minHeight: 40),
                            alignment: Alignment.center,
                            decoration: ShapeDecoration(
                              color: v == selected
                                  ? p.surface
                                  : Colors.transparent,
                              shape: SoftShapes.capsule(),
                              shadows: v == selected
                                  ? const [
                                      BoxShadow(
                                        color: Color(0x14000000),
                                        blurRadius: 4,
                                        offset: Offset(0, 1),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Text(
                              label(v),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: v == selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: v == selected ? p.text : p.textMuted,
                                decoration: on
                                    ? null
                                    : TextDecoration.lineThrough,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What «Añadir widget» chose.
final class HomeGalleryChoice {
  final HomeWidgetKind kind;
  final HomeWidgetSize size;
  final Map<String, Object?> options;
  const HomeGalleryChoice(this.kind, this.size, this.options);
}

/// Targets a kind can point at, for its pickers.
List<(String id, String label)> homeWidgetTargets(
  HomeWidgetKind kind,
  HomeBoardData data,
) => switch (kind) {
  HomeWidgetKind.room => [for (final r in data.rooms) (r.key, r.title)],
  HomeWidgetKind.bot => [
    for (final b in data.bots) (b.profileName, b.displayName),
  ],
  HomeWidgetKind.chat => [for (final c in data.chats) (c.key, c.title)],
  HomeWidgetKind.cron => [
    for (final j in data.automations ?? const []) (j.key, j.name),
  ],
  _ => const [],
};

/// «Añadir widget»: every widget the board can still take, each with the
/// sizes that fit in what is free ([plan]). Choosing a size adds it; a
/// widget about one bot or one chat asks which first.
Future<HomeGalleryChoice?> showHomeWidgetGallery(
  BuildContext context, {
  required HomeBoardLayout layout,
  required HomeBoardData data,
  required HomeBoardPlan plan,
  required ValueChanged<bool> onNeutralChanged,
}) => _sheet<HomeGalleryChoice>(
  context,
  (context) => _Gallery(
    layout: layout,
    data: data,
    plan: plan,
    onNeutralChanged: onNeutralChanged,
  ),
);

class _Gallery extends StatefulWidget {
  const _Gallery({
    required this.layout,
    required this.data,
    required this.plan,
    required this.onNeutralChanged,
  });
  final HomeBoardLayout layout;
  final HomeBoardData data;
  final HomeBoardPlan plan;
  final ValueChanged<bool> onNeutralChanged;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  /// The kind and size waiting for their target.
  (HomeWidgetKind, HomeWidgetSize)? _picking;
  late bool _neutral = widget.layout.neutral;

  void _choose(HomeWidgetKind kind, HomeWidgetSize size) {
    final option = HomeWidgetCatalog.of(kind).requiredOption;
    if (option != null) {
      setState(() => _picking = (kind, size));
      return;
    }
    Navigator.of(context).pop(HomeGalleryChoice(kind, size, const {}));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    if (_picking case (final kind, final size)) {
      final option = HomeWidgetCatalog.of(kind).requiredOption!;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetTitle(
            _pickTitle(s, kind),
            onClose: () => setState(() => _picking = null),
          ),
          Flexible(
            child: _TargetList(
              targets: homeWidgetTargets(kind, widget.data),
              selected: null,
              onPick: (id) => Navigator.of(
                context,
              ).pop(HomeGalleryChoice(kind, size, {option: id})),
            ),
          ),
        ],
      );
    }
    final kinds = HomeWidgetCatalog.addable(widget.layout);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetTitle(
          s.hwAddWidget,
          trailing: HomeBoardMeter(
            key: const ValueKey('home-gallery-meter'),
            compact: true,
            plan: widget.plan,
          ),
        ),
        Flexible(
          child: ListView(
            key: const ValueKey('home-gallery'),
            primary: true,
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              for (final (i, kind) in kinds.indexed) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: p.hairline),
                _GalleryRow(
                  key: ValueKey('home-gallery-${kind.name}'),
                  kind: kind,
                  neutral: _neutral,
                  fits: widget.plan.fits,
                  onAdd: (size) => _choose(kind, size),
                ),
              ],
              const SizedBox(height: 8),
              _SwitchRow(
                key: const ValueKey('home-gallery-colorful'),
                title: s.hwColorful,
                value: !_neutral,
                onChanged: (on) {
                  setState(() => _neutral = !on);
                  widget.onNeutralChanged(!on);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _pickTitle(Strings s, HomeWidgetKind kind) => switch (kind) {
  HomeWidgetKind.room => s.hwPickRooms,
  HomeWidgetKind.bot => s.hwPickBot,
  HomeWidgetKind.chat => s.hwPickChat,
  _ => s.hwPickJob,
};

/// One widget of «Añadir widget»: its icon and name, and a chip per size.
class _GalleryRow extends StatelessWidget {
  const _GalleryRow({
    super.key,
    required this.kind,
    required this.neutral,
    required this.fits,
    required this.onAdd,
  });
  final HomeWidgetKind kind;
  final bool neutral;
  final bool Function(HomeWidgetSize size) fits;
  final ValueChanged<HomeWidgetSize> onAdd;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final tint = p.tint(neutral ? SoftHue.neutral : homeWidgetHue(kind));
    return LayoutBuilder(
      builder: (context, box) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                color: tint.wash,
                shape: SoftShapes.card(radius: SoftRadii.chip),
              ),
              child: SizedBox.square(
                dimension: 30,
                child: Icon(homeWidgetIcon(kind), size: 16, color: tint.ink),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                homeWidgetAddName(s, kind),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HomeType.row(p),
              ),
            ),
            const SizedBox(width: 6),
            _Chips(
              // The name keeps at least 72 dp.
              max: box.maxWidth - 30 - 11 - 6 - 72,
              children: [
                for (final size in HomeWidgetCatalog.of(kind).sizes)
                  _SizeChip(
                    key: ValueKey('home-add-${kind.name}-${size.name}'),
                    label: homeSizeName(s, size),
                    current: false,
                    enabled: fits(size),
                    outlined: true,
                    onTap: () => onAdd(size),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetList extends StatelessWidget {
  const _TargetList({
    required this.targets,
    required this.selected,
    required this.onPick,
  });
  final List<(String, String)> targets;
  final String? selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    if (targets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(s.hwPickNone, style: HomeType.meta(p)),
      );
    }
    return ListView(
      primary: true,
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        _Group(
          children: [
            for (final (id, label) in targets)
              _OptionRow(
                key: ValueKey('home-pick-$id'),
                title: label,
                selected: id == selected,
                onTap: () => onPick(id),
              ),
          ],
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: p.inset,
        shape: SoftShapes.card(radius: 18),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Divider(height: 0.8, thickness: 0.8, color: p.hairline),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.leading,
    this.enabled = true,
  });
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    final row = Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HomeType.body(p).copyWith(fontSize: 16),
                  ),
                ),
                AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: SoftMotion.of(context, SoftMotion.quick),
                  child: Icon(Icons.check_rounded, size: 20, color: p.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return enabled || selected ? row : Opacity(opacity: 0.45, child: row);
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.leading,
  });
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? leading;
  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HomeType.body(p).copyWith(fontSize: 16),
                ),
              ),
              Switch.adaptive(
                value: value,
                activeTrackColor: p.primary,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  onChanged(v);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings of one widget instance. Every change applies at once. A size
/// [sizeFits] refuses is off.
Future<void> showHomeWidgetConfigure(
  BuildContext context, {
  required HomeWidgetInstance item,
  required HomeBoardData data,
  required bool Function(HomeWidgetSize size) sizeFits,
  required ValueChanged<HomeWidgetInstance> onChanged,
  required VoidCallback onRemove,
}) => _sheet<void>(
  context,
  (context) => _Configure(
    item: item,
    data: data,
    sizeFits: sizeFits,
    onChanged: onChanged,
    onRemove: onRemove,
  ),
);

class _Configure extends StatefulWidget {
  const _Configure({
    required this.item,
    required this.data,
    required this.sizeFits,
    required this.onChanged,
    required this.onRemove,
  });
  final HomeWidgetInstance item;
  final HomeBoardData data;
  final bool Function(HomeWidgetSize size) sizeFits;
  final ValueChanged<HomeWidgetInstance> onChanged;
  final VoidCallback onRemove;

  @override
  State<_Configure> createState() => _ConfigureState();
}

class _ConfigureState extends State<_Configure> {
  late HomeWidgetInstance _item = widget.item;

  void _set(HomeWidgetInstance next) {
    setState(() => _item = next);
    widget.onChanged(next);
  }

  void _option(String key, Object? value) {
    final options = Map<String, Object?>.of(_item.options);
    if (value == null) {
      options.remove(key);
    } else {
      options[key] = value;
    }
    _set(_item.copyWith(options: options));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final kind = _item.kind;
    final spec = HomeWidgetCatalog.of(kind);
    final sections = <Widget>[];
    void section(String title, Widget child) {
      sections
        ..add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
            child: Text(title, style: HomeType.label(p)),
          ),
        )
        ..add(child);
    }

    switch (kind) {
      case HomeWidgetKind.team:
        final chosen = _item.listOption('bots');
        section(
          s.hwTeamBots,
          _Group(
            children: [
              for (final b in widget.data.bots)
                _SwitchRow(
                  key: ValueKey('home-cfg-bot-${b.profileName}'),
                  leading: HomeFace(
                    profileName: b.profileName,
                    data: widget.data,
                    size: 28,
                  ),
                  title: b.displayName,
                  value: chosen == null || chosen.contains(b.profileName),
                  onChanged: (on) {
                    final all = [
                      for (final x in widget.data.bots) x.profileName,
                    ];
                    final next = {...(chosen ?? all)};
                    on ? next.add(b.profileName) : next.remove(b.profileName);
                    _option(
                      'bots',
                      next.length == all.length && all.every(next.contains)
                          ? null
                          : [
                              for (final n in all)
                                if (next.contains(n)) n,
                            ],
                    );
                  },
                ),
            ],
          ),
        );
        sections.add(const SizedBox(height: 8));
        sections.add(
          _SwitchRow(
            key: const ValueKey('home-cfg-only-working'),
            title: s.hwTeamOnlyWorking,
            value: _item.boolOption('onlyWorking'),
            onChanged: (v) => _option('onlyWorking', v ? true : null),
          ),
        );
      case HomeWidgetKind.room:
        final keys = _item.roomKeys;
        final full = keys.length >= HomeWidgetInstance.maxRooms;
        section(
          s.hwPickRooms,
          _Group(
            children: [
              // No room chosen: the liveliest ones, whichever they are.
              _OptionRow(
                key: const ValueKey('home-pick-any'),
                title: s.hwRoomsAny,
                selected: keys.isEmpty,
                onTap: () => _set(_item.withRooms(const [])),
              ),
              for (final (id, label) in homeWidgetTargets(kind, widget.data))
                _OptionRow(
                  key: ValueKey('home-pick-$id'),
                  title: label,
                  selected: keys.contains(id),
                  // A full widget offers no fourth room.
                  enabled: keys.contains(id) || !full,
                  onTap: () => _set(
                    _item.withRooms(
                      keys.contains(id)
                          ? [
                              for (final k in keys)
                                if (k != id) k,
                            ]
                          : [...keys, id],
                    ),
                  ),
                ),
            ],
          ),
        );
      case HomeWidgetKind.bot || HomeWidgetKind.chat:
        final option = spec.requiredOption!;
        section(
          _pickTitle(s, kind),
          _Group(
            children: [
              for (final (id, label) in homeWidgetTargets(kind, widget.data))
                _OptionRow(
                  key: ValueKey('home-pick-$id'),
                  title: label,
                  leading: kind == HomeWidgetKind.bot
                      ? HomeFace(profileName: id, data: widget.data, size: 28)
                      : null,
                  selected: _item.stringOption(option) == id,
                  onTap: () => _option(option, id),
                ),
            ],
          ),
        );
      case HomeWidgetKind.cron:
        section(
          s.hwPickJob,
          _Group(
            children: [
              _OptionRow(
                key: const ValueKey('home-pick-any'),
                title: s.hwNextAny,
                selected: _item.stringOption('job') == null,
                onTap: () => _option('job', null),
              ),
              for (final (id, label) in homeWidgetTargets(kind, widget.data))
                _OptionRow(
                  key: ValueKey('home-pick-$id'),
                  title: label,
                  selected: _item.stringOption('job') == id,
                  onTap: () => _option('job', id),
                ),
            ],
          ),
        );
      default:
        break;
    }
    if (spec.sizes.length > 1) {
      section(
        s.hwSize,
        HomeSegmented<HomeWidgetSize>(
          values: spec.sizes,
          selected: _item.size,
          label: (v) => homeSizeName(s, v),
          enabled: widget.sizeFits,
          onChanged: (v) => _set(_item.copyWith(size: v)),
        ),
      );
    }
    section(
      s.hwTint,
      HomeSegmented<bool>(
        key: const ValueKey('home-cfg-tint'),
        values: const [false, true],
        selected: _item.stringOption('tint') == 'neutral',
        label: (neutral) => neutral ? s.hwTintNeutral : s.hwTintTheme,
        onChanged: (neutral) => _option('tint', neutral ? 'neutral' : null),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetTitle(
          homeWidgetName(s, kind),
          onClose: () => Navigator.of(context).pop(),
        ),
        Flexible(
          child: ListView(
            key: const ValueKey('home-configure'),
            primary: true,
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              ...sections,
              const SizedBox(height: 18),
              Center(
                child: TextButton(
                  key: const ValueKey('home-cfg-remove'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onRemove();
                  },
                  child: Text(
                    s.hwRemove,
                    style: TextStyle(
                      color: p.failure,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The widgets of the board that do not fit on this screen: each one with
/// its sizes (those that would bring it back are on) and a way out.
Future<void> showHomeHiddenWidgets(
  BuildContext context, {
  required HomeBoardLayout Function() layout,
  required int rows,
  required void Function(HomeWidgetInstance item, HomeWidgetSize size) onResize,
  required ValueChanged<HomeWidgetInstance> onRemove,
}) => _sheet<void>(
  context,
  (context) => _Hidden(
    layout: layout,
    rows: rows,
    onResize: onResize,
    onRemove: onRemove,
  ),
);

class _Hidden extends StatefulWidget {
  const _Hidden({
    required this.layout,
    required this.rows,
    required this.onResize,
    required this.onRemove,
  });
  final HomeBoardLayout Function() layout;
  final int rows;
  final void Function(HomeWidgetInstance item, HomeWidgetSize size) onResize;
  final ValueChanged<HomeWidgetInstance> onRemove;

  @override
  State<_Hidden> createState() => _HiddenState();
}

class _HiddenState extends State<_Hidden> {
  /// The host applies a change after this frame; then the list is read
  /// again (and the surface closes once nothing is left out).
  void _after(VoidCallback change) {
    change();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final plan = HomeBoardPlan.of(widget.layout().items, widget.rows);
      if (plan.hidden.isEmpty) {
        Navigator.of(context).maybePop();
      } else {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final layout = widget.layout();
    final plan = HomeBoardPlan.of(layout.items, widget.rows);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetTitle(
          s.hwHiddenTitle,
          trailing: HomeBoardMeter(plan: plan, compact: true),
          onClose: () => Navigator.of(context).pop(),
        ),
        Flexible(
          child: ListView(
            key: const ValueKey('home-hidden'),
            primary: true,
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
            children: [
              for (final (i, item) in plan.hidden.indexed) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: p.hairline),
                LayoutBuilder(
                  key: ValueKey('home-hidden-${item.id}'),
                  builder: (context, box) => ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: Row(
                      children: [
                        Icon(
                          homeWidgetIcon(item.kind),
                          size: 18,
                          color: p.textMuted,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            homeWidgetName(s, item.kind),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HomeType.row(p),
                          ),
                        ),
                        _Chips(
                          max: box.maxWidth - 18 - 11 - 48 - 72,
                          children: [
                            for (final size in HomeWidgetCatalog.of(
                              item.kind,
                            ).sizes)
                              _SizeChip(
                                key: ValueKey(
                                  'home-hidden-${item.id}-${size.name}',
                                ),
                                label: homeSizeName(s, size),
                                current: false,
                                enabled: HomeBoardPlan.allows(
                                  layout.items,
                                  widget.rows,
                                  item.id,
                                  size,
                                ),
                                outlined: true,
                                onTap: () =>
                                    _after(() => widget.onResize(item, size)),
                              ),
                          ],
                        ),
                        IconButton(
                          key: ValueKey('home-hidden-remove-${item.id}'),
                          tooltip: s.hwRemoveA11y(homeWidgetName(s, item.kind)),
                          onPressed: () => _after(() => widget.onRemove(item)),
                          icon: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: p.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
