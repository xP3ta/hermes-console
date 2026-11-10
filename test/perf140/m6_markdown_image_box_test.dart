// M6 (performance audit 1.4.0): a markdown image keeps its final box from
// the moment its bytes arrive, before the first frame is decoded, so the
// reply does not grow from nothing when the picture lands.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;

/// A 400x200 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAZAAAADICAIAAABJdyC1AAACBUlEQVR42u3UMQ0AAAgE'
  'sZeCNKQhFRUMJE2q4IZL9QC8EAkAwwIwLMCwAAwLwLAAwwIwLADDAgwLwLAADAswLADD'
  'AjAswLAADAvAsADDAjAsAMMCDAvAsAAMCzAsAMMCMCzAsAAMCzAsFQDDAjAswLAADAvA'
  'sADDAjAsAMMCDAvAsAAMCzAsAMMCMCzAsAAMC8CwAMMCMCwAwwIMC8CwAAwLMCwAwwIw'
  'LMCwAAwLMCwVAMMCMCzAsAAMC8CwAMMCMCwAwwIMC8CwAAwLMCwAwwIwLMCwAAwLwLAA'
  'wwIwLADDAgwLwLAADAswLADDAjAswLAADAswLADDAjAswLAADAvAsADDAjAsAMMCDAvA'
  'sAAMCzAsAMMCMCzAsAAMC8CwAMMCMCwAwwIMC8CwAAwLMCwAwwIwLMCwAAwLMCwAwwIw'
  'LMCwAAwLwLAAwwIwLADDAgwLwLAADAswLADDAjAswLAADAvAsADDAjAsAMMCDAvAsAAM'
  'CzAsAMMCMCzAsAAMCzAsAMMCMCzAsAAMC8CwAMMCMCwAwwIMC8CwAAwLMCwAwwIwLMCw'
  'AAwLwLAAwwIwLADDAgwLwLAADAswLADDAjAswLAADAswLADDAjAswLAADAvAsADDAjAs'
  'AMMCDAvAsAAMCzAsAMMCMCzAsAAMC8CwAMMCMCwAwwIMC8CwAAwLMCyAOwvXb6SSgsrY'
  'FgAAAABJRU5ErkJggg==',
);

Widget _host(Uri uri, {double width = 300}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Builder(
          builder: (context) =>
              ChatGatedImage(uri: uri, colors: Theme.of(context).hermes),
        ),
      ),
    ),
  ),
);

/// Serves [_png] and counts the requests.
class _ImageServer extends http.BaseClient {
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(
      Stream.value(_png),
      200,
      contentLength: _png.length,
      headers: {'content-type': 'image/png'},
    );
  }
}

/// Opens the placeholder and lets the download finish on the real event
/// loop (runAsync), then builds one frame. The image is not decoded yet:
/// the test looks at the box before the first frame.
Future<void> _load(WidgetTester tester, http.Client client) async {
  final open = tester
      .widget<GestureDetector>(
        find
            .descendant(
              of: find.byType(ChatGatedImage),
              matching: find.byType(GestureDetector),
            )
            .first,
      )
      .onTap!;
  await tester.runAsync(
    () => http.runWithClient(() async {
      open();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }, () => client),
  );
  await tester.pump();
}

void main() {
  testWidgets('a loaded image reserves its final height before its first '
      'frame', (tester) async {
    final client = _ImageServer();
    await tester.pumpWidget(_host(Uri.parse('https://imagenes.example/a.png')));

    final image = find.descendant(
      of: find.byType(ChatGatedImage),
      matching: find.byType(Image),
    );
    await _load(tester, client);
    expect(
      image,
      findsOneWidget,
      reason:
          'spinner: ${find.byType(CircularProgressIndicator).evaluate().length}'
          ' retry: ${find.byIcon(Icons.refresh_rounded).evaluate().length}'
          ' requests: ${client.requests}',
    );
    // 300 dp wide, 2:1, before any frame of the picture was decoded.
    expect(tester.getSize(image), const Size(300, 150));
    expect(tester.getSize(find.byType(ChatGatedImage)), const Size(300, 150));
  });

  testWidgets('a picture narrower than the bubble keeps its own width', (
    tester,
  ) async {
    final client = _ImageServer();
    await tester.pumpWidget(
      _host(Uri.parse('https://imagenes.example/b.png'), width: 600),
    );

    final image = find.descendant(
      of: find.byType(ChatGatedImage),
      matching: find.byType(Image),
    );
    await _load(tester, client);
    expect(tester.getSize(image), const Size(400, 200));
  });
}
