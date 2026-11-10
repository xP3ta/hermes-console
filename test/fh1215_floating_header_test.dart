import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/generated_image_card.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/stacked_image_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// fh1215: every chat surface gets a floating header (no app bar band): a
// round back button, a round button on the right and, in the centre, the
// island with the face(s) standing on its top edge. At rest the island is
// the name after one state dot (its own suite: island_test.dart). Several
// images of one reply become a stack of cards.

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
  IslandStatus status = IslandStatus.idle,
  VoidCallback? onBack,
  VoidCallback? onPillTap,
  VoidCallback? onLongPress,
  bool newChat = true,
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
          pill: ChatIsland(
            name: text,
            status: status,
            onTap: onPillTap,
            onLongPress: onLongPress,
          ),
        ),
      ),
    ],
  ),
);

Finder get _pill => find.byKey(const ValueKey('island'));
Finder get _text => find.byKey(const ValueKey('island-name'));

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
    testWidgets('no app bar band: the face stands on a centred island, round '
        'buttons float at the sides', (tester) async {
      _phone(tester);
      var back = 0;
      await tester.pumpWidget(_app(_screen(onBack: () => back++)));
      expect(find.byType(AppBar), findsNothing);
      final face = tester.getRect(find.byKey(const ValueKey('test-face')));
      final pill = tester.getRect(_pill);
      expect((pill.center.dx - 195).abs(), lessThan(1), reason: 'centred');
      expect((face.center.dx - pill.center.dx).abs(), lessThan(1));
      // The face STANDS on the island: above it, its feet on the top edge.
      expect(face.top, lessThan(pill.top));
      expect(face.bottom - pill.top, FloatingChatHeader.faceOverlap);
      expect(face.height, FloatingChatHeader.faceSize);
      expect(face.height, 48);
      expect(face.top, greaterThanOrEqualTo(24), reason: 'below status bar');
      for (final key in ['floating-header-back', 'test-new']) {
        // Vistas v3: the circle is the button's face, under a bare
        // IconButton (it may be a strip's glass piece).
        final circle = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byKey(const ValueKey('floating-header-button-face')),
        );
        expect(tester.getSize(circle), const Size.square(44));
        final face = tester.widget<DecoratedBox>(circle).decoration;
        expect(face, isA<ShapeDecoration>());
        face as ShapeDecoration;
        expect(face.shape, isA<CircleBorder>());
        expect(face.color!.a, greaterThan(0.5), reason: 'surface tint');
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          (tester.getCenter(circle).dy - pill.center.dy).abs(),
          lessThan(1),
          reason: 'buttons line up with the island',
        );
        expect(tester.getRect(circle).top, greaterThan(24));
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

    // the owner (gint72): no state dot of colour; a state that asks for
    // attention is said in words, in the muted ink.
    testWidgets('the name keeps its ink in every state; no dot of colour', (
      tester,
    ) async {
      _phone(tester);
      final colors = AppTheme.hermesRedDark.hermes;
      for (final status in IslandStatus.values) {
        await tester.pumpWidget(_app(_screen(text: 'x', status: status)));
        expect(
          tester.widget<Text>(_text).style!.color,
          colors.textPrimary,
          reason: '$status',
        );
        expect(
          find.descendant(
            of: _pill,
            matching: find.byKey(ValueKey('island-dot-${status.name}')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: _pill,
            matching: find.byKey(ValueKey('island-state-${status.name}')),
          ),
          status == IslandStatus.idle || status == IslandStatus.working
              ? findsNothing
              : findsOneWidget,
          reason: '$status',
        );
        expect(
          find.descendant(of: _pill, matching: find.byType(Icon)),
          findsNothing,
          reason: 'no chevron',
        );
      }
    });

    // Measured in a gate run: a Scaffold that makes room
    // for the keyboard lowers its body's viewPadding.bottom on every keyboard
    // frame. The header reads only its top inset, so a keyboard frame
    // rebuilds, relays out and repaints none of it; a new top inset (a
    // rotation, a cutout) still moves it.
    testWidgets('a keyboard frame neither rebuilds nor repaints it', (
      tester,
    ) async {
      _phone(tester);
      tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 72);
      tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
      await tester.pumpWidget(_app(_screen()));
      // Let the first frame settle before anything is counted. Measured
      // in gate runs: the frame after pumpWidget rebuilds the
      // header's button's Focus and _FocusInheritedScope with no keyboard
      // change at all (focus settling under its InkResponse's Actions), and
      // the next one rebuilds nothing. Only what a keyboard frame does is
      // judged below.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final root = tester.element(find.byType(FloatingChatHeader));
      final elements = Set<Element>.identity()..add(root);
      final renders = Set<RenderObject>.identity();
      void collect(Element element) {
        elements.add(element);
        final render = element.renderObject;
        if (render != null) renders.add(render);
        element.visitChildren(collect);
      }

      root.visitChildren(collect);
      // Gate gint42 (measured, gdiag42): the island's own Builder, inside
      // its LayoutBuilder, rebuilt on the keyboard frame, unseen by a check
      // of the root and the LayoutBuilder alone. Every element of the
      // header is watched now; only the widget that hands the header the
      // view without its bottom edge, and the MediaQuery it makes, rebuild.
      final topInset = elements.firstWhere(
        (element) => element.widget.runtimeType.toString() == '_TopInset',
      );
      Element? topInsetData;
      topInset.visitChildren((child) => topInsetData = child);
      final rebuiltTypes = <String>[];
      final paintedTypes = <String>[];
      // The header's own layer (FloatingChatHeader wraps itself in it).
      final ownBoundary = tester.renderObject(
        find
            .descendant(
              of: find.byType(FloatingChatHeader),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      final cleanVisits = Set<RenderObject>.identity();
      var rebuilds = 0;
      var paints = 0;
      // The page behind it (the fixture's blue box): the keyboard does relay
      // the body out and repaint it, so a header painted with its parent's
      // layer would show here.
      final page = tester.renderObject(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.blue,
        ),
      );
      var pagePaints = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (!elements.contains(element) ||
            identical(element, topInset) ||
            identical(element, topInsetData)) {
          return;
        }
        rebuilds++;
        rebuiltTypes.add('${element.widget.runtimeType}');
      };
      debugProfilePaintsEnabled = true;
      debugOnProfilePaint = (render) {
        if (identical(render, page)) pagePaints++;
        if (!renders.contains(render)) return;
        // Gate gint44: PaintingContext.paintChild calls this hook for every
        // child it visits, a repaint boundary included, before it looks at
        // whether that boundary is dirty (flutter rendering/object.dart,
        // paintChild: debugOnProfilePaint?.call(child), then
        // _compositeChild). A clean boundary is not painted: _compositeChild
        // only reuses its layer (repaintCompositedChild runs only when it
        // needs paint). So the header's own boundary, visited while the
        // body around it repaints, counts only if it really repaints.
        // Anything painted under it is counted as before.
        if (render.isRepaintBoundary && !render.debugNeedsPaint) {
          cleanVisits.add(render);
          return;
        }
        paints++;
        paintedTypes.add(
          '${render.runtimeType} '
          '(${'${render.debugCreator}'.split('\n').first})',
        );
      };
      addTearDown(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        debugProfilePaintsEnabled = false;
      });
      final pillTop = tester.getRect(_pill).top;
      for (final inset in [45.0, 180.0, 360.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          rebuilds,
          0,
          reason: 'keyboard $inset rebuilt the header: $rebuiltTypes',
        );
        expect(
          paints,
          0,
          reason: 'keyboard $inset repainted the header: $paintedTypes',
        );
      }
      // Gate gint41: the body around it did repaint, the header did not.
      expect(pagePaints, greaterThan(0));
      // Gate gint44: the one object the hook reported was the header's own
      // boundary, visited clean while the body repainted, and nothing else.
      expect(cleanVisits, {ownBoundary});
      debugOnRebuildDirtyWidget = null;
      debugOnProfilePaint = null;
      debugProfilePaintsEnabled = false;

      tester.view.viewPadding = const FakeViewPadding(top: 120, bottom: 72);
      tester.view.padding = const FakeViewPadding(top: 120, bottom: 72);
      await tester.pump();
      expect(tester.getRect(_pill).top, closeTo(pillTop + 16, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('its extent never depends on the island', (tester) async {
      _phone(tester);
      final heights = <double>{};
      for (final status in IslandStatus.values) {
        await tester.pumpWidget(_app(_screen(text: 'x', status: status)));
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

    // the owner (APK 9708): the reply read through the header and the island.
    // The band is solid down to the header's extent; only the tail fades.
    testWidgets('a solid band under the header, a short fade, no blur', (
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
      expect(gradient.colors.first.a, 1);
      expect(gradient.colors[1].a, 1);
      expect(gradient.colors.last.a, 0);
      expect(gradient.colors.first.r, closeTo(bg.r, 0.01));
      final height = tester
          .getSize(find.byKey(const ValueKey('floating-header-scrim')))
          .height;
      // Opaque down to the header's extent, then the tail.
      final inset = FloatingChatHeader.insetFor(tester.element(_pill));
      expect(height, inset + FloatingChatHeader.scrimTail);
      expect(gradient.stops![1], closeTo(inset / height, 0.001));
      // The status bar, the 48 dp face, the island and the tail.
      expect(height, inInclusiveRange(120, 150));
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

    testWidgets('tap and long press on the island; one semantics node', (
      tester,
    ) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      var taps = 0;
      var longs = 0;
      await tester.pumpWidget(
        _app(
          _screen(
            text: 'Hermes',
            status: IslandStatus.needsYou,
            onPillTap: () => taps++,
            onLongPress: () => longs++,
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

  // the owner, Fold horizontal (APK 9708): «≡» on the left, a big gap, the
  // island, and «Vistas» and «+» stuck to the right. The two right buttons
  // now share one pill, and the island touches neither side.
  group('header of pills (mock 136 v2-A)', () {
    Widget wide({bool compact = false}) => Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.blue)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FloatingChatHeader(
              compact: compact,
              faces: _face(FloatingChatHeader.faceSize),
              leading: FloatingHeaderButton(
                key: const ValueKey('test-list'),
                icon: Icons.menu_rounded,
                tooltip: 'List',
                onPressed: () {},
              ),
              trailingSecondary: FloatingHeaderButton(
                key: const ValueKey('test-views'),
                icon: Icons.view_column_outlined,
                tooltip: 'Views',
                onPressed: () {},
              ),
              trailing: FloatingHeaderButton(
                key: const ValueKey('test-new'),
                icon: Icons.add_rounded,
                tooltip: 'New',
                onPressed: () {},
              ),
              pill: const ChatIsland(
                name: 'Hermes · 2 en marcha con un nombre largo',
                status: IslandStatus.working,
              ),
            ),
          ),
        ],
      ),
    );

    // Vistas v3 (the owner): [Vistas] [Ajustes], two round buttons apart, each
    // its own circle as the left one; no shared pill.
    testWidgets('the right buttons stand apart, each its own circle; the '
        'island touches nothing', (tester) async {
      _phone(tester, size: const Size(480, 704));
      await tester.pumpWidget(_app(wide()));
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('floating-header-button-group')),
        findsNothing,
      );
      final pair = tester.getRect(
        find.byKey(const ValueKey('floating-header-trailing-pair')),
      );
      Rect face(String key) => tester.getRect(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byKey(const ValueKey('floating-header-button-face')),
        ),
      );
      final views = tester.getRect(find.byKey(const ValueKey('test-views')));
      final add = tester.getRect(find.byKey(const ValueKey('test-new')));
      // Each keeps a 48 dp target around its 44 dp circle.
      for (final rect in [views, add]) {
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      for (final key in ['test-list', 'test-views', 'test-new']) {
        expect(
          face(key).size,
          const Size.square(FloatingChatHeader.buttonSize),
        );
      }
      // Apart: at least 8 dp between the two circles.
      expect(
        face('test-new').left - face('test-views').right,
        greaterThanOrEqualTo(FloatingChatHeader.pairGap),
      );
      expect(pair.contains(views.center), isTrue);
      expect(pair.contains(add.center), isTrue);
      final list = tester.getRect(find.byKey(const ValueKey('test-list')));
      final pill = tester.getRect(_pill);
      // The island never touches the buttons (where it centres is the
      // island's own rule, feat/140-pill: island_pill_fit_test).
      expect(pill.left, greaterThan(list.right));
      expect(pill.right, lessThan(pair.left));
    });

    testWidgets('compact: one thin row, no face, buttons in line', (
      tester,
    ) async {
      _phone(tester, size: const Size(480, 704));
      await tester.pumpWidget(_app(wide(compact: true)));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('test-face')), findsNothing);
      final pill = tester.getRect(_pill);
      final inset = FloatingChatHeader.insetFor(
        tester.element(_pill),
        compact: true,
      );
      expect(
        inset,
        24 + FloatingChatHeader.heightFor(TextScaler.noScaling, compact: true),
      );
      // One row: the island as tall as an event, 4 dp of air above it and
      // the 4 below, no face. The full header keeps only 1 dp above its
      // face since the face stands on the island (62c19919); the row keeps
      // 4 above the island so the 44 dp side buttons, centred on it, stay
      // below the status bar. So it is the full header less the face and
      // those 3 dp, not less the whole face.
      expect(
        FloatingChatHeader.heightFor(TextScaler.noScaling, compact: true),
        4 + IslandMetrics.eventHeight + 4,
      );
      expect(
        FloatingChatHeader.heightFor(TextScaler.noScaling) -
            FloatingChatHeader.heightFor(TextScaler.noScaling, compact: true),
        // The face's overlap never moves the island's top edge, so it adds
        // nothing to the header's extent.
        FloatingChatHeader.faceSize - 3,
      );
      expect(pill.top, lessThan(24 + 8));
      expect(pill.bottom, lessThanOrEqualTo(inset));
      final list = tester.getRect(find.byKey(const ValueKey('test-list')));
      expect((list.center.dy - pill.center.dy).abs(), lessThan(1));
    });

    test('compact below 560 dp above the keyboard', () {
      expect(
        FloatingChatHeader.compactFor(height: 704, keyboard: 0),
        isFalse,
      );
      // The open Fold with an 800 px keyboard at 2.625: 305 dp.
      expect(
        FloatingChatHeader.compactFor(height: 704, keyboard: 305),
        isTrue,
      );
      // A phone keeps its face.
      expect(
        FloatingChatHeader.compactFor(height: 915, keyboard: 320),
        isFalse,
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
        pill: const ChatIsland(name: 'CEO', status: IslandStatus.idle),
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
      expect(seen!.size, 48);
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
          'behind the top one, shifted and turned as in L2', (tester) async {
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
          // L2 (`v2-cadu-console.html` `.stack .c`): the same card as the
          // top one, shifted 7 px to the end and 6 px up per depth and
          // turned 2° more each time.
          final r = tester.getRect(card);
          expect(r.topLeft, offsetMoreOrLessEquals(top.topLeft, epsilon: 0.5));
          expect(r.width, closeTo(top.width, 0.5));
          expect(r.height, closeTo(top.height, 0.5));
          final turn = tester
              .widget<Transform>(
                find.byKey(ValueKey('image-stack-behind-$depth-turn')),
              )
              .transform;
          expect(turn.getTranslation().x, closeTo(7.0 * depth, 0.01));
          expect(
            turn.getTranslation().y,
            closeTo(-6.0 * depth, 0.01),
            reason: 'shifted up',
          );
          expect(
            math.atan2(turn.entry(1, 0), turn.entry(0, 0)),
            closeTo(2 * math.pi / 180 * depth, 1e-6),
          );
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
      expect(tester.widget<Text>(position).data, '1 de 3');
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.fling(
        find.byKey(const ValueKey('image-gallery-pages')),
        const Offset(-300, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(position).data, '2 de 3');
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
