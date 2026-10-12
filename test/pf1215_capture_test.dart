// Visual evidence for the project file browser (412x915, es, dark + light).
// Writes PNGs only when PF1215_SHOTS_DIR is set; otherwise a layout smoke
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
import 'support/pf1215_fake_files_gateway.dart';

const _shotKey = ValueKey('pf1215-shot');

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  HermesDesktopControlGateway gateway,
) async {
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
                id: 'pf1215-shots',
                label: 'Hermes QA',
                host: '127.0.0.1',
                port: 8642,
                apiKey: 'k',
              ),
              connectionManager: manager,
              gateway: gateway,
              chatLauncher: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Hermes Console'));
  await tester.pumpAndSettle();
}

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
  final dir = Platform.environment['PF1215_SHOTS_DIR'];
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

Future<void> _files(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('pf1215-tab-files')));
  await tester.pumpAndSettle();
}

void main() {
  for (final (themeName, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$themeName: project chats', (tester) async {
      await _pump(tester, theme, Pf1215FakeFilesGateway.sample());
      await _save(tester, 'project-chats-$themeName');
    });

    testWidgets('$themeName: project files root', (tester) async {
      await _pump(tester, theme, Pf1215FakeFilesGateway.sample());
      await _files(tester);
      await _save(tester, 'project-files-$themeName');
    });

    testWidgets('$themeName: project subfolder', (tester) async {
      await _pump(tester, theme, Pf1215FakeFilesGateway.sample());
      await _files(tester);
      await tester.tap(
        find.byKey(const ValueKey('pf1215-fs-entry-$pf1215Root/lib')),
      );
      await tester.pumpAndSettle();
      await _save(tester, 'project-subfolder-$themeName');
    });

    testWidgets('$themeName: file preview', (tester) async {
      await _pump(tester, theme, Pf1215FakeFilesGateway.sample());
      await _files(tester);
      await tester.tap(
        find.byKey(const ValueKey('pf1215-fs-entry-$pf1215Root/lib')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('pf1215-fs-entry-$pf1215Root/lib/main.dart')),
      );
      await tester.pumpAndSettle();
      await _save(tester, 'file-preview-$themeName');
    });

    testWidgets('$themeName: older Hermes gate', (tester) async {
      final gateway = Pf1215FakeFilesGateway.sample()..knownUnsupported = true;
      await _pump(tester, theme, gateway);
      await _files(tester);
      await _save(tester, 'files-unsupported-$themeName');
    });
  }
}
