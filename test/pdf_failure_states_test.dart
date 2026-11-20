// A PDF whose pages cannot be shown says why, with the file's actions; a
// renderer that does not answer is given up at a deadline, and only then is
// Retry offered.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/attachment_history_preview.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAY'
  'AAjCB0C8AAAAASUVORK5CYII=',
);

const _documents = MethodChannel('hermes/document_preview');

const _damaged =
    'This PDF could not be opened. It may be damaged or protected.';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.fromMode(AppThemeMode.dark),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

/// Lets real file reads finish between frames until [done] holds.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Answers the document channel with [answer] and records the calls.
List<MethodCall> _answerDocuments(
  Future<Object?> Function(MethodCall call) answer,
) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_documents, (call) {
    calls.add(call);
    return answer(call);
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_documents, null));
  return calls;
}

/// A PDF kept where generated media is kept (so the renderer gets keys).
File _storedPdf(Directory directory) {
  final folder = Directory('${directory.path}/generated_media/${'c' * 64}')
    ..createSync(recursive: true);
  return File('${folder.path}/${'d' * 64}.pdf')
    ..writeAsBytesSync(utf8.encode('%PDF-1.4\n'));
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('viewer-recovery-');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('PDF', () {
    Widget screen(File file, {VoidCallback? onShare, VoidCallback? onSave}) =>
        AttachmentBytesPreviewScreen(
          name: 'report.pdf',
          sizeLabel: '9 B',
          reference: AttachmentHistoryReference(
            index: 0,
            storageKey: 'd' * 64,
            type: AttachmentType.document,
            mimeType: 'application/pdf',
            sizeBytes: file.lengthSync(),
            sha256Hex: 'd' * 64,
          ),
          file: file,
          onOpenExternal: () {},
          onShare: onShare,
          onSave: onSave,
        );

    testWidgets('a PDF the renderer refuses says so with the file actions, '
        'not a hex dump, and no Retry', (tester) async {
      final calls = _answerDocuments(
        (call) async => throw PlatformException(code: 'pdf', message: 'bad'),
      );
      var shared = 0;
      var saved = 0;
      final file = _storedPdf(directory);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: screen(file, onShare: () => shared++, onSave: () => saved++),
        ),
      );
      await _until(
        tester,
        () => find.text(_damaged).evaluate().isNotEmpty,
      );

      expect(calls, isNotEmpty);
      expect(find.text(_damaged), findsOneWidget);
      expect(find.textContaining('0000000'), findsNothing, reason: 'no hex');
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Share'));
      await tester.tap(find.text('Save'));
      expect((shared, saved), (1, 1));
    });

    testWidgets('a renderer that does not answer is given up at its deadline '
        'and Retry renders again', (tester) async {
      var answer = false;
      final calls = _answerDocuments((call) {
        if (!answer) return Completer<Object?>().future;
        return Future.value(<String, Object>{'pngBytes': _png, 'pageCount': 1});
      });
      final file = _storedPdf(directory);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: screen(file),
        ),
      );
      await _until(tester, () => calls.isNotEmpty);
      expect(find.text(_damaged), findsNothing);

      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
      expect(find.text(_damaged), findsOneWidget);
      expect(find.text('It took too long to draw.'), findsOneWidget);

      answer = true;
      await tester.tap(find.text('Retry'));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('attachment-pdf-page-0'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byKey(const ValueKey('attachment-pdf-page-0')), findsOne);
    });

    testWidgets('the chat card of a PDF whose renderer does not answer becomes '
        'the file card, with its actions', (tester) async {
      final calls = _answerDocuments((call) => Completer<Object?>().future);
      final file = _storedPdf(directory);
      var opened = 0;
      await tester.pumpWidget(
        _host(
          GeneratedPdfPreviewCard(
            file: file,
            name: 'report.pdf',
            sizeBytes: file.lengthSync(),
            onOpen: () => opened++,
            onShare: () {},
            onSave: () {},
          ),
        ),
      );
      await _until(tester, () => calls.isNotEmpty);
      expect(
        find.byKey(const ValueKey<String>('generated-pdf-loading')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('generated-pdf-loading')),
        findsNothing,
      );
      await tester.tap(find.text('Open'));
      expect(opened, 1);
    });

    testWidgets('the full screen PDF viewer gives a silent renderer up and '
        'says the PDF could not be opened', (tester) async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => directory.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
      final calls = _answerDocuments((call) => Completer<Object?>().future);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: ArtifactViewerScreen(
            name: 'report.pdf',
            mimeType: 'application/pdf',
            loadBytes: () async => Uint8List.fromList(utf8.encode('%PDF-1.4')),
            onShare: () {},
          ),
        ),
      );
      await _until(tester, () => calls.isNotEmpty);
      expect(
        find.byKey(const ValueKey('artifact-viewer-fallback')),
        findsNothing,
      );

      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('artifact-viewer-fallback')),
        findsOneWidget,
      );
      expect(find.text(_damaged), findsOneWidget);
      expect(find.textContaining("can't be viewed"), findsNothing);
    });

    testWidgets('a damaged PDF full screen says it could not be opened, not '
        'that its type is not viewable', (tester) async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => directory.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
      final calls = _answerDocuments(
        (call) async => throw PlatformException(code: 'pdf', message: 'bad'),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: ArtifactViewerScreen(
            name: 'report.pdf',
            mimeType: 'application/pdf',
            loadBytes: () async =>
                Uint8List.fromList(utf8.encode('%PDF-1.4\nbroken')),
            onShare: () {},
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('artifact-viewer-fallback'))
            .evaluate()
            .isNotEmpty,
      );
      expect(calls, isNotEmpty);
      expect(
        find.byKey(const ValueKey('artifact-viewer-fallback')),
        findsOneWidget,
      );
      expect(find.text(_damaged), findsOneWidget);
      expect(find.textContaining("can't be viewed"), findsNothing);
    });
  });
}
