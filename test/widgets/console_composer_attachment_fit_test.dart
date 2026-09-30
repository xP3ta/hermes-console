import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/inter_font.dart';

/// Owner report (Pixel 9 Pro, ~412 dp wide): an image staged in the chat
/// input "does not adapt to the input, it overflows". These tests render the
/// real composer with staged images and check the geometry the user sees:
/// thumbs inside the rounded surface, remove/retry fully visible and
/// tappable, and no layout overflow in the compact (landscape + IME) state.
///
/// Set `ATTACHFIT_CAPTURE_DIR` to also write PNG captures of each scenario.

const _surfaceKey = ValueKey('hermes-composer-visible-surface');
const _stripKey = ValueKey('composer-attachment-preview');
const _captureKey = ValueKey('attachfit-capture');

Future<File> _writePng(Directory dir, String name, int w, int h, Color c) {
  return Future<File>(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = c,
    );
    // A light stripe makes the crop (BoxFit.cover) visible in captures.
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.45, w.toDouble(), h * 0.1),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final image = await recorder.endRecording().toImage(w, h);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    return file;
  });
}

AttachmentDraft _draft(
  File file,
  String id, {
  AttachmentUploadState state = AttachmentUploadState.pending,
}) => AttachmentDraft(
  localId: id,
  type: AttachmentType.image,
  name: file.uri.pathSegments.last,
  mimeType: 'image/png',
  sizeBytes: file.lengthSync(),
  localPath: file.path,
  uploadState: state,
);

Future<void> _pumpComposer(
  WidgetTester tester, {
  required List<AttachmentDraft> attachments,
  required Size size,
  double keyboard = 0,
  ValueChanged<String>? onRemove,
  ValueChanged<String>? onRetry,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  final controller = TextEditingController();
  final focus = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      theme: AppTheme.hermesRedDark,
      home: RepaintBoundary(
        key: _captureKey,
        child: Scaffold(
          // Same shape as the chat: the transcript takes the remaining height
          // and the composer sits at the bottom of the body.
          body: Column(
            children: [
              const Expanded(child: SizedBox.expand()),
              ConsoleComposer(
                controller: controller,
                focusNode: focus,
                onSend: (_, _) {},
                onAttach: (_) {},
                attachments: attachments,
                onRemoveAttachment: onRemove ?? (_) {},
                onRetryAttachment: onRetry ?? (_) {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Let the file images decode for real.
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  final dir = Platform.environment['ATTACHFIT_CAPTURE_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_captureKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// The visible circle of a remove/retry button (the decorated container that
/// wraps the icon), as opposed to its 48 dp invisible hit target.
Rect _buttonVisual(WidgetTester tester, Finder card, IconData icon) {
  final circle = find
      .ancestor(
        of: find.descendant(of: card, matching: find.byIcon(icon)),
        matching: find.byType(Container),
      )
      .first;
  return tester.getRect(circle);
}

Rect _buttonHitTarget(WidgetTester tester, Finder card, IconData icon) {
  final target = find
      .ancestor(
        of: find.descendant(of: card, matching: find.byIcon(icon)),
        matching: find.byType(GestureDetector),
      )
      .first;
  return tester.getRect(target);
}

Rect _thumb(WidgetTester tester, Finder card) => tester.getRect(
  find
      .ancestor(
        of: find.descendant(of: card, matching: find.byType(Image)),
        matching: find.byType(ClipRRect),
      )
      .first,
);

bool _contains(Rect outer, Rect inner, {double slack = 0.5}) =>
    inner.left >= outer.left - slack &&
    inner.top >= outer.top - slack &&
    inner.right <= outer.right + slack &&
    inner.bottom <= outer.bottom + slack;

/// A point of [r] lies outside the rounded rectangle [surface] (radius 28)
/// when it falls in one of its corner squares beyond the arc.
bool _insideRounded(Rect surface, Rect r, {double radius = 28}) {
  final rrect = RRect.fromRectAndRadius(surface, Radius.circular(radius));
  return rrect.contains(r.topLeft + const Offset(0.5, 0.5)) &&
      rrect.contains(r.topRight + const Offset(-0.5, 0.5)) &&
      rrect.contains(r.bottomLeft + const Offset(0.5, -0.5)) &&
      rrect.contains(r.bottomRight + const Offset(-0.5, -0.5));
}

void main() {
  late Directory temp;
  late File portrait;
  late File landscape;
  late File square;

  setUpAll(() async {
    await loadInterFont();
  });

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('attachfit-');
    portrait = await _writePng(temp, 'portrait.png', 60, 120, Colors.teal);
    landscape = await _writePng(temp, 'landscape.png', 160, 80, Colors.indigo);
    square = await _writePng(temp, 'square.png', 90, 90, Colors.deepOrange);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> expectFitsInside(
    WidgetTester tester,
    List<AttachmentDraft> drafts, {
    required String capture,
  }) async {
    await _capture(tester, capture);
    expect(tester.takeException(), isNull, reason: 'no layout overflow');
    final surface = tester.getRect(find.byKey(_surfaceKey));
    final strip = tester.getRect(find.byKey(_stripKey));
    // The horizontal scroll view clips its content to its own box.
    final viewport = tester.getRect(
      find.descendant(
        of: find.byKey(_stripKey),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(_contains(surface, strip), isTrue, reason: '$strip in $surface');
    for (final draft in drafts) {
      final card = find.byKey(ValueKey('attachment-card-${draft.localId}'));
      expect(card, findsOneWidget);
      final visibleArea = viewport.intersect(surface);
      final thumb = _thumb(tester, card);
      // Only the thumbs that are on screen (the strip may scroll).
      if (thumb.left >= viewport.right) continue;
      final clippedThumb = thumb.intersect(viewport);
      expect(
        thumb.height,
        lessThanOrEqualTo(88),
        reason: 'the composer thumb is compact, not the 120 dp chat card',
      );
      expect(thumb.height, greaterThanOrEqualTo(64));
      expect(
        clippedThumb.height,
        closeTo(thumb.height, 0.5),
        reason: 'thumb is not cut vertically by the strip: $thumb/$viewport',
      );
      if (thumb.right <= viewport.right) {
        expect(
          _insideRounded(surface, thumb),
          isTrue,
          reason: 'thumb $thumb pokes out of the rounded input $surface',
        );
      }
      final remove = _buttonVisual(tester, card, Icons.close);
      if (remove.right <= viewport.right) {
        expect(
          _contains(visibleArea, remove),
          isTrue,
          reason: 'remove button $remove is clipped by $visibleArea',
        );
        expect(_insideRounded(surface, remove), isTrue, reason: '$remove');
        final hit = _buttonHitTarget(tester, card, Icons.close);
        expect(hit.width, greaterThanOrEqualTo(48));
        expect(hit.height, greaterThanOrEqualTo(48));
        expect(
          _contains(viewport, hit),
          isTrue,
          reason: 'the 48 dp remove target $hit is cut by the strip $viewport',
        );
      }
    }
  }

  testWidgets('one portrait image fits inside the input at 412 dp', (
    tester,
  ) async {
    final drafts = [_draft(portrait, 'p1')];
    await _pumpComposer(
      tester,
      attachments: drafts,
      size: const Size(412, 915),
    );
    await expectFitsInside(tester, drafts, capture: 'one_portrait_412');
  });

  testWidgets('three images (portrait/landscape/error) fit at 412 dp', (
    tester,
  ) async {
    final drafts = [
      _draft(portrait, 'p1'),
      _draft(landscape, 'l1'),
      _draft(square, 's1', state: AttachmentUploadState.error),
    ];
    await _pumpComposer(
      tester,
      attachments: drafts,
      size: const Size(412, 915),
    );
    await expectFitsInside(tester, drafts, capture: 'three_mixed_412');
    // The retry button of the failed upload is fully visible too.
    final failed = find.byKey(const ValueKey('attachment-card-s1'));
    final retry = _buttonVisual(tester, failed, Icons.refresh_rounded);
    final viewport = tester.getRect(
      find.descendant(
        of: find.byKey(_stripKey),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    if (retry.right <= viewport.right) {
      expect(_contains(viewport, retry), isTrue, reason: '$retry/$viewport');
    }
  });

  testWidgets('compact IME (landscape + keyboard) has no overflow', (
    tester,
  ) async {
    final drafts = [
      _draft(portrait, 'p1'),
      _draft(landscape, 'l1'),
      _draft(square, 's1'),
    ];
    await _pumpComposer(
      tester,
      attachments: drafts,
      size: const Size(915, 412),
      keyboard: 190,
    );
    await expectFitsInside(tester, drafts, capture: 'three_compact_ime');
  });

  testWidgets('remove and retry respond at their visible centre', (
    tester,
  ) async {
    final removed = <String>[];
    final retried = <String>[];
    final drafts = [
      _draft(portrait, 'p1'),
      _draft(square, 's1', state: AttachmentUploadState.error),
    ];
    await _pumpComposer(
      tester,
      attachments: drafts,
      size: const Size(412, 915),
      onRemove: removed.add,
      onRetry: retried.add,
    );
    final first = find.byKey(const ValueKey('attachment-card-p1'));
    final failed = find.byKey(const ValueKey('attachment-card-s1'));
    await tester.tapAt(_buttonVisual(tester, first, Icons.close).center);
    await tester.tapAt(_buttonVisual(tester, failed, Icons.close).center);
    await tester.tapAt(
      _buttonVisual(tester, failed, Icons.refresh_rounded).center,
    );
    await tester.pump();
    expect(removed, ['p1', 's1']);
    expect(retried, ['s1']);
  });

  testWidgets('chat bubble cards keep the large 120 dp thumb', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: Center(
            child: AttachmentCard(
              key: const ValueKey('bubble-card'),
              name: 'portrait.png',
              mimeType: 'image/png',
              sizeLabel: '1 KB',
              thumbnailFile: portrait,
            ),
          ),
        ),
      ),
    );
    expect(
      _thumb(tester, find.byKey(const ValueKey('bubble-card'))).size,
      const Size(120, 120),
    );
  });
}
