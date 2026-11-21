// 1.4.3: Files without an SSH profile reads the conversation's folder
// through the server's own `/api/fs`, as Hermes Desktop's Files pane
// (`apps/desktop/src/app/contrib/panes.tsx`, `FilesPane`); with a profile
// it stays SFTP.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/list.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/core/widgets/workspace/workspace_files_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/pf1215_fake_files_gateway.dart';

const _root = pf1215Root;

Finder _entry(String path) => find.byKey(ValueKey('pf1215-fs-entry-$path'));

Future<void> _pump(
  WidgetTester tester,
  Pf1215FakeFilesGateway gateway, {
  String root = _root,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(412, 915);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: ChatWorkspacePaneScope(
          tab: ChatWorkspaceTab.files,
          child: ChatWorkspaceServerFiles(files: gateway, root: root),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the source of the Files panel', () {
    final files = Pf1215FakeFilesGateway();

    test('with an SSH profile, or before it is known: SFTP', () {
      for (final folder in [null, '', _root]) {
        expect(
          chatFilesSource(withoutSsh: false, files: files, folder: folder),
          ChatFilesSource.sftp,
        );
      }
    });

    test('without one: the server\'s folder routes at the chat\'s folder', () {
      expect(
        chatFilesSource(withoutSsh: true, files: files, folder: _root),
        ChatFilesSource.server,
      );
    });

    test('without one and nothing the server can list: none', () {
      expect(
        chatFilesSource(withoutSsh: true, files: null, folder: _root),
        ChatFilesSource.none,
      );
      for (final folder in [null, '', '  ']) {
        expect(
          chatFilesSource(withoutSsh: true, files: files, folder: folder),
          ChatFilesSource.none,
          reason: 'folder «$folder»',
        );
      }
      final old = Pf1215FakeFilesGateway()..knownUnsupported = true;
      expect(
        chatFilesSource(withoutSsh: true, files: old, folder: _root),
        ChatFilesSource.none,
        reason: 'an older Hermes answered 404 to /api/fs/list',
      );
    });
  });

  testWidgets('lists the chat\'s folder through /api/fs, enters a folder '
      'and opens a file in the existing viewer', (tester) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _pump(tester, gateway);
    expect(gateway.fsCalls.first, 'list:$_root');
    expect(_entry('$_root/lib'), findsOneWidget);
    expect(_entry('$_root/README.md'), findsOneWidget);
    final rows = tester.widget<HermesListGroup>(find.byType(HermesListGroup));
    expect(rows.showSurface, isFalse);

    await tester.tap(_entry('$_root/lib'));
    await tester.pumpAndSettle();
    expect(gateway.fsCalls, contains('list:$_root/lib'));
    expect(_entry('$_root/lib/main.dart'), findsOneWidget);

    await tester.tap(_entry('$_root/lib/main.dart'));
    await tester.pumpAndSettle();
    expect(gateway.fsCalls.last, 'read-text:$_root/lib/main.dart');
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('never leaves the chat\'s folder', (tester) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _pump(tester, gateway, root: '$_root/lib');
    expect(gateway.fsCalls, ['list:$_root/lib']);
    expect(_entry('$_root/README.md'), findsNothing);
    expect(_entry('$_root/lib/main.dart'), findsOneWidget);
  });

  testWidgets('an older Hermes without /api/fs says so instead of a list', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample()..knownUnsupported = true;
    await _pump(tester, gateway);
    expect(
      find.byKey(const ValueKey('pf1215-fs-unsupported')),
      findsOneWidget,
    );
    expect(gateway.fsCalls, isEmpty);
  });
}
