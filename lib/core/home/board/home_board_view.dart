/// Home widget board: a two-column grid of whole rows that fits between
/// the header and the dock and never scrolls, and its edit mode (hold
/// 420 ms, drag to reorder, remove, a size control, add) with its
/// accessibility.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/soft_tokens.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_ui.dart' show HermesPrimaryButton;
import 'home_board_catalog.dart';
import 'home_board_data.dart';
import 'home_board_kit.dart';
import 'home_board_model.dart';
import 'home_board_sheets.dart';
import 'home_board_tiles.dart';

/// Interaction constants of the owner's guide.
abstract final class HomeBoardMotion {
  static const hold = Duration(milliseconds: 420);
  static const holdSlop = 9.0;
  static const reflow = Duration(milliseconds: 210);
  static const wiggleDegrees = 0.55;
}

abstract final class HomeBoardMetrics {
  static const gap = HomeBoardGridRule.gap;
  static const sidePadding = 17.0;

  /// Room around the grid for the edit handles (they overhang the tiles);
  /// above the first row it is also the space under the header.
  static const handleRoom = 13.0;
  static const maxBoardWidth = 640.0;

  /// The edit bar takes the place of the screen's header.
  static const editBarHeight = kToolbarHeight;
}

/// Where the board put everything the last time it was built.
@immutable
final class HomeBoardGeometry {
  final HomeBoardPlan plan;
  final double rowHeight;
  final double cellWidth;
  const HomeBoardGeometry({
    required this.plan,
    required this.rowHeight,
    required this.cellWidth,
  });

  static const _gap = HomeBoardMetrics.gap;

  /// Board coordinates (without the handle room).
  Rect rectOf(HomeBoardSlot s) => Rect.fromLTWH(
    s.col * (cellWidth + _gap),
    s.row * (rowHeight + _gap),
    s.cols * cellWidth + (s.cols - 1) * _gap,
    s.rows * rowHeight + (s.rows - 1) * _gap,
  );

  Rect? rect(String id) => switch (plan.slotOf(id)) {
    final slot? => rectOf(slot),
    null => null,
  };

  double get height => plan.rows * rowHeight + (plan.rows - 1) * _gap;
}

class HomeBoardView extends StatefulWidget {
  const HomeBoardView({
    super.key,
    required this.layout,
    required this.data,
    required this.actions,
    required this.onChanged,
    required this.newId,
    required this.clock,
    this.leading = const [],
    this.bottomPadding = 0,
    this.initiallyEditing = false,
    this.onEditingChanged,
  });

  final HomeBoardLayout layout;
  final HomeBoardData data;
  final HomeBoardActions actions;
  final ValueChanged<HomeBoardLayout> onChanged;
  final String Function() newId;
  final DateTime Function() clock;

  /// Banners above the grid (offline cards, list errors). They take their
  /// height from the grid: fewer rows fit while one shows.
  final List<Widget> leading;

  /// Space the floating dock takes under the last row.
  final double bottomPadding;
  final bool initiallyEditing;

  /// Edit mode opened or closed. While it is open the board draws the
  /// edit bar where the screen's header was: the host leaves it that
  /// room (its own header out).
  final ValueChanged<bool>? onEditingChanged;

  @override
  State<HomeBoardView> createState() => HomeBoardViewState();
}

class HomeBoardViewState extends State<HomeBoardView>
    with TickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _boardKey = GlobalKey(debugLabel: 'home-board');
  late final AnimationController _wiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  late bool _editing = widget.initiallyEditing;
  String? _pressedId;
  String? _dragId;
  Offset _dragGlobal = Offset.zero;
  Offset _grab = Offset.zero;
  List<String>? _order;
  String? _lastSwap;

  /// The widget whose size control is open.
  String? _sizingId;

  /// What the last build laid out (drag hit-testing, fit checks).
  HomeBoardGeometry? _geometry;

  bool get editing => _editing;

  /// The grid as last laid out: its rows and what fits.
  @visibleForTesting
  HomeBoardGeometry? get geometry => _geometry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncWiggle();
  }

  @override
  void didUpdateWidget(HomeBoardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sizing = _sizingId;
    if (sizing != null && widget.layout.byId(sizing) == null) _sizingId = null;
  }

  @override
  void dispose() {
    _wiggle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncWiggle() {
    final run =
        _editing &&
        _sizingId == null &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false) &&
        TickerMode.valuesOf(context).enabled;
    if (run && !_wiggle.isAnimating) {
      _wiggle.repeat();
    } else if (!run && _wiggle.isAnimating) {
      _wiggle.stop();
    }
  }

  void setEditing(bool value) {
    if (_editing == value) return;
    setState(() {
      _editing = value;
      _pressedId = null;
      _sizingId = null;
    });
    _syncWiggle();
    widget.onEditingChanged?.call(value);
  }

  void _setSizing(String? id) {
    if (_sizingId == id) return;
    setState(() => _sizingId = id);
    _syncWiggle();
  }

  // ── layout ──────────────────────────────────────────────────────────

  /// The widgets in board order, or in drag order while one is dragged.
  List<HomeWidgetInstance> _ordered() {
    final order = _order;
    if (order == null) return widget.layout.items;
    final byId = {for (final i in widget.layout.items) i.id: i};
    return [for (final id in order) ?byId[id]];
  }

  int get _rows => _geometry?.plan.rows ?? HomeBoardGridRule.designRows;

  // ── drag ────────────────────────────────────────────────────────────

  Offset? _toBoard(Offset global) {
    final box = _boardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    return box.globalToLocal(global) -
        const Offset(HomeBoardMetrics.handleRoom, HomeBoardMetrics.handleRoom);
  }

  void _onHoldStart(String id, Offset global) {
    if (!_editing) {
      HapticFeedback.lightImpact();
      setEditing(true);
    }
    final local = _toBoard(global);
    final rect = _geometry?.rect(id);
    setState(() {
      _pressedId = null;
      _sizingId = null;
      _dragId = id;
      _dragGlobal = global;
      _grab = local == null || rect == null
          ? Offset.zero
          : local - rect.topLeft;
      _order = [for (final i in widget.layout.items) i.id];
      _lastSwap = null;
    });
    _syncWiggle();
  }

  void _onDragUpdate(Offset global) {
    if (_dragId == null) return;
    _dragGlobal = global;
    _reorderAt(global);
    setState(() {});
  }

  void _reorderAt(Offset global) {
    final id = _dragId;
    final order = _order;
    final geometry = _geometry;
    final local = _toBoard(global);
    if (id == null || order == null || local == null || geometry == null) {
      return;
    }
    final own = geometry.rect(id);
    final center =
        local - _grab + (own?.size.center(Offset.zero) ?? Offset.zero);
    String? target;
    for (final other in geometry.plan.placed) {
      if (other.id == id) continue;
      final rect = geometry.rect(other.id);
      if (rect != null && rect.deflate(8).contains(center)) {
        target = other.id;
        break;
      }
    }
    if (target == null) {
      if (_lastSwap case final last?) {
        final rect = geometry.rect(last);
        if (rect == null || !rect.contains(center)) _lastSwap = null;
      }
      // Over a free slot: last in the order (the grid backfills holes).
      final overHole = geometry.plan.holes.any(
        (h) => geometry.rectOf(h).contains(center),
      );
      if ((overHole || center.dy > geometry.height) && order.last != id) {
        order
          ..remove(id)
          ..add(id);
        HapticFeedback.selectionClick();
      }
      return;
    }
    if (target == _lastSwap) return;
    final to = order.indexOf(target);
    order
      ..remove(id)
      ..insert(to, id);
    _lastSwap = target;
    HapticFeedback.selectionClick();
  }

  void _onDragEnd() {
    final id = _dragId;
    final order = _order;
    if (id == null || order == null) return;
    final layout = widget.layout.move(id, order.indexOf(id));
    if (!identical(layout, widget.layout)) HapticFeedback.selectionClick();
    setState(() {
      _dragId = null;
      _order = null;
    });
    _syncWiggle();
    if (!identical(layout, widget.layout)) widget.onChanged(layout);
  }

  // ── edits ───────────────────────────────────────────────────────────

  void _remove(HomeWidgetInstance item) {
    HapticFeedback.selectionClick();
    if (_sizingId == item.id) _sizingId = null;
    widget.onChanged(widget.layout.remove(item.id));
  }

  /// The size [id] is shown at now (a smaller one than it stores when its
  /// own has no place).
  HomeWidgetSize? _shownSize(String id) =>
      _geometry?.plan.shownSize(id) ?? widget.layout.byId(id)?.size;

  /// Whether the widget [id] can take [size] with everything on the board
  /// staying on it as it is.
  bool _sizeFits(String id, HomeWidgetSize size) =>
      _shownSize(id) == size ||
      HomeBoardPlan.allows(widget.layout.items, _rows, id, size);

  void _resize(String id, HomeWidgetSize size) {
    if (_shownSize(id) == size || !_sizeFits(id, size)) return;
    HapticFeedback.selectionClick();
    widget.onChanged(widget.layout.resize(id, size));
  }

  void _moveBy(HomeWidgetInstance item, int delta) {
    final items = widget.layout.items;
    final at = items.indexWhere((i) => i.id == item.id);
    final to = at + delta;
    if (at < 0 || to < 0 || to >= items.length) return;
    widget.onChanged(widget.layout.move(item.id, to));
  }

  /// The settings of [item], given at the size it is shown at.
  Future<void> _configure(HomeWidgetInstance item) => showHomeWidgetConfigure(
    context,
    item: item,
    data: widget.data,
    sizeFits: (size) =>
        widget.layout.byId(item.id) != null && _sizeFits(item.id, size),
    onChanged: (updated) {
      var layout = widget.layout;
      if (layout.byId(item.id) == null) return;
      if (updated.size != _shownSize(item.id)) {
        if (!_sizeFits(item.id, updated.size)) return;
        layout = layout.resize(item.id, updated.size);
      }
      layout = layout.configure(item.id, updated.options);
      widget.onChanged(layout);
    },
    onRemove: () => _remove(item),
  );

  /// «Añadir widget»: what still fits, at the sizes that fit.
  Future<void> openGallery() async {
    final plan = _geometry?.plan;
    if (plan == null || plan.full) return;
    final choice = await showHomeWidgetGallery(
      context,
      layout: widget.layout,
      data: widget.data,
      plan: plan,
      onNeutralChanged: (neutral) =>
          widget.onChanged(widget.layout.withNeutral(neutral)),
    );
    if (choice == null || !mounted) return;
    widget.onChanged(
      widget.layout.add(
        choice.kind,
        size: choice.size,
        options: choice.options,
        newId: widget.newId,
      ),
    );
  }

  /// The widgets that do not fit on this screen: each can be made smaller
  /// or removed.
  Future<void> _openHidden() async {
    final plan = _geometry?.plan;
    if (plan == null || plan.hidden.isEmpty) return;
    await showHomeHiddenWidgets(
      context,
      layout: () => widget.layout,
      rows: plan.rows,
      onResize: (item, size) =>
          widget.onChanged(widget.layout.resize(item.id, size)),
      onRemove: _remove,
    );
  }

  // ── build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final plan = _geometry?.plan;
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_sizingId != null) {
          _setSizing(null);
        } else {
          setEditing(false);
        }
      },
      child: LayoutBuilder(
        builder: (context, viewport) => ScrollConfiguration(
          // Nothing moves when the board is pushed: no stretch, no glow.
          behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
          child: SingleChildScrollView(
            // The page is exactly as tall as its viewport: nothing scrolls,
            // and pulling down still refreshes.
            key: const ValueKey('home-board-list'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: viewport.maxHeight,
              child: _page(context, viewport.maxHeight, plan),
            ),
          ),
        ),
      ),
    );
  }

  /// The edit bar (in edit mode), the banners and the grid, top to bottom.
  Widget _page(BuildContext context, double height, HomeBoardPlan? plan) {
    const side = HomeBoardMetrics.sidePadding;
    final bar = _editing
        ? HomeBoardMetrics.editBarHeight + MediaQuery.paddingOf(context).top
        : 0.0;
    // The banners never take the grid's last row: past that they scroll in
    // their own place.
    final bannerRoom = math.max(
      0.0,
      height -
          bar -
          HomeBoardMetrics.handleRoom -
          math.max(widget.bottomPadding, HomeBoardMetrics.handleRoom) -
          HomeBoardGridRule.minRowHeight,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // In the same frame the host takes its header out: the grid below
        // keeps its place.
        if (_editing)
          _EditBar(
            key: const ValueKey('home-edit-bar'),
            plan: plan,
            onAdd: openGallery,
            onDone: () => setEditing(false),
            onHidden: _openHidden,
          ),
        if (widget.leading.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: bannerRoom),
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final banner in widget.leading)
                    _BannerSlot(side: side, top: 6, child: banner),
                ],
              ),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, area) => _board(context, area, height - bar),
          ),
        ),
      ],
    );
  }

  /// The grid in [area]; [open] is the height it has with no banner above.
  Widget _board(BuildContext context, BoxConstraints area, double open) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    const room = HomeBoardMetrics.handleRoom;
    const gap = HomeBoardMetrics.gap;
    final width = math.max(
      0.0,
      math.min(
        area.maxWidth - 2 * HomeBoardMetrics.sidePadding,
        HomeBoardMetrics.maxBoardWidth,
      ),
    );
    final around = room + math.max(widget.bottomPadding, room);
    final height = math.max(0.0, area.maxHeight - around);
    // A banner tightens the rows before it takes one away.
    final rows = HomeBoardGridRule.rowsUnder(
      height,
      math.max(height, open - around),
    );
    final geometry = HomeBoardGeometry(
      plan: HomeBoardPlan.of(_ordered(), rows),
      rowHeight: HomeBoardGridRule.rowHeightFor(height, rows),
      cellWidth: math.max(0.0, (width - gap) / 2),
    );
    final before = _geometry?.plan;
    _geometry = geometry;
    final plan = geometry.plan;
    if (_editing &&
        (before == null ||
            before.rows != plan.rows ||
            before.free != plan.free ||
            before.hidden.length != plan.hidden.length)) {
      // The edit bar (built before the grid was measured) shows these.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    final dragId = _dragId;
    final sizing = _sizingId == null
        ? null
        : plan.shown.where((i) => i.id == _sizingId).firstOrNull;
    final sizingRect = sizing == null ? null : geometry.rect(sizing.id);
    Positioned at(Rect rect, {required Widget child, Key? key}) => Positioned(
      key: key,
      left: rect.left + room,
      top: rect.top + room,
      width: rect.width,
      height: rect.height,
      child: child,
    );
    final children = <Widget>[
      if (_editing)
        for (final hole in plan.holes)
          at(
            geometry.rectOf(hole),
            key: ValueKey('home-hole-${hole.col}-${hole.row}'),
            child: _Hole(onTap: dragId == null ? openGallery : null),
          )
      else if (plan.placed.isEmpty)
        at(
          geometry.rectOf(
            const HomeBoardSlot(col: 0, row: 0, cols: 2, rows: 1),
          ),
          key: const ValueKey('home-board-empty'),
          child: _Hole(
            onTap: () {
              setEditing(true);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) openGallery();
              });
            },
          ),
        ),
      if (dragId != null)
        if (geometry.rect(dragId) case final rect?)
          at(
            rect,
            key: const ValueKey('home-drop-placeholder'),
            child: const _DropPlaceholder(),
          ),
    ];
    // The dragged widget is painted last (on top).
    final order = [
      for (var i = 0; i < plan.placed.length; i++)
        if (plan.placed[i].id != dragId) i,
      for (var i = 0; i < plan.placed.length; i++)
        if (plan.placed[i].id == dragId) i,
    ];
    final shown = plan.shown;
    for (final i in order) {
      final item = shown[i];
      final dragging = item.id == dragId;
      var rect = geometry.rectOf(plan.slots[i]);
      if (dragging) {
        final local = _toBoard(_dragGlobal);
        if (local != null) rect = (local - _grab) & rect.size;
      }
      children.add(
        AnimatedPositioned(
          key: ValueKey('home-widget-${item.id}'),
          duration: reduced || dragging
              ? Duration.zero
              : HomeBoardMotion.reflow,
          curve: SoftMotion.spring,
          // The box reaches past the tile by the handle room, so the
          // handles that overhang it can be touched.
          left: rect.left,
          top: rect.top,
          width: rect.width + 2 * room,
          height: rect.height + 2 * room,
          child: Padding(
            padding: const EdgeInsets.all(room),
            child: _tile(
              context,
              item,
              index: widget.layout.indexOf(item.id),
              dragging: dragging,
              dimmed: sizing != null && sizing.id != item.id,
              selected: sizing?.id == item.id,
            ),
          ),
        ),
      );
    }
    if (sizing != null && sizingRect != null) {
      children
        ..add(
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('home-size-dismiss'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _setSizing(null),
            ),
          ),
        )
        ..add(_sizeControl(context, sizing, sizingRect, width, height));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        key: _boardKey,
        width: width + 2 * room,
        height: height + 2 * room,
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    );
  }

  /// Pequeño / Ancho / Grande of [item], floating at its bottom edge (at
  /// the top one for a tile of the last row, clear of the dock).
  Widget _sizeControl(
    BuildContext context,
    HomeWidgetInstance item,
    Rect rect,
    double width,
    double height,
  ) {
    const room = HomeBoardMetrics.handleRoom;
    const barHeight = 40.0;
    const overlap = 6.0;
    final below = rect.bottom - overlap + barHeight <= height + room;
    final top = below
        ? rect.bottom - overlap
        : math.max(0.0, rect.top - barHeight + overlap);
    return Positioned(
      left: room,
      width: width,
      top: top + room,
      height: barHeight,
      child: Align(
        alignment: Alignment(
          width <= 0 ? 0 : ((rect.center.dx / width) * 2 - 1).clamp(-1.0, 1.0),
          0,
        ),
        child: HomeSizeControl(
          key: ValueKey('home-size-${item.id}'),
          id: item.id,
          sizes: HomeWidgetCatalog.of(item.kind).sizes,
          selected: item.size,
          fits: (size) => _sizeFits(item.id, size),
          onChanged: (size) => _resize(item.id, size),
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    HomeWidgetInstance item, {
    required int index,
    required bool dragging,
    required bool dimmed,
    required bool selected,
  }) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final name = homeWidgetName(s, item.kind);
    final spec = HomeWidgetCatalog.of(item.kind);
    final tint = homeWidgetTint(p, item, colorful: !widget.layout.neutral);
    final count = widget.layout.items.length;
    final body = HomeCard(
      padding: _editing
          ? const EdgeInsets.fromLTRB(14, 48, 14, 12)
          : HomeCard.contentPadding,
      hero: !_editing && homeWidgetHero(item, widget.data),
      child: HomeWidgetBody(
        HomeTileContext(
          item: item,
          data: widget.data,
          actions: widget.actions,
          tint: tint,
          editing: _editing,
          clock: widget.clock,
        ),
      ),
    );
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // The structure stays the same in every state (normal, edit, lifted):
    // a wrapper added or removed mid-gesture would remount the gesture
    // detector and drop the drag in progress.
    final content = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _editing ? () => _configure(item) : null,
      child: IgnorePointer(ignoring: _editing, child: body),
    );
    final phase = (index * 0.37) % 1.0;
    final wiggles = _editing && !dragging && _sizingId == null;
    final visual = AnimatedBuilder(
      animation: _wiggle,
      builder: (context, child) => Transform.rotate(
        angle: wiggles
            ? math.sin((_wiggle.value + phase) * 2 * math.pi) *
                  HomeBoardMotion.wiggleDegrees *
                  math.pi /
                  180
            : 0,
        child: child,
      ),
      child: AnimatedOpacity(
        opacity: dimmed ? 0.42 : 1,
        duration: reduced ? Duration.zero : const Duration(milliseconds: 160),
        child: AnimatedScale(
          scale: dragging
              ? 1.04
              : _pressedId == item.id
              ? 0.97
              : 1,
          duration: reduced ? Duration.zero : const Duration(milliseconds: 160),
          curve: SoftMotion.spring,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: ShapeDecoration(
              shape: SoftShapes.card(
                side: selected
                    ? BorderSide(color: HomeType.live(p), width: 2)
                    : BorderSide.none,
              ),
            ),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: SoftShapes.card(),
                shadows: dragging
                    ? const [
                        BoxShadow(
                          color: Color(0x2E000000),
                          blurRadius: 24,
                          offset: Offset(0, 10),
                        ),
                      ]
                    : const [],
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
    final tile = RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        HoldDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<HoldDragGestureRecognizer>(
              HoldDragGestureRecognizer.new,
              (r) {
                r
                  ..hold = _editing ? null : HomeBoardMotion.hold
                  ..slop = HomeBoardMotion.holdSlop
                  ..onPress = (() => setState(() => _pressedId = item.id))
                  ..onCancel = (() {
                    if (_pressedId == item.id) {
                      setState(() => _pressedId = null);
                    }
                  })
                  ..onStart = ((g) => _onHoldStart(item.id, g))
                  ..onUpdate = _onDragUpdate
                  ..onEnd = _onDragEnd;
              },
            ),
      },
      child: visual,
    );
    final handles = _editing && !dragging;
    return Semantics(
      key: ValueKey('home-tile-${item.kind.name}-${item.id}'),
      container: true,
      label: name,
      hint: _editing ? null : s.hwEditA11yHint,
      onLongPress: _editing ? null : () => setEditing(true),
      customSemanticsActions: {
        if (index > 0)
          CustomSemanticsAction(label: s.hwMoveUp): () => _moveBy(item, -1),
        if (index < count - 1)
          CustomSemanticsAction(label: s.hwMoveDown): () => _moveBy(item, 1),
        for (final size in spec.sizes)
          if (size != item.size && _sizeFits(item.id, size))
            CustomSemanticsAction(
              label: s.hwResizeToA11y(homeSizeName(s, size)),
            ): () =>
                _resize(item.id, size),
        CustomSemanticsAction(label: s.hwConfigureA11y(name)): () =>
            _configure(item),
        CustomSemanticsAction(label: s.hwRemoveA11y(name)): () => _remove(item),
      },
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: [
          tile,
          if (handles)
            Positioned(
              left: 0,
              top: 0,
              child: _Handle(
                key: ValueKey('home-remove-${item.id}'),
                icon: Icons.close_rounded,
                label: s.hwRemoveA11y(name),
                onTap: () => _remove(item),
              ),
            ),
          if (handles && spec.sizes.length > 1)
            Positioned(
              right: 0,
              top: 0,
              child: _Handle(
                key: ValueKey('home-resize-${item.id}'),
                icon: Icons.open_in_full_rounded,
                label: s.hwResizeA11y(name),
                hot: selected,
                onTap: () => _setSizing(selected ? null : item.id),
              ),
            ),
          if (_editing)
            Positioned(
              left: _Handle.extent,
              right: _Handle.extent,
              top: 0,
              height: _Handle.extent,
              child: Center(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HomeType.label(p),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A banner above the grid with its margins, which it only takes while it
/// shows something (a banner with nothing to say has no height).
class _BannerSlot extends SingleChildRenderObjectWidget {
  const _BannerSlot({required this.side, required this.top, super.child});
  final double side;
  final double top;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBannerSlot(side, top);

  @override
  void updateRenderObject(BuildContext context, _RenderBannerSlot object) =>
      object
        ..side = side
        ..top = top;
}

class _RenderBannerSlot extends RenderShiftedBox {
  _RenderBannerSlot(this._side, this._top) : super(null);

  double _side;
  set side(double value) {
    if (value == _side) return;
    _side = value;
    markNeedsLayout();
  }

  double _top;
  set top(double value) {
    if (value == _top) return;
    _top = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final box = child;
    final width = constraints.maxWidth;
    if (box == null) {
      size = constraints.constrain(Size(width, 0));
      return;
    }
    box.layout(
      BoxConstraints.tightFor(width: math.max(0.0, width - 2 * _side)),
      parentUsesSize: true,
    );
    (box.parentData! as BoxParentData).offset = Offset(_side, _top);
    final height = box.size.height <= 0 ? 0.0 : box.size.height + _top;
    size = constraints.constrain(Size(width, height));
  }
}

/// Lays the board out in the height its page has with the keyboard closed.
///
/// A keyboard that opens over Home (the dock's composer, a field in a
/// sheet) shortens the page. The board would plan fewer rows and rebuild
/// every tile on each frame of the keyboard's way up, for rows that end
/// behind it anyway. Here its box keeps its height, so nothing is planned
/// or built again, and the keyboard covers its lower part.
class HomeBoardSteady extends SingleChildRenderObjectWidget {
  const HomeBoardSteady({super.key, required this.keyboard, super.child});

  /// What the keyboard takes from the page right now. Read while laying
  /// out, so it must not depend on anything that rebuilds the caller.
  final double Function() keyboard;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBoardSteady(keyboard);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderBoardSteady).keyboard = keyboard;
}

class _RenderBoardSteady extends RenderShiftedBox {
  _RenderBoardSteady(this.keyboard) : super(null);

  /// Not a layout input by itself: the page changes height in the same
  /// frame the keyboard does, and that is what lays this out again.
  double Function() keyboard;

  double? _height;
  final _clip = LayerHandle<ClipRectLayer>();

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final box = child;
    if (!constraints.hasBoundedHeight || !constraints.hasBoundedWidth) {
      _height = null;
      box?.layout(constraints, parentUsesSize: true);
      size = constraints.constrain(box?.size ?? Size.zero);
      return;
    }
    size = constraints.biggest;
    if (box == null) return;
    var height = size.height + math.max(0.0, keyboard());
    // Frame after frame of the keyboard this is one height, give or take a
    // rounding error of the sum.
    final last = _height;
    if (last != null && (last - height).abs() < 0.5) height = last;
    _height = height;
    box.layout(BoxConstraints.tightFor(width: size.width, height: height));
  }

  bool get _covered => (_height ?? 0) > size.height;

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _covered ? Offset.zero & size : null;

  @override
  void paint(PaintingContext context, Offset offset) {
    final box = child;
    if (box == null || !_covered) {
      _clip.layer = null;
      if (box != null) context.paintChild(box, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(box, offset),
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}

/// Hold-to-drag: [hold] null starts the drag once the finger moved more
/// than [slop] (edit mode); otherwise it waits [hold] and is cancelled by
/// a move over [slop] before that (normal mode, so taps on the widget and
/// the pull to refresh keep working).
class HoldDragGestureRecognizer extends OneSequenceGestureRecognizer {
  HoldDragGestureRecognizer({super.debugOwner});

  Duration? hold;
  double slop = 9;
  VoidCallback? onPress;
  VoidCallback? onCancel;
  ValueChanged<Offset>? onStart;
  ValueChanged<Offset>? onUpdate;
  VoidCallback? onEnd;

  Timer? _timer;
  Offset? _origin;
  Offset _last = Offset.zero;
  bool _accepted = false;
  int? _pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return;
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    _origin = event.position;
    _last = event.position;
    _accepted = false;
    onPress?.call();
    final delay = hold;
    if (delay != null) {
      _timer = Timer(delay, () {
        _timer = null;
        if (_pointer != null && !_accepted) {
          resolve(GestureDisposition.accepted);
        }
      });
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      _last = event.position;
      if (_accepted) {
        onUpdate?.call(event.position);
      } else if ((event.position - _origin!).distance > slop) {
        if (hold == null) {
          resolve(GestureDisposition.accepted);
        } else {
          _giveUp();
        }
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_accepted) {
        onEnd?.call();
      } else {
        _giveUp();
      }
      stopTrackingPointer(event.pointer);
    }
  }

  void _giveUp() {
    _timer?.cancel();
    _timer = null;
    if (_pointer != null && !_accepted) {
      onCancel?.call();
      final pointer = _pointer!;
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer != _pointer || _accepted) return;
    _timer?.cancel();
    _timer = null;
    _accepted = true;
    onStart?.call(_last);
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer != _pointer) return;
    _timer?.cancel();
    _timer = null;
    if (!_accepted) onCancel?.call();
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _origin = null;
    _accepted = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  String get debugDescription => 'hold-drag';
}

class _DashedSquircle extends CustomPainter {
  _DashedSquircle(this.color, this.fill);
  final Color color;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final path = SoftShapes.card().getOuterPath(Offset.zero & size);
    canvas.drawPath(path, Paint()..color = fill);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSquircle old) =>
      old.color != color || old.fill != fill;
}

/// Where the dragged widget will land.
class _DropPlaceholder extends StatelessWidget {
  const _DropPlaceholder();
  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    return CustomPaint(
      painter: _DashedSquircle(p.hairline, p.inset.withValues(alpha: 0.5)),
    );
  }
}

/// A free slot in edit mode: a dashed cell that adds a widget.
class _Hole extends StatelessWidget {
  const _Hole({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    final accent = HomeType.live(p);
    return Semantics(
      button: true,
      label: Strings.of(context).hwAddWidget,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: CustomPaint(
          painter: _DashedSquircle(
            accent.withValues(alpha: 0.75),
            accent.withValues(alpha: 0.06),
          ),
          child: Center(
            child: Icon(Icons.add_rounded, size: 26, color: accent),
          ),
        ),
      ),
    );
  }
}

/// A round handle at a corner of a tile in edit mode.
class _Handle extends StatelessWidget {
  const _Handle({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.hot = false,
  });

  /// The touch area is [extent] wide; the 26 dp disc at its centre hangs
  /// 7 dp out of the tile's corner.
  static const extent = 48.0;

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Its control is open.
  final bool hot;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: extent,
          child: Center(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: hot ? p.primary : p.track,
                shape: CircleBorder(
                  side: BorderSide(
                    color: hot ? p.primary : p.hairline,
                    width: 0.8,
                  ),
                ),
                shadows: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: SizedBox.square(
                dimension: 26,
                child: Icon(icon, size: 14, color: hot ? p.onPrimary : p.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header of edit mode: add, the title over how full the board is,
/// and done. It takes the place of the screen's own header.
class _EditBar extends StatelessWidget {
  const _EditBar({
    super.key,
    required this.plan,
    required this.onAdd,
    required this.onDone,
    required this.onHidden,
  });
  final HomeBoardPlan? plan;
  final VoidCallback onAdd;
  final VoidCallback onDone;
  final VoidCallback onHidden;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final plan = this.plan;
    final full = plan?.full ?? false;
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: HomeBoardMetrics.editBarHeight,
        child: HermesAppBar(
          automaticallyImplyLeading: false,
          // The title over how full the board is, in the bar's own height:
          // entering edit mode never moves the grid.
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.hwEditTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: MediaQuery.textScalerOf(
                  context,
                ).clamp(maxScaleFactor: 1.3),
              ),
              if (plan != null) ...[
                const SizedBox(height: 2),
                HomeBoardMeter(
                  key: const ValueKey('home-edit-meter'),
                  plan: plan,
                  onTap: plan.hidden.isEmpty ? null : onHidden,
                ),
              ],
            ],
          ),
          leading: IconButton(
            key: const ValueKey('home-edit-add'),
            tooltip: full ? s.hwBoardFull : s.hwAddWidget,
            onPressed: full ? null : onAdd,
            icon: const Icon(Icons.add_rounded),
          ),
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: SizedBox(
                width: 76,
                child: HermesPrimaryButton(
                  key: const ValueKey('home-edit-done'),
                  label: s.hwDone,
                  onTap: onDone,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
