// Piezas de la sección «Agentes» (1.4.0): lista viva de los agentes de
// Herdr, su detalle (salida, instrucción, teclas), el aviso discreto de
// «Herdr no instalado» y los diálogos de instalar y crear. Solo presentación:
// el estado vive en HerdrAgentsController (services/herdr_agents.dart) y
// el SSH en la pantalla. Cristal/gel con los tokens del tema; el estado
// siempre va con color + icono + texto.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../design/gel_surface.dart';
import '../design/modal.dart';
import '../feedback/feedback_policy.dart';
import '../services/herdr_agents.dart';
import '../services/herdr_status.dart';
import '../services/ssh_session_kind.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../utils/short_server_path.dart';

String hdaStatusLabel(Strings strings, HerdrAgentStatus status) =>
    switch (status) {
      HerdrAgentStatus.working => strings.hdaStatusWorking,
      HerdrAgentStatus.blocked => strings.hdaStatusBlocked,
      HerdrAgentStatus.idle => strings.hdaStatusIdle,
      HerdrAgentStatus.done => strings.hdaStatusDone,
      HerdrAgentStatus.unknown => strings.hdaStatusUnknown,
    };

/// The icon that carries the state beside its colour and its word.
IconData hdaStatusIcon(HerdrAgentStatus status) => switch (status) {
  HerdrAgentStatus.working => Icons.autorenew_rounded,
  HerdrAgentStatus.blocked => Icons.front_hand_outlined,
  HerdrAgentStatus.idle => Icons.radio_button_unchecked,
  HerdrAgentStatus.done => Icons.check_circle_outline,
  HerdrAgentStatus.unknown => Icons.help_outline_rounded,
};

/// Colour of a state's icon and tint. The words always take the primary
/// ink, so contrast never depends on this colour.
Color hdaStatusColor(HermesThemeColors colors, HerdrAgentStatus status) =>
    switch (status) {
      HerdrAgentStatus.working => colors.accent,
      HerdrAgentStatus.blocked => colors.warning,
      HerdrAgentStatus.done => colors.success,
      HerdrAgentStatus.idle || HerdrAgentStatus.unknown => colors.textSecondary,
    };

/// «3m», «2h», «1d», or «now» under a minute.
String hdaDurationText(Strings strings, Duration duration) {
  if (duration.inMinutes < 1) return strings.hdaNow;
  if (duration.inHours < 1) {
    return strings.i18n131SpanMinutes(duration.inMinutes);
  }
  if (duration.inDays < 1) return strings.i18n131SpanHours(duration.inHours);
  return strings.i18n131SpanDays(duration.inDays);
}

/// The folder an agent works in, short, or «unknown».
String hdaFolderText(Strings strings, HerdrPane pane) {
  final cwd = pane.cwd;
  return cwd == null || cwd.isEmpty
      ? strings.hdaFolderUnknown
      : shortServerPath(cwd);
}

/// State pill: tinted background and edge, icon and word.
class HerdrStatusPill extends StatelessWidget {
  const HerdrStatusPill({required this.status, super.key});

  final HerdrAgentStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tint = hdaStatusColor(colors, status);
    return DecoratedBox(
      key: ValueKey('hda-pill-${status.name}'),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(HermesRadius.tag),
        border: Border.all(color: tint.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpace.x2,
          vertical: HermesSpace.x1,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(hdaStatusIcon(status), size: HermesIcon.sm, color: tint),
            const SizedBox(width: HermesSpace.x1),
            Flexible(
              child: Text(
                hdaStatusLabel(Strings.of(context), status),
                style: HermesType.caption.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A button of the glass-gel family, at least 48 dp each way. [selected]
/// turns it into the accent gel (the chosen filter, the primary action).
class HerdrGelButton extends StatelessWidget {
  const HerdrGelButton({
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.selected,
    this.accent = false,
    this.shape,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// For a toggle (filter chips): announced as selected.
  final bool? selected;

  /// The accent gel, for the primary action.
  final bool accent;
  final OutlinedBorder? shape;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final lit = accent || selected == true;
    final outline = shape ?? const StadiumBorder();
    final ink = lit ? colors.onAccent : colors.textPrimary;
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: HermesSpace.tap,
          minWidth: HermesSpace.tap,
        ),
        child: HermesGelSurface(
          shape: outline,
          tone: lit ? HermesGelTone.accent : HermesGelTone.glass,
          paintFill: true,
          hairline: true,
          enabled: onTap != null,
          inset: 2,
          sheenScale: HermesGel.textSheenScale(colors, HermesGelInks.chip),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: outline,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x4,
                  vertical: HermesSpace.x2,
                ),
                child: Center(
                  widthFactor: 1,
                  child: DefaultTextStyle.merge(
                    style: HermesType.text.copyWith(
                      color: ink,
                      fontWeight: FontWeight.w600,
                    ),
                    child: IconTheme.merge(
                      data: IconThemeData(color: ink, size: HermesIcon.md),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Code agents running on the server outside Herdr (a read-only look at the
/// process table): which ones, and that Herdr is how to control them.
class HerdrOutsideProcessesLine extends StatelessWidget {
  const HerdrOutsideProcessesLine({required this.found, super.key});

  /// Executable name -> how many processes.
  final Map<String, int> found;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final names = [
      for (final entry in found.entries)
        entry.value > 1 ? '${entry.key} ×${entry.value}' : entry.key,
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x3),
      child: Semantics(
        container: true,
        child: Column(
          key: const ValueKey('hda-outside-processes'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.tplAgentsProcTitle(names),
              style: HermesType.support.copyWith(color: colors.textPrimary),
            ),
            Text(
              strings.tplAgentsProcHint,
              style: HermesType.caption.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one discreet line of «Herdr is not installed»: the sentence, how to
/// install, and a × that the server remembers.
class HerdrInstallHintLine extends StatelessWidget {
  const HerdrInstallHintLine({
    required this.onHowToInstall,
    required this.onDismiss,
    super.key,
  });

  final VoidCallback onHowToInstall;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Semantics(
      container: true,
      child: Row(
        key: const ValueKey('hda-install-hint'),
        children: [
          Icon(
            Icons.info_outline,
            size: HermesIcon.md,
            color: colors.textSecondary,
          ),
          const SizedBox(width: HermesSpace.x2),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  strings.hdaHintLine,
                  style: HermesType.support.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: HermesSpace.x2),
                TextButton(
                  key: const ValueKey('hda-install-how'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
                    foregroundColor: colors.accentText,
                  ),
                  onPressed: onHowToInstall,
                  child: Text(
                    strings.hdaHowToInstall,
                    style: HermesType.support.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('hda-install-dismiss'),
            tooltip: strings.hdaHintDismiss,
            constraints: const BoxConstraints(
              minWidth: HermesSpace.tap,
              minHeight: HermesSpace.tap,
            ),
            onPressed: onDismiss,
            icon: Icon(
              Icons.close_rounded,
              size: HermesIcon.md,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A centred message with an optional action (empty, stopped, error).
class HerdrAgentsMessage extends StatelessWidget {
  const HerdrAgentsMessage({
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(HermesSpace.x6),
          child: Semantics(
            container: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: HermesSpace.x8, color: colors.textSecondary),
                const SizedBox(height: HermesSpace.x3),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: HermesType.title.copyWith(color: colors.textPrimary),
                ),
                if (body != null) ...[
                  const SizedBox(height: HermesSpace.x2),
                  Text(
                    body!,
                    textAlign: TextAlign.center,
                    style: HermesType.text.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                if (actionLabel != null) ...[
                  const SizedBox(height: HermesSpace.x4),
                  HerdrGelButton(
                    key: const ValueKey('hda-message-action'),
                    onTap: onAction,
                    child: Text(actionLabel!),
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

/// Opens the project page or copies the command.
Future<void> _openUrl(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('[herdr-agents] could not open link (${e.runtimeType})');
  }
}

/// How to install Herdr: the command to copy and the project link. Shown,
/// never run. Returns true when the user says they installed it.
Future<bool?> showHerdrInstallSheet(BuildContext context) {
  final strings = Strings.of(context);
  return showHermesFormDialog<bool>(
    context: context,
    surfaceKey: const ValueKey('hda-install-sheet'),
    title: strings.hdaInstallTitle,
    message: strings.hdaInstallBody,
    actions: [
      HermesDialogAction(
        key: const ValueKey('hda-install-close'),
        label: strings.commonClose,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(
        key: const ValueKey('hda-install-check'),
        label: strings.hdaInstallCheck,
        value: true,
      ),
    ],
    body: (context, setState) {
      final colors = Theme.of(context).hermes;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  sshHerdrInstallCommand,
                  key: const ValueKey('hda-install-command'),
                  style: HermesType.support.copyWith(
                    fontFamily: HermesType.monoFamily,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('hda-install-copy'),
                tooltip: strings.commonCopy,
                constraints: const BoxConstraints(
                  minWidth: HermesSpace.tap,
                  minHeight: HermesSpace.tap,
                ),
                icon: Icon(
                  Icons.copy_rounded,
                  size: HermesIcon.lg,
                  color: colors.textSecondary,
                ),
                onPressed: () async {
                  final feedback = AppFeedback.of(context);
                  await Clipboard.setData(
                    const ClipboardData(text: sshHerdrInstallCommand),
                  );
                  feedback.notify(FeedbackKind.routine, strings.sshCopied);
                },
              ),
            ],
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('hda-install-project'),
              style: TextButton.styleFrom(
                minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
                foregroundColor: colors.accentText,
              ),
              onPressed: () => _openUrl(sshHerdrRepoUrl),
              child: Text(strings.hdaInstallProject),
            ),
          ),
        ],
      );
    },
  );
}

/// The words for what an action returned, or null when it went through.
String? hdaResultMessage(
  Strings strings,
  HerdrActionResult result, {
  required String agent,
  HerdrInputProblem? problem,
}) => switch (result) {
  HerdrActionResult.ok => null,
  HerdrActionResult.agentBlocked => strings.hdaErrBlocked(agent),
  HerdrActionResult.notFound => strings.hdaErrNotFound,
  HerdrActionResult.serverStopped => strings.hdaServerStoppedTitle,
  HerdrActionResult.timedOut => strings.hdaTimedOut,
  HerdrActionResult.noPath => strings.hdaReadOnly,
  HerdrActionResult.startFailed => strings.hdaCreateStartFailed(agent),
  HerdrActionResult.invalid => switch (problem) {
    HerdrInputProblem.empty => strings.hdaErrEmpty,
    HerdrInputProblem.tooLong => strings.hdaErrTooLong,
    HerdrInputProblem.badChars => strings.hdaErrChars,
    HerdrInputProblem.badFolder => strings.hdaErrFolder,
    _ => strings.hdaErrFailed,
  },
  HerdrActionResult.failed => strings.hdaErrFailed,
};

/// Which input problem a prompt has, for the message; null when fine.
HerdrInputProblem? hdaPromptProblem(String text) {
  try {
    herdrPromptText(text);
    return null;
  } on HerdrInputException catch (e) {
    return e.problem;
  }
}
