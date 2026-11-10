import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/in_app_browser_policy.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_html_policy.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

class _RecordingSettings implements ArtifactWebViewPlatformSettings {
  final List<String> calls = [];

  @override
  Future<void> setAllowFileAccess(bool allow) async =>
      calls.add('fileAccess:$allow');
  @override
  Future<void> setAllowContentAccess(bool allow) async =>
      calls.add('contentAccess:$allow');
  @override
  Future<void> setGeolocationEnabled(bool enabled) async =>
      calls.add('geolocation:$enabled');
  @override
  Future<void> denyGeolocationPrompts() async => calls.add('denyGeoPrompts');
  @override
  Future<void> setMixedContentNeverAllow() async => calls.add('mixedNever');
  @override
  Future<void> setMediaPlaybackRequiresUserGesture(bool require) async =>
      calls.add('mediaGesture:$require');
  @override
  Future<void> refuseFileChooser() async => calls.add('noFileChooser');
}

NavigationRequest _main(String url) =>
    NavigationRequest(url: url, isMainFrame: true);
NavigationRequest _frame(String url) =>
    NavigationRequest(url: url, isMainFrame: false);

void main() {
  group('address bar (Desktop normalizePreviewAddress, http/https only)', () {
    test('a bare host gets https, a bare loopback host gets http', () {
      expect(
        normalizeBrowserAddress('example.com').toString(),
        'https://example.com',
      );
      expect(
        normalizeBrowserAddress('  example.com/path?q=1  ').toString(),
        'https://example.com/path?q=1',
      );
      expect(
        normalizeBrowserAddress('localhost:5173').toString(),
        'http://localhost:5173',
      );
      expect(
        normalizeBrowserAddress('127.0.0.1:8080/app').toString(),
        'http://127.0.0.1:8080/app',
      );
      expect(normalizeBrowserAddress('[::1]:3000')?.scheme, 'http');
      expect(
        normalizeBrowserAddress('HTTP://Example.com')?.host,
        'example.com',
      );
      expect(normalizeBrowserAddress('https://x.dev')?.scheme, 'https');
    });

    test('every other scheme and junk never navigate', () {
      for (final typed in [
        '',
        '   ',
        'javascript:alert(1)',
        'data:text/html,<h1>x</h1>',
        'file:///etc/hosts',
        'about:blank',
        'intent://scan/#Intent;scheme=zxing;end',
        'market://details?id=x',
        'content://media/external',
        'mailto:a@b.c',
        'tel:123',
        'view-source:https://example.com',
        'http://',
        'exa mple.com',
      ]) {
        expect(normalizeBrowserAddress(typed), isNull, reason: typed);
      }
    });
  });

  group('navigation policy', () {
    test('the main frame only goes to http and https', () {
      expect(
        inAppBrowserNavigationDecision(_main('https://example.com/')),
        NavigationDecision.navigate,
      );
      expect(
        inAppBrowserNavigationDecision(_main('http://example.com/')),
        NavigationDecision.navigate,
      );
      for (final url in [
        'intent://scan/#Intent;end',
        'market://details?id=x',
        'tel:123',
        'mailto:a@b.c',
        'file:///sdcard/x.html',
        'content://x',
        'javascript:alert(1)',
        'about:blank',
        'data:text/html,x',
        'not a url',
      ]) {
        expect(
          inAppBrowserNavigationDecision(_main(url)),
          NavigationDecision.prevent,
          reason: url,
        );
      }
    });

    test('a frame inside the page may use inert documents, nothing else', () {
      expect(
        inAppBrowserNavigationDecision(_frame('about:blank')),
        NavigationDecision.navigate,
      );
      expect(
        inAppBrowserNavigationDecision(_frame('https://ads.example/')),
        NavigationDecision.navigate,
      );
      expect(
        inAppBrowserNavigationDecision(_frame('intent://x#Intent;end')),
        NavigationDecision.prevent,
      );
    });

    test('only an http/https page can be handed to the system browser', () {
      expect(browserExternalUri('https://example.com/a')?.host, 'example.com');
      expect(browserExternalUri('http://example.com')?.scheme, 'http');
      for (final url in ['', 'about:blank', 'file:///x', 'intent://x']) {
        expect(browserExternalUri(url), isNull, reason: url);
      }
    });

    test('load errors are titled like Desktop', () {
      expect(
        classifyBrowserLoadError('net::ERR_CONNECTION_REFUSED'),
        InAppBrowserErrorKind.serverNotFound,
      );
      expect(
        classifyBrowserLoadError('404 Not Found'),
        InAppBrowserErrorKind.serverNotFound,
      );
      expect(
        classifyBrowserLoadError('net::ERR_NAME_NOT_RESOLVED'),
        InAppBrowserErrorKind.failedToLoad,
      );
      expect(
        classifyBrowserLoadError(''),
        InAppBrowserErrorKind.failedToLoad,
      );
      // REVIEW-F3 P2-2: the manifest refuses cleartext; not a Desktop case.
      expect(
        classifyBrowserLoadError('net::ERR_CLEARTEXT_NOT_PERMITTED'),
        InAppBrowserErrorKind.cleartextBlocked,
      );
    });

    test('the error never paints user:password from an address', () {
      expect(
        browserDisplayUrl('https://user:secret@example.com/a'),
        'https://example.com/a',
      );
      expect(
        browserDisplayUrl('https://example.com/a'),
        'https://example.com/a',
      );
      expect(browserDisplayUrl('not a url'), 'not a url');
    });

    test('loopback addresses are recognised', () {
      expect(isLoopbackBrowserUrl('http://localhost:5173/'), isTrue);
      expect(isLoopbackBrowserUrl('http://127.0.0.1/'), isTrue);
      expect(isLoopbackBrowserUrl('http://[::1]:3000/'), isTrue);
      expect(isLoopbackBrowserUrl('http://0.0.0.0:80/'), isTrue);
      expect(isLoopbackBrowserUrl('https://example.com/'), isFalse);
      expect(isLoopbackBrowserUrl('http://192.168.1.2/'), isFalse);
    });
  });

  group('InAppBrowserScreen', () {
    late FakeWebViewPlatform web;
    late _RecordingSettings settings;
    late List<Uri> launched;
    late GlobalKey<NavigatorState> navigator;

    setUp(() {
      web = FakeWebViewPlatform();
      WebViewPlatform.instance = web;
      settings = _RecordingSettings();
      launched = [];
      navigator = GlobalKey<NavigatorState>();
    });

    Future<bool> launch(Uri uri) async {
      launched.add(uri);
      return true;
    }

    /// A "chat" page with the browser pushed on top, like the notch does.
    Future<void> pumpBrowser(
      WidgetTester tester, {
      AppThemeMode mode = AppThemeMode.dark,
      double textScale = 1,
      Uri? initialUrl,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.fromMode(mode),
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: Text('chat-under')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => InAppBrowserScreen(
            initialUrl: initialUrl,
            launchExternal: launch,
            settingsFor: (_) => settings,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    FakeNavigationDelegate delegate() => web.last.navigationDelegate!;

    Strings strings(WidgetTester tester) =>
        Strings.of(tester.element(find.byType(InAppBrowserScreen)));

    bool enabled(WidgetTester tester, String key) =>
        tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed !=
        null;

    final address = find.byKey(const ValueKey('in-app-browser-address'));
    final blank = find.byKey(const ValueKey('in-app-browser-blank'));
    final errorView = find.byKey(const ValueKey('in-app-browser-error'));

    Future<void> type(WidgetTester tester, String text) async {
      await tester.tap(address);
      await tester.pump();
      await tester.enterText(address, text);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
    }

    testWidgets('locks the WebView down before anything loads', (
      tester,
    ) async {
      await pumpBrowser(tester);
      final controller = web.last;
      expect(controller.javaScriptModes, [
        JavaScriptMode.disabled,
        JavaScriptMode.unrestricted,
      ]);
      expect(settings.calls, [
        'fileAccess:false',
        'contentAccess:false',
        'geolocation:false',
        'denyGeoPrompts',
        'mixedNever',
        'mediaGesture:true',
        'noFileChooser',
      ]);
      expect(controller.zoomEnabled, isTrue);
      // A page can never call into the app.
      expect(controller.javaScriptChannels, isEmpty);
      final request = FakePermissionRequest();
      controller.permissionHandler!(request);
      expect(request.denied, isTrue);
      expect(request.granted, isFalse);
    });

    testWidgets('opens blank: loads nothing, takes no focus, explains', (
      tester,
    ) async {
      await pumpBrowser(tester);
      expect(blank, findsOneWidget);
      expect(find.text(strings(tester).brwBlankPage), findsOneWidget);
      expect(web.last.loadedRequests, isEmpty);
      expect(tester.widget<TextField>(address).focusNode!.hasFocus, isFalse);
      expect(tester.widget<TextField>(address).controller!.text, isEmpty);
      for (final key in [
        'in-app-browser-back',
        'in-app-browser-forward',
        'in-app-browser-reload',
        'in-app-browser-open-external',
      ]) {
        expect(enabled(tester, key), isFalse, reason: key);
      }
    });

    testWidgets('a typed host loads over https and the bar follows the page', (
      tester,
    ) async {
      await pumpBrowser(tester);
      await type(tester, 'example.com');
      expect(web.last.loadedRequests, [Uri.parse('https://example.com')]);
      expect(
        find.byKey(const ValueKey('in-app-browser-loading')),
        findsOneWidget,
      );
      expect(blank, findsNothing);
      expect(
        tester.widget<TextField>(address).controller!.text,
        'https://example.com',
      );

      delegate().load('https://example.com/home');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('in-app-browser-loading')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(address).controller!.text,
        'https://example.com/home',
      );
      expect(enabled(tester, 'in-app-browser-reload'), isTrue);
      expect(enabled(tester, 'in-app-browser-open-external'), isTrue);
      expect(launched, isEmpty);
    });

    testWidgets('an address that is not http/https is flagged and never '
        'loads', (tester) async {
      await pumpBrowser(tester);
      await tester.tap(address);
      await tester.pump();
      await tester.enterText(address, 'javascript:alert(1)');
      await tester.pump();
      final colors = Theme.of(tester.element(address)).hermes;
      final field = tester.widget<TextField>(address);
      final border = field.decoration!.focusedBorder! as OutlineInputBorder;
      expect(border.borderSide.color, colors.error);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(web.last.loadedRequests, isEmpty);
      expect(launched, isEmpty);
      // Leaving the field drops the draft.
      expect(tester.widget<TextField>(address).controller!.text, isEmpty);
    });

    // The policy only; that the Android plugin turns window.open and
    // target=_blank into a navigation of this same WebView is checked by
    // hand on a device (REVIEW-F3 P3).
    testWidgets('the navigation policy refuses other schemes and launches '
        'nothing', (tester) async {
      await pumpBrowser(tester, initialUrl: Uri.parse('https://example.com'));
      delegate().load('https://example.com/');
      await tester.pump();
      expect(
        await delegate().request('intent://scan/#Intent;end'),
        NavigationDecision.prevent,
      );
      expect(
        await delegate().request('market://details?id=evil'),
        NavigationDecision.prevent,
      );
      // window.open / target=_blank reach the same delegate on Android and
      // stay inside this WebView.
      expect(
        await delegate().request('https://other.example/'),
        NavigationDecision.navigate,
      );
      await tester.pump();
      expect(launched, isEmpty);
    });

    testWidgets('back and forward follow the WebView\'s own history', (
      tester,
    ) async {
      await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
      expect(web.last.loadedRequests, [Uri.parse('https://a.example')]);
      expect(enabled(tester, 'in-app-browser-back'), isFalse);
      web.last.canGoBackValue = true;
      delegate().load('https://b.example/');
      await tester.pump();
      expect(enabled(tester, 'in-app-browser-back'), isTrue);
      expect(enabled(tester, 'in-app-browser-forward'), isFalse);
      await tester.tap(find.byKey(const ValueKey('in-app-browser-back')));
      await tester.pump();
      expect(web.last.goBackCalls, 1);

      web.last
        ..canGoBackValue = false
        ..canGoForwardValue = true;
      delegate().load('https://a.example/');
      await tester.pump();
      expect(enabled(tester, 'in-app-browser-forward'), isTrue);
      await tester.tap(find.byKey(const ValueKey('in-app-browser-forward')));
      await tester.pump();
      expect(web.last.goForwardCalls, 1);

      await tester.tap(find.byKey(const ValueKey('in-app-browser-reload')));
      await tester.pump();
      expect(web.last.reloadCalls, 1);
    });

    testWidgets('system Back walks the page history first, then leaves', (
      tester,
    ) async {
      await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
      web.last.canGoBackValue = true;
      delegate().load('https://b.example/');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(InAppBrowserScreen), findsOneWidget);
      expect(web.last.goBackCalls, 1);

      web.last.canGoBackValue = false;
      delegate().load('https://a.example/');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(InAppBrowserScreen), findsNothing);
      expect(find.text('chat-under'), findsOneWidget);
    });

    testWidgets('the notch goes back to the chat even with page history', (
      tester,
    ) async {
      // Disposed inside the test body: flutter_test checks for live
      // SemanticsHandles before tearDowns run, so addTearDown is too late.
      final semantics = tester.ensureSemantics();
      try {
        await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
        web.last.canGoBackValue = true;
        delegate().load('https://b.example/');
        await tester.pump();
        expect(
          find.bySemanticsLabel(strings(tester).brwBackToChat),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('in-app-browser-notch')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(InAppBrowserScreen), findsNothing);
        expect(find.text('chat-under'), findsOneWidget);
        expect(web.last.goBackCalls, 0);
      } finally {
        semantics.dispose();
      }
    });

    // Audit 2.9 (Ola 1): in the workspace pane the chat is beside the
    // browser. «Volver al chat» popped the tab's first route there, which
    // closed the tab; and the page's grey sat on the pane's grey (T1).
    testWidgets('in the pane: no way back to the chat, no page of its own', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromMode(AppThemeMode.dark),
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: ChatWorkspacePaneScope(
            tab: ChatWorkspaceTab.browser,
            child: InAppBrowserScreen(
              launchExternal: launch,
              settingsFor: (_) => settings,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('in-app-browser-notch')), findsNothing);
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('in-app-browser')))
            .backgroundColor,
        Colors.transparent,
      );
      // The page's card keeps its air at the foot of the pane.
      final card = tester.getRect(
        find.byKey(const ValueKey('in-app-browser-webview')),
      );
      final height =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(height - card.bottom, greaterThanOrEqualTo(8));
      expect(tester.takeException(), isNull);
    });

    testWidgets('full screen it keeps the notch and the page', (tester) async {
      await pumpBrowser(tester);
      expect(
        find.byKey(const ValueKey('in-app-browser-notch')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('in-app-browser')))
            .backgroundColor,
        AppTheme.fromMode(AppThemeMode.dark).hermes.background,
      );
    });

    testWidgets('leaving unloads the page so nothing keeps playing', (
      tester,
    ) async {
      await pumpBrowser(tester, initialUrl: Uri.parse('https://video.example'));
      delegate().load('https://video.example/watch');
      await tester.pump();
      final controller = web.last;
      expect(controller.loadedRequests.last, isNot(Uri.parse('about:blank')));
      await tester.tap(find.byKey(const ValueKey('in-app-browser-notch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(InAppBrowserScreen), findsNothing);
      expect(controller.loadedRequests.last, Uri.parse('about:blank'));
      expect(launched, isEmpty);
    });

    testWidgets('a failed load shows Desktop\'s error state and retries', (
      tester,
    ) async {
      await pumpBrowser(tester, initialUrl: Uri.parse('https://nope.invalid'));
      delegate().fail('https://nope.invalid/');
      await tester.pump();
      final s = strings(tester);
      expect(errorView, findsOneWidget);
      expect(find.text(s.brwFailedToLoad), findsOneWidget);
      expect(find.text('https://nope.invalid/ (-2)'), findsOneWidget);
      expect(find.text('net::ERR_NAME_NOT_RESOLVED'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('in-app-browser-remote-loopback')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('in-app-browser-retry')));
      await tester.pump();
      expect(web.last.loadedRequests.last, Uri.parse('https://nope.invalid/'));
      expect(errorView, findsNothing);

      delegate().fail(
        'https://down.example/',
        description: 'net::ERR_CONNECTION_REFUSED',
        code: -6,
      );
      await tester.pump();
      expect(find.text(s.brwServerNotFound), findsOneWidget);
    });

    testWidgets('a failing frame inside a healthy page changes nothing', (
      tester,
    ) async {
      await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
      delegate().load('https://a.example/');
      await tester.pump();
      delegate().fail('https://ads.example/x', mainFrame: false);
      await tester.pump();
      expect(errorView, findsNothing);
    });

    testWidgets('a loopback address explains it is not the agent\'s machine', (
      tester,
    ) async {
      await pumpBrowser(tester);
      await type(tester, 'localhost:5173');
      expect(web.last.loadedRequests, [Uri.parse('http://localhost:5173')]);
      delegate().fail(
        'http://localhost:5173/',
        description: 'net::ERR_CLEARTEXT_NOT_PERMITTED',
      );
      await tester.pump();
      expect(
        find.text(strings(tester).brwRemoteLoopback),
        findsOneWidget,
      );
    });

    testWidgets('an http page says the app only opens https and offers the '
        'system browser', (tester) async {
      await pumpBrowser(tester);
      await type(tester, 'http://example.com/plain');
      expect(web.last.loadedRequests, [Uri.parse('http://example.com/plain')]);
      delegate().fail(
        'http://example.com/plain',
        description: 'net::ERR_CLEARTEXT_NOT_PERMITTED',
      );
      await tester.pump();
      final s = strings(tester);
      expect(find.text(s.brwCleartextTitle), findsOneWidget);
      expect(find.text(s.brwCleartextBody), findsOneWidget);
      // Trying again can never work; the way on is the system browser.
      expect(find.byKey(const ValueKey('in-app-browser-retry')), findsNothing);
      expect(launched, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('in-app-browser-error-open-external')),
      );
      await tester.pump();
      expect(launched, [Uri.parse('http://example.com/plain')]);
    });

    testWidgets('only a tap by the user opens the system browser', (
      tester,
    ) async {
      await pumpBrowser(tester, initialUrl: Uri.parse('https://a.example'));
      delegate().load('https://a.example/page');
      await tester.pump();
      expect(launched, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('in-app-browser-open-external')),
      );
      await tester.pump();
      expect(launched, [Uri.parse('https://a.example/page')]);

      delegate().fail('https://gone.example/');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('in-app-browser-error-url')));
      await tester.pump();
      expect(launched.last, Uri.parse('https://gone.example/'));
    });

    for (final mode in [AppThemeMode.light, AppThemeMode.dark]) {
      testWidgets('${mode.name}: theme tokens, no hard-coded colours', (
        tester,
      ) async {
        await pumpBrowser(tester, mode: mode);
        final colors = Theme.of(tester.element(address)).hermes;
        final field = tester.widget<TextField>(address);
        expect(field.decoration!.fillColor, colors.surfaceVariant);
        final scaffold = tester.widget<Scaffold>(
          find.byKey(const ValueKey('in-app-browser')),
        );
        expect(scaffold.backgroundColor, colors.background);
        final blankBox = tester.widget<ColoredBox>(blank);
        expect(blankBox.color, colors.surface);
      });
    }

    for (final scale in [1.3, 2.0]) {
      testWidgets('text at ${scale}x on a small phone: no overflow', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await pumpBrowser(tester, textScale: scale);
        expect(tester.takeException(), isNull);
        expect(blank, findsOneWidget);

        delegate().fail(
          'http://localhost:5173/',
          description: 'net::ERR_CLEARTEXT_NOT_PERMITTED',
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(errorView, findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('in-app-browser-error-open-external')),
          80,
          scrollable: find.descendant(
            of: errorView,
            matching: find.byType(Scrollable),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
