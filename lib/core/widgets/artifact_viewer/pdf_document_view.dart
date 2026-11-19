import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../theme/app_theme.dart';
import '../console_loader.dart';

/// Renders the pages of a PDF natively (Android's `PdfRenderer`, through the
/// app's own `hermes/document_preview` channel) as a scrolling column.
///
/// The document is held in the app's private cache only while it is on
/// screen (`<cache>/pdf_viewer/<sha256>.pdf`, removed on dispose); the
/// channel is given the digest, never a path. Pages render as they scroll
/// into view and only a few are kept. Tapping a page opens it alone, where
/// it can be pinched.
///
/// Where pages cannot be rendered (another platform, a broken or protected
/// file) [fallback] is shown instead.
class PdfDocumentView extends StatefulWidget {
  const PdfDocumentView({
    super.key,
    required this.bytes,
    required this.fallback,
    this.renderPage,
  });

  final Uint8List bytes;
  final Widget fallback;

  /// Test seam: renders page [index] of the stored document [key].
  final Future<({Uint8List png, int pageCount})?> Function(String key, int index)?
  renderPage;

  /// Largest document handed to the renderer.
  static const int maxBytes = 50 * 1024 * 1024;

  @override
  State<PdfDocumentView> createState() => _PdfDocumentViewState();
}

class _PdfDocumentViewState extends State<PdfDocumentView> {
  static const _channel = MethodChannel('hermes/document_preview');
  static const int _kept = 6;

  late Future<({int pageCount, double aspect})?> _opened = _open();
  final Map<int, Future<Uint8List?>> _pages = {};
  final List<int> _order = [];
  File? _file;
  String? _key;

  @override
  void didUpdateWidget(covariant PdfDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _removeFile();
      _pages.clear();
      _order.clear();
      _opened = _open();
    }
  }

  @override
  void dispose() {
    _removeFile();
    super.dispose();
  }

  void _removeFile() {
    final file = _file;
    _file = null;
    if (file != null) {
      unawaited(file.delete().then<void>((_) {}, onError: (_) {}));
    }
  }

  Future<({Uint8List png, int pageCount})?> _render(String key, int index) async {
    final custom = widget.renderPage;
    if (custom != null) return custom(key, index);
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'renderViewerPdfPage',
      {'key': key, 'page': index},
    );
    final png = response?['pngBytes'];
    final count = (response?['pageCount'] as num?)?.toInt();
    if (png is! Uint8List || png.isEmpty || count == null || count <= 0) {
      return null;
    }
    return (png: png, pageCount: count);
  }

  Future<({int pageCount, double aspect})?> _open() async {
    final bytes = widget.bytes;
    if (bytes.isEmpty || bytes.length > PdfDocumentView.maxBytes) return null;
    try {
      final key = sha256.convert(bytes).toString();
      if (widget.renderPage == null) {
        final root = await getTemporaryDirectory();
        final directory = Directory('${root.path}/pdf_viewer');
        await directory.create(recursive: true);
        final file = File('${directory.path}/$key.pdf');
        await file.writeAsBytes(bytes, flush: true);
        if (!mounted) {
          unawaited(file.delete().then<void>((_) {}, onError: (_) {}));
          return null;
        }
        _file = file;
      }
      _key = key;
      final first = await _render(key, 0);
      if (first == null) return null;
      final codec = await ui.instantiateImageCodec(first.png);
      final frame = await codec.getNextFrame();
      final aspect = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      _remember(0, Future.value(first.png));
      return (pageCount: first.pageCount, aspect: aspect);
    } catch (_) {
      return null;
    }
  }

  void _remember(int index, Future<Uint8List?> page) {
    _pages[index] = page;
    _order
      ..remove(index)
      ..add(index);
    while (_order.length > _kept) {
      _pages.remove(_order.removeAt(0));
    }
  }

  Future<Uint8List?> _page(int index) {
    final known = _pages[index];
    if (known != null) {
      _order
        ..remove(index)
        ..add(index);
      return known;
    }
    final key = _key;
    final future = key == null
        ? Future<Uint8List?>.value()
        : _render(key, index).then<Uint8List?>(
            (page) => page?.png,
            onError: (_) => null,
          );
    _remember(index, future);
    return future;
  }

  void _zoom(Uint8List png) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          body: InteractiveViewer(
            key: const ValueKey('pdf-page-zoom'),
            minScale: 1,
            maxScale: 6,
            child: Center(child: Image.memory(png, gaplessPlayback: true)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return FutureBuilder<({int pageCount, double aspect})?>(
      future: _opened,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            key: ValueKey('pdf-document-loading'),
            child: ConsoleLoader.large(),
          );
        }
        final opened = snapshot.data;
        if (opened == null) return widget.fallback;
        return ListView.separated(
          key: const ValueKey('pdf-document-pages'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          itemCount: opened.pageCount,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) => ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: opened.aspect,
              child: ColoredBox(
                color: Colors.white,
                child: FutureBuilder<Uint8List?>(
                  future: _page(index),
                  builder: (context, page) {
                    final png = page.data;
                    if (png == null) {
                      return page.connectionState == ConnectionState.done
                          ? Center(
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(color: colors.textTertiary),
                              ),
                            )
                          : const Center(child: ConsoleLoader());
                    }
                    return GestureDetector(
                      onTap: () => _zoom(png),
                      child: Image.memory(
                        png,
                        key: ValueKey('pdf-page-$index'),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
