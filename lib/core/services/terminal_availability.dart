import 'package:flutter/foundation.dart';

import '../models/connection.dart';

/// Whether the entries that open the terminal page are offered for a
/// connection. A server that answered -32601 to `shell.exec` stays hidden
/// until the app restarts; a read-only connection never offers it.
abstract final class TerminalAvailability {
  static final Set<String> _unsupported = {};

  static bool offered(SavedConnection connection) =>
      !connection.readOnly && !_unsupported.contains(connection.id);

  static void markUnsupported(String connectionId) =>
      _unsupported.add(connectionId);

  @visibleForTesting
  static void resetForTesting() => _unsupported.clear();
}
