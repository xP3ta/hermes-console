/// Routing of a delivered artifact (MEDIA file, attachment, generated
/// artifact) to the in-app viewer surface that can show it.
///
/// Pure (no I/O) so the routing table is unit-testable. The viewer only ever
/// receives bytes the app already holds in private storage; this function
/// decides how they are presented, never where they come from.
enum ArtifactViewerKind { html, svg, markdown, text, image, pdf, unsupported }

const Set<String> _htmlExtensions = {'.html', '.htm', '.xhtml'};
const Set<String> _markdownExtensions = {'.md', '.markdown', '.mdown'};
const Set<String> _imageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
};

/// Extension → `highlight` language id. A null value means plain monospace.
const Map<String, String?> _textExtensions = {
  '.txt': null,
  '.log': null,
  '.csv': null,
  '.tsv': null,
  '.env': null,
  '.conf': null,
  '.cfg': null,
  '.properties': 'properties',
  '.ini': 'ini',
  '.toml': 'ini',
  '.json': 'json',
  '.geojson': 'json',
  '.jsonl': 'json',
  '.yaml': 'yaml',
  '.yml': 'yaml',
  '.xml': 'xml',
  '.kml': 'xml',
  '.gpx': 'xml',
  '.py': 'python',
  '.dart': 'dart',
  '.js': 'javascript',
  '.mjs': 'javascript',
  '.ts': 'typescript',
  '.tsx': 'typescript',
  '.jsx': 'javascript',
  '.sh': 'bash',
  '.bash': 'bash',
  '.zsh': 'bash',
  '.kt': 'kotlin',
  '.kts': 'kotlin',
  '.java': 'java',
  '.c': 'cpp',
  '.h': 'cpp',
  '.cpp': 'cpp',
  '.hpp': 'cpp',
  '.rs': 'rust',
  '.go': 'go',
  '.rb': 'ruby',
  '.php': 'php',
  '.swift': 'swift',
  '.sql': 'sql',
  '.css': 'css',
  '.scss': 'scss',
  '.diff': 'diff',
  '.patch': 'diff',
  '.gradle': 'gradle',
  '.dockerfile': 'dockerfile',
  '.mk': 'makefile',
};

String _extensionOf(String name) {
  final base = name.split(RegExp(r'[\\/]')).last.toLowerCase();
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? '' : base.substring(dot);
}

String _normalisedMime(String mimeType) =>
    mimeType.split(';').first.trim().toLowerCase();

/// Picks the viewer surface for [name] / [mimeType]. The extension wins over
/// a generic MIME (`application/octet-stream`, `text/plain` for `.md`) because
/// the server often labels every text file as `text/plain`.
ArtifactViewerKind artifactViewerKindFor({
  required String name,
  required String mimeType,
}) {
  final ext = _extensionOf(name);
  final mime = _normalisedMime(mimeType);
  if (_htmlExtensions.contains(ext)) return ArtifactViewerKind.html;
  if (ext == '.svg') return ArtifactViewerKind.svg;
  if (_markdownExtensions.contains(ext)) return ArtifactViewerKind.markdown;
  if (ext == '.pdf') return ArtifactViewerKind.pdf;
  if (_imageExtensions.contains(ext)) return ArtifactViewerKind.image;
  if (_textExtensions.containsKey(ext)) return ArtifactViewerKind.text;
  if (mime == 'text/html' || mime == 'application/xhtml+xml') {
    return ArtifactViewerKind.html;
  }
  if (mime == 'image/svg+xml') return ArtifactViewerKind.svg;
  if (mime == 'text/markdown' || mime == 'text/x-markdown') {
    return ArtifactViewerKind.markdown;
  }
  if (mime == 'application/pdf') return ArtifactViewerKind.pdf;
  if (const {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  }.contains(mime)) {
    return ArtifactViewerKind.image;
  }
  if (mime.startsWith('text/') ||
      const {
        'application/json',
        'application/xml',
        'application/yaml',
        'application/x-yaml',
        'application/javascript',
        'application/x-sh',
      }.contains(mime)) {
    return ArtifactViewerKind.text;
  }
  return ArtifactViewerKind.unsupported;
}

/// `highlight` language for a text artifact, or null for plain monospace.
String? artifactHighlightLanguage({
  required String name,
  required String mimeType,
}) {
  final ext = _extensionOf(name);
  if (_textExtensions.containsKey(ext)) return _textExtensions[ext];
  return switch (_normalisedMime(mimeType)) {
    'application/json' => 'json',
    'application/xml' || 'text/xml' => 'xml',
    'application/yaml' || 'application/x-yaml' => 'yaml',
    'application/javascript' || 'text/javascript' => 'javascript',
    'text/css' => 'css',
    _ => null,
  };
}

/// Whether the viewer shows this kind inside the app (anything except the
/// metadata/open-with fallback).
bool artifactViewerRendersInline(ArtifactViewerKind kind) =>
    kind != ArtifactViewerKind.pdf && kind != ArtifactViewerKind.unsupported;
