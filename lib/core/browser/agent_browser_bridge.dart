import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/app_lock_sensitive_read_fence.dart';
import 'agent_preview_act.dart';
import 'agent_preview_protocol.dart';
import 'in_app_browser_policy.dart';

/// Default and hard cap on one read (Desktop `PREVIEW_READ_MAX_CHARS`): a
/// page's text can be megabytes and it crosses into the model's context.
const int agentPreviewReadMaxChars = 24000;

/// Desktop's page reader (`preview-pane.tsx`, `registerPreviewPageReader`).
const String agentPreviewTextScript =
    'document.body ? document.body.innerText : ""';

/// The agent asked to show a page (`preview.open`) and Console did not open
/// it: its chat was not on screen (Desktop drops such an open, "offer, don't
/// hijack"; Console keeps it as a card), or the browser shows a page the user
/// opened (REVIEW-R4 P2-a2). The user decides with «Ver».
@immutable
class AgentPreviewOffer {
  const AgentPreviewOffer({
    required this.connectionId,
    required this.sessionId,
    required this.url,
    this.label = '',
  });

  /// The connection and runtime session whose agent asked.
  final String connectionId;
  final String sessionId;
  final Uri url;

  /// The agent's own name for the page, if it gave one.
  final String label;
}

/// A chat screen, as the bridge sees it.
abstract interface class AgentChatPresence {
  /// The chat's connection (`SavedConnection.id`).
  String get connectionId;

  /// The chat's runtime session, read live (compression can rotate it).
  String? get sessionId;

  /// The chat (or the browser opened over it) is in front and the app is in
  /// the foreground: Desktop's "session on screen".
  bool get onScreen;

  /// Opens the in-app browser over this chat on [url].
  void openBrowser(Uri url, String label);
}

/// The open in-app browser, as the bridge sees it.
abstract interface class AgentBrowserPage {
  /// The connection and runtime session (read live) of the chat it was
  /// opened from.
  String? get ownerConnectionId;
  String? get ownerSessionId;

  /// In front and in the foreground.
  bool get onScreen;

  /// Nothing is loaded (the browser opened blank).
  bool get blank;

  /// The page on screen is the agent's: it opened it, or the user took the
  /// agent's offer. A page the user typed or opened is not.
  bool get openedByAgent;

  /// The address on screen, and the one it was opened with.
  String get currentUrl;
  String get initialUrl;

  /// The agent's label for the page it opened ('' otherwise).
  String get label;

  /// The page's title, '' when it has none.
  Future<String> title();

  /// Runs [script] in the page and returns what the WebView hands back.
  Future<Object?> runScript(String script);

  void goBack();
  void goForward();
  void reload();

  /// Shows the agent's [url] in this same view (one view: no tabs on a
  /// phone); the page is the agent's from then on.
  void navigate(Uri url, String label);

  /// The agent is reading (or acting on) the page: the browser says so
  /// while it lasts (REVIEW-R4 P2-a4; Desktop shows nothing for a read).
  void setAgentReading(bool reading);

  /// Leaves the browser.
  void close();
}

/// One tab, as an agent's read lists it when several are open (Desktop's
/// `PreviewReadTabSummary`, `preview-reader.ts`).
@immutable
class AgentPreviewTabSummary {
  const AgentPreviewTabSummary({
    required this.id,
    required this.label,
    required this.url,
  });

  final String id;
  final String label;
  final String url;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': 'url',
    'label': label,
    'url': url,
  };
}

/// The tabs of a browser with tabs, as the bridge sees them (Q9-NAV): the
/// agent's open lands in its own tab, a close names a tab by its address or
/// takes them all.
abstract interface class AgentBrowserTabsHost {
  /// Every tab, for a read when more than one is open.
  List<AgentPreviewTabSummary> get tabSummaries;

  /// `preview.open`: the agent's own tab shows [url] and comes to the front
  /// (the owner's decision 2 a); never a tab of the user's.
  void openAgentTab(Uri url, String label);

  /// `preview.close` with a url: the tab at that address (Hermes's first).
  /// False when none is.
  bool closeTabsMatching(String target);

  /// `preview.close` without a url: every tab, and the browser goes.
  void closeAllTabs();
}

/// A page that is one tab of a browser with tabs.
abstract interface class AgentBrowserTabbedPage implements AgentBrowserPage {
  String get tabId;
  AgentBrowserTabsHost get tabsHost;
}

/// Whether the page at [a] is the one [b] names (no fragment, no trailing
/// slash), as a `preview.close` with a url means it.
bool agentPreviewSameAddress(Uri? a, String b) {
  final other = normalizeBrowserAddress(b) ?? Uri.tryParse(b);
  if (a == null || other == null) return false;
  String key(Uri u) =>
      u.replace(fragment: '').toString().replaceAll(RegExp(r'/$'), '');
  return key(a) == key(other);
}

/// The agent's name for a page, or '' when it is not plain text a person can
/// trust to read: too long, or with control or bidi characters that could
/// turn «Tu banco» into something else (REVIEW-R5-B #22). The host is shown
/// beside it anyway.
String agentPreviewSafeLabel(Object? raw) {
  if (raw is! String) return '';
  final text = raw.trim();
  if (text.isEmpty || text.length > 120) return '';
  if (_unsafeLabelChars.hasMatch(text)) return '';
  return text;
}

final RegExp _unsafeLabelChars = RegExp(
  '[\u0000-\u001f\u007f\u200e\u200f\u2028\u2029\u202a-\u202e'
  '\u2066-\u2069]',
);

String _key(String connectionId, String sessionId) =>
    '$connectionId\u0000$sessionId';

/// Bridges the agent's `desktop_preview`, `drive_preview` and
/// `annotate_preview` tools to Console's in-app browser, the way Hermes
/// Desktop's renderer does (`use-preview-routing.ts`, `server-requests.ts`),
/// scoped by connection and runtime session (Desktop scopes by its owner:
/// runtime, stored id and profile; a runtime id names one profile on its
/// gateway):
///
/// * `preview.open`: opens the browser at once when that chat is on screen;
///   an open browser shows it in place only if its page is blank or already
///   the agent's; otherwise (chat not on screen, or the user's own page
///   showing) an offer with «Ver» ("offer, don't hijack").
/// * `preview.close`: only for a chat on screen; closes its browser, or only
///   the page whose address matches.
/// * `preview.read` / `preview.act`: answered only for the chat on screen;
///   every other request is declined (NOT_SHOWN), like a Desktop window that
///   does not host the session. While one runs the browser says so.
class AgentBrowserBridge implements PreviewRequestBridge {
  AgentBrowserBridge({
    AgentPreviewActEngine? engine,
    bool Function()? unlocked,
    this._readTimeout = agentPreviewActTimeout,
  }) : _engine = engine ?? AgentPreviewActEngine.bundled(),
       _unlocked = unlocked ?? _appUnlocked;

  /// Longest a read may take (the same 8 s as an action).
  final Duration _readTimeout;

  static final AgentBrowserBridge instance = AgentBrowserBridge();

  final AgentPreviewActEngine _engine;

  /// The app is not behind its lock: a locked app shows nothing, so the
  /// agent reads, drives, opens and closes nothing (REVIEW-R5-B #3).
  final bool Function() _unlocked;

  static bool _appUnlocked() => AppLockSensitiveReadFence.capture().isCurrent;

  /// The latest offer per connection and runtime session.
  final ValueNotifier<Map<String, AgentPreviewOffer>> offers = ValueNotifier(
    const {},
  );

  final List<AgentChatPresence> _chats = [];
  final List<AgentBrowserPage> _pages = [];

  /// The most recently opened browser, if any.
  AgentBrowserPage? get page => _pages.isEmpty ? null : _pages.last;

  /// Registers an open browser; returns an idempotent unregister.
  VoidCallback attach(AgentBrowserPage page) {
    _pages.add(page);
    return () => _pages.remove(page);
  }

  /// Registers a chat screen; returns an idempotent unregister.
  VoidCallback attachChat(AgentChatPresence chat) {
    _chats.add(chat);
    return () => _chats.remove(chat);
  }

  AgentPreviewOffer? offerFor(String connectionId, String sessionId) =>
      offers.value[_key(connectionId, sessionId)];

  void dismissOffer(String connectionId, String sessionId) {
    final key = _key(connectionId, sessionId);
    if (!offers.value.containsKey(key)) return;
    offers.value = Map.unmodifiable(Map.of(offers.value)..remove(key));
  }

  void _offer(AgentPreviewOffer offer) {
    offers.value = Map.unmodifiable({
      ...offers.value,
      _key(offer.connectionId, offer.sessionId): offer,
    });
  }

  /// The browser of that chat, if one is open (the newest): its floating
  /// window reads from it who is driving the page.
  AgentBrowserPage? pageOf(String connectionId, String sessionId) =>
      _pageOf(connectionId, sessionId);

  /// The browser of that chat, if one is open: the page on screen (with
  /// tabs, the one in front, Desktop's active tab), else the newest.
  AgentBrowserPage? _pageOf(String connectionId, String sessionId) {
    AgentBrowserPage? newest;
    for (final page in _pages.reversed) {
      if (page.ownerConnectionId != connectionId ||
          page.ownerSessionId != sessionId) {
        continue;
      }
      if (page.onScreen) return page;
      newest ??= page;
    }
    return newest;
  }

  /// Desktop's `sessionIsOnScreen` / `windowHostsSession`: the chat of
  /// [sessionId] on [connectionId], or the browser opened over it, is in
  /// front.
  bool sessionOnScreen(String connectionId, String sessionId) {
    if (connectionId.isEmpty || sessionId.isEmpty) return false;
    if (!_unlocked()) return false;
    if (_pageOf(connectionId, sessionId)?.onScreen ?? false) return true;
    return _chats.any(
      (chat) =>
          chat.connectionId == connectionId &&
          chat.sessionId == sessionId &&
          chat.onScreen,
    );
  }

  /// A `preview.open` / `preview.close` event of [sessionId]'s turn on
  /// [connectionId].
  void onAgentPreviewEvent({
    required String connectionId,
    required String sessionId,
    required String type,
    required Map<String, dynamic> payload,
  }) {
    if (connectionId.isEmpty || sessionId.isEmpty) return;
    final raw = payload['url'];
    final target = raw is String ? raw.trim() : '';
    if (type == 'preview.open') {
      // Same rule as the address bar: only http/https pages. File paths and
      // other targets Desktop previews are out of reach (REPORT, PARADA).
      final uri = browserExternalUri(target) ?? normalizeBrowserAddress(target);
      if (uri == null) return;
      final rawLabel = payload['label'];
      final offer = AgentPreviewOffer(
        connectionId: connectionId,
        sessionId: sessionId,
        url: uri,
        label: agentPreviewSafeLabel(rawLabel),
      );
      if (!sessionOnScreen(connectionId, sessionId)) {
        _offer(offer);
        return;
      }
      final open = _pageOf(connectionId, sessionId);
      if (open is AgentBrowserTabbedPage && open.onScreen) {
        // Q9-NAV (decision 2 a): with tabs, the agent's page goes to its
        // own tab, brought to the front; the user's tabs are left alone.
        dismissOffer(connectionId, sessionId);
        open.tabsHost.openAgentTab(uri, offer.label);
        return;
      }
      if (open != null) {
        // One view, no tabs: only a blank page or the agent's own is
        // replaced; the page the user opened stays and gets «Ver». A page
        // the user cannot see (a hidden workspace tab) is never navigated.
        if (open.onScreen && (open.blank || open.openedByAgent)) {
          dismissOffer(connectionId, sessionId);
          open.navigate(uri, offer.label);
        } else {
          _offer(offer);
        }
        return;
      }
      dismissOffer(connectionId, sessionId);
      for (final chat in _chats) {
        if (chat.connectionId == connectionId &&
            chat.sessionId == sessionId &&
            chat.onScreen) {
          chat.openBrowser(uri, offer.label);
          return;
        }
      }
      return;
    }
    if (type != 'preview.close') return;
    final offer = offerFor(connectionId, sessionId);
    if (offer != null && (target.isEmpty || _sameAddress(offer.url, target))) {
      dismissOffer(connectionId, sessionId);
    }
    // Same on-screen gate as open: a hidden turn never closes the page the
    // user is looking at.
    if (!sessionOnScreen(connectionId, sessionId)) return;
    final page = _pageOf(connectionId, sessionId);
    if (page == null || !page.onScreen) return;
    if (page is AgentBrowserTabbedPage) {
      // Desktop's `closeAgentPreview`: the tab that matches, or all of
      // them (the browser goes with the last one).
      if (target.isEmpty) {
        page.tabsHost.closeAllTabs();
      } else {
        page.tabsHost.closeTabsMatching(target);
      }
      return;
    }
    if (target.isEmpty ||
        _sameAddress(Uri.tryParse(page.currentUrl), target) ||
        _sameAddress(Uri.tryParse(page.initialUrl), target)) {
      page.close();
    }
  }

  static bool _sameAddress(Uri? a, String b) => agentPreviewSameAddress(a, b);

  @override
  Future<PreviewBridgeAnswer> answer(PreviewBridgeRequest request) async {
    final connectionId = request.connectionId;
    final sessionId = request.sessionId;
    if (!sessionOnScreen(connectionId, sessionId)) {
      // Desktop's WINDOW_OWNED_REQUESTS: a window not showing the session
      // declines so the one that does can answer. A request from another
      // connection never reaches this connection's page.
      return const PreviewBridgeAnswer.notShown();
    }
    final page = _pageOf(connectionId, sessionId);
    // The chat is in front but its browser is not (a hidden workspace tab,
    // a screen over it): what the user cannot see is never read or driven.
    if (page != null && !page.onScreen) {
      return const PreviewBridgeAnswer.notShown();
    }
    return switch (request.method) {
      'preview.read' => _read(page, request.params),
      'preview.act' => PreviewBridgeAnswer.value(
        jsonEncode(await _act(page, request)),
      ),
      _ => const PreviewBridgeAnswer.notShown(),
    };
  }

  /// Desktop `previewRead` → `readActivePreview`: nothing open answers empty;
  /// a page that cannot be read yet answers its identity and a note.
  Future<PreviewBridgeAnswer> _read(
    AgentBrowserPage? page,
    Map<String, dynamic> params,
  ) async {
    if (page == null) return const PreviewBridgeAnswer.value('');
    final url = page.currentUrl.isNotEmpty ? page.currentUrl : page.initialUrl;
    page.setAgentReading(true);
    try {
      // Never longer than an action: a stuck page answers the note instead
      // of holding the request (REVIEW-R5-B #9).
      final raw = await page
          .runScript(agentPreviewTextScript)
          .timeout(_readTimeout);
      final text = decodeWebViewString(raw);
      if (text == null) throw StateError('page not ready');
      final title = await page.title().timeout(
        _readTimeout,
        onTimeout: () => '',
      );
      // Say it on the page, as Desktop does (`nudgeOverlay('read')`): a no-op
      // on a page the agent never acted on.
      unawaited(_engine.nudge(page.runScript, 'read'));
      return PreviewBridgeAnswer.value(
        jsonEncode(
          windowAgentPreviewText(
            url: url,
            title: title.isNotEmpty ? title : page.label,
            text: text,
            params: params,
            tabs: _tabsOf(page),
          ),
        ),
      );
    } catch (_) {
      return PreviewBridgeAnswer.value(
        jsonEncode(
          windowAgentPreviewText(
            url: url,
            title: page.label,
            text: '',
            params: params,
            note: 'The page has not finished loading — retry in a moment.',
            tabs: _tabsOf(page),
          ),
        ),
      );
    } finally {
      page.setAgentReading(false);
    }
  }

  /// The tabs open beside [page] and which one it is, for a read.
  static ({List<AgentPreviewTabSummary> tabs, String activeId})? _tabsOf(
    AgentBrowserPage page,
  ) {
    if (page is! AgentBrowserTabbedPage) return null;
    return (tabs: page.tabsHost.tabSummaries, activeId: page.tabId);
  }

  /// Desktop `previewAct` → `actOnActivePreview`, on the scripted path (the
  /// one Desktop takes when a pane has no real input channel).
  Future<Map<String, Object?>> _act(
    AgentBrowserPage? page,
    PreviewBridgeRequest request,
  ) async {
    final p = request.params;
    final action = agentPreviewActAction(p);
    if (page == null) {
      return {'error': agentPreviewNothingOpen, 'success': false};
    }
    page.setAgentReading(true);
    try {
      return await _engine.act(
        page,
        action,
        // Stops the trip once Hermes withdrew it or the page left the screen.
        isOpen: () => request.isOpen() && page.onScreen,
      );
    } catch (_) {
      // Never a platform's text for the model.
      return {'error': agentPreviewNoAnswer, 'success': false};
    } finally {
      page.setAgentReading(false);
    }
  }
}

/// Desktop's note when a read had several tabs to choose from
/// (`preview-reader.ts`, `withMultiNote`).
const String agentPreviewMultiTabNote =
    'Multiple preview tabs are open; this read used the hovered or focused '
    'preview (see tabs).';

/// Desktop's read answer (`preview-reader.ts`, `windowText`): `{kind, url,
/// title, text, start, end, total_chars}` plus a `note` when there is one,
/// paged by character offset and capped at [agentPreviewReadMaxChars]. With
/// more than one tab open, `tabs` and `active_tab_id` say which ones and
/// which this read used (Desktop's `zoneMeta`).
Map<String, Object?> windowAgentPreviewText({
  required String url,
  required String title,
  required String text,
  required Map<String, dynamic> params,
  String? note,
  ({List<AgentPreviewTabSummary> tabs, String activeId})? tabs,
}) {
  int? asInt(Object? value) => value is num ? value.toInt() : null;
  final total = text.length;
  final from = math.min(math.max(asInt(params['start']) ?? 0, 0), total);
  final want = math.min(
    math.max(asInt(params['count']) ?? agentPreviewReadMaxChars, 1),
    agentPreviewReadMaxChars,
  );
  final to = math.max(from, math.min(from + want, total));
  final open = tabs != null && tabs.tabs.length > 1 ? tabs : null;
  var shownNote = note;
  if (open != null) shownNote = [?note, agentPreviewMultiTabNote].join(' ');
  return {
    if (open != null) 'active_tab_id': open.activeId,
    if (open != null) 'tabs': [for (final tab in open.tabs) tab.toJson()],
    'kind': 'url',
    'note': ?shownNote,
    'title': title,
    'url': url,
    'end': to,
    'start': from,
    'text': text.substring(from, to),
    'total_chars': total,
  };
}

/// What `runJavaScriptReturningResult` gave for a script that yields a
/// string: Android hands strings back JSON-quoted, iOS and the test fake as
/// they are. Null when the page answered nothing usable.
String? decodeWebViewString(Object? raw) {
  if (raw is! String) return null;
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
    } on FormatException {
      return raw;
    }
  }
  return raw;
}
