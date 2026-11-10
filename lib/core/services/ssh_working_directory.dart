// La carpeta en la que está el shell del terminal (Ola 6, mock 136 v2-A: la
// segunda línea sobre el terminal, `~/proyecto` en mono). Solo lo que dice
// el propio shell, nunca una suposición:
//  * OSC 7 (`ESC ] 7 ; file://host/ruta BEL`), lo que emiten zsh, fish y el
//    `vte.sh` de muchas distribuciones en cada prompt;
//  * si no, el título que pone el `.bashrc` por defecto de Debian y Ubuntu,
//    `usuario@host: ~/carpeta` (OSC 0/2).
// Sin ninguno de los dos, no hay carpeta y la línea no se pinta.

/// Longest folder kept (a path the shell sends; anything longer is noise).
const int sshWorkingDirectoryMaxLength = 1024;

/// Control characters (C0, DEL, C1), line and paragraph separators and the
/// bidirectional marks, overrides and isolates: a folder the server sends
/// must never read backwards (`exe.txt` shown as `txt.exe`).
final RegExp _controls = RegExp(
  r'[\x00-\x1F\x7F-\x9F\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]',
);

/// Bash's default title: `user@host: ~/dir` (Debian and Ubuntu `.bashrc`).
final RegExp _bashTitle = RegExp(r'^[\w.-]+@[\w.-]+:\s*([~/].*)$');

String? _bounded(String value) {
  final clean = value.replaceAll(_controls, '').trim();
  if (clean.isEmpty || clean.length > sshWorkingDirectoryMaxLength) {
    return null;
  }
  return clean;
}

/// The folder an OSC 7 says, from the arguments after its code (`7`): a
/// `file://host/path` URL, percent-encoded. Null when it is not one.
String? sshWorkingDirectoryFromOsc7(List<String> args) {
  final raw = args.join(';').trim();
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'file' || !_hasPath(raw)) return null;
  String path;
  try {
    path = Uri.decodeComponent(uri.path);
  } on ArgumentError {
    path = uri.path;
  } on FormatException {
    path = uri.path;
  }
  if (!path.startsWith('/')) return null;
  return _bounded(path);
}

/// Whether the `file:` URL [raw] names a path. Dart gives one with none
/// (`file://host`) the path `/`, which is no folder the shell said: after
/// the host there must be a `/` (`file:///tmp`, `file://host/tmp`).
bool _hasPath(String raw) {
  final rest = raw.substring(raw.indexOf(':') + 1);
  if (!rest.startsWith('//')) return rest.startsWith('/');
  return rest.indexOf('/', 2) >= 0;
}

/// The folder in a window [title] of the form bash sets by default,
/// `user@host: dir` (dir starting with `~` or `/`). Null for any other
/// title (a program's, tmux's).
String? sshWorkingDirectoryFromTitle(String title) {
  final match = _bashTitle.firstMatch(title.replaceAll(_controls, '').trim());
  if (match == null) return null;
  return _bounded(match.group(1)!);
}

/// [directory] as a person reads it: the home of [user] as `~`
/// (`/home/user/x` → `~/x`, and `/root` for root).
String sshShortDirectory(String directory, String? user) {
  final home = user == null || user.isEmpty
      ? null
      : user == 'root'
      ? '/root'
      : '/home/$user';
  if (home == null) return directory;
  if (directory == home) return '~';
  if (directory.startsWith('$home/')) {
    return '~${directory.substring(home.length)}';
  }
  return directory;
}
