/// How the Artefactos view presents what [collectChatContent] found: the
/// file type of each file, where an item lives, and the files grouped by
/// type so «Todo» reads as sections.
///
/// Desktop gives every file the same glyph and the kind tag «archivo»; the
/// per-type icon and grouping are Console additions so a phone list can be
/// read at a glance. Pure and synchronous: no I/O.
library;

import '../utils/external_link_labels.dart';
import 'chat_content_extractor.dart';

/// Group of a file, in the order the groups are listed.
enum ChatContentFileType {
  pdf,
  document,
  spreadsheet,
  presentation,
  archive,
  app,
  audio,
  video,
  text,
  data,
  code,
  other,
}

const Map<String, ChatContentFileType> _byExtension = {
  'pdf': ChatContentFileType.pdf,
  'doc': ChatContentFileType.document,
  'docx': ChatContentFileType.document,
  'odt': ChatContentFileType.document,
  'rtf': ChatContentFileType.document,
  'pages': ChatContentFileType.document,
  'xls': ChatContentFileType.spreadsheet,
  'xlsx': ChatContentFileType.spreadsheet,
  'ods': ChatContentFileType.spreadsheet,
  'csv': ChatContentFileType.spreadsheet,
  'tsv': ChatContentFileType.spreadsheet,
  'numbers': ChatContentFileType.spreadsheet,
  'ppt': ChatContentFileType.presentation,
  'pptx': ChatContentFileType.presentation,
  'odp': ChatContentFileType.presentation,
  'key': ChatContentFileType.presentation,
  'zip': ChatContentFileType.archive,
  'tar': ChatContentFileType.archive,
  'gz': ChatContentFileType.archive,
  'tgz': ChatContentFileType.archive,
  'bz2': ChatContentFileType.archive,
  'xz': ChatContentFileType.archive,
  '7z': ChatContentFileType.archive,
  'rar': ChatContentFileType.archive,
  'apk': ChatContentFileType.app,
  'aab': ChatContentFileType.app,
  'xapk': ChatContentFileType.app,
  'mp3': ChatContentFileType.audio,
  'wav': ChatContentFileType.audio,
  'ogg': ChatContentFileType.audio,
  'opus': ChatContentFileType.audio,
  'flac': ChatContentFileType.audio,
  'm4a': ChatContentFileType.audio,
  'aac': ChatContentFileType.audio,
  'mp4': ChatContentFileType.video,
  'm4v': ChatContentFileType.video,
  'mov': ChatContentFileType.video,
  'mkv': ChatContentFileType.video,
  'webm': ChatContentFileType.video,
  'avi': ChatContentFileType.video,
  'txt': ChatContentFileType.text,
  'md': ChatContentFileType.text,
  'markdown': ChatContentFileType.text,
  'rst': ChatContentFileType.text,
  'log': ChatContentFileType.text,
  'json': ChatContentFileType.data,
  'yaml': ChatContentFileType.data,
  'yml': ChatContentFileType.data,
  'toml': ChatContentFileType.data,
  'xml': ChatContentFileType.data,
  'sql': ChatContentFileType.data,
  'db': ChatContentFileType.data,
  'sqlite': ChatContentFileType.data,
  'html': ChatContentFileType.code,
  'htm': ChatContentFileType.code,
  'css': ChatContentFileType.code,
  'js': ChatContentFileType.code,
  'mjs': ChatContentFileType.code,
  'ts': ChatContentFileType.code,
  'tsx': ChatContentFileType.code,
  'jsx': ChatContentFileType.code,
  'py': ChatContentFileType.code,
  'dart': ChatContentFileType.code,
  'kt': ChatContentFileType.code,
  'java': ChatContentFileType.code,
  'go': ChatContentFileType.code,
  'rs': ChatContentFileType.code,
  'rb': ChatContentFileType.code,
  'php': ChatContentFileType.code,
  'swift': ChatContentFileType.code,
  'c': ChatContentFileType.code,
  'h': ChatContentFileType.code,
  'cpp': ChatContentFileType.code,
  'sh': ChatContentFileType.code,
};

final RegExp _extensionRe = RegExp(r'\.([a-z0-9]{1,8})$', caseSensitive: false);

/// Lower-case extension of the item's name (`informe.PDF` → `pdf`), or ''.
String chatContentExtension(ChatContentItem item) =>
    _extensionRe.firstMatch(item.label)?.group(1)?.toLowerCase() ?? '';

/// The group a file belongs to. Images and links are not files here.
ChatContentFileType chatContentFileType(ChatContentItem item) =>
    _byExtension[chatContentExtension(item)] ?? ChatContentFileType.other;

final RegExp _windowsPathRe = RegExp(r'^[A-Za-z]:[\\/]');

/// Where the item lives, shown in grey under its name: the folder of a path,
/// host and folder of a file URL, host and path of a link. Null when there
/// is nothing to say (inline `data:` images, a bare name).
String? chatContentLocation(ChatContentItem item) {
  final value = item.value;
  if (value.startsWith('data:')) return null;
  if (item.kind == ChatContentKind.link) return hostPathLabel(value);
  if (RegExp(r'^(?:https?|file)://', caseSensitive: false).hasMatch(value)) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    String path;
    try {
      path = Uri.decodeFull(uri.path);
    } catch (_) {
      path = uri.path;
    }
    final folder = _parent(path, '/');
    if (uri.scheme.toLowerCase() == 'file') return folder;
    final host = shortHostLabel(value);
    return folder == null || folder == '/' ? host : '$host$folder';
  }
  final windows = _windowsPathRe.hasMatch(value);
  return _parent(value, windows ? r'\' : '/');
}

String? _parent(String path, String separator) {
  final normalized = separator == '/' ? path : path.replaceAll('/', r'\');
  final cut = normalized.lastIndexOf(separator);
  if (cut < 0) return null;
  if (cut == 0) return separator;
  return normalized.substring(0, cut);
}

/// Files grouped by [ChatContentFileType], groups in enum order and items in
/// the order given (newest first).
List<(ChatContentFileType, List<ChatContentItem>)> groupChatContentFiles(
  Iterable<ChatContentItem> files,
) {
  final groups = <ChatContentFileType, List<ChatContentItem>>{};
  for (final item in files) {
    groups.putIfAbsent(chatContentFileType(item), () => []).add(item);
  }
  return [
    for (final type in ChatContentFileType.values)
      if (groups[type] case final items?) (type, items),
  ];
}
