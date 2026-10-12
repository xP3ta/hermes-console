import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'hermes_premium_ui.dart';
import 'menu_back_guard.dart';

enum AttachmentSourceChoice { camera, photos, files }

/// Menú de fuentes anclado al mismo botón `+` que lo abre.
///
/// [MenuAnchor] reposiciona la superficie dentro del viewport y conserva
/// navegación por teclado/TalkBack. El contrato se mantiene deliberadamente
/// cerrado a las tres fuentes de adjuntos reales.
class AttachmentSourceMenuButton extends StatelessWidget {
  const AttachmentSourceMenuButton({
    required this.semanticLabel,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final String semanticLabel;
  final ValueChanged<AttachmentSourceChoice> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    MenuItemButton item({
      required AttachmentSourceChoice source,
      required IconData icon,
      required String label,
    }) {
      return MenuItemButton(
        leadingIcon: Icon(icon, size: 21, color: colors.textSecondary),
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(184, 48)),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
        onPressed: () {
          HapticFeedback.selectionClick();
          onSelected(source);
        },
        child: Text(
          label,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    // Back closes the open menu only, never the chat underneath.
    return MenuBackGuard(
      builder: (context, menuController, onOpen, onClose) => MenuAnchor(
        controller: menuController,
        onOpen: onOpen,
        onClose: onClose,
        animated: !reduceMotion,
        crossAxisUnconstrained: false,
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: colors.divider.withValues(alpha: 0.72)),
            ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 6),
          ),
        ),
        menuChildren: [
          item(
            source: AttachmentSourceChoice.camera,
            icon: Icons.photo_camera_outlined,
            label: strings.chatAttachCamera,
          ),
          item(
            source: AttachmentSourceChoice.photos,
            icon: Icons.photo_library_outlined,
            label: strings.chatAttachPhotos,
          ),
          item(
            source: AttachmentSourceChoice.files,
            icon: Icons.attach_file_rounded,
            label: strings.chatAttachFiles,
          ),
        ],
        builder: (context, controller, child) {
          return HermesTactileAction(
            icon: Icons.add_rounded,
            iconSize: 23,
            semanticLabel: semanticLabel,
            onPressed: !enabled
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
            foregroundColor: colors.textPrimary,
            enabled: enabled,
            size: 38,
            visual: HermesTactileActionVisual.quiet,
          );
        },
      ),
    );
  }
}
