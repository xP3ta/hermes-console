// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../services/legacy_bridge_retirement.dart';
import '../theme/app_theme.dart';
import '../widgets/legacy_bridge_removal_help.dart';
import '../widgets/hermes_notice.dart';
import 'dashboard_sign_in.dart';

typedef DashboardSignIn =
    Future<bool> Function(
      NavigatorState navigator,
      ConnectionManager manager,
      SavedConnection connection,
    );

/// What someone who updates from a bridge-era install is told, once.
///
/// The work ([LegacyBridgeRetirement]) is silent. Afterwards, at most one
/// notice per launch goes through the app's notice lane, never a screen:
/// "one step left" for an instance whose Dashboard has no working sign-in;
/// or, when the phone already talks to Hermes directly, "you no longer need
/// the bridge" with how to remove it from the computer.
abstract final class LegacyBridgeNotices {
  /// Runs the retirement and, when there is something to say, says it as
  /// soon as the app is on screen ([quiet] false: unlocked, past the
  /// first-run screens). If that moment does not come in this launch, the
  /// notice waits for the next one.
  static Future<void> start({
    required ConnectionManager connManager,
    required NavigatorState? Function() navigator,
    required bool Function() quiet,
    LegacyBridgeRetirement? retirement,
    DashboardSignIn signIn = signInToDashboard,
    Duration retryEvery = const Duration(seconds: 2),
    int maxWaits = 90,
  }) async {
    final work = retirement ?? LegacyBridgeRetirement(prefs: connManager.prefs);
    try {
      await work.run(connManager.getConnections());
    } catch (error) {
      debugPrint('[legacy-bridge] retirement skipped (${error.runtimeType})');
      return;
    }
    if (work.legacyInstall != true) return;
    for (var waited = 0; waited < maxWaits; waited++) {
      final nav = navigator();
      if (nav != null && nav.mounted && !quiet()) {
        present(nav, connManager, work, signIn: signIn);
        return;
      }
      await Future<void>.delayed(retryEvery);
    }
  }

  /// Posts the one notice that applies now, if any, and returns its handle.
  @visibleForTesting
  static HermesNoticeHandle? present(
    NavigatorState nav,
    ConnectionManager manager,
    LegacyBridgeRetirement work, {
    DashboardSignIn signIn = signInToDashboard,
  }) {
    final notices = HermesNotice.ofNavigator(nav);
    if (notices == null) return null;
    final s = Strings.of(nav.context);
    // Said in the app's own accent: it waits for an answer, it is no alarm.
    final accent = Theme.of(nav.context).hermes.accent;
    final connections = manager.getConnections();
    final waiting = work.signInCandidate(
      connections,
      manager.activeConnectionId.value,
    );
    if (waiting != null) {
      var acted = false;
      return notices.show(
        id: 'legacy-bridge-sign-in-${waiting.id}',
        noticeKey: const ValueKey('legacy-bridge-sign-in-notice'),
        icon: Icons.login_rounded,
        tint: accent,
        title: s.legacyBridgeStepTitle,
        message: connections.length > 1
            ? s.legacyBridgeStepBodyNamed(waiting.label)
            : s.legacyBridgeStepBody,
        // It waits for the user, without blocking anything: routine feedback
        // passes over it and it comes back.
        priority: HermesNoticePriority.high,
        sticky: true,
        showDismiss: true,
        action: HermesNoticeAction(
          label: s.legacyBridgeStepAction,
          onPressed: () {
            acted = true;
            unawaited(() async {
              var solved = false;
              try {
                solved = await signIn(nav, manager, waiting);
              } catch (error) {
                debugPrint(
                  '[legacy-bridge] sign-in not completed (${error.runtimeType})',
                );
              }
              await work.markSignInNoticeDone(waiting.id, solved: solved);
            }());
          },
        ),
        onClosed: () {
          if (!acted) unawaited(work.markSignInNoticeDone(waiting.id));
        },
      );
    }
    if (work.shouldOfferRemoval(connections)) {
      var acted = false;
      return notices.show(
        id: 'legacy-bridge-removal',
        noticeKey: const ValueKey('legacy-bridge-removal-notice'),
        icon: Icons.check_circle_outline_rounded,
        tint: accent,
        title: s.bridgeGoneTitle,
        message: s.bridgeGoneBody,
        // Two answers, both the user's: see how, or not now (the dismiss).
        priority: HermesNoticePriority.high,
        sticky: true,
        showDismiss: true,
        dismissLabel: s.bridgeGoneLater,
        action: HermesNoticeAction(
          label: s.bridgeGoneAction,
          onPressed: () {
            acted = true;
            unawaited(work.markRemovalNoticeDone());
            final context = nav.overlay?.context;
            if (context != null && context.mounted) {
              unawaited(showBridgeRemovalHelp(context));
            }
          },
        ),
        onClosed: () {
          if (!acted) unawaited(work.markRemovalNoticeDone());
        },
      );
    }
    return null;
  }
}
