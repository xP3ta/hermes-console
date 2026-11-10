// Chat + espacio de trabajo en dos paneles (1.4.0, F4): tablet y Fold
// abierto. Modelo sin widgets: pestañas abiertas, modo de vista, proporción
// del divisor y geometría (incluida la bisagra). Sigue la maqueta v25
// (`?dev=tablet`, `?dev=fold`) y el modelo de paneles de Hermes Desktop
// (`components/pane-shell`): pestaña activa por grupo, cerrar elige la
// vecina de la derecha (o la de la izquierda si era la última), doble toque
// en el divisor restablece y la proporción se guarda.
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/responsive.dart';

/// The workspace tabs, in v25's order: Terminal, Archivos, Git, Navegador.
/// v25's fifth tab (Bots) is not here: the Bots home is a full screen with
/// its own dock, and the side navigation already reaches it.
enum ChatWorkspaceTab { terminal, files, git, browser, agents }

/// v25's «Solo chat» / «Dividido» / «Solo trabajo».
enum ChatWorkspaceMode { chat, split, workspace }

/// The views of a wide screen (the owner's «Vistas», mock 134-fold-chats): the
/// list of chats (on the Chats screen), the chat and the workspace pane.
/// One controller governs the three; the chat and the workspace are its
/// [ChatWorkspaceMode], the list one more flag.
enum ChatWorkspaceView { list, chat, workspace }

/// Which screen the views belong to: what is remembered is per kind.
enum ChatWorkspaceScreen {
  /// A chat on its own (full screen, from Home, a notification…).
  chat,

  /// The Chats screen: the list of chats beside the open one.
  chats,
}

class ChatWorkspaceController extends ChangeNotifier {
  ChatWorkspaceController({
    SharedPreferences? prefs,
    this.screen = ChatWorkspaceScreen.chat,
  }) : _prefs = prefs {
    for (final tab in ChatWorkspaceTab.values) {
      final stored = prefs?.getDouble(ratioKeyFor(tab));
      if (stored != null && stored.isFinite) _ratios[tab] = clampRatio(stored);
    }
    // The one shared ratio of before (0.44 on the Fold) left the chat at
    // ~396 dp; the split is now remembered per kind of panel.
    if (prefs?.containsKey(legacyRatioKey) ?? false) {
      prefs?.remove(legacyRatioKey);
    }
    _listOpen = prefs?.getBool(listOpenKey(screen)) ?? true;
    _preferredTab = ChatWorkspaceTab.values
        .where((tab) => tab.name == prefs?.getString(tabKey(screen)))
        .firstOrNull;
  }

  /// The screen these views are for.
  final ChatWorkspaceScreen screen;

  /// Whether the list of chats is open, per kind of screen (same mechanism
  /// as [ratioKey]).
  static String listOpenKey(ChatWorkspaceScreen screen) =>
      'chat_workspace_list_open_v1.${screen.name}';

  /// The workspace tab last chosen, per kind of screen.
  static String tabKey(ChatWorkspaceScreen screen) =>
      'chat_workspace_tab_v1.${screen.name}';

  /// Width of the list of chats beside the chat (mock 134: 300 dp).
  static const double listWidth = 300;

  /// Chat share of the split, kept across launches like Desktop's layout,
  /// per kind of panel ([ratioKeyFor]): the Terminal and the Browser want
  /// room, Files and Git less (the owner, Fold horizontal, APK 9708).
  static String ratioKeyFor(ChatWorkspaceTab tab) =>
      'chat_workspace_split_ratio_v2.${tab.name}';

  /// The one ratio of every panel before 1.4.0's Fold round; removed on
  /// load.
  static const String legacyRatioKey = 'chat_workspace_split_ratio_v1';

  /// the owner (APK 9708): beside a panel the chat had ~396 dp of the open Fold
  /// (~25 characters a line) while the panel showed two rows of files. With
  /// a panel open the chat never gets narrower than this, as long as the
  /// panel keeps its own floor ([ChatWorkspaceGeometry.minPane]).
  static const double minChatWidth = 480;

  /// Files and Git list a few rows: the chat keeps most of the room, 58/42.
  /// Also the split of a window too narrow for [minChatWidth] and a panel.
  static const double listPanelRatio = 0.58;

  /// Dragged within 0.25-0.70, always within the panes' floors.
  static const double minRatio = 0.25;
  static const double maxRatio = 0.70;

  /// Default share for [tab]: the Terminal and the Browser start with the
  /// chat at its floor ([minChatWidth]) and give the panel the rest; Files
  /// and Git start at [listPanelRatio].
  static double defaultRatioFor(ChatWorkspaceTab? tab) => switch (tab) {
    ChatWorkspaceTab.files || ChatWorkspaceTab.git => listPanelRatio,
    _ => minRatio,
  };

  static double clampRatio(double ratio) =>
      ratio.clamp(minRatio, maxRatio).toDouble();

  final SharedPreferences? _prefs;

  final List<ChatWorkspaceTab> _tabs = [];
  final List<ChatWorkspaceTab> _closed = [];
  ChatWorkspaceTab? _active;
  ChatWorkspaceMode _mode = ChatWorkspaceMode.chat;
  final Map<ChatWorkspaceTab, double> _ratios = {};

  List<ChatWorkspaceTab> get tabs => List.unmodifiable(_tabs);
  ChatWorkspaceTab? get active => _active;
  ChatWorkspaceMode get mode => _mode;

  /// Tabs that were closed, most recent last («Reabrir pestaña»).
  List<ChatWorkspaceTab> get closed => List.unmodifiable(_closed);

  /// The user's ratio for the active panel, or null to use
  /// [defaultRatioFor].
  double? get storedRatio => _active == null ? null : _ratios[_active];

  /// The chat's share beside [tab] (the active panel by default).
  double ratioFor([ChatWorkspaceTab? tab]) {
    final kind = tab ?? _active;
    return (kind == null ? null : _ratios[kind]) ?? defaultRatioFor(kind);
  }

  bool get hasWorkspace => _tabs.isNotEmpty;

  /// Width the host last laid out at (set by [ChatWorkspaceHost], without
  /// notifying). Lets the chat decide whether opening a tab can split.
  double? layoutWidth;

  /// Opening a tab now would show two panes (wide enough), rather than a
  /// full screen as on a phone. Beside a list of chats the room is the
  /// window's: the list makes way when there is not enough ([_fit]).
  bool get canSplit {
    final width = layoutWidth;
    final window = hasList ? windowWidth : null;
    final room = math.max(width ?? 0, window ?? 0);
    return room.isFinite && chatWorkspaceSplitFits(room);
  }

  // ── Views (list · chat · workspace) ──────────────────────────────────────

  late bool _listOpen;
  bool _listOverlay = false;
  ChatWorkspaceTab? _preferredTab;

  /// Least recently turned on first.
  final List<ChatWorkspaceView> _recency = [
    ChatWorkspaceView.list,
    ChatWorkspaceView.chat,
  ];

  /// Width the views share: the window of the screen that holds them (set
  /// by its host, see [updateWindowWidth]). Null: no limit.
  double? windowWidth;

  /// This screen has a list of chats, so the list is a view.
  bool get hasList => screen == ChatWorkspaceScreen.chats;

  /// Narrower than an expanded window (an open Fold held upright): the
  /// views do not sit side by side. An open chat takes the whole screen,
  /// as on a phone; the list comes over it from «Vistas», the workspace's
  /// tabs open over it as from the notch.
  bool get stacked {
    final width = windowWidth;
    return width != null && !chatWorkspaceSplitFits(width);
  }

  /// The list as a column beside the chat.
  bool get listVisible => hasList && _listOpen && !stacked;

  /// The list shown over the chat and the workspace without taking a
  /// column (the chat's list button when two views already fill the
  /// screen, mock 134 state C; always when [stacked]). Gone at the next
  /// choice.
  bool get listOverlay => hasList && _listOverlay && (stacked || !_listOpen);

  bool get workspaceVisible => hasWorkspace && _mode != ChatWorkspaceMode.chat;

  /// The chat hides only while the workspace shows («Solo trabajo»).
  bool get chatVisible =>
      !workspaceVisible || _mode != ChatWorkspaceMode.workspace;

  /// The tab the workspace opens on: the active one, else the one last
  /// chosen (remembered), if any.
  ChatWorkspaceTab? get preferredTab => _active ?? _preferredTab;

  /// How many views fit side by side: two below
  /// [kChatWorkspaceNavigationMinWidth] (the open Fold), three on a tablet
  /// when the list leaves the chat and the workspace room to split.
  int get maxViews {
    final width = windowWidth;
    if (width == null) return ChatWorkspaceView.values.length;
    return width >= kChatWorkspaceNavigationMinWidth &&
            chatWorkspaceSplitFits(width - listWidth - 1)
        ? 3
        : 2;
  }

  bool isVisible(ChatWorkspaceView view) => switch (view) {
    ChatWorkspaceView.list => listVisible,
    ChatWorkspaceView.chat => chatVisible,
    ChatWorkspaceView.workspace => workspaceVisible,
  };

  /// Visible views, in screen order.
  List<ChatWorkspaceView> get visibleViews => [
    for (final view in ChatWorkspaceView.values)
      if (isVisible(view)) view,
  ];

  /// Whether [view] may be turned off now: never the chat without the
  /// workspace (the screen is never left without a view).
  bool canHide(ChatWorkspaceView view) => switch (view) {
    ChatWorkspaceView.list => listVisible,
    ChatWorkspaceView.chat => chatVisible && workspaceVisible,
    ChatWorkspaceView.workspace => workspaceVisible,
  };

  /// Turns [view] on or off. On, it is the newest: if it does not fit, the
  /// least recently turned on of the others makes way (opening the
  /// workspace with the list open folds the list). The workspace opens on
  /// [tab], else on [preferredTab]; with neither, it stays off.
  void setViewVisible(
    ChatWorkspaceView view,
    bool visible, {
    ChatWorkspaceTab? tab,
  }) {
    if (visible) {
      switch (view) {
        case ChatWorkspaceView.list:
          if (!hasList) return;
          if (stacked) {
            // Upright, the list only ever comes over the chat.
            _listOverlay = true;
            notifyListeners();
            return;
          }
          _listOpen = true;
          _listOverlay = false;
        case ChatWorkspaceView.chat:
          if (chatVisible) return;
          _mode = ChatWorkspaceMode.split;
        case ChatWorkspaceView.workspace:
          final target = tab ?? preferredTab;
          if (target == null) return;
          // open() makes it the newest and saves.
          return open(target);
      }
      _touch(view);
      _fit(view);
    } else {
      if (!canHide(view) && !(view == ChatWorkspaceView.list && _listOverlay)) {
        return;
      }
      if (stacked && view == ChatWorkspaceView.list) {
        // Only the overlay goes: the column the user chose stays chosen.
        _listOverlay = false;
        notifyListeners();
        return;
      }
      _hide(view);
    }
    _saveViews();
    notifyListeners();
  }

  /// The chat's list button and the left edge's handle: closes the list,
  /// or opens it as a column when there is room, else over the content.
  void toggleList() {
    if (!hasList) return;
    if (stacked) {
      _listOverlay = !_listOverlay;
      notifyListeners();
      return;
    }
    if (listVisible || _listOverlay) {
      _listOpen = false;
      _listOverlay = false;
    } else if (visibleViews.length < maxViews) {
      _listOpen = true;
      _touch(ChatWorkspaceView.list);
    } else {
      _listOverlay = true;
    }
    _saveViews();
    notifyListeners();
  }

  /// The list over the content goes (a chat was picked, or a tap outside).
  void dismissListOverlay() {
    if (!_listOverlay) return;
    _listOverlay = false;
    notifyListeners();
  }

  /// A chat was opened from the list: it is the view in use.
  void chatOpened() {
    _touch(ChatWorkspaceView.chat);
    dismissListOverlay();
  }

  /// The window the views share changed. Returns whether a view had to
  /// make way (the caller notifies after the frame: this runs in layout).
  bool updateWindowWidth(double width) {
    if (windowWidth == width) return false;
    final wasStacked = stacked;
    windowWidth = width;
    var changed = false;
    // Turning the device: the list over the content belongs to the old
    // layout. What the user chose (list, chat, workspace) stays.
    if (wasStacked != stacked && _listOverlay) {
      _listOverlay = false;
      changed = true;
    }
    if (!stacked && visibleViews.length > maxViews) {
      final newest = _recency.lastWhere(isVisible, orElse: () => _recency.last);
      _fit(newest);
      _saveViews();
      changed = true;
    }
    return changed;
  }

  /// Notifies after [updateWindowWidth] changed the views.
  void viewsChanged() => notifyListeners();

  void _touch(ChatWorkspaceView view) {
    _recency
      ..remove(view)
      ..add(view);
  }

  void _hide(ChatWorkspaceView view) {
    switch (view) {
      case ChatWorkspaceView.list:
        _listOpen = false;
        _listOverlay = false;
      case ChatWorkspaceView.chat:
        _mode = ChatWorkspaceMode.workspace;
      case ChatWorkspaceView.workspace:
        _mode = ChatWorkspaceMode.chat;
    }
  }

  /// Folds the least recently turned on views, never [newest], until the
  /// visible ones fit [maxViews].
  void _fit(ChatWorkspaceView newest) {
    // Upright nothing sits side by side: nothing to fold, and nothing the
    // user chose is lost by turning the device.
    if (stacked) return;
    while (visibleViews.length > maxViews) {
      final victim = _recency
          .where((v) => v != newest && isVisible(v) && canHide(v))
          .firstOrNull;
      if (victim == null) return;
      _hide(victim);
    }
  }

  void _saveViews() {
    final prefs = _prefs;
    if (prefs == null) return;
    if (hasList) prefs.setBool(listOpenKey(screen), _listOpen);
    final tab = _preferredTab;
    if (tab != null) prefs.setString(tabKey(screen), tab.name);
  }

  /// Opens [tab] (or brings it to the front) and shows the workspace.
  void open(ChatWorkspaceTab tab) {
    if (!_tabs.contains(tab)) _tabs.add(tab);
    _closed.remove(tab);
    _active = tab;
    _preferredTab = tab;
    if (_mode == ChatWorkspaceMode.chat) _mode = ChatWorkspaceMode.split;
    // A tab opens from the chat, which is in use: with the list open, the
    // list is the one that makes way, even if it was turned on last.
    if (chatVisible) _touch(ChatWorkspaceView.chat);
    _touch(ChatWorkspaceView.workspace);
    _fit(ChatWorkspaceView.workspace);
    _saveViews();
    notifyListeners();
  }

  void activate(ChatWorkspaceTab tab) {
    if (!_tabs.contains(tab) || _active == tab) return;
    _active = tab;
    _preferredTab = tab;
    _saveViews();
    notifyListeners();
  }

  /// Closes [tab]. Like Desktop, the right-hand neighbour takes over (the
  /// left one if it was the last); with no tab left the chat takes the
  /// whole screen.
  void close(ChatWorkspaceTab tab) {
    final index = _tabs.indexOf(tab);
    if (index < 0) return;
    _tabs.removeAt(index);
    _closed
      ..remove(tab)
      ..add(tab);
    if (_active == tab) {
      _active = _tabs.isEmpty ? null : _tabs[math.min(index, _tabs.length - 1)];
    }
    if (_tabs.isEmpty) _mode = ChatWorkspaceMode.chat;
    notifyListeners();
  }

  void setMode(ChatWorkspaceMode mode) {
    if (mode != ChatWorkspaceMode.chat && _tabs.isEmpty) return;
    if (_mode == mode) return;
    final chatBack = !chatVisible;
    _mode = mode;
    // What the mode turns on is the newest view: back to the split from
    // «Solo trabajo», the chat; otherwise the workspace.
    if (mode != ChatWorkspaceMode.chat) {
      final newest = mode == ChatWorkspaceMode.split && chatBack
          ? ChatWorkspaceView.chat
          : ChatWorkspaceView.workspace;
      _touch(newest);
      _fit(newest);
    }
    notifyListeners();
  }

  /// The pane's expand button: workspace only ⇄ split.
  void toggleExpanded() => setMode(
    _mode == ChatWorkspaceMode.workspace
        ? ChatWorkspaceMode.split
        : ChatWorkspaceMode.workspace,
  );

  /// While dragging: not saved until [commitRatio]. Applies to the active
  /// panel's kind.
  void setRatio(double ratio) {
    final tab = _active;
    if (tab == null) return;
    final next = clampRatio(ratio);
    if (_ratios[tab] == next) return;
    _ratios[tab] = next;
    notifyListeners();
  }

  void commitRatio() {
    final tab = _active;
    final ratio = tab == null ? null : _ratios[tab];
    if (tab == null || ratio == null) return;
    _prefs?.setDouble(ratioKeyFor(tab), ratio);
  }

  /// Double tap on the divider: back to the active panel's default.
  void resetRatio() {
    final tab = _active;
    if (tab == null) return;
    _ratios.remove(tab);
    _prefs?.remove(ratioKeyFor(tab));
    notifyListeners();
  }
}

/// Where the panes go for a given width.
@immutable
class ChatWorkspaceGeometry {
  const ChatWorkspaceGeometry({
    required this.chatWidth,
    required this.dividerWidth,
    required this.workspaceWidth,
    required this.lockedToHinge,
  });

  /// Space around the two panes (v25: 10 dp).
  static const double padding = 10;

  /// v25 divider.
  static const double divider = 14;

  /// No pane narrower than this (Desktop floors panes, v25 only clamps the
  /// ratio; with the ratio alone a Fold could squeeze the chat to ~230 dp).
  static const double minPane = 280;

  /// v25 «Solo trabajo»: the chat folds into a 56 dp rail.
  static const double rail = 56;

  final double chatWidth;
  final double dividerWidth;
  final double workspaceWidth;

  /// A hinge decides the split; the divider cannot be dragged.
  final bool lockedToHinge;

  /// Widths for a window [width] at [ratio]. A [hinge] (global x range of
  /// a vertical hinge or half-open fold) takes over: each pane stays on its
  /// own side of it.
  ///
  /// The chat never gets narrower than
  /// [ChatWorkspaceController.minChatWidth] while the panel keeps
  /// [minPane]; where both do not fit, the split is a fixed 58/42
  /// ([ChatWorkspaceController.listPanelRatio]).
  static ChatWorkspaceGeometry compute({
    required double width,
    required double ratio,
    Rect? hinge,
  }) {
    final inner = math.max(0.0, width - 2 * padding);
    if (hinge != null) {
      final gap = math.max(hinge.width, divider);
      final chat = math.max(0.0, hinge.center.dx - gap / 2 - padding);
      return ChatWorkspaceGeometry(
        chatWidth: chat,
        dividerWidth: gap,
        workspaceWidth: math.max(0.0, inner - chat - gap),
        lockedToHinge: true,
      );
    }
    final available = math.max(0.0, inner - divider);
    if (available - minPane < ChatWorkspaceController.minChatWidth) {
      final chat = (available * ChatWorkspaceController.listPanelRatio)
          .roundToDouble();
      return ChatWorkspaceGeometry(
        chatWidth: chat,
        dividerWidth: divider,
        workspaceWidth: available - chat,
        lockedToHinge: false,
      );
    }
    const low = ChatWorkspaceController.minChatWidth;
    final high = math.max(low, available - minPane);
    final chat = (available * ChatWorkspaceController.clampRatio(ratio))
        .clamp(low, high)
        .roundToDouble();
    return ChatWorkspaceGeometry(
      chatWidth: chat,
      dividerWidth: divider,
      workspaceWidth: available - chat,
      lockedToHinge: false,
    );
  }

  /// Narrowest and widest the chat can be in a window [width], without a
  /// hinge: the ratio's bounds within the panes' floor.
  static (double, double) chatWidthRange(double width) => (
    compute(width: width, ratio: ChatWorkspaceController.minRatio).chatWidth,
    compute(width: width, ratio: ChatWorkspaceController.maxRatio).chatWidth,
  );

  /// Ratio that puts the divider's centre at [chatWidth] for a [width].
  static double ratioForChatWidth(double chatWidth, double width) {
    final available = math.max(1.0, width - 2 * padding - divider);
    return ChatWorkspaceController.clampRatio(chatWidth / available);
  }
}

/// From this window width the two-pane layout also shows the app's side
/// navigation (v25's dock), to the left of the chat. Tablet only: on an
/// open Fold (~933 dp) it left the panes too cramped (the owner, 2026-10-26).
const double kChatWorkspaceNavigationMinWidth = 1100;

/// Two panes need an expanded window (≥ 840 dp, Material 3 / `Responsive`).
/// Narrower, the workspace keeps opening as a full screen, as today.
bool chatWorkspaceSplitFits(double width) =>
    width >= Responsive.expandedBreakpoint;

/// A vertical hinge the split must respect, in window coordinates: an
/// occluding hinge always; a fold only when half open (book posture). A
/// flat fold is ignored (the screen is continuous), as is a cutout.
Rect? chatWorkspaceHinge(List<DisplayFeature> features, Size window) {
  for (final feature in features) {
    if (feature.type == DisplayFeatureType.cutout) continue;
    final bounds = feature.bounds;
    final vertical =
        bounds.height >= window.height * 0.9 && bounds.width < window.width / 2;
    if (!vertical) continue;
    if (feature.type == DisplayFeatureType.hinge) return bounds;
    if (feature.type == DisplayFeatureType.fold &&
        feature.state == DisplayFeatureState.postureHalfOpened) {
      return bounds;
    }
  }
  return null;
}
