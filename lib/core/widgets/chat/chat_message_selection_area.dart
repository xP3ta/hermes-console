import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../hermes_notice.dart';
import 'quick_reaction_bar.dart';
import '../../feedback/haptics.dart';

/// Which messages of a chat hold a text selection right now. A plain object
/// the chat screen owns and reads at the moment it would move the list on its
/// own (follow the tail, land at the bottom): a reader holding text is not
/// carried away from it. It never notifies and never rebuilds anything.
class ChatSelectionHold {
  final Set<Object> _holders = Set<Object>.identity();

  /// A selection is held in some message of this chat.
  bool get active => _holders.isNotEmpty;

  void set(Object holder, {required bool holding}) {
    if (holding) {
      _holders.add(holder);
    } else {
      _holders.remove(holder);
    }
  }
}

/// Gives the messages below it the chat's [ChatSelectionHold].
class ChatSelectionHoldScope extends InheritedWidget {
  const ChatSelectionHoldScope({
    super.key,
    required this.hold,
    required super.child,
  });

  final ChatSelectionHold hold;

  static ChatSelectionHold? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatSelectionHoldScope>()?.hold;

  @override
  bool updateShouldNotify(ChatSelectionHoldScope oldWidget) => false;
}

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
  ChatSelectionHold? _hold;

  void _report(String text) {
    _selectedText = text;
    // Never a setState: the hold is read when the list is about to move.
    _hold?.set(this, holding: _selectedText.isNotEmpty);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hold = ChatSelectionHoldScope.maybeOf(context);
    if (!identical(hold, _hold)) {
      _hold?.set(this, holding: false);
      _hold = hold;
      _hold?.set(this, holding: _selectedText.isNotEmpty);
    }
  }

  void _clearSelection() {
    _selectedText = '';
    _hold?.set(this, holding: false);
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
    _hold?.set(this, holding: false);
    super.dispose();
  }

  /// rr1215: with quick reactions, a long-press opens the message surface
  /// (reactions on top of the actions) instead of starting a selection, so
  /// no handles or selection toolbar ever show under the reactions. Text
  /// selection starts from «Select text» (or a double-tap, as before).
  Future<void> _openActions(Offset press) async {
    final scope = MessageQuickReactScope.maybeOf(context);
    final box = context.findRenderObject();
    if (scope == null || box is! RenderBox || !box.hasSize) return;
    _clearSelection();
    HermesHaptics.selection();
    final choice = await showMessageActions(
      context: context,
      message: box.localToGlobal(Offset.zero) & box.size,
      press: press,
      scope: scope,
    );
    if (!mounted) return;
    switch (choice) {
      case null:
        return;
      case MessageReactChoice(:final emoji):
        scope.onReact?.call(emoji);
      case MessageActionKindChoice(kind: MessageActionKind.copy):
        final text = scope.copyText?.call() ?? '';
        unawaited(Clipboard.setData(ClipboardData(text: text)));
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaCopied),
            duration: const Duration(seconds: 1),
          ),
          kind: HermesNoticeKind.success,
        );
      case MessageActionKindChoice(kind: MessageActionKind.reply):
        scope.onReply?.call();
      case MessageActionKindChoice(kind: MessageActionKind.select):
        _selectWholeMessage();
    }
  }

  /// Selects the whole message with handles and the selection toolbar.
  void _selectWholeMessage() => _selectionAreaKey.currentState?.selectableRegion
      .selectAll(SelectionChangedCause.toolbar);

  List<ContextMenuButtonItem> _items(
    SelectableRegionState region,
    ChatAskAboutScope? scope,
    ValueChanged<String>? onAsk,
  ) {
    final items = [...region.contextMenuButtonItems];
    if (scope == null || onAsk == null) return items;
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
    final copy = items.indexWhere(
      (item) => item.type == ContextMenuButtonType.copy,
    );
    items.insert(copy < 0 ? 0 : copy + 1, ask);
    return items;
  }

  Widget _menu(
    BuildContext context,
    SelectableRegionState region,
    ChatAskAboutScope? scope,
    ValueChanged<String>? onAsk,
  ) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: region.contextMenuAnchors,
    buttonItems: _items(region, scope, onAsk),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final scope = widget.askable ? ChatAskAboutScope.maybeOf(context) : null;
    final onAsk = scope?.onAsk;
    final react = MessageQuickReactScope.maybeOf(context);
    // Always the same tree shape (the gesture layer stays mounted with or
    // without reactions), so toggling reactions never remounts the message.
    // Being deeper than the region's own long-press, it wins the gesture.
    final child = GestureDetector(
      onLongPressStart: react == null
          ? null
          : (details) => unawaited(_openActions(details.globalPosition)),
      child: widget.child,
    );
    final ask = scope != null && onAsk != null;
    return SelectionArea(
      key: _selectionAreaKey,
      magnifierConfiguration: TextMagnifierConfiguration.disabled,
      onSelectionChanged: (content) => _report(content?.plainText ?? ''),
      contextMenuBuilder: ask
          ? (context, region) => _menu(context, region, scope, onAsk)
          : _defaultMenu,
      child: child,
    );
  }

  static Widget _defaultMenu(
    BuildContext context,
    SelectableRegionState region,
  ) => AdaptiveTextSelectionToolbar.selectableRegion(
    selectableRegionState: region,
  );
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
