// M1 (performance audit 1.4.0, partial): a large generated text file keeps
// only its first 64 KB as the inline preview (read and decoded on the UI
// isolate), while its line count and the full viewer still cover the whole
// file.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(body: child),
);

Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump();
  expect(done(), isTrue);
}

void main() {
  setUp(GeneratedMediaAttachmentCard.clearReadyMemoForTesting);
  tearDown(GeneratedMediaAttachmentCard.clearReadyMemoForTesting);

  testWidgets('a large text keeps a 64 KB preview and its whole line count', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('perf140-text-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final lines = [for (var i = 1; i <= 900; i++) 'Linea $i ${'x' * 200}'];
    final file = File('${directory.path}/informe.txt')
      ..writeAsStringSync(lines.join('\n'));
    expect(file.lengthSync(), greaterThan(2 * 64 * 1024));
    var loads = 0;
    const reference = GeneratedMediaReference(
      source: '/workspace/informe.txt',
      kind: GeneratedMediaKind.file,
      sourceKind: GeneratedMediaSourceKind.serverPath,
      displayName: 'informe.txt',
      mimeType: 'text/plain',
    );
    Widget card() => GeneratedMediaAttachmentCard(
      reference: reference,
      autoLoad: true,
      readyMemoKey: 'scope-perf140',
      load: (onProgress, isCancelled) async {
        loads++;
        return file;
      },
    );
    final preview = find.byType(GeneratedTextPreviewCard);
    String previewText() =>
        tester.widget<GeneratedTextPreviewCard>(preview).text;

    await tester.pumpWidget(_host(card()));
    await _settle(tester, () => preview.evaluate().isNotEmpty);

    expect(loads, 1);
    expect(previewText().length, lessThanOrEqualTo(64 * 1024));
    expect(previewText(), startsWith('Linea 1 '));
    expect(find.textContaining('900 líneas'), findsOneWidget);

    // Disposed and built again (a row scrolled away and back): ready on its
    // first frame from the memo, still bounded, nothing downloaded again.
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await tester.pumpWidget(_host(card()));
    expect(preview, findsOneWidget);
    expect(previewText().length, lessThanOrEqualTo(64 * 1024));
    expect(find.textContaining('900 líneas'), findsOneWidget);
    expect(loads, 1);

    // The full viewer still opens with the whole file.
    final viewer = find.byKey(const ValueKey('generated-text-viewer-body'));
    await tester.tap(find.byKey(const ValueKey('generated-text-preview-body')));
    await _settle(tester, () => viewer.evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('Linea 900 '), findsOneWidget);
  });

  testWidgets('a small text keeps its whole content as the preview', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('perf140-small-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/nota.txt')
      ..writeAsStringSync('uno\ndos\ntres');
    const reference = GeneratedMediaReference(
      source: '/workspace/nota.txt',
      kind: GeneratedMediaKind.file,
      sourceKind: GeneratedMediaSourceKind.serverPath,
      displayName: 'nota.txt',
      mimeType: 'text/plain',
    );
    final preview = find.byType(GeneratedTextPreviewCard);

    await tester.pumpWidget(
      _host(
        GeneratedMediaAttachmentCard(
          reference: reference,
          autoLoad: true,
          load: (onProgress, isCancelled) async => file,
        ),
      ),
    );
    await _settle(tester, () => preview.evaluate().isNotEmpty);

    expect(
      tester.widget<GeneratedTextPreviewCard>(preview).text,
      'uno\ndos\ntres',
    );
    expect(find.textContaining('3 líneas'), findsOneWidget);
  });
}
