// A stand-in for a server that has (or lacks) Herdr, behind the same
// `SshRemoteRunner` the app uses. It answers with the shapes Herdr's docs
// and a real 0.9.5 `api snapshot` give; what the docs do not show
// (`workspace create`, `agent_blocked`, `agent read` text) comes from the
// *_synthetic fixtures. Records every command line it is sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hermes_android/core/services/agent_processes.dart';
import 'package:hermes_android/core/services/herdr_harness.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/terminal_sessions.dart';

/// Absolute path the fake server reports for `herdr`.
const String fakeHerdrPath = '/home/demo/.local/bin/herdr';

class FakeAgent {
  FakeAgent(
    this.paneId,
    this.agent,
    this.status, {
    this.name,
    this.cwd = '/home/demo/proyectos/app',
    this.seq = 1,
    this.workspace = 'app',
    this.workspaceId,
    this.launchPending = false,
  });

  final String paneId;

  /// Fixed id of the workspace (one made by `workspace create`); else the
  /// fake numbers workspaces by order.
  final String? workspaceId;
  bool launchPending;
  final String agent;
  HerdrAgentStatus status;
  final String? name;
  final String cwd;
  int seq;
  final String workspace;
}

/// A workspace made by `workspace create`, with its one shell pane.
class FakeCreated {
  FakeCreated(this.workspaceId, this.paneId, this.label, this.cwd);

  final String workspaceId;
  final String paneId;
  final String label;
  final String cwd;
}

class FakeTmux {
  const FakeTmux(this.id, this.name, {this.windows = 1, this.attached = 0});

  final String id;
  final String name;
  final int windows;
  final int attached;
}

class FakeHerdrServer {
  FakeHerdrServer({this.installed = true, List<FakeAgent>? agents})
    : agents = agents ?? [];

  /// Harnesses `command -v` finds (all by default).
  Set<String> harnesses = {...herdrHarnessNames};

  /// Both harness commands throw (the connection dropped).
  bool harnessFails = false;

  /// `null`: tmux is not installed (exit 127). Else the sessions it lists
  /// (empty: «no server running», exit 1).
  List<FakeTmux>? tmux = const [];

  /// Named sessions `herdr session list --json` reports (the fixture's when
  /// null).
  String? sessionListJson;

  /// How `agent start` goes. [startCommandAfter]: how long the command
  /// takes to answer; [startError]: the fixture it answers with instead of
  /// success; [agentAppearsAfter]: how long after the call the agent shows
  /// in the snapshot (null: never).
  Duration startCommandAfter = Duration.zero;
  String? startError;
  Duration? agentAppearsAfter = Duration.zero;

  /// What `pane read` shows for panes without an agent.
  final Map<String, String> paneScreens = {};
  final List<FakeCreated> created = [];
  int startCalls = 0;

  /// `command -v herdr` finds it (login shell or folder look).
  bool installed;

  /// Only the folder look finds it.
  bool onlyInFolders = false;
  bool serverRunning = true;

  /// What `ps -eo comm=` lists (the executables running on the server).
  List<String> processes = const [];

  /// Throws instead of answering (a dropped connection).
  Object? failWith;

  final List<FakeAgent> agents;
  final Map<String, String> screens = {};
  final List<String> commands = [];

  /// Command lines of the `herdr …` invocations only, as sent.
  List<String> get herdrCalls =>
      commands.where((c) => c.startsWith("'$fakeHerdrPath'")).toList();

  int get snapshotCalls =>
      herdrCalls.where((c) => shellWords(c)[2] == 'snapshot').length;
  int get readCalls =>
      herdrCalls.where((c) => shellWords(c)[2] == 'read').length;

  static String _fixture(String name) =>
      File('test/fixtures/herdr/$name').readAsStringSync();

  Future<SshRemoteResult> call(String command) async {
    commands.add(command);
    final failure = failWith;
    if (failure != null) throw failure;
    if (command == sshAgentProcessesCommand) {
      return SshRemoteResult(stdout: '${processes.join('\n')}\n', exitCode: 0);
    }
    if (command == sshHerdrProbeCommand) {
      return installed && !onlyInFolders
          ? const SshRemoteResult(stdout: '$fakeHerdrPath\n', exitCode: 0)
          : const SshRemoteResult(stdout: '', exitCode: 1);
    }
    if (command == sshHerdrFallbackProbeCommand) {
      return installed
          ? const SshRemoteResult(stdout: '$fakeHerdrPath\n', exitCode: 0)
          : const SshRemoteResult(stdout: '', exitCode: 1);
    }
    if (command == sshHarnessLoginCommand ||
        command == sshHarnessFolderCommand) {
      if (harnessFails) throw StateError('connection dropped');
      // Both commands print the same paths here; the login one also exits
      // non-zero when it finds fewer than it was asked for.
      final out = [
        for (final name in herdrHarnessNames)
          if (harnesses.contains(name)) '/home/demo/.local/bin/$name',
      ];
      return SshRemoteResult(stdout: '${out.join('\n')}\n', exitCode: 0);
    }
    if (command == sshTmuxListCommand) {
      final list = tmux;
      if (list == null) {
        return const SshRemoteResult(
          stdout: '',
          stderr: 'sh: 1: tmux: not found',
          exitCode: 127,
        );
      }
      if (list.isEmpty) {
        return const SshRemoteResult(
          stdout: '',
          stderr: 'no server running on /tmp/tmux-1000/default',
          exitCode: 1,
        );
      }
      return SshRemoteResult(
        stdout: [
          for (final t in list)
            '${t.id}\t${t.windows}\t${t.attached}\t${t.name}',
        ].join('\n'),
        exitCode: 0,
      );
    }
    List<String> words;
    try {
      words = shellWords(command);
    } on FormatException {
      words = const [];
    }
    if (words.isEmpty || words.first != fakeHerdrPath) {
      // The login-shell form of a read (`herdr api snapshot`), or junk.
      if (command.contains('herdr api snapshot') && serverRunning) {
        return _snapshot();
      }
      return const SshRemoteResult(
        stdout: '',
        stderr: 'sh: 1: herdr: not found',
        exitCode: 127,
      );
    }
    if (!serverRunning) {
      return SshRemoteResult(
        stdout: '',
        stderr: _fixture('server_not_running_0_9_5.json'),
        exitCode: 1,
      );
    }
    final verb = '${words[1]} ${words[2]}';
    final pane = words.length > 3 ? words[3] : '';
    switch (verb) {
      case 'api snapshot':
        return _snapshot();
      case 'agent read':
        final text = screens[pane] ?? _fixture('agent_read_ansi_synthetic.txt');
        return SshRemoteResult(stdout: text, exitCode: 0);
      case 'pane read':
        return SshRemoteResult(
          stdout:
              paneScreens[pane] ??
              _fixture('pane_read_not_found_shell_0_9_5.txt'),
          exitCode: 0,
        );
      case 'session list':
        return SshRemoteResult(
          stdout: sessionListJson ?? _fixture('session_list_0_9_5.json'),
          exitCode: 0,
        );
      case 'agent prompt':
        final agent = _agent(pane);
        if (agent == null) return _notFound();
        if (agent.status == HerdrAgentStatus.blocked) {
          return SshRemoteResult(
            stdout: '',
            stderr: _fixture('agent_blocked_synthetic.json'),
            exitCode: 1,
          );
        }
        return const SshRemoteResult(stdout: '{"result":{}}', exitCode: 0);
      case 'agent send-keys':
        if (sendKeysDelay > Duration.zero) {
          await Future<void>.delayed(sendKeysDelay);
        }
        if (_agent(pane) == null) return _notFound();
        if (sendKeysFails) {
          return const SshRemoteResult(
            stdout: '',
            stderr:
                '{"id":"cli:agent:send-keys","error":{"code":"invalid_key",'
                '"message":"invalid key"}}',
            exitCode: 1,
          );
        }
        return const SshRemoteResult(stdout: '{"result":{}}', exitCode: 0);
      case 'workspace create':
        final cwd = words[words.indexOf('--cwd') + 1];
        final label = words[words.indexOf('--label') + 1];
        final n = 4 + created.length;
        final made = FakeCreated('w$n', 'w$n:p1', label, cwd);
        created.add(made);
        return SshRemoteResult(
          stdout: _fixture('workspace_create_0_9_5.json')
              .replaceAll('w1:p1', made.paneId)
              .replaceAll('w1:t1', 'w$n:t1')
              .replaceAll('"w1"', '"w$n"')
              .replaceAll('hp-test', label)
              .replaceAll('"/tmp"', jsonEncode(cwd)),
          exitCode: 0,
        );
      case 'agent start':
        return _start(words);
    }
    return const SshRemoteResult(stdout: '', exitCode: 2);
  }

  /// How long `agent send-keys` takes to answer, and whether it refuses
  /// (`invalid_key`): for the states of an answer sent by number.
  Duration sendKeysDelay = Duration.zero;
  bool sendKeysFails = false;

  /// The keys sent so far, per `agent send-keys` call (words after the pane).
  List<List<String>> get keysSent => [
    for (final call in herdrCalls)
      if (shellWords(call)[2] == 'send-keys') shellWords(call).sublist(4),
  ];

  /// How many `agent start` calls answer «pane busy» before one works.
  int startFailures = 0;

  Future<SshRemoteResult> _start(List<String> words) async {
    startCalls++;
    final name = words[3];
    final kind = words[5];
    final pane = words[7];
    if (startFailures > 0) {
      startFailures--;
      return SshRemoteResult(
        stdout: '',
        stderr: _fixture('agent_start_pane_busy_0_9_5.json'),
        exitCode: 1,
      );
    }
    final appear = agentAppearsAfter;
    if (appear != null) {
      void add() {
        final made = created.where((c) => c.paneId == pane);
        if (agents.any((a) => a.paneId == pane)) return;
        agents.add(
          FakeAgent(
            pane,
            kind,
            startError == 'agent_start_not_ready_0_9_5.json'
                ? HerdrAgentStatus.blocked
                : HerdrAgentStatus.idle,
            name: name,
            cwd: made.isEmpty ? '/home/demo' : made.first.cwd,
            workspace: made.isEmpty ? 'ws' : made.first.label,
            workspaceId: made.isEmpty ? null : made.first.workspaceId,
          ),
        );
      }

      if (appear == Duration.zero) {
        add();
      } else {
        Timer(appear, add);
      }
    }
    if (startCommandAfter > Duration.zero) {
      await Future<void>.delayed(startCommandAfter);
    }
    final error = startError;
    if (error != null) {
      return SshRemoteResult(stdout: '', stderr: _fixture(error), exitCode: 1);
    }
    return SshRemoteResult(
      stdout: _fixture('agent_started_0_9_5.json'),
      exitCode: 0,
    );
  }

  FakeAgent? _agent(String pane) {
    for (final agent in agents) {
      if (agent.paneId == pane) return agent;
    }
    return null;
  }

  SshRemoteResult _notFound() => SshRemoteResult(
    stdout: '',
    stderr: _fixture('agent_not_found_0_9_5.json'),
    exitCode: 1,
  );

  SshRemoteResult _snapshot() => SshRemoteResult(
    stdout: jsonEncode({'id': 'cli:api:snapshot', 'result': snapshotJson()}),
    exitCode: 0,
  );

  /// Herdr's roll-up of a workspace: what needs you most.
  String _rollup(List<HerdrAgentStatus> statuses) {
    for (final status in [
      HerdrAgentStatus.blocked,
      HerdrAgentStatus.working,
      HerdrAgentStatus.done,
      HerdrAgentStatus.idle,
    ]) {
      if (statuses.contains(status)) return status.name;
    }
    return 'unknown';
  }

  /// Workspace focused in the snapshot (the first agent's when null).
  String? focusedWorkspace;

  /// `result` of `api snapshot`, in the real 0.9.5 shape, for [agents], the
  /// workspaces `workspace create` made and one plain shell pane.
  Map<String, Object?> snapshotJson() {
    final ids = <String, String>{};
    var next = 0;
    for (final a in agents) {
      if (ids.containsKey(a.workspace)) continue;
      ids[a.workspace] = a.workspaceId ?? 'w${++next}';
    }
    String wid(FakeAgent a) => ids[a.workspace]!;
    Map<String, Object?> pane(FakeAgent a) => {
      'agent': a.agent,
      'agent_status': a.status.name,
      'cwd': a.cwd,
      'focused': false,
      'foreground_cwd': a.cwd,
      'pane_id': a.paneId,
      'revision': 0,
      'tab_id': '${wid(a)}:t1',
      'terminal_id': 'term_${a.paneId.replaceAll(':', '')}',
      'workspace_id': wid(a),
    };
    final shells = [
      for (final c in created)
        if (!agents.any((a) => a.paneId == c.paneId)) c,
    ];
    final labels = ids.keys.toList();
    final focus = focusedWorkspace;
    return {
      'snapshot': {
        'agents': [
          for (final a in agents)
            {
              ...pane(a),
              'state_change_seq': a.seq,
              if (a.name != null) 'name': a.name,
              if (a.launchPending) 'launch_pending': true,
            },
        ],
        'panes': [
          for (final a in agents) pane(a),
          for (final c in shells)
            {
              'agent_status': 'unknown',
              'cwd': c.cwd,
              'focused': false,
              'pane_id': c.paneId,
              'workspace_id': c.workspaceId,
              'tab_id': '${c.workspaceId}:t1',
            },
          {
            'agent_status': 'unknown',
            'cwd': '/home/demo',
            'focused': false,
            'pane_id': 'w9:p1',
            'workspace_id': 'w9',
            'tab_id': 'w9:t1',
          },
        ],
        'workspaces': [
          for (var i = 0; i < labels.length; i++)
            {
              'workspace_id': ids[labels[i]],
              'label': labels[i],
              'number': i + 1,
              'focused': ids[labels[i]] == focus,
              'agent_status': _rollup([
                for (final a in agents)
                  if (a.workspace == labels[i]) a.status,
              ]),
            },
          for (final c in shells)
            {
              'workspace_id': c.workspaceId,
              'label': c.label,
              'number': 4,
              'focused': false,
              'agent_status': 'unknown',
            },
          {
            'workspace_id': 'w9',
            'label': 'shell',
            'number': 9,
            'focused': false,
            'agent_status': 'unknown',
          },
        ],
        'focused_pane_id': agents.isEmpty ? 'w9:p1' : agents.first.paneId,
        'protocol': 22,
        'version': '0.9.5',
      },
    };
  }
}

/// The words a POSIX shell would read from [line] when every word is
/// single-quoted the way the app quotes them (`'` as `'\''`). Throws on
/// anything else a shell would act on (an unquoted `$`, `;`, backtick…), so
/// a test that parses a command line also proves it has no such thing.
List<String> shellWords(String line) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == "'") {
      final end = line.indexOf("'", i + 1);
      if (end < 0) throw FormatException('unterminated quote in: $line');
      word.write(line.substring(i + 1, end));
      inWord = true;
      i = end + 1;
    } else if (c == r'\') {
      if (i + 1 >= line.length) throw FormatException('trailing backslash');
      word.write(line[i + 1]);
      inWord = true;
      i += 2;
    } else if (c == ' ') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
      i++;
    } else {
      throw FormatException('unquoted character "$c" in: $line');
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}
