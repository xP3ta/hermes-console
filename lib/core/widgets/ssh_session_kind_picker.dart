// Selector del tipo de sesión de un perfil SSH (1.4.0, F1): Shell normal
// (por defecto) o, a mano, Herdr o tmux. Va en «Avanzado» de la edición. Chips en un Wrap para que el texto grande baje de línea en
// vez de desbordar.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/ssh_session_kind.dart';
import '../theme/app_theme.dart';

class SshSessionKindPicker extends StatelessWidget {
  const SshSessionKindPicker({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final SshSessionKind value;
  final ValueChanged<SshSessionKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          strings.sshSessionKind,
          style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in SshSessionKind.values)
              ChoiceChip(
                key: ValueKey('ssh-session-kind-${kind.id}'),
                label: Text(kind.programName ?? strings.sshSessionKindShell),
                selected: kind == value,
                onSelected: (_) => onChanged(kind),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          strings.tplSshRunInHint,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.4,
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }
}
