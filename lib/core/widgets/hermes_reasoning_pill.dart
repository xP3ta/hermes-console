import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/modal.dart' show HermesSurfaceHeader, showHermesSurface;
import '../design/tokens.dart' show HermesSpace, HermesType;
import '../theme/app_theme.dart';
import 'reasoning_squares_track.dart';
import '../feedback/haptics.dart';

/// Horizontal inset of the pill track: the first and last step sit this far
/// from the edges, so the round thumb is never clipped.
const double kReasoningTrackInset = 24;

/// One step of a [HermesReasoningPill]: the [value] the caller stores (a wire
/// name such as `high`) and the [label] shown under the track.
@immutable
class HermesReasoningLevel {
  const HermesReasoningLevel(this.value, this.label);

  final String value;
  final String label;
}

/// The one control for a reasoning level: the squares pill with its round
/// thumb (a hollow ring at «off») and the names of the real [levels] under it,
/// the current one marked. Stepped: the preview follows the finger and
/// [onChanged] runs once per change, on release, tap, key or accessibility
/// action, so one drag is one request.
class HermesReasoningPill extends StatefulWidget {
  const HermesReasoningPill({
    required this.levels,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.defaultLabel,
    this.supported = true,
    this.showHeader = true,
    this.reportsCurrent = false,
    this.offValue = 'none',
    this.anchorValue = 'medium',
    this.impactOf,
    this.unavailableText,
    super.key,
  });

  /// The steps, in ascending order.
  final List<HermesReasoningLevel> levels;

  /// The current level's value; null (or one that is not in [levels]) while
  /// there is no explicit level.
  final String? value;

  /// Null disables the control (a change is already being applied).
  final ValueChanged<String>? onChanged;

  /// The accessible name; also the header when [showHeader].
  final String title;

  /// What is read while there is no explicit level.
  final String defaultLabel;

  /// False when the model does not take an adjustable level: the control is
  /// dimmed, shows no level and cannot change.
  final bool supported;

  /// Whether the title and the live level are written above the pill.
  final bool showHeader;

  /// Whether choosing the level already in force still calls [onChanged]:
  /// for a sheet whose answer is the level itself (keeping the current one is
  /// an answer too). The session control leaves it off: a change is a request.
  final bool reportsCurrent;

  /// The value that reads as «off» (hollow ring thumb).
  final String offValue;

  /// Where the first step goes when there is no explicit level.
  final String anchorValue;

  /// A short hint for the accessibility layer about what [value] costs.
  final String Function(String? value)? impactOf;

  /// Why the control is unavailable, written under it when not [supported].
  final String? unavailableText;

  @override
  State<HermesReasoningPill> createState() => _HermesReasoningPillState();
}

class _HermesReasoningPillState extends State<HermesReasoningPill> {
  int? _preview;

  /// Finger position along the track in steps, while dragging: the thumb is
  /// pulled towards the nearest step like a small magnet.
  double? _dragPosition;
  bool _dragging = false;
  bool _focused = false;
  final _focusNode = FocusNode(debugLabel: 'HermesReasoningPill');

  List<HermesReasoningLevel> get _steps => widget.levels;

  bool get _enabled => widget.supported && widget.onChanged != null;

  int? get _valueIndex {
    final value = widget.value;
    if (value == null) return null;
    final index = _steps.indexWhere((s) => s.value == value);
    return index < 0 ? null : index;
  }

  int? get _shown => _preview ?? _valueIndex;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  double _positionAt(double dx, double width) {
    final usable = width - 2 * kReasoningTrackInset;
    if (usable <= 0 || _steps.length < 2) return 0;
    final fraction = ((dx - kReasoningTrackInset) / usable).clamp(0.0, 1.0);
    return fraction * (_steps.length - 1);
  }

  int _indexAt(double dx, double width) => _positionAt(dx, width).round();

  void _drag(double dx, double width) {
    final position = _positionAt(dx, width);
    _setPreview(position.round());
    setState(() => _dragPosition = position);
  }

  void _haptic() =>
      HermesHaptics.selection();

  void _setPreview(int index) {
    if (_preview == index) return;
    if ((_preview ?? _valueIndex) != index) _haptic();
    setState(() => _preview = index);
  }

  void _commit(int index) {
    final previous = _valueIndex;
    setState(() {
      _preview = null;
      _dragPosition = null;
      _dragging = false;
    });
    if (index != previous || widget.reportsCurrent) {
      widget.onChanged?.call(_steps[index].value);
    }
  }

  int get _anchorIndex {
    final index = _steps.indexWhere((s) => s.value == widget.anchorValue);
    return index < 0 ? _steps.length ~/ 2 : index;
  }

  void _step(int delta) {
    if (!_enabled) return;
    final current = _valueIndex;
    final next = current == null
        ? _anchorIndex
        : (current + delta).clamp(0, _steps.length - 1);
    if (next == current) return;
    _haptic();
    _commit(next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabled || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp) {
      _step(1);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowDown) {
      _step(-1);
    } else if (key == LogicalKeyboardKey.home) {
      if (_valueIndex != 0) _haptic();
      _commit(0);
    } else if (key == LogicalKeyboardKey.end) {
      if (_valueIndex != _steps.length - 1) _haptic();
      _commit(_steps.length - 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shown = _shown;
    final effort = shown == null ? null : _steps[shown];
    final showsValue = widget.supported;
    final liveLabel = effort == null ? widget.defaultLabel : effort.label;
    final impact = widget.impactOf?.call(effort?.value);
    final dragPosition = _dragPosition;
    final fraction = shown == null || _steps.length < 2
        ? 0.0
        : (dragPosition == null
                  ? shown.toDouble()
                  : reasoningMagnet(dragPosition)) /
              (_steps.length - 1);
    final highContrast = MediaQuery.highContrastOf(context);
    final labels = [for (final step in _steps) step.label];
    // Without an explicit level the first step goes to the anchor.
    final anchor = _steps[_anchorIndex].label;
    final next = shown == null
        ? anchor
        : shown < _steps.length - 1
        ? _steps[shown + 1].label
        : null;
    final previous = shown == null
        ? anchor
        : shown > 0
        ? _steps[shown - 1].label
        : null;
    final off = effort?.value == widget.offValue;

    final track = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          key: const ValueKey('model-picker-reasoning-track'),
          behavior: HitTestBehavior.opaque,
          onTapUp: !_enabled
              ? null
              : (details) {
                  _focusNode.requestFocus();
                  final index = _indexAt(details.localPosition.dx, width);
                  if (index != _valueIndex) _haptic();
                  _commit(index);
                },
          onHorizontalDragStart: !_enabled
              ? null
              : (details) {
                  _focusNode.requestFocus();
                  setState(() => _dragging = true);
                  _drag(details.localPosition.dx, width);
                },
          onHorizontalDragUpdate: !_enabled
              ? null
              : (details) => _drag(details.localPosition.dx, width),
          onHorizontalDragEnd: !_enabled
              ? null
              : (_) {
                  final index = _preview;
                  if (index == null) {
                    setState(() {
                      _dragPosition = null;
                      _dragging = false;
                    });
                  } else {
                    _commit(index);
                  }
                },
          onHorizontalDragCancel: !_enabled
              ? null
              : () => setState(() {
                  _preview = null;
                  _dragPosition = null;
                  _dragging = false;
                }),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: fraction),
                duration: reduceMotion || _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                builder: (context, animated, _) => highContrast
                    ? CustomPaint(
                        size: Size(width, kReasoningSquaresHeight),
                        painter: _ReasoningTrackPainter(
                          steps: _steps.length,
                          fraction: animated,
                          hasThumb: showsValue && shown != null,
                          off: off,
                          enabled: _enabled,
                          focused: _focused && _enabled,
                          activeColor: colors.accent,
                          onActiveColor: colors.onAccent,
                          trackColor: colors.divider,
                          surfaceColor: colors.surface,
                          mutedColor: colors.textTertiary,
                        ),
                      )
                    : ReasoningSquaresTrack(
                        width: width,
                        level: showsValue ? shown : null,
                        levels: _steps.length,
                        fraction: animated,
                        inset: kReasoningTrackInset,
                        hasThumb: showsValue && shown != null,
                        off: off,
                        enabled: _enabled,
                        focused: _focused && _enabled,
                        animate: !reduceMotion,
                      ),
              ),
              const SizedBox(height: HermesSpace.x2),
              ReasoningLevelLabels(
                labels: labels,
                active: showsValue ? shown : null,
                inset: kReasoningTrackInset,
                enabled: _enabled,
              ),
            ],
          ),
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showHeader) ...[
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(top: HermesSpace.x2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title.toUpperCase(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: HermesType.captionSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  if (showsValue)
                    Text(
                      liveLabel,
                      key: const ValueKey('model-picker-reasoning-label'),
                      style: TextStyle(
                        fontSize: HermesType.supportSize,
                        fontWeight: FontWeight.w700,
                        color: _enabled
                            ? colors.accentText
                            : colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: HermesSpace.x2),
        ],
        Semantics(
          container: true,
          slider: true,
          enabled: _enabled,
          label: widget.title,
          value: showsValue ? liveLabel : null,
          hint: showsValue ? impact : null,
          increasedValue: next,
          decreasedValue: previous,
          onIncrease: _enabled && next != null ? () => _step(1) : null,
          onDecrease: _enabled && previous != null ? () => _step(-1) : null,
          child: Focus(
            focusNode: _focusNode,
            canRequestFocus: _enabled,
            onKeyEvent: _onKey,
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: ExcludeSemantics(
              child: widget.supported
                  ? track
                  : Opacity(
                      key: const ValueKey('model-picker-reasoning-dim'),
                      opacity: 0.45,
                      child: track,
                    ),
            ),
          ),
        ),
        if (!widget.supported && widget.unavailableText != null) ...[
          const SizedBox(height: 2),
          Text(
            widget.unavailableText!,
            style: TextStyle(
              fontSize: HermesType.supportSize,
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// The floating sheet that asks for a reasoning level with the shared pill:
/// it closes with the level picked (its value), or with `''` for
/// [inheritLabel] (follow the general value), and with null when dismissed.
/// Picking the level already in force closes it with that level too.
Future<String?> showHermesReasoningPicker({
  required BuildContext context,
  required String title,
  required List<HermesReasoningLevel> levels,
  required String? selected,
  required String defaultLabel,
  String? inheritLabel,
  Key surfaceKey = const ValueKey('reasoning-pill-surface'),
}) => showHermesSurface<String>(
  context: context,
  surfaceKey: surfaceKey,
  maxWidth: 520,
  builder: (sheet) {
    final colors = Theme.of(sheet).hermes;
    final inherits = inheritLabel != null && (selected ?? '').isEmpty;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HermesSurfaceHeader(title: title),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x4,
              HermesSpace.x2,
              HermesSpace.x4,
              HermesSpace.x4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HermesReasoningPill(
                  key: const ValueKey('reasoning-pill'),
                  levels: levels,
                  value: (selected ?? '').isEmpty ? null : selected,
                  title: title,
                  defaultLabel: defaultLabel,
                  showHeader: false,
                  reportsCurrent: true,
                  onChanged: (value) => Navigator.of(sheet).pop(value),
                ),
                if (inheritLabel != null) ...[
                  const SizedBox(height: HermesSpace.x2),
                  Semantics(
                    button: true,
                    selected: inherits,
                    child: TextButton(
                      key: const ValueKey('reasoning-pill-inherit'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: () => Navigator.of(sheet).pop(''),
                      child: Text(
                        inheritLabel,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: HermesType.supportSize,
                          fontWeight: inherits
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: inherits
                              ? colors.accentText
                              : colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  },
);

class _ReasoningTrackPainter extends CustomPainter {
  const _ReasoningTrackPainter({
    required this.steps,
    required this.fraction,
    required this.hasThumb,
    required this.off,
    required this.enabled,
    required this.focused,
    required this.activeColor,
    required this.onActiveColor,
    required this.trackColor,
    required this.surfaceColor,
    required this.mutedColor,
  });

  final int steps;
  final double fraction;
  final bool hasThumb;
  final bool off;
  final bool enabled;
  final bool focused;
  final Color activeColor;
  final Color onActiveColor;
  final Color trackColor;
  final Color surfaceColor;
  final Color mutedColor;

  static const _thumbWidth = 30.0;
  static const _thumbHeight = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final left = kReasoningTrackInset;
    final right = size.width - kReasoningTrackInset;
    final y = size.height / 2;
    if (right <= left) return;
    final accent = enabled ? activeColor : mutedColor.withValues(alpha: 0.6);
    final thumbX = left + (right - left) * fraction;

    final line = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.5
      ..color = trackColor;
    canvas.drawLine(Offset(left, y), Offset(right, y), line);
    if (hasThumb && !off && fraction > 0) {
      line.color = accent;
      canvas.drawLine(Offset(left, y), Offset(thumbX, y), line);
    }

    final tick = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5;
    for (var i = 0; i < steps; i++) {
      final x = left + (right - left) * i / (steps - 1);
      final passed = hasThumb && !off && x <= thumbX + 0.5;
      tick.color = passed ? accent : mutedColor.withValues(alpha: 0.55);
      canvas.drawLine(Offset(x, y - 6), Offset(x, y + 6), tick);
    }

    if (!hasThumb) return;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(thumbX, y),
        width: _thumbWidth,
        height: _thumbHeight,
      ),
      const Radius.circular(_thumbHeight / 2),
    );
    if (focused) {
      canvas.drawRRect(
        rect.inflate(4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent.withValues(alpha: 0.45),
      );
    }
    canvas.drawRRect(rect.inflate(1.5), Paint()..color = surfaceColor);
    canvas.drawRRect(rect, Paint()..color = off ? surfaceColor : accent);
    if (off) {
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent,
      );
    }
    final grip = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5
      ..color = off ? accent : onActiveColor.withValues(alpha: 0.85);
    for (final dx in const [-3.0, 3.0]) {
      canvas.drawLine(
        Offset(thumbX + dx, y - 3.5),
        Offset(thumbX + dx, y + 3.5),
        grip,
      );
    }
  }

  @override
  bool shouldRepaint(_ReasoningTrackPainter old) =>
      old.steps != steps ||
      old.fraction != fraction ||
      old.hasThumb != hasThumb ||
      old.off != off ||
      old.enabled != enabled ||
      old.focused != focused ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor ||
      old.surfaceColor != surfaceColor ||
      old.mutedColor != mutedColor;
}
