/// Output of one `shell.exec` run. Held in memory by the terminal page only.
class ShellExecResult {
  const ShellExecResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int exitCode;

  static ShellExecResult? tryParse(Map<String, dynamic> json) {
    final stdout = json['stdout'];
    final stderr = json['stderr'];
    final code = json['code'];
    if (stdout is! String || stderr is! String || code is! int) return null;
    return ShellExecResult(stdout: stdout, stderr: stderr, exitCode: code);
  }
}

/// Any failure of a `shell.exec` call. Carries no server text and no command.
class ShellExecFailure implements Exception {
  const ShellExecFailure();

  @override
  String toString() => 'ShellExecFailure';
}

/// The server does not offer `shell.exec` (or the connection is read-only).
class ShellExecUnsupported extends ShellExecFailure {
  const ShellExecUnsupported();

  @override
  String toString() => 'ShellExecUnsupported';
}

/// The server answered with one of its own `shell.exec` errors (4004, 4005,
/// 5001, 5002, 5003). [message] is the server's text, shown verbatim.
class ShellExecRefusal extends ShellExecFailure {
  const ShellExecRefusal(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'ShellExecRefusal($code)';
}

/// One agent background process as listed by `process.list`.
class AgentProcessSeed {
  const AgentProcessSeed({
    required this.id,
    required this.command,
    required this.outputTail,
    required this.closed,
  });

  final String id;
  final String command;
  final String outputTail;
  final bool closed;

  static AgentProcessSeed? tryParse(Object? row) {
    if (row is! Map) return null;
    final id = row['session_id'];
    if (id is! String || id.isEmpty) return null;
    final command = row['command'];
    final tail = row['output_tail'];
    return AgentProcessSeed(
      id: id,
      command: command is String ? command : '',
      outputTail: tail is String ? tail : '',
      closed: row['status'] != 'running',
    );
  }
}

/// `agent.terminal.output` / `terminal.close` payload: the process and, for
/// output, the chunk. Null when the payload names no process.
({String processId, String chunk})? parseAgentTerminalEvent(
  Map<String, dynamic> payload,
) {
  final id = payload['process_id'];
  if (id is! String || id.isEmpty) return null;
  final chunk = payload['chunk'];
  return (processId: id, chunk: chunk is String ? chunk : '');
}

/// Server-side terminal: commands run through `shell.exec` on the server,
/// never on the phone.
abstract class HermesTerminalGateway {
  /// False once the server answered -32601, or on a read-only connection.
  bool get shellExecAvailable;

  Future<ShellExecResult> shellExec(String command, {required String profile});

  /// Records the client's column width server-side; failures are ignored.
  Future<void> terminalResize(String runtimeSessionId, int cols);

  /// One `process.list` read for the chat's runtime.
  Future<List<AgentProcessSeed>> agentProcessSeeds(
    String runtimeSessionId, {
    String? profile,
  });
}

/// Why a typed command was refused before reaching the server.
enum ShellInputProblem { empty, tooLong, controlCharacter }

const int kShellCommandMaxLength = 4096;

/// Trims [raw] and checks it. The command itself is never rewritten.
({String? command, ShellInputProblem? problem}) sanitizeShellCommand(
  String raw,
) {
  final command = raw.trim();
  if (command.isEmpty) return (command: null, problem: ShellInputProblem.empty);
  if (command.length > kShellCommandMaxLength) {
    return (command: null, problem: ShellInputProblem.tooLong);
  }
  for (final unit in command.codeUnits) {
    if ((unit < 0x20 && unit != 0x09) || unit == 0x7f) {
      return (command: null, problem: ShellInputProblem.controlCharacter);
    }
  }
  return (command: command, problem: null);
}
