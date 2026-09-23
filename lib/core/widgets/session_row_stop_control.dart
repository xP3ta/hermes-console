import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class SessionRowStopControl extends StatefulWidget {
  const SessionRowStopControl({required this.onStop, super.key});

  final Future<void> Function() onStop;

  @override
  State<SessionRowStopControl> createState() => _SessionRowStopControlState();
}

class _SessionRowStopControlState extends State<SessionRowStopControl> {
  bool _stopping = false;

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await widget.onStop();
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final label = Strings.of(context).chaStopTooltip;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: colors.surfaceVariant.withValues(alpha: 0.9),
          shape: CircleBorder(side: BorderSide(color: colors.divider)),
          child: InkResponse(
            key: const ValueKey('session-row-stop'),
            onTap: _stopping ? null : _stop,
            radius: 22,
            containedInkWell: true,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: 36,
              child: Center(
                child: _stopping
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: colors.textSecondary,
                        ),
                      )
                    : Icon(
                        Icons.stop_rounded,
                        size: 18,
                        color: colors.textPrimary,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
