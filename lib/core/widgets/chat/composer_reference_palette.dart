import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/composer_reference.dart';
import '../../theme/app_theme.dart';

/// `@` reference palette: files, folders and the `@file:`/`@folder:`/`@url:`
/// starters `complete.path` offers for the token under the caret. Appears only
/// while such a token is being typed and the server answered with rows.
class ComposerReferencePalette extends StatelessWidget {
  final List<PathCompletionItem> items;
  final ValueChanged<PathCompletionItem> onPick;
  final ValueChanged<PathCompletionItem> onDescend;

  const ComposerReferencePalette({
    super.key,
    required this.items,
    required this.onPick,
    required this.onDescend,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Semantics(
      label: s.t1215RefPaletteLabel,
      child: Container(
        key: const ValueKey('chat-reference-palette'),
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        constraints: const BoxConstraints(maxHeight: 224),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.divider.withValues(alpha: 0.72)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 22,
              offset: const Offset(0, 9),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Material(
            color: Colors.transparent,
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: items.length,
              itemBuilder: (context, index) =>
                  _row(context, colors, s, items[index]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    HermesThemeColors colors,
    Strings s,
    PathCompletionItem item,
  ) {
    final icon = switch (item.kind) {
      ComposerReferenceKind.file => Icons.description_outlined,
      ComposerReferenceKind.folder => Icons.folder_outlined,
      ComposerReferenceKind.url => Icons.link_rounded,
    };
    final title = item.isStarter ? '@${item.kind.name}:' : item.display;
    final subtitle = item.isStarter
        ? switch (item.kind) {
            ComposerReferenceKind.file => s.t1215RefStarterFile,
            ComposerReferenceKind.folder => s.t1215RefStarterFolder,
            ComposerReferenceKind.url => s.t1215RefStarterUrl,
          }
        : (item.meta == 'dir' ? '' : item.meta);
    final canDescend =
        item.kind == ComposerReferenceKind.folder && !item.isStarter;
    return InkWell(
      key: ValueKey('chat-reference-${item.rawText}'),
      canRequestFocus: false,
      onTap: () => onPick(item),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 4, 6),
        child: Row(
          children: [
            Icon(icon, size: 18, color: colors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        height: 1.2,
                      ),
                    ),
                ],
              ),
            ),
            if (canDescend)
              IconButton(
                key: ValueKey('chat-reference-open-${item.rawText}'),
                tooltip: s.t1215RefOpenFolder,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.chevron_right_rounded,
                  color: colors.textSecondary,
                ),
                onPressed: () => onDescend(item),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
