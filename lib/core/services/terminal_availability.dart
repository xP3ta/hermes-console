import 'package:flutter/foundation.dart';

import '../models/connection.dart';
import '../models/terminal_exec.dart';

/// Whether the entries that open the terminal page are offered for a
/// connection. They stay hidden until the server has answered `shell.exec`
/// (even with its empty-command refusal, which proves the method exists);
/// a server that answered -32601 stays hidden until the app restarts, and a
/// read-only connection never offers it.
abstract final class TerminalAvailability {
  static final Set<String> _confirmed = {};
  static final Set<String> _unsupported = {};
  static final Set<String> _probing = {};

  /// Bumped whenever an answer changes what [offered] returns.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static bool offered(SavedConnection connection) =>
      !connection.readOnly &&
      _confirmed.contains(connection.id) &&
      !_unsupported.contains(connection.id);

  static void markConfirmed(String connectionId) {
    if (_confirmed.add(connectionId)) changes.value++;
  }

  static void markUnsupported(String connectionId) {
    if (_unsupported.add(connectionId)) changes.value++;
  }

  /// Asks once whether the server has `shell.exec`, with the empty command
  /// the server refuses with 4004 without running anything. A timeout, an
  /// authentication error or a dropped connection confirms nothing; the
  /// entries stay hidden and a later call may ask again.
  static Future<void> confirm(
    SavedConnection connection,
    HermesTerminalGateway gateway, {
    required String profile,
  }) async {
    final id = connection.id;
    if (connection.readOnly ||
        _confirmed.contains(id) ||
        _unsupported.contains(id) ||
        !_probing.add(id)) {
      return;
    }
    try {
      await gateway.shellExec('', profile: profile);
      markConfirmed(id);
    } on ShellExecRefusal {
      markConfirmed(id);
    } on ShellExecUnsupported {
      markUnsupported(id);
    } catch (_) {
      // Nothing learned.
    } finally {
      _probing.remove(id);
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _confirmed.clear();
    _unsupported.clear();
    _probing.clear();
  }
}
