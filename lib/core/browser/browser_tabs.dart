// The in-app browser's tabs (Q9-NAV, mock 140-qa9709/navegador-pestanas,
// approved by the owner): one list per chat, the user's tabs and Hermes's own.
//
// As Hermes Desktop's preview rail (`store/preview.ts`): a list of tabs, the
// active one in front, closing a tab gives the screen to its neighbour. As
// the owner decided (Q9-NAV decision 2 a), the agent's page always lands in ITS
// tab, made when missing and brought to the front, never in one of the
// user's. Closing the last tab leaves a blank one: the browser stays open.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One tab of the in-app browser.
class BrowserTab {
  BrowserTab._({
    required this.id,
    this.url,
    this.agent = false,
    this.label = '',
  });

  final String id;

  /// Where the tab is (or was when it was last on screen); null for a new,
  /// blank tab.
  Uri? url;

  /// The page's title, '' until it says one.
  String title = '';

  /// Hermes's tab: the agent's `preview.open` lands here.
  bool agent;

  /// The agent's own name for its page ('' otherwise).
  String label;

  bool get blank => url == null;

  /// What the tab is called: its title, else the agent's label, else its
  /// host; '' for a blank tab.
  String get name {
    if (title.isNotEmpty) return title;
    if (label.isNotEmpty) return label;
    return url?.host ?? '';
  }
}

/// The tabs of one chat's browser. The browser widgets read and change it;
/// it outlives them, so the tabs are there when the browser opens again.
class BrowserTabs extends ChangeNotifier {
  /// Tabs that keep their page alive at once (the active one and the most
  /// recent others); the rest sleep with their address and title, and load
  /// again when they come back. A WebView is heavy on a phone.
  static const int maxLive = 3;

  final List<BrowserTab> _tabs = [];

  /// Most recently active first.
  final List<String> _recent = [];
  String? _activeId;
  int _next = 0;

  /// What the last close took away, for «Deshacer».
  List<BrowserTab>? _undoTabs;
  int? _undoIndex;
  String? _undoActive;
  String? _undoBlank;

  List<BrowserTab> get tabs => List.unmodifiable(_tabs);
  int get length => _tabs.length;
  bool get isEmpty => _tabs.isEmpty;

  BrowserTab? get active => byId(_activeId);

  int get activeIndex => _tabs.indexWhere((tab) => tab.id == _activeId);

  /// Hermes's tab, if there is one.
  BrowserTab? get agentTab => _tabs.where((tab) => tab.agent).lastOrNull;

  BrowserTab? byId(String? id) =>
      id == null ? null : _tabs.where((tab) => tab.id == id).firstOrNull;

  bool get canUndo => _undoTabs != null;

  /// The tabs whose page is alive: the active one first, then the most
  /// recent others, up to [maxLive].
  Set<String> get liveIds {
    final ids = <String>{};
    final activeId = _activeId;
    if (activeId != null && byId(activeId) != null) ids.add(activeId);
    for (final id in _recent) {
      if (ids.length >= maxLive) break;
      if (byId(id) != null) ids.add(id);
    }
    return ids;
  }

  BrowserTab _make({Uri? url, bool agent = false, String label = ''}) =>
      BrowserTab._(id: 'tab-${_next++}', url: url, agent: agent, label: label);

  void _setActive(String id) {
    _activeId = id;
    _recent
      ..remove(id)
      ..insert(0, id);
  }

  void _clearUndo() {
    _undoTabs = null;
    _undoIndex = null;
    _undoActive = null;
    _undoBlank = null;
  }

  /// A blank tab when there is none. Does not notify: the browser calls it
  /// as it opens.
  void ensureOne() {
    if (_tabs.isNotEmpty) return;
    final tab = _make();
    _tabs.add(tab);
    _setActive(tab.id);
  }

  /// A new tab, at the end, in front ([url] null: blank).
  BrowserTab open({Uri? url, bool agent = false, String label = ''}) {
    _clearUndo();
    final tab = _make(url: url, agent: agent, label: label);
    _tabs.add(tab);
    _setActive(tab.id);
    notifyListeners();
    return tab;
  }

  /// Where the agent's [url] goes: its tab if there is one, else a blank
  /// tab in front, else nowhere yet (null: a new tab is to be made). Never
  /// a tab of the user's.
  BrowserTab? agentTarget() {
    final own = agentTab;
    if (own != null) return own;
    final front = active;
    return front != null && front.blank ? front : null;
  }

  /// Hermes's `preview.open`: its tab ([agentTarget], or a new one) shows
  /// [url] and comes to the front.
  BrowserTab openAgent(Uri url, String label) {
    _clearUndo();
    var tab = agentTarget();
    if (tab == null) {
      tab = _make(url: url, agent: true, label: label);
      _tabs.add(tab);
    } else {
      tab
        ..url = url
        ..title = ''
        ..agent = true
        ..label = label;
    }
    _setActive(tab.id);
    notifyListeners();
    return tab;
  }

  /// Brings [id] to the front.
  void activate(String id) {
    if (byId(id) == null || id == _activeId) return;
    _setActive(id);
    notifyListeners();
  }

  /// The user closes [id]: its neighbour takes the screen (the one on its
  /// right, or on its left when it was the last), and the last tab gives
  /// way to a blank one: the browser stays open. «Deshacer» brings it back.
  BrowserTab? close(String id) {
    final index = _tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return null;
    final closed = _tabs[index];
    _clearUndo();
    _undoTabs = [closed];
    _undoIndex = index;
    _undoActive = _activeId;
    _tabs.removeAt(index);
    _recent.remove(id);
    if (_tabs.isEmpty) {
      final blank = _make();
      _tabs.add(blank);
      _undoBlank = blank.id;
      _setActive(blank.id);
    } else if (_activeId == id) {
      _setActive(_tabs[math.min(index, _tabs.length - 1)].id);
    }
    notifyListeners();
    return closed;
  }

  /// «Cerrar todas»: one blank tab is left, and «Deshacer» brings them all
  /// back. Nothing to do when only a blank tab is open.
  int closeAll() {
    if (_tabs.length == 1 && _tabs.single.blank) return 0;
    final count = _tabs.length;
    _clearUndo();
    _undoTabs = List.of(_tabs);
    _undoActive = _activeId;
    _tabs.clear();
    _recent.clear();
    final blank = _make();
    _tabs.add(blank);
    _undoBlank = blank.id;
    _setActive(blank.id);
    notifyListeners();
    return count;
  }

  /// «Deshacer» after [close] or [closeAll].
  bool undo() {
    final saved = _undoTabs;
    if (saved == null) return false;
    final blankId = _undoBlank;
    if (blankId != null) {
      final blank = byId(blankId);
      if (blank != null && blank.blank) {
        _tabs.remove(blank);
        _recent.remove(blankId);
      }
    }
    final index = _undoIndex;
    if (index == null) {
      _tabs
        ..clear()
        ..addAll(saved);
    } else {
      _tabs.insert(math.min(index, _tabs.length), saved.single);
    }
    final back = _undoActive;
    _clearUndo();
    if (back != null && byId(back) != null) {
      _setActive(back);
    } else if (_tabs.isNotEmpty && active == null) {
      _setActive(_tabs.first.id);
    }
    notifyListeners();
    return true;
  }

  /// The agent closes [id] (`preview.close`): no «Deshacer» and no blank
  /// tab in its place. True when no tab is left (the browser goes, as
  /// Desktop's pane does).
  bool removeForAgent(String id) {
    final index = _tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return _tabs.isEmpty;
    _clearUndo();
    _tabs.removeAt(index);
    _recent.remove(id);
    if (_tabs.isNotEmpty && _activeId == id) {
      _setActive(_tabs[math.min(index, _tabs.length - 1)].id);
    } else if (_tabs.isEmpty) {
      _activeId = null;
    }
    notifyListeners();
    return _tabs.isEmpty;
  }

  /// The agent closes every tab (`preview.close` without a url).
  void clearForAgent() {
    if (_tabs.isEmpty) return;
    _clearUndo();
    _tabs.clear();
    _recent.clear();
    _activeId = null;
    notifyListeners();
  }

  /// What the tab's page says about itself as it moves.
  void update(String id, {Uri? url, String? title, bool? agent}) {
    final tab = byId(id);
    if (tab == null) return;
    var changed = false;
    if (url != null && url != tab.url) {
      tab.url = url;
      changed = true;
    }
    if (title != null && title != tab.title) {
      tab.title = title;
      changed = true;
    }
    if (agent != null && agent != tab.agent) {
      tab.agent = agent;
      if (!agent) tab.label = '';
      changed = true;
    }
    if (changed) notifyListeners();
  }
}
