import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../utils/external_link_labels.dart';
import 'link_brand_glyphs.dart';
import 'provider_logo.dart' show ProviderGlyphPainter, parseSvgPathData;

/// Hermes Desktop `resolveBrandIcon` (`lib/brand-icon.ts`): the Simple Icons
/// slug of [hostname], walking its suffixes so a subdomain inherits its
/// parent's mark (`api.github.com` → `github.com`). The longest match wins
/// (`docs.google.com` beats `google.com`); the bare TLD is never tested.
String? resolveLinkBrandSlug(String hostname) {
  var host = hostname.trim().toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  if (!host.contains('.')) return null;
  final parts = host.split('.');
  for (var i = 0; i < parts.length - 1; i++) {
    final slug = linkBrandHostSlugs[parts.sublist(i).join('.')];
    if (slug != null) return slug;
  }
  return null;
}

final Map<String, ui.Path> _glyphCache = {};

/// The brand glyph of [url]'s host in one theme [color], or the generic link
/// icon when Desktop has no mark for it. Drawn from bundled path data: never
/// a favicon request.
class LinkBrandIcon extends StatelessWidget {
  const LinkBrandIcon({
    required this.url,
    required this.color,
    this.size = 18,
    super.key,
  });

  final String url;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final slug = resolveLinkBrandSlug(shortHostLabel(url));
    final data = slug == null ? null : linkBrandGlyphPaths[slug];
    if (slug == null || data == null) {
      return Icon(Icons.link_rounded, size: size, color: color);
    }
    final path = _glyphCache.putIfAbsent(slug, () => parseSvgPathData(data));
    return SizedBox.square(
      key: ValueKey('link-brand-$slug'),
      dimension: size,
      child: CustomPaint(
        painter: ProviderGlyphPainter(path: path, color: color),
      ),
    );
  }
}
