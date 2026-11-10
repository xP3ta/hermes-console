/// How Hermes Desktop names a link without loading it: port of
/// `normalizeExternalUrl`, `shortHostLabel`, `hostPathLabel` and
/// `urlSlugTitleLabel` (`apps/desktop/src/lib/external-link.tsx`).
///
/// Pure and synchronous: no network. Desktop also fetches the page title
/// through its Electron bridge (`useLinkTitle`); Console does not port that
/// fetch (see [urlSlugTitleLabel]).
library;

final RegExp _domainRe = RegExp(
  r'^(?:www\.)?[a-z0-9](?:[a-z0-9-]*\.)+[a-z]{2,}(?::\d+)?(?:[/?#][^\s]*)?$',
  caseSensitive: false,
);
final RegExp _httpRe = RegExp(r'^https?://', caseSensitive: false);

/// A bare domain (`example.com/docs`) gets `https://`; anything else is
/// returned trimmed.
String normalizeExternalUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || _httpRe.hasMatch(trimmed)) return trimmed;
  return _domainRe.hasMatch(trimmed) ? 'https://$trimmed' : trimmed;
}

Uri? _parseUrl(String value) {
  final uri = Uri.tryParse(normalizeExternalUrl(value));
  return uri == null || !uri.hasScheme ? null : uri;
}

String _withoutWww(String host) =>
    host.startsWith('www.') ? host.substring(4) : host;

/// Host without `www.`; the value itself when it is not a URL.
String shortHostLabel(String value) {
  final uri = _parseUrl(value);
  return uri == null ? value : _withoutWww(uri.host);
}

/// Host and path, without `www.` or a trailing slash.
String hostPathLabel(String value) {
  final uri = _parseUrl(value);
  if (uri == null) return value;
  final path = uri.path.isNotEmpty && uri.path != '/'
      ? uri.path.replaceFirst(RegExp(r'/$'), '')
      : '';
  return '${_withoutWww(uri.host)}$path';
}

String _cleanSlug(String segment) {
  final String decoded;
  try {
    decoded = Uri.decodeComponent(segment);
  } catch (_) {
    return '';
  }
  return decoded
      .replaceFirst(RegExp(r'\.a\d+\..*$', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\.(?:html?|php|aspx?)$', caseSensitive: false), '')
      .replaceFirst(
        RegExp(
          r'(?:[-_.](?:[a-z]{1,3}\d{2,}|i\d{2,}))+$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

final RegExp _letterRe = RegExp('[a-z]', caseSensitive: false);
final RegExp _idOnlyRe = RegExp(
  r'^(?:[a-z]{1,3}\d+|\d+)$',
  caseSensitive: false,
);

/// A readable title from the URL alone: the last meaningful path segment,
/// cleaned (`/blog/some-guide.html` → `Some Guide`), else host and path.
///
/// Desktop shows the page's own title when its bridge fetched one, and this
/// label otherwise. Console never requests a page for its title here; the
/// chat may pass a title it already loaded for its link preview.
String urlSlugTitleLabel(String value) {
  final uri = _parseUrl(value);
  final segments = (uri?.path ?? '').split('/').where((s) => s.isNotEmpty);
  for (final segment in segments.toList().reversed) {
    final cleaned = _cleanSlug(segment);
    if (cleaned.isEmpty || !_letterRe.hasMatch(cleaned)) continue;
    if (_idOnlyRe.hasMatch(cleaned.replaceAll(RegExp(r'\s+'), ''))) continue;
    // Keep the exact casing of a separator-less identifier (`v1.0.1`,
    // `README.md`); title-case word slugs.
    final looksLikeIdentifier =
        RegExp(r'\d').hasMatch(cleaned) ||
        RegExp('[A-Z]').hasMatch(cleaned) ||
        cleaned.contains('.');
    final label = looksLikeIdentifier && !cleaned.contains(' ')
        ? cleaned
        : cleaned.replaceAllMapped(
            RegExp(r'\b[a-z]'),
            (match) => match[0]!.toUpperCase(),
          );
    if (label.length >= 4) return label;
  }
  return hostPathLabel(value);
}

final RegExp _errorTitleRe = RegExp(
  r'\b(?:access denied|attention required|captcha|error|forbidden|'
  r'just a moment|not found|request blocked|too many requests)\b',
  caseSensitive: false,
);

/// Desktop `fetchLinkTitle`'s filter: a page title worth showing, not empty
/// and not an error or bot-check page.
bool isUsableLinkTitle(String title) {
  final clean = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.isNotEmpty && !_errorTitleRe.hasMatch(clean);
}
