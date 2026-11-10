// Installing a plugin from a source the person types (owner/repo or an HTTPS
// Git URL): the form, the unconditional confirmation and the App Lock check.
//
// The identifier is validated on the phone before it can leave it
// ([isSafePluginInstallIdentifier]); the server's own installer does the work.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesSpace,
        showHermesDialog;
import '../models/desktop_control_center.dart';
import '../screens/lock_screen.dart';
import '../services/desktop_control_gateway.dart'
    show isSafePluginInstallIdentifier;
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart' show showHermesFloatingSurface;
import '../widgets/hermes_ui.dart' show HermesSwitchTile;
import 'spp_safety.dart' show sppSafeTarget;

/// Sends the install request of [identifier] to the server.
typedef PluginSourceInstaller =
    Future<DesktopExtensionInstallResult> Function(
      String identifier, {
      required bool enable,
    });

class PluginInstallDraft {
  final String identifier;
  final bool enableAfterInstall;

  const PluginInstallDraft({
    required this.identifier,
    required this.enableAfterInstall,
  });
}

/// Asks for the source, confirms and installs. Returns null when the person
/// stopped (closed the form, declined the confirmation or the lock); a failure
/// of the request propagates to the caller.
Future<DesktopExtensionInstallResult?> installPluginFromSource(
  BuildContext context, {
  required PluginSourceInstaller install,
}) async {
  final draft = await showHermesFloatingSurface<PluginInstallDraft>(
    context: context,
    surfaceKey: const ValueKey('extensions-plugin-install-surface'),
    maxWidth: 520,
    builder: (_) => const PluginSourceInstallSheet(),
  );
  if (draft == null || !context.mounted) return null;
  final strings = Strings.of(context);
  // Installing code is always asked for, whatever the approval mode says.
  final approved = await showHermesDialog<bool>(
    context: context,
    title: strings.extensionsCenterPluginInstallConfirmTitle,
    message: strings.extensionsCenterPluginInstallConfirmBody(
      sppSafeTarget(draft.identifier),
    ),
    actions: [
      HermesDialogAction(
        label: strings.commonCancel,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(
        label: strings.extensionsCenterPluginInstallAction,
        value: true,
        style: HermesDialogActionStyle.primary,
      ),
    ],
  );
  if (approved != true || !context.mounted) return null;
  final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
  if (lock != null) {
    final unlocked = await LockScreen.verify(
      context,
      lock,
      reason: strings.extensionsCenterPluginInstallConfirmTitle,
    );
    if (!unlocked) return null;
  }
  return install(draft.identifier, enable: draft.enableAfterInstall);
}

class PluginSourceInstallSheet extends StatefulWidget {
  const PluginSourceInstallSheet({super.key});

  @override
  State<PluginSourceInstallSheet> createState() =>
      _PluginSourceInstallSheetState();
}

class _PluginSourceInstallSheetState extends State<PluginSourceInstallSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _enable = false;
  bool _showError = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final identifier = _controller.text.trim();
    if (!isSafePluginInstallIdentifier(identifier)) {
      setState(() => _showError = true);
      return;
    }
    Navigator.pop(
      context,
      PluginInstallDraft(identifier: identifier, enableAfterInstall: _enable),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(HermesSpace.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            strings.extensionsCenterPluginInstallTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: HermesSpace.x2),
          Text(
            strings.extensionsCenterPluginInstallRisk,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: HermesSpace.x5),
          TextField(
            key: const ValueKey('extensions-plugin-identifier'),
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_showError) setState(() => _showError = false);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: strings.extensionsCenterPluginIdentifierLabel,
              hintText: strings.extensionsCenterPluginIdentifierHint,
              errorText: _showError
                  ? strings.extensionsCenterPluginIdentifierInvalid
                  : null,
            ),
          ),
          const SizedBox(height: HermesSpace.x3),
          HermesSwitchTile(
            contentPadding: EdgeInsets.zero,
            title: strings.extensionsCenterPluginEnableAfterInstall,
            value: _enable,
            onChanged: (value) => setState(() => _enable = value),
          ),
          const SizedBox(height: HermesSpace.x3),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.arrow_forward_rounded, size: 19),
            label: Text(strings.extensionsCenterPluginReviewAction),
          ),
        ],
      ),
    );
  }
}
