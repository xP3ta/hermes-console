import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/interactive_prompt.dart';
import '../services/interactive_prompt_reducer.dart';
import '../theme/app_theme.dart';
import '../theme/component_profile.dart';
import 'hermes_premium_ui.dart';

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
  final VoidCallback onCancel;

  const InteractivePromptCard({
    required this.entry,
    required this.busy,
    required this.onSubmit,
    this.onSubmitBatch,
    required this.onCancel,
    super.key,
  });

  @override
  State<InteractivePromptCard> createState() => _InteractivePromptCardState();
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
  bool _obscure = true;
  bool _batchSubmissionStarted = false;

  InteractivePromptRequest get _request => widget.entry.request!;

  bool get _isTerminalRead =>
      _request.kind == InteractivePromptKind.terminalRead;

  bool get _isBatchClarify =>
      _request is ClarifyPromptRequest &&
      (_request as ClarifyPromptRequest).isBatch;

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
    final value = explicitValue ?? _controller.text;
    if (!_isTerminalRead && value.trim().isEmpty) return;
    _controller.clear();
    widget.onSubmit(value);
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
    final request = _request;
    final title = switch (request.kind) {
      InteractivePromptKind.clarify => strings.interactiveClarifyTitle,
      InteractivePromptKind.sudo => strings.interactiveSudoTitle,
      InteractivePromptKind.secret => strings.interactiveSecretTitle,
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
        final compactBatchActions =
            _isBatchClarify &&
            MediaQuery.textScalerOf(context).scale(1) > 1 &&
            constraints.maxHeight.isFinite &&
            constraints.maxHeight < 600;
        return Material(
          color: colors.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            side: BorderSide(color: colors.divider),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  HermesInlineActivity(
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
                          ? _batchBody(context, constraints)
                          : _requestBody(context, request, colors),
                    ),
                    actions: _isBatchClarify
                        ? _batchActions(strings, compact: compactBatchActions)
                        : _legacyActions(strings),
                    semanticLabel: title,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _requestBody(
    BuildContext context,
    InteractivePromptRequest request,
    HermesThemeColors colors,
  ) {
    final strings = Strings.of(context);
    switch (request) {
      case ClarifyPromptRequest(:final question, :final choices):
        return [
          _questionText(question, colors),
          if (choices.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final choice in choices) ...[
              _choiceRow(
                context,
                label: choice,
                selected: false,
                multiSelect: false,
                trailingChevron: true,
                onTap: widget.busy ? null : () => _submit(choice),
              ),
              const SizedBox(height: 6),
            ],
          ] else
            const SizedBox(height: 10),
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
              fontFamily: 'monospace',
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

  Widget _questionText(String text, HermesThemeColors colors) => Text(
    text,
    style: TextStyle(
      color: colors.textPrimary,
      fontSize: 14.5,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
  );

  List<Widget> _batchBody(BuildContext context, BoxConstraints constraints) {
    final request = _request as ClarifyPromptRequest;
    final strings = Strings.of(context);
    // Header, progress and the action row need room around the question list;
    // under a keyboard or a small host the list scrolls instead of overflowing.
    const reservedChrome = 190.0;
    final screenCap = MediaQuery.sizeOf(context).height * 0.5;
    final hostCap = constraints.maxHeight.isFinite
        ? (constraints.maxHeight - reservedChrome).clamp(96.0, double.infinity)
        : double.infinity;
    final maxHeight = screenCap < hostCap ? screenCap : hostCap;
    return [
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < request.questions.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                _batchQuestion(context, request.questions[i], strings),
              ],
            ],
          ),
        ),
      ),
    ];
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
    return Semantics(
      selected: selected,
      checked: multiSelect ? selected : null,
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
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

  List<Widget> _batchActions(Strings strings, {required bool compact}) => [
    if (compact)
      Semantics(
        label: strings.interactiveCancel,
        button: true,
        enabled: !widget.busy,
        excludeSemantics: true,
        child: TextButton(
          key: const ValueKey('interactive-batch-cancel'),
          onPressed: widget.busy ? null : widget.onCancel,
          child: const Icon(Icons.stop_circle_outlined, size: 18),
        ),
      )
    else
      TextButton.icon(
        key: const ValueKey('interactive-batch-cancel'),
        onPressed: widget.busy ? null : widget.onCancel,
        icon: const Icon(Icons.stop_circle_outlined, size: 18),
        label: Text(strings.interactiveCancel),
      ),
    if (compact)
      Semantics(
        label: strings.interactiveBatchConfirm,
        button: true,
        enabled: !widget.busy && _batchComplete,
        excludeSemantics: true,
        child: FilledButton(
          key: const ValueKey('interactive-batch-confirm'),
          onPressed: widget.busy || !_batchComplete ? null : _submitBatch,
          child: const Icon(Icons.send_rounded, size: 17),
        ),
      )
    else
      FilledButton.icon(
        key: const ValueKey('interactive-batch-confirm'),
        onPressed: widget.busy || !_batchComplete ? null : _submitBatch,
        icon: const Icon(Icons.send_rounded, size: 17),
        label: Text(strings.interactiveBatchConfirm),
      ),
  ];

  Widget _input(String hint, {required bool sensitive}) => _answerField(
    controller: _controller,
    hint: hint,
    enabled: !widget.busy,
    textInputAction: TextInputAction.send,
    onSubmitted: (_) => _submit(),
    sensitive: sensitive,
    suffixIcon: sensitive
        ? IconButton(
            onPressed: widget.busy
                ? null
                : () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
          )
        : null,
  );
}
