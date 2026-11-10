// Vistas v3 (QA 9709, the owner): the chat's header with [Vistas] [Ajustes],
// two round buttons apart, and «Vistas» a switch that shows its state; and
// the header of the same glass as the composer (Navegador's strip: one blur
// for all its pieces, the composer's veil, the soft fade), with today's
// solid header wherever the device or the reader asks for no blur.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _menu = ValueKey('test-menu');
const _views = ValueKey('test-views');
const _settings = ValueKey('test-settings');

Widget _app(
  Widget home, {
  ThemeData? theme,
  double textScale = 1,
  bool reduceMotion = false,
  bool highContrast = false,
  TextDirection? textDirection,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.fromId('classic-dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
      highContrast: highContrast,
    ),
    child: textDirection == null
        ? child!
        : Directionality(textDirection: textDirection, child: child!),
  ),
  home: home,
);

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(top: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24);
  addTearDown(tester.view.reset);
}

/// A chat's header over lines of text, as the transcript under it.
Widget _chat({
  bool glass = true,
  bool viewsOn = false,
  VoidCallback? onPickPanel,
  int glassPriority = FloatingChatHeader.chatGlassPriority,
}) => Scaffold(
  body: Stack(
    children: [
      Positioned.fill(
        child: ListView(
          children: [
            for (var i = 0; i < 40; i++)
              Text('Línea $i de la conversación que pasa por detrás'),
          ],
        ),
      ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: FloatingChatHeader(
          glass: glass,
          glassPriority: glassPriority,
          faces: const SizedBox.square(dimension: FloatingChatHeader.faceSize),
          leading: FloatingHeaderButton(
            key: _menu,
            icon: Icons.menu_rounded,
            tooltip: 'Menú',
            onPressed: () {},
          ),
          trailingSecondary: FloatingHeaderButton(
            key: _views,
            icon: Icons.view_sidebar_outlined,
            selectedIcon: Icons.view_sidebar,
            toggled: viewsOn,
            tooltip: viewsOn ? 'Cerrar el panel' : 'Abrir el panel',
            onPressed: () {},
            longPressLabel: 'Elegir panel',
            onLongPress: onPickPanel ?? () {},
          ),
          trailing: FloatingHeaderButton(
            key: _settings,
            icon: Icons.more_horiz_rounded,
            tooltip: 'Esta conversación',
            onPressed: () {},
          ),
          pill: const ChatIsland(
            name: 'Hermes · 2 en marcha',
            status: IslandStatus.working,
          ),
        ),
      ),
    ],
  ),
);

List<BackdropFilterLayer> _filters(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().toList();

/// Where the one blur is, on screen: its clip, through the offsets of the
/// layers above it (the strips are repaint boundaries; no transforms here).
Rect _blurRect(WidgetTester tester) {
  final clip = tester.layers.whereType<ClipPathLayer>().singleWhere(
    (layer) => layer.firstChild is BackdropFilterLayer,
  );
  var rect = clip.clipPath!.getBounds();
  for (ContainerLayer? layer = clip.parent; layer != null;) {
    if (layer is OffsetLayer) rect = rect.shift(layer.offset);
    layer = layer.parent;
  }
  return rect;
}

Rect _face(WidgetTester tester, Key key) => tester.getRect(
  find.descendant(
    of: find.byKey(key),
    matching: find.byKey(const ValueKey('floating-header-button-face')),
  ),
);

Color _faceColor(WidgetTester tester, Key key) =>
    (tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(key),
                    matching: find.byKey(
                      const ValueKey('floating-header-button-face'),
                    ),
                  ),
                )
                .decoration
            as ShapeDecoration)
        .color!;

Color _islandFill(WidgetTester tester) => tester
    .widget<Material>(
      find
          .descendant(
            of: find.byType(IslandSurface),
            matching: find.byType(Material),
          )
          .first,
    )
    .color!;

LinearGradient _scrim(WidgetTester tester) =>
    (tester
                .widget<DecoratedBox>(
                  find.byKey(const ValueKey('floating-header-scrim')),
                )
                .decoration
            as BoxDecoration)
        .gradient!
        as LinearGradient;

void main() {
  tearDown(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });

  group('the header of glass', () {
    for (final id in ['classic-dark', 'console-light']) {
      testWidgets('$id: one blur for the whole header; every piece in the '
          'composer\'s veil, with no shadow; the soft fade', (tester) async {
        _size(tester, const Size(390, 844));
        final theme = AppTheme.fromId(id);
        await tester.pumpWidget(_app(_chat(), theme: theme));
        await tester.pump();
        expect(tester.takeException(), isNull);
        // One layer for hamburger, island, «Vistas» and «Ajustes».
        expect(_filters(tester), hasLength(1));
        final colors = theme.hermes;
        final veil = FrostedBackdrop.glassVeil(colors);
        for (final key in [_menu, _views, _settings]) {
          expect(_faceColor(tester, key), veil, reason: '$key');
        }
        expect(_islandFill(tester), veil);
        expect(
          tester
              .widget<DecoratedBox>(
                find
                    .descendant(
                      of: find.byType(IslandSurface),
                      matching: find.byType(DecoratedBox),
                    )
                    .first,
              )
              .decoration,
          isA<ShapeDecoration>().having((d) => d.shadows, 'shadows', isNull),
        );
        // Never a solid band: denser over the status bar, lighter towards
        // the pieces' foot, gone below.
        final scrim = _scrim(tester);
        expect(
          [for (final c in scrim.colors) c.a],
          [
            closeTo(HermesGlassStrip.fadeTop, 0.002),
            closeTo(HermesGlassStrip.fadeStatus, 0.002),
            closeTo(HermesGlassStrip.fadeEdge, 0.002),
            0,
          ],
        );
        expect(scrim.colors.first.r, closeTo(colors.background.r, 0.01));
      });
    }

    for (final (name, reduceMotion, highContrast, blurAllowed) in const [
      ('reduced motion', true, false, true),
      ('high contrast', false, true, true),
      ('a device that does not blur', false, false, false),
    ]) {
      testWidgets('$name: no blur, today\'s header (solid pieces, solid '
          'band)', (tester) async {
        FrostedBackdropPolicy.blurAllowed.value = blurAllowed;
        _size(tester, const Size(390, 844));
        await tester.pumpWidget(
          _app(
            _chat(),
            reduceMotion: reduceMotion,
            highContrast: highContrast,
          ),
        );
        await tester.pump();
        expect(_filters(tester), isEmpty);
        final colors = AppTheme.fromId('classic-dark').hermes;
        final chrome = HermesChrome.of(colors);
        for (final key in [_menu, _views, _settings]) {
          expect(_faceColor(tester, key), chrome.fill, reason: '$key');
        }
        expect(_islandFill(tester), chrome.opaque);
        final scrim = _scrim(tester);
        expect(scrim.colors[1].a, 1, reason: 'solid down to the extent');
      });
    }

    // Navegador's API: the chat may put the header and its pinned chip in
    // one strip; the header then joins it instead of opening its own.
    testWidgets('inside a strip of the screen: still one blur, the chip '
        'and the header together', (tester) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(
        _app(
          HermesGlassStrip(
            child: Stack(
              children: [
                _chat(),
                const Positioned(
                  top: 140,
                  left: 60,
                  child: HermesGlassPiece(
                    shape: StadiumBorder(),
                    child: SizedBox(
                      key: ValueKey('test-chip'),
                      width: 120,
                      height: 32,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(_filters(tester), hasLength(1));
      final colors = AppTheme.fromId('classic-dark').hermes;
      expect(_faceColor(tester, _menu), FrostedBackdrop.glassVeil(colors));
    });

    testWidgets('without glass (the default): no blur, as before', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(_app(_chat(glass: false)));
      await tester.pump();
      expect(_filters(tester), isEmpty);
      expect(_scrim(tester).colors[1].a, 1);
    });
  });

  // REVIEW-Q9-VISTAS3 P2: on the open Fold the Chats screen shows the
  // list's header (a HermesAppBar strip, 0) beside the chat's. One blur
  // for the zone, and it is the chat's.
  group('the open Fold: the list and the chat side by side', () {
    Widget fold({int priority = FloatingChatHeader.chatGlassPriority}) => Row(
      children: [
        SizedBox(
          width: 360,
          child: Scaffold(
            appBar: HermesAppBar(
              title: const Text('Conversaciones'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Nuevo',
                  onPressed: () {},
                ),
              ],
            ),
            body: ListView(
              children: [for (var i = 0; i < 40; i++) Text('Fila $i')],
            ),
          ),
        ),
        Expanded(child: _chat(glassPriority: priority)),
      ],
    );

    testWidgets('ONE backdrop filter, the chat header\'s', (tester) async {
      _size(tester, const Size(884, 1000));
      await tester.pumpWidget(_app(fold()));
      // Who blurs is told after the frame.
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(_filters(tester), hasLength(1));
      final colors = AppTheme.fromId('classic-dark').hermes;
      final veil = FrostedBackdrop.glassVeil(colors);
      for (final key in [_menu, _views, _settings]) {
        expect(_faceColor(tester, key), veil, reason: '$key');
      }
      expect(_islandFill(tester), veil);
      // The blur is over the chat's header, right of the 360 dp list.
      expect(_blurRect(tester).left, greaterThanOrEqualTo(360 - 0.5));
    });

    // The control: the rank decides who blurs, not who was mounted first
    // (a tie has no defined winner, gint72). Below the list's (0), the
    // list's header takes the one blur. Navegador's C2 (Q9-CRISTAL R2): a
    // strip that loses the zone keeps the glass's look, its veil, and only
    // loses the blur (gint73: it no longer goes back to the solid chrome).
    testWidgets('ranked below the list, the chat\'s header keeps its veil '
        'but not the blur: the rank decides who blurs', (tester) async {
      _size(tester, const Size(884, 1000));
      await tester.pumpWidget(_app(fold(priority: -1)));
      await tester.pump();
      await tester.pump();
      expect(_filters(tester), hasLength(1));
      // The one blur is over the list's header, left of the chat.
      expect(_blurRect(tester).right, lessThanOrEqualTo(360 + 0.5));
      final veil = FrostedBackdrop.glassVeil(
        AppTheme.fromId('classic-dark').hermes,
      );
      for (final key in [_menu, _views, _settings]) {
        expect(_faceColor(tester, key), veil, reason: '$key (C2)');
      }
    });
  });

  group('[Vistas] [Ajustes]', () {
    for (final width in const [320.0, 360.0, 390.0, 773.0, 884.0]) {
      for (final scale in const [1.0, 1.3, 2.0]) {
        testWidgets('${width.toInt()} dp, text ${scale}x: two whole circles '
            'apart, 48 dp targets, the island between and touching '
            'nothing', (tester) async {
          _size(tester, Size(width, 900));
          await tester.pumpWidget(_app(_chat(), textScale: scale));
          await tester.pump();
          expect(tester.takeException(), isNull);
          for (final key in [_menu, _views, _settings]) {
            expect(
              _face(tester, key).size,
              const Size.square(FloatingChatHeader.buttonSize),
            );
            final target = tester.getRect(find.byKey(key));
            expect(target.width, greaterThanOrEqualTo(48));
            expect(target.height, greaterThanOrEqualTo(48));
          }
          final views = _face(tester, _views);
          final settings = _face(tester, _settings);
          expect(
            settings.left - views.right,
            greaterThanOrEqualTo(HermesSpace.x2),
          );
          expect(settings.right, lessThanOrEqualTo(width));
          final island = tester.getRect(find.byKey(const ValueKey('island')));
          expect(island.left, greaterThan(_face(tester, _menu).right));
          expect(island.right, lessThan(views.left));
        });
      }
    }

    testWidgets('right to left: nothing overlaps', (tester) async {
      _size(tester, const Size(360, 800));
      await tester.pumpWidget(
        _app(_chat(), textDirection: TextDirection.rtl),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final island = tester.getRect(find.byKey(const ValueKey('island')));
      for (final key in [_menu, _views, _settings]) {
        expect(_face(tester, key).overlaps(island), isFalse, reason: '$key');
      }
    });

    testWidgets('«Vistas» is a switch: TalkBack hears its name, its state '
        'and «Elegir panel»; a long press opens more', (tester) async {
      final semantics = tester.ensureSemantics();
      var picks = 0;
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(_app(_chat(onPickPanel: () => picks++)));
      await tester.pump();
      final node = tester.getSemantics(
        find.descendant(
          of: find.byKey(_views),
          matching: find.byType(MergeSemantics),
        ),
      );
      expect(
        node,
        isSemantics(
          label: 'Abrir el panel',
          isButton: true,
          hasToggledState: true,
          isToggled: false,
          hasLongPressAction: true,
          hasTapAction: true,
        ),
      );
      // The chevron says there is more; a plain button has none.
      expect(
        find.descendant(
          of: find.byKey(_views),
          matching: find.byKey(const ValueKey('floating-header-button-more')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_settings),
          matching: find.byKey(const ValueKey('floating-header-button-more')),
        ),
        findsNothing,
      );
      await tester.longPress(find.byKey(_views));
      await tester.pump();
      expect(picks, 1);
      semantics.dispose();
    });

    testWidgets('a button that cannot be used looks it: the muted ink', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: Center(
              child: FloatingHeaderButton(
                key: _views,
                icon: Icons.view_sidebar_outlined,
                tooltip: 'Vistas',
                onPressed: null,
              ),
            ),
          ),
        ),
      );
      final chrome = HermesChrome.of(AppTheme.fromId('classic-dark').hermes);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(_views),
          matching: find.byIcon(Icons.view_sidebar_outlined),
        ),
      );
      expect(icon.color, chrome.mutedInk);
    });

    testWidgets('on: the filled icon on a soft accent face, still in the '
        'veil', (tester) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(_app(_chat(viewsOn: true)));
      await tester.pump();
      final colors = AppTheme.fromId('classic-dark').hermes;
      final veil = FrostedBackdrop.glassVeil(colors);
      expect(
        find.descendant(
          of: find.byKey(_views),
          matching: find.byIcon(Icons.view_sidebar),
        ),
        findsOneWidget,
      );
      final face = _faceColor(tester, _views);
      expect(face, isNot(veil));
      expect(
        face,
        Color.alphaBlend(colors.accent.withValues(alpha: 0.16), veil),
      );
      expect(_faceColor(tester, _settings), veil);
    });
  });
}
