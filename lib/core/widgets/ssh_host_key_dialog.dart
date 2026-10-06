import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/ssh_manager.dart';
import '../theme/app_theme.dart';

/// Diálogo de verificación de host key (TOFU). Se muestra solo cuando el
/// fingerprint es nuevo (primera conexión) o ha cambiado (posible MITM).
/// Devuelve true si el usuario confía en la clave.
Future<bool> showSshHostKeyDialog(
  BuildContext context,
  SshHostKeyPrompt prompt,
) async {
  final colors = Theme.of(context).hermes;
  final changed = prompt.changed;
  final tone = changed ? colors.error : colors.warning;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(changed ? Icons.gpp_bad_outlined : Icons.verified_user_outlined,
              size: 20, color: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              changed ? Strings.of(ctx).sshKeyChangedTitle : Strings.of(ctx).sshNewServerTitle,
              style: TextStyle(fontSize: 16, color: colors.textPrimary),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            changed
                ? Strings.of(ctx).sshKeyChangedBody
                : Strings.of(ctx).sshNewServerBody,
            style: TextStyle(
                fontSize: 13, height: 1.45, color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: tone.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${prompt.type} · fingerprint',
                    style: TextStyle(fontSize: 11, color: colors.textTertiary)),
                const SizedBox(height: 4),
                SelectableText(
                  prompt.fingerprint,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${Strings.of(ctx).sshCheckCmd}'
            'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256',
            style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                fontFamily: 'monospace',
                color: colors.textTertiary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(Strings.of(ctx).commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: changed
              ? FilledButton.styleFrom(backgroundColor: colors.error)
              : null,
          child: Text(changed ? Strings.of(ctx).sshTrustAnyway : Strings.of(ctx).sshTrustBtn,
              style: TextStyle(color: colors.onAccent)),
        ),
      ],
    ),
  );
  return ok ?? false;
}
