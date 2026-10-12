import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/services/media_dimensions.dart';
import 'package:hermes_android/core/services/media_prefetcher.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/generated_image_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const String _scope = 'conn-presize\u0000default';

GeneratedMediaReference _ref(String name) => GeneratedMediaReference(
  source: '/workspace/generated/$name',
  kind: GeneratedMediaKind.image,
  sourceKind: GeneratedMediaSourceKind.serverPath,
  displayName: name,
  mimeType: 'image/png',
);

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: Scaffold(
        body: ListView(children: [child, const SizedBox(height: 40)]),
      ),
    ),
  ),
);

Widget _card(
  GeneratedMediaReference reference,
  GeneratedMediaFileLoader load,
) => GeneratedMediaAttachmentCard(
  key: const ValueKey('presize-card'),
  reference: reference,
  autoLoad: true,
  readyMemoKey: _scope,
  load: load,
  // Same ready widget the chat builds for MEDIA images.
  readyBuilder: (_, file, _, _, _, _) =>
      GeneratedImageCard(status: GeneratedImageStatus.ready, file: file),
);

Future<Uint8List> _realPng(WidgetTester tester, int w, int h) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xff3366ff),
    );
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

double _cardHeight(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('presize-card'))).height;

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('media-presize-');
    GeneratedMediaAttachmentCard.clearReadyMemoForTesting();
    MediaDimensionsCache.clearForTesting();
    MediaPrefetcher.instance.resetForTesting();
    GeneratedMediaService.cacheRootForTesting = temp;
  });

  tearDown(() {
    GeneratedMediaService.cacheRootForTesting = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  testWidgets(
    'known dimensions reserve the final height: no change when bytes land',
    (tester) async {
      final reference = _ref('wide.png');
      final file = File('${temp.path}/wide.png')
        ..writeAsBytesSync(await _realPng(tester, 400, 200));
      MediaDimensionsCache.remember(
        GeneratedMediaService.readyKey(_scope, reference),
        const Size(400, 200),
      );
      final gate = Completer<File>();
      await tester.pumpWidget(_host(_card(reference, (_, _) => gate.future)));
      await tester.pump();
      final heights = <double>[_cardHeight(tester)];
      // No file name flashes while the bytes are on their way.
      expect(find.text('wide.png'), findsNothing);
      expect(
        find.byKey(const ValueKey('generated-image-skeleton')),
        findsOneWidget,
      );

      gate.complete(file);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        heights.add(_cardHeight(tester));
      }
      await tester.pump(const Duration(milliseconds: 300));
      heights.add(_cardHeight(tester));

      expect(
        find.byKey(const ValueKey('generated-image-thumbnail')),
        findsOneWidget,
      );
      // 232 wide at 2:1 plus the card's vertical padding (2 x 5).
      expect(heights.toSet(), {232 / 2 + 10});
    },
  );

  testWidgets(
    'header probe of the cached copy sizes the first layout, no fetch',
    (tester) async {
      final reference = _ref('tall.png');
      final bytes = await _realPng(tester, 300, 450);
      await tester.runAsync(
        () => GeneratedMediaService.ensureDownloaded(
          _scope,
          reference,
          fetchServerPath: (_) async => bytes,
          baseDir: temp,
        ),
      );
      // A restart: no memo, no prefetch, no known dimensions.
      GeneratedMediaAttachmentCard.clearReadyMemoForTesting();
      MediaDimensionsCache.clearForTesting();
      var loads = 0;
      await tester.pumpWidget(
        _host(
          _card(reference, (_, _) async {
            loads++;
            throw StateError('cached media must not be fetched');
          }),
        ),
      );
      // First frame: the thumbnail, already at its final size.
      expect(
        find.byKey(const ValueKey('generated-image-thumbnail')),
        findsOneWidget,
      );
      expect(_cardHeight(tester), 232 + 10);
      await _settleIo(tester);
      expect(_cardHeight(tester), 232 + 10);
      expect(loads, 0);
    },
  );

  testWidgets('a row built mid-prefetch joins it: one fetch in total', (
    tester,
  ) async {
    final reference = _ref('joined.png');
    final bytes = await _realPng(tester, 200, 200);
    final key = GeneratedMediaService.readyKey(_scope, reference);
    var fetches = 0;
    final gate = Completer<void>();
    Future<File> download() async {
      fetches++;
      await gate.future;
      final file = File('${temp.path}/joined.png');
      await file.writeAsBytes(bytes);
      return file;
    }

    expect(
      MediaPrefetcher.instance.prefetch(
        key: key,
        reference: reference,
        load: download,
      ),
      isTrue,
    );
    await tester.pumpWidget(_host(_card(reference, (_, _) => download())));
    await tester.pump();
    expect(find.text('joined.png'), findsNothing);
    gate.complete();
    await _settleIo(tester);

    expect(fetches, 1);
    expect(
      find.byKey(const ValueKey('generated-image-thumbnail')),
      findsOneWidget,
    );
  });

  testWidgets('a rebuilt row after a finished prefetch paints at once', (
    tester,
  ) async {
    final reference = _ref('ready.png');
    final bytes = await _realPng(tester, 640, 360);
    final key = GeneratedMediaService.readyKey(_scope, reference);
    final file = File('${temp.path}/ready.png')..writeAsBytesSync(bytes);
    var fetches = 0;
    // The prefetch runs (and finishes) before the row exists.
    await tester.runAsync(() async {
      MediaPrefetcher.instance.prefetch(
        key: key,
        reference: reference,
        load: () async {
          fetches++;
          return file;
        },
      );
      await MediaPrefetcher.instance.pending(key);
    });
    await tester.pumpWidget(
      _host(
        _card(reference, (_, _) async {
          fetches++;
          return file;
        }),
      ),
    );
    expect(
      find.byKey(const ValueKey('generated-image-thumbnail')),
      findsOneWidget,
    );
    expect(_cardHeight(tester), 232 * 360 / 640 + 10);
    expect(fetches, 1);
  });

  testWidgets('reduced motion keeps the skeleton static', (tester) async {
    final reference = _ref('still.png');
    final gate = Completer<File>();
    await tester.pumpWidget(
      _host(_card(reference, (_, _) => gate.future), reduceMotion: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('generated-image-skeleton')),
      findsOneWidget,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
    gate.complete(File('${temp.path}/missing.png'));
    await _settleIo(tester);
  });
}
