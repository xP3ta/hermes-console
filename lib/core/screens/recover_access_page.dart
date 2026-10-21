// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../services/hermes_setup_commands.dart';
import '../services/official_dashboard_command.dart';
import '../theme/app_theme.dart';
import '../widgets/command_block.dart';
import '../widgets/dashboard_password_help.dart';

/// «I don't know the password»: the Dashboard has no route to change it (only
/// login, logout, session and native exchange), so the app explains where it
/// is changed and hands over the line that gives the Dashboard a new access.
/// Back in the app, the existing expired-session flow signs in again.
Future<void> openRecoverAccess(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const RecoverAccessPage()));

class RecoverAccessPage extends StatefulWidget {
  const RecoverAccessPage({super.key});

  @override
  State<RecoverAccessPage> createState() => _RecoverAccessPageState();
}

class _RecoverAccessPageState extends State<RecoverAccessPage> {
  SetupHostSystem _system = SetupHostSystem.unix;

  Future<void> _send(String command) async {
    try {
      await Share.share(command);
    } catch (_) {
      // No share sheet: the Copy button on the block is the way.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final support = HermesType.text.copyWith(color: colors.textSecondary);
    final windows = _system == SetupHostSystem.windows;
    final command = newAccessCommand(_system);
    return HermesPage(
      title: s.onb2RecoverTitle,
      children: [
        Text(s.leg3RecoverBody, style: support),
        const SizedBox(height: HermesSpace.x4),
        SegmentedButton<SetupHostSystem>(
          key: const ValueKey('recover-access-system'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: SetupHostSystem.unix,
              label: Text(s.o2MacLinux),
            ),
            ButtonSegment(
              value: SetupHostSystem.windows,
              label: Text(s.o2Windows),
            ),
          ],
          selected: {_system},
          onSelectionChanged: (v) => setState(() => _system = v.first),
        ),
        const SizedBox(height: HermesSpace.x3),
        Text(windows ? s.o2StepPowerShell : s.o2StepTerminal, style: support),
        const SizedBox(height: HermesSpace.x2),
        CommandBlock(command, key: const ValueKey('recover-access-command')),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('recover-access-send'),
            onPressed: () => unawaited(_send(command)),
            icon: const Icon(Icons.ios_share_rounded, size: 16),
            label: Text(s.o2SendToComputer),
          ),
        ),
        const SizedBox(height: HermesSpace.x3),
        Text(s.onb2RecoverAfter, style: support),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('recover-access-other'),
            onPressed: () => unawaited(showDashboardPasswordHelp(context)),
            child: Text(s.onb2RecoverOther),
          ),
        ),
      ],
    );
  }
}
