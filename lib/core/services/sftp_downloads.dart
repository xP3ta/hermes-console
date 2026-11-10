// Nombres de archivo seguros para guardar en el móvil (1.4.0): el nombre lo
// manda el servidor (o un adjunto, un artefacto): nunca se usa tal cual.
// Solo su último segmento, sin separadores, NUL, caracteres de control ni
// bidireccionales. Lo usa «Guardar en el móvil» (save_to_device.dart) para
// el nombre que sugiere el diálogo de Android.
//
// La copia privada de las descargas SFTP (carpeta, índice y su lista) ya no
// existe: la orden DESCARGAS-DIRECTAS escribe directo al destino elegido.
import 'dart:convert';
import 'dart:io';

/// Name used when the server's name leaves nothing usable.
const String sftpFallbackFileName = 'download';

/// Longest name kept, in UTF-8 bytes (ext4 and most providers allow 255).
const int _maxNameBytes = 255;

final RegExp _controlChars = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

/// Bidirectional overrides and isolates: they make `exe.jpg` read as
/// `gpj.exe`. Never part of a name shown as a file.
final RegExp _bidiChars = RegExp(r'[\u200e\u200f\u202a-\u202e\u2066-\u2069]');

/// Characters a document provider may refuse in a name.
final RegExp _reservedChars = RegExp(r'[<>:"|?*]');

/// The name suggested to save a file on the phone, from the [raw] name the
/// server (or the sender) gave: only its last segment (after `/` or `\`),
/// without NUL, control or bidirectional characters, with characters a
/// provider may refuse replaced by `_`, trimmed and at most 255 UTF-8 bytes
/// (the extension kept). Empty, `.` or `..` give [sftpFallbackFileName].
String sftpSafeFileName(String raw) {
  final segments = raw
      .split(RegExp(r'[/\\]'))
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  var name = segments.isEmpty ? '' : segments.last;
  name = name
      .replaceAll(_controlChars, '')
      .replaceAll(_bidiChars, '')
      .replaceAll(_reservedChars, '_')
      .trim();
  if (name.isEmpty || name == '.' || name == '..') {
    return sftpFallbackFileName;
  }
  return _fitName(name);
}

String _fitName(String name) {
  if (utf8.encode(name).length <= _maxNameBytes) return name;
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 && name.length - dot <= 16
      ? name.substring(dot)
      : '';
  var stem = name.substring(0, name.length - extension.length);
  final room = _maxNameBytes - utf8.encode(extension).length;
  while (stem.isNotEmpty && utf8.encode(stem).length > room) {
    stem = String.fromCharCodes(stem.runes.toList()..removeLast());
  }
  return '$stem$extension';
}

/// A write that ran out of room (`ENOSPC`).
bool isNoSpaceError(Object error) {
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    if (code == 28) return true;
    final message = '${error.message} ${error.osError?.message ?? ''}';
    return message.contains('No space left');
  }
  return false;
}
