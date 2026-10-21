// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/mobile_oauth.dart';
import 'island.dart';

/// The "browser session" wording and the Sign in action apply only behind the
/// simple-connect flag, and only when the connection holds a native (browser
/// login) session, not for a manual token or a password.
bool dashboardBrowserSession({
  required bool simpleConnect,
  required String? storedSession,
}) =>
    simpleConnect &&
    storedSession?.startsWith(MobileOAuthSession.prefix) == true;

/// The chat's "the Dashboard wants you to sign in" notice. With a browser
/// session ([browserSession]) it says plainly that the session expired and
/// offers the sign-in right there; the sign-in opens over the chat, so the
/// draft and the transcript stay where they are.
IslandEvent dashboardSignInEvent({
  required Strings str,
  required bool browserSession,
  required VoidCallback? onSignIn,
  VoidCallback? onRecover,
  required VoidCallback onDismissed,
}) => IslandEvent(
  id: 'dashboard-sign-in',
  key: const ValueKey('chat-dashboard-auth-required'),
  tone: IslandTone.warning,
  icon: Icons.lock_outline_rounded,
  sticky: true,
  line: browserSession ? str.s2SessionExpiredLine : str.islandSignIn,
  more: browserSession
      ? str.s2SessionExpiredBody
      : str.chaDesktopAuthRequiredBanner,
  action: browserSession
      ? IslandAction(
          key: const ValueKey('chat-dashboard-sign-in-action'),
          label: str.s2SessionExpiredSignIn,
          closes: false,
          onPressed: onSignIn,
        )
      : null,
  secondary: browserSession && onRecover != null
      ? IslandAction(
          key: const ValueKey('chat-dashboard-recover-action'),
          label: str.dashboardSetupForgotPassword,
          closes: false,
          onPressed: onRecover,
        )
      : null,
  onDismissed: onDismissed,
);
