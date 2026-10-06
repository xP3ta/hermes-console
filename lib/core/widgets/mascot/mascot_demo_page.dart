import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'mascot_cluster.dart';
import 'mascot_identity.dart';
import 'mascot_sprite.dart';
import 'mascot_state.dart';

/// Demo of the mascot engine for the header integration: every state at
/// the three sizes, the sprites and a room cluster. Not routed in the app;
/// mount it from a debug entry or a widget test.
class MascotDemoPage extends StatefulWidget {
  const MascotDemoPage({super.key});

  @override
  State<MascotDemoPage> createState() => _MascotDemoPageState();
}

class _MascotDemoPageState extends State<MascotDemoPage> {
  MascotState _state = MascotState.idle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: AppBar(title: const Text('Mascot')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final state in MascotState.values)
                ChoiceChip(
                  label: Text(state.name),
                  selected: state == _state,
                  onSelected: (_) => setState(() => _state = state),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final size in const [
                MascotSprite.small,
                MascotSprite.medium,
                MascotSprite.large,
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 24),
                  child: MascotSprite(state: _state, size: size),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              for (final kind in MascotSpriteKind.values)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: MascotSprite(
                    state: _state,
                    size: MascotSprite.large,
                    name: kind.name,
                    identity: MascotIdentity.forProfile(
                      kind.name,
                      sprite: kind,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          // The pill the header will host: the mascot sits on its top edge.
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MascotCluster(
                  members: [
                    MascotClusterMember(
                      name: 'Forja',
                      identity: MascotIdentity.forProfile('forja'),
                      state: _state,
                    ),
                    MascotClusterMember(
                      name: 'Radar',
                      identity: MascotIdentity.forProfile('radar'),
                    ),
                    MascotClusterMember(
                      name: 'Lira',
                      identity: MascotIdentity.forProfile('lira'),
                    ),
                    MascotClusterMember(
                      name: 'Nube',
                      identity: MascotIdentity.forProfile('nube'),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _state.name,
                    style: TextStyle(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
