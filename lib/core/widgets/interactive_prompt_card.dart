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

class _InteractivePromptCardState extends State<InteractivePromptCard> {
  final TextEditingController _controller = TextEditingController();
  final Map<String, _StagedAnswer> _batchAnswers = {};
  final Map<String, TextEditingController> _batchControllers = {};
  bool _obscure = true;

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
    if (widget.busy || !_isBatchClarify) return;
    final request = _request as ClarifyPromptRequest;
    final answers = <String, String>{};
    for (final question in request.questions) {
      final staged = _batchAnswers[question.qid];
      if (staged == null) return;
      final answer = _batchAnswer(question, staged);
      if (answer == null || answer.isEmpty) return;
      answers[question.qid] = answer;
    }
    try {
      await widget.onSubmitBatch?.call(answers);
    } catch (_) {
      // Errors are reported and guarded by the host screen; this card only
      // ensures the async gap does not surface as an unawaited exception.
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
    return true;
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

    return HermesInlineActivity(
      title: title,
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
            ? _batchBody(context)
            : _requestBody(context, request, colors),
      ),
      actions: _isBatchClarify
          ? _batchActions(strings)
          : _legacyActions(strings),
      semanticLabel: title,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
          Text(
            question,
            style: TextStyle(color: colors.textPrimary, fontSize: 13),
          ),
          if (choices.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final choice in choices)
                  OutlinedButton(
                    onPressed: widget.busy ? null : () => _submit(choice),
                    child: Text(choice),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          _input(strings.interactiveAnswerHint, sensitive: false),
        ];
      case SudoPromptRequest():
        return [_input(strings.interactivePasswordHint, sensitive: true)];
      case SecretPromptRequest(:final envVar, :final prompt):
        return [
          Text(
            prompt,
            style: TextStyle(color: colors.textPrimary, fontSize: 13),
          ),
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

  List<Widget> _batchBody(BuildContext context) {
    final request = _request as ClarifyPromptRequest;
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final total = request.questions.length;
    final answered = _batchAnsweredCount;
    return [
      Text(
        strings.interactiveBatchProgress(answered, total),
        style: TextStyle(color: colors.textSecondary, fontSize: 12),
      ),
      const SizedBox(height: 10),
      LayoutBuilder(
        builder: (context, constraints) {
          final maxHeight =
              constraints.maxHeight.isFinite && constraints.maxHeight > 0
              ? constraints.maxHeight
              : 320.0;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final question in request.questions) ...[
                    _batchQuestion(context, question, strings),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          );
        },
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
    final hasChoices = question.choices.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                question.question,
                style: TextStyle(color: colors.textPrimary, fontSize: 13),
              ),
            ),
            if (locked)
              Icon(Icons.lock_outline, size: 14, color: colors.textSecondary),
          ],
        ),
        if (hasChoices) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final choice in question.choices)
                Semantics(
                  selected: staged.choices.contains(choice),
                  checked: staged.choices.contains(choice),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: componentMinimumTapTarget,
                    ),
                    child: OutlinedButton(
                      onPressed: widget.busy || locked
                          ? null
                          : () => _toggleChoice(question, choice),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: staged.choices.contains(choice)
                            ? colors.accent.withAlpha(30)
                            : null,
                      ),
                      child: Text(choice),
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: componentMinimumTapTarget,
          ),
          child: TextField(
            controller: _batchControllers[question.qid],
            enabled: !widget.busy && !locked,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onChanged: (value) => _setDraft(question, value),
            decoration: InputDecoration(
              hintText: strings.interactiveBatchOtherHint,
              isDense: true,
            ),
          ),
        ),
      ],
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

  List<Widget> _batchActions(Strings strings) => [
    TextButton.icon(
      onPressed: widget.busy ? null : widget.onCancel,
      icon: const Icon(Icons.stop_circle_outlined, size: 18),
      label: Text(strings.interactiveCancel),
    ),
    FilledButton.icon(
      onPressed: widget.busy || !_batchComplete ? null : _submitBatch,
      icon: const Icon(Icons.send_rounded, size: 17),
      label: Text(strings.interactiveBatchConfirm),
    ),
  ];

  Widget _input(String hint, {required bool sensitive}) => TextField(
    controller: _controller,
    enabled: !widget.busy,
    obscureText: sensitive && _obscure,
    autocorrect: false,
    enableSuggestions: !sensitive,
    textInputAction: TextInputAction.send,
    onSubmitted: (_) => _submit(),
    decoration: InputDecoration(
      hintText: hint,
      isDense: true,
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
    ),
  );
}
