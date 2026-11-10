import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../characters/bot_character.dart';
import '../../characters/character_draft.dart';
import '../../characters/studio_catalog.dart';
import '../../characters/studio_painter.dart';
import '../../characters/studio_pieces.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_contrast.dart';
import 'studio_view.dart';
import 'studio_widgets.dart';

/// Distance, in logical pixels, within which a touch grabs a handle.
const double studioHandleReach = 24;

/// Label of a preview state.
String studioStateLabel(BotStudioState state, Strings s) => switch (state) {
  BotStudioState.still => s.bstStateStill,
  BotStudioState.idle => s.bstStateIdle,
  BotStudioState.listen => s.bstStateListen,
  BotStudioState.think => s.bstStateThink,
  BotStudioState.work => s.bstStateWork,
  BotStudioState.speak => s.bstStateSpeak,
  BotStudioState.curious => s.bstStateCurious,
  BotStudioState.celebrate => s.bstStateCelebrate,
  BotStudioState.love => s.bstStateLove,
  BotStudioState.oops => s.bstStateOops,
  BotStudioState.sleep => s.bstStateSleep,
  BotStudioState.bounce => s.bstStateBounce,
  BotStudioState.dance => s.bstStateDance,
  BotStudioState.spin => s.bstStateSpin,
};

/// [base] pulled up to [amount] of the way toward the colour of
/// [character]'s body: the editor's background wears the tone being chosen.
///
/// The pull is reduced, step by step, until [ink] reads on the result with
/// [minimum] contrast (or with what [base] itself gives, if that is less),
/// so a dark or a light body never makes the text over it harder to read.
Color studioTint(
  Color base,
  BotCharacter character,
  String profileName,
  double amount, {
  required Color ink,
  double minimum = 4.5,
}) {
  final body = studioBodyColor(
    character,
    character.visual(profileName).headColor,
  );
  final floor = math.min(minimum, ThemeContrast.ratio(ink, base));
  for (var pull = amount; pull > 0.001; pull -= 0.02) {
    final tinted = Color.lerp(base, body, pull)!;
    if (ThemeContrast.ratio(ink, tinted) + 1e-9 >= floor) return tinted;
  }
  return base;
}

/// Where the rotate handle of [piece] sits, in widget coordinates.
Offset studioRotateHandle(StudioViewport view, BotPiece piece) {
  final box = StudioPieces.of(piece.kind).bounds;
  return view.fromCanvas(StudioPieces.toCanvas(piece, Offset(0, box.top - 12)));
}

/// Where the size handle of [piece] sits, in widget coordinates.
Offset studioScaleHandle(StudioViewport view, BotPiece piece) {
  final box = StudioPieces.of(piece.kind).bounds;
  return view.fromCanvas(StudioPieces.toCanvas(piece, box.bottomRight));
}

enum _Grab { none, move, rotate, scale, pinchPiece, zoom, pan }

/// The editor's canvas: the character on a square that zooms and pans, the
/// frame and handles of the selected piece, and the pill that picks the
/// preview state.
///
/// One finger drags a piece (or a handle of the selected one); two fingers
/// scale and turn the selected piece, or zoom the canvas when none is
/// selected. A drag is one undo step. The canvas rebuilds on its own when
/// the character changes: nothing around it does.
class StudioCanvas extends StatefulWidget {
  final CharacterDraft draft;
  final String profileName;
  final StudioViewController view;
  final ValueNotifier<int?> selection;
  final ValueNotifier<BotStudioState> previewState;

  /// Key of the repaint boundary that holds only the character (the PNG).
  final GlobalKey exportKey;
  final Color background;
  final VoidCallback onPickState;

  const StudioCanvas({
    super.key,
    required this.draft,
    required this.profileName,
    required this.view,
    required this.selection,
    required this.previewState,
    required this.exportKey,
    required this.background,
    required this.onPickState,
  });

  @override
  State<StudioCanvas> createState() => _StudioCanvasState();
}

class _StudioCanvasState extends State<StudioCanvas> {
  _Grab _grab = _Grab.none;
  Offset _startFocal = Offset.zero;
  Offset _grabOffset = Offset.zero;
  double _startRotation = 0;
  double _startScale = 1;
  double _startDistance = 1;
  double _startZoom = 1;
  Offset _startPan = Offset.zero;
  double _side = 1;

  /// Where the last pointer went down: a drag is judged from there, not from
  /// where the gesture recogniser finally accepts it.
  Offset? _down;

  CharacterDraft get _draft => widget.draft;
  StudioViewController get _view => widget.view;

  StudioViewport get _viewport =>
      StudioViewport(side: _side, zoom: _view.zoom, pan: _view.pan);

  BotPiece? get _selected {
    final index = widget.selection.value;
    final pieces = _draft.value.pieces;
    return index != null && index < pieces.length ? pieces[index] : null;
  }

  void _setSelected(BotPiece next) {
    final index = widget.selection.value;
    if (index == null) return;
    final pieces = [..._draft.value.pieces];
    if (index >= pieces.length) return;
    pieces[index] = next;
    _draft.update(_draft.value.copyWith(pieces: pieces));
  }

  int? _hitPiece(Offset canvasPoint) {
    final pieces = _draft.value.pieces;
    for (var i = pieces.length - 1; i >= 0; i--) {
      if (StudioPieces.hits(pieces[i], canvasPoint)) return i;
    }
    return null;
  }

  static Offset _centreOf(BotPiece piece) =>
      Offset(piece.x * 100, piece.y * 100);

  static double _wrapDegrees(double degrees) {
    var d = degrees % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  void _onStart(ScaleStartDetails details) {
    final focal = details.pointerCount == 1 && _down != null
        ? _down!
        : details.localFocalPoint;
    _startFocal = focal;
    _startZoom = _view.zoom;
    _startPan = _view.pan;
    final piece = _selected;
    if (details.pointerCount >= 2) {
      if (piece != null) {
        _grab = _Grab.pinchPiece;
        _startRotation = piece.rotation;
        _startScale = piece.scale;
        _draft.beginGesture();
      } else {
        _grab = _Grab.zoom;
      }
      return;
    }
    if (_view.panMode) {
      _grab = _Grab.pan;
      return;
    }
    final viewport = _viewport;
    if (piece != null) {
      if ((studioRotateHandle(viewport, piece) - focal).distance <=
          studioHandleReach) {
        _grab = _Grab.rotate;
        _draft.beginGesture();
        return;
      }
      if ((studioScaleHandle(viewport, piece) - focal).distance <=
          studioHandleReach) {
        _grab = _Grab.scale;
        _startScale = piece.scale;
        _startDistance = math.max(
          1,
          (viewport.toCanvas(focal) - _centreOf(piece)).distance,
        );
        _draft.beginGesture();
        return;
      }
    }
    final canvasPoint = viewport.toCanvas(focal);
    final hit = _hitPiece(canvasPoint);
    if (hit != null) {
      widget.selection.value = hit;
      _grab = _Grab.move;
      _grabOffset = canvasPoint - _centreOf(_draft.value.pieces[hit]);
      _draft.beginGesture();
      return;
    }
    _grab = _view.zoom > 1 ? _Grab.pan : _Grab.none;
  }

  void _onUpdate(ScaleUpdateDetails details) {
    final viewport = _viewport;
    final piece = _selected;
    switch (_grab) {
      case _Grab.none:
        break;
      case _Grab.move:
        if (piece == null) break;
        final target = viewport.toCanvas(details.localFocalPoint) - _grabOffset;
        _setSelected(piece.copyWith(x: target.dx / 100, y: target.dy / 100));
      case _Grab.rotate:
        if (piece == null) break;
        final v = viewport.toCanvas(details.localFocalPoint) - _centreOf(piece);
        if (v.distance < 0.5) break;
        _setSelected(
          piece.copyWith(
            rotation: _wrapDegrees(math.atan2(v.dy, v.dx) * 180 / math.pi + 90),
          ),
        );
      case _Grab.scale:
        if (piece == null) break;
        final distance =
            (viewport.toCanvas(details.localFocalPoint) - _centreOf(piece))
                .distance;
        _setSelected(
          piece.copyWith(scale: _startScale * distance / _startDistance),
        );
      case _Grab.pinchPiece:
        if (piece == null) break;
        _setSelected(
          piece.copyWith(
            scale: _startScale * details.scale,
            rotation: _wrapDegrees(
              _startRotation + details.rotation * 180 / math.pi,
            ),
          ),
        );
      case _Grab.zoom:
        _view.setZoom(_startZoom * details.scale);
        _view.setPan(
          _clampPan(_startPan + (details.localFocalPoint - _startFocal)),
        );
      case _Grab.pan:
        _view.setPan(
          _clampPan(_startPan + (details.localFocalPoint - _startFocal)),
        );
    }
  }

  Offset _clampPan(Offset pan) {
    final limit = _side * _view.zoom;
    return Offset(
      pan.dx.clamp(-limit, limit).toDouble(),
      pan.dy.clamp(-limit, limit).toDouble(),
    );
  }

  void _onEnd(ScaleEndDetails details) {
    _draft.endGesture();
    _grab = _Grab.none;
  }

  void _onTapUp(TapUpDetails details) {
    final point = _viewport.toCanvas(details.localPosition);
    widget.selection.value = _hitPiece(point);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return LayoutBuilder(
      builder: (context, box) {
        final available = math.min(
          box.maxWidth.isFinite ? box.maxWidth : 320.0,
          box.maxHeight.isFinite ? box.maxHeight : 320.0,
        );
        _side = available;
        return Center(
          child: SizedBox.square(
            dimension: available,
            child: Semantics(
              container: true,
              // The state pill keeps its own node; the canvas is spoken as
              // one picture.
              explicitChildNodes: true,
              image: true,
              label: s.bstCanvasLabel,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(HermesRadius.card),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ListenableBuilder(
                      listenable: _draft,
                      builder: (context, _) => ColoredBox(
                        color: studioTint(
                          widget.background,
                          _draft.value,
                          widget.profileName,
                          0.22,
                          ink: colors.textSecondary,
                        ),
                      ),
                    ),
                    Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (event) => _down = event.localPosition,
                      child: GestureDetector(
                        key: const ValueKey('studio-canvas-gestures'),
                        behavior: HitTestBehavior.opaque,
                        // The canvas is spoken as a whole; the pieces are
                        // chosen and adjusted from the panel.
                        excludeFromSemantics: true,
                        onScaleStart: _onStart,
                        onScaleUpdate: _onUpdate,
                        onScaleEnd: _onEnd,
                        onTapUp: _onTapUp,
                        child: ListenableBuilder(
                          listenable: _view,
                          builder: (context, _) => Transform.translate(
                            offset: _view.pan,
                            child: Transform.scale(
                              scale: _view.zoom,
                              child: _content(available),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: CustomPaint(
                        key: const ValueKey('studio-selection-paint'),
                        painter: _SelectionPainter(
                          draft: _draft,
                          selection: widget.selection,
                          view: _view,
                          side: available,
                          color: colors.textPrimary,
                          ring: colors.surface,
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: HermesSpace.x3,
                      top: HermesSpace.x3,
                      child: IgnorePointer(
                        child: Text(
                          s.bstCanvasSize,
                          style: HermesType.style(
                            HermesType.support,
                            colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      end: HermesSpace.x3,
                      bottom: HermesSpace.x3,
                      child: ValueListenableBuilder<BotStudioState>(
                        valueListenable: widget.previewState,
                        builder: (context, state, _) => StudioPill(
                          key: const ValueKey('studio-state-pill'),
                          label: studioStateLabel(state, s),
                          semanticLabel:
                              '${s.bstStateButton}: ${studioStateLabel(state, s)}',
                          icon: Icons.unfold_more_rounded,
                          onTap: widget.onPickState,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _content(double side) => ListenableBuilder(
    listenable: Listenable.merge([_draft, widget.previewState]),
    builder: (context, _) => RepaintBoundary(
      key: widget.exportKey,
      child: SizedBox.square(
        dimension: side,
        child: StudioCharacterFace(
          key: const ValueKey('character-preview'),
          character: _draft.value,
          profileName: widget.profileName,
          size: side,
          animate: true,
          state: widget.previewState.value,
        ),
      ),
    ),
  );
}

final class _SelectionPainter extends CustomPainter {
  final CharacterDraft draft;
  final ValueNotifier<int?> selection;
  final StudioViewController view;
  final double side;
  final Color color;
  final Color ring;

  _SelectionPainter({
    required this.draft,
    required this.selection,
    required this.view,
    required this.side,
    required this.color,
    required this.ring,
  }) : super(repaint: Listenable.merge([draft, selection, view]));

  @override
  void paint(Canvas canvas, Size size) {
    final index = selection.value;
    final pieces = draft.value.pieces;
    if (index == null || index >= pieces.length) return;
    final piece = pieces[index];
    final viewport = StudioViewport(side: side, zoom: view.zoom, pan: view.pan);
    final corners = [
      for (final c in StudioPieces.corners(piece)) viewport.fromCanvas(c),
    ];
    final frame = Path()..moveTo(corners[0].dx, corners[0].dy);
    for (final c in corners.skip(1)) {
      frame.lineTo(c.dx, c.dy);
    }
    frame.close();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color;
    canvas.drawPath(frame, stroke);
    final rotate = studioRotateHandle(viewport, piece);
    final topCentre = viewport.fromCanvas(
      StudioPieces.toCanvas(
        piece,
        Offset(0, StudioPieces.of(piece.kind).bounds.top),
      ),
    );
    canvas.drawLine(topCentre, rotate, stroke);
    final fill = Paint()..color = color;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = ring;
    canvas
      ..drawCircle(rotate, 8, fill)
      ..drawCircle(rotate, 8, edge);
    final scale = studioScaleHandle(viewport, piece);
    final square = Rect.fromCenter(center: scale, width: 14, height: 14);
    canvas
      ..drawRect(square, fill)
      ..drawRect(square, edge);
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.side != side || old.color != color || old.ring != ring;
}
