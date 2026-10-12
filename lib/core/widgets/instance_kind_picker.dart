import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../l10n/app_localizations.dart';
import '../models/connection.dart';
import '../theme/app_theme.dart';

/// The icon that identifies a saved Hermes by where it lives. One table for
/// every place an instance is drawn (the list of Hermes, the switchers, the
/// first-run flow), so a kind never has two faces.
IconData instanceKindIcon(InstanceKind kind) => switch (kind) {
  InstanceKind.vps => Icons.dns_outlined,
  InstanceKind.homelab => Icons.storage_outlined,
  InstanceKind.pc => Icons.computer_outlined,
  InstanceKind.tailscale => Icons.vpn_lock_outlined,
  InstanceKind.localhost => Icons.terminal_outlined,
};

/// The plain words for a kind. A person does not say "homelab" or "VPS": they
/// say where the thing is.
String instanceKindLabel(Strings s, InstanceKind kind) => switch (kind) {
  InstanceKind.homelab => s.o2KindHome,
  InstanceKind.vps => s.o2KindServer,
  InstanceKind.tailscale => s.o2KindPrivate,
  InstanceKind.pc => s.o2KindComputer,
  InstanceKind.localhost => s.sIconTerminal,
};

/// "Where does this Hermes live?": one compact row of selectable tiles, an
/// icon over a word each, for the kinds [kOfferedInstanceKinds] lists. Shared
/// by the first-run confirmation and the connection screen.
///
/// A tile never truncates its label: when the words do not fit four across at
/// the current text size, the tiles wrap into rows of two (or one). A [value]
/// that is not offered any more (the retired on-device kind) still appears, as
/// an extra tile, so a saved connection keeps showing what it is.
class InstanceKindPicker extends StatelessWidget {
  const InstanceKindPicker({
    required this.value,
    required this.onChanged,
    this.title,
    this.entrance,
    super.key,
  });

  final InstanceKind value;
  final ValueChanged<InstanceKind> onChanged;

  /// A small heading above the row. The connection screen asks the question in
  /// its own block heading and leaves this null.
  final String? title;

  /// Wraps tile [index] (and the heading as index -1) in an entrance, so the
  /// first-run flow can make them join its stagger.
  final Widget Function(int index, Widget child)? entrance;

  static const double _gap = 8;
  static const double _padding = 6;
  static const double _fontSize = 12.5;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final kinds = [
      ...kOfferedInstanceKinds,
      if (!kOfferedInstanceKinds.contains(value)) value,
    ];
    final labelStyle = TextStyle(
      fontSize: _fontSize,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: c.textPrimary,
    );
    // The words follow the system text size up to 1.5x: at 2x a tile's word
    // would no longer fit two across a 320 dp phone.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.5);
    Widget wrap(int i, Widget child) =>
        entrance == null ? child : entrance!(i, child);
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            wrap(
              -1,
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Semantics(
                  header: true,
                  child: Text(
                    title!,
                    key: const ValueKey('instance-kind-title'),
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          _KindGrid(
            gap: _gap,
            children: [
              for (var i = 0; i < kinds.length; i++)
                wrap(
                  i,
                  _KindTile(
                    kind: kinds[i],
                    label: instanceKindLabel(s, kinds[i]),
                    selected: kinds[i] == value,
                    labelStyle: labelStyle,
                    scaler: scaler,
                    onTap: () => onChanged(kinds[i]),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KindGridData extends ContainerBoxParentData<RenderBox> {}

/// Lays the tiles out as equal-width tiles: all in one row when the widest
/// word of any label fits in a quarter of the width, otherwise two across,
/// otherwise one. It measures the real labels (their longest word, at the
/// current text size and font) instead of guessing, answers the intrinsic
/// queries the first-run frame makes, and never shrinks a tile below its
/// longest word, so a label is never cut.
class _KindGrid extends MultiChildRenderObjectWidget {
  const _KindGrid({required this.gap, required super.children});

  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderKindGrid(gap);

  @override
  void updateRenderObject(BuildContext context, _RenderKindGrid renderObject) {
    renderObject.gap = gap;
  }
}

class _RenderKindGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _KindGridData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _KindGridData> {
  _RenderKindGrid(this._gap);

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _KindGridData) child.parentData = _KindGridData();
  }

  Iterable<RenderBox> get _tiles sync* {
    var child = firstChild;
    while (child != null) {
      yield child;
      child = childAfter(child);
    }
  }

  /// Tiles per row for [width].
  int _across(double width) {
    var needed = 0.0;
    for (final tile in _tiles) {
      needed = math.max(needed, tile.getMinIntrinsicWidth(double.infinity));
    }
    for (final across in [math.min(childCount, 4), 2]) {
      if (across < 1 || across > childCount) continue;
      if ((width - _gap * (across - 1)) / across >= needed) return across;
    }
    return 1;
  }

  double _tileWidth(double width, int across) =>
      (width - _gap * (across - 1)) / across;

  /// Row heights for [width], each the tallest tile of its row.
  List<double> _rows(double width, double Function(RenderBox, double) height) {
    final across = _across(width);
    final tileWidth = _tileWidth(width, across);
    final rows = <double>[];
    var i = 0;
    for (final tile in _tiles) {
      final h = height(tile, tileWidth);
      if (i % across == 0) {
        rows.add(h);
      } else {
        rows[rows.length - 1] = math.max(rows.last, h);
      }
      i++;
    }
    return rows;
  }

  double _stack(List<double> rows) =>
      rows.fold(0.0, (sum, h) => sum + h) + _gap * math.max(0, rows.length - 1);

  @override
  double computeMinIntrinsicWidth(double height) {
    var needed = 0.0;
    for (final tile in _tiles) {
      needed = math.max(needed, tile.getMinIntrinsicWidth(double.infinity));
    }
    return needed;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    var sum = 0.0;
    for (final tile in _tiles) {
      sum += tile.getMaxIntrinsicWidth(double.infinity);
    }
    return sum + _gap * math.max(0, childCount - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _stack(_rows(width, (tile, w) => tile.getMinIntrinsicHeight(w)));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _stack(_rows(width, (tile, w) => tile.getMaxIntrinsicHeight(w)));

  double _widthFor(BoxConstraints constraints) => constraints.hasBoundedWidth
      ? constraints.maxWidth
      : constraints.constrainWidth(computeMaxIntrinsicWidth(double.infinity));

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final width = _widthFor(constraints);
    final rows = _rows(
      width,
      (tile, w) => tile.getDryLayout(BoxConstraints.tightFor(width: w)).height,
    );
    return constraints.constrain(Size(width, _stack(rows)));
  }

  @override
  void performLayout() {
    final width = _widthFor(constraints);
    final across = _across(width);
    final tileWidth = _tileWidth(width, across);
    final rows = _rows(width, (tile, w) {
      tile.layout(BoxConstraints.tightFor(width: w), parentUsesSize: true);
      return tile.size.height;
    });
    var y = 0.0;
    var i = 0;
    for (final tile in _tiles) {
      final row = i ~/ across;
      final column = i % across;
      if (column == 0 && row > 0) y += rows[row - 1] + _gap;
      tile.layout(
        BoxConstraints.tightFor(width: tileWidth, height: rows[row]),
        parentUsesSize: true,
      );
      (tile.parentData! as _KindGridData).offset = Offset(
        column * (tileWidth + _gap),
        y,
      );
      i++;
    }
    size = constraints.constrain(Size(width, _stack(rows)));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.kind,
    required this.label,
    required this.selected,
    required this.labelStyle,
    required this.scaler,
    required this.onTap,
  });

  final InstanceKind kind;
  final String label;
  final bool selected;
  final TextStyle labelStyle;
  final TextScaler scaler;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 150);
    final radius = BorderRadius.circular(18);
    // Matte, like every selection in the app: the accent tint over the
    // surface and a hairline of the accent, no shadow and no glow.
    final fill = selected
        ? Color.alphaBlend(c.accent.withValues(alpha: .16), c.surface)
        : c.surface;
    final edge = selected
        ? c.accent.withValues(alpha: .55)
        : c.divider.withValues(alpha: .8);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: AnimatedContainer(
        key: ValueKey('instance-kind-${kind.storageKey}'),
        duration: duration,
        curve: Curves.easeOut,
        constraints: const BoxConstraints(minHeight: 64),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: radius,
          border: Border.all(color: edge),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: InstanceKindPicker._padding,
                vertical: 10,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedScale(
                    duration: duration,
                    curve: Curves.easeOut,
                    scale: selected ? 1.1 : 1,
                    child: Icon(
                      instanceKindIcon(kind),
                      size: 24,
                      color: selected ? c.accentText : c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    textScaler: scaler,
                    style: labelStyle.copyWith(
                      color: selected ? c.textPrimary : c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
