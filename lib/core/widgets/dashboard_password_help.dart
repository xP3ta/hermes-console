// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart';
import '../design/tokens.dart';
import '../services/hermes_setup_commands.dart';
import '../theme/app_theme.dart';
import 'command_block.dart';
import 'hermes_premium_ui.dart';

/// Official recipe for the Dashboard's username and password provider.
const _dashboardPasswordDocs =
    'https://hermes-agent.nousresearch.com/docs/user-guide/features/'
    'web-dashboard#usernamepassword-provider-no-oauth-idp';

Future<void> _openDocs() async {
  try {
    await launchUrl(
      Uri.parse(_dashboardPasswordDocs),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // No browser to open it with: the steps above are the whole recipe.
  }
}

/// The two lines Hermes reads at start: an env password overrides whatever
/// password is stored hashed in its config (`plugins/dashboard_auth/basic`).
String dashboardPasswordEnvLines(Strings s) =>
    'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin\n'
    'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${s.dashPasswordHelpPlaceholder}';

/// What the app can truthfully offer to someone who does not know the
/// Dashboard password: it cannot be read back from anywhere, only replaced
/// on the computer that runs Hermes. One line of the setup helper does it
/// (a new sign-in, shown there to type here); the two `.env` lines remain
/// for whoever prefers to do it by hand.
Future<void> showDashboardPasswordHelp(BuildContext context) {
  return showHermesSurface<void>(
    context: context,
    surfaceKey: const ValueKey('dashboard-password-help'),
    builder: (_) => const _DashboardPasswordHelp(),
  );
}

class _DashboardPasswordHelp extends StatefulWidget {
  const _DashboardPasswordHelp();

  @override
  State<_DashboardPasswordHelp> createState() => _DashboardPasswordHelpState();
}

class _DashboardPasswordHelpState extends State<_DashboardPasswordHelp> {
  SetupHostSystem _system = SetupHostSystem.unix;
  bool _byHand = false;
  final _byHandKey = GlobalKey();

  void _toggleByHand() {
    setState(() => _byHand = !_byHand);
    if (_byHand) revealWhenBuilt(_byHandKey);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final text = HermesType.text.copyWith(color: colors.textPrimary);
    final support = HermesType.text.copyWith(color: colors.textSecondary);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesSurfaceHeader(title: s.dashPasswordHelpTitle, showClose: true),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x5,
              0,
              HermesSpace.x5,
              HermesSpace.x4,
            ),
            children: [
              Text(s.dashPasswordHelpIntro, style: support),
              const SizedBox(height: HermesSpace.x4),
              HermesSegmentedControl<SetupHostSystem>(
                value: _system,
                semanticLabel: s.dashPasswordHelpTitle,
                segments: [
                  HermesSegment(
                    value: SetupHostSystem.unix,
                    label: s.setupHostUnix,
                    key: const ValueKey('dashboard-password-unix'),
                  ),
                  const HermesSegment(
                    value: SetupHostSystem.windows,
                    label: 'Windows',
                    key: ValueKey('dashboard-password-windows'),
                  ),
                ],
                onChanged: (system) => setState(() => _system = system),
              ),
              const SizedBox(height: HermesSpace.x3),
              CommandBlock(
                HermesSetupCommands.newAccess(_system),
                key: const ValueKey('dashboard-password-command'),
              ),
              const SizedBox(height: HermesSpace.x3),
              Text(s.dashPasswordHelpCommand, style: text),
              const SizedBox(height: HermesSpace.x2),
              Text(s.dashPasswordHelpOthers, style: support),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('dashboard-password-by-hand'),
                  onPressed: _toggleByHand,
                  child: Text(s.setupByHand),
                ),
              ),
              if (_byHand) ...[
                Text(s.dashPasswordHelpStep1, style: text),
                const SizedBox(height: HermesSpace.x2),
                KeyedSubtree(
                  key: _byHandKey,
                  child: CommandBlock(
                    dashboardPasswordEnvLines(s),
                    key: const ValueKey('dashboard-password-manual-command'),
                  ),
                ),
                const SizedBox(height: HermesSpace.x4),
                Text(s.dashPasswordHelpStep2, style: text),
                const SizedBox(height: HermesSpace.x2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => unawaited(_openDocs()),
                    child: Text(s.connectInstallHelp),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
