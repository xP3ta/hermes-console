import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/inter_font.dart';

/// Owner QA (room composer with an attached image): the staged image sat
/// in a card above the text, the text looked indented and the bubble was
/// tall. The tray is now a row of small rounded tiles INSIDE the input;
/// the text keeps its position and the composer grows only by the tray.
///
/// QA 9493: tiles starting at the text (after the `+`) left a big empty
/// gap on the left. They now sit flush at the composer's own start inset,
/// the column of the `+` glyph (the text start when there is no `+`), with
/// the × inside each tile's corner and one even gap between tiles.
const _trayKey = ValueKey('composer-attachment-preview');

Future<File> _png(Directory dir, String name) async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 90, 60), Paint()..color = Colors.teal);
  final image = await recorder.endRecording().toImage(90, 60);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return File('${dir.path}/$name')
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

AttachmentDraft _image(File file) => AttachmentDraft(
  localId: 'img',
  type: AttachmentType.image,
  name: 'captura.png',
  mimeType: 'image/png',
  sizeBytes: file.lengthSync(),
  localPath: file.path,
);

const _pdf = AttachmentDraft(
  localId: 'pdf',
  type: AttachmentType.document,
  name: 'informe-de-qa-largo.pdf',
  mimeType: 'application/pdf',
  sizeBytes: 120000,
  localPath: '',
);

const _video = AttachmentDraft(
  localId: 'vid',
  type: AttachmentType.document,
  name: 'grabacion.mp4',
  mimeType: 'video/mp4',
  sizeBytes: 4200000,
  localPath: '',
);

Future<void> _pump(
  WidgetTester tester, {
  required List<AttachmentDraft> attachments,
  ValueChanged<String>? onRemove,
  double textScale = 1,
  bool withAttach = true,
  Size size = const Size(412, 915),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final controller = TextEditingController(text: 'hello');
  final focus = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      theme: AppTheme.hermesRedDark,
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox.expand()),
            ConsoleComposer(
              key: const ValueKey('composer'),
              controller: controller,
              focusNode: focus,
              onSend: (_, _) {},
              onAttach: withAttach ? (_) {} : null,
              attachments: attachments,
              onRemoveAttachment: onRemove ?? (_) {},
            ),
          ],
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Rect _text(WidgetTester tester) => tester.getRect(find.byType(EditableText));
Rect _tile(WidgetTester tester, String id) =>
    tester.getRect(find.byKey(ValueKey('attachment-card-$id')));
double _composerHeight(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('composer'))).height;

/// The visible × circle of a tile (not its invisible 48 dp target).
Rect _closeVisual(WidgetTester tester, String id) => tester.getRect(
  find
      .ancestor(
        of: find.descendant(
          of: find.byKey(ValueKey('attachment-card-$id')),
          matching: find.byIcon(Icons.close),
        ),
        matching: find.byType(Container),
      )
      .first,
);

void main() {
  late Directory temp;
  late File image;

  setUpAll(loadInterFont);
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tray-');
    image = await _png(temp, 'captura.png');
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Where the composer's content starts: the `+` glyph when the attach
  /// button shows, else the text.
  double contentStart(WidgetTester tester, {required bool withAttach}) =>
      withAttach
      ? tester
            .getRect(
              find.descendant(
                of: find.byKey(const ValueKey('composer-add')),
                matching: find.byIcon(Icons.add_rounded),
              ),
            )
            .left
      : _text(tester).left;

  for (final withAttach in [true, false]) {
    testWidgets('QA 9493: tray sits flush at the composer start inset, not '
        'after the + (attach button: $withAttach)', (tester) async {
      await _pump(
        tester,
        attachments: [_image(image), _pdf],
        withAttach: withAttach,
      );
      final start = contentStart(tester, withAttach: withAttach);
      final first = _tile(tester, 'img');
      expect(
        first.left,
        closeTo(start, 1),
        reason: 'first tile in the column of the composer content start',
      );
      if (withAttach) {
        expect(
          first.left,
          lessThan(_text(tester).left - 24),
          reason: 'no gap the width of the + before the first tile',
        );
      }
      final second = _tile(tester, 'pdf');
      expect(second.left - first.right, closeTo(8, 0.5), reason: 'even gap');
      expect(tester.takeException(), isNull);
    });
  }

  for (final withAttach in [true, false]) {
    testWidgets('text does not move and the composer grows only by the tray '
        '(attach button: $withAttach)', (tester) async {
      await _pump(tester, attachments: const [], withAttach: withAttach);
      final textBefore = _text(tester);
      final heightBefore = _composerHeight(tester);

      await _pump(
        tester,
        attachments: [_image(image), _pdf, _video],
        withAttach: withAttach,
      );
      final textAfter = _text(tester);
      expect(textAfter.left, closeTo(textBefore.left, 2));
      final tray = tester.getRect(find.byKey(_trayKey));
      expect(
        _composerHeight(tester) - heightBefore,
        closeTo(tray.height, 1),
        reason: 'the composer grows only by the tray',
      );
      expect(tray.height, lessThanOrEqualTo(84));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('every tile is a 56–64 dp rounded square', (tester) async {
    await _pump(tester, attachments: [_image(image), _pdf, _video]);
    for (final id in ['img', 'pdf', 'vid']) {
      final r = _tile(tester, id);
      expect(r.width, inInclusiveRange(56, 64), reason: id);
      expect(r.height, inInclusiveRange(56, 64), reason: id);
      expect(r.width, r.height, reason: id);
    }
    // Files and videos show an icon and a short name inside the tile.
    for (final (id, icon) in [
      ('pdf', Icons.description_outlined),
      ('vid', Icons.movie_outlined),
    ]) {
      final tile = find.byKey(ValueKey('attachment-card-$id'));
      expect(
        find.descendant(of: tile, matching: find.byIcon(icon)),
        findsOneWidget,
        reason: id,
      );
      final name = find.descendant(
        of: tile,
        matching: find.byKey(const ValueKey('attachment-tile-name')),
      );
      expect(name, findsOneWidget);
      final nameRect = tester.getRect(name);
      final tileRect = _tile(tester, id);
      expect(nameRect.left, greaterThanOrEqualTo(tileRect.left));
      expect(nameRect.right, lessThanOrEqualTo(tileRect.right + 0.5));
      expect(nameRect.bottom, lessThanOrEqualTo(tileRect.bottom + 0.5));
    }
  });

  testWidgets('small × inside each tile corner removes it', (tester) async {
    final removed = <String>[];
    await _pump(
      tester,
      attachments: [_image(image), _pdf],
      onRemove: removed.add,
    );
    for (final id in ['img', 'pdf']) {
      final close = _closeVisual(tester, id);
      final tile = _tile(tester, id);
      expect(close.width, lessThanOrEqualTo(22), reason: 'small badge');
      // QA 9493: the whole × badge sits inside the tile's corner, never
      // hanging off its edge.
      expect(close.left, greaterThanOrEqualTo(tile.left), reason: id);
      expect(close.top, greaterThanOrEqualTo(tile.top + 2), reason: id);
      expect(close.right, lessThanOrEqualTo(tile.right - 2), reason: id);
      expect(close.center.dx, greaterThan(tile.center.dx), reason: id);
      expect(close.center.dy, lessThan(tile.center.dy), reason: id);
      await tester.tapAt(close.center);
      await tester.pump();
    }
    expect(removed, ['img', 'pdf']);
    // The tile's centre stays free for the preview: it never removes.
    await tester.tapAt(_tile(tester, 'pdf').center);
    await tester.pump();
    expect(removed, ['img', 'pdf']);
    final target = find
        .ancestor(
          of: find.descendant(
            of: find.byKey(const ValueKey('attachment-card-pdf')),
            matching: find.byIcon(Icons.close),
          ),
          matching: find.byType(GestureDetector),
        )
        .first;
    expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
  });

  testWidgets('tiles are labelled for accessibility', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, attachments: [_image(image), _pdf]);
    expect(find.bySemanticsLabel(RegExp('captura.png')), findsWidgets);
    expect(
      find.bySemanticsLabel(RegExp('informe-de-qa-largo.pdf')),
      findsWidgets,
    );
    handle.dispose();
  });

  testWidgets('text scale 2.0: no overflow, tiles keep their size', (
    tester,
  ) async {
    await _pump(
      tester,
      attachments: [_image(image), _pdf, _video],
      textScale: 2,
      size: const Size(360, 800),
    );
    expect(tester.takeException(), isNull);
    for (final id in ['img', 'pdf', 'vid']) {
      expect(_tile(tester, id).height, inInclusiveRange(56, 64));
    }
    expect(
      _tile(tester, 'img').left,
      closeTo(contentStart(tester, withAttach: true), 1),
    );
  });
}
