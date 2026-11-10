// Estado de Herdr leído desde la app (1.4.0, F5). Verificado contra un Herdr
// 0.9.5 real (ver REPORT-WS-F5): `herdr api snapshot` imprime en stdout un
// JSON `{"result":{"snapshot":{…}}}` y sale con 0; si falla, imprime en
// stderr `{"error":{"code":…,"message":…}}` y sale con 1 (por ejemplo,
// `server_not_running`).
// Solo se usan campos vistos en esa salida. La app lo ejecuta por un canal
// `execute` aparte, nunca en el pty del usuario.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ssh_session_kind.dart';

/// Read-only: the whole session (workspaces, tabs, panes, agents) at once.
/// Run in the login shell, like the probe: Herdr's installer puts it in
/// `~/.local/bin`, which a plain `execute` channel may not have in PATH.
/// Only when the probe gave no usable path ([herdrSnapshotCommand]).
final String sshHerdrSnapshotCommand = sshInLoginShell('herdr api snapshot');

/// The snapshot command. With [herdr], the program's absolute path that
/// the launch probe resolved once ([herdrPathFromProbe]), Herdr runs as is:
/// no login shell (profiles, banners) on every poll (reviews R3 P2-F5-3,
/// R5A P2-B4-3). Without one, [sshHerdrSnapshotCommand].
String herdrSnapshotCommand(String? herdr) =>
    herdr == null ? sshHerdrSnapshotCommand : "'$herdr' api snapshot";

/// An absolute path the app runs as is: no quote, space or anything a
/// shell would read.
final RegExp _herdrPath = RegExp(r'^/[A-Za-z0-9._/+-]+$');

/// What `command -v herdr` printed in the login shell, when its last line
/// is such a path; null for anything else (an alias, a function, nothing).
/// A login profile may print first: only the last line counts.
String? herdrPathFromProbe(String stdout) {
  final lines = stdout.trim().split('\n');
  final path = lines.last.trim();
  return _herdrPath.hasMatch(path) ? path : null;
}

/// Pane ids Herdr returns look like `w1:p2`. Anything else is refused before
/// it can reach a remote command line.
final RegExp _herdrPaneId = RegExp(r'^w[0-9]+:p[0-9]+$');

/// Whether [id] has the shape of a Herdr pane id (`w1:p2`).
bool isHerdrPaneId(String id) => _herdrPaneId.hasMatch(id);

/// `herdr agent focus <pane>` for a pane id taken from a snapshot, or null
/// when the id does not have Herdr's shape. With [herdr], run by its path
/// as [herdrSnapshotCommand] does.
String? herdrFocusAgentCommand(String paneId, {String? herdr}) {
  if (!_herdrPaneId.hasMatch(paneId)) return null;
  return herdr == null
      ? sshInLoginShell('herdr agent focus $paneId')
      : "'$herdr' agent focus $paneId";
}

/// Herdr's agent lifecycle states (API schema `AgentStatus`, protocol 22).
enum HerdrAgentStatus {
  idle,
  working,

  /// Herdr recognized an approval or question UI.
  blocked,

  /// Finished while nobody was looking at it.
  done,

  /// No agent, or one Herdr cannot classify.
  unknown;

  static HerdrAgentStatus fromWire(Object? value) => values.firstWhere(
    (s) => s.name == value,
    orElse: () => HerdrAgentStatus.unknown,
  );
}

class HerdrPane {
  const HerdrPane({
    required this.paneId,
    required this.workspaceId,
    required this.status,
    this.agent,
    this.name,
    this.cwd,
    this.focused = false,
    this.stateSeq,
    this.launchPending = false,
  });

  final String paneId;
  final String workspaceId;

  /// Herdr's `state_change_seq` for this agent: it moves each time the
  /// agent changes state. Herdr gives no timestamp, so how long an agent
  /// has been in a state is measured from when the app saw it change.
  final int? stateSeq;

  /// Agent kind as Herdr reports it (`claude`, `codex`…); null for a shell.
  final String? agent;

  /// Name given with `herdr agent rename`, if any.
  final String? name;
  final HerdrAgentStatus status;
  final String? cwd;
  final bool focused;

  /// Herdr's `launch_pending` (0.9.5): the agent was started by
  /// `agent start` and its first screen (a trust or login question, say) is
  /// still up.
  final bool launchPending;

  bool get hasAgent => agent != null;
}

class HerdrWorkspace {
  const HerdrWorkspace({
    required this.id,
    required this.label,
    required this.status,
    required this.panes,
    this.focused = false,
    this.number,
  });

  final String id;
  final String label;

  /// Herdr's `number`: the workspace's place in its sidebar.
  final int? number;

  /// The folder of the first pane that has one (a workspace has no folder of
  /// its own in the snapshot).
  String? get cwd {
    for (final pane in panes) {
      final folder = pane.cwd;
      if (folder != null && folder.startsWith('/')) return folder;
    }
    return null;
  }

  /// Herdr's own roll-up of the workspace's agents.
  final HerdrAgentStatus status;
  final List<HerdrPane> panes;
  final bool focused;
}

class HerdrSnapshot {
  const HerdrSnapshot({
    required this.workspaces,
    this.focusedPaneId,
    this.version,
  });

  final List<HerdrWorkspace> workspaces;
  final String? focusedPaneId;
  final String? version;

  Iterable<HerdrPane> get panes => workspaces.expand((w) => w.panes);

  HerdrPane? get focusedPane {
    for (final pane in panes) {
      if (pane.paneId == focusedPaneId) return pane;
    }
    return null;
  }

  /// Agents waiting on an approval or a question.
  int get needsYou =>
      panes.where((p) => p.status == HerdrAgentStatus.blocked).length;

  /// Parses the `snapshot` object of `herdr api snapshot`. Agent names come
  /// from `agents` (panes do not carry them).
  static HerdrSnapshot fromJson(Map<String, Object?> snapshot) {
    final names = <String, String>{};
    final seqs = <String, int>{};
    final pending = <String>{};
    for (final agent in _maps(snapshot['agents'])) {
      final paneId = agent['pane_id'];
      final name = agent['name'];
      final seq = agent['state_change_seq'];
      if (paneId is String && name is String) names[paneId] = name;
      if (paneId is String && seq is int) seqs[paneId] = seq;
      if (paneId is String && agent['launch_pending'] == true) {
        pending.add(paneId);
      }
    }
    final panesByWorkspace = <String, List<HerdrPane>>{};
    for (final pane in _maps(snapshot['panes'])) {
      final paneId = pane['pane_id'];
      final workspaceId = pane['workspace_id'];
      if (paneId is! String || workspaceId is! String) continue;
      final agent = pane['agent'];
      final cwd = pane['cwd'];
      panesByWorkspace
          .putIfAbsent(workspaceId, () => [])
          .add(
            HerdrPane(
              paneId: paneId,
              workspaceId: workspaceId,
              agent: agent is String ? agent : null,
              name: names[paneId],
              status: HerdrAgentStatus.fromWire(pane['agent_status']),
              cwd: cwd is String ? cwd : null,
              focused: pane['focused'] == true,
              stateSeq: seqs[paneId],
              launchPending: pending.contains(paneId),
            ),
          );
    }
    final workspaces = <HerdrWorkspace>[];
    for (final workspace in _maps(snapshot['workspaces'])) {
      final id = workspace['workspace_id'];
      if (id is! String) continue;
      final label = workspace['label'];
      workspaces.add(
        HerdrWorkspace(
          id: id,
          label: label is String ? label : id,
          status: HerdrAgentStatus.fromWire(workspace['agent_status']),
          panes: panesByWorkspace[id] ?? const [],
          focused: workspace['focused'] == true,
          number: workspace['number'] is int
              ? workspace['number'] as int
              : null,
        ),
      );
    }
    final focused = snapshot['focused_pane_id'];
    final version = snapshot['version'];
    return HerdrSnapshot(
      workspaces: workspaces,
      focusedPaneId: focused is String ? focused : null,
      version: version is String ? version : null,
    );
  }

  static Iterable<Map<String, Object?>> _maps(Object? list) =>
      list is List ? list.whereType<Map<String, Object?>>() : const [];
}

/// Herdr answered with an error object (`code` as Herdr names it).
class HerdrError implements Exception {
  const HerdrError(this.code, [this.message]);

  static const String serverNotRunning = 'server_not_running';

  final String code;

  /// Herdr's own sentence (`error.message`), as it came: sanitise before
  /// showing it.
  final String? message;

  @override
  String toString() => 'HerdrError($code)';
}

/// Output of one remote command run on its own `execute` channel.
class SshRemoteResult {
  const SshRemoteResult({
    required this.stdout,
    this.stderr = '',
    this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;
}

typedef SshRemoteRunner = Future<SshRemoteResult> Function(String command);

/// Reads `herdr api snapshot` output: the snapshot on success, a
/// [HerdrError] for Herdr's error object, [FormatException] otherwise.
/// Herdr's JSON in [text], tolerating anything a login profile printed
/// before it (motd, banners: review P2-F5-3). Tries the whole text, then
/// from each line that starts with `{`, last first.
Object? _herdrJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    var i = text.lastIndexOf('\n{');
    while (i >= 0) {
      try {
        return jsonDecode(text.substring(i + 1));
      } on FormatException {
        if (i == 0) break;
        i = text.lastIndexOf('\n{', i - 1);
      }
    }
    rethrow;
  }
}

/// Herdr's JSON in [text], tolerating what a login profile printed first.
Object? decodeHerdrJson(String text) => _herdrJson(text);

HerdrSnapshot parseHerdrSnapshotOutput(SshRemoteResult result) {
  if (result.exitCode == 0) {
    final decoded = _herdrJson(result.stdout);
    if (decoded is Map<String, Object?>) {
      final body = decoded['result'];
      if (body is Map<String, Object?>) {
        final snapshot = body['snapshot'];
        if (snapshot is Map<String, Object?>) {
          return HerdrSnapshot.fromJson(snapshot);
        }
      }
    }
    throw const FormatException('herdr api snapshot: unexpected output');
  }
  try {
    final decoded = _herdrJson(result.stderr);
    if (decoded is Map<String, Object?>) {
      final error = decoded['error'];
      if (error is Map<String, Object?> && error['code'] is String) {
        final message = error['message'];
        throw HerdrError(
          error['code']! as String,
          message is String ? message : null,
        );
      }
    }
  } on FormatException {
    // Not Herdr's JSON (e.g. "command not found"): report it as such below.
  }
  throw FormatException('herdr api snapshot exited with ${result.exitCode}');
}

/// What the UI shows about Herdr.
@immutable
class HerdrView {
  const HerdrView({
    this.snapshot,
    this.notRunning = false,
    this.failed = false,
  });

  /// Last snapshot read; null before the first one or once the server is
  /// known to be stopped.
  final HerdrSnapshot? snapshot;
  final bool notRunning;

  /// The last read failed for another reason; [snapshot] may be stale.
  final bool failed;
}

/// Polls `herdr api snapshot` while the terminal is on screen. Never runs
/// two reads at once, waits [interval] between reads ([errorInterval] after
/// a failure) and does nothing once stopped. The owner starts it when the
/// terminal is visible and stops it when it is not.
class HerdrMonitor {
  HerdrMonitor({
    required this.run,
    this.herdr,
    this.interval = defaultInterval,
    this.errorInterval = defaultErrorInterval,
  });

  static const Duration defaultInterval = Duration(seconds: 5);
  static const Duration defaultErrorInterval = Duration(seconds: 15);

  final SshRemoteRunner run;

  /// Herdr's absolute path on the server, when the probe resolved one: the
  /// reads run it directly ([herdrSnapshotCommand]).
  final String? herdr;
  final Duration interval;
  final Duration errorInterval;

  final ValueNotifier<HerdrView> view = ValueNotifier<HerdrView>(
    const HerdrView(),
  );

  Timer? _timer;
  bool _reading = false;
  // Bumped whenever polling stops so a read that lands afterwards is
  // dropped.
  int _generation = 0;

  /// Screens showing this session's Herdr state right now. The monitor is
  /// the session's, shared by every screen on it: it polls while at least
  /// one of them is on screen (review P1-F5-2).
  int _holders = 0;

  bool get isRunning => _holders > 0;

  /// A screen starts showing the state: poll while anyone does.
  void acquire() {
    _holders++;
    if (_holders == 1) unawaited(_read(_generation));
  }

  /// That screen stopped showing it (left, covered, off screen).
  void release() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) _halt();
  }

  /// Same as [acquire], for a single owner.
  void start() => acquire();

  /// The session ended: stop for every holder.
  void stop() {
    _holders = 0;
    _halt();
  }

  void _halt() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  /// Reads now (e.g. after focusing an agent) without waiting for the timer.
  Future<void> refresh() async {
    if (!isRunning || _reading) return;
    _timer?.cancel();
    _timer = null;
    await _read(_generation);
  }

  /// Focuses the agent in [paneId] in the running Herdr client. Returns
  /// false for an id that does not look like Herdr's or when Herdr refuses.
  Future<bool> focusAgent(String paneId) async {
    final command = herdrFocusAgentCommand(paneId, herdr: herdr);
    if (command == null) return false;
    try {
      final result = await run(command);
      if (result.exitCode != 0) return false;
    } catch (e) {
      debugPrint('[herdr] focus failed (${e.runtimeType})');
      return false;
    }
    unawaited(refresh());
    return true;
  }

  Future<void> _read(int generation) async {
    if (_reading) return;
    _reading = true;
    // The timer that called this (if any) has fired: the next one is set
    // in `finally`.
    _timer = null;
    var next = interval;
    try {
      final snapshot = parseHerdrSnapshotOutput(
        await run(herdrSnapshotCommand(herdr)),
      );
      if (generation != _generation) return;
      view.value = HerdrView(snapshot: snapshot);
    } on HerdrError catch (e) {
      if (generation != _generation) return;
      next = errorInterval;
      view.value = e.code == HerdrError.serverNotRunning
          ? const HerdrView(notRunning: true)
          : HerdrView(snapshot: view.value.snapshot, failed: true);
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('[herdr] snapshot failed (${e.runtimeType})');
      next = errorInterval;
      view.value = HerdrView(snapshot: view.value.snapshot, failed: true);
    } finally {
      _reading = false;
      if (isRunning && _timer == null) {
        // Review P1-F5-1: a stop() and start() while this read was in
        // flight bumped the generation, and start() found the read busy, so
        // the new run has not read yet: read now, under the current run.
        final current = _generation;
        _timer = Timer(
          generation == current ? next : Duration.zero,
          () => _read(current),
        );
      }
    }
  }

  void dispose() {
    stop();
    view.dispose();
  }
}
