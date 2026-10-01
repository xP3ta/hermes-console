// Behavioural tests for the read-only project file browser inside an entered
// project: listing, folder navigation (tap, breadcrumbs, back), opening a
// file in the artifact viewer, server errors and the honest capability gate.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pf1215_fake_files_gateway.dart';
import 'support/pj1215_fake_projects_gateway.dart';

const _root = pf1215Root;

Future<List<ProjectChatRequest>> _enterProject(
  WidgetTester tester,
  HermesDesktopControlGateway gateway, {
  String project = 'Hermes Console',
}) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final launched = <ProjectChatRequest>[];
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
          id: 'pf1215',
          label: 'Hermes QA',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
        ),
        connectionManager: manager,
        gateway: gateway,
        chatLauncher: (_, request) => launched.add(request),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(project));
  await tester.pumpAndSettle();
  return launched;
}

Future<void> _openFiles(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('pf1215-tab-files')));
  await tester.pumpAndSettle();
}

Finder _entry(String path) => find.byKey(ValueKey('pf1215-fs-entry-$path'));

Future<void> _tapEntry(WidgetTester tester, String path) async {
  await tester.ensureVisible(_entry(path));
  await tester.pumpAndSettle();
  await tester.tap(_entry(path));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the project screen offers its folders next to its chats', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);

    expect(find.byKey(const ValueKey('pf1215-tab-chats')), findsOneWidget);
    expect(find.byKey(const ValueKey('pf1215-tab-files')), findsOneWidget);
    expect(gateway.fsCalls, isEmpty, reason: 'listing is lazy');

    await _openFiles(tester);

    expect(gateway.fsCalls, ['list:$_root']);
    for (final name in [
      'android',
      'lib',
      'test',
      'README.md',
      'pubspec.yaml',
    ]) {
      expect(_entry('$_root/$name'), findsOneWidget, reason: name);
    }
    // Sessions are not shown on the files tab.
    expect(find.text('Arreglar notificaciones'), findsNothing);
  });

  testWidgets('folders are entered by tap and left by breadcrumbs or back', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);

    await _tapEntry(tester, '$_root/lib');
    expect(_entry('$_root/lib/main.dart'), findsOneWidget);
    expect(_entry('$_root/README.md'), findsNothing);
    await _tapEntry(tester, '$_root/lib/core');
    await _tapEntry(tester, '$_root/lib/core/screens');
    expect(find.byKey(const ValueKey('pf1215-fs-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('pf1215-crumb-3')), findsOneWidget);

    // Breadcrumb jumps straight back to lib.
    await tester.tap(find.byKey(const ValueKey('pf1215-crumb-1')));
    await tester.pumpAndSettle();
    expect(_entry('$_root/lib/main.dart'), findsOneWidget);
    expect(find.byKey(const ValueKey('pf1215-crumb-2')), findsNothing);

    // System back goes up one folder before leaving the project.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_entry('$_root/README.md'), findsOneWidget);
    expect(find.byKey(const ValueKey('pf1215-tab-files')), findsOneWidget);

    // Already-read folders are not fetched again.
    expect(gateway.fsCalls.where((c) => c == 'list:$_root/lib'), hasLength(1));
  });

  testWidgets('switching to chats and back keeps the folder you were in', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    await _tapEntry(tester, '$_root/lib');
    await tester.tap(find.byKey(const ValueKey('pf1215-tab-chats')));
    await tester.pumpAndSettle();
    expect(find.text('Arreglar notificaciones'), findsOneWidget);
    await _openFiles(tester);
    expect(_entry('$_root/lib/main.dart'), findsOneWidget);
  });

  testWidgets('a text file opens in the artifact viewer', (tester) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    await _tapEntry(tester, '$_root/lib');
    await _tapEntry(tester, '$_root/lib/main.dart');

    expect(gateway.fsCalls, contains('read-text:$_root/lib/main.dart'));
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    expect(find.textContaining('runApp(const HermesApp())'), findsOneWidget);
  });

  testWidgets('a server-truncated preview says it is partial', (tester) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    await _tapEntry(tester, '$_root/README.md');
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    expect(
      find.text(Strings.of(_ctx(tester)).pf1215PreviewTruncated),
      findsOne,
    );
  });

  testWidgets('an image is read as bytes and shown in the viewer', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    await _tapEntry(tester, '$_root/assets');
    await _tapEntry(tester, '$_root/assets/logo.png');
    expect(gateway.fsCalls, contains('read-data-url:$_root/assets/logo.png'));
    expect(gateway.fsCalls.any((c) => c.startsWith('read-text')), isFalse);
    expect(find.byKey(const ValueKey('artifact-viewer-image')), findsOneWidget);
  });

  testWidgets('a binary file shows its path with a copy action instead', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    await _tapEntry(tester, '$_root/app.keystore');

    expect(find.byType(ArtifactViewerScreen), findsNothing);
    expect(find.byKey(const ValueKey('pf1215-file-info')), findsOneWidget);
    expect(find.text('$_root/app.keystore'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pf1215-file-copy-path')));
    await tester.pumpAndSettle();
    expect(copied, '$_root/app.keystore');
  });

  testWidgets('a file that cannot be read is reported, nothing opens', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample()
      ..readFailure = const DesktopControlFailure(
        DesktopControlFailureKind.forbidden,
        code: 403,
      );
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    await _tapEntry(tester, '$_root/pubspec.yaml');
    expect(find.byType(ArtifactViewerScreen), findsNothing);
    expect(
      find.text(Strings.of(_ctx(tester)).pf1215FileReadFailed),
      findsOneWidget,
    );
  });

  testWidgets('a folder the server cannot read says why', (tester) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    await _tapEntry(tester, '$_root/docs');
    expect(find.byKey(const ValueKey('pf1215-fs-error')), findsOneWidget);
    expect(
      find.text(Strings.of(_ctx(tester)).pf1215FolderNoPermission),
      findsOneWidget,
    );
  });

  testWidgets('a listing failure offers retry and recovers', (tester) async {
    final gateway = Pf1215FakeFilesGateway.sample()
      ..listFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
      );
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    expect(find.byKey(const ValueKey('pf1215-fs-error')), findsOneWidget);
    expect(_entry('$_root/lib'), findsNothing);

    gateway.listFailure = null;
    await tester.tap(find.byKey(const ValueKey('pf1215-fs-retry')));
    await tester.pumpAndSettle();
    expect(_entry('$_root/lib'), findsOneWidget);
  });

  testWidgets('an older Hermes without /api/fs is gated honestly', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample()
      ..listFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: 404,
      );
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    expect(find.byKey(const ValueKey('pf1215-fs-unsupported')), findsOneWidget);
    expect(find.byKey(const ValueKey('pf1215-fs-retry')), findsNothing);
  });

  testWidgets('a gateway already known to lack /api/fs is never called', (
    tester,
  ) async {
    final gateway = Pf1215FakeFilesGateway.sample()..knownUnsupported = true;
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    expect(find.byKey(const ValueKey('pf1215-fs-unsupported')), findsOneWidget);
    expect(gateway.fsCalls, isEmpty);
  });

  testWidgets('a gateway without the files surface shows the gate', (
    tester,
  ) async {
    final gateway = Pj1215FakeProjectsGateway.sample();
    await _enterProject(tester, gateway);
    await _openFiles(tester);
    expect(find.byKey(const ValueKey('pf1215-fs-unsupported')), findsOneWidget);
  });

  testWidgets('the folderless Home bucket has no files tab', (tester) async {
    final gateway = Pf1215FakeFilesGateway.sample();
    await _enterProject(tester, gateway, project: 'Sin proyecto');
    expect(find.byKey(const ValueKey('pf1215-tab-files')), findsNothing);
  });
}

BuildContext _ctx(WidgetTester tester) =>
    tester.element(find.byType(Navigator).first);
