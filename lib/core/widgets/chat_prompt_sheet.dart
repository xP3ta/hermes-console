import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'hermes_premium_ui.dart';
import 'console_loader.dart';

/// State painted by [ChatPromptSheet]; owned by whoever opens the sheet.
@immutable
class ChatPromptSheetModel {
  const ChatPromptSheetModel({
    required this.previews,
    this.activeIndex,
    this.hasMore = false,
    this.loading = false,
  });

  /// Previews, from the newest to the oldest.
  final List<String> previews;
  final int? activeIndex;

  /// The server index has more prompts to read (a user action).
  final bool hasMore;
  final bool loading;
}

/// List of the chat's prompts to jump to one. It only projects the previews
/// that are already derived: it does not read the transcript, know the scroll
/// position or make any request; the owner of the model decides when anything is
/// read.
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
                          child: Center(child: ConsoleLoader.small()),
                        );
                      }
                      return _LoadEarlierRow(
                        key: const ValueKey('chat-prompt-more'),
                        label: moreLabel,
                        onMore: onMore,
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

/// "Load earlier" row. It asks for a single read per appearance: a second tap
/// before the owner switches to `loading` (and the row is replaced by the
/// indicator) does not repeat the request with the same cursor.
class _LoadEarlierRow extends StatefulWidget {
  const _LoadEarlierRow({
    required this.label,
    required this.onMore,
    super.key,
  });

  final String label;
  final VoidCallback onMore;

  @override
  State<_LoadEarlierRow> createState() => _LoadEarlierRowState();
}

class _LoadEarlierRowState extends State<_LoadEarlierRow> {
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    return HermesListRow(
      title: widget.label,
      onTap: () {
        if (_requested) return;
        _requested = true;
        widget.onMore();
      },
    );
  }
}
