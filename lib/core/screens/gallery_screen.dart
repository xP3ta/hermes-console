import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../navigation/chat_route.dart';
import '../services/artifact_media.dart';
import '../services/chat_content_extractor.dart';
import '../services/connection_manager.dart';
import '../services/gallery_groups.dart';
import '../services/generated_media_service.dart';
import '../services/global_artifacts.dart';
import '../theme/app_theme.dart';
import '../utils/session_title.dart';
import '../widgets/artifacts/artifact_sections.dart' show ArtifactOrigin;
import '../widgets/artifacts/open_artifact.dart';
import '../widgets/chat_content_thumbnail.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart' show HermesSecondaryButton;
import 'chat_screen.dart';

/// The widest a thumbnail grows before another column fits: more columns on
/// a wide screen (the open Fold), never fewer than three on a phone.
const double _tileExtent = 128;

/// «Galería»: the images the recent conversations produced or received, in
/// a grid grouped by day, newest first. It reads like «Artefactos» does
/// ([GlobalArtifactsController]: a few conversations at a time, one page in
/// memory, a bounded list), keeps only the images, and draws thumbnails
/// lazily through [ChatContentThumbnailLoader] (a bounded cache, a few
/// fetches at once, only what is on screen). A tile opens the media viewer
/// (zoom, share, save, the conversation it came from) over the images the
/// conversation filter leaves.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    required this.connection,
    this.source,
    this.openChat,
    this.download,
    super.key,
  });

  final SavedConnection connection;

  /// Where the conversations are read from; the connection's Dashboard by
  /// default (tests inject a fake).
  final GlobalArtifactsSource? source;

  /// Opens a conversation; a chat above this view by default.
  final void Function(BuildContext context, Session session)? openChat;

  /// Brings an image of [session] into the media cache; the Dashboard
  /// download for its profile by default.
  final Future<File> Function(
    Session session,
    GeneratedMediaReference reference,
  )?
  download;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  DashboardClient? _client;
  late final GlobalArtifactsController _controller;
  late final ChatContentThumbnailLoader _thumbnails;

  /// The conversation the gallery is narrowed to; null shows them all.
  String? _sessionId;
  bool _opening = false;

  /// The conversation of each image on screen, by identity.
  Map<ChatContentItem, GlobalArtifact> _origins = Map.identity();

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
        Session.profileOwner(_sessionOf(item)?.profile),
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
    _client?.close();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Session? _sessionOf(ChatContentItem item) => _origins[item]?.session;

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

  ArtifactOrigin? _originOf(Strings strings, ChatContentItem item) {
    final artifact = _origins[item];
    if (artifact == null) return null;
    return ArtifactOrigin(
      title: localizedSessionTitle(strings, artifact.session),
      onOpenChat: () => _openChat(artifact.session),
    );
  }

  Future<void> _open(
    GlobalArtifact artifact,
    List<GlobalArtifact> shown,
  ) async {
    if (_opening) return;
    final strings = Strings.of(context);
    _opening = true;
    try {
      await openArtifactsInViewer(
        context,
        initial: artifact.item,
        group: [for (final each in shown) each.item],
        download: (each, reference) => _download(_sessionOf(each), reference),
        originOf: (each) => _originOf(strings, each),
      );
    } finally {
      _opening = false;
    }
  }

  Future<void> _pickConversation(
    Strings strings,
    List<GalleryConversation> conversations,
  ) async {
    const all = '';
    final picked = await showHermesOptions<String>(
      context: context,
      surfaceKey: const ValueKey('gallery-filter-surface'),
      title: strings.galleryFilterTitle,
      selected: _sessionId ?? all,
      options: [
        HermesOption(value: all, label: strings.galleryFilterAll),
        for (final conversation in conversations)
          HermesOption(
            value: conversation.session.id,
            label: localizedSessionTitle(strings, conversation.session),
            subtitle: strings.galleryImageCount(conversation.count),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() => _sessionId = picked.isEmpty ? null : picked);
  }

  String _dayLabel(Strings strings, DateTime day) {
    final today = galleryDayOf(DateTime.now());
    if (day == today) return strings.galleryToday;
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return strings.galleryYesterday;
    }
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMMMMEEEEd(locale).format(day);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final state = _controller.state;
    final secondary = HermesType.support.copyWith(color: colors.textSecondary);
    _origins = Map.identity()
      ..addEntries([for (final a in state.artifacts) MapEntry(a.item, a)]);
    final images = galleryImages(state.artifacts);
    final conversations = galleryConversations(images);
    // A conversation that no longer has images in the list drops the filter.
    final filter = conversations.any((c) => c.session.id == _sessionId)
        ? _sessionId
        : null;
    final shown = galleryInConversation(images, filter);
    final days = groupGalleryByDay(shown);

    final read = state.phase != GlobalArtifactsPhase.idle && !state.busy;
    Widget? placeholder;
    if (state.phase == GlobalArtifactsPhase.failed) {
      placeholder = Column(
        key: const ValueKey('gallery-failed'),
        children: [
          HermesEmptyStateView(
            icon: Icons.cloud_off_outlined,
            title: strings.artGlobalFailed,
          ),
          HermesSecondaryButton(
            key: const ValueKey('gallery-retry'),
            label: strings.commonRetry,
            icon: Icons.refresh_rounded,
            onTap: () => unawaited(_controller.refresh()),
          ),
        ],
      );
    } else if (images.isEmpty && read) {
      placeholder = HermesEmptyStateView(
        key: const ValueKey('gallery-empty'),
        icon: Icons.perm_media_outlined,
        title: strings.galleryEmptyTitle,
        body: strings.galleryEmptyBody,
      );
    }

    final slivers = <Widget>[
      if (conversations.length > 1)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: HermesSpace.x3),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: HermesSecondaryButton(
                key: const ValueKey('gallery-filter'),
                label: filter == null
                    ? strings.galleryFilterAll
                    : localizedSessionTitle(
                        strings,
                        conversations
                            .firstWhere((c) => c.session.id == filter)
                            .session,
                      ),
                onTap: () =>
                    unawaited(_pickConversation(strings, conversations)),
              ),
            ),
          ),
        ),
      if (state.phase == GlobalArtifactsPhase.indexing ||
          state.phase == GlobalArtifactsPhase.listing)
        SliverToBoxAdapter(child: _Progress(state: state)),
      if (state.skipped > 0)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: HermesSpace.x3),
            child: Text(
              strings.artGlobalSkipped(state.skipped, state.indexed),
              key: const ValueKey('gallery-partial'),
              style: secondary,
            ),
          ),
        ),
      if (placeholder != null)
        SliverToBoxAdapter(child: placeholder)
      else
        for (final day in days) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(
                top: HermesSpace.sectionTop,
                bottom: HermesSpace.sectionBottom,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  _dayLabel(strings, day.day),
                  key: ValueKey('gallery-day-${day.day.toIso8601String()}'),
                  style: HermesType.support.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: _tileExtent,
              mainAxisSpacing: HermesSpace.x2,
              crossAxisSpacing: HermesSpace.x2,
            ),
            itemCount: day.items.length,
            itemBuilder: (context, index) => _Tile(
              artifact: day.items[index],
              thumbnails: _thumbnails,
              label: strings.galleryTileLabel(
                day.items[index].item.label,
                localizedSessionTitle(strings, day.items[index].session),
              ),
              onTap: () => unawaited(_open(day.items[index], shown)),
            ),
          ),
        ],
      if (state.listed > 0 && state.phase != GlobalArtifactsPhase.failed)
        SliverToBoxAdapter(
          child: Column(
            children: [
              const SizedBox(height: HermesSpace.x5),
              Text(
                strings.artGlobalScope(state.indexed, state.listed),
                key: const ValueKey('gallery-scope'),
                textAlign: TextAlign.center,
                style: secondary,
              ),
              if (state.hasMore) ...[
                const SizedBox(height: HermesSpace.x2),
                HermesSecondaryButton(
                  key: const ValueKey('gallery-load-more'),
                  label: strings.artGlobalLoadMore(
                    (state.listed - state.indexed).clamp(
                      0,
                      _controller.batchSize,
                    ),
                  ),
                  icon: Icons.history_rounded,
                  onTap: () => unawaited(_controller.loadMore()),
                ),
              ],
            ],
          ),
        ),
    ];

    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          strings.galleryTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('gallery-refresh'),
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
        child: CustomScrollView(
          key: const ValueKey('gallery-list'),
          clipBehavior: hermesUnderHeader,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.pageH,
                HermesSpace.pageTop,
                HermesSpace.pageH,
                HermesSpace.pageBottom,
              ),
              sliver: SliverMainAxisGroup(slivers: slivers),
            ),
          ],
        ),
      ),
    );
  }
}

/// One thumbnail: the picture, a button that opens it.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.artifact,
    required this.thumbnails,
    required this.label,
    required this.onTap,
  });

  final GlobalArtifact artifact;
  final ChatContentThumbnailLoader thumbnails;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: ValueKey('gallery-tile-${artifact.key}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(HermesRadius.control),
          child: LayoutBuilder(
            builder: (context, box) => ChatContentThumbnail(
              item: artifact.item,
              loader: thumbnails,
              height: box.maxHeight,
            ),
          ),
        ),
      ),
    );
  }
}

/// While reading: which conversation of the batch is being read.
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
      key: const ValueKey('gallery-progress'),
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x3),
      child: Row(
        children: [
          ConsoleLoader.small(label: strings.artGlobalIndexing, dimension: 20),
          const SizedBox(width: HermesSpace.x3),
          Expanded(
            child: Semantics(
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
