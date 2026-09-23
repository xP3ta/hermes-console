import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'hermes_notice.dart';

/// Tappable helper shown under gateway API key fields so the user never has
/// to guess which key the app is asking for or where to find it.
class ApiKeyHelpLink extends StatelessWidget {
  const ApiKeyHelpLink({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(48, 48),
        ),
        icon: Icon(Icons.help_outline, size: 14, color: colors.accentHover),
        label: Text(
          Strings.of(context).apiKeyHelpLinkLabel,
          style: TextStyle(
            fontSize: 11,
            color: colors.accentHover,
          ),
        ),
        onPressed: () => showDialog(
          context: context,
          builder: (_) => const _ApiKeyHelpDialog(),
        ),
      ),
    );
  }
}

class _ApiKeyHelpDialog extends StatelessWidget {
  const _ApiKeyHelpDialog();

  static const _command = r'grep API_SERVER_KEY ~/.hermes/.env';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return AlertDialog(
      title: Text(
        Strings.of(context).apiKeyHelpTitle,
        style: const TextStyle(fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Strings.of(context).apiKeyHelpBody1,
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
          ),
          const SizedBox(height: 12),
          Text(
            Strings.of(context).apiKeyHelpGatewayLabel,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _command,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.accentHover,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: Strings.of(context).apiKeyHelpCopy,
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(text: _command));
                    HermesNotice.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          Strings.of(context).apiKeyHelpCopied,
                          style: TextStyle(
                            fontSize: 13,
                          ),
                        ),
                      ),
                      kind: HermesNoticeKind.success,
                    );
                  },
                  icon: Icon(
                    Icons.copy,
                    size: 14,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            Strings.of(context).apiKeyHelpBody2,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(Strings.of(context).apiKeyHelpOk),
        ),
      ],
    );
  }
}
