// The pending action of an agent, as a sheet anchored over the instruction
// field (1.4.0): the question or permission the screen shows, its numbered
// options one per row (a tap sends only that number's key), or, when the
// screen shows no options, Enter and Esc as buttons. It shows the agent's own
// lines; it never words an approval for it.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/herdr_agents.dart';
import '../services/herdr_attention.dart';
import '../services/herdr_status.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'herdr_agents_widgets.dart';
import 'herdr_flat_widgets.dart';

class HerdrAskSheet extends StatelessWidget {
  const HerdrAskSheet({
    required this.ask,
    required this.send,
    required this.canWrite,
    required this.onOption,
    required this.onKey,
    required this.maxHeight,
    super.key,
  });

  final HerdrAsk ask;

  /// Where the answer stands for this very question; null when none was sent.
  final HerdrOptionSend? send;
  final bool canWrite;

  /// Sends the key of option [number].
  final ValueChanged<int> onOption;
  final Future<void> Function(HerdrKey key) onKey;

  /// The sheet scrolls beyond this height (nine options at large text).
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final question = ask.question;
    final command = ask.command;
    final mono = HermesType.support.copyWith(
      fontFamily: HermesType.monoFamily,
      color: colors.textPrimary,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Material(
        key: const ValueKey('hda-ask-sheet'),
        color: colors.surfaceVariant,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(HermesRadius.card),
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(HermesSpace.x3),
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      hdaStatusIcon(HerdrAgentStatus.blocked),
                      size: HermesIcon.md,
                      color: colors.warning,
                    ),
                    const SizedBox(width: HermesSpace.x2),
                    Expanded(
                      child: Text(
                        agfReasonLabel(strings, ask),
                        key: const ValueKey('hda-ask-reason'),
                        style: HermesType.support.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (question != null && question != command) ...[
                  const SizedBox(height: HermesSpace.x2),
                  Text(
                    question,
                    key: const ValueKey('hda-ask-question'),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.text.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (command != null) ...[
                  const SizedBox(height: HermesSpace.x2),
                  Text(
                    strings.agfAskCommand,
                    style: HermesType.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  SelectableText(
                    command,
                    key: const ValueKey('hda-ask-command'),
                    maxLines: 4,
                    style: mono,
                  ),
                ],
                const SizedBox(height: HermesSpace.x1),
                if (ask.hasOptions) ...[
                  for (final option in ask.options)
                    _OptionRow(
                      option: option,
                      send: send,
                      enabled:
                          canWrite &&
                          (send == null ||
                              send!.phase == HerdrOptionPhase.failed),
                      onTap: () => onOption(option.number),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: HermesSpace.x1),
                    child: Text(
                      strings.agfAskKeyHint,
                      style: HermesType.caption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ] else
                  Column(
                    key: const ValueKey('hda-blocked-card'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        strings.hdpBlockedBody,
                        style: HermesType.support.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      if (canWrite) ...[
                        const SizedBox(height: HermesSpace.x2),
                        Wrap(
                          spacing: HermesSpace.x2,
                          runSpacing: HermesSpace.x1,
                          children: [
                            HerdrGelButton(
                              key: const ValueKey('hda-accept'),
                              accent: true,
                              onTap: () => onKey(HerdrKey.enter),
                              child: Text(strings.hdpKeyEnterMarked),
                            ),
                            HerdrGelButton(
                              key: const ValueKey('hda-reject'),
                              onTap: () => onKey(HerdrKey.esc),
                              child: Text(strings.hdpKeyEscCancel),
                            ),
                          ],
                        ),
                      ],
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

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.send,
    required this.enabled,
    required this.onTap,
  });

  final HerdrOption option;
  final HerdrOptionSend? send;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final mine = send != null && send!.number == option.number ? send : null;
    final progress = switch (mine?.phase) {
      HerdrOptionPhase.sending => strings.agfSending,
      HerdrOptionPhase.sent => strings.agfSent,
      HerdrOptionPhase.failed => strings.agfSendFailed,
      null => null,
    };
    final failed = mine?.phase == HerdrOptionPhase.failed;
    return Semantics(
      button: true,
      enabled: enabled,
      container: true,
      excludeSemantics: true,
      label: [
        strings.agfOptionSemantics(option.number, option.label),
        ?progress,
      ].join('. '),
      onTap: enabled ? onTap : null,
      child: InkWell(
        key: ValueKey('hda-ask-option-${option.number}'),
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
            child: Row(
              children: [
                SizedBox(
                  width: HermesSpace.x6,
                  child: Text(
                    option.number.toString(),
                    textAlign: TextAlign.center,
                    style: HermesType.value.copyWith(
                      fontFamily: HermesType.monoFamily,
                      fontWeight: FontWeight.w700,
                      color: enabled ? colors.accentText : colors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: HermesSpace.x2),
                Expanded(
                  child: Text(
                    option.label,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.text.copyWith(color: colors.textPrimary),
                  ),
                ),
                if (progress != null) ...[
                  const SizedBox(width: HermesSpace.x2),
                  if (failed) ...[
                    Icon(
                      Icons.error_outline_rounded,
                      size: HermesIcon.sm,
                      color: colors.error,
                    ),
                    const SizedBox(width: HermesSpace.x1),
                  ],
                  Flexible(
                    child: Text(
                      progress,
                      key: ValueKey('hda-ask-progress-${option.number}'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: HermesType.caption.copyWith(
                        color: failed
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
