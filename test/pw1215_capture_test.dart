// Visual evidence for writing in a project's files (412x915, es, dark +
// light). Writes PNGs only when PW1215_SHOTS_DIR is set; otherwise a layout
// smoke test. Fixtures are synthetic.
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
import 'support/pw1215_fake_writable_files_gateway.dart';

const _shotKey = ValueKey('pw1215-shot');

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  HermesDesktopControlGateway gateway, {
  bool readOnly = false,
}) async {
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
                id: 'pw1215-shots',
                label: 'Hermes QA',
                host: '127.0.0.1',
                port: 8642,
                apiKey: 'k',
                readOnly: readOnly,
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
  final dir = Platform.environment['PW1215_SHOTS_DIR'];
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

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _settleNotice(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  for (final (themeName, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$themeName: writable files', (tester) async {
      await _pump(tester, theme, Pw1215FakeWritableFilesGateway.sample());
      await _files(tester);
      await _save(tester, 'files-writable-$themeName');
    });

    testWidgets('$themeName: add menu', (tester) async {
      await _pump(tester, theme, Pw1215FakeWritableFilesGateway.sample());
      await _files(tester);
      await _tap(tester, const ValueKey('pw1215-fs-add'));
      await _save(tester, 'add-menu-$themeName');
    });

    testWidgets('$themeName: new folder name', (tester) async {
      await _pump(tester, theme, Pw1215FakeWritableFilesGateway.sample());
      await _files(tester);
      await _tap(tester, const ValueKey('pw1215-fs-add'));
      await _tap(tester, const ValueKey('pw1215-add-folder'));
      await tester.enterText(
        find.byKey(const ValueKey('pw1215-name-field')),
        'a/b',
      );
      await tester.pumpAndSettle();
      await _save(tester, 'new-folder-invalid-$themeName');
    });

    testWidgets('$themeName: entry menu and delete', (tester) async {
      await _pump(tester, theme, Pw1215FakeWritableFilesGateway.sample());
      await _files(tester);
      await _tap(
        tester,
        const ValueKey('pw1215-fs-entry-menu-$pf1215Root/AGENTS.md'),
      );
      await _save(tester, 'entry-menu-$themeName');
      await _tap(tester, const ValueKey('pw1215-entry-delete'));
      await _save(tester, 'delete-confirm-$themeName');
    });

    testWidgets('$themeName: editor', (tester) async {
      await _pump(tester, theme, Pw1215FakeWritableFilesGateway.sample());
      await _files(tester);
      await _tap(tester, const ValueKey('pf1215-fs-entry-$pf1215Root/lib'));
      await _tap(
        tester,
        const ValueKey('pf1215-fs-entry-$pf1215Root/lib/main.dart'),
      );
      await _save(tester, 'preview-edit-action-$themeName');
      await _tap(tester, const ValueKey('artifact-viewer-edit'));
      await tester.enterText(
        find.byKey(const ValueKey('pw1215-editor-field')),
        'void main() {\n  runApp(const HermesApp());\n}\n',
      );
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _save(tester, 'editor-dirty-$themeName');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _save(tester, 'editor-discard-$themeName');
    });

    testWidgets('$themeName: read-only connection', (tester) async {
      await _pump(
        tester,
        theme,
        Pw1215FakeWritableFilesGateway.sample(),
        readOnly: true,
      );
      await _files(tester);
      await _save(tester, 'files-read-only-$themeName');
    });

    testWidgets('$themeName: folder created', (tester) async {
      await _pump(tester, theme, Pw1215FakeWritableFilesGateway.sample());
      await _files(tester);
      await _tap(tester, const ValueKey('pw1215-fs-add'));
      await _tap(tester, const ValueKey('pw1215-add-folder'));
      await tester.enterText(
        find.byKey(const ValueKey('pw1215-name-field')),
        'notas',
      );
      await tester.pumpAndSettle();
      await _tap(tester, const ValueKey('pw1215-name-create'));
      await _save(tester, 'folder-created-$themeName');
      await _settleNotice(tester);
    });
  }
}
