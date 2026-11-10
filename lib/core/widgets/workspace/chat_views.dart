// QA 9709, the owner's final windows: the chat's «Vistas» is a round button of
// its own in the header, and it is ONLY how the screen is shared. A tap
// opens a small vertical menu of circles with their names, «Chat ·
// Dividido · Trabajo», the one in use in the accent. No panels here: they
// are in Ajustes. Where nothing sits beside the chat (a phone, the Fold
// held upright) only «Chat» can be chosen, with one line that says why.
// Everything [ChatWorkspaceController] does stays as it was.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/hermes_design.dart'
    show
        HermesFloatingSurface,
        HermesScrim,
        hermesOriginOf,
        showHermesSurface;
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../floating_chat_header.dart';
import 'chat_workspace.dart';
import 'chat_workspace_host.dart';

/// A count on a panel of the popover (Git: changed files), and what a
/// screen reader says for it («4 cambios»).
@immutable
class ChatViewsBadge {
  const ChatViewsBadge({required this.count, required this.semanticLabel});

  final int count;
  final String semanticLabel;
}

/// Whether a panel chosen now opens over the chat (a phone, the open Fold
/// held upright) rather than beside it.
bool chatWorkspaceOpensOverChat(ChatWorkspaceController controller) =>
    controller.stacked || !controller.canSplit;

/// Whether the chat's «Vistas» shows as on: the workspace beside the chat.
bool chatWorkspaceShownBeside(ChatWorkspaceController controller) =>
    !chatWorkspaceOpensOverChat(controller) && controller.workspaceVisible;

/// The chat's «Vistas»: a round header button that opens the layout menu.
/// It shows when a panel is beside the chat (a soft accent face, the filled
/// icon); its name says what is on screen.
class ChatViewsButton extends StatelessWidget {
  const ChatViewsButton({
    required this.controller,
    required this.availableTabs,
    this.openTab,
    this.badges = const {},
    this.onUse,
    this.onPopover,
    super.key,
  });

  final ChatWorkspaceController controller;

  /// Told on every use (the chat re-reads what may change the panels:
  /// Git's status).
  final VoidCallback? onUse;

  /// Told just before the menu opens, with when it closes: it floats over a
  /// chat that stays on screen (the chat does not take it for a screen on
  /// top of it).
  final void Function(Future<void> closed)? onPopover;

  /// The panels this chat can open: «Dividido» and «Trabajo» open the last
  /// one used when none is open yet.
  final List<ChatWorkspaceTab> availableTabs;

  /// Kept for callers of the popover of before (the panels are Ajustes'
  /// now); not used by the menu.
  final ValueChanged<ChatWorkspaceTab>? openTab;
  final Map<ChatWorkspaceTab, ChatViewsBadge> badges;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final strings = Strings.of(context);
      return Builder(
        builder: (buttonContext) => FloatingHeaderButton(
          icon: Icons.view_sidebar_outlined,
          selectedIcon: Icons.view_sidebar,
          highlighted: chatWorkspaceShownBeside(controller),
          tooltip: chatWorkspaceViewsLabel(strings, controller),
          onPressed: () {
            onUse?.call();
            final closed = Completer<void>();
            onPopover?.call(closed.future);
            showChatWorkspaceViews(
              buttonContext,
              controller: controller,
              availableTabs: availableTabs,
            ).whenComplete(closed.complete).ignore();
          },
        ),
      );
    },
  );
}

/// the owner's «Vistas» menu, anchored to [context] (the button that opens it):
/// how the screen is shared, «Chat · Dividido · Trabajo». The controller
/// decides what fits and what makes way; this only asks it. A choice closes
/// the menu.
///
/// [openTab] and [badges] are no longer used (the panels are in Ajustes);
/// they stay so callers of before still build.
Future<void> showChatWorkspaceViews(
  BuildContext context, {
  required ChatWorkspaceController controller,
  required List<ChatWorkspaceTab> availableTabs,
  ValueChanged<ChatWorkspaceTab>? openTab,
  Map<ChatWorkspaceTab, ChatViewsBadge> badges = const {},
}) => showHermesSurface<void>(
  context: context,
  surfaceKey: const ValueKey('chat-workspace-views'),
  originRect: hermesOriginOf(context),
  maxWidth: _ViewsPanel.width,
  scrim: HermesScrim.menu,
  // A menu over the chat, not a page: closing it is not a return to the
  // chat, which would re-read it (gint72).
  coversPage: false,
  // the owner: windows with a little more depth.
  lifted: true,
  builder: (surfaceContext) => _ViewsPanel(
    controller: controller,
    availableTabs: availableTabs,
    onChosen: () => Navigator.of(surfaceContext).maybePop(),
  ),
);

/// The names of the views on screen, for «Vistas: lista, chat».
String chatWorkspaceViewsLabel(
  Strings strings,
  ChatWorkspaceController controller,
) => strings.cwsViewsState(
  [
    for (final view in controller.visibleViews)
      switch (view) {
        ChatWorkspaceView.list => strings.cwsViewList,
        ChatWorkspaceView.chat => strings.cwsViewChat,
        ChatWorkspaceView.workspace => strings.cwsViewWorkspace,
      },
  ].join(', '),
);

/// The icon of each layout in the menu.
IconData chatWorkspaceLayoutIcon(ChatWorkspaceMode mode) => switch (mode) {
  ChatWorkspaceMode.chat => Icons.chat_bubble_outline_rounded,
  ChatWorkspaceMode.split => Icons.vertical_split_outlined,
  ChatWorkspaceMode.workspace => Icons.terminal_rounded,
};

class _ViewsPanel extends StatelessWidget {
  const _ViewsPanel({
    required this.controller,
    required this.availableTabs,
    required this.onChosen,
  });

  /// The menu's width: its circles and their names (ref-ventanas-1).
  static const double width = 240;

  final ChatWorkspaceController controller;
  final List<ChatWorkspaceTab> availableTabs;
  final VoidCallback onChosen;

  void _layout(ChatWorkspaceMode mode) {
    final c = controller;
    if (mode == ChatWorkspaceMode.chat) {
      c.setViewVisible(ChatWorkspaceView.workspace, false);
      return;
    }
    if (!c.workspaceVisible) {
      c.setViewVisible(
        ChatWorkspaceView.workspace,
        true,
        tab: chatWorkspaceTabFor(c, availableTabs),
      );
    }
    c.setMode(mode);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final strings = Strings.of(context);
      final colors = Theme.of(context).hermes;
      final c = controller;
      final overChat = chatWorkspaceOpensOverChat(c);
      // Sharing the screen needs room beside the chat and a panel to show.
      final canShare =
          !overChat && (c.hasWorkspace || availableTabs.isNotEmpty);
      final current = !overChat && c.workspaceVisible
          ? c.mode
          : ChatWorkspaceMode.chat;
      final hint = overChat
          ? strings.cwsViewsHintStacked
          : !canShare
          ? strings.cwsViewsHintNoPanel
          : c.hasList && c.maxViews < ChatWorkspaceView.values.length
          ? strings.cwsViewsHintTwo
          : null;
      String label(ChatWorkspaceMode mode) => switch (mode) {
        ChatWorkspaceMode.chat => strings.cwsViewChat,
        ChatWorkspaceMode.split => strings.cwsLayoutSplit,
        ChatWorkspaceMode.workspace => strings.cwsLayoutWork,
      };
      return SingleChildScrollView(
        padding: const EdgeInsets.all(HermesSpace.x2),
        child: Column(
          key: const ValueKey('chat-views-layout'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final mode in ChatWorkspaceMode.values)
              _LayoutRow(
                key: ValueKey('chat-views-layout-${mode.name}'),
                icon: chatWorkspaceLayoutIcon(mode),
                label: label(mode),
                selected: mode == current,
                onTap: mode == ChatWorkspaceMode.chat || canShare
                    ? () {
                        _layout(mode);
                        onChosen();
                      }
                    : null,
              ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.x2,
                  HermesSpace.x1,
                  HermesSpace.x2,
                  HermesSpace.x1,
                ),
                child: Text(
                  hint,
                  key: const ValueKey('chat-workspace-views-hint'),
                  style: TextStyle(
                    fontSize: HermesType.captionSize,
                    height: 1.4,
                    // REVIEW-Q9-VENT P2-2: readable on the window
                    // wherever it blurs.
                    color: HermesFloatingSurface.windowInk(
                      colors,
                      colors.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// One layout of the menu (ref-ventanas-1): a 40 dp circle with its icon
/// and its name, on a 48 dp target. The one in use: the circle in the
/// accent (its edge and a soft fill), its name in bold accent. One that
/// cannot be chosen now is dimmed.
class _LayoutRow extends StatelessWidget {
  const _LayoutRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// The accent's fill in the circle of the layout in use.
  static const double _tint = 0.16;

  /// Above and below a row, inside its target.
  static const double _rowPad = HermesSpace.x1 / 2;

  /// The circle, and its edge when it is the layout in use
  /// (ventanas-final-png).
  static const double circle = 40;
  static const double _selectedEdge = 1.8;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final enabled = onTap != null;
    final ink = enabled
        ? HermesFloatingSurface.windowInk(
            colors,
            selected ? colors.accentText : chrome.ink,
          )
        : chrome.mutedInk;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      enabled: enabled,
      onTap: onTap,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HermesRadius.row),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap + 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x1,
              vertical: _rowPad,
            ),
            child: Row(
              children: [
                DecoratedBox(
                  key: const ValueKey('chat-views-layout-circle'),
                  decoration: ShapeDecoration(
                    color: selected
                        ? colors.accent.withValues(alpha: _tint)
                        : chrome.raised,
                    shape: CircleBorder(
                      side: BorderSide(
                        color: selected ? colors.accent : chrome.line,
                        width: selected ? _selectedEdge : 1,
                      ),
                    ),
                  ),
                  child: SizedBox.square(
                    dimension: circle,
                    child: Icon(icon, size: HermesIcon.lg, color: ink),
                  ),
                ),
                const SizedBox(width: HermesSpace.x3),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: HermesType.bodySize,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
