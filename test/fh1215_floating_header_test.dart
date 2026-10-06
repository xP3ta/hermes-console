import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/generated_image_card.dart';
import 'package:hermes_android/core/widgets/stacked_image_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// fh1215: bot chats and rooms get a floating header (no app bar band): a
// round back button, a round overflow button and, in the centre, a small
// name pill with the face(s) sitting on its top edge. The live status rides
// inside the pill only while working or waiting. Several images of one
// reply become a stack of cards.

Widget _app(
  Widget child, {
  double textScale = 1,
  ThemeData? theme,
  Locale locale = const Locale('es'),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: child,
);

Widget _face(double size) => SizedBox(
  key: const ValueKey('test-face'),
  width: size,
  height: size,
  child: const ColoredBox(color: Colors.orange),
);

Widget _screen({
  String text = 'CEO of RPL.gg',
  FloatingHeaderTone tone = FloatingHeaderTone.idle,
  VoidCallback? onBack,
  VoidCallback? onPillTap,
  VoidCallback? onLongPress,
  bool newChat = true,
  String label = 'CEO of RPL.gg',
}) => Scaffold(
  body: Stack(
    children: [
      const Positioned.fill(child: ColoredBox(color: Colors.blue)),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: FloatingChatHeader(
          faces: _face(FloatingChatHeader.faceSize),
          leading: onBack == null
              ? null
              : FloatingHeaderButton(
                  key: const ValueKey('floating-header-back'),
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  onPressed: onBack,
                ),
          trailing: newChat
              ? FloatingHeaderButton(
                  key: const ValueKey('test-new'),
                  icon: Icons.add_rounded,
                  tooltip: 'New',
                  onPressed: () {},
                )
              : null,
          pill: FloatingHeaderPill(
            key: const ValueKey('test-pill'),
            text: text,
            tone: tone,
            semanticsLabel: label,
            onTap: onPillTap,
            onLongPress: onLongPress,
          ),
        ),
      ),
    ],
  ),
);

Finder get _pill => find.byKey(const ValueKey('test-pill'));
Finder get _text => find.byKey(const ValueKey('floating-header-text'));

void _phone(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 24 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 24 * 3);
  addTearDown(tester.view.reset);
}

Future<File> _png(WidgetTester tester, Directory dir, String name) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 40, 30),
      Paint()..color = const Color(0xff2255aa),
    );
    final image = await recorder.endRecording().toImage(40, 30);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  final f = File('${dir.path}/$name');
  f.writeAsBytesSync(bytes!);
  return f;
}

void main() {
  group('floating header', () {
    testWidgets('no app bar band: the face sits on a centred pill, round '
        'buttons float at the sides', (tester) async {
      _phone(tester);
      var back = 0;
      await tester.pumpWidget(_app(_screen(onBack: () => back++)));
      expect(find.byType(AppBar), findsNothing);
      final face = tester.getRect(find.byKey(const ValueKey('test-face')));
      final pill = tester.getRect(_pill);
      expect((pill.center.dx - 195).abs(), lessThan(1), reason: 'centred');
      expect((face.center.dx - pill.center.dx).abs(), lessThan(1));
      // The face SITS on the pill: above it, overlapping its top edge.
      expect(face.top, lessThan(pill.top));
      expect(face.bottom, greaterThan(pill.top + 4));
      expect(face.bottom, lessThan(pill.center.dy));
      expect(face.height, FloatingChatHeader.faceSize);
      expect(face.top, greaterThanOrEqualTo(24), reason: 'below status bar');
      for (final key in ['floating-header-back', 'test-new']) {
        final circle = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Material),
        );
        expect(tester.getSize(circle), const Size.square(44));
        final material = tester.widget<Material>(circle);
        expect(material.shape, isA<CircleBorder>());
        expect(material.color!.a, greaterThan(0.5), reason: 'surface tint');
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          (tester.getCenter(circle).dy - pill.center.dy).abs(),
          lessThan(4),
          reason: 'buttons line up with the pill',
        );
      }
      expect(
        tester.getCenter(find.byKey(const ValueKey('floating-header-back'))).dx,
        lessThan(60),
      );
      expect(
        tester.getCenter(find.byKey(const ValueKey('test-new'))).dx,
        greaterThan(390 - 60),
      );
      await tester.tap(find.byKey(const ValueKey('floating-header-back')));
      expect(back, 1);
      expect(
        find.descendant(of: _pill, matching: find.text('CEO of RPL.gg')),
        findsOneWidget,
      );
    });

    testWidgets('idle: name and chevron; working: green dot; needs you: '
        'amber; offline: red', (tester) async {
      _phone(tester);
      final colors = AppTheme.hermesRedDark.hermes;
      await tester.pumpWidget(_app(_screen()));
      expect(
        find.descendant(
          of: _pill,
          matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('floating-header-dot-idle')),
        findsNothing,
      );
      expect(tester.widget<Text>(_text).style!.color, colors.textPrimary);
      for (final (tone, ink) in [
        (FloatingHeaderTone.working, colors.textPrimary),
        (FloatingHeaderTone.waiting, colors.warning),
        (FloatingHeaderTone.offline, colors.error),
      ]) {
        await tester.pumpWidget(_app(_screen(text: 'x', tone: tone)));
        expect(tester.widget<Text>(_text).style!.color, ink, reason: '$tone');
        final dot = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(ValueKey('floating-header-dot-${tone.name}')),
            matching: find.byType(DecoratedBox),
          ),
        );
        expect(
          (dot.decoration as BoxDecoration).color,
          tone == FloatingHeaderTone.working ? colors.success : ink,
        );
      }
    });

    testWidgets('its extent never depends on the pill', (tester) async {
      _phone(tester);
      final heights = <double>{};
      for (final tone in FloatingHeaderTone.values) {
        await tester.pumpWidget(_app(_screen(text: 'x', tone: tone)));
        heights.add(
          tester.getSize(find.byKey(const ValueKey('floating-header'))).height,
        );
        expect(
          tester.getRect(_pill).bottom,
          lessThanOrEqualTo(FloatingChatHeader.insetFor(tester.element(_pill))),
        );
      }
      expect(heights, hasLength(1));
    });

    testWidgets('a gradient scrim fades the content under the top, no blur', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen()));
      final scrim = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('floating-header-scrim')),
      );
      final gradient =
          (scrim.decoration as BoxDecoration).gradient! as LinearGradient;
      final bg = AppTheme.hermesRedDark.hermes.background;
      expect(gradient.colors.first.a, closeTo(0.85, 0.01));
      expect(gradient.colors.last.a, 0);
      expect(gradient.colors.first.r, closeTo(bg.r, 0.01));
      final height = tester
          .getSize(find.byKey(const ValueKey('floating-header-scrim')))
          .height;
      expect(height, inInclusiveRange(88, 140));
      expect(find.byType(BackdropFilter), findsNothing);
      // The scrim never takes a touch: a tap under it reaches the content.
      final hits = tester
          .hitTestOnBinding(Offset(195, height - 4))
          .path
          .map((e) => e.target);
      expect(
        hits.whereType<RenderDecoratedBox>().any((r) {
          final d = r.decoration;
          return d is BoxDecoration && d.gradient != null;
        }),
        isFalse,
      );
    });

    testWidgets('tap and long press on the pill; one semantics node', (
      tester,
    ) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      var taps = 0;
      var longs = 0;
      await tester.pumpWidget(
        _app(
          _screen(
            onPillTap: () => taps++,
            onLongPress: () => longs++,
            label: 'Hermes, Te necesita',
          ),
        ),
      );
      await tester.tap(_pill);
      await tester.longPress(_pill);
      expect((taps, longs), (1, 1));
      expect(find.bySemanticsLabel('Hermes, Te necesita'), findsOneWidget);
      handle.dispose();
    });

    for (final (label, size) in const [
      ('phone 360', Size(360, 800)),
      ('tablet', Size(1280, 800)),
    ]) {
      testWidgets('text scale 2.0 on $label fits, centred', (tester) async {
        _phone(tester, size: size);
        await tester.pumpWidget(
          _app(
            _screen(
              text: 'Un bot con un nombre larguísimo que no cabe nunca jamás',
            ),
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
        final pill = tester.getRect(_pill);
        expect(pill.left, greaterThanOrEqualTo(48));
        expect(pill.right, lessThanOrEqualTo(size.width - 48));
        expect(pill.center.dx, closeTo(size.width / 2, 1));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: _text, matching: find.byType(RichText)),
        );
        expect(
          paragraph.textScaler.scale(14) / 14,
          closeTo(FloatingChatHeader.maxTextScale, 0.01),
        );
        expect(
          pill.bottom,
          lessThanOrEqualTo(FloatingChatHeader.insetFor(tester.element(_pill))),
        );
      });
    }

    testWidgets('light theme: the scrim follows the background', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen(), theme: AppTheme.hermesRedLight));
      expect(tester.takeException(), isNull);
      final scrim = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('floating-header-scrim')),
      );
      final first =
          ((scrim.decoration as BoxDecoration).gradient! as LinearGradient)
              .colors
              .first;
      expect(
        first.r,
        closeTo(AppTheme.hermesRedLight.hermes.background.r, 0.01),
      );
    });
  });

  group('mascot seam', () {
    testWidgets('a HeaderMascotScope builder takes the face slot; without '
        'one the default face stays; same layout', (tester) async {
      _phone(tester);
      Widget header() => FloatingChatHeader(
        faces: _face(FloatingChatHeader.faceSize),
        mascot: const HeaderMascotRequest(
          identity: 'ceo',
          state: HeaderMascotState.working,
        ),
        pill: const FloatingHeaderPill(
          key: ValueKey('test-pill'),
          text: 'CEO',
          semanticsLabel: 'CEO',
        ),
      );
      await tester.pumpWidget(_app(Scaffold(body: header())));
      expect(find.byKey(const ValueKey('test-face')), findsOneWidget);
      final slot = tester.getRect(
        find.byKey(const ValueKey('floating-header-faces')),
      );
      HeaderMascotRequest? seen;
      await tester.pumpWidget(
        _app(
          HeaderMascotScope(
            builder: (context, request) {
              seen = request;
              return const SizedBox.expand(key: ValueKey('engine-mascot'));
            },
            child: Scaffold(body: header()),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('test-face')), findsNothing);
      expect(find.byKey(const ValueKey('engine-mascot')), findsOneWidget);
      expect(seen!.identity, 'ceo');
      expect(seen!.state, HeaderMascotState.working);
      expect(
        tester.getRect(find.byKey(const ValueKey('floating-header-faces'))),
        slot,
      );
    });
  });

  group('stacked images', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('fh1215-stack-'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<List<File>> files(WidgetTester tester, int n) async => [
      for (var i = 0; i < n; i++) await _png(tester, dir, 'img-$i.png'),
    ];

    Widget stack(List<File> images, {void Function(List<File>, int)? onOpen}) =>
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StackedImageCards(
                  onOpenGallery: onOpen,
                  children: [
                    for (final f in images)
                      GeneratedImageCard(
                        status: GeneratedImageStatus.ready,
                        file: f,
                        intrinsicSize: const Size(40, 30),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );

    for (final n in [2, 3, 5]) {
      testWidgets('$n images: count badge, ${n == 2 ? 1 : 2} dimmed cards '
          'peek above the top one', (tester) async {
        _phone(tester);
        final images = await files(tester, n);
        await tester.pumpWidget(_app(stack(images)));
        await tester.pump();
        final badge = find.byKey(const ValueKey('image-stack-count'));
        expect(
          find.descendant(of: badge, matching: find.text('$n')),
          findsOneWidget,
        );
        final top = tester.getRect(
          find.byKey(const ValueKey('image-stack-top')),
        );
        final behind = n == 2 ? 1 : 2;
        final alphas = <double>[];
        for (var depth = 1; depth <= 2; depth++) {
          final card = find.byKey(ValueKey('image-stack-behind-$depth'));
          if (depth > behind) {
            expect(card, findsNothing);
            continue;
          }
          final r = tester.getRect(card);
          expect(
            r.top,
            closeTo(top.top - 8.0 * depth, 0.5),
            reason: 'peeks up',
          );
          expect(r.left, closeTo(top.left + 8.0 * depth, 0.5));
          expect(r.right, closeTo(top.right - 8.0 * depth, 0.5));
          expect(r.height, closeTo(top.height, 0.5));
          final box = tester.widget<DecoratedBox>(
            find.descendant(of: card, matching: find.byType(DecoratedBox)),
          );
          final deco = box.decoration as BoxDecoration;
          final colors = AppTheme.hermesRedDark.hermes;
          expect(deco.color, isNot(colors.background), reason: 'visible');
          expect(deco.borderRadius, isNotNull, reason: 'same rounded card');
          alphas.add(deco.color!.a);
        }
        // Further back is dimmer.
        for (var i = 1; i < alphas.length; i++) {
          expect(alphas[i], lessThan(alphas[i - 1]));
        }
        // Only one image painted: the top card.
        expect(
          find.byKey(const ValueKey('generated-image-thumbnail')),
          findsOneWidget,
        );
        expect(top.width, StackedImageCards.maxWidth);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('tap opens the gallery at the top image', (tester) async {
      _phone(tester);
      final images = await files(tester, 5);
      final opened = <(List<File>, int)>[];
      await tester.pumpWidget(
        _app(stack(images, onOpen: (f, i) => opened.add((f, i)))),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('image-stack-top')));
      expect(opened, hasLength(1));
      expect(opened.single.$2, 0);
      expect(
        opened.single.$1.map((f) => f.path),
        images.map((f) => f.path),
        reason: 'every ready image, in reply order',
      );
    });

    testWidgets('swipe cycles the top image; tap then opens that one', (
      tester,
    ) async {
      _phone(tester);
      final images = await files(tester, 3);
      final opened = <int>[];
      await tester.pumpWidget(
        _app(stack(images, onOpen: (_, i) => opened.add(i))),
      );
      await tester.pump();
      await tester.fling(
        find.byKey(const ValueKey('image-stack')),
        const Offset(-200, 0),
        1200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('image-stack-top')));
      expect(opened, [1]);
      // A short drag springs back without cycling.
      await tester.drag(
        find.byKey(const ValueKey('image-stack')),
        const Offset(-20, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('image-stack-top')));
      expect(opened, [1, 1]);
      // Right swipe goes back.
      await tester.fling(
        find.byKey(const ValueKey('image-stack')),
        const Offset(200, 0),
        1200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('image-stack-top')));
      expect(opened, [1, 1, 0]);
    });

    testWidgets('the real gallery opens at the index and swipes', (
      tester,
    ) async {
      _phone(tester);
      final images = await files(tester, 3);
      await tester.pumpWidget(_app(stack(images)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('image-stack-top')));
      await tester.pumpAndSettle();
      final position = find.byKey(const ValueKey('image-gallery-position'));
      expect(tester.widget<Text>(position).data, '1 / 3');
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.fling(
        find.byKey(const ValueKey('image-gallery-pages')),
        const Offset(-300, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(position).data, '2 / 3');
    });

    testWidgets('a single image keeps its own viewer, no position', (
      tester,
    ) async {
      _phone(tester);
      final images = await files(tester, 1);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showImageViewer(context, images.single),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        find.byKey(const ValueKey('image-gallery-position')),
        findsNothing,
      );
    });

    testWidgets('semantics name the position in the stack', (tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      final images = await files(tester, 3);
      await tester.pumpWidget(_app(stack(images)));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(r'^Imagen 1 de 3')), findsOneWidget);
      handle.dispose();
    });
  });
}
