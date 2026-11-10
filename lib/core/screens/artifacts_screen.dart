import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../browser/in_app_browser_policy.dart' show isBrowsableWebUri;
import '../browser/open_web_link.dart';
import '../design/hermes_design.dart';
import '../feedback/feedback_policy.dart';
import '../navigation/chat_route.dart';
import '../services/artifact_media.dart';
import '../services/chat_content_extractor.dart';
import '../services/connection_manager.dart';
import '../services/generated_media_service.dart';
import '../services/global_artifacts.dart';
import '../theme/app_theme.dart';
import '../utils/session_title.dart';
import '../widgets/artifacts/artifact_sections.dart';
import '../widgets/artifacts/open_artifact.dart';
import '../widgets/chat_content_thumbnail.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart' show HermesSearchField;
import '../widgets/hermes_ui.dart' show HermesSecondaryButton;
import 'chat_screen.dart';
import 'gallery_screen.dart';

/// «Artefactos» across the recent conversations of every profile: Hermes
/// Desktop's Artifacts page (`/artifacts`, «Explora salidas generadas»),
/// with the same presentation as a conversation's own view plus, on each
/// item, the conversation it came from and a «Chat» button that opens it.
///
/// Reading is incremental and bounded for a phone (see
/// [GlobalArtifactsController]): the first ten recent conversations, then
/// ten more on request, up to Desktop's thirty; leaving the view stops it.
class ArtifactsScreen extends StatefulWidget {
  const ArtifactsScreen({
    required this.connection,
    this.source,
    this.openChat,
    this.openInApp,
    this.download,
    this.profile,
    super.key,
  });

  final SavedConnection connection;

  /// Only this profile's artifacts (a bot's profile page). Null: every
  /// profile's, as the drawer's «Artefactos» shows them.
  final String? profile;

  /// Where the conversations are read from; the connection's Dashboard by
  /// default (tests inject a fake).
  final GlobalArtifactsSource? source;

  /// Opens a conversation; a chat above this view by default.
  final void Function(BuildContext context, Session session)? openChat;

  /// Opens an `http`/`https` link inside the app; the in-app browser by
  /// default.
  final void Function(BuildContext context, Uri uri)? openInApp;

  /// Brings an image or file of [session] into the media cache; the
  /// Dashboard download for its profile by default.
  final Future<File> Function(
    Session session,
    GeneratedMediaReference reference,
  )?
  download;

  @override
  State<ArtifactsScreen> createState() => _ArtifactsScreenState();
}

class _ArtifactsScreenState extends State<ArtifactsScreen> {
  DashboardClient? _client;
  late final GlobalArtifactsController _controller;
  late final ChatContentThumbnailLoader _thumbnails;
  ChatContentFilter _filter = ChatContentFilter.all;
  String _query = '';

  /// The search box's text lives here: the box sits in the lazy list and
  /// is rebuilt when it scrolls back or the list is read again, and it
  /// must still show what filters the list.
  final TextEditingController _search = TextEditingController();
  bool _opening = false;

  /// The conversation of each item on screen, by identity.
  Map<ChatContentItem, GlobalArtifact> _origins = Map.identity();

  /// The images and files the filters and the search leave on screen, in
  /// their order: the viewer pages through them.
  List<ChatContentItem> _viewerGroup = const [];

  @override
  void initState() {
    super.initState();
    final source =
        widget.source ??
        DashboardGlobalArtifactsSource(
          _client = DashboardClient.lazy(widget.connection),
        );
    _controller = GlobalArtifactsController(
      source: source,
      cacheKey: widget.connection.id,
    )..addListener(_changed);
    _thumbnails = ChatContentThumbnailLoader(
      fetch: (item) => artifactImageFile(
        item,
        download: (reference) => _download(_sessionOf(item), reference),
      ),
      // A relative path names a different file in each conversation.
      cacheKey: (item) => [
        _profileOf(item),
        _sessionOf(item)?.id ?? '',
        item.value,
      ].join('\u0000'),
    )..addListener(_changed);
    if (!_controller.hasRead) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_controller.refresh());
      });
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_changed)
      ..cancel()
      ..dispose();
    _thumbnails
      ..removeListener(_changed)
      ..dispose();
    _search.dispose();
    _client?.close();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Session? _sessionOf(ChatContentItem item) => _origins[item]?.session;

  String _profileOf(ChatContentItem item) =>
      Session.profileOwner(_sessionOf(item)?.profile);

  /// Desktop's `downloadGatewayMediaFile` with the item's conversation:
  /// its profile, and its session for a path relative to its folder.
  Future<File> _download(Session? session, GeneratedMediaReference reference) {
    if (session == null) {
      return Future.error(
        const ArtifactFetchFailure(ArtifactFetchProblem.noFolder),
      );
    }
    final custom = widget.download;
    if (custom != null) return custom(session, reference);
    return fetchArtifactMedia(
      connection: widget.connection,
      owner: ArtifactOwner(
        profile: Session.profileOwner(session.profile),
        sessionId: session.id,
      ),
      reference: reference,
    );
  }

  void _openChat(Session session) {
    final open = widget.openChat;
    if (open != null) {
      open(context, session);
      return;
    }
    unawaited(
      openChatFromSection<void>(
        context,
        builder: (_) =>
            ChatScreen(connection: widget.connection, session: session),
      ),
    );
  }

  /// «Galería»: the images of these same conversations, in a grid.
  void _openGallery() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => GalleryScreen(
            connection: widget.connection,
            source: widget.source,
            openChat: widget.openChat,
            download: widget.download,
          ),
        ),
      ),
    );
  }

  Future<void> _open(ChatContentItem item) async {
    if (_opening) return;
    final strings = Strings.of(context);
    final notice = AppFeedback.of(context);
    if (item.kind == ChatContentKind.link) {
      final uri = Uri.tryParse(item.href);
      if (uri == null) return;
      final inApp = widget.openInApp;
      if (inApp != null && isBrowsableWebUri(uri)) {
        inApp(context, uri);
        return;
      }
      if (openWebLinkInApp(
        context,
        uri,
        backLabel: strings.brwBackToArtifacts,
      )) {
        return;
      }
      bool ok;
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
      if (!ok && mounted) {
        notice.notify(FeedbackKind.error, strings.sa1215OpenFailed(item.label));
      }
      return;
    }
    _opening = true;
    try {
      await openArtifactsInViewer(
        context,
        initial: item,
        group: _viewerGroup,
        download: (each, reference) => _download(_sessionOf(each), reference),
        originOf: (each) => _originOf(strings, each),
      );
    } catch (error) {
      notifyArtifactOpenFailure(notice, strings, item, error);
    } finally {
      _opening = false;
    }
  }

  ArtifactOrigin? _originOf(Strings strings, ChatContentItem item) {
    final artifact = _origins[item];
    if (artifact == null) return null;
    return ArtifactOrigin(
      title: localizedSessionTitle(strings, artifact.session),
      onOpenChat: () => _openChat(artifact.session),
    );
  }

  Future<void> _copy(ChatContentItem item) async {
    final strings = Strings.of(context);
    final notice = AppFeedback.of(context);
    await Clipboard.setData(ClipboardData(text: item.value));
    notice.notify(FeedbackKind.routine, strings.chaCopied);
  }

  /// Desktop's search: name, path or URL, and the conversation's title.
  List<GlobalArtifact> _visible(
    Strings strings,
    List<GlobalArtifact> artifacts,
  ) {
    final q = _query.trim().toLowerCase();
    return [
      for (final artifact in artifacts)
        if ((_filter == ChatContentFilter.all ||
                artifact.item.kind.name == _filter.name) &&
            (q.isEmpty ||
                artifact.item.label.toLowerCase().contains(q) ||
                artifact.item.value.toLowerCase().contains(q) ||
                localizedSessionTitle(
                  strings,
                  artifact.session,
                ).toLowerCase().contains(q)))
          artifact,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final state = _controller.state;
    final owner = widget.profile == null
        ? null
        : Session.profileOwner(widget.profile);
    final all = owner == null
        ? state.artifacts
        : [
            for (final artifact in state.artifacts)
              if (Session.profileOwner(artifact.session.profile) == owner)
                artifact,
          ];
    _origins = Map.identity()
      ..addEntries([for (final a in all) MapEntry(a.item, a)]);
    final visible = _visible(strings, all);
    _viewerGroup = artifactViewerOrder([for (final a in visible) a.item]);
    final secondary = HermesType.support.copyWith(color: colors.textSecondary);

    final header = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: HermesSpace.x3),
        child: Text(strings.artGlobalDetail, style: secondary),
      ),
      if (all.isNotEmpty) ...[
        HermesSearchField(
          key: const ValueKey('artifacts-search'),
          controller: _search,
          hintText: strings.artGlobalSearchHint,
          clearTooltip: strings.sa1215SearchClear,
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: HermesSpace.x3),
        ArtifactFilterTabs(
          value: _filter,
          counts: artifactFilterCounts([for (final a in all) a.item]),
          onChanged: (value) => setState(() => _filter = value),
        ),
      ],
      if (state.phase == GlobalArtifactsPhase.indexing ||
          state.phase == GlobalArtifactsPhase.listing)
        _Progress(state: state),
      if (state.skipped > 0 ||
          state.truncated > 0 ||
          state.capped ||
          state.budgetReached)
        _Partial(state: state),
    ];

    final read = state.phase != GlobalArtifactsPhase.idle && !state.busy;
    Widget? placeholder;
    if (state.phase == GlobalArtifactsPhase.failed) {
      placeholder = Column(
        key: const ValueKey('artifacts-failed'),
        children: [
          HermesEmptyStateView(
            icon: Icons.cloud_off_outlined,
            title: strings.artGlobalFailed,
          ),
          HermesSecondaryButton(
            key: const ValueKey('artifacts-retry'),
            label: strings.commonRetry,
            icon: Icons.refresh_rounded,
            onTap: () => unawaited(_controller.refresh()),
          ),
        ],
      );
    } else if (all.isEmpty && read) {
      placeholder = HermesEmptyStateView(
        key: const ValueKey('artifacts-empty'),
        icon: Icons.perm_media_outlined,
        title: strings.artGlobalEmptyTitle,
        body: strings.artGlobalEmptyBody,
      );
    } else if (all.isNotEmpty && visible.isEmpty) {
      placeholder = HermesEmptyStateView(
        icon: Icons.search_off_rounded,
        title: strings.sa1215NoMatchesTitle,
        body: strings.sa1215NoMatchesBody,
      );
    }

    final footer = <Widget>[
      if (state.listed > 0 && state.phase != GlobalArtifactsPhase.failed) ...[
        const SizedBox(height: HermesSpace.x5),
        Text(
          strings.artGlobalScope(state.indexed, state.listed),
          key: const ValueKey('artifacts-scope'),
          textAlign: TextAlign.center,
          style: secondary,
        ),
        if (state.hasMore) ...[
          const SizedBox(height: HermesSpace.x2),
          Center(
            child: HermesSecondaryButton(
              key: const ValueKey('artifacts-load-more'),
              label: strings.artGlobalLoadMore(
                (state.listed - state.indexed).clamp(0, _controller.batchSize),
              ),
              icon: Icons.history_rounded,
              onTap: () => unawaited(_controller.loadMore()),
            ),
          ),
        ],
      ],
    ];

    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          strings.chaArtifactsAction,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('artifacts-gallery'),
            tooltip: strings.galleryAction,
            onPressed: _openGallery,
            icon: const Icon(Icons.grid_view_rounded),
          ),
          IconButton(
            key: const ValueKey('artifacts-refresh'),
            tooltip: strings.artGlobalRefresh,
            onPressed: state.busy
                ? null
                : () => unawaited(_controller.refresh()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth - 2 * HermesSpace.pageH;
            final List<Widget Function()> body;
            final empty = placeholder;
            if (empty != null) {
              body = [() => empty];
            } else if (all.isEmpty) {
              body = const [];
            } else {
              final byItem = {for (final a in visible) a.item: a};
              body = buildArtifactSections(
                context: context,
                items: [for (final a in visible) a.item],
                width: width,
                thumbnails: _thumbnails,
                onRetryThumbnails: _thumbnails.failedCount > 0
                    ? _thumbnails.retryFailed
                    : null,
                onOpen: (item) => unawaited(_open(item)),
                onCopy: (item) => unawaited(_copy(item)),
                keyOf: (item) => byItem[item]?.key ?? item.label,
                originOf: (item) => _originOf(strings, item),
              );
            }
            return ListView.builder(
              clipBehavior: hermesUnderHeader,
              key: const ValueKey('artifacts-list'),
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
}

/// While reading: Desktop's «Indexando…», and which conversation of the
/// batch is being read.
class _Progress extends StatelessWidget {
  const _Progress({required this.state});

  final GlobalArtifactsState state;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final listing = state.phase == GlobalArtifactsPhase.listing;
    final current = state.indexed < state.listed
        ? state.indexed + 1
        : state.listed;
    return Padding(
      key: const ValueKey('artifacts-progress'),
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x3),
      child: Row(
        children: [
          ConsoleLoader.small(label: strings.artGlobalIndexing, dimension: 20),
          const SizedBox(width: HermesSpace.x3),
          Expanded(
            // Read again by TalkBack as it advances.
            child: Semantics(
              key: const ValueKey('artifacts-progress-text'),
              liveRegion: true,
              child: Text(
                listing
                    ? strings.artGlobalIndexing
                    : strings.artGlobalProgress(current, state.listed),
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop's partial-load warning: what could not be read, and why.
class _Partial extends StatelessWidget {
  const _Partial({required this.state});

  final GlobalArtifactsState state;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lines = [
      if (state.skipped > 0)
        strings.artGlobalSkipped(state.skipped, state.indexed),
      if (state.skippedTooLarge > 0)
        strings.artGlobalSkippedTooLarge(state.skippedTooLarge),
      if (state.skippedTimedOut > 0)
        strings.artGlobalSkippedTimedOut(state.skippedTimedOut),
      if (state.truncated > 0) strings.artGlobalTruncated(state.truncated),
      if (state.budgetReached) strings.artGlobalBudget,
      if (state.capped) strings.artGlobalCapped,
    ];
    return Padding(
      key: const ValueKey('artifacts-partial'),
      padding: const EdgeInsets.only(bottom: HermesSpace.x3),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(HermesRadius.control),
        ),
        child: Padding(
          padding: const EdgeInsets.all(HermesSpace.x3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: colors.warning,
              ),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: Semantics(
                  key: const ValueKey('artifacts-partial-text'),
                  liveRegion: true,
                  child: Text(
                    lines.join(' '),
                    style: HermesType.support.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
