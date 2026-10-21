import 'package:flutter/material.dart';

import '../../../main.dart' show HermesAppState;
import '../../config/flavor.dart';
import '../../services/connection_manager.dart';
import '../onboarding_screen.dart';

/// The one guided page for a connection that exists and does not reach its
/// Dashboard: the onboarding's own setup help (same command panel, same
/// camera, same v2 connection), opened on it. Scanning a code from the same
/// host replaces that connection instead of adding a second one.
class ManualSetupPage extends StatelessWidget {
  const ManualSetupPage({
    this.connManager,
    this.simpleConnectEnabled = kSimpleConnectEnabled,
    super.key,
  });

  /// Defaults to the app's own manager.
  final ConnectionManager? connManager;
  final bool simpleConnectEnabled;

  /// Tests that open the page from a screen with no app above it.
  @visibleForTesting
  static ConnectionManager? managerForTest;

  @override
  Widget build(BuildContext context) => OnboardingScreen(
    connManager:
        connManager ??
        context.findAncestorStateOfType<HermesAppState>()?.connManager ??
        managerForTest!,
    guided: true,
    playOpening: false,
    simpleConnectEnabled: simpleConnectEnabled,
    onDone: () => Navigator.of(context).popUntil((r) => r.isFirst),
  );
}
