// the owner's decision for 1.4.0 (Desktop opens links outside): an http/https
// link of a conversation opens inside the app, in the in-app browser, and
// its notch comes back to where the link was. Other schemes keep their own
// handling.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/browser/open_web_link.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart'
    show openChatMarkdownLink;
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

void main() {
  late FakeWebViewPlatform web;

  setUp(() {
    web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;
  });

  Widget app(void Function(BuildContext context) onTap) => MaterialApp(
    theme: AppTheme.hermesRedDark,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const ValueKey('link'),
            onPressed: () => onTap(context),
            child: const Text('link'),
          ),
        ),
      ),
    ),
  );

  testWidgets('a message link opens the in-app browser; the notch returns', (
    tester,
  ) async {
    const url = 'https://example.com/docs/guia';
    await tester.pumpWidget(
      app((context) => openChatMarkdownLink(context, url)),
    );
    await tester.tap(find.byKey(const ValueKey('link')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final browser = tester.widget<InAppBrowserScreen>(
      find.byType(InAppBrowserScreen),
    );
    expect(browser.initialUrl, Uri.parse(url));
    expect(browser.backLabel, isNull);
    expect(web.last.loadedRequests, [Uri.parse(url)]);

    await tester.tap(find.byKey(const ValueKey('in-app-browser-notch')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(InAppBrowserScreen), findsNothing);
    expect(find.byKey(const ValueKey('link')), findsOneWidget);
  });

  testWidgets('mailto, tel and intents never open the browser', (tester) async {
    final opened = <bool>[];
    await tester.pumpWidget(
      app((context) {
        for (final address in [
          'mailto:hola@example.com',
          'tel:+34600000000',
          'intent://scan/#Intent;scheme=zxing;end',
          'file:///etc/hosts',
        ]) {
          opened.add(openWebLinkInApp(context, Uri.parse(address)));
        }
      }),
    );
    await tester.tap(find.byKey(const ValueKey('link')));
    await tester.pump();
    expect(opened, [false, false, false, false]);
    expect(find.byType(InAppBrowserScreen), findsNothing);
  });

  testWidgets('a blocked scheme in a message still says so, no browser', (
    tester,
  ) async {
    await tester.pumpWidget(
      app((context) => openChatMarkdownLink(context, 'tel:+34600000000')),
    );
    await tester.tap(find.byKey(const ValueKey('link')));
    await tester.pump();
    expect(find.byType(InAppBrowserScreen), findsNothing);
    // Its notice goes away on its own.
    await tester.pump(const Duration(seconds: 3));
  });
}
