import 'package:flutter/material.dart';

/// Frontera estable de selección para un único mensaje terminado.
///
/// `MarkdownBody(selectable: true)` convierte cada bloque en un `EditableText`.
/// En una lista invertida Android intenta entonces hacer `bringIntoView` al
/// mostrar el menú y desplaza el mensaje bajo el dedo. Una región por mensaje
/// mantiene el Markdown como `Text.rich`, permite selección parcial y no toca el
/// scroll. Al deshabilitar la región se limpia la selección de forma explícita;
/// durante el desmontaje se deja que Flutter retire primero el Overlay y se
/// conserva una limpieza final defensiva en [dispose].
class ChatMessageSelectionArea extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Object? selectionIdentity;

  /// Adds the [ChatAskAboutScope] action to the selection menu (assistant
  /// answers and their tool output; never the user's own messages).
  final bool askable;

  const ChatMessageSelectionArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.selectionIdentity,
    this.askable = false,
  });

  @override
  State<ChatMessageSelectionArea> createState() =>
      _ChatMessageSelectionAreaState();
}

class _ChatMessageSelectionAreaState extends State<ChatMessageSelectionArea> {
  final GlobalKey<SelectionAreaState> _selectionAreaKey =
      GlobalKey<SelectionAreaState>();
  String _selectedText = '';

  void _clearSelection() {
    final area = _selectionAreaKey.currentState;
    if (area == null) return;
    final region = area.selectableRegion;
    region.hideToolbar();
    region.clearSelection();
  }

  @override
  void didUpdateWidget(ChatMessageSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.enabled && !widget.enabled) ||
        oldWidget.selectionIdentity != widget.selectionIdentity) {
      _clearSelection();
    }
  }

  @override
  void dispose() {
    _clearSelection();
    super.dispose();
  }

  Widget _askMenu(
    BuildContext context,
    SelectableRegionState region,
    ChatAskAboutScope scope,
    ValueChanged<String> onAsk,
  ) {
    final ask = ContextMenuButtonItem(
      label: scope.label,
      onPressed: () {
        // Read at tap time: the menu can be built before the region reports
        // the selection that opened it.
        final selected = _selectedText;
        region.hideToolbar();
        region.clearSelection();
        if (selected.trim().isNotEmpty) onAsk(selected);
      },
    );
    // Copy / Share / Select all stay; the new action goes right after Copy
    // so the phone's narrow toolbar keeps it visible instead of in "More".
    final items = [...region.contextMenuButtonItems];
    final copy = items.indexWhere(
      (item) => item.type == ContextMenuButtonType.copy,
    );
    items.insert(copy < 0 ? 0 : copy + 1, ask);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final scope = widget.askable ? ChatAskAboutScope.maybeOf(context) : null;
    final onAsk = scope?.onAsk;
    if (scope == null || onAsk == null) {
      return SelectionArea(
        key: _selectionAreaKey,
        magnifierConfiguration: TextMagnifierConfiguration.disabled,
        child: widget.child,
      );
    }
    return SelectionArea(
      key: _selectionAreaKey,
      magnifierConfiguration: TextMagnifierConfiguration.disabled,
      onSelectionChanged: (content) => _selectedText = content?.plainText ?? '',
      contextMenuBuilder: (context, region) =>
          _askMenu(context, region, scope, onAsk),
      child: widget.child,
    );
  }
}

/// Hands "Ask about this" to every askable [ChatMessageSelectionArea] below:
/// the chat screen puts the quoted selection into its composer. Pass a stable
/// callback (a method tear-off): a new closure per build would rebuild every
/// message. A null [onAsk] (read-only chat) hides the action.
class ChatAskAboutScope extends InheritedWidget {
  const ChatAskAboutScope({
    super.key,
    required this.label,
    required this.onAsk,
    required super.child,
  });

  final String label;
  final ValueChanged<String>? onAsk;

  static ChatAskAboutScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatAskAboutScope>();

  @override
  bool updateShouldNotify(ChatAskAboutScope oldWidget) =>
      oldWidget.label != label || oldWidget.onAsk != onAsk;
}
