import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';

// dc1215: the building blocks of the Dots-style activity view. One row shape
// for everything the chat is doing (a step of the turn, a delegated
// subagent, a background process): a 40dp icon tile, a title, a one- or
// two-line subtitle (a gerund while it runs, past tense once done) and,
// only when the app can already stop that item, a round Stop button.

/// What a step is called in the activity view and in the Bot Chat header.
///
/// The same names the working line under the assistant uses: a skill load
/// reads as its skill (without the `category/` prefix), anything else as
/// the tool plus its safe, already projected detail.
String activityStepTitle(ActivityStep step) {
  final label = step.label.trim();
  final detail = step.detail?.trim();
  if (step.kind == ActivityStepKind.skill) {
    return label.split('/').last.trim();
  }
  if (isSkillLoadTool(label) && detail != null && detail.isNotEmpty) {
    final skill = detail.split(' → ').first.split('/').last.trim();
    if (skill.isNotEmpty) return skill;
  }
  if (detail == null || detail.isEmpty) return label;
  return '$label · $detail';
}

/// Whether [step] is a skill (loaded or declared), for its gerund.
bool activityStepIsSkill(ActivityStep step) =>
    step.kind == ActivityStepKind.skill ||
    (isSkillLoadTool(step.label) && (step.detail?.trim().isNotEmpty ?? false));

/// The 40dp rounded tile that leads every row.
class ActivityRowTile extends StatelessWidget {
  const ActivityRowTile({
    required this.icon,
    this.color,
    this.child,
    super.key = const ValueKey('activity-row-tile'),
  });

  final IconData icon;
  final Color? color;

  /// Replaces the icon (e.g. a small progress ring).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return SizedBox(
      width: 40,
      height: 40,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.divider, width: 0.6),
        ),
        child: Center(
          child:
              child ??
              Icon(icon, size: 20, color: color ?? colors.textSecondary),
        ),
      ),
    );
  }
}

/// Round Stop: a filled circle with a square, inside a 48dp target. Busy
/// (and disabled) while its action runs, so a double tap sends one stop.
class ActivityStopButton extends StatefulWidget {
  const ActivityStopButton({
    required this.semanticLabel,
    required this.onPressed,
    super.key,
  });

  final String semanticLabel;
  final Future<void> Function() onPressed;

  @override
  State<ActivityStopButton> createState() => _ActivityStopButtonState();
}

class _ActivityStopButtonState extends State<ActivityStopButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      enabled: !_busy,
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: Tooltip(
        message: widget.semanticLabel,
        excludeFromSemantics: true,
        child: InkResponse(
          onTap: _busy ? null : _run,
          radius: 24,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _busy
                      ? colors.textPrimary.withValues(alpha: 0.4)
                      : colors.textPrimary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.stop_rounded,
                  size: 20,
                  color: colors.surface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the activity view.
class ActivityDotsRow extends StatelessWidget {
  const ActivityDotsRow({
    required this.tile,
    required this.title,
    this.subtitle,
    this.trailing,
    this.stop,
    this.highlighted = false,
    this.muted = false,
    this.titleColor,
    this.onTap,
    this.semanticsHint,
    this.footer,
    this.footerLabel,
    super.key,
  });

  final Widget tile;
  final String title;
  final String? subtitle;

  /// Elapsed time or duration, before [stop].
  final Widget? trailing;
  final Widget? stop;

  /// The current step: a soft filled background, as in the mockup.
  final bool highlighted;

  /// Finished rows read quieter.
  final bool muted;
  final Color? titleColor;
  final VoidCallback? onTap;
  final String? semanticsHint;

  /// Extra lines under the subtitle (a process's watch patterns).
  final Widget? footer;

  /// What [footer] says, for screen readers.
  final String? footerLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: Row(
        children: [
          tile,
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              container: true,
              label: [title, ?subtitle, ?footerLabel].join(', '),
              hint: semanticsHint,
              button: onTap != null,
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.body.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      color:
                          titleColor ??
                          (muted ? colors.textSecondary : colors.textPrimary),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.25,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                  if (footer != null) ...[const SizedBox(height: 2), footer!],
                ],
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Padding(
              padding: EdgeInsets.only(right: stop == null ? 8 : 0),
              child: trailing,
            ),
          ],
          if (stop != null) ...[const SizedBox(width: 4), stop!],
        ],
      ),
    );
    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: row,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: highlighted
            ? colors.surfaceVariant.withValues(alpha: 0.7)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(HermesRadius.group),
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? body : InkWell(onTap: onTap, child: body),
      ),
    );
  }
}

/// The three bottom actions of the activity view. Each one appears only
/// when its callback exists (the chat decides that from what the session
/// supports today). On narrow widths or large text the two composer
/// actions stack instead of squeezing.
class ActivityDotsActionsBar extends StatelessWidget {
  const ActivityDotsActionsBar({
    this.onAddContext,
    this.onChangeCourse,
    this.onStopAll,
    super.key = const ValueKey('activity-actions'),
  });

  final VoidCallback? onAddContext;
  final VoidCallback? onChangeCourse;
  final Future<void> Function()? onStopAll;

  bool get isEmpty =>
      onAddContext == null && onChangeCourse == null && onStopAll == null;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final addContext = onAddContext;
    final changeCourse = onChangeCourse;
    final stopAll = onStopAll;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(HermesRadius.tag),
    );
    // From the theme so the labels keep the app font (a bare TextStyle
    // would replace the theme's family).
    final labelStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
        );
    Widget label(String text) => Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    final buttons = <Widget>[
      if (addContext != null)
        OutlinedButton(
          key: const ValueKey('activity-action-add-context'),
          onPressed: addContext,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: shape,
            foregroundColor: colors.textPrimary,
            side: BorderSide(color: colors.divider),
            textStyle: labelStyle,
          ),
          child: label(s.dc1215AddContext),
        ),
      if (changeCourse != null)
        FilledButton(
          key: const ValueKey('activity-action-change-course'),
          onPressed: changeCourse,
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: shape,
            backgroundColor: colors.accent,
            foregroundColor: colors.onAccent,
            textStyle: labelStyle,
          ),
          child: label(s.dc1215ChangeCourse),
        ),
    ];
    final stack = scale > 1.3 || buttons.length < 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (buttons.isNotEmpty)
            stack
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < buttons.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        buttons[i],
                      ],
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: buttons[0]),
                      const SizedBox(width: 8),
                      Expanded(child: buttons[1]),
                    ],
                  ),
          if (stopAll != null)
            Center(
              child: TextButton(
                key: const ValueKey('activity-action-stop-all'),
                onPressed: () => unawaited(stopAll()),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: colors.error,
                  textStyle: labelStyle,
                ),
                child: Text(s.dc1215StopAll, textAlign: TextAlign.center),
              ),
            ),
        ],
      ),
    );
  }
}

/// Round close button of the activity card (48dp target).
class ActivityRoundCloseButton extends StatelessWidget {
  const ActivityRoundCloseButton({
    required this.onPressed,
    required this.tooltip,
    super.key,
  });

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: const Icon(Icons.close_rounded, size: 20),
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: const CircleBorder(),
        backgroundColor: colors.surfaceVariant,
        foregroundColor: colors.textPrimary,
      ),
    );
  }
}
