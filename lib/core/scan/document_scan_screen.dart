import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'scan_image_ops.dart';
import 'scan_platform.dart';

/// A file produced by the scanner, still in memory.
class ScanFile {
  const ScanFile({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

/// What the scanner hands back: one PNG per page, or a single PDF.
class ScanResult {
  const ScanResult({required this.files, required this.isPdf});

  final List<ScanFile> files;
  final bool isPdf;
}

/// Budget of one exported image (the composer takes 8 MiB per file and
/// 24 MiB per message, so a many-page scan is shrunk to stay inside).
const int kScanImageBudgetBytes = 5 * 1024 * 1024;
const int kScanBatchBudgetBytes = 20 * 1024 * 1024;
const int kScanPdfBudgetBytes = 7 * 1024 * 1024;

/// Longest side of an exported page and of its on-screen preview.
const int kScanExportMaxSide = 2000;
const int kScanPreviewMaxSide = 900;

/// Smallest share of the photo the four corners must enclose.
const double kScanMinCropArea = 0.03;

class _ScanPage {
  _ScanPage(this.full, this.preview, this.filter);

  final ScanBitmap full;
  final ScanBitmap preview;
  ScanFilter filter;
  int turns = 0;
  Uint8List? previewPng;
  int version = 0;
}

class _Crop {
  _Crop(this.bytes, this.rgba)
    : corners = const [
        Offset(0.06, 0.06),
        Offset(0.94, 0.06),
        Offset(0.94, 0.94),
        Offset(0.06, 0.94),
      ];

  final Uint8List bytes;
  final ScanRgba rgba;
  List<Offset> corners;

  List<ScanPoint> get points => [
    for (final c in corners) ScanPoint(c.dx * rgba.width, c.dy * rgba.height),
  ];

  bool get usable {
    final p = points;
    return isConvexQuad(p) &&
        quadArea(p) >= kScanMinCropArea * rgba.width * rgba.height;
  }
}

/// Document scanner: photo or gallery image, four draggable corners,
/// perspective correction, enhancement, several pages, and export as images
/// or as a PDF. Pops with a [ScanResult] (or `null` when abandoned).
///
/// Every platform edge is injectable so the flow can run on synthetic images.
class DocumentScanScreen extends StatefulWidget {
  const DocumentScanScreen({
    super.key,
    this.maxPages = 10,
    this.imageSource = pickScanImageFromPlatform,
    this.decoder = decodeScanImage,
    this.runner = runScanOnIsolate,
    this.clock,
  });

  /// Pages the message can still take.
  final int maxPages;
  final Future<Uint8List?> Function(ScanImageOrigin origin) imageSource;
  final Future<ScanRgba?> Function(Uint8List bytes) decoder;
  final ScanRunner runner;
  final DateTime Function()? clock;

  @override
  State<DocumentScanScreen> createState() => _DocumentScanScreenState();
}

class _DocumentScanScreenState extends State<DocumentScanScreen> {
  final List<_ScanPage> _pages = [];
  _Crop? _crop;
  int _current = 0;
  bool _adding = false;
  bool _busy = false;
  bool _failed = false;
  ScanFilter _lastFilter = ScanFilter.contrast;

  bool get _atPageLimit => _pages.length >= widget.maxPages;

  Future<void> _acquire(ScanImageOrigin origin) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final bytes = await widget.imageSource(origin);
      if (bytes == null || !mounted) return;
      final rgba = await widget.decoder(bytes);
      if (!mounted) return;
      if (rgba == null) {
        setState(() => _failed = true);
        return;
      }
      setState(() {
        _crop = _Crop(bytes, rgba);
        _adding = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmCrop() async {
    final crop = _crop;
    if (crop == null || _busy || !crop.usable) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final quad = orderCorners(crop.points);
      final result = await scanWarpOn(
        widget.runner,
        ScanWarpRequest(
          crop.rgba,
          quad,
          kScanExportMaxSide,
          kScanPreviewMaxSide,
        ),
      );
      if (!mounted) return;
      if (result == null) {
        setState(() => _failed = true);
        return;
      }
      final page = _ScanPage(result.full, result.preview, _lastFilter);
      setState(() {
        _pages.add(page);
        _current = _pages.length - 1;
        _crop = null;
      });
      unawaited(_renderPreview(page));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renderPreview(_ScanPage page) async {
    final version = ++page.version;
    try {
      final png = await scanPreviewOn(
        widget.runner,
        ScanRenderRequest(page.preview, page.filter, page.turns),
      );
      if (!mounted || version != page.version) return;
      setState(() => page.previewPng = png);
    } catch (_) {
      if (mounted && version == page.version) setState(() => _failed = true);
    }
  }

  void _setFilter(ScanFilter filter) {
    final page = _pages[_current];
    if (page.filter == filter) return;
    setState(() {
      page.filter = filter;
      _lastFilter = filter;
    });
    unawaited(_renderPreview(page));
  }

  void _rotate() {
    final page = _pages[_current];
    setState(() => page.turns = (page.turns + 1) % 4);
    unawaited(_renderPreview(page));
  }

  void _deletePage() {
    setState(() {
      _pages.removeAt(_current);
      _current = math.max(0, math.min(_current, _pages.length - 1));
      _adding = false;
    });
  }

  String _stamp() {
    final t = (widget.clock ?? DateTime.now)();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'scan-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Future<void> _export({required bool pdf}) async {
    if (_busy || _pages.isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final requests = [
        for (final p in _pages) ScanRenderRequest(p.full, p.filter, p.turns),
      ];
      final budget = pdf
          ? kScanPdfBudgetBytes
          : math.min(
              kScanImageBudgetBytes,
              kScanBatchBudgetBytes ~/ requests.length,
            );
      final encoded = await scanExportOn(
        widget.runner,
        ScanExportRequest(requests, pdf, budget),
      );
      if (!mounted) return;
      final stamp = _stamp();
      final files = pdf
          ? [
              ScanFile(
                name: '$stamp.pdf',
                mimeType: 'application/pdf',
                bytes: encoded.first,
              ),
            ]
          : [
              for (var i = 0; i < encoded.length; i++)
                ScanFile(
                  name: '$stamp-${i + 1}.png',
                  mimeType: 'image/png',
                  bytes: encoded[i],
                ),
            ];
      Navigator.of(context).pop(ScanResult(files: files, isPdf: pdf));
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    }
  }

  bool get _canLeave => _crop == null && !_adding;

  void _stepBack() {
    setState(() {
      if (_crop != null) {
        _crop = null;
      } else {
        _adding = false;
      }
      _failed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final Widget body;
    if (_crop != null) {
      body = _cropView(context, s, colors, _crop!);
    } else if (_pages.isEmpty || _adding) {
      body = _startView(context, s, colors);
    } else {
      body = _reviewView(context, s, colors);
    }
    return PopScope(
      canPop: _canLeave,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _stepBack();
      },
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          foregroundColor: colors.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            s.scanDocTitle,
            style: HermesType.title.copyWith(color: colors.textPrimary),
          ),
          bottom: _busy
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    key: const ValueKey('scanDoc-busy'),
                    minHeight: 2,
                    color: colors.accent,
                    backgroundColor: colors.divider,
                  ),
                )
              : null,
        ),
        body: SafeArea(top: false, child: body),
      ),
    );
  }

  Widget _errorLine(Strings s, HermesThemeColors colors) => Padding(
    padding: const EdgeInsets.only(bottom: HermesSpace.x3),
    child: Text(
      s.scanDocError,
      key: const ValueKey('scanDoc-error'),
      textAlign: TextAlign.center,
      style: HermesType.support.copyWith(color: colors.error),
    ),
  );

  Widget _startView(BuildContext context, Strings s, HermesThemeColors colors) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(HermesSpace.x6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.scanDocStartHint,
                textAlign: TextAlign.center,
                style: HermesType.body.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: HermesSpace.x6),
              if (_failed) _errorLine(s, colors),
              if (_atPageLimit && _pages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: HermesSpace.x3),
                  child: Text(
                    s.scanDocPageLimit(widget.maxPages),
                    textAlign: TextAlign.center,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              FilledButton(
                key: const ValueKey('scanDoc-take-photo'),
                onPressed: _busy || _atPageLimit
                    ? null
                    : () => _acquire(ScanImageOrigin.camera),
                child: Text(s.scanDocTakePhoto),
              ),
              const SizedBox(height: HermesSpace.x3),
              OutlinedButton(
                key: const ValueKey('scanDoc-from-gallery'),
                onPressed: _busy || _atPageLimit
                    ? null
                    : () => _acquire(ScanImageOrigin.gallery),
                child: Text(s.scanDocFromGallery),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cropView(
    BuildContext context,
    Strings s,
    HermesThemeColors colors,
    _Crop crop,
  ) {
    final usable = crop.usable;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x4,
            vertical: HermesSpace.x2,
          ),
          child: Text(
            usable ? s.scanDocCropHint : s.scanDocCropInvalid,
            key: const ValueKey('scanDoc-crop-hint'),
            textAlign: TextAlign.center,
            style: HermesType.support.copyWith(
              color: usable ? colors.textSecondary : colors.error,
            ),
          ),
        ),
        Expanded(
          child: _CropEditor(
            key: const ValueKey('scanDoc-crop'),
            bytes: crop.bytes,
            imageWidth: crop.rgba.width,
            imageHeight: crop.rgba.height,
            corners: crop.corners,
            semanticLabel: s.scanDocCropArea,
            cornerLabel: s.scanDocCorner,
            colors: colors,
            onMoved: (index, value) => setState(() {
              crop.corners = [
                for (var i = 0; i < 4; i++)
                  i == index ? value : crop.corners[i],
              ];
            }),
          ),
        ),
        if (_failed) _errorLine(s, colors),
        Padding(
          padding: const EdgeInsets.all(HermesSpace.x4),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: HermesSpace.x3,
            runSpacing: HermesSpace.x2,
            children: [
              TextButton(
                key: const ValueKey('scanDoc-crop-reset'),
                onPressed: () => setState(() {
                  crop.corners = _Crop(crop.bytes, crop.rgba).corners;
                }),
                child: Text(s.scanDocCropReset),
              ),
              FilledButton(
                key: const ValueKey('scanDoc-crop-continue'),
                onPressed: usable && !_busy ? _confirmCrop : null,
                child: Text(s.scanDocCropContinue),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _filterLabel(Strings s, ScanFilter filter) => switch (filter) {
    ScanFilter.original => s.scanDocFilterOriginal,
    ScanFilter.grayscale => s.scanDocFilterGray,
    ScanFilter.contrast => s.scanDocFilterContrast,
    ScanFilter.blackWhite => s.scanDocFilterBw,
  };

  Widget _reviewView(
    BuildContext context,
    Strings s,
    HermesThemeColors colors,
  ) {
    final page = _pages[_current];
    final png = page.previewPng;
    final preview = Semantics(
      label: s.scanDocPageOf(_current + 1, _pages.length),
      image: true,
      child: Container(
        key: const ValueKey('scanDoc-preview'),
        margin: const EdgeInsets.all(HermesSpace.x4),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(HermesRadius.control),
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: png == null
            ? const CircularProgressIndicator()
            : Image.memory(
                png,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
      ),
    );
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        0,
        HermesSpace.x4,
        HermesSpace.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.scanDocPageOf(_current + 1, _pages.length),
            key: const ValueKey('scanDoc-page-of'),
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          if (_pages.length > 1) ...[
            const SizedBox(height: HermesSpace.x2),
            Wrap(
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x2,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  ChoiceChip(
                    key: ValueKey('scanDoc-page-$i'),
                    label: Text((i + 1).toString()),
                    selected: i == _current,
                    onSelected: (_) => setState(() => _current = i),
                  ),
              ],
            ),
          ],
          const SizedBox(height: HermesSpace.x3),
          Wrap(
            spacing: HermesSpace.x2,
            runSpacing: HermesSpace.x2,
            children: [
              for (final filter in ScanFilter.values)
                ChoiceChip(
                  key: ValueKey('scanDoc-filter-${filter.name}'),
                  label: Text(_filterLabel(s, filter)),
                  selected: page.filter == filter,
                  onSelected: _busy ? null : (_) => _setFilter(filter),
                ),
            ],
          ),
          const SizedBox(height: HermesSpace.x2),
          Wrap(
            spacing: HermesSpace.x2,
            children: [
              TextButton(
                key: const ValueKey('scanDoc-rotate'),
                onPressed: _busy ? null : _rotate,
                child: Text(s.scanDocRotate),
              ),
              TextButton(
                key: const ValueKey('scanDoc-delete'),
                onPressed: _busy ? null : _deletePage,
                child: Text(s.scanDocDeletePage),
              ),
              TextButton(
                key: const ValueKey('scanDoc-add'),
                onPressed: _busy || _atPageLimit
                    ? null
                    : () => setState(() => _adding = true),
                child: Text(s.scanDocAddPage),
              ),
            ],
          ),
          if (_atPageLimit)
            Padding(
              padding: const EdgeInsets.only(top: HermesSpace.x1),
              child: Text(
                s.scanDocPageLimit(widget.maxPages),
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
            ),
          if (_failed) ...[
            const SizedBox(height: HermesSpace.x2),
            _errorLine(s, colors),
          ],
          const SizedBox(height: HermesSpace.x3),
          FilledButton(
            key: const ValueKey('scanDoc-attach-images'),
            onPressed: _busy ? null : () => _export(pdf: false),
            child: Text(s.scanDocAttachImages),
          ),
          const SizedBox(height: HermesSpace.x2),
          OutlinedButton(
            key: const ValueKey('scanDoc-attach-pdf'),
            onPressed: _busy ? null : () => _export(pdf: true),
            child: Text(s.scanDocAttachPdf),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 720) {
          return Row(
            children: [
              Expanded(child: preview),
              SizedBox(
                width: 360,
                child: SingleChildScrollView(child: controls),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            children: [
              SizedBox(
                height: math.max(240, constraints.maxHeight * 0.5),
                child: preview,
              ),
              controls,
            ],
          ),
        );
      },
    );
  }
}

/// The photo with a dimmed outside, the quad and four draggable handles.
class _CropEditor extends StatelessWidget {
  const _CropEditor({
    super.key,
    required this.bytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.corners,
    required this.semanticLabel,
    required this.cornerLabel,
    required this.colors,
    required this.onMoved,
  });

  final Uint8List bytes;
  final int imageWidth;
  final int imageHeight;

  /// Normalised (0..1) top-left, top-right, bottom-right, bottom-left.
  final List<Offset> corners;
  final String semanticLabel;
  final String Function(int n) cornerLabel;
  final HermesThemeColors colors;
  final void Function(int index, Offset normalized) onMoved;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const pad = HermesSpace.x6;
        final availW = math.max(1.0, c.maxWidth - 2 * pad);
        final availH = math.max(1.0, c.maxHeight - 2 * pad);
        final scale = math.min(availW / imageWidth, availH / imageHeight);
        final size = Size(imageWidth * scale, imageHeight * scale);
        final rect = Rect.fromLTWH(
          (c.maxWidth - size.width) / 2,
          (c.maxHeight - size.height) / 2,
          size.width,
          size.height,
        );
        Offset toLocal(Offset n) => Offset(
          rect.left + n.dx * rect.width,
          rect.top + n.dy * rect.height,
        );
        const half = HermesSpace.tap / 2;
        return Semantics(
          container: true,
          label: semanticLabel,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: rect,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.fill,
                  cacheWidth: math.min(imageWidth, 1600),
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CropPainter(
                      rect: rect,
                      corners: corners,
                      shade: colors.background.withValues(alpha: 0.55),
                      line: colors.accent,
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < 4; i++)
                Positioned(
                  left: toLocal(corners[i]).dx - half,
                  top: toLocal(corners[i]).dy - half,
                  width: HermesSpace.tap,
                  height: HermesSpace.tap,
                  child: Semantics(
                    label: cornerLabel(i + 1),
                    child: GestureDetector(
                      key: ValueKey('scanDoc-corner-$i'),
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        final next = Offset(
                          (corners[i].dx + details.delta.dx / rect.width).clamp(
                            0.0,
                            1.0,
                          ),
                          (corners[i].dy + details.delta.dy / rect.height)
                              .clamp(0.0, 1.0),
                        );
                        onMoved(i, next);
                      },
                      child: Center(
                        child: Container(
                          width: HermesSpace.x6,
                          height: HermesSpace.x6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.accent.withValues(alpha: 0.35),
                            border: Border.all(color: colors.accent, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.rect,
    required this.corners,
    required this.shade,
    required this.line,
  });

  final Rect rect;
  final List<Offset> corners;
  final Color shade;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      for (final c in corners)
        Offset(rect.left + c.dx * rect.width, rect.top + c.dy * rect.height),
    ];
    final quad = Path()..addPolygon(points, true);
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect),
      quad,
    );
    canvas.drawPath(outside, Paint()..color = shade);
    canvas.drawPath(
      quad,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.rect != rect ||
      old.shade != shade ||
      old.line != line ||
      old.corners != corners;
}
