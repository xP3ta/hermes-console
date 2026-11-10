// The agent rail beside an open chat on a wide window, when the list of
// chats is folded away: one face per agent (the open chat's agent wears the
// accent ring), a small count when the agent has chats and a dot when one
// of its chats works or waits. A tap opens an opaque panel
// anchored beside the rail with that agent's chats; a row switches the chat
// in the detail pane through the screen's own mechanism and the panel
// closes. The rail is a view of what the Chats screen hands it (its list,
// plus the other profiles' first pages): nothing here reads the network.
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/floating.dart';
import '../../models/agent_profile.dart';
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../mission_profile_avatar.dart';
import '../profile_face.dart';
import '../session_status_tone.dart';

/// What a chat of the rail says about itself besides its title: working,
/// waiting for the user, unread, or nothing. Attention and work come from
/// the same live status the list shows; unread from the same archive.
enum ChatSwitcherMark { none, working, waiting, unread }

/// One chat of an agent, as the panel lists it.
@immutable
class ChatSwitcherChat {
  const ChatSwitcherChat({
    required this.id,
    required this.title,
    required this.time,
    this.mark = ChatSwitcherMark.none,
  });

  final String id;

  /// One line; the row ellipsizes it.
  final String title;

  /// Relative time already worded by the list («hace 5 min»).
  final String time;
  final ChatSwitcherMark mark;
}

/// One agent (profile) of the rail with its chats, newest first.
@immutable
class ChatSwitcherAgent {
  const ChatSwitcherAgent({
    required this.owner,
    required this.name,
    required this.chats,
    this.profile,
    this.more = false,
  });

  /// Canonical owner key (`default` for the main profile).
  final String owner;

  /// How the lists name the agent.
  final String name;
  final AgentProfile? profile;
  final List<ChatSwitcherChat> chats;

  /// Whether the agent has chats past [chats] (a page of the server not
  /// read yet): the face and the panel then say «N+».
  final bool more;

  /// What the face and the panel count: the chats the panel lists, no
  /// more (a server total counts rows no list shows).
  int get count => chats.length;

  bool get working =>
      chats.any((chat) => chat.mark == ChatSwitcherMark.working);
  bool get waiting =>
      chats.any((chat) => chat.mark == ChatSwitcherMark.waiting);
  bool get unread => chats.any((chat) => chat.mark == ChatSwitcherMark.unread);

  /// The one mark the face shows: waiting first (it needs the user), then
  /// working, then unread.
  ChatSwitcherMark get mark => waiting
      ? ChatSwitcherMark.waiting
      : working
      ? ChatSwitcherMark.working
      : unread
      ? ChatSwitcherMark.unread
      : ChatSwitcherMark.none;

  bool has(String? chatId) =>
      chatId != null && chats.any((chat) => chat.id == chatId);
}

/// The rail with [child] (the open chat's pane) beside it.
class ChatSwitcherRail extends StatefulWidget {
  const ChatSwitcherRail({
    required this.agents,
    required this.currentChatId,
    required this.onOpenChat,
    required this.onNewChat,
    required this.onOpenList,
    required this.child,
    this.avatarCache,
    this.connectionId,
    super.key,
  });

  /// Width of the rail, its hairline aside.
  static const double width = 64;

  /// Width of the panel anchored beside it (within the window).
  static const double panelWidth = 288;

  /// Rows the panel lists before «Ver más».
  static const int pageSize = 12;

  /// The face at rest and the touch target around it.
  static const double faceSize = 36;

  final List<ChatSwitcherAgent> agents;

  /// The chat open in the pane, if any of the agents' is.
  final String? currentChatId;
  final ValueChanged<String> onOpenChat;

  /// A new chat with [ChatSwitcherAgent] (the panel's last row), or with no
  /// agent in particular (the pencil at the foot of the rail).
  final ValueChanged<ChatSwitcherAgent?> onNewChat;

  /// «≡»: the list of chats, as a column or over the content.
  final VoidCallback onOpenList;
  final MissionProfileAvatarCache? avatarCache;
  final String? connectionId;
  final Widget child;

  @override
  State<ChatSwitcherRail> createState() => _ChatSwitcherRailState();
}

class _ChatSwitcherRailState extends State<ChatSwitcherRail> {
  /// Bumped when the rail's data changes, so an open panel follows it.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  final GlobalKey _railKey = GlobalKey(debugLabel: 'chat-switcher-rail');
  NavigatorState? _panelNavigator;
  _ChatSwitcherPanelRoute? _panel;

  @override
  void didUpdateWidget(ChatSwitcherRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_panel == null) return;
    if (!identical(oldWidget.agents, widget.agents) ||
        oldWidget.currentChatId != widget.currentChatId) {
      // The panel lives on a route of its own, not below this widget: it
      // is told after this frame, never during the build that got here.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final open = _panel;
        if (open == null) return;
        if (_agentFor(open.owner) == null) {
          _closePanel();
        } else {
          _revision.value++;
        }
      });
    }
  }

  @override
  void dispose() {
    _closePanel();
    _revision.dispose();
    super.dispose();
  }

  ChatSwitcherAgent? _agentFor(String owner) =>
      widget.agents.where((agent) => agent.owner == owner).firstOrNull;

  String? get _currentTitle {
    final id = widget.currentChatId;
    if (id == null) return null;
    for (final agent in widget.agents) {
      for (final chat in agent.chats) {
        if (chat.id == id) return chat.title;
      }
    }
    return null;
  }

  void _closePanel() {
    final route = _panel;
    final navigator = _panelNavigator;
    _panel = null;
    _panelNavigator = null;
    if (route == null || navigator == null || !navigator.mounted) return;
    if (!route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Future<void> _openPanel(ChatSwitcherAgent agent) async {
    _closePanel();
    final box = _railKey.currentContext?.findRenderObject();
    final rail = box is RenderBox && box.attached && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    final navigator = Navigator.of(context);
    final route = _ChatSwitcherPanelRoute(
      owner: agent.owner,
      railRect: rail,
      direction: Directionality.of(context),
      barrierLabel: Strings.of(context).cswClosePanel,
      transitionDuration: HermesMotion.duration(
        context,
        HermesMotion.sheetOpen,
      ),
      reverseTransitionDuration: HermesMotion.duration(
        context,
        HermesMotion.sheetClose,
      ),
      builder: (_) => ListenableBuilder(
        listenable: _revision,
        builder: (context, _) {
          final live = _agentFor(agent.owner) ?? agent;
          return _ChatSwitcherPanel(
            agent: live,
            currentChatId: widget.currentChatId,
            avatarCache: widget.avatarCache,
            connectionId: widget.connectionId,
            onOpenChat: (id) {
              _closePanel();
              widget.onOpenChat(id);
            },
            onNewChat: () {
              _closePanel();
              widget.onNewChat(live);
            },
          );
        },
      ),
    );
    _panel = route;
    _panelNavigator = navigator;
    await navigator.push<void>(route);
    if (identical(_panel, route)) {
      _panel = null;
      _panelNavigator = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final safe = MediaQuery.paddingOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          label: s.cswRailLabel,
          child: SizedBox(
            key: _railKey,
            width: ChatSwitcherRail.width,
            child: ColoredBox(
              key: const ValueKey('chat-switcher-rail'),
              color: colors.background,
              child: Material(
                type: MaterialType.transparency,
                child: FocusTraversalGroup(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: safe.top + HermesSpace.x2,
                      bottom: safe.bottom + HermesSpace.x2,
                    ),
                    child: Column(
                      children: [
                        IconButton(
                          key: const ValueKey('chat-switcher-open-list'),
                          tooltip: s.cwsOpenList,
                          icon: Icon(
                            Icons.menu_rounded,
                            color: colors.textPrimary,
                          ),
                          onPressed: widget.onOpenList,
                        ),
                        const SizedBox(height: HermesSpace.x2),
                        Expanded(
                          child: ListView.separated(
                            key: const ValueKey('chat-switcher-faces'),
                            padding: const EdgeInsets.symmetric(
                              vertical: HermesSpace.x1,
                            ),
                            itemCount: widget.agents.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: HermesSpace.x1),
                            itemBuilder: (context, index) {
                              final agent = widget.agents[index];
                              final active = agent.has(widget.currentChatId);
                              return _AgentFace(
                                agent: agent,
                                active: active,
                                currentTitle: active ? _currentTitle : null,
                                avatarCache: widget.avatarCache,
                                connectionId: widget.connectionId,
                                onTap: () => _openPanel(agent),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: HermesSpace.x2),
                        IconButton(
                          key: const ValueKey('chat-switcher-new'),
                          tooltip: s.slNewSession,
                          icon: const Icon(Icons.edit_outlined),
                          style: IconButton.styleFrom(
                            backgroundColor: colors.surface,
                            foregroundColor: colors.accent,
                            minimumSize: const Size.square(HermesSpace.tap),
                            shape: const CircleBorder(),
                          ),
                          onPressed: () => widget.onNewChat(null),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        VerticalDivider(
          key: const ValueKey('chat-switcher-divider'),
          width: 1,
          thickness: 1,
          color: HermesSurfaces.divider(colors),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

/// One face of the rail: the agent's still face, the ring of the open
/// chat's agent, a count when it has any chat and the dot of its
/// mark. Long press names the agent; a screen reader hears the name, the
/// count, the open chat and the mark.
class _AgentFace extends StatelessWidget {
  const _AgentFace({
    required this.agent,
    required this.active,
    required this.currentTitle,
    required this.avatarCache,
    required this.connectionId,
    required this.onTap,
  });

  final ChatSwitcherAgent agent;
  final bool active;
  final String? currentTitle;
  final MissionProfileAvatarCache? avatarCache;
  final String? connectionId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final count = agent.count;
    final markLabel = chatSwitcherMarkLabel(s, agent.mark);
    final label = [
      chatSwitcherCountLabel(s, agent.name, count, more: agent.more),
      if (currentTitle case final title?) s.cswAgentCurrent(title),
      ?markLabel,
    ].join(', ');
    final markColor = chatSwitcherMarkColor(colors, agent.mark);
    return Semantics(
      button: true,
      selected: active,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: agent.name,
        excludeFromSemantics: true,
        child: Center(
          child: InkResponse(
            key: ValueKey('chat-switcher-face-${agent.owner}'),
            onTap: onTap,
            radius: HermesSpace.tap / 2 + HermesSpace.x1,
            child: SizedBox.square(
              dimension: HermesSpace.tap,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  ProfileFace(
                    profileName: agent.owner,
                    profile: agent.profile,
                    avatarCache: avatarCache,
                    connectionId: connectionId,
                    active: active,
                    size: ChatSwitcherRail.faceSize,
                  ),
                  if (markColor != null)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        key: ValueKey('chat-switcher-mark-${agent.owner}'),
                        width: HermesSpace.x3 - HermesSpace.x1,
                        height: HermesSpace.x3 - HermesSpace.x1,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: markColor,
                          border: Border.all(
                            color: colors.background,
                            width: ProfileFace.ringWidth,
                          ),
                        ),
                      ),
                    ),
                  // From one chat on: an agent with a chat must not look like
                  // one with none (the rail lists every profile).
                  if (count > 0)
                    Positioned(
                      right: -HermesSpace.x1,
                      bottom: -HermesSpace.x1,
                      child: ChatSwitcherCountBadge(
                        key: ValueKey('chat-switcher-badge-${agent.owner}'),
                        count: count,
                        more: agent.more,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a face with [count] chats says to a screen reader: «Forja, 2
/// conversaciones», «pi, 10+ conversaciones» when [more]. The rail and the
/// Chats list's profile strip (open Fold, a tablet, a phone on its side)
/// word it the same.
String chatSwitcherCountLabel(
  Strings s,
  String name,
  int count, {
  required bool more,
}) => more ? s.cswAgentFaceMore(name, count) : s.cswAgentFace(name, count);

/// The small count on a face. Its figure keeps to a modest scale (the
/// badge is read by the face's semantics, at any size). The rail's faces
/// and the Chats list's profile strip wear the same one.
class ChatSwitcherCountBadge extends StatelessWidget {
  const ChatSwitcherCountBadge({
    required this.count,
    this.more = false,
    super.key,
  });

  final int count;

  /// «N+»: the agent has chats past the [count] listed.
  final bool more;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: chrome.opaque,
        borderRadius: BorderRadius.circular(HermesRadius.tag),
        border: Border.all(color: chrome.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: HermesSpace.x4 + HermesSpace.x1,
          minHeight: HermesSpace.x4 + HermesSpace.x1,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x1),
          child: Center(
            child: Text(
              count > 99
                  ? '99+'
                  : more
                  ? '$count+'
                  : '$count',
              textScaler: scaler,
              style: HermesType.caption.copyWith(
                color: chrome.ink,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a mark says, in the words the list already uses. Null for none.
String? chatSwitcherMarkLabel(Strings s, ChatSwitcherMark mark) =>
    switch (mark) {
      ChatSwitcherMark.working => s.ss1215StatusWorking,
      ChatSwitcherMark.waiting => s.liveWaitingForUser,
      ChatSwitcherMark.unread => s.slUnreadDot,
      ChatSwitcherMark.none => null,
    };

/// The mark's colour: the list's working and attention tones, the accent
/// for unread. Null for none.
Color? chatSwitcherMarkColor(HermesThemeColors colors, ChatSwitcherMark mark) =>
    switch (mark) {
      ChatSwitcherMark.working => sessionStatusColor(
        colors,
        SessionStatusTone.working,
      ),
      ChatSwitcherMark.waiting => sessionStatusColor(
        colors,
        SessionStatusTone.attention,
      ),
      ChatSwitcherMark.unread => colors.accent,
      ChatSwitcherMark.none => null,
    };

/// The panel beside the rail, as a route of its own: the scrim, Back and
/// Escape close it, and the screen under it is not told it was left (a
/// popup, not a page). Positioned next to the rail's edge within the safe
/// area, never wider than the window leaves.
class _ChatSwitcherPanelRoute extends PopupRoute<void> {
  _ChatSwitcherPanelRoute({
    required this.owner,
    required this.railRect,
    required this.direction,
    required this.builder,
    required this.barrierLabel,
    required this.transitionDuration,
    required this.reverseTransitionDuration,
  });

  final String owner;
  final Rect railRect;
  final TextDirection direction;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  final Duration transitionDuration;

  @override
  final Duration reverseTransitionDuration;

  @override
  Color get barrierColor =>
      Colors.black.withValues(alpha: HermesChrome.scrimSheet);

  @override
  bool get barrierDismissible => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final window = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    const gap = HermesSpace.gap;
    final free = window.width - railRect.width - 2 * gap;
    final width = free < ChatSwitcherRail.panelWidth
        ? (free < 0 ? 0.0 : free)
        : ChatSwitcherRail.panelWidth;
    final ltr = direction == TextDirection.ltr;
    final left = ltr ? railRect.right + gap : railRect.left - gap - width;
    return Stack(
      children: [
        Positioned(
          left: left.clamp(0.0, window.width - width).toDouble(),
          top: safe.top + gap,
          width: width,
          bottom: safe.bottom + gap,
          child: Align(
            alignment: Alignment.topCenter,
            child: FocusTraversalGroup(
              child: HermesFloatingSurface(
                key: const ValueKey('chat-switcher-panel'),
                modal: true,
                lifted: true,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(HermesRadius.pane),
                  ),
                ),
                child: builder(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final eased = CurvedAnimation(
      parent: animation,
      curve: HermesMotion.emphasized,
      reverseCurve: HermesMotion.exit,
    );
    final slide = Tween<Offset>(
      begin: Offset(direction == TextDirection.ltr ? -0.04 : 0.04, 0),
      end: Offset.zero,
    ).animate(eased);
    return FadeTransition(
      opacity: eased,
      child: SlideTransition(position: slide, child: child),
    );
  }
}

/// The panel's content: the agent's face and name over «N chats», its chats
/// (a page at a time, «Ver más (N)» for the rest) and «Nueva conversación
/// con …» last. Content-sized, capped by the room the route gives it.
class _ChatSwitcherPanel extends StatefulWidget {
  const _ChatSwitcherPanel({
    required this.agent,
    required this.currentChatId,
    required this.avatarCache,
    required this.connectionId,
    required this.onOpenChat,
    required this.onNewChat,
  });

  final ChatSwitcherAgent agent;
  final String? currentChatId;
  final MissionProfileAvatarCache? avatarCache;
  final String? connectionId;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onNewChat;

  @override
  State<_ChatSwitcherPanel> createState() => _ChatSwitcherPanelState();
}

class _ChatSwitcherPanelState extends State<_ChatSwitcherPanel> {
  int _shown = ChatSwitcherRail.pageSize;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final agent = widget.agent;
    final ink = HermesFloatingSurface.windowInk(colors, colors.textPrimary);
    final mutedInk = HermesFloatingSurface.windowInk(
      colors,
      colors.textSecondary,
    );
    final chats = agent.chats;
    final visible = chats.take(_shown).toList();
    final hidden = chats.length - visible.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.x4,
            HermesSpace.x4,
            HermesSpace.x4,
            HermesSpace.x3,
          ),
          child: Semantics(
            header: true,
            child: Row(
              children: [
                ProfileFace(
                  profileName: agent.owner,
                  profile: agent.profile,
                  avatarCache: widget.avatarCache,
                  connectionId: widget.connectionId,
                  size: ChatSwitcherRail.faceSize + HermesSpace.x1,
                ),
                const SizedBox(width: HermesSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        agent.name,
                        key: const ValueKey('chat-switcher-panel-name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.title.copyWith(color: ink),
                      ),
                      Text(
                        agent.more
                            ? s.cswChatCountMore(agent.count)
                            : s.cswChatCount(agent.count),
                        key: const ValueKey('chat-switcher-panel-count'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(color: mutedInk),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, thickness: 1, color: HermesSurfaces.divider(colors)),
        Flexible(
          child: ListView(
            key: const ValueKey('chat-switcher-panel-list'),
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
            children: [
              if (chats.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.x4,
                    vertical: HermesSpace.x3,
                  ),
                  child: Text(
                    s.cswNoChats,
                    key: const ValueKey('chat-switcher-empty'),
                    style: HermesType.support.copyWith(color: mutedInk),
                  ),
                ),
              for (var i = 0; i < visible.length; i++)
                _ChatRow(
                  chat: visible[i],
                  current: visible[i].id == widget.currentChatId,
                  autofocus:
                      visible[i].id == widget.currentChatId ||
                      (i == 0 && !agent.has(widget.currentChatId)),
                  onTap: () => widget.onOpenChat(visible[i].id),
                ),
              if (hidden > 0)
                _PanelAction(
                  key: const ValueKey('chat-switcher-more'),
                  icon: Icons.expand_more_rounded,
                  label: s.cswSeeMore(hidden),
                  onTap: () =>
                      setState(() => _shown += ChatSwitcherRail.pageSize),
                ),
              Divider(
                height: HermesSpace.x3,
                thickness: 1,
                indent: HermesSpace.x4,
                endIndent: HermesSpace.x4,
                color: HermesSurfaces.divider(colors),
              ),
              _PanelAction(
                key: const ValueKey('chat-switcher-new-with'),
                icon: Icons.edit_outlined,
                label: s.cswNewChatWith(agent.name),
                accent: true,
                onTap: widget.onNewChat,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A chat of the panel: its mark, title (one line), time and status; the
/// open one is ticked and said as selected.
class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.current,
    required this.autofocus,
    required this.onTap,
  });

  final ChatSwitcherChat chat;
  final bool current;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ink = HermesFloatingSurface.windowInk(colors, colors.textPrimary);
    final mutedInk = HermesFloatingSurface.windowInk(
      colors,
      colors.textSecondary,
    );
    final markLabel = chatSwitcherMarkLabel(s, chat.mark);
    final markColor = chatSwitcherMarkColor(colors, chat.mark);
    final detail = [chat.time, ?markLabel].join(' · ');
    return Semantics(
      button: true,
      selected: current,
      label: chat.title,
      value: [detail, if (current) s.cswCurrentChat].join(', '),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: ValueKey('chat-switcher-row-${chat.id}'),
        autofocus: autofocus,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x4,
              vertical: HermesSpace.x2,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: HermesSpace.x3,
                  child: markColor == null
                      ? null
                      : Center(
                          child: Container(
                            key: ValueKey('chat-switcher-row-mark-${chat.id}'),
                            width: HermesSpace.x2,
                            height: HermesSpace.x2,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: markColor,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: HermesSpace.x2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.body.copyWith(
                          color: ink,
                          fontWeight: current
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(
                          color: markColor ?? mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                if (current) ...[
                  const SizedBox(width: HermesSpace.x2),
                  Icon(
                    Icons.check_rounded,
                    key: ValueKey('chat-switcher-current-${chat.id}'),
                    size: HermesIcon.md,
                    color: colors.accent,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «Ver más» and «Nueva conversación con …»: an icon and a label.
class _PanelAction extends StatelessWidget {
  const _PanelAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final ink = accent
        ? colors.accent
        : HermesFloatingSurface.windowInk(colors, colors.textPrimary);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: HermesSpace.tap),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x4,
            vertical: HermesSpace.x2,
          ),
          child: Row(
            children: [
              Icon(icon, size: HermesIcon.md, color: ink),
              const SizedBox(width: HermesSpace.x3),
              Expanded(
                child: Text(label, style: HermesType.body.copyWith(color: ink)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
