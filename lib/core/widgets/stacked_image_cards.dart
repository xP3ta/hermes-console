import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import 'attachment_card.dart' show showImageGallery;

/// Bookkeeping shared by the cards of one [StackedImageCards]: which images
/// already have their file (for the gallery) and how to open it.
class ImageStackController {
  final Map<int, File> _ready = {};
  final Map<int, String> _names = {};
  void Function(int index)? _open;

  /// A card reports its downloaded file and, when known, its name. Plain
  /// bookkeeping, never a rebuild: the gallery reads it only when the user
  /// taps.
  void report(int index, File file, {String? name}) {
    _ready[index] = file;
    if (name == null) {
      _names.remove(index);
    } else {
      _names[index] = name;
    }
  }

  /// Opens the gallery on the card at [index].
  void open(int index) => _open?.call(index);

  /// The ready files in reply order with their names, and where [index]
  /// lands among them.
  ({List<File> files, List<String?> names, int initial}) galleryFrom(
    int index,
    int count,
  ) {
    final files = <File>[];
    final names = <String?>[];
    var initial = 0;
    for (var i = 0; i < count; i++) {
      final f = _ready[i];
      if (f == null) continue;
      if (i == index) initial = files.length;
      files.add(f);
      names.add(_names[i]);
    }
    return (files: files, names: names, initial: initial);
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

/// Two or more consecutive images of one reply as a deck of cards, as the
/// L2 chat design draws it (`hermes-132/maquetas/v2-cadu-console.html`,
/// `.stack`): the current image on top with a soft shadow, and up to two
/// dimmed cards of the same size behind it, each shifted up and to the end
/// and turned a little more ([behindOffset], [behindTurn]). A badge shows the
/// count and a caption under the deck says «N imágenes · toca para abrir».
///
/// A horizontal swipe cycles the top image with a spring; a tap (on the
/// card, the caption, or TalkBack's double tap) opens the gallery at the
/// image on top. Every card stays mounted (only the top one paints), so each
/// image loads once and the gallery can page through all that are ready.
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

  /// How far each card behind is shifted from the one in front of it
  /// (L2: 7 px to the end, 6 px up).
  static const Offset behindOffset = Offset(7, -6);

  /// How much more each card behind is turned (L2: 2°).
  static const double behindTurn = 2 * math.pi / 180;

  /// Opacity of the cards behind, nearest first (L2: .9 and .75).
  static const List<double> behindOpacity = [0.9, 0.75];

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
    showImageGallery(
      context,
      gallery.files,
      initialIndex: gallery.initial,
      names: gallery.names,
    );
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
    const offset = StackedImageCards.behindOffset;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final turn = StackedImageCards.behindTurn * behind;
            final room = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : StackedImageCards.maxWidth;
            // The furthest card sticks out to the end by its shift and what
            // its turn swings a corner (about h/2·sin): on a narrow phone
            // the deck gives that room up instead of drawing past it
            // (REVIEW-R5-B #18).
            final overhang = behind == 0
                ? 0.0
                : offset.dx * behind;
            final swing = behind == 0
                ? 0.0
                : StackedImageCards.aspect / 2 * math.sin(turn);
            final fits = (room - overhang) / (1 + swing);
            final w = math
                .min(StackedImageCards.maxWidth, fits)
                .floorToDouble();
            _width = w;
            final h = (w * StackedImageCards.aspect).roundToDouble();
            // Room above for the furthest card: its shift plus what its turn
            // lifts a top corner.
            final top = behind == 0
                ? 0.0
                : (-offset.dy * behind + w / 2 * math.sin(turn)).ceilToDouble();
            final rtl = Directionality.of(context) == TextDirection.rtl;
            final cards = <Widget>[
              // Furthest first, so the nearer ones paint over it.
              for (var depth = behind; depth >= 1; depth--)
                Positioned(
                  key: ValueKey('image-stack-behind-$depth'),
                  top: top,
                  left: 0,
                  width: w,
                  height: h,
                  child: Transform(
                    key: ValueKey('image-stack-behind-$depth-turn'),
                    alignment: Alignment.center,
                    transform: Matrix4.translationValues(
                      (rtl ? -offset.dx : offset.dx) * depth,
                      offset.dy * depth,
                      0,
                    )..rotateZ(
                        (rtl ? -1 : 1) * StackedImageCards.behindTurn * depth,
                      ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        // Dimmer the further back, yet always readable as a
                        // card on the chat background.
                        color: Color.lerp(
                          colors.surfaceVariant,
                          colors.textPrimary,
                          0.16 - 0.06 * depth,
                        )!.withValues(
                          alpha: StackedImageCards.behindOpacity[depth - 1],
                        ),
                        borderRadius: BorderRadius.circular(radius),
                        border: Border.all(color: colors.divider),
                      ),
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
                    return Transform.translate(
                      offset: Offset(
                        _drag.value + (rtl ? -offset.dx : offset.dx) * (1 - e),
                        offset.dy * (1 - e),
                      ),
                      child: Transform.rotate(
                        angle:
                            (rtl ? -1 : 1) *
                            StackedImageCards.behindTurn *
                            (1 - e),
                        child: child,
                      ),
                    );
                  },
                  child: _topCard(colors, radius),
                ),
              ),
              PositionedDirectional(
                top: top + 10,
                end: 10,
                child: IgnorePointer(child: _badge(colors)),
              ),
            ];
            return Semantics(
              container: true,
              // Where the deck is, then «5 imágenes, toca para abrir».
              label: s.fh1215ImageStackLabel(_current + 1, _count),
              hint: s.chaImageStackSemantics(_count),
              onTap: () => _controller.open(_current),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    key: const ValueKey('image-stack'),
                    onHorizontalDragUpdate: _onDragUpdate,
                    onHorizontalDragEnd: (d) => _onDragEnd(d),
                    child: SizedBox(
                      width: w,
                      height: top + h,
                      child: Stack(clipBehavior: Clip.none, children: cards),
                    ),
                  ),
                  ExcludeSemantics(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _controller.open(_current),
                      child: SizedBox(
                        width: w,
                        child: Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            2,
                            8,
                            2,
                            0,
                          ),
                          child: Text(
                            s.chaImageStackCaption(_count),
                            key: const ValueKey('image-stack-caption'),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.3,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
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

  /// L2 `.badge`: the count alone in a dark pill over the image.
  Widget _badge(HermesThemeColors colors) => DecoratedBox(
    key: const ValueKey('image-stack-count'),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.66),
      borderRadius: BorderRadius.circular(HermesRadius.tag),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      child: Text(
        '$_count',
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    ),
  );
}
