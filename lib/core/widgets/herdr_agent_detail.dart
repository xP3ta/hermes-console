// The open agent (1.4.0), flat: its name with the state and folder under it, a
// menu, its screen as plain monospaced text over the whole pane, the pending
// action as a sheet over the instruction field, the quick keys and the field.
// The screen is a list of lines that grows from the bottom: it stays on the
// latest line unless the user scrolled up to read, and a changed screen
// repaints only the lines that changed.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart' show HermesAction, HermesMenuButton;
import '../feedback/feedback_policy.dart';
import '../services/herdr_agents.dart';
import '../services/herdr_attention.dart';
import '../services/herdr_status.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'herdr_agents_widgets.dart';
import 'herdr_ask_sheet.dart';
import 'herdr_flat_widgets.dart';
import 'herdr_list_widgets.dart';
import 'herdr_transcript_view.dart';

class HerdrAgentDetail extends StatefulWidget {
  const HerdrAgentDetail({
    required this.controller,
    required this.row,
    required this.server,
    required this.onSend,
    required this.onKey,
    this.onBack,
    this.onOpenTerminal,
    super.key,
  });

  final HerdrAgentsController controller;

  /// Null when the agent is gone from Herdr.
  final HerdrAgentRow? row;
  final String server;

  /// Back to the list (or, with the list beside it, closes the agent).
  final VoidCallback? onBack;

  /// «Open in terminal» for this agent; null leaves it out of the menu.
  final VoidCallback? onOpenTerminal;

  /// Sends the prompt; true when it went (the field is then cleared).
  final Future<bool> Function(String text) onSend;
  final Future<void> Function(HerdrKey key) onKey;

  @override
  State<HerdrAgentDetail> createState() => _HerdrAgentDetailState();
}

class _HerdrAgentDetailState extends State<HerdrAgentDetail> {
  final TextEditingController _field = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;

  /// The view is on the latest line (the bottom of the list).
  bool _atEnd = true;

  /// The user chose the terminal screen over the conversation.
  bool _terminalView = false;

  List<String>? _readableFrom;
  List<String> _readable = const [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final atEnd = !_scroll.hasClients || _scroll.position.pixels < 48;
      if (atEnd != _atEnd && mounted) setState(() => _atEnd = atEnd);
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final sent = await widget.onSend(_field.text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) _field.clear();
  }

  void _toEnd() {
    if (!_scroll.hasClients) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _scroll.jumpTo(0);
    } else {
      _scroll.animateTo(0, duration: HermesMotion.base, curve: Curves.easeOut);
    }
  }

  Future<void> _copyPath(String path) async {
    final feedback = AppFeedback.of(context);
    final copied = Strings.of(context).sshCopied;
    await Clipboard.setData(ClipboardData(text: path));
    feedback.notify(FeedbackKind.routine, copied);
  }

  Widget _header(BuildContext context, HerdrAgentRow? row) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final controller = widget.controller;
    final cwd = row?.pane.cwd;
    final canCopy = cwd != null && cwd.isNotEmpty;
    final ask = row == null ? null : controller.askFor(row);
    final hasConversation =
        controller.transcriptPhase == HerdrTranscriptPhase.ready;
    final state = row == null ? '' : agfStateLabel(strings, row.status, ask);
    final subtitle = row == null
        ? ''
        : [
            state,
            hdaFolderText(strings, row.pane),
            widget.server,
            if (controller.launchedHere(row.paneId)) strings.agfLaunchedHere,
          ].where((p) => p.isNotEmpty).join(' · ');
    return Row(
      children: [
        if (widget.onBack != null)
          IconButton(
            key: const ValueKey('hda-detail-back'),
            tooltip: strings.hdaBack,
            constraints: const BoxConstraints(
              minWidth: HermesSpace.tap,
              minHeight: HermesSpace.tap,
            ),
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        Expanded(
          child: row == null
              ? Text(
                  strings.hdaGone,
                  style: HermesType.body.copyWith(color: colors.textPrimary),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.title.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          hdaStatusIcon(row.status),
                          size: HermesIcon.sm,
                          color: hdaStatusColor(colors, row.status),
                        ),
                        const SizedBox(width: HermesSpace.x1),
                        Expanded(
                          child: Text(
                            subtitle,
                            key: const ValueKey('hda-detail-subtitle'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.support.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
        if (row != null &&
            (widget.onOpenTerminal != null || canCopy || hasConversation))
          HermesMenuButton<String>(
            key: const ValueKey('hda-detail-menu'),
            tooltip: strings.hdaMore,
            onSelected: (value) {
              if (value == 'terminal') widget.onOpenTerminal?.call();
              if (value == 'copy' && cwd != null) _copyPath(cwd);
              if (value == 'view') {
                setState(() => _terminalView = !_terminalView);
              }
            },
            actions: (_) => [
              if (hasConversation)
                HermesAction<String>(
                  key: const ValueKey('hda-detail-view'),
                  value: 'view',
                  label: _terminalView
                      ? strings.agfShowConversation
                      : strings.agfShowTerminal,
                ),
              if (widget.onOpenTerminal != null)
                HermesAction<String>(
                  key: const ValueKey('hda-detail-terminal'),
                  value: 'terminal',
                  label: strings.hdpOpenTerminal,
                ),
              if (canCopy)
                HermesAction<String>(
                  key: const ValueKey('hda-detail-copy'),
                  value: 'copy',
                  label: strings.agfCopyPath,
                ),
            ],
          ),
      ],
    );
  }

  Widget _status(BuildContext context, HerdrAgentRow row) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final controller = widget.controller;
    final since = controller.inState(row.paneId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
      child: Wrap(
        spacing: HermesSpace.x2,
        runSpacing: HermesSpace.x1,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (since != null)
            Text(
              strings.hdaInState(hdaDurationText(strings, since)),
              style: HermesType.caption.copyWith(color: colors.textSecondary),
            ),
          HerdrUpdatedAgo(
            at: () => controller.detailUpdatedAt,
            now: controller.clockNow,
          ),
        ],
      ),
    );
  }

  List<String> _readableLines(List<String> raw) {
    if (!identical(raw, _readableFrom)) {
      _readableFrom = raw;
      _readable = herdrReadableLines(raw);
    }
    return _readable;
  }

  /// The agent's conversation (from its session file) or, when that cannot be
  /// found with certainty, its screen as plain monospaced text, edge to edge:
  /// no frame, no inner box.
  Widget _output(BuildContext context, HerdrAgentRow row) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final controller = widget.controller;
    final phase = controller.transcriptPhase;
    final Widget content;
    if (phase == HerdrTranscriptPhase.ready && !_terminalView) {
      content = HerdrTranscriptView(
        turns: controller.transcriptTurns,
        hasEarlier: controller.transcriptHasEarlier,
        onLoadEarlier: controller.loadEarlierTranscript,
        controller: _scroll,
      );
    } else {
      final lines = _readableLines(controller.detailLines);
      if (!controller.detailLoaded) {
        content = Text(
          controller.detailFailed
              ? strings.hdaOutputFailed
              : strings.hdaProbing,
          style: HermesType.support.copyWith(color: colors.textSecondary),
        );
      } else if (lines.isEmpty) {
        content = Text(
          strings.hdaOutputEmpty,
          style: HermesType.support.copyWith(color: colors.textSecondary),
        );
      } else {
        final style = HermesType.support.copyWith(
          fontFamily: HermesType.monoFamily,
          color: colors.textPrimary,
          height: 1.35,
        );
        content = SelectionArea(
          child: ListView.builder(
            key: const ValueKey('hda-output'),
            controller: _scroll,
            reverse: true,
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final line = lines[lines.length - 1 - i];
              return Text(line.isEmpty ? ' ' : line, style: style);
            },
          ),
        );
      }
    }
    final notice = phase == HerdrTranscriptPhase.unavailable;
    return Semantics(
      container: true,
      label: strings.hdaOutputLabel(row.title),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notice)
            Padding(
              padding: const EdgeInsets.only(bottom: HermesSpace.x1),
              child: Text(
                strings.agfNoTranscript,
                key: const ValueKey('hda-no-transcript'),
                style: HermesType.caption.copyWith(color: colors.textSecondary),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: content),
                if (!_atEnd && controller.detailLoaded)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: HerdrGelButton(
                      key: const ValueKey('hda-jump-end'),
                      onTap: _toEnd,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.arrow_downward_rounded),
                          const SizedBox(width: HermesSpace.x1),
                          Text(strings.hdpJumpToEnd),
                        ],
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

  Widget _composer(BuildContext context, HerdrAgentRow row) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: HermesSpace.x6),
          child: HermesMenuButton<HerdrKey>(
            key: const ValueKey('hda-keys'),
            tooltip: strings.agfKeysMenu,
            icon: const Icon(Icons.keyboard_rounded),
            onSelected: widget.onKey,
            actions: (_) => [
              for (final key in HerdrKey.quick)
                HermesAction<HerdrKey>(
                  key: ValueKey('hda-key-${key.name}'),
                  value: key,
                  label: key == HerdrKey.enter ? strings.hdaKeyEnter : key.cap,
                ),
            ],
          ),
        ),
        Expanded(
          child: TextField(
            key: const ValueKey('hda-prompt-field'),
            controller: _field,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: HermesType.text.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: strings.hdaPromptHint,
              helperText: strings.hdaPromptTarget(
                row.title,
                hdaFolderText(strings, row.pane),
              ),
              helperMaxLines: 1,
            ),
          ),
        ),
        const SizedBox(width: HermesSpace.x2),
        Padding(
          padding: const EdgeInsets.only(bottom: HermesSpace.x6),
          child: HerdrGelButton(
            key: const ValueKey('hda-send'),
            accent: true,
            semanticLabel: strings.hdaSend,
            onTap: _sending ? null : _send,
            child: const Icon(Icons.arrow_upward_rounded),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final row = widget.row;
    final controller = widget.controller;
    if (row == null) {
      return Column(
        key: const ValueKey('hda-detail'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_header(context, null)],
      );
    }
    final blocked = row.status == HerdrAgentStatus.blocked;
    final canWrite = controller.canWrite;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final ask = blocked ? controller.askFor(row) : null;
    return LayoutBuilder(
      builder: (context, box) {
        // Short room (a tiny window, large text): the page scrolls and the
        // screen keeps a height of its own.
        final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
        final withSheet = ask != null && !keyboard;
        // With the sheet up (at most 45 % of the room) the screen still needs
        // a few lines: the header, status and field take about 240 dp per
        // unit of text scale.
        final cramped = withSheet
            ? box.maxHeight * 0.55 < 240 * scale + 100
            : box.maxHeight < 360 * scale;
        final sheet = withSheet
            ? HerdrAskSheet(
                ask: ask,
                send: controller.optionSendFor(row, ask),
                canWrite: canWrite,
                onOption: (n) => controller.sendOption(row, ask, n),
                onKey: widget.onKey,
                maxHeight: cramped
                    ? MediaQuery.sizeOf(context).height * 0.45
                    : box.maxHeight * 0.45,
              )
            : null;
        final bottom = <Widget>[
          if (!canWrite)
            Text(
              strings.hdaReadOnly,
              key: const ValueKey('hda-read-only'),
              style: HermesType.support.copyWith(color: colors.textSecondary),
            )
          else
            _composer(context, row),
        ];
        final top = <Widget>[
          _header(context, row),
          if (!keyboard) _status(context, row),
        ];
        if (cramped) {
          return SingleChildScrollView(
            key: const ValueKey('hda-detail-scroll'),
            child: Column(
              key: const ValueKey('hda-detail'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...top,
                SizedBox(height: 200, child: _output(context, row)),
                ?sheet,
                const SizedBox(height: HermesSpace.x2),
                ...bottom,
              ],
            ),
          );
        }
        return Column(
          key: const ValueKey('hda-detail'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...top,
            Expanded(child: _output(context, row)),
            if (controller.detailFailed && controller.detailLoaded)
              Padding(
                padding: const EdgeInsets.only(top: HermesSpace.x1),
                child: Text(
                  strings.hdaOutputFailed,
                  style: HermesType.caption.copyWith(color: colors.warning),
                ),
              ),
            ?sheet,
            const SizedBox(height: HermesSpace.x2),
            ...bottom,
          ],
        );
      },
    );
  }
}
