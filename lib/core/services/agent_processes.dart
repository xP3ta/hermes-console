// Agentes de código en marcha en el servidor SIN Herdr (1.4.0): una consulta
// de solo lectura de la tabla de procesos, con una orden constante (nada del
// usuario entra en ella), en un canal `execute` aparte, con los límites de
// tiempo y tamaño de SshSessionService.runRemote. Solo sirve para decir «hay
// agentes fuera de Herdr: ábrelos con Herdr para controlarlos»; la app no
// puede leerlos ni escribirles.
//
// Límite conocido: reconoce el nombre del ejecutable. Un agente que corre
// como script de Node o Python aparece como `node` o `python` y no se ve.
import 'package:flutter/foundation.dart';

import 'herdr_status.dart';

/// Read-only list of executable names, one per line. Constant on purpose.
const String sshAgentProcessesCommand = 'ps -eo comm=';

/// Executable names counted as a code agent. An exact-match whitelist.
const List<String> agentProcessNames = [
  'claude',
  'codex',
  'opencode',
  'gemini',
  'pi',
  'copilot',
];

/// The agents in [output] (a `ps -eo comm=` listing), by name in
/// [agentProcessNames] order, with how many processes each has. Names are
/// compared by their last path segment (macOS prints full paths), lower case.
/// Only the first [limit] lines are read.
Map<String, int> parseAgentProcesses(String output, {int limit = 20000}) {
  final counts = <String, int>{};
  var seen = 0;
  for (final line in output.split('\n')) {
    if (++seen > limit) break;
    final text = line.trim();
    if (text.isEmpty) continue;
    final name = text.split('/').last.toLowerCase();
    if (agentProcessNames.contains(name)) {
      counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  return {
    for (final name in agentProcessNames)
      if (counts.containsKey(name)) name: counts[name]!,
  };
}

/// Runs the scan at most once until [reset]; [found] holds what it saw
/// (empty when nothing, or when the server did not answer).
class AgentProcessScanner {
  AgentProcessScanner({required this.run});

  final SshRemoteRunner run;
  final ValueNotifier<Map<String, int>> found = ValueNotifier<Map<String, int>>(
    const {},
  );

  bool _scanned = false;
  bool _scanning = false;
  bool _disposed = false;

  Future<void> scan() async {
    if (_scanned || _scanning || _disposed) return;
    _scanning = true;
    try {
      final result = await run(sshAgentProcessesCommand);
      if (_disposed) return;
      found.value = result.exitCode == 0
          ? parseAgentProcesses(result.stdout)
          : const {};
    } catch (e) {
      debugPrint('[agent-processes] scan failed (${e.runtimeType})');
      if (!_disposed) found.value = const {};
    } finally {
      _scanned = true;
      _scanning = false;
    }
  }

  /// Forget the last scan (Herdr is there now, or the user asked again).
  void reset() {
    _scanned = false;
    if (found.value.isNotEmpty) found.value = const {};
  }

  void dispose() {
    _disposed = true;
    found.dispose();
  }
}
