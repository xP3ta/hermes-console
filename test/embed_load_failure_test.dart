// A link embed whose page fails to load, or does not finish by its
// deadline, says why in its own box, with Retry and the link opened in the
// browser.
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

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.fromMode(AppThemeMode.dark),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  group('link embeds', () {
    late FakeWebViewPlatform web;
    late EmbedConsentStore consent;

    setUp(() async {
      EmbedConsentStore.debugAllowThirdPartyEmbeds = true;
      SharedPreferences.setMockInitialValues({});
      consent = EmbedConsentStore.forTesting(
        await SharedPreferences.getInstance(),
      );
      await consent.setMode(EmbedType.youtube, EmbedMode.ask);
      web = FakeWebViewPlatform();
      WebViewPlatform.instance = web;
    });

    tearDown(() {
      EmbedConsentStore.debugAllowThirdPartyEmbeds = false;
      final owner = EmbedLiveRegistry.instance.owner;
      if (owner != null) EmbedLiveRegistry.instance.drop(owner);
    });

    Future<List<Uri>> loadCard(WidgetTester tester) async {
      final launched = <Uri>[];
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 400,
            child: EmbedCard(
              descriptor: detectEmbed('https://youtu.be/dQw4w9WgXcQ')!,
              fallback: const Text('fallback link'),
              consent: consent,
              launchExternal: (uri) async {
                launched.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('embed-placeholder')));
      await tester.pump();
      await tester.pump();
      return launched;
    }

    testWidgets('a page that fails to load says why, with Retry and the link '
        'in the browser', (tester) async {
      final launched = await loadCard(tester);
      expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);

      web.delegates.last.fail('https://www.youtube-nocookie.com/embed/x');
      await tester.pump();

      expect(find.byKey(const ValueKey('embed-webview')), findsNothing);
      expect(find.text('YouTube could not be loaded.'), findsOneWidget);
      expect(find.text('net::ERR_NAME_NOT_RESOLVED'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('embed-open-link')));
      expect(launched.single.toString(), 'https://youtu.be/dQw4w9WgXcQ');

      await tester.tap(find.byKey(const ValueKey('embed-retry')));
      await tester.pump();
      await tester.pump();
      expect(web.controllers, hasLength(2));
      expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    });

    testWidgets('a page that never finishes is given up at its deadline; one '
        'that finished stays', (tester) async {
      await loadCard(tester);
      web.delegates.last.load('https://www.youtube-nocookie.com/embed/x');
      await tester.pump(const Duration(seconds: 25));
      expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await loadCard(tester);
      await tester.pump(const Duration(seconds: 21));
      expect(find.text('YouTube could not be loaded.'), findsOneWidget);
      expect(find.text('It took too long to draw.'), findsOneWidget);
    });
  });
}
