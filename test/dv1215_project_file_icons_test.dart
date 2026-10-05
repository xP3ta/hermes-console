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

void main() {
  const cases = <String, IconData>{
    // Code.
    'main.dart': Icons.code_rounded,
    'app.py': Icons.code_rounded,
    'index.js': Icons.code_rounded,
    'view.tsx': Icons.code_rounded,
    'types.ts': Icons.code_rounded,
    'MainActivity.kt': Icons.code_rounded,
    'Main.java': Icons.code_rounded,
    'server.go': Icons.code_rounded,
    'lib.rs': Icons.code_rounded,
    'main.c': Icons.code_rounded,
    'engine.cpp': Icons.code_rounded,
    'BUILD.SH': Icons.terminal_rounded,
    'deploy.sh': Icons.terminal_rounded,
    // Data.
    'package.json': Icons.data_object_rounded,
    'pubspec.yaml': Icons.data_object_rounded,
    'ci.yml': Icons.data_object_rounded,
    'Cargo.toml': Icons.data_object_rounded,
    'AndroidManifest.xml': Icons.data_object_rounded,
    'rows.csv': Icons.table_chart_outlined,
    // Docs.
    'README.md': Icons.description_outlined,
    'notes.txt': Icons.description_outlined,
    'paper.pdf': Icons.picture_as_pdf_outlined,
    // Images.
    'logo.png': Icons.image_outlined,
    'photo.JPEG': Icons.image_outlined,
    'icon.svg': Icons.image_outlined,
    // Archives, including multi-part extensions.
    'release.zip': Icons.folder_zip_outlined,
    'backup.tar.gz': Icons.folder_zip_outlined,
    // Config and dotfiles.
    '.gitignore': Icons.settings_outlined,
    '.env': Icons.settings_outlined,
    '.env.local': Icons.settings_outlined,
    'Dockerfile': Icons.settings_outlined,
    'Makefile': Icons.settings_outlined,
    'setup.cfg': Icons.settings_outlined,
    // Lockfiles win over their data extension.
    'pubspec.lock': Icons.lock_outline_rounded,
    'package-lock.json': Icons.lock_outline_rounded,
    'yarn.lock': Icons.lock_outline_rounded,
    // Unknown → generic.
    'app.keystore': Icons.insert_drive_file_outlined,
    'LICENSE': Icons.insert_drive_file_outlined,
    'archive.': Icons.insert_drive_file_outlined,
    '': Icons.insert_drive_file_outlined,
  };

  for (final entry in cases.entries) {
    test('icon for "${entry.key}"', () {
      expect(projectFileIcon(entry.key), entry.value);
    });
  }

  test('unknown names fall back to the generic file icon', () {
    expect(projectFileGenericIcon, Icons.insert_drive_file_outlined);
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

    expect(iconOf('android').icon, Icons.folder_rounded);
    expect(iconOf('README.md').icon, Icons.description_outlined);
    expect(iconOf('pubspec.yaml').icon, Icons.data_object_rounded);
    expect(iconOf('.gitignore').icon, Icons.settings_outlined);
    expect(iconOf('app.keystore').icon, Icons.insert_drive_file_outlined);
    // Icons stay decorative: the row is announced by its name only.
    expect(iconOf('README.md').semanticLabel, isNull);
  });
}
