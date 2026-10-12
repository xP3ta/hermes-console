import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/connection.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart';
import 'themes_screen.dart';

/// Instance-scoped entry point for visual personalization.
///
/// Theme values remain local to the Android client, but the product route is
/// deliberately scoped to a real saved instance, like Voice and Settings.
class AppearanceScreen extends StatelessWidget {
  final SavedConnection connection;

  const AppearanceScreen({required this.connection, super.key});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(title: Text(strings.setSecAppearance)),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _AppearanceScope(connectionLabel: connection.label),
          HermesSectionHeader(strings.themesTitle),
          HermesGroup(
            children: [
              HermesNavRow(
                key: const ValueKey('appearance-theme-presets'),
                icon: Icons.palette_outlined,
                title: strings.themesTitle,
                subtitle: strings.themesHint(AppTheme.familyCount),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(builder: (_) => const ThemesScreen()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppearanceScope extends StatelessWidget {
  final String connectionLabel;

  const _AppearanceScope({required this.connectionLabel});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: true,
      label: '${Strings.of(context).setSecAppearance}: $connectionLabel',
      child: Padding(
        key: const ValueKey('appearance-current-preview'),
        padding: const EdgeInsets.fromLTRB(2, 5, 2, 3),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.dns_outlined,
                size: 15,
                color: colors.accentHover,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                Strings.of(context).gwActiveInstance(connectionLabel),
                key: const ValueKey('appearance-connection-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: colors.textSecondary,
                  letterSpacing: 0,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: colors.accent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: colors.accent.withValues(alpha: 0.35),
                    blurRadius: 7,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
