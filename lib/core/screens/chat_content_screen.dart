import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../services/agent_preview_extractor.dart';
import '../services/agent_preview_target.dart';
import '../services/chat_content_extractor.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSearchField, HermesSegment, HermesSegmentedControl;
import '../widgets/hermes_ui.dart' show HermesSecondaryButton;

/// Thrown by [ChatContentScreen.onOpenFile] when an item cannot be reached
/// from the phone (a path on another machine, a relative path…).
class ChatContentUnreachable implements Exception {
  const ChatContentUnreachable();
}

/// sa1215: everything shared in one conversation — links, images and files
/// (agent deliveries and the person's attachments) — with Desktop's
/// All/Images/Files/Links filters and search, newest first.
///
/// The screen only reads the chat's loaded transcript. Older pages are
/// fetched exclusively through the explicit «Cargar más antiguos» action.
class ChatContentScreen extends StatefulWidget {
  /// Current chat transcript, newest first.
  final List<Map<String, dynamic>> Function() transcript;
  final bool Function() hasOlder;
  final Future<void> Function() loadOlder;

  /// Opens an image or file in the app's viewers. Throws
  /// [ChatContentUnreachable] when the item cannot be fetched.
  final Future<void> Function(ChatContentItem item) onOpenFile;
  final Future<bool> Function(Uri uri) launchExternal;

  const ChatContentScreen({
    required this.transcript,
    required this.hasOlder,
    required this.loadOlder,
    required this.onOpenFile,
    required this.launchExternal,
    super.key,
  });

  @override
  State<ChatContentScreen> createState() => _ChatContentScreenState();
}

class _ChatContentScreenState extends State<ChatContentScreen> {
  ChatContentFilter _filter = ChatContentFilter.all;
  String _query = '';
  List<Map<String, dynamic>>? _source;
  List<ChatContentItem> _items = const [];
  bool _loadingOlder = false;
  bool _opening = false;

  List<AgentPreview> _previews = const [];

  List<ChatContentItem> get _all {
    final transcript = widget.transcript();
    if (!identical(transcript, _source)) {
      _source = transcript;
      _items = collectChatContent(transcript);
      _previews = collectAgentPreviews(transcript);
    }
    return _items;
  }

  /// Previews the agent has open, narrowed by the search box. They are links
  /// of the conversation, so they stay out of the Images and Files filters.
  List<AgentPreview> get _visiblePreviews {
    if (_filter != ChatContentFilter.all && _filter != ChatContentFilter.link) {
      return const [];
    }
    final q = _query.trim().toLowerCase();
    return [
      for (final preview in _previews)
        if (q.isEmpty ||
            preview.label.toLowerCase().contains(q) ||
            preview.target.url.toLowerCase().contains(q))
          preview,
    ];
  }

  Future<void> _openPreview(AgentPreview preview) async {
    final target = preview.target;
    switch (target.reach) {
      case AgentPreviewReach.serverOnly:
        return;
      case AgentPreviewReach.web:
        final uri = Uri.tryParse(target.url);
        final ok = uri != null && await widget.launchExternal(uri);
        if (!ok && mounted) {
          HermesNotice.of(context).show(
            message: Strings.of(context).sa1215OpenFailed(preview.label),
            kind: HermesNoticeKind.error,
          );
        }
      case AgentPreviewReach.serverFile:
        final path = target.filePath ?? target.url;
        await _open(
          ChatContentItem(
            kind: ChatContentKind.file,
            value: path,
            href: path,
            label: preview.label,
          ),
        );
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      await widget.loadOlder();
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).show(
          message: Strings.of(context).sa1215LoadOlderFailed,
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _open(ChatContentItem item) async {
    if (_opening) return;
    final strings = Strings.of(context);
    final notice = HermesNotice.of(context);
    if (item.kind == ChatContentKind.link) {
      final uri = Uri.tryParse(item.href);
      final ok = uri != null && await widget.launchExternal(uri);
      if (!ok && mounted) {
        notice.show(
          message: strings.sa1215OpenFailed(item.label),
          kind: HermesNoticeKind.error,
        );
      }
      return;
    }
    _opening = true;
    try {
      await widget.onOpenFile(item);
    } on ChatContentUnreachable {
      notice.show(message: strings.sa1215NotReachable);
    } catch (_) {
      notice.show(
        message: strings.sa1215OpenFailed(item.label),
        kind: HermesNoticeKind.error,
      );
    } finally {
      _opening = false;
    }
  }

  Future<void> _copy(ChatContentItem item) async {
    final strings = Strings.of(context);
    final notice = HermesNotice.of(context);
    await Clipboard.setData(ClipboardData(text: item.value));
    notice.show(message: strings.chaCopied, kind: HermesNoticeKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final all = _all;
    final visible = filterChatContent(all, _filter, query: _query);
    final previews = _visiblePreviews;
    final hasOlder = widget.hasOlder();
    final header = <Widget>[
      HermesSearchField(
        key: const ValueKey('sa1215-search'),
        hintText: strings.sa1215SearchHint,
        clearTooltip: strings.sa1215SearchClear,
        onChanged: (value) => setState(() => _query = value),
      ),
      const SizedBox(height: HermesSpace.x3),
      HermesSegmentedControl<ChatContentFilter>(
        key: const ValueKey('sa1215-filters'),
        value: _filter,
        onChanged: (value) => setState(() => _filter = value),
        segments: [
          for (final (filter, label) in [
            (ChatContentFilter.all, strings.sa1215FilterAll),
            (ChatContentFilter.image, strings.sa1215FilterImages),
            (ChatContentFilter.file, strings.sa1215FilterFiles),
            (ChatContentFilter.link, strings.sa1215FilterLinks),
          ])
            HermesSegment(
              key: ValueKey('sa1215-filter-${filter.name}'),
              value: filter,
              label: label,
              horizontalPadding: 6,
            ),
        ],
      ),
      if (all.isNotEmpty)
        HermesSectionHeader(strings.artifactCount(visible.length)),
    ];
    final previewSection = <Widget>[
      if (previews.isNotEmpty) ...[
        HermesSectionHeader(strings.sa1215AgentPreviews),
        for (var i = 0; i < previews.length; i++)
          _PreviewRow(
            preview: previews[i],
            isFirst: i == 0,
            isLast: i == previews.length - 1,
            onTap: previews[i].target.reach == AgentPreviewReach.serverOnly
                ? null
                : () => unawaited(_openPreview(previews[i])),
          ),
      ],
    ];
    final footer = <Widget>[
      if (hasOlder) ...[
        const SizedBox(height: HermesSpace.x5),
        Text(
          strings.sa1215OlderPending,
          textAlign: TextAlign.center,
          style: HermesType.support.copyWith(
            color: Theme.of(context).hermes.textSecondary,
          ),
        ),
        const SizedBox(height: HermesSpace.x2),
        Center(
          child: _loadingOlder
              ? const Padding(
                  padding: EdgeInsets.all(HermesSpace.x3),
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : HermesSecondaryButton(
                  key: const ValueKey('sa1215-load-older'),
                  label: strings.sa1215LoadOlder,
                  icon: Icons.history_rounded,
                  onTap: _loadOlder,
                ),
        ),
      ],
    ];
    final Widget? placeholder = all.isEmpty && previews.isEmpty
        ? HermesEmptyStateView(
            icon: Icons.perm_media_outlined,
            title: strings.sa1215EmptyTitle,
            body: strings.sa1215EmptyBody,
          )
        : visible.isEmpty && previews.isEmpty
        ? HermesEmptyStateView(
            icon: Icons.search_off_rounded,
            title: strings.sa1215NoMatchesTitle,
            body: strings.sa1215NoMatchesBody,
          )
        : null;
    final bodyCount = placeholder != null
        ? 1
        : (visible.isEmpty ? 0 : visible.length);
    final count =
        header.length + previewSection.length + bodyCount + footer.length;

    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          strings.sa1215ContentTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView.builder(
          key: const ValueKey('sa1215-list'),
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.pageH,
            HermesSpace.pageTop,
            HermesSpace.pageH,
            HermesSpace.pageBottom,
          ),
          itemCount: count,
          itemBuilder: (context, index) {
            if (index < header.length) return header[index];
            index -= header.length;
            if (index < previewSection.length) return previewSection[index];
            index -= previewSection.length;
            if (index < bodyCount) {
              if (placeholder != null) return placeholder;
              return _ContentRow(
                item: visible[index],
                isFirst: index == 0,
                isLast: index == visible.length - 1,
                onTap: () => unawaited(_open(visible[index])),
                onLongPress: () => unawaited(_copy(visible[index])),
              );
            }
            return footer[index - bodyCount];
          },
        ),
      ),
    );
  }
}

/// One agent preview, in the same tile as the conversation's other links.
/// A target only the server machine can reach is shown but cannot be tapped.
class _PreviewRow extends StatelessWidget {
  final AgentPreview preview;
  final bool isFirst;
  final bool isLast;
  final VoidCallback? onTap;

  const _PreviewRow({
    required this.preview,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    const radius = Radius.circular(HermesRadius.group);
    final serverOnly = preview.target.reach == AgentPreviewReach.serverOnly;
    final isFile = preview.target.reach == AgentPreviewReach.serverFile;
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
            HermesListRow(
              key: ValueKey('sa1215-preview-${preview.label}'),
              icon: isFile
                  ? Icons.insert_drive_file_outlined
                  : Icons.link_rounded,
              iconColor: serverOnly || isFile
                  ? colors.textSecondary
                  : colors.accent,
              title: preview.label,
              subtitle: serverOnly
                  ? strings.sa1215PreviewServerOnly
                  : preview.target.url,
              muted: serverOnly,
              onTap: onTap,
              trailing: serverOnly
                  ? null
                  : Icon(
                      isFile
                          ? Icons.chevron_right_rounded
                          : Icons.open_in_new_rounded,
                      size: 18,
                      color: colors.textDisabled,
                    ),
              showChevron: false,
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

class _ContentRow extends StatelessWidget {
  final ChatContentItem item;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ContentRow({
    required this.item,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    const radius = Radius.circular(HermesRadius.group);
    final (icon, kindLabel) = switch (item.kind) {
      ChatContentKind.image => (Icons.image_outlined, strings.sa1215KindImage),
      ChatContentKind.file => (
        Icons.insert_drive_file_outlined,
        strings.sa1215KindFile,
      ),
      ChatContentKind.link => (Icons.link_rounded, _host(item.value)),
    };
    final when = item.timestamp;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final subtitle = [
      kindLabel,
      if (when != null) DateFormat.MMMd(locale).add_Hm().format(when),
    ].join(' · ');
    return Semantics(
      button: true,
      hint: strings.sa1215CopyHint,
      child: ClipRRect(
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
              GestureDetector(
                key: ValueKey('sa1215-item-${item.label}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: onLongPress,
                child: HermesListRow(
                  icon: icon,
                  iconColor: item.kind == ChatContentKind.link
                      ? colors.accent
                      : colors.textSecondary,
                  title: item.label,
                  subtitle: subtitle,
                  onTap: onTap,
                  trailing: Icon(
                    item.kind == ChatContentKind.link
                        ? Icons.open_in_new_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                  showChevron: false,
                ),
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
      ),
    );
  }
}

String _host(String value) {
  final uri = Uri.tryParse(value);
  final host = uri?.host ?? '';
  return host.startsWith('www.') ? host.substring(4) : host;
}
