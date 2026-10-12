import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../../l10n/app_localizations.dart';

/// Runtime health status of a Hermes instance.
enum InstanceStatus {
  online,
  offline,
  syncing,
  readOnly,
  error,
  unknown,
  checking,
}

extension InstanceStatusLabel on InstanceStatus {
  /// Etiqueta neutra (para servicios/diagnóstico sin BuildContext).
  String get label => switch (this) {
    InstanceStatus.online => 'online',
    InstanceStatus.offline => 'offline',
    InstanceStatus.syncing => 'sync',
    InstanceStatus.readOnly => 'read only',
    InstanceStatus.error => 'error',
    InstanceStatus.unknown => '—',
    InstanceStatus.checking => 'checking',
  };

  /// Etiqueta localizada para la UI.
  String labelFor(BuildContext context) {
    final strings = Strings.of(context);
    return switch (this) {
      InstanceStatus.online => strings.i18n1215StatusOnline,
      InstanceStatus.offline => strings.statusOffline,
      InstanceStatus.syncing => strings.i18n1215StatusSyncing,
      InstanceStatus.readOnly => strings.statusReadOnly,
      InstanceStatus.error => strings.i18n1215StatusError,
      InstanceStatus.unknown => label,
      InstanceStatus.checking => strings.statusChecking,
    };
  }
}

/// Compact status pill — dot + lowercase mono label.
///
/// `checking` animates the dot with a subtle pulse.
/// Other statuses are static. Colors are resolved from [HermesThemeColors].
class StatusPill extends StatefulWidget {
  final InstanceStatus status;

  const StatusPill({required this.status, super.key});

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _alpha;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _alpha = Tween<double>(
      begin: 0.35,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(StatusPill old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  void _syncPulse() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.status == InstanceStatus.checking && !reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      if (reduceMotion) _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color _resolveColor(HermesThemeColors c) => switch (widget.status) {
    InstanceStatus.online => c.success,
    InstanceStatus.syncing => c.accent,
    InstanceStatus.readOnly => c.warning,
    InstanceStatus.error => c.error,
    // Offline es información crítica, no un control deshabilitado:
    // textSecondary (5.65:1) en vez de textDisabled (3.69:1, falla WCAG AA
    // para texto de 10px) (spec 028 A-113).
    InstanceStatus.offline => c.textSecondary,
    InstanceStatus.unknown => c.textSecondary,
    InstanceStatus.checking => c.accent,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = _resolveColor(colors);
    final label = widget.status.labelFor(context);
    final isChecking = widget.status == InstanceStatus.checking;

    final dot = isChecking
        ? AnimatedBuilder(
            animation: _alpha,
            builder: (_, _) =>
                _Dot(color: color.withValues(alpha: _alpha.value)),
          )
        : _Dot(color: color);

    final motion = Motion.duration(context, Motion.fast);
    return AnimatedContainer(
      duration: motion,
      curve: Motion.enter,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.40), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 5),
          AnimatedDefaultTextStyle(
            duration: motion,
            curve: Motion.enter,
            style: TextStyle(
              // 10px como base mínima legible de las pills (spec 028 A-113).
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.8,
            ),
            child: Text(label.toUpperCase()),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Motion.duration(context, Motion.fast),
      curve: Motion.enter,
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
