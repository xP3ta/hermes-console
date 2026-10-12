import 'dart:math';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../models/bot_visual_identity.dart';
import '../theme/app_theme.dart';
import 'hermes_bot_face.dart';
import 'hermes_ui.dart' show HermesSectionHeader;

/// One colour control for both face families. A null colour preserves the
/// original seed palette until the owner picks a swatch.
class BotFaceOptions extends StatelessWidget {
  final String name;
  final String keyPrefix;
  final BlobatarShapeWire blob;
  final ClassicFaceIdentity? classic;
  final String? colorHex;
  final String fallbackColorHex;
  final ValueChanged<BlobatarShapeWire> onBlob;
  final ValueChanged<ClassicFaceIdentity> onClassic;
  final ValueChanged<String> onColor;
  final bool enabled;

  const BotFaceOptions({
    super.key,
    required this.name,
    required this.keyPrefix,
    required this.blob,
    required this.classic,
    required this.colorHex,
    required this.onBlob,
    required this.onClassic,
    required this.onColor,
    this.fallbackColorHex = '#8b5cf6',
    this.enabled = true,
  });

  String _silhouetteLabel(String? kind, Strings s) => switch (kind) {
    'round' => s.botSilhouetteRound,
    'organic' => s.botSilhouetteOrganic,
    'boxy' => s.botSilhouetteBoxy,
    'capsule' => s.botSilhouetteCapsule,
    'nub' => s.botSilhouetteNub,
    'cloud' => s.botSilhouetteCloud,
    'droplet' => s.botSilhouetteDroplet,
    'hexagon' => s.botSilhouetteHexagon,
    'sun' => s.botSilhouetteSun,
    'triangle' => s.botSilhouetteTriangle,
    _ => s.botSilhouetteAutomatic,
  };

  Widget _choice(
    BuildContext context, {
    required Key key,
    required String label,
    required bool selected,
    required Widget child,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).hermes;
    return Tooltip(
      message: label,
      child: Semantics(
        selected: selected,
        button: true,
        enabled: enabled,
        label: label,
        child: InkWell(
          key: key,
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(HermesRadius.control),
          child: Container(
            width: HermesSpace.tap,
            height: HermesSpace.tap,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HermesRadius.control),
              border: Border.all(
                color: selected ? colors.accent : colors.divider,
                width: selected ? 1.8 : 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final selectedColor = classic?.colorHex ?? colorHex;
    final geometricColor = selectedColor ?? fallbackColorHex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            TextButton.icon(
              key: const ValueKey('bot-face-random'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: !enabled
                  ? null
                  : () => onBlob(
                      blob.withSeed(
                        Random.secure().nextInt(1 << 30).toRadixString(36),
                      ),
                    ),
              icon: const Icon(Icons.shuffle),
              label: Text(s.botFaceRandom),
            ),
            if (classic == null)
              TextButton.icon(
                key: const ValueKey('bot-face-lock'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: !enabled
                    ? null
                    : () => onBlob(
                        blob.withSeed(blob.followsProfileName ? name : ''),
                      ),
                icon: Icon(
                  blob.followsProfileName
                      ? Icons.lock_open
                      : Icons.lock_outline,
                ),
                label: Text(
                  blob.followsProfileName ? s.botFaceLock : s.botFaceUnlock,
                ),
              ),
          ],
        ),
        HermesSectionHeader(s.botClassicFace),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final shape in ClassicFaceIdentity.shapes)
              _choice(
                context,
                key: ValueKey('bot-face-classic-$shape'),
                label:
                    '${s.botClassicFace} ${ClassicFaceIdentity.shapes.toList().indexOf(shape) + 1}',
                selected: classic?.shape == shape,
                onTap: () => onClassic(
                  ClassicFaceIdentity(shape: shape, colorHex: geometricColor),
                ),
                child: HermesBotFace(
                  size: 40,
                  visual: HermesClassicFaceVisual.tryParse(
                    shape: shape,
                    colorHex: geometricColor,
                  )!,
                ),
              ),
          ],
        ),
        HermesSectionHeader(s.botFaceSilhouette),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final kind in <String?>[null, ...BlobatarShapeWire.kinds])
              _choice(
                context,
                key: ValueKey('$keyPrefix-blobatar-${kind ?? 'auto'}'),
                label: _silhouetteLabel(kind, s),
                selected: classic == null && blob.kind == kind,
                onTap: () => onBlob(blob.withKind(kind)),
                child: HermesBotFace(
                  size: 40,
                  visual: HermesBlobatarFaceVisual.tryParse(
                    shapeWire: blob.withKind(kind).wire,
                    profileName: name,
                    colorHex: selectedColor,
                  )!,
                ),
              ),
          ],
        ),
        HermesSectionHeader(s.botFaceColor),
        Wrap(
          key: const ValueKey('bot-face-color-palette'),
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final color in ClassicFaceIdentity.colors)
              Tooltip(
                message:
                    '${s.botFaceColor} ${ClassicFaceIdentity.colors.toList().indexOf(color) + 1}',
                child: Semantics(
                  button: true,
                  selected: selectedColor == color,
                  enabled: enabled,
                  child: InkWell(
                    key: ValueKey('bot-face-color-$color'),
                    onTap: enabled ? () => onColor(color) : null,
                    borderRadius: BorderRadius.circular(HermesRadius.tag),
                    child: SizedBox.square(
                      dimension: HermesSpace.tap,
                      child: Center(
                        child: Container(
                          width: 36,
                          height: 36,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selectedColor == color
                                  ? colors.accent
                                  : colors.divider,
                              width: selectedColor == color ? 2 : 1,
                            ),
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(
                                0xff000000 |
                                    int.parse(color.substring(1), radix: 16),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
