import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../feedback/feedback_policy.dart';
import '../theme/app_theme.dart';
import '../widgets/artifact_viewer/artifact_html_policy.dart';
import '../widgets/chat/back_to_chat_notch.dart';
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspacePaneScope;
import 'agent_browser_bridge.dart';
import 'agent_preview_offer_card.dart';
import 'webview_render_guard.dart';
import 'in_app_browser_policy.dart';

/// A failed main-frame load (Desktop `PreviewLoadErrorState`).
@immutable
class InAppBrowserLoadError {
  const InAppBrowserLoadError({
    required this.url,
    required this.description,
    this.code,
    this.rendererGone = false,
  });

  final String url;

  /// The WebView's own description; empty when there is none.
  final String description;
  final int? code;

  /// The system killed the page's renderer (REVIEW-R5-B #1): the WebView was
  /// replaced and Retry loads [url] in the new one.
  final bool rendererGone;
}

/// What a tab of an `InAppTabbedBrowser` gets from its host and tells it
/// (Q9-NAV). Without hooks the screen is a browser of one page, as before.
@immutable
class InAppBrowserTabHooks {
  const InAppBrowserTabHooks({
    required this.foreground,
    this.tabId,
    this.tabsHost,
    this.onUrl,
    this.onTitle,
    this.onAgentOwned,
    this.onAgentClose,
    this.onPage,
    this.belowBar,
    this.barTrailing,
  });

  /// The tab is the one on screen: it takes Back.
  final bool foreground;

  /// The tab, and its browser's tabs as the agent bridge reaches them: the
  /// agent's open lands in its own tab, its read lists them all.
  final String? tabId;
  final AgentBrowserTabsHost? tabsHost;

  /// Where the page is, as it moves (`http`/`https` only).
  final ValueChanged<Uri>? onUrl;

  /// The page's title once it has loaded.
  final ValueChanged<String>? onTitle;

  /// The page became the agent's (its open) or the user's (a link, an
  /// address typed).
  final ValueChanged<bool>? onAgentOwned;

  /// The agent's `preview.close` of this tab; null: it leaves the screen.
  final VoidCallback? onAgentClose;

  /// The tab's page as the agent bridge sees it, when it registers, and
  /// null when it leaves.
  final ValueChanged<AgentBrowserPage?>? onPage;

  /// Under the bar: who drives the page.
  final Widget? belowBar;

  /// In the bar's row, after the address: the tabs, on a short screen.
  final Widget? barTrailing;
}

/// The in-app browser of a conversation, opened from the notch sheet's
/// «Navegador» pill. A copy of Hermes Desktop's Browser tab reduced to one
/// page on a narrow screen: the bar (back, forward, reload, address, open in
/// the system browser), the page, its loading, blank and error states, and
/// the notch at the bottom to go back to the chat.
///
/// The page runs on the phone, never on the agent's machine. The agent of
/// the chat it belongs to ([agentConnectionId], [agentSessionId]) reaches it
/// the way Hermes Desktop's agent reaches its preview pane (see
/// [AgentBrowserBridge]): it may open a page here while that chat is on
/// screen, read it (`desktop_preview`), drive it (`drive_preview`), mark it
/// (`annotate_preview`) and close it, always only for the chat on screen.
class InAppBrowserScreen extends StatefulWidget {
  const InAppBrowserScreen({
    this.initialUrl,
    this.launchExternal,
    this.agentConnectionId,
    this.agentSessionId,
    this.agentLabel = '',
    this.openedByAgent = false,
    this.bridge,
    this.backLabel,
    this.settingsFor = defaultArtifactWebViewSettings,
    this.rendererWatch,
    this.tab,
    super.key,
  });

  /// Set when the screen is one tab of an `InAppTabbedBrowser`.
  final InAppBrowserTabHooks? tab;

  /// The connection of the chat this browser belongs to, and its runtime
  /// session, read live. Either null: no agent can read it.
  final String? agentConnectionId;
  final String? Function()? agentSessionId;

  /// The agent's label for the page it opened (Desktop's tab label; a read
  /// falls back to it for a page with no title).
  final String agentLabel;

  /// [initialUrl] is the agent's page (its `preview.open`, or the user took
  /// its offer): a later `preview.open` may replace it. A page the user
  /// opened or typed is never replaced; the agent's next page waits behind
  /// «Ver» (REVIEW-R4 P2-a2).
  final bool openedByAgent;

  /// The agent bridge to register with; [AgentBrowserBridge.instance] when
  /// null (tests inject their own).
  final AgentBrowserBridge? bridge;

  /// Page to load on open; without one the browser starts blank and waits
  /// for the user to type an address.
  final Uri? initialUrl;

  /// Opens an address in the system browser (tests inject a fake).
  final Future<bool> Function(Uri uri)? launchExternal;

  /// What the notch at the bottom says it goes back to; «Volver al chat»
  /// by default.
  final String? backLabel;

  @visibleForTesting
  final ArtifactWebViewSettingsFactory settingsFor;

  /// Watches for a dead renderer; [WebViewRenderGuard.instance] when null
  /// (tests inject their own).
  final WebViewRendererWatch? rendererWatch;

  @override
  State<InAppBrowserScreen> createState() => _InAppBrowserScreenState();
}

class _InAppBrowserScreenState extends State<InAppBrowserScreen>
    with WidgetsBindingObserver {
  /// Replaced when the system kills the renderer ([_onRendererGone]).
  late WebViewController _controller = _newController();
  final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode(debugLabel: 'browser-address');
  late Future<void> _ready;

  /// Which WebView this is: a new one after a dead renderer.
  int _webGeneration = 0;

  WebViewRendererWatch get _rendererWatch =>
      widget.rendererWatch ?? WebViewRenderGuard.instance;

  static WebViewController _newController() =>
      WebViewController(onPermissionRequest: denyArtifactPermissionRequest);

  /// The page's CURRENT address (it moves as the page navigates).
  String _url = '';

  /// The address asked for and still on its way, so the field never flashes
  /// the page being left (Desktop `pending`).
  String? _pending;
  bool _loading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// Only while the user is typing: a page that navigates itself is never
  /// the user's mistake to flag.
  bool _invalid = false;
  InAppBrowserLoadError? _error;

  /// The agent's label for the page on screen ('' for the user's own).
  late String _agentLabel = widget.agentLabel;

  /// The page on screen is the agent's
  /// ([InAppBrowserScreen.openedByAgent]).
  late bool _agentOwned = widget.openedByAgent;

  /// Reads and actions of the agent in flight, and the short linger that
  /// keeps «Hermes está leyendo esta página» on screen long enough to be
  /// seen after a read of a few milliseconds.
  int _agentReads = 0;
  bool _agentReadingShown = false;
  Timer? _agentReadingLinger;
  static const Duration _agentReadingLingerFor = Duration(milliseconds: 1500);
  AppLifecycleState? _lifecycle;
  VoidCallback? _detachAgent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_agentReachable) {
      final hooks = widget.tab;
      final page = hooks?.tabId != null && hooks?.tabsHost != null
          ? _TabbedAgentPage(this)
          : _AgentPage(this);
      _detachAgent = _bridge.attach(page);
      widget.tab?.onPage?.call(page);
    }
    _addressFocus.addListener(_onAddressFocus);
    _address.addListener(_onAddressEdited);
    _ready = _configure();
    unawaited(_watchRenderer());
    final initial = widget.initialUrl;
    if (initial != null && isBrowsableWebUri(initial)) {
      _pending = initial.toString();
      _loading = true;
      unawaited(_load(initial));
    }
    _syncAddressField();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }

  @override
  void dispose() {
    _detachAgent?.call();
    if (_agentReachable) widget.tab?.onPage?.call(null);
    _rendererWatch.forget(_controller);
    _agentReadingLinger?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_unload());
    _addressFocus
      ..removeListener(_onAddressFocus)
      ..dispose();
    _address
      ..removeListener(_onAddressEdited)
      ..dispose();
    super.dispose();
  }

  // ── Agent bridge ────────────────────────────────────────────────────────

  AgentBrowserBridge get _bridge =>
      widget.bridge ?? AgentBrowserBridge.instance;

  bool get _agentReachable =>
      widget.agentConnectionId != null && widget.agentSessionId != null;

  /// Nothing loaded and nothing on its way: the blank start page.
  bool get _blank => _error == null && !_loading && _url.isEmpty;

  void _setAgentReading(bool reading) {
    if (reading) {
      _agentReads++;
    } else if (_agentReads > 0) {
      _agentReads--;
    }
    if (!mounted) return;
    if (_agentReads > 0) {
      _agentReadingLinger?.cancel();
      if (!_agentReadingShown) setState(() => _agentReadingShown = true);
      return;
    }
    _agentReadingLinger?.cancel();
    _agentReadingLinger = Timer(_agentReadingLingerFor, () {
      if (mounted && _agentReads == 0) {
        setState(() => _agentReadingShown = false);
      }
    });
  }

  /// The agent's page, from its `preview.open` or its offer's «Ver».
  void _showAgentPage(Uri url, String label) {
    if (!mounted || !isBrowsableWebUri(url)) return;
    _agentLabel = label;
    _setAgentOwned(true);
    _navigate(url);
  }

  /// Whose page this is, told to the tab's host when it changes.
  void _setAgentOwned(bool owned) {
    if (_agentOwned == owned) return;
    _agentOwned = owned;
    widget.tab?.onAgentOwned?.call(owned);
  }

  /// Where the page is, for the tab's host.
  void _reportUrl() {
    final onUrl = widget.tab?.onUrl;
    if (onUrl == null || _url.isEmpty) return;
    final uri = Uri.tryParse(_url);
    if (uri != null && isBrowsableWebUri(uri)) onUrl(uri);
  }

  /// The page's title, for the tab's host, once it has loaded.
  Future<void> _reportTitle() async {
    final onTitle = widget.tab?.onTitle;
    if (onTitle == null) return;
    try {
      final title = await _controller.getTitle();
      if (mounted) onTitle(title?.trim() ?? '');
    } catch (_) {
      // The WebView went away; the tab keeps its address.
    }
  }

  /// In front and in the foreground: the only time a page may be read.
  ///
  /// In the workspace the browser is the root of a tab's own Navigator, so
  /// its route stays current while the tab is hidden or a screen covers the
  /// chat (REVIEW-R5-B #3): a hidden tab runs with its tickers off, and every
  /// route that holds it, up to the app's own, must be the current one.
  bool get _onScreen {
    if (!mounted) return false;
    final foreground =
        _lifecycle == null || _lifecycle == AppLifecycleState.resumed;
    if (!foreground) return false;
    if (!TickerMode.valuesOf(context).enabled) return false;
    return _everyRouteCurrent(context);
  }

  /// The route holding [context], and each route holding the Navigator above
  /// it, is the current one of its Navigator.
  static bool _everyRouteCurrent(BuildContext context) {
    BuildContext? at = context;
    while (at != null) {
      final route = ModalRoute.of(at);
      if (route != null && !route.isCurrent) return false;
      at = at.findAncestorStateOfType<NavigatorState>()?.context;
    }
    return true;
  }

  void _closeForAgent() {
    if (!mounted) return;
    final closeTab = widget.tab?.onAgentClose;
    if (closeTab != null) {
      closeTab();
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// The native WebView outlives this screen until the plugin lets it go,
  /// so a page left loaded could keep playing audio or video after the user
  /// went back to the chat (REVIEW-F3 P2-3). Leaving unloads it. A
  /// programmatic load never goes through [inAppBrowserNavigationDecision].
  Future<void> _unload() async {
    try {
      await _controller.loadRequest(Uri.parse('about:blank'));
    } catch (_) {
      // The WebView is already gone; nothing is left to play.
    }
  }

  /// After configuring (which installs webview_flutter's client) the native
  /// guard wraps that client, so a dead renderer never closes the app.
  Future<void> _watchRenderer() async {
    final generation = _webGeneration;
    final controller = _controller;
    try {
      await _ready;
    } catch (_) {
      return;
    }
    if (!mounted || generation != _webGeneration) return;
    await _rendererWatch.watch(controller, () {
      if (generation == _webGeneration) _onRendererGone();
    });
  }

  /// The system killed the renderer (memory, a heavy or hostile page): a
  /// new WebView takes the dead one's place and the page's error says so,
  /// with Retry loading the same address again. Never a crash.
  void _onRendererGone() {
    if (!mounted) return;
    final last =
        _pending ??
        (_url.isNotEmpty ? _url : widget.initialUrl?.toString() ?? '');
    _rendererWatch.forget(_controller);
    setState(() {
      _webGeneration++;
      _controller = _newController();
      _loading = false;
      _pending = null;
      _canGoBack = false;
      _canGoForward = false;
      _error = last.isEmpty
          ? null
          : InAppBrowserLoadError(
              url: last,
              description: '',
              rendererGone: true,
            );
    });
    _ready = _configure();
    unawaited(_watchRenderer());
  }

  Future<void> _configure() => configureInAppBrowserWebView(
    _controller,
    navigationDelegate: NavigationDelegate(
      onNavigationRequest: _onNavigationRequest,
      onPageStarted: _onPageStarted,
      onPageFinished: _onPageFinished,
      onUrlChange: _onUrlChange,
      onWebResourceError: _onWebResourceError,
    ),
    settingsFor: widget.settingsFor,
  );

  // ── WebView events ──────────────────────────────────────────────────────

  /// The page asked to go somewhere (a link, a form, a script). Unless the
  /// agent is acting on it right now, the user is the one going there: from
  /// then on the page is the user's and the agent's next page waits behind
  /// «Ver» (REVIEW-R5-B #26). Loads Console starts never come through here.
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final decision = inAppBrowserNavigationDecision(request);
    if (decision == NavigationDecision.navigate &&
        request.isMainFrame &&
        _agentReads == 0) {
      _setAgentOwned(false);
    }
    return decision;
  }

  void _onPageStarted(String url) {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      if (url.isNotEmpty) _url = url;
      _pending = null;
    });
    _syncAddressField();
    _reportUrl();
  }

  void _onPageFinished(String url) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (url.isNotEmpty) _url = url;
      _pending = null;
    });
    _syncAddressField();
    _reportUrl();
    unawaited(_reportTitle());
    // A load that ends without a URL change (a reload, a cancelled
    // navigation) still settles the history.
    unawaited(_syncHistory());
  }

  /// SPA route changes and redirects: ask the WebView rather than counting
  /// navigations, it is the only thing that knows what its history holds.
  void _onUrlChange(UrlChange change) {
    final url = change.url;
    if (!mounted || url == null || url.isEmpty) return;
    setState(() {
      _url = url;
      _pending = null;
    });
    _syncAddressField();
    _reportUrl();
    unawaited(_syncHistory());
  }

  void _onWebResourceError(WebResourceError error) {
    // A blocked ad or tracking frame must not replace a healthy page.
    if (!mounted || error.isForMainFrame == false) return;
    setState(() {
      _error = InAppBrowserLoadError(
        url: error.url ?? _pending ?? _url,
        description: error.description,
        code: error.errorCode,
      );
      _loading = false;
    });
  }

  Future<void> _syncHistory() async {
    try {
      final back = await _controller.canGoBack();
      final forward = await _controller.canGoForward();
      if (!mounted) return;
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    } catch (_) {
      // The WebView went away mid-question; the next event asks again.
    }
  }

  // ── Actions (all of them follow a tap by the user) ─────────────────────

  Future<void> _load(Uri uri) async {
    try {
      await _ready;
      await _controller.loadRequest(uri);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = InAppBrowserLoadError(url: uri.toString(), description: '');
        _loading = false;
        _pending = null;
      });
      _syncAddressField();
    }
  }

  void _navigate(Uri uri) {
    setState(() {
      _error = null;
      _loading = true;
      _pending = uri.toString();
    });
    _syncAddressField();
    unawaited(_load(uri));
  }

  Future<void> _goBack() async {
    try {
      if (await _controller.canGoBack()) await _controller.goBack();
    } catch (_) {
      // The WebView went away; there is no history left to walk.
    }
  }

  Future<void> _goForward() async {
    try {
      if (await _controller.canGoForward()) await _controller.goForward();
    } catch (_) {
      // Same as [_goBack].
    }
  }

  /// «Recargar» and the error state's retry: a failed address is asked for
  /// again, a loaded page reloads in place.
  void _reload() {
    final failed = _error;
    final again = failed == null ? null : browserExternalUri(failed.url);
    if (again != null) {
      _navigate(again);
      return;
    }
    if (_url.isEmpty) return;
    setState(() {
      _error = null;
      _loading = true;
    });
    unawaited(() async {
      try {
        await _ready;
        await _controller.reload();
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    }());
  }

  /// The only way anything leaves the app: the user's own tap, `http`/`https`
  /// only, to the system browser.
  Future<void> _openExternal(Uri uri) async {
    final launcher = widget.launchExternal ?? launchArtifactLinkExternally;
    var ok = false;
    try {
      ok = await launcher(uri);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      AppFeedback.of(context).notify(
        FeedbackKind.error,
        Strings.of(context).vw1215LinkOpenFailed,
        warning: true,
      );
    }
  }

  // ── Address field ───────────────────────────────────────────────────────

  /// While the user is not editing, the field shows where the page is (or
  /// is going).
  void _syncAddressField() {
    if (_addressFocus.hasFocus) return;
    final shown = _pending ?? _url;
    if (_address.text != shown) _address.text = shown;
  }

  void _onAddressFocus() {
    if (_addressFocus.hasFocus) {
      _address.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _address.text.length,
      );
      return;
    }
    // Leaving the field drops the draft, as Desktop's bar does on blur.
    if (_invalid) setState(() => _invalid = false);
    _syncAddressField();
  }

  void _onAddressEdited() {
    if (!_addressFocus.hasFocus) return;
    final text = _address.text;
    final invalid =
        text.trim().isNotEmpty && browserBarTarget(text) == null;
    if (invalid != _invalid) setState(() => _invalid = invalid);
  }

  void _commit(String value) {
    final uri = browserBarTarget(value);
    _addressFocus.unfocus();
    if (uri == null) return;
    // An address the user typed is the user's page, not the agent's.
    _agentLabel = '';
    _setAgentOwned(false);
    _navigate(uri);
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final error = _error;
    final blank = _blank;
    final agentSession = _agentReachable ? widget.agentSessionId!() : null;
    // In the workspace pane the chat is beside it: no «Volver al chat»,
    // whose pop closed the tab there (audit 2.9).
    final inPane = ChatWorkspacePaneScope.isInPane(context);
    final tab = widget.tab;
    // A tab behind another one leaves Back to the tab on screen.
    final foreground = tab?.foreground ?? true;
    // A tab typing its address: the page keeps the room the notch took.
    final typing = tab != null && MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      // Back walks the page's history first (Desktop: Escape goes back when
      // the page has somewhere to go back to); the notch always leaves.
      canPop: !(foreground && _canGoBack),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && foreground) unawaited(_goBack());
      },
      child: Scaffold(
        key: const ValueKey('in-app-browser'),
        // In the pane the pane's own surface shows (audit T1).
        backgroundColor: ChatWorkspacePaneScope.backgroundOf(
          context,
          colors.background,
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBar(strings, colors),
              ?tab?.belowBar,
              if (_agentReadingShown) _buildAgentReading(strings, colors),
              // The agent's next page while the user's own is showing.
              if (agentSession != null)
                AgentPreviewOfferCard(
                  bridge: _bridge,
                  connectionId: widget.agentConnectionId!,
                  sessionId: agentSession,
                  onOpen: (offer) => _showAgentPage(offer.url, offer.label),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.x2,
                  ),
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.divider),
                      borderRadius: BorderRadius.circular(HermesRadius.group),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(HermesRadius.group),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // A new platform view for a new WebView.
                          KeyedSubtree(
                            key: ValueKey(_webGeneration),
                            child: WebViewWidget(
                              key: const ValueKey('in-app-browser-webview'),
                              controller: _controller,
                            ),
                          ),
                          if (error != null)
                            _InAppBrowserErrorView(
                              error: error,
                              onRetry: _reload,
                              onOpenExternal: (uri) =>
                                  unawaited(_openExternal(uri)),
                            )
                          else if (blank)
                            const _InAppBrowserBlankView(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (inPane || typing)
                const SizedBox(height: HermesSpace.x2)
              else
                BackToChatNotch(
                  notchKey: const ValueKey('in-app-browser-notch'),
                  label: widget.backLabel ?? strings.brwBackToChat,
                  onTap: () => Navigator.of(context).pop(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A quiet line under the bar while the agent reads or acts on the page,
  /// announced once to screen readers.
  Widget _buildAgentReading(Strings strings, HermesThemeColors colors) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        key: const ValueKey('in-app-browser-agent-reading'),
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.x3,
          0,
          HermesSpace.x3,
          HermesSpace.x1,
        ),
        child: Row(
          children: [
            Icon(Icons.visibility_outlined, size: 16, color: colors.accent),
            const SizedBox(width: HermesSpace.x2),
            Expanded(
              child: Text(
                strings.brwAgentReading,
                style: HermesType.style(
                  HermesType.support,
                  colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBar(Strings strings, HermesThemeColors colors) {
    final external = browserExternalUri(_url.isNotEmpty ? _url : '');
    return Padding(
      key: const ValueKey('in-app-browser-bar'),
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.x1,
        vertical: HermesSpace.x1,
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('in-app-browser-back'),
            tooltip: strings.brwBack,
            color: colors.textPrimary,
            onPressed: _canGoBack ? () => unawaited(_goBack()) : null,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          IconButton(
            key: const ValueKey('in-app-browser-forward'),
            tooltip: strings.brwForward,
            color: colors.textPrimary,
            onPressed: _canGoForward ? () => unawaited(_goForward()) : null,
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
          IconButton(
            key: const ValueKey('in-app-browser-reload'),
            tooltip: strings.brwReload,
            color: colors.textPrimary,
            onPressed: _url.isEmpty && _error == null ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (widget.tab?.barTrailing case final trailing?) ...[
            Expanded(flex: 2, child: _buildAddressField(strings, colors)),
            const SizedBox(width: HermesSpace.x1),
            Expanded(flex: 3, child: trailing),
          ] else
            Expanded(child: _buildAddressField(strings, colors)),
          IconButton(
            key: const ValueKey('in-app-browser-open-external'),
            tooltip: strings.brwOpenExternal,
            color: colors.textPrimary,
            onPressed: external == null
                ? null
                : () => unawaited(_openExternal(external)),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressField(Strings strings, HermesThemeColors colors) {
    OutlineInputBorder pill(Color? color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(HermesRadius.tag),
      borderSide: color == null ? BorderSide.none : BorderSide(color: color),
    );
    // Progress lives IN the field, beside the address it belongs to.
    final lead = _loading
        ? SizedBox.square(
            key: const ValueKey('in-app-browser-loading'),
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.accent,
            ),
          )
        : Icon(Icons.language_rounded, size: 18, color: colors.textSecondary);
    return Semantics(
      label: strings.brwAddress,
      textField: true,
      child: TextField(
        key: const ValueKey('in-app-browser-address'),
        controller: _address,
        focusNode: _addressFocus,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        autocorrect: false,
        enableSuggestions: false,
        maxLines: 1,
        style: HermesType.style(HermesType.text, colors.textPrimary),
        cursorColor: colors.accent,
        onSubmitted: _commit,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: colors.surfaceVariant,
          hintText: strings.brwAddressPlaceholder,
          hintStyle: HermesType.style(HermesType.text, colors.textSecondary),
          prefixIcon: Center(widthFactor: 1, child: lead),
          prefixIconConstraints: const BoxConstraints(
            minWidth: HermesSpace.x8 + HermesSpace.x2,
            minHeight: HermesSpace.x8,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x3,
            vertical: HermesSpace.x2,
          ),
          border: pill(null),
          enabledBorder: pill(_invalid ? colors.error : null),
          focusedBorder: pill(_invalid ? colors.error : colors.accent),
        ),
      ),
    );
  }
}

/// `about:blank` paints a white void that reads as broken: say what to do.
class _InAppBrowserBlankView extends StatelessWidget {
  const _InAppBrowserBlankView();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ColoredBox(
      key: const ValueKey('in-app-browser-blank'),
      color: colors.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(HermesSpace.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.language_rounded,
                size: HermesSpace.x8,
                color: colors.textSecondary,
              ),
              const SizedBox(height: HermesSpace.x3),
              Text(
                Strings.of(context).brwBlankPage,
                textAlign: TextAlign.center,
                style: HermesType.style(HermesType.text, colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Desktop `PreviewLoadError`: what failed, where (tap to open it in the
/// system browser), why, the loopback mismatch when it applies, and «Try
/// again». The page under it stays hidden while it is shown.
class _InAppBrowserErrorView extends StatelessWidget {
  const _InAppBrowserErrorView({
    required this.error,
    required this.onRetry,
    required this.onOpenExternal,
  });

  final InAppBrowserLoadError error;
  final VoidCallback onRetry;
  final ValueChanged<Uri> onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final kind = classifyBrowserLoadError(error.description);
    final cleartext =
        !error.rendererGone && kind == InAppBrowserErrorKind.cleartextBlocked;
    final title = error.rendererGone
        ? strings.brwRendererGone
        : switch (kind) {
            InAppBrowserErrorKind.cleartextBlocked => strings.brwCleartextTitle,
            InAppBrowserErrorKind.serverNotFound => strings.brwServerNotFound,
            InAppBrowserErrorKind.failedToLoad => strings.brwFailedToLoad,
          };
    final description = error.rendererGone
        ? strings.brwRendererGoneBody
        : cleartext
        ? strings.brwCleartextBody
        : error.description.isEmpty
        ? strings.brwUnreachable
        : error.description;
    final code = error.code;
    final shown = browserDisplayUrl(error.url);
    final where = code == null ? shown : '$shown ($code)';
    final external = browserExternalUri(error.url);
    final support = HermesType.style(HermesType.support, colors.textSecondary);
    return ColoredBox(
      key: const ValueKey('in-app-browser-error'),
      color: colors.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(HermesSpace.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: HermesType.style(HermesType.title, colors.textPrimary),
              ),
              const SizedBox(height: HermesSpace.x2),
              Semantics(
                link: external != null,
                child: InkWell(
                  key: const ValueKey('in-app-browser-error-url'),
                  borderRadius: BorderRadius.circular(HermesRadius.control),
                  onTap: external == null
                      ? null
                      : () => onOpenExternal(external),
                  child: Padding(
                    padding: const EdgeInsets.all(HermesSpace.x1),
                    child: Text(
                      where,
                      textAlign: TextAlign.center,
                      style: support.copyWith(
                        fontFamily: 'monospace',
                        decoration: external == null
                            ? null
                            : TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: HermesSpace.x1),
              Text(description, textAlign: TextAlign.center, style: support),
              if (isLoopbackBrowserUrl(error.url)) ...[
                const SizedBox(height: HermesSpace.x2),
                Text(
                  strings.brwRemoteLoopback,
                  key: const ValueKey('in-app-browser-remote-loopback'),
                  textAlign: TextAlign.center,
                  style: support,
                ),
              ],
              const SizedBox(height: HermesSpace.x4),
              // A cleartext page can never load here: the way on is the
              // system browser, not another try.
              if (cleartext && external != null)
                FilledButton.icon(
                  key: const ValueKey('in-app-browser-error-open-external'),
                  onPressed: () => onOpenExternal(external),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(strings.brwOpenExternal),
                )
              else
                FilledButton(
                  key: const ValueKey('in-app-browser-retry'),
                  onPressed: onRetry,
                  child: Text(strings.commonRetry),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The screen as [AgentBrowserBridge] sees it.
class _AgentPage implements AgentBrowserPage {
  _AgentPage(this._state);

  final _InAppBrowserScreenState _state;

  @override
  String? get ownerConnectionId => _state.widget.agentConnectionId;

  @override
  String? get ownerSessionId => _state.widget.agentSessionId?.call();

  @override
  bool get onScreen => _state._onScreen;

  @override
  bool get blank => _state._blank;

  @override
  bool get openedByAgent => _state._agentOwned;

  @override
  String get currentUrl => _state._url;

  @override
  String get initialUrl => _state.widget.initialUrl?.toString() ?? '';

  @override
  String get label => _state._agentLabel;

  @override
  Future<String> title() async {
    try {
      return await _state._controller.getTitle() ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<Object?> runScript(String script) =>
      _state._controller.runJavaScriptReturningResult(script);

  @override
  void goBack() => unawaited(_state._goBack());

  @override
  void goForward() => unawaited(_state._goForward());

  @override
  void reload() => _state._reload();

  @override
  void navigate(Uri url, String label) => _state._showAgentPage(url, label);

  @override
  void setAgentReading(bool reading) => _state._setAgentReading(reading);

  @override
  void close() => _state._closeForAgent();
}

/// A tab of an `InAppTabbedBrowser`, as [AgentBrowserBridge] sees it.
class _TabbedAgentPage extends _AgentPage implements AgentBrowserTabbedPage {
  _TabbedAgentPage(super._state);

  @override
  String get tabId => _state.widget.tab!.tabId!;

  @override
  AgentBrowserTabsHost get tabsHost => _state.widget.tab!.tabsHost!;
}
