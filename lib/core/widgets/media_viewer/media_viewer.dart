import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/hermes_design.dart';
import '../../design/glass_strip.dart';
import '../../design/liquid_glass.dart';
import '../../design/liquid_sheen.dart';
import '../../feedback/feedback_policy.dart';
import '../../services/artifact_media.dart';
import '../../services/artifact_viewer_kind.dart';
import '../../services/generated_media_service.dart';
import '../../services/media_dimensions.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart'
    show CoveredRouteMediaQueryFreeze, HermesMotion;
import '../artifact_viewer/artifact_viewer_screen.dart';
import '../attachment_card.dart'
    show
        GeneratedAudioPlayback,
        GeneratedAudioPlayerCard,
        openGeneratedMediaExternally,
        saveMediaToGallery,
        shareMediaFile;
import '../chat_content_thumbnail.dart' show artifactFetchReason;
import '../console_loader.dart';
import '../frosted_backdrop.dart';
import '../generated_video_card.dart';
import '../hermes_ui.dart' show HermesPrimaryButton, HermesSecondaryButton;
import '../save_to_device_feedback.dart' show saveFileToDevice;

/// How the viewer shows an element.
enum MediaViewerKind { image, video, audio, document }

/// One element of the group the viewer pages through: what it is, what its
/// details card says about it, and where its bytes come from.
///
/// The bytes are one of: a [file] already in the app-private cache, inline
/// [bytes], an [imageUrl] already shown by the chat, or [load], which
/// fetches it only when the page needs it. [problem] is a reason known
/// before any fetch (an `http:` address, an unsupported scheme).
class MediaViewerItem {
  const MediaViewerItem({
    required this.kind,
    this.name,
    this.typeLabel,
    this.mimeType = 'application/octet-stream',
    this.sizeBytes,
    this.location,
    this.locationIsUrl = false,
    this.conversation,
    this.onOpenChat,
    this.timestamp,
    this.file,
    this.bytes,
    this.imageUrl,
    this.load,
    this.problem,
    this.heroTag,
  });

  final MediaViewerKind kind;

  /// Null for a private copy without a name of its own: the viewer then
  /// says what it is («Imagen», «Vídeo»…).
  final String? name;

  /// Desktop's kind tag («PNG», «PDF»); null derives it from [name].
  final String? typeLabel;
  final String mimeType;
  final int? sizeBytes;

  /// The path or URL as the conversation wrote it. Null hides it (the
  /// chat's own media never shows its server path).
  final String? location;
  final bool locationIsUrl;

  /// Title of the conversation the element came from.
  final String? conversation;
  final VoidCallback? onOpenChat;
  final DateTime? timestamp;
  final File? file;
  final Uint8List? bytes;
  final String? imageUrl;
  final Future<File> Function()? load;
  final ArtifactFetchProblem? problem;
  final Object? heroTag;
}

/// Opens the viewer over [items] at [initialIndex].
Future<void> showMediaViewer(
  BuildContext context,
  List<MediaViewerItem> items, {
  int initialIndex = 0,
  GeneratedAudioPlayback Function()? audioPlayback,
}) {
  assert(items.isNotEmpty);
  releaseTextFocusIfKeyboardHidden(context);
  // Ola 7 (AUDITORIA-PULIDO §4.2): the sheet rises over the dimmed chat
  // (v25 `.sheet`); with «reduce motion» it is simply there.
  final reduce = HermesMotion.reduced(context);
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: reduce ? Duration.zero : HermesMotion.sheetOpen,
      reverseTransitionDuration: reduce
          ? Duration.zero
          : HermesMotion.sheetClose,
      pageBuilder: (_, animation, _) => CoveredRouteMediaQueryFreeze(
        child: MediaViewerScreen(
          items: items,
          initialIndex: initialIndex.clamp(0, items.length - 1),
          audioPlayback: audioPlayback,
          entrance: animation,
        ),
      ),
    ),
  );
}

/// Desktop's zoom range and button step (`use-zoom-pan.ts`).
const double _minScale = 0.25;
const double _maxScale = 8;
const double _buttonStep = 1.25;

/// A picture is decoded at most at this side (and at twice the stage)
/// until it is zoomed past [_fullResolutionScale]: a 8000×6000 photo is not
/// held at full size (about 190 MB) just to be seen whole.
const int _maxDecodedSide = 4096;
const double _fullResolutionScale = 2;

/// How far a page is dragged down or up before letting go closes it.
const double _dismissDistance = 120;
const double _dismissVelocity = 800;

/// The mockup's sheet (L3-visor): the chat shows above it, blurred.
const double _sheetTop = 40;
// the owner's sheet radius and the card step of the scale (they were 28 and 20).
const double _sheetRadius = HermesRadius.sheet;
const double _cardRadius = HermesRadius.card;

/// The strip of thumbnails under the picture: five on screen, scrolling.
const int _stripVisible = 5;
const double _stripGap = 10;

/// Strip pictures fetched at once, as the Artefactos grid does.
const int _stripConcurrency = 3;
const double _stripAspect = .76;

/// Wide sheets (tablet, landscape) keep the strip low.
const double _stripMaxHeight = 64;

/// Below this the sheet drops the strip, so the element keeps its room.
const double _compactSheetHeight = 520;

/// Width of a strip tile when [viewport] shows five.
double _stripTileWidth(double viewport) =>
    (viewport - _stripGap * (_stripVisible - 1)) / _stripVisible;

enum _Load { idle, loading, ready, failed }

class _Slot {
  _Load state = _Load.idle;
  File? file;

  /// Bytes of [file], once fetched.
  int? size;

  /// Pixel size of a picture, read once from its header.
  Size? dimensions;
  bool dimensionsRead = false;
  ArtifactFetchProblem? problem;
  Future<void>? pending;
}

/// The single viewer of images, video, audio and documents, from
/// «Artefactos» and from the chat.
///
/// It looks like the owner's mockup (L3-visor): a sheet with a handle over the
/// blurred chat, «n de N», copy/share/save in a capsule, a details card
/// («Imagen 1 · JPEG 1200 × 800 px · 98 KB», tap for path, conversation and
/// date), the element in a card, and the strip of thumbnails with the one
/// on screen highlighted. It behaves as Desktop: its lightbox
/// (`zoomable-image.tsx`) zooms and pans in 25 %–800 % with its −/%/+ bar
/// and saves; its media attachments (`markdown-text.tsx`) play video and
/// audio with their controls, fetched only when asked (`preload="none"`),
/// and a file opens outside. Like Desktop's lightbox it has no close
/// button: the handle, the blurred chat, a drag down or Back close it.
class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({
    required this.items,
    this.initialIndex = 0,
    this.audioPlayback,
    this.launchExternal,
    this.entrance,
    super.key,
  });

  final List<MediaViewerItem> items;
  final int initialIndex;
  final GeneratedAudioPlayback Function()? audioPlayback;

  /// The route's own animation ([showMediaViewer]): the scrim fades in with
  /// it and the sheet rises with it. Null: the route that holds the screen
  /// moves it.
  final Animation<double>? entrance;

  /// Replaces «Abrir fuera» (tests).
  final Future<void> Function(MediaViewerItem, File)? launchExternal;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  final ScrollController _strip = ScrollController();
  late int _index = widget.initialIndex;
  bool _zoomed = false;
  final Map<int, _Slot> _slots = {};
  final Map<int, TransformationController> _transforms = {};
  final Set<int> _autoplay = {};

  /// Strip tiles on screen, those waiting to fetch their picture, and how
  /// many strip fetches run (at most [_stripConcurrency]).
  final Set<int> _stripShown = {};
  final List<int> _stripQueue = [];
  int _stripRunning = 0;
  bool _stripPumpScheduled = false;

  /// Size of the pages, the zoom buttons' centre.
  Size _stage = Size.zero;

  int get _count => widget.items.length;
  MediaViewerItem get _item => widget.items[_index];

  /// [MediaViewerScreen.entrance] on its curves, held for as long as the
  /// route lives (see `RouteCurves`): a sheet closed half way in goes back
  /// down the way it came.
  CurvedAnimation? _entrance;

  CurvedAnimation? _curved(Animation<double>? route) {
    if (route == null) return null;
    return CurvedAnimation(
      parent: route,
      curve: HermesMotion.emphasized,
      reverseCurve: HermesMotion.exit.flipped,
    );
  }

  @override
  void didUpdateWidget(MediaViewerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.entrance, widget.entrance)) return;
    _entrance?.dispose();
    _entrance = _curved(widget.entrance);
  }

  @override
  void initState() {
    super.initState();
    _entrance = _curved(widget.entrance);
    // On a wide screen the strip opens on the element tapped.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealInStrip(_index);
    });
  }

  @override
  void dispose() {
    _entrance?.dispose();
    _pages.dispose();
    _strip.dispose();
    for (final transform in _transforms.values) {
      transform.dispose();
    }
    super.dispose();
  }

  _Slot _slot(int index) {
    final known = _slots[index];
    if (known != null) return known;
    final item = widget.items[index];
    final slot = _Slot();
    if (item.file != null || item.bytes != null || item.imageUrl != null) {
      slot
        ..state = _Load.ready
        ..file = item.file;
    } else if (item.problem != null || item.load == null) {
      slot
        ..state = _Load.failed
        ..problem = item.problem ?? ArtifactFetchProblem.unsupported;
    }
    return _slots[index] = slot;
  }

  /// Fetches the element at [index] once; the page shows its progress and
  /// then its content or the reason it failed.
  Future<void>? _fetch(int index) {
    final slot = _slot(index);
    final load = widget.items[index].load;
    if (slot.state != _Load.idle || load == null) return slot.pending;
    slot.state = _Load.loading;
    return slot.pending = _run(slot, load);
  }

  Future<void> _run(_Slot slot, Future<File> Function() load) async {
    try {
      final file = await Future.sync(load);
      slot
        ..file = file
        ..size = _lengthOf(file)
        ..state = _Load.ready;
    } on ArtifactFetchFailure catch (failure) {
      slot
        ..problem = failure.problem
        ..state = _Load.failed;
    } catch (error) {
      slot
        ..problem = artifactFetchProblemOf(error, https: false)
        ..state = _Load.failed;
    }
    slot.pending = null;
    if (mounted) setState(() {});
  }

  /// Runs [action] on the file of the element at [index], fetching it
  /// first when needed (a document's «Ver en la app» or «Abrir fuera»).
  Future<void> _withFile(
    int index,
    Future<void> Function(File file) action,
  ) async {
    final slot = _slot(index);
    if (slot.state == _Load.idle) {
      setState(() {
        _fetch(index);
      });
    }
    await slot.pending;
    final file = slot.file;
    if (!mounted || slot.state != _Load.ready || file == null) return;
    if (index != _index) return;
    await action(file);
  }

  /// A strip tile came on screen: its picture is fetched in turn, after the
  /// frame, so the page on screen asks first and nothing starts mid-layout.
  void _stripTileShown(int index) {
    _stripShown.add(index);
    if (_slot(index).state != _Load.idle || _stripQueue.contains(index)) {
      return;
    }
    _stripQueue.add(index);
    if (_stripPumpScheduled) return;
    _stripPumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stripPumpScheduled = false;
      if (mounted) _pumpStrip();
    });
  }

  void _stripTileHidden(int index) => _stripShown.remove(index);

  void _pumpStrip() {
    while (_stripRunning < _stripConcurrency && _stripQueue.isNotEmpty) {
      final index = _stripQueue.removeAt(0);
      // Scrolled away before its turn, or already asked for by its page.
      if (!_stripShown.contains(index)) continue;
      if (_slot(index).state != _Load.idle) continue;
      final pending = _fetch(index);
      if (pending == null) continue;
      _stripRunning++;
      unawaited(
        pending.whenComplete(() {
          _stripRunning--;
          if (mounted) _pumpStrip();
        }),
      );
    }
  }

  void _act(int index, Future<void> Function(File file) action) =>
      unawaited(_withFile(index, action));

  void _retry(int index) {
    final slot = _slot(index);
    if (slot.state != _Load.failed) return;
    setState(() {
      slot
        ..state = _Load.idle
        ..problem = null;
      _fetch(index);
    });
  }

  void _play(int index) {
    setState(() {
      _autoplay.add(index);
      _fetch(index);
    });
  }

  TransformationController _transform(int index) =>
      _transforms.putIfAbsent(index, TransformationController.new);

  void _onPage(int index) {
    setState(() {
      _index = index;
      _zoomed = false;
      // «Reproducir» starts a clip once; coming back to it does not.
      _autoplay.clear();
    });
    // A page comes back at its fit size.
    _transforms[index]?.value = Matrix4.identity();
    _revealInStrip(index);
  }

  void _setZoomed(bool zoomed) {
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _close() => unawaited(Navigator.of(context).maybePop());

  /// A thumbnail of the strip: a neighbour slides in, anything further
  /// jumps, so the pages in between are not fetched on the way.
  void _goTo(int index) {
    if (index == _index) return;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion || (index - _index).abs() > 1) {
      _pages.jumpToPage(index);
      return;
    }
    unawaited(
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _revealInStrip(int index) {
    if (!_strip.hasClients) return;
    final position = _strip.position;
    final viewport = position.viewportDimension;
    final tile = _stripTileWidth(viewport);
    final centred = index * (tile + _stripGap) - (viewport - tile) / 2;
    _strip.jumpTo(
      centred.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  /// Zooms the image on screen around its centre, as Desktop's buttons.
  void _zoomBy(double factor) {
    final transform = _transform(_index);
    final scale = transform.value.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(_minScale, _maxScale);
    if (next == scale) return;
    final f = next / scale;
    final cx = _stage.width / 2;
    final cy = _stage.height / 2;
    final around = Matrix4.identity()
      ..translateByDouble(cx, cy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1);
    transform.value = around.multiplied(transform.value);
    _setZoomed((next - 1).abs() > 0.01);
  }

  void _resetZoom() {
    _transform(_index).value = Matrix4.identity();
    _setZoomed(false);
  }

  // ---- Actions -----------------------------------------------------------

  /// The file behind the element on screen, when it is in the app.
  File? get _readyFile {
    final slot = _slot(_index);
    return slot.state == _Load.ready ? slot.file : null;
  }

  /// Pictures and clips go to the gallery, as the chat saves them; the
  /// rest through Android's save dialog, as Desktop's download.
  bool get _savesToGallery =>
      (_item.kind == MediaViewerKind.image && !_isSvg(_item)) ||
      _item.kind == MediaViewerKind.video;

  Future<void> _save(File file) async {
    if (_savesToGallery) {
      await saveMediaToGallery(
        context,
        file,
        isVideo: _item.kind == MediaViewerKind.video,
      );
      return;
    }
    // Copied by blocks from its file to the place chosen: never loaded
    // whole, so no size limit; each failure says why.
    await saveFileToDevice(
      context,
      file,
      name: _displayName(Strings.of(context), _item),
      source: 'media_viewer',
    );
  }

  Future<void> _share(File file) async {
    final notice = AppFeedback.of(context);
    final strings = Strings.of(context);
    try {
      await shareMediaFile(file);
    } catch (_) {
      notice.notify(FeedbackKind.error, strings.mvActionFailed);
    }
  }

  Future<void> _openOutside(MediaViewerItem item, File file) async {
    final notice = AppFeedback.of(context);
    final strings = Strings.of(context);
    try {
      final launch = widget.launchExternal;
      if (launch != null) {
        await launch(item, file);
        return;
      }
      await openGeneratedMediaExternally(
        file,
        mimeType: item.mimeType,
        expectedSize: _lengthOf(file) ?? 0,
      );
    } catch (_) {
      notice.notify(FeedbackKind.error, strings.mvActionFailed);
    }
  }

  Future<void> _copyLocation(MediaViewerItem item) async {
    final location = item.location;
    if (location == null) return;
    final notice = AppFeedback.of(context);
    final strings = Strings.of(context);
    await Clipboard.setData(ClipboardData(text: location));
    notice.notify(FeedbackKind.routine, strings.chaCopied);
  }

  Future<void> _openInApp(MediaViewerItem item, File file) async {
    await openArtifactViewer(
      context,
      name: _displayName(Strings.of(context), item),
      mimeType: item.mimeType,
      file: file,
      sizeBytes: _lengthOf(file),
      onOpenExternal: () => unawaited(_openOutside(item, file)),
      onShare: () => unawaited(_share(file)),
    );
  }

  /// Desktop's «Chat»: leaves the viewer for the conversation. Synchronous,
  /// so the chat is pushed over what was under the viewer.
  void _openChat(VoidCallback openChat) {
    Navigator.of(context).pop();
    openChat();
  }

  /// Pixel size of a picture the app holds (read from its header).
  Size? _dimensionsOf(int index) {
    final item = widget.items[index];
    final slot = _slot(index);
    if (item.kind != MediaViewerKind.image || slot.state != _Load.ready) {
      return null;
    }
    if (slot.dimensionsRead) return slot.dimensions;
    slot.dimensionsRead = true;
    final bytes = item.bytes;
    final file = slot.file;
    if (bytes != null) {
      slot.dimensions = imageDimensionsFromHeader(bytes);
    } else if (file != null) {
      slot.dimensions = MediaDimensionsCache.ofFileSync(file);
    }
    return slot.dimensions;
  }

  /// Bytes of the element at [index] when known: from the conversation, or
  /// from the copy the app holds.
  int? _sizeOf(int index) {
    final slot = _slot(index);
    if (slot.state != _Load.ready) return widget.items[index].sizeBytes;
    return slot.size ??= widget.items[index].sizeBytes ?? _lengthOf(slot.file);
  }

  // ---- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: _entering(_Scrim(onTap: _close))),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x2,
                _sheetTop,
                HermesSpace.x2,
                HermesSpace.x2,
              ),
              child: _rising(
                _DragToClose(
                  onClose: _close,
                  enabled: !_zoomed,
                  child: _sheet(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The scrim, fading in and out with the route.
  Widget _entering(Widget scrim) {
    final entrance = _entrance;
    if (entrance == null) return scrim;
    return FadeTransition(opacity: entrance, child: scrim);
  }

  /// The sheet, rising from below the screen and going back down.
  Widget _rising(Widget sheet) {
    final entrance = _entrance;
    if (entrance == null) return sheet;
    return SlideTransition(
      key: const ValueKey('media-viewer-rise'),
      position: entrance.drive(
        Tween(begin: const Offset(0, 1), end: Offset.zero),
      ),
      child: sheet,
    );
  }

  Widget _sheet(BuildContext context) {
    // Ola 3 (AUDITORIA-PULIDO T2): the sheet floats like the rest, in the
    // solid chrome with its hairline and shadow.
    final chrome = HermesChrome.of(Theme.of(context).hermes);
    return HermesSheen(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_sheetRadius),
      ),
      child: DecoratedBox(
        key: const ValueKey<String>('generated-image-viewer-safe-area'),
        decoration: BoxDecoration(
          color: chrome.opaque,
          borderRadius: BorderRadius.circular(_sheetRadius),
          border: Border.all(color: chrome.line),
          boxShadow: chrome.shadow,
        ),
        child: Material(
          // Ink of the card and the strip, painted on the sheet itself.
          type: MaterialType.transparency,
          child: LayoutBuilder(
            builder: (context, box) => Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x3,
                0,
                HermesSpace.x3,
                HermesSpace.x3,
              ),
              child: _sheetColumn(context, box.maxHeight),
            ),
          ),
        ),
      ),
    );
  }

  /// Handle, «n de N» with the capsule, the details card, the element and,
  /// when the sheet is tall enough (not a phone on its side), the strip.
  Widget _sheetColumn(BuildContext context, double height) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final item = _item;
    final file = _readyFile;
    final openChat = item.onOpenChat;
    final strip = _count > 1 && height >= _compactSheetHeight;
    return Column(
      children: [
        _Handle(onClose: _close),
        Row(
          children: [
            Expanded(child: _position(strings, colors)),
            _Capsule(
              onCopy: item.location == null
                  ? null
                  : () => unawaited(_copyLocation(item)),
              copyLabel: item.locationIsUrl
                  ? strings.artCopyUrl
                  : strings.artCopyPath,
              onShare: file == null ? null : () => unawaited(_share(file)),
              onSave: file == null ? null : () => unawaited(_save(file)),
              saveLabel: _savesToGallery
                  ? strings.imgSaveToGallery
                  : strings.commonSave,
            ),
          ],
        ),
        const SizedBox(height: HermesSpace.x2),
        _InfoCard(
          key: ValueKey<int>(_index),
          title: _title(strings, item, _index),
          meta: _meta(strings, _index),
          item: item,
          detailsHeight: height * .2,
          onOpenChat: openChat == null ? null : () => _openChat(openChat),
        ),
        const SizedBox(height: HermesSpace.x3),
        Expanded(child: _stageCard(colors)),
        if (strip) ...[
          const SizedBox(height: HermesSpace.x3),
          _Strip(
            controller: _strip,
            items: widget.items,
            index: _index,
            slotOf: _slot,
            onShown: _stripTileShown,
            onHidden: _stripTileHidden,
            titleOf: (i) => _title(strings, widget.items[i], i),
            onTap: _goTo,
          ),
        ],
      ],
    );
  }

  /// «n de N», read again by TalkBack when it changes.
  Widget _position(Strings strings, HermesThemeColors colors) {
    if (_count < 2) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Text(
        strings.mvPosition(_index + 1, _count),
        key: const ValueKey<String>('image-gallery-position'),
        // the owner: «n de N» in mono (L3).
        style: HermesType.support.copyWith(
          color: colors.textSecondary,
          fontFamily: HermesType.monoFamily,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  /// The mockup's «JPEG  1200 × 800 px  98 KB»: kind tag, pixel size of a
  /// picture and bytes, each when known.
  String _meta(Strings strings, int index) {
    final dimensions = _dimensionsOf(index);
    final size = _sizeOf(index);
    return [
      _typeLabel(strings, widget.items[index]),
      if (dimensions != null)
        strings.mvDimensions(
          dimensions.width.round(),
          dimensions.height.round(),
        ),
      if (size != null) _formatSize(size),
    ].join('  ');
  }

  /// The element in its card: the pages, and Desktop's zoom bar over a
  /// picture.
  Widget _stageCard(HermesThemeColors colors) {
    final item = _item;
    final zoomable =
        item.kind == MediaViewerKind.image &&
        !_isSvg(item) &&
        _slot(_index).state == _Load.ready;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _inset(colors),
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: colors.divider),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_cardRadius),
        child: Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, box) {
                  _stage = box.biggest;
                  return PageView.builder(
                    key: const ValueKey<String>('image-gallery-pages'),
                    controller: _pages,
                    physics: _zoomed || _count < 2
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    itemCount: _count,
                    onPageChanged: _onPage,
                    itemBuilder: (_, i) => _page(i),
                  );
                },
              ),
            ),
            if (zoomable)
              Positioned(
                left: 0,
                right: 0,
                bottom: HermesSpace.x3,
                child: Center(
                  child: _ZoomBar(
                    transform: _transform(_index),
                    onZoomOut: () => _zoomBy(1 / _buttonStep),
                    onReset: _resetZoom,
                    onZoomIn: () => _zoomBy(_buttonStep),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _page(int i) {
    final item = widget.items[i];
    final slot = _slot(i);
    final key = ValueKey<String>('image-gallery-page-$i');
    if (slot.state == _Load.failed) {
      return _Failure(
        key: key,
        item: item,
        problem: slot.problem,
        onRetry: item.load == null || !_retryable(slot.problem)
            ? null
            : () => _retry(i),
      );
    }
    switch (item.kind) {
      case MediaViewerKind.image:
        if (_isSvg(item)) return _document(i, key);
        if (slot.state == _Load.idle) _fetch(i);
        if (slot.state != _Load.ready) return _Loading(key: key);
        return _ImagePage(
          key: key,
          item: item,
          file: slot.file,
          transform: _transform(i),
          zoomed: i == _index && _zoomed,
          onZoomChanged: _setZoomed,
        );
      case MediaViewerKind.video:
      case MediaViewerKind.audio:
        final file = slot.file;
        if (slot.state != _Load.ready || file == null) {
          return _Poster(
            key: key,
            item: item,
            loading: slot.state == _Load.loading,
            onPlay: () => _play(i),
          );
        }
        if (item.kind == MediaViewerKind.audio) {
          return _AudioPage(
            key: key,
            item: item,
            file: file,
            sizeBytes: _sizeOf(i) ?? 0,
            autoplay: _autoplay.contains(i),
            playback: widget.audioPlayback?.call(),
            onShare: () => unawaited(_share(file)),
            onSave: () => unawaited(_save(file)),
          );
        }
        return Center(
          key: key,
          child: GeneratedVideoCard(
            key: ValueKey<String>('media-viewer-video-$i'),
            file: file,
            autoplay: _autoplay.contains(i),
          ),
        );
      case MediaViewerKind.document:
        return _document(i, key);
    }
  }

  Widget _document(int i, Key key) {
    final item = widget.items[i];
    // The cache keeps the name's extension, so the name tells it already.
    final outside =
        widget.launchExternal != null ||
        GeneratedMediaService.allowsExternalOpen(
          File(item.name ?? ''),
          mimeType: item.mimeType,
        );
    return _DocumentPage(
      key: key,
      item: item,
      slot: _slot(i),
      onView: () => _act(i, (file) => _openInApp(item, file)),
      onOpenOutside: outside
          ? () => _act(i, (file) => _openOutside(item, file))
          : null,
      onSave: () => _act(i, _save),
    );
  }
}

/// A retry cannot change these: the link, the scheme or the content.
bool _retryable(ArtifactFetchProblem? problem) => switch (problem) {
  ArtifactFetchProblem.insecure ||
  ArtifactFetchProblem.unsupported ||
  ArtifactFetchProblem.notImage ||
  ArtifactFetchProblem.undecodable => false,
  _ => true,
};

/// The side a picture is decoded at for [pixels] of stage: the next power
/// of two from 256 to [_maxDecodedSide], so a small change of the stage
/// (the keyboard, the details card) does not decode it again.
int _decodeSide(double pixels) {
  var side = 256;
  while (side < pixels && side < _maxDecodedSide) {
    side *= 2;
  }
  return side;
}

/// Flutter does not paint SVG; the artifact viewer's WebView does.
bool _isSvg(MediaViewerItem item) {
  final kind = artifactViewerKindFor(
    name: item.name ?? '',
    mimeType: item.mimeType,
  );
  return kind == ArtifactViewerKind.svg;
}

String _kindWord(Strings strings, MediaViewerKind kind) => switch (kind) {
  MediaViewerKind.image => strings.sa1215KindImage,
  MediaViewerKind.video => strings.artTypeVideo,
  MediaViewerKind.audio => strings.artTypeAudio,
  MediaViewerKind.document => strings.sa1215KindFile,
};

String _displayName(Strings strings, MediaViewerItem item) {
  final name = item.name?.trim();
  return name == null || name.isEmpty ? _kindWord(strings, item.kind) : name;
}

/// The title of the details card: the element's name, or «Imagen 1» when
/// it has none (the chat's own pictures).
String _title(Strings strings, MediaViewerItem item, int index) {
  final name = item.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  return strings.mvKindNumbered(_kindWord(strings, item.kind), index + 1);
}

/// Desktop's kind tag: the extension (`PNG`, `PDF`), else the kind word.
String _typeLabel(Strings strings, MediaViewerItem item) {
  final given = item.typeLabel;
  if (given != null) return given;
  final name = item.name ?? '';
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1 && name.length - dot <= 9) {
    return name.substring(dot + 1).toUpperCase();
  }
  return _kindWord(strings, item.kind);
}

IconData _kindIcon(MediaViewerKind kind) => switch (kind) {
  MediaViewerKind.image => Icons.image_outlined,
  MediaViewerKind.video => Icons.movie_outlined,
  MediaViewerKind.audio => Icons.audiotrack_outlined,
  MediaViewerKind.document => Icons.insert_drive_file_outlined,
};

// ---- Sheet -----------------------------------------------------------------

/// The cards inside the sheet: a shade off its surface, in either theme.
Color _inset(HermesThemeColors colors) =>
    Color.alphaBlend(colors.textPrimary.withValues(alpha: .04), colors.surface);

/// The capsules (actions, zoom): a shade further, with the theme's border.
BoxDecoration _chrome(HermesThemeColors colors) {
  return BoxDecoration(
    color: Color.alphaBlend(
      colors.textPrimary.withValues(alpha: .08),
      colors.surface,
    ),
    borderRadius: BorderRadius.circular(HermesRadius.tag),
    border: Border.all(color: colors.divider),
  );
}

/// The chat behind the sheet, dimmed and blurred; a tap on it closes.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: FrostedBackdrop(
          sigma: 12,
          zone: FrostedZone.overlay,
          zonePriority: -1,
          tint: HermesScrim.sheet.color,
          borderRadius: BorderRadius.zero,
          builder: (_, fill) => ColoredBox(color: fill),
        ),
      ),
    );
  }
}

/// The sheet's handle: tap it, or drag the sheet down, to close. It is
/// the close button for TalkBack.
class _Handle extends StatelessWidget {
  const _Handle({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Semantics(
      label: strings.commonClose,
      button: true,
      onTap: onClose,
      excludeSemantics: true,
      child: Tooltip(
        message: strings.commonClose,
        child: GestureDetector(
          key: const ValueKey('media-viewer-handle'),
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          child: SizedBox(
            width: 120,
            height: 48,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.textSecondary.withValues(alpha: .5),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const SizedBox(width: 40, height: 4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Copy, share and save, in the mockup's capsule. Each one only when it
/// can act: a path or URL to copy, a file in the app to share or save.
class _Capsule extends StatelessWidget {
  const _Capsule({
    required this.onCopy,
    required this.copyLabel,
    required this.onShare,
    required this.onSave,
    required this.saveLabel,
  });

  final VoidCallback? onCopy;
  final String copyLabel;
  final VoidCallback? onShare;
  final VoidCallback? onSave;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final copy = onCopy;
    final share = onShare;
    final save = onSave;
    if (copy == null && share == null && save == null) {
      return const SizedBox(height: 48);
    }
    return DecoratedBox(
      decoration: _chrome(colors),
      child: IconTheme.merge(
        data: IconThemeData(color: colors.textPrimary),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (copy != null)
              IconButton(
                key: const ValueKey('media-viewer-copy'),
                icon: const Icon(Icons.copy_rounded),
                tooltip: copyLabel,
                onPressed: copy,
              ),
            if (share != null)
              IconButton(
                key: const ValueKey('media-viewer-share'),
                icon: const Icon(Icons.ios_share),
                tooltip: strings.commonShare,
                onPressed: share,
              ),
            if (save != null)
              IconButton(
                key: const ValueKey('media-viewer-save'),
                icon: const Icon(Icons.download_rounded),
                tooltip: saveLabel,
                onPressed: save,
              ),
          ],
        ),
      ),
    );
  }
}

/// The details card: its title and «JPEG  1200 × 800 px  98 KB». A tap
/// opens the rest: path or URL, conversation (with Desktop's «Chat») and
/// date.
class _InfoCard extends StatefulWidget {
  const _InfoCard({
    required this.title,
    required this.meta,
    required this.item,
    required this.detailsHeight,
    required this.onOpenChat,
    super.key,
  });

  final String title;
  final String meta;
  final MediaViewerItem item;

  /// Most the open details take; they scroll beyond.
  final double detailsHeight;
  final VoidCallback? onOpenChat;

  @override
  State<_InfoCard> createState() => _InfoCardState();
}

class _InfoCardState extends State<_InfoCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final item = widget.item;
    final when = item.timestamp;
    final conversation = item.conversation;
    final rows = <(String, String)>[
      if (item.location case final location?) (strings.mvLocation, location),
      if (conversation != null) (strings.mvConversation, conversation),
      if (when != null)
        (strings.mvDate, DateFormat.yMMMd(locale).add_Hm().format(when)),
    ];
    final expandable = rows.isNotEmpty;
    final radius = BorderRadius.circular(HermesRadius.control);
    final summary = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.x4,
        vertical: HermesSpace.x3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            key: const ValueKey('media-viewer-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: HermesSpace.x1),
          Text(
            widget.meta,
            key: const ValueKey('media-viewer-meta'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            // the owner: the viewer's metadata in mono (L3).
            style: HermesType.text.copyWith(
              color: colors.textPrimary,
              fontFamily: HermesType.monoFamily,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    return DecoratedBox(
      key: const ValueKey('media-viewer-info'),
      decoration: BoxDecoration(
        color: _inset(colors),
        borderRadius: radius,
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: expandable,
            expanded: expandable ? _open : null,
            hint: expandable ? strings.mvDetails : null,
            child: InkWell(
              borderRadius: radius,
              onTap: expandable ? () => setState(() => _open = !_open) : null,
              child: summary,
            ),
          ),
          if (_open)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.detailsHeight),
              child: SingleChildScrollView(
                key: const ValueKey('media-viewer-details'),
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.x4,
                  0,
                  HermesSpace.x4,
                  HermesSpace.x3,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (label, value) in rows)
                      _DetailRow(label: label, value: value),
                    if (widget.onOpenChat != null && conversation != null)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          key: const ValueKey('media-viewer-open-chat'),
                          onPressed: widget.onOpenChat,
                          icon: const Icon(Icons.forum_outlined, size: 18),
                          label: Text(
                            strings.artChat,
                            semanticsLabel: strings.artOpenChat(conversation),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(bottom: HermesSpace.x2),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
            SelectableText(
              value,
              style: HermesType.body.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Desktop's zoom bar: −, the scale (tap resets it) and +.
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({
    required this.transform,
    required this.onZoomOut,
    required this.onReset,
    required this.onZoomIn,
  });

  final TransformationController transform;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final VoidCallback onZoomIn;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return ValueListenableBuilder<Matrix4>(
      valueListenable: transform,
      builder: (context, matrix, _) {
        final scale = matrix.getMaxScaleOnAxis();
        final percent = NumberFormat.percentPattern(locale).format(scale);
        return HermesLiquidSurface(
          liquid: HermesLiquid.overlay,
          tint: _chrome(colors).color,
          zone: FrostedZone.overlay,
          priority: 1,
          // The viewer's drag-to-close owner is not this toolbar.
          shaderEnabled: false,
          maxFilterArea: HermesLiquid.overlayFilterArea,
          builder: (context, fill) => DecoratedBox(
            key: const ValueKey('media-viewer-zoom'),
            decoration: _chrome(colors).copyWith(color: fill),
            child: IconTheme.merge(
              data: IconThemeData(color: colors.textPrimary),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('media-viewer-zoom-out'),
                    icon: const Icon(Icons.zoom_out_rounded),
                    tooltip: strings.mvZoomOut,
                    onPressed: scale <= _minScale + 0.001 ? null : onZoomOut,
                  ),
                  Semantics(
                    button: true,
                    label: strings.mvZoomReset(percent),
                    excludeSemantics: true,
                    onTap: onReset,
                    child: TextButton(
                      key: const ValueKey('media-viewer-zoom-reset'),
                      onPressed: onReset,
                      child: Text(
                        percent,
                        style: HermesType.support.copyWith(
                          color: colors.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('media-viewer-zoom-in'),
                    icon: const Icon(Icons.zoom_in_rounded),
                    tooltip: strings.mvZoomIn,
                    onPressed: scale >= _maxScale - 0.001 ? null : onZoomIn,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The thumbnails of the group under the element, five on screen, the one
/// on screen highlighted. A picture's tile asks for it once the tile is on
/// screen (a thumbnail seen), three at a time; nothing off screen is built
/// or fetched.
class _Strip extends StatelessWidget {
  const _Strip({
    required this.controller,
    required this.items,
    required this.index,
    required this.slotOf,
    required this.onShown,
    required this.onHidden,
    required this.titleOf,
    required this.onTap,
  });

  final ScrollController controller;
  final List<MediaViewerItem> items;
  final int index;
  final _Slot Function(int index) slotOf;

  /// A picture's tile came on screen, or left it.
  final ValueChanged<int> onShown;
  final ValueChanged<int> onHidden;
  final String Function(int index) titleOf;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final width = _stripTileWidth(box.maxWidth);
        // Never under the 48 dp touch target, even on a 360 dp phone.
        final height = math.max(
          HermesSpace.tap,
          math.min(width * _stripAspect, _stripMaxHeight),
        );
        return SizedBox(
          height: height,
          child: ListView.separated(
            key: const ValueKey('media-viewer-strip'),
            controller: controller,
            scrollDirection: Axis.horizontal,
            // Only the visible thumbnails build (nothing is fetched ahead).
            // `scrollCacheExtent` is the replacement, but its type is not
            // available in every SDK this project builds with.
            // ignore: deprecated_member_use
            cacheExtent: 0,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: _stripGap),
            itemBuilder: (context, i) {
              final item = items[i];
              final picture =
                  item.kind == MediaViewerKind.image && !_isSvg(item);
              ImageProvider? image;
              if (picture && slotOf(i).state == _Load.ready) {
                image = _imageProvider(item, slotOf(i).file);
              }
              return _StripTile(
                key: ValueKey('media-viewer-strip-$i'),
                onShown: picture ? () => onShown(i) : null,
                onHidden: picture ? () => onHidden(i) : null,
                kind: item.kind,
                image: image,
                selected: i == index,
                label: strings.mvGoTo(titleOf(i), i + 1, items.length),
                size: Size(width, height),
                onTap: () => onTap(i),
              );
            },
          ),
        );
      },
    );
  }
}

/// One thumbnail of the strip: the picture when the app holds it, else
/// the icon of its kind; the one on screen with the accent border. It tells
/// the viewer when it comes on screen and when it leaves.
class _StripTile extends StatefulWidget {
  const _StripTile({
    required this.onShown,
    required this.onHidden,
    required this.kind,
    required this.image,
    required this.selected,
    required this.label,
    required this.size,
    required this.onTap,
    super.key,
  });

  final VoidCallback? onShown;
  final VoidCallback? onHidden;
  final MediaViewerKind kind;
  final ImageProvider? image;
  final bool selected;
  final String label;
  final Size size;
  final VoidCallback onTap;

  @override
  State<_StripTile> createState() => _StripTileState();
}

class _StripTileState extends State<_StripTile> {
  @override
  void initState() {
    super.initState();
    widget.onShown?.call();
  }

  @override
  void dispose() {
    widget.onHidden?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(HermesRadius.control);
    final kind = widget.kind;
    final selected = widget.selected;
    final size = widget.size;
    final onTap = widget.onTap;
    final icon = Icon(_kindIcon(kind), color: colors.textSecondary);
    final picture = widget.image;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          width: size.width,
          height: size.height,
          clipBehavior: Clip.antiAlias,
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: selected
                ? Border.all(color: colors.accent, width: 2.5)
                : null,
          ),
          decoration: BoxDecoration(
            color: _inset(colors),
            borderRadius: radius,
          ),
          child: picture == null
              ? Center(child: icon)
              : Image(
                  // Bounded both ways: a very tall picture is not decoded
                  // at its full height for a small tile.
                  image: ResizeImage(
                    picture,
                    width: 160,
                    height: 160,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(child: icon),
                ),
        ),
      ),
    );
  }
}

/// Bytes as the mockup writes them: «98 kB», «1.4 MB», «70 B».
String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} kB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

int? _lengthOf(File? file) {
  if (file == null) return null;
  try {
    return file.lengthSync();
  } on FileSystemException {
    return null;
  }
}

ImageProvider? _imageProvider(MediaViewerItem item, File? file) {
  final bytes = item.bytes;
  if (bytes != null) return MemoryImage(bytes);
  if (file != null) return FileImage(file);
  final url = item.imageUrl;
  if (url != null) return NetworkImage(url);
  return null;
}

// ---- Pages -----------------------------------------------------------------

/// Leaves the viewer when a page is dragged far enough down or up.
class _DragToClose extends StatefulWidget {
  const _DragToClose({
    required this.onClose,
    required this.child,
    this.enabled = true,
  });

  final VoidCallback onClose;
  final Widget child;

  /// Off while a picture is zoomed: the drag pans it instead.
  final bool enabled;

  @override
  State<_DragToClose> createState() => _DragToCloseState();
}

class _DragToCloseState extends State<_DragToClose>
    with SingleTickerProviderStateMixin {
  double _dy = 0;

  /// Let go far enough: the route takes the sheet out from where the finger
  /// left it (audit FLUIDEZ B1: it used to jump back up first).
  bool _closing = false;

  /// Let go short of it: the sheet goes back to its place.
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: HermesMotion.base,
  )..addListener(_onBack);
  double _backFrom = 0;

  void _onBack() {
    final eased = HermesMotion.emphasized.transform(_back.value);
    setState(() => _dy = _backFrom * (1 - eased));
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails details) {
    if (_closing) return;
    _back.stop();
    setState(() => _dy += details.delta.dy);
  }

  void _end(DragEndDetails details) {
    if (_closing) return;
    final velocity = details.velocity.pixelsPerSecond.dy.abs();
    if (_dy.abs() > _dismissDistance || velocity > _dismissVelocity) {
      _closing = true;
      widget.onClose();
      // Something kept the route (a pop handler): back to its place.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
        _closing = false;
        _settleBack();
      });
      return;
    }
    _settleBack();
  }

  void _cancel() {
    if (!_closing) _settleBack();
  }

  void _settleBack() {
    if (_dy == 0) return;
    if (HermesMotion.reduced(context)) {
      setState(() => _dy = 0);
      return;
    }
    _backFrom = _dy;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // Same tree either way, so the page keeps its state when zoom changes.
    final on = widget.enabled;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: on ? _update : null,
      onVerticalDragEnd: on ? _end : null,
      onVerticalDragCancel: on ? _cancel : null,
      child: Transform.translate(offset: Offset(0, _dy), child: widget.child),
    );
  }
}

class _ImagePage extends StatefulWidget {
  const _ImagePage({
    required this.item,
    required this.file,
    required this.transform,
    required this.zoomed,
    required this.onZoomChanged,
    super.key,
  });

  final MediaViewerItem item;
  final File? file;
  final TransformationController transform;

  /// At fit size the picture does not pan: a drag pages or closes.
  final bool zoomed;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage> {
  TapDownDetails? _doubleTapDetails;
  bool _broken = false;

  /// Zoomed past 2× once: from then on the picture's own resolution.
  bool _fullResolution = false;

  double get _scale => widget.transform.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    widget.transform.addListener(_onTransform);
  }

  @override
  void didUpdateWidget(_ImagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transform != widget.transform) {
      oldWidget.transform.removeListener(_onTransform);
      widget.transform.addListener(_onTransform);
    }
  }

  @override
  void dispose() {
    widget.transform.removeListener(_onTransform);
    super.dispose();
  }

  void _onTransform() {
    if (_fullResolution || _scale <= _fullResolutionScale) return;
    setState(() => _fullResolution = true);
  }

  void _toggleZoom() {
    if (widget.transform.value != Matrix4.identity()) {
      widget.transform.value = Matrix4.identity();
      widget.onZoomChanged(false);
      return;
    }
    final point = _doubleTapDetails?.localPosition ?? Offset.zero;
    widget.transform.value = Matrix4.identity()
      ..translateByDouble(-point.dx * 2, -point.dy * 2, 0, 1)
      ..scaleByDouble(3, 3, 1, 1);
    widget.onZoomChanged(true);
  }

  void _onInteractionEnd(ScaleEndDetails details) =>
      widget.onZoomChanged((_scale - 1).abs() > 0.01);

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final image = _imageProvider(widget.item, widget.file);
    if (image == null || _broken) {
      // It arrived but cannot be drawn: say that, not a bare failure.
      return _Failure(
        item: widget.item,
        problem: image == null
            ? ArtifactFetchProblem.failed
            : ArtifactFetchProblem.undecodable,
        onRetry: null,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final side = _decodeSide(box.biggest.longestSide * ratio * 2);
        final shown = _fullResolution
            ? image
            : ResizeImage(
                image,
                width: side,
                height: side,
                policy: ResizeImagePolicy.fit,
              );
        return _zoomable(strings, shown);
      },
    );
  }

  Widget _zoomable(Strings strings, ImageProvider image) {
    Widget picture = Image(
      image: image,
      fit: BoxFit.contain,
      // Switching to the full resolution keeps the picture on screen.
      gaplessPlayback: true,
      semanticLabel: _displayName(strings, widget.item),
      errorBuilder: (_, _, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_broken) setState(() => _broken = true);
        });
        return const SizedBox.shrink();
      },
    );
    final hero = widget.item.heroTag;
    if (hero != null) picture = Hero(tag: hero, child: picture);
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: widget.transform,
        minScale: _minScale,
        maxScale: _maxScale,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        panEnabled: widget.zoomed,
        onInteractionEnd: _onInteractionEnd,
        child: SizedBox.expand(child: Center(child: picture)),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Center(
      key: const ValueKey('media-viewer-loading'),
      child: ConsoleLoader.small(label: strings.artThumbLoading),
    );
  }
}

/// What a page that is not a picture shows inside the element's card,
/// centred. It scrolls only when it does not fit, so a drag on it moves
/// the sheet: the app's behaviour would make it always scrollable.
class _Panel extends StatelessWidget {
  const _Panel({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scroll = ScrollConfiguration.of(context);
    return Center(
      child: ScrollConfiguration(
        behavior: scroll.copyWith(physics: const ClampingScrollPhysics()),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(HermesSpace.x5),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The heading of a card: kind icon, name and kind tag · size.
class _CardHeading extends StatelessWidget {
  const _CardHeading({required this.item, this.sizeBytes, this.icon});

  final MediaViewerItem item;
  final int? sizeBytes;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final size = sizeBytes ?? item.sizeBytes;
    final tag = [
      _typeLabel(strings, item),
      if (size != null) _formatSize(size),
    ].join(' · ');
    return Column(
      children: [
        Icon(icon ?? _kindIcon(item.kind), size: 48, color: colors.accent),
        const SizedBox(height: HermesSpace.x3),
        Text(
          _displayName(strings, item),
          textAlign: TextAlign.center,
          style: HermesType.title.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: HermesSpace.x1),
        Text(
          tag,
          textAlign: TextAlign.center,
          style: HermesType.support.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// The reason an element cannot be shown, as its thumbnail says it.
class _Failure extends StatelessWidget {
  const _Failure({
    required this.item,
    required this.problem,
    required this.onRetry,
    super.key,
  });

  final MediaViewerItem item;
  final ArtifactFetchProblem? problem;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final retry = onRetry;
    return _Panel(
      key: const ValueKey('media-viewer-failure'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CardHeading(
            item: item,
            icon: item.kind == MediaViewerKind.image
                ? Icons.broken_image_outlined
                : null,
          ),
          const SizedBox(height: HermesSpace.x4),
          Text(
            artifactFetchReason(strings, problem),
            key: const ValueKey('media-viewer-reason'),
            textAlign: TextAlign.center,
            style: HermesType.body.copyWith(color: colors.textPrimary),
          ),
          if (retry != null) ...[
            const SizedBox(height: HermesSpace.x4),
            HermesSecondaryButton(
              key: const ValueKey('media-viewer-retry'),
              label: strings.artThumbRetry,
              icon: Icons.refresh_rounded,
              onTap: retry,
            ),
          ],
        ],
      ),
    );
  }
}

/// A video or audio not fetched yet: Desktop's `preload="none"`, nothing
/// is downloaded until «Reproducir».
class _Poster extends StatelessWidget {
  const _Poster({
    required this.item,
    required this.loading,
    required this.onPlay,
    super.key,
  });

  final MediaViewerItem item;
  final bool loading;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return _Panel(
      key: const ValueKey('media-viewer-poster'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CardHeading(item: item),
          const SizedBox(height: HermesSpace.x4),
          if (loading)
            ConsoleLoader.small(label: strings.artThumbLoading)
          else
            HermesPrimaryButton(
              key: const ValueKey('media-viewer-play'),
              label: strings.mvPlay,
              icon: Icons.play_arrow_rounded,
              onTap: onPlay,
            ),
        ],
      ),
    );
  }
}

class _AudioPage extends StatelessWidget {
  const _AudioPage({
    required this.item,
    required this.file,
    required this.sizeBytes,
    required this.autoplay,
    required this.playback,
    required this.onShare,
    required this.onSave,
    super.key,
  });

  final MediaViewerItem item;
  final File file;
  final int sizeBytes;
  final bool autoplay;
  final GeneratedAudioPlayback? playback;
  final VoidCallback onShare;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return _Panel(
      key: const ValueKey('media-viewer-audio'),
      child: GeneratedAudioPlayerCard(
        file: file,
        name: _displayName(strings, item),
        mimeType: item.mimeType,
        sizeBytes: sizeBytes,
        onShare: onShare,
        onSave: onSave,
        showOpenAction: false,
        autoplay: autoplay,
        playback: playback,
      ),
    );
  }
}

/// A document: what it is, and Desktop's way to open it (outside), plus
/// the app's own viewer for what it renders (text, Markdown, HTML, SVG).
/// Fetched only when one of them is tapped.
class _DocumentPage extends StatelessWidget {
  const _DocumentPage({
    required this.item,
    required this.slot,
    required this.onView,
    required this.onOpenOutside,
    required this.onSave,
    super.key,
  });

  final MediaViewerItem item;
  final _Slot slot;
  final VoidCallback onView;

  /// Null for what Android must not open (an installer).
  final VoidCallback? onOpenOutside;
  final VoidCallback onSave;

  bool get _viewable {
    final kind = artifactViewerKindFor(
      name: item.name ?? '',
      mimeType: item.mimeType,
    );
    return switch (kind) {
      ArtifactViewerKind.html ||
      ArtifactViewerKind.svg ||
      ArtifactViewerKind.markdown ||
      ArtifactViewerKind.text => true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final loading = slot.state == _Load.loading;
    return _Panel(
      key: const ValueKey('media-viewer-document'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeading(item: item, sizeBytes: slot.size),
          const SizedBox(height: HermesSpace.x4),
          if (loading)
            Center(child: ConsoleLoader.small(label: strings.artThumbLoading))
          else ...[
            if (_viewable) ...[
              HermesPrimaryButton(
                key: const ValueKey('media-viewer-view'),
                label: strings.mvView,
                icon: Icons.visibility_outlined,
                onTap: onView,
              ),
              const SizedBox(height: HermesSpace.x2),
            ],
            if (onOpenOutside case final open?) ...[
              HermesSecondaryButton(
                key: const ValueKey('media-viewer-open-outside'),
                label: strings.vw1215OpenOutside,
                icon: Icons.open_in_new_rounded,
                onTap: open,
              ),
              const SizedBox(height: HermesSpace.x2),
            ],
            HermesSecondaryButton(
              key: const ValueKey('media-viewer-save-file'),
              label: strings.commonSave,
              icon: Icons.save_alt_rounded,
              onTap: onSave,
            ),
          ],
        ],
      ),
    );
  }
}
