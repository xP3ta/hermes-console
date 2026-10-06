import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'attachment_card.dart' show showImageGallery;

/// Bookkeeping shared by the cards of one [StackedImageCards]: which images
/// already have their file (for the gallery) and how to open it.
class ImageStackController {
  final Map<int, File> _ready = {};
  void Function(int index)? _open;

  /// A card reports its downloaded file. Plain bookkeeping, never a
  /// rebuild: the gallery reads it only when the user taps.
  void report(int index, File file) => _ready[index] = file;

  /// Opens the gallery on the card at [index].
  void open(int index) => _open?.call(index);

  /// The ready files in reply order, and where [index] lands among them.
  ({List<File> files, int initial}) galleryFrom(int index, int count) {
    final files = <File>[];
    var initial = 0;
    for (var i = 0; i < count; i++) {
      final f = _ready[i];
      if (f == null) continue;
      if (i == index) initial = files.length;
      files.add(f);
    }
    return (files: files, initial: initial);
  }
}

/// Tells an image card that it lives inside a stack at [index]: it fills
/// the card (cover) and a tap opens the stack's gallery.
class ImageStackScope extends InheritedWidget {
  const ImageStackScope({
    required this.controller,
    required this.index,
    required super.child,
    super.key,
  });

  final ImageStackController controller;
  final int index;

  static ImageStackScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ImageStackScope>();

  @override
  bool updateShouldNotify(ImageStackScope oldWidget) =>
      controller != oldWidget.controller || index != oldWidget.index;
}

/// Two or more consecutive images of one reply as a stack of cards: the
/// current image on top, full width with a soft shadow, and up to two
/// dimmed cards peeking ABOVE it (8 and 16 dp higher, 8 and 16 dp narrower
/// per side, same radius, no rotation). A badge shows the count.
///
/// A horizontal swipe cycles the top image with a spring; a tap opens the
/// gallery at the image on top. Every card stays mounted (only the top one
/// paints), so each image loads once and the gallery can page through all
/// that are ready.
class StackedImageCards extends StatefulWidget {
  const StackedImageCards({
    required this.children,
    this.onOpenGallery,
    super.key,
  }) : assert(children.length >= 2);

  /// The image cards, in reply order.
  final List<Widget> children;

  /// Test seam: replaces the real gallery route.
  final void Function(List<File> files, int initialIndex)? onOpenGallery;

  static const double maxWidth = 320;
  static const double aspect = 0.82;

  /// How far each card behind peeks above the one in front of it.
  static const double peek = 8;

  @override
  State<StackedImageCards> createState() => _StackedImageCardsState();
}

class _StackedImageCardsState extends State<StackedImageCards>
    with TickerProviderStateMixin {
  final ImageStackController _controller = ImageStackController();
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _enter = AnimationController(
    vsync: this,
    value: 1,
  );
  int _current = 0;
  double _width = StackedImageCards.maxWidth;

  int get _count => widget.children.length;

  @override
  void initState() {
    super.initState();
    _controller._open = _openGallery;
  }

  @override
  void didUpdateWidget(StackedImageCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_current >= _count) _current = 0;
  }

  @override
  void dispose() {
    _drag.dispose();
    _enter.dispose();
    super.dispose();
  }

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _openGallery(int index) {
    final gallery = _controller.galleryFrom(index, _count);
    if (gallery.files.isEmpty) return;
    final open = widget.onOpenGallery;
    if (open != null) {
      open(gallery.files, gallery.initial);
      return;
    }
    showImageGallery(context, gallery.files, initialIndex: gallery.initial);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _drag.stop();
    _drag.value += d.delta.dx;
  }

  Future<void> _onDragEnd(DragEndDetails d) async {
    final v = d.velocity.pixelsPerSecond.dx;
    final dx = _drag.value;
    final commit = dx.abs() > _width * 0.22 || v.abs() > 450;
    if (!commit) {
      _springTo(0, v);
      return;
    }
    final dir = (dx.abs() > 1 ? dx.sign : v.sign).toInt();
    // Left swipe shows the next image, right swipe the previous one.
    final next = (_current - dir) % _count;
    if (_reduceMotion) {
      _drag.value = 0;
      setState(() => _current = next);
      return;
    }
    await _drag.animateTo(
      dir * (_width + 32),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeIn,
    );
    if (!mounted) return;
    _drag.value = 0;
    setState(() => _current = next);
    _enter
      ..value = 0
      ..animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 420, damping: 30),
          0,
          1,
          0,
        ),
      );
  }

  void _springTo(double target, double velocity) {
    if (_reduceMotion) {
      _drag.value = target;
      return;
    }
    _drag.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 500, damping: 32),
        _drag.value,
        target,
        velocity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final radius = theme.hermesComponents.profile.shape.cardRadius;
    final s = Strings.of(context);
    final behind = math.min(_count - 1, 2);
    const peek = StackedImageCards.peek;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = math.min(
              constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : StackedImageCards.maxWidth,
              StackedImageCards.maxWidth,
            );
            _width = w;
            final h = (w * StackedImageCards.aspect).roundToDouble();
            final top = peek * behind;
            final cards = <Widget>[
              // Furthest first, so the nearer ones paint over it.
              for (var depth = behind; depth >= 1; depth--)
                Positioned(
                  key: ValueKey('image-stack-behind-$depth'),
                  top: top - peek * depth,
                  left: peek * depth,
                  right: peek * depth,
                  height: h,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // Dimmer the further back, yet always readable as a
                      // card on the chat background.
                      color: Color.lerp(
                        colors.surfaceVariant,
                        colors.textPrimary,
                        0.16 - 0.06 * depth,
                      )!.withValues(alpha: 1 - 0.18 * depth),
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(color: colors.divider),
                    ),
                  ),
                ),
              Positioned(
                top: top,
                left: 0,
                width: w,
                height: h,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_drag, _enter]),
                  builder: (context, child) {
                    // A new top card rises from the first card behind.
                    final e = _enter.value;
                    final scale = 1 - (1 - e) * (2 * peek / w);
                    return Transform.translate(
                      offset: Offset(_drag.value, -peek * (1 - e)),
                      child: Transform.scale(
                        scaleX: scale,
                        alignment: Alignment.topCenter,
                        child: child,
                      ),
                    );
                  },
                  child: _topCard(colors, radius),
                ),
              ),
              Positioned(
                top: top + 8,
                right: 8,
                child: IgnorePointer(child: _badge(colors)),
              ),
            ];
            return Semantics(
              container: true,
              label: s.fh1215ImageStackLabel(_current + 1, _count),
              child: GestureDetector(
                key: const ValueKey('image-stack'),
                onHorizontalDragUpdate: _onDragUpdate,
                onHorizontalDragEnd: (d) => _onDragEnd(d),
                child: SizedBox(
                  width: w,
                  height: top + h,
                  child: Stack(clipBehavior: Clip.none, children: cards),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _topCard(HermesThemeColors colors, double radius) => DecoratedBox(
    key: const ValueKey('image-stack-top'),
    decoration: BoxDecoration(
      color: colors.surfaceVariant,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: IndexedStack(
        index: _current,
        sizing: StackFit.expand,
        children: [
          for (var i = 0; i < _count; i++)
            ImageStackScope(
              controller: _controller,
              index: i,
              child: widget.children[i],
            ),
        ],
      ),
    ),
  );

  Widget _badge(HermesThemeColors colors) => DecoratedBox(
    key: const ValueKey('image-stack-count'),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.photo_library_outlined,
            size: 13,
            color: Colors.white,
          ),
          const SizedBox(width: 4),
          Text(
            '$_count',
            style: const TextStyle(
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    ),
  );
}
