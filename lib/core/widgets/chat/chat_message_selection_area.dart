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

  const ChatMessageSelectionArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.selectionIdentity,
  });

  @override
  State<ChatMessageSelectionArea> createState() =>
      _ChatMessageSelectionAreaState();
}

class _ChatMessageSelectionAreaState extends State<ChatMessageSelectionArea> {
  final GlobalKey<SelectionAreaState> _selectionAreaKey =
      GlobalKey<SelectionAreaState>();

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

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return SelectionArea(
      key: _selectionAreaKey,
      magnifierConfiguration: TextMagnifierConfiguration.disabled,
      child: widget.child,
    );
  }
}
