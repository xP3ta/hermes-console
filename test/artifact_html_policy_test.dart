import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_html_policy.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

class _RecordingSettings implements ArtifactWebViewPlatformSettings {
  final List<String> calls = [];

  @override
  Future<void> setAllowFileAccess(bool allow) async =>
      calls.add('fileAccess=$allow');

  @override
  Future<void> setAllowContentAccess(bool allow) async =>
      calls.add('contentAccess=$allow');

  @override
  Future<void> setGeolocationEnabled(bool enabled) async =>
      calls.add('geolocation=$enabled');

  @override
  Future<void> denyGeolocationPrompts() async => calls.add('geoPromptDeny');

  @override
  Future<void> setMixedContentNeverAllow() async => calls.add('mixedNever');

  @override
  Future<void> setMediaPlaybackRequiresUserGesture(bool require) async =>
      calls.add('mediaGesture=$require');

  @override
  Future<void> refuseFileChooser() async => calls.add('fileChooserRefused');
}

void main() {
  late DateTime now;
  late List<Uri> launched;
  late ArtifactHtmlNavigationPolicy policy;

  setUp(() {
    now = DateTime(2026, 10, 1, 12);
    launched = [];
    policy = ArtifactHtmlNavigationPolicy(
      clock: () => now,
      launchExternal: (uri) async {
        launched.add(uri);
        return true;
      },
    );
  });

  NavigationDecision nav(String url, {bool mainFrame = true}) => policy
      .onNavigationRequest(NavigationRequest(url: url, isMainFrame: mainFrame));

  group('navigation policy', () {
    test(
      'a tapped http(s) link opens externally and never navigates',
      () async {
        policy.registerUserTap();
        expect(nav('https://example.com/docs'), NavigationDecision.prevent);
        await Future<void>.delayed(Duration.zero);
        expect(launched, [Uri.parse('https://example.com/docs')]);
      },
    );

    test(
      'malicious scripted navigations are blocked and launch nothing',
      () async {
        // Each one arrives as a main-frame request without a user tap:
        // <meta http-equiv="refresh" content="0;url=…">, location.href = …,
        // window.open(…) (routed through onCreateWindow → the same delegate).
        for (final url in [
          'https://evil.example/meta-refresh',
          'https://evil.example/location-href',
          'https://evil.example/window-open',
          'http://evil.example/redirect',
        ]) {
          expect(nav(url), NavigationDecision.prevent, reason: url);
        }
        await Future<void>.delayed(Duration.zero);
        expect(launched, isEmpty);
      },
    );

    test('file:///etc/passwd in an iframe or main frame is blocked', () async {
      policy.registerUserTap();
      expect(
        nav('file:///etc/passwd', mainFrame: false),
        NavigationDecision.prevent,
      );
      expect(nav('file:///etc/passwd'), NavigationDecision.prevent);
      await Future<void>.delayed(Duration.zero);
      expect(launched, isEmpty);
    });

    test('non-web schemes are never launched even after a tap', () async {
      for (final url in [
        'file:///data/data/app/secret',
        'intent://scan/#Intent;scheme=zxing;end',
        'javascript:alert(1)',
        'data:text/html,<b>x</b>',
        'content://media/external/1',
        'tel:123',
        'https:///no-host',
      ]) {
        policy.registerUserTap();
        expect(nav(url), NavigationDecision.prevent, reason: url);
      }
      await Future<void>.delayed(Duration.zero);
      expect(launched, isEmpty);
    });

    test('a stale tap does not authorise a later scripted redirect', () async {
      policy.registerUserTap();
      now = now.add(const Duration(seconds: 5));
      expect(nav('https://evil.example/late'), NavigationDecision.prevent);
      await Future<void>.delayed(Duration.zero);
      expect(launched, isEmpty);
    });

    test('one tap authorises at most one launch', () async {
      policy.registerUserTap();
      nav('https://example.com/a');
      nav('https://evil.example/chained');
      await Future<void>.delayed(Duration.zero);
      expect(launched, [Uri.parse('https://example.com/a')]);
    });

    test('a subframe request consumes nothing and launches nothing', () async {
      policy.registerUserTap();
      nav('https://ads.example/frame', mainFrame: false);
      await Future<void>.delayed(Duration.zero);
      expect(launched, isEmpty);
    });

    test('default launcher uses the external browser', () async {
      final previous = UrlLauncherPlatform.instance;
      final fake = FakeUrlLauncher();
      UrlLauncherPlatform.instance = fake;
      addTearDown(() => UrlLauncherPlatform.instance = previous);
      await launchArtifactLinkExternally(Uri.parse('https://example.com'));
      expect(fake.launches, [
        ('https://example.com', PreferredLaunchMode.externalApplication),
      ]);
    });
  });

  group('guarded document', () {
    test('CSP denies network, frames, objects and forms; no scripts by '
        'default', () {
      final html = buildGuardedArtifactHtml(
        '<!DOCTYPE html><html><body>'
        '<meta http-equiv="refresh" content="0;url=https://evil.example">'
        '<iframe src="file:///etc/passwd"></iframe></body></html>',
        scriptsEnabled: false,
      );
      expect(html, startsWith('<!DOCTYPE html><meta http-equiv='));
      expect(html, contains("script-src 'none'"));
      expect(html, contains("default-src 'none'"));
      expect(html, contains("frame-src 'none'"));
      expect(html, contains("child-src 'none'"));
      expect(html, contains("connect-src 'none'"));
      expect(html, contains("object-src 'none'"));
      expect(html, contains("form-action 'none'"));
      expect(html, isNot(contains('Object.defineProperty(window,"open"')));
    });

    test('with scripts on, only inline scripts run and window.open is a '
        'no-op', () {
      final html = buildGuardedArtifactHtml(
        '<script>window.open("https://evil.example")</script>',
        scriptsEnabled: true,
      );
      expect(html, contains("script-src 'unsafe-inline'"));
      expect(html, contains('Object.defineProperty(window,"open"'));
      // The lock precedes any guest script.
      expect(
        html.indexOf('defineProperty'),
        lessThan(html.indexOf('evil.example')),
      );
    });

    test('SVG is embedded as an image, so its scripts cannot run', () {
      final html = buildGuardedSvgHtml(
        '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script>'
        '</svg>',
      );
      expect(html, contains('<img alt="" src="data:image/svg+xml;base64,'));
      expect(html, isNot(contains('<script>alert')));
      expect(html, contains("script-src 'none'"));
    });
  });

  group('WebView configuration', () {
    late FakeWebViewPlatform platform;

    setUp(() {
      platform = FakeWebViewPlatform();
      WebViewPlatform.instance = platform;
    });

    test('locks the WebView down before any load', () async {
      final settings = _RecordingSettings();
      final controller = WebViewController();
      await configureArtifactWebView(
        controller,
        policy: policy,
        settingsFor: (_) => settings,
      );
      final fake = platform.last;
      expect(fake.javaScriptMode, JavaScriptMode.disabled);
      expect(fake.navigationDelegate, isNotNull);
      expect(fake.loadedHtml, isEmpty);
      expect(settings.calls, [
        'fileAccess=false',
        'contentAccess=false',
        'geolocation=false',
        'geoPromptDeny',
        'mixedNever',
        'mediaGesture=true',
        'fileChooserRefused',
      ]);
      expect(
        await fake.navigationDelegate!.request('https://evil.example'),
        NavigationDecision.prevent,
      );
    });

    test('camera/microphone permission requests are denied', () async {
      final request = FakePermissionRequest();
      WebViewController(onPermissionRequest: denyArtifactPermissionRequest);
      platform.last.permissionHandler!(request);
      await Future<void>.delayed(Duration.zero);
      expect(request.denied, isTrue);
      expect(request.granted, isFalse);
    });
  });
}
