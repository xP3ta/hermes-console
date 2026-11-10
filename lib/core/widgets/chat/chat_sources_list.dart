import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../utils/chat_inline_refs.dart';
import 'chat_file_opener.dart';
import 'chat_inline_chips.dart' show chatChipInk;

/// The sources a reply lists, one compact row each: the number in the same
/// pill the citations in the text use, the domain small above, and what the
/// source is in one or two lines. The address is not shown: a tap opens it
/// like any link and a long press copies it.
class ChatSourcesList extends StatelessWidget {
  const ChatSourcesList({super.key, required this.entries, this.onOpen});

  final List<ChatSourceEntry> entries;

  /// Opens a source address; null leaves the rows without a tap.
  final void Function(String href)? onOpen;

  /// Space between two rows.
  static const double rowGap = 6;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final strings = Localizations.of<Strings>(context, Strings);
    return Semantics(
      container: true,
      label: strings?.mdpSourcesLabel(entries.length),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, entry) in entries.indexed) ...[
            if (index > 0) const SizedBox(height: rowGap),
            ChatSourceRow(
              key: ValueKey(('source-row', entry.number)),
              entry: entry,
              onOpen: onOpen,
            ),
          ],
        ],
      ),
    );
  }
}

/// One source of [ChatSourcesList].
class ChatSourceRow extends StatelessWidget {
  const ChatSourceRow({super.key, required this.entry, this.onOpen});

  final ChatSourceEntry entry;
  final void Function(String href)? onOpen;

  /// The row is at least this tall: a touch target.
  static const double minHeight = 48;

  void _open() => onOpen?.call(entry.url);

  void _copy(BuildContext context) {
    final strings = Localizations.of<Strings>(context, Strings);
    unawaited(
      copyChatFilePath(context, entry.url, message: strings?.mdpLinkCopied),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Localizations.of<Strings>(context, Strings);
    final theme = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final ink = chatChipInk(colors);
    final domain = entry.domain;
    final title = entry.title;
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(HermesRadius.tag),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 26),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x2,
            vertical: HermesSpace.x1,
          ),
          child: Text(
            entry.number.toString(),
            maxLines: 1,
            textAlign: TextAlign.center,
            style: theme.copyWith(
              fontSize: HermesType.captionSize,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
          ),
        ),
      ),
    );
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        pill,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                domain,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.copyWith(
                  fontSize: HermesType.captionSize,
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.copyWith(
                  fontSize: HermesType.supportSize + 1,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Semantics(
      container: true,
      link: true,
      label: strings?.mdpSourceLabel(entry.number, title, domain),
      hint: strings?.mdpSourceOpenHint,
      excludeSemantics: true,
      onTap: onOpen == null ? null : _open,
      onLongPress: () => _copy(context),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen == null ? null : _open,
        onLongPress: () => _copy(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: minHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceVariant.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(HermesRadius.control),
              border: Border.all(color: colors.divider.withValues(alpha: 0.4)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3,
                vertical: HermesSpace.x2,
              ),
              child: Align(alignment: Alignment.centerLeft, child: body),
            ),
          ),
        ),
      ),
    );
  }
}
