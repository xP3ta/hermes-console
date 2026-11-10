// The read-only look for code agents running without Herdr.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/agent_processes.dart';
import 'package:hermes_android/core/services/herdr_status.dart';

void main() {
  test('the command is one constant, read-only, with no arguments to fill', () {
    expect(sshAgentProcessesCommand, 'ps -eo comm=');
    expect(agentProcessNames, [
      'claude',
      'codex',
      'opencode',
      'gemini',
      'pi',
      'copilot',
    ]);
  });

  test('parse: exact names only, by last path segment, counted', () {
    final found = parseAgentProcesses(
      'bash\nclaude\n/usr/local/bin/Codex\nclaude\nclaude-helper\npicom\n'
      'opencode\n  gemini  \nnode\n\n',
    );
    expect(found, {'claude': 2, 'codex': 1, 'opencode': 1, 'gemini': 1});
    expect(found.keys.toList(), ['claude', 'codex', 'opencode', 'gemini']);
    expect(parseAgentProcesses(''), isEmpty);
    expect(parseAgentProcesses('pi\ncopilot\n'), {'pi': 1, 'copilot': 1});
  });

  test('parse: reads a bounded number of lines', () {
    final text = '${List.filled(50, 'bash').join('\n')}\nclaude\n';
    expect(parseAgentProcesses(text, limit: 10), isEmpty);
    expect(parseAgentProcesses(text), {'claude': 1});
  });

  test(
    'the scanner runs once, keeps the answer, and reset allows another',
    () async {
      final sent = <String>[];
      final scanner = AgentProcessScanner(
        run: (command) async {
          sent.add(command);
          return const SshRemoteResult(stdout: 'claude\n', exitCode: 0);
        },
      );
      addTearDown(scanner.dispose);
      await scanner.scan();
      await scanner.scan();
      expect(sent, [sshAgentProcessesCommand]);
      expect(scanner.found.value, {'claude': 1});
      scanner.reset();
      expect(scanner.found.value, isEmpty);
      await scanner.scan();
      expect(sent.length, 2);
    },
  );

  test('a failing or non-zero read shows nothing, never throws', () async {
    final failing = AgentProcessScanner(
      run: (_) async => throw StateError('x'),
    );
    addTearDown(failing.dispose);
    await failing.scan();
    expect(failing.found.value, isEmpty);

    final refused = AgentProcessScanner(
      run: (_) async =>
          const SshRemoteResult(stdout: 'claude\n', exitCode: 127),
    );
    addTearDown(refused.dispose);
    await refused.scan();
    expect(refused.found.value, isEmpty);
  });
}
