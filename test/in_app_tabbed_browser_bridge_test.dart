// Q9-NAV (the owner's decisions 1 a and 2 a, as Hermes Desktop's preview tabs):
// the agent reads and drives the tab on screen, and its read lists every
// tab and which one it used; its open goes to its own tab, brought to the
// front, never to one of the user's; its close takes the tab at an address
// or all of them; the user closing the agent's tab mid-act leaves nothing
// behind.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/agent_browser_bridge.dart';
import 'package:hermes_android/core/browser/agent_preview_act.dart';
import 'package:hermes_android/core/browser/agent_preview_protocol.dart';
import 'package:hermes_android/core/browser/browser_tabs.dart';
import 'package:hermes_android/core/browser/hermes_preview_engine.g.dart';
import 'package:hermes_android/core/browser/in_app_tabbed_browser.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

final _boletin = Uri.parse('https://boletin.ejemplo.dev/semana-43');
final _docs = Uri.parse('https://docs.ejemplo.dev/');
final _tienda = Uri.parse('https://tienda.ejemplo.dev/');

PreviewBridgeRequest _req(
  String method, [
  Map<String, dynamic> params = const {},
]) => PreviewBridgeRequest(
  method: method,
  connectionId: 'conn-a',
  sessionId: 'rt-1',
  params: params,
  isOpen: () => true,
);

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  late FakeWebViewPlatform web;
  late AgentBrowserBridge bridge;
  late GlobalKey<NavigatorState> navigator;

  setUp(() {
    web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;
    bridge = AgentBrowserBridge(
      engine: AgentPreviewActEngine(
        () async => hermesPreviewEngine,
        pollEvery: const Duration(milliseconds: 1),
      ),
    );
    navigator = GlobalKey<NavigatorState>();
  });

  /// The browser over a chat, as `_openInAppBrowser` pushes it.
  Future<void> pump(WidgetTester tester, BrowserTabs tabs) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.fromMode(AppThemeMode.dark),
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: Text('chat-under')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => InAppTabbedBrowser(
          tabs: tabs,
          agentConnectionId: 'conn-a',
          agentSessionId: () => 'rt-1',
          bridge: bridge,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  void open(Uri url, String label) => bridge.onAgentPreviewEvent(
    connectionId: 'conn-a',
    sessionId: 'rt-1',
    type: 'preview.open',
    payload: {'url': url.toString(), 'label': label},
  );

  void close([Uri? url]) => bridge.onAgentPreviewEvent(
    connectionId: 'conn-a',
    sessionId: 'rt-1',
    type: 'preview.close',
    payload: {'url': ?url?.toString()},
  );

  /// The WebView that was given [url] first.
  FakeWebViewController viewOf(Uri url) =>
      web.controllers.firstWhere((c) => c.loadedRequests.contains(url));

  test('a read lists the tabs only when more than one is open', () {
    const one = AgentPreviewTabSummary(id: 'a', label: 'A', url: 'about:x');
    const two = AgentPreviewTabSummary(id: 'b', label: 'B', url: 'about:y');
    final single = windowAgentPreviewText(
      url: 'about:x',
      title: 'A',
      text: 'hola',
      params: const {},
      tabs: (tabs: const [one], activeId: 'a'),
    );
    expect(single.containsKey('tabs'), isFalse);
    expect(single.containsKey('active_tab_id'), isFalse);
    expect(single.containsKey('note'), isFalse);
    final both = windowAgentPreviewText(
      url: 'about:y',
      title: 'B',
      text: 'hola',
      params: const {},
      note: 'Not yet.',
      tabs: (tabs: const [one, two], activeId: 'b'),
    );
    expect(both['active_tab_id'], 'b');
    expect(both['tabs'], [one.toJson(), two.toJson()]);
    expect(both['note'], 'Not yet. $agentPreviewMultiTabNote');
  });

  testWidgets('preview.read reads the tab in front and lists every tab', (
    tester,
  ) async {
    final tabs = BrowserTabs()..open(url: _docs);
    final agent = tabs.openAgent(_boletin, 'Boletín');
    final mine = tabs.tabs.first;
    await pump(tester, tabs);
    viewOf(_boletin).javaScriptResponder = (script) =>
        script == agentPreviewTextScript ? '"Hola desde el boletín"' : 'cold';
    viewOf(_docs).javaScriptResponder = (script) =>
        script == agentPreviewTextScript ? '"Hola desde docs"' : 'cold';

    final answer = await bridge.answer(_req('preview.read'));
    await tester.pump();
    final read = jsonDecode(answer.value) as Map<String, dynamic>;
    expect(read['text'], 'Hola desde el boletín');
    expect(read['active_tab_id'], agent.id);
    expect(read['tabs'], [
      {
        'id': mine.id,
        'kind': 'url',
        'label': 'docs.ejemplo.dev',
        'url': _docs.toString(),
      },
      {
        'id': agent.id,
        'kind': 'url',
        'label': 'Boletín',
        'url': _boletin.toString(),
      },
    ]);
    expect(read['note'], agentPreviewMultiTabNote);

    // The user brings their tab to the front: the next read is that one.
    tabs.activate(mine.id);
    await tester.pump();
    final next = await bridge.answer(_req('preview.read'));
    await tester.pump();
    final again = jsonDecode(next.value) as Map<String, dynamic>;
    expect(again['text'], 'Hola desde docs');
    expect(again['active_tab_id'], mine.id);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('preview.open goes to the agent\'s tab and brings it to the '
      'front; the user\'s tab is left alone', (tester) async {
    final tabs = BrowserTabs();
    final agent = tabs.openAgent(_boletin, 'Boletín');
    final mine = tabs.open(url: _docs);
    await pump(tester, tabs);
    expect(tabs.active, same(mine));

    open(_tienda, 'Tienda');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.length, 2);
    expect(tabs.active, same(agent));
    expect(agent.url, _tienda);
    expect(agent.label, 'Tienda');
    expect(mine.url, _docs, reason: 'the user\'s page is untouched');
    expect(viewOf(_boletin).loadedRequests.last, _tienda);
    expect(viewOf(_docs).loadedRequests.last, _docs);
    expect(_key('browser-tab-screen-${agent.id}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no tab of its own, the agent\'s page opens a new tab in '
      'front', (tester) async {
    final tabs = BrowserTabs();
    final mine = tabs.open(url: _docs);
    await pump(tester, tabs);

    open(_tienda, 'Tienda');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.length, 2);
    final agent = tabs.active!;
    expect(agent, isNot(same(mine)));
    expect(agent.agent, isTrue);
    expect(agent.url, _tienda);
    expect(mine.url, _docs);
    expect(viewOf(_tienda), isNotNull);
    expect(bridge.pageOf('conn-a', 'rt-1')!.openedByAgent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview.close with an address closes that tab; without one, '
      'every tab and the browser', (tester) async {
    final tabs = BrowserTabs()..openAgent(_boletin, 'Boletín');
    final mine = tabs.open(url: _docs);
    await pump(tester, tabs);

    close(_boletin);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.tabs, [mine], reason: 'no blank tab, no «Deshacer»');
    expect(tabs.canUndo, isFalse);
    expect(_key('browser-tabs'), findsOneWidget);
    expect(viewOf(_boletin).loadedRequests.last, Uri.parse('about:blank'));

    // An address no tab is at closes nothing.
    close(_tienda);
    await tester.pump();
    expect(tabs.tabs, [mine]);

    close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tabs.isEmpty, isTrue);
    expect(_key('browser-tabs'), findsNothing);
    expect(find.text('chat-under'), findsOneWidget);
    expect(bridge.pageOf('conn-a', 'rt-1'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the user closes the agent\'s tab mid-act: its page goes '
      'blank, leaves the bridge, and the act ends', (tester) async {
    final tabs = BrowserTabs()..open(url: _docs);
    final agent = tabs.openAgent(_boletin, 'Boletín');
    await pump(tester, tabs);
    final view = viewOf(_boletin);
    // The page takes the trip and never parks an answer.
    view.javaScriptResponder = (script) =>
        script.contains('w.__hermesTrips[id] = { v: v }') ? 'started' : '';
    final page = bridge.pageOf('conn-a', 'rt-1')!;
    expect(page.openedByAgent, isTrue);

    var done = false;
    final act = bridge.answer(_req('preview.act', {'action': 'elements'}));
    unawaited(act.then((_) => done = true));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(done, isFalse, reason: 'still waiting for the page');

    // The browser opens with the tab in front in view: its × is a whole
    // target inside the strip, not under «+» or the count (gint64).
    final shut = _key('browser-tab-close-${agent.id}');
    final strip = tester.getRect(_key('browser-tab-list'));
    expect(strip.contains(tester.getCenter(shut)), isTrue);
    await tester.tap(shut);
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(done, isTrue);
    final result = jsonDecode((await act).value) as Map<String, dynamic>;
    expect(result['error'], isNull);
    expect(view.loadedRequests.last, Uri.parse('about:blank'));
    expect(page.onScreen, isFalse);
    expect(bridge.pageOf('conn-a', 'rt-1'), isNot(same(page)));
    expect(tabs.agentTab, isNull);
    expect(_key('browser-tabs'), findsOneWidget, reason: 'the browser stays');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 7));
  });
}
