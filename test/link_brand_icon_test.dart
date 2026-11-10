// The brand glyph of a link in «Artefactos»: Desktop's `resolveBrandIcon`
// (`lib/brand-icon.ts`) with the cases of its own test, drawn from bundled
// Simple Icons path data.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/link_brand_glyphs.dart';
import 'package:hermes_android/core/widgets/link_brand_icon.dart';
import 'package:hermes_android/core/widgets/provider_logo.dart'
    show parseSvgPathData;

/// Bounds of the outline a glyph draws, sampled every 0.1 units along each
/// contour. Path.getBounds is not that: it also counts curve control
/// points, and the conics Skia builds for SVG arcs put them outside the
/// shape (Quora's ring reaches -2.6 there while its outline stays in 0-24).
Rect _outlineBounds(Path path) {
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final metric in path.computeMetrics()) {
    for (var offset = 0.0; ; offset += 0.1) {
      final at = math.min(offset, metric.length);
      final point = metric.getTangentForOffset(at)?.position;
      if (point != null) {
        left = math.min(left, point.dx);
        top = math.min(top, point.dy);
        right = math.max(right, point.dx);
        bottom = math.max(bottom, point.dy);
      }
      if (at >= metric.length) break;
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

void main() {
  test('a registrable domain resolves to its brand', () {
    expect(resolveLinkBrandSlug('github.com'), 'github');
    expect(resolveLinkBrandSlug('gitlab.com'), 'gitlab');
  });

  test('case and a leading www. are ignored', () {
    expect(resolveLinkBrandSlug('WWW.GitHub.com'), 'github');
  });

  test('subdomains inherit the parent brand', () {
    expect(resolveLinkBrandSlug('gist.github.com'), 'github');
    expect(resolveLinkBrandSlug('api.github.com'), 'github');
  });

  test('the longest matching suffix wins over its parent', () {
    expect(resolveLinkBrandSlug('docs.google.com'), 'googledocs');
    expect(resolveLinkBrandSlug('www.google.com'), 'google');
  });

  test('unknown hosts, bare labels and bare suffixes have none', () {
    expect(resolveLinkBrandSlug('example.com'), isNull);
    expect(resolveLinkBrandSlug('localhost'), isNull);
    expect(resolveLinkBrandSlug(''), isNull);
    expect(resolveLinkBrandSlug('io'), isNull);
    expect(resolveLinkBrandSlug('com'), isNull);
  });

  test('every host of the table has one parseable 24x24 glyph', () {
    expect(linkBrandHostSlugs, isNotEmpty);
    for (final slug in linkBrandHostSlugs.values.toSet()) {
      final data = linkBrandGlyphPaths[slug];
      expect(data, isNotNull, reason: slug);
      final bounds = _outlineBounds(parseSvgPathData(data!));
      expect(bounds.width, greaterThan(4), reason: slug);
      expect(bounds.height, greaterThan(4), reason: slug);
      expect(bounds.left, greaterThanOrEqualTo(-0.5), reason: slug);
      expect(bounds.top, greaterThanOrEqualTo(-0.5), reason: slug);
      expect(bounds.right, lessThanOrEqualTo(24.5), reason: slug);
      expect(bounds.bottom, lessThanOrEqualTo(24.5), reason: slug);
    }
    // No unused glyph data.
    expect(linkBrandGlyphPaths.keys.toSet(), linkBrandHostSlugs.values.toSet());
  });

  test('the glyph source is recorded in ASSET_PROVENANCE.md', () {
    final provenance = File('ASSET_PROVENANCE.md').readAsStringSync();
    expect(provenance, contains('lib/core/widgets/link_brand_glyphs.dart'));
    expect(provenance, contains('simple-icons@16.8.0'));
  });

  test('the host table is credited to Hermes Desktop (MIT) too', () {
    final reuse = File('REUSE.toml').readAsStringSync();
    final start = reuse.indexOf(
      'path = "lib/core/widgets/link_brand_glyphs.dart"',
    );
    expect(start, isNot(-1));
    final annotation = reuse.substring(start, reuse.indexOf('\n\n', start));
    expect(annotation, contains('Simple Icons contributors'));
    expect(annotation, contains('Copyright (c) 2025 Nous Research'));
    expect(annotation, contains('"CC0-1.0 AND MIT"'));
    final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    final section = notices.substring(
      notices.indexOf('## Marcas de sitios en Artefactos'),
    );
    final credit = section
        .substring(0, section.indexOf('\n## '))
        .replaceAll('\n', ' ');
    expect(
      credit,
      contains('licencia **MIT**, Copyright (c) 2025 Nous Research'),
    );
  });

  testWidgets('a known site draws its glyph; others the link icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            LinkBrandIcon(url: 'https://github.com/a/b', color: Colors.grey),
            LinkBrandIcon(url: 'https://example.com/x', color: Colors.grey),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('link-brand-github')), findsOneWidget);
    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
  });
}
