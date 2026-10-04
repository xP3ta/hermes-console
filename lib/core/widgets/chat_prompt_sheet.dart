import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'hermes_premium_ui.dart';

/// Lista de prompts del chat para saltar a uno. Solo proyecta las vistas
/// previas ya derivadas: no lee la transcripción ni conoce el scroll.
class ChatPromptSheet extends StatelessWidget {
  const ChatPromptSheet({
    required this.title,
    required this.emptyLabel,
    required this.previews,
    required this.onSelect,
    this.activeIndex,
    super.key,
  });

  final String title;
  final String emptyLabel;

  /// Vistas previas, de la más reciente a la más antigua.
  final List<String> previews;
  final int? activeIndex;
  final ValueChanged<int> onSelect;

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
            if (previews.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                child: Text(
                  emptyLabel,
                  key: const ValueKey('chat-prompt-sheet-empty'),
                  style: TextStyle(color: colors.textSecondary, fontSize: 14),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: previews.length,
                  itemBuilder: (context, index) => HermesListRow(
                    key: ValueKey('chat-prompt-row-$index'),
                    title: previews[index],
                    selected: index == activeIndex,
                    onTap: () => onSelect(index),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
