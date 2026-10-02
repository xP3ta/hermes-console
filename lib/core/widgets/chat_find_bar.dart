import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/component_profile.dart';
import 'hermes_premium_ui.dart';

/// Estado observable de la búsqueda dentro de un chat. Inmutable: la pantalla
/// publica uno nuevo por cambio y solo la barra se repinta.
@immutable
class ChatFindStatus {
  /// Consulta ya aplicada (tras el debounce).
  final String query;

  /// Número total de coincidencias en los mensajes cargados.
  final int total;

  /// Índice 0-based de la coincidencia actual, o null si no hay.
  final int? current;

  /// Quedan mensajes anteriores sin cargar en los que podría haber resultados.
  final bool canSearchOlder;

  /// Se están paginando mensajes anteriores en busca de resultados.
  final bool searchingOlder;

  const ChatFindStatus({
    this.query = '',
    this.total = 0,
    this.current,
    this.canSearchOlder = false,
    this.searchingOlder = false,
  });

  bool get hasQuery => query.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ChatFindStatus &&
      other.query == query &&
      other.total == total &&
      other.current == current &&
      other.canSearchOlder == canSearchOlder &&
      other.searchingOlder == searchingOlder;

  @override
  int get hashCode =>
      Object.hash(query, total, current, canSearchOlder, searchingOlder);
}

/// Barra de búsqueda dentro de la conversación abierta.
///
/// La barra posee su propio campo y aplica un debounce antes de notificar la
/// consulta: escribir no reconstruye la transcripción en cada pulsación.
class ChatFindBar extends StatefulWidget {
  final ValueListenable<ChatFindStatus> status;
  final ValueChanged<String> onQueryChanged;

  /// Sube por el historial (coincidencia más antigua).
  final VoidCallback onOlder;

  /// Baja por el historial (coincidencia más reciente).
  final VoidCallback onNewer;
  final VoidCallback onSearchOlderMessages;
  final VoidCallback onClose;
  final String initialQuery;
  final Duration debounce;

  const ChatFindBar({
    required this.status,
    required this.onQueryChanged,
    required this.onOlder,
    required this.onNewer,
    required this.onSearchOlderMessages,
    required this.onClose,
    this.initialQuery = '',
    this.debounce = const Duration(milliseconds: 150),
    super.key,
  });

  @override
  State<ChatFindBar> createState() => _ChatFindBarState();
}

class _ChatFindBarState extends State<ChatFindBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      widget.onQueryChanged(value);
      return;
    }
    _debounce = Timer(widget.debounce, () {
      if (mounted) widget.onQueryChanged(value);
    });
  }

  void _onSubmitted(String value) {
    _debounce?.cancel();
    final status = widget.status.value;
    if (status.query != value) {
      widget.onQueryChanged(value);
    } else if (status.total > 0) {
      widget.onOlder();
    }
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final str = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Material(
        key: const ValueKey('chat-find-bar'),
        color: colors.background,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: ValueListenableBuilder<ChatFindStatus>(
            valueListenable: widget.status,
            builder: (context, status, _) {
              final hasMatches = status.total > 0 && status.current != null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          textField: true,
                          label: str.cs1215FindHint,
                          child: HermesSearchField(
                            key: const ValueKey('chat-find-field'),
                            controller: _controller,
                            focusNode: _focusNode,
                            autofocus: true,
                            hintText: str.cs1215FindHint,
                            clearTooltip: str.cs1215FindClear,
                            onChanged: _onChanged,
                            onSubmitted: _onSubmitted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (status.hasQuery)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            hasMatches
                                ? str.cs1215MatchCounter(
                                    status.current! + 1,
                                    status.total,
                                  )
                                : str.cs1215NoMatches,
                            key: const ValueKey('chat-find-counter'),
                            style: TextStyle(
                              color: hasMatches
                                  ? colors.textSecondary
                                  : colors.textDisabled,
                              fontSize: 12.5,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      IconButton(
                        key: const ValueKey('chat-find-older'),
                        tooltip: str.cs1215OlderMatch,
                        constraints: const BoxConstraints(
                          minWidth: componentMinimumTapTarget,
                          minHeight: componentMinimumTapTarget,
                        ),
                        onPressed: status.total > 1 ? widget.onOlder : null,
                        icon: const Icon(Icons.keyboard_arrow_up_rounded),
                      ),
                      IconButton(
                        key: const ValueKey('chat-find-newer'),
                        tooltip: str.cs1215NewerMatch,
                        constraints: const BoxConstraints(
                          minWidth: componentMinimumTapTarget,
                          minHeight: componentMinimumTapTarget,
                        ),
                        onPressed: status.total > 1 ? widget.onNewer : null,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                      IconButton(
                        key: const ValueKey('chat-find-close'),
                        tooltip: str.cs1215CloseFind,
                        constraints: const BoxConstraints(
                          minWidth: componentMinimumTapTarget,
                          minHeight: componentMinimumTapTarget,
                        ),
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  if (status.hasQuery && status.total == 0)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: status.searchingOlder
                          ? Padding(
                              key: const ValueKey('chat-find-searching-older'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 12,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    str.cs1215SearchingOlder,
                                    style: TextStyle(
                                      color: colors.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : status.canSearchOlder
                          ? TextButton.icon(
                              key: const ValueKey('chat-find-search-older'),
                              onPressed: widget.onSearchOlderMessages,
                              icon: const Icon(Icons.history_rounded, size: 18),
                              label: Text(str.cs1215SearchOlder),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 12,
                              ),
                              child: Text(
                                str.cs1215NoMatchesAnywhere,
                                key: const ValueKey('chat-find-exhausted'),
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Resalta la fila de la transcripción que contiene la coincidencia actual.
///
/// Presente alrededor de cada fila mientras la búsqueda está abierta (activa o
/// no), de modo que navegar entre resultados solo repinta la decoración y no
/// cambia la estructura del árbol ni remonta el Markdown de la fila.
class ChatFindMatchHighlight extends StatelessWidget {
  final bool active;
  final String? semanticLabel;
  final Widget child;

  const ChatFindMatchHighlight({
    required this.active,
    required this.child,
    this.semanticLabel,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: active,
      label: active ? semanticLabel : null,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: active
            ? BoxDecoration(
                color: colors.accent.withValues(alpha: 0.08),
                border: Border.all(
                  color: colors.accent.withValues(alpha: 0.7),
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(12),
              )
            : const BoxDecoration(),
        child: child,
      ),
    );
  }
}
