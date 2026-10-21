// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_status.dart';
import 'island.dart';

/// The chat notice's line for a lost connection of [kind]. With
/// [simpleConnect] the "no server" case says it in plain words.
String? connectionIslandLine({
  required Strings str,
  required ConnectionStatusKind? kind,
  required bool simpleConnect,
}) => switch (kind) {
  ConnectionStatusKind.noServer =>
    simpleConnect ? str.walkIslandNoServerLine : str.connStatusNoServer,
  _ => null,
};

/// The notice's one action. «What to do» on the "no server" notice: the
/// official Dashboard command page, the same one the offline Home card opens
/// (behind [simpleConnect]). «Retry» while the link is merely reconnecting or
/// starting, and on the persistent notice: the user's own redial now, as
/// Desktop's foreground reconnect. Nothing for "no network" or sign-in: there
/// is nothing to press. The notice stays until the link is back.
IslandAction? connectionIslandAction({
  required Strings str,
  required ConnectionStatusKind? kind,
  required bool simpleConnect,
  required VoidCallback onOpenHelp,
  VoidCallback? onRetry,
}) {
  if (simpleConnect && kind == ConnectionStatusKind.noServer) {
    return IslandAction(
      key: const ValueKey('chat-connection-help-action'),
      label: str.walkIslandWhatToDo,
      closes: false,
      onPressed: onOpenHelp,
    );
  }
  final retryable = switch (kind) {
    null ||
    ConnectionStatusKind.reconnecting ||
    ConnectionStatusKind.starting => true,
    _ => false,
  };
  if (!retryable || onRetry == null) return null;
  return IslandAction(
    key: const ValueKey('chat-connection-retry-action'),
    label: str.commonRetry,
    closes: false,
    onPressed: onRetry,
  );
}
