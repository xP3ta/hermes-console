import 'package:flutter/material.dart';

/// Generic icon for files whose type is not recognised.
const IconData projectFileGenericIcon = Icons.insert_drive_file_outlined;

const IconData _code = Icons.code_rounded;
const IconData _shell = Icons.terminal_rounded;
const IconData _data = Icons.data_object_rounded;
const IconData _table = Icons.table_chart_outlined;
const IconData _doc = Icons.description_outlined;
const IconData _pdf = Icons.picture_as_pdf_outlined;
const IconData _image = Icons.image_outlined;
const IconData _archive = Icons.folder_zip_outlined;
const IconData _config = Icons.settings_outlined;
const IconData _lock = Icons.lock_outline_rounded;

/// Lower-case exact file names, then extensions with their leading dot.
/// Exact names win, so lockfiles beat their `.json` extension.
const Map<String, IconData> _projectFileIcons = {
  // Exact names.
  'package-lock.json': _lock,
  'pnpm-lock.yaml': _lock,
  'composer.lock': _lock,
  'dockerfile': _config,
  'makefile': _config,
  '.gitignore': _config,
  '.gitattributes': _config,
  '.editorconfig': _config,
  '.env': _config,
  // Code.
  '.dart': _code,
  '.py': _code,
  '.js': _code,
  '.jsx': _code,
  '.mjs': _code,
  '.ts': _code,
  '.tsx': _code,
  '.kt': _code,
  '.kts': _code,
  '.java': _code,
  '.go': _code,
  '.rs': _code,
  '.c': _code,
  '.h': _code,
  '.cc': _code,
  '.cpp': _code,
  '.hpp': _code,
  '.swift': _code,
  '.rb': _code,
  '.php': _code,
  '.cs': _code,
  '.html': _code,
  '.css': _code,
  '.sh': _shell,
  '.bash': _shell,
  '.zsh': _shell,
  '.fish': _shell,
  '.ps1': _shell,
  // Data.
  '.json': _data,
  '.yaml': _data,
  '.yml': _data,
  '.toml': _data,
  '.xml': _data,
  '.arb': _data,
  '.csv': _table,
  '.tsv': _table,
  // Docs.
  '.md': _doc,
  '.markdown': _doc,
  '.txt': _doc,
  '.rst': _doc,
  '.log': _doc,
  '.pdf': _pdf,
  // Images.
  '.png': _image,
  '.jpg': _image,
  '.jpeg': _image,
  '.gif': _image,
  '.webp': _image,
  '.bmp': _image,
  '.ico': _image,
  '.svg': _image,
  '.heic': _image,
  // Archives.
  '.zip': _archive,
  '.tar': _archive,
  '.gz': _archive,
  '.tgz': _archive,
  '.bz2': _archive,
  '.xz': _archive,
  '.7z': _archive,
  '.rar': _archive,
  '.jar': _archive,
  // Config.
  '.ini': _config,
  '.cfg': _config,
  '.conf': _config,
  '.properties': _config,
  // Lockfiles.
  '.lock': _lock,
};

/// Material icon for a file row in Projects › Files: exact name first, then
/// the longest known extension (`a.tar.gz` tries `.tar.gz`, then `.gz`).
/// Unmatched dotfiles count as config; anything else keeps the generic icon.
IconData projectFileIcon(String name) {
  final lower = name.toLowerCase();
  final exact = _projectFileIcons[lower];
  if (exact != null) return exact;
  for (var dot = lower.length > 1 ? lower.indexOf('.', 1) : -1; dot >= 0;) {
    final hit = _projectFileIcons[lower.substring(dot)];
    if (hit != null) return hit;
    dot = lower.indexOf('.', dot + 1);
  }
  if (lower.startsWith('.') && lower.length > 1) return _config;
  return projectFileGenericIcon;
}
