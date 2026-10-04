import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'hermes_premium_ui.dart';

/// Estado que pinta [ChatPromptSheet]; lo posee quien abre la hoja.
@immutable
class ChatPromptSheetModel {
  const ChatPromptSheetModel({
    required this.previews,
    this.activeIndex,
    this.hasMore = false,
    this.loading = false,
  });

  /// Vistas previas, de la más reciente a la más antigua.
  final List<String> previews;
  final int? activeIndex;

  /// El índice del servidor tiene más prompts por leer (acción del usuario).
  final bool hasMore;
  final bool loading;
}

/// Lista de prompts del chat para saltar a uno. Solo proyecta las vistas
/// previas ya derivadas: no lee la transcripción ni conoce el scroll, ni hace
/// ninguna petición; el dueño del modelo decide cuándo se lee algo.
class ChatPromptSheet extends StatelessWidget {
  const ChatPromptSheet({
    required this.title,
    required this.emptyLabel,
    required this.moreLabel,
    required this.model,
    required this.onSelect,
    required this.onMore,
    super.key,
  });

  final String title;
  final String emptyLabel;
  final String moreLabel;
  final ValueListenable<ChatPromptSheetModel> model;
  final ValueChanged<int> onSelect;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          key: const ValueKey('chat-prompt-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Text(
                title,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Flexible(
              child: ValueListenableBuilder<ChatPromptSheetModel>(
                valueListenable: model,
                builder: (context, state, _) {
                  final previews = state.previews;
                  final footer = state.loading || state.hasMore ? 1 : 0;
                  if (previews.isEmpty && footer == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                      child: Text(
                        emptyLabel,
                        key: const ValueKey('chat-prompt-sheet-empty'),
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: previews.length + footer,
                    itemBuilder: (context, index) {
                      if (index < previews.length) {
                        return HermesListRow(
                          key: ValueKey('chat-prompt-row-$index'),
                          title: previews[index],
                          selected: index == state.activeIndex,
                          onTap: () => onSelect(index),
                        );
                      }
                      if (state.loading) {
                        return const Padding(
                          key: ValueKey('chat-prompt-loading'),
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: LinearProgressIndicator(),
                        );
                      }
                      return HermesListRow(
                        key: const ValueKey('chat-prompt-more'),
                        title: moreLabel,
                        onTap: onMore,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
