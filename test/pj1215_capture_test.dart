// Visual evidence for the Projects center (412x915, es, dark + light).
// Writes PNGs only when PJ1215_SHOTS_DIR is set; otherwise a layout smoke
// test. Fixtures are synthetic.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart' show loadDesignFonts;
import 'support/pj1215_fake_projects_gateway.dart';

const _shotKey = ValueKey('pj1215-shot');

final _connection = SavedConnection(
  id: 'pj1215-shots',
  label: 'Hermes QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
);

Future<void> _pump(WidgetTester tester, ThemeData theme, Widget home) async {
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
            child: home is ProjectsCenterScreen
                ? ProjectsCenterScreen(
                    connection: _connection,
                    connectionManager: manager,
                    gateway: home.gateway,
                  )
                : home,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// The app's ListTile theme styles carry no font family (the device falls
// back to its system font); the test engine would draw placeholder boxes.
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
  final dir = Platform.environment['PJ1215_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

ProjectsCenterScreen _screen(HermesDesktopControlGateway gateway) =>
    ProjectsCenterScreen(
      connection: _connection,
      connectionManager: _placeholderManager,
      gateway: gateway,
    );

// Replaced in [_pump] by a real manager; only the gateway is read from here.
late ConnectionManager _placeholderManager;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _placeholderManager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
  });

  for (final (themeName, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$themeName: projects list', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await _save(tester, 'list-$themeName');
    });

    testWidgets('$themeName: entered project', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(find.text('Hermes Console'));
      await tester.pumpAndSettle();
      await _save(tester, 'entered-$themeName');
    });

    testWidgets('$themeName: project menu', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(
        find.byKey(const ValueKey('pj1215-card-menu-p_console')),
      );
      await tester.pumpAndSettle();
      await _save(tester, 'menu-$themeName');
    });

    testWidgets('$themeName: new worktree sheet', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(
        find.byKey(const ValueKey('pj1215-card-menu-p_console')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pj1215-menu-new-worktree')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pj1215-worktree-name')),
        'arreglar-login',
      );
      await tester.pumpAndSettle();
      await _save(tester, 'worktree-$themeName');

      await tester.tap(find.byKey(const ValueKey('pj1215-worktree-base')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-option-surface')), findsOne);
      await _save(tester, 'worktree-base-$themeName');
    });

    testWidgets('$themeName: rename dialog', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(
        find.byKey(const ValueKey('pj1215-card-menu-p_console')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pj1215-menu-rename')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pj1215-rename-field')), findsOne);
      await _save(tester, 'rename-$themeName');
    });

    testWidgets('$themeName: delete confirmation', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(find.byKey(const ValueKey('pj1215-card-menu-p_notes')));
      await tester.pumpAndSettle();
      final delete = find.byKey(const ValueKey('pj1215-menu-delete'));
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pj1215-delete-confirm')), findsOne);
      await _save(tester, 'delete-$themeName');
    });

    testWidgets('$themeName: open branch sheet', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(
        find.byKey(const ValueKey('pj1215-card-menu-p_console')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pj1215-menu-open-branch')));
      await tester.pumpAndSettle();
      await _save(tester, 'open-branch-$themeName');
    });

    testWidgets('$themeName: appearance sheet', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(
        find.byKey(const ValueKey('pj1215-card-menu-p_console')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pj1215-menu-appearance')));
      await tester.pumpAndSettle();
      await _save(tester, 'appearance-$themeName');
    });

    testWidgets('$themeName: explainer', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(find.byKey(const ValueKey('pj1215-help')));
      await tester.pumpAndSettle();
      await _save(tester, 'explainer-$themeName');
    });

    testWidgets('$themeName: older Hermes menu (read-only gateway)', (
      tester,
    ) async {
      final gateway = Pj1215ReadOnlyProjectsGateway.sample();
      await _pump(tester, theme, _screen(gateway));
      await tester.tap(
        find.byKey(const ValueKey('pj1215-card-menu-p_console')),
      );
      await tester.pumpAndSettle();
      await _save(tester, 'menu-older-hermes-$themeName');
    });

    testWidgets('$themeName: empty', (tester) async {
      final gateway = Pj1215ReadOnlyProjectsGateway();
      await _pump(tester, theme, _screen(gateway));
      await _save(tester, 'empty-$themeName');
    });
  }
}
