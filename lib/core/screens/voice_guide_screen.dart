import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';

/// Guía local de configuración de voz.
///
/// Vive en la app para que siempre coincida con la versión instalada y no
/// dependa de una ruta web que pueda no existir o estar desactualizada.
class VoiceGuideScreen extends StatelessWidget {
  const VoiceGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(title: Text(strings.voiceGuideButton)),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          Text(
            strings.voiceGuideLocalTitle,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          _GuideStep(
            icon: Icons.mic_none_outlined,
            title: strings.voiceGuideDictationTitle,
            body: strings.voiceGuideDictationBody,
          ),
          const SizedBox(height: 12),
          _GuideStep(
            icon: Icons.volume_up_outlined,
            title: strings.voiceGuideReadingTitle,
            body: strings.voiceGuideReadingBody,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 17, color: colors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.voiceGuidePrivacyNote,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _GuideStep({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.accent),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
