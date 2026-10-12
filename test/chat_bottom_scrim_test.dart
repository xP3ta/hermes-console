// The foot of the chat: a reply that scrolls behind the composer and the
// status pill under it dissolves into the page behind them, so its text
// never reads through a piece or beside the labels of the status row
// (owner, QA 9529). Nothing is painted above the composer (owner, QA 9494).
//
// The floor is the one of the floating header: text passing behind stays
// under 1.6:1 against the page while the labels on the pieces keep 7:1 or
// more. No blur.
//
// PNGs are written only with `--dart-define=GLASS_SHOTS=<dir>`.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesComposerSurface;

import 'support/design_shots.dart';

const _dir = String.fromEnvironment('GLASS_SHOTS');
const _shotKey = ValueKey('chat-foot-shot');
const _size = Size(390, 844);

/// Height of the chat's bottom pieces in this page: the composer, the gap,
/// the status pill and the room under it.
const _bars = 4.0 + 48 + 6 + 30 + 10;

const _reply = [
  'España hoy, lunes 12 de octubre',
  'Resumen actualizado a las 9:04 en Canarias y a las 10:04 en la '
      'Península. Distingo las novedades de hoy de las noticias recientes '
      'que siguen en la agenda.',
  'El Consejo de Ministros se reúne mañana; hoy no hay sesión por el festivo '
      'nacional. El desfile ha terminado sin incidentes y con menos público '
      'que el año pasado por la lluvia.',
  'En economía, el dato de inflación se publica el jueves. Los mercados '
      'abren el martes con la vista puesta en los tipos y en el precio de la '
      'energía, que ha subido durante el fin de semana.',
  'En deportes, la selección juega esta noche el partido de clasificación. '
      'La convocatoria no cambia respecto a la del sábado y se espera lleno.',
  'El tiempo: lluvias en el norte y en el Mediterráneo, con avisos amarillos '
      'en seis provincias. Las temperaturas bajan entre dos y cuatro grados.',
  'Tráfico: retenciones de regreso en las entradas a las grandes ciudades a '
      'partir de las cinco de la tarde, sobre todo en la A-3 y la A-4.',
  'Cultura: se inaugura la exposición de otoño y siguen las fiestas locales '
      'en varias capitales, con conciertos gratuitos hasta la medianoche.',
];

/// A page built like the chat: the transcript runs under the bottom pieces,
/// the scrim sits over it and under them, as `chat_screen.dart` mounts it.
///
/// With [ink] false the reply is written in the page's own colour: the same
/// page with nothing to read, to measure what the reply adds to each pixel.
Widget _page(
  String themeId, {
  bool scrim = true,
  bool ink = true,
  ScrollController? scroll,
}) {
  final theme = AppTheme.fromId(themeId);
  final colors = theme.hermes;
  return RepaintBoundary(
    key: _shotKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            ListView(
              key: const ValueKey('transcript'),
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(14, 60, 14, 12 + 22 + _bars),
              children: [
                // Twice over: long enough to be passing behind the foot.
                for (final (i, text) in [..._reply, ..._reply].indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      text,
                      key: ValueKey('reply-$i'),
                      style: TextStyle(
                        fontSize: i == 0 ? 18 : 16,
                        height: 1.45,
                        fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w400,
                        color: ink ? colors.textPrimary : colors.background,
                      ),
                    ),
                  ),
              ],
            ),
            if (scrim)
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _bars,
                child: HermesBottomScrim(key: ValueKey('chat-foot-scrim')),
              ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 0,
              height: _bars,
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  HermesComposerSurface(
                    key: const ValueKey('composer'),
                    unfocusedHorizontalInset: 12,
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        children: [
                          const SizedBox(width: 14),
                          Icon(Icons.add, color: colors.textPrimary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Pregunta a Hermes…',
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          ),
                          Icon(Icons.mic, color: colors.textPrimary),
                          const SizedBox(width: 14),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // The status pill's own fill and hairline
                  // (`chat_status_pill.dart`).
                  Container(
                    key: const ValueKey('status-pill'),
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: colors.surfaceVariant.withValues(
                        alpha: ChatStatusPill.fillOpacity,
                      ),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: colors.divider.withValues(alpha: 0.7),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '3 %   GPT-6.1-sol   YOLO',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<ui.Image> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  late ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage();
  });
  return image;
}

Future<ByteData> _pixels(WidgetTester tester, ui.Image image) async {
  late ByteData data;
  await tester.runAsync(() async {
    data = (await image.toByteData())!;
  });
  return data;
}

Color _at(ByteData data, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return Color.fromARGB(
    255,
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

/// The most the reply changes any pixel of [area]: the strongest contrast
/// between the page with the reply ([ink]) and the same page without it
/// ([blank]). The pieces and their labels are in both, so only what shows of
/// the reply counts — beside the pieces, between them and through them.
double _strongest(ByteData ink, ByteData blank, int width, Rect area) {
  var strongest = 1.0;
  for (var y = area.top.ceil(); y < area.bottom.floor(); y++) {
    for (var x = area.left.ceil(); x < area.right.floor(); x++) {
      final ratio = ThemeContrast.ratio(
        _at(ink, width, x, y),
        _at(blank, width, x, y),
      );
      if (ratio > strongest) strongest = ratio;
    }
  }
  return strongest;
}

Future<void> _pump(WidgetTester tester, Widget page) async {
  await loadDesignFonts();
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(page);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('in every theme, text behind the foot stays under 1.6:1 and the '
      'labels on the pieces keep 7:1', () {
    expect(AppTheme.presets.length, greaterThanOrEqualTo(40));
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final page = colors.background;
      Color under(Color scrimmed) => ThemeContrast.composite(
        page.withValues(alpha: HermesBottomScrim.strength),
        scrimmed,
      );
      // Beside and between the pieces: the reply's own ink, scrimmed.
      for (final ink in [colors.textPrimary, colors.accent]) {
        expect(
          ThemeContrast.ratio(under(ink), under(page)),
          lessThanOrEqualTo(1.6),
          reason: '${preset.id}: ghost text beside the pieces',
        );
      }
      // Behind the status pill and the composer: scrimmed, then their fill.
      for (final alpha in const [
        ChatStatusPill.fillOpacity,
        HermesComposerSurface.fillOpacity,
      ]) {
        final fill = colors.surfaceVariant.withValues(alpha: alpha);
        final behindText = ThemeContrast.composite(
          fill,
          under(colors.textPrimary),
        );
        final behindPage = ThemeContrast.composite(fill, under(page));
        expect(
          ThemeContrast.ratio(behindText, behindPage),
          lessThanOrEqualTo(1.1),
          reason: '${preset.id}: ghost text behind a piece',
        );
        // Text passing behind costs the label next to nothing.
        final clean = ThemeContrast.ratio(colors.textPrimary, behindPage);
        expect(
          ThemeContrast.ratio(colors.textPrimary, behindText),
          greaterThanOrEqualTo(clean * 0.95),
          reason: '${preset.id}: the label over text passing behind',
        );
        if (preset.id == 'classic-dark' || preset.id == 'classic') {
          expect(clean, greaterThanOrEqualTo(7), reason: preset.id);
        }
      }
    }
  });

  for (final theme in const ['classic-dark', 'classic']) {
    testWidgets('$theme: rendered, nothing behind the foot reads beside or '
        'between the pieces', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await _pump(tester, _page(theme, scroll: scroll));
      // Mid-reply: text is passing behind the composer and the pill.
      scroll.jumpTo(140);
      await tester.pump();
      // The status row and what is under it; the composer; the pill.
      final foot = Rect.fromLTRB(0, _size.height - 46, 390, _size.height);
      // Inside the capsule, clear of its round ends.
      final composer = tester
          .getRect(
            find.byKey(const ValueKey('hermes-composer-visible-surface')),
          )
          .deflate(12);
      final pill = tester.getRect(find.byKey(const ValueKey('status-pill')));

      Future<ByteData> render({required bool scrim, required bool ink}) async {
        await _pump(
          tester,
          _page(theme, scrim: scrim, ink: ink, scroll: scroll),
        );
        final image = await _capture(tester);
        final data = await _pixels(tester, image);
        image.dispose();
        return data;
      }

      final after = await render(scrim: true, ink: true);
      if (_dir.isNotEmpty) await _write(tester, 'chat_pie_${theme}_despues');
      final afterBlank = await render(scrim: true, ink: false);
      expect(
        _strongest(after, afterBlank, 390, foot),
        lessThanOrEqualTo(1.6),
        reason: 'beside the status pill and under it',
      );
      expect(
        _strongest(after, afterBlank, 390, pill),
        lessThanOrEqualTo(1.05),
        reason: 'through the status pill',
      );
      expect(
        _strongest(after, afterBlank, 390, composer),
        lessThanOrEqualTo(1.1),
        reason: 'through the composer',
      );

      // The same page without it is what the owner photographed.
      final before = await render(scrim: false, ink: true);
      if (_dir.isNotEmpty) await _write(tester, 'chat_pie_${theme}_antes');
      final beforeBlank = await render(scrim: false, ink: false);
      expect(
        _strongest(before, beforeBlank, 390, foot),
        greaterThan(4),
        reason: 'the page without the scrim',
      );
    });
  }

  testWidgets('nothing is painted above the composer: at rest the reply is '
      'as it was', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _pump(tester, _page('classic-dark', scroll: scroll));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    final scrim = tester.getRect(find.byKey(const ValueKey('chat-foot-scrim')));
    expect(scrim.top, _size.height - _bars);
    expect(
      scrim.top,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('composer'))).top - 4,
      ),
    );
    final last = tester.getRect(
      find.byKey(ValueKey('reply-${_reply.length * 2 - 1}')),
    );
    expect(last.bottom, lessThan(scrim.top));

    // Pixel for pixel, everything above the bottom pieces is the same page
    // with the scrim and without it.
    final above = Rect.fromLTRB(0, 0, 390, _size.height - _bars);
    final a = await _capture(tester);
    final withScrim = await _pixels(tester, a);
    a.dispose();
    await _pump(tester, _page('classic-dark', scrim: false, scroll: scroll));
    final b = await _capture(tester);
    final bare = await _pixels(tester, b);
    b.dispose();
    expect(_strongest(withScrim, bare, 390, above), 1.0);
  });

  testWidgets('it is static, takes no touch and blurs nothing', (tester) async {
    await _pump(tester, _page('classic-dark'));
    final scrim = find.byKey(const ValueKey('chat-foot-scrim'));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(
      find.descendant(of: scrim, matching: find.byType(RepaintBoundary)),
      findsOneWidget,
    );
    // A touch in the foot, beside the pill, still reaches the transcript.
    final beside = Offset(24, _size.height - 20);
    final hit = tester.hitTestOnBinding(beside);
    final list = tester.renderObject(find.byKey(const ValueKey('transcript')));
    expect(hit.path.any((entry) => entry.target == list), isTrue);
  });

  test('the chat mounts it behind its bottom pieces, under the notch', () {
    final source = File('lib/core/screens/chat_screen.dart').readAsStringSync();
    final scrim = source.indexOf('HermesBottomScrim(');
    expect(scrim, greaterThan(0));
    final mount = source.substring(scrim - 900, scrim);
    expect(mount, contains('valueListenable: _bottomBarsExtent'));
    expect(mount, contains('bottom: 0'));
    // The area of the bottom pieces and not a pixel above it.
    expect(mount, contains('height: bars,'));
    // Painted before the notch: the tab on the composer's edge stays clean.
    expect(scrim, lessThan(source.indexOf('_buildNotch(str)')));
  });
}

Future<void> _write(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(_dir).createSync(recursive: true);
    File('$_dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}
