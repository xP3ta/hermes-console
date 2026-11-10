// Which code agents (harnesses) are installed on a server, so «new agent»
// offers only those that can start. A read-only look through two constant
// commands (nothing of the user's is interpolated): the login shell's own
// `command -v` for each name, and a plain `sh` walk through the usual install
// folders (a login, non-interactive shell skips `~/.bashrc`, where some
// installers add their folder to PATH). Parsed by the file name of each
// printed absolute path, never by exit status: `command -v a b c` exits 0
// even when only some are found (checked against a real server).
//
// Versions are not asked: `--version` would run the harness itself.
import 'dart:async';

import 'herdr_status.dart';
import 'ssh_session_kind.dart';

/// The `--kind` values the app offers for a new agent, in this order: the
/// kinds Herdr's CLI names (checked against Herdr 0.9.5, whose `agent start`
/// accepts `hermes` too). Also the names looked for on the server.
const List<String> herdrHarnessNames = [
  'claude',
  'codex',
  'hermes',
  'opencode',
  'gemini',
  'pi',
  'copilot',
];

final String _names = herdrHarnessNames.join(' ');

/// Login-shell `command -v` of every harness. Prints one path per harness it
/// finds (aliases and functions print no absolute path and are ignored).
final String sshHarnessLoginCommand = sshInLoginShell('command -v $_names');

/// The usual install folders, looked at by plain `sh` (so it works whatever
/// the user's shell is). Prints the first executable found for each name.
final String sshHarnessFolderCommand =
    "/bin/sh -c '"
    'for c in $_names; do '
    'for d in "\$HOME/.local/bin" "\$HOME/.npm-global/bin" "\$HOME/.bun/bin" '
    '"\$HOME/.cargo/bin" /usr/local/bin /opt/homebrew/bin; do '
    '[ -x "\$d/\$c" ] && { echo "\$d/\$c"; break; }; done; done; exit 0'
    "'";

/// What a look found.
class HerdrHarnessReport {
  const HerdrHarnessReport({
    required this.installed,
    required this.at,
    this.failed = false,
  });

  /// Harness name -> absolute path of its executable.
  final Map<String, String> installed;
  final DateTime at;

  /// The server could not be asked: nothing is known (the UI then offers
  /// every harness, with a quiet note).
  final bool failed;

  /// Whether the app should let [kind] be chosen.
  bool isInstalled(String kind) => failed || installed.containsKey(kind);

  /// Harnesses known to be missing (none when the look failed).
  List<String> get missing => failed
      ? const []
      : [
          for (final name in herdrHarnessNames)
            if (!installed.containsKey(name)) name,
        ];
}

final RegExp _absolute = RegExp(r'^/[A-Za-z0-9._/+-]+$');

/// The harnesses named by the printed paths in [output]: the last path
/// segment must be one of [herdrHarnessNames]. Other lines (a login banner,
/// an alias) are ignored.
Map<String, String> parseHerdrHarnessOutput(String output) {
  final found = <String, String>{};
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line.length > 400 || !_absolute.hasMatch(line)) continue;
    final name = line.substring(line.lastIndexOf('/') + 1);
    if (herdrHarnessNames.contains(name)) found.putIfAbsent(name, () => line);
  }
  return found;
}

/// Asks a server which harnesses it has, and remembers the answer for [ttl]
/// per server.
class HerdrHarnessDetector {
  HerdrHarnessDetector({
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The app's own cache.
  static final HerdrHarnessDetector shared = HerdrHarnessDetector();

  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, HerdrHarnessReport> _cache = {};
  final Map<String, Future<HerdrHarnessReport>> _inFlight = {};

  /// The cached report for [serverId], if still fresh.
  HerdrHarnessReport? fresh(String serverId) {
    final cached = _cache[serverId];
    if (cached == null || cached.failed) return null;
    return _now().difference(cached.at) < ttl ? cached : null;
  }

  /// Looks (or answers from the cache unless [force]). Never throws: a
  /// server that does not answer gives a report with `failed` set (which is
  /// not cached, so the next look asks again).
  Future<HerdrHarnessReport> detect(
    String serverId,
    SshRemoteRunner run, {
    bool force = false,
  }) {
    if (!force) {
      final cached = fresh(serverId);
      if (cached != null) return Future.value(cached);
    }
    final running = _inFlight[serverId];
    if (running != null && !force) return running;
    final future = _look(serverId, run).whenComplete(() {
      // A block, not an arrow: `remove` returns this very future, and a
      // callback that returns a future is waited for.
      _inFlight.remove(serverId);
    });
    _inFlight[serverId] = future;
    return future;
  }

  Future<HerdrHarnessReport> _look(String serverId, SshRemoteRunner run) async {
    Future<String?> output(String command) async {
      try {
        final result = await run(command);
        return result.stdout;
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([
      output(sshHarnessLoginCommand),
      output(sshHarnessFolderCommand),
    ]);
    final report = results.every((r) => r == null)
        ? HerdrHarnessReport(installed: const {}, at: _now(), failed: true)
        : HerdrHarnessReport(
            installed: {
              for (final out in results.reversed)
                if (out != null) ...parseHerdrHarnessOutput(out),
            },
            at: _now(),
          );
    if (!report.failed) _cache[serverId] = report;
    return report;
  }

  void forget(String serverId) => _cache.remove(serverId);
}
