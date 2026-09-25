import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/attachment_history_preview.dart';
import 'package:hermes_android/core/widgets/generated_video_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';
import 'package:video_player/video_player.dart';

class _FakeAudioPlayback implements GeneratedAudioPlayback {
  final durations = StreamController<Duration>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final playing = StreamController<bool>.broadcast();
  int playCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  Duration? seekPosition;

  @override
  Stream<Duration> get durationChanges => durations.stream;

  @override
  Stream<Duration> get positionChanges => positions.stream;

  @override
  Stream<bool> get playingChanges => playing.stream;

  @override
  Future<void> play(File file) async {
    playCalls++;
    playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing.add(false);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    playing.add(true);
  }

  @override
  Future<void> seek(Duration position) async {
    seekPosition = position;
  }

  @override
  Future<void> dispose() async {
    await durations.close();
    await positions.close();
    await playing.close();
  }
}

void main() {
  Widget host(Widget child, {Locale locale = const Locale('es')}) =>
      MaterialApp(
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(body: child),
      );

  testWidgets('adjunto en subida muestra progreso y permite quitarlo', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AttachmentCard(
          name: 'captura.jpg',
          mimeType: 'image/jpeg',
          sizeLabel: '2 MB',
          showUploadState: true,
          uploadState: AttachmentUploadState.uploading,
          onRemove: () {},
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.textContaining('Subiendo'), findsOneWidget);
  });

  testWidgets('quitar adjunto tiene etiqueta y target de 48 dp', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AttachmentCard(
          name: 'documento.pdf',
          mimeType: 'application/pdf',
          sizeLabel: '20 KB',
          onRemove: () {},
        ),
      ),
    );

    final target = find
        .ancestor(
          of: find.byIcon(Icons.close),
          matching: find.byType(GestureDetector),
        )
        .first;
    expect(tester.getSize(target), const Size(48, 48));
    expect(find.bySemanticsLabel('Quitar adjunto'), findsOneWidget);
  });

  testWidgets('archivo generado muestra progreso determinado y cancelar', (
    tester,
  ) async {
    var cancelled = 0;
    await tester.pumpWidget(
      host(
        GeneratedFileCard(
          name: 'informe.pdf',
          mimeType: 'application/pdf',
          status: GeneratedFileStatus.downloading,
          receivedBytes: 512,
          totalBytes: 1024,
          onDownload: () {},
          onCancel: () => cancelled++,
        ),
      ),
    );

    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, 0.5);
    expect(find.textContaining('512 B / 1.0 KB'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    expect(cancelled, 1);

    await tester.pumpWidget(
      host(
        GeneratedFileCard(
          name: 'informe.pdf',
          mimeType: 'application/pdf',
          status: GeneratedFileStatus.downloading,
          receivedBytes: 512,
          onDownload: () {},
          onCancel: () {},
        ),
      ),
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    expect(find.textContaining('Cargando contenido generado'), findsOneWidget);
  });

  testWidgets('archivo generado listo ofrece abrir compartir y guardar', (
    tester,
  ) async {
    var opened = 0;
    var shared = 0;
    var saved = 0;
    await tester.pumpWidget(
      host(
        GeneratedFileCard(
          name: 'informe.pdf',
          mimeType: 'application/pdf',
          status: GeneratedFileStatus.ready,
          receivedBytes: 2048,
          totalBytes: 2048,
          onDownload: () {},
          onOpen: () => opened++,
          onShare: () => shared++,
          onSave: () => saved++,
        ),
      ),
    );

    await tester.tap(find.text('Abrir'));
    await tester.tap(find.text('Compartir'));
    await tester.tap(find.text('Guardar'));
    expect((opened, shared, saved), (1, 1, 1));
  });

  testWidgets('archivo generado fallido ofrece reintentar', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      host(
        GeneratedFileCard(
          name: 'informe.pdf',
          mimeType: 'application/pdf',
          status: GeneratedFileStatus.error,
          errorLabel: 'Este archivo ya no está disponible',
          onDownload: () => retries++,
        ),
      ),
    );

    expect(find.textContaining('ya no está disponible'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    expect(retries, 1);
  });

  testWidgets(
    'audio generado no reproduce solo y muestra duración y progreso',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('generated-audio-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final file = File('${directory.path}/resumen.mp3')..writeAsBytesSync([1]);
      final playback = _FakeAudioPlayback();

      await tester.pumpWidget(
        host(
          GeneratedAudioPlayerCard(
            file: file,
            name: 'resumen.mp3',
            mimeType: 'audio/mpeg',
            sizeBytes: 1024,
            playback: playback,
            onShare: () {},
            onSave: () {},
          ),
        ),
      );

      expect(playback.playCalls, 0);
      playback.durations.add(const Duration(minutes: 2));
      playback.positions.add(const Duration(seconds: 30));
      await tester.pump();
      expect(find.text('0:30 / 2:00'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(playback.playCalls, 1);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    },
  );

  testWidgets('audio generado permite pausa, seek, compartir y guardar', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('generated-audio-');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/resumen.mp3')..writeAsBytesSync([1]);
    final playback = _FakeAudioPlayback();
    var shared = 0;
    var saved = 0;

    await tester.pumpWidget(
      host(
        GeneratedAudioPlayerCard(
          file: file,
          name: 'resumen.mp3',
          mimeType: 'audio/mpeg',
          sizeBytes: 1024,
          playback: playback,
          onShare: () => shared++,
          onSave: () => saved++,
        ),
      ),
    );
    playback.durations.add(const Duration(minutes: 1));
    playback.playing.add(true);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.pause_rounded));
    expect(playback.pauseCalls, 1);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(30000);
    await tester.pump();
    expect(playback.seekPosition, const Duration(seconds: 30));
    await tester.tap(find.text('Compartir'));
    await tester.tap(find.text('Guardar'));
    expect((shared, saved), (1, 1));
  });

  testWidgets('error de imagen ofrece retry y remove independientes de 48 dp', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'attachment-card-image-',
    );
    addTearDown(() {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });
    final image = File('${directory.path}/pixel.png');
    image.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    var retries = 0;
    var removes = 0;

    await tester.pumpWidget(
      host(
        AttachmentCard(
          name: 'captura.png',
          mimeType: 'image/png',
          sizeLabel: '1 KB',
          thumbnailFile: image,
          showUploadState: true,
          uploadState: AttachmentUploadState.error,
          onRetry: () => retries++,
          onRemove: () => removes++,
        ),
      ),
    );

    expect(find.text('Error al subir'), findsOneWidget);
    expect(find.bySemanticsLabel('Reintentar adjunto'), findsOneWidget);
    expect(find.bySemanticsLabel('Quitar adjunto'), findsOneWidget);
    for (final icon in [Icons.refresh_rounded, Icons.close]) {
      final target = find
          .ancestor(
            of: find.byIcon(icon),
            matching: find.byType(GestureDetector),
          )
          .first;
      expect(tester.getSize(target), const Size(48, 48));
    }

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.tap(find.byIcon(Icons.close));
    expect(retries, 1);
    expect(removes, 1);
  });

  testWidgets('miniatura pendiente o adjuntada no lleva badge de estado', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'attachment-card-no-badge-',
    );
    addTearDown(() {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });
    final image = File('${directory.path}/pixel.png');
    image.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    for (final state in [
      AttachmentUploadState.pending,
      AttachmentUploadState.attached,
    ]) {
      await tester.pumpWidget(
        host(
          AttachmentCard(
            name: 'captura.png',
            mimeType: 'image/png',
            sizeLabel: '1 KB',
            thumbnailFile: image,
            showUploadState: true,
            uploadState: state,
            onRemove: () {},
          ),
        ),
      );
      expect(find.text('Pendiente'), findsNothing, reason: '$state');
      expect(find.text('Adjuntado'), findsNothing, reason: '$state');
      expect(find.byType(Image), findsOneWidget, reason: '$state');
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }

    // Uploading keeps its spinner overlay; error keeps its label and retry.
    await tester.pumpWidget(
      host(
        AttachmentCard(
          name: 'captura.png',
          mimeType: 'image/png',
          sizeLabel: '1 KB',
          thumbnailFile: image,
          showUploadState: true,
          uploadState: AttachmentUploadState.uploading,
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(
      host(
        AttachmentCard(
          name: 'captura.png',
          mimeType: 'image/png',
          sizeLabel: '1 KB',
          thumbnailFile: image,
          showUploadState: true,
          uploadState: AttachmentUploadState.error,
          onRetry: () {},
        ),
      ),
    );
    expect(find.text('Error al subir'), findsOneWidget);
    expect(find.bySemanticsLabel('Reintentar adjunto'), findsOneWidget);
  });

  testWidgets('miniatura de imagen conserva la proporción al decodificar', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'attachment-card-thumb-ratio-',
    );
    addTearDown(() {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });
    final image = File('${directory.path}/pixel.png');
    image.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    await tester.pumpWidget(
      host(
        AttachmentCard(
          name: 'captura.png',
          mimeType: 'image/png',
          sizeLabel: '1 KB',
          thumbnailFile: image,
        ),
      ),
    );

    final rendered = tester.widget<Image>(find.byType(Image));
    expect(rendered.fit, BoxFit.cover);
    final provider = rendered.image;
    expect(provider, isA<ResizeImage>());
    final resize = provider as ResizeImage;
    // Fixing both sides forces a 360x360 decode that squashes the bitmap
    // before `cover` runs; one bound keeps the aspect ratio.
    expect(
      resize.width == null || resize.height == null,
      isTrue,
      reason: 'cacheWidth y cacheHeight juntos deforman la miniatura',
    );
    expect(resize.width ?? resize.height, isNotNull);
    // Rebuilds during streaming must not blank the thumb while re-decoding.
    expect(rendered.gaplessPlayback, isTrue);
  });

  testWidgets('text summary pluralizes one line in English and Spanish', (
    tester,
  ) async {
    Widget preview() => GeneratedTextPreviewCard(
      name: 'note.txt',
      text: 'hello world',
      sizeBytes: 11,
      onOpen: () {},
      onShare: () {},
      onSave: () {},
    );

    await tester.pumpWidget(host(preview()));
    expect(find.text('1 línea · 11 B'), findsOneWidget);

    await tester.pumpWidget(host(preview(), locale: const Locale('en')));
    expect(find.text('1 line · 11 B'), findsOneWidget);

    expect(StringsEn().genMediaPages(1), '1 page');
    expect(StringsEn().genMediaPages(2), '2 pages');
    expect(StringsEs().genMediaPages(1), '1 página');
    expect(StringsEs().genMediaPages(2), '2 páginas');
  });

  testWidgets('text viewer keeps content above the system navigation inset', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800)
      ..padding = const FakeViewPadding(top: 28, bottom: 48)
      ..viewPadding = const FakeViewPadding(top: 28, bottom: 48);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(
        GeneratedTextViewerScreen(
          name: 'note.txt',
          text: 'hello world',
          sizeBytes: 11,
          onShare: () {},
          onSave: () {},
        ),
      ),
    );

    final viewport = find.byKey(
      const ValueKey('generated-text-viewer-safe-area'),
    );
    expect(tester.getRect(viewport).bottom, lessThanOrEqualTo(752));
  });

  testWidgets('image viewer keeps controls inside system safe areas', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800)
      ..padding = const FakeViewPadding(top: 28, bottom: 48)
      ..viewPadding = const FakeViewPadding(top: 28, bottom: 48);
    addTearDown(tester.view.reset);
    final directory = Directory.systemTemp.createTempSync('image-viewer-safe-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/pixel.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );

    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showImageViewer(context, file),
            child: const Text('Launch'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();

    final close = find.byIcon(Icons.close);
    final viewer = find.byKey(
      const ValueKey('generated-image-viewer-safe-area'),
    );
    expect(tester.getRect(close).top, greaterThanOrEqualTo(28));
    expect(tester.getRect(viewer).bottom, lessThanOrEqualTo(752));
  });

  testWidgets('video viewer keeps playback controls above navigation inset', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800)
      ..padding = const FakeViewPadding(top: 28, bottom: 48)
      ..viewPadding = const FakeViewPadding(top: 28, bottom: 48);
    addTearDown(tester.view.reset);
    final directory = Directory.systemTemp.createTempSync('video-viewer-safe-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/clip.mp4')
      ..writeAsBytesSync(<int>[0, 0, 0, 24]);
    final controller = VideoPlayerController.file(file);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showVideoViewer(context, file, controller),
            child: const Text('Launch'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final viewer = find.byKey(
      const ValueKey('generated-video-viewer-safe-area'),
    );
    final playback = find.byIcon(Icons.play_arrow_rounded);
    expect(tester.getRect(viewer).bottom, lessThanOrEqualTo(752));
    expect(tester.getRect(playback).bottom, lessThanOrEqualTo(752));
  });

  testWidgets('MEDIA text auto-loads and opens a selectable full viewer', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('generated-text-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/report.txt')
      ..writeAsStringSync('first line\nsecond line\nfull final line');
    var loads = 0;
    const reference = GeneratedMediaReference(
      source: '/workspace/report.txt',
      kind: GeneratedMediaKind.file,
      sourceKind: GeneratedMediaSourceKind.serverPath,
      displayName: 'report.txt',
      mimeType: 'text/plain',
      sizeBytes: 38,
    );

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: reference,
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            loads++;
            expect(isCancelled(), isFalse);
            onProgress(file.lengthSync(), file.lengthSync());
            return file;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.textContaining('first line\nsecond line'), findsOneWidget);
    expect(find.text('Descargar'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('generated-text-preview-body')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey('generated-text-viewer-body')),
      findsOneWidget,
    );
    expect(find.textContaining('full final line'), findsOneWidget);

    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.tap(find.byKey(const ValueKey('generated-text-copy')));
    await tester.pump();
    expect(copiedText, 'first line\nsecond line\nfull final line');
  });

  testWidgets(
    'el visor de texto completo desplaza al arrastrar sobre el contenido',
    (tester) async {
      // Reproduce el bug real del Pixel: SelectableText suelto dentro de un
      // SingleChildScrollView le ganaba el gesto de arrastre vertical al
      // scroll, así que arrastrar sobre el texto no desplazaba nunca. La
      // pantalla debe usar SelectionArea (que sí cede el arrastre al
      // ancestro Scrollable) en vez de SelectableText.
      final longText = List.generate(60, (i) => 'Linea ${i + 1}').join('\n');
      await tester.pumpWidget(
        host(
          GeneratedTextViewerScreen(
            name: 'largo.txt',
            text: longText,
            sizeBytes: longText.length,
            onShare: () {},
            onSave: () {},
          ),
        ),
      );
      await tester.pump();

      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.pixels, 0);
      expect(
        scrollable.position.maxScrollExtent,
        greaterThan(0),
        reason: 'el texto largo debe desbordar la pantalla',
      );

      // Comprobación estructural: la corrección real (probada a mano en un
      // Pixel real y en el emulador, arrastrando físicamente sobre el texto y
      // viendo cómo desplaza) es sustituir SelectableText por SelectionArea
      // envolviendo un Text plano. SelectableText suelto dentro de un
      // SingleChildScrollView se quedaba con cualquier arrastre vertical como
      // gesto de selección y el scroll nunca se movía; el simulador de
      // gestos synthetic de flutter_test no reproduce de forma fiable esa
      // resolución de árbitro de gestos aquí (movimiento en un solo salto vs.
      // multi-frame), así que esta prueba fija la forma del widget en vez de
      // fingir el arrastre: si alguien vuelve a poner un SelectableText
      // suelto aquí, esto falla.
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('generated-text-viewer-body')),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
        reason:
            'el texto completo debe ir dentro de SelectionArea (no '
            'SelectableText suelto) para no robarle el arrastre al scroll',
      );
      // tester.widget<Text>() ya lanza si el widget en esa key no es
      // exactamente Text (por ejemplo, si alguien lo revierte a
      // SelectableText, que no es subtipo de Text).
      tester.widget<Text>(
        find.byKey(const ValueKey('generated-text-viewer-body')),
      );
    },
  );

  testWidgets('sensitive text returned by a loader is never rendered inline', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'generated-sensitive-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/.netrc')
      ..writeAsStringSync('machine example.test password exposed');

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/report.txt',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'report.txt',
            mimeType: 'text/plain',
            sizeBytes: 37,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async => file,
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('password exposed'), findsNothing);
    expect(
      find.textContaining('Access to this file was denied'),
      findsOneWidget,
    );
  });

  testWidgets('APK waits for consent instead of auto-loading', (tester) async {
    var loads = 0;

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/payload.apk',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'payload.apk',
            mimeType: 'application/vnd.android.package-archive',
            sizeBytes: 4,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            loads++;
            throw StateError('must wait for consent');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 0);
    expect(find.text('Descargar'), findsOneWidget);
  });

  testWidgets('MEDIA image auto-loads directly into its ready preview', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('generated-image-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/pixel.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    var loads = 0;

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/pixel.png',
            kind: GeneratedMediaKind.image,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'pixel.png',
            mimeType: 'image/png',
            sizeBytes: 68,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            loads++;
            onProgress(file.lengthSync(), file.lengthSync());
            return file;
          },
          readyBuilder: (_, readyFile, _, _, _, _) =>
              Image.file(readyFile, key: const ValueKey('auto-loaded-image')),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.byKey(const ValueKey('auto-loaded-image')), findsOneWidget);
    expect(find.text('Descargar'), findsNothing);
  });

  testWidgets('MEDIA pdf audio and video auto-load into visible tiles', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('generated-kinds-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final pdf = File('${directory.path}/report.pdf')
      ..writeAsBytesSync(utf8.encode('%PDF-1.4'));
    final audio = File('${directory.path}/voice.mp3')
      ..writeAsBytesSync(<int>[0x49, 0x44, 0x33, 0]);
    final video = File('${directory.path}/clip.mp4')
      ..writeAsBytesSync(<int>[
        0,
        0,
        0,
        24,
        0x66,
        0x74,
        0x79,
        0x70,
        0x69,
        0x73,
        0x6f,
        0x6d,
      ]);

    for (final entry in <(GeneratedMediaReference, File, Key)>[
      (
        const GeneratedMediaReference(
          source: '/workspace/report.pdf',
          kind: GeneratedMediaKind.file,
          sourceKind: GeneratedMediaSourceKind.serverPath,
          displayName: 'report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 8,
        ),
        pdf,
        const ValueKey('pdf-ready-tile'),
      ),
      (
        const GeneratedMediaReference(
          source: '/workspace/clip.mp4',
          kind: GeneratedMediaKind.video,
          sourceKind: GeneratedMediaSourceKind.serverPath,
          displayName: 'clip.mp4',
          mimeType: 'video/mp4',
          sizeBytes: 12,
        ),
        video,
        const ValueKey('video-ready-tile'),
      ),
    ]) {
      await tester.pumpWidget(
        host(
          GeneratedMediaAttachmentCard(
            reference: entry.$1,
            autoLoad: true,
            load: (onProgress, isCancelled) async => entry.$2,
            readyBuilder: (_, _, _, _, _, _) => SizedBox(key: entry.$3),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(entry.$3), findsOneWidget);
      expect(find.text('Descargar'), findsNothing);
    }

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/voice.mp3',
            kind: GeneratedMediaKind.audio,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'voice.mp3',
            mimeType: 'audio/mpeg',
            sizeBytes: 4,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async => audio,
          audioPlayback: _FakeAudioPlayback(),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('generated-audio-player')),
      findsOneWidget,
    );
    expect(find.text('Descargar'), findsNothing);
  });

  testWidgets('MEDIA above its auto cap shows real size and Download', (
    tester,
  ) async {
    var loads = 0;
    const reference = GeneratedMediaReference(
      source: '/workspace/large.png',
      kind: GeneratedMediaKind.image,
      sourceKind: GeneratedMediaSourceKind.serverPath,
      displayName: 'large.png',
      mimeType: 'image/png',
      sizeBytes: GeneratedMediaService.maxAutoImageBytes + 1024,
    );

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: reference,
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            loads++;
            throw StateError('must not auto-load');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 0);
    expect(find.textContaining('15 MB'), findsOneWidget);
    expect(find.text('Descargar'), findsOneWidget);
  });

  testWidgets('non-current-session source keeps the consent card', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: 'https://example.test/report.txt',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.https,
            displayName: 'report.txt',
            mimeType: 'text/plain',
            sizeBytes: 12,
          ),
          autoLoad: false,
          load: (onProgress, isCancelled) async {
            loads++;
            throw StateError('must wait for consent');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 0);
    expect(find.text('Descargar'), findsOneWidget);
  });

  testWidgets('transient MEDIA failure retries before showing an error', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'generated-transient-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/ready.txt')
      ..writeAsStringSync('loaded on first visible attempt');
    var loads = 0;

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/ready.txt',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'ready.txt',
            mimeType: 'text/plain',
            sizeBytes: 31,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            loads++;
            if (loads == 1) throw const DashboardHttpException(503);
            return file;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('Reintentar'), findsNothing);
    expect(
      find.textContaining('loaded on first visible attempt'),
      findsOneWidget,
    );
  });

  testWidgets('rate-limited MEDIA keeps its calm error state', (tester) async {
    var loads = 0;

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/rate-limited.txt',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'rate-limited.txt',
            mimeType: 'text/plain',
            sizeBytes: 12,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            loads++;
            throw const DashboardAuthException(
              DashboardAuthFailureCode.rateLimited,
              statusCode: 429,
            );
          },
          errorLabelBuilder: (_, _) => 'Please wait before trying again',
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('failed MEDIA auto-load retries and becomes ready', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('generated-retry-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/retry.txt')
      ..writeAsStringSync('retry succeeded');
    var loads = 0;

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/retry.txt',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'retry.txt',
            mimeType: 'text/plain',
            sizeBytes: 15,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            loads++;
            if (loads == 1) throw StateError('temporary failure');
            return file;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reintentar'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.textContaining('retry succeeded'), findsOneWidget);
  });

  testWidgets('disposed queued MEDIA load yields its place to a visible card', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('generated-queue-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/visible.txt')
      ..writeAsStringSync('visible');
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();
    var disposedLoads = 0;
    var visibleLoads = 0;

    unawaited(
      GeneratedMediaService.runAutoLoad(() async {
        firstStarted.complete();
        await firstRelease.future;
      }),
    );
    unawaited(
      GeneratedMediaService.runAutoLoad(() async {
        secondStarted.complete();
        await secondRelease.future;
      }),
    );
    await Future.wait([firstStarted.future, secondStarted.future]);
    addTearDown(() {
      if (!firstRelease.isCompleted) firstRelease.complete();
      if (!secondRelease.isCompleted) secondRelease.complete();
    });

    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/disposed.txt',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'disposed.txt',
            mimeType: 'text/plain',
            sizeBytes: 7,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            disposedLoads++;
            return file;
          },
        ),
      ),
    );
    await tester.pump();
    expect(disposedLoads, 0);

    await tester.pumpWidget(host(const SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(
      host(
        GeneratedMediaAttachmentCard(
          reference: const GeneratedMediaReference(
            source: '/workspace/visible.txt',
            kind: GeneratedMediaKind.file,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'visible.txt',
            mimeType: 'text/plain',
            sizeBytes: 7,
          ),
          autoLoad: true,
          load: (onProgress, isCancelled) async {
            visibleLoads++;
            return file;
          },
        ),
      ),
    );
    await tester.pump();

    firstRelease.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(disposedLoads, 0);
    expect(visibleLoads, 1);
    expect(
      find.byKey(const ValueKey('generated-text-preview-body')),
      findsOneWidget,
    );

    secondRelease.complete();
    await tester.pumpWidget(host(const SizedBox.shrink()));
    await tester.pump();
  });

  test('external file opener sends opaque cache keys without a path', () async {
    final directory = Directory.systemTemp.createTempSync('generated-open-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final connectionKey = 'e' * 64;
    final fileKey = 'f' * 64;
    final cacheDirectory = Directory(
      '${directory.path}/generated_media/$connectionKey',
    )..createSync(recursive: true);
    final file = File('${cacheDirectory.path}/$fileKey.bin')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    MethodCall? openCall;
    const channel = MethodChannel('hermes/document_preview');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      openCall = call;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await openGeneratedMediaExternally(
      file,
      mimeType: 'application/octet-stream',
      expectedSize: file.lengthSync(),
    );

    expect(openCall?.method, 'openGeneratedFile');
    final arguments = openCall?.arguments as Map<Object?, Object?>;
    expect(arguments['generatedConnectionKey'], connectionKey);
    expect(arguments['generatedFileKey'], fileKey);
    expect(arguments['mimeType'], 'application/octet-stream');
    expect(arguments.containsKey('path'), isFalse);
    expect(arguments['storageKey'], arguments['expectedSha256']);
  });

  test('APK cannot invoke the external package installer channel', () async {
    final directory = Directory.systemTemp.createTempSync(
      'generated-apk-open-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final connectionKey = 'a' * 64;
    final fileKey = 'b' * 64;
    final cacheDirectory = Directory(
      '${directory.path}/generated_media/$connectionKey',
    )..createSync(recursive: true);
    final file = File('${cacheDirectory.path}/$fileKey.apk')
      ..writeAsBytesSync(<int>[0x50, 0x4b, 0x03, 0x04]);
    MethodCall? openCall;
    const channel = MethodChannel('hermes/document_preview');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      openCall = call;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      openGeneratedMediaExternally(
        file,
        mimeType: 'application/vnd.android.package-archive',
        expectedSize: file.lengthSync(),
      ),
      throwsA(isA<FormatException>()),
    );

    expect(openCall, isNull);
  });

  testWidgets('generic file opens an in-app viewer with distinct actions', (
    tester,
  ) async {
    var openedExternally = 0;
    var shared = 0;
    var saved = 0;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => GeneratedFileViewerScreen(
                  name: 'archive.bin',
                  mimeType: 'application/octet-stream',
                  sizeBytes: 4096,
                  onOpenWith: () => openedExternally++,
                  onShare: () => shared++,
                  onSave: () => saved++,
                ),
              ),
            ),
            child: const Text('Launch'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
    expect(find.text('archive.bin'), findsWidgets);
    expect(find.textContaining('application/octet-stream'), findsOneWidget);
    await tester.tap(find.text('Abrir con…'));
    await tester.tap(find.text('Compartir'));
    await tester.tap(find.text('Guardar'));
    expect((openedExternally, shared, saved), (1, 1, 1));
  });

  testWidgets('PDF generated preview uses opaque cache keys and page zero', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('generated-pdf-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final connectionKey = 'a' * 64;
    final fileKey = 'b' * 64;
    final cacheDirectory = Directory(
      '${directory.path}/generated_media/$connectionKey',
    )..createSync(recursive: true);
    final file = File('${cacheDirectory.path}/$fileKey.pdf')
      ..writeAsBytesSync(utf8.encode('%PDF-1.4\n'));
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    MethodCall? renderCall;
    const channel = MethodChannel('hermes/document_preview');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      renderCall = call;
      return <String, Object>{'pngBytes': pngBytes, 'pageCount': 3};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var opened = 0;
    var shared = 0;
    var saved = 0;

    await tester.runAsync(() async {
      await tester.pumpWidget(
        host(
          GeneratedPdfPreviewCard(
            file: file,
            name: 'report.pdf',
            sizeBytes: file.lengthSync(),
            onOpen: () => opened++,
            onShare: () => shared++,
            onSave: () => saved++,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(renderCall?.method, 'renderPdfPage');
    final arguments = renderCall?.arguments as Map<Object?, Object?>;
    expect(arguments['page'], 0);
    expect(arguments['generatedConnectionKey'], connectionKey);
    expect(arguments['generatedFileKey'], fileKey);
    expect(arguments.containsKey('path'), isFalse);
    expect(arguments['storageKey'], arguments['expectedSha256']);
    final thumbnail = find.byKey(
      const ValueKey<String>('generated-pdf-thumbnail'),
    );
    final caption = find.byKey(const ValueKey<String>('generated-pdf-caption'));
    final card = find.byKey(
      const ValueKey<String>('generated-pdf-preview-card'),
    );
    final actions = find.byKey(const ValueKey<String>('generated-pdf-actions'));
    expect(thumbnail, findsOneWidget);
    expect(find.textContaining('3 páginas'), findsOneWidget);
    expect(tester.getRect(thumbnail).width, tester.getRect(caption).width);
    expect(
      tester.getRect(thumbnail).bottom,
      lessThanOrEqualTo(tester.getRect(caption).top),
    );
    final thumbnailRect = tester.getRect(thumbnail);
    expect(thumbnailRect.width / thumbnailRect.height, closeTo(1, 0.01));
    expect(tester.getRect(thumbnail).height, lessThanOrEqualTo(320));
    expect(tester.getRect(card).left, tester.getRect(actions).left);

    await tester.tap(find.text('Abrir'));
    await tester.tap(find.text('Compartir'));
    await tester.tap(find.text('Guardar'));
    expect((opened, shared, saved), (1, 1, 1));
  });

  testWidgets('PDF viewer renders pages lazily with per-page zoom', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800)
      ..padding = const FakeViewPadding(top: 28, bottom: 48)
      ..viewPadding = const FakeViewPadding(top: 28, bottom: 48);
    addTearDown(tester.view.reset);
    final directory = Directory.systemTemp.createTempSync('generated-pdf-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final connectionKey = 'c' * 64;
    final fileKey = 'd' * 64;
    final cacheDirectory = Directory(
      '${directory.path}/generated_media/$connectionKey',
    )..createSync(recursive: true);
    final file = File('${cacheDirectory.path}/$fileKey.pdf')
      ..writeAsBytesSync(utf8.encode('%PDF-1.4\n'));
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final renderedPages = <int>[];
    const channel = MethodChannel('hermes/document_preview');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments['generatedConnectionKey'], connectionKey);
      expect(arguments['generatedFileKey'], fileKey);
      expect(arguments.containsKey('path'), isFalse);
      renderedPages.add(arguments['page']! as int);
      return <String, Object>{'pngBytes': pngBytes, 'pageCount': 3};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.runAsync(() async {
      await tester.pumpWidget(
        host(
          AttachmentBytesPreviewScreen(
            name: 'report.pdf',
            sizeLabel: '${file.lengthSync()} B',
            reference: AttachmentHistoryReference(
              index: 0,
              storageKey: fileKey,
              type: AttachmentType.document,
              mimeType: 'application/pdf',
              sizeBytes: file.lengthSync(),
              sha256Hex: fileKey,
            ),
            file: file,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(renderedPages, contains(0));
    expect(renderedPages, isNot(contains(2)));
    expect(find.byKey(const ValueKey('attachment-pdf-page-0')), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsWidgets);
    expect(
      tester.getRect(find.byType(ListView)).bottom,
      lessThanOrEqualTo(752),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(renderedPages, contains(2));
    expect(find.byKey(const ValueKey('attachment-pdf-page-2')), findsOneWidget);
  });
}
