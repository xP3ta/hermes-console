import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart' show HermesChrome;
import '../models/interactive_prompt.dart';
import '../services/interactive_prompt_reducer.dart';
import '../theme/app_theme.dart';
import '../theme/component_profile.dart';
import '../utils/plain_preview.dart';
import 'agent_name_scope.dart';
import 'chat/chat_markdown_body.dart' show kChatCodeFontFamily;
import 'compact_markdown.dart';
import 'hermes_premium_ui.dart';
import 'workspace/chat_workspace_host.dart' show ChatWorkspaceTokens;

/// Inline tactile surface for Hermes Desktop 0.19 blocking requests.
///
/// Text controllers live only for this keyed card. Sensitive inputs are
/// cleared before invoking [onSubmit] and again during disposal; they never
/// enter restoration, preferences, transcript messages, or diagnostics.
///
/// Clarify can arrive either as a legacy single-question payload or as a
/// batch (`questions` array). Batches render every question inside one card
/// and submit all answers with a single confirmation.
class InteractivePromptCard extends StatefulWidget {
  final InteractivePromptEntry entry;
  final bool busy;
  final void Function(String value) onSubmit;
  final FutureOr<void> Function(Map<String, String> answers)? onSubmitBatch;
  /// «Detener tarea»: stops the whole turn.
  final VoidCallback onCancel;

  /// «Omitir» on a clarify card: skips the question, and only it; the turn
  /// goes on (Desktop `clarify/pending.tsx:246-253`, `skipClarify`).
  final VoidCallback? onSkip;

  const InteractivePromptCard({
    required this.entry,
    required this.busy,
    required this.onSubmit,
    this.onSubmitBatch,
    required this.onCancel,
    this.onSkip,
    super.key,
  });

  @override
  State<InteractivePromptCard> createState() => _InteractivePromptCardState();
}

/// Where [InteractivePromptCard] floats over a chat: [margin] from the sides
/// and from the bottom (the chat's bottom bars are already below), and never
/// into the band of the chat's floating header (the face, the island, «≡»
/// and «+»). The chat measures that band and passes it as [topInset]
/// (`FloatingChatHeader.insetFor`: the safe area plus the header). The card
/// gets the height in between, so its questions scroll instead of running
/// under the header.
class InteractivePromptPlacement extends StatelessWidget {
  const InteractivePromptPlacement({
    required this.topInset,
    required this.child,
    super.key,
  });

  final double topInset;
  final Widget child;

  static const double margin = 16;

  /// Air between the header band and the card.
  static const double headerGap = 8;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(margin, topInset + headerGap, margin, margin),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Flexible(child: child)],
    ),
  );
}

/// The surface of a request that waits on the user (clarify and approval):
/// v25 `.apv` paints it with the accent's tint, `--accbg` (13 % light,
/// 18 % dark), here laid over [HermesThemeColors.surface] so it stays
/// opaque wherever it sits.
Color blockingRequestSurface(HermesThemeColors colors) {
  final dark =
      ThemeData.estimateBrightnessForColor(colors.background) ==
      Brightness.dark;
  return Color.alphaBlend(
    colors.accent.withValues(alpha: dark ? 0.18 : 0.13),
    colors.surface,
  );
}

class _StagedAnswer {
  List<String> choices;
  String draft;

  _StagedAnswer({this.choices = const [], this.draft = ''});
}

// The backend tags the agent's preferred option in the label itself.
final RegExp _recommendedSuffix = RegExp(
  r'\s*\((recommended|recomendado)\)\s*$',
  caseSensitive: false,
);

class _InteractivePromptCardState extends State<InteractivePromptCard> {
  final TextEditingController _controller = TextEditingController();
  final Map<String, _StagedAnswer> _batchAnswers = {};
  final Map<String, TextEditingController> _batchControllers = {};
  final List<String> _singleSelected = [];
  bool _obscure = true;
  bool _batchSubmissionStarted = false;

  InteractivePromptRequest get _request => widget.entry.request!;

  bool get _isTerminalRead =>
      _request.kind == InteractivePromptKind.terminalRead;

  bool get _isBatchClarify =>
      _request is ClarifyPromptRequest &&
      (_request as ClarifyPromptRequest).isBatch;

  /// Only a question can be skipped; sudo, secrets and terminal reads keep
  /// «Detener tarea» alone.
  VoidCallback? get _onSkip =>
      _request.kind == InteractivePromptKind.clarify && !widget.busy
      ? widget.onSkip
      : null;

  bool get _skippable =>
      _request.kind == InteractivePromptKind.clarify && widget.onSkip != null;

  static const _skipKey = ValueKey('interactive-skip');

  @override
  void initState() {
    super.initState();
    _initBatchState();
  }

  void _initBatchState() {
    if (!_isBatchClarify) return;
    final request = _request as ClarifyPromptRequest;
    for (final question in request.questions) {
      final locked = request.lockedAnswers[question.qid];
      _batchAnswers[question.qid] = locked == null
          ? _StagedAnswer()
          : _stagedLockedAnswer(question, locked);
      _batchControllers[question.qid] = TextEditingController(
        text: _batchAnswers[question.qid]!.draft,
      );
    }
  }

  _StagedAnswer _stagedLockedAnswer(ClarifyQuestion question, String locked) {
    final options = question.choices;
    if (question.multiSelect) {
      try {
        final parsed = jsonDecode(locked) as List<dynamic>;
        final selected = parsed
            .whereType<String>()
            .where((choice) => options.contains(choice))
            .toList();
        return _StagedAnswer(
          choices: selected.isNotEmpty ? selected : [],
          draft: selected.isNotEmpty ? '' : locked,
        );
      } catch (_) {
        // A malformed authoritative answer is displayed as text, never dropped.
      }
    }
    return _StagedAnswer(
      choices: options.contains(locked) ? [locked] : [],
      draft: options.contains(locked) ? '' : locked,
    );
  }

  @override
  void didUpdateWidget(covariant InteractivePromptCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_batchSubmissionStarted &&
        oldWidget.busy &&
        !widget.busy &&
        widget.entry.status == InteractivePromptStatus.pending) {
      _batchSubmissionStarted = false;
    }
    final request = widget.entry.request;
    final oldRequest = oldWidget.entry.request;
    if (oldRequest?.key != request?.key) _singleSelected.clear();
    if (request is! ClarifyPromptRequest || !request.isBatch) return;
    if (oldRequest is! ClarifyPromptRequest ||
        !oldRequest.isBatch ||
        oldRequest.key != request.key) {
      for (final controller in _batchControllers.values) {
        controller.dispose();
      }
      _batchControllers.clear();
      _batchAnswers.clear();
      _initBatchState();
      return;
    }

    for (final question in request.questions) {
      _batchAnswers.putIfAbsent(question.qid, _StagedAnswer.new);
      final controller = _batchControllers.putIfAbsent(
        question.qid,
        () => TextEditingController(text: _batchAnswers[question.qid]!.draft),
      );
      final locked = request.lockedAnswers[question.qid];
      final oldLocked = oldRequest.lockedAnswers[question.qid];
      if (locked == null || locked == oldLocked) continue;
      final staged = _stagedLockedAnswer(question, locked);
      _batchAnswers[question.qid] = staged;
      controller.value = TextEditingValue(
        text: staged.draft,
        selection: TextSelection.collapsed(offset: staged.draft.length),
      );
    }
  }

  void _submit([String? explicitValue]) {
    if (widget.busy) return;
    if (explicitValue == null && _isSingleMultiSelect) {
      _submitSingleMultiSelect();
      return;
    }
    final value = explicitValue ?? _controller.text;
    if (!_isTerminalRead && value.trim().isEmpty) return;
    _controller.clear();
    widget.onSubmit(value);
  }

  /// A single `multi_select` clarify: Desktop answers with the JSON list of
  /// picked choices plus any typed extra (`clarify-tool.tsx`), which Hermes
  /// reads back through `_parse_multi_select_response`.
  bool get _isSingleMultiSelect {
    final request = _request;
    return request is ClarifyPromptRequest &&
        !request.isBatch &&
        request.multiSelect;
  }

  void _toggleSingleChoice(String choice) => setState(() {
    _singleSelected.contains(choice)
        ? _singleSelected.remove(choice)
        : _singleSelected.add(choice);
  });

  void _submitSingleMultiSelect() {
    final draft = _controller.text.trim();
    final answer = [..._singleSelected, if (draft.isNotEmpty) draft];
    if (answer.isEmpty) return;
    _controller.clear();
    widget.onSubmit(jsonEncode(answer));
  }

  Future<void> _submitBatch() async {
    if (widget.busy || _batchSubmissionStarted || !_isBatchClarify) return;
    final request = _request as ClarifyPromptRequest;
    final answers = <String, String>{};
    for (final question in request.questions) {
      final staged = _batchAnswers[question.qid];
      if (staged == null) return;
      final answer = _batchAnswer(question, staged);
      if (answer == null || answer.isEmpty) return;
      answers[question.qid] = answer;
    }
    setState(() => _batchSubmissionStarted = true);
    try {
      await widget.onSubmitBatch?.call(answers);
    } catch (_) {
      // Errors are reported and guarded by the host screen; this card only
      // ensures the async gap does not surface as an unawaited exception.
      if (mounted) setState(() => _batchSubmissionStarted = false);
    }
  }

  String? _batchAnswer(ClarifyQuestion question, _StagedAnswer staged) {
    if (staged.choices.isNotEmpty) {
      if (question.multiSelect) {
        return jsonEncode(staged.choices);
      }
      return staged.choices.first;
    }
    final draft = staged.draft;
    return draft.trim().isEmpty ? null : draft;
  }

  bool get _batchComplete {
    if (!_isBatchClarify) return false;
    final request = _request as ClarifyPromptRequest;
    for (final question in request.questions) {
      final staged = _batchAnswers[question.qid];
      if (staged == null) return false;
      if (_batchAnswer(question, staged) == null) return false;
    }
    return !_batchSubmissionStarted;
  }

  int get _batchAnsweredCount {
    if (!_isBatchClarify) return 0;
    final request = _request as ClarifyPromptRequest;
    var count = 0;
    for (final question in request.questions) {
      final staged = _batchAnswers[question.qid];
      if (staged != null && _batchAnswer(question, staged) != null) {
        count++;
      }
    }
    return count;
  }

  void _toggleChoice(ClarifyQuestion question, String choice) {
    setState(() {
      final current = _batchAnswers[question.qid]!;
      late List<String> next;
      if (question.multiSelect) {
        next = current.choices.contains(choice)
            ? current.choices.where((c) => c != choice).toList()
            : [...current.choices, choice];
      } else {
        next = [choice];
      }
      _batchAnswers[question.qid] = _StagedAnswer(choices: next, draft: '');
      _batchControllers[question.qid]?.text = '';
    });
  }

  void _setDraft(ClarifyQuestion question, String value) {
    setState(() {
      _batchAnswers[question.qid] = _StagedAnswer(choices: [], draft: value);
    });
  }

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    for (final controller in _batchControllers.values) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final agentName = AgentNameScope.of(context);
    final request = _request;
    final title = switch (request.kind) {
      InteractivePromptKind.clarify => strings.mpnClarifyTitle(agentName),
      InteractivePromptKind.sudo => strings.mpnSudoTitle(agentName),
      InteractivePromptKind.secret => strings.mpnSecretTitle(agentName),
      InteractivePromptKind.terminalRead => strings.interactiveTerminalTitle,
    };
    final icon = switch (request.kind) {
      InteractivePromptKind.clarify => Icons.help_outline_rounded,
      InteractivePromptKind.sudo => Icons.admin_panel_settings_outlined,
      InteractivePromptKind.secret => Icons.key_outlined,
      InteractivePromptKind.terminalRead => Icons.terminal_rounded,
    };
    final summary = _isBatchClarify
        ? strings.interactiveBatchProgress(
            _batchAnsweredCount,
            (request as ClarifyPromptRequest).questions.length,
          )
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        // Over the chat the card gets the room actually free (below the
        // floating header, above the composer). Unbounded (in a column), as
        // before.
        final bounded = constraints.maxHeight.isFinite;
        final compactBatchActions =
            _isBatchClarify &&
            bounded &&
            constraints.maxHeight < 600 &&
            (scale > 1 || constraints.maxHeight < _labelledActionsMinRoom);
        // The actions stay pinned at the card's foot while they leave the
        // questions some room; with less (the keyboard up on a small
        // phone) they scroll at the end of the card instead of overflowing.
        final actionsHeight = compactBatchActions
            ? _compactActionsHeight
            : _labelledActionsHeight;
        final pinActions =
            bounded &&
            constraints.maxHeight - _cardPaddingHeight >=
                actionsHeight + _minQuestionsHeight;
        // The header stays fixed above the questions only at the normal
        // text size, when it is short. Larger, it is several lines and,
        // fixed, it left the questions less than one option (gate gint24):
        // then it scrolls with them and they get the card's whole height.
        final flexible =
            pinActions &&
            scale <= 1 &&
            constraints.maxHeight >=
                _minFlexibleHeight(context, compact: compactBatchActions);
        final actions = _isBatchClarify
            ? _batchActions(strings, compact: compactBatchActions)
            : _legacyActions(strings);
        final activity = HermesInlineActivity(
          title: title,
          summary: summary,
          leading: Icon(icon, size: 20, color: colors.warning),
          status: widget.busy
              ? Semantics(
                  label: strings.chaStatusWaiting,
                  liveRegion: true,
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.warning,
                    ),
                  ),
                )
              : null,
          detail: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _isBatchClarify
                ? _batchBody(context, flexible: flexible, bounded: bounded)
                : _requestBody(
                    context,
                    request,
                    colors,
                    constraints,
                    flexible: flexible,
                    bounded: bounded,
                  ),
          ),
          flexibleDetail: flexible,
          flexibleDetailFit: FlexFit.loose,
          // Bounded, the actions are pinned at the card's foot (below).
          actions: bounded ? const [] : actions,
          semanticLabel: title,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        );
        // No grabber: the card is not dragged (AUDITORIA-PULIDO §2.16 P3).
        final Widget content;
        if (!bounded) {
          content = activity;
        } else {
          // «Detener tarea» and «Confirmar» pinned at the foot ([pinActions])
          // stay inside the card whatever the questions do. Above them
          // either the header stays and the questions scroll ([flexible]),
          // or header and questions scroll together.
          final footer = Padding(
            key: const ValueKey('interactive-prompt-actions'),
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final action in actions)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: componentMinimumTapTarget,
                      minWidth: componentMinimumTapTarget,
                    ),
                    child: action,
                  ),
              ],
            ),
          );
          final upper = flexible
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [Flexible(child: activity)],
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      activity,
                      if (!pinActions)
                        SizedBox(width: double.infinity, child: footer),
                    ],
                  ),
                );
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Flexible(child: upper), if (pinActions) footer],
          );
        }
        final chrome = HermesChrome.of(colors);
        // TODO(token): HermesRadius.card once Ola 2 lands.
        const radius = ChatWorkspaceTokens.cardRadius;
        return DecoratedBox(
          // Floating card on all four corners, off the screen edges — not a
          // bottom-sheet flush to the bottom (that read as a modal takeover
          // for something that's just a paused, resumable question).
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: chrome.shadow,
          ),
          child: Material(
            // v25 `.apv`: the request sits on the accent's own tint (Ola 5),
            // opaque here because the card floats over the chat's text.
            color: blockingRequestSurface(colors),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: BorderSide(color: chrome.line),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
              child: content,
            ),
          ),
        );
      },
    );
  }

  /// Below this room the batch actions show as icons even at the normal
  /// text size: labelled, they can take two rows.
  static const double _labelledActionsMinRoom = 300;

  /// The pinned actions' row with its padding: icons fit in one 48 dp row;
  /// labelled, allow for two.
  static const double _compactActionsHeight = 58;
  static const double _labelledActionsHeight = 114;

  /// The card's own padding above and below its content.
  static const double _cardPaddingHeight = 14;

  /// Two rows of questions: the least the pinned actions must leave them.
  static const double _minQuestionsHeight = 96;

  /// Least height in which the header, the actions and one row of the
  /// questions fit, at this text size; below it the header scrolls with the
  /// questions (the actions stay pinned either way).
  double _minFlexibleHeight(BuildContext context, {required bool compact}) {
    final scale = MediaQuery.textScalerOf(context);
    // Paddings and the actions' 48 dp row, plus the header text.
    var height = 120 + scale.scale(64);
    // Compact batch actions stack in two rows.
    if (compact) height += 56;
    // A single question keeps its answer field under the list.
    if (!_isBatchClarify) height += 36 + scale.scale(24);
    // One row of questions or choices.
    return height + 48;
  }

  List<Widget> _requestBody(
    BuildContext context,
    InteractivePromptRequest request,
    HermesThemeColors colors,
    BoxConstraints constraints, {
    required bool flexible,
    required bool bounded,
  }) {
    final strings = Strings.of(context);
    switch (request) {
      case ClarifyPromptRequest(
        :final question,
        :final choices,
        :final multiSelect,
      ):
        // rt1215: a long question or many choices scroll inside a bounded
        // box (as the batch body does); the answer field stays reachable.
        final scroll = ConstrainedBox(
          key: const ValueKey('interactive-prompt-scroll'),
          constraints: BoxConstraints(
            // Over the chat: what the card has left, at most half the
            // screen, or no cap when it scrolls with the whole card;
            // unbounded, the old estimate.
            maxHeight: flexible
                ? MediaQuery.sizeOf(context).height * 0.5
                : bounded
                ? double.infinity
                : _scrollCap(context, constraints),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _questionText(question, colors),
                if (choices.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  for (final choice in choices) ...[
                    _choiceRow(
                      context,
                      label: choice,
                      selected: multiSelect && _singleSelected.contains(choice),
                      multiSelect: multiSelect,
                      trailingChevron: !multiSelect,
                      onTap: widget.busy
                          ? null
                          : multiSelect
                          ? () => _toggleSingleChoice(choice)
                          : () => _submit(choice),
                    ),
                    const SizedBox(height: 6),
                  ],
                ],
              ],
            ),
          ),
        );
        return [
          if (flexible) Flexible(child: scroll) else scroll,
          if (choices.isEmpty) const SizedBox(height: 10),
          _input(strings.interactiveAnswerHint, sensitive: false),
        ];
      case SudoPromptRequest():
        return [_input(strings.interactivePasswordHint, sensitive: true)];
      case SecretPromptRequest(:final envVar, :final prompt):
        return [
          _questionText(prompt, colors),
          const SizedBox(height: 4),
          Text(
            envVar,
            style: TextStyle(
              color: colors.textSecondary,
              fontFamily: kChatCodeFontFamily,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 10),
          _input(strings.interactiveSecretHint, sensitive: true),
        ];
      case TerminalReadPromptRequest():
        return [
          Text(
            strings.interactiveTerminalBody,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ];
    }
  }

  // rt1215: an agent question written in Markdown renders as Markdown.
  Widget _questionText(String text, HermesThemeColors colors) =>
      looksLikeMarkdown(text)
      ? CompactMarkdown(
          data: text,
          tone: CompactMarkdownTone.body,
          fontSize: 14.5,
        )
      : Text(
          text,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14.5,
            height: 1.3,
            fontWeight: FontWeight.w600,
          ),
        );

  /// Height left for a scrolling question body once the header, the answer
  /// field and the actions have their room (at most half the screen).
  double _scrollCap(BuildContext context, BoxConstraints constraints) {
    final reserved = MediaQuery.textScalerOf(context).scale(240.0);
    final screen = MediaQuery.sizeOf(context).height;
    final host = constraints.maxHeight.isFinite ? constraints.maxHeight : screen;
    final room = (host < screen ? host : screen) - reserved;
    final half = screen * 0.5;
    return (room < half ? room : half).clamp(96.0, double.infinity);
  }

  List<Widget> _batchBody(
    BuildContext context, {
    required bool flexible,
    required bool bounded,
  }) {
    final request = _request as ClarifyPromptRequest;
    final strings = Strings.of(context);
    final questions = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < request.questions.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          _batchQuestion(context, request.questions[i], strings),
        ],
      ],
    );
    // Over the chat, scrolling with the whole card: no scroll of its own.
    if (bounded && !flexible) return [questions];
    // Below the fixed header (flexible) the list takes what is left, at
    // most half the screen; unbounded (in a column), half the screen.
    final list = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.5,
      ),
      child: SingleChildScrollView(child: questions),
    );
    return [if (flexible) Flexible(child: list) else list];
  }

  Widget _batchQuestion(
    BuildContext context,
    ClarifyQuestion question,
    Strings strings,
  ) {
    final colors = Theme.of(context).hermes;
    final locked =
        (_request as ClarifyPromptRequest).lockedAnswers[question.qid] != null;
    final staged = _batchAnswers[question.qid]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _questionText(question.question, colors)),
            if (locked)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (final choice in question.choices) ...[
          _choiceRow(
            context,
            label: choice,
            selected: staged.choices.contains(choice),
            multiSelect: question.multiSelect,
            onTap: widget.busy || locked
                ? null
                : () => _toggleChoice(question, choice),
          ),
          const SizedBox(height: 6),
        ],
        _answerField(
          controller: _batchControllers[question.qid],
          hint: strings.interactiveBatchOtherHint,
          enabled: !widget.busy && !locked,
          textInputAction: TextInputAction.next,
          onChanged: (value) => _setDraft(question, value),
          highlighted: staged.draft.trim().isNotEmpty,
        ),
      ],
    );
  }

  Widget _choiceRow(
    BuildContext context, {
    required String label,
    required bool selected,
    required bool multiSelect,
    required VoidCallback? onTap,
    bool trailingChevron = false,
  }) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final bare = label.replaceFirst(_recommendedSuffix, '');
    final recommended = bare != label;
    final enabled = onTap != null;
    final indicator = multiSelect
        ? (selected
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded)
        : (selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_off_rounded);
    final foreground = enabled ? colors.textPrimary : colors.textDisabled;
    // A single answer reads as a radio button («1 of 3, checked»), several
    // as check boxes (review R5A B3-5).
    final row = Semantics(
      selected: selected,
      checked: selected,
      inMutuallyExclusiveGroup: !multiSelect,
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(componentMinimumTapTarget),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            alignment: Alignment.centerLeft,
            backgroundColor: selected
                ? colors.accent.withAlpha(34)
                : colors.surfaceVariant,
            foregroundColor: foreground,
            side: BorderSide(color: selected ? colors.accent : colors.divider),
            // Pill; 24 keeps a multi-line option a soft rectangle instead of
            // a stadium as tall as its text.
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          child: Row(
            children: [
              Icon(
                indicator,
                size: 20,
                color: selected ? colors.accent : colors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  bare,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 14,
                    height: 1.3,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (recommended)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.accent.withAlpha(30),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    strings.interactiveRecommended,
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              if (trailingChevron)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
    // One node: the button with its checked state.
    return MergeSemantics(child: row);
  }

  Widget _answerField({
    required TextEditingController? controller,
    required String hint,
    required bool enabled,
    required TextInputAction textInputAction,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
    bool sensitive = false,
    bool highlighted = false,
    Widget? suffixIcon,
  }) {
    final colors = Theme.of(context).hermes;
    final borderColor = highlighted ? colors.accent : colors.divider;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: componentMinimumTapTarget),
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: sensitive && _obscure,
        autocorrect: false,
        enableSuggestions: !sensitive,
        textInputAction: textInputAction,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: TextStyle(color: colors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: colors.textSecondary, fontSize: 14),
          isDense: true,
          filled: true,
          fillColor: highlighted
              ? colors.accent.withAlpha(34)
              : colors.surfaceVariant,
          prefixIcon: Icon(
            sensitive ? Icons.lock_outline_rounded : Icons.edit_outlined,
            size: 18,
            color: colors.textSecondary,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 20,
          ),
          suffixIcon: suffixIcon,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: borderColor),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.accent, width: 1.4),
          ),
        ),
      ),
    );
  }

  List<Widget> _legacyActions(Strings strings) => [
    TextButton.icon(
      onPressed: widget.busy ? null : widget.onCancel,
      icon: const Icon(Icons.stop_circle_outlined, size: 18),
      label: Text(strings.interactiveCancel),
    ),
    if (_skippable)
      TextButton(
        key: _skipKey,
        onPressed: _onSkip,
        child: Text(strings.interactiveSkip),
      ),
    FilledButton.icon(
      onPressed: widget.busy ? null : _submit,
      icon: Icon(
        _isTerminalRead ? Icons.refresh_rounded : Icons.send_rounded,
        size: 17,
      ),
      label: Text(
        _isTerminalRead ? strings.interactiveRetry : strings.interactiveSend,
      ),
    ),
  ];

  List<Widget> _batchActions(Strings strings, {required bool compact}) {
    final onCancel = widget.busy ? null : widget.onCancel;
    final onConfirm = widget.busy || !_batchComplete ? null : _submitBatch;
    if (compact) {
      return [_compactBatchActions(strings, onCancel, onConfirm)];
    }
    return [
      TextButton.icon(
        key: const ValueKey('interactive-batch-cancel'),
        onPressed: onCancel,
        icon: const Icon(Icons.stop_circle_outlined, size: 18),
        label: Text(strings.interactiveCancel),
      ),
      if (_skippable)
        TextButton(
          key: _skipKey,
          onPressed: _onSkip,
          child: Text(strings.interactiveSkip),
        ),
      FilledButton.icon(
        key: const ValueKey('interactive-batch-confirm'),
        onPressed: onConfirm,
        icon: const Icon(Icons.send_rounded, size: 17),
        label: Text(strings.interactiveBatchConfirm),
      ),
    ];
  }

  /// Compact (a large text size in little room): «Detener tarea» and
  /// «Confirmar» keep one 48 dp row, so the questions keep their room. Both
  /// show their words while they fit in that row; else each shows its icon,
  /// with the word as tooltip and as TalkBack label, and a tap action.
  Widget _compactBatchActions(
    Strings strings,
    VoidCallback? onCancel,
    VoidCallback? onConfirm,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final cancel = strings.interactiveCancel;
      final skip = strings.interactiveSkip;
      final confirm = strings.interactiveBatchConfirm;
      final style = Theme.of(context).textTheme.labelLarge;
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      double textWidth(String text) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textScaler: scaler,
          textDirection: direction,
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      // A `*.icon` button around its label: icon, gap and padding (ample).
      // Should it still not fit, the Wrap takes a second row, no overflow.
      const chrome = 80.0;
      final skipWidth = _skippable ? textWidth(skip) + chrome + 8 : 0.0;
      final words =
          textWidth(cancel) +
              textWidth(confirm) +
              2 * chrome +
              8 +
              skipWidth <=
          constraints.maxWidth;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (words)
            _tapTarget(
              TextButton.icon(
                key: const ValueKey('interactive-batch-cancel'),
                onPressed: onCancel,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: Text(cancel, maxLines: 1),
              ),
            )
          else
            _iconAction(
              label: cancel,
              onTap: onCancel,
              child: TextButton(
                key: const ValueKey('interactive-batch-cancel'),
                onPressed: onCancel,
                child: const Icon(Icons.stop_circle_outlined, size: 18),
              ),
            ),
          if (_skippable && words)
            _tapTarget(
              TextButton(
                key: _skipKey,
                onPressed: _onSkip,
                child: Text(skip, maxLines: 1),
              ),
            )
          else if (_skippable)
            _iconAction(
              label: skip,
              onTap: _onSkip,
              child: TextButton(
                key: _skipKey,
                onPressed: _onSkip,
                child: const Icon(Icons.skip_next_rounded, size: 18),
              ),
            ),
          if (words)
            _tapTarget(
              FilledButton.icon(
                key: const ValueKey('interactive-batch-confirm'),
                onPressed: onConfirm,
                icon: const Icon(Icons.send_rounded, size: 17),
                label: Text(confirm, maxLines: 1),
              ),
            )
          else
            _iconAction(
              label: confirm,
              onTap: onConfirm,
              child: FilledButton(
                key: const ValueKey('interactive-batch-confirm'),
                onPressed: onConfirm,
                child: const Icon(Icons.send_rounded, size: 17),
              ),
            ),
        ],
      );
    },
  );

  static Widget _tapTarget(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: componentMinimumTapTarget,
      minWidth: componentMinimumTapTarget,
    ),
    child: child,
  );

  /// An action shown as its icon: [label] as tooltip and as the TalkBack
  /// label, and the same [onTap] for TalkBack's double tap (review R5A
  /// B3-1: without it the excluded button could not be pressed).
  Widget _iconAction({
    required String label,
    required VoidCallback? onTap,
    required Widget child,
  }) => Semantics(
    label: label,
    button: true,
    enabled: onTap != null,
    onTap: onTap,
    excludeSemantics: true,
    child: Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: _tapTarget(child),
    ),
  );

  Widget _input(String hint, {required bool sensitive}) => _answerField(
    controller: _controller,
    hint: hint,
    enabled: !widget.busy,
    textInputAction: TextInputAction.send,
    onSubmitted: (_) => _submit(),
    sensitive: sensitive,
    suffixIcon: sensitive
        ? Semantics(
            label: _obscure
                ? Strings.of(context).a11yShowAnswer
                : Strings.of(context).a11yHideAnswer,
            button: true,
            enabled: !widget.busy,
            onTap: widget.busy
                ? null
                : () => setState(() => _obscure = !_obscure),
            excludeSemantics: true,
            child: IconButton(
              onPressed: widget.busy
                  ? null
                  : () => setState(() => _obscure = !_obscure),
              tooltip: _obscure
                  ? Strings.of(context).a11yShowAnswer
                  : Strings.of(context).a11yHideAnswer,
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          )
        : null,
  );
}
