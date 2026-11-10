// Pieces of the Agents list (1.4.0): an agent that is still starting (or
// failed to), the quiet «updated N s ago» line and the closing card for
// agents running outside Herdr. Presentation only; the state is
// HerdrAgentsController's. The rows themselves are in herdr_flat_widgets.dart.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/gel_surface.dart';
import '../services/herdr_agents.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../utils/short_server_path.dart';
import 'herdr_agents_widgets.dart';

/// «Updated N s ago», refreshed by its own one-second timer so nothing
/// around it repaints. Says nothing until there is a first reading.
class HerdrUpdatedAgo extends StatefulWidget {
  const HerdrUpdatedAgo({
    required this.at,
    required this.now,
    this.style,
    super.key,
  });

  /// When the last reading landed (read on every tick, so pass a getter).
  final DateTime? Function() at;

  /// The clock.
  final DateTime Function() now;
  final TextStyle? style;

  @override
  State<HerdrUpdatedAgo> createState() => _HerdrUpdatedAgoState();
}

class _HerdrUpdatedAgoState extends State<HerdrUpdatedAgo> {
  Timer? _timer;
  int _shown = -1;

  int _seconds() {
    final at = widget.at();
    if (at == null) return -1;
    final elapsed = widget.now().difference(at).inSeconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  @override
  void initState() {
    super.initState();
    _shown = _seconds();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = _seconds();
      // Under a minute it counts seconds; after that only each minute
      // changes the words.
      final changed = next < 60 || _shown < 60 || next ~/ 60 != _shown ~/ 60;
      if (next != _shown && changed && mounted) {
        setState(() => _shown = next);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _seconds();
    if (seconds < 0) return const SizedBox.shrink();
    final strings = Strings.of(context);
    final text = seconds < 3
        ? strings.hdpUpdatedNow
        : seconds < 60
        ? strings.hdpUpdatedSeconds(seconds)
        : strings.hdpUpdatedAgo(
            hdaDurationText(strings, Duration(seconds: seconds)),
          );
    return Text(
      text,
      key: const ValueKey('hda-updated'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style:
          widget.style ??
          HermesType.caption.copyWith(
            color: Theme.of(context).hermes.textSecondary,
          ),
    );
  }
}

/// An agent that is starting (spinner and «Starting…» in its own row) or
/// whose start failed (why, in the harness's name, with «Open in terminal»
/// and «Retry»).
class HerdrStartTile extends StatelessWidget {
  const HerdrStartTile({
    required this.job,
    required this.onRetry,
    required this.onDismiss,
    required this.onOpenTerminal,
    super.key,
  });

  final HerdrStartJob job;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;
  final VoidCallback? onOpenTerminal;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final folder = shortServerPath(job.folder);
    final failed = job.failed;
    return Semantics(
      container: true,
      liveRegion: true,
      label: failed
          ? strings.hdpStartFailedTitle(job.kind)
          : '${job.kind}, ${strings.hdpStarting}, $folder',
      child: ColoredBox(
        key: ValueKey('hda-start-${job.paneId}'),
        color: failed
            ? colors.error.withValues(alpha: 0.08)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.rowH,
            vertical: HermesSpace.rowV,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: HermesIcon.xl,
                height: HermesIcon.xl,
                child: failed
                    ? Icon(
                        Icons.error_outline_rounded,
                        size: HermesIcon.xl,
                        color: colors.error,
                      )
                    : Padding(
                        padding: const EdgeInsets.all(3),
                        child: CircularProgressIndicator(
                          key: const ValueKey('hda-start-spinner'),
                          strokeWidth: 2.5,
                          color: colors.accent,
                        ),
                      ),
              ),
              const SizedBox(width: HermesSpace.rowIconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      failed ? strings.hdpStartFailedTitle(job.kind) : job.kind,
                      style: HermesType.body.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      failed
                          ? strings.hdpStartFailedBody
                          : '${strings.hdpStarting} · $folder',
                      style: HermesType.support.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    if (failed && job.reason != null) ...[
                      const SizedBox(height: HermesSpace.x1),
                      Text(
                        strings.hdpStartReason,
                        style: HermesType.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      SelectableText(
                        job.reason!,
                        key: const ValueKey('hda-start-reason'),
                        style: HermesType.support.copyWith(
                          fontFamily: HermesType.monoFamily,
                          color: colors.textPrimary,
                        ),
                      ),
                    ],
                    if (failed) ...[
                      const SizedBox(height: HermesSpace.x2),
                      Wrap(
                        spacing: HermesSpace.x2,
                        runSpacing: HermesSpace.x1,
                        children: [
                          HerdrGelButton(
                            key: const ValueKey('hda-start-retry'),
                            accent: true,
                            onTap: onRetry,
                            child: Text(strings.hdpRetry),
                          ),
                          if (onOpenTerminal != null)
                            HerdrGelButton(
                              key: const ValueKey('hda-start-terminal'),
                              onTap: onOpenTerminal,
                              child: Text(strings.hdpOpenTerminal),
                            ),
                          HerdrGelButton(
                            key: const ValueKey('hda-start-dismiss'),
                            onTap: onDismiss,
                            child: Text(strings.hdpDismiss),
                          ),
                        ],
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(top: HermesSpace.x1),
                        child: Text(
                          strings.hdpStartingHint,
                          style: HermesType.caption.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Code agents running on the server outside Herdr: a discreet card at the
/// end of the list, with «Open with herdr» only when Herdr is there to be
/// opened.
class HerdrOutsideCard extends StatelessWidget {
  const HerdrOutsideCard({required this.found, this.onOpenHerdr, super.key});

  /// Executable name -> how many processes.
  final Map<String, int> found;

  /// Types `herdr` into a terminal; null when Herdr is not installed.
  final VoidCallback? onOpenHerdr;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final names = [
      for (final entry in found.entries)
        entry.value > 1 ? '${entry.key} ×${entry.value}' : entry.key,
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x4),
      child: HermesGelSurface(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HermesRadius.row),
        ),
        tone: HermesGelTone.glass,
        paintFill: true,
        hairline: true,
        glow: false,
        pressable: false,
        child: Padding(
          key: const ValueKey('hda-outside-processes'),
          padding: const EdgeInsets.all(HermesSpace.x3),
          child: Semantics(
            container: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.tplAgentsProcTitle(names),
                  style: HermesType.support.copyWith(color: colors.textPrimary),
                ),
                Text(
                  strings.tplAgentsProcHint,
                  style: HermesType.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                if (onOpenHerdr != null) ...[
                  const SizedBox(height: HermesSpace.x2),
                  HerdrGelButton(
                    key: const ValueKey('hda-outside-open'),
                    onTap: onOpenHerdr,
                    child: Text(strings.hdpOpenWithHerdr),
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
