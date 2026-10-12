// Visual evidence of the floating header (E1), the chrome tone (T1) and the
// dissolving bottom edge (B2): one page per pattern, dark and light, at the
// top and scrolled, at 412×915 in Spanish.
//
// PNGs are written only with `--dart-define=GLASS_SHOTS=<dir>`; without it
// this is a layout smoke test (nothing overflows in either theme).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/screens/voice_guide_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesSearchField, HermesSegment, HermesSegmentedControl;
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart';

const _dir = String.fromEnvironment('GLASS_SHOTS');
const _size = Size(412, 915);
const _key = ValueKey('glass-shot');
const _themes = ['classic-dark', 'classic'];

Future<void> _pump(WidgetTester tester, Widget home, String themeId) async {
  await loadDesignFonts();
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 36, bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 36, bottom: 24);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId(themeId),
        home: home,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  if (_dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(_dir).createSync(recursive: true);
    File('$_dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _topAndScrolled(
  WidgetTester tester,
  String name,
  Finder scrollable, {
  double by = 260,
}) async {
  await _shot(tester, '${name}_top');
  await tester.drag(scrollable, Offset(0, -by));
  await tester.pump(const Duration(milliseconds: 400));
  await _shot(tester, '${name}_scrolled');
}

const _chats = [
  ('Prueba con subagentes, herramientas y pensamiento', 'Hecho: 4 de 5 tareas'),
  ('Buscar cómo era el onboarding nuevo', '¿Sigo con la versión de marzo?'),
  ('Diseño de píldora de estados', 'Te dejo tres opciones de píldora'),
  ('Saludo amistoso', 'Borrador · Hola, necesito hacer unos retoques'),
  ('Arreglar selección de modelo fallback', 'Ya elige Sonnet 5.5'),
  ('Restaurar errores localizados', 'Los 14 textos vuelven a salir'),
  ('Prueba QA 9511, responder OK', 'OK'),
  ('Copia de seguridad del homelab', 'La copia de las 03:00 terminó'),
  ('Notas de la versión 1.2.15', 'Borrador en inglés, listo para revisar'),
  ('Revisar disco al 92 % y carga alta', 'El disco baja al 81 %'),
  ('Ideas para el widget de Cron', 'Tres tamaños'),
  ('Traducir la guía de voz', 'Quedan dos apartados'),
  ('Entrada RRHH del lunes', 'Te lo recuerdo el lunes a las 07:00'),
  ('Primer chat', 'Hola, soy Hermes'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final theme in _themes) {
    testWidgets('P2 plain list · Guía de voz · $theme', (tester) async {
      await _pump(tester, const VoiceGuideScreen(), theme);
      await _topAndScrolled(
        tester,
        'p2_guia_voz_$theme',
        find.byType(ListView),
      );
    });

    testWidgets('P3 design-system page · $theme', (tester) async {
      await _pump(
        tester,
        HermesPage(
          title: 'Ajustes',
          actions: [
            IconButton(
              tooltip: 'Buscar',
              icon: const Icon(Icons.search_rounded),
              onPressed: () {},
            ),
          ],
          children: [
            for (final (section, rows) in const [
              ('Conexión', ['Instancias', 'Perfiles']),
              ('Chat', ['Voz', 'Modelos', 'Avisos', 'Permisos']),
              ('Sistema', ['Seguridad', 'Copias de seguridad', 'Dock']),
              ('Datos', ['Memoria', 'Exportar', 'Importar sesión']),
              ('Acerca de', ['Versión', 'Licencias', 'Privacidad']),
            ]) ...[
              HermesSectionHeader(section),
              HermesListGroup(
                children: [
                  for (final row in rows)
                    HermesListRow(
                      icon: Icons.tune_rounded,
                      title: row,
                      onTap: () {},
                    ),
                ],
              ),
            ],
          ],
        ),
        theme,
      );
      await _topAndScrolled(tester, 'p3_pagina_$theme', find.byType(ListView));
    });

    testWidgets('P1 page with the dock · $theme', (tester) async {
      SharedPreferences.setMockInitialValues({});
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async =>
                call.method == 'readAll' ? <String, String>{} : null,
          );
      FeatureFlags.instance.resetToDefaultForTesting();
      GestureDockController.instance.resetForTesting(
        settings: const GestureDockSettings(),
      );
      DockGeometry.instance.resetForTesting();
      DockModes.instance.resetForTesting();
      addTearDown(FeatureFlags.instance.resetForTesting);
      await DockPreferencesController.instance.setUseDock(true);
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final colors = AppTheme.fromId(theme).hermes;
      await _pump(
        tester,
        Scaffold(
          drawer: const Drawer(),
          appBar: HermesAppBar(
            // The name alone; the connection's state is the dot beside it.
            title: const Text('Conversaciones'),
            titleBadge: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.success,
                shape: BoxShape.circle,
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'Nueva',
                icon: const Icon(Icons.add_rounded),
                onPressed: () {},
              ),
              IconButton(
                tooltip: 'Más',
                icon: const Icon(Icons.more_vert),
                onPressed: () {},
              ),
            ],
          ),
          body: GeneralDockShell(
            connection: SavedConnection(
              id: 'glass-shot',
              label: 'casa',
              host: '127.0.0.1',
              port: 8642,
              apiKey: 'test-only',
            ),
            connManager: manager,
            body: ListView(
              key: const ValueKey('glass-shot-list'),
              clipBehavior: hermesUnderHeader,
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 28),
              children: [
                for (final (title, last) in _chats)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        theme,
      );
      await _topAndScrolled(
        tester,
        'p1_dock_$theme',
        find.byKey(const ValueKey('glass-shot-list')),
        by: 200,
      );
    });

    Widget rowsOf(HermesThemeColors colors) => HermesControlsScroll.children(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      [
        for (final (title, last) in _chats)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    testWidgets('P4 controls as the first rows · $theme', (tester) async {
      final colors = AppTheme.fromId(theme).hermes;
      var category = 0;
      await _pump(
        tester,
        Scaffold(
          appBar: HermesAppBar(
            title: const Text('Conversaciones'),
            actions: [
              IconButton(
                tooltip: 'Nueva',
                icon: const Icon(Icons.add_rounded),
                onPressed: () {},
              ),
            ],
          ),
          body: StatefulBuilder(
            builder: (context, setState) => HermesControlsScroll(
              scrollKey: const ValueKey('glass-shot-scroll'),
              controls: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: HermesSearchField(
                    onChanged: (_) {},
                    hintText: 'Buscar conversaciones…',
                    clearTooltip: 'Borrar',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: HermesSegmentedControl<int>(
                    value: category,
                    onChanged: (v) => setState(() => category = v),
                    segments: const [
                      HermesSegment(value: 0, label: 'Chats'),
                      HermesSegment(value: 1, label: 'Automatización'),
                      HermesSegment(value: 2, label: 'Todo'),
                    ],
                  ),
                ),
              ],
              slivers: [rowsOf(colors)],
            ),
          ),
        ),
        theme,
      );
      await _topAndScrolled(
        tester,
        'p4_controles_$theme',
        find.byKey(const ValueKey('glass-shot-scroll')),
      );
    });

    testWidgets('P4 a floating view switch · $theme', (tester) async {
      final colors = AppTheme.fromId(theme).hermes;
      await _pump(
        tester,
        Scaffold(
          appBar: HermesAppBar(
            title: const Text('KANBAN'),
            actions: [
              IconButton(
                tooltip: 'Nueva tarea',
                icon: const Icon(Icons.add_rounded),
                onPressed: () {},
              ),
              IconButton(
                tooltip: 'Ayuda',
                icon: const Icon(Icons.help_outline_rounded),
                onPressed: () {},
              ),
              IconButton(
                tooltip: 'Actualizar',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () {},
              ),
            ],
          ),
          body: HermesStickyControls(
            controls: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: HermesSegmentedControl<int>(
                    floating: true,
                    value: 0,
                    onChanged: (_) {},
                    segments: const [
                      HermesSegment(value: 0, label: 'Lista'),
                      HermesSegment(value: 1, label: 'Tablero'),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                HermesFloatingIconButton(
                  icon: Icons.filter_alt_rounded,
                  tooltip: 'Filtrar',
                  color: colors.accent,
                  onPressed: () {},
                ),
              ],
            ),
            child: CustomScrollView(
              key: const ValueKey('glass-shot-scroll'),
              clipBehavior: hermesUnderHeader,
              slivers: [
                const SliverToBoxAdapter(
                  child: SizedBox(height: HermesStickyControls.extent),
                ),
                rowsOf(colors),
              ],
            ),
          ),
        ),
        theme,
      );
      await _topAndScrolled(
        tester,
        'p4_cambio_vista_$theme',
        find.byKey(const ValueKey('glass-shot-scroll')),
      );
    });

    testWidgets('P5 buttons at the lower edge · $theme', (tester) async {
      final colors = AppTheme.fromId(theme).hermes;
      await _pump(
        tester,
        Scaffold(
          appBar: const HermesAppBar(title: Text('Personalizar tema')),
          body: Column(
            children: [
              Expanded(
                child: HermesFadedEnd(
                  child: CustomScrollView(
                    key: const ValueKey('glass-shot-scroll'),
                    clipBehavior: hermesUnderHeader,
                    slivers: [rowsOf(colors)],
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 7, 16, 9),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {},
                        child: const Text('Guardar borrador'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {},
                        child: const Text('Guardar y activar'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        theme,
      );
      await _topAndScrolled(
        tester,
        'p5_botones_$theme',
        find.byKey(const ValueKey('glass-shot-scroll')),
      );
    });

    testWidgets('H menu, sheet and dialog · $theme', (tester) async {
      final colors = AppTheme.fromId(theme).hermes;
      late BuildContext page;
      final more = GlobalKey();
      await _pump(
        tester,
        Scaffold(
          appBar: HermesAppBar(
            title: const Text('Conversaciones'),
            actions: [
              IconButton(
                key: more,
                tooltip: 'Más',
                icon: const Icon(Icons.more_vert),
                onPressed: () {},
              ),
            ],
          ),
          body: Builder(
            builder: (context) {
              page = context;
              return CustomScrollView(
                clipBehavior: hermesUnderHeader,
                slivers: [rowsOf(colors)],
              );
            },
          ),
        ),
        theme,
      );
      Future<void> close() async {
        await tester.tapAt(const Offset(6, 880));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      showHermesMenu<int>(
        context: page,
        anchorKey: more,
        actions: const [
          HermesAction(value: 0, label: 'Actualizar', icon: Icons.refresh),
          HermesAction(value: 1, label: 'Ordenar', icon: Icons.swap_vert),
          HermesAction(
            value: 2,
            label: 'Importar sesión',
            icon: Icons.download_outlined,
          ),
          HermesAction(
            value: 3,
            label: 'Borrar',
            icon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ).ignore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'h_menu_$theme');
      await close();

      showHermesOptions<String>(
        context: page,
        title: 'Cambiar de perfil',
        selected: 'Hermes',
        options: [
          for (final name in const [
            'Hermes',
            'console-builder',
            'console-fable',
            'console-lead',
            'console-radar',
            'oficina',
          ])
            HermesOption(value: name, label: name),
        ],
      ).ignore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'h_hoja_$theme');
      await close();

      showHermesDialog<bool>(
        context: page,
        title: '¿Borrar esta conversación?',
        message: 'Se borra de este móvil y del servidor.',
        actions: const [
          HermesDialogAction(
            label: 'Cancelar',
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(
            label: 'Borrar',
            value: true,
            style: HermesDialogActionStyle.destructive,
          ),
        ],
      ).ignore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'h_dialogo_$theme');
      await close();
    });
  }
}
