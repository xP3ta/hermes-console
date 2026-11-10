import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/hermes_design.dart';
import '../../services/chat_content_extractor.dart';
import '../../services/chat_content_presentation.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_scale.dart';
import '../../utils/external_link_labels.dart';
import '../chat_content_thumbnail.dart';
import '../link_brand_icon.dart';

// «Artefactos» as Hermes Desktop presents it (`app/artifacts/index.tsx`),
// shared by the view of one conversation and the view across the recent
// conversations: filter tabs with counts, the images as a grid of
// thumbnails, the files grouped by type and the links, each as a row with
// its icon, name, kind tag, location and copy button.

/// Desktop's image grid: `repeat(auto-fill, minmax(11rem, 1fr))`, gap 8.
const double _gridMinCell = 176;
const double _gridGap = HermesSpace.x2;

/// Desktop's thumbnail box is 10rem tall.
const double _thumbHeight = 160;

/// The conversation an item came from, in a view across conversations:
/// Desktop's session cell and its «Chat» button.
class ArtifactOrigin {
  const ArtifactOrigin({required this.title, required this.onOpenChat});

  final String title;
  final VoidCallback onOpenChat;
}

/// Desktop's tab counts. [extraLinks] are links listed apart from [items]
/// (the agent's previews of one conversation).
Map<ChatContentFilter, int> artifactFilterCounts(
  Iterable<ChatContentItem> items, {
  int extraLinks = 0,
}) {
  var images = 0, files = 0, links = 0;
  for (final item in items) {
    switch (item.kind) {
      case ChatContentKind.image:
        images++;
      case ChatContentKind.file:
        files++;
      case ChatContentKind.link:
        links++;
    }
  }
  return {
    ChatContentFilter.all: images + files + links + extraLinks,
    ChatContentFilter.image: images,
    ChatContentFilter.file: files,
    ChatContentFilter.link: links + extraLinks,
  };
}

/// The list under the filters, built lazily: images as a grid sized like
/// Desktop's, files grouped by type, then links, each group with a header
/// and its count. [items] are already filtered and in order.
///
/// [keyOf] names an item in its widget keys (its label by default; a view
/// across conversations, where the same file can come from two of them,
/// passes something unique). [originOf] adds the conversation line and its
/// «Chat» button. [knownTitle] is a page title already loaded for a link.
/// [onRetryThumbnails], given while some thumbnail failed, puts a retry
/// button on the images' header.
List<Widget Function()> buildArtifactSections({
  required BuildContext context,
  required List<ChatContentItem> items,
  required double width,
  required ChatContentThumbnailLoader? thumbnails,
  required void Function(ChatContentItem item) onOpen,
  required void Function(ChatContentItem item) onCopy,
  String? Function(ChatContentItem item)? knownTitle,
  ArtifactOrigin? Function(ChatContentItem item)? originOf,
  String Function(ChatContentItem item)? keyOf,
  VoidCallback? onRetryThumbnails,
}) {
  final strings = Strings.of(context);
  String keyFor(ChatContentItem item) => keyOf?.call(item) ?? item.label;
  String titleOf(ChatContentItem item) {
    if (item.kind != ChatContentKind.link) return item.label;
    final known = knownTitle?.call(item)?.trim();
    if (known != null &&
        isUsableLinkTitle(known) &&
        known != shortHostLabel(item.value)) {
      return known;
    }
    return urlSlugTitleLabel(item.href);
  }

  final images = [
    for (final item in items)
      if (item.kind == ChatContentKind.image) item,
  ];
  final files = [
    for (final item in items)
      if (item.kind == ChatContentKind.file) item,
  ];
  final links = [
    for (final item in items)
      if (item.kind == ChatContentKind.link) item,
  ];
  final entries = <Widget Function()>[];
  void section(String label, int count, String key, {Widget? trailing}) =>
      entries.add(
        () => HermesSectionHeader(
          strings.artSectionCount(label, count),
          key: ValueKey('sa1215-section-$key'),
          trailing: trailing,
        ),
      );
  void rows(List<ChatContentItem> group) {
    for (var i = 0; i < group.length; i++) {
      final item = group[i];
      entries.add(
        () => _ContentRow(
          item: item,
          itemKey: keyFor(item),
          title: titleOf(item),
          isFirst: i == 0,
          isLast: i == group.length - 1,
          onTap: () => onOpen(item),
          onCopy: () => onCopy(item),
          origin: originOf?.call(item),
        ),
      );
    }
  }

  if (images.isNotEmpty) {
    final retry = onRetryThumbnails;
    section(
      strings.sa1215FilterImages,
      images.length,
      'image',
      trailing: retry == null
          ? null
          : TextButton.icon(
              key: const ValueKey('sa1215-thumb-retry'),
              onPressed: retry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(strings.artThumbRetry),
            ),
    );
    final columns = math.max(
      2,
      ((width + _gridGap) / (_gridMinCell + _gridGap)).floor(),
    );
    // A zero-width box (mid-layout) must not give a negative cell.
    final cell = math.max(0.0, (width - _gridGap * (columns - 1)) / columns);
    final thumbHeight = math.min(_thumbHeight, cell);
    for (var start = 0; start < images.length; start += columns) {
      final row = images.sublist(
        start,
        math.min(start + columns, images.length),
      );
      entries.add(
        () => Padding(
          padding: const EdgeInsets.only(bottom: _gridGap),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: _gridGap),
                Expanded(
                  child: c < row.length
                      ? _ImageCard(
                          item: row[c],
                          itemKey: keyFor(row[c]),
                          loader: thumbnails,
                          thumbHeight: thumbHeight,
                          onTap: () => onOpen(row[c]),
                          onCopy: () => onCopy(row[c]),
                          origin: originOf?.call(row[c]),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
  }
  for (final (type, group) in groupChatContentFiles(files)) {
    section(_fileTypeLabel(strings, type), group.length, type.name);
    rows(group);
  }
  if (links.isNotEmpty) {
    section(strings.sa1215FilterLinks, links.length, 'link');
    rows(links);
  }
  return entries;
}

String _fileTypeLabel(Strings strings, ChatContentFileType type) =>
    switch (type) {
      ChatContentFileType.pdf => strings.artTypePdf,
      ChatContentFileType.document => strings.artTypeDocument,
      ChatContentFileType.spreadsheet => strings.artTypeSpreadsheet,
      ChatContentFileType.presentation => strings.artTypePresentation,
      ChatContentFileType.archive => strings.artTypeArchive,
      ChatContentFileType.app => strings.artTypeApp,
      ChatContentFileType.audio => strings.artTypeAudio,
      ChatContentFileType.video => strings.artTypeVideo,
      ChatContentFileType.text => strings.artTypeText,
      ChatContentFileType.data => strings.artTypeData,
      ChatContentFileType.code => strings.artTypeCode,
      ChatContentFileType.other => strings.artTypeOther,
    };

IconData _fileTypeIcon(ChatContentFileType type) => switch (type) {
  ChatContentFileType.pdf => Icons.picture_as_pdf_outlined,
  ChatContentFileType.document => Icons.description_outlined,
  ChatContentFileType.spreadsheet => Icons.table_chart_outlined,
  ChatContentFileType.presentation => Icons.slideshow_outlined,
  ChatContentFileType.archive => Icons.folder_zip_outlined,
  ChatContentFileType.app => Icons.android_rounded,
  ChatContentFileType.audio => Icons.audiotrack_outlined,
  ChatContentFileType.video => Icons.movie_outlined,
  ChatContentFileType.text => Icons.article_outlined,
  ChatContentFileType.data => Icons.data_object_rounded,
  ChatContentFileType.code => Icons.code_rounded,
  ChatContentFileType.other => Icons.insert_drive_file_outlined,
};

/// Desktop's kind tag: the extension of a file (`PDF`, `APK`), else its
/// kind word.
String _kindTag(Strings strings, ChatContentItem item) {
  switch (item.kind) {
    case ChatContentKind.image:
      return strings.sa1215KindImage;
    case ChatContentKind.link:
      return strings.artKindLink;
    case ChatContentKind.file:
      final extension = chatContentExtension(item);
      return extension.isEmpty
          ? strings.sa1215KindFile
          : extension.toUpperCase();
  }
}

String? _dateLabel(BuildContext context, ChatContentItem item) {
  final when = item.timestamp;
  if (when == null) return null;
  final locale = Localizations.localeOf(context).toLanguageTag();
  return DateFormat.MMMd(locale).add_Hm().format(when);
}

/// What TalkBack reads for an item: its kind, its name and where it lives.
String _semantics(Strings strings, String kind, String name, String? at) {
  if (at == null) return strings.artItemSemantics(kind, name);
  return strings.artItemSemanticsAt(kind, name, at);
}

/// Desktop's tabs: the filter name with its count.
class ArtifactFilterTabs extends StatelessWidget {
  const ArtifactFilterTabs({
    required this.value,
    required this.counts,
    required this.onChanged,
    super.key,
  });

  final ChatContentFilter value;
  final Map<ChatContentFilter, int> counts;
  final ValueChanged<ChatContentFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final labels = {
      ChatContentFilter.all: strings.sa1215FilterAll,
      ChatContentFilter.image: strings.sa1215FilterImages,
      ChatContentFilter.file: strings.sa1215FilterFiles,
      ChatContentFilter.link: strings.sa1215FilterLinks,
    };
    return SingleChildScrollView(
      key: const ValueKey('sa1215-filters'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final filter in ChatContentFilter.values) ...[
            if (filter != ChatContentFilter.all)
              const SizedBox(width: HermesSpace.x2),
            _FilterTab(
              key: ValueKey('sa1215-filter-${filter.name}'),
              label: labels[filter]!,
              count: counts[filter] ?? 0,
              selected: filter == value,
              colors: colors,
              onTap: () => onChanged(filter),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterTab extends StatelessWidget {
  const _FilterTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.colors,
    required this.onTap,
    super.key,
  });

  final String label;
  final int count;
  final bool selected;
  final HermesThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? colors.accentText : colors.textPrimary;
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected
              ? colors.accent.withValues(alpha: .16)
              : colors.surfaceVariant.withValues(alpha: .46),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x4,
                  vertical: HermesSpace.x2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: HermesType.body.copyWith(
                        color: ink,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: HermesSpace.x2),
                    Text(
                      count.toString(),
                      style: HermesType.support.copyWith(
                        color: selected ? ink : colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop `ArtifactImageCard`: the thumbnail, then the kind tag, the name
/// and where it lives.
class _ImageCard extends StatelessWidget {
  const _ImageCard({
    required this.item,
    required this.itemKey,
    required this.loader,
    required this.thumbHeight,
    required this.onTap,
    required this.onCopy,
    this.origin,
  });

  final ChatContentItem item;
  final String itemKey;
  final ChatContentThumbnailLoader? loader;
  final double thumbHeight;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final ArtifactOrigin? origin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final kind = strings.sa1215KindImage;
    final location = chatContentLocation(item);
    final date = _dateLabel(context, item);
    final from = origin;
    // Desktop's card line: the conversation and the time.
    final when = from == null
        ? date
        : date == null
        ? from.title
        : '${from.title} · $date';
    final secondary = HermesType.support.copyWith(color: colors.textSecondary);
    final card = MergeSemantics(
      child: Semantics(
        button: true,
        label: _semantics(strings, kind, item.label, location),
        hint: strings.sa1215CopyHint,
        child: InkWell(
          key: ValueKey('sa1215-item-$itemKey'),
          onTap: onTap,
          onLongPress: onCopy,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChatContentThumbnail(
                key: ValueKey('sa1215-thumb-${item.value}'),
                item: item,
                loader: loader,
                height: thumbHeight,
              ),
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.all(HermesSpace.x2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.image_outlined,
                            size: 14,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: HermesSpace.x1),
                          Flexible(
                            child: Text(
                              kind.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HermesType.caption.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        maxLines: labelMaxLines(context),
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.body.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      if (location != null)
                        Text(
                          location,
                          maxLines: labelMaxLines(context),
                          overflow: TextOverflow.ellipsis,
                          style: secondary,
                        ),
                      if (when != null)
                        Text(
                          when,
                          maxLines: labelMaxLines(context),
                          overflow: TextOverflow.ellipsis,
                          style: secondary,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // On a light page the group tint is ~1:1 with the page: a hairline
    // draws the card's edge there (Ola 8). Dark keeps its edge-less card.
    final chrome = HermesChrome.of(colors);
    return Material(
      color: HermesSurfaces.group(colors),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.control),
        side: chrome.dark ? BorderSide.none : BorderSide(color: chrome.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          card,
          if (from != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              // The button keeps its own tap for TalkBack (REVIEW-R4 P1-B1):
              // only its spoken text says which conversation it opens.
              child: TextButton.icon(
                key: ValueKey('sa1215-chat-$itemKey'),
                onPressed: from.onOpenChat,
                icon: const Icon(Icons.forum_outlined, size: 16),
                label: Text(
                  strings.artChat,
                  semanticsLabel: strings.artOpenChat(from.title),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A file or a link, like a row of Desktop's table: its icon (the brand of
/// a link's site), its name or title, then the kind tag and where it lives
/// in grey, the date, and a copy button for the path or URL.
class _ContentRow extends StatelessWidget {
  final ChatContentItem item;
  final String itemKey;
  final String title;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final ArtifactOrigin? origin;

  const _ContentRow({
    required this.item,
    required this.itemKey,
    required this.title,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
    required this.onCopy,
    this.origin,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    const radius = Radius.circular(HermesRadius.group);
    final isLink = item.kind == ChatContentKind.link;
    final tag = _kindTag(strings, item);
    final location = chatContentLocation(item);
    final from = origin;
    final where = location == null ? tag : '$tag · $location';
    // A view across conversations names the one each item came from.
    final subtitle = from == null ? where : '$where\n${from.title}';
    final leading = SizedBox.square(
      dimension: 32,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(HermesSpace.x2),
        ),
        child: Center(
          child: isLink
              ? LinkBrandIcon(url: item.href, color: colors.textSecondary)
              : Icon(
                  _fileTypeIcon(chatContentFileType(item)),
                  size: 18,
                  color: colors.textSecondary,
                ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: isFirst ? radius : Radius.zero,
        topRight: isFirst ? radius : Radius.zero,
        bottomLeft: isLast ? radius : Radius.zero,
        bottomRight: isLast ? radius : Radius.zero,
      ),
      child: ColoredBox(
        color: HermesSurfaces.group(colors),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    hint: strings.sa1215CopyHint,
                    child: GestureDetector(
                      key: ValueKey('sa1215-item-$itemKey'),
                      behavior: HitTestBehavior.opaque,
                      onLongPress: onCopy,
                      child: HermesListRow(
                        leading: leading,
                        title: title,
                        subtitle: subtitle,
                        subtitleMaxLines: from == null ? 1 : 2,
                        value: _dateLabel(context, item),
                        onTap: onTap,
                        semanticLabel: _semantics(
                          strings,
                          tag,
                          title,
                          location,
                        ),
                        trailing: Icon(
                          isLink
                              ? Icons.open_in_new_rounded
                              : Icons.chevron_right_rounded,
                          size: 18,
                          color: colors.textSecondary,
                        ),
                        showChevron: false,
                      ),
                    ),
                  ),
                ),
                if (from != null)
                  IconButton(
                    key: ValueKey('sa1215-chat-$itemKey'),
                    tooltip: strings.artOpenChat(from.title),
                    onPressed: from.onOpenChat,
                    icon: Icon(
                      Icons.forum_outlined,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                  ),
                IconButton(
                  key: ValueKey('sa1215-copy-$itemKey'),
                  tooltip: isLink ? strings.artCopyUrl : strings.artCopyPath,
                  onPressed: onCopy,
                  icon: Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
            if (!isLast)
              Divider(
                height: 1,
                indent: HermesSpace.rowDividerIndent,
                color: HermesSurfaces.divider(colors),
              ),
          ],
        ),
      ),
    );
  }
}
