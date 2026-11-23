import 'package:flutter/material.dart';

import '../../main.dart';
import '../services/ssh_manager.dart';
import '../services/ssh_profile_presence.dart';
import '../services/ssh_session_service.dart' show SshSessionPhase;
import '../widgets/ssh_host_key_dialog.dart';
import 'browser_loopback_reach.dart';
import 'open_web_link.dart';

/// Opens a web address tapped in an SSH terminal of [connectionId] in the
/// in-app browser. With SSH set up ([config] answers), a loopback address is
/// the SERVER's and is reached through a forward on that profile; without
/// it the plain in-app browser opens. Every terminal the app pushes uses
/// this, so a `localhost` link means the same thing in all of them.
void openSshTerminalLink(
  BuildContext context, {
  required String connectionId,
  required Uri uri,
  required SshConfig? Function() config,
}) {
  final app = context.findAncestorStateOfType<HermesAppState>();
  if (app == null || config() == null) {
    openWebLinkInApp(context, uri);
    return;
  }
  openWebLinkInApp(
    context,
    uri,
    loopbackReach: () => BrowserLoopbackReach.overSsh(
      live: () {
        final session = app.sshSessions.of(connectionId);
        return session?.phase.value == SshSessionPhase.ready
            ? session?.client
            : null;
      },
      connect: () => app.sshManager.connect(
        connectionId,
        onHostKey: (prompt) async =>
            context.mounted && await showSshHostKeyDialog(context, prompt),
      ),
    ),
    loopbackReachScope: () {
      final current = config();
      return current == null
          ? null
          : '$connectionId|${current.target}|${current.method.name}|'
                '${SshProfilePresence.instance.revision.value}';
    },
    loopbackReachChanges: SshProfilePresence.instance.revision,
  );
}
