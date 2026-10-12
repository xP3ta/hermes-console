// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:async';

import '../connection_manager.dart';
import '../connection_setup_activity.dart';

/// When the app asks for notifications.
///
/// Not when it opens: a first launch has nothing to notify about. The ask
/// comes the first time there is a Hermes to hear from (the first connection
/// saved, or one that was already there) while the app is on screen. It is
/// the system dialog alone, once; the request remembers that it asked.
class NotificationPermissionMoment {
  NotificationPermissionMoment({
    required this.connManager,
    required this.request,
    required this.quiet,
  }) {
    connManager.connectionsRevision.addListener(check);
    ConnectionSetupActivity.instance.addListener(check);
  }

  final ConnectionManager connManager;

  /// The one ask. It remembers that it asked.
  final Future<void> Function() request;

  /// True while nothing should be asked (the first-run screens are up).
  final bool Function() quiet;
  bool _disposed = false;

  /// Asks if this is the moment: a connection exists and nothing forbids it
  /// (the first-run screens are still up). Safe to call any time.
  void check() {
    if (_disposed || quiet() || ConnectionSetupActivity.instance.active) {
      return;
    }
    if (connManager.getConnections().isEmpty) return;
    unawaited(request());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    connManager.connectionsRevision.removeListener(check);
    ConnectionSetupActivity.instance.removeListener(check);
  }
}
