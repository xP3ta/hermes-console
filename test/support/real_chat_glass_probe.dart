import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

/// Test-only observer of the actual ChatScreen. Captures the complete native
/// view, so global logical rects have one explicit DPR transform. Controls do
/// not pump frames, move the scroll, reparent render objects or change widgets.
class RealChatGlassProbe {
  RealChatGlassProbe({
    required this.tester,
    required this.transcript,
    required this.foot,
    required this.scrim,
    required this.composer,
    required this.capsule,
    required this.colors,
    required this.hint,
    required this.expectGlass,
    this.directory,
  });

  final WidgetTester tester;
  final Finder transcript, foot, scrim, composer, capsule;
  final HermesThemeColors colors;
  final String hint;
  final bool expectGlass;
  final String? directory;

  Rect bounds(Finder finder) {
    final box = tester.renderObject<RenderBox>(finder);
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
  }

  Map<String, Rect> regions() => {
    'composer': bounds(composer),
    'capsule': bounds(capsule),
    'foot': bounds(foot),
    'scrim': bounds(scrim),
  };

  List<RenderParagraph> paragraphs(Finder finder) {
    final found = <RenderParagraph>[];
    void visit(RenderObject object) {
      if (object is RenderParagraph && object.attached && object.hasSize) {
        found.add(object);
      }
      object.visitChildren(visit);
    }

    visit(tester.renderObject<RenderObject>(finder));
    return found;
  }

  RRect _mask(Rect r, {bool pill = false}) {
    final inner = r.deflate(5);
    final radius = pill
        ? inner.shortestSide / 2
        : math.min(23.0, inner.shortestSide / 2);
    return RRect.fromRectAndRadius(inner, Radius.circular(radius));
  }

  int _filters(Layer? layer) {
    if (layer == null) return 0;
    var total = layer is BackdropFilterLayer ? 1 : 0;
    if (layer is ContainerLayer) {
      for (
        Layer? child = layer.firstChild;
        child != null;
        child = child.nextSibling
      ) {
        total += _filters(child);
      }
    }
    return total;
  }

  Future<_Pixels> _take(String name) async {
    final view = tester.binding.renderViews.single;
    final layer = view.debugLayer! as OffsetLayer;
    final dpr = tester.view.devicePixelRatio;
    final shot = await tester.runAsync(() async {
      final image = await layer.toImage(Offset.zero & (view.size * dpr));
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!;
        if (directory != null) {
          Directory(directory!).createSync(recursive: true);
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          File('$directory/$name.png').writeAsBytesSync(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          );
        }
        return _Pixels(image.width, image.height, dpr, data);
      } finally {
        image.dispose();
      }
    });
    final pixels = shot!;
    expect(pixels.width, tester.view.physicalSize.width.round());
    expect(pixels.height, tester.view.physicalSize.height.round());
    return pixels;
  }

  InlineSpan _withoutInk(InlineSpan span) {
    if (span is! TextSpan) return span;
    return TextSpan(
      text: span.text,
      style: (span.style ?? const TextStyle()).copyWith(
        foreground: Paint()..color = Colors.transparent,
        shadows: const [],
        decorationColor: Colors.transparent,
      ),
      recognizer: span.recognizer,
      locale: span.locale,
      spellOut: span.spellOut,
      children: [
        for (final child in span.children ?? const <InlineSpan>[])
          _withoutInk(child),
      ],
    );
  }

  void _flush() {
    final pipeline = tester.binding.rootPipelineOwner;
    pipeline.flushLayout();
    pipeline.flushCompositingBits();
    pipeline.flushPaint();
  }

  Future<_Pixels> _inkControl(
    Finder target,
    String name, {
    bool bare = false,
  }) async {
    final saved = {
      for (final paragraph in paragraphs(target)) paragraph: paragraph.text,
    };
    // The empty editor's caret overlaps the hint's first glyph box. It is
    // foreground ink too: leaving it in a background-only control would
    // compare the hint with the caret, rather than with its reading surface.
    final cursors = <RenderEditable, bool>{};
    void visitCursor(RenderObject object) {
      if (object is RenderEditable) {
        cursors[object] = object.showCursor.value;
      }
      object.visitChildren(visitCursor);
    }

    visitCursor(tester.renderObject<RenderObject>(target));
    // A context ring is foreground ink too; never mistake its stroke for
    // transmitted image colour in the narrow overlap with a real image.
    final progressInk = <RenderCustomPaint, (CustomPainter?, CustomPainter?)>{};
    for (final indicator
        in find
            .descendant(
              of: target,
              matching: find.byType(CircularProgressIndicator),
            )
            .evaluate()) {
      for (final element
          in find
              .descendant(
                of: find.byWidget(indicator.widget),
                matching: find.byType(CustomPaint),
              )
              .evaluate()) {
        final render = element.renderObject;
        if (render is RenderCustomPaint) {
          progressInk[render] = (render.painter, render.foregroundPainter);
        }
      }
    }
    if (name.endsWith('-no-foot-ink')) {
      expect(progressInk, hasLength(1));
    }
    final before = regions();
    try {
      for (final render in progressInk.keys) {
        render.painter = null;
        render.foregroundPainter = null;
      }
      for (final editable in cursors.keys) {
        editable.showCursor.value = false;
      }
      for (final entry in saved.entries) {
        entry.key.text = _withoutInk(entry.value);
      }
      _flush();
      expect(regions(), before, reason: 'ink control preserves geometry');
      return bare ? await _bare(name) : await _take(name);
    } finally {
      for (final entry in progressInk.entries) {
        expect(entry.key.attached, isTrue);
        entry.key.painter = entry.value.$1;
        entry.key.foregroundPainter = entry.value.$2;
      }
      for (final entry in cursors.entries) {
        expect(entry.key.attached, isTrue);
        entry.key.showCursor.value = entry.value;
      }
      for (final entry in saved.entries) {
        expect(entry.key.attached, isTrue);
        entry.key.text = entry.value;
      }
      _flush();
      expect(regions(), before, reason: 'ink control restores geometry');
    }
  }

  /// Omit only the already-painted footer and scrim layers, retaining every
  /// direct child with LayerHandle while it is detached. No disposal, layout
  /// or paint occurs until all children have been restored in their old order.
  Future<_Pixels> _bare(String name) async {
    final footLayer = tester.renderObject<RenderObject>(foot).debugLayer;
    final scrimBoundary = find.descendant(
      of: scrim,
      matching: find.byType(RepaintBoundary),
    );
    expect(scrimBoundary, findsOneWidget);
    final scrimLayer = tester
        .renderObject<RenderObject>(scrimBoundary)
        .debugLayer;
    expect(footLayer, isA<OffsetLayer>());
    expect(scrimLayer, isA<OffsetLayer>());
    final omitted = <Layer>{footLayer!, scrimLayer!};
    final groups = <ContainerLayer, List<Layer>>{};
    final handles = <LayerHandle<Layer>>[];
    for (final layer in omitted) {
      final parent = layer.parent;
      expect(parent, isNotNull);
      final attachedParent = parent!;
      if (!groups.containsKey(attachedParent)) {
        final children = <Layer>[];
        for (
          Layer? child = attachedParent.firstChild;
          child != null;
          child = child.nextSibling
        ) {
          children.add(child);
          handles.add(LayerHandle<Layer>()..layer = child);
        }
        groups[attachedParent] = children;
      }
    }
    try {
      for (final entry in groups.entries) {
        entry.key.removeAllChildren();
        for (final child in entry.value) {
          if (!omitted.contains(child)) entry.key.append(child);
        }
      }
      return await _take(name);
    } finally {
      try {
        for (final entry in groups.entries.toList().reversed) {
          entry.key.removeAllChildren();
          for (final child in entry.value) {
            entry.key.append(child);
          }
        }
      } finally {
        for (final handle in handles) {
          handle.layer = null;
        }
      }
    }
  }

  Future<Map<String, Object?>> sample(
    String name, {
    required bool textStimulus,
    Rect? imageStimulusRect,
  }) async {
    final before = regions();
    final full = await _take(name);
    final noTranscript = await _inkControl(
      transcript,
      '$name-no-transcript-ink',
    );
    final bare = await _bare('$name-bare');
    final bareNoTranscript = await _inkControl(
      transcript,
      '$name-bare-no-transcript-ink',
      bare: true,
    );
    final noFootInk = await _inkControl(foot, '$name-no-foot-ink');
    final restored = await _take('$name-restored');
    expect(regions(), before);
    expect(
      restored.digest,
      full.digest,
      reason: 'all paint controls restore the exact native frame',
    );
    final measures = <String, Object?>{};
    final footFilters = _filters(
      tester.renderObject<RenderObject>(foot).debugLayer,
    );
    expect(
      footFilters,
      expectGlass ? 1 : 0,
      reason: 'filter count follows the declared A/B input and policy',
    );
    for (final (piece, r, limit) in [
      ('composer', before['composer']!, 1.1),
      ('capsule', before['capsule']!, 1.05),
    ]) {
      final mask = _mask(r, pill: piece == 'capsule');
      final ghost = full.contrastWith(noTranscript, mask);
      final stimulus = bare.contrastWith(bareNoTranscript, mask);
      final contentSpread = noFootInk.percentileChannelSpread(
        mask,
        clip: imageStimulusRect,
      );
      if (!textStimulus) {
        expect(imageStimulusRect, isNotNull);
        expect(
          contentSpread,
          expectGlass ? greaterThanOrEqualTo(12) : lessThanOrEqualTo(3),
          reason:
              'image must remain visible through $piece, not only darken it',
        );
      }
      if (textStimulus) {
        expect(
          stimulus,
          greaterThan(3),
          reason: 'real transcript ink must be behind $piece',
        );
        expect(
          ghost,
          lessThanOrEqualTo(limit),
          reason: 'unchanged centre ghost contract for $piece',
        );
      }
      measures[piece] = {
        'rect': [r.left, r.top, r.right, r.bottom],
        'ghost': ghost,
        'ghostLimit': limit,
        'bareInkContrast': stimulus,
        'bareColourSpread': bare.spread(mask),
        'paintedCentreSpreadWithoutInk': noFootInk.spread(mask),
        'contentSpreadP95P5RGB': contentSpread,
      };
    }
    final hints = paragraphs(
      foot,
    ).where((p) => p.text.toPlainText().contains(hint)).toList();
    expect(
      hints,
      isNotEmpty,
      reason: 'capture the actual hint, not an assumed token',
    );
    var hintWorst = double.infinity;
    for (final paragraph in hints) {
      var offset = 0;
      void check(InlineSpan span, TextStyle inherited) {
        if (span is! TextSpan) {
          offset += 1;
          return;
        }
        final style = inherited.merge(span.style);
        final text = span.text ?? '';
        if (text.trim().isNotEmpty) {
          final ink = style.foreground?.color ?? style.color;
          expect(ink, isNotNull);
          for (final box in paragraph.getBoxesForSelection(
            TextSelection(
              baseOffset: offset,
              extentOffset: offset + text.length,
            ),
          )) {
            final rect = MatrixUtils.transformRect(
              paragraph.getTransformTo(null),
              box.toRect(),
            );
            for (final (x, y) in noFootInk.cells(
              _mask(before['composer']!),
              clip: rect,
            )) {
              final bg = noFootInk.at(x, y);
              final renderedInk = ThemeContrast.composite(ink!, bg);
              hintWorst = math.min(
                hintWorst,
                ThemeContrast.ratio(renderedInk, bg),
              );
            }
          }
        }
        offset += text.length;
        for (final child in span.children ?? const <InlineSpan>[]) {
          check(child, style);
        }
      }

      check(paragraph.text, const TextStyle());
    }
    expect(hintWorst.isFinite, isTrue);
    expect(
      hintWorst,
      greaterThanOrEqualTo(4.5),
      reason: 'actual hint foreground versus native background, no epsilon',
    );
    final report = <String, Object?>{
      'stage': name,
      'nativeWidth': full.width,
      'nativeHeight': full.height,
      'dpr': full.dpr,
      'paletteBackgroundARGB': colors.background.toARGB32(),
      'maskInsetDP': 5,
      'pieces': measures,
      'hintWorst': hintWorst,
      'exactFrameRestored': true,
      'fullSHA256': full.digest,
      'componentFixture': false,
      'expectedFooterFilterLayers': expectGlass ? 1 : 0,
      'footerFilterLayers': _filters(
        tester.renderObject<RenderObject>(foot).debugLayer,
      ),
      'totalFilterLayers': _filters(
        tester.binding.renderViews.single.debugLayer,
      ),
    };
    expect(report['footerFilterLayers']! as int, lessThanOrEqualTo(1));
    if (directory != null) {
      File('$directory/$name.json').writeAsStringSync(jsonEncode(report));
    }
    return report;
  }
}

class _Pixels {
  _Pixels(this.width, this.height, this.dpr, this.data);
  final int width, height;
  final double dpr;
  final ByteData data;
  String get digest => sha256
      .convert(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))
      .toString();
  Color at(int x, int y) {
    final offset = (y * width + x) * 4;
    return Color.fromARGB(
      data.getUint8(offset + 3),
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  }

  Iterable<(int, int)> cells(RRect logical, {Rect? clip}) sync* {
    final outer = logical.outerRect;
    final area = clip == null ? outer : outer.intersect(clip);
    for (
      var y = math.max(0, (area.top * dpr).ceil());
      y < math.min(height, (area.bottom * dpr).floor());
      y++
    ) {
      for (
        var x = math.max(0, (area.left * dpr).ceil());
        x < math.min(width, (area.right * dpr).floor());
        x++
      ) {
        if (logical.contains(Offset((x + .5) / dpr, (y + .5) / dpr))) {
          yield (x, y);
        }
      }
    }
  }

  double contrastWith(_Pixels control, RRect mask) {
    expect((width, height, dpr), (control.width, control.height, control.dpr));
    var worst = 1.0;
    var count = 0;
    for (final (x, y) in cells(mask)) {
      worst = math.max(worst, ThemeContrast.ratio(at(x, y), control.at(x, y)));
      count++;
    }
    expect(count, greaterThan(0));
    return worst;
  }

  /// Reject a flat darker fill as evidence of transmitted image content.
  /// Five percent at either tail excludes a small remaining progress glyph.
  int percentileChannelSpread(RRect mask, {Rect? clip}) {
    final histograms = List.generate(3, (_) => List.filled(256, 0));
    var count = 0;
    for (final (x, y) in cells(mask, clip: clip)) {
      final color = at(x, y).toARGB32();
      for (var channel = 0; channel < 3; channel++) {
        histograms[channel][(color >> (16 - channel * 8)) & 255]++;
      }
      count++;
    }
    expect(count, greaterThan(0));
    int percentile(List<int> histogram, double fraction) {
      final target = (count * fraction).ceil();
      var total = 0;
      for (var value = 0; value < histogram.length; value++) {
        total += histogram[value];
        if (total >= target) {
          return value;
        }
      }
      throw StateError('empty content histogram');
    }

    return [
      for (final histogram in histograms)
        percentile(histogram, .95) - percentile(histogram, .05),
    ].reduce(math.max);
  }

  int spread(RRect mask) {
    final lo = [255, 255, 255], hi = [0, 0, 0];
    for (final (x, y) in cells(mask)) {
      final c = at(x, y).toARGB32();
      for (var i = 0; i < 3; i++) {
        final channel = (c >> (16 - 8 * i)) & 255;
        lo[i] = math.min(lo[i], channel);
        hi[i] = math.max(hi[i], channel);
      }
    }
    return [for (var i = 0; i < 3; i++) hi[i] - lo[i]].reduce(math.max);
  }
}
