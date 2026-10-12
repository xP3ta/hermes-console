import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/hermes_design.dart';
import '../../widgets/platform_setup_commands.dart';

/// The documented way to prepare the computer by hand, for whoever connects
/// manually: Hermes' own commands, none of them run from the phone.
class ManualSetupPage extends StatelessWidget {
  const ManualSetupPage({super.key});

  @override
  Widget build(BuildContext context) => HermesPage(
    title: Strings.of(context).o2SetupByHand,
    children: const [PlatformConnectionInstructions()],
  );
}
