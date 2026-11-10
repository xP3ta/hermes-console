import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/scan/document_scan_screen.dart';
import 'package:hermes_android/core/scan/scan_image_ops.dart';
import 'package:hermes_android/core/scan/scan_platform.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// A 120 x 90 "photo": dark table with a light sheet and a dark line of text.
ScanRgba _syntheticPhoto() {
  const w = 120, h = 90;
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final onSheet = x >= 14 && x < 106 && y >= 8 && y < 82;
      var v = onSheet ? 225 : 40;
      if (onSheet && y >= 40 && y < 44 && x >= 24 && x < 96) v = 50;
      final i = (y * w + x) * 4;
      px[i] = px[i + 1] = px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return ScanRgba(w, h, px);
}

/// Valid encoded bytes so the on-screen decode of the photo has no errors.
Uint8List _encodedPhoto() {
  final photo = _syntheticPhoto();
  final rgb = Uint8List(photo.width * photo.height * 3);
  for (var i = 0; i < photo.width * photo.height; i++) {
    rgb[i * 3] = photo.pixels[i * 4];
    rgb[i * 3 + 1] = photo.pixels[i * 4 + 1];
    rgb[i * 3 + 2] = photo.pixels[i * 4 + 2];
  }
  return encodePng(
    ScanBitmap(photo.width, photo.height, ScanPixelFormat.rgb, rgb),
  );
}

class _Host {
  _Host({this.decoder});

  final origins = <ScanImageOrigin>[];
  Future<ScanRgba?> Function(Uint8List)? decoder;
  ScanResult? result;
  bool popped = false;
  int maxPages = 10;

  Widget build({double textScale = 1}) {
    return MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-scanner'),
              onPressed: () async {
                result = await Navigator.of(context).push<ScanResult>(
                  MaterialPageRoute(
                    builder: (_) => DocumentScanScreen(
                      maxPages: maxPages,
                      runner: runScanInline,
                      clock: () => DateTime(2026, 1, 2, 3, 4, 5),
                      imageSource: (origin) async {
                        origins.add(origin);
                        return _encodedPhoto();
                      },
                      decoder: decoder ?? (_) async => _syntheticPhoto(),
                    ),
                  ),
                );
                popped = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _pumpFor(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _open(WidgetTester tester, _Host host, {double scale = 1}) async {
  await tester.pumpWidget(host.build(textScale: scale));
  await tester.tap(find.byKey(const ValueKey('open-scanner')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _pumpFor(tester);
}

Future<void> _takePhotoAndCrop(WidgetTester tester) async {
  await _tapKey(tester, 'scanDoc-take-photo');
  expect(find.byKey(const ValueKey('scanDoc-crop')), findsOneWidget);
  await _tapKey(tester, 'scanDoc-crop-continue');
}

FilledButton _filled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(ValueKey(key)));

void main() {
  testWidgets('photo, four corners, enhancement and export as one image', (
    tester,
  ) async {
    final host = _Host();
    await _open(tester, host);

    expect(find.text('Escanear documento'), findsOneWidget);
    expect(find.byKey(const ValueKey('scanDoc-take-photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('scanDoc-from-gallery')), findsOneWidget);

    await _tapKey(tester, 'scanDoc-take-photo');
    expect(host.origins, [ScanImageOrigin.camera]);
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(ValueKey('scanDoc-corner-$i')), findsOneWidget);
    }
    expect(
      find.text('Arrastra cada esquina hasta el borde del documento.'),
      findsOneWidget,
    );
    expect(_filled(tester, 'scanDoc-crop-continue').onPressed, isNotNull);

    final before = tester.getCenter(
      find.byKey(const ValueKey('scanDoc-corner-0')),
    );
    await tester.drag(
      find.byKey(const ValueKey('scanDoc-corner-0')),
      const Offset(120, 90),
    );
    await tester.pump();
    final after = tester.getCenter(
      find.byKey(const ValueKey('scanDoc-corner-0')),
    );
    expect(after.dx, greaterThan(before.dx + 10));
    expect(after.dy, greaterThan(before.dy + 5));

    await _tapKey(tester, 'scanDoc-crop-continue');
    expect(find.byKey(const ValueKey('scanDoc-preview')), findsOneWidget);
    expect(find.text('Página 1 de 1'), findsOneWidget);
    for (final label in ['Original', 'Grises', 'Contraste', 'Blanco y negro']) {
      expect(find.text(label), findsOneWidget);
    }
    // The last filter used (contrast) is preselected.
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('scanDoc-filter-contrast')),
          )
          .selected,
      isTrue,
    );

    await _tapKey(tester, 'scanDoc-filter-blackWhite');
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('scanDoc-filter-blackWhite')),
          )
          .selected,
      isTrue,
    );
    await _tapKey(tester, 'scanDoc-rotate');

    await _tapKey(tester, 'scanDoc-attach-images');
    await tester.pump(const Duration(milliseconds: 400));

    expect(host.popped, isTrue);
    final result = host.result!;
    expect(result.isPdf, isFalse);
    expect(result.files, hasLength(1));
    final file = result.files.single;
    expect(file.name, 'scan-20260102-030405-1.png');
    expect(file.mimeType, 'image/png');
    expect(file.bytes.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    // Black and white was chosen: 1 bit per pixel, grayscale colour type.
    expect(file.bytes[24], 1);
    expect(file.bytes[25], 0);
    // The page was rotated a quarter turn: taller than wide now? The photo is
    // landscape, so after rotation height > width.
    final view = ByteData.sublistView(file.bytes);
    expect(view.getUint32(20), greaterThan(view.getUint32(16)));
  });

  testWidgets('corners that fold the quad disable the crop with a reason', (
    tester,
  ) async {
    final host = _Host();
    await _open(tester, host);
    await _tapKey(tester, 'scanDoc-from-gallery');
    expect(host.origins, [ScanImageOrigin.gallery]);

    await tester.drag(
      find.byKey(const ValueKey('scanDoc-corner-0')),
      const Offset(4000, 4000),
    );
    await tester.pump();
    expect(_filled(tester, 'scanDoc-crop-continue').onPressed, isNull);
    expect(
      find.text('Las esquinas no forman un cuadrilátero válido. Recolócalas.'),
      findsOneWidget,
    );

    await _tapKey(tester, 'scanDoc-crop-reset');
    expect(_filled(tester, 'scanDoc-crop-continue').onPressed, isNotNull);
    expect(
      find.text('Arrastra cada esquina hasta el borde del documento.'),
      findsOneWidget,
    );
  });

  testWidgets('several pages export as a PDF with one page each', (
    tester,
  ) async {
    final host = _Host();
    await _open(tester, host);
    await _takePhotoAndCrop(tester);
    expect(find.text('Página 1 de 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('scanDoc-page-0')), findsNothing);

    await _tapKey(tester, 'scanDoc-add');
    expect(find.byKey(const ValueKey('scanDoc-take-photo')), findsOneWidget);
    await _takePhotoAndCrop(tester);

    expect(find.text('Página 2 de 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('scanDoc-page-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('scanDoc-page-1')), findsOneWidget);
    await _tapKey(tester, 'scanDoc-page-0');
    expect(find.text('Página 1 de 2'), findsOneWidget);

    await _tapKey(tester, 'scanDoc-attach-pdf');
    await tester.pump(const Duration(milliseconds: 400));

    final result = host.result!;
    expect(result.isPdf, isTrue);
    expect(result.files, hasLength(1));
    final file = result.files.single;
    expect(file.name, 'scan-20260102-030405.pdf');
    expect(file.mimeType, 'application/pdf');
    final text = latin1.decode(file.bytes);
    expect(text, startsWith('%PDF-1.4'));
    expect(text, contains('/Count 2'));
  });

  testWidgets('several pages can also be attached as separate images', (
    tester,
  ) async {
    final host = _Host();
    await _open(tester, host);
    await _takePhotoAndCrop(tester);
    await _tapKey(tester, 'scanDoc-add');
    await _takePhotoAndCrop(tester);
    await _tapKey(tester, 'scanDoc-attach-images');
    await tester.pump(const Duration(milliseconds: 400));

    expect(host.result!.files.map((f) => f.name), [
      'scan-20260102-030405-1.png',
      'scan-20260102-030405-2.png',
    ]);
  });

  testWidgets('the page limit stops adding and deleting returns to the start', (
    tester,
  ) async {
    final host = _Host()..maxPages = 1;
    await _open(tester, host);
    await _takePhotoAndCrop(tester);

    expect(find.text('Has llegado al máximo de 1 páginas.'), findsOneWidget);
    final add = tester.widget<TextButton>(
      find.byKey(const ValueKey('scanDoc-add')),
    );
    expect(add.onPressed, isNull);

    await _tapKey(tester, 'scanDoc-delete');
    expect(find.byKey(const ValueKey('scanDoc-take-photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('scanDoc-preview')), findsNothing);
  });

  testWidgets('back from the crop returns to the start, back again leaves', (
    tester,
  ) async {
    final host = _Host();
    await _open(tester, host);
    await _tapKey(tester, 'scanDoc-take-photo');
    expect(find.byKey(const ValueKey('scanDoc-crop')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('scanDoc-crop')), findsNothing);
    expect(find.byKey(const ValueKey('scanDoc-take-photo')), findsOneWidget);
    expect(host.popped, isFalse);

    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(host.popped, isTrue);
    expect(host.result, isNull);
  });

  testWidgets('an image that cannot be decoded shows an error and stays put', (
    tester,
  ) async {
    final host = _Host(decoder: (_) async => null);
    await _open(tester, host);
    await _tapKey(tester, 'scanDoc-take-photo');

    expect(find.text('No se pudo procesar la imagen.'), findsOneWidget);
    expect(find.byKey(const ValueKey('scanDoc-crop')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('scanDoc-take-photo')),
          )
          .onPressed,
      isNotNull,
    );
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('narrow screen at ${scale}x text does not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      await _open(tester, host, scale: scale);
      expect(tester.takeException(), isNull);
      await _tapKey(tester, 'scanDoc-take-photo');
      expect(tester.takeException(), isNull);
      await _tapKey(tester, 'scanDoc-crop-continue');
      expect(find.byKey(const ValueKey('scanDoc-attach-pdf')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an open Fold lays the preview beside the controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host();
    await _open(tester, host);
    await _takePhotoAndCrop(tester);

    final preview = tester.getRect(
      find.byKey(const ValueKey('scanDoc-preview')),
    );
    final attach = tester.getRect(
      find.byKey(const ValueKey('scanDoc-attach-pdf')),
    );
    expect(preview.right, lessThanOrEqualTo(attach.left));
    expect(tester.takeException(), isNull);
  });
}
