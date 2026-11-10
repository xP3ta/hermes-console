import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../services/chat_stream_trace.dart';
import '../../theme/hermes_tokens.dart';
import '../../utils/frame_stream_reveal.dart';

int _activeRevealClocks = 0;
Future<ui.FragmentProgram>? _replyProgram;
ui.FragmentProgram? _compiledReplyProgram;

/// Also used by pixel tests to await the bundled shader, outside fake time.
@visibleForTesting
Future<void> warmLiveReplyShader() async {
  _compiledReplyProgram = await (_replyProgram ??= ui.FragmentProgram.fromAsset(
    'shaders/live_reply_tail.frag',
  ));
}

int get debugActiveLiveReplyClocks => _activeRevealClocks;

/// The reply is composed on source arrival. Frames reveal that composition;
/// they never rebuild its Markdown, closed paragraphs, header or activity.
///
/// The rendered text supplies the buffer's offsets, so Markdown delimiters
/// do not consume animation time and rich text/RTL keep their real geometry.
/// Height follows separately. The last few graphemes fade in; a stalled
/// stream finishes that fade and releases its clock. No live semantics are
/// added: TalkBack can read the authoritative reply without token notices.
class LiveReplyReveal extends StatefulWidget {
  const LiveReplyReveal({
    required this.child,
    required this.revision,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final Object revision;
  final bool enabled;

  /// Whether [context] is drawn inside a live reply.
  ///
  /// The reveal only reads plain paragraphs ([RenderParagraph]): a block
  /// drawn there puts its words in them, and draws them the same way when
  /// the reply finishes, so nothing moves at that moment.
  static bool live(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LiveReplyScope>() != null;

  /// Whether [context] is drawn inside a live reply that reveals its text.
  ///
  /// The reveal clips everything below the line being read, so a block
  /// drawn there must draw nothing below its last word that is not real
  /// content (no placeholder frame, no blank rows): the clip would show
  /// that only between arrivals, and hide it again on the next one.
  ///
  /// This follows the reply and the stable reduce-motion preference only.
  /// The reveal also pauses while the reader holds the transcript, while
  /// the app is in the background or its route is covered; the block must
  /// keep its shape then, or the reply changes height under the reader.
  static bool revealing(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LiveReplyScope>()?.animates ??
      false;

  @override
  State<LiveReplyReveal> createState() => _LiveReplyRevealState();
}

class _LiveReplyScope extends InheritedWidget {
  const _LiveReplyScope({required this.animates, required super.child});

  final bool animates;

  @override
  bool updateShouldNotify(_LiveReplyScope oldWidget) =>
      animates != oldWidget.animates;
}

/// The frame of a block inside a live reply, such as a table's border.
///
/// The reveal clips everything below the line it reads, except the glyphs
/// it has read, so a frame that holds no text would show only between
/// arrivals and be hidden again on the next one. While the line being read
/// is inside this box, the reveal also paints its [edges]: the sides from
/// that line down to the foot of the row being read (a [RenderTable] row
/// inside), and the foot itself when that row is the last one. The reply
/// grows to that foot.
class LiveReplyFrame extends SingleChildRenderObjectWidget {
  const LiveReplyFrame({required this.edges, super.child, super.key});

  /// How far in from each side this box draws nothing but its frame (its
  /// border and the padding next to it). The top is not used.
  final EdgeInsets edges;

  @override
  RenderLiveReplyFrame createRenderObject(BuildContext context) =>
      RenderLiveReplyFrame(edges);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiveReplyFrame renderObject,
  ) {
    renderObject.edges = edges;
  }
}

/// The render object of a [LiveReplyFrame].
class RenderLiveReplyFrame extends RenderProxyBox {
  RenderLiveReplyFrame(this.edges);

  /// See [LiveReplyFrame.edges].
  EdgeInsets edges;

  /// The bottom of each row of the first table inside, top to bottom, in
  /// this box's coordinates; this box's own bottom when it holds none.
  List<double> rowBottoms() {
    RenderTable? table;
    void search(RenderObject object) {
      if (table != null) return;
      if (object is RenderTable) {
        table = object;
        return;
      }
      object.visitChildren(search);
    }

    visitChildren(search);
    final found = table;
    if (found == null || !found.hasSize || found.rows == 0) {
      return [size.height];
    }
    final transform = found.getTransformTo(this);
    return [
      for (var row = 0; row < found.rows; row++)
        MatrixUtils.transformPoint(
          transform,
          Offset(0, found.getRowBox(row).bottom),
        ).dy,
    ];
  }
}

/// A [LiveReplyFrame] in the reveal's coordinates.
typedef _ReplyFrame = ({Rect rect, EdgeInsets edges, List<double> rowBottoms});

class _LiveReplyRevealState extends State<LiveReplyReveal>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _foreground = true;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final cached = _compiledReplyProgram;
      if (cached != null) {
        _shader = cached.fragmentShader();
        return;
      }
      await warmLiveReplyShader();
      final program = await _replyProgram!;
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (error) {
      // Unsupported renderers keep the seek-safe reveal without opacity;
      // never hide a reply because an optional paint effect cannot load.
      debugPrint(
        '[live-reply] opacity shader unavailable (${error.runtimeType})',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground != _foreground) setState(() => _foreground = foreground);
  }

  @override
  Widget build(BuildContext context) {
    final animates = !HermesMotion.reduced(context);
    return _RevealBox(
      vsync: this,
      revision: widget.revision,
      shader: _shader,
      enabled:
          widget.enabled &&
          _foreground &&
          animates &&
          TickerMode.valuesOf(context).enabled,
      child: _LiveReplyScope(animates: animates, child: widget.child),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shader?.dispose();
    super.dispose();
  }
}

class _RevealBox extends SingleChildRenderObjectWidget {
  const _RevealBox({
    required this.vsync,
    required this.revision,
    required this.enabled,
    required this.shader,
    required super.child,
  });

  final TickerProvider vsync;
  final Object revision;
  final bool enabled;
  final ui.FragmentShader? shader;

  @override
  RenderLiveReplyReveal createRenderObject(BuildContext context) =>
      RenderLiveReplyReveal(
        vsync: vsync,
        revision: revision,
        enabled: enabled,
        shader: shader,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiveReplyReveal renderObject,
  ) {
    renderObject
      ..revision = revision
      ..shader = shader
      ..enabled = enabled;
  }
}

/// Public diagnostics let integration tests assert *painted* visibility.
/// Text finders alone would also find the not-yet-painted authoritative tail.
class RenderLiveReplyReveal extends RenderProxyBox {
  RenderLiveReplyReveal({
    required TickerProvider vsync,
    required this._revision,
    required this._enabled,
    this._shader,
  }) {
    _ticker = vsync.createTicker(_tick);
  }

  static const int _fadeGraphemes = 24;
  final FrameStreamReveal _buffer = FrameStreamReveal();
  late final Ticker _ticker;
  Object _revision;
  bool _enabled;
  bool _geometryDirty = true;
  bool _geometryScheduled = false;
  bool _hasGeometry = false;
  bool _animationLayout = false;
  bool _skipNextReveal = false;
  BoxConstraints? _lastConstraints;
  Duration _lastTick = Duration.zero;
  Duration _now = Duration.zero;
  Duration _tailAge = Duration.zero;
  Duration _heightAge = Duration.zero;
  double _height = 0;
  double _heightFrom = 0;
  double _heightTo = 0;
  int _opaqueEnd = 0;
  List<_ReplyRun> _runs = [];
  Map<RenderParagraph, _ReplyRun> _runCache = {};
  Path _visible = Path();
  Path _safePrefix = Path();
  double _safeBottom = 0;
  int _safeClipRectCount = 0;
  int _clipRectCount = 0;
  Path _tail = Path();
  bool _hasTail = false;
  ui.FragmentShader? _shader;
  final LayerHandle<ShaderMaskLayer> _maskLayer =
      LayerHandle<ShaderMaskLayer>();
  final List<({Rect rect, double opacity})> _fadeBoxes = [];
  Map<int, double> _tailOpacities = {};

  @visibleForTesting
  bool paintsPosition(Offset position) => _visible.contains(position);

  @visibleForTesting
  Map<int, double> get tailOpacities => Map.unmodifiable(_tailOpacities);

  @visibleForTesting
  int get clipRectCount => _clipRectCount;

  set shader(ui.FragmentShader? value) {
    if (identical(_shader, value)) return;
    _shader = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @visibleForTesting
  int geometryBuilds = 0;

  @visibleForTesting
  int get revealedEnd => _buffer.end;

  @visibleForTesting
  String get visibleText => _buffer.source.substring(0, _buffer.end);

  @visibleForTesting
  bool get settled => !_ticker.isActive;

  @visibleForTesting
  bool get usesTailShader => _shader != null && _hasTail;

  set revision(Object value) {
    if (identical(value, _revision)) return;
    _revision = value;
    markNeedsLayout();
  }

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    // Returning to the bottom/foreground does not replay text received away.
    if (value) _skipNextReveal = true;
    if (!value) {
      _buffer.finish();
      _stop();
    }
    markNeedsLayout();
  }

  @override
  void markNeedsLayout() {
    if (!_animationLayout) _geometryDirty = true;
    super.markNeedsLayout();
  }

  void _start() {
    if (_ticker.isActive || !attached || !_enabled) return;
    _lastTick = Duration.zero;
    _activeRevealClocks++;
    // Called from layout, inside a frame. Ticker records that frame's time,
    // preserving the entire interval before the first tick (including a
    // long first frame); starting it in a network callback lost that time.
    _ticker.start();
  }

  void _stop() {
    if (!_ticker.isActive) return;
    _ticker.stop();
    _activeRevealClocks--;
  }

  void _tick(Duration elapsed) {
    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    _now += delta;
    final before = _buffer.end;
    _buffer.advance(delta);
    _tailAge = _buffer.caughtUp ? _tailAge + delta : Duration.zero;
    _heightAge += delta;
    if (_buffer.end != before) {
      ChatStreamTrace.mark(
        ChatStreamPoint.reveal,
        chars: _buffer.end - before,
        pending: _buffer.source.length - _buffer.end,
      );
    }
    _animationLayout = true;
    markNeedsLayout();
    _animationLayout = false;
    markNeedsPaint();
  }

  void _readGeometry() {
    geometryBuilds++;
    final next = <_ReplyRun>[];
    final cache = <RenderParagraph, _ReplyRun>{};
    _ReplyFrame? frame;
    void visit(RenderObject object) {
      if (object is RenderOffstage && object.offstage) return;
      if (object is RenderLiveReplyFrame && object.hasSize) {
        final outer = frame;
        final transform = object.getTransformTo(this);
        frame = (
          rect: MatrixUtils.transformRect(transform, Offset.zero & object.size),
          edges: object.edges,
          rowBottoms: [
            for (final bottom in object.rowBottoms())
              MatrixUtils.transformPoint(transform, Offset(0, bottom)).dy,
          ],
        );
        object.visitChildren(visit);
        frame = outer;
        return;
      }
      if (object is RenderParagraph) {
        final span = object.text;
        // Icons are RichText too; they must not delay the prose.
        if (span.style?.fontFamily == 'MaterialIcons') return;
        final cached = _runCache[object];
        final run = cached != null && cached.matches(object)
            ? cached
            : _ReplyRun(object);
        run.offset = MatrixUtils.transformPoint(
          object.getTransformTo(this),
          Offset.zero,
        );
        run.sourceOrder = next.length;
        run.frame = frame;
        next.add(run);
        cache[object] = run;
        return;
      }
      object.visitChildren(visit);
    }

    if (child != null) visit(child!);
    next.sort((a, b) {
      final vertical = a.offset.dy.compareTo(b.offset.dy);
      // The composition's child order already follows Row/Table's reading
      // direction. Sorting equal-height cells by X would reverse RTL.
      return vertical != 0 ? vertical : a.sourceOrder.compareTo(b.sourceOrder);
    });
    final source = StringBuffer();
    var offset = 0;
    final overlapping = <_ReplyRun>[];
    var prefixBottom = 0.0;
    for (var index = 0; index < next.length; index++) {
      final run = next[index];
      run.index = index;
      // Cache only earlier siblings whose vertical bands overlap this run.
      // Ordinary closed paragraphs leave this sweep immediately; their
      // growing prefix must never become a native Path copy on each tick.
      overlapping.removeWhere(
        (previous) => previous.bounds.bottom <= run.offset.dy,
      );
      run.priorSiblings = List.of(overlapping);
      run.prefixBottom = prefixBottom;
      prefixBottom = math.max(prefixBottom, run.bounds.bottom);
      overlapping.add(run);
      if (source.isNotEmpty) {
        source.write('\n');
        offset++;
      }
      run.start = offset;
      source.write(run.text);
      offset += run.text.length;
    }
    for (final entry in _runCache.entries) {
      if (!identical(cache[entry.key], entry.value)) entry.value.dispose();
    }
    _runs = next;
    _runCache = cache;
    final text = source.toString();
    if (!text.startsWith(_buffer.source)) _tailOpacities.clear();
    _buffer.observe(text, _now);
    _opaqueEnd = math.min(_opaqueEnd, _buffer.end);
    if (!_enabled || _skipNextReveal) {
      _buffer.finish();
      _opaqueEnd = _buffer.end;
      _skipNextReveal = false;
    }
    // This post-layout mask is ready for the next arrival's first paint.
    // A settled full-box clip would also expose new letters in its blank
    // tail before their geometry is observed at the end of that frame.
    _rememberSafePrefix(_prefixVisibility());
    _makeTail();
  }

  void _scheduleGeometry() {
    if (_geometryScheduled) return;
    _geometryScheduled = true;
    // Descendant transforms (for example an aligned code-block transform)
    // may read their own sizes. Read after the layout phase, when that is
    // legal, once per source/layout change; frames reuse the resulting cache.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryScheduled = false;
      if (!attached || child == null) return;
      _now = SchedulerBinding.instance.currentFrameTimeStamp;
      _readGeometry();
      _hasGeometry = true;
      _geometryDirty = false;
      _animationLayout = true;
      markNeedsLayout();
      _animationLayout = false;
    });
  }

  _ReplyRun? _runAt(int end) {
    var low = 0;
    var high = _runs.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_runs[mid].start < end) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low == 0 ? null : _runs[low - 1];
  }

  double _visibility(double fullHeight) {
    _clipRectCount = 0;
    if (!_enabled) {
      _visible = Path()
        ..addRect(Rect.fromLTWH(0, 0, child!.size.width, fullHeight));
      _clipRectCount = 1;
      _hasTail = false;
      return fullHeight;
    }
    if (!_hasGeometry) {
      _visible = Path();
      return 0;
    }
    if (_geometryScheduled && !_skipNextReveal) {
      _visible = _safePrefix;
      _clipRectCount = _safeClipRectCount;
      return _safeBottom;
    }
    final bottom = _prefixVisibility();
    _rememberSafePrefix(bottom);
    if (_buffer.caughtUp) {
      _visible = Path()
        ..addRect(Rect.fromLTWH(0, 0, child!.size.width, fullHeight));
      _clipRectCount = 1;
    }
    _makeTail();
    return _buffer.caughtUp ? fullHeight : bottom;
  }

  void _rememberSafePrefix(double bottom) {
    // Keep the immutable bounded band path; never clone/mutate a growing
    // path of all completed paragraphs on display ticks.
    _safePrefix = _visible;
    _safeClipRectCount = _clipRectCount;
    _safeBottom = _buffer.caughtUp ? child!.size.height : bottom;
  }

  double _prefixVisibility() {
    _visible = Path();
    _clipRectCount = 0;
    final run = _runAt(_buffer.end);
    if (run == null) return 0;
    final end = math.min(run.text.length, _buffer.end - run.start);
    if (end <= 0) return math.max(run.prefixBottom, run.offset.dy);
    final line = run.lineAt(end - 1);
    final boxes = run.boxes(line.start, end);
    if (boxes.isEmpty) return math.max(run.prefixBottom, run.offset.dy);
    final top = boxes.map((box) => box.top).reduce(math.min);
    final bottom = boxes.map((box) => box.bottom).reduce(math.max);
    _visible.addRect(Rect.fromLTWH(0, 0, child!.size.width, math.max(0, top)));
    _clipRectCount++;
    for (final previous in run.priorSiblings) {
      final rect = previous.bounds;
      if (rect.bottom <= top) continue;
      _visible.addRect(
        Rect.fromLTRB(
          rect.left,
          math.max(top, rect.top),
          rect.right,
          rect.bottom,
        ),
      );
      _clipRectCount++;
    }
    for (final box in boxes) {
      _visible.addRect(box);
      _clipRectCount++;
    }
    final frame = run.frame;
    if (frame == null) return math.max(run.prefixBottom, bottom);
    // The frame around the line being read stays painted: its sides from
    // this line down to the foot of the row being read, and the frame's
    // own foot when that row is its last. Neither holds text.
    //
    // Once all that came is read the whole box shows. This path is then
    // what stays painted in the frame where more text arrives, before its
    // geometry is read, while the box keeps its height: a new row starts
    // below the old foot, in the table's margin, and its sides would be
    // cut there. So the whole frame is kept and its sides run to the
    // bottom of the box; a new row's first glyph is 9 dp further down.
    final rect = frame.rect;
    final edges = frame.edges;
    var foot = rect.bottom;
    if (!_buffer.caughtUp) {
      for (final rowBottom in frame.rowBottoms) {
        if (rowBottom >= bottom - 0.5) {
          foot = rowBottom;
          break;
        }
      }
    }
    if (rect.bottom - foot <= edges.bottom) foot = rect.bottom;
    final down = _buffer.caughtUp ? math.max(foot, child!.size.height) : foot;
    _visible
      ..addRect(Rect.fromLTRB(rect.left, top, rect.left + edges.left, down))
      ..addRect(Rect.fromLTRB(rect.right - edges.right, top, rect.right, down));
    _clipRectCount += 2;
    if (foot == rect.bottom) {
      _visible.addRect(
        Rect.fromLTRB(rect.left, foot - edges.bottom, rect.right, foot),
      );
      _clipRectCount++;
    }
    return math.max(math.max(run.prefixBottom, bottom), foot);
  }

  void _makeTail() {
    _tail = Path();
    _fadeBoxes.clear();
    _hasTail = false;
    if (!_enabled || _buffer.end == 0) return;
    if (_buffer.caughtUp && _tailAge >= HermesMotion.fast) {
      _opaqueEnd = _buffer.end;
      _tailOpacities.clear();
      return;
    }
    final start = math.max(_opaqueEnd, _buffer.tailStart(_fadeGraphemes));
    _opaqueEnd = start;
    final boundaries = _buffer.tailBoundaries(_fadeGraphemes);
    final fade = _buffer.caughtUp
        ? (_tailAge.inMicroseconds / HermesMotion.fast.inMicroseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final opacities = <int, double>{};
    for (var index = 1; index < boundaries.length; index++) {
      final from = math.max(start, boundaries[index - 1]);
      final to = boundaries[index];
      if (from >= to) continue;
      final base =
          ((boundaries.length - index + _buffer.fractionalProgress) /
                  _fadeGraphemes)
              .clamp(0.0, 1.0);
      // New arrivals restart the tail clock, but never dim a glyph that
      // already faded in. Only the bounded visible tail needs this ledger.
      final opacity = math.max(
        _tailOpacities[to] ?? 0,
        base + (1 - base) * fade,
      );
      opacities[to] = opacity;
      var cursor = to;
      while (cursor > from) {
        final run = _runAt(cursor);
        if (run == null) break;
        final end = math.min(run.text.length, cursor - run.start);
        final localStart = math.max(0, from - run.start);
        for (final box in run.boxes(localStart, end)) {
          // At most 24 clusters; split bidi/style boxes have a small cap.
          if (_fadeBoxes.length < 32) {
            _fadeBoxes.add((rect: box, opacity: opacity));
            _tail.addRect(box);
            _hasTail = true;
          }
        }
        cursor = run.start - 1;
      }
    }
    _tailOpacities = opacities;
  }

  @override
  void performLayout() {
    final box = child;
    if (box == null) {
      size = constraints.smallest;
      _stop();
      return;
    }
    box.layout(constraints, parentUsesSize: true);
    if (_geometryDirty || _lastConstraints != constraints) {
      _scheduleGeometry();
      _lastConstraints = constraints;
    }
    final target = _visibility(box.size.height).clamp(0.0, box.size.height);
    if (!_enabled || _skipNextReveal) {
      _height = _heightFrom = _heightTo = target;
      _heightAge = HermesMotion.base;
    } else {
      // Sample before retargeting: resetting the age first on each new
      // line would freeze height throughout a large burst.
      final t = (_heightAge.inMicroseconds / HermesMotion.base.inMicroseconds)
          .clamp(0.0, 1.0);
      _height =
          _heightFrom +
          (_heightTo - _heightFrom) * HermesMotion.standard.transform(t);
      if ((target - _heightTo).abs() > 0.01) {
        _heightFrom = _height;
        _heightTo = target;
        _heightAge = Duration.zero;
      }
    }
    size = constraints.constrain(Size(box.size.width, _height));
    if (_enabled &&
        !_skipNextReveal &&
        (_geometryScheduled ||
            !_buffer.caughtUp ||
            _hasTail ||
            (_height - target).abs() > 0.01)) {
      _start();
    } else {
      _stop();
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _visible.contains(position) &&
      super.hitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) return;
    context.pushClipRect(needsCompositing, offset, Offset.zero & size, (
      context,
      offset,
    ) {
      context.pushClipPath(
        needsCompositing,
        offset,
        Offset.zero & size,
        _visible,
        (context, offset) {
          final shader = _shader;
          if (!_hasTail || shader == null) {
            _maskLayer.layer = null;
            context.paintChild(child!, offset);
            return;
          }
          final bounds = _tail.getBounds();
          shader
            ..setFloat(0, bounds.top)
            ..setFloat(1, bounds.bottom)
            ..setFloat(2, _fadeBoxes.length.toDouble());
          for (var index = 0; index < 32; index++) {
            final rect = index < _fadeBoxes.length
                ? _fadeBoxes[index].rect
                : Rect.zero;
            final at = 3 + index * 4;
            shader
              ..setFloat(at, rect.left)
              ..setFloat(at + 1, rect.top)
              ..setFloat(at + 2, rect.right)
              ..setFloat(at + 3, rect.bottom)
              ..setFloat(
                3 + 32 * 4 + index,
                index < _fadeBoxes.length ? _fadeBoxes[index].opacity : 1,
              );
          }
          // One compositor layer, painted once, compatible with the cached
          // paragraph RepaintBoundaries. A canvas saveLayer around paintChild
          // would be invalid when that child starts a composited layer.
          final layer = _maskLayer.layer ??= ShaderMaskLayer();
          layer
            ..shader = shader
            ..maskRect = offset & size
            ..blendMode = BlendMode.dstIn;
          context.pushLayer(
            layer,
            (context, offset) => context.paintChild(child!, offset),
            offset,
          );
        },
      );
    });
  }

  @override
  void detach() {
    _stop();
    _buffer.finish();
    super.detach();
  }

  @override
  void dispose() {
    _stop();
    _ticker.dispose();
    _maskLayer.layer = null;
    for (final run in _runCache.values) {
      run.dispose();
    }
    super.dispose();
  }
}

class _ReplyRun {
  _ReplyRun(this.paragraph)
    : span = paragraph.text,
      size = paragraph.size,
      metrics = _metrics(paragraph) {
    var atomic = span is PlaceholderSpan;
    span.visitChildren((span) {
      atomic |= span is PlaceholderSpan;
      return !atomic;
    });
    // An inline widget has no character-to-box mapping in a copied painter.
    // Treat that small mixed block atomically rather than inventing offsets.
    text = atomic ? '\ufffc' : span.toPlainText(includeSemanticsLabels: false);
    painter = atomic
        ? null
        : (TextPainter(
            text: span,
            textAlign: paragraph.textAlign,
            textDirection: paragraph.textDirection,
            textScaler: paragraph.textScaler,
            maxLines: paragraph.maxLines,
            ellipsis: paragraph.overflow == TextOverflow.ellipsis
                ? '\u2026'
                : null,
            locale: paragraph.locale,
            strutStyle: paragraph.strutStyle,
            textWidthBasis: paragraph.textWidthBasis,
            textHeightBehavior: paragraph.textHeightBehavior,
          )..layout(minWidth: size.width, maxWidth: size.width));
  }

  final RenderParagraph paragraph;
  final InlineSpan span;
  final Size size;
  final Object metrics;
  late final String text;
  late final TextPainter? painter;
  Offset offset = Offset.zero;
  int start = 0;
  int index = 0;
  int sourceOrder = 0;
  double prefixBottom = 0;

  /// The [LiveReplyFrame] this run is drawn in, if any.
  _ReplyFrame? frame;
  List<_ReplyRun> priorSiblings = const [];

  Rect get bounds => offset & size;

  bool matches(RenderParagraph value) =>
      identical(span, value.text) && metrics == _metrics(value);

  static Object _metrics(RenderParagraph value) => (
    value.constraints,
    value.size,
    value.textAlign,
    value.textDirection,
    value.textScaler,
    value.maxLines,
    value.overflow,
    value.locale,
    value.strutStyle,
    value.textWidthBasis,
    value.textHeightBehavior,
  );

  TextRange lineAt(int offset) =>
      painter?.getLineBoundary(TextPosition(offset: offset)) ??
      const TextRange(start: 0, end: 1);

  List<Rect> boxes(int from, int to) => from >= to
      ? const []
      : painter == null
      ? [offset & size]
      : paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: from, extentOffset: to),
            )
            .map((box) => box.toRect().shift(offset))
            .toList(growable: false);

  void dispose() => painter?.dispose();
}
