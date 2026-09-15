import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

enum VoiceDisclosureChoice { foregroundOnly, continueWhenLocked }

/// Aviso afirmativo de primer uso. Cerrar, pulsar fuera o volver atrás devuelve
/// null y no activa el micrófono ni guarda consentimiento.
Future<VoiceDisclosureChoice?> showVoiceDisclosureDialog(
  BuildContext context,
) => showDialog<VoiceDisclosureChoice>(
  context: context,
  builder: (context) {
    final s = Strings.of(context);
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.graphic_eq_rounded),
      title: Text(s.voiceDisclosureTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.voiceDisclosureBody),
            const SizedBox(height: 16),
            _DisclosureChoiceTile(
              icon: Icons.phone_android_rounded,
              title: s.voiceForegroundOnlyTitle,
              subtitle: s.voiceForegroundOnlySub,
              onTap: () => Navigator.of(
                context,
              ).pop(VoiceDisclosureChoice.foregroundOnly),
            ),
            const SizedBox(height: 8),
            _DisclosureChoiceTile(
              icon: Icons.lock_outline_rounded,
              title: s.voiceContinueLockedTitle,
              subtitle: s.voiceContinueLockedSub,
              onTap: () => Navigator.of(
                context,
              ).pop(VoiceDisclosureChoice.continueWhenLocked),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.commonCancel),
        ),
      ],
    );
  },
);

/// Consentimiento único del modo de voz nativo (spec 048/US5). Devuelve true
/// (usar la voz del servidor), false (seguir en local; no se vuelve a
/// preguntar) o null si se cierra sin decidir (se ofrecerá de nuevo).
Future<bool?> showNativeVoiceConsentDialog(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (context) {
        final s = Strings.of(context);
        return AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.dns_rounded),
          title: Text(s.nativeVoiceConsentTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.nativeVoiceConsentBody),
                const SizedBox(height: 16),
                _DisclosureChoiceTile(
                  icon: Icons.record_voice_over_rounded,
                  title: s.nativeVoiceConsentAccept,
                  subtitle: s.nativeVoiceConsentAcceptSub,
                  onTap: () => Navigator.of(context).pop(true),
                ),
                const SizedBox(height: 8),
                _DisclosureChoiceTile(
                  icon: Icons.phone_android_rounded,
                  title: s.nativeVoiceConsentDecline,
                  subtitle: s.nativeVoiceConsentDeclineSub,
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        );
      },
    );

class _DisclosureChoiceTile extends StatelessWidget {
  const _DisclosureChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    // Bug real: usaba Theme.of(context).colorScheme en vez de `hermes`.
    color: Theme.of(context).hermes.surfaceVariant,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
