// The in-app browser with tabs (Q9-NAV, mock 140-qa9709/navegador-pestanas,
// approved by the owner after APK 9709): a strip of rounded tabs with «+» and
// the count, each tab with its ×, the view of every tab in a grid, «Cerrar
// todas», Hermes's tab marked, and who drives the page. Each tab is an
// [InAppBrowserScreen] of its own: its bar, its page, its history.
//
// It fills whatever it is given: the phone's screen, the open Fold, a
// tablet or the work pane. On a phone on its side the tabs share the bar's
// row; while the address is being typed the strip steps aside, so the page
// keeps its room.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../feedback/feedback_policy.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart' show HermesMotion;
import '../widgets/hermes_notice.dart' show HermesNoticeAction;
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspacePaneScope;
import 'agent_browser_bridge.dart';
import 'browser_tabs.dart';
import 'in_app_browser_screen.dart';
import 'webview_render_guard.dart' show WebViewRendererWatch;

/// Below this height a screen wider than tall is a phone on its side: the
/// strip goes into the bar's row instead of a row of its own.
const double _inlineStripBelow = 480;

/// The strip's row: 48 dp targets and 4 dp around them.
const double kBrowserTabStripHeight = HermesSpace.tap + HermesSpace.x2;

/// A tab's pill: 40 dp to the eye, the whole 48 dp row to the finger.
const double _tabPillHeight = HermesSpace.x8 + HermesSpace.x2;
const double _tabMaxWidth = 178;

/// How long «Deshacer» stays after a close.
const Duration _undoFor = Duration(seconds: 6);

/// Columns of the tab view for a width: two on a phone, three on an open
/// Fold or a tablet held upright, four on a wide tablet.
int browserTabGridColumns(double width) {
  if (width < 600) return 2;
  if (width < 1000) return 3;
  return 4;
}

class InAppTabbedBrowser extends StatefulWidget {
  const InAppTabbedBrowser({
    required this.tabs,
    this.agentConnectionId,
    this.agentSessionId,
    this.bridge,
    this.working,
    this.changes,
    this.launchExternal,
    this.backLabel,
    this.rendererWatch,
    super.key,
  });

  /// The chat's tabs; they outlive this widget.
  final BrowserTabs tabs;

  /// The chat whose agent reaches the tabs (see [InAppBrowserScreen]).
  final String? agentConnectionId;
  final String? Function()? agentSessionId;
  final AgentBrowserBridge? bridge;

  /// The agent's turn is running: its tab's dot is live and the line under
  /// the bar says who drives. Null: no line.
  final bool Function()? working;

  /// When [working] may have changed.
  final Listenable? changes;

  final Future<bool> Function(Uri uri)? launchExternal;
  final String? backLabel;
  final WebViewRendererWatch? rendererWatch;

  @override
  State<InAppTabbedBrowser> createState() => _InAppTabbedBrowserState();
}

class _InAppTabbedBrowserState extends State<InAppTabbedBrowser> {
  /// The view of every tab is open.
  bool _grid = false;

  final ScrollController _strip = ScrollController();
  final Map<String, GlobalKey> _chipKeys = {};

  /// The live tabs' pages, as the agent bridge sees them.
  final Map<String, AgentBrowserPage> _pages = {};

  /// The tab the strip last brought into view.
  String? _shownActive;

  /// These tabs as the agent bridge reaches them.
  late final _TabsHost _host = _TabsHost(this);

  BrowserTabs get _tabs => widget.tabs;

  @override
  void initState() {
    super.initState();
    _tabs.ensureOne();
  }

  @override
  void didUpdateWidget(InAppTabbedBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tabs, widget.tabs)) widget.tabs.ensureOne();
  }

  @override
  void dispose() {
    _strip.dispose();
    super.dispose();
  }

  // ── What the user does ─────────────────────────────────────────────────

  void _activate(String id) {
    _tabs.activate(id);
    if (_grid) setState(() => _grid = false);
  }

  void _newTab() {
    _tabs.open();
    if (_grid) setState(() => _grid = false);
  }

  void _close(BrowserTab tab) {
    final strings = Strings.of(context);
    final name = tab.blank ? strings.brwTabBlank : tab.name;
    _tabs.close(tab.id);
    _offerUndo(strings.brwTabClosed(name));
  }

  void _closeAll() {
    final strings = Strings.of(context);
    final count = _tabs.closeAll();
    if (count == 0) return;
    setState(() => _grid = false);
    _offerUndo(strings.brwTabsClosed(count));
  }

  void _offerUndo(String message) {
    final strings = Strings.of(context);
    AppFeedback.of(context).notify(
      FeedbackKind.undo,
      message,
      action: HermesNoticeAction(
        label: strings.brwTabUndo,
        onPressed: () => _tabs.undo(),
      ),
      duration: _undoFor,
    );
  }

  void _toggleGrid() => setState(() => _grid = !_grid);

  // ── What the agent does (Desktop's preview tabs) ───────────────────────

  /// `preview.open`: the agent's tab (or a blank one in front, or a new
  /// one) gets the page and comes to the front; the user's are left alone.
  void _openAgentTab(Uri url, String label) {
    if (!mounted) return;
    final target = _tabs.agentTarget();
    final page = target == null ? null : _pages[target.id];
    _tabs.openAgent(url, label);
    // A live page loads it now; a sleeping or new one wakes on it.
    page?.navigate(url, label);
    if (_grid) setState(() => _grid = false);
  }

  /// `preview.close` with a url: the tab at that address, Hermes's first.
  bool _closeMatching(String target) {
    final agent = _tabs.agentTab;
    final tabs = [?agent, ..._tabs.tabs.where((tab) => tab != agent)];
    for (final tab in tabs) {
      if (agentPreviewSameAddress(tab.url, target)) {
        _closeTabForAgent(tab.id);
        return true;
      }
    }
    return false;
  }

  /// The agent closes a tab: no blank tab and no «Deshacer»; with the last
  /// one the browser goes, as Desktop's preview pane does.
  void _closeTabForAgent(String id) {
    if (!mounted) return;
    if (_tabs.removeForAgent(id)) _leave();
  }

  void _closeAllForAgent() {
    if (!mounted) return;
    _tabs.clearForAgent();
    _leave();
  }

  /// Over the chat the route goes; in the work pane its tab does (the
  /// pane's navigator closes the tab when its first route goes).
  void _leave() {
    final route = ModalRoute.of(context);
    if (route == null) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// Keeps the tab in front visible in the strip as it changes.
  void _followActive(String? id) {
    if (id == null || id == _shownActive) return;
    // The browser opens with the tab in front already in view; only a
    // change after that scrolls to it (gint64: the first follow animated
    // from the start of the strip while the page was opening).
    final first = _shownActive == null;
    _shownActive = id;
    final instant = first || HermesMotion.reduced(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _chipKeys[id]?.currentContext;
      if (!mounted || chip == null) return;
      Scrollable.ensureVisible(
        chip,
        alignment: 0.5,
        duration: instant ? Duration.zero : HermesMotion.base,
        curve: HermesMotion.standard,
      );
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final changes = widget.changes;
    return ListenableBuilder(
      listenable: changes == null ? _tabs : Listenable.merge([_tabs, changes]),
      builder: (context, _) => LayoutBuilder(builder: _layout),
    );
  }

  Widget _layout(BuildContext context, BoxConstraints box) {
    final colors = Theme.of(context).hermes;
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    final short = box.maxHeight < _inlineStripBelow;
    final inline = box.maxWidth > box.maxHeight && short;
    final tabs = _tabs.tabs;
    final active = _tabs.active;
    final live = _tabs.liveIds;
    final working = widget.working?.call() ?? false;
    _chipKeys.removeWhere((id, _) => _tabs.byId(id) == null);
    _pages.removeWhere((id, _) => _tabs.byId(id) == null);
    _followActive(active?.id);

    Widget strip() => _TabStrip(
      tabs: tabs,
      activeId: active?.id,
      working: working,
      controller: _strip,
      keyFor: (id) => _chipKeys.putIfAbsent(id, GlobalKey.new),
      onSelect: _activate,
      onClose: _close,
      onNew: _newTab,
      onShowAll: _toggleGrid,
    );

    final pages = Stack(
      fit: StackFit.expand,
      children: [
        for (final tab in tabs)
          if (live.contains(tab.id))
            _page(
              tab,
              front: tab.id == active?.id && !_grid,
              working: working,
              inlineStrip: inline && !typing && tab.id == active?.id
                  ? strip()
                  : null,
            ),
        if (_grid)
          _TabGrid(
            tabs: tabs,
            activeId: active?.id,
            working: working,
            onSelect: _activate,
            onClose: _close,
            onCloseAll: _closeAll,
            onNew: _newTab,
          ),
      ],
    );
    return PopScope(
      // Back closes the view of the tabs first.
      canPop: !_grid,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _grid) setState(() => _grid = false);
      },
      child: Material(
        key: const ValueKey('browser-tabs'),
        color: ChatWorkspacePaneScope.backgroundOf(context, colors.background),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!inline && !typing && !_grid) strip(),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: pages,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(
    BrowserTab tab, {
    required bool front,
    required bool working,
    Widget? inlineStrip,
  }) {
    final id = tab.id;
    return Offstage(
      key: ValueKey('browser-tab-page-$id'),
      offstage: !front,
      child: TickerMode(
        enabled: front,
        child: InAppBrowserScreen(
          key: ValueKey('browser-tab-screen-$id'),
          initialUrl: tab.url,
          agentLabel: tab.label,
          openedByAgent: tab.agent,
          agentConnectionId: widget.agentConnectionId,
          agentSessionId: widget.agentSessionId,
          bridge: widget.bridge,
          launchExternal: widget.launchExternal,
          backLabel: widget.backLabel,
          rendererWatch: widget.rendererWatch,
          tab: InAppBrowserTabHooks(
            foreground: front,
            tabId: id,
            tabsHost: _host,
            onAgentClose: () => _closeTabForAgent(id),
            onUrl: (url) => _tabs.update(id, url: url),
            onTitle: (title) => _tabs.update(id, title: title),
            onAgentOwned: (agent) => _tabs.update(id, agent: agent),
            onPage: (page) {
              if (page == null) {
                _pages.remove(id);
              } else {
                _pages[id] = page;
              }
            },
            belowBar: front ? _whoLine(tab, working) : null,
            barTrailing: inlineStrip,
          ),
        ),
      ),
    );
  }

  /// Who drives the page in front (the floating window's line, mock 138
  /// v2): Hermes in its tab while it works; the user in theirs, which the
  /// agent still sees (it reads and drives the tab on screen, as in Hermes
  /// Desktop).
  Widget? _whoLine(BrowserTab tab, bool working) {
    if (widget.working == null || tab.blank) return null;
    if (!working && !tab.agent) return null;
    return _WhoLine(agentTab: tab.agent, working: working);
  }
}

/// The tabs as [AgentBrowserBridge] reaches them: what a read lists, and
/// the agent's open and close.
class _TabsHost implements AgentBrowserTabsHost {
  _TabsHost(this._state);

  final _InAppTabbedBrowserState _state;

  @override
  List<AgentPreviewTabSummary> get tabSummaries => [
    for (final tab in _state._tabs.tabs)
      AgentPreviewTabSummary(
        id: tab.id,
        label: tab.name,
        url: tab.url?.toString() ?? 'about:blank',
      ),
  ];

  @override
  void openAgentTab(Uri url, String label) => _state._openAgentTab(url, label);

  @override
  bool closeTabsMatching(String target) => _state._closeMatching(target);

  @override
  void closeAllTabs() => _state._closeAllForAgent();
}

/// What TalkBack says for a tab, in the strip and in the grid.
String _tabLabel(
  Strings strings,
  BrowserTab tab, {
  required int index,
  required int count,
  required bool live,
}) {
  final name = tab.blank ? strings.brwTabBlank : tab.name;
  if (!tab.agent) return strings.brwTabLabel(index + 1, count, name);
  if (live) return strings.brwTabAgentLiveLabel(name);
  return strings.brwTabAgentLabel(name);
}

/// The strip of tabs: rounded pills that scroll, fading at the end, then
/// «+» and the count.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.activeId,
    required this.working,
    required this.controller,
    required this.keyFor,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onShowAll,
  });

  final List<BrowserTab> tabs;
  final String? activeId;
  final bool working;
  final ScrollController controller;
  final GlobalKey Function(String id) keyFor;
  final ValueChanged<String> onSelect;
  final ValueChanged<BrowserTab> onClose;
  final VoidCallback onNew;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final agentLive = working && tabs.any((tab) => tab.agent);
    return SizedBox(
      key: const ValueKey('browser-tab-strip'),
      height: kBrowserTabStripHeight,
      child: Row(
        children: [
          Expanded(
            child: ShaderMask(
              // The strip fades at its end: more tabs are there.
              shaderCallback: (rect) => const LinearGradient(
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0, 0.9, 1],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: ListView.separated(
                key: const ValueKey('browser-tab-list'),
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(
                  left: HermesSpace.x2,
                  right: HermesSpace.x6,
                ),
                itemCount: tabs.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: HermesSpace.x1),
                itemBuilder: (context, index) {
                  final tab = tabs[index];
                  return _TabChip(
                    key: keyFor(tab.id),
                    tab: tab,
                    index: index,
                    count: tabs.length,
                    active: tab.id == activeId,
                    live: working && tab.agent,
                    onSelect: () => onSelect(tab.id),
                    onClose: () => onClose(tab),
                  );
                },
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('browser-tab-new'),
            tooltip: strings.brwTabNew,
            color: colors.textPrimary,
            onPressed: onNew,
            icon: const Icon(Icons.add_rounded),
          ),
          _CountButton(
            count: tabs.length,
            agent: tabs.any((tab) => tab.agent),
            live: agentLive,
            onTap: onShowAll,
          ),
          const SizedBox(width: HermesSpace.x1),
        ],
      ),
    );
  }
}

/// One tab: favicon (or Hermes's mark), title and ×. The pill is 40 dp to
/// the eye; selecting and closing each take the strip's full 48 dp.
class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tab,
    required this.index,
    required this.count,
    required this.active,
    required this.live,
    required this.onSelect,
    required this.onClose,
    super.key,
  });

  final BrowserTab tab;
  final int index;
  final int count;
  final bool active;
  final bool live;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final name = tab.blank ? strings.brwTabBlank : tab.name;
    final label = _tabLabel(
      strings,
      tab,
      index: index,
      count: count,
      live: live,
    );
    final ink = active ? colors.textPrimary : colors.textSecondary;
    final support = HermesType.style(HermesType.support, ink);
    final title = support.copyWith(fontWeight: FontWeight.w600);
    final edge = tab.agent
        ? colors.accent.withValues(alpha: 0.55)
        : chrome.line;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _tabMaxWidth),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The pill drawn inside the strip's row.
          Positioned.fill(
            top: (kBrowserTabStripHeight - _tabPillHeight) / 2,
            bottom: (kBrowserTabStripHeight - _tabPillHeight) / 2,
            child: DecoratedBox(
              key: active ? const ValueKey('browser-tab-active') : null,
              decoration: ShapeDecoration(
                color: active ? chrome.opaque : colors.surfaceVariant,
                shadows: active ? chrome.shadow : null,
                shape: StadiumBorder(side: BorderSide(color: edge)),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Semantics(
                  button: true,
                  selected: active,
                  label: label,
                  excludeSemantics: true,
                  onTap: onSelect,
                  child: InkWell(
                    key: ValueKey('browser-tab-chip-${tab.id}'),
                    customBorder: const StadiumBorder(),
                    onTap: onSelect,
                    child: SizedBox(
                      height: HermesSpace.tap,
                      child: Padding(
                        padding: const EdgeInsets.only(left: HermesSpace.x3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Hermes's mark and the page's name are one
                            // line: with large text the name gives way
                            // first, never past the pill (gint64).
                            if (tab.agent)
                              Flexible(
                                child: _HermesMark(
                                  live: live,
                                  page: name,
                                  pageStyle: title,
                                ),
                              )
                            else ...[
                              _Favicon(tab: tab),
                              const SizedBox(width: HermesSpace.x2),
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: title,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: strings.brwTabClose(name),
                excludeSemantics: true,
                onTap: onClose,
                child: InkResponse(
                  key: ValueKey('browser-tab-close-${tab.id}'),
                  radius: HermesSpace.tap / 2,
                  onTap: onClose,
                  child: SizedBox.square(
                    dimension: HermesSpace.tap,
                    child: Icon(Icons.close_rounded, size: 16, color: ink),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Hermes's mark on its tab: the dot (live while it works) and its name.
/// In the strip the page's name follows on the same line, which shrinks
/// with an ellipsis (so it must sit in a bounded width); in the grid the
/// mark stands alone.
class _HermesMark extends StatelessWidget {
  const _HermesMark({required this.live, this.page, this.pageStyle});

  final bool live;
  final String? page;
  final TextStyle? pageStyle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final support = HermesType.style(HermesType.support, colors.accentText);
    final name = support.copyWith(fontWeight: FontWeight.w700);
    final hermes = Strings.of(context).brwTabHermes;
    final page = this.page;
    return Row(
      key: const ValueKey('browser-tab-hermes'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dot(color: live ? colors.error : colors.accent),
        const SizedBox(width: HermesSpace.x1),
        if (page == null)
          Text(hermes, style: name)
        else
          Flexible(
            child: Text.rich(
              TextSpan(
                text: hermes,
                style: name,
                children: [
                  TextSpan(text: '  · ', style: pageStyle),
                  TextSpan(text: page, style: pageStyle),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: HermesSpace.x2,
    child: DecoratedBox(
      decoration: ShapeDecoration(color: color, shape: const CircleBorder()),
    ),
  );
}

/// A page's mark: its host's initial on a tint of its own. The plugin has
/// no favicon, and fetching one would be a request the page never made.
class _Favicon extends StatelessWidget {
  const _Favicon({required this.tab, this.size = HermesSpace.x5});

  final BrowserTab tab;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final host = tab.url?.host ?? '';
    if (host.isEmpty) {
      return Icon(
        Icons.language_rounded,
        size: size,
        color: colors.textSecondary,
      );
    }
    final letter = host.replaceFirst('www.', '').characters.first.toUpperCase();
    final hue = (host.hashCode % 360).abs().toDouble();
    final tint = HSLColor.fromAHSL(1, hue, 0.45, 0.42).toColor();
    final mark = HermesType.style(HermesType.caption, Colors.white);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(HermesRadius.chip),
        ),
        child: Center(
          child: Text(
            letter,
            style: mark.copyWith(fontSize: size * 0.55, letterSpacing: 0),
          ),
        ),
      ),
    );
  }
}

/// The count of tabs in a rounded square: opens the view of every tab.
/// Its dot says one of them is Hermes's (red while it works).
class _CountButton extends StatelessWidget {
  const _CountButton({
    required this.count,
    required this.agent,
    required this.live,
    required this.onTap,
  });

  final int count;
  final bool agent;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final figure = HermesType.style(HermesType.value, colors.textPrimary);
    return Semantics(
      button: true,
      label: strings.brwTabsShow(count),
      excludeSemantics: true,
      onTap: onTap,
      child: InkResponse(
        key: const ValueKey('browser-tab-count'),
        radius: HermesSpace.tap / 2,
        onTap: onTap,
        child: SizedBox.square(
          dimension: HermesSpace.tap,
          child: Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: HermesSpace.x8,
                  height: HermesSpace.x8,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.textPrimary, width: 2),
                    borderRadius: BorderRadius.circular(HermesRadius.control),
                  ),
                  child: Text(
                    count > 99 ? '∞' : '$count',
                    style: figure.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                if (agent)
                  Positioned(
                    top: -HermesSpace.x1,
                    right: -HermesSpace.x1,
                    child: _Dot(color: live ? colors.error : colors.accent),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Who drives the page in front.
class _WhoLine extends StatelessWidget {
  const _WhoLine({required this.agentTab, required this.working});

  final bool agentTab;
  final bool working;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final support = HermesType.style(HermesType.support, colors.textSecondary);
    final strong = support.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    final List<Widget> parts;
    if (agentTab && working) {
      parts = [
        _Dot(color: colors.error),
        const SizedBox(width: HermesSpace.x1),
        Text(strings.brwPipLive, style: strong.copyWith(color: colors.error)),
        Flexible(
          child: Text(
            ' · ${strings.brwPipAgentControls}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: support.copyWith(color: colors.textPrimary),
          ),
        ),
      ];
    } else if (agentTab) {
      parts = [
        Text(strings.brwPipDone, style: strong),
        Flexible(
          child: Text(
            ' · ${strings.brwPipYouControl}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: support,
          ),
        ),
      ];
    } else {
      parts = [
        Flexible(
          child: Text(
            strings.brwPipYouControl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: support.copyWith(color: colors.textPrimary),
          ),
        ),
        const Spacer(),
        Icon(Icons.visibility_outlined, size: 14, color: colors.accentText),
        const SizedBox(width: HermesSpace.x1),
        Text(
          strings.brwTabHermesSees,
          style: support.copyWith(
            color: colors.accentText,
            fontWeight: FontWeight.w600,
          ),
        ),
      ];
    }
    return Semantics(
      key: const ValueKey('browser-tab-who'),
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.x4,
          0,
          HermesSpace.x4,
          HermesSpace.x1,
        ),
        child: Row(children: parts),
      ),
    );
  }
}

/// Every tab, in a grid of cards: two columns on a phone, three or four on
/// a wide screen; each card its own width, never stretched. «Cerrar todas»
/// at the top, «Nueva pestaña» at the bottom.
class _TabGrid extends StatelessWidget {
  const _TabGrid({
    required this.tabs,
    required this.activeId,
    required this.working,
    required this.onSelect,
    required this.onClose,
    required this.onCloseAll,
    required this.onNew,
  });

  final List<BrowserTab> tabs;
  final String? activeId;
  final bool working;
  final ValueChanged<String> onSelect;
  final ValueChanged<BrowserTab> onClose;
  final VoidCallback onCloseAll;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Material(
      key: const ValueKey('browser-tab-grid'),
      color: ChatWorkspacePaneScope.backgroundOf(context, colors.background),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x4,
              HermesSpace.x1,
              HermesSpace.x2,
              HermesSpace.x1,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      strings.brwTabsCount(tabs.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.style(
                        HermesType.title,
                        colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                Semantics(
                  button: true,
                  label: strings.brwTabsCloseAllLabel(tabs.length),
                  excludeSemantics: true,
                  onTap: onCloseAll,
                  child: TextButton(
                    key: const ValueKey('browser-tab-close-all'),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.error,
                      minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
                    ),
                    onPressed: onCloseAll,
                    child: Text(strings.brwTabsCloseAll),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                const pad = HermesSpace.x3;
                const gap = HermesSpace.x3;
                final columns = browserTabGridColumns(box.maxWidth);
                final cell =
                    (box.maxWidth - 2 * pad - gap * (columns - 1)) / columns;
                // A card keeps one shape at every width: a page above,
                // its name below, as tall as its text needs.
                final extent =
                    math.min(cell * 0.72, HermesSpace.x8 * 6) +
                    HermesSpace.x4 +
                    HermesSpace.x8 * scale;
                return GridView.builder(
                  key: const ValueKey('browser-tab-grid-cards'),
                  padding: const EdgeInsets.all(pad),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    mainAxisExtent: extent,
                  ),
                  itemCount: tabs.length,
                  itemBuilder: (context, index) {
                    final tab = tabs[index];
                    return _TabCard(
                      tab: tab,
                      index: index,
                      count: tabs.length,
                      active: tab.id == activeId,
                      live: working && tab.agent,
                      onSelect: () => onSelect(tab.id),
                      onClose: () => onClose(tab),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
              child: Center(
                child: FilledButton.icon(
                  key: const ValueKey('browser-tab-grid-new'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
                  ),
                  onPressed: onNew,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(strings.brwTabNew),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tab in the grid: its mark large on its tint, its name and host, its
/// × in the corner; Hermes's with its mark, the one in front ringed.
class _TabCard extends StatelessWidget {
  const _TabCard({
    required this.tab,
    required this.index,
    required this.count,
    required this.active,
    required this.live,
    required this.onSelect,
    required this.onClose,
  });

  final BrowserTab tab;
  final int index;
  final int count;
  final bool active;
  final bool live;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final name = tab.blank ? strings.brwTabBlank : tab.name;
    final label = _tabLabel(
      strings,
      tab,
      index: index,
      count: count,
      live: live,
    );
    final edge = tab.agent
        ? colors.accent.withValues(alpha: 0.55)
        : chrome.line;
    final side = active
        ? BorderSide(color: colors.accent, width: 2)
        : BorderSide(color: edge);
    final title = HermesType.style(HermesType.support, colors.textPrimary);
    final host = HermesType.style(HermesType.caption, colors.textSecondary);
    return Material(
      key: ValueKey('browser-tab-card-${tab.id}'),
      color: chrome.opaque,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.card),
        side: side,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              button: true,
              selected: active,
              label: label,
              excludeSemantics: true,
              onTap: onSelect,
              child: InkWell(
                onTap: onSelect,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ColoredBox(
                        color: colors.surfaceVariant,
                        child: Center(child: _Favicon(tab: tab, size: 40)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HermesSpace.x3,
                        vertical: HermesSpace.x2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: title.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            tab.url?.host ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: host.copyWith(
                              fontWeight: FontWeight.w400,
                              letterSpacing: 0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (tab.agent)
            Positioned(
              left: HermesSpace.x2,
              top: HermesSpace.x2,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: chrome.opaque,
                  shape: const StadiumBorder(),
                  shadows: chrome.shadow,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.x2,
                    vertical: HermesSpace.x1,
                  ),
                  child: _HermesMark(live: live),
                ),
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            child: Semantics(
              button: true,
              label: strings.brwTabClose(name),
              excludeSemantics: true,
              onTap: onClose,
              child: InkResponse(
                key: ValueKey('browser-tab-card-close-${tab.id}'),
                radius: HermesSpace.tap / 2,
                onTap: onClose,
                child: SizedBox.square(
                  dimension: HermesSpace.tap,
                  child: Center(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: chrome.opaque,
                        shape: CircleBorder(
                          side: BorderSide(color: chrome.line),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(HermesSpace.x1),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
