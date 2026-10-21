// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart';
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import 'command_block.dart';
import 'hermes_premium_ui.dart';

/// The system of the computer that still runs the Mobile Bridge.
enum BridgeHost { linux, macos, windows }

const _setupRaw = 'https://raw.githubusercontent.com/xP3ta/hermes-setup/main';
const _setupUnix = 'curl -fsSL $_setupRaw/hermes-mobile-setup.sh | sh';
const _setupWindows =
    '& ([scriptblock]::Create((irm $_setupRaw/hermes-mobile-setup.ps1)))';

/// The recommended way: the old assistant's own `--retire-bridge`, which
/// stops, disables and removes only the bridge, is safe to run twice and
/// refuses when the service is not its own. This is the only place the app
/// still names that assistant (nothing else can remove what it installed).
String bridgeRetireCommand(BridgeHost host) => host == BridgeHost.windows
    ? '$_setupWindows -RetireBridge'
    : '$_setupUnix -s -- --retire-bridge';

/// The same by hand, for whoever prefers not to run the installer: stops and
/// removes ONLY the Mobile Bridge that the Console installer
/// (github.com/xP3ta/hermes-setup) created. The Gateway and the Dashboard
/// services it also created are not named here and stay as they are.
///
/// Every name is the installer's own:
///  * Linux: user unit `hermes-bridge.service` in `~/.config/systemd/user/`;
///  * macOS: LaunchAgent `dev.xpetalab.hermes-console.bridge` and its plist
///    in `~/Library/LaunchAgents/` (stopped with
///    `launchctl bootout gui/$(id -u)/<label>`);
///  * Windows: Scheduled Tasks `HermesConsole-MobileBridge` and
///    `HermesConsole-Restart-MobileBridge`.
/// They are the ones the installer's `--retire-bridge` removes.
const bridgeRemovalCommands = <BridgeHost, String>{
  BridgeHost.linux:
      'systemctl --user disable --now hermes-bridge.service\n'
      'rm -f ~/.config/systemd/user/hermes-bridge.service\n'
      'systemctl --user daemon-reload',
  BridgeHost.macos:
      r'launchctl bootout gui/$(id -u)/dev.xpetalab.hermes-console.bridge'
      '\n'
      'rm -f ~/Library/LaunchAgents/dev.xpetalab.hermes-console.bridge.plist',
  BridgeHost.windows:
      'Stop-ScheduledTask -TaskName HermesConsole-MobileBridge\n'
      r'Unregister-ScheduledTask -TaskName HermesConsole-MobileBridge -Confirm:$false'
      '\n'
      r'Unregister-ScheduledTask -TaskName HermesConsole-Restart-MobileBridge -Confirm:$false',
};

/// How to stop and remove the old bridge, per system, as one line to copy
/// and run on the computer where Hermes lives, with the manual steps one tap
/// away. The phone removes nothing itself.
Future<void> showBridgeRemovalHelp(BuildContext context) {
  return showHermesSurface<void>(
    context: context,
    surfaceKey: const ValueKey('bridge-removal-help'),
    builder: (_) => const _BridgeRemovalHelp(),
  );
}

class _BridgeRemovalHelp extends StatefulWidget {
  const _BridgeRemovalHelp();

  @override
  State<_BridgeRemovalHelp> createState() => _BridgeRemovalHelpState();
}

class _BridgeRemovalHelpState extends State<_BridgeRemovalHelp> {
  BridgeHost _host = BridgeHost.linux;
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
    final support = HermesType.text.copyWith(color: colors.textSecondary);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesSurfaceHeader(title: s.bridgeRemovalTitle, showClose: true),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x5,
              0,
              HermesSpace.x5,
              HermesSpace.x5,
            ),
            children: [
              Text(s.bridgeRemovalIntro, style: support),
              const SizedBox(height: HermesSpace.x4),
              HermesSegmentedControl<BridgeHost>(
                value: _host,
                semanticLabel: s.bridgeRemovalTitle,
                segments: const [
                  HermesSegment(
                    value: BridgeHost.linux,
                    label: 'Linux',
                    key: ValueKey('bridge-removal-linux'),
                  ),
                  HermesSegment(
                    value: BridgeHost.macos,
                    label: 'macOS',
                    key: ValueKey('bridge-removal-macos'),
                  ),
                  HermesSegment(
                    value: BridgeHost.windows,
                    label: 'Windows',
                    key: ValueKey('bridge-removal-windows'),
                  ),
                ],
                onChanged: (host) => setState(() => _host = host),
              ),
              const SizedBox(height: HermesSpace.x3),
              CommandBlock(
                bridgeRetireCommand(_host),
                key: const ValueKey('bridge-removal-command'),
              ),
              const SizedBox(height: HermesSpace.x3),
              Text(
                _host == BridgeHost.windows
                    ? s.bridgeRemovalWhereWindows
                    : s.bridgeRemovalWhereTerminal,
                style: support,
              ),
              const SizedBox(height: HermesSpace.x2),
              Text(s.bridgeRemovalKeeps, style: support),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('bridge-removal-by-hand'),
                  onPressed: _toggleByHand,
                  child: Text(s.setupByHand),
                ),
              ),
              if (_byHand)
                KeyedSubtree(
                  key: _byHandKey,
                  child: CommandBlock(
                    bridgeRemovalCommands[_host]!,
                    key: const ValueKey('bridge-removal-manual-command'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
