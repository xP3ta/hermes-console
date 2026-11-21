// Opening a chat with several previews made its rows jump and blink.
//
// A file already on the phone (a page, a note, a PDF) drew its Download
// button, then a progress bar, then the file, three heights in a list that
// grows upwards. A page preview dropped its live page in the very frame the
// still picture was set, before the picture had a frame, leaving the box
// empty; and built again it showed a placeholder although its picture was
// in memory. Each is asserted on the frames in between, not on the end.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/services/media_prefetcher.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/web_preview.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAY'
    'AAjCB0C8AAAAASUVORK5CYII=';

const String _scope = 'conn-flicker\u0000default';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(AppThemeMode.dark),
  home: Scaffold(
    body: ListView(children: [child, const SizedBox(height: 40)]),
  ),
);

void main() {
  group('a file already on the phone', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('preview-flicker-');
      GeneratedMediaAttachmentCard.clearReadyMemoForTesting();
      MediaPrefetcher.instance.resetForTesting();
      GeneratedMediaService.cacheRootForTesting = temp;
    });

    tearDown(() {
      GeneratedMediaService.cacheRootForTesting = null;
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    GeneratedMediaReference note(String name) => GeneratedMediaReference(
      source: '/workspace/out/$name',
      kind: GeneratedMediaKind.file,
      sourceKind: GeneratedMediaSourceKind.serverPath,
      displayName: name,
      mimeType: 'text/plain',
    );

    testWidgets('is its ready card on the first frame after a restart: no '
        'Download button, no progress, no fetch', (tester) async {
      final reference = note('notes.txt');
      await tester.runAsync(
        () => GeneratedMediaService.ensureDownloaded(
          _scope,
          reference,
          fetchServerPath: (_) async =>
              Uint8List.fromList(utf8.encode('first line\nsecond line\n')),
          baseDir: temp,
        ),
      );
      // A restart: nothing remembered in memory, only the copy on disk.
      GeneratedMediaAttachmentCard.clearReadyMemoForTesting();
      var loads = 0;
      await tester.pumpWidget(
        _host(
          GeneratedMediaAttachmentCard(
            reference: reference,
            autoLoad: true,
            readyMemoKey: _scope,
            load: (_, _) async {
              loads++;
              throw StateError('a cached file must not be fetched');
            },
          ),
        ),
      );
      final strings = Strings.of(tester.element(find.byType(Scaffold)));

      // The very first frame, and the ones after it.
      for (var frame = 0; frame < 4; frame++) {
        expect(
          find.byType(GeneratedTextPreviewCard),
          findsOneWidget,
          reason: 'frame $frame',
        );
        expect(find.text(strings.commonDownload), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.textContaining('first line'), findsOneWidget);
      expect(loads, 0);
    });

    testWidgets('a name that is never previewed is still not restored', (
      tester,
    ) async {
      final secret = File('${temp.path}/secret.env')..writeAsStringSync('K=1');
      final reference = note('prod.env');
      expect(
        GeneratedMediaService.isSafeForInlinePreviewSync(reference, secret),
        isFalse,
      );
      final plain = File('${temp.path}/plain.txt')..writeAsStringSync('hello');
      final ok = note('plain.txt');
      final sync = GeneratedMediaService.isSafeForInlinePreviewSync(ok, plain);
      final later = await tester.runAsync(
        () => GeneratedMediaService.isSafeForInlinePreview(ok, plain),
      );
      expect(sync, later, reason: 'the same answer as the check of a load');
    });
  });

  testWidgets('a page preview keeps its page under the picture until the '
      'picture has a frame, and is its picture at once when built again', (
    tester,
  ) async {
    final web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;
    const key = 'flicker-test:page-one';

    Widget preview({
      Future<String?> Function()? resolve,
      String? Function()? known,
      Key? boxKey,
    }) => SizedBox(
      key: boxKey,
      width: 240,
      child: InlineWebPreview(
        document: () async => '<!doctype html><p>page</p>',
        label: 'HTML',
        icon: Icons.language,
        snapshotKey: resolve == null ? key : null,
        resolveSnapshotKey: resolve,
        knownSnapshotKey: known,
        readyScript: 'READY',
        captureScript: 'CAPTURE',
      ),
    );

    await tester.pumpWidget(_host(preview(boxKey: const ValueKey('first'))));
    final page = find.byKey(const ValueKey('inline-web-preview-page'));
    final picture = find.byKey(const ValueKey('inline-web-preview-picture'));

    var sawPage = false;
    for (var i = 0; i < 60 && picture.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (web.controllers.isNotEmpty) {
        web.last.javaScriptResponder ??= (script) {
          if (script.contains('CAPTURE')) {
            return '"data:image/png;base64,$_pngBase64"';
          }
          if (script.contains('READY')) return 1;
          if (script.contains('scrollHeight')) return 120;
          return 0;
        };
      }
      if (page.evaluate().isNotEmpty) sawPage = true;
      if (sawPage) {
        expect(
          page.evaluate().isNotEmpty || picture.evaluate().isNotEmpty,
          isTrue,
          reason: 'never a frame with neither the page nor its picture',
        );
      }
    }
    expect(sawPage, isTrue);
    expect(picture, findsOneWidget);
    // The picture is set but not decoded yet: the page is still under it.
    expect(page, findsOneWidget);

    for (var i = 0; i < 60 && page.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(picture, findsOneWidget);
    }
    expect(page, findsNothing, reason: 'the page goes once the picture drew');
    expect(picture, findsOneWidget);
    final pagesMade = web.controllers.length;

    // Built again (the chat opened a second time) with a key that takes
    // work to work out, but is already known for these bytes.
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await tester.pumpWidget(
      _host(
        preview(
          boxKey: const ValueKey('second'),
          resolve: () => Completer<String?>().future,
          known: () => key,
        ),
      ),
    );
    expect(picture, findsOneWidget, reason: 'on its first frame');
    await tester.pump(const Duration(milliseconds: 400));
    expect(picture, findsOneWidget);
    expect(web.controllers, hasLength(pagesMade), reason: 'no page is made');
  });
}
