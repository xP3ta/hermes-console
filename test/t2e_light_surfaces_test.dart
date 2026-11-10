// Wave 8 (audit 1.4.0 §2.12): on a light page an artifact card's group
// tint is ~1.03:1 with the page, so the card had no visible edge. In light
// themes it gets the floating hairline; dark keeps its edge-less card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifacts/artifact_sections.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const item = ChatContentItem(
    kind: ChatContentKind.image,
    value: 'https://example.invalid/photo.png',
    href: 'https://example.invalid/photo.png',
    label: 'photo.png',
  );

  Future<BorderSide> cardEdge(WidgetTester tester, String themeId) async {
    final theme = AppTheme.fromId(themeId);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              children: [
                for (final entry in buildArtifactSections(
                  context: context,
                  items: const [item],
                  width: 392,
                  thumbnails: null,
                  onOpen: (_) {},
                  onCopy: (_) {},
                ))
                  entry(),
              ],
            ),
          ),
        ),
      ),
    );
    final material = tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('sa1215-item-photo.png')),
            matching: find.byType(Material),
          )
          .first,
    );
    return (material.shape! as RoundedRectangleBorder).side;
  }

  testWidgets('a light theme draws the card edge with the hairline', (
    tester,
  ) async {
    final side = await cardEdge(tester, 'console-light');
    final colors = AppTheme.fromId('console-light').hermes;
    expect(side.color, HermesChrome.of(colors).line);
    expect(side.style, BorderStyle.solid);
  });

  testWidgets('a dark theme keeps the card without an edge', (tester) async {
    expect(await cardEdge(tester, 'console'), BorderSide.none);
  });
}
