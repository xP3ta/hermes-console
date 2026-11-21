import 'package:hermes_android/core/design/hicons.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/activity_snapshot.dart'
    show
        MemoryWrite,
        MemoryWriteAction,
        isMemoryTool,
        isSkillLoadTool,
        measuredActivityDuration;
import '../../design/gel_surface.dart' show HermesGelSurface;
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../../theme/live_turn_tokens.dart';
import '../activity_pill.dart' show ActivityTicker;
import '../chat_turn_activity.dart'
    show LiveTurnScope, TurnType, turnToolIconFor;
import 'chat_live_icon.dart' show ChatLiveGlyph, chatLiveGlyphForTool;
import 'tool_steps_summary.dart' show turnLineDuration;
import 'turn_step_cards.dart' show TurnStepCardEntry;
import 'turn_step_motion.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The live turn's look (approved 9 nov 2026; mock `turno3.html`). Only the
// look: nothing here decides what a step is or when the turn ends. The rows
// come from the entries the turn already builds.
// ─────────────────────────────────────────────────────────────────────────────

/// What a window row says about the tool: a skill, a file, the terminal, or
/// any other tool.
enum LiveToolKind { skill, file, terminal, other }

const Set<String> _fileTools = {
  'read_file',
  'write_file',
  'patch',
  'search_files',
  'edit_file',
  'view_file',
  'list_files',
  'file',
};

/// The kind of tool of a step, by the name the gateway sent.
LiveToolKind liveToolKind(String? tool) {
  final name = tool?.trim().toLowerCase() ?? '';
  if (name.isEmpty) return LiveToolKind.other;
  if (isSkillLoadTool(name)) return LiveToolKind.skill;
  if (chatLiveGlyphForTool(name) == ChatLiveGlyph.terminalAgent) {
    return LiveToolKind.terminal;
  }
  if (_fileTools.contains(name) ||
      name.endsWith('_file') ||
      name.endsWith('_files')) {
    return LiveToolKind.file;
  }
  return LiveToolKind.other;
}

/// One pill of the window: a step, or a run of consecutive steps of the same
/// tool folded into one («Ejecutar comando ×20 · último comando»).
@immutable
final class LiveTurnRow {
  const LiveTurnRow({
    required this.id,
    required this.toolName,
    required this.title,
    required this.detail,
    required this.count,
    required this.running,
    required this.failed,
    required this.startedAt,
    required this.clock,
    this.memory,
    this.duration,
  });

  factory LiveTurnRow.of(TurnStepCardEntry step) => LiveTurnRow(
    id: step.id,
    toolName: step.toolName,
    title: step.title,
    detail: step.detail,
    count: 1,
    running: step.running,
    failed: step.failed,
    startedAt: step.startedAt,
    clock: step.clock,
    memory: step.memory,
    duration: measuredActivityDuration(step.duration),
  );

  /// The first step's id: it does not change while the run grows.
  final String id;
  final String? toolName;
  final String title;
  final String? detail;
  final int count;
  final bool running;
  final bool failed;
  final DateTime? startedAt;
  final DateTime Function()? clock;

  /// What a memory tool says it wrote, when this row is one.
  final MemoryWrite? memory;

  /// How long the row's finished calls took together, when measured.
  final Duration? duration;

  /// A memory tool (`memory`, the OMH plugin's `omh_remember`): its own
  /// brain row with the four states, never folded into a run.
  bool get isMemory => toolName != null && isMemoryTool(toolName!);

  /// Where a memory row is: in flight, stored, not stored, or finished
  /// without a confirmation either way (queued for review, no parsable
  /// answer), which says nothing it cannot back up.
  LiveMemoryState get memoryState {
    if (running) return LiveMemoryState.saving;
    if (failed || memory?.rejected == true) return LiveMemoryState.failed;
    if (memory?.landed == true) return LiveMemoryState.saved;
    return LiveMemoryState.unconfirmed;
  }

  LiveToolKind get kind => liveToolKind(toolName);

  /// The title, with the size of the run when it is more than one.
  String get name => count > 1 ? '$title ×$count' : title;

  LiveTurnRow merge(TurnStepCardEntry step) => LiveTurnRow(
    id: id,
    toolName: toolName,
    title: title,
    detail: step.detail,
    count: count + 1,
    running: step.running,
    failed: false,
    startedAt: step.startedAt,
    clock: step.clock ?? clock,
    memory: memory,
    duration: switch ((duration, measuredActivityDuration(step.duration))) {
      (final total?, final more?) => total + more,
      (final total, final more) => total ?? more,
    },
  );
}

enum LiveMemoryState { saving, saved, failed, unconfirmed }

/// The words of a memory row's state. «Guardado»/«Perfil actualizado» are
/// said only for a write the gateway confirmed.
String liveMemoryLabel(Strings s, LiveTurnRow row) {
  final write = row.memory;
  return switch (row.memoryState) {
    LiveMemoryState.saving =>
      write?.action == MemoryWriteAction.remove
          ? s.liveMemRemoving
          : s.liveMemSaving,
    LiveMemoryState.failed => s.liveMemFailed,
    LiveMemoryState.unconfirmed => row.title,
    LiveMemoryState.saved => switch ((write?.action, write?.userTarget)) {
      (MemoryWriteAction.remove, true) => s.mp1215RemovedFromProfile,
      (MemoryWriteAction.remove, _) => s.mp1215RemovedFromMemory,
      (_, true) => s.mp1215ProfileUpdated,
      (MemoryWriteAction.replace, _) => s.mp1215MemoryUpdated,
      _ => s.mp1215SavedToMemory,
    },
  };
}

/// A `skill_view` either loads a skill or reads one of its files (its
/// detail is then «skill → file», `skillStepTitle`). They are worded apart,
/// so a file read is never counted into a run of loads, nor the reverse.
bool _sameSkillStep(String tool, String? before, String? now) {
  if (!isSkillLoadTool(tool)) return true;
  bool resource(String? detail) => detail != null && detail.contains(' → ');
  return resource(before) == resource(now);
}

/// The rows of the window for [tools], oldest first: consecutive steps of
/// the same tool are one row (a failed step is never folded into a run, so
/// a failure is always seen on its own row).
List<LiveTurnRow> liveTurnRows(Iterable<TurnStepCardEntry> tools) {
  final rows = <LiveTurnRow>[];
  for (final step in tools) {
    final last = rows.isEmpty ? null : rows.last;
    final tool = step.toolName;
    if (last != null &&
        tool != null &&
        tool == last.toolName &&
        !isMemoryTool(tool) &&
        _sameSkillStep(tool, last.detail, step.detail) &&
        !step.failed &&
        !last.failed &&
        !last.running) {
      rows[rows.length - 1] = last.merge(step);
    } else {
      rows.add(LiveTurnRow.of(step));
    }
  }
  return rows;
}

/// A ring with its mark inside: the green outline and the check, the way the
/// app draws a thing that is done (not a filled disc).
class LiveRingCheck extends StatelessWidget {
  const LiveRingCheck({this.size = HermesLiveTurn.ringSize, this.color, super.key});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      key: const ValueKey('live-ring-check'),
      size: Size.square(size),
      painter: _RingCheckPainter(color ?? Theme.of(context).hermes.success),
    ),
  );
}

class _RingCheckPainter extends CustomPainter {
  const _RingCheckPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 1.3 * size.shortestSide / 15;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawOval((Offset.zero & size).deflate(stroke / 2), paint);
    final w = size.width;
    final h = size.height;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.30, h * 0.52)
        ..lineTo(w * 0.44, h * 0.66)
        ..lineTo(w * 0.70, h * 0.37),
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingCheckPainter old) => old.color != color;
}

/// A ring with an exclamation mark inside: something did not work (orange,
/// like the check is green), so it is never mistaken for a done step.
class LiveRingBang extends StatelessWidget {
  const LiveRingBang({this.size = HermesLiveTurn.ringSize, this.color, super.key});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      key: const ValueKey('live-ring-bang'),
      size: Size.square(size),
      painter: _RingBangPainter(color ?? Theme.of(context).hermes.warning),
    ),
  );
}

class _RingBangPainter extends CustomPainter {
  const _RingBangPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 1.3 * size.shortestSide / 15;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawOval((Offset.zero & size).deflate(stroke / 2), paint);
    final w = size.width;
    final h = size.height;
    canvas.drawLine(Offset(w * 0.5, h * 0.28), Offset(w * 0.5, h * 0.55), paint);
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.72),
      stroke / 2,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingBangPainter old) => old.color != color;
}

/// A ring that turns while something runs; still (the same three quarters)
/// with «reducir animaciones».
class LiveSpinnerRing extends StatefulWidget {
  const LiveSpinnerRing({
    this.size = HermesLiveTurn.ringSize,
    this.color,
    super.key,
  });

  final double size;
  final Color? color;

  @override
  State<LiveSpinnerRing> createState() => _LiveSpinnerRingState();
}

class _LiveSpinnerRingState extends State<LiveSpinnerRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: HermesMotion.spin,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (HermesMotion.reduced(context)) {
      _turn.stop();
    } else if (!_turn.isAnimating) {
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).hermes.success;
    return RepaintBoundary(
      child: RotationTransition(
        key: const ValueKey('live-ring-spinner'),
        turns: _turn,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _SpinnerPainter(color),
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 1.3 * size.shortestSide / 15;
    canvas.drawArc(
      (Offset.zero & size).deflate(stroke / 2),
      -math.pi / 2,
      math.pi * 1.5,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.color != color;
}

/// The window of the live turn: at most [HermesLiveTurn.windowRows] actions
/// under the «Trabajando» card, whatever the turn has done. The newest comes
/// in by the bottom and the oldest leaves by the top; each pill draws its own
/// piece of the connector, so the line follows the rows while they move.
class LiveTurnWindow extends StatelessWidget {
  const LiveTurnWindow({required this.steps, super.key});

  /// The turn's tool steps, oldest first, the one in hand last.
  final List<TurnStepCardEntry> steps;

  @override
  Widget build(BuildContext context) {
    final rows = liveTurnRows(steps);
    if (rows.isEmpty) return const SizedBox.shrink();
    final skip = math.max(0, rows.length - HermesLiveTurn.windowRows);
    final shown = rows.sublist(skip);
    return TurnStepMotion(
      key: const ValueKey('live-turn-window'),
      entries: [
        for (var i = 0; i < shown.length; i++)
          (
            id: shown[i].id,
            child: _LiveRow(
              row: shown[i],
              // How many rows follow this one: it fades with them.
              age: shown.length - 1 - i,
              last: i == shown.length - 1,
            ),
          ),
      ],
    );
  }
}

class _LiveRow extends StatelessWidget {
  const _LiveRow({required this.row, required this.age, required this.last});

  final LiveTurnRow row;
  final int age;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final title = row.isMemory
        ? liveMemoryLabel(Strings.of(context), row)
        : row.name;
    final opacity = row.running
        ? 1.0
        : HermesLiveTurn.ageOpacity[age.clamp(
            0,
            HermesLiveTurn.ageOpacity.length - 1,
          )];
    return Semantics(
      key: ValueKey('live-turn-row-${row.id}'),
      container: true,
      label: [title, ?row.detail].join(', '),
      excludeSemantics: true,
      child: LiveTurnBranch(
        paintKey: ValueKey('live-turn-elbow-${row.id}'),
        last: last,
        child: AnimatedOpacity(
          opacity: opacity,
          duration: HermesMotion.duration(context, HermesMotion.enter),
          curve: HermesMotion.standard,
          child: LiveTurnRowPill(row: row),
        ),
      ),
    );
  }
}

/// One step of the live turn as its own small outlined pill (the approved
/// look of 9 nov, mock `turno3.html`): what the tool is, the verb in bold
/// with «×N» when calls were folded, the target in the secondary ink, the
/// clock of the call in hand and the state ring at the trailing end. The
/// closed window and the opened list draw every step with it.
class LiveTurnRowPill extends StatelessWidget {
  const LiveTurnRowPill({
    required this.row,
    this.showTime = false,
    this.open,
    this.quiet = false,
    this.progress,
    this.markKey,
    super.key,
  });

  final LiveTurnRow row;

  /// The unfolded level of an opened run: the same pill, shorter and
  /// quieter ([HermesLiveTurn.nestedRowHeight], hairline outline, fainter
  /// fill, the verb in medium weight, the ring in the secondary ink).
  final bool quiet;

  /// A running call's live progress (`42% · refining mesh`), beside its
  /// clock as Desktop's `ToolRunningMeta` says it.
  final String? progress;

  /// The key of the state ring (the opened list's rows are found by it).
  final Key? markKey;

  /// Also how long a finished row took (the opened list). The window says
  /// only the clock of the call in hand.
  final bool showTime;

  /// Null: the row opens nothing. Otherwise its caret, open or closed.
  final bool? open;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final s = row.running; // the one in hand
    final history = showTime && !s;
    final memory = row.isMemory;
    final memState = row.memoryState;
    final strings = Strings.of(context);
    // A memory row has its own tint (soft violet); a failed one is orange.
    final accent = !memory
        ? colors.success
        : memState == LiveMemoryState.failed
        ? colors.warning
        : HermesLiveTurn.memory;
    final title = memory ? liveMemoryLabel(strings, row) : row.name;
    final detail = row.detail;
    final started = row.startedAt;
    final nameStyle = HermesType.support.copyWith(
      fontWeight: quiet || history ? FontWeight.w500 : FontWeight.w600,
      color: colors.textPrimary,
    );
    final detailStyle = HermesType.support.copyWith(color: colors.textSecondary);
    final timeStyle = HermesType.caption.copyWith(
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: colors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final took = showTime && !s ? turnLineDuration(row.duration) : null;
    // Opened, a failure is said in words too, never by the colour alone.
    final failure = showTime && row.failed && !memory
        ? strings.stepsBarStatusFailed
        : null;
    final caret = open;
    final quietInk = quiet ? colors.textSecondary : null;
    final quietAlpha = quiet ? HermesLiveTurn.quietAlpha : 1.0;
    final surfaceAlpha = history &&
            !row.failed &&
            !memory &&
            !MediaQuery.highContrastOf(context)
        ? HermesLiveTurn.historyAlpha * quietAlpha
        : quietAlpha;
    final Widget mark = memory
        ? switch (memState) {
            LiveMemoryState.saving => LiveSpinnerRing(color: accent),
            LiveMemoryState.saved => LiveRingCheck(color: accent),
            LiveMemoryState.failed => LiveRingBang(color: accent),
            LiveMemoryState.unconfirmed => const SizedBox(
              width: HermesLiveTurn.ringSize,
              height: HermesLiveTurn.ringSize,
            ),
          }
        : row.failed
        ? Icon(HIcons.error_outline_rounded, size: HermesLiveTurn.glyphSize, color: colors.error)
        : s
        ? LiveSpinnerRing(color: quietInk)
        : LiveRingCheck(color: quietInk);
    final line = memory && memState != LiveMemoryState.unconfirmed
        ? accent.withValues(alpha: 0.5)
        : row.failed
        ? colors.error.withValues(alpha: 0.5)
        : s
        ? colors.success.withValues(alpha: 0.5)
        : chrome.line;
    final fill = s || (memory && memState != LiveMemoryState.unconfirmed)
        ? accent.withValues(alpha: 0.10)
        : chrome.fill;
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill.withValues(alpha: fill.a * surfaceAlpha),
        borderRadius: BorderRadius.circular(HermesRadius.tag),
        border: Border.all(
          color: line.withValues(alpha: line.a * surfaceAlpha),
          width: quiet ? HermesLiveTurn.hairline : 1,
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: quiet
              ? HermesLiveTurn.nestedRowHeight
              : HermesLiveTurn.rowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.gap),
          child: Row(
            children: [
              Icon(
                memory
                    ? HIcons.bookmark_border_rounded
                    : turnToolIconFor(row.toolName ?? ''),
                key: ValueKey(
                  memory ? 'live-turn-glyph-memory' : 'live-turn-glyph-${row.kind.name}',
                ),
                size: HermesLiveTurn.glyphSize,
                color: memory
                    ? accent
                    : s
                    ? colors.success
                    : colors.textSecondary,
              ),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: title, style: nameStyle),
                        if (detail != null && detail.isNotEmpty)
                          TextSpan(text: '  $detail', style: detailStyle),
                      ],
                    ),
                    maxLines: !history || row.count > 1
                        ? 1
                        : detail == null
                        ? 2
                        : constraints.maxWidth >= HermesLiveTurn.metaWithWords
                        ? 3
                        : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (caret != null) ...[
                const SizedBox(width: HermesSpace.x1),
                AnimatedRotation(
                  turns: caret ? 0 : -0.25,
                  duration: HermesMotion.duration(context, HermesMotion.fast),
                  child: Icon(
                    HIcons.expand_more,
                    key: ValueKey('live-turn-caret-${row.id}'),
                    size: HermesLiveTurn.glyphSize,
                    color: colors.textSecondary,
                  ),
                ),
              ],
              if (progress != null && s) ...[
                const SizedBox(width: HermesSpace.x2),
                Flexible(
                  child: Text(
                    progress!,
                    key: ValueKey('turn-step-progress-${row.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: timeStyle,
                  ),
                ),
              ],
              if (failure != null) ...[
                const SizedBox(width: HermesSpace.x2),
                Text(failure, style: timeStyle),
              ],
              if (s && started != null) ...[
                const SizedBox(width: HermesSpace.x2),
                ActivityTicker(
                  active: true,
                  clock: row.clock ?? LiveTurnScope.maybeOf(context)?.clock,
                  builder: (context, now) {
                    final value = turnLineDuration(now.difference(started));
                    return value == null
                        ? const SizedBox.shrink()
                        : Text(value, style: timeStyle);
                  },
                ),
              ] else if (took != null) ...[
                const SizedBox(width: HermesSpace.x2),
                Text(
                  failure == null ? took : '· $took',
                  key: ValueKey('live-turn-time-${row.id}'),
                  style: timeStyle,
                ),
              ],
              const SizedBox(width: HermesSpace.x2),
              KeyedSubtree(key: markKey, child: mark),
            ],
          ),
        ),
      ),
    );
    return history && !quiet
        ? HermesGelSurface(
            shape: const StadiumBorder(),
            pressable: false,
            sheenScale: HermesGel.textSheenScale(colors),
            child: surface,
          )
        : surface;
  }
}

/// A row's piece of the connector that hangs from the «Trabajando» card:
/// the vertical line down the side and the tick into [child] (see
/// [_ConnectorPainter]). Without [tick] it is only the line, passing beside
/// what a row opened under itself, and nothing at all under the last row.
/// [elbow] puts the tick that far below the row's top, for a row taller
/// than a pill; by default it meets the row at mid-height.
class LiveTurnBranch extends StatelessWidget {
  const LiveTurnBranch({
    required this.child,
    required this.last,
    this.tick = true,
    this.elbow,
    this.paintKey,
    this.quiet = false,
    this.history = false,
    super.key,
  });

  final Widget child;
  final bool last;
  final bool tick;
  final double? elbow;

  /// The unfolded level: a hairline connector at a lower contrast.
  final bool quiet;

  /// The expanded history uses shorter, quieter elbows than live work.
  final bool history;

  /// The key of the painted piece (the window's rows are found by it).
  final Key? paintKey;

  @override
  Widget build(BuildContext context) {
    final gutter = history
        ? HermesLiveTurn.connectorInset +
            HermesLiveTurn.connectorWidth +
            HermesSpace.x3
        : HermesLiveTurn.gutter;
    final color = history
        ? Theme.of(context).hermes.textSecondary.withValues(alpha: 0.42)
        : HermesLiveTurn.connector;
    final body = Padding(
      padding: EdgeInsetsDirectional.only(
        start: gutter,
        top: tick ? HermesLiveTurn.rowGap : 0,
      ),
      child: child,
    );
    if (!tick && last) return body;
    return CustomPaint(
      key: paintKey,
      painter: _ConnectorPainter(
        color: quiet
            ? color.withValues(alpha: color.a * HermesLiveTurn.quietAlpha)
            : color,
        gutter: gutter,
        width: quiet ? HermesLiveTurn.hairline : HermesLiveTurn.connectorWidth,
        last: last,
        rtl: Directionality.of(context) == TextDirection.rtl,
        tick: tick,
        elbow: elbow,
      ),
      child: body,
    );
  }
}

/// This row's piece of the connector: the vertical line through its gap and
/// its pill, and the elbow into the pill at mid-height. The last row ends in
/// a rounded corner instead of continuing down.
class _ConnectorPainter extends CustomPainter {
  const _ConnectorPainter({
    required this.color,
    required this.last,
    required this.rtl,
    required this.gutter,
    this.width = HermesLiveTurn.connectorWidth,
    this.tick = true,
    this.elbow,
  });

  final Color color;
  final double width;
  final bool last;
  final bool rtl;
  final double gutter;
  final bool tick;
  final double? elbow;

  @override
  void paint(Canvas canvas, Size size) {
    final w = width;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.butt;
    if (rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final x = HermesLiveTurn.connectorInset + w / 2;
    if (!tick) {
      // Beside what a row opened: the line only, on to the next row.
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      return;
    }
    final y = HermesLiveTurn.rowGap +
        math.min(
          elbow ?? double.infinity,
          (size.height - HermesLiveTurn.rowGap) / 2,
        );
    final end = gutter;
    final r = math.min(HermesLiveTurn.corner, y);
    if (last) {
      canvas.drawPath(
        Path()
          ..moveTo(x, 0)
          ..lineTo(x, y - r)
          ..arcTo(Rect.fromLTWH(x, y - 2 * r, 2 * r, 2 * r), math.pi, -math.pi / 2, false)
          ..lineTo(end, y),
        paint,
      );
    } else {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
    }
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.color != color ||
      old.width != width ||
      old.last != last ||
      old.rtl != rtl ||
      old.gutter != gutter ||
      old.tick != tick ||
      old.elbow != elbow;
}

/// The tail of the last line of what the model is thinking, as a quiet
/// italic fragment of one or two lines with a cursor: never the whole text,
/// never a bar, never bold.
class LiveReasoningSnippet extends StatelessWidget {
  const LiveReasoningSnippet({required this.text, super.key});

  final String text;

  /// True when [thought] is the same words as the [answer] being written (the
  /// interim narration shows in both): the same text, a prefix of it, or it a
  /// prefix of the thought. The live block then leaves the fragment out.
  static bool repeatsAnswer(String thought, String answer) {
    final t = thought.trim();
    final a = answer.trim();
    return t.isNotEmpty && a.isNotEmpty && (a.startsWith(t) || t.startsWith(a));
  }

  /// The fragment to show for [text]: its last non-empty line without the
  /// Markdown marks, cut from the left to [HermesLiveTurn.thoughtChars].
  static String fragment(String text) {
    var line = '';
    for (final raw in text.split('\n').reversed) {
      final clean = raw
          .replaceAll(RegExp(r'^[\s#>*\-]+'), '')
          .replaceAll(RegExp(r'(\*\*|__|`)'), '')
          .trim();
      if (clean.isNotEmpty) {
        line = clean;
        break;
      }
    }
    if (line.length <= HermesLiveTurn.thoughtChars) return line;
    final cut = line.substring(line.length - HermesLiveTurn.thoughtChars);
    final space = cut.indexOf(' ');
    return '…${space > 0 && space < 20 ? cut.substring(space + 1) : cut}';
  }

  @override
  Widget build(BuildContext context) {
    final shown = fragment(text);
    if (shown.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    return Padding(
      key: const ValueKey('live-turn-fragment'),
      padding: const EdgeInsetsDirectional.only(
        start: HermesSpace.x6 + HermesSpace.x1,
        top: HermesSpace.x2,
      ),
      child: Semantics(
        container: true,
        liveRegion: false,
        label: shown,
        excludeSemantics: true,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: shown),
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(start: HermesSpace.x1),
                  child: _BlinkCursor(),
                ),
              ),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: TurnType.reasoning,
            height: 1.4,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w400,
            color: colors.textSecondary.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}

class _BlinkCursor extends StatefulWidget {
  const _BlinkCursor();

  @override
  State<_BlinkCursor> createState() => _BlinkCursorState();
}

class _BlinkCursorState extends State<_BlinkCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: HermesMotion.breath * 0.25,
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (HermesMotion.reduced(context)) {
      _blink.stop();
      _blink.value = 1;
    } else if (!_blink.isAnimating) {
      _blink.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    key: const ValueKey('live-turn-cursor'),
    opacity: _blink,
    child: SizedBox(
      width: HermesLiveTurn.cursorWidth,
      height: HermesLiveTurn.cursorHeight,
      child: ColoredBox(color: Theme.of(context).hermes.success),
    ),
  );
}
