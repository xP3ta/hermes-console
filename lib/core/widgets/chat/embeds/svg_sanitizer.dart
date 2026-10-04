import 'dart:convert';

/// Largest SVG fence Console will try to render; bigger stays a code block.
const int svgEmbedMaxBytes = 256 * 1024;

/// Elements dropped together with everything inside them.
const Set<String> _blockedElements = {
  'script',
  'foreignobject',
  'iframe',
  'object',
  'embed',
  'link',
  'meta',
  'audio',
  'video',
  'canvas',
  'base',
};

final RegExp _tag = RegExp(
  r'<(/?)([A-Za-z][\w:.-]*)((?:\s+[^\s=/>]+(?:\s*=\s*(?:"[^"]*"|'
  "'[^']*'"
  r'|[^\s"'
  "'"
  r'>]+))?)*)\s*(/?)>',
);
final RegExp _attribute = RegExp(
  r'([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'
  "'([^']*)'"
  r'|([^\s"'
  "'"
  r'>]+)))?',
);
final RegExp _comment = RegExp(r'<!--[\s\S]*?-->');
final RegExp _cdata = RegExp(r'<!\[CDATA\[[\s\S]*?\]\]>');
final RegExp _processing = RegExp(r'<\?[\s\S]*?\?>');
final RegExp _cssUrl = RegExp(r'url\(\s*([^)]*)\)', caseSensitive: false);

bool _safeReference(String value) {
  final v = value.trim().toLowerCase();
  return v.startsWith('#') ||
      RegExp(r'^data:image/(png|jpe?g|gif|webp);').hasMatch(v);
}

bool _safeCss(String css) {
  final lower = css.toLowerCase();
  if (lower.contains('@import') ||
      lower.contains('expression(') ||
      lower.contains('javascript:') ||
      lower.contains('behavior:') ||
      lower.contains('-moz-binding')) {
    return false;
  }
  for (final match in _cssUrl.allMatches(css)) {
    var target = (match.group(1) ?? '').trim();
    if (target.length >= 2 &&
        (target.startsWith('"') || target.startsWith("'"))) {
      target = target.substring(1, target.length - 1);
    }
    if (!_safeReference(target)) return false;
  }
  return true;
}

String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;');

/// Returns a script-free, network-free copy of [source], or null when it is
/// too large, not an SVG document or malformed. Strips `<script>`, event
/// handler attributes, `foreignObject` and every `href`/`xlink:href`/`url()`
/// that does not point at `#id` or an inline raster `data:` image. A null
/// result means "show the code block instead".
String? sanitizeSvgForEmbed(String source) {
  if (utf8.encode(source).length > svgEmbedMaxBytes) return null;
  var text = source.trim();
  final lower = text.toLowerCase();
  if (lower.contains('<!doctype') || lower.contains('<!entity')) return null;
  text = text
      .replaceAll(_comment, '')
      .replaceAll(_cdata, '')
      .replaceAll(_processing, '');

  final out = StringBuffer();
  final stack = <String>[];
  var blockedDepth = 0;
  var rootSeen = false;
  var cursor = 0;
  for (final match in _tag.allMatches(text)) {
    final between = text.substring(cursor, match.start);
    cursor = match.end;
    if (between.contains('<')) return null;
    if (blockedDepth == 0) {
      if (!rootSeen && between.trim().isNotEmpty) return null;
      out.write(between);
    }
    final closing = match.group(1) == '/';
    final name = match.group(2)!;
    final lname = name.toLowerCase().split(':').last;
    final selfClosing = match.group(4) == '/';
    if (closing) {
      if (blockedDepth > 0) {
        if (_blockedElements.contains(lname)) blockedDepth--;
        continue;
      }
      if (stack.isEmpty || stack.last != name) return null;
      stack.removeLast();
      out.write('</$name>');
      continue;
    }
    if (!rootSeen) {
      if (lname != 'svg') return null;
      rootSeen = true;
    }
    if (_blockedElements.contains(lname)) {
      if (!selfClosing) blockedDepth++;
      continue;
    }
    if (blockedDepth > 0) {
      continue;
    }
    final kept = StringBuffer();
    var attributeName = '';
    final attributes = <(String, String)>[];
    for (final attr in _attribute.allMatches(match.group(3) ?? '')) {
      final key = attr.group(1)!;
      final value = attr.group(2) ?? attr.group(3) ?? attr.group(4) ?? '';
      attributes.add((key, value));
      if (key.toLowerCase() == 'attributename') attributeName = value;
    }
    if ((lname == 'set' || lname.startsWith('animate')) &&
        RegExp(r'^(on|.*href)', caseSensitive: false).hasMatch(attributeName)) {
      if (!selfClosing) blockedDepth++;
      continue;
    }
    for (final (key, value) in attributes) {
      final lkey = key.toLowerCase();
      if (lkey.startsWith('on') || lkey == 'src') continue;
      if (lkey == 'href' || lkey.endsWith(':href')) {
        if (!_safeReference(value)) continue;
      } else if (lkey == 'style') {
        if (!_safeCss(value)) continue;
      } else if (value.toLowerCase().contains('javascript:') ||
          (_cssUrl.hasMatch(value) && !_safeCss(value))) {
        continue;
      }
      kept.write(' $key="${_escapeAttribute(value)}"');
    }
    out.write('<$name$kept${selfClosing ? '/' : ''}>');
    if (lname == 'style' && !selfClosing) {
      // Inline CSS is kept only when it cannot fetch anything.
      final end = text.toLowerCase().indexOf('</style', match.end);
      if (end < 0) return null;
      final css = text.substring(match.end, end);
      if (!_safeCss(css)) return null;
      out.write(css.replaceAll('<', '&lt;'));
      cursor = end;
    }
    if (!selfClosing) stack.add(name);
  }
  final tail = text.substring(cursor);
  if (tail.contains('<')) return null;
  if (blockedDepth == 0 && tail.trim().isNotEmpty) return null;
  if (!rootSeen || stack.isNotEmpty || blockedDepth != 0) return null;
  return out.toString();
}
