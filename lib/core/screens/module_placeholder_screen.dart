import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';

/// Console-style placeholder for roadmap modules that have no backing
/// screen yet (SOUL, plugins, activity log…). Honest about its status:
/// shows the module slug, a `not_linked` state line and the roadmap phase.
class ModulePlaceholderScreen extends StatelessWidget {
  final String title;
  final String slug;
  final IconData icon;
  final String description;
  final String phase;

  const ModulePlaceholderScreen({
    required this.title,
    required this.slug,
    required this.icon,
    required this.description,
    required this.phase,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(title),
      ),
      body: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - t)),
              child: child,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: colors.accent.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Icon(icon, size: 26, color: colors.accent),
                ),
                const SizedBox(height: 18),
                Text(
                  '▸ module: $slug',
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'status: not_linked · $phase',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.textTertiary,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
