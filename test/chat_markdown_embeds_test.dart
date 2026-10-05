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

void main() {
  late FakeWebViewPlatform platform;
  late EmbedConsentStore consent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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

  Future<List<String>> texts(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(_app(child));
    await tester.pump();
    return [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText(),
    ];
  }

  testWidgets('every type off renders exactly like a block without embeds', (
    tester,
  ) async {
    final plain = await texts(
      tester,
      const ChatMarkdownBlock(data: '$_link\n\n$_svg'),
    );
    final off = await texts(
      tester,
      const ChatMarkdownBlock(data: '$_link\n\n$_svg', embeds: true),
    );
    expect(off, plain);
    expect(find.byKey(const ValueKey('embed-placeholder')), findsNothing);
    expect(platform.controllers, isEmpty);
  });

  testWidgets('ask adds a placeholder under the link and loads nothing', (
    tester,
  ) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.ask);
    await tester.pumpWidget(
      _app(const ChatMarkdownBlock(data: _link, embeds: true)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
    expect(find.textContaining('youtu.be'), findsWidgets);
    expect(platform.controllers, isEmpty);
  });

  testWidgets('a type that is still off adds nothing for that link', (
    tester,
  ) async {
    await consent.setMode(EmbedType.vimeo, EmbedMode.ask);
    await tester.pumpWidget(
      _app(const ChatMarkdownBlock(data: _link, embeds: true)),
    );
    await tester.pump();
    expect(find.byType(EmbedCard), findsNothing);
  });

  testWidgets('a streaming message never embeds', (tester) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.always);
    await consent.setMode(EmbedType.svg, EmbedMode.always);
    await tester.pumpWidget(
      _app(
        const ChatMarkdownBody(
          data: '$_link\n\n$_svg',
          isStreaming: true,
          embeds: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EmbedCard), findsNothing);
    expect(platform.controllers, isEmpty);
  });

  testWidgets('embeds stay off unless the caller opts in', (tester) async {
    await consent.setMode(EmbedType.youtube, EmbedMode.always);
    await tester.pumpWidget(_app(const ChatMarkdownBody(data: _link)));
    await tester.pumpAndSettle();
    expect(find.byType(EmbedCard), findsNothing);
    expect(platform.controllers, isEmpty);
  });

  testWidgets('a finished message with an svg fence gets the gated card', (
    tester,
  ) async {
    await consent.setMode(EmbedType.svg, EmbedMode.ask);
    await tester.pumpWidget(
      _app(const ChatMarkdownBody(data: _svg, embeds: true)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
    expect(platform.controllers, isEmpty);
  });

  testWidgets('switching the type off in settings restores the code block', (
    tester,
  ) async {
    await consent.setMode(EmbedType.svg, EmbedMode.ask);
    await tester.pumpWidget(
      _app(const ChatMarkdownBody(data: _svg, embeds: true)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('embed-placeholder')), findsOneWidget);
    await consent.setMode(EmbedType.svg, EmbedMode.off);
    await tester.pump();
    expect(find.byKey(const ValueKey('embed-placeholder')), findsNothing);
    expect(find.textContaining('<rect'), findsWidgets);
  });
}
