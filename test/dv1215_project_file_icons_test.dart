// File-type icons in Projects › Files: one const mapping by name/extension,
// unknown names keep the generic file icon, folders keep the folder icon.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/projects/project_file_icons.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pf1215_fake_files_gateway.dart';
import 'package:hermes_android/core/design/hicons.dart';

void main() {
  const cases = <String, IconData>{
    // Code.
    'main.dart': HIcons.code_rounded,
    'app.py': HIcons.code_rounded,
    'index.js': HIcons.code_rounded,
    'view.tsx': HIcons.code_rounded,
    'types.ts': HIcons.code_rounded,
    'MainActivity.kt': HIcons.code_rounded,
    'Main.java': HIcons.code_rounded,
    'server.go': HIcons.code_rounded,
    'lib.rs': HIcons.code_rounded,
    'main.c': HIcons.code_rounded,
    'engine.cpp': HIcons.code_rounded,
    'BUILD.SH': HIcons.terminal_rounded,
    'deploy.sh': HIcons.terminal_rounded,
    // Data.
    'package.json': HIcons.data_object_rounded,
    'pubspec.yaml': HIcons.data_object_rounded,
    'ci.yml': HIcons.data_object_rounded,
    'Cargo.toml': HIcons.data_object_rounded,
    'AndroidManifest.xml': HIcons.data_object_rounded,
    'rows.csv': HIcons.table_chart_outlined,
    // Docs.
    'README.md': HIcons.description_outlined,
    'notes.txt': HIcons.description_outlined,
    'paper.pdf': HIcons.picture_as_pdf_outlined,
    // Images.
    'logo.png': HIcons.image_outlined,
    'photo.JPEG': HIcons.image_outlined,
    'icon.svg': HIcons.image_outlined,
    // Archives, including multi-part extensions.
    'release.zip': HIcons.folder_zip_outlined,
    'backup.tar.gz': HIcons.folder_zip_outlined,
    // Config and dotfiles.
    '.gitignore': HIcons.settings_outlined,
    '.env': HIcons.settings_outlined,
    '.env.local': HIcons.settings_outlined,
    'Dockerfile': HIcons.settings_outlined,
    'Makefile': HIcons.settings_outlined,
    'setup.cfg': HIcons.settings_outlined,
    // Lockfiles win over their data extension.
    'pubspec.lock': HIcons.lock_outline_rounded,
    'package-lock.json': HIcons.lock_outline_rounded,
    'yarn.lock': HIcons.lock_outline_rounded,
    // Unknown → generic.
    'app.keystore': HIcons.insert_drive_file_outlined,
    'LICENSE': HIcons.insert_drive_file_outlined,
    'archive.': HIcons.insert_drive_file_outlined,
    '': HIcons.insert_drive_file_outlined,
  };

  for (final entry in cases.entries) {
    test('icon for "${entry.key}"', () {
      expect(projectFileIcon(entry.key), entry.value);
    });
  }

  test('unknown names fall back to the generic file icon', () {
    expect(projectFileGenericIcon, HIcons.insert_drive_file_outlined);
    expect(projectFileIcon('weird.qqq'), projectFileGenericIcon);
  });

  testWidgets('file rows use the type icon, folders and labels unchanged', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: ProjectsCenterScreen(
          connection: SavedConnection(
            id: 'dv1215',
            label: 'Hermes QA',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'k',
          ),
          connectionManager: manager,
          gateway: Pf1215FakeFilesGateway.sample(),
          chatLauncher: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hermes Console'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pf1215-tab-files')));
    await tester.pumpAndSettle();

    Icon iconOf(String name) => tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(ValueKey('pf1215-fs-entry-$pf1215Root/$name')),
            matching: find.byType(Icon),
          )
          .first,
    );

    expect(iconOf('android').icon, HIcons.folder_rounded);
    expect(iconOf('README.md').icon, HIcons.description_outlined);
    expect(iconOf('pubspec.yaml').icon, HIcons.data_object_rounded);
    expect(iconOf('.gitignore').icon, HIcons.settings_outlined);
    expect(iconOf('app.keystore').icon, HIcons.insert_drive_file_outlined);
    // Icons stay decorative: the row is announced by its name only.
    expect(iconOf('README.md').semanticLabel, isNull);
  });
}
