// Behavioural tests for writing inside a project's Files tab, mirroring
// Hermes Desktop remote mode: new folder, new text file, edit + save a text
// file, upload from the phone and a confirmed, non-recursive delete. Read-only
// connections and older servers never get a write action.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/projects/project_files_browser.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pf1215_fake_files_gateway.dart';
import 'support/pw1215_fake_writable_files_gateway.dart';

const _root = pf1215Root;

Future<void> _enterFiles(
  WidgetTester tester,
  HermesDesktopControlGateway gateway, {
  bool readOnly = false,
  ProjectUploadPicker? picker,
}) async {
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
          id: 'pw1215',
          label: 'Hermes QA',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
          readOnly: readOnly,
        ),
        connectionManager: manager,
        gateway: gateway,
        chatLauncher: (_, _) {},
        projectUploadPicker: picker,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Hermes Console'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('pf1215-tab-files')));
  await tester.pumpAndSettle();
}

Strings _s(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(Navigator).first));

Finder _entry(String path) => find.byKey(ValueKey('pf1215-fs-entry-$path'));
const _add = ValueKey('pw1215-fs-add');
const _nameField = ValueKey('pw1215-name-field');
const _create = ValueKey('pw1215-name-create');

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _tapEntry(WidgetTester tester, String path) async {
  await tester.ensureVisible(_entry(path));
  await tester.pumpAndSettle();
  await tester.tap(_entry(path));
  await tester.pumpAndSettle();
}

Future<void> _addMenu(WidgetTester tester, String option) async {
  await _tapKey(tester, _add);
  await _tapKey(tester, ValueKey('pw1215-add-$option'));
}

Future<void> _typeName(WidgetTester tester, String name) async {
  await tester.enterText(find.byKey(_nameField), name);
  await tester.pumpAndSettle();
}

Future<void> _letNoticePass(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

Future<void> _entryMenu(WidgetTester tester, String path) =>
    _tapKey(tester, ValueKey('pw1215-fs-entry-menu-$path'));

void main() {
  testWidgets('a writable connection offers add actions and says so', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample();
    await _enterFiles(tester, gateway);
    final s = _s(tester);
    expect(find.byKey(_add), findsOneWidget);
    expect(find.text(s.pw1215FilesWritableNote), findsOneWidget);
    expect(find.text(s.pf1215FilesReadOnlyNote), findsNothing);
    await _tapKey(tester, _add);
    for (final option in ['folder', 'file', 'upload']) {
      expect(find.byKey(ValueKey('pw1215-add-$option')), findsOneWidget);
    }
  });

  testWidgets('new folder: Desktop-style name check, mkdir, enter it', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample();
    await _enterFiles(tester, gateway);
    final s = _s(tester);
    await _addMenu(tester, 'folder');

    for (final bad in ['', '   ', '.', '..', 'a/b', r'a\b', 'a\u0001b']) {
      await _typeName(tester, bad);
      await tester.tap(find.byKey(_create));
      await tester.pumpAndSettle();
      expect(find.byKey(_nameField), findsOneWidget, reason: 'kept: $bad');
    }
    expect(find.text(s.pw1215InvalidName), findsOneWidget);
    await _typeName(tester, 'lib');
    await tester.tap(find.byKey(_create));
    await tester.pumpAndSettle();
    expect(find.text(s.pw1215NameTaken), findsOneWidget);
    expect(gateway.writeCalls, isEmpty);

    await _typeName(tester, '  notas  ');
    await tester.tap(find.byKey(_create));
    await tester.pumpAndSettle();

    expect(gateway.writeCalls, ['mkdir:$_root/notas']);
    expect(find.byKey(_nameField), findsNothing);
    // Navigated into the new folder, like Desktop's picker.
    expect(find.byKey(const ValueKey('pf1215-crumb-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('pf1215-fs-empty')), findsOneWidget);
    // The parent listing was refreshed, not served stale from the cache.
    await tester.tap(find.byKey(const ValueKey('pf1215-crumb-0')));
    await tester.pumpAndSettle();
    expect(_entry('$_root/notas'), findsOneWidget);
  });

  testWidgets('new folder: a server conflict is reported honestly', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample()
      ..failNext[ProjectFileWriteAction.createFolder] =
          const DesktopControlFailure(
            DesktopControlFailureKind.rejected,
            code: 409,
          );
    await _enterFiles(tester, gateway);
    await _addMenu(tester, 'folder');
    await _typeName(tester, 'nueva');
    await tester.tap(find.byKey(_create));
    await tester.pumpAndSettle();
    expect(gateway.writeCalls, ['mkdir:$_root/nueva']);
    expect(find.text(_s(tester).pw1215NameTaken), findsOneWidget);
    expect(find.byKey(const ValueKey('pf1215-crumb-1')), findsNothing);
  });

  testWidgets('new file: refuses an existing name, creates empty, opens it', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample();
    await _enterFiles(tester, gateway);
    await _addMenu(tester, 'file');
    await _typeName(tester, 'README.md');
    await tester.tap(find.byKey(_create));
    await tester.pumpAndSettle();
    expect(find.text(_s(tester).pw1215NameTaken), findsOneWidget);
    expect(gateway.writeCalls, isEmpty);

    await _typeName(tester, 'idea.md');
    await tester.tap(find.byKey(_create));
    await tester.pumpAndSettle();
    expect(gateway.writeCalls, ['write-text:$_root/idea.md:']);
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    expect(gateway.fsCalls, contains('read-text:$_root/idea.md'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_entry('$_root/idea.md'), findsOneWidget);
  });

  testWidgets('upload: picks a phone file into the current folder', (
    tester,
  ) async {
    var picks = 0;
    ProjectUploadPick? next = const ProjectUploadPick(
      localPath: '/data/cache/photo.jpg',
      name: 'photo.jpg',
      size: 2048,
    );
    final gateway = Pw1215FakeWritableFilesGateway.sample();
    await _enterFiles(
      tester,
      gateway,
      picker: () async {
        picks++;
        return next;
      },
    );
    await _tapEntry(tester, '$_root/lib');
    await _addMenu(tester, 'upload');
    expect(gateway.writeCalls, [
      'upload:$_root/lib/photo.jpg:/data/cache/photo.jpg:photo.jpg',
    ]);
    expect(find.text(_s(tester).pw1215Uploaded), findsOneWidget);
    expect(_entry('$_root/lib/photo.jpg'), findsOneWidget);
    await _letNoticePass(tester);

    // Same name again: refused before the wire (the server never overwrites).
    await _addMenu(tester, 'upload');
    expect(gateway.writeCalls, hasLength(1));
    expect(find.text(_s(tester).pw1215NameTaken), findsOneWidget);
    await _letNoticePass(tester);

    // Over the server's 100 MB cap: refused before the wire.
    next = const ProjectUploadPick(
      localPath: '/data/cache/big.zip',
      name: 'big.zip',
      size: 100 * 1024 * 1024 + 1,
    );
    await _addMenu(tester, 'upload');
    expect(gateway.writeCalls, hasLength(1));
    expect(find.text(_s(tester).pw1215UploadTooLarge), findsOneWidget);

    // Cancelling the picker sends nothing.
    next = null;
    await _addMenu(tester, 'upload');
    expect(picks, 4);
    expect(gateway.writeCalls, hasLength(1));
  });

  testWidgets('delete: confirmed, non-recursive, row disappears', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample();
    await _enterFiles(tester, gateway);
    final s = _s(tester);
    await _entryMenu(tester, '$_root/AGENTS.md');
    await _tapKey(tester, const ValueKey('pw1215-entry-delete'));
    expect(find.text(s.pw1215DeleteTitle('AGENTS.md')), findsOneWidget);
    await tester.tap(find.text(s.commonCancel));
    await tester.pumpAndSettle();
    expect(gateway.writeCalls, isEmpty);

    await _entryMenu(tester, '$_root/AGENTS.md');
    await _tapKey(tester, const ValueKey('pw1215-entry-delete'));
    await _tapKey(tester, const ValueKey('pw1215-delete-confirm'));
    expect(gateway.writeCalls, ['delete:$_root/AGENTS.md']);
    expect(_entry('$_root/AGENTS.md'), findsNothing);
    expect(find.text(s.pw1215Deleted), findsOneWidget);
  });

  testWidgets('delete: a non-empty folder is refused with guidance', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample()
      ..failNext[ProjectFileWriteAction.delete] = const DesktopControlFailure(
        DesktopControlFailureKind.rejected,
        code: 409,
      );
    await _enterFiles(tester, gateway);
    await _entryMenu(tester, '$_root/lib');
    expect(
      find.text(_s(tester).pw1215DeleteFolderBody),
      findsNothing,
      reason: 'body only in the confirmation',
    );
    await _tapKey(tester, const ValueKey('pw1215-entry-delete'));
    expect(find.text(_s(tester).pw1215DeleteFolderBody), findsOneWidget);
    await _tapKey(tester, const ValueKey('pw1215-delete-confirm'));
    expect(gateway.writeCalls, ['delete:$_root/lib']);
    expect(find.text(_s(tester).pw1215FolderNotEmpty), findsOneWidget);
    expect(_entry('$_root/lib'), findsOneWidget);
  });

  testWidgets('403 says the folder does not allow it', (tester) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample()
      ..failNext[ProjectFileWriteAction.createFolder] =
          const DesktopControlFailure(
            DesktopControlFailureKind.forbidden,
            code: 403,
          );
    await _enterFiles(tester, gateway);
    await _addMenu(tester, 'folder');
    await _typeName(tester, 'x');
    await tester.tap(find.byKey(_create));
    await tester.pumpAndSettle();
    expect(find.text(_s(tester).pw1215NotAllowed), findsOneWidget);
  });

  testWidgets('a read-only connection gets no write action at all', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample();
    await _enterFiles(tester, gateway, readOnly: true);
    expect(find.byKey(_add), findsNothing);
    expect(
      find.byKey(ValueKey('pw1215-fs-entry-menu-$_root/AGENTS.md')),
      findsNothing,
    );
    expect(find.text(_s(tester).pw1215FilesReadOnlyConnection), findsOneWidget);
    expect(gateway.writeCalls, isEmpty);
  });

  testWidgets('routes the server lacks are hidden one by one', (tester) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample()
      ..unsupported.addAll({
        ProjectFileWriteAction.createFolder,
        ProjectFileWriteAction.delete,
      });
    await _enterFiles(tester, gateway);
    await _tapKey(tester, _add);
    expect(find.byKey(const ValueKey('pw1215-add-folder')), findsNothing);
    expect(find.byKey(const ValueKey('pw1215-add-file')), findsOneWidget);
    expect(find.byKey(const ValueKey('pw1215-add-upload')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('pw1215-fs-entry-menu-$_root/AGENTS.md')),
      findsNothing,
    );
  });

  testWidgets('a 404 on a write hides that action from then on', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample()
      ..failNext[ProjectFileWriteAction.createFolder] =
          const DesktopControlFailure(
            DesktopControlFailureKind.unsupported,
            code: 404,
          );
    await _enterFiles(tester, gateway);
    await _addMenu(tester, 'folder');
    await _typeName(tester, 'x');
    await tester.tap(find.byKey(_create));
    await tester.pumpAndSettle();
    expect(find.text(_s(tester).pw1215ActionUnsupported), findsOneWidget);
    await _tapKey(tester, _add);
    expect(find.byKey(const ValueKey('pw1215-add-folder')), findsNothing);
  });

  testWidgets('no write route at all keeps the old read-only browser', (
    tester,
  ) async {
    final gateway = Pw1215FakeWritableFilesGateway.sample()
      ..unsupported.addAll(ProjectFileWriteAction.values);
    await _enterFiles(tester, gateway);
    expect(find.byKey(_add), findsNothing);
    expect(find.text(_s(tester).pf1215FilesReadOnlyNote), findsOneWidget);
  });

  testWidgets('a gateway without writes stays read-only', (tester) async {
    await _enterFiles(tester, Pf1215FakeFilesGateway.sample());
    expect(find.byKey(_add), findsNothing);
    expect(find.text(_s(tester).pf1215FilesReadOnlyNote), findsOneWidget);
  });
}
