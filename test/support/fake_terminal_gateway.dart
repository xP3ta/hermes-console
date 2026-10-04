import 'dart:async';

import 'package:hermes_android/core/models/terminal_exec.dart';

/// Scriptable [HermesTerminalGateway]: records every command, answers from
/// [handler], and can hold an answer open with [hold].
class FakeTerminalGateway implements HermesTerminalGateway {
  FakeTerminalGateway({this.available = true});

  bool available;
  final List<({String command, String profile})> commands = [];
  final List<({String session, int cols})> resizes = [];
  List<AgentProcessSeed> seeds = const [];
  int seedReads = 0;

  Future<ShellExecResult> Function(String command, String profile)? handler;
  Completer<ShellExecResult>? hold;

  @override
  bool get shellExecAvailable => available;

  @override
  Future<ShellExecResult> shellExec(String command, {required String profile}) {
    commands.add((command: command, profile: profile));
    if (command.isEmpty) {
      return Future.error(const ShellExecRefusal(4004, 'empty command'));
    }
    final pending = hold;
    if (pending != null) return pending.future;
    final h = handler;
    if (h != null) return h(command, profile);
    return Future.value(
      const ShellExecResult(stdout: 'ok\n', stderr: '', exitCode: 0),
    );
  }

  /// Commands that actually reached the server (the empty probe excluded).
  List<String> get ran => [
    for (final c in commands)
      if (c.command.isNotEmpty) c.command,
  ];

  @override
  Future<void> terminalResize(String runtimeSessionId, int cols) async {
    resizes.add((session: runtimeSessionId, cols: cols));
  }

  @override
  Future<List<AgentProcessSeed>> agentProcessSeeds(
    String runtimeSessionId, {
    String? profile,
  }) async {
    seedReads += 1;
    return seeds;
  }
}
