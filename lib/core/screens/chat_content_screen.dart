import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../browser/in_app_browser_policy.dart' show isBrowsableWebUri;
import '../browser/open_web_link.dart';
import '../design/hermes_design.dart';
import '../services/agent_preview_extractor.dart';
import '../services/agent_preview_target.dart';
import '../services/app_error_log.dart';
import '../services/chat_content_extractor.dart';
import '../theme/app_theme.dart';
import '../widgets/artifacts/artifact_sections.dart';
import '../widgets/artifacts/open_artifact.dart'
    show artifactViewerOrder, notifyArtifactOpenFailure;
import '../widgets/chat_content_thumbnail.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_premium_ui.dart' show HermesSearchField;
import '../widgets/hermes_ui.dart' show HermesSecondaryButton;
import '../feedback/feedback_policy.dart';

/// Opens [item] in the media viewer, paging through [group].
typedef ChatContentOpener =
    Future<void> Function(ChatContentItem item, List<ChatContentItem> group);

/// Thrown by [ChatContentScreen.onOpenFile] when an item cannot be reached
/// from the phone (a path on another machine, a relative path…).
class ChatContentUnreachable implements Exception {
  const ChatContentUnreachable();
}

/// «Artefactos»: everything shared in one conversation, presented like
/// Hermes Desktop's Artifacts view (`apps/desktop/src/app/artifacts`):
/// All/Images/Files/Links filters with their counts, the images as a grid
/// of real thumbnails, then the files and the links as rows with their
/// icon, name, location and kind tag. Under «Todo» the files are grouped by
/// type, each group with its header, so every item says what it is.
///
/// The screen only reads the chat's loaded transcript. Older pages are
/// fetched exclusively through the explicit «Cargar más antiguos» action.
class ChatContentScreen extends StatefulWidget {
  /// Current chat transcript, newest first.
  final List<Map<String, dynamic>> Function() transcript;
  final bool Function() hasOlder;
  final Future<void> Function() loadOlder;

  /// Opens an image or file in the media viewer, paging through [group]:
  /// the images and files on screen, in their order. Throws
  /// [ChatContentUnreachable] when the item cannot be fetched.
  final ChatContentOpener onOpenFile;
  final Future<bool> Function(Uri uri) launchExternal;

  /// Brings an image into the app-private media cache for its thumbnail.
  /// Null shows an image glyph instead of thumbnails.
  final Future<File> Function(ChatContentItem item)? loadImageFile;

  /// The page title the chat already loaded for a link preview, if any.
  /// Never triggers a request.
  final String? Function(String url)? knownLinkTitle;

  /// Opens an `http`/`https` link inside the app; the in-app browser by
  /// default (the owner's decision; Desktop opens links outside). Tests inject a
  /// fake. [launchExternal] stays for anything else.
  final void Function(BuildContext context, Uri uri)? openInApp;

  const ChatContentScreen({
    required this.transcript,
    required this.hasOlder,
    required this.loadOlder,
    required this.onOpenFile,
    required this.launchExternal,
    this.loadImageFile,
    this.knownLinkTitle,
    this.openInApp,
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

  /// The transcript, or one extractor over it, failed as a whole (a bad
  /// row is already left out inside the extractors). What was read before
  /// stays; the page says it and offers to read again.
  bool _transcriptFailed = false;
  bool _extractFailed = false;
  bool get _readFailed => _transcriptFailed || _extractFailed;
  bool _loadingOlder = false;
  bool _opening = false;

  List<AgentPreview> _previews = const [];

  ChatContentThumbnailLoader? _thumbnails;

  /// The images and files on screen, in their order: the viewer's group.
  List<ChatContentItem> _viewerGroup = const [];

  @override
  void initState() {
    super.initState();
    final load = widget.loadImageFile;
    if (load != null) {
      _thumbnails = ChatContentThumbnailLoader(fetch: load)
        ..addListener(_thumbnailsChanged);
    }
  }

  @override
  void dispose() {
    _thumbnails
      ?..removeListener(_thumbnailsChanged)
      ..dispose();
    super.dispose();
  }

  /// A thumbnail failed: the images' header offers its retry button.
  void _thumbnailsChanged() {
    if (mounted) setState(() {});
  }

  List<ChatContentItem> get _all {
    // ARTBLANCO: this runs in build(), before the Scaffold; a fault here
    // replaced the whole page with the release error box. Never «nothing
    // shared» for a failure either (review R5A B3-3): the items and the
    // previews are read apart, a failure keeps what was read before, and
    // the page says it could not read, with a retry. Logged by type only.
    final List<Map<String, dynamic>> transcript;
    try {
      transcript = widget.transcript();
    } catch (error) {
      AppErrorLog.record('artifacts', error);
      _transcriptFailed = true;
      return _items;
    }
    _transcriptFailed = false;
    if (identical(transcript, _source)) return _items;
    _source = transcript;
    _extractFailed = false;
    try {
      _items = collectChatContent(transcript);
    } catch (error) {
      AppErrorLog.record('artifacts', error);
      _extractFailed = true;
    }
    try {
      _previews = collectAgentPreviews(transcript);
    } catch (error) {
      AppErrorLog.record('artifacts', error);
      _extractFailed = true;
    }
    return _items;
  }

  /// Reads the conversation again (the retry of a failed read).
  void _readAgain() => setState(() => _source = null);

  /// Above the list when the read failed after something was read: what
  /// is shown is not the whole conversation; [retry] reads it again.
  Widget _partialNotice(BuildContext context, String text, Widget retry) {
    final colors = Theme.of(context).hermes;
    return Padding(
      key: const ValueKey('sa1215-read-partial'),
      padding: const EdgeInsets.only(bottom: HermesSpace.x3),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(HermesRadius.control),
        ),
        child: Padding(
          padding: const EdgeInsets.all(HermesSpace.x3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: colors.warning,
                  ),
                  const SizedBox(width: HermesSpace.x2),
                  Expanded(
                    child: Text(
                      text,
                      style: HermesType.support.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HermesSpace.x2),
              Align(alignment: AlignmentDirectional.centerEnd, child: retry),
            ],
          ),
        ),
      ),
    );
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
        if (uri != null && _openInApp(uri)) return;
        final ok = uri != null && await widget.launchExternal(uri);
        if (!ok && mounted) {
          AppFeedback.of(context).notify(
            FeedbackKind.error,
            Strings.of(context).sa1215OpenFailed(preview.label),
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

  /// An `http`/`https` [uri] in the in-app browser, coming back here.
  bool _openInApp(Uri uri) {
    if (!isBrowsableWebUri(uri)) return false;
    final open = widget.openInApp;
    if (open != null) {
      open(context, uri);
      return true;
    }
    return openWebLinkInApp(
      context,
      uri,
      backLabel: Strings.of(context).brwBackToArtifacts,
    );
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      await widget.loadOlder();
    } catch (_) {
      if (mounted) {
        AppFeedback.of(
          context,
        ).notify(FeedbackKind.error, Strings.of(context).sa1215LoadOlderFailed);
      }
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _open(ChatContentItem item) async {
    if (_opening) return;
    final strings = Strings.of(context);
    final notice = AppFeedback.of(context);
    if (item.kind == ChatContentKind.link) {
      final uri = Uri.tryParse(item.href);
      if (uri != null && _openInApp(uri)) return;
      final ok = uri != null && await widget.launchExternal(uri);
      if (!ok && mounted) {
        notice.notify(FeedbackKind.error, strings.sa1215OpenFailed(item.label));
      }
      return;
    }
    _opening = true;
    try {
      await widget.onOpenFile(item, _viewerGroup);
    } catch (error) {
      notifyArtifactOpenFailure(notice, strings, item, error);
    } finally {
      _opening = false;
    }
  }

  Future<void> _copy(ChatContentItem item) async {
    final strings = Strings.of(context);
    final notice = AppFeedback.of(context);
    await Clipboard.setData(ClipboardData(text: item.value));
    notice.notify(FeedbackKind.routine, strings.chaCopied);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final all = _all;
    final visible = filterChatContent(all, _filter, query: _query);
    _viewerGroup = artifactViewerOrder(visible);
    final previews = _visiblePreviews;
    final hasOlder = widget.hasOlder();
    // Desktop counts the whole conversation, not the search results; the
    // agent's previews are links of the conversation too.
    final counts = artifactFilterCounts(all, extraLinks: _previews.length);
    final header = <Widget>[
      HermesSearchField(
        key: const ValueKey('sa1215-search'),
        hintText: strings.sa1215SearchHint,
        clearTooltip: strings.sa1215SearchClear,
        onChanged: (value) => setState(() => _query = value),
      ),
      const SizedBox(height: HermesSpace.x3),
      ArtifactFilterTabs(
        value: _filter,
        counts: counts,
        onChanged: (value) => setState(() => _filter = value),
      ),
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
                  child: ConsoleLoader.small(dimension: 20),
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
    final retry = HermesSecondaryButton(
      key: const ValueKey('sa1215-read-retry'),
      label: strings.commonRetry,
      icon: Icons.refresh_rounded,
      onTap: _readAgain,
    );
    if (_readFailed && (all.isNotEmpty || _previews.isNotEmpty)) {
      header.insert(
        0,
        _partialNotice(context, strings.sa1215ReadPartial, retry),
      );
    }
    final Widget? placeholder = all.isEmpty && _previews.isEmpty && _readFailed
        ? Column(
            key: const ValueKey('sa1215-read-failed'),
            children: [
              HermesEmptyStateView(
                icon: Icons.error_outline_rounded,
                title: strings.sa1215ReadFailed,
              ),
              retry,
            ],
          )
        : all.isEmpty && previews.isEmpty
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

    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          strings.chaArtifactsAction,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final width = math.max(0.0, box.maxWidth - 2 * HermesSpace.pageH);
            final List<Widget Function()> body;
            if (placeholder != null) {
              final empty = placeholder;
              body = [() => empty];
            } else {
              body = _sections(context, visible, previews, width);
            }
            return ListView.builder(
              clipBehavior: hermesUnderHeader,
              key: const ValueKey('sa1215-list'),
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.pageH,
                HermesSpace.pageTop,
                HermesSpace.pageH,
                HermesSpace.pageBottom,
              ),
              itemCount: header.length + body.length + footer.length,
              itemBuilder: (context, index) {
                if (index < header.length) return header[index];
                index -= header.length;
                if (index < body.length) return body[index]();
                return footer[index - body.length];
              },
            );
          },
        ),
      ),
    );
  }

  /// The list below the filters, built lazily: the shared sections (images
  /// as a grid, files grouped by type, links), then the agent's previews.
  List<Widget Function()> _sections(
    BuildContext context,
    List<ChatContentItem> visible,
    List<AgentPreview> previews,
    double width,
  ) {
    final strings = Strings.of(context);
    final known = widget.knownLinkTitle;
    final entries = buildArtifactSections(
      context: context,
      items: visible,
      width: width,
      thumbnails: _thumbnails,
      onRetryThumbnails: (_thumbnails?.failedCount ?? 0) > 0
          ? _thumbnails!.retryFailed
          : null,
      onOpen: (item) => unawaited(_open(item)),
      onCopy: (item) => unawaited(_copy(item)),
      knownTitle: known == null ? null : (item) => known(item.value),
    );
    if (previews.isNotEmpty) {
      entries.add(() => HermesSectionHeader(strings.sa1215AgentPreviews));
      for (var i = 0; i < previews.length; i++) {
        final preview = previews[i];
        entries.add(
          () => _PreviewRow(
            preview: preview,
            isFirst: i == 0,
            isLast: i == previews.length - 1,
            onTap: preview.target.reach == AgentPreviewReach.serverOnly
                ? null
                : () => unawaited(_openPreview(preview)),
          ),
        );
      }
    }
    return entries;
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
