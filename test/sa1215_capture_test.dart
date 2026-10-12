// sa1215 visual evidence: «Archivos y enlaces» at 412×915, Spanish, dark and
// light. Writes PNGs only when SA1215_SHOTS_DIR is set (otherwise a layout
// smoke test). Fixtures are synthetic.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_content_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart' show loadDesignFonts;

const _shotKey = ValueKey('sa1215-shot');

List<Map<String, dynamic>> _transcript() => [
  {
    'role': 'assistant',
    'content':
        'Listo. He dejado el informe y la presentación:\n'
        'MEDIA:/home/u/proyectos/q3/informe-trimestral.pdf\n'
        'MEDIA:/home/u/proyectos/q3/resumen.pptx',
    'timestamp': 1790841600,
  },
  {
    'role': 'tool',
    'tool_name': 'image_generate',
    'content': jsonEncode({
      'image': 'https://cdn.example.com/gen/portada-q3.png',
    }),
    'timestamp': 1790841000,
  },
  {
    'role': 'assistant',
    'content':
        'Fuentes: [Informe INE](https://www.ine.es/prensa/epa_2026.htm) y '
        'https://github.com/example/dashboards',
    'timestamp': 1790838000,
  },
  {
    'role': 'tool',
    'tool_name': 'terminal',
    'content': jsonEncode({
      'output': 'saved /home/u/proyectos/q3/ventas.csv',
      'exit_code': 0,
    }),
    'timestamp': 1790837000,
  },
  {
    'role': 'user',
    'content':
        'Usa estos datos https://docs.example.org/plantilla\n'
        '@image:/home/u/.hermes/uploads/pizarra.jpg',
    'timestamp': 1790836000,
  },
];

void main() {
  for (final (mode, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('sa1215 contenido $mode', (tester) async {
      await loadDesignFonts();
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            locale: const Locale('es'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: ChatContentScreen(
              transcript: _transcript,
              hasOlder: () => true,
              loadOlder: () async {},
              onOpenFile: (_) async {},
              launchExternal: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('sa1215-item-pizarra.jpg')), findsOne);

      final dir = Platform.environment['SA1215_SHOTS_DIR'];
      if (dir == null || dir.isEmpty) return;
      final boundary =
          tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        Directory(dir).createSync(recursive: true);
        File(
          '$dir/sa1215_contenido_$mode.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
      });
    });
  }
}
