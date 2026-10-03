import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/generated_image_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// PNG 1x1 válido (mínimo) para el estado "ready" sin assets externos.
final Uint8List _tinyPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // firma
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, // IDAT
  0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, // IEND
  0x42, 0x60, 0x82,
]);

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  home: Scaffold(body: child),
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('genimg_card');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  testWidgets('estado ready renderiza la miniatura desde archivo local', (
    tester,
  ) async {
    final f = File('${tmp.path}/a.png')..writeAsBytesSync(_tinyPng);
    await tester.pumpWidget(
      _wrap(GeneratedImageCard(status: GeneratedImageStatus.ready, file: f)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    // Accesible: la miniatura lleva label semántico.
    expect(
      find.bySemanticsLabel('Imagen generada por el agente'),
      findsOneWidget,
    );
    final thumbnail = find.byKey(const ValueKey('generated-image-thumbnail'));
    expect(thumbnail, findsOneWidget);
    expect(tester.getSize(thumbnail).width, lessThanOrEqualTo(232));
    expect(tester.getSize(thumbnail).height, lessThanOrEqualTo(232));
    expect(
      find.byKey(const ValueKey('generated-image-expand')),
      findsOneWidget,
    );
  });

  testWidgets('tocar la miniatura abre el visor sin añadir otro CTA', (
    tester,
  ) async {
    final f = File('${tmp.path}/viewer.png')..writeAsBytesSync(_tinyPng);
    await tester.pumpWidget(
      _wrap(GeneratedImageCard(status: GeneratedImageStatus.ready, file: f)),
    );
    await tester.pumpAndSettle();

    final imageTap = find.ancestor(
      of: find.byKey(const ValueKey('generated-image-thumbnail')),
      matching: find.byType(GestureDetector),
    );
    tester.widget<GestureDetector>(imageTap).onTap!();
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('estado error muestra Reintentar y dispara el callback', (
    tester,
  ) async {
    var retried = 0;
    await tester.pumpWidget(
      _wrap(
        GeneratedImageCard(
          status: GeneratedImageStatus.error,
          onRetry: () => retried++,
        ),
      ),
    );
    expect(find.text('No se pudo descargar la imagen'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    expect(retried, 1);
  });

  testWidgets('estado descargando muestra spinner y texto', (tester) async {
    await tester.pumpWidget(
      _wrap(const GeneratedImageCard(status: GeneratedImageStatus.downloading)),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Descargando imagen…'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('generated-image-status')))
          .width,
      lessThanOrEqualTo(320),
    );
  });

  testWidgets('estado gone: sin Reintentar (no hay reintento útil)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const GeneratedImageCard(status: GeneratedImageStatus.gone)),
    );
    expect(
      find.text('La imagen ya no está disponible en el servidor'),
      findsOneWidget,
    );
    expect(find.text('Reintentar'), findsNothing);
  });

  testWidgets('US2: variante pista (bridge viejo) muestra el hint localizado '
      'y no intenta red', (tester) async {
    await tester.pumpWidget(
      _wrap(const GeneratedImageCard(status: GeneratedImageStatus.unsupported)),
    );
    expect(find.textContaining('Actualiza el Mobile Bridge'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('archivo corrupto no crashea: cae al estado de error visual', (
    tester,
  ) async {
    final f = File('${tmp.path}/bad.png')
      ..writeAsBytesSync(Uint8List.fromList([1, 2, 3]));
    // El decode de Image.file es I/O real: bajo el fake-async del tester el
    // códec nunca llega a fallar. runAsync deja correr la I/O de verdad y se
    // espera al propio fallo del códec, no a una ventana de reloj fija (bajo
    // carga 200 ms no bastaban). Se resuelve el mismo provider que usa la
    // miniatura: comparte su completer en la caché, que avisa primero al
    // listener del widget, así que al llegar el error el errorBuilder ya está
    // programado. Luego se consume el reporte interno de la excepción del
    // códec (la garantía del test es la UI, no el reporte).
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _wrap(GeneratedImageCard(status: GeneratedImageStatus.ready, file: f)),
      );
      final image = tester.widget<Image>(find.byType(Image));
      final failed = Completer<void>();
      final stream = image.image.resolve(
        createLocalImageConfiguration(tester.element(find.byType(Image))),
      );
      final listener = ImageStreamListener(
        (_, _) => failed.completeError(StateError('decoded a corrupt file')),
        onError: (_, _) => failed.complete(),
      );
      stream.addListener(listener);
      try {
        await failed.future;
      } finally {
        stream.removeListener(listener);
      }
    });
    await tester.pump();
    tester.takeException();
    expect(find.text('No se pudo descargar la imagen'), findsOneWidget);
  });
}
