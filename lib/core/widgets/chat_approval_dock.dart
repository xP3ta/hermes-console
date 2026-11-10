import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/floating.dart';
import '../design/modal.dart';
import '../feedback/haptics.dart';
import '../design/tokens.dart';
import '../services/approval_policy.dart';
import '../services/approval_response.dart';
import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import '../utils/approval_display.dart';
import 'activity_pill.dart' show ActivityTicker;
import 'chat/chat_markdown_body.dart' show kChatCodeFontFamily;

/// A decision fixed above the composer. The owner keys it by request identity,
/// so a late confirmation/error cannot submit or repaint another request.
class ChatApprovalDock extends StatefulWidget {
  const ChatApprovalDock({
    required this.approval,
    required this.onChoice,
    this.clock,
    this.allowAlways = true,
    this.navigation,
    super.key,
  });

  final Map<String, dynamic> approval;
  final Future<ApprovalSendResult> Function(ApprovalSubmission) onChoice;
  final bool allowAlways;
  final Widget? navigation;
  final DateTime Function()? clock;

  @override
  State<ChatApprovalDock> createState() => _ChatApprovalDockState();
}

class _ChatApprovalDockState extends State<ChatApprovalDock> {
  late final DateTime _arrived = widget.clock?.call() ?? DateTime.now();
  bool _busy = false;
  bool _sent = false;
  bool _failed = false;
  String? _retryChoice;
  int _submissionEpoch = 0;

  @override
  void didUpdateWidget(ChatApprovalDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.approval, widget.approval)) {
      // Even the same request ID can be re-offered from a new authority.
      _submissionEpoch++;
      _busy = _sent = _failed = false;
      _retryChoice = null;
    }
  }

  Future<void> _answer(
    String choice,
    ApprovalTarget target,
    String confirmation,
  ) async {
    if (_busy ||
        _sent ||
        !permittedApprovalChoices(widget.approval).contains(choice) ||
        choice == 'always' && !widget.allowAlways) {
      return;
    }
    final epoch = _submissionEpoch;
    bool current() => mounted && epoch == _submissionEpoch;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      if (choice == 'always') {
        final s = Strings.of(context);
        final confirmed = await showHermesDialog<bool>(
          context: context,
          surfaceKey: const ValueKey('approval-always-dialog'),
          title: s.adkAlwaysConfirm,
          message: confirmation,
          actions: [
            HermesDialogAction(
              key: const ValueKey('approval-always-cancel'),
              label: s.commonCancel,
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(
              key: const ValueKey('approval-always-confirm'),
              label: s.approvalAlwaysConfirm,
              value: true,
            ),
          ],
        );
        if (!current() || confirmed != true) return;
      }
      if (!current() || choice == 'always' && !widget.allowAlways) return;
      final result = await widget.onChoice(ApprovalSubmission(target, choice));
      if (!current()) return;
      // The answer to the decision: granted, denied, or it did not arrive.
      switch (result) {
        case ApprovalSendResult.accepted:
          choice == 'deny' ? HermesHaptics.warning() : HermesHaptics.success();
        case ApprovalSendResult.error:
          HermesHaptics.error();
        case ApprovalSendResult.ignored:
          break;
      }
      setState(() {
        _sent = result == ApprovalSendResult.accepted;
        _failed = result == ApprovalSendResult.error;
        if (_failed) _retryChoice = choice;
      });
    } on Object {
      if (current()) {
        HermesHaptics.error();
        setState(() {
          _failed = true;
          _retryChoice = choice;
        });
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _showFull(String text) => showHermesSurface<void>(
    context: context,
    surfaceKey: const ValueKey('approval-full-sheet'),
    maxHeightFactor: 0.9,
    builder: (context) {
      final s = Strings.of(context);
      return Padding(
        padding: const EdgeInsets.all(HermesSpace.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.adkTitle, style: HermesType.title),
            const SizedBox(height: HermesSpace.x3),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: kChatCodeFontFamily),
                ),
              ),
            ),
            const SizedBox(height: HermesSpace.x3),
            TextButton.icon(
              key: const ValueKey('approval-copy-command'),
              style: TextButton.styleFrom(
                minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
              ),
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              icon: const Icon(Icons.content_copy),
              label: Text(s.cevCopyTooltip),
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final command = approvalDisplayText(
      widget.approval['command'] ?? widget.approval['code'],
      s,
    );
    final description = approvalDisplayText(
      widget.approval['description'] ?? widget.approval['tool'],
      s,
    );
    final tool = approvalDisplayText(
      widget.approval['tool'] ?? widget.approval['description'],
      s,
    );
    final what = command.isEmpty ? description : command;
    final extraLines = RegExp(r'\r\n|[\r\n]').allMatches(what).length;
    // Freeze both identity and display evidence in the painted button closure.
    final target = ApprovalTarget.of(widget.approval);
    final scope = [
      approvalDisplayText(widget.approval['pattern_key'], s),
      description,
    ].where((value) => value.isNotEmpty).toSet().join(' · ');
    final confirmation = [if (scope.isNotEmpty) scope, what].join('\n\n');
    // Unlike legacy surfaces, this dock never invents scopes when no list was
    // supplied. Capability flags can further restrict an explicit choice list.
    final allowed =
        widget.approval['choices'] is List ||
            widget.approval['allowed_choices'] is List
        ? permittedApprovalChoices(widget.approval)
        : const <String>{};
    final offered = {...allowed};
    if (!widget.allowAlways) offered.remove('always');
    final compact = widget.navigation != null;
    final disabled = _busy || _sent;
    Widget button(
      String choice,
      String label, {
      bool primary = false,
      String? hint,
    }) {
      final style = TextButton.styleFrom(
        minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpace.x3,
          vertical: HermesSpace.x2,
        ),
        foregroundColor: choice == 'deny' ? colors.error : colors.textSecondary,
        textStyle: HermesType.support.copyWith(
          fontSize: compact && (choice == 'session' || choice == 'always')
              ? HermesType.captionSize
              : HermesType.supportSize,
          height: 1.2,
        ),
      );
      final retry = _failed && _retryChoice == choice;
      final shownLabel = retry ? s.commonRetry : label;
      final action = disabled
          ? null
          : () => unawaited(_answer(choice, target, confirmation));
      final child = primary
          ? FilledButton(
              key: ValueKey(retry ? 'approval-retry' : 'approval-$choice'),
              onPressed: action,
              style: FilledButton.styleFrom(
                minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x3,
                  vertical: HermesSpace.x2,
                ),
                textStyle: HermesType.text.copyWith(height: 1.2),
                backgroundColor: colors.success,
                foregroundColor: ThemeContrast.adjustForContrast(
                  colors.onAccent,
                  [colors.success],
                  minimum: 4.5,
                ),
              ),
              child: Text(shownLabel, textAlign: TextAlign.center),
            )
          : TextButton(
              key: ValueKey(retry ? 'approval-retry' : 'approval-$choice'),
              onPressed: action,
              style: style,
              child: Text(shownLabel, textAlign: TextAlign.center),
            );
      final named = retry ? Semantics(label: label, child: child) : child;
      return hint == null ? named : Tooltip(message: hint, child: named);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        HermesSpace.x3,
        HermesSpace.x1,
        HermesSpace.x3,
        compact ? HermesSpace.x1 : HermesSpace.x2,
      ),
      child: FocusTraversalGroup(
        child: Semantics(
          container: true,
          label: '${s.adkTitle} · $tool · $what',
          child: HermesFloatingSurface(
            key: const ValueKey('approval-dock-surface'),
            modal: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HermesRadius.card),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: HermesSpace.x3,
              vertical: compact ? HermesSpace.x2 : HermesSpace.x3,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ?widget.navigation,
                    Icon(
                      Icons.build_outlined,
                      color: colors.warning,
                      size: HermesSpace.x5,
                    ),
                    const SizedBox(width: HermesSpace.x2),
                    Expanded(
                      child: Text(
                        s.adkTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: HermesSpace.x2),
                    ExcludeSemantics(
                      child: ActivityTicker(
                        active: true,
                        clock: widget.clock,
                        builder: (context, now) {
                          final seconds = now
                              .difference(_arrived)
                              .inSeconds
                              .clamp(0, 359999);
                          return Text(
                            '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
                            key: const ValueKey('approval-wait-time'),
                            style: HermesType.support.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                // Status replaces the subtitle instead of growing the dock.
                // Retrying replaces the failed choice's label below, so sending
                // and errors cannot push input out of a large-type viewport.
                Semantics(
                  liveRegion: disabled || _failed,
                  child: Text(
                    disabled
                        ? s.adkSending
                        : _failed
                        ? s.adkSendError
                        : tool.isNotEmpty && tool != description
                        ? '$tool · $description'
                        : description.isEmpty
                        ? s.cevToolFallback
                        : description,
                    key: disabled
                        ? const ValueKey('approval-responding')
                        : null,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.support.copyWith(
                      color: _failed ? colors.error : colors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: HermesSpace.x2),
                Container(
                  padding: const EdgeInsets.all(HermesSpace.x2),
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius: BorderRadius.circular(HermesRadius.chip),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          what
                              .replaceAll(RegExp(r'\r\n|[\r\n]'), ' ↵ ')
                              .replaceAll(RegExp(r'[ \t]+'), ' '),
                          key: const ValueKey('approval-command-preview'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kChatCodeFontFamily,
                            fontSize: HermesType.supportSize,
                          ),
                        ),
                      ),
                      if (extraLines > 0)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: HermesSpace.x2,
                          ),
                          child: Text(
                            '+$extraLines ↵',
                            key: const ValueKey('approval-more-lines'),
                            style: HermesType.support,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: HermesSpace.x2),
                // Wrap both rows: at 320 dp / 2x no fixed height clips actions.
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: HermesSpace.x2,
                  runSpacing: HermesSpace.x1,
                  children: [
                    if (offered.contains('deny')) button('deny', s.cevDeny),
                    if (offered.contains('once'))
                      button(
                        'once',
                        s.adkOnce,
                        primary: true,
                        hint: s.apx1215ScopeOnceHint,
                      ),
                  ],
                ),
                Wrap(
                  spacing: HermesSpace.x1,
                  runSpacing: HermesSpace.x1,
                  children: [
                    if (offered.contains('session'))
                      button(
                        'session',
                        s.adkSession,
                        hint: s.apx1215ScopeSessionHint,
                      ),
                    if (offered.contains('always'))
                      button('always', s.adkAlways, hint: s.adkAlwaysHint),
                    TextButton(
                      key: const ValueKey('approval-view-full'),
                      style: TextButton.styleFrom(
                        textStyle: HermesType.support.copyWith(height: 1.2),
                        minimumSize: const Size(
                          HermesSpace.tap,
                          HermesSpace.tap,
                        ),
                      ),
                      onPressed: () => unawaited(_showFull(what)),
                      child: Text(s.adkViewFull),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
