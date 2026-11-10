// Thumbnails of «Artefactos»: fetched only for cells that are built, a few
// at a time, remembered within a bound, each with its own state.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/artifact_media.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_content_thumbnail.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

ChatContentItem _image(String name) => ChatContentItem(
  kind: ChatContentKind.image,
  value: '/srv/img/$name',
  href: '/srv/img/$name',
  label: name,
);

/// A fetch the test resolves by hand.
class _Fetches {
  final calls = <String>[];
  final pending = <String, Completer<File>>{};

  Future<File> call(ChatContentItem item) {
    calls.add(item.value);
    return (pending[item.value] = Completer<File>()).future;
  }

  void finish(String value, File file) => pending.remove(value)!.complete(file);

  void fail(String value) =>
      pending.remove(value)!.completeError(const FileSystemException('x'));
}

/// Lets a fetch that just finished reach the screen: the first pump runs
/// the microtasks that end in the thumbnail's setState, the second draws
/// the frame that setState asked for. One pump is not enough when no other
/// frame is pending (the loader animates on a timer, not a ticker).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  group('loader', () {
    test('at most maxConcurrent fetches run; the rest wait', () async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      for (var i = 0; i < 5; i++) {
        unawaited(loader.load(_image('$i.png'), wanted: () => true));
      }
      expect(fetches.calls, hasLength(3));
      expect(loader.activeCount, 3);
      expect(loader.queuedCount, 2);
      fetches.finish('/srv/img/0.png', File('/cache/0.png'));
      await pumpEventQueue();
      expect(fetches.calls, hasLength(4));
      expect(loader.activeCount, 3);
    });

    test('a request no longer wanted when its turn comes is dropped', () async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(
        fetch: fetches.call,
        maxConcurrent: 1,
      );
      unawaited(loader.load(_image('a.png'), wanted: () => true));
      final gone = loader.load(_image('b.png'), wanted: () => false);
      fetches.finish('/srv/img/a.png', File('/cache/a.png'));
      expect(await gone, isNull);
      expect(fetches.calls, ['/srv/img/a.png']);
      expect(loader.settled('/srv/img/b.png'), isNull);
    });

    test('the same image is fetched once and remembered', () async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      final first = loader.load(_image('a.png'), wanted: () => true);
      final second = loader.load(_image('a.png'), wanted: () => true);
      fetches.finish('/srv/img/a.png', File('/cache/a.png'));
      expect((await first)?.path, '/cache/a.png');
      expect((await second)?.path, '/cache/a.png');
      expect(
        (await loader.load(_image('a.png'), wanted: () => true))?.path,
        '/cache/a.png',
      );
      expect(fetches.calls, hasLength(1));
    });

    test('a failed fetch settles as null and is remembered too', () async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      final result = loader.load(_image('a.png'), wanted: () => true);
      fetches.fail('/srv/img/a.png');
      expect(await result, isNull);
      expect(loader.settled('/srv/img/a.png')?.file, isNull);
      expect(loader.settled('/srv/img/a.png'), isNotNull);
    });

    test('a cache key keeps one path of two profiles apart', () async {
      final fetched = <String>[];
      final owner = <ChatContentItem, String>{};
      final loader = ChatContentThumbnailLoader(
        fetch: (item) async {
          fetched.add('${owner[item]}:${item.value}');
          return File('/cache/${owner[item]}.png');
        },
        cacheKey: (item) => '${owner[item]}\u0000${item.value}',
      );
      final work = _image('a.png');
      final home = _image('a.png');
      owner[work] = 'work';
      owner[home] = 'home';
      final first = await loader.load(work, wanted: () => true);
      final second = await loader.load(home, wanted: () => true);
      expect(first?.path, '/cache/work.png');
      expect(second?.path, '/cache/home.png');
      expect(fetched, ['work:/srv/img/a.png', 'home:/srv/img/a.png']);
    });

    test('memory keeps only the last maxEntries outcomes', () async {
      final loader = ChatContentThumbnailLoader(
        fetch: (item) async => File('/cache/${item.label}'),
        maxEntries: 4,
      );
      for (var i = 0; i < 10; i++) {
        await loader.load(_image('$i.png'), wanted: () => true);
      }
      expect(loader.settledCount, 4);
      expect(loader.settled('/srv/img/0.png'), isNull);
      expect(loader.settled('/srv/img/9.png')?.file?.path, '/cache/9.png');
    });
  });

  group('thumbnail', () {
    testWidgets('loading, then the image, scaled down when decoded', (
      tester,
    ) async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 180,
            child: ChatContentThumbnail(
              item: _image('a.png'),
              loader: loader,
              height: 140,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('sa1215-thumb-loading')), findsOne);
      expect(fetches.calls, ['/srv/img/a.png']);
      fetches.finish('/srv/img/a.png', File('/cache/a.png'));
      await _settle(tester);
      final image = tester.widget<Image>(
        find.byKey(const ValueKey('sa1215-thumb-image')),
      );
      final resized = image.image as ResizeImage;
      expect((resized.imageProvider as FileImage).file.path, '/cache/a.png');
      expect(resized.width, lessThanOrEqualTo(1024));
      expect(image.fit, BoxFit.contain);
    });

    testWidgets('a fetch that fails says so on the thumbnail', (tester) async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      await tester.pumpWidget(
        _app(
          ChatContentThumbnail(
            item: _image('a.png'),
            loader: loader,
            height: 140,
          ),
        ),
      );
      await tester.pump();
      fetches.fail('/srv/img/a.png');
      await _settle(tester);
      expect(find.byKey(const ValueKey('sa1215-thumb-error')), findsOne);
      // It says why (R5C C-V1), never a bare «Sin vista previa».
      expect(find.text('No se pudo descargar'), findsOne);
      expect(find.text('Sin vista previa'), findsNothing);
    });

    testWidgets('the failure says why, as the fetch reported it', (
      tester,
    ) async {
      final reasons = {
        'remote.png': (
          ArtifactFetchProblem.remote,
          'Imagen remota no disponible',
        ),
        'insecure.png': (
          ArtifactFetchProblem.insecure,
          'Imagen por http, sin cifrar',
        ),
        'rel.png': (ArtifactFetchProblem.noFolder, 'Ruta sin carpeta'),
        'gone.png': (ArtifactFetchProblem.notFound, 'No está en el servidor'),
        'big.png': (ArtifactFetchProblem.tooLarge, 'Demasiado grande'),
        'secret.png': (ArtifactFetchProblem.denied, 'Hermes no deja leerla'),
      };
      final loader = ChatContentThumbnailLoader(
        fetch: (item) async =>
            throw ArtifactFetchFailure(reasons[item.label]!.$1),
        maxConcurrent: 6,
      );
      await tester.pumpWidget(
        _app(
          ListView(
            children: [
              for (final name in reasons.keys)
                ChatContentThumbnail(
                  key: ValueKey(name),
                  item: _image(name),
                  loader: loader,
                  height: 80,
                ),
            ],
          ),
        ),
      );
      await _settle(tester);
      for (final MapEntry(key: name, value: (_, text)) in reasons.entries) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey(name)),
            matching: find.text(text),
          ),
          findsOne,
          reason: name,
        );
      }
      expect(loader.failedCount, reasons.length);
    });

    testWidgets('retry fetches the failed thumbnails again, only those', (
      tester,
    ) async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      var notified = 0;
      loader.addListener(() => notified++);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              for (final name in ['a.png', 'b.png'])
                ChatContentThumbnail(
                  key: ValueKey(name),
                  item: _image(name),
                  loader: loader,
                  height: 60,
                ),
            ],
          ),
        ),
      );
      fetches.fail('/srv/img/a.png');
      fetches.finish('/srv/img/b.png', File('/cache/b.png'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sa1215-thumb-error')), findsOne);
      expect(loader.failedCount, 1);
      expect(notified, greaterThan(0));

      Finder inside(String name, String key) => find.descendant(
        of: find.byKey(ValueKey(name)),
        matching: find.byKey(ValueKey(key)),
      );
      loader.retryFailed();
      await tester.pump();
      // Only the failed one asks again; it shows it is loading meanwhile.
      expect(fetches.calls, [
        '/srv/img/a.png',
        '/srv/img/b.png',
        '/srv/img/a.png',
      ]);
      expect(inside('a.png', 'sa1215-thumb-loading'), findsOne);
      // The one that had loaded keeps its image: it is not asked again.
      // (Its placeholder while the test's file decodes, which never happens
      // here, shares the loading key, so the count is per thumbnail.)
      expect(inside('b.png', 'sa1215-thumb-image'), findsOne);
      fetches.finish('/srv/img/a.png', File('/cache/a.png'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sa1215-thumb-error')), findsNothing);
      expect(loader.failedCount, 0);
    });

    testWidgets('a thumbnail scrolled away before its turn never fetches', (
      tester,
    ) async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(
        fetch: fetches.call,
        maxConcurrent: 1,
      );
      Widget cells(List<String> names) => _app(
        Column(
          children: [
            for (final name in names)
              ChatContentThumbnail(
                key: ValueKey(name),
                item: _image(name),
                loader: loader,
                height: 60,
              ),
          ],
        ),
      );
      await tester.pumpWidget(cells(['a.png', 'b.png']));
      expect(fetches.calls, ['/srv/img/a.png']);
      expect(loader.queuedCount, 1);
      // b leaves the screen while a still holds the only slot.
      await tester.pumpWidget(cells(['a.png']));
      fetches.finish('/srv/img/a.png', File('/cache/a.png'));
      await tester.pump();
      expect(fetches.calls, ['/srv/img/a.png']);
      expect(loader.queuedCount, 0);
    });

    testWidgets('SVG and no loader: nothing fetched, each says what it is', (
      tester,
    ) async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              ChatContentThumbnail(
                item: _image('logo.svg'),
                loader: loader,
                height: 100,
              ),
              ChatContentThumbnail(
                item: _image('b.png'),
                loader: null,
                height: 100,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      // R5C C-V1: an SVG says why it has no preview; with no loader the
      // tile keeps its plain glyph.
      expect(find.byKey(const ValueKey('sa1215-thumb-svg')), findsOne);
      expect(find.text('SVG: sin vista previa en la app'), findsOne);
      expect(find.byKey(const ValueKey('sa1215-thumb-none')), findsOne);
      expect(fetches.calls, isEmpty);
    });

    testWidgets('an inline data image needs no fetch', (tester) async {
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
          '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      const value = 'data:image/png;base64,$png';
      await tester.pumpWidget(
        _app(
          const ChatContentThumbnail(
            item: ChatContentItem(
              kind: ChatContentKind.image,
              value: value,
              href: value,
              label: 'data:image/png;base64',
            ),
            loader: null,
            height: 100,
          ),
        ),
      );
      final image = tester.widget<Image>(
        find.byKey(const ValueKey('sa1215-thumb-image')),
      );
      expect((image.image as ResizeImage).imageProvider, isA<MemoryImage>());
    });

    test('every reason is its own, never a bare «Sin vista previa»', () {
      final Strings es = StringsEs();
      final texts = {
        for (final problem in ArtifactFetchProblem.values)
          artifactFetchReason(es, problem),
      };
      // One text per reason, so each case says why.
      expect(texts, hasLength(ArtifactFetchProblem.values.length));
      expect(texts, isNot(contains('Sin vista previa')));
      expect(artifactFetchReason(es, null), 'No se pudo descargar');
      expect(
        artifactFetchReason(es, ArtifactFetchProblem.unreachable),
        'No se pudo conectar con Hermes',
      );
      expect(
        artifactFetchReason(es, ArtifactFetchProblem.notImage),
        'El archivo no es una imagen',
      );
    });

    testWidgets('an SVG says it has no preview, also to TalkBack', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final fetches = _Fetches();
      await tester.pumpWidget(
        _app(
          ChatContentThumbnail(
            item: _image('diagram.svg'),
            loader: ChatContentThumbnailLoader(fetch: fetches.call),
            height: 140,
          ),
        ),
      );
      expect(find.text('SVG: sin vista previa en la app'), findsOne);
      expect(
        find.bySemanticsLabel('SVG: sin vista previa en la app'),
        findsOne,
      );
      expect(fetches.calls, isEmpty);
      handle.dispose();
    });

    testWidgets('a picture that does not decode says so', (tester) async {
      final fetches = _Fetches();
      final loader = ChatContentThumbnailLoader(fetch: fetches.call);
      await tester.pumpWidget(
        _app(
          ChatContentThumbnail(
            item: _image('broken.png'),
            loader: loader,
            height: 140,
          ),
        ),
      );
      fetches.finish('/srv/img/broken.png', File('/cache/broken.png'));
      await _settle(tester);
      final image = tester.widget<Image>(
        find.byKey(const ValueKey('sa1215-thumb-image')),
      );
      // What the image shows when the engine cannot decode it.
      final shown = Builder(
        builder: (context) =>
            image.errorBuilder!(context, Exception('bad'), null),
      );
      await tester.pumpWidget(_app(shown));
      expect(find.text('No se pudo abrir la imagen'), findsOne);
    });

    testWidgets('a thumbnail is decoded bounded in both directions', (
      tester,
    ) async {
      final fetches = _Fetches();
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 180,
            child: ChatContentThumbnail(
              item: _image('tall.png'),
              loader: ChatContentThumbnailLoader(fetch: fetches.call),
              height: 140,
            ),
          ),
        ),
      );
      fetches.finish('/srv/img/tall.png', File('/cache/tall.png'));
      await _settle(tester);
      final image = tester.widget<Image>(
        find.byKey(const ValueKey('sa1215-thumb-image')),
      );
      final resized = image.image as ResizeImage;
      expect(resized.width, lessThanOrEqualTo(1024));
      expect(resized.height, lessThanOrEqualTo(1024));
      expect(resized.policy, ResizeImagePolicy.fit);
    });
  });
}
