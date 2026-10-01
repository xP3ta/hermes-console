import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_html_policy.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

// Same 1×1 transparent PNG used across the suite.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _NoSettings implements ArtifactWebViewPlatformSettings {
  int fileAccessOff = 0;

  @override
  Future<void> setAllowFileAccess(bool allow) async {
    if (!allow) fileAccessOff++;
  }

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

void main() {
  late FakeWebViewPlatform webPlatform;
  late FakeUrlLauncher launcher;
  late UrlLauncherPlatform previousLauncher;
  late _NoSettings settings;

  setUp(() {
    webPlatform = FakeWebViewPlatform();
    WebViewPlatform.instance = webPlatform;
    previousLauncher = UrlLauncherPlatform.instance;
    launcher = FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
    settings = _NoSettings();
  });

  tearDown(() => UrlLauncherPlatform.instance = previousLauncher);

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.fromMode(AppThemeMode.dark),
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: child,
  );

  Widget viewer(
    String name,
    String mime,
    Uint8List bytes, {
    VoidCallback? onOpenExternal,
    VoidCallback? onShare,
  }) => ArtifactViewerScreen(
    name: name,
    mimeType: mime,
    loadBytes: () async => bytes,
    sizeBytes: bytes.length,
    onOpenExternal: onOpenExternal,
    onShare: onShare,
    webViewSettingsFor: (_) => settings,
  );

  Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  group('HTML', () {
    const malicious =
        '<!doctype html><html><head>'
        '<meta http-equiv="refresh" content="0;url=https://evil.example/refresh">'
        '</head><body><a href="https://example.com/docs">docs</a>'
        '<script>location.href="https://evil.example/href";'
        'window.open("https://evil.example/popup");</script>'
        '<iframe src="file:///etc/passwd"></iframe></body></html>';

    testWidgets('renders directly with inline scripts in an isolated WebView, '
        'no scripts banner', (tester) async {
      await tester.pumpWidget(
        host(viewer('page.html', 'text/html', text(malicious))),
      );
      await settle(tester);

      final web = webPlatform.last;
      expect(find.byKey(const ValueKey('artifact-viewer-webview')), findsOne);
      // Scripts run like Desktop's sandboxed iframe: no opt-in nag.
      expect(web.javaScriptMode, JavaScriptMode.unrestricted);
      expect(web.loadedHtml, hasLength(1));
      final html = web.loadedHtml.single;
      expect(html, contains("script-src 'unsafe-inline'"));
      expect(html, contains("default-src 'none'"));
      expect(html, contains("connect-src 'none'"));
      expect(html, contains("frame-src 'none'"));
      // window.open is pinned to a no-op before any guest script runs.
      expect(
        html.indexOf('Object.defineProperty(window,"open"'),
        allOf(isNonNegative, lessThan(html.indexOf('location.href'))),
      );
      // Lock-down happens before the load and never exposes a bridge.
      expect(web.javaScriptModes.first, JavaScriptMode.disabled);
      expect(web.javaScriptChannels, isEmpty);
      expect(web.loadedFiles, isEmpty);
      expect(web.loadedRequests, isEmpty);
      expect(settings.fileAccessOff, 1);
      expect(
        find.byKey(const ValueKey('artifact-viewer-scripts-bar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('artifact-viewer-scripts-toggle')),
        findsNothing,
      );
      expect(find.textContaining('cripts'), findsNothing);
    });

    testWidgets('scripted redirects, refresh and window.open launch nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(viewer('page.html', 'text/html', text(malicious))),
      );
      await settle(tester);
      final delegate = webPlatform.last.navigationDelegate!;

      for (final url in [
        'https://evil.example/refresh',
        'https://evil.example/href',
        'https://evil.example/popup',
      ]) {
        expect(await delegate.request(url), NavigationDecision.prevent);
      }
      expect(
        await delegate.request('file:///etc/passwd', mainFrame: false),
        NavigationDecision.prevent,
      );
      await settle(tester);
      expect(launcher.launches, isEmpty);
      expect(webPlatform.last.loadedHtml, hasLength(1));
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a tapped link opens once in the external browser, no sheet', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(viewer('page.html', 'text/html', text(malicious))),
      );
      await settle(tester);

      await tester.tap(
        find.byKey(const ValueKey('fake-platform-webview')),
        warnIfMissed: false,
      );
      final decision = await webPlatform.last.navigationDelegate!.request(
        'https://example.com/docs',
      );
      await settle(tester);

      expect(decision, NavigationDecision.prevent);
      expect(launcher.launches, [
        ('https://example.com/docs', PreferredLaunchMode.externalApplication),
      ]);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(webPlatform.last.loadedHtml, hasLength(1));
    });

    testWidgets('a tapped non-web link is never launched', (tester) async {
      await tester.pumpWidget(
        host(viewer('page.html', 'text/html', text(malicious))),
      );
      await settle(tester);
      for (final url in [
        'file:///etc/passwd',
        'intent://x#Intent;end',
        'javascript:alert(1)',
        'data:text/html,x',
      ]) {
        await tester.tap(
          find.byKey(const ValueKey('fake-platform-webview')),
          warnIfMissed: false,
        );
        await webPlatform.last.navigationDelegate!.request(url);
      }
      await settle(tester);
      expect(launcher.launches, isEmpty);
    });

    testWidgets('scripted navigation to intent:, file: and http(s) is '
        'blocked without a tap and launches nothing', (tester) async {
      await tester.pumpWidget(
        host(viewer('page.html', 'text/html', text(malicious))),
      );
      await settle(tester);
      final web = webPlatform.last;
      expect(web.javaScriptMode, JavaScriptMode.unrestricted);
      for (final url in [
        'intent://scan/#Intent;scheme=zxing;end',
        'file:///data/data/com.hermesagent.hermes_android/shared_prefs/x.xml',
        'content://com.android.contacts/contacts',
        'javascript:alert(1)',
        'https://evil.example/scripted',
        'about:blank',
      ]) {
        expect(
          await web.navigationDelegate!.request(url),
          NavigationDecision.prevent,
        );
        expect(
          await web.navigationDelegate!.request(url, mainFrame: false),
          NavigationDecision.prevent,
        );
      }
      await settle(tester);
      expect(launcher.launches, isEmpty);
      expect(web.loadedHtml, hasLength(1));
      expect(web.loadedRequests, isEmpty);
    });

    testWidgets('reopening loads a fresh WebView with the same policy', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(viewer('page.html', 'text/html', text('<p>hola</p>'))),
      );
      await settle(tester);
      final first = webPlatform.last;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        host(viewer('page.html', 'text/html', text('<p>hola</p>'))),
      );
      await settle(tester);
      final reopened = webPlatform.last;
      expect(identical(reopened, first), isFalse);
      expect(reopened.loadedHtml, hasLength(1));
      expect(reopened.javaScriptMode, JavaScriptMode.unrestricted);
      expect(reopened.javaScriptChannels, isEmpty);
    });

    testWidgets('SVG renders as an image with no scripts toggle', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          viewer(
            'chart.svg',
            'image/svg+xml',
            text(
              '<svg xmlns="http://www.w3.org/2000/svg"><script>x()</script></svg>',
            ),
          ),
        ),
      );
      await settle(tester);
      final web = webPlatform.last;
      expect(web.javaScriptMode, JavaScriptMode.disabled);
      expect(web.loadedHtml.single, contains('data:image/svg+xml;base64,'));
      expect(
        find.byKey(const ValueKey('artifact-viewer-scripts-toggle')),
        findsNothing,
      );
    });
  });

  group('native viewers', () {
    testWidgets('Markdown renders formatted, source toggle shows raw text', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(viewer('notes.md', 'text/plain', text('# Título\n\n**negrita**'))),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('artifact-viewer-markdown')), findsOne);
      expect(find.textContaining('# Título'), findsNothing);
      expect(find.textContaining('Título'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-source-toggle')),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('artifact-viewer-text')), findsOne);
      expect(find.textContaining('# Título'), findsOneWidget);
    });

    testWidgets('code renders with syntax colours and copy works', (
      tester,
    ) async {
      const source = 'def hola():\n    return "mundo"\n';
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        host(viewer('main.py', 'text/x-python', text(source))),
      );
      await settle(tester);

      final line = tester.widget<Text>(
        find.byKey(const ValueKey('artifact-viewer-line-0')),
      );
      final colored = <Color>{};
      line.textSpan!.visitChildren((span) {
        final color = span.style?.color;
        if (color != null) colored.add(color);
        return true;
      });
      expect(colored, isNotEmpty, reason: 'keyword "def" is highlighted');
      expect(line.textSpan!.toPlainText(), 'def hola():');

      await tester.tap(find.byKey(const ValueKey('artifact-viewer-menu')));
      await settle(tester);
      await tester.tap(find.text('Copiar'));
      await settle(tester);
      expect(copied, source);
    });

    testWidgets('search counts matches and steps through them', (tester) async {
      final log = [
        for (var i = 0; i < 400; i++)
          i % 100 == 7 ? 'linea $i ERROR fallo' : 'linea $i ok',
      ].join('\n');
      await tester.pumpWidget(
        host(viewer('server.log', 'text/plain', text(log))),
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-search')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('artifact-viewer-search-field')),
        'error',
      );
      await settle(tester);
      Text count() => tester.widget<Text>(
        find.byKey(const ValueKey('artifact-viewer-search-count')),
      );
      expect(count().data, '1 de 4');
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-next')),
      );
      await settle(tester);
      expect(count().data, '2 de 4');
      // The view scrolled so the second match (line 107) is built.
      expect(find.byKey(const ValueKey('artifact-viewer-line-107')), findsOne);
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-prev')),
      );
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-prev')),
      );
      await settle(tester);
      expect(count().data, '4 de 4');

      await tester.enterText(
        find.byKey(const ValueKey('artifact-viewer-search-field')),
        'zzz',
      );
      await settle(tester);
      expect(count().data, 'Sin resultados');
    });

    testWidgets('files over 1 MB are capped with an honest "Mostrar todo"', (
      tester,
    ) async {
      final line = '${'x' * 99}\n';
      final big = line * 15000; // ~1.5 MB
      await tester.pumpWidget(host(viewer('big.txt', 'text/plain', text(big))));
      await settle(tester);
      expect(find.byKey(const ValueKey('artifact-viewer-truncated')), findsOne);
      expect(find.textContaining('Se muestra solo una parte'), findsOneWidget);
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('artifact-viewer-text')),
      );
      final shownLines = (list.childrenDelegate as SliverChildBuilderDelegate)
          .estimatedChildCount!;
      expect(shownLines, lessThan(15000));

      await tester.tap(find.byKey(const ValueKey('artifact-viewer-show-all')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('artifact-viewer-truncated')),
        findsNothing,
      );
      final full = tester.widget<ListView>(
        find.byKey(const ValueKey('artifact-viewer-text')),
      );
      expect(
        (full.childrenDelegate as SliverChildBuilderDelegate)
            .estimatedChildCount,
        15000,
      );
    });

    testWidgets('images open in a zoomable InteractiveViewer', (tester) async {
      await tester.pumpWidget(host(viewer('photo.png', 'image/png', _png)));
      await settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('artifact-viewer-image')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<InteractiveViewer>(
              find.byKey(const ValueKey('artifact-viewer-image')),
            )
            .maxScale,
        greaterThan(1),
      );
    });
  });

  group('fallback', () {
    for (final (name, mime) in [
      ('report.pdf', 'application/pdf'),
      ('archive.zip', 'application/zip'),
    ]) {
      testWidgets('$name shows metadata with Abrir con… and Compartir', (
        tester,
      ) async {
        var opened = 0;
        var shared = 0;
        await tester.pumpWidget(
          host(
            viewer(
              name,
              mime,
              Uint8List.fromList([1, 2, 3]),
              onOpenExternal: () => opened++,
              onShare: () => shared++,
            ),
          ),
        );
        await settle(tester);
        expect(
          find.byKey(const ValueKey('artifact-viewer-fallback')),
          findsOne,
        );
        expect(find.text(name), findsWidgets);
        expect(find.textContaining(mime), findsOneWidget);
        expect(
          find.byKey(const ValueKey('artifact-viewer-webview')),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const ValueKey('artifact-viewer-open-with')),
        );
        await tester.tap(find.text('Compartir'));
        expect(opened, 1);
        expect(shared, 1);
      });
    }
  });
}
