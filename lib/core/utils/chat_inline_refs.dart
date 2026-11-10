import 'dart:collection';

/// Pure detection of what a chat reply can show as an inline chip: file and
/// folder references, and citation numbers («[1]») with their sources. No
/// Flutter here: the parse is cheap, deterministic and memoised, and tests
/// run it without a widget tree.

/// Where a path starts, which decides if the agent's machine can be asked
/// for it.
enum ChatPathRoot { absolute, home, relative }

/// Icon family of a file chip.
enum ChatFileKind { file, markdown, archive, image, pdf, code, data, folder }

/// One recognised file or folder reference.
final class ChatFileRef {
  const ChatFileRef({
    required this.path,
    required this.name,
    required this.kind,
    required this.root,
    this.line,
    this.endLine,
  });

  /// As written, without a trailing `:line` and without a closing `/`.
  final String path;

  /// The line the text pointed at (`a.dart:120`, `a.dart#L120`), and the end
  /// of a range (`a.dart:10-20`, `a.dart#L10-L20`); null when it said none.
  final int? line;
  final int? endLine;

  /// What the chip shows: the last segment, plus the `:line` the text had.
  final String name;
  final ChatFileKind kind;
  final ChatPathRoot root;

  bool get isFolder => kind == ChatFileKind.folder;

  @override
  bool operator ==(Object other) =>
      other is ChatFileRef &&
      other.path == path &&
      other.name == name &&
      other.kind == kind &&
      other.root == root &&
      other.line == line &&
      other.endLine == endLine;

  @override
  int get hashCode => Object.hash(path, name, kind, root, line, endLine);
}

const Set<String> _markdownExt = {'md', 'markdown', 'mdx'};
const Set<String> _archiveExt = {
  'zip',
  'tar',
  'gz',
  'tgz',
  'bz2',
  'xz',
  '7z',
  'rar',
  'apk',
  'jar',
};
const Set<String> _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'};
const Set<String> _codeExt = {
  'dart',
  'py',
  'ts',
  'tsx',
  'js',
  'jsx',
  'kt',
  'kts',
  'java',
  'swift',
  'go',
  'rs',
  'rb',
  'php',
  'lua',
  'sh',
  'html',
  'css',
  'sql',
  'gradle',
  'patch',
  'diff',
};
const Set<String> _dataExt = {
  'json',
  'yaml',
  'yml',
  'toml',
  'lock',
  'csv',
  'xml',
  'ini',
  'cfg',
  'conf',
  'log',
  'env',
  'properties',
  'ipynb',
  'db',
  'sqlite',
};
const Set<String> _otherExt = {
  'txt',
  'rst',
  'pdf',
  'docx',
  'xlsx',
  'pptx',
  'mp3',
  'mp4',
  'wav',
  'ogg',
};

/// Extensions that make a bare name a file reference. Unknown ones (`foo.bar`,
/// `1.2.3`) stay plain code or text.
final Set<String> chatKnownFileExtensions = {
  ..._markdownExt,
  ..._archiveExt,
  ..._imageExt,
  ..._codeExt,
  ..._dataExt,
  ..._otherExt,
};

/// Regex alternation of [chatKnownFileExtensions] (no capture group).
final String _extAlternation =
    (chatKnownFileExtensions.toList()
          ..sort((a, b) => b.length.compareTo(a.length)))
        .join('|');

/// Library and runtime names that look like files in prose («Node.js»).
const Set<String> _notFiles = {
  'node.js',
  'next.js',
  'vue.js',
  'nuxt.js',
  'react.js',
  'express.js',
  'three.js',
  'd3.js',
  'p5.js',
  'chart.js',
  'ember.js',
  'backbone.js',
  'alpine.js',
  'angular.js',
  'socket.js',
  'jquery.js',
  'underscore.js',
  'lodash.js',
  'moment.js',
  'anime.js',
  'deno.js',
  'nest.js',
  'koa.js',
  'preact.js',
  'meteor.js',
  'phaser.js',
  'pixi.js',
  'leaflet.js',
  'plotly.js',
};

/// First segments of absolute paths a machine really has: an extension-less
/// `/api/v1/users` or `/compact` is a route or a command, not a folder.
const Set<String> _knownRoots = {
  'home',
  'usr',
  'etc',
  'var',
  'tmp',
  'opt',
  'mnt',
  'srv',
  'root',
  'users',
  'volumes',
  'library',
  'applications',
  'data',
  'storage',
  'sdcard',
  'workspace',
  'workspaces',
  'app',
  'proc',
  'sys',
  'dev',
  'bin',
  'sbin',
  'lib',
  'media',
  'run',
  'snap',
  'private',
  'projects',
  'repo',
  'src',
};

final RegExp _badChar = RegExp(
  r'''[\s\\:*?"<>|(){}\[\]$`,;!'@#=^&\u0000-\u001F\u007F\u202A-\u202E\u2066-\u2069]''',
);
final RegExp _lineSuffix = RegExp(
  r'^(.*?)(:\d{1,6}(?:[:\-]\d{1,6})?|#L\d{1,6}(?:-L?\d{1,6})?)$',
);

/// The line and the end of the range in a suffix kept by [_lineSuffix]:
/// `:120`, `:10-20`, `:10:5` (line and column), `#L10`, `#L10-L20`.
(int?, int?) _linesOf(String suffix) {
  final range = RegExp(r'^(?::|#L)(\d+)-L?(\d+)$').firstMatch(suffix);
  if (range != null) {
    final from = int.parse(range.group(1)!);
    final to = int.parse(range.group(2)!);
    return to >= from ? (from, to) : (from, null);
  }
  final one = RegExp(r'^(?::|#L)(\d+)').firstMatch(suffix);
  return one == null ? (null, null) : (int.parse(one.group(1)!), null);
}

/// Whether [raw] is a file or folder reference, with the chip's data.
///
/// [plain] is for text outside code: only files with a known extension
/// count there (a bare `/home/demo/` in prose stays prose). Inside code
/// spans a `~/…` or `…/` path is a folder too.
ChatFileRef? chatFileRefFor(String raw, {bool plain = false}) {
  var text = raw.trim();
  if (text.isEmpty || text.length > 400) return null;
  var line = '';
  final suffix = _lineSuffix.firstMatch(text);
  if (suffix != null) {
    text = suffix.group(1)!;
    line = suffix.group(2)!;
  }
  if (text.isEmpty || _badChar.hasMatch(text) || text.contains('//')) {
    return null;
  }
  final ChatPathRoot root;
  final bool prefixed;
  if (text.startsWith('~/')) {
    root = ChatPathRoot.home;
    prefixed = true;
  } else if (text.startsWith('/')) {
    root = ChatPathRoot.absolute;
    prefixed = true;
  } else if (text.startsWith('./') || text.startsWith('../')) {
    root = ChatPathRoot.relative;
    prefixed = true;
  } else {
    root = ChatPathRoot.relative;
    prefixed = false;
  }
  final trailingSlash = text.length > 1 && text.endsWith('/');
  final segments = text.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  // `.` and `..` only lead a relative path.
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    final dots = s == '.' || s == '..';
    if (dots && (i != 0 || root != ChatPathRoot.relative)) return null;
    if (s.replaceAll('.', '').isEmpty && !dots) return null;
  }
  final name = segments.last;
  if (name == '.' || name == '..' || name == '~') return null;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && dot < name.length - 1
      ? name.substring(dot + 1).toLowerCase()
      : '';
  final knownExt = chatKnownFileExtensions.contains(ext);

  var folder = false;
  if (knownExt && !trailingSlash) {
    // A file. A bare name must not be a library («Node.js») nor start with a
    // domain («example.com/readme.md»).
    if (!prefixed) {
      if (segments.length == 1 && _notFiles.contains(name.toLowerCase())) {
        return null;
      }
      if (segments.length > 1 && segments.first.contains('.')) return null;
    }
  } else {
    if (plain) return null;
    switch (root) {
      case ChatPathRoot.home:
        break;
      case ChatPathRoot.absolute:
        if (segments.length < 2 ||
            !_knownRoots.contains(segments.first.toLowerCase())) {
          return null;
        }
      case ChatPathRoot.relative:
        // `./gradlew` is a command; `./build/` says it is a folder.
        if (!prefixed || !trailingSlash) return null;
    }
    folder = true;
  }

  var path = text;
  if (trailingSlash) path = path.substring(0, path.length - 1);
  final kind = folder
      ? ChatFileKind.folder
      : _markdownExt.contains(ext)
      ? ChatFileKind.markdown
      : _archiveExt.contains(ext)
      ? ChatFileKind.archive
      : _imageExt.contains(ext)
      ? ChatFileKind.image
      : ext == 'pdf'
      ? ChatFileKind.pdf
      : _codeExt.contains(ext)
      ? ChatFileKind.code
      : _dataExt.contains(ext)
      ? ChatFileKind.data
      : ChatFileKind.file;
  final (from, to) = line.isEmpty ? (null, null) : _linesOf(line);
  return ChatFileRef(
    path: path,
    name: '$name$line',
    kind: kind,
    root: root,
    line: from == null || from < 1 ? null : from,
    endLine: from == null || from < 1 ? null : to,
  );
}

/// Characters a path segment may hold in prose (no regex flags needed).
const String _segmentChar = r'''[^\s/\\:*?"<>|(){}\[\]$`,;!'“”‘’«»@#=^&%~]''';

/// Pattern of a file reference in running text (not code): an optional
/// `~/`, `./`, `../` or `/` start, segments, and a known extension. Preceded
/// by a space or an opening mark, never by a word, `/`, `:`, `.` or `@`
/// (that is a URL, a date or an address); followed by a space or closing
/// punctuation, never by more name.
final String chatFilePattern =
    '(?<=^|[\\s(\\["\'“‘«>*,;=])'
    '(?:(?:~|\\.{1,2})?(?:/$_segmentChar+)+|$_segmentChar+(?:/$_segmentChar+)*)'
    '\\.(?:$_extAlternation)'
    '(?::\\d{1,6}(?:[:\\-]\\d{1,6})?|#L\\d{1,6}(?:-L?\\d{1,6})?)?'
    '(?=[\\s)\\]}"\'”’»,;:!?*<>~]|\\.(?:\\s|\$)|\$)';

/// Pattern of a citation number («[3]»), group 1 the number. It follows a
/// space or punctuation (or another citation), so `array[0]`, `f(x)[1]`,
/// `a[1][2]` and a line that starts with «[1]» are not citations; it does
/// not lead into `(` (a Markdown link), `:`, `=`, `.name` or more name.
const String chatCitationPattern =
    r'(?<=[ \t .,;:!?"'
    "'"
    r'”’»…%*](?:\[[1-9]\d{0,2}\])*)'
    r'\[([1-9]\d{0,2})\]'
    r'(?![\w(:=]|\.\w|\[(?![1-9]\d{0,2}\]))';

/// Pattern of a web address written bare in running text, as one token: not
/// the target of a Markdown link (`](`), not an autolink (`<…>`), not part of
/// a longer word or path, and without the punctuation that closes the
/// sentence. A closing `)` belongs to it only when the address opened one.
const String chatBareUrlPattern =
    '(?<![\\w/@.=:"\'<\\]]|\\]\\()'
    'https?://'
    '(?:[^\\s<>()\\[\\]]|\\([^\\s<>()]*\\))*'
    '(?:[^\\s<>()\\[\\].,;:!?*_~`"\'”’»]|\\([^\\s<>()]*\\))';

final RegExp _singleUrl = RegExp(r'^\s*https?://\S+\s*$');

/// Cheap pre-check: can [text] hold a bare web address that is not the
/// whole text (a lone address keeps its own handling: the link card)?
bool chatMayHaveBareUrls(String text) =>
    text.contains('://') && !_singleUrl.hasMatch(text);

final RegExp _citationHint = RegExp(r'\[[1-9]\d{0,2}\]');
final RegExp _pathHint = RegExp(
  '/[^\\s/]|\\.(?:$_extAlternation)(?![A-Za-z0-9_])',
  caseSensitive: false,
);

/// Cheap pre-check: can [text] hold a citation number at all?
bool chatMayHaveCitations(String text) =>
    text.contains('[') && _citationHint.hasMatch(text);

/// Cheap pre-check: can [text] hold a file reference at all?
bool chatMayHaveFilePaths(String text) => _pathHint.hasMatch(text);

/// Whether [index] of [text] sits inside an unclosed `[` (a link's text,
/// which keeps its own tap).
bool chatInsideBrackets(String text, int index) {
  var depth = 0;
  for (var i = index - 1; i >= 0; i--) {
    final c = text.codeUnitAt(i);
    if (c == 0x5D) {
      depth++;
    } else if (c == 0x5B) {
      if (depth == 0) return true;
      depth--;
    }
  }
  return false;
}

/// The links a message lists for its citation numbers.
final class ChatCitationSources {
  const ChatCitationSources(this.urls);

  static const ChatCitationSources empty = ChatCitationSources({});

  /// Citation number to `http(s)` URL.
  final Map<int, String> urls;

  String? operator [](int number) => urls[number];

  bool get isEmpty => urls.isEmpty;
}

final RegExp _labelLine = RegExp(
  r'^[ \t]*(?:[-*+][ \t]+|\d{1,3}[.)][ \t]+)?\[(\d{1,3})\]:?[ \t]*(.*)$',
);
final RegExp _sourcesHeading = RegExp(
  r'^[ \t]{0,3}(?:#{1,6}[ \t]*)?(?:\*\*|__)?[ \t]*'
  r'(?:fuentes|sources|referencias|references|refer[eê]ncias|fontes|quellen|'
  r'fonti|参考|出典|출처|来源)(?![A-Za-zÀ-ÿ])',
  caseSensitive: false,
);
final RegExp _numberedLine = RegExp(
  r'^[ \t]*(?:[-*+][ \t]+)?(\d{1,3})[.)][ \t]+(.*)$',
);
final RegExp _linkTarget = RegExp(r'\]\((https?://[^\s)]+)');
final RegExp _bareUrl = RegExp(r'https?://[^\s<>)\]]+');

String? _urlIn(String rest) {
  final target = _linkTarget.firstMatch(rest)?.group(1);
  var url = target ?? _bareUrl.firstMatch(rest)?.group(0);
  if (url == null) return null;
  while (url!.isNotEmpty && '.,;:'.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return url.length > 'https://'.length ? url : null;
}

final LinkedHashMap<String, ChatCitationSources> _sourcesCache =
    LinkedHashMap<String, ChatCitationSources>();

/// The numbered sources [data] lists: «[1] https://…» lines (also
/// «[1]: …» definitions), and numbered lines under a «Fuentes» / «Sources»
/// heading. The first line of a number wins. Memoised: the same text is
/// parsed once.
ChatCitationSources chatCitationSources(String data) {
  if (!data.contains('http')) return ChatCitationSources.empty;
  final cached = _sourcesCache.remove(data);
  if (cached != null) {
    _sourcesCache[data] = cached;
    return cached;
  }
  final urls = <int, String>{};
  var inSources = false;
  for (final line in data.split('\n')) {
    if (line.trimLeft().startsWith('#')) inSources = false;
    if (_sourcesHeading.hasMatch(line)) {
      inSources = true;
      continue;
    }
    final label = _labelLine.firstMatch(line);
    if (label != null) {
      final n = int.parse(label.group(1)!);
      final url = _urlIn(label.group(2)!);
      if (n > 0 && url != null) urls.putIfAbsent(n, () => url);
      // A list run together in one line: `[1] https://a … [2] https://b …`.
      _addRunTogether(line, label.end - label.group(2)!.length, urls);
      continue;
    }
    if (inSources) {
      final item = _numberedLine.firstMatch(line);
      if (item != null) {
        final n = int.parse(item.group(1)!);
        final url = _urlIn(item.group(2)!);
        if (n > 0 && url != null) urls.putIfAbsent(n, () => url);
      }
    }
  }
  final result = urls.isEmpty
      ? ChatCitationSources.empty
      : ChatCitationSources(Map.unmodifiable(urls));
  _sourcesCache[data] = result;
  if (_sourcesCache.length > 24) {
    _sourcesCache.remove(_sourcesCache.keys.first);
  }
  return result;
}

/// Every `[n] url` that starts after [from] in [line] (a list written as
/// running text): the first number of a line is read by the line rule, the
/// ones that follow it by this.
void _addRunTogether(String line, int from, Map<int, String> urls) {
  if (!line.contains('] ')) return;
  for (final start in _entryStarts(line)) {
    if (start.start < from) continue;
    final end = _nextStartOrEnd(line, start);
    final body = _parseSourceBody(line.substring(start.bodyStart, end));
    if (body != null && start.number > 0) {
      urls.putIfAbsent(start.number, () => body.url);
    }
  }
}

// ---------------------------------------------------------------------------
// The section of sources, as rows.
// ---------------------------------------------------------------------------

/// One numbered source of a reply: «[1] https://… — what it is».
final class ChatSourceEntry {
  const ChatSourceEntry({
    required this.number,
    required this.url,
    required this.description,
  });

  final int number;
  final String url;

  /// What the reply says about the source («EFE: 31 heridos…»), or empty.
  final String description;

  /// The host without `www.`: «efe.com».
  String get domain => chatUrlDomain(url);

  /// What the row shows as its title: the description, or a readable slug of
  /// the link when there is none.
  String get title =>
      description.isNotEmpty ? description : chatUrlSlugTitle(url);

  @override
  bool operator ==(Object other) =>
      other is ChatSourceEntry &&
      other.number == number &&
      other.url == url &&
      other.description == description;

  @override
  int get hashCode => Object.hash(number, url, description);
}

/// The host of [url] without `www.`, or [url] when it has none.
String chatUrlDomain(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return url;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// A readable title out of the last path segment of [url]
/// («heridos-urda-toledo.html» → «Heridos urda toledo»), or the domain.
String chatUrlSlugTitle(String url) {
  final uri = Uri.tryParse(url);
  final segments = (uri?.pathSegments ?? const <String>[])
      .where((s) => s.isNotEmpty)
      .toList();
  if (segments.isEmpty) return chatUrlDomain(url);
  var slug = segments.last;
  try {
    slug = Uri.decodeComponent(slug);
  } catch (_) {}
  slug = slug
      .replaceFirst(RegExp(r'\.(?:s?html?|php|aspx?|amp)$'), '')
      .replaceAll(RegExp(r'[-_+]+'), ' ')
      .trim();
  if (slug.isEmpty || RegExp(r'^[\d\s]+$').hasMatch(slug)) {
    // A bare id says nothing: the segment before it, if any.
    if (segments.length > 1) {
      final up = segments[segments.length - 2]
          .replaceAll(RegExp(r'[-_+]+'), ' ')
          .trim();
      if (up.isNotEmpty && !RegExp(r'^[\d\s]+$').hasMatch(up)) {
        return up[0].toUpperCase() + up.substring(1);
      }
    }
    return chatUrlDomain(url);
  }
  return slug[0].toUpperCase() + slug.substring(1);
}

/// The link as a chip writes it: no scheme, no closing `/`
/// («efe.com/espana/2026-11-01/heridos»). The chip cuts it with an ellipsis,
/// so a copied selection still holds the whole address.
String chatUrlChipLabel(String url) {
  var label = url.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  if (label.startsWith('www.')) label = label.substring(4);
  while (label.endsWith('/')) {
    label = label.substring(0, label.length - 1);
  }
  return label;
}

final RegExp _strictSourcesHeading = RegExp(
  r'^[ \t]{0,3}(?:#{1,6}[ \t]*)?(?:\*\*|__)?[ \t]*'
  r'(?:fuentes|sources|referencias|references|refer[eê]ncias|fontes|quellen|'
  r'fonti|参考|出典|출처|来源)'
  r'[ \t]*:?[ \t]*(?:\*\*|__)?[ \t]*:?[ \t]*(?:#{1,6})?[ \t]*$',
  caseSensitive: false,
);

final RegExp _headingHint = RegExp(
  r'fuentes|sources|referencias|references|refer[eê]ncias|fontes|quellen|'
  r'fonti|参考|出典|출처|来源',
  caseSensitive: false,
);

/// Cheap pre-check: can [text] hold a sources heading at all?
bool chatMayHaveSourcesHeading(String text) => _headingHint.hasMatch(text);

/// Whether [line] is a heading that only says «Sources» (also in bold or
/// with a colon), not a sentence that starts with that word.
bool chatIsSourcesHeading(String line) => _strictSourcesHeading.hasMatch(line);

typedef _Start = ({int number, int start, int bodyStart});

final RegExp _bracketStart = RegExp(
  r'(?<=^|[ \t])\[(\d{1,3})\](?!:)[ \t]*'
  r'(?=https?://|\[[^\]\n]*\]\(https?://)',
);
final RegExp _numberedStart = RegExp(
  r'^[ \t]*(?:[-*+][ \t]+)?(\d{1,3})[.)][ \t]+'
  r'(?=https?://|\[[^\]\n]*\]\(https?://)',
);
final RegExp _linePrefix = RegExp(r'^[ \t]*(?:(?:[-*+]|\d{1,3}[.)])[ \t]+)?$');

/// The starts of numbered sources in [line]: the first may be a list item,
/// the ones after it follow a space («… [2] https://…»).
List<_Start> _entryStarts(String line) {
  final starts = <_Start>[];
  for (final m in _bracketStart.allMatches(line)) {
    starts.add((
      number: int.parse(m.group(1)!),
      start: m.start,
      bodyStart: m.end,
    ));
  }
  if (starts.isEmpty || starts.first.start > 0) {
    final m = _numberedStart.firstMatch(line);
    if (m != null) {
      starts.insert(0, (
        number: int.parse(m.group(1)!),
        start: m.start,
        bodyStart: m.end,
      ));
    }
  }
  return starts;
}

int _nextStartOrEnd(String line, _Start start) {
  final all = _entryStarts(line);
  for (final other in all) {
    if (other.start > start.start) return other.start;
  }
  return line.length;
}

final RegExp _bodyLink = RegExp(r'^\[([^\]\n]*)\]\((https?://[^\s)]+)\)(.*)$');
final RegExp _bodyBare = RegExp(r'^(https?://\S+)(.*)$');
final RegExp _separatorLead = RegExp(r'^[\s\-–—:|·•]+');

({String url, String description, bool terminated})? _parseSourceBody(
  String body,
) {
  final text = body.trim();
  if (text.isEmpty) return null;
  String? url;
  var rest = '';
  var linkText = '';
  var terminated = false;
  final link = _bodyLink.firstMatch(text);
  if (link != null) {
    linkText = link.group(1)!;
    url = link.group(2);
    rest = link.group(3)!;
    terminated = true;
  } else {
    final bare = _bodyBare.firstMatch(text);
    if (bare == null) return null;
    url = bare.group(1);
    rest = bare.group(2)!;
    // The address is whole once something (a space) follows it, or the
    // entry ends because another one starts.
    terminated = rest.isNotEmpty || body != body.trimRight();
    while (url!.isNotEmpty && '.,;:)'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
  }
  if (url!.length <= 'https://'.length) return null;
  var description = rest
      .replaceFirst(_separatorLead, '')
      .replaceAll(RegExp(r'\*\*|__|`'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (linkText.trim().isNotEmpty) {
    final label = linkText.replaceAll(RegExp(r'\*\*|__|`'), '').trim();
    description = description.isEmpty ? label : '$label — $description';
  }
  return (url: url, description: description, terminated: terminated);
}

/// A run of numbered sources found in a list of lines.
final class ChatSourcesSection {
  const ChatSourcesSection({
    required this.entries,
    required this.end,
    this.held = false,
  });

  /// The sources whole enough to show.
  final List<ChatSourceEntry> entries;

  /// The first line after the section.
  final int end;

  /// A live section whose last entry (or its first one) is still arriving:
  /// what was cut stays out of the text until it is whole.
  final bool held;
}

final RegExp _openTailCandidate = RegExp(r'(?:^|[ \t])(\[(?:\d{1,3}\]?)?)');
final RegExp _partialNumbered = RegExp(
  r'^[ \t]*(?:[-*+]|\d{1,3}[.)]?)[ \t]*'
  r'(?:h(?:t(?:t(?:p(?:s(?::(?:/(?:/)?)?)?)?)?)?)?)?$',
);

/// The part of a live line that cannot be read yet («… [3] htt»): where to
/// cut it, or -1 when the line is whole as far as sources go.
int _openLineCut(String line) {
  if (_partialNumbered.hasMatch(line)) return 0;
  Match? last;
  for (final m in _openTailCandidate.allMatches(line)) {
    last = m;
  }
  if (last == null) return -1;
  final at = last.end - last.group(1)!.length;
  // A complete start is the entry's business, not a cut.
  for (final s in _entryStarts(line)) {
    if (s.start == at) return -1;
  }
  return at;
}

/// The sources listed from line [from] of [lines] on, or null when the line
/// does not start one. [live] reads text that is still arriving: the last
/// line of [lines] has no line break yet, so what it holds is not trusted
/// until its address is closed and a word follows it.
ChatSourcesSection? chatSourcesSectionAt(
  List<String> lines,
  int from, {
  bool live = false,
}) {
  final openLine = live && lines.isNotEmpty && lines.last.isNotEmpty
      ? lines.length - 1
      : -1;
  final raws = <({int number, StringBuffer body, int line})>[];
  var consumed = from;
  var sawBlank = false;
  var held = false;
  var j = from;
  for (; j < lines.length; j++) {
    var line = lines[j];
    if (line.trim().isEmpty) {
      sawBlank = true;
      continue;
    }
    if (line.trimLeft().startsWith('#')) break;
    if (j == openLine) {
      final cut = _openLineCut(line);
      if (cut >= 0) {
        line = line.substring(0, cut);
        held = true;
      }
    }
    final starts = _entryStarts(line);
    if (starts.isEmpty) {
      if (raws.isEmpty) {
        // A first line that can still become an entry is held.
        if (held && line.trim().isEmpty) {
          consumed = j + 1;
          break;
        }
        return null;
      }
      if (sawBlank) break;
      if (line.trim().isNotEmpty) raws.last.body.write(' ${line.trim()}');
      consumed = j + 1;
      continue;
    }
    final lead = line.substring(0, starts.first.start);
    final leads = _linePrefix.hasMatch(lead);
    if (raws.isEmpty && !leads) return null;
    if (sawBlank && !leads) break;
    sawBlank = false;
    if (raws.isNotEmpty && !leads) raws.last.body.write(' ${lead.trim()}');
    for (var k = 0; k < starts.length; k++) {
      final end = k + 1 < starts.length ? starts[k + 1].start : line.length;
      raws.add((
        number: starts[k].number,
        body: StringBuffer(line.substring(starts[k].bodyStart, end)),
        line: j,
      ));
    }
    consumed = j + 1;
  }
  if (raws.isEmpty) {
    // Live: the heading's first line is still being written («[», «[1»).
    if (live && held) {
      return ChatSourcesSection(
        entries: const [],
        end: lines.length,
        held: true,
      );
    }
    return null;
  }
  final entries = <ChatSourceEntry>[];
  for (var k = 0; k < raws.length; k++) {
    final raw = raws[k];
    final parsed = _parseSourceBody(raw.body.toString());
    final isLast = k == raws.length - 1;
    if (live && isLast) {
      final open = raw.line == openLine;
      if (parsed == null ||
          (open && (!parsed.terminated || parsed.description.isEmpty))) {
        held = true;
        continue;
      }
    }
    if (parsed == null || raw.number <= 0) continue;
    entries.add(
      ChatSourceEntry(
        number: raw.number,
        url: parsed.url,
        description: parsed.description,
      ),
    );
  }
  return ChatSourcesSection(
    entries: List<ChatSourceEntry>.unmodifiable(entries),
    // A live section runs to the end of the text: what is held is not text
    // to show but the rest of an entry.
    end: live && held ? lines.length : consumed,
    held: held,
  );
}
