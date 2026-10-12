import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import 'command_block.dart';
import 'dashboard_password_help.dart';

/// What a computer that already runs Hermes needs so this phone can reach
/// it: the Dashboard with a username and password, and the Gateway with its
/// key. Text to run there, as Hermes documents it; none of it can be done
/// from the phone, and nothing here installs or downloads anything.
class PlatformConnectionInstructions extends StatelessWidget {
  const PlatformConnectionInstructions({super.key});

  /// `hermes dashboard` binds to the computer itself unless told otherwise,
  /// and refuses a wider bind without a sign-in.
  static const dashboardCommand =
      'hermes dashboard --no-open --host 0.0.0.0 --port 9119';

  /// Hermes refuses to start the Gateway with a short key.
  static const keyCommand = 'openssl rand -hex 32';

  static const gatewayCommand = 'hermes gateway';

  static String gatewayEnvLines(Strings s) =>
      'API_SERVER_ENABLED=true\n'
      'API_SERVER_HOST=0.0.0.0\n'
      'API_SERVER_KEY=${s.setupStepsKeyPlaceholder}';

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final title = HermesType.title.copyWith(color: colors.textPrimary);
    final line = HermesType.text.copyWith(color: colors.textSecondary);
    Widget gap(double height) => SizedBox(height: height);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.setupStepsDashboardTitle, style: title),
        gap(HermesSpace.x2),
        Text(s.setupStepsDashboardEnv, style: line),
        gap(HermesSpace.x2),
        CommandBlock(
          dashboardPasswordEnvLines(s),
          key: const ValueKey('setup-step-dashboard-env'),
        ),
        gap(HermesSpace.x3),
        Text(s.setupStepsDashboardRun, style: line),
        gap(HermesSpace.x2),
        const CommandBlock(
          dashboardCommand,
          key: ValueKey('setup-step-dashboard-run'),
        ),
        gap(HermesSpace.x6),
        Text(s.setupStepsGatewayTitle, style: title),
        gap(HermesSpace.x2),
        Text(s.setupStepsGatewayKey, style: line),
        gap(HermesSpace.x2),
        const CommandBlock(keyCommand, key: ValueKey('setup-step-key')),
        gap(HermesSpace.x3),
        Text(s.setupStepsGatewayEnv, style: line),
        gap(HermesSpace.x2),
        CommandBlock(
          gatewayEnvLines(s),
          key: const ValueKey('setup-step-gateway-env'),
        ),
        gap(HermesSpace.x3),
        Text(s.setupStepsGatewayRun, style: line),
        gap(HermesSpace.x2),
        const CommandBlock(
          gatewayCommand,
          key: ValueKey('setup-step-gateway-run'),
        ),
        gap(HermesSpace.x4),
        Text(s.setupStepsPrivateOnly, style: line),
      ],
    );
  }
}
