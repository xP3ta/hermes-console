// Contact sheets of the launcher widget pictures, for a person to look at.
//
// Not part of the regular suite (it only writes images): it runs when
// LW_EVIDENCE=1 and writes one PNG per sheet under `build/lw-sheets/`.
//   LW_EVIDENCE=1 flutter test test/launcher_widget_evidence_test.dart
//
// Sheets: every state of every subject in the four reference themes; the
// stress sheets (font scale 1.3 and 2.0 x plain, hostile and bare data x the
// three real sizes of every span); the languages; and the tap zones drawn
// over the pictures, to compare with the buttons.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_geometry.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_painter.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_scene.dart';

import 'launcher_widget_fixtures.dart';

const _density = 2.0;
const _maxWidthPx = 2400.0;
const _gapPx = 24.0;
const _labelPx = 26.0;

class _Cell {
  _Cell(this.label, this.request);
  final String label;
  final LwPaintRequest request;
}

class _Row {
  _Row(this.title, this.cells);
  final String title;
  final List<_Cell> cells;
}

LwPaintRequest _request(
  LwSubject subject,
  String mood,
  ui.Size size, {
  int theme = 0,
  double fontScale = 1,
  String locale = 'es',
  LwData data = LwData.plain,
}) => LwPaintRequest(
  subject: subject,
  scene: lwScene(subject, mood, data),
  sizeDp: size,
  palette: lwThemes[theme].palette,
  words: lwWords(locale, use24h: data.use24h),
  fontScale: fontScale,
  textDirection: data == LwData.rtl ? TextDirection.rtl : TextDirection.ltr,
  instanceId: 'home',
);

ui.Size _middle(LwSpan span) => lwSizes[span]![1];

String _main(LwSubject subject) => switch (subject) {
  LwSubject.ahora => 'need',
  LwSubject.chats => 'rows-live',
  LwSubject.cron => 'next',
  LwSubject.tasks => 'counts',
  LwSubject.newChat => 'ready',
};

TextPainter _label(
  String text,
  Color color, {
  double size = 18,
  FontWeight weight = FontWeight.w500,
}) => TextPainter(
  text: TextSpan(
    text: text,
    style: TextStyle(
      fontFamily: 'Inter',
      fontSize: size,
      color: color,
      fontWeight: weight,
    ),
  ),
  textDirection: TextDirection.ltr,
  maxLines: 1,
  ellipsis: '…',
)..layout(maxWidth: _maxWidthPx);

Future<void> _sheet(
  String name,
  List<_Row> rows, {
  int theme = 0,
  bool zones = false,
}) async {
  final palette = lwThemes[theme].palette;
  final ink = palette.dark ? const Color(0xFFDDDDE3) : const Color(0xFF303036);
  // Lay out: rows wrap at the sheet's width.
  final placed = <(Offset, _Cell)>[];
  final titles = <(Offset, String)>[];
  var y = _gapPx;
  var width = 0.0;
  for (final row in rows) {
    titles.add((Offset(_gapPx, y), row.title));
    y += 34;
    var x = _gapPx;
    var lineH = 0.0;
    for (final cell in row.cells) {
      final w = cell.request.sizeDp.width * _density;
      final h = cell.request.sizeDp.height * _density + _labelPx;
      if (x + w > _maxWidthPx && x > _gapPx) {
        x = _gapPx;
        y += lineH + _gapPx;
        lineH = 0;
      }
      placed.add((Offset(x, y), cell));
      x += w + _gapPx;
      if (h > lineH) lineH = h;
      if (x > width) width = x;
    }
    y += lineH + _gapPx * 1.5;
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final bounds = Rect.fromLTWH(0, 0, width, y);
  // A neutral "wallpaper" in the theme's family: the widget brings only its
  // own glass and hairline.
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = ui.Gradient.linear(bounds.topLeft, bounds.bottomRight, [
        Color.lerp(
          palette.page,
          const Color(0xFFFFFFFF),
          palette.dark ? 0.04 : 0.3,
        )!,
        Color.lerp(
          palette.page,
          const Color(0xFF000000),
          palette.dark ? 0.25 : 0.08,
        )!,
      ]),
  );
  for (final (at, title) in titles) {
    _label(title, ink, size: 22, weight: FontWeight.w600).paint(canvas, at);
  }
  for (final (at, cell) in placed) {
    final frame = paintLauncherWidget(cell.request);
    _label(
      '${cell.label} · ${frame.plan}',
      ink.withValues(alpha: 0.75),
      size: 16,
    ).paint(canvas, at);
    canvas.save();
    canvas.translate(at.dx, at.dy + _labelPx);
    canvas.scale(_density);
    canvas.drawPicture(frame.picture);
    if (zones) {
      final card = Offset.zero & frame.sizeDp;
      for (final zone in frame.zones) {
        if (zone.rect == card) continue;
        canvas.drawRect(
          zone.rect.deflate(0.5),
          Paint()
            ..color = const Color(0xCCFF00AA)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
    canvas.restore();
    frame.dispose();
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width.ceil(), y.ceil());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  final file = File('build/lw-sheets/$name.png');
  await file.writeAsBytes(png!.buffer.asUint8List(), flush: true);
}

void main() {
  final enabled = Platform.environment['LW_EVIDENCE'] == '1';
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!enabled) return;
    await lwLoadFonts();
    await Directory('build/lw-sheets').create(recursive: true);
  });

  final skip = enabled ? null : 'evidence sheets: set LW_EVIDENCE=1';

  for (final subject in LwSubject.values) {
    final spans = lwSpansOf[subject]!;
    for (var theme = 0; theme < lwThemes.length; theme++) {
      test('states ${subject.key} ${lwThemes[theme].id}', tags: 'opt-in', skip: skip, () async {
        await _sheet('${subject.key}-states-${lwThemes[theme].id}', [
          for (final mood in lwMoodsOf[subject]!)
            _Row(mood, [
              for (final span in spans)
                _Cell(
                  span.code,
                  _request(subject, mood, _middle(span), theme: theme),
                ),
            ]),
        ], theme: theme);
      });
    }
    for (final fontScale in const [1.3, 2.0]) {
      for (final group in const ['board', 'strip']) {
        final groupSpans = spans
            .where((s) => group == 'strip' ? s.oneRow : !s.oneRow)
            .toList();
        if (groupSpans.isEmpty) continue;
        test('stress ${subject.key} x$fontScale $group', tags: 'opt-in', skip: skip, () async {
          await _sheet('${subject.key}-stress-x$fontScale-$group', [
            for (final data in const [
              LwData.plain,
              LwData.hostile,
              LwData.bare,
            ])
              _Row('${data.id} · ${_main(subject)} · x$fontScale', [
                for (final span in groupSpans)
                  for (final size in lwSizes[span]!)
                    _Cell(
                      '${span.code} ${size.width.round()}x${size.height.round()}',
                      _request(
                        subject,
                        _main(subject),
                        size,
                        fontScale: fontScale,
                        data: data,
                      ),
                    ),
              ]),
          ]);
        });
      }
    }
    test('languages ${subject.key}', tags: 'opt-in', skip: skip, () async {
      await _sheet('${subject.key}-languages', [
        for (final locale in const ['en', 'de', 'ja', 'zh'])
          for (final fontScale in const [1.0, 2.0])
            _Row('$locale · x$fontScale', [
              for (final span in spans)
                _Cell(
                  span.code,
                  _request(
                    subject,
                    _main(subject),
                    _middle(span),
                    locale: locale,
                    fontScale: fontScale,
                  ),
                ),
            ]),
      ]);
    });
    test('zones ${subject.key}', tags: 'opt-in', skip: skip, () async {
      await _sheet('${subject.key}-zones', [
        for (final fontScale in const [1.0, 2.0])
          _Row('${_main(subject)} · x$fontScale · tap zones in magenta', [
            for (final span in spans)
              for (final size in lwSizes[span]!)
                _Cell(
                  '${span.code} ${size.width.round()}x${size.height.round()}',
                  _request(subject, _main(subject), size, fontScale: fontScale),
                ),
          ]),
      ], zones: true);
    });
  }
}
