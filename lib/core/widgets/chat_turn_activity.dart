import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/activity_snapshot.dart';
import '../models/agent_task_list.dart';
import '../models/tool_label.dart';
import '../models/tool_name.dart';
import '../theme/app_theme.dart';
import '../utils/plain_preview.dart';
import 'activity_pill.dart';
import 'chat/chat_markdown_body.dart' show chatCodeTextStyle;
import 'compact_markdown.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ct1215 · The turn inside the transcript («C1 — como Desktop»)
//
// What Hermes is doing is told where the reply will be, under its name, in
// loose lines: one status line, the thinking as a quoted block, the tool in
// hand, the task list. When the turn ends they fold into at most two quiet
// lines the reader can open. No card, no bubble.
// ─────────────────────────────────────────────────────────────────────────────

/// Type sizes of the turn's lines: readable next to a 15 pt reply, never the
/// header pill's.
abstract final class TurnType {
  static const double status = 13;
  static const double row = 13.5;
  static const double reasoning = 14;
  static const double fold = 13;
}

/// What the live turn is doing, in the terms of the status line. Compared by
/// value, so the line only rebuilds when what it says changes: a reasoning
/// delta does not touch it.
@immutable
final class LiveTurnStatus {
  const LiveTurnStatus({
    this.active = false,
    this.startedAt,
    this.headline,
    this.waitingForUser = false,
    this.noActivityHint = false,
    this.step,
    this.tasks,
  });

  static const LiveTurnStatus idle = LiveTurnStatus();

  /// The same snapshot the header pill is painted from.
  factory LiveTurnStatus.of(ActivitySnapshot snapshot) {
    if (!snapshot.turnActive) return idle;
    final current = snapshot.current;
    return LiveTurnStatus(
      active: true,
      startedAt: snapshot.turnStartedAt,
      headline: snapshot.headline,
      waitingForUser: snapshot.waitingForUser,
      noActivityHint: snapshot.noActivityHint,
      step: current != null && current.kind != ActivityStepKind.reasoning
          ? current
          : null,
      tasks: snapshot.showTasks ? snapshot.tasks : null,
    );
  }

  final bool active;
  final DateTime? startedAt;

  /// Pipeline line when no tool runs («Pensando…», «Respondiendo…», a
  /// provider wait).
  final String? headline;
  final bool waitingForUser;
  final bool noActivityHint;

  /// The tool or skill in hand.
  final ActivityStep? step;

  /// The plan in flight, when there is one.
  final AgentTaskList? tasks;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveTurnStatus &&
          active == other.active &&
          startedAt == other.startedAt &&
          headline == other.headline &&
          waitingForUser == other.waitingForUser &&
          noActivityHint == other.noActivityHint &&
          step?.id == other.step?.id &&
          step?.label == other.step?.label &&
          step?.kind == other.step?.kind &&
          step?.title == other.step?.title &&
          _sameTasks(tasks, other.tasks);

  @override
  int get hashCode => Object.hash(
    active,
    startedAt,
    headline,
    waitingForUser,
    noActivityHint,
    step?.id,
    step?.label,
    tasks?.revision,
    tasks?.done,
    tasks?.total,
  );

  static bool _sameTasks(AgentTaskList? a, AgentTaskList? b) =>
      identical(a, b) || (a != null && b != null && a.sameContentAs(b));
}

/// Hands the live turn's state to the transcript rows that paint it, without
/// threading it through every message wrapper.
class LiveTurnScope extends InheritedWidget {
  const LiveTurnScope({
    required this.status,
    required this.clock,
    required super.child,
    super.key,
  });

  final LiveTurnStatus status;

  /// The clock the chat measures the turn with.
  final DateTime Function() clock;

  static LiveTurnScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveTurnScope>();

  @override
  bool updateShouldNotify(LiveTurnScope oldWidget) =>
      oldWidget.status != status;
}

/// The plan in flight of the live turn, for a turn that has nothing else to
/// show yet.
class LiveTurnTasks extends StatelessWidget {
  const LiveTurnTasks({super.key});

  @override
  Widget build(BuildContext context) {
    final tasks = LiveTurnScope.maybeOf(context)?.status.tasks;
    return tasks == null || tasks.isEmpty
        ? const SizedBox.shrink()
        : TurnTasksLive(tasks: tasks);
  }
}

String _trimStatus(String value) {
  var clean = value.trim();
  while (clean.endsWith('.') || clean.endsWith('…')) {
    clean = clean.substring(0, clean.length - 1).trimRight();
  }
  return clean.isEmpty ? value.trim() : clean;
}

/// The words of the status line: the state, and the step in hand when a tool
/// or a skill runs.
({String state, String? step}) turnStatusWords(
  Strings s,
  LiveTurnStatus status, {
  String? fallbackState,
}) {
  if (status.noActivityHint) return (state: s.chaTurnStillWorking, step: null);
  if (status.waitingForUser) return (state: s.liveWaitingForUser, step: null);
  final step = status.step;
  if (step != null) {
    return (
      state: _trimStatus(s.liveHeaderWorking),
      step: step.kind == ActivityStepKind.skill
          ? step.label
          : toolOrSkillStepTitle(
              s,
              step.label,
              running: true,
              gatewayTitle: step.title,
            ),
    );
  }
  return (
    state: _trimStatus(
      status.headline ?? fallbackState ?? s.chaPipelineThinking,
    ),
    step: null,
  );
}

/// «Trabajando · Ejecutando comando · 0:07»: the one line that says the turn
/// is alive, what it is on and for how long. A polite live region: a screen
/// reader hears the state change, never the seconds.
class TurnStatusLine extends StatelessWidget {
  const TurnStatusLine({this.fallbackState, super.key});

  /// State word when no chat describes the turn (the card on its own).
  final String? fallbackState;

  @override
  Widget build(BuildContext context) {
    final scope = LiveTurnScope.maybeOf(context);
    final status = scope?.status ?? LiveTurnStatus.idle;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final words = turnStatusWords(s, status, fallbackState: fallbackState);
    final startedAt = status.active ? status.startedAt : null;
    final waiting = status.waitingForUser && !status.noActivityHint;
    final base = TextStyle(
      fontSize: TurnType.status,
      height: 1.3,
      color: colors.textSecondary,
    );
    Widget line(DateTime? now) {
      final elapsed = startedAt == null || now == null
          ? null
          : now.difference(startedAt);
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: words.state,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: waiting ? colors.warning : colors.textPrimary,
              ),
            ),
            // No-break spaces: when the line wraps, a separator goes down
            // with what follows it and the timer with the last word; neither
            // is ever left alone on a line.
            if (words.step case final step?) TextSpan(text: ' ·\u00A0$step'),
            if (elapsed != null)
              TextSpan(
                text:
                    '\u00A0·\u00A0${formatTurnElapsed(elapsed.isNegative ? Duration.zero : elapsed)}',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
        key: const ValueKey('turn-status-text'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }

    return Semantics(
      key: const ValueKey('turn-status-line'),
      container: true,
      liveRegion: true,
      label: [words.state, ?words.step].join(', '),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 5, end: 7),
              child: _StatusMark(
                color: waiting ? colors.warning : colors.accent,
              ),
            ),
            Expanded(
              child: startedAt == null
                  ? line(null)
                  : ActivityTicker(
                      active: true,
                      clock: scope?.clock,
                      builder: (context, now) => line(now),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The small square that opens the status line.
class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
    child: const SizedBox.square(dimension: 8),
  );
}

/// A thought that only grows, cut into blocks that never change again and
/// the one still being written.
///
/// A block ends at a blank line (outside a code fence, and not in the middle
/// of a list whose items are spaced out). A passage that goes on without one
/// is cut at a line or a sentence once it is longer than [sealAfter], so the
/// block still being written stays that small however long the thought gets.
/// Feeding it the text as it grows costs one prefix comparison and a scan of
/// the new lines: nothing already cut is read again.
final class ThoughtBlocks {
  /// An unbroken passage is cut once it is longer than this.
  static const int sealAfter = 1200;

  /// The finished blocks, oldest first. [tight] ones continue the passage
  /// of the next block: no paragraph gap after them.
  final List<({String text, bool tight})> sealed = [];

  String _text = '';

  /// Where the block being written starts.
  int _start = 0;

  /// Start of the first line that is not complete yet.
  int _line = 0;

  /// Start of the blank line that may end the block being written.
  int _blank = -1;
  bool _fence = false;
  bool _list = false;

  static final RegExp _fenceMark = RegExp(r'^ {0,3}(?:```|~~~)');
  static final RegExp _listMark = RegExp(r'^\s*(?:[-*+]|\d{1,3}[.)])\s');

  /// The block being written.
  String get open => _text.substring(_start).trimRight();

  /// Takes the thought as it is now. Returns true when it is not the text
  /// seen before with more at its end, and so was cut again from its start.
  bool update(String text) {
    final restarted = !text.startsWith(_text);
    if (restarted) {
      sealed.clear();
      _start = 0;
      _line = 0;
      _blank = -1;
      _fence = false;
      _list = false;
    }
    _text = text;
    while (true) {
      final end = text.indexOf('\n', _line);
      if (end < 0) break;
      _examine(_line, text.substring(_line, end));
      _line = end + 1;
    }
    // A paragraph is one long line: do not wait for its end to close the
    // block before it.
    if (_blank >= 0 && text.length - _line >= 8) {
      final head = text.substring(_line, _line + 8);
      if (head.trim().isNotEmpty) _afterBlank(_line, head);
    }
    _cutLongPassage();
    return restarted;
  }

  void _examine(int at, String line) {
    if (_fence) {
      if (_fenceMark.hasMatch(line)) _fence = false;
      return;
    }
    if (line.trim().isEmpty) {
      if (at <= _start || _text.substring(_start, at).trim().isEmpty) {
        if (at >= _start) _start = at + line.length + 1;
      } else if (_blank < 0) {
        _blank = at;
      }
      return;
    }
    if (_blank >= 0) _afterBlank(at, line);
    if (_fenceMark.hasMatch(line)) _fence = true;
    _list =
        _listMark.hasMatch(line) ||
        (_list && (line.startsWith('  ') || line.startsWith('\t')));
  }

  /// A blank line was followed by [line]: the block ends there unless a
  /// spaced-out list goes on.
  void _afterBlank(int at, String line) {
    final listGoesOn =
        _list &&
        (_listMark.hasMatch(line) ||
            line.startsWith('  ') ||
            line.startsWith('\t'));
    if (!listGoesOn) {
      sealed.add((
        text: _text.substring(_start, _blank).trimRight(),
        tight: false,
      ));
      _start = at;
      _list = false;
    }
    _blank = -1;
  }

  void _cutLongPassage() {
    while (!_fence && _blank < 0 && _text.length - _start > sealAfter) {
      final limit = _start + sealAfter;
      final floor = _start + sealAfter ~/ 2;
      var cut = _text.lastIndexOf('\n', limit - 1) + 1;
      if (cut <= floor) {
        cut = -1;
        for (final mark in const ['. ', '? ', '! ', '… ']) {
          final at = _text.lastIndexOf(mark, limit - mark.length);
          if (at >= floor && at + mark.length > cut) cut = at + mark.length;
        }
      }
      if (cut <= floor) cut = _text.lastIndexOf(' ', limit - 1) + 1;
      if (cut <= floor) cut = limit;
      sealed.add((text: _text.substring(_start, cut).trimRight(), tight: true));
      _start = cut;
    }
  }
}

/// The thought being written, whole: every finished block is built once and
/// kept, and only the block still growing is parsed and laid out again when
/// more of it arrives.
class _LiveThought extends StatefulWidget {
  const _LiveThought({required this.text});

  final String text;

  @override
  State<_LiveThought> createState() => _LiveThoughtState();
}

class _LiveThoughtState extends State<_LiveThought> {
  final ThoughtBlocks _blocks = ThoughtBlocks();

  /// One widget per finished block, the same instance on every build: a
  /// block that is done is never rebuilt, parsed or laid out again.
  final List<Widget> _sealed = [];

  @override
  Widget build(BuildContext context) {
    if (_blocks.update(widget.text)) _sealed.clear();
    for (var index = _sealed.length; index < _blocks.sealed.length; index++) {
      final block = _blocks.sealed[index];
      _sealed.add(
        Padding(
          key: ValueKey('turn-thought-block-$index'),
          // The gap a paragraph leaves inside one Markdown body.
          padding: EdgeInsets.only(bottom: block.tight ? 0 : 6),
          child: CompactMarkdown(
            data: block.text,
            fontSize: TurnType.reasoning,
          ),
        ),
      );
    }
    final open = _blocks.open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._sealed,
        if (open.isNotEmpty)
          CompactMarkdown(
            key: const ValueKey('turn-thought-open'),
            data: open,
            fontSize: TurnType.reasoning,
            streaming: true,
          ),
      ],
    );
  }
}

/// The model's thinking as a quoted block: a rule on the left, no surface,
/// at a size meant to be read.
///
/// [live] is the thought being written now: it is shown whole, from its
/// first word, and grows with it ([_LiveThought] keeps what each new word
/// costs small). Finished, it is the whole text in one piece.
class TurnReasoningQuote extends StatelessWidget {
  const TurnReasoningQuote({required this.text, this.live = false, super.key});

  final String text;
  final bool live;

  static bool _blank(String text) {
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit != 0x20 && unit != 0x0A && unit != 0x0D && unit != 0x09) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final Widget body;
    if (live) {
      // Stops at the first word: never a pass over the whole thought.
      if (_blank(text)) return const SizedBox.shrink();
      body = _LiveThought(text: text);
    } else {
      final shown = text.trim();
      if (shown.isEmpty) return const SizedBox.shrink();
      body = CompactMarkdown(data: shown, fontSize: TurnType.reasoning);
    }
    return Semantics(
      container: true,
      label: Strings.of(context).rt1215Thinking,
      child: Padding(
        key: const ValueKey('turn-reasoning'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(
                color: colors.textSecondary.withValues(alpha: 0.45),
                width: 2,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12),
            child: SizedBox(width: double.infinity, child: body),
          ),
        ),
      ),
    );
  }
}

/// Icon of a tool row, by what the tool does.
IconData turnToolIcon(ActivityStep step) {
  if (step.kind == ActivityStepKind.skill) return Icons.auto_awesome_rounded;
  final name = canonicalToolName(step.label);
  if (isSkillActivityTool(name)) return Icons.auto_awesome_rounded;
  if (toolAppActionLabel(name) != null) return Icons.extension_outlined;
  return switch (name) {
    'terminal' ||
    'execute_code' ||
    'process_manage' ||
    'process' => Icons.terminal_rounded,
    'read_file' => Icons.description_outlined,
    'edit_file' || 'patch' || 'write_file' => Icons.edit_outlined,
    'list_files' => Icons.folder_open_outlined,
    'search_files' ||
    'web_search' ||
    'session_search_recall' ||
    'session_search' ||
    'x_search' => Icons.search_rounded,
    'memory' => Icons.psychology_outlined,
    'clarify' || 'setup_choose' => Icons.help_outline_rounded,
    'cronjob' || 'cronjob_manage' => Icons.schedule_rounded,
    'image_generate' || 'browser_take_screenshot' => Icons.image_outlined,
    'vision_analyze' => Icons.visibility_outlined,
    'start_chat' => Icons.chat_bubble_outline_rounded,
    // A subagent is the app's agent everywhere (the island's card too).
    'delegate_task' => Icons.smart_toy_outlined,
    'todo' || 'todo_list' => Icons.checklist_rounded,
    _ =>
      name.startsWith('browser_') || name.startsWith('web_')
          ? Icons.public_rounded
          : name.startsWith('kanban_')
          ? Icons.checklist_rounded
          : Icons.build_outlined,
  };
}

/// One tool of the turn: icon · what it does · its target in mono · how long.
/// A running one counts its own seconds.
class TurnToolRow extends StatelessWidget {
  const TurnToolRow({required this.step, this.clock, super.key});

  final ActivityStep step;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final failed = step.status == ActivityStepStatus.failed;
    final running = step.isRunning;
    final title = activityStepTitle(s, step);
    final ink = failed
        ? colors.error
        : (running ? colors.textPrimary : colors.textSecondary);
    final status = switch (step.status) {
      ActivityStepStatus.done => s.liveStepDone,
      ActivityStepStatus.failed => s.liveStepFailed,
      ActivityStepStatus.running => s.liveStepRunning,
    };
    Widget time(String text) => Padding(
      padding: const EdgeInsetsDirectional.only(start: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          color: colors.textSecondary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final startedAt = step.startedAt;
    final Widget? trailing;
    if (running && startedAt != null) {
      trailing = ActivityTicker(
        active: true,
        clock: clock,
        builder: (context, now) {
          final elapsed = now.difference(startedAt);
          return time(
            formatTurnElapsed(elapsed.isNegative ? Duration.zero : elapsed),
          );
        },
      );
    } else if (!running && step.duration != null) {
      trailing = time(formatStepDuration(step.duration!, languageCode: lang));
    } else {
      trailing = null;
    }
    final duration = !running && step.duration != null
        ? formatStepDuration(step.duration!, languageCode: lang)
        : null;
    return Semantics(
      container: true,
      label: [title, ?step.detail, status, ?duration].join(', '),
      excludeSemantics: true,
      child: Padding(
        key: ValueKey('turn-tool-${step.id}'),
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 1, end: 8),
              child: Icon(
                failed ? Icons.error_outline_rounded : turnToolIcon(step),
                size: 16,
                color: failed ? colors.error : colors.textSecondary,
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: title,
                      style: TextStyle(color: ink),
                    ),
                    if (step.detail case final detail?) ...[
                      TextSpan(
                        text: ' · ',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                      TextSpan(
                        text: detail,
                        style: chatCodeTextStyle(
                          colors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: TurnType.row, height: 1.3),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

String _taskStatusWord(Strings s, AgentTaskStatus status) => switch (status) {
  AgentTaskStatus.pending => s.agentTasksStatusPending,
  AgentTaskStatus.inProgress => s.agentTasksStatusInProgress,
  AgentTaskStatus.completed => s.agentTasksStatusCompleted,
  AgentTaskStatus.cancelled => s.agentTasksStatusCancelled,
};

/// One task of the turn's plan.
class _TurnTaskRow extends StatelessWidget {
  const _TurnTaskRow({
    required this.item,
    required this.depth,
    this.history = false,
  });

  final AgentTaskItem item;
  final int depth;

  /// The turn ended: nothing is in progress, what stayed open is marked.
  final bool history;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final notDone = history && item.isOpen;
    final Widget icon = switch (item.status) {
      AgentTaskStatus.completed => Icon(
        Icons.check_rounded,
        size: 16,
        color: history ? colors.success.withValues(alpha: 0.8) : colors.success,
      ),
      AgentTaskStatus.inProgress when !history && !reduceMotion => SizedBox(
        width: 13,
        height: 13,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: colors.accent,
        ),
      ),
      AgentTaskStatus.inProgress when !history => Icon(
        Icons.play_circle_outline_rounded,
        size: 16,
        color: colors.accent,
      ),
      AgentTaskStatus.cancelled => Icon(
        Icons.block_rounded,
        size: 15,
        color: colors.textSecondary,
      ),
      _ => Icon(
        Icons.radio_button_unchecked_rounded,
        size: 15,
        color: colors.textSecondary,
      ),
    };
    final style = switch (item.status) {
      AgentTaskStatus.completed => TextStyle(color: colors.textSecondary),
      AgentTaskStatus.cancelled => TextStyle(
        color: colors.textSecondary,
        fontStyle: FontStyle.italic,
      ),
      AgentTaskStatus.inProgress when !history => TextStyle(
        color: colors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      _ => TextStyle(color: colors.textPrimary),
    };
    return Semantics(
      container: true,
      label: notDone
          ? '${item.content}: ${s.ctTaskNotDone}'
          : '${_taskStatusWord(s, item.status)}: ${item.content}',
      excludeSemantics: true,
      child: Padding(
        key: ValueKey('turn-task-${item.id}'),
        padding: EdgeInsetsDirectional.only(
          start: (depth > 3 ? 3 : depth) * 14.0,
          top: 3,
          bottom: 3,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: TurnType.row * 1.3,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: icon,
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: plainPreview(item.content)),
                    if (notDone)
                      TextSpan(
                        text: ' · ${s.ctTaskNotDone}',
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                  ],
                ),
                style: style.copyWith(fontSize: TurnType.row, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The plan in flight: «Tareas 3/5» with a thin bar, the finished ones folded
/// into «3 completadas», the one in hand with a spinner, the pending listed.
class TurnTasksLive extends StatefulWidget {
  const TurnTasksLive({required this.tasks, super.key});

  final AgentTaskList tasks;

  @override
  State<TurnTasksLive> createState() => _TurnTasksLiveState();
}

class _TurnTasksLiveState extends State<TurnTasksLive> {
  bool _showDone = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final tasks = widget.tasks;
    final rows = tasks.rows;
    final done = [
      for (final row in rows)
        if (row.item.status == AgentTaskStatus.completed) row,
    ];
    final shown = _showDone
        ? rows
        : [
            for (final row in rows)
              if (row.item.status != AgentTaskStatus.completed) row,
          ];
    return Column(
      key: const ValueKey('turn-tasks-live'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          container: true,
          header: true,
          label: s.agentTasksSummary(tasks.done, tasks.total),
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            // The bar sits next to the count and drops under it when large
            // text leaves it no room.
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Icon(
                        Icons.checklist_rounded,
                        size: 16,
                        color: colors.textSecondary,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        s.agentTasksPillTitle(tasks.done, tasks.total),
                        key: const ValueKey('turn-tasks-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TurnType.row,
                          height: 1.3,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  width: 96,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      key: const ValueKey('turn-tasks-progress'),
                      value: tasks.progress,
                      minHeight: 3,
                      backgroundColor: colors.divider,
                      color: tasks.isFinished ? colors.success : colors.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (done.isNotEmpty)
          TurnFoldLine(
            key: const ValueKey('turn-tasks-done-toggle'),
            label: s.fh1215TasksCompleted(done.length),
            expanded: _showDone,
            leading: Icons.check_rounded,
            leadingColor: colors.success,
            onTap: () => setState(() => _showDone = !_showDone),
          ),
        for (final row in shown) _TurnTaskRow(item: row.item, depth: row.depth),
        if (tasks.omitted > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 24, top: 2),
            child: Text(
              s.agentTasksMore(tasks.omitted),
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// The plan of a finished turn, opened: every task with its final state,
/// the ones left open marked «sin hacer».
class TurnTasksHistory extends StatelessWidget {
  const TurnTasksHistory({required this.tasks, super.key});

  final AgentTaskList tasks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Column(
      key: const ValueKey('turn-tasks-history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in tasks.rows)
          _TurnTaskRow(item: row.item, depth: row.depth, history: true),
        if (tasks.omitted > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 24, top: 2),
            child: Text(
              s.agentTasksMore(tasks.omitted),
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// «Tareas 4 de 5 · 1 sin hacer»: the folded line of a finished turn's plan.
String turnTasksFoldLabel(Strings s, AgentTaskList tasks) {
  final open = tasks.openCount;
  final base = s.ctTasksOfTotal(tasks.done, tasks.total);
  return open == 0 ? base : '$base · ${s.ctTasksNotDone(open)}';
}

/// A quiet line that opens what it names: a button with its expanded state,
/// a chevron at its end.
class TurnFoldLine extends StatelessWidget {
  const TurnFoldLine({
    required this.label,
    required this.expanded,
    this.onTap,
    this.leading,
    this.leadingColor,
    this.semanticsLabel,
    super.key,
  });

  final String label;
  final bool expanded;

  /// Null when there is nothing to open: the line is then plain text.
  final VoidCallback? onTap;
  final IconData? leading;
  final Color? leadingColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final line = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 30),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading case final icon?)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Icon(
                icon,
                size: 16,
                color: leadingColor ?? colors.textSecondary,
              ),
            ),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TurnType.fold,
                height: 1.3,
                color: colors.textSecondary,
              ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              child: Icon(
                Icons.expand_more,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) {
      return Semantics(
        container: true,
        label: semanticsLabel ?? label,
        excludeSemantics: true,
        child: line,
      );
    }
    return Semantics(
      container: true,
      button: true,
      expanded: expanded,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: line,
      ),
    );
  }
}
