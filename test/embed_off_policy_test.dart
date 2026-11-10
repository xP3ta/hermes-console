import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_card.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_consent_store.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_detector.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

const _link = 'Mira esto:\n\nhttps://youtu.be/dQw4w9WgXcQ\n\nfin';
const _svg =
    '```svg\n<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
    '<rect width="4" height="4"/></svg>\n```';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

// Third-party embeds are off for good (flag untouched: default policy).
void main() {
  late FakeWebViewPlatform platform;
  late EmbedConsentStore consent;

  setUp(() async {
    expect(EmbedConsentStore.debugAllowThirdPartyEmbeds, isFalse);
    SharedPreferences.setMockInitialValues({
      for (final type in EmbedType.values)
        '${EmbedConsentStore.keyPrefix}${type.name}': 'always',
    });
    consent = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
    EmbedConsentStore.debugUse(consent);
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  tearDown(() {
    EmbedConsentStore.debugUse(null);
    final owner = EmbedLiveRegistry.instance.owner;
    if (owner != null) EmbedLiveRegistry.instance.drop(owner);
  });

  test('a saved always for a link type or Mermaid reads as off', () {
    expect(consent.storedMode(EmbedType.youtube), EmbedMode.always);
    for (final type in EmbedType.values.where((t) => t != EmbedType.svg)) {
      expect(consent.modeFor(type), EmbedMode.off, reason: type.name);
    }
    expect(consent.modeFor(EmbedType.svg), EmbedMode.always);
  });

  testWidgets('a saved always for YouTube loads nothing in the chat', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const ChatMarkdownBody(data: _link, embeds: true)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EmbedCard), findsNothing);
    expect(platform.controllers, isEmpty);
    expect(find.textContaining('https://youtu.be/dQw4w9WgXcQ'), findsOneWidget);
  });

  testWidgets('a YouTube card given directly still creates no WebView', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        EmbedCard(
          descriptor: detectEmbed('https://youtu.be/dQw4w9WgXcQ')!,
          fallback: const Text('fallback link'),
          consent: consent,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('fallback link'), findsOneWidget);
    expect(find.byKey(const ValueKey('embed-placeholder')), findsNothing);
    expect(platform.controllers, isEmpty);
  });

  testWidgets('an svg fence is drawn locally, sanitized, without a prompt', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fresh = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
    EmbedConsentStore.debugUse(fresh);
    await tester.pumpWidget(
      _app(const ChatMarkdownBody(data: _svg, embeds: true)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('embed-placeholder')), findsNothing);
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    expect(platform.controllers, hasLength(1));
    expect(platform.last.loadedRequests, isEmpty, reason: 'no network load');
    final html = platform.last.loadedHtml.single;
    expect(html, contains("default-src 'none'"));
    expect(html, contains("connect-src 'none'"));
    final data = RegExp(r'base64,([A-Za-z0-9+/=]+)').firstMatch(html)!;
    expect(utf8.decode(base64Decode(data.group(1)!)), contains('<rect'));
  });

  testWidgets('Mermaid stays a code block', (tester) async {
    await tester.pumpWidget(
      _app(
        const ChatMarkdownBody(
          data: '```mermaid\ngraph TD; A-->B;\n```',
          embeds: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EmbedCard), findsNothing);
    expect(platform.controllers, isEmpty);
  });
}
