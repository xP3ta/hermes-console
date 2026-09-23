import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/connection.dart';
import '../widgets/hermes_notice.dart';

/// Single gate for routes that only make sense after an instance is active.
///
/// Callers pass the nullable connection they already resolved for their shell.
/// The guard never fabricates a local/default connection and never probes the
/// network: an offline saved instance is still a valid configuration scope.
abstract final class InstanceRouteGuard {
  /// Returns the real active [SavedConnection], or reports the missing-instance
  /// reason and returns `null`.
  static SavedConnection? require(
    BuildContext context, {
    required SavedConnection? connection,
    VoidCallback? onBlocked,
  }) {
    if (connection != null) return connection;
    if (onBlocked != null) {
      onBlocked();
    } else {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).drawerNeedInstance)),
        kind: HermesNoticeKind.warning,
      );
    }
    return null;
  }

  /// Pushes [builder] only when [connection] is present.
  ///
  /// This is suitable for direct/deep-link adapters as well as ordinary button
  /// handlers. A blocked attempt completes with `null` without adding a route.
  static Future<T?> push<T>(
    BuildContext context, {
    required SavedConnection? connection,
    required Widget Function(SavedConnection connection) builder,
    VoidCallback? onBlocked,
  }) {
    final active = require(
      context,
      connection: connection,
      onBlocked: onBlocked,
    );
    if (active == null) return Future<T?>.value();
    return Navigator.of(
      context,
    ).push<T>(MaterialPageRoute<T>(builder: (_) => builder(active)));
  }
}
