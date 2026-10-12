import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/clipboard_image_source.dart';

/// The composer's long-press text menu: the platform's own items (Paste for
/// text is unchanged) plus "Paste image" when the system clipboard holds an
/// image. The image goes to [onContentInserted], the same path keyboard
/// images take, so every composer applies one set of limits.
class ComposerClipboardMenu extends StatefulWidget {
  const ComposerClipboardMenu({
    super.key,
    required this.editableTextState,
    required this.onContentInserted,
  });

  final EditableTextState editableTextState;
  final ValueChanged<KeyboardInsertedContent> onContentInserted;

  @override
  State<ComposerClipboardMenu> createState() => _ComposerClipboardMenuState();
}

class _ComposerClipboardMenuState extends State<ComposerClipboardMenu> {
  bool _hasImage = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final hasImage = await ClipboardImageSource.hasImage();
    if (mounted && hasImage != _hasImage) {
      setState(() => _hasImage = hasImage);
    }
  }

  Future<void> _pasteImage() async {
    final onContentInserted = widget.onContentInserted;
    widget.editableTextState.hideToolbar();
    final content = await ClipboardImageSource.readImage();
    if (content != null) onContentInserted(content);
  }

  @override
  Widget build(BuildContext context) {
    final items = List<ContextMenuButtonItem>.of(
      widget.editableTextState.contextMenuButtonItems,
    );
    if (_hasImage) {
      final paste = items.indexWhere(
        (item) => item.type == ContextMenuButtonType.paste,
      );
      // Right after the text Paste (or first): on Android a fourth item
      // falls into the overflow, so keep it near the front.
      items.insert(
        paste < 0 ? 0 : paste + 1,
        ContextMenuButtonItem(
          label: Strings.of(context).cmp1215PasteImage,
          onPressed: () => unawaited(_pasteImage()),
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: widget.editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }
}
