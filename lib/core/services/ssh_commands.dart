import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un comando rápido guardado: una etiqueta legible y el comando a ejecutar.
/// Es la pieza de "automatización" — atajos de un toque en la terminal.
class SshQuickCommand {
  final String label;
  final String command;

  const SshQuickCommand(this.label, this.command);

  Map<String, dynamic> toJson() => {'label': label, 'command': command};

  factory SshQuickCommand.fromJson(Map<String, dynamic> j) => SshQuickCommand(
        (j['label'] ?? '').toString(),
        (j['command'] ?? '').toString(),
      );
}

/// Persiste los comandos rápidos por instancia en SharedPreferences (no son
/// secretos). Si el usuario no ha definido ninguno, ofrece una lista de
/// arranque con comandos genéricos y seguros (solo lectura).
class SshCommandsStore {
  final SharedPreferences _prefs;

  SshCommandsStore(this._prefs);

  static String _key(String connectionId) => 'ssh_cmds_$connectionId';

  /// Comandos por defecto: diagnóstico inocuo, sin nada destructivo.
  static const List<SshQuickCommand> defaults = [
    SshQuickCommand('Uptime', 'uptime'),
    SshQuickCommand('Disco', 'df -h'),
    SshQuickCommand('Memoria', 'free -h'),
    SshQuickCommand('Top CPU', 'ps aux --sort=-%cpu | head -n 12'),
    SshQuickCommand(
      'Estado Hermes',
      'systemctl --user status hermes-dashboard hermes-gateway --no-pager || true',
    ),
  ];

  List<SshQuickCommand> load(String connectionId) {
    final raw = _prefs.getString(_key(connectionId));
    if (raw == null) return List.of(defaults);
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => SshQuickCommand.fromJson(e as Map<String, dynamic>))
          .where((c) => c.label.isNotEmpty && c.command.isNotEmpty)
          .toList();
      return list;
    } catch (e) {
      debugPrint('[ssh] excepción silenciada (se continúa sin propagar): $e');
      return List.of(defaults);
    }
  }

  Future<void> save(String connectionId, List<SshQuickCommand> cmds) async {
    await _prefs.setString(
      _key(connectionId),
      jsonEncode(cmds.map((c) => c.toJson()).toList()),
    );
  }

  /// Restaura la lista por defecto (borra la personalización).
  Future<void> reset(String connectionId) async {
    await _prefs.remove(_key(connectionId));
  }
}
