import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'guided_tour.dart';

/// Colour of the dim layer around a spotlight (every tour, dock too).
const Color guideScrimColor = Color(0x8C000000);

/// Air between a target and the edge of its spotlight.
const double guideSpotlightPadding = 6;

/// The dim layer of a tour with a rounded hole around [hole].
class GuideSpotlightPainter extends CustomPainter {
  final Rect? hole;
  final Color color;

  const GuideSpotlightPainter({
    required this.hole,
    this.color = guideScrimColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final all = Path()..addRect(Offset.zero & size);
    final rect = hole;
    final path = rect == null
        ? all
        : Path.combine(
            PathOperation.difference,
            all,
            Path()..addRRect(
              RRect.fromRectAndRadius(
                rect,
                Radius.circular(math.min(rect.shortestSide / 2, 24)),
              ),
            ),
          );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(GuideSpotlightPainter old) =>
      old.hole != hole || old.color != color;
}

/// The card every tour uses: a small tag, a title, a short text and its
/// buttons.
class GuideCard extends StatelessWidget {
  final String? tag;
  final String title;
  final String? body;
  final List<Widget> actions;
  final Widget? trailing;
  final bool compact;

  /// Floating over the screen (tours, hint) or lying in a screen's flow.
  final bool elevated;

  /// In a box shorter than the card (big text, small screen) only the text
  /// scrolls: Saltar and the step's buttons always stay in reach.
  final bool scrollText;

  const GuideCard({
    required this.title,
    this.tag,
    this.body,
    this.actions = const [],
    this.trailing,
    this.compact = false,
    this.elevated = true,
    this.scrollText = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          key: const ValueKey('guide-card-title'),
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: compact ? 14 : 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (body != null) ...[
          const SizedBox(height: 4),
          Text(body!, style: TextStyle(color: colors.textSecondary)),
        ],
      ],
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        color: colors.surface,
        elevation: elevated ? 10 : 0,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, compact ? 12 : 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (tag != null || trailing != null)
                Row(
                  children: [
                    Expanded(
                      child: tag == null
                          ? const SizedBox.shrink()
                          : Text(
                              tag!,
                              style: TextStyle(
                                color: colors.accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    ?trailing,
                  ],
                ),
              if (scrollText)
                Flexible(child: SingleChildScrollView(child: text))
              else
                text,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws the running tour over the whole app: a dim layer with a
/// spotlight on the real widget of the current step and the step's card.
///
/// It sits above the navigator (MaterialApp.builder) and finds targets by
/// their `ValueKey` in what the navigator shows, so screens need no hooks.
/// A target counts only when it is on screen and a touch there would reach
/// it (not covered by a sheet, a route or App Lock). The spotlight follows
/// the target's rect after every frame. With no tour, or while [locked],
/// it adds nothing on top of [child]: no barrier is ever left behind.
class GuideLayer extends StatefulWidget {
  final Widget child;
  final ValueListenable<bool>? locked;
  final GuideController? controller;

  const GuideLayer({
    required this.child,
    this.locked,
    this.controller,
    super.key,
  });

  @override
  State<GuideLayer> createState() => _GuideLayerState();
}

class _GuideLayerState extends State<GuideLayer> {
  GuideController get _c => widget.controller ?? GuideController.instance;

  final GlobalKey _content = GlobalKey(debugLabel: 'guide-content');
  final GlobalKey _layer = GlobalKey(debugLabel: 'guide-layer');

  /// The current step's target and its rect in this layer.
  Element? _target;
  Rect? _rect;
  bool _frameQueued = false;

  /// Whether Atrás and Terminar apply, read outside build (finding targets
  /// walks the tree, which build may not do).
  bool _canBack = false;
  bool _last = false;

  void _readButtons() {
    _canBack = _c.canGoBack;
    _last = _c.isLastStep;
  }

  bool get _locked => widget.locked?.value ?? false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onTour);
    _c.probe = _probe;
    widget.locked?.addListener(_onLock);
    _onTour();
  }

  @override
  void didUpdateWidget(covariant GuideLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      (oldWidget.controller ?? GuideController.instance).removeListener(
        _onTour,
      );
      _c.addListener(_onTour);
      _c.probe = _probe;
    }
    if (!identical(oldWidget.locked, widget.locked)) {
      oldWidget.locked?.removeListener(_onLock);
      widget.locked?.addListener(_onLock);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onTour);
    if (_c.probe == _probe) _c.probe = null;
    widget.locked?.removeListener(_onLock);
    super.dispose();
  }

  void _onLock() {
    _c.setPaused(_locked);
    if (!mounted) return;
    setState(() {});
    _queueFrame(kick: true);
  }

  /// The tour changed (started, moved, ended): the new step's target is
  /// found at once, so the spotlight never blinks between two steps.
  void _onTour() {
    final step = _c.currentStep;
    Element? element;
    Rect? rect;
    if (step != null && !_locked && _content.currentContext != null) {
      element = _find(step);
      rect = element == null ? null : _visibleRect(element);
    }
    _target = rect == null ? null : element;
    _rect = rect;
    if (step != null && _content.currentContext != null) _readButtons();
    if (!mounted) return;
    setState(() {});
    _queueFrame(kick: true);
  }

  /// Checks the target after the next frame, and after every frame while a
  /// tour runs. Only a change of tour or lock asks for a frame ([kick]):
  /// otherwise an idle screen stays idle.
  void _queueFrame({bool kick = false}) {
    if (!_c.active) return;
    if (kick) WidgetsBinding.instance.ensureVisualUpdate();
    if (_frameQueued) return;
    _frameQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameQueued = false;
      if (!mounted || !_c.active) return;
      _afterFrame();
      _queueFrame();
    });
  }

  void _afterFrame() {
    _c.setPaused(_locked);
    if (_locked) return;
    if (_c.step == null) {
      _c.showFirstAvailable();
      return;
    }
    final step = _c.currentStep!;
    var element = _target;
    if (element == null ||
        !element.mounted ||
        !step.matches(element.widget.key)) {
      element = _find(step);
    }
    final rect = element == null ? null : _visibleRect(element);
    if (rect == null) {
      _c.targetLost();
    } else {
      _c.targetFound();
    }
    final back = _canBack;
    final last = _last;
    // Walking the tree for the other steps costs more than a frame should:
    // only when this step's target came, went or changed.
    if (element != _target || (rect == null) != (_rect == null)) {
      _readButtons();
    }
    if (element != _target ||
        rect != _rect ||
        back != _canBack ||
        last != _last) {
      setState(() {
        _target = rect == null ? null : element;
        _rect = rect;
      });
    }
  }

  bool _probe(GuideStep step) => !_locked && _find(step) != null;

  /// The first widget in what the navigator shows that [step] points at
  /// and that is really on screen.
  Element? _find(GuideStep step) {
    final root = _content.currentContext;
    if (root == null) return null;
    for (final spec in step.targets) {
      Element? found;
      void visit(Element element) {
        if (found != null) return;
        final key = element.widget.key;
        if (key is ValueKey<String> &&
            guideKeyMatches(spec, key.value) &&
            _visibleRect(element) != null) {
          found = element;
          return;
        }
        element.visitChildren(visit);
      }

      root.visitChildElements(visit);
      if (found != null) return found;
    }
    return null;
  }

  /// [element]'s rect in this layer when part of it is on screen (above
  /// the keyboard) and a touch there reaches it; null otherwise.
  Rect? _visibleRect(Element element) {
    final box = element.renderObject;
    final content = _content.currentContext?.findRenderObject();
    final layer = _layer.currentContext?.findRenderObject();
    if (box is! RenderBox ||
        content is! RenderBox ||
        layer is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        !layer.hasSize ||
        box.size.isEmpty) {
      return null;
    }
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(layer),
      Offset.zero & box.size,
    );
    final screen = Rect.fromLTRB(
      0,
      0,
      layer.size.width,
      layer.size.height - MediaQuery.viewInsetsOf(context).bottom,
    );
    final visible = rect.intersect(screen);
    if (visible.width < 8 || visible.height < 8) return null;
    // Nine points over the visible part: one touch that reaches it is
    // enough (a floating header may cover an edge).
    for (final fx in const [.5, .2, .8]) {
      for (final fy in const [.5, .2, .8]) {
        final point = Offset(
          visible.left + visible.width * fx,
          visible.top + visible.height * fy,
        );
        final result = BoxHitTestResult();
        content.hitTest(
          result,
          position: content.globalToLocal(layer.localToGlobal(point)),
        );
        if (result.path.any((entry) => identical(entry.target, box))) {
          return rect;
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final step = _c.currentStep;
    final rect = _rect;
    final show = step != null && rect != null && !_locked;
    // The stack stays the same with or without a tour, so the navigator
    // under it is never rebuilt from scratch.
    return Stack(
      key: _layer,
      fit: StackFit.expand,
      children: [
        KeyedSubtree(key: _content, child: widget.child),
        if (show) _overlay(context, step, rect),
      ],
    );
  }

  Widget _overlay(BuildContext context, GuideStep step, Rect target) {
    final strings = Strings.of(context);
    final media = MediaQuery.of(context);
    final size = media.size;
    final hole = target
        .inflate(guideSpotlightPadding)
        .intersect(Offset.zero & size);
    final top = media.padding.top + 8;
    final bottom =
        size.height -
        math.max(media.padding.bottom, media.viewInsets.bottom) -
        8;
    final above = hole.center.dy > (top + bottom) / 2;
    final room = above ? hole.top - 12 - top : bottom - hole.bottom - 12;
    final index = _c.step ?? 0;
    final total = _c.steps.length;
    final last = _last;
    final card = GuideCard(
      key: const ValueKey('guide-card'),
      scrollText: true,
      tag: strings.gdTourStep(index + 1, total),
      title: step.title(strings),
      body: step.body(strings),
      trailing: TextButton(
        key: const ValueKey('guide-skip'),
        onPressed: _c.skip,
        child: Text(strings.gdTourSkip),
      ),
      actions: [
        if (_canBack)
          TextButton(
            key: const ValueKey('guide-back'),
            onPressed: _c.back,
            child: Text(strings.gdTourBack),
          ),
        FilledButton.tonal(
          key: const ValueKey('guide-next'),
          onPressed: _c.next,
          child: Text(last ? strings.gdTourDone : strings.gdTourNext),
        ),
      ],
    );
    final width = math.min(size.width - 28, 420.0);
    final left = (size.width - width) / 2;
    Widget placed(Widget child, {required double maxHeight}) => ConstrainedBox(
      key: const ValueKey('guide-card-box'),
      constraints: BoxConstraints(maxHeight: math.max(maxHeight, 0)),
      child: child,
    );
    // A target too tall to leave room on either side: the card sits at the
    // bottom of the screen, over the target.
    final fits = room >= 140;
    return Positioned.fill(
      key: const ValueKey('guide-layer'),
      child: BlockSemantics(
        child: Semantics(
          scopesRoute: true,
          explicitChildNodes: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                key: const ValueKey('guide-scrim'),
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: CustomPaint(
                  key: const ValueKey('guide-spotlight'),
                  painter: GuideSpotlightPainter(hole: hole),
                ),
              ),
              if (fits && above)
                Positioned(
                  left: left,
                  width: width,
                  bottom: size.height - hole.top + 12,
                  child: placed(card, maxHeight: room),
                )
              else if (fits)
                Positioned(
                  left: left,
                  width: width,
                  top: hole.bottom + 12,
                  child: placed(card, maxHeight: room),
                )
              else
                Positioned(
                  left: left,
                  width: width,
                  bottom: size.height - bottom,
                  child: placed(card, maxHeight: (bottom - top) / 2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
