/// sa1215: everything shared in one conversation (links, images, files).
///
/// Faithful port of Desktop's artifact extraction
/// (`apps/desktop/src/app/artifacts/artifact-utils.ts`
/// `collectArtifactsForSession`, plus `mediaTagValues` from
/// `lib/chat-messages/parts.ts` and `isArtifactFilePath` /
/// `mediaPathFromMarkdownHref` from `lib/media.ts`). Same regexes, same
/// strong/producer tool keys and the same false-positive budget, so Console
/// and Desktop list the same things for the same transcript.
///
/// Console additions (Desktop's page ignores user rows):
/// - user turns contribute links and the `@image:`/`@file:` lines Hermes
///   persists for attachments;
/// - tool results that the transcript coalesced into an assistant row
///   (`_activity_tool_results`) are scanned exactly like standalone tool rows;
/// - `::preview{file="…"}` directives and `_generatedImages` metadata are
///   explicit deliveries.
///
/// Pure and synchronous: no I/O, no Flutter.
library;

import 'dart:convert';

import 'session_reconciler.dart' show assistantToolResultEvidenceKey;
import 'transcript_directive_parser.dart';

enum ChatContentKind { image, file, link }

enum ChatContentFilter { all, image, file, link }

final class ChatContentItem {
  final ChatContentKind kind;

  /// Normalized path or URL, exactly what Desktop stores as `value`.
  final String value;

  /// What to open: the URL itself for http(s)/data, `file://` for local
  /// absolute paths, otherwise the value (Desktop `artifactHref`).
  final String href;
  final String label;

  /// Null when the source row carried no usable timestamp. Desktop falls back
  /// to the session time or `Date.now()`; Console shows no date instead of an
  /// invented one.
  final DateTime? timestamp;

  const ChatContentItem({
    required this.kind,
    required this.value,
    required this.href,
    required this.label,
    this.timestamp,
  });

  @override
  String toString() => 'ChatContentItem(${kind.name}, $value)';
}

// ---- Desktop regexes (artifact-utils.ts) ---------------------------------

final RegExp _markdownImageRe = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final RegExp _markdownLinkRe = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');
final RegExp _urlRe = RegExp(r'''https?://[^\s<>"')`]+''');
final RegExp _pathRe = RegExp(
  r'''(^|[\s("'`])((?:/|~[\\/]|\.\.?[\\/]|\\\\)[^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)''',
  caseSensitive: false,
);
final RegExp _windowsPathRe = RegExp(
  r'''(^|[\s("'`])([A-Za-z]:[\\/][^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)''',
  caseSensitive: false,
);
final RegExp _imageExtRe = RegExp(
  r'\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$',
  caseSensitive: false,
);
final RegExp _fileExtRe = RegExp(
  r'\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|xlsx?|docx?|pptx?|html|zip|tar|gz|avi|flac|m4a|mkv|mp3|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$',
  caseSensitive: false,
);
const double _maxUnixSeconds = 10000000000;
final RegExp _artifactProducerToolRe = RegExp(
  r'(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)',
  caseSensitive: false,
);
final RegExp _strongToolArtifactKeyRe = RegExp(
  r'^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$',
  caseSensitive: false,
);
final RegExp _producerToolArtifactKeyRe = RegExp(
  r'^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path|media(?:_(?:file|path|url))?|path)$',
  caseSensitive: false,
);
final RegExp _screenshotPathRe = RegExp(
  r'Screenshot path:\s*([^\r\n<>]+)',
  caseSensitive: false,
);
final RegExp _shellOutputKeyRe = RegExp(
  r'^(?:output|stdout|path)$',
  caseSensitive: false,
);
final RegExp _pipCacheDirRe = RegExp(
  r'/(?:\.cache/pip|library/caches/pip|appdata/local/pip/cache)/',
);
final RegExp _wheelRe = RegExp(r'\.whl(?:\.metadata)?$');
final RegExp _packageIndexDistRe = RegExp(
  r'/packages/.+\.(?:tar\.gz|tar\.bz2|zip|egg)(?:\.metadata)?$',
);

// ---- Desktop MEDIA tag regex (parts.ts) ------------------------------------

const List<String> _mediaDeliveryExts = [
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'tiff', 'svg', 'mp4', 'mov', //
  'avi', 'mkv', 'webm', '3gp', 'mp3', 'm2a', 'wav', 'ogg', 'opus', 'm4a',
  'flac', 'pdf', 'docx', 'doc', 'odt', 'rtf', 'txt', 'md', 'epub', 'xlsx',
  'xls', 'ods', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml', 'kmz', 'kml',
  'geojson', 'gpx', 'pptx', 'ppt', 'odp', 'key', 'zip', 'tar', 'gz', 'tgz',
  'bz2', 'xz', '7z', 'rar', 'apk', 'ipa', 'html', 'htm',
];

final RegExp _mediaTagRe = () {
  final exts = [..._mediaDeliveryExts]
    ..sort((a, b) => b.length.compareTo(a.length));
  final alternation = exts.join('|');
  final anchored =
      r'''(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:'''
      '$alternation'
      r''')(?=[\s`"'*_,;:)\]}]|MEDIA:|$)''';
  const bare = r'''[^\s`"]+''';
  return RegExp(
    r'''[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|'''
    '$anchored|$bare'
    r''')[`"']?''',
  );
}();

// ---- Console-only directives ------------------------------------------------

final RegExp _userAttachmentLineRe = RegExp(r'^@(image|file):(.+)$');
final RegExp _userAttachmentValueRe = RegExp(
  r'''^(?:(`|"|')(.+?)\1|(.+?))(?::\d+(?:-\d+)?)?$''',
);

typedef _PushValue = void Function(String value, {bool explicit});

// ---- Helpers (1:1 with artifact-utils.ts) -----------------------------------

bool _isArtifactFilePath(String path) => RegExp(
  r'^(?:file:|/|[~.][\\/]|\.\.[\\/]|[a-z]:[\\/]|\\\\)',
  caseSensitive: false,
).hasMatch(path);

bool _isWindowsPath(String value) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) || value.startsWith(r'\\');

String _artifactPathForFiltering(String value) {
  if (RegExp(r'^(?:https?|file)://', caseSensitive: false).hasMatch(value)) {
    final uri = Uri.tryParse(value);
    if (uri != null) {
      try {
        return Uri.decodeFull(uri.path).toLowerCase();
      } on ArgumentError {
        // Malformed escape: fall through to plain normalization.
      }
    }
  }
  return value.replaceAll(r'\', '/').toLowerCase();
}

bool _isPythonPackageDownload(String value) {
  final path = _artifactPathForFiltering(value);
  return _pipCacheDirRe.hasMatch(path) ||
      _wheelRe.hasMatch(path) ||
      (RegExp(r'^https?://', caseSensitive: false).hasMatch(value) &&
          _packageIndexDistRe.hasMatch(path));
}

bool _looksLikePathOrUrl(String value) =>
    value.startsWith('http://') ||
    value.startsWith('https://') ||
    value.startsWith('data:image/') ||
    _isArtifactFilePath(value);

bool _looksLikeArtifact(String value, {bool explicit = false}) {
  if (!explicit && _isPythonPackageDownload(value)) return false;
  if (RegExp(r'^(?:https?://|data:image/)').hasMatch(value)) return true;
  if (!_looksLikePathOrUrl(value)) return false;
  if (explicit) return true;
  return _imageExtRe.hasMatch(value) || _fileExtRe.hasMatch(value);
}

String _normalizeValue(String value) {
  var trimmed = value.trim();
  for (var i = 0; i < 3; i++) {
    if (trimmed.length >= 2) {
      final quote = trimmed[0];
      if ((quote == '"' || quote == "'" || quote == '`') &&
          trimmed.endsWith(quote)) {
        trimmed = trimmed.substring(1, trimmed.length - 1).trim();
        continue;
      }
    }
    break;
  }
  return trimmed
      .replaceFirst(RegExp(r'[`*]+$'), '')
      .replaceFirst(RegExp(r'[),.;]+$'), '');
}

String? _mediaPathFromMarkdownHref(String href) {
  if (!href.startsWith('#media:')) return null;
  try {
    return Uri.decodeComponent(href.substring('#media:'.length));
  } on ArgumentError {
    return null;
  }
}

String _decodeMediaHrefValue(String value) =>
    _mediaPathFromMarkdownHref(value) ?? value;

String _unquoteMediaValue(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2) {
    final quote = trimmed[0];
    if ((quote == '"' || quote == "'" || quote == '`') &&
        trimmed.endsWith(quote)) {
      return trimmed.substring(1, trimmed.length - 1);
    }
  }
  return trimmed.replaceFirst(RegExp(r'''[`"'*_]{1,3}$'''), '');
}

void _collectMediaValues(String text, _PushValue push) {
  for (final match in _mediaTagRe.allMatches(text)) {
    push(_unquoteMediaValue(match.group(1) ?? ''), explicit: true);
  }
}

Object? _parseMaybeJson(String value) {
  if (value.trim().isEmpty) return null;
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

String? _untrustedToolPayload(String value) {
  final trimmed = value.trim();
  final openTag = RegExp(
    r'^<untrusted_tool_result\b[^>]*>\s*',
  ).firstMatch(trimmed);
  if (openTag == null) return null;
  final closeIndex = trimmed.lastIndexOf('</untrusted_tool_result>');
  if (closeIndex <= openTag.end) return null;
  final wrapped = trimmed.substring(openTag.end, closeIndex).trim();
  final payloadStart = wrapped.indexOf('\n\n');
  return (payloadStart == -1 ? wrapped : wrapped.substring(payloadStart + 2))
      .trim();
}

List<Object> _parseToolPayloads(String text) {
  final payloads = <Object>[];
  for (final candidate in [text, _untrustedToolPayload(text)]) {
    if (candidate == null || candidate.isEmpty) continue;
    final parsed = _parseMaybeJson(candidate);
    if (parsed != null) payloads.add(parsed);
  }
  return payloads;
}

ChatContentKind _artifactKind(String value) {
  if (value.startsWith('data:image/') || _imageExtRe.hasMatch(value)) {
    return ChatContentKind.image;
  }
  if (_isArtifactFilePath(value)) return ChatContentKind.file;
  return ChatContentKind.link;
}

String _artifactHref(String value) {
  if (value.startsWith('http://') ||
      value.startsWith('https://') ||
      value.startsWith('data:')) {
    return value;
  }
  if (value.startsWith('file://')) return value;
  if (value.startsWith('/')) return Uri.file(value).toString();
  if (_isWindowsPath(value)) {
    return Uri.file(value, windows: true).toString();
  }
  return value;
}

/// Desktop uses `new URL(value).pathname` and falls back to the last path
/// segment. A Windows path parses as a `c:` URL there and keeps its
/// backslashes; Console only treats real URL schemes as URLs so the label is
/// always the file name.
String _artifactLabel(String value) {
  if (RegExp(r'^(?:https?|file):', caseSensitive: false).hasMatch(value)) {
    final uri = Uri.tryParse(value);
    if (uri != null) {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty);
      return segments.isEmpty ? value : segments.last;
    }
  }
  if (value.startsWith('data:')) return value.split(',').first;
  final parts = value.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? value : parts.last;
}

DateTime? _artifactTimestamp(Object? raw) {
  if (raw is! num || !raw.isFinite || raw <= 0) return null;
  final millis = raw < _maxUnixSeconds ? raw * 1000 : raw;
  try {
    return DateTime.fromMillisecondsSinceEpoch(millis.round());
  } on RangeError {
    return null;
  }
}

String _messageText(Map<String, dynamic> message) {
  for (final key in const ['content', 'text', 'context']) {
    final value = message[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return '';
}

void _collectStringValues(
  Object? value,
  String keyPath,
  void Function(String value, String keyPath) collector,
) {
  if (value is String) {
    collector(value, keyPath);
    return;
  }
  if (value is List) {
    for (var index = 0; index < value.length; index++) {
      _collectStringValues(value[index], '$keyPath.$index', collector);
    }
    return;
  }
  if (value is! Map) return;
  for (final entry in value.entries) {
    final key = entry.key.toString();
    _collectStringValues(
      entry.value,
      keyPath.isEmpty ? key : '$keyPath.$key',
      collector,
    );
  }
}

void _collectArtifactsFromText(String text, _PushValue push) {
  _collectMediaValues(text, push);
  for (final match in _markdownImageRe.allMatches(text)) {
    push(match.group(2) ?? '');
  }
  for (final match in _markdownLinkRe.allMatches(text)) {
    if (match.start > 0 && text[match.start - 1] == '!') continue;
    final value = _decodeMediaHrefValue(match.group(2) ?? '');
    if (_looksLikeArtifact(value)) push(value);
  }
  for (final match in _urlRe.allMatches(text)) {
    final value = match.group(0) ?? '';
    if (_looksLikeArtifact(value)) push(value);
  }
  for (final match in _pathRe.allMatches(text)) {
    push(match.group(2) ?? '');
  }
  for (final match in _windowsPathRe.allMatches(text)) {
    push(match.group(2) ?? '');
  }
}

String _toolName(Map<String, dynamic> message) =>
    (message['tool_name'] ?? message['name'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

bool _isArtifactProducerTool(String name) =>
    _artifactProducerToolRe.hasMatch(name) || name.startsWith('bfl_flux3_');

List<String> _keySegments(String keyPath) => keyPath
    .split('.')
    .where((s) => s.isNotEmpty && !RegExp(r'^\d+$').hasMatch(s))
    .toList(growable: false);

bool _explicitToolArtifactKey(String keyPath, bool producerTool) =>
    _keySegments(keyPath).any(
      (segment) =>
          _strongToolArtifactKeyRe.hasMatch(segment) ||
          (producerTool && _producerToolArtifactKeyRe.hasMatch(segment)),
    );

Object? _structuredToolPayload(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is Map) {
    if (content['_multimodal'] == true) return content['meta'];
    return content;
  }
  if (content is List) return content;
  return null;
}

void _collectFromTool(Map<String, dynamic> message, _PushValue push) {
  final text = _messageText(message);
  final name = _toolName(message);
  final producerTool = _isArtifactProducerTool(name);
  final terminalTool = name == 'terminal';

  if (text.isNotEmpty && (producerTool || terminalTool)) {
    _collectArtifactsFromText(text, push);
  }
  if (name == 'browser_vision' && text.isNotEmpty) {
    for (final match in _screenshotPathRe.allMatches(text)) {
      push(match.group(1) ?? '');
    }
  }

  final payloads = _parseToolPayloads(text);
  final structured = _structuredToolPayload(message);
  if (structured != null) payloads.add(structured);

  for (final parsed in payloads) {
    _collectStringValues(parsed, 'tool_result', (value, keyPath) {
      final segments = _keySegments(keyPath);
      final shellOutput =
          terminalTool && segments.any(_shellOutputKeyRe.hasMatch);
      if (!shellOutput && !_explicitToolArtifactKey(keyPath, producerTool)) {
        return;
      }
      if (shellOutput) {
        if (value.isNotEmpty) _collectArtifactsFromText(value, push);
        return;
      }
      _collectMediaValues(value, push);
      final normalized = _normalizeValue(_decodeMediaHrefValue(value));
      if (normalized.isNotEmpty && _looksLikeArtifact(normalized)) {
        push(normalized);
      }
    });
  }
}

void _collectFromUser(String text, _PushValue push) {
  // Links the person shared. Bare paths in prose stay out: a person quoting
  // a path is not sharing a file.
  for (final match in _markdownLinkRe.allMatches(text)) {
    final value = match.group(2) ?? '';
    if (value.startsWith('http://') || value.startsWith('https://')) {
      push(value);
    }
  }
  for (final match in _urlRe.allMatches(text)) {
    push(match.group(0) ?? '');
  }
  // Attachments Hermes persisted for this turn, after the prose they follow.
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    final match = _userAttachmentLineRe.firstMatch(line);
    if (match == null) continue;
    final parsed = _userAttachmentValueRe.firstMatch(match.group(2)!.trim());
    final value = (parsed?.group(2) ?? parsed?.group(3))?.trim();
    if (value != null && value.isNotEmpty) push(value, explicit: true);
  }
}

void _collectFromAssistant(Map<String, dynamic> message, _PushValue push) {
  final text = _messageText(message);
  if (text.isNotEmpty) {
    _collectArtifactsFromText(text, push);
    for (final paragraph in text.split(RegExp(r'\n\s*\n'))) {
      final directive = parseTranscriptDirective(paragraph);
      final file = directive?.name == 'preview'
          ? directive!.attrs['file']
          : null;
      if (file != null && file.trim().isNotEmpty) push(file, explicit: true);
    }
  }
  final generated = message['_generatedImages'];
  if (generated is List) {
    for (final entry in generated) {
      final source = entry is Map ? entry['source'] : null;
      if (source is String) push(source, explicit: true);
    }
  }
  final toolResults = message[assistantToolResultEvidenceKey];
  if (toolResults is List) {
    for (final raw in toolResults) {
      if (raw is Map) _collectFromTool(Map<String, dynamic>.from(raw), push);
    }
  }
}

/// Collects shared content from [newestFirst] (Console transcript order).
/// Returns items newest first; a value seen in several messages keeps its
/// first (oldest) sighting, like Desktop.
List<ChatContentItem> collectChatContent(
  List<Map<String, dynamic>> newestFirst,
) {
  final found = <String, ChatContentItem>{};
  for (final message in newestFirst.reversed) {
    final role = message['role']?.toString().trim().toLowerCase();
    final timestamp = _artifactTimestamp(message['timestamp']);
    void push(String candidate, {bool explicit = false}) {
      final value = _normalizeValue(_decodeMediaHrefValue(candidate));
      if (value.isEmpty || !_looksLikeArtifact(value, explicit: explicit)) {
        return;
      }
      found.putIfAbsent(
        value,
        () => ChatContentItem(
          kind: _artifactKind(value),
          value: value,
          href: _artifactHref(value),
          label: _artifactLabel(value),
          timestamp: timestamp,
        ),
      );
    }

    switch (role) {
      case 'assistant':
        _collectFromAssistant(message, push);
      case 'tool':
        _collectFromTool(message, push);
      case 'user':
        final kind = message['display_kind']?.toString().trim() ?? '';
        if (kind.isEmpty) _collectFromUser(_messageText(message), push);
    }
  }
  return found.values.toList(growable: false).reversed.toList();
}

/// Desktop `visibleArtifacts`: kind filter plus a case-insensitive substring
/// search over label and value.
List<ChatContentItem> filterChatContent(
  List<ChatContentItem> items,
  ChatContentFilter filter, {
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final item in items)
      if ((filter == ChatContentFilter.all || item.kind.name == filter.name) &&
          (q.isEmpty ||
              item.label.toLowerCase().contains(q) ||
              item.value.toLowerCase().contains(q)))
        item,
  ];
}
