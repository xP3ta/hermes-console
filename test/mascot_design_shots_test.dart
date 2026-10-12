import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_manifest_parser.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/render/companion_floating_pet.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/screens/companion/mascotas_screen.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_screen.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_attention.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_float_physics.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_overlay.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_prefs.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_route_watch.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_sources.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_atlas.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_identity.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart';

/// The floating mascot at 390 x 844, Spanish, dark: the real overlay, the
/// real dock and a bundled pet over stand-in pages. Writes PNGs when a
/// directory is given (`DESIGN_SHOTS_DIR` in the environment, or
/// `--dart-define=MASCOT_SHOTS_DIR=…`); otherwise it is a layout test: the
/// pet stands where the approved drawing puts it and nothing overflows.

const _size = Size(390, 844);
const _sprite = ValueKey('mascot-overlay-sprite');
const _shot = ValueKey('mascot-shot');

String? get _dir {
  const defined = String.fromEnvironment('MASCOT_SHOTS_DIR');
  if (defined.isNotEmpty) return defined;
  final env = Platform.environment['DESIGN_SHOTS_DIR'];
  return env == null || env.isEmpty ? null : env;
}

class _Stage {
  _Stage(this.companion);

  final CompanionController companion;
  final prefs = MascotPrefs();
  final geometry = DockGeometry();
  final dock = GestureDockController();
  late final watch = MascotRouteWatch(geometry: geometry);
  final attention = MascotAttention()..setScope(connId: 'c1', profile: '');
  final navigator = GlobalKey<NavigatorState>();

  late final pet = CompanionFloatingPet(companion);
  late final sources = MascotSources(
    permissions: attention.permissions,
    notices: attention.notices,
  );

  Widget page(Widget body, {bool withDock = true, GestureDockTab? current}) =>
      DockScreen(
        geometry: geometry,
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              body,
              if (withDock)
                GestureDock(
                  controller: dock,
                  geometry: geometry,
                  current: current ?? GestureDockTab.home,
                  onTab: {
                    for (final tab in GestureDockTab.values)
                      if (tab != (current ?? GestureDockTab.home)) tab: () {},
                  },
                ),
            ],
          ),
        ),
      );

  Widget app(Widget home) => RepaintBoundary(
    key: _shot,
    child: MaterialApp(
      navigatorKey: navigator,
      debugShowCheckedModeBanner: false,
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      navigatorObservers: [watch],
      builder: (context, nav) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 44, bottom: 24),
          viewPadding: const EdgeInsets.only(top: 44, bottom: 24),
        ),
        child: MascotOverlayHost(
          pet: pet,
          prefs: prefs,
          sources: sources,
          geometry: geometry,
          routeWatch: watch,
          actions: MascotOverlayActions(onTalk: () {}, onChange: () {}),
          child: nav!,
        ),
      ),
      home: home,
    ),
  );
}

/// No pet ships with the app (they come from Petdex). The repo keeps the
/// team's own CC0 ones in Petdex format: one of them, read from disk the way
/// an imported pet is.
class _DiskRepo extends CompanionRepository {
  @override
  Future<Directory?> importedRoot() async => null;

  @override
  Future<List<Companion>> loadAll() async {
    final dir = Directory('assets/companions/nimbus').absolute.path;
    return [
      CompanionManifestParser.parse(
        File('$dir/pet.json').readAsStringSync(),
        assetDir: dir,
        slug: 'nimbus',
        origin: CompanionOrigin.imported,
      ),
    ];
  }
}

Future<CompanionController> _companion(
  WidgetTester tester, {
  String? slug = 'nimbus',
}) async {
  final controller = CompanionController(
    _DiskRepo(),
    await CompanionPreferences.load(),
  );
  await tester.runAsync(controller.init);
  if (slug != null) {
    await tester.runAsync(() => controller.select(slug));
    expect(controller.activeCompanion?.slug, slug);
  }
  return controller;
}

Future<_Stage> _pump(
  WidgetTester tester,
  Widget Function(_Stage stage) home, {
  String? slug = 'nimbus',
}) async {
  await loadDesignFonts();
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final stage = _Stage(await _companion(tester, slug: slug));
  await tester.pumpWidget(stage.app(home(stage)));
  await _frames(tester);
  return stage;
}

/// Lets the sprite sheet decode (real time) and the overlay settle.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _save(WidgetTester tester, String name) async {
  final dir = _dir;
  if (dir == null) return;
  await _frames(tester);
  final boundary =
      tester.renderObject(find.byKey(_shot)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

Widget _card(BuildContext context, String title, List<String> lines) {
  final colors = Theme.of(context).hermes;
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: colors.surfaceVariant.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: colors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 10),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    ),
  );
}

/// Inicio: a board of cards that does not scroll, the dock under it.
Widget _homeBody(BuildContext context) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 60, 16, 110),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'CONSOLE',
        style: TextStyle(
          color: Theme.of(context).hermes.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 14),
      _card(context, 'Ahora', const [
        'Forja · Console Devs',
        'Hermes · Prueba con subagentes',
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: _card(context, 'Bots', const [
          'Forja',
          'Radar',
          'Fable',
          'Astra',
          'Argos',
        ]),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 150,
        child: Row(
          children: [
            Expanded(
              child: _card(context, 'Salas', const [
                'Console Devs',
                'Luego, Astra',
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _card(context, 'Cron', const [
                '03:00',
                'Copia de seguridad',
              ]),
            ),
          ],
        ),
      ),
    ],
  ),
);

/// Chats: a list that scrolls under the dock.
Widget _listBody(BuildContext context) {
  final colors = Theme.of(context).hermes;
  return ListView(
    padding: const EdgeInsets.fromLTRB(18, 64, 18, 120),
    children: [
      Text(
        'Chats',
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 16),
      for (final (title, line) in const [
        ('Prueba con subagentes, herramientas…', 'Trabajando · 2 subagentes'),
        (
          'Buscar cómo era onboarding nuevo',
          'Te pregunta · ¿Sigo con la versión…',
        ),
        ('Diseño de píldora de estados', 'Terminó · Te dejo tres opciones'),
        ('Saludo amistoso', 'Borrador · Hola, necesito hacer unos…'),
        ('Arreglar selección de modelo fallback', 'Terminó · Ya elige Sonnet'),
        ('Restaurar errores localizados', 'Terminó · Quedan dos cadenas'),
        ('Prueba de scroll', 'Terminó · Listo, el scroll ya no salta'),
        ('Notas de la versión', 'Terminó · Publicadas'),
        ('Plan de viaje', 'Terminó · Tres rutas'),
        ('Recetas de la semana', 'Terminó · Lista de la compra'),
        ('Copia de seguridad', 'Terminó · Sin errores'),
        ('Ideas para el widget', 'Borrador'),
      ])
        InkWell(
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

const _forja = MascotPlace(
  connId: 'c1',
  connLabel: 'Oficina',
  profile: 'forja',
  profileLabel: 'Forja',
);
const _casa = MascotPlace(connId: 'c2', connLabel: 'Casa');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The pet's real drawing, one still frame: the shots show where it
    // stands, not how it moves.
    debugMascotSpritesStill = true;
  });

  /// Where the bar rests on this screen (14 px side margin, 14 px above
  /// the 24 px navigation inset, 60 px tall).
  final bar = Rect.fromLTWH(14, 844 - 24 - 14 - 60, 362, 60);

  testWidgets('Inicio: standing on the dock\'s right end', (tester) async {
    final stage = await _pump(
      tester,
      (s) => s.page(Builder(builder: _homeBody)),
    );
    expect(stage.geometry.rect.value, bar);
    expect(find.byKey(const ValueKey('floating-pet-sprite')), findsOneWidget);
    final box = tester.getRect(find.byKey(_sprite));
    expect(box.size, const Size.square(48));
    expect(box.bottom, bar.top + 2, reason: 'feet on the top edge');
    expect(
      box.right,
      bar.right - MascotFloatPhysics.dockEndInset,
      reason: 'the right end',
    );
    // Over none of the dock's five items.
    for (final tab in GestureDockTab.defaultLayout) {
      final item = tester.getRect(
        find.byKey(ValueKey('gesture-dock-tab-${tab.name}')),
      );
      expect(box.intersect(item.deflate(1)).height, lessThanOrEqualTo(2));
    }
    expect(tester.takeException(), isNull);
    await _save(tester, '01-inicio-sobre-el-dock');
    await _close(tester);
  });

  testWidgets('a list screen: the same spot', (tester) async {
    final stage = await _pump(
      tester,
      (s) =>
          s.page(Builder(builder: _listBody), current: GestureDockTab.search),
    );
    final box = tester.getRect(find.byKey(_sprite));
    expect(
      box.bottomRight,
      Offset(bar.right - MascotFloatPhysics.dockEndInset, bar.top + 2),
    );
    expect(stage.prefs.moved, isFalse);
    await _save(tester, '02-lista-sobre-el-dock');
    await _close(tester);
  });

  testWidgets('dock switched off: its corner', (tester) async {
    await _pump(
      tester,
      (s) => s.page(Builder(builder: _homeBody), withDock: false),
    );
    final box = tester.getRect(find.byKey(_sprite));
    expect(
      box.right,
      bar.right - MascotFloatPhysics.dockEndInset,
      reason: 'the same column',
    );
    expect(box.bottom, 844 - 24 - 12, reason: 'above the navigation inset');
    await _save(tester, '03-sin-dock');
    await _close(tester);
  });

  testWidgets('dock hidden by hand: clear of the handle', (tester) async {
    final stage = await _pump(
      tester,
      (s) => s.page(Builder(builder: _homeBody)),
    );
    stage.dock.setHidden(true);
    await _frames(tester);
    final box = tester.getRect(find.byKey(_sprite));
    final handle = stage.geometry.rect.value!;
    expect(stage.geometry.hidden.value, isTrue);
    expect(box.overlaps(handle), isFalse);
    expect(box.right, bar.right - MascotFloatPhysics.dockEndInset);
    await _save(tester, '04-dock-escondido');
    await _close(tester);
  });

  testWidgets('dragged to a free spot: it stays there', (tester) async {
    final stage = await _pump(
      tester,
      (s) =>
          s.page(Builder(builder: _listBody), current: GestureDockTab.search),
    );
    final from = tester.getRect(find.byKey(_sprite));
    final gesture = await tester.startGesture(from.center);
    await gesture.moveBy(const Offset(-8, -8));
    await gesture.moveTo(const Offset(70, 420));
    await tester.pump();
    await gesture.up();
    await _frames(tester);
    final box = tester.getRect(find.byKey(_sprite));
    expect(box.center.dx, closeTo(70, 0.5));
    expect(box.center.dy, closeTo(420, 0.5));
    expect(stage.prefs.placement, MascotPlacement.free);
    await _save(tester, '05-arrastrada-a-un-sitio-libre');
    await _close(tester);
  });

  testWidgets('its menu', (tester) async {
    await _pump(tester, (s) => s.page(Builder(builder: _homeBody)));
    await tester.tap(find.byKey(_sprite));
    await tester.pump();
    for (final label in ['Hablar', 'Cambiar mascota', 'Ocultar']) {
      expect(find.text(label), findsOneWidget);
    }
    final menu = tester.getRect(
      find.byKey(const ValueKey('mascot-overlay-bubble')),
    );
    expect(menu.width, lessThanOrEqualTo(220), reason: 'a tiny menu');
    expect(menu.right, lessThanOrEqualTo(390 - 12));
    expect(menu.bottom, lessThan(tester.getRect(find.byKey(_sprite)).top));
    await _save(tester, '06-menu');
    await _close(tester);
  });

  testWidgets('a bubble for another profile', (tester) async {
    final stage = await _pump(
      tester,
      (s) => s.page(Builder(builder: _homeBody)),
    );
    for (final (id, text) in const [
      ('s1', 'Hermes respondió en Diseño de píldora'),
      ('s2', 'Terminó: Revisar disco'),
      ('s3', 'Hermes respondió en Login'),
    ]) {
      stage.attention.report(
        MascotEvent(id: id, place: _forja, text: text, open: () {}),
      );
    }
    await tester.pump();
    await tester.tap(find.byKey(_sprite));
    await tester.pump();
    expect(find.text('Forja tiene 3 novedades'), findsOneWidget);
    expect(find.text('Ver'), findsOneWidget);
    await _save(tester, '07-burbuja-otro-perfil');
    await _close(tester);
  });

  testWidgets('a bubble for another instance', (tester) async {
    final stage = await _pump(
      tester,
      (s) =>
          s.page(Builder(builder: _listBody), current: GestureDockTab.search),
    );
    stage.attention.report(
      MascotEvent(
        id: 'j1',
        place: _casa,
        text: 'Falló una tarea programada: Copia de seguridad',
        failed: true,
        open: () {},
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(_sprite));
    await tester.pump();
    expect(
      find.text('Casa: Falló una tarea programada: Copia de seguridad'),
      findsOneWidget,
    );
    expect(find.text('Ir'), findsOneWidget);
    await _save(tester, '08-burbuja-otra-instancia');
    await _close(tester);
  });

  testWidgets('a permission from another profile', (tester) async {
    final stage = await _pump(
      tester,
      (s) => s.page(Builder(builder: _homeBody)),
    );
    stage.attention.setWaiting([
      MascotWaiting(
        key: 'c1:s9:r1',
        place: _forja,
        title: 'Login tests',
        command: 'git push origin fix/login-tests',
        resolve: (_) async {},
        open: () {},
      ),
    ]);
    await tester.pump();
    await tester.tap(find.byKey(_sprite));
    await tester.pump();
    expect(find.text('Forja · Login tests'), findsOneWidget);
    for (final label in ['Permitir', 'Rechazar', 'Ver el chat']) {
      expect(find.text(label), findsOneWidget);
    }
    await _save(tester, '09-permiso');
    await _close(tester);
  });

  testWidgets('no pet chosen: Hermes\' own sprite', (tester) async {
    await tester.runAsync(() => MascotAtlas.load(MascotIdentity.hermes.sprite));
    await _pump(tester, (s) => s.page(Builder(builder: _homeBody)), slug: null);
    expect(find.byKey(const ValueKey('floating-pet-hermes')), findsOneWidget);
    expect(find.byKey(const ValueKey('floating-pet-sprite')), findsNothing);
    await _save(tester, '10-sin-mascota-elegida');
    await _close(tester);
  });

  testWidgets('Mascotas: the presence block', (tester) async {
    await loadDesignFonts();
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _companion(tester);
    final mascot = MascotPrefs();
    await mascot.ensureLoaded();
    await mascot.placeFree(const Offset(0.2, 0.4));
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: MascotasScreen(
            controller: controller,
            mascotPrefs: mascot,
            petdexVerified: false,
          ),
        ),
      ),
    );
    await _frames(tester);
    for (final label in ['Apagada', 'Solo en el chat', 'En toda la app']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Volver al dock'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _save(tester, '11-mascotas-presencia');
    await _close(tester);
  });
}
