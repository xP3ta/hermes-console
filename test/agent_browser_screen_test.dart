import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/browser/agent_browser_bridge.dart';
import 'package:hermes_android/core/browser/agent_preview_act.dart';
import 'package:hermes_android/core/browser/agent_preview_offer_card.dart';
import 'package:hermes_android/core/browser/agent_preview_protocol.dart';
import 'package:hermes_android/core/browser/hermes_preview_engine.g.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_html_policy.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

class _NoSettings implements ArtifactWebViewPlatformSettings {
  @override
  Future<void> setAllowFileAccess(bool allow) async {}
  @override
  Future<void> setAllowContentAccess(bool allow) async {}
  @override
  Future<void> setGeolocationEnabled(bool enabled) async {}
  @override
  Future<void> denyGeolocationPrompts() async {}
  @override
  Future<void> setMixedContentNeverAllow() async {}
  @override
  Future<void> setMediaPlaybackRequiresUserGesture(bool require) async {}
  @override
  Future<void> refuseFileChooser() async {}
}

PreviewBridgeRequest _req(
  String method, [
  Map<String, dynamic> params = const {},
  String connection = 'conn-a',
]) => PreviewBridgeRequest(
  method: method,
  connectionId: connection,
  sessionId: 'rt-1',
  params: params,
  isOpen: () => true,
);

Widget _app(Widget home, {AppThemeMode mode = AppThemeMode.dark}) =>
    MaterialApp(
      theme: AppTheme.fromMode(mode),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: home,
    );

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

  Future<void> pumpBrowser(
    WidgetTester tester, {
    Uri? initialUrl,
    String label = '',
    bool openedByAgent = false,
  }) async {
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
        builder: (_) => InAppBrowserScreen(
          initialUrl: initialUrl,
          agentLabel: label,
          openedByAgent: openedByAgent,
          agentConnectionId: 'conn-a',
          agentSessionId: () => 'rt-1',
          bridge: bridge,
          settingsFor: (_) => _NoSettings(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  FakeNavigationDelegate delegate() => web.last.navigationDelegate!;

  testWidgets('the open browser is the chat\'s page for the agent', (
    tester,
  ) async {
    await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
    expect(bridge.page, isNotNull);
    expect(bridge.page!.ownerConnectionId, 'conn-a');
    expect(bridge.page!.ownerSessionId, 'rt-1');
    expect(bridge.page!.onScreen, isTrue);
    expect(bridge.sessionOnScreen('conn-a', 'rt-1'), isTrue);
    expect(bridge.sessionOnScreen('conn-a', 'rt-2'), isFalse);
    // The same runtime id on another connection is another chat.
    expect(bridge.sessionOnScreen('conn-b', 'rt-1'), isFalse);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(bridge.page, isNull);
  });

  testWidgets('preview.read answers the page text at once: no dialog', (
    tester,
  ) async {
    await pumpBrowser(
      tester,
      initialUrl: Uri.parse('https://a.example'),
      label: 'A',
    );
    web.last
      ..title = 'Página A'
      ..javaScriptResponder = (script) =>
          script == agentPreviewTextScript ? '"Hola desde A"' : 'cold';
    delegate().load('https://a.example/');
    await tester.pump();

    final answer = await bridge.answer(_req('preview.read'));
    await tester.pump();
    expect(answer.notShown, isFalse);
    expect(jsonDecode(answer.value), {
      'kind': 'url',
      'title': 'Página A',
      'url': 'https://a.example/',
      'end': 12,
      'start': 0,
      'text': 'Hola desde A',
      'total_chars': 12,
    });
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a read shows «Hermes está leyendo esta página» for a moment', (
    tester,
  ) async {
    await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
    web.last.javaScriptResponder = (_) => '"Hola"';
    final reading = find.byKey(
      const ValueKey('in-app-browser-agent-reading'),
    );
    expect(reading, findsNothing);
    final answer = bridge.answer(_req('preview.read'));
    await tester.pump();
    expect(reading, findsOneWidget);
    expect(find.text('Hermes está leyendo esta página'), findsOneWidget);
    expect((await answer).notShown, isFalse);
    // It stays long enough to be seen, then goes.
    await tester.pump(const Duration(milliseconds: 500));
    expect(reading, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(reading, findsNothing);
  });

  testWidgets('another connection\'s session never reads this page', (
    tester,
  ) async {
    await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
    web.last.javaScriptResponder = (_) => '"texto privado"';
    final answer = await bridge.answer(
      _req('preview.read', const {}, 'conn-b'),
    );
    expect(answer.notShown, isTrue);
    expect(web.last.javaScriptCalls, isEmpty);
  });

  testWidgets('a page covered by another screen is not read', (tester) async {
    await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('encima')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect((await bridge.answer(_req('preview.read'))).notShown, isTrue);
  });

  group('a workspace tab (REVIEW-R5-B #3)', () {
    // As in the workspace: the browser is the root of a tab's own
    // Navigator, hidden with its tickers off when another tab shows.
    Future<ValueNotifier<bool>> pumpTab(WidgetTester tester) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.fromMode(AppThemeMode.dark),
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, shown, child) => Offstage(
                offstage: !shown,
                child: TickerMode(enabled: shown, child: child!),
              ),
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => InAppBrowserScreen(
                    initialUrl: Uri.parse('https://a.example'),
                    agentConnectionId: 'conn-a',
                    agentSessionId: () => 'rt-1',
                    bridge: bridge,
                    settingsFor: (_) => _NoSettings(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      return visible;
    }

    testWidgets('a hidden tab is not on screen and is not read', (
      tester,
    ) async {
      final visible = await pumpTab(tester);
      expect(bridge.page!.onScreen, isTrue);
      visible.value = false;
      await tester.pump();
      expect(bridge.page!.onScreen, isFalse);
      expect((await bridge.answer(_req('preview.read'))).notShown, isTrue);
      expect(web.last.javaScriptCalls, isEmpty);
    });

    testWidgets('an app in the background shows nothing', (tester) async {
      await pumpTab(tester);
      expect(bridge.page!.onScreen, isTrue);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(bridge.page!.onScreen, isFalse);
      expect((await bridge.answer(_req('preview.read'))).notShown, isTrue);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(bridge.page!.onScreen, isTrue);
    });

    testWidgets('a locked app (the real app-lock fence) shows nothing', (
      tester,
    ) async {
      final visible = await pumpTab(tester);
      expect(visible.value, isTrue);
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final locked = ValueNotifier(true);
      final issuer = Object();
      AppLockSensitiveReadFence.bind(issuer, prefs, locked);
      addTearDown(() async {
        await prefs.setBool('app_lock_enabled', false);
        AppLockSensitiveReadFence.unbind(issuer);
        locked.dispose();
      });
      web.last.javaScriptResponder = (_) => '"texto privado"';
      expect((await bridge.answer(_req('preview.read'))).notShown, isTrue);
      expect(web.last.javaScriptCalls, isEmpty);
      // Unlocked again: the page in view is the agent's to read.
      locked.value = false;
      expect((await bridge.answer(_req('preview.read'))).notShown, isFalse);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a screen over the whole app hides the tab too', (
      tester,
    ) async {
      await pumpTab(tester);
      expect(bridge.page!.onScreen, isTrue);
      // Settings, the lock screen…: pushed on the app's own Navigator.
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('encima')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(bridge.page!.onScreen, isFalse);
      expect((await bridge.answer(_req('preview.read'))).notShown, isTrue);
    });
  });

  testWidgets('preview.open of that chat navigates the agent\'s page', (
    tester,
  ) async {
    await pumpBrowser(
      tester,
      initialUrl: Uri.parse('https://a.example'),
      openedByAgent: true,
    );
    bridge.onAgentPreviewEvent(
      connectionId: 'conn-a',
      sessionId: 'rt-1',
      type: 'preview.open',
      payload: {'url': 'https://b.example/', 'label': 'B'},
    );
    await tester.pump();
    expect(web.last.loadedRequests.last, Uri.parse('https://b.example/'));
    expect(find.byType(InAppBrowserScreen), findsOneWidget);
  });

  testWidgets('preview.open over the user\'s page offers «Ver» instead', (
    tester,
  ) async {
    await pumpBrowser(tester, initialUrl: Uri.parse('https://mine.example'));
    delegate().load('https://mine.example/');
    await tester.pump();
    final loads = web.last.loadedRequests.length;
    bridge.onAgentPreviewEvent(
      connectionId: 'conn-a',
      sessionId: 'rt-1',
      type: 'preview.open',
      payload: {'url': 'https://b.example/', 'label': 'B'},
    );
    await tester.pump();
    // The user's page stays: nothing loaded, the address is the same.
    expect(web.last.loadedRequests, hasLength(loads));
    expect(bridge.page!.currentUrl, 'https://mine.example/');
    expect(
      bridge.offerFor('conn-a', 'rt-1')?.url,
      Uri.parse('https://b.example/'),
    );
    expect(find.byKey(const ValueKey('agent-preview-offer')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-preview-offer-open')));
    await tester.pump();
    expect(web.last.loadedRequests.last, Uri.parse('https://b.example/'));
    expect(bridge.page!.openedByAgent, isTrue);
    expect(bridge.offerFor('conn-a', 'rt-1'), isNull);
    expect(find.byKey(const ValueKey('agent-preview-offer')), findsNothing);
  });

  testWidgets('a blank browser shows the agent\'s page at once', (
    tester,
  ) async {
    await pumpBrowser(tester);
    expect(bridge.page!.blank, isTrue);
    bridge.onAgentPreviewEvent(
      connectionId: 'conn-a',
      sessionId: 'rt-1',
      type: 'preview.open',
      payload: {'url': 'https://b.example/'},
    );
    await tester.pump();
    expect(web.last.loadedRequests.last, Uri.parse('https://b.example/'));
    expect(bridge.offerFor('conn-a', 'rt-1'), isNull);
  });

  testWidgets('following a link makes the agent\'s page the user\'s (#26)', (
    tester,
  ) async {
    await pumpBrowser(
      tester,
      initialUrl: Uri.parse('https://a.example'),
      openedByAgent: true,
    );
    final page = bridge.page!;
    // A click the agent makes is still the agent's page.
    page.setAgentReading(true);
    await delegate().onNavigationRequest!(
      const NavigationRequest(url: 'https://a.example/b', isMainFrame: true),
    );
    page.setAgentReading(false);
    expect(page.openedByAgent, isTrue);
    // A frame inside the page is not the page.
    await delegate().onNavigationRequest!(
      const NavigationRequest(url: 'https://ads.example/', isMainFrame: false),
    );
    expect(page.openedByAgent, isTrue);
    // The user follows a link: the page is the user's now, and the agent's
    // next page waits behind «Ver» instead of replacing it.
    await delegate().onNavigationRequest!(
      const NavigationRequest(url: 'https://a.example/c', isMainFrame: true),
    );
    expect(page.openedByAgent, isFalse);
    bridge.onAgentPreviewEvent(
      connectionId: 'conn-a',
      sessionId: 'rt-1',
      type: 'preview.open',
      payload: {'url': 'https://b.example/'},
    );
    await tester.pump();
    expect(bridge.offerFor('conn-a', 'rt-1'), isNotNull);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('an address the user types makes the page the user\'s', (
    tester,
  ) async {
    await pumpBrowser(
      tester,
      initialUrl: Uri.parse('https://a.example'),
      openedByAgent: true,
    );
    expect(bridge.page!.openedByAgent, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('in-app-browser-address')),
      'mine.example',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(bridge.page!.openedByAgent, isFalse);
  });

  testWidgets('preview.close of that chat closes the browser', (tester) async {
    await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
    delegate().load('https://a.example/');
    await tester.pump();
    bridge.onAgentPreviewEvent(
      connectionId: 'conn-a',
      sessionId: 'rt-1',
      type: 'preview.close',
      payload: {'url': 'https://a.example/'},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(InAppBrowserScreen), findsNothing);
    expect(find.text('chat-under'), findsOneWidget);
  });

  testWidgets('drive_preview elements runs Desktop\'s engine in the WebView', (
    tester,
  ) async {
    await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
    final inventory = {
      'elements': [
        {'ref': 'btn-sign-in', 'role': 'button', 'label': 'Sign in'},
      ],
      'success': true,
      'title': 'A',
      'url': 'https://a.example/',
    };
    web.last.javaScriptResponder = (script) {
      if (script.contains('w.__hermesTrips[id] = { v: v }')) return 'started';
      if (script.contains('delete w.__hermesTrips')) {
        return jsonEncode(jsonEncode({'v': jsonEncode(inventory)}));
      }
      return '';
    };
    final answer = await tester.runAsync(
      () => bridge.answer(_req('preview.act', {'action': 'elements'})),
    );
    expect(jsonDecode(answer!.value), inventory);
    expect(
      web.last.javaScriptCalls.first,
      contains('w.__hermesAct = (function (doc, holder, action)'),
    );
  });

  group('AgentPreviewOfferCard', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      AppThemeMode mode = AppThemeMode.dark,
      double textScale = 1,
      String? session = 'rt-1',
      ValueChanged<AgentPreviewOffer>? onOpen,
    }) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: AgentPreviewOfferCard(
                bridge: bridge,
                connectionId: 'conn-a',
                sessionId: session,
                onOpen: onOpen ?? (_) {},
              ),
            ),
          ),
          mode: mode,
        ),
      );
    }

    void offer() => bridge.onAgentPreviewEvent(
      connectionId: 'conn-a',
      sessionId: 'rt-1',
      type: 'preview.open',
      payload: {'url': 'https://news.example/', 'label': 'Noticias'},
    );

    testWidgets('shows the agent\'s offer for this chat only', (tester) async {
      offer();
      await pumpCard(tester, session: 'rt-2');
      expect(find.byKey(const ValueKey('agent-preview-offer')), findsNothing);
      await pumpCard(tester);
      expect(find.byKey(const ValueKey('agent-preview-offer')), findsOneWidget);
      expect(find.text('Hermes quiere enseñarte una página'), findsOneWidget);
      expect(find.text('Noticias'), findsOneWidget);
    });

    testWidgets('the host is always shown; a tricky label is dropped (#22)', (
      tester,
    ) async {
      offer();
      await pumpCard(tester);
      // The agent's label never stands alone: the real host is under it.
      expect(find.text('Noticias'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('agent-preview-offer-host')),
            )
            .data,
        'news.example',
      );
      // A right-to-left override or a control character could disguise
      // the name: such a label is not shown at all.
      bridge.onAgentPreviewEvent(
        connectionId: 'conn-a',
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://evil.example/', 'label': 'Tu \u202Eocnab'},
      );
      await tester.pump();
      expect(bridge.offerFor('conn-a', 'rt-1')?.label, '');
      expect(find.textContaining('ocnab'), findsNothing);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('agent-preview-offer-host')),
            )
            .data,
        'evil.example',
      );
    });

    testWidgets('«Ver» opens the page and «Descartar» drops it', (
      tester,
    ) async {
      final opened = <AgentPreviewOffer>[];
      offer();
      await pumpCard(tester, onOpen: opened.add);
      await tester.tap(find.byKey(const ValueKey('agent-preview-offer-open')));
      await tester.pump();
      expect(opened.single.url, Uri.parse('https://news.example/'));
      expect(bridge.offerFor('conn-a', 'rt-1'), isNull);
      expect(find.byKey(const ValueKey('agent-preview-offer')), findsNothing);

      offer();
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('agent-preview-offer-dismiss')),
      );
      await tester.pump();
      expect(bridge.offerFor('conn-a', 'rt-1'), isNull);
      expect(opened, hasLength(1));
    });

    for (final mode in [AppThemeMode.light, AppThemeMode.dark]) {
      testWidgets('${mode.name}: theme tokens', (tester) async {
        offer();
        await pumpCard(tester, mode: mode);
        final colors = Theme.of(
          tester.element(find.byKey(const ValueKey('agent-preview-offer'))),
        ).hermes;
        final card = tester.widget<Material>(
          find.byKey(const ValueKey('agent-preview-offer')),
        );
        expect(card.color, colors.surfaceVariant);
      });
    }

    testWidgets('text at 2x on a small phone: no overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      offer();
      await pumpCard(tester, textScale: 2);
      expect(tester.takeException(), isNull);
    });
  });
}
