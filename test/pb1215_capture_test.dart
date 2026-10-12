// Visual evidence for the folder-style Projects browser (412x915, es, dark
// + light). Writes PNGs only when PB1215_SHOTS_DIR is set; otherwise a
// layout smoke test. Fixtures are synthetic.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart' show loadDesignFonts;
import 'support/pj1215_fake_projects_gateway.dart';

const _shotKey = ValueKey('pb1215-shot');

double _ago(Duration d) =>
    DateTime.now().subtract(d).millisecondsSinceEpoch / 1000;

/// A fuller tree than the behaviour fixture: several folders and a big
/// "Otros chats" bucket, as on a real phone.
Pc1215CreatingProjectsGateway _gateway() {
  final json = pj1215SampleTreeJson();
  final projects = <Map<String, dynamic>>[
    for (final project in json['projects'] as List)
      Map<String, dynamic>.from(project as Map),
  ];
  json['projects'] = projects;
  final home = projects.removeAt(3)
    ..['sessionCount'] = 114
    ..['previewSessions'] = [
      {'id': 'h1', 'title': 'Receta de pan de centeno'},
    ];
  projects.addAll([
    {
      'id': 'p_garden',
      'label': 'Huerto',
      'path': '/home/demo/garden',
      'icon': 'lightbulb',
      'sessionCount': 0,
      'repos': [],
    },
    {
      'id': 'p_site',
      'label': 'Web personal',
      'path': '/home/demo/code/site',
      'sessionCount': 12,
      'lastActive': _ago(const Duration(days: 9)),
      'repos': [],
    },
    home,
  ]);
  final gateway = Pc1215CreatingProjectsGateway(
    tree: ProjectTreeSnapshot.fromJson(json),
  );
  final detail = pj1215ConsoleDetailJson();
  final lanes =
      ((detail['repos'] as List).first as Map<String, dynamic>)['groups']
          as List;
  final main = lanes.first as Map<String, dynamic>;
  main['sessions'] = [
    for (final session in main['sessions'] as List)
      {
        ...(session as Map<String, dynamic>),
        'preview': 'Revisa el cambio y dime si se puede subir hoy',
      },
  ];
  lanes.add({
    'id': '/home/demo/code/hermes-console/.worktrees',
    'label': 'kanban',
    'path': '/home/demo/code/hermes-console/.worktrees',
    'isKanban': true,
    'sessions': [
      {'id': 'k0', 'title': 'Tarea: icono de la app'},
    ],
  });
  gateway.details['p_console'] = ProjectNode.tryParse(detail)!;
  return gateway;
}

Future<void> _pump(WidgetTester tester, ThemeData theme) async {
  await loadDesignFonts();
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: _withTileFont(theme),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: ProjectsCenterScreen(
              connection: SavedConnection(
                id: 'pb1215-shots',
                label: 'Hermes QA',
                host: '127.0.0.1',
                port: 8642,
                apiKey: 'k',
              ),
              connectionManager: manager,
              gateway: _gateway(),
              chatLauncher: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(GestureDock), findsOneWidget);
}

// The app's ListTile styles carry no font family (the device falls back to
// its system font); the test engine would draw placeholder boxes.
ThemeData _withTileFont(ThemeData theme) => theme.copyWith(
  listTileTheme: theme.listTileTheme.copyWith(
    titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
      fontFamily: 'Inter',
    ),
    subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(
      fontFamily: 'Inter',
    ),
  ),
);

Future<void> _save(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final dir = Platform.environment['PB1215_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  setUp(PrivateRenderCaches.clearAll);
  // The unified gesture dock (default since QA 9495), Proyectos selected.
  setUp(() {
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(),
    );
    DockGeometry.instance.resetForTesting();
    DockModes.instance.resetForTesting();
  });
  tearDown(() {
    FeatureFlags.instance.resetForTesting();
  });

  for (final (themeName, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$themeName: root', (tester) async {
      await _pump(tester, theme);
      await _save(tester, 'root-$themeName');
    });

    testWidgets('$themeName: project folder', (tester) async {
      await _pump(tester, theme);
      await tester.tap(find.byKey(const ValueKey('pj1215-card-p_console')));
      await tester.pumpAndSettle();
      await _save(tester, 'project-$themeName');
    });

    testWidgets('$themeName: subfolder', (tester) async {
      await _pump(tester, theme);
      await tester.tap(find.byKey(const ValueKey('pj1215-card-p_console')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey(
            'pb1215-subfolder-/home/demo/code/hermes-console-wt/projects',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _save(tester, 'subfolder-$themeName');
    });

    testWidgets('$themeName: search', (tester) async {
      await _pump(tester, theme);
      await tester.enterText(find.byKey(const ValueKey('pb1215-search')), 're');
      await tester.pumpAndSettle();
      await _save(tester, 'search-$themeName');
    });

    testWidgets('$themeName: empty folder', (tester) async {
      await _pump(tester, theme);
      await tester.tap(find.byKey(const ValueKey('pj1215-card-p_garden')));
      await tester.pumpAndSettle();
      await _save(tester, 'empty-folder-$themeName');
    });

    testWidgets('$themeName: long-press menu', (tester) async {
      await _pump(tester, theme);
      await tester.longPress(
        find.byKey(const ValueKey('pj1215-card-p_console')),
      );
      await tester.pumpAndSettle();
      await _save(tester, 'menu-$themeName');
    });
  }
}
