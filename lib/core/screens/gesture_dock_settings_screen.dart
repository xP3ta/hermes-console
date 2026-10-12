import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../shell/dock_edit_sheet.dart';
import '../shell/gesture_dock_state.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart';

/// Ajustes › Dock: glass or solid, hiding it by hand and the edit mode.
/// Whether the app uses a dock at all is "Usar dock flotante", one level
/// up.
class GestureDockSettingsScreen extends StatelessWidget {
  final GestureDockController? controller;

  const GestureDockSettingsScreen({this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    final c = controller ?? GestureDockController.instance;
    unawaited(c.ensureLoaded());
    final strings = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(title: Text(strings.gdSettingsTitle)),
      body: ListenableBuilder(
        listenable: Listenable.merge([c.settings, c.hidden]),
        builder: (context, _) => ListView(
          clipBehavior: hermesUnderHeader,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            HermesGroup(
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: HermesSwitchTile(
                    controlKey: const ValueKey('gesture-dock-opaque'),
                    title: strings.gdOpaqueTitle,
                    subtitle: strings.gdOpaqueSubtitle,
                    value: c.value.opaque,
                    onChanged: (v) => unawaited(c.setOpaque(v)),
                  ),
                ),
                // Not a stored preference: a dock hidden by hand is back on
                // the next app start, and its handle shows it at any time.
                Material(
                  type: MaterialType.transparency,
                  child: HermesSwitchTile(
                    controlKey: const ValueKey('gesture-dock-hidden'),
                    title: strings.gdHideDock,
                    value: c.hidden.value,
                    onChanged: c.setHidden,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            HermesGroup(
              children: [
                HermesNavRow(
                  key: const ValueKey('gesture-dock-edit'),
                  icon: Icons.edit_outlined,
                  title: strings.gdEditDock,
                  subtitle: strings.gdEditHint,
                  onTap: () =>
                      unawaited(showDockEditSheet(context, controller: c)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
