import 'dart:math';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../models/bot_visual_identity.dart';
import 'hermes_bot_face.dart';

class BotFaceOptions extends StatelessWidget {
  final String name;
  final BlobatarShapeWire blob;
  final ClassicFaceIdentity? classic;
  final ValueChanged<BlobatarShapeWire> onBlob;
  final ValueChanged<ClassicFaceIdentity> onClassic;
  final bool enabled;
  const BotFaceOptions({
    super.key,
    required this.name,
    required this.blob,
    required this.classic,
    required this.onBlob,
    required this.onClassic,
    this.enabled = true,
  });
  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
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
            TextButton.icon(
              onPressed: !enabled
                  ? null
                  : () => onBlob(
                      blob.withSeed(blob.followsProfileName ? name : ''),
                    ),
              icon: Icon(
                blob.followsProfileName ? Icons.lock_open : Icons.lock_outline,
              ),
              label: Text(
                blob.followsProfileName ? s.botFaceLock : s.botFaceUnlock,
              ),
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(s.botClassicFace),
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final shape in ClassicFaceIdentity.shapes)
                  IconButton(
                    tooltip:
                        '${s.botClassicFace} ${ClassicFaceIdentity.shapes.toList().indexOf(shape) + 1}',
                    onPressed: !enabled
                        ? null
                        : () => onClassic(
                            ClassicFaceIdentity(
                              shape: shape,
                              colorHex: classic?.colorHex ?? '#8b5cf6',
                            ),
                          ),
                    icon: HermesBotFace(
                      size: 32,
                      visual: HermesClassicFaceVisual.tryParse(
                        shape: shape,
                        colorHex: classic?.colorHex ?? '#8b5cf6',
                      )!,
                    ),
                  ),
              ],
            ),
            Wrap(
              spacing: 4,
              children: [
                for (final color in ClassicFaceIdentity.colors)
                  IconButton(
                    tooltip:
                        '${s.botFaceColor} ${ClassicFaceIdentity.colors.toList().indexOf(color) + 1}',
                    onPressed: !enabled
                        ? null
                        : () => onClassic(
                            ClassicFaceIdentity(
                              shape: classic?.shape ?? 'circle',
                              colorHex: color,
                            ),
                          ),
                    icon: Icon(
                      Icons.circle,
                      color: Color(
                        int.parse(color.replaceFirst('#', 'ff'), radix: 16),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
