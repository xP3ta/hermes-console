import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'mascot_atlas.dart';
import 'mascot_identity.dart';
import 'mascot_state.dart';

/// Test switch: when true every [MascotSprite] paints the still pose of its
/// state (as with reduced motion) and runs no timer, so whole-screen tests
/// can `pumpAndSettle`. Set for the suite in `flutter_test_config.dart`;
/// motion tests switch it off.
@visibleForTesting
bool debugMascotSpritesStill = false;

/// Test hook: paints of every [MascotSprite] since the process started.
@visibleForTesting
int debugMascotPaintCount = 0;

/// Test hook: [MascotSprite]s holding a pending frame timer right now.
@visibleForTesting
int get debugMascotActiveTimers => _MascotSpriteState._timers;

/// Read-only view of a mounted [MascotSprite] for tests.
abstract interface class MascotSpriteDebugView {
  /// Atlas cell painted now.
  int get debugCell;

  /// State whose animation is playing (the done wave hands over to idle).
  MascotState get debugPlaying;

  /// True when motion is allowed (visible, foreground, unlocked, motion on).
  bool get debugMoving;
}

/// The header mascot: a small sprite that sits on the activity pill and
/// shows what Hermes is doing.
///
/// Cost policy (same as `LivingBotFace`):
/// * one shared, decoded atlas per sprite ([MascotAtlas]); each frame is a
///   single `drawImageRect` with a cached colour filter, no allocation;
/// * frames come from one one-shot [Timer] per mascot, never a vsync
///   ticker: a frame is produced only when the cell changes. Idle repaints
///   twice per blink (4.2-8 s apart, ≤ 6 fps), active states run at
///   5.9-9 fps and the 200 ms crossfade between states at ~30 fps;
/// * zero frames and zero timers while the route is covered
///   ([TickerMode]), the app is not resumed, the App Lock is locked, or
///   reduced motion is on (then the state's still pose is painted).
class MascotSprite extends StatefulWidget {
  const MascotSprite({
    super.key,
    required this.state,
    this.identity = MascotIdentity.hermes,
    this.size = medium,
    this.name = 'Hermes',
    this.attentionColor,
    this.locked,
    this.excludeSemantics = false,
    this.header = false,
  }) : assert(size > 0);

  /// Sizes used by the header pill and rooms (dp). The sprite is fitted
  /// into a [size] x [size] box, standing on its bottom edge.
  static const double small = 24;
  static const double medium = 32;
  static const double large = 40;

  /// The App Lock state, wired once at startup (like the media prefetcher):
  /// while it is true no mascot produces frames. [locked] overrides it.
  static ValueListenable<bool>? appLocked;

  final MascotState state;
  final MascotIdentity identity;
  final double size;

  /// Who the mascot is, for the screen-reader label ("Hermes te necesita").
  final String name;

  /// Body colour while the state is [MascotState.needsYou]; defaults to the
  /// theme's warning (amber) colour, the same as the pill.
  final Color? attentionColor;

  final ValueListenable<bool>? locked;

  /// Leave the label to an ancestor (the pill or a [MascotCluster]).
  final bool excludeSemantics;

  /// True for the mascot hosted by the chat header pill. While one is on
  /// the visible route, [visibleHeaders] is above zero and the floating
  /// mascot steps aside: there is never a second mascot in a chat.
  final bool header;

  /// Header mascots on a visible route (updated after each frame).
  static ValueListenable<int> get visibleHeaders => _MascotSpriteState._headers;

  static const Color errorColor = Color(0xFFC9463E);
  static const Color offlineColor = Color(0x998A8F98);
  static const Color fallbackAttention = Color(0xFFE9A93C);

  static String semanticLabel(
    Strings strings,
    MascotState state,
    String name,
  ) => switch (state) {
    MascotState.idle => strings.mascotStateIdle(name),
    MascotState.thinking => strings.mascotStateThinking(name),
    MascotState.tool => strings.mascotStateTool(name),
    MascotState.needsYou => strings.mascotStateNeedsYou(name),
    MascotState.done => strings.mascotStateDone(name),
    MascotState.offline => strings.mascotStateOffline(name),
    MascotState.error => strings.mascotStateError(name),
  };

  @override
  State<MascotSprite> createState() => _MascotSpriteState();
}

class _MascotSpriteState extends State<MascotSprite>
    with WidgetsBindingObserver
    implements MascotSpriteDebugView {
  static int _timers = 0;
  static final ValueNotifier<int> _headers = ValueNotifier<int>(0);
  static final Set<_MascotSpriteState> _headerClaims = <_MascotSpriteState>{};
  static bool _headerFlushPending = false;

  /// Publishes the header count after the frame: listeners (the floating
  /// overlay, above the navigator) must not be dirtied during this build.
  static void _flushHeaders() {
    if (_headerFlushPending) return;
    _headerFlushPending = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _headerFlushPending = false;
        _headers.value = _headerClaims.length;
      })
      ..scheduleFrame();
  }

  void _claimHeader(bool claim) {
    final changed = claim
        ? _headerClaims.add(this)
        : _headerClaims.remove(this);
    if (changed) _flushHeaders();
  }

  static final List<Color> _fadeAlpha = List<Color>.unmodifiable(
    List<Color>.generate(
      MascotProgram.fadeSteps + 1,
      (i) => Color.fromRGBO(255, 255, 255, i / MascotProgram.fadeSteps),
    ),
  );

  final _MascotFrame _frame = _MascotFrame();
  Timer? _timer;
  bool _timerCounted = false;

  late MascotState _playing = widget.state;
  late MascotProgram _program = _programFor(_playing);
  int _step = 0;
  int _blinks = 0;

  /// Remaining crossfade repaints (0 = no fade running).
  int _fade = 0;

  bool _moving = false;
  bool _still = false;
  bool _applied = false;
  ValueListenable<bool>? _lock;
  Color _attention = MascotSprite.fallbackAttention;

  int get _seed => widget.identity.hashCode & 0xffff;

  @override
  int get debugCell => _frame.cell;

  @override
  MascotState get debugPlaying => _playing;

  @override
  bool get debugMoving => _moving;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindLock();
    _loadAtlas();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attention = widget.attentionColor ?? Theme.of(context).hermes.warning;
    _sync();
  }

  @override
  void didUpdateWidget(covariant MascotSprite oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locked != widget.locked) _bindLock();
    if (oldWidget.identity.sprite != widget.identity.sprite) _loadAtlas();
    if (oldWidget.attentionColor != widget.attentionColor &&
        widget.attentionColor != null) {
      _attention = widget.attentionColor!;
    }
    if (oldWidget.state != widget.state) {
      _enter(widget.state, fade: true);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _claimHeader(false);
    _lock?.removeListener(_sync);
    _stopTimer();
    _frame.dispose();
    super.dispose();
  }

  void _bindLock() {
    _lock?.removeListener(_sync);
    _lock = widget.locked ?? MascotSprite.appLocked;
    _lock?.addListener(_sync);
  }

  void _loadAtlas() {
    final kind = widget.identity.sprite;
    final image = MascotAtlas.cached(kind);
    if (image != null) {
      _frame.image = image;
      return;
    }
    _frame.image = null;
    MascotAtlas.load(kind).then((image) {
      if (!mounted || widget.identity.sprite != kind) return;
      _frame.image = image;
      _frame.changed();
    }, onError: (Object _) {});
  }

  MascotProgram _programFor(MascotState state) =>
      MascotProgram.of(state, seed: _seed, blinks: _blinks);

  Color? _tintFor(MascotState state) => switch (state) {
    MascotState.needsYou => _attention,
    MascotState.error => MascotSprite.errorColor,
    MascotState.offline => MascotSprite.offlineColor,
    _ => widget.identity.color,
  };

  /// Starts [state]'s program from its first frame.
  void _enter(MascotState state, {required bool fade}) {
    // A new program starts now, not when the old one's pending hold (an
    // idle rest can be 8 s) would have ended.
    _stopTimer();
    final canFade = fade && _moving && !_still && _frame.image != null;
    if (canFade) {
      _frame.fromCell = _frame.cell;
      _frame.fromPaint.colorFilter = _frame.paint.colorFilter;
      _fade = MascotProgram.fadeSteps;
    } else {
      _fade = 0;
    }
    _playing = state;
    _program = _programFor(state);
    _step = 0;
    _applyStep();
  }

  void _applyStep() {
    final cell = _still
        ? MascotProgram.staticCell(_playing)
        : _program.steps[_step].cell;
    final tint = _tintFor(_playing);
    _frame.setTint(tint);
    _frame.cell = cell;
    _frame.paint.color = _fadeAlpha[MascotProgram.fadeSteps - _fade];
    _frame.fromPaint.color = _fadeAlpha[_fade];
    _frame.fading = _fade > 0;
    _frame.changed();
  }

  /// Reconciles motion with visibility, lifecycle, lock and reduced motion.
  void _sync() {
    if (!mounted) return;
    final reduced =
        debugMascotSpritesStill ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final visibleRoute = TickerMode.valuesOf(context).enabled;
    _claimHeader(widget.header && visibleRoute);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final foreground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final moving =
        !reduced && foreground && visibleRoute && !(_lock?.value ?? false);
    final stillChanged = reduced != _still;
    _still = reduced;
    _moving = moving;
    if (!_applied) {
      _applied = true;
      _applyStep();
    } else if (_frame.tint?.toARGB32() != _tintFor(_playing)?.toARGB32()) {
      _applyStep();
    }
    if (stillChanged) {
      _fade = 0;
      if (reduced) {
        _applyStep();
      } else {
        _enter(_playing, fade: false);
      }
    }
    if (!moving && _fade > 0) {
      // Frozen mid-fade: settle on the new state now, no more frames.
      _fade = 0;
      _applyStep();
    }
    if (moving) {
      _schedule();
    } else {
      _stopTimer();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    if (_timerCounted) {
      _timerCounted = false;
      _timers--;
    }
  }

  void _schedule() {
    if (_timer != null) return;
    final Duration wait;
    if (_fade > 0) {
      wait = MascotProgram.fadeFrame;
    } else {
      final hold = _program.steps[_step].hold;
      // A held pose (offline, the end of the error shake): no timer at all.
      if (hold == Duration.zero) return;
      wait = hold;
    }
    if (!_timerCounted) {
      _timerCounted = true;
      _timers++;
    }
    _timer = Timer(wait, _tick);
  }

  void _tick() {
    _timer = null;
    if (_timerCounted) {
      _timerCounted = false;
      _timers--;
    }
    if (!mounted || !_moving) return;
    if (_fade > 0) {
      _fade--;
      _applyStep();
      _schedule();
      return;
    }
    final next = _step + 1;
    if (next < _program.steps.length) {
      _step = next;
    } else if (_program.loop) {
      if (_playing == MascotState.idle) {
        _blinks++;
        _program = _programFor(MascotState.idle);
      }
      _step = 0;
    } else if (_playing == MascotState.done) {
      // One wave, then back to idle.
      _enter(MascotState.idle, fade: true);
      _schedule();
      return;
    } else {
      return;
    }
    _applyStep();
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final sprite = RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _MascotPainter(_frame)),
      ),
    );
    if (widget.excludeSemantics) return ExcludeSemantics(child: sprite);
    return Semantics(
      image: true,
      label: MascotSprite.semanticLabel(
        Strings.of(context),
        widget.state,
        widget.name,
      ),
      excludeSemantics: true,
      child: sprite,
    );
  }
}

/// Everything the painter reads, mutated in place between frames.
final class _MascotFrame extends ChangeNotifier {
  ui.Image? image;
  int cell = MascotCell.bob;
  int fromCell = MascotCell.bob;
  bool fading = false;
  Color? _tint;
  Color? get tint => _tint;
  final Paint paint = Paint()..filterQuality = FilterQuality.medium;
  final Paint fromPaint = Paint()..filterQuality = FilterQuality.medium;

  Size _dstFor = Size.zero;
  Rect _dst = Rect.zero;

  /// Colour filters are created only when the tint changes (state or
  /// identity), never per frame.
  void setTint(Color? tint) {
    if (tint?.toARGB32() == _tint?.toARGB32()) return;
    _tint = tint;
    paint.colorFilter = tint == null
        ? null
        : ColorFilter.mode(tint, BlendMode.modulate);
  }

  Rect dst(Size size) {
    if (size != _dstFor) {
      _dstFor = size;
      final scale =
          (size.width / MascotAtlas.cellWidth) <
              (size.height / MascotAtlas.cellHeight)
          ? size.width / MascotAtlas.cellWidth
          : size.height / MascotAtlas.cellHeight;
      final w = MascotAtlas.cellWidth * scale;
      final h = MascotAtlas.cellHeight * scale;
      _dst = Rect.fromLTWH((size.width - w) / 2, size.height - h, w, h);
    }
    return _dst;
  }

  void changed() => notifyListeners();
}

final class _MascotPainter extends CustomPainter {
  _MascotPainter(this.frame) : super(repaint: frame);

  final _MascotFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    debugMascotPaintCount++;
    final image = frame.image;
    if (image == null) return;
    final dst = frame.dst(size);
    if (frame.fading) {
      canvas.drawImageRect(
        image,
        MascotAtlas.cellRects[frame.fromCell],
        dst,
        frame.fromPaint,
      );
    }
    canvas.drawImageRect(
      image,
      MascotAtlas.cellRects[frame.cell],
      dst,
      frame.paint,
    );
  }

  @override
  bool shouldRepaint(_MascotPainter oldDelegate) => oldDelegate.frame != frame;
}
