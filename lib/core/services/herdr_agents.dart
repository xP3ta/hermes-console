// Agentes de Herdr desde la app (1.4.0): lista por espacios de trabajo, salida,
// prompt, teclas y alta de un agente nuevo, todo por la conexión SSH que la
// app ya tiene (canales `execute` aparte, nunca el pty del usuario; sin
// puertos nuevos ni nada instalado en el servidor).
//
// Verificado contra un Herdr 0.9.5 real, en una sesión con nombre y servidor
// propios (ver la guía de prueba): `api snapshot`, `workspace create`,
// `workspace focus`, `agent start` (resultado `agent_started`; errores
// `agent_not_ready`, `agent_pane_busy`, `agent_name_taken`,
// `invalid_agent_name`, `invalid_agent_timeout`, `timeout`; `--kind hermes`
// vale), `agent read`, `agent send-keys` (las teclas `enter`, `esc`, `up`,
// `down`, `y`, `n`; `invalid_key` si no existe), `agent attach`,
// `session attach`, `session list --json`, `pane read` y los errores
// `agent_not_found` y `workspace_not_found`. Solo contra la documentación y
// el doble de pruebas: `agent prompt` (que pulsa Intro por sí solo y
// `agent_blocked`).
//
// Seguridad: solo existen las órdenes de [HerdrCommand] (lista blanca de
// subcomandos); cada palabra sale entrecomillada con [herdrShellQuote]; las
// escrituras exigen la ruta absoluta que resolvió la sonda; el texto y las
// carpetas se validan y acotan antes de salir.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'herdr_attention.dart';
import 'herdr_harness.dart';
import 'herdr_session_files.dart';
import 'herdr_status.dart';
import 'herdr_transcript.dart';
import 'ssh_session_kind.dart';

/// [value] as one POSIX shell word: single quotes, and every single quote
/// inside closed, escaped and reopened (`'` becomes `'\''`). Nothing else is
/// special inside single quotes, so `$()`, backticks, `;` or a newline stay
/// plain text.
String herdrShellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Why the app refused to build a command, before anything left the phone.
enum HerdrInputProblem {
  empty,
  tooLong,
  badChars,
  badFolder,
  badName,
  badKind,
  badPane,
  badKey,
  noPath,
}

class HerdrInputException implements Exception {
  const HerdrInputException(this.problem);

  final HerdrInputProblem problem;

  @override
  String toString() => 'HerdrInputException(${problem.name})';
}

/// Most a prompt may weigh (UTF-8) and how many keys one send may carry.
const int herdrPromptMaxBytes = 4096;
const int herdrKeysMax = 8;

/// Most screen rows asked of `agent read`, and what is kept of its output.
const int herdrReadMaxLines = 120;
const int herdrScreenMaxChars = 16000;

/// Keys the detail view can send. The wire names are Herdr's key-combo
/// strings; all of them were accepted by a real Herdr 0.9.5 (`invalid_key`
/// for anything else).
enum HerdrKey {
  enter('enter', 'Enter'),
  esc('esc', 'Esc'),
  ctrlC('ctrl+c', 'Ctrl+C'),
  up('up', '↑'),
  down('down', '↓'),
  yes('y', 'y'),
  no('n', 'n'),

  /// The numbers 1..9: answer option N of a numbered question or approval.
  /// Herdr takes a single character as a key like `y` and `n`; the numbers
  /// themselves were not tried on a real server (see the manual).
  digit1('1', '1'),
  digit2('2', '2'),
  digit3('3', '3'),
  digit4('4', '4'),
  digit5('5', '5'),
  digit6('6', '6'),
  digit7('7', '7'),
  digit8('8', '8'),
  digit9('9', '9');

  const HerdrKey(this.wire, this.cap);

  /// The keys of the quick row under the instruction field.
  static const List<HerdrKey> quick = [enter, esc, ctrlC, up, down, yes, no];

  /// The key for option [number] (1..9).
  static HerdrKey digit(int number) {
    if (number < 1 || number > 9) {
      throw const HerdrInputException(HerdrInputProblem.badKey);
    }
    return values.firstWhere((k) => k.wire == '$number');
  }

  final String wire;

  /// Printed on the key's button: key names are not translated.
  final String cap;
}

/// Agent kinds the app offers for a new agent (`--kind` values; Herdr 0.9.5
/// accepts `hermes` as well). Which of them a server has is asked by
/// [HerdrHarnessDetector].
const List<String> herdrAgentKinds = herdrHarnessNames;

final RegExp _agentName = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');
final RegExp _absolutePath = RegExp(r'^/[A-Za-z0-9._/+-]+$');
final RegExp _plainWord = RegExp(r'^[A-Za-z0-9:_.+-]+$');

bool _hasControl(String text, {bool allowNewline = false}) {
  for (final rune in text.runes) {
    if (allowNewline && (rune == 0x0A || rune == 0x09)) continue;
    if (rune < 0x20 || rune == 0x7F || (rune >= 0x80 && rune <= 0x9F)) {
      return true;
    }
  }
  return false;
}

/// The prompt as it will be sent: line ends unified, trimmed; refused when
/// empty, over [herdrPromptMaxBytes] or with control characters (a newline
/// and a tab are fine). A leading `-` gets a space so Herdr's parser cannot
/// read the text as one of its flags.
String herdrPromptText(String raw) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.isEmpty) throw const HerdrInputException(HerdrInputProblem.empty);
  if (_hasControl(text, allowNewline: true)) {
    throw const HerdrInputException(HerdrInputProblem.badChars);
  }
  if (utf8.encode(text).length > herdrPromptMaxBytes) {
    throw const HerdrInputException(HerdrInputProblem.tooLong);
  }
  return text.startsWith('-') ? ' $text' : text;
}

/// An absolute server folder, as typed: no trailing slash, no control
/// characters, at most 512 characters. Quoting makes spaces and the like
/// safe, so those are allowed.
String herdrFolder(String raw) {
  var folder = raw.trim();
  if (folder.length > 1 && folder.endsWith('/')) {
    folder = folder.substring(0, folder.length - 1);
  }
  if (!folder.startsWith('/') || folder.length > 512 || _hasControl(folder)) {
    throw const HerdrInputException(HerdrInputProblem.badFolder);
  }
  return folder;
}

/// Label for the workspace Herdr creates: the folder's name, reduced to
/// plain characters and never starting with a dash.
String herdrLabelFor(String folder) {
  final parts = folder.split('/').where((p) => p.isNotEmpty);
  final base = parts.isEmpty ? '' : parts.last;
  var label = base.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '-');
  label = label.replaceFirst(RegExp(r'^[-._ ]+'), '');
  if (label.length > 40) label = label.substring(0, 40);
  return label.isEmpty ? 'agent' : label;
}

/// One of Herdr's CLI invocations the app may run. There is no way to build
/// any other: the subcommand is one of [allowedSubcommands] and every other
/// word is validated or fixed. Rendering quotes every word.
class HerdrCommand {
  const HerdrCommand._(this._words, {required this.isWrite});

  /// The only `herdr` subcommands the app runs (the first two words).
  static const Set<String> allowedSubcommands = {
    'api snapshot',
    'agent read',
    'agent prompt',
    'agent send-keys',
    'agent start',
    'workspace create',
    'pane read',
    'session list',
  };

  final List<String> _words;

  /// Changes something on the server (types into an agent, creates panes).
  final bool isWrite;

  String get subcommand => '${_words[0]} ${_words[1]}';

  /// The words after `herdr`, for tests and logs that must not show text.
  List<String> get words => List.unmodifiable(_words);

  /// Whole session as JSON (verified on a real server).
  factory HerdrCommand.snapshot() =>
      const HerdrCommand._(['api', 'snapshot'], isWrite: false);

  /// The agent's screen as plain text. By default what its pane shows now
  /// (`--source visible`): measured on a real Herdr 0.9.5 that takes about
  /// 15 ms, where `--source recent` with more rows than the pane has costs
  /// about 390 ms for the same text. With [lines], that many rows of recent
  /// history (up to [herdrReadMaxLines]), for the rare look further back.
  factory HerdrCommand.read(String paneId, {int? lines}) {
    if (lines == null) {
      return HerdrCommand._([
        'agent',
        'read',
        _pane(paneId),
        '--source',
        'visible',
      ], isWrite: false);
    }
    final count = lines.clamp(1, herdrReadMaxLines);
    return HerdrCommand._([
      'agent',
      'read',
      _pane(paneId),
      '--source',
      'recent',
      '--lines',
      '$count',
    ], isWrite: false);
  }

  /// Types a prompt into an agent and submits it (no `--wait`: the app does
  /// not hold the channel open). Herdr sends nothing to a blocked agent.
  factory HerdrCommand.prompt(String paneId, String text) => HerdrCommand._([
    'agent',
    'prompt',
    _pane(paneId),
    herdrPromptText(text),
  ], isWrite: true);

  factory HerdrCommand.sendKeys(String paneId, List<HerdrKey> keys) {
    if (keys.isEmpty || keys.length > herdrKeysMax) {
      throw const HerdrInputException(HerdrInputProblem.empty);
    }
    return HerdrCommand._([
      'agent',
      'send-keys',
      _pane(paneId),
      for (final key in keys) key.wire,
    ], isWrite: true);
  }

  /// A new workspace in [folder], without taking focus from whoever is
  /// attached.
  factory HerdrCommand.workspaceCreate(String folder, {String? label}) {
    final cwd = herdrFolder(folder);
    return HerdrCommand._([
      'workspace',
      'create',
      '--cwd',
      cwd,
      '--label',
      herdrWorkspaceLabel(label) ?? herdrLabelFor(cwd),
      '--no-focus',
    ], isWrite: true);
  }

  /// The last lines of a pane as it shows them: what a shell said when an
  /// agent did not start (`agent read` has nothing to read then). Read-only.
  factory HerdrCommand.paneRead(String paneId, {int lines = 20}) =>
      HerdrCommand._([
        'pane',
        'read',
        _pane(paneId),
        '--source',
        'recent',
        '--lines',
        '${lines.clamp(1, 40)}',
      ], isWrite: false);

  /// The named sessions (separate Herdr servers) of this account, as JSON.
  factory HerdrCommand.sessionList() =>
      const HerdrCommand._(['session', 'list', '--json'], isWrite: false);

  /// Starts a [kind] agent named [name] in an available shell pane.
  factory HerdrCommand.agentStart(String name, String kind, String paneId) {
    if (!_agentName.hasMatch(name)) {
      throw const HerdrInputException(HerdrInputProblem.badName);
    }
    if (!herdrAgentKinds.contains(kind)) {
      throw const HerdrInputException(HerdrInputProblem.badKind);
    }
    return HerdrCommand._([
      'agent',
      'start',
      name,
      '--kind',
      kind,
      '--pane',
      _pane(paneId),
      '--timeout',
      '8000',
    ], isWrite: true);
  }

  static String _pane(String id) {
    if (!isHerdrPaneId(id)) {
      throw const HerdrInputException(HerdrInputProblem.badPane);
    }
    return id;
  }

  /// The command line for the server. With [herdr], the absolute path the
  /// probe resolved: `'/path' 'agent' 'read' …`, every word quoted. Without
  /// it only the read commands run, by name in the login shell (their words
  /// are plain by construction); a write without a path is refused.
  String render({String? herdr}) {
    if (!allowedSubcommands.contains(subcommand)) {
      throw StateError('Herdr subcommand not allowed: $subcommand');
    }
    if (herdr != null) {
      if (!_absolutePath.hasMatch(herdr)) {
        throw const HerdrInputException(HerdrInputProblem.noPath);
      }
      return [herdr, ..._words].map(herdrShellQuote).join(' ');
    }
    if (isWrite || !_words.every(_plainWord.hasMatch)) {
      throw const HerdrInputException(HerdrInputProblem.noPath);
    }
    return sshInLoginShell(['herdr', ..._words].join(' '));
  }
}

/// A Herdr error code the UI treats on its own.
class HerdrErrorCodes {
  const HerdrErrorCodes._();

  /// `agent prompt` on an agent at an approval (documented, not provoked
  /// on a real server).
  static const String agentBlocked = 'agent_blocked';

  /// Checked on a real 0.9.5: an unknown agent or pane, and an unknown
  /// workspace. (`not_found` is kept for older servers.)
  static const String agentNotFound = 'agent_not_found';
  static const String workspaceNotFound = 'workspace_not_found';
  static const String notFound = 'not_found';

  /// `agent start`: the agent stopped at a question on its first screen (a
  /// trust prompt): it IS running, and it is `blocked`.
  static const String agentNotReady = 'agent_not_ready';

  /// `agent start` on a pane that is not at a shell prompt (an agent or a
  /// program already runs there).
  static const String paneBusy = 'agent_pane_busy';
  static const String nameTaken = 'agent_name_taken';

  /// `agent start` did not see the agent within its `--timeout`.
  static const String timeout = 'timeout';

  static bool isNotFound(String code) =>
      code == agentNotFound || code == workspaceNotFound || code == notFound;
}

/// Herdr's error object in [result] (stderr, or stdout), or null when what
/// came back is not one.
HerdrError? herdrErrorOf(SshRemoteResult result) {
  for (final text in [result.stderr, result.stdout]) {
    if (text.trim().isEmpty) continue;
    try {
      final decoded = decodeHerdrJson(text);
      if (decoded is Map<String, Object?>) {
        final error = decoded['error'];
        if (error is Map<String, Object?> && error['code'] is String) {
          final message = error['message'];
          return HerdrError(
            error['code']! as String,
            message is String ? message : null,
          );
        }
      }
    } on FormatException {
      // Not JSON: keep looking.
    }
  }
  return null;
}

/// Throws what a failed command says: [HerdrError] for Herdr's own error,
/// [FormatException] for anything else (no Herdr, bad flags).
void herdrExpectOk(SshRemoteResult result) {
  if (result.exitCode == 0) return;
  final error = herdrErrorOf(result);
  if (error != null) throw error;
  throw FormatException('herdr exited with ${result.exitCode}');
}

final RegExp _escapeCsi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final RegExp _escapeOsc = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');
final RegExp _escapeOther = RegExp(r'\x1B[@-Z\\-_]');

/// The screen text for display: escape sequences and control characters
/// gone, trailing blanks trimmed, only the last [herdrScreenMaxChars].
String herdrCleanScreen(String raw) {
  var text = raw
      .replaceAll(_escapeOsc, '')
      .replaceAll(_escapeCsi, '')
      .replaceAll(_escapeOther, '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
  final lines = text.split('\n').map((l) => l.trimRight()).toList();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  var cleaned = lines.join('\n');
  if (cleaned.length > herdrScreenMaxChars) {
    cleaned = cleaned.substring(cleaned.length - herdrScreenMaxChars);
  }
  return cleaned;
}

/// `agent read` output: the screen as text.
String parseHerdrReadOutput(SshRemoteResult result) {
  herdrExpectOk(result);
  return herdrCleanScreen(result.stdout);
}

/// What `workspace create` made.
class HerdrCreated {
  const HerdrCreated({required this.paneId, this.workspaceId});

  final String paneId;
  final String? workspaceId;
}

/// `workspace create` output: `result.root_pane.pane_id` (Herdr's CLI
/// reference), plus `result.workspace.workspace_id` when there.
HerdrCreated parseHerdrCreated(SshRemoteResult result) {
  herdrExpectOk(result);
  final decoded = decodeHerdrJson(result.stdout);
  if (decoded is Map<String, Object?>) {
    final body = decoded['result'];
    if (body is Map<String, Object?>) {
      final root = body['root_pane'];
      final workspace = body['workspace'];
      final paneId = root is Map<String, Object?> ? root['pane_id'] : null;
      final workspaceId = workspace is Map<String, Object?>
          ? workspace['workspace_id']
          : null;
      if (paneId is String && isHerdrPaneId(paneId)) {
        return HerdrCreated(
          paneId: paneId,
          workspaceId: workspaceId is String ? workspaceId : null,
        );
      }
    }
  }
  throw const FormatException('herdr workspace create: unexpected output');
}

/// What the list can be narrowed to. `idle` also holds «finished, not yet
/// seen» (Herdr's `done`).
enum HerdrStatusFilter {
  all,
  blocked,
  working,
  idle;

  bool matches(HerdrAgentStatus status) => switch (this) {
    HerdrStatusFilter.all => true,
    HerdrStatusFilter.blocked => status == HerdrAgentStatus.blocked,
    HerdrStatusFilter.working => status == HerdrAgentStatus.working,
    HerdrStatusFilter.idle =>
      status == HerdrAgentStatus.idle || status == HerdrAgentStatus.done,
  };
}

/// One agent of the list: its pane and the workspace it lives in.
class HerdrAgentRow {
  const HerdrAgentRow({
    required this.pane,
    required this.workspaceLabel,
    this.statusOverride,
  });

  final HerdrPane pane;
  final String workspaceLabel;

  /// What the app knows better than the last snapshot (a prompt it just
  /// sent): shown until the next snapshot catches up.
  final HerdrAgentStatus? statusOverride;

  String get paneId => pane.paneId;
  HerdrAgentStatus get status => statusOverride ?? pane.status;

  /// What to call it: the name given to it, else its kind.
  String get title => pane.name ?? pane.agent ?? paneId;
}

int _statusRank(HerdrAgentStatus status) => switch (status) {
  HerdrAgentStatus.blocked => 0,
  HerdrAgentStatus.working => 1,
  HerdrAgentStatus.done => 2,
  HerdrAgentStatus.idle => 3,
  HerdrAgentStatus.unknown => 4,
};

/// The panes that hold an agent, those waiting on you first, then the
/// working ones, then the rest, each group in Herdr's own order.
List<HerdrAgentRow> herdrAgentRows(
  HerdrSnapshot snapshot, {
  HerdrStatusFilter filter = HerdrStatusFilter.all,
  Map<String, HerdrAgentStatus> overrides = const {},
}) {
  final rows = <HerdrAgentRow>[];
  for (final workspace in snapshot.workspaces) {
    for (final pane in workspace.panes) {
      if (!pane.hasAgent) continue;
      final row = HerdrAgentRow(
        pane: pane,
        workspaceLabel: workspace.label,
        statusOverride: overrides[pane.paneId],
      );
      if (!filter.matches(row.status)) continue;
      rows.add(row);
    }
  }
  final order = {for (var i = 0; i < rows.length; i++) rows[i].paneId: i};
  rows.sort((a, b) {
    final byStatus = _statusRank(a.status).compareTo(_statusRank(b.status));
    return byStatus != 0
        ? byStatus
        : order[a.paneId]!.compareTo(order[b.paneId]!);
  });
  return rows;
}

/// One Herdr workspace with the agents inside it that the list shows.
class HerdrWorkspaceGroup {
  const HerdrWorkspaceGroup({required this.workspace, required this.rows});

  final HerdrWorkspace workspace;

  /// Its agents, those waiting on you first.
  final List<HerdrAgentRow> rows;

  bool get hasAgents => rows.isNotEmpty;

  /// The most pressing state among its agents; `unknown` for a workspace
  /// with only shells.
  HerdrAgentStatus get status {
    var best = HerdrAgentStatus.unknown;
    for (final row in rows) {
      if (_statusRank(row.status) < _statusRank(best) ||
          best == HerdrAgentStatus.unknown) {
        best = row.status;
      }
    }
    return best;
  }

  int get _rank => rows.isEmpty ? 5 : _statusRank(status);
}

bool _hasText(String? haystack, String needle) =>
    haystack != null && haystack.toLowerCase().contains(needle);

/// The workspaces of [snapshot] with their agents, for the list: those with
/// an agent that waits on you first, then working, finished, idle, and the
/// workspaces with only shells last (only under «all» and without a filter
/// that would exclude them). [query] narrows by agent, kind, folder or
/// workspace name.
List<HerdrWorkspaceGroup> herdrWorkspaceGroups(
  HerdrSnapshot snapshot, {
  HerdrStatusFilter filter = HerdrStatusFilter.all,
  String query = '',
  Map<String, HerdrAgentStatus> overrides = const {},
}) {
  final needle = query.trim().toLowerCase();
  final groups = <HerdrWorkspaceGroup>[];
  for (final workspace in snapshot.workspaces) {
    final workspaceHit =
        needle.isEmpty ||
        _hasText(workspace.label, needle) ||
        _hasText(workspace.cwd, needle);
    final rows = <HerdrAgentRow>[];
    for (final pane in workspace.panes) {
      if (!pane.hasAgent) continue;
      final row = HerdrAgentRow(
        pane: pane,
        workspaceLabel: workspace.label,
        statusOverride: overrides[pane.paneId],
      );
      if (!filter.matches(row.status)) continue;
      final rowHit =
          workspaceHit ||
          _hasText(row.title, needle) ||
          _hasText(pane.agent, needle) ||
          _hasText(pane.cwd, needle);
      if (rowHit) rows.add(row);
    }
    if (rows.isEmpty) {
      final hasAgents = workspace.panes.any((p) => p.hasAgent);
      // Shell-only workspaces: under «all» only, and when the query fits.
      if (hasAgents || filter != HerdrStatusFilter.all || !workspaceHit) {
        continue;
      }
    }
    final order = {for (var i = 0; i < rows.length; i++) rows[i].paneId: i};
    rows.sort((a, b) {
      final byStatus = _statusRank(a.status).compareTo(_statusRank(b.status));
      return byStatus != 0
          ? byStatus
          : order[a.paneId]!.compareTo(order[b.paneId]!);
    });
    groups.add(HerdrWorkspaceGroup(workspace: workspace, rows: rows));
  }
  final order = {
    for (var i = 0; i < groups.length; i++) groups[i].workspace.id: i,
  };
  groups.sort((a, b) {
    final byRank = a._rank.compareTo(b._rank);
    return byRank != 0
        ? byRank
        : order[a.workspace.id]!.compareTo(order[b.workspace.id]!);
  });
  return groups;
}

/// How long each agent has been in its state. Herdr's snapshot has no
/// timestamps, so this counts from the moment the app saw the state (or its
/// `state_change_seq`) change: for an agent already in a state when the
/// screen opened it is a lower bound.
class HerdrStateClock {
  final Map<String, _Seen> _seen = {};

  /// Takes a snapshot's agents at [now]. Returns the panes that moved into
  /// `blocked` since the previous look (not the ones first seen blocked).
  Set<String> observe(Iterable<HerdrPane> panes, DateTime now) {
    final newlyBlocked = <String>{};
    final live = <String>{};
    for (final pane in panes) {
      if (!pane.hasAgent) continue;
      live.add(pane.paneId);
      final before = _seen[pane.paneId];
      final changed =
          before == null ||
          before.status != pane.status ||
          (before.seq != null &&
              pane.stateSeq != null &&
              before.seq != pane.stateSeq);
      if (!changed) continue;
      _seen[pane.paneId] = _Seen(pane.status, pane.stateSeq, now);
      if (before != null &&
          before.status != HerdrAgentStatus.blocked &&
          pane.status == HerdrAgentStatus.blocked) {
        newlyBlocked.add(pane.paneId);
      }
    }
    _seen.removeWhere((id, _) => !live.contains(id));
    return newlyBlocked;
  }

  /// Time in the current state as the app saw it; null for an unknown pane.
  Duration? inState(String paneId, DateTime now) {
    final seen = _seen[paneId];
    if (seen == null) return null;
    final elapsed = now.difference(seen.since);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }
}

class _Seen {
  const _Seen(this.status, this.seq, this.since);

  final HerdrAgentStatus status;
  final int? seq;
  final DateTime since;
}

/// Wait before the next list read: 1 s while an agent is starting, 3 s with
/// an agent working or waiting on you, 10 s when nothing moves, and 15/30/60
/// s after consecutive failures.
Duration herdrListDelay({
  required bool busy,
  required int failures,
  bool starting = false,
}) {
  if (failures > 0) {
    const steps = [15, 30, 60];
    return Duration(seconds: steps[failures.clamp(1, steps.length) - 1]);
  }
  if (starting) return const Duration(seconds: 1);
  return Duration(seconds: busy ? 3 : 10);
}

/// Wait before the next read of one agent's screen: 1 s while it works (and
/// the screen keeps changing), 2 s otherwise, slower the longer the screen
/// stays the same, 0.7 s right after the user sent something, and 4/8/16/30 s
/// after consecutive failures.
Duration herdrReadDelay({
  required HerdrAgentStatus status,
  required int unchanged,
  required int failures,
  bool boosted = false,
}) {
  if (failures > 0) {
    const steps = [4, 8, 16, 30];
    return Duration(seconds: steps[failures.clamp(1, steps.length) - 1]);
  }
  if (boosted) return const Duration(milliseconds: 700);
  if (status == HerdrAgentStatus.working) {
    if (unchanged < 3) return const Duration(seconds: 1);
    return Duration(seconds: unchanged < 8 ? 2 : 4);
  }
  if (unchanged >= 6) return const Duration(seconds: 8);
  if (unchanged >= 3) return const Duration(seconds: 4);
  return const Duration(seconds: 2);
}

/// What is remembered per server (the saved connection), on this phone.
abstract interface class HerdrAgentsStore {
  /// The user dismissed the «Herdr is not installed» hint for this server.
  bool get hintDismissed;
  Future<void> dismissHint();

  /// Folders agents were created in, most recent first.
  List<String> get folders;
  Future<void> rememberFolder(String folder);

  /// Folders the user pinned, in the order they were pinned.
  List<String> get favorites;

  /// Pins [folder], or unpins it when it was pinned.
  Future<void> toggleFavorite(String folder);

  String? get lastKind;
  Future<void> setLastKind(String kind);
}

class PrefsHerdrAgentsStore implements HerdrAgentsStore {
  PrefsHerdrAgentsStore(this._prefs, this.connectionId);

  final SharedPreferences _prefs;
  final String connectionId;

  static const int maxFolders = 8;
  static const int maxFavorites = 20;

  String get _hintKey => 'hda.hint.$connectionId';
  String get _foldersKey => 'hda.folders.$connectionId';
  String get _favoritesKey => 'hda.favorites.$connectionId';
  String get _kindKey => 'hda.kind.$connectionId';

  @override
  bool get hintDismissed => _prefs.getBool(_hintKey) ?? false;

  @override
  Future<void> dismissHint() => _prefs.setBool(_hintKey, true);

  @override
  List<String> get folders => _prefs.getStringList(_foldersKey) ?? const [];

  @override
  Future<void> rememberFolder(String folder) {
    final next = [folder, ...folders.where((f) => f != folder)];
    return _prefs.setStringList(_foldersKey, next.take(maxFolders).toList());
  }

  @override
  List<String> get favorites => _prefs.getStringList(_favoritesKey) ?? const [];

  @override
  Future<void> toggleFavorite(String folder) {
    final current = favorites;
    final next = current.contains(folder)
        ? current.where((f) => f != folder).toList()
        : [...current, folder].take(maxFavorites).toList();
    return _prefs.setStringList(_favoritesKey, next);
  }

  @override
  String? get lastKind => _prefs.getString(_kindKey);

  @override
  Future<void> setLastKind(String kind) => _prefs.setString(_kindKey, kind);
}

/// Where the Agents section stands.
enum HerdrAgentsPhase {
  probing,
  notInstalled,

  /// Installed, but no Herdr server is running to ask.
  serverStopped,
  ready,
  connectionError,
  timedOut,
}

/// How an action ended, for the UI to say.
enum HerdrActionResult {
  ok,

  /// The agent is waiting on an approval: Herdr sent nothing.
  agentBlocked,
  notFound,
  serverStopped,

  /// The app refused the input (empty, too long, bad characters or folder).
  invalid,

  /// No absolute path to Herdr: the section is read-only.
  noPath,
  timedOut,
  failed,

  /// The workspace exists but the agent did not start in it.
  startFailed,
}

/// A new agent between «the workspace exists» and «the agent runs».
enum HerdrStartPhase { starting, failed }

/// One agent being started in a workspace the app just made. It lives here
/// until the snapshot shows the agent in its pane (then it is the agent's
/// own row) or until [HerdrAgentsController.startDeadline] passes with no
/// agent there (then it is `failed`, with the reason).
class HerdrStartJob {
  HerdrStartJob({
    required this.paneId,
    required this.kind,
    required this.folder,
    required this.name,
    required this.startedAt,
    this.workspaceId,
  });

  final String paneId;
  final String? workspaceId;
  final String kind;
  final String folder;
  final String name;
  final DateTime startedAt;

  HerdrStartPhase phase = HerdrStartPhase.starting;

  /// For a failed start: what the pane or Herdr said, plain and short. Null
  /// when nothing useful came back.
  String? reason;

  /// The `agent start` command has answered (well or not).
  bool commandDone = false;
  bool retried = false;
  HerdrError? error;

  bool get failed => phase == HerdrStartPhase.failed;
}

/// A line of a pane or of Herdr's error, for the user: no escape or control
/// characters, at most [maxLines] non-empty lines and [maxChars] characters.
String herdrSafeReason(String raw, {int maxLines = 3, int maxChars = 240}) {
  final lines = herdrCleanScreen(
    raw,
  ).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final tail = lines.length > maxLines
      ? lines.sublist(lines.length - maxLines)
      : lines;
  var text = tail.join('\n');
  if (text.length > maxChars) text = text.substring(text.length - maxChars);
  return text;
}

/// A label for a new workspace from what the user typed: plain characters,
/// never starting with a dash, at most 40 characters; null when nothing is
/// left.
String? herdrWorkspaceLabel(String? raw) {
  if (raw == null) return null;
  var label = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '-');
  label = label.replaceFirst(RegExp(r'^[-._ ]+'), '');
  if (label.length > 40) label = label.substring(0, 40);
  return label.isEmpty ? null : label;
}

/// Whether the open agent's conversation is shown from its session file.
enum HerdrTranscriptPhase {
  /// Not looked for (no source, or an agent that keeps no such file).
  off,
  loading,
  ready,

  /// Looked for and not found with certainty: the screen is shown instead.
  unavailable,
}

/// The screen of an agent as last read for its row in the list.
class HerdrPeek {
  const HerdrPeek({
    required this.lines,
    required this.at,
    required this.status,
    required this.seq,
    this.ok = true,
  });

  final List<String> lines;
  final DateTime at;
  final HerdrAgentStatus status;
  final int? seq;

  /// The read went through (false: the lines are the previous ones).
  final bool ok;
}

/// Where the answer to a numbered question stands.
enum HerdrOptionPhase { sending, sent, failed }

/// One answer sent (or being sent) with an option's number.
class HerdrOptionSend {
  const HerdrOptionSend({
    required this.key,
    required this.number,
    required this.phase,
    required this.at,
  });

  /// Identity of the question answered: pane, state change and options.
  final String key;
  final int number;
  final HerdrOptionPhase phase;
  final DateTime at;
}

/// The state behind the Agents section of one server: the probe, the list,
/// the open agent's screen and the actions. It only talks to the server
/// while [setActive] is true (the section is on screen and the app in the
/// foreground) and does so with the delays of [herdrListDelay] and
/// [herdrReadDelay]. Never runs two reads of the same kind at once; reads
/// that land after a stop are dropped.
class HerdrAgentsController extends ChangeNotifier {
  HerdrAgentsController({
    required this.run,
    required this.store,
    DateTime Function()? now,
    this.startRetry = const Duration(milliseconds: 1500),
    this.startDeadline = const Duration(seconds: 30),
    this.serverId = 'server',
    this.sessionFiles,
    HerdrHarnessDetector? detector,
  }) : _now = now ?? DateTime.now,
       _detector = detector ?? HerdrHarnessDetector.shared;

  final SshRemoteRunner run;
  final HerdrAgentsStore store;
  final DateTime Function() _now;

  /// Which server this is, for the harness cache.
  final String serverId;
  final HerdrHarnessDetector _detector;

  /// Wait before the one retry of `agent start` when Herdr says the pane is
  /// not at a prompt yet.
  final Duration startRetry;

  /// How long a new agent may take to show up before it counts as not
  /// started. Herdr's own startup wait is 8 s here; a slow harness can take
  /// longer than that and still start, which is why the snapshot, not the
  /// command's answer, decides.
  final Duration startDeadline;

  HerdrAgentsPhase _phase = HerdrAgentsPhase.probing;
  HerdrAgentsPhase get phase => _phase;

  /// Absolute path of `herdr` on the server; null before the probe, or when
  /// it only exists as an alias (then the section is read-only).
  String? _herdr;
  bool get canWrite => _herdr != null;

  /// The path the probe resolved, for lines typed into a terminal.
  String? get herdrPath => _herdr;

  HerdrSnapshot? _snapshot;
  HerdrSnapshot? get snapshot => _snapshot;

  /// The last list read failed; what is shown may be stale.
  bool _stale = false;
  bool get stale => _stale;

  /// When the last list / screen read landed, for «updated N s ago».
  DateTime? _listAt;
  DateTime? get listUpdatedAt => _listAt;
  DateTime? _detailAt;
  DateTime? get detailUpdatedAt => _detailAt;

  /// The controller's clock, for widgets that show elapsed time.
  DateTime clockNow() => _now();

  HerdrStatusFilter _filter = HerdrStatusFilter.all;
  HerdrStatusFilter get filter => _filter;

  String _query = '';
  String get query => _query;

  /// The folder the list is narrowed to (a path as Herdr reports it); null
  /// for every folder.
  String? _folderFilter;
  String? get folderFilter => _folderFilter;

  final HerdrStateClock _clock = HerdrStateClock();

  bool _active = false;
  bool _disposed = false;
  int _generation = 0;
  int _listFailures = 0;
  bool _listing = false;
  bool _probing = false;

  /// The server answered the probe (found or not): no need to ask again
  /// unless [recheck] says so.
  bool _probeDone = false;
  Timer? _listTimer;

  String? _detail;
  String? get detailPaneId => _detail;
  String _detailText = '';
  String get detailText => _detailText;
  List<String> _detailLines = const [];

  /// The screen split into lines (unchanged lines keep their identity of
  /// position, so a list of them repaints only what moved).
  List<String> get detailLines => _detailLines;
  bool _detailLoaded = false;
  bool get detailLoaded => _detailLoaded;
  bool _detailFailed = false;
  bool get detailFailed => _detailFailed;
  int _detailFailures = 0;
  int _detailUnchanged = 0;
  bool _reading = false;
  Timer? _readTimer;

  /// Reads left to do soon after something was sent.
  int _readBoost = 0;

  /// Panes that moved into `blocked` on the last list read, for the UI to
  /// announce.
  Set<String> newlyBlocked = const {};

  // ── Derived views ─────────────────────────────────────────────────────

  final Map<String, DateTime> _optimistic = {};

  /// What a prompt just sent makes true before Herdr says so: the pane is
  /// working, for a few seconds.
  Map<String, HerdrAgentStatus> get _overrides {
    if (_optimistic.isEmpty) return const {};
    final now = _now();
    _optimistic.removeWhere((_, until) => !now.isBefore(until));
    return {for (final id in _optimistic.keys) id: HerdrAgentStatus.working};
  }

  /// All agents, in display order, with the filter applied.
  List<HerdrAgentRow> get rows {
    final snapshot = _snapshot;
    if (snapshot == null) return const [];
    return herdrAgentRows(snapshot, filter: _filter, overrides: _overrides);
  }

  /// All agents, whatever the filter.
  List<HerdrAgentRow> get allRows {
    final snapshot = _snapshot;
    if (snapshot == null) return const [];
    return herdrAgentRows(snapshot, overrides: _overrides);
  }

  /// The workspaces and their agents, filtered and searched.
  List<HerdrWorkspaceGroup> get groups {
    final snapshot = _snapshot;
    if (snapshot == null) return const [];
    return herdrWorkspaceGroups(
      snapshot,
      filter: _filter,
      query: _query,
      overrides: _overrides,
    );
  }

  int get needsYou =>
      allRows.where((r) => r.status == HerdrAgentStatus.blocked).length;

  HerdrAgentRow? get detailRow {
    for (final row in allRows) {
      if (row.paneId == _detail) return row;
    }
    return null;
  }

  Duration? inState(String paneId) => _clock.inState(paneId, _now());

  bool get hintDismissed => store.hintDismissed;

  /// Folders worth offering for a new agent: where agents run now, then the
  /// ones remembered.
  List<String> get folderSuggestions {
    final out = <String>[];
    for (final row in allRows) {
      final cwd = row.pane.cwd;
      if (cwd != null && cwd.startsWith('/') && !out.contains(cwd)) {
        out.add(cwd);
      }
    }
    for (final folder in store.folders) {
      if (!out.contains(folder)) out.add(folder);
    }
    return out;
  }

  // ── What the screens say ──────────────────────────────────────────────

  /// Reads each agent's screen once per state (and a working one every
  /// [peekWorkingEvery]) so the list can say what it is doing and why a
  /// blocked one waits. Off until the view that shows it turns it on: the
  /// bare controller never reads a screen for the list.
  bool peekScreens = false;

  /// How often the screen of a working agent is read again for its row.
  static const Duration peekWorkingEvery = Duration(seconds: 20);

  /// Most screens read in one round (a long list fills over a few rounds).
  static const int peekPerRound = 6;

  final Map<String, HerdrPeek> _peeks = {};
  bool _peeking = false;

  /// The lines last read from [paneId]'s screen for the list; the open
  /// agent's own live lines when it is the one open.
  List<String> screenLines(String paneId) {
    if (paneId == _detail && _detailLoaded) return _detailLines;
    return _peeks[paneId]?.lines ?? const [];
  }

  /// What a blocked agent's screen asks; null when the agent is not blocked.
  /// Reads the screen as it was last seen (see [screenLines]).
  HerdrAsk? askFor(HerdrAgentRow row) {
    if (row.status != HerdrAgentStatus.blocked) return null;
    return herdrReadAsk(screenLines(row.paneId));
  }

  /// The one line a row shows under the agent's name; null when nothing was
  /// read yet.
  String? activityFor(HerdrAgentRow row) {
    final lines = screenLines(row.paneId);
    if (lines.isEmpty) return null;
    return herdrActivityLine(lines, ask: askFor(row));
  }

  Future<void> _peekRound(int generation) async {
    if (!peekScreens || _peeking || _disposed || !_active) return;
    final snapshot = _snapshot;
    if (snapshot == null) return;
    _peeking = true;
    var changed = false;
    try {
      final live = <String>{};
      var budget = peekPerRound;
      for (final row in allRows) {
        live.add(row.paneId);
        if (budget == 0 || row.paneId == _detail) continue;
        final seen = _peeks[row.paneId];
        final now = _now();
        final stale =
            seen == null ||
            seen.status != row.status ||
            seen.seq != row.pane.stateSeq ||
            (!seen.ok &&
                now.difference(seen.at) >= const Duration(seconds: 10)) ||
            (row.status == HerdrAgentStatus.working &&
                now.difference(seen.at) >= peekWorkingEvery);
        if (!stale) continue;
        budget--;
        List<String> lines;
        var ok = true;
        try {
          final command = HerdrCommand.read(row.paneId).render(herdr: _herdr);
          final text = parseHerdrReadOutput(await run(command));
          lines = text.isEmpty ? const [] : text.split('\n');
        } catch (e) {
          debugPrint('[herdr-agents] peek failed (${e.runtimeType})');
          lines = seen?.lines ?? const [];
          ok = false;
        }
        if (generation != _generation || _disposed || !_active) return;
        final before = seen?.lines.join('\n');
        _peeks[row.paneId] = HerdrPeek(
          lines: lines,
          at: _now(),
          status: row.status,
          seq: row.pane.stateSeq,
          ok: ok,
        );
        if (before != lines.join('\n')) changed = true;
      }
      _peeks.removeWhere((id, _) => !live.contains(id));
    } finally {
      _peeking = false;
    }
    if (changed) _notify();
  }

  // ── Answering a numbered question ─────────────────────────────────────

  final Map<String, HerdrOptionSend> _optionSends = {};
  final List<Timer> _optionTimers = [];

  /// How long «sent» holds the options still before they can be tried again
  /// (the agent did not move on).
  static const Duration optionSentHold = Duration(seconds: 6);

  String _askKey(HerdrAgentRow row, HerdrAsk ask) =>
      '${row.paneId}|${row.pane.stateSeq}|${ask.signature}';

  /// Where the answer to [ask] stands: null when nothing was sent for this
  /// very question, or the send is old enough to try again.
  HerdrOptionSend? optionSendFor(HerdrAgentRow row, HerdrAsk ask) {
    final send = _optionSends[row.paneId];
    if (send == null || send.key != _askKey(row, ask)) return null;
    if (send.phase == HerdrOptionPhase.sent &&
        !_now().isBefore(send.at.add(optionSentHold))) {
      return null;
    }
    return send;
  }

  /// Sends only the key of option [number] to the agent of [row], once: a
  /// second call while the first is in flight, or after it went through
  /// (until [optionSentHold] passes), does nothing. Returns whether a key
  /// went out and Herdr accepted it; that says the key was typed, not that
  /// the agent took it.
  Future<bool> sendOption(HerdrAgentRow row, HerdrAsk ask, int number) async {
    if (_disposed || !ask.options.any((o) => o.number == number)) return false;
    final current = optionSendFor(row, ask);
    if (current != null && current.phase != HerdrOptionPhase.failed) {
      return false;
    }
    final key = _askKey(row, ask);
    _optionSends[row.paneId] = HerdrOptionSend(
      key: key,
      number: number,
      phase: HerdrOptionPhase.sending,
      at: _now(),
    );
    _notify();
    final result = await sendKey(row.paneId, HerdrKey.digit(number));
    if (_disposed) return false;
    final ok = result == HerdrActionResult.ok;
    _optionSends[row.paneId] = HerdrOptionSend(
      key: key,
      number: number,
      phase: ok ? HerdrOptionPhase.sent : HerdrOptionPhase.failed,
      at: _now(),
    );
    _notify();
    if (ok) {
      // Let the options come back to life if the agent did not move on.
      _optionTimers.add(Timer(optionSentHold, _notify));
    }
    return ok;
  }

  // ── Launched from here ────────────────────────────────────────────────

  final Set<String> _launched = {};

  /// The agent was started by this app in this session. Herdr's snapshot
  /// does not say who launched an agent, so this is all that is known; a pane
  /// id can be reused later, so it is not remembered across sessions.
  bool launchedHere(String paneId) => _launched.contains(paneId);

  // ── The conversation of the open agent ────────────────────────────────

  /// Where session files are read from; null leaves every agent on its
  /// screen.
  final HerdrSessionFiles? sessionFiles;

  /// How much of the end of a session file is read first, and the most that
  /// paging back ever holds.
  static const int transcriptWindow = 256 * 1024;
  static const int transcriptCap = 4 * 1024 * 1024;

  /// How often the file of an agent is looked for again.
  static const Duration transcriptRelocate = Duration(seconds: 30);
  static const Duration transcriptRetry = Duration(seconds: 15);

  HerdrTranscriptPhase _txPhase = HerdrTranscriptPhase.off;
  HerdrSessionRef? _txRef;
  DateTime? _txLocatedAt;
  List<String> _txLines = const [];
  List<HerdrTurn> _txTurns = const [];
  int _txStart = 0;
  int _txEnd = 0;
  int _txLimit = transcriptWindow;
  bool _txBusy = false;

  HerdrTranscriptPhase get transcriptPhase => _txPhase;

  /// The conversation of the open agent, oldest first.
  List<HerdrTurn> get transcriptTurns => _txTurns;

  /// Bytes of the file held in memory (never above the limit the reader has
  /// paged back to, plus one line).
  int get transcriptBytes => _txEnd - _txStart;

  /// Older messages are in the file than the ones loaded.
  bool get transcriptHasEarlier =>
      _txStart > 0 && (_txEnd - _txStart) < transcriptCap;

  void _txReset() {
    _txRef = null;
    _txLocatedAt = null;
    _txLines = const [];
    _txTurns = const [];
    _txStart = 0;
    _txEnd = 0;
    _txLimit = transcriptWindow;
    _txPhase = sessionFiles == null
        ? HerdrTranscriptPhase.off
        : HerdrTranscriptPhase.loading;
  }

  /// Forgets the oldest lines while more than [_txLimit] bytes are held, so
  /// following a long session does not grow memory or parsing time.
  void _txTrim() {
    if (_txEnd - _txStart <= _txLimit) return;
    var drop = 0;
    var start = _txStart;
    while (drop < _txLines.length - 1 && _txEnd - start > _txLimit) {
      start += utf8.encode(_txLines[drop]).length + 1;
      drop++;
    }
    if (drop == 0) return;
    _txLines = _txLines.sublist(drop);
    _txStart = start;
  }

  void _txRebuild() {
    final ref = _txRef;
    if (ref == null) return;
    _txTrim();
    _txTurns = ref.format == HerdrTranscriptFormat.claude
        ? herdrParseClaude(_txLines)
        : herdrParseCodex(_txLines);
    _txPhase = HerdrTranscriptPhase.ready;
  }

  /// The complete lines of [bytes] and how many bytes they took (up to the
  /// last line break; a cut last line is left for the next read).
  ({List<String> lines, int used}) _txLinesOf(Uint8List bytes) {
    final last = bytes.lastIndexOf(0x0A);
    if (last < 0) return (lines: const [], used: 0);
    final text = utf8.decode(bytes.sublist(0, last), allowMalformed: true);
    return (lines: text.split('\n'), used: last + 1);
  }

  Future<void> _syncTranscript(int generation, String paneId) async {
    final files = sessionFiles;
    if (files == null || _txBusy || _disposed) return;
    final row = detailRow;
    final kind = row?.pane.agent;
    final cwd = row?.pane.cwd;
    if (row == null ||
        (kind != 'claude' && kind != 'codex') ||
        cwd == null ||
        cwd.isEmpty) {
      _txPhase = HerdrTranscriptPhase.off;
      return;
    }
    bool stale() => generation != _generation || paneId != _detail || _disposed;
    _txBusy = true;
    try {
      final now = _now();
      final located = _txLocatedAt;
      final every = _txRef == null ? transcriptRetry : transcriptRelocate;
      if (located == null || now.difference(located) >= every) {
        _txLocatedAt = now;
        final same = allRows
            .where((r) => r.pane.agent == kind && r.pane.cwd == cwd)
            .length;
        final found = await herdrLocateSession(
          files,
          kind: kind!,
          cwd: cwd,
          now: now,
          working: row.status == HerdrAgentStatus.working,
          sameKindInFolder: same,
          quietFor: row.status == HerdrAgentStatus.working
              ? null
              : _clock.inState(paneId, now),
        );
        if (stale()) return;
        if (found != _txRef) {
          final had = _txRef != null;
          _txRef = found;
          _txLines = const [];
          _txTurns = const [];
          _txStart = 0;
          _txEnd = 0;
          _txLimit = transcriptWindow;
          if (found == null &&
              (had || _txPhase != HerdrTranscriptPhase.ready)) {
            _txPhase = HerdrTranscriptPhase.unavailable;
            _notify();
          }
        }
      }
      final ref = _txRef;
      if (ref == null) {
        if (_txPhase == HerdrTranscriptPhase.loading) {
          _txPhase = HerdrTranscriptPhase.unavailable;
          _notify();
        }
        return;
      }
      final info = await files.stat(ref.path);
      if (stale()) return;
      if (info == null) {
        _txRef = null;
        _txLocatedAt = null;
        _txPhase = HerdrTranscriptPhase.unavailable;
        _notify();
        return;
      }
      var changed = false;
      if (_txEnd == 0 && _txLines.isEmpty) {
        var start = info.size > transcriptWindow
            ? info.size - transcriptWindow
            : 0;
        final bytes = await files.read(
          ref.path,
          offset: start,
          length: info.size - start,
        );
        if (stale()) return;
        var body = bytes;
        if (start > 0) {
          final cut = bytes.indexOf(0x0A);
          body = cut < 0 ? Uint8List(0) : bytes.sublist(cut + 1);
          start += cut < 0 ? bytes.length : cut + 1;
        }
        final read = _txLinesOf(body);
        _txLines = read.lines;
        _txStart = start;
        _txEnd = start + read.used;
        changed = true;
      } else if (info.size > _txEnd) {
        final bytes = await files.read(
          ref.path,
          offset: _txEnd,
          length: info.size - _txEnd,
        );
        if (stale()) return;
        final read = _txLinesOf(bytes);
        if (read.used > 0) {
          _txLines = [..._txLines, ...read.lines];
          _txEnd += read.used;
          changed = true;
        }
      } else if (info.size < _txEnd) {
        // The file was replaced by a shorter one: start over.
        _txLines = const [];
        _txEnd = 0;
        _txStart = 0;
        return;
      }
      if (changed || _txPhase != HerdrTranscriptPhase.ready) {
        _txRebuild();
        _notify();
      }
    } catch (e) {
      debugPrint('[herdr-agents] transcript failed (${e.runtimeType})');
      if (_txPhase == HerdrTranscriptPhase.loading) {
        _txPhase = HerdrTranscriptPhase.unavailable;
        _notify();
      }
    } finally {
      _txBusy = false;
    }
  }

  /// Loads the messages before the ones shown (one more window, up to
  /// [transcriptCap] in all).
  Future<void> loadEarlierTranscript() async {
    final ref = _txRef;
    final files = sessionFiles;
    if (ref == null || files == null || _txBusy || !transcriptHasEarlier) {
      return;
    }
    _txBusy = true;
    final paneId = _detail;
    try {
      final from = _txStart > transcriptWindow
          ? _txStart - transcriptWindow
          : 0;
      final bytes = await files.read(
        ref.path,
        offset: from,
        length: _txStart - from,
      );
      if (_disposed || paneId != _detail) return;
      var body = bytes;
      var start = from;
      if (from > 0) {
        final cut = bytes.indexOf(0x0A);
        body = cut < 0 ? Uint8List(0) : bytes.sublist(cut + 1);
        start += cut < 0 ? bytes.length : cut + 1;
      }
      final text = utf8.decode(body, allowMalformed: true);
      final lines = text.isEmpty
          ? <String>[]
          : (text.endsWith('\n') ? text.substring(0, text.length - 1) : text)
                .split('\n');
      _txLines = [...lines, ..._txLines];
      _txStart = start;
      _txLimit = (_txLimit + transcriptWindow).clamp(0, transcriptCap);
      _txRebuild();
      _notify();
    } catch (e) {
      debugPrint('[herdr-agents] earlier messages failed (${e.runtimeType})');
    } finally {
      _txBusy = false;
    }
  }

  // ── Harnesses ─────────────────────────────────────────────────────────

  HerdrHarnessReport? _harness;

  /// Which harnesses the server has; null until the first look.
  HerdrHarnessReport? get harness => _harness;
  bool _detecting = false;
  bool get detecting => _detecting;

  /// Looks for the harnesses (from the cache when fresh, unless [force]).
  Future<void> detectHarnesses({bool force = false}) async {
    if (_disposed || _detecting) return;
    _detecting = true;
    _notify();
    try {
      _harness = await _detector.detect(serverId, run, force: force);
    } finally {
      _detecting = false;
      _notify();
    }
  }

  // ── Visibility ────────────────────────────────────────────────────────

  /// The section is shown (true) or hidden/in the background (false).
  void setActive(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    if (!active) {
      _stopTimers();
      return;
    }
    if (_phase == HerdrAgentsPhase.notInstalled) return;
    if (!_probeDone) {
      unawaited(_probe());
    } else {
      unawaited(refresh());
      if (_detail != null) unawaited(_readDetail(_generation));
    }
  }

  void _stopTimers() {
    _generation++;
    _listTimer?.cancel();
    _listTimer = null;
    _readTimer?.cancel();
    _readTimer = null;
  }

  // ── Probe ─────────────────────────────────────────────────────────────

  /// Looks for Herdr on the server (read-only `command -v`, then the usual
  /// folders). Missing is only «the server answered, no Herdr»: an error or
  /// a silence is not «not installed».
  Future<void> _probe() async {
    if (_probing || _disposed) return;
    _probing = true;
    final generation = _generation;
    _setPhase(HerdrAgentsPhase.probing);
    try {
      var result = await run(sshHerdrProbeCommand);
      if (result.exitCode != 0) {
        result = await run(sshHerdrFallbackProbeCommand);
      }
      if (generation != _generation) return;
      _probeDone = true;
      if (result.exitCode != 0) {
        _setPhase(HerdrAgentsPhase.notInstalled);
        return;
      }
      _herdr = herdrPathFromProbe(result.stdout);
      await _readList(generation);
    } on TimeoutException {
      if (generation == _generation) _setPhase(HerdrAgentsPhase.timedOut);
    } catch (e) {
      debugPrint('[herdr-agents] probe failed (${e.runtimeType})');
      if (generation == _generation) {
        _setPhase(HerdrAgentsPhase.connectionError);
      }
    } finally {
      _probing = false;
    }
  }

  /// Asks again (after installing, or after an error).
  Future<void> recheck() async {
    if (_disposed) return;
    _herdr = null;
    _probeDone = false;
    _listFailures = 0;
    _listTimer?.cancel();
    _listTimer = null;
    _generation++;
    await _probe();
  }

  /// The user said «not now» to the install hint of this server.
  Future<void> dismissHint() async {
    await store.dismissHint();
    _notify();
  }

  // ── List ──────────────────────────────────────────────────────────────

  /// Reads the list now.
  Future<void> refresh() async {
    if (_disposed || !_active) return;
    if (!_probeDone) return _probe();
    _listTimer?.cancel();
    _listTimer = null;
    await _readList(_generation);
  }

  bool get _starting => _jobs.values.any((j) => !j.failed);

  Future<void> _readList(int generation) async {
    if (_listing || _disposed) return;
    _listing = true;
    var next = herdrListDelay(busy: false, failures: 0);
    try {
      final command = HerdrCommand.snapshot().render(herdr: _herdr);
      final snapshot = parseHerdrSnapshotOutput(await run(command));
      if (generation != _generation) return;
      _listFailures = 0;
      _stale = false;
      _snapshot = snapshot;
      _listAt = _now();
      newlyBlocked = _clock.observe(snapshot.panes, _now());
      for (final pane in snapshot.panes) {
        if (pane.status == HerdrAgentStatus.working) {
          _optimistic.remove(pane.paneId);
        }
      }
      final busy = snapshot.panes.any(
        (p) =>
            p.hasAgent &&
            (p.status == HerdrAgentStatus.working ||
                p.status == HerdrAgentStatus.blocked),
      );
      _resolveJobs(snapshot);
      final here = {for (final pane in snapshot.panes) pane.paneId};
      _launched.removeWhere(
        (id) => !here.contains(id) && !_jobs.containsKey(id),
      );
      next = herdrListDelay(
        busy: busy || _detail != null || _optimistic.isNotEmpty,
        failures: 0,
        starting: _starting,
      );
      _setPhase(HerdrAgentsPhase.ready);
      if (peekScreens) unawaited(_peekRound(generation));
    } on HerdrError catch (e) {
      if (generation != _generation) return;
      _listFailures++;
      next = herdrListDelay(busy: false, failures: _listFailures);
      if (e.code == HerdrError.serverNotRunning) {
        _snapshot = null;
        _setPhase(HerdrAgentsPhase.serverStopped);
      } else {
        _failList(HerdrAgentsPhase.connectionError);
      }
    } on TimeoutException {
      if (generation != _generation) return;
      _listFailures++;
      next = herdrListDelay(busy: false, failures: _listFailures);
      _failList(HerdrAgentsPhase.timedOut);
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('[herdr-agents] list failed (${e.runtimeType})');
      _listFailures++;
      next = herdrListDelay(busy: false, failures: _listFailures);
      _failList(HerdrAgentsPhase.connectionError);
    } finally {
      _listing = false;
      if (_active && !_disposed && generation == _generation) {
        _listTimer?.cancel();
        _listTimer = Timer(next, () => unawaited(_readList(generation)));
      }
    }
  }

  void _failList(HerdrAgentsPhase failure) {
    if (_snapshot != null) {
      _stale = true;
      _notify();
    } else {
      _setPhase(failure);
    }
  }

  void setFilter(HerdrStatusFilter filter) {
    if (_filter == filter) return;
    _filter = filter;
    _notify();
  }

  void setQuery(String query) {
    if (_query == query) return;
    _query = query;
    _notify();
  }

  void setFolderFilter(String? folder) {
    if (_folderFilter == folder) return;
    _folderFilter = folder;
    _notify();
  }

  // ── One agent ─────────────────────────────────────────────────────────

  /// Starts following [paneId]'s screen.
  void openDetail(String paneId) {
    if (!isHerdrPaneId(paneId)) return;
    _detail = paneId;
    _detailText = '';
    _detailLines = const [];
    _detailLoaded = false;
    _detailFailed = false;
    _detailFailures = 0;
    _detailUnchanged = 0;
    _detailAt = null;
    _txReset();
    _readTimer?.cancel();
    _readTimer = null;
    _notify();
    if (_active) unawaited(_readDetail(_generation));
  }

  void closeDetail() {
    if (_detail == null) return;
    _detail = null;
    _txReset();
    _txPhase = HerdrTranscriptPhase.off;
    _readTimer?.cancel();
    _readTimer = null;
    _notify();
  }

  Future<void> _readDetail(int generation) async {
    final paneId = _detail;
    if (paneId == null || _reading || _disposed) return;
    _reading = true;
    var next = const Duration(seconds: 2);
    try {
      final command = HerdrCommand.read(paneId).render(herdr: _herdr);
      final text = parseHerdrReadOutput(await run(command));
      if (generation != _generation || paneId != _detail) return;
      final recovered = _detailFailed;
      _detailFailures = 0;
      _detailFailed = false;
      _detailAt = _now();
      final changed = text != _detailText || !_detailLoaded;
      _detailUnchanged = changed ? 0 : _detailUnchanged + 1;
      if (changed) {
        _detailText = text;
        _detailLines = text.isEmpty ? const [] : text.split('\n');
        _detailLoaded = true;
        final row = detailRow;
        if (peekScreens && row != null) {
          // The row keeps what the open screen said once it is closed.
          _peeks[paneId] = HerdrPeek(
            lines: _detailLines,
            at: _now(),
            status: row.status,
            seq: row.pane.stateSeq,
          );
        }
      }
      // An unchanged screen repaints nothing («updated N s ago» has its
      // own clock).
      if (changed || recovered) _notify();
      if (sessionFiles != null) unawaited(_syncTranscript(generation, paneId));
      final boosted = _readBoost > 0;
      if (boosted) _readBoost--;
      next = herdrReadDelay(
        status: detailRow?.status ?? HerdrAgentStatus.idle,
        unchanged: _detailUnchanged,
        failures: 0,
        boosted: boosted,
      );
    } catch (e) {
      if (generation != _generation || paneId != _detail) return;
      debugPrint('[herdr-agents] read failed (${e.runtimeType})');
      _detailFailures++;
      _detailFailed = true;
      next = herdrReadDelay(
        status: HerdrAgentStatus.idle,
        unchanged: 0,
        failures: _detailFailures,
      );
      _notify();
    } finally {
      _reading = false;
      if (_active && !_disposed && generation == _generation) {
        if (_detail == paneId) {
          _readTimer?.cancel();
          _readTimer = Timer(next, () => unawaited(_readDetail(generation)));
        }
      }
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────

  HerdrActionResult _resultOf(Object error) {
    if (error is HerdrInputException) {
      return error.problem == HerdrInputProblem.noPath
          ? HerdrActionResult.noPath
          : HerdrActionResult.invalid;
    }
    if (error is TimeoutException) return HerdrActionResult.timedOut;
    if (error is HerdrError) {
      if (HerdrErrorCodes.isNotFound(error.code)) {
        return HerdrActionResult.notFound;
      }
      return switch (error.code) {
        HerdrErrorCodes.agentBlocked => HerdrActionResult.agentBlocked,
        HerdrError.serverNotRunning => HerdrActionResult.serverStopped,
        _ => HerdrActionResult.failed,
      };
    }
    return HerdrActionResult.failed;
  }

  Future<HerdrActionResult> _write(
    HerdrCommand command, {
    String? optimisticPane,
  }) async {
    try {
      final result = await run(command.render(herdr: _herdr));
      herdrExpectOk(result);
      if (optimisticPane != null) {
        // The agent is about to work: say so at once instead of waiting for
        // the next look, and look again soon.
        _optimistic[optimisticPane] = _now().add(const Duration(seconds: 4));
        _readBoost = 3;
        _notify();
      }
      return HerdrActionResult.ok;
    } catch (e) {
      debugPrint('[herdr-agents] ${command.subcommand} failed');
      return _resultOf(e);
    } finally {
      if (_active && !_disposed) {
        unawaited(refresh());
        if (_detail != null) {
          _readTimer?.cancel();
          unawaited(_readDetail(_generation));
        }
      }
    }
  }

  /// Types [text] into the agent in [paneId] and submits it. The text is an
  /// input to the agent, not a shell command: nothing here runs a shell
  /// line on the server.
  Future<HerdrActionResult> sendPrompt(String paneId, String text) {
    try {
      return _write(HerdrCommand.prompt(paneId, text), optimisticPane: paneId);
    } catch (e) {
      return Future.value(_resultOf(e));
    }
  }

  Future<HerdrActionResult> sendKey(String paneId, HerdrKey key) {
    try {
      return _write(HerdrCommand.sendKeys(paneId, [key]));
    } catch (e) {
      return Future.value(_resultOf(e));
    }
  }

  // ── New agents ────────────────────────────────────────────────────────

  final Map<String, HerdrStartJob> _jobs = {};

  /// Agents being started and those whose start failed, oldest first.
  List<HerdrStartJob> get startJobs => List.unmodifiable(_jobs.values);

  /// Pane the last [createAgent] made, to open it.
  String? createdPaneId;

  /// A name for a new [kind] agent that no agent in the list uses.
  String uniqueName(String kind) {
    final taken = {
      for (final row in allRows)
        if (row.pane.name != null) row.pane.name!,
      for (final job in _jobs.values) job.name,
    };
    if (!taken.contains(kind)) return kind;
    for (var i = 2; i < 1000; i++) {
      final name = '$kind-$i';
      if (!taken.contains(name)) return name;
    }
    return '$kind-${_now().millisecondsSinceEpoch % 100000}';
  }

  /// Creates a workspace in [folder] and starts a [kind] agent in it. Only
  /// called after the user confirmed folder and kind. Returns as soon as the
  /// workspace exists: the agent is then «starting» (see [startJobs]) and
  /// the list shows it, however long the harness takes.
  Future<HerdrActionResult> createAgent({
    required String folder,
    required String kind,
    String? label,
  }) async {
    createdPaneId = null;
    final HerdrCommand create;
    try {
      if (!herdrAgentKinds.contains(kind)) {
        throw const HerdrInputException(HerdrInputProblem.badKind);
      }
      create = HerdrCommand.workspaceCreate(folder, label: label);
    } catch (e) {
      return _resultOf(e);
    }
    final HerdrCreated created;
    try {
      created = parseHerdrCreated(await run(create.render(herdr: _herdr)));
    } catch (e) {
      debugPrint('[herdr-agents] workspace create failed');
      return _resultOf(e);
    }
    createdPaneId = created.paneId;
    _launched.add(created.paneId);
    final cwd = herdrFolder(folder);
    final job = HerdrStartJob(
      paneId: created.paneId,
      workspaceId: created.workspaceId,
      kind: kind,
      folder: cwd,
      name: uniqueName(kind),
      startedAt: _now(),
    );
    _jobs[job.paneId] = job;
    await store.rememberFolder(cwd);
    await store.setLastKind(kind);
    _notify();
    unawaited(_runStart(job));
    // Look now, and from then on every second (see [herdrListDelay]) until
    // the agent shows up.
    if (_active && !_disposed) unawaited(refresh());
    return HerdrActionResult.ok;
  }

  /// Runs `agent start` for [job]. Its answer is not what decides: a slow
  /// harness makes Herdr's own wait end with `timeout` while the harness
  /// goes on starting, and one that stops at a question answers
  /// `agent_not_ready` while it runs. The snapshot (see [_resolveJobs])
  /// decides, up to [startDeadline].
  Future<void> _runStart(HerdrStartJob job) async {
    try {
      final start = HerdrCommand.agentStart(job.name, job.kind, job.paneId);
      herdrExpectOk(await run(start.render(herdr: _herdr)));
      job.commandDone = true;
    } on HerdrInputException {
      job.commandDone = true;
      await _failJob(job);
      return;
    } catch (e) {
      debugPrint('[herdr-agents] agent start did not answer ok');
      if (e is HerdrError && e.code == HerdrErrorCodes.agentNotReady) {
        job.commandDone = true;
      } else if (e is HerdrError &&
          e.code == HerdrErrorCodes.paneBusy &&
          !job.retried) {
        // The new shell may not be at its prompt yet: once more, unless an
        // agent is already there.
        job.retried = true;
        await Future<void>.delayed(startRetry);
        if (_disposed) return;
        if (!_paneHasAgent(job.paneId)) return _runStart(job);
        job.commandDone = true;
      } else {
        job.commandDone = true;
        if (e is HerdrError) job.error = e;
      }
    }
    if (_active && !_disposed) unawaited(refresh());
  }

  static HerdrPane? _paneIn(HerdrSnapshot? snapshot, String paneId) {
    if (snapshot == null) return null;
    for (final pane in snapshot.panes) {
      if (pane.paneId == paneId) return pane;
    }
    return null;
  }

  bool _paneHasAgent(String paneId) =>
      _paneIn(_snapshot, paneId)?.hasAgent ?? false;

  /// After each snapshot: a job whose pane now holds an agent is done; one
  /// whose pane is gone is dropped; one past its deadline has failed.
  void _resolveJobs(HerdrSnapshot snapshot) {
    for (final job in _jobs.values.toList()) {
      if (job.failed) {
        // A harness slower than the deadline may still come up: then its
        // own row replaces the failure (the one thing worse than a late
        // agent is a «did not start» beside it).
        final pane = _paneIn(snapshot, job.paneId);
        if (pane == null || pane.hasAgent) _jobs.remove(job.paneId);
        continue;
      }
      final pane = _paneIn(snapshot, job.paneId);
      if (pane == null) {
        _jobs.remove(job.paneId);
      } else if (pane.hasAgent) {
        _jobs.remove(job.paneId);
      } else if (_now().difference(job.startedAt) >= startDeadline) {
        unawaited(_failJob(job));
      }
    }
  }

  /// The start did not happen: say why, in the harness's name. What the
  /// pane's shell printed is the best reason (`pi: command not found`);
  /// Herdr's own sentence is the fallback.
  Future<void> _failJob(HerdrStartJob job) async {
    if (job.failed) return;
    job.phase = HerdrStartPhase.failed;
    _notify();
    String? reason;
    try {
      final read = HerdrCommand.paneRead(job.paneId).render(herdr: _herdr);
      final result = await run(read);
      if (result.exitCode == 0) {
        final text = herdrSafeReason(result.stdout);
        if (text.isNotEmpty) reason = text;
      }
    } catch (_) {
      // Best effort.
    }
    reason ??= switch (job.error?.message) {
      final String message when message.trim().isNotEmpty => herdrSafeReason(
        message,
      ),
      _ => null,
    };
    job.reason = reason;
    _notify();
  }

  /// Starts the failed agent of [paneId] again, in the same workspace (or in
  /// a new one when the workspace is gone).
  Future<void> retryStart(String paneId) async {
    final old = _jobs[paneId];
    if (old == null || !old.failed || _disposed) return;
    _jobs.remove(paneId);
    final present = _paneIn(_snapshot, paneId);
    if (present == null) {
      await createAgent(folder: old.folder, kind: old.kind);
      return;
    }
    if (present.hasAgent) {
      _notify();
      return;
    }
    final job = HerdrStartJob(
      paneId: paneId,
      workspaceId: old.workspaceId,
      kind: old.kind,
      folder: old.folder,
      name: uniqueName(old.kind),
      startedAt: _now(),
    );
    _jobs[paneId] = job;
    _notify();
    unawaited(_runStart(job));
    if (_active && !_disposed) unawaited(refresh());
  }

  /// Forgets a failed start (the workspace stays on the server).
  void dismissStart(String paneId) {
    if (_jobs.remove(paneId) != null) _notify();
  }

  // ── Plumbing ──────────────────────────────────────────────────────────

  void _setPhase(HerdrAgentsPhase phase) {
    _phase = phase;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _optionTimers) {
      timer.cancel();
    }
    _optionTimers.clear();
    _stopTimers();
    super.dispose();
  }
}
