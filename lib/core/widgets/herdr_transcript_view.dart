// The conversation of a code agent as text to read (1.4.0): the agent's
// answers in plain Markdown, the user's messages in a quiet bubble, thinking
// and the tool calls folded under one line each («Thinking ›», «4 more
// steps ›») with their state. A question waiting for an answer shows as a
// question with its options. It grows from the bottom like a chat: it stays on
// the latest message unless the reader scrolled up.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/herdr_transcript.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'compact_markdown.dart';

String agfStepStateLabel(Strings strings, HerdrStepState state) =>
    switch (state) {
      HerdrStepState.running => strings.agfStepRunning,
      HerdrStepState.done => strings.agfStepDone,
      HerdrStepState.failed => strings.agfStepFailed,
    };

class HerdrTranscriptView extends StatefulWidget {
  const HerdrTranscriptView({
    required this.turns,
    required this.hasEarlier,
    required this.onLoadEarlier,
    required this.controller,
    super.key,
  });

  final List<HerdrTurn> turns;
  final bool hasEarlier;
  final VoidCallback onLoadEarlier;

  /// The list's controller (the detail follows it to show «jump to latest»).
  final ScrollController controller;

  @override
  State<HerdrTranscriptView> createState() => _HerdrTranscriptViewState();
}

class _HerdrTranscriptViewState extends State<HerdrTranscriptView> {
  final Set<String> _open = {};

  void _toggle(String key) =>
      setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key));

  /// Identity of each turn for its fold state and its list key: the turn's
  /// own key, which stays the same while the transcript grows at either end.
  /// (An index in the identity closed every open fold and remounted every
  /// row when «load earlier» prepended turns.) Should a key repeat, the
  /// repeats are told apart counting from the newest turn, so a prepend
  /// still leaves them alone.
  static List<String> _turnIds(List<HerdrTurn> turns) {
    final ids = List<String>.filled(turns.length, '');
    final seen = <String, int>{};
    for (var index = turns.length - 1; index >= 0; index--) {
      final key = turns[index].key;
      final repeat = seen[key] ?? 0;
      seen[key] = repeat + 1;
      ids[index] = repeat == 0 ? key : '$key#$repeat';
    }
    return ids;
  }

  @override
  Widget build(BuildContext context) {
    final turns = widget.turns;
    final extra = widget.hasEarlier ? 1 : 0;
    final ids = _turnIds(turns);
    // One map per build: the sliver asks for every keyed child it kept, and
    // a scan per question was quadratic in the transcript's length.
    final childIndexByKey = <String, int>{
      for (var index = 0; index < turns.length; index++)
        'tx-${ids[index]}': turns.length - 1 - index,
    };
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('hda-transcript'),
        controller: widget.controller,
        reverse: true,
        itemCount: turns.length + extra,
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          return childIndexByKey[key.value];
        },
        itemBuilder: (context, i) {
          if (i == turns.length) {
            return Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('hda-load-earlier'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
                ),
                onPressed: widget.onLoadEarlier,
                child: Text(Strings.of(context).agfLoadEarlier),
              ),
            );
          }
          final index = turns.length - 1 - i;
          final turn = turns[index];
          final id = ids[index];
          return KeyedSubtree(
            key: ValueKey('tx-$id'),
            child: _TurnTile(
              turn: turn,
              open: _open.contains(id),
              onToggle: () => _toggle(id),
            ),
          );
        },
      ),
    );
  }
}

class _TurnTile extends StatelessWidget {
  const _TurnTile({
    required this.turn,
    required this.open,
    required this.onToggle,
  });

  final HerdrTurn turn;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    switch (turn.kind) {
      case HerdrTurnKind.user:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(HermesRadius.row),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.x3,
                    vertical: HermesSpace.x2,
                  ),
                  child: Text(
                    turn.text,
                    key: const ValueKey('hda-tx-user'),
                    style: HermesType.text.copyWith(color: colors.textPrimary),
                  ),
                ),
              ),
            ),
          ),
        );
      case HerdrTurnKind.assistant:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
          child: CompactMarkdown(
            key: const ValueKey('hda-tx-assistant'),
            data: turn.text,
            tone: CompactMarkdownTone.body,
            fontSize: HermesType.textSize,
          ),
        );
      case HerdrTurnKind.thinking:
        return _Fold(
          label: strings.agfThinking,
          open: open,
          onToggle: onToggle,
          children: [
            Text(
              turn.text,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ],
        );
      case HerdrTurnKind.steps:
        final state = turn.overall;
        return _Fold(
          label: strings.agfStepsMore(turn.steps.length),
          state: agfStepStateLabel(strings, state),
          open: open,
          onToggle: onToggle,
          children: [for (final step in turn.steps) _StepLine(step: step)],
        );
      case HerdrTurnKind.question:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
          child: Column(
            key: const ValueKey('hda-tx-question'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${strings.agfReasonQuestion} · '
                '${agfStepStateLabel(strings, turn.answered ? HerdrStepState.done : HerdrStepState.running)}',
                style: HermesType.caption.copyWith(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                turn.text,
                style: HermesType.text.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (var i = 0; i < turn.options.length; i++)
                Text(
                  '${i + 1}  ${turn.options[i]}',
                  style: HermesType.support.copyWith(
                    fontFamily: HermesType.monoFamily,
                    color: colors.textPrimary,
                  ),
                ),
            ],
          ),
        );
    }
  }
}

/// One folded line: its label, its state in words and a chevron; the detail
/// opens under it.
class _Fold extends StatelessWidget {
  const _Fold({
    required this.label,
    required this.open,
    required this.onToggle,
    required this.children,
    this.state,
  });

  final String label;
  final String? state;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          container: true,
          excludeSemantics: true,
          label: [label, ?state].join(' · '),
          onTap: onToggle,
          child: InkWell(
            key: ValueKey('hda-fold-$label'),
            onTap: onToggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      [label, ?state].join(' · '),
                      style: HermesType.support.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    open
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    size: HermesIcon.md,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: HermesSpace.x3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.step});

  final HerdrStep step;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final failed = step.state == HerdrStepState.failed;
    return Padding(
      padding: const EdgeInsets.only(bottom: HermesSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              step.name,
              if (step.summary.isNotEmpty) step.summary,
              agfStepStateLabel(strings, step.state),
            ].join(' · '),
            style: HermesType.support.copyWith(
              fontFamily: HermesType.monoFamily,
              color: failed ? colors.error : colors.textPrimary,
            ),
          ),
          if (step.result != null)
            Text(
              step.result!,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: HermesType.caption.copyWith(
                fontFamily: HermesType.monoFamily,
                color: colors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}
