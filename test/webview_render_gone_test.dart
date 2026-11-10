// REVIEW-R5-B #1: a WebView renderer the system kills never closes the app.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/browser/webview_render_guard.dart';
import 'package:hermes_android/core/screen/takeover_view.dart';
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

/// Stands in for the native guard: remembers who watches and can kill.
class _Watch implements WebViewRendererWatch {
  final watched = <WebViewController, VoidCallback>{};
  final forgotten = <WebViewController>[];

  @override
  Future<void> watch(WebViewController controller, VoidCallback onGone) async {
    watched[controller] = onGone;
  }

  @override
  void forget(WebViewController controller) => forgotten.add(controller);

  void killLatest() => watched.values.last();
}

void main() {
  late FakeWebViewPlatform web;

  setUp(() {
    web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;
  });

  Future<_Watch> pumpBrowser(WidgetTester tester) async {
    final watch = _Watch();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromMode(AppThemeMode.dark),
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InAppBrowserScreen(
          initialUrl: Uri.parse('https://a.example/doc'),
          settingsFor: (_) => _NoSettings(),
          rendererWatch: watch,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return watch;
  }

  testWidgets('a dead renderer replaces the WebView and offers Retry', (
    tester,
  ) async {
    final watch = await pumpBrowser(tester);
    expect(watch.watched, hasLength(1), reason: 'watched once configured');
    final first = web.last;
    first.navigationDelegate!.load('https://a.example/doc');
    await tester.pump();

    watch.killLatest();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // No crash: the error says what happened, in a new WebView.
    expect(tester.takeException(), isNull);
    expect(find.text('La página se ha cerrado'), findsOneWidget);
    expect(find.byKey(const ValueKey('in-app-browser-error')), findsOneWidget);
    expect(web.last, isNot(same(first)));
    expect(watch.watched, hasLength(2), reason: 'the new one is watched');

    await tester.tap(find.byKey(const ValueKey('in-app-browser-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(web.last.loadedRequests.last, Uri.parse('https://a.example/doc'));
    expect(find.byKey(const ValueKey('in-app-browser-error')), findsNothing);
  });

  testWidgets('a second report from the dead WebView changes nothing', (
    tester,
  ) async {
    final watch = await pumpBrowser(tester);
    final dead = watch.watched.values.first;
    dead();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final replaced = web.last;
    dead();
    await tester.pump();
    expect(web.last, same(replaced));
    expect(tester.takeException(), isNull);
  });

  test('the noVNC host reports a dead renderer to the takeover', () async {
    var gone = 0;
    var failed = 0;
    final handle = screenAssetHostCalls(
      onLoadFailed: () => failed++,
      onRenderGone: () => gone++,
    );
    await handle(const MethodCall('renderGone'));
    await handle(const MethodCall('loadFailed'));
    expect(gone, 1);
    expect(failed, 1);
  });

  test('the guard ignores a report for a WebView it does not watch', () async {
    await WebViewRenderGuard.instance.handle(
      const MethodCall('renderGone', 42),
    );
    await WebViewRenderGuard.instance.handle(const MethodCall('other'));
  });
}
