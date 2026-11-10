import 'package:flutter/foundation.dart';

/// Whether the turn keep-alive (a short foreground service, see
/// `TurnKeepAliveController`) is holding the process right now.
///
/// A plain flag with no imports so the two background idlers can read it
/// without an import cycle: `ActiveChat`'s 30 s transport park and the app's
/// `_gatewayIdleTimer`. While it is true they wait another round instead of
/// closing the sockets the running turn streams on. Only the controller
/// writes it, and only after the platform confirmed the service started.
abstract final class TurnKeepAliveHold {
  /// Fires on every edge of the hold. conn-registry (REVISION-3 #3): a chat
  /// in the background follows it to redial a cut socket while the hold
  /// lasts, instead of waiting for the app to come back.
  static final ValueNotifier<bool> changes = ValueNotifier<bool>(false);

  static bool get held => changes.value;
  static set held(bool value) => changes.value = value;

  @visibleForTesting
  static void resetForTesting() => held = false;
}
