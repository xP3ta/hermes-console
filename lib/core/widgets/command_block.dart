// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../feedback/feedback_policy.dart';
import '../theme/app_theme.dart';

/// A command or a few config lines the user runs on the computer where
/// Hermes lives: exact text, selectable, with one Copy button.
class CommandBlock extends StatelessWidget {
  const CommandBlock(this.command, {super.key});

  final String command;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x3,
        HermesSpace.x3,
        HermesSpace.x2,
        HermesSpace.x1,
      ),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            command,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.45,
              color: colors.textPrimary,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: command));
                AppFeedback.of(
                  context,
                ).notify(FeedbackKind.routine, s.qrCmdCopied);
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: Text(s.commonCopy),
            ),
          ),
        ],
      ),
    );
  }
}

/// Scrolls what [key] marks into view once it has been built: a block that a
/// tap just unfolded at the bottom of a sheet must not appear below the fold.
void revealWhenBuilt(GlobalKey key) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = key.currentContext;
    if (target == null || !target.mounted) return;
    Scrollable.ensureVisible(
      target,
      alignment: 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  });
}
