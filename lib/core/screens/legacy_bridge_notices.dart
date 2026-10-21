// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../services/gateway_era_notice.dart';
import '../services/legacy_bridge_retirement.dart';
import '../theme/app_theme.dart';
import '../widgets/legacy_bridge_removal_help.dart';
import '../widgets/hermes_notice.dart';
import 'dashboard_sign_in.dart';
import 'onboarding/manual_setup_page.dart';

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
    GatewayEraNotice? gatewayEra,
    DashboardSignIn signIn = signInToDashboard,
    Duration retryEvery = const Duration(seconds: 2),
    int maxWaits = 90,
  }) async {
    final era = gatewayEra ?? GatewayEraNotice(prefs: connManager.prefs);
    try {
      await era.snapshotIfNeeded(connManager.getConnections());
    } catch (error) {
      debugPrint('[gateway-era] snapshot skipped (${error.runtimeType})');
    }
    final work = retirement ?? LegacyBridgeRetirement(prefs: connManager.prefs);
    try {
      await work.run(connManager.getConnections());
    } catch (error) {
      debugPrint('[legacy-bridge] retirement skipped (${error.runtimeType})');
      return;
    }
    if (work.legacyInstall != true &&
        !era.hasPending(connManager.getConnections())) {
      return;
    }
    for (var waited = 0; waited < maxWaits; waited++) {
      final nav = navigator();
      if (nav != null && nav.mounted && !quiet()) {
        // One notice per launch: the bridge's first, then the Gateway era's.
        if (present(nav, connManager, work, signIn: signIn) == null) {
          await presentGatewayEra(
            nav,
            connManager,
            era,
            resolved: {
              ...work.signInNoticeDone,
              for (final e in work.access.entries)
                if (e.value == DashboardAccess.ready) e.key,
            },
            signIn: signIn,
          );
        }
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

  /// The Gateway-era notice: at most one, after probing one connection.
  @visibleForTesting
  static Future<HermesNoticeHandle?> presentGatewayEra(
    NavigatorState nav,
    ConnectionManager manager,
    GatewayEraNotice era, {
    Set<String> resolved = const {},
    DashboardSignIn signIn = signInToDashboard,
  }) async {
    final notices = HermesNotice.ofNavigator(nav);
    final connections = manager.getConnections();
    final found = notices == null
        ? null
        : await era.candidate(
            connections,
            manager.activeConnectionId.value,
            resolved: resolved,
          );
    if (notices == null || found == null || !nav.mounted) return null;
    final c = found.connection;
    final s = Strings.of(nav.context);
    final signInOnly = found.access == DashboardAccess.needsSignIn;
    void enter() =>
        unawaited(signIn(nav, manager, c).then((_) {}, onError: (Object _) {}));
    void done() => unawaited(era.markDone(c.id));
    return notices.show(
      id: 'gateway-era-${c.id}',
      noticeKey: const ValueKey('gateway-era-notice'),
      icon: Icons.login_rounded,
      tint: Theme.of(nav.context).hermes.accent,
      title: signInOnly ? s.legacyBridgeStepTitle : s.gatewayEraTitle,
      message: connections.length > 1 && signInOnly
          ? s.legacyBridgeStepBodyNamed(c.label)
          : (signInOnly ? s.legacyBridgeStepBody : s.leg3EraBody),
      priority: HermesNoticePriority.high,
      sticky: true,
      showDismiss: true,
      action: HermesNoticeAction(
        label: signInOnly ? s.legacyBridgeStepAction : s.gatewayEraAction,
        onPressed: () {
          done();
          if (signInOnly) return enter();
          unawaited(
            nav.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ManualSetupPage(connManager: manager),
              ),
            ),
          );
        },
      ),
      onClosed: done,
    );
  }
}
