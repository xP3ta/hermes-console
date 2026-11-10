// What already runs on a server, to attach the terminal to it: tmux sessions
// and Herdr (named sessions of Herdr's own, and the workspaces of the
// default one), and the lines the app types into the terminal to attach.
//
// Everything asked is read-only and fixed (no part of it comes from the
// user): `tmux list-sessions -F`, Herdr's `api snapshot` and
// `session list --json`. Everything typed is built here from a validated
// id or name, every word single-quoted; a name with a control character or
// a leading dash is refused, not escaped.
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'herdr_agents.dart';
import 'herdr_status.dart';
import 'ssh_session_kind.dart';

// ── Lines typed into the terminal ───────────────────────────────────────

final RegExp _tmuxId = RegExp(r'^\$[0-9]{1,9}$');

/// Longest session name the app will quote into a line.
const int terminalSessionNameMax = 128;

/// Whether [name] may be put (quoted) into a typed line: not empty, bounded,
/// no control character (a newline would run a second command, NUL would
/// cut the line) and no leading dash (an option).
bool terminalSessionNameOk(String name) {
  if (name.isEmpty || name.length > terminalSessionNameMax) return false;
  if (name.startsWith('-')) return false;
  for (final rune in name.runes) {
    if (rune < 0x20 || rune == 0x7F || (rune >= 0x80 && rune <= 0x9F)) {
      return false;
    }
  }
  return true;
}

final RegExp _herdrBin = RegExp(r'^/[A-Za-z0-9._/+-]+$');

String _herdrWord(String? herdr) => herdr != null && _herdrBin.hasMatch(herdr)
    ? herdrShellQuote(herdr)
    : 'herdr';

/// The lines the app types into a terminal the user chose to attach. Null
/// when what they would carry is not valid.
abstract final class TerminalAttach {
  /// `tmux attach-session -t '$3'`: by tmux's own id, which has a fixed
  /// shape, not by the name (a name can hold what the listing escapes).
  static String? tmux(String sessionId) => _tmuxId.hasMatch(sessionId)
      ? 'tmux attach-session -t ${herdrShellQuote(sessionId)}'
      : null;

  /// Herdr's named session; the default one is plain `herdr`.
  static String? herdrSession(
    String name, {
    bool isDefault = false,
    String? herdr,
  }) {
    if (isDefault) return _herdrWord(herdr);
    if (!terminalSessionNameOk(name)) return null;
    return '${_herdrWord(herdr)} session attach ${herdrShellQuote(name)}';
  }

  /// One agent's own terminal: `herdr agent attach 'w1:p2'`.
  static String? herdrAgent(String paneId, {String? herdr}) =>
      isHerdrPaneId(paneId)
      ? '${_herdrWord(herdr)} agent attach ${herdrShellQuote(paneId)}'
      : null;

  /// The default session with [workspaceId] in front: focuses it (for every
  /// client attached) and then opens Herdr.
  static String? herdrWorkspace(String workspaceId, {String? herdr}) {
    if (!RegExp(r'^w[0-9]+$').hasMatch(workspaceId)) return null;
    final bin = _herdrWord(herdr);
    return '$bin workspace focus ${herdrShellQuote(workspaceId)} '
        '>/dev/null 2>&1; $bin';
  }
}

// ── What is there ───────────────────────────────────────────────────────

class TmuxSession {
  const TmuxSession({
    required this.id,
    required this.name,
    required this.windows,
    required this.attached,
  });

  /// tmux's session id (`$3`): what the app attaches by.
  final String id;
  final String name;
  final int windows;
  final int attached;
}

enum TerminalProgram { notInstalled, failed, ready }

/// Read-only, constant: the id, window count, attached count and name of
/// each tmux session, tab separated (the name last).
final String sshTmuxListCommand = sshInLoginShell(
  'tmux list-sessions -F "#{session_id}\t#{session_windows}'
  '\t#{session_attached}\t#{session_name}"',
);

class TmuxListing {
  const TmuxListing(this.state, [this.sessions = const []]);

  final TerminalProgram state;
  final List<TmuxSession> sessions;
}

/// `tmux list-sessions -F` output: one session per line. A line that does
/// not have the shape is skipped.
List<TmuxSession> parseTmuxSessions(String output) {
  final out = <TmuxSession>[];
  for (final line in output.split('\n')) {
    final parts = line.split('\t');
    if (parts.length < 4) continue;
    final id = parts[0].trim();
    if (!_tmuxId.hasMatch(id)) continue;
    final windows = int.tryParse(parts[1]);
    final attached = int.tryParse(parts[2]);
    final name = parts.sublist(3).join('\t').trim();
    if (windows == null || attached == null || name.isEmpty) continue;
    out.add(
      TmuxSession(
        id: id,
        name: name.length > terminalSessionNameMax
            ? name.substring(0, terminalSessionNameMax)
            : name,
        windows: windows,
        attached: attached,
      ),
    );
    if (out.length >= 100) break;
  }
  return out;
}

/// Reads the tmux sessions. Exit 127 means there is no tmux; exit 1 with
/// nothing listed is «no server running», an empty list.
Future<TmuxListing> loadTmuxSessions(SshRemoteRunner run) async {
  try {
    final result = await run(sshTmuxListCommand);
    if (result.exitCode == 127) {
      return const TmuxListing(TerminalProgram.notInstalled);
    }
    final sessions = parseTmuxSessions(result.stdout);
    if (result.exitCode != 0 && sessions.isEmpty) {
      final said = result.stderr.toLowerCase();
      final empty =
          said.contains('no server') ||
          said.contains('error connecting') ||
          said.contains('no sessions');
      return TmuxListing(
        empty ? TerminalProgram.ready : TerminalProgram.failed,
      );
    }
    return TmuxListing(TerminalProgram.ready, sessions);
  } catch (_) {
    return const TmuxListing(TerminalProgram.failed);
  }
}

class HerdrNamedSession {
  const HerdrNamedSession({
    required this.name,
    required this.isDefault,
    required this.running,
  });

  final String name;
  final bool isDefault;
  final bool running;
}

/// `session list --json` output; sessions with an unusable name are skipped.
List<HerdrNamedSession> parseHerdrSessions(String output) {
  try {
    final decoded = decodeHerdrJson(output);
    if (decoded is! Map<String, Object?>) return const [];
    final list = decoded['sessions'];
    if (list is! List) return const [];
    final out = <HerdrNamedSession>[];
    for (final item in list) {
      if (item is! Map<String, Object?>) continue;
      final name = item['name'];
      if (name is! String || !terminalSessionNameOk(name)) continue;
      out.add(
        HerdrNamedSession(
          name: name,
          isDefault: item['default'] == true,
          running: item['running'] == true,
        ),
      );
      if (out.length >= 50) break;
    }
    return out;
  } on FormatException {
    return const [];
  }
}

/// What Herdr has on a server.
class HerdrListing {
  const HerdrListing(
    this.state, {
    this.herdr,
    this.sessions = const [],
    this.workspaces = const [],
  });

  final TerminalProgram state;

  /// Absolute path of `herdr`, when the probe found one.
  final String? herdr;
  final List<HerdrNamedSession> sessions;

  /// Workspaces of the default session (empty when its server is stopped).
  final List<HerdrWorkspace> workspaces;
}

Future<HerdrListing> loadHerdrSessions(SshRemoteRunner run) async {
  try {
    var probe = await run(sshHerdrProbeCommand);
    if (probe.exitCode != 0) probe = await run(sshHerdrFallbackProbeCommand);
    if (probe.exitCode != 0) {
      return const HerdrListing(TerminalProgram.notInstalled);
    }
    final herdr = herdrPathFromProbe(probe.stdout);
    var workspaces = const <HerdrWorkspace>[];
    var sessions = const <HerdrNamedSession>[];
    final results = await Future.wait([
      run(
        HerdrCommand.snapshot().render(herdr: herdr),
      ).then<Object?>((r) => r, onError: (Object e) => e),
      run(
        HerdrCommand.sessionList().render(herdr: herdr),
      ).then<Object?>((r) => r, onError: (Object e) => e),
    ]);
    final snapshot = results[0];
    if (snapshot is SshRemoteResult) {
      try {
        workspaces = parseHerdrSnapshotOutput(snapshot).workspaces;
      } on HerdrError {
        // Server not running: no workspaces to list.
      } on FormatException {
        // Unreadable: none either.
      }
    }
    final list = results[1];
    if (list is SshRemoteResult && list.exitCode == 0) {
      sessions = parseHerdrSessions(list.stdout);
    }
    return HerdrListing(
      TerminalProgram.ready,
      herdr: herdr,
      sessions: sessions,
      workspaces: workspaces,
    );
  } catch (_) {
    return const HerdrListing(TerminalProgram.failed);
  }
}

// ── Recent attaches ─────────────────────────────────────────────────────

enum TerminalRecentKind { tmux, herdrSession, herdrWorkspace }

class TerminalRecent {
  const TerminalRecent(this.kind, this.name);

  final TerminalRecentKind kind;

  /// The tmux session's or Herdr session's name, or the workspace's label.
  final String name;

  String get _encoded => jsonEncode([kind.name, name]);

  @override
  bool operator ==(Object other) =>
      other is TerminalRecent && other.kind == kind && other.name == name;

  @override
  int get hashCode => Object.hash(kind, name);
}

/// The last sessions attached from the terminal, per server, on this phone.
class TerminalRecentStore {
  TerminalRecentStore(this._prefs, this.connectionId);

  final SharedPreferences _prefs;
  final String connectionId;

  static const int max = 8;

  String get _key => 'tss.recent.$connectionId';

  List<TerminalRecent> get items {
    final out = <TerminalRecent>[];
    for (final raw in _prefs.getStringList(_key) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List && decoded.length == 2) {
          final kind = TerminalRecentKind.values.where(
            (k) => k.name == decoded[0],
          );
          final name = decoded[1];
          if (kind.isNotEmpty && name is String && name.isNotEmpty) {
            out.add(TerminalRecent(kind.first, name));
          }
        }
      } on FormatException {
        // A corrupt entry is dropped.
      }
    }
    return out;
  }

  Future<void> add(TerminalRecent recent) {
    final next = [recent, ...items.where((r) => r != recent)];
    return _prefs.setStringList(_key, [
      for (final r in next.take(max)) r._encoded,
    ]);
  }
}
