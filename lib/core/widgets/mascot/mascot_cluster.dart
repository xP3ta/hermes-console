import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'mascot_identity.dart';
import 'mascot_sprite.dart';
import 'mascot_state.dart';

/// One bot of a room, as the header shows it.
@immutable
final class MascotClusterMember {
  const MascotClusterMember({
    required this.name,
    required this.identity,
    this.state = MascotState.idle,
  });

  final String name;
  final MascotIdentity identity;
  final MascotState state;
}

/// A room's mascots on the pill: up to [maxVisible] overlapping faces and a
/// `+N` chip for the rest. The first member is drawn in front (callers put
/// the bot that is replying first). One label covers the whole cluster.
class MascotCluster extends StatelessWidget {
  const MascotCluster({
    super.key,
    required this.members,
    this.size = MascotSprite.medium,
    this.locked,
  });

  static const int maxVisible = 3;

  /// Horizontal step between two faces, as a fraction of [size].
  static const double overlap = 0.62;

  final List<MascotClusterMember> members;
  final double size;
  final ValueListenable<bool>? locked;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    final strings = Strings.of(context);
    final shown = members.take(maxVisible).toList(growable: false);
    final extra = members.length - shown.length;
    final step = size * overlap;
    final facesWidth = size + step * (shown.length - 1);
    final colors = Theme.of(context).hermes;
    final chip = size * 0.62;
    final label = extra > 0
        ? strings.mascotClusterMore(shown.map((m) => m.name).join(', '), extra)
        : shown
              .map((m) => MascotSprite.semanticLabel(strings, m.state, m.name))
              .join(', ');
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: facesWidth,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Painted back to front so the first member is on top.
                for (var i = shown.length - 1; i >= 0; i--)
                  Positioned(
                    left: step * i,
                    bottom: 0,
                    child: MascotSprite(
                      key: ValueKey('mascot-cluster-$i'),
                      state: shown[i].state,
                      identity: shown[i].identity,
                      name: shown[i].name,
                      size: size,
                      locked: locked,
                      excludeSemantics: true,
                    ),
                  ),
              ],
            ),
          ),
          if (extra > 0)
            Padding(
              padding: EdgeInsets.only(left: size * 0.08),
              child: Container(
                key: const ValueKey('mascot-cluster-more'),
                height: chip,
                constraints: BoxConstraints(minWidth: chip),
                padding: EdgeInsets.symmetric(horizontal: chip * 0.22),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(chip / 2),
                  border: Border.all(color: colors.divider),
                ),
                child: Text(
                  '+$extra',
                  maxLines: 1,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: chip * 0.5,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
