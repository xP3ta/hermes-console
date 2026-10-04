import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_card.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_consent_store.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_detector.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

const _fallbackKey = ValueKey('embed-fallback');
const _fallback = Text('fallback link', key: _fallbackKey);

EmbedDescriptor _youtube([String id = 'dQw4w9WgXcQ']) =>
    detectEmbed('https://youtu.be/$id')!;

Widget _app(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(size: size),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 400, height: size.height, child: child),
      ),
    ),
  ),
);

void main() {
  late FakeWebViewPlatform platform;
  late EmbedConsentStore consent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    consent = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  tearDown(() {
    final owner = EmbedLiveRegistry.instance.owner;
    if (owner != null) EmbedLiveRegistry.instance.drop(owner);
  });

  Widget card(
    EmbedDescriptor d, {
    Key? key,
    Future<bool> Function(Uri)? launch,
  }) => EmbedCard(
    key: key,
    descriptor: d,
    fallback: _fallback,
    consent: consent,
    launchExternal: launch,
  );

  testWidgets('type off renders the fallback and creates no WebView', (
    tester,
  ) async {
    await tester.pumpWidget(_app(card(_youtube())));
    await tester.pump();
    expect(find.byKey(_fallbackKey), findsOneWidget);
    expect(find.byKey(const ValueKey('embed-placeholder')), findsNothing);
    expect(platform.controllers, isEmpty);
  });

  testWidgets('ask shows a fixed-size placeholder and loads nothing', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    await tester.pumpWidget(_app(card(_youtube())));
    await tester.pump();
    expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
    expect(find.text('Load YouTube'), findsOneWidget);
    expect(platform.controllers, isEmpty);
    final placeholderSize = tester.getSize(
      find.byKey(const ValueKey('embed-card-box')),
    );
    expect(placeholderSize.width, 400);
    expect(placeholderSize.height, closeTo(400 / (16 / 9), 0.01));
  });

  testWidgets('tapping Load creates one sandboxed WebView of the same size', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    await tester.pumpWidget(_app(card(_youtube())));
    final before = tester.getSize(find.byKey(const ValueKey('embed-card-box')));
    await tester.tap(find.byKey(const ValueKey('embed-placeholder')));
    await tester.pumpAndSettle();
    expect(platform.controllers.length, 1);
    final controller = platform.last;
    expect(
      controller.loadedRequests.single.toString(),
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?modestbranding=1&rel=0',
    );
    expect(controller.javaScriptChannels, isEmpty);
    expect(controller.javaScriptMode, JavaScriptMode.unrestricted);
    expect(
      tester.getSize(find.byKey(const ValueKey('embed-card-box'))),
      before,
    );
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
  });

  testWidgets('every navigation inside the frame is prevented', (tester) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    final launched = <Uri>[];
    await tester.pumpWidget(
      _app(
        card(
          _youtube(),
          launch: (uri) async {
            launched.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('embed-placeholder')));
    await tester.pumpAndSettle();
    final delegate = platform.last.navigationDelegate!;
    expect(
      await delegate.request('https://evil.example.test/'),
      NavigationDecision.prevent,
    );
    expect(
      await delegate.request('intent://x', mainFrame: false),
      NavigationDecision.prevent,
    );
    expect(launched, isEmpty);
  });

  testWidgets('long press offers Always allow and persists it per type', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    await tester.pumpWidget(_app(card(_youtube())));
    await tester.longPress(find.byKey(const ValueKey('embed-placeholder')));
    await tester.pumpAndSettle();
    expect(find.text('Always allow YouTube'), findsOneWidget);
    expect(find.text('Load once'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('embed-always-allow')));
    await tester.pumpAndSettle();
    expect(consent.modeFor(EmbedType.youtube), EmbedMode.always);
    expect(consent.modeFor(EmbedType.vimeo), EmbedMode.off);
    expect(platform.controllers.length, 1);
  });

  testWidgets('Load once does not change the stored mode', (tester) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    await tester.pumpWidget(_app(card(_youtube())));
    await tester.longPress(find.byKey(const ValueKey('embed-placeholder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('embed-load-once')));
    await tester.pumpAndSettle();
    expect(consent.modeFor(EmbedType.youtube), EmbedMode.ask);
    expect(platform.controllers.length, 1);
  });

  testWidgets('always loads once the card is on screen, without a tap', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.always);
    await tester.pumpWidget(_app(card(_youtube())));
    await tester.pumpAndSettle();
    expect(platform.controllers.length, 1);
  });

  testWidgets('only one live WebView: loading another restores the first', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: Column(
            children: [
              card(_youtube('aaaaaaaaaaa'), key: const ValueKey('a')),
              card(_youtube('bbbbbbbbbbb'), key: const ValueKey('b')),
            ],
          ),
        ),
        size: const Size(400, 1400),
      ),
    );
    final placeholders = find.byKey(const ValueKey('embed-placeholder'));
    await tester.tap(placeholders.first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('embed-placeholder')).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
    // The restored card waits for a tap; nothing reloads by itself.
    expect(platform.controllers.length, 2);
    await tester.pump(const Duration(seconds: 5));
    expect(platform.controllers.length, 2);
  });

  testWidgets('scrolling away disposes the WebView', (tester) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        ListView(
          controller: controller,
          children: [card(_youtube()), const SizedBox(height: 3000)],
        ),
        size: const Size(400, 600),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('embed-placeholder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    controller.jumpTo(420);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('embed-webview')), findsNothing);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    // Back on screen: a placeholder, not an automatic reload.
    expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
    expect(platform.controllers.length, 1);
  });

  testWidgets('a route pushed on top releases the live WebView', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.fromId('dark'),
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: card(_youtube()))),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('embed-placeholder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('embed-webview')), findsNothing);
    expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
  });

  testWidgets('a frame url off the allow-list never creates a WebView', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.always);
    const forged = EmbedDescriptor(
      id: 'youtube:x',
      label: 'YouTube',
      provider: EmbedType.youtube,
      renderer: EmbedRenderer.frame,
      sourceUrl: 'https://youtu.be/dQw4w9WgXcQ',
      embedUrl: 'https://evil.example.test/embed',
      aspectRatio: 16 / 9,
    );
    await tester.pumpWidget(_app(card(forged)));
    await tester.pumpAndSettle();
    expect(find.byKey(_fallbackKey), findsOneWidget);
    expect(platform.controllers, isEmpty);
  });

  group('SVG', () {
    Widget svgCard(String source) =>
        EmbedCard(svgSource: source, fallback: _fallback, consent: consent);

    testWidgets('off keeps the code block, ask waits, load sanitises', (
      tester,
    ) async {
      const source =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" '
          'onload="x()"><script>alert(1)</script><rect width="4" height="4"/>'
          '<foreignObject><div>hi</div></foreignObject></svg>';
      await tester.pumpWidget(_app(svgCard(source)));
      expect(find.byKey(_fallbackKey), findsOneWidget);
      expect(platform.controllers, isEmpty);

      await consent.setMode(EmbedType.svg, EmbedMode.ask);
      await tester.pumpWidget(_app(svgCard(source)));
      await tester.pump();
      expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
      expect(platform.controllers, isEmpty);

      await tester.tap(find.byKey(const ValueKey('embed-placeholder')));
      await tester.pumpAndSettle();
      final controller = platform.last;
      expect(controller.javaScriptMode, JavaScriptMode.disabled);
      expect(controller.javaScriptChannels, isEmpty);
      final html = controller.loadedHtml.single;
      expect(html, contains('data:image/svg+xml;base64,'));
      expect(controller.loadedRequests, isEmpty);
    });

    testWidgets('height is capped to a third of the viewport', (tester) async {
      await consent.setMode(EmbedType.svg, EmbedMode.ask);
      await tester.pumpWidget(
        _app(
          svgCard(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 100">'
            '<rect/></svg>',
          ),
          size: const Size(400, 900),
        ),
      );
      final size = tester.getSize(find.byKey(const ValueKey('embed-card-box')));
      expect(size.height, lessThanOrEqualTo(300));
    });

    testWidgets('an unsafe or oversized svg stays a code block', (
      tester,
    ) async {
      await consent.setMode(EmbedType.svg, EmbedMode.always);
      await tester.pumpWidget(
        _app(
          svgCard(
            '<svg><style>@import url(https://x.example.test/a.css);'
            '</style></svg>',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_fallbackKey), findsOneWidget);
      expect(platform.controllers, isEmpty);
    });
  });
}
