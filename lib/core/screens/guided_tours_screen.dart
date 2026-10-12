import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../guide/guided_tour.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart';
import 'chat_screen.dart';
import 'mission_control_screen.dart';

/// Ajustes › Recorrido guiado: the one place every tour starts again from.
/// Each tour opens its own screen first (Home, a new chat, the Bots home)
/// and then runs there.
class GuidedToursScreen extends StatelessWidget {
  final SavedConnection? connection;
  final ConnectionManager? connManager;
  final GuideController? controller;

  const GuidedToursScreen({
    this.connection,
    this.connManager,
    this.controller,
    super.key,
  });

  /// Replaces the chat and Bots screens a tour opens, in widget tests.
  @visibleForTesting
  static WidgetBuilder? debugChatScreen;
  @visibleForTesting
  static WidgetBuilder? debugBotsScreen;

  GuideController get _c => controller ?? GuideController.instance;

  void _run(BuildContext context, GuideTourId tour) {
    final navigator = Navigator.of(context);
    final strings = Strings.of(context);
    navigator.popUntil((route) => route.isFirst);
    switch (tour) {
      case GuideTourId.general:
        break;
      case GuideTourId.chat:
        final conn = connection;
        final builder =
            debugChatScreen ??
            (conn == null
                ? null
                : (_) => ChatScreen(
                    connection: conn,
                    session: Session(
                      id: GatewayChatClient.generateSessionId(),
                      title: strings.drawerNewChat,
                      model: 'hermes-agent',
                      source: 'mobile',
                      messageCount: 0,
                      isActive: true,
                      preview: '',
                      startedAt:
                          DateTime.now().millisecondsSinceEpoch.toDouble() /
                          1000,
                    ),
                  ));
        if (builder == null) return;
        unawaited(navigator.push(MaterialPageRoute<void>(builder: builder)));
      case GuideTourId.bots:
        final conn = connection;
        final manager = connManager;
        final builder =
            debugBotsScreen ??
            (conn == null || manager == null
                ? null
                : (_) => MissionControlScreen(
                    connection: conn,
                    connManager: manager,
                  ));
        if (builder == null) return;
        unawaited(navigator.push(MaterialPageRoute<void>(builder: builder)));
    }
    _c.start(tour);
  }

  @override
  Widget build(BuildContext context) {
    unawaited(_c.ensureLoaded());
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final hasServer = connection != null;
    final rows = <(GuideTourId, IconData, String, String, bool)>[
      (
        GuideTourId.general,
        Icons.home_outlined,
        strings.gt1215TourGeneral,
        strings.gt1215TourGeneralSubtitle,
        true,
      ),
      (
        GuideTourId.chat,
        Icons.chat_bubble_outline_rounded,
        strings.gt1215TourChat,
        strings.gt1215TourChatSubtitle,
        hasServer || debugChatScreen != null,
      ),
      (
        GuideTourId.bots,
        Icons.smart_toy_outlined,
        strings.gt1215TourBots,
        strings.gt1215TourBotsSubtitle,
        (hasServer && connManager != null) || debugBotsScreen != null,
      ),
    ];
    return Scaffold(
      appBar: HermesAppBar(title: Text(strings.gt1215SettingsTitle)),
      body: ListenableBuilder(
        listenable: _c,
        builder: (context, _) => ListView(
          clipBehavior: hermesUnderHeader,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                strings.gt1215ListIntro,
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
            HermesGroup(
              children: [
                for (final (tour, icon, title, subtitle, enabled) in rows)
                  HermesNavRow(
                    key: ValueKey('guided-tour-${tour.name}'),
                    icon: icon,
                    title: _c.isDone(tour)
                        ? '$title · ${strings.gt1215TourDone}'
                        : title,
                    subtitle: enabled ? subtitle : strings.gt1215NeedsServer,
                    onTap: enabled
                        ? () => _run(context, tour)
                        : () =>
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(
                                  content: Text(strings.gt1215NeedsServer),
                                ),
                              ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
