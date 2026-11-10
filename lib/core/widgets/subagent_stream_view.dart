import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../models/tool_label.dart' show toolStepTitle;
import '../screens/subagent_detail_screen.dart' show SubagentLiveTail;
import '../services/subagent_child_session.dart';
import '../services/subagent_finished_record.dart' show subagentLiveTarget;
import '../services/subagent_live_watch.dart';
import '../services/subagent_tail_log.dart';
import '../theme/app_theme.dart';
import 'activity_pill.dart' show ActivityTicker, formatTurnElapsed;
import 'chat/chat_live_icon.dart';
import 'chat/chat_markdown_body.dart';

/// Section headings and notes for a FINISHED agent read back from storage
/// (its goal, the steps it ran, its result), so the same rows read as a
/// record instead of a live log. A record opens at its top.
final class SubagentStreamRecap {
  const SubagentStreamRecap({
    required this.task,
    required this.steps,
    required this.result,
    required this.empty,
    this.note,
    this.meta,
  });

  final String task;
  final String steps;
  final String result;

  /// Said when there is nothing at all to show.
  final String empty;

  /// Where the record comes from, when it is not the child's conversation.
  final String? note;

  /// Duration, model and API calls, one line.
  final String? meta;
}

/// Stable transcript viewport, read top to bottom like a chat. Layout pins
/// new output in the same frame; dragging pauses follow until the reader
/// reaches the bottom again. Output only grows at the end, so a paused
/// reader keeps what is on screen without any anchoring.
class SubagentStreamView extends StatefulWidget {
  const SubagentStreamView({
    super.key,
    required this.tail,
    required this.live,
    required this.prompt,
    required this.working,
    this.result = '',
    this.showTargets = false,
    this.activityLabel = '',
    this.activityDetail = '',
    this.activitySince,
    this.active = true,
    this.clock,
    this.recap,
    this.child,
  });
  final ValueListenable<SubagentLiveTail> tail;
  final ValueListenable<SubagentLiveWatchView> live;
  final String prompt;
  final bool working;
  final String result;

  /// Whether the one-line target of each tool is shown: the owner-wired
  /// surface only, command lines included, with every secret masked
  /// ([subagentLiveTarget]).
  final bool showTargets;

  /// What the child does now per its roster (thinking, using a tool), shown
  /// at the end while no tool row or streamed text already says it.
  final String activityLabel;

  /// Owner-only detail of [activityLabel] (the thought, the tool target).
  final String activityDetail;

  /// When the step [activityLabel] names began, if known: its clock runs
  /// beside it so a long command visibly keeps working.
  final DateTime? activitySince;

  /// Whether the page is visible: the running tool's clock ticks only then.
  final bool active;
  final DateTime Function()? clock;

  /// Headings of a finished agent's record; null for the live log.
  final SubagentStreamRecap? recap;

  /// The running child read from its own stored session (owner surface
  /// only). Once it holds rows it is the page's source: the live mirror and
  /// the polled log only add what it does not hold yet
  /// ([mergeSubagentChildRows]).
  final ValueListenable<SubagentChildFeedView>? child;

  @override
  State<SubagentStreamView> createState() => _SubagentStreamViewState();
}

class _SubagentStreamViewState extends State<SubagentStreamView> {
  late bool _follow = widget.recap == null;
  // A child read from its session opens like the official app's chat of
  // the child: its whole task first.
  late bool _promptOpen = widget.child != null;
  SubagentLiveWatchView? _sealedTranscript;
  final Map<String, _MarkdownCache> _markdown = {};
  late final _scroll = _FollowScrollController(following: () => _follow);

  // The polled live transcript as rows, parsed once per new tail.
  List<String>? _parsedLines;
  List<SubagentTailEntry>? _parsedRows;

  /// Rows of the polled tail when it is the server's live transcript; null
  /// when it is prose (a mirrored watch text), which stays Markdown.
  List<SubagentTailEntry>? _tailRows(SubagentLiveTail tail) {
    if (!identical(tail.lines, _parsedLines)) {
      _parsedLines = tail.lines;
      final text = tail.text;
      _parsedRows = isSubagentTailLog(text)
          ? parseSubagentTailLog(text, truncated: tail.truncated)
          : null;
    }
    return _parsedRows;
  }

  @override
  void initState() {
    super.initState();
    widget.tail.addListener(_onContent);
    widget.live.addListener(_onContent);
    widget.child?.addListener(_onContent);
  }

  void _onContent() {
    final view = widget.live.value;
    if (view.blocks.isNotEmpty) _sealedTranscript = view;
    if (_follow) _scroll.requestFollow();
  }

  @override
  void dispose() {
    widget.tail.removeListener(_onContent);
    widget.live.removeListener(_onContent);
    widget.child?.removeListener(_onContent);
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      if (_follow) setState(() => _follow = false);
    } else if (!_follow &&
        (notification is ScrollUpdateNotification ||
            notification is ScrollEndNotification) &&
        notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - .5) {
      setState(() => _follow = true);
    }
    return false;
  }

  Widget _textBlock(
    SubagentWatchBlock block,
    bool streaming, {
    bool appendOnly = true,
  }) {
    final cache = _markdown.putIfAbsent(
      block.id,
      () => _MarkdownCache(block.id),
    );
    return RepaintBoundary(
      key: ValueKey('subagent-text-${block.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: cache.update(
          block.text,
          streaming: streaming,
          appendOnly: appendOnly,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              widget.tail,
              widget.live,
              ?widget.child,
            ]),
            builder: (context, _) {
              final view = widget.live.value;
              if (view.blocks.isNotEmpty) {
                _sealedTranscript = view;
              } else if (widget.working) {
                // An unavailable/covered watch gives way to fresh polling.
                _sealedTranscript = null;
              }
              // Closing the watch clears its live state, not the public log
              // the reader is already reading. Keep that log at its full
              // native budget instead of replacing it with the 16 KB tail.
              final transcript = view.blocks.isEmpty && !widget.working
                  ? _sealedTranscript ?? view
                  : view;
              final native = transcript.blocks;
              final parsed = native.isEmpty
                  ? _tailRows(widget.tail.value)
                  : null;
              // Another opener sees which tools ran and how they ended,
              // never a command, an output or the child's words.
              final tailRows = parsed == null
                  ? null
                  : widget.showTargets
                  ? parsed
                  : [
                      for (final row in parsed)
                        if (row.kind == SubagentTailKind.tool) row,
                    ];
              // The child's own session, once read, is the source; the
              // mirror and the polled log add only what it lacks yet.
              final feed = widget.child?.value;
              final childTranscript = feed != null && feed.hasRows
                  ? feed.transcript
                  : null;
              List<SubagentTailEntry>? childRows;
              SubagentWatchBlock? streaming;
              if (childTranscript != null) {
                final merged = mergeSubagentChildRows(
                  childTranscript,
                  tail: _tailRows(widget.tail.value),
                  watch: native,
                );
                childRows = widget.showTargets
                    ? merged
                    : [
                        for (final row in merged)
                          if (row.kind == SubagentTailKind.tool) row,
                      ];
                // Words still being written are not stored yet.
                final open = native.isEmpty ? null : native.last;
                if (open != null &&
                    open.tool == null &&
                    !open.closed &&
                    open.text.trim().isNotEmpty &&
                    widget.showTargets) {
                  streaming = open;
                }
              }
              final blocks = childRows != null
                  ? [?streaming]
                  : native.isNotEmpty
                  ? native
                  : tailRows != null
                  ? const <SubagentWatchBlock>[]
                  : [SubagentWatchBlock.text('tail', widget.tail.value.text)];
              final shownRows = childRows ?? tailRows;
              final result = widget.result.trim();
              final lastChildText = childRows == null
                  ? null
                  : [
                      for (final row in childRows)
                        if (row.kind == SubagentTailKind.text) row.text,
                    ].lastOrNull;
              final showResult =
                  !widget.working &&
                  result.isNotEmpty &&
                  !(lastChildText ??
                          (native.isEmpty
                              ? widget.tail.value.text
                              : transcript.text))
                      .trim()
                      .endsWith(result);
              final ids = {
                for (final block in blocks) block.id,
                if (childRows != null)
                  for (final row in childRows)
                    if (row.kind == SubagentTailKind.text) row.id,
                if (showResult) 'result',
              };
              _markdown.removeWhere((id, _) => !ids.contains(id));
              final recap = widget.recap;
              final hasSteps =
                  (shownRows?.isNotEmpty ?? false) ||
                  blocks.any(
                    (block) => block.tool != null || block.text.isNotEmpty,
                  );
              final children = <Widget>[
                if (recap != null && widget.prompt.isNotEmpty)
                  HermesSectionHeader(recap.task),
                if (widget.prompt.isNotEmpty) ...[
                  InkWell(
                    key: const ValueKey('subagent-prompt-toggle'),
                    onTap: () => setState(() => _promptOpen = !_promptOpen),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: HermesSpace.tap,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.chat_bubble_outline_rounded),
                          const SizedBox(width: HermesSpace.x2),
                          Expanded(
                            child: Text(
                              widget.prompt,
                              maxLines: _promptOpen ? null : 1,
                              overflow: _promptOpen
                                  ? null
                                  : TextOverflow.ellipsis,
                              style: HermesType.support.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                          Icon(
                            _promptOpen ? Icons.expand_less : Icons.expand_more,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: HermesSpace.x3),
                ],
                if (recap?.note case final note?)
                  Text(
                    note,
                    key: const ValueKey('subagent-record-note'),
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                if (recap != null && hasSteps) HermesSectionHeader(recap.steps),
                for (final block in blocks)
                  if (block.tool case final tool?)
                    _toolRow(context, tool, view)
                  else if (block.text.isNotEmpty)
                    _textBlock(
                      block,
                      widget.working &&
                          !block.closed &&
                          view.status != SubagentLiveWatchStatus.finished,
                      appendOnly: native.isNotEmpty,
                    ),
                if (childRows != null)
                  for (final row in childRows)
                    if (row.kind == SubagentTailKind.tool)
                      SubagentTailToolRow(
                        key: ValueKey('subagent-tail-${row.id}'),
                        entry: row,
                        showTargets: widget.showTargets,
                        running: widget.working && !row.finished,
                        // The stored call says when it began.
                        since: row.finished
                            ? null
                            : childTranscript!.startedAt[row.id] ??
                                  widget.activitySince,
                        active: widget.active,
                        clock: widget.clock,
                      )
                    else if (row.kind == SubagentTailKind.text &&
                        row.id.startsWith('child-text-'))
                      // The child's words read as the chat renders an
                      // answer: Markdown.
                      _textBlock(
                        SubagentWatchBlock.text(row.id, row.text, closed: true),
                        false,
                        appendOnly: false,
                      )
                    else
                      SubagentTailProse(
                        key: ValueKey('subagent-tail-${row.id}'),
                        entry: row,
                      ),
                if (childRows == null && tailRows != null)
                  for (final row in tailRows)
                    if (row.kind == SubagentTailKind.tool)
                      SubagentTailToolRow(
                        key: ValueKey('subagent-tail-${row.id}'),
                        entry: row,
                        showTargets: widget.showTargets,
                        running: widget.working && !row.finished,
                        // The roster knows when the step in hand began.
                        since: row.finished ? null : widget.activitySince,
                        active: widget.active,
                        clock: widget.clock,
                      )
                    else
                      SubagentTailProse(
                        key: ValueKey('subagent-tail-${row.id}'),
                        entry: row,
                      ),
                if (recap != null && showResult)
                  HermesSectionHeader(recap.result),
                if (showResult)
                  _textBlock(
                    SubagentWatchBlock.text('result', result, closed: true),
                    false,
                    appendOnly: false,
                  ),
                if (view.status == SubagentLiveWatchStatus.reconnecting)
                  Text(
                    s.subagentUiStatusUnconfirmed,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                if (blocks.every(
                      (block) => block.text.isEmpty && block.tool == null,
                    ) &&
                    (shownRows?.isEmpty ?? true) &&
                    !showResult &&
                    !_showsActivity(view, blocks, shownRows))
                  Text(
                    widget.working
                        ? feed?.status == SubagentChildFeedStatus.waiting
                              ? s.subagentUiWaitingChild
                              : s.subagentUiLiveWaiting
                        : recap?.empty ?? s.subagentUiTranscriptEmpty,
                    key: const ValueKey('subagent-stream-empty'),
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                if (_showsActivity(view, blocks, shownRows))
                  _activityRow(context),
                if (recap?.meta case final meta?)
                  Padding(
                    padding: const EdgeInsets.only(top: HermesSpace.x3),
                    child: Text(
                      meta,
                      key: const ValueKey('subagent-record-meta'),
                      style: HermesType.support.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
              ];
              return CustomScrollView(
                key: const ValueKey('subagent-live-panel'),
                controller: _scroll,
                slivers: [
                  SliverPadding(
                    // The end keeps room for the follow button so the last
                    // line is never under it.
                    padding: const EdgeInsets.fromLTRB(
                      HermesSpace.pageH,
                      HermesSpace.pageH,
                      HermesSpace.pageH,
                      HermesSpace.pageH + HermesSpace.tap,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: children,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (!_follow)
          PositionedDirectional(
            bottom: HermesSpace.x2,
            end: HermesSpace.x2,
            child: IconButton.filledTonal(
              key: const ValueKey('subagent-live-follow'),
              tooltip: s.subagentUiGoToEnd,
              constraints: const BoxConstraints(
                minWidth: HermesSpace.tap,
                minHeight: HermesSpace.tap,
              ),
              onPressed: () {
                setState(() => _follow = true);
                _scroll.requestFollow();
                if (_scroll.hasClients) {
                  _scroll.jumpTo(_scroll.position.maxScrollExtent);
                }
              },
              icon: const Icon(Icons.arrow_downward_rounded),
            ),
          ),
      ],
    );
  }

  /// The roster's "now" line belongs at the end only while the stream does
  /// not already show the work in hand (a running tool, text being written).
  bool _showsActivity(
    SubagentLiveWatchView view,
    List<SubagentWatchBlock> blocks, [
    List<SubagentTailEntry>? tailRows,
  ]) {
    if (!widget.working ||
        view.status != SubagentLiveWatchStatus.live ||
        widget.activityLabel.isEmpty) {
      return false;
    }
    if (blocks.any((b) => b.tool != null && !b.tool!.finished)) return false;
    // The log already shows the call in hand, with its clock: the roster's
    // «thinking» (which may last the whole run of a command) gives way to it.
    if (tailRows != null &&
        tailRows.any(
          (row) => row.kind == SubagentTailKind.tool && !row.finished,
        )) {
      return false;
    }
    final last = blocks.isEmpty ? null : blocks.last;
    return last == null ||
        last.tool != null ||
        last.closed ||
        last.text.trim().isEmpty;
  }

  Widget _activityRow(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final detail = widget.activityDetail.trim();
    return Padding(
      key: const ValueKey('subagent-stream-activity'),
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.activityLabel,
                  style: HermesType.support.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              if (widget.activitySince case final since?)
                _ToolClock(
                  key: ValueKey(
                    'subagent-stream-activity-clock-${since.microsecondsSinceEpoch}',
                  ),
                  active: widget.active,
                  clock: widget.clock,
                  since: since,
                ),
            ],
          ),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: HermesSpace.x1),
              child: Text(
                detail,
                key: const ValueKey('subagent-stream-activity-detail'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: HermesType.support.copyWith(
                  color: colors.textSecondary,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolRow(
    BuildContext context,
    SubagentWatchTool tool,
    SubagentLiveWatchView view,
  ) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final confirmed = view.status != SubagentLiveWatchStatus.reconnecting;
    final running =
        !tool.finished &&
        confirmed &&
        widget.working &&
        view.status != SubagentLiveWatchStatus.finished;
    final label = tool.finished
        ? '${tool.name} · ${tool.failed ? s.subagentUiStatusFailed : s.subagentUiStatusDone}'
        : running
        ? s.subagentPillRunningTool(tool.name)
        : '${tool.name} · ${s.subagentUiStatusUnconfirmed}';
    final preview = widget.showTargets
        ? subagentLiveTarget(tool.preview)
        : null;
    return Padding(
      key: ValueKey('subagent-stream-tool-${tool.id}'),
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: Semantics(
        label: preview == null ? label : '$label: $preview',
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.terminal_rounded,
              size: HermesSpace.x5,
              color: colors.textSecondary,
            ),
            const SizedBox(width: HermesSpace.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    label,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  if (preview != null)
                    Text(
                      preview,
                      key: ValueKey('subagent-stream-tool-preview-${tool.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.4,
                        color: colors.textPrimary,
                      ),
                    ),
                ],
              ),
            ),
            if (running)
              _ToolClock(
                key: ValueKey('subagent-stream-tool-clock-${tool.id}'),
                active: widget.active,
                clock: widget.clock,
              ),
          ],
        ),
      ),
    );
  }
}

/// How long the running tool has been at it, counted from when this page saw
/// it start. Its own ticker: one second repaints this text only.
class _ToolClock extends StatefulWidget {
  const _ToolClock({super.key, required this.active, this.clock, this.since});

  final bool active;
  final DateTime Function()? clock;

  /// When the work began, if known; else when this page first saw it.
  final DateTime? since;

  @override
  State<_ToolClock> createState() => _ToolClockState();
}

class _ToolClockState extends State<_ToolClock> {
  late final DateTime _start = widget.since ?? (widget.clock ?? DateTime.now)();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: HermesSpace.x2),
      child: ActivityTicker(
        active: widget.active,
        clock: widget.clock,
        builder: (context, now) => Text(
          formatTurnElapsed(now.difference(_start)),
          style: HermesType.support.copyWith(
            color: colors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// The child's words in the live transcript: its reply as plain prose, its
/// thought quieter, its run's error in the error ink. One paragraph each.
class SubagentTailProse extends StatelessWidget {
  const SubagentTailProse({super.key, required this.entry});

  final SubagentTailEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final style = switch (entry.kind) {
      SubagentTailKind.thought => HermesType.support.copyWith(
        color: colors.textSecondary,
        fontStyle: FontStyle.italic,
      ),
      SubagentTailKind.error => HermesType.support.copyWith(
        color: colors.error,
      ),
      _ => HermesType.body.copyWith(color: colors.textPrimary),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: Text(entry.text, style: style),
    );
  }
}

/// One row of the live transcript, tool call or prose, for the owner
/// ([showTargets]) or, as tool titles and outcomes only, for anyone else.
Widget? subagentTailRow(
  SubagentTailEntry entry, {
  required bool showTargets,
  bool running = false,
  bool active = true,
  DateTime Function()? clock,
}) {
  final key = ValueKey('subagent-tail-${entry.id}');
  if (entry.kind == SubagentTailKind.tool) {
    return SubagentTailToolRow(
      key: key,
      entry: entry,
      showTargets: showTargets,
      running: running,
      active: active,
      clock: clock,
    );
  }
  return showTargets ? SubagentTailProse(key: key, entry: entry) : null;
}

/// Lines of a tool's output shown before «Ver más».
const int kSubagentTailPreviewLines = 6;

/// How long a call took, in the reader's numbers: «0,1 s», «12 s», «1:05».
String subagentTailDuration(double seconds, String locale) {
  if (!seconds.isFinite || seconds < 0) return '';
  if (seconds >= 60) {
    return formatTurnElapsed(Duration(milliseconds: (seconds * 1000).round()));
  }
  if (seconds >= 10) return '${seconds.round()} s';
  String number;
  try {
    number = NumberFormat('0.0', locale).format(seconds);
  } catch (_) {
    number = seconds.toStringAsFixed(1);
  }
  return '$number s';
}

/// How a finished call ended, one short line: «ok · 0,1 s», «falló · exit 1».
String subagentTailStatus(Strings s, SubagentTailEntry entry, String locale) {
  final duration = entry.durationSeconds == null
      ? ''
      : subagentTailDuration(entry.durationSeconds!, locale);
  final exit = entry.exitCode;
  if (entry.failed) {
    final failed = s.subagentUiStatusFailed.toLowerCase();
    if (exit != null && exit != 0) return '$failed · exit $exit';
    return duration.isEmpty ? failed : '$failed · $duration';
  }
  return duration.isEmpty ? 'ok' : 'ok · $duration';
}

/// One tool call of the live transcript, in the page's row family: the
/// chat's outline glyph of the tool, its title, the quiet time it began on
/// the right, its one-line command, how it ended (or its clock while it
/// runs) and the start of what it printed, folded to a few monospace lines
/// that open with «Ver más». The command and output are the owner's only.
class SubagentTailToolRow extends StatefulWidget {
  const SubagentTailToolRow({
    super.key,
    required this.entry,
    required this.showTargets,
    required this.running,
    this.since,
    this.active = true,
    this.clock,
  });

  final SubagentTailEntry entry;
  final bool showTargets;
  final bool running;

  /// When the call in hand began, if known; else its clock starts when this
  /// page first sees it.
  final DateTime? since;
  final bool active;
  final DateTime Function()? clock;

  @override
  State<SubagentTailToolRow> createState() => _SubagentTailToolRowState();
}

class _SubagentTailToolRowState extends State<SubagentTailToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final entry = widget.entry;
    final locale = Localizations.localeOf(context).toString();
    final tool = entry.tool ?? '';
    final title = toolStepTitle(s, tool, running: !entry.finished);
    final status = entry.finished
        ? subagentTailStatus(s, entry, locale)
        : null;
    final command = widget.showTargets ? entry.command : null;
    final output = widget.showTargets ? entry.output : '';
    final lines = output.isEmpty ? const <String>[] : output.split('\n');
    final folds = lines.length > kSubagentTailPreviewLines;
    final shown = _open || lines.length <= kSubagentTailPreviewLines
        ? lines
        : lines.sublist(0, kSubagentTailPreviewLines);
    final preview = [
      ...shown,
      if (lines.isNotEmpty &&
          ((!_open && folds) || (entry.outputCut && (_open || !folds))))
        '…',
    ].join('\n');
    final ink = entry.failed ? colors.error : colors.textPrimary;
    final semantics = [
      title,
      ?command,
      ?status,
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SizedBox.square(
              dimension: _tailIconSize,
              child: ChatLiveIcon(
                key: ValueKey('subagent-tail-icon-${entry.id}'),
                chatLiveGlyphForTool(tool),
                live: widget.running,
                size: _tailIconSize,
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: HermesSpace.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Semantics(
                        label: semantics,
                        excludeSemantics: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              title,
                              style: HermesType.support.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                            if (command != null)
                              Text(
                                command,
                                key: ValueKey(
                                  'subagent-tail-command-${entry.id}',
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: HermesType.monoFamily,
                                  fontSize: 12,
                                  height: 1.4,
                                  color: colors.textPrimary,
                                ),
                              ),
                            if (status != null)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: HermesSpace.x1,
                                ),
                                child: Text(
                                  status,
                                  key: ValueKey(
                                    'subagent-tail-status-${entry.id}',
                                  ),
                                  style: HermesType.caption.copyWith(
                                    color: entry.failed
                                        ? colors.error
                                        : colors.textSecondary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    // Outside the row's label: the running clock is read
                    // out as it is shown, the time a call began too.
                    if (widget.running)
                      _ToolClock(
                        key: ValueKey('subagent-tail-clock-${entry.id}'),
                        active: widget.active,
                        clock: widget.clock,
                        since: widget.since,
                      )
                    else if (entry.time case final time?)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: HermesSpace.x2,
                        ),
                        child: Text(
                          time,
                          key: ValueKey('subagent-tail-time-${entry.id}'),
                          style: HermesType.caption.copyWith(
                            color: colors.textTertiary,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                if (preview.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: HermesSpace.x2),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant.withValues(alpha: .5),
                        borderRadius: BorderRadius.circular(HermesSpace.x2),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(HermesSpace.x2),
                        child: SelectableText(
                          preview,
                          key: ValueKey('subagent-tail-output-${entry.id}'),
                          style: TextStyle(
                            fontFamily: HermesType.monoFamily,
                            fontSize: 12,
                            height: 1.4,
                            color: ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (folds)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: ValueKey('subagent-tail-more-${entry.id}'),
                      onPressed: () => setState(() => _open = !_open),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, HermesSpace.tap),
                        padding: EdgeInsets.zero,
                        foregroundColor: colors.accentText,
                      ),
                      child: Text(
                        _open ? s.mp1215ShowLess : s.mp1215ShowMore,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The edge of a tool's mark in the log: the step rows' own size.
const double _tailIconSize = 16;

/// Keeps the end of the stream on screen while the reader follows: when the
/// content grows the position moves to the new end inside the same layout,
/// never one frame late. A finger on the list always wins.
class _FollowScrollController extends ScrollController {
  _FollowScrollController({required this.following});

  final bool Function() following;
  bool _followPending = false;

  /// New content arrived while following: pin the next layout to the end.
  void requestFollow() => _followPending = true;

  bool _takeFollow() {
    final value = _followPending;
    _followPending = false;
    return value;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _FollowScrollPosition(
    owner: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _FollowScrollPosition extends ScrollPositionWithSingleContext {
  _FollowScrollPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.oldPosition,
    super.debugLabel,
  });

  final _FollowScrollController owner;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final hadDimensions = hasContentDimensions && hasPixels;
    final oldMax = hadDimensions ? this.maxScrollExtent : null;
    final startPixels = hasPixels ? pixels : null;
    final settled = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (!hasViewportDimension || !hasPixels) return settled;
    final follow = owner._takeFollow();
    final atOldEnd =
        oldMax == null ||
        startPixels == null ||
        (startPixels - oldMax).abs() <= 0.01;
    final changed =
        oldMax == null || (oldMax - this.maxScrollExtent).abs() > 0.01;
    if ((follow || (changed && atOldEnd)) &&
        owner.following() &&
        activity is! DragScrollActivity &&
        (pixels - this.maxScrollExtent).abs() > 0.01) {
      correctPixels(this.maxScrollExtent);
      return false;
    }
    return settled;
  }
}

/// Incrementally scans new lines only. Finished prose paragraphs are immutable
/// widgets, so a token at the tail never reparses/rebuilds earlier Markdown.
/// Fences and structured lists stay together to preserve Markdown semantics.
class _MarkdownCache {
  _MarkdownCache(this.id);
  final String id;
  String _source = '';
  String _pending = '';
  int _scan = 0;
  int _line = 0;
  String? _fence;
  bool _structured = false;
  final List<Widget> _closed = [];
  Widget? _tail;
  String? _tailData;
  bool? _tailStreaming;

  List<Widget> update(
    String text, {
    required bool streaming,
    required bool appendOnly,
  }) {
    if (!identical(text, _source)) {
      if (text.length < _source.length ||
          (!appendOnly && !text.startsWith(_source))) {
        _source = '';
        _pending = '';
        _scan = _line = 0;
        _fence = null;
        _structured = false;
        _closed.clear();
        _tailData = null;
      }
      _pending += text.substring(_source.length);
      _source = text;
      while (true) {
        final end = _pending.indexOf('\n', _scan);
        if (end < 0) {
          _scan = _pending.length;
          break;
        }
        final line = _pending.substring(_line, end);
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
          final fence = trimmed.substring(0, 3);
          if (_fence == null) {
            _fence = fence;
          } else if (fence == _fence) {
            _fence = null;
          }
        } else if (_fence == null &&
            RegExp(r'^(?: {2,}|[-+*>] |[0-9]+[.)] |\||<)').hasMatch(line)) {
          _structured = true;
        }
        _scan = _line = end + 1;
        if (line.trim().isEmpty && _fence == null && !_structured) {
          final closed = _pending.substring(0, end + 1).trim();
          if (closed.isNotEmpty) {
            _closed.add(_body(closed, false, _closed.length));
          }
          _pending = _pending.substring(end + 1);
          _scan = _line = 0;
        }
      }
    }
    if (_tailData != _pending || _tailStreaming != streaming) {
      _tailData = _pending;
      _tailStreaming = streaming;
      _tail = _pending.trim().isEmpty
          ? null
          : _body(_pending, streaming, _closed.length);
    }
    return [..._closed, ?_tail];
  }

  Widget _body(String data, bool streaming, int index) => ChatMarkdownBody(
    key: ValueKey('subagent-markdown-$id-$index'),
    data: data,
    isStreaming: streaming,
    selectionIdentity: 'subagent-markdown-$id-$index',
  );
}
