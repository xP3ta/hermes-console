import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../mascot_identity.dart';
import '../mascot_sprite.dart';
import '../mascot_state.dart';
import 'mascot_prefs.dart';

/// Ajustes → Mascota: on/off, placement and sprite. Everything is stored
/// on this device ([MascotPrefs]).
class MascotSettingsScreen extends StatefulWidget {
  const MascotSettingsScreen({this.prefs, super.key});

  final MascotPrefs? prefs;

  @override
  State<MascotSettingsScreen> createState() => _MascotSettingsScreenState();
}

class _MascotSettingsScreenState extends State<MascotSettingsScreen> {
  MascotPrefs get _prefs => widget.prefs ?? MascotPrefs.instance;

  @override
  void initState() {
    super.initState();
    _prefs.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: AppBar(title: Text(strings.mascotSettingsTitle)),
      body: ListenableBuilder(
        listenable: _prefs,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            SwitchListTile(
              key: const ValueKey('mascot-settings-enabled'),
              title: Text(strings.mascotSettingsEnabled),
              subtitle: Text(strings.mascotSettingsEnabledHint),
              value: _prefs.enabled,
              onChanged: (value) => _prefs.setEnabled(value),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                strings.mascotSettingsPlacement,
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<MascotPlacement>(
                key: const ValueKey('mascot-settings-placement'),
                segments: [
                  ButtonSegment(
                    value: MascotPlacement.dock,
                    label: Text(strings.mascotPlacementDock),
                  ),
                  ButtonSegment(
                    value: MascotPlacement.float,
                    label: Text(strings.mascotPlacementFloat),
                  ),
                ],
                selected: {_prefs.placement},
                onSelectionChanged: _prefs.enabled
                    ? (value) => _prefs.setPlacement(value.single)
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                strings.mascotSettingsSprite,
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const ValueKey('mascot-settings-sprite-auto'),
                    label: Text(strings.mascotSettingsSpriteAuto),
                    selected: _prefs.sprite == null,
                    onSelected: (_) => _prefs.setSprite(null),
                  ),
                  for (final kind in MascotSpriteKind.values)
                    ChoiceChip(
                      key: ValueKey('mascot-settings-sprite-${kind.name}'),
                      avatar: MascotSprite(
                        state: MascotState.idle,
                        size: MascotSprite.small,
                        identity: MascotIdentity(
                          sprite: kind,
                          color: MascotIdentity.hermes.color,
                        ),
                        excludeSemantics: true,
                      ),
                      label: Text(
                        kind.name[0].toUpperCase() + kind.name.substring(1),
                      ),
                      selected: _prefs.sprite == kind,
                      onSelected: (_) => _prefs.setSprite(kind),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
