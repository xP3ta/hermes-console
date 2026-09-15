import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../services/server_setup_generator.dart';
import '../theme/app_theme.dart';

/// Dos comandos ejecutables por separado. Evita que una persona en Windows
/// copie por accidente el `curl | sh`, o que alguien en Unix copie PowerShell.
class PlatformSetupCommands extends StatelessWidget {
  const PlatformSetupCommands({super.key, this.pairing = false});

  final bool pairing;

  @override
  Widget build(BuildContext context) {
    final str = Strings.of(context);
    final commands = <(String, String)>[
      (
        '${str.setupPlatformLinux} / ${str.setupPlatformMacos}',
        pairing
            ? ServerSetupGenerator.pairCommand
            : ServerSetupGenerator.curlCommand,
      ),
      (
        '${str.setupPlatformWindows} PowerShell',
        pairing
            ? ServerSetupGenerator.powershellPairCommand
            : ServerSetupGenerator.powershellCommand,
      ),
    ];
    return Column(
      children: commands
          .map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _PlatformCommand(label: entry.$1, command: entry.$2),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _PlatformCommand extends StatelessWidget {
  const _PlatformCommand({required this.label, required this.command});

  final String label;
  final String command;

  @override
  Widget build(BuildContext context) {
    // Bug real: usaba Theme.of(context).colorScheme en vez de `hermes`.
    final colors = Theme.of(context).hermes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          SelectableText(
            command,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: command));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(Strings.of(context).qrCmdCopied)),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: Text(Strings.of(context).commonCopy),
            ),
          ),
        ],
      ),
    );
  }
}
