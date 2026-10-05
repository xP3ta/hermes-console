// Creating projects from the phone with Hermes Desktop's exact contract:
// the project dialog (`projects.create {name, folders, use: true}`, IDEA.md
// through `POST /api/fs/write-text`, `llm.oneshot` idea), "Open folder…"
// (upsert: a covered folder enters its project) and "Add folder"
// (`projects.add_folder`). Folders always come from the SERVER picker.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:hermes_android/core/widgets/projects/project_create_sheet.dart';
import 'package:hermes_android/core/widgets/projects/project_files_browser.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pj1215_fake_projects_gateway.dart';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'pc1215-${readOnly ? 'ro' : 'rw'}',
  label: 'Hermes QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  readOnly: readOnly,
);

class _Harness {
  final List<ProjectChatRequest> launched = [];
  final List<String> picks = [];
  final List<String?> pickerStarts = [];
}

Future<_Harness> _pump(
  WidgetTester tester,
  HermesDesktopControlGateway gateway, {
  bool readOnly = false,
  List<String> picks = const [],
  Locale locale = const Locale('es'),
}) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final harness = _Harness()..picks.addAll(picks);
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: ProjectsCenterScreen(
        connection: _connection(readOnly: readOnly),
        connectionManager: manager,
        gateway: gateway,
        chatLauncher: (_, request) => harness.launched.add(request),
        folderPicker: (_, startPath) async {
          harness.pickerStarts.add(startPath);
          return harness.picks.isEmpty ? null : harness.picks.removeAt(0);
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openCreate(WidgetTester tester) async {
  await _tap(tester, 'pc1215-add');
  await _tap(tester, 'pc1215-add-create');
}

bool _submitEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(
          find.byKey(const ValueKey('pc1215-create-submit')),
        )
        .onPressed !=
    null;

List<List<Object?>> _calls(Pj1215FakeProjectsGateway g, String method) => [
  for (final write in g.writes)
    if (write.$1 == method) [write.$1, write.$2],
];

ProjectTreeSnapshot _treeWithNew() {
  final json = pj1215SampleTreeJson();
  (json['projects'] as List).insert(0, {
    'id': 'p_new',
    'label': 'garden',
    'path': '/srv/garden',
    'isAuto': false,
    'sessionCount': 0,
    'repos': [],
  });
  return ProjectTreeSnapshot.fromJson(json);
}

void main() {
  setUp(PrivateRenderCaches.clearAll);

  group('new project dialog', () {
    testWidgets('picks a server folder, names it after the folder, sends '
        'Desktop\'s projects.create, writes IDEA.md, refreshes and enters it', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample()
        ..treeAfterCreate = _treeWithNew();
      final harness = await _pump(tester, gateway, picks: ['/srv/garden/']);
      final treeReads = gateway.calls.where((c) => c == 'projects.tree').length;

      await _openCreate(tester);
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsOneWidget);
      expect(_submitEnabled(tester), isFalse);

      await _tap(tester, 'pc1215-create-add-folder');
      // The picker opens at the server's default folder (Desktop
      // `desktopDefaultCwd`), never a phone path.
      expect(harness.pickerStarts, ['/home/demo']);
      expect(
        find.byKey(const ValueKey('pc1215-create-folder-/srv/garden')),
        findsOneWidget,
      );
      final name = tester.widget<TextField>(
        find.byKey(const ValueKey('pc1215-create-name')),
      );
      expect(name.controller!.text, 'garden');

      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-idea')),
        'Plan the beds',
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'pc1215-create-submit');

      expect(_calls(gateway, 'projects.create'), [
        [
          'projects.create',
          {
            'name': 'garden',
            'folders': ['/srv/garden'],
            'use': true,
          },
        ],
      ]);
      // The folder is listed first: IDEA.md is only written when absent.
      expect(gateway.calls, contains('GET /api/fs/list:/srv/garden'));
      expect(_calls(gateway, 'POST /api/fs/write-text'), [
        [
          'POST /api/fs/write-text',
          {'path': '/srv/garden/IDEA.md', 'content': 'Plan the beds\n'},
        ],
      ]);
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsNothing);
      expect(find.textContaining('IDEA.md'), findsNothing);
      expect(
        gateway.calls.where((c) => c == 'projects.tree').length,
        greaterThan(treeReads),
      );
      // Desktop enters the created project.
      expect(gateway.calls, contains('projects.project_sessions:p_new'));
      expect(harness.launched, isEmpty);
    });

    Future<Pc1215CreatingProjectsGateway> createWithIdea(
      WidgetTester tester,
      void Function(Pc1215CreatingProjectsGateway gateway) setUp, {
      Locale locale = const Locale('es'),
    }) async {
      final gateway = Pc1215CreatingProjectsGateway.sample()
        ..treeAfterCreate = _treeWithNew();
      setUp(gateway);
      await _pump(tester, gateway, picks: ['/srv/garden'], locale: locale);
      await _openCreate(tester);
      await _tap(tester, 'pc1215-create-add-folder');
      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-idea')),
        'Plan the beds',
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'pc1215-create-submit');
      return gateway;
    }

    testWidgets('an existing IDEA.md is never overwritten; the user is told '
        'and the project is still created and entered', (tester) async {
      final gateway = await createWithIdea(tester, (gateway) {
        gateway.folders['/srv/garden'] = const [
          ProjectFsEntry(
            name: 'src',
            path: '/srv/garden/src',
            isDirectory: true,
          ),
          ProjectFsEntry(
            name: 'IDEA.md',
            path: '/srv/garden/IDEA.md',
            isDirectory: false,
          ),
        ];
      });
      expect(gateway.calls, contains('GET /api/fs/list:/srv/garden'));
      expect(_calls(gateway, 'POST /api/fs/write-text'), isEmpty);
      expect(_calls(gateway, 'projects.create'), hasLength(1));
      expect(
        find.text('Ya existe IDEA.md en la carpeta; no se ha sobrescrito.'),
        findsOneWidget,
      );
      expect(gateway.calls, contains('projects.project_sessions:p_new'));
    });

    testWidgets('English: an existing IDEA.md is reported in English', (
      tester,
    ) async {
      final gateway = await createWithIdea(tester, (gateway) {
        gateway.folders['/srv/garden'] = const [
          ProjectFsEntry(
            name: 'IDEA.md',
            path: '/srv/garden/IDEA.md',
            isDirectory: false,
          ),
        ];
      }, locale: const Locale('en'));
      expect(_calls(gateway, 'POST /api/fs/write-text'), isEmpty);
      expect(
        find.text(
          "IDEA.md already exists in the folder; it wasn't overwritten.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('a folder whose listing fails is not written either', (
      tester,
    ) async {
      final gateway = await createWithIdea(tester, (gateway) {
        gateway.folderErrors['/srv/garden'] = 'EACCES';
      });
      expect(gateway.calls, contains('GET /api/fs/list:/srv/garden'));
      expect(_calls(gateway, 'POST /api/fs/write-text'), isEmpty);
      expect(
        find.text(
          'No se pudo comprobar si la carpeta ya tiene IDEA.md; '
          'no se ha escrito.',
        ),
        findsOneWidget,
      );
      expect(gateway.calls, contains('projects.project_sessions:p_new'));
    });

    testWidgets('a similarly named file does not block IDEA.md', (
      tester,
    ) async {
      final gateway = await createWithIdea(tester, (gateway) {
        gateway.folders['/srv/garden'] = const [
          ProjectFsEntry(
            name: 'IDEA.md.bak',
            path: '/srv/garden/IDEA.md.bak',
            isDirectory: false,
          ),
        ];
      });
      expect(_calls(gateway, 'POST /api/fs/write-text').single[1], {
        'path': '/srv/garden/IDEA.md',
        'content': 'Plan the beds\n',
      });
      expect(find.textContaining('no se ha'), findsNothing);
    });

    testWidgets('several folders: the first is primary; no idea, no IDEA.md', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, picks: ['/srv/a', '/srv/b']);
      await _openCreate(tester);
      await _tap(tester, 'pc1215-create-add-folder');
      await _tap(tester, 'pc1215-create-add-folder');
      expect(find.text('principal'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-name')),
        'Mi web',
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'pc1215-create-submit');
      expect(_calls(gateway, 'projects.create').single[1], {
        'name': 'Mi web',
        'folders': ['/srv/a', '/srv/b'],
        'use': true,
      });
      expect(_calls(gateway, 'POST /api/fs/write-text'), isEmpty);
    });

    testWidgets('needs a name and at least one folder', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, picks: ['/srv/garden']);
      await _openCreate(tester);

      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-name')),
        'Huerto',
      );
      await tester.pumpAndSettle();
      expect(_submitEnabled(tester), isFalse);
      expect(find.text('Aún no has añadido ninguna carpeta.'), findsOneWidget);

      await _tap(tester, 'pc1215-create-add-folder');
      expect(_submitEnabled(tester), isTrue);
      // A typed name is kept: the folder only names an unnamed project.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('pc1215-create-name')))
            .controller!
            .text,
        'Huerto',
      );

      await _tap(tester, 'pc1215-create-remove-/srv/garden');
      expect(_submitEnabled(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('pc1215-create-submit')));
      await tester.pumpAndSettle();
      expect(_calls(gateway, 'projects.create'), isEmpty);

      await _tap(tester, 'pc1215-create-add-folder');
      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-name')),
        '   ',
      );
      await tester.pumpAndSettle();
      expect(_submitEnabled(tester), isFalse);
    });

    testWidgets('picking the same folder twice keeps one entry and sends it '
        'once', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, picks: ['/srv/garden', '/srv/garden/']);
      await _openCreate(tester);
      await _tap(tester, 'pc1215-create-add-folder');
      await _tap(tester, 'pc1215-create-add-folder');
      expect(
        find.byKey(const ValueKey('pc1215-create-folder-/srv/garden')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      await _tap(tester, 'pc1215-create-submit');
      expect(_calls(gateway, 'projects.create').single[1], {
        'name': 'garden',
        'folders': ['/srv/garden'],
        'use': true,
      });
    });

    testWidgets('keyboard "done" with no folders or an empty name never '
        'reaches the gateway', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, picks: ['/srv/garden']);
      await _openCreate(tester);
      final name = find.byKey(const ValueKey('pc1215-create-name'));

      // A name but no folder yet.
      await tester.enterText(name, 'Huerto');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_calls(gateway, 'projects.create'), isEmpty);

      // A folder but a blank name.
      await _tap(tester, 'pc1215-create-add-folder');
      await tester.enterText(name, '   ');
      await tester.pumpAndSettle();
      await tester.showKeyboard(name);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_calls(gateway, 'projects.create'), isEmpty);
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsOneWidget);

      // Control: with both, "done" submits through the same path.
      await tester.enterText(name, 'Huerto');
      await tester.pumpAndSettle();
      await tester.showKeyboard(name);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_calls(gateway, 'projects.create').single[1], {
        'name': 'Huerto',
        'folders': ['/srv/garden'],
        'use': true,
      });
    });

    testWidgets('a folder already in a project offers to open it instead; '
        'nothing is created', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      final harness = await _pump(
        tester,
        gateway,
        picks: ['/home/demo/code/hermes-console/lib'],
      );
      final treeReads = gateway.calls.where((c) => c == 'projects.tree').length;
      await _openCreate(tester);
      await _tap(tester, 'pc1215-create-add-folder');

      // Membership is checked against a fresh tree (Desktop refreshes first).
      expect(
        gateway.calls.where((c) => c == 'projects.tree').length,
        greaterThan(treeReads),
      );
      expect(
        find.byKey(const ValueKey('pc1215-covered-dialog')),
        findsOneWidget,
      );
      expect(find.text('Ya está en «Hermes Console»'), findsOneWidget);
      await _tap(tester, 'pc1215-covered-open');

      expect(_calls(gateway, 'projects.create'), isEmpty);
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsNothing);
      expect(gateway.calls, contains('projects.project_sessions:p_console'));
      expect(harness.launched, isEmpty);
    });

    testWidgets('a detected repo can still become a named project', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, picks: ['/srv/work/homelab']);
      await _openCreate(tester);
      await _tap(tester, 'pc1215-create-add-folder');
      expect(
        find.byKey(const ValueKey('pc1215-covered-dialog')),
        findsOneWidget,
      );
      await _tap(tester, 'pc1215-covered-add');
      expect(
        find.byKey(const ValueKey('pc1215-create-folder-/srv/work/homelab')),
        findsOneWidget,
      );
      await _tap(tester, 'pc1215-create-submit');
      expect(_calls(gateway, 'projects.create').single[1], {
        'name': 'homelab',
        'folders': ['/srv/work/homelab'],
        'use': true,
      });
    });

    testWidgets('a failed create keeps the dialog open with the error', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample()
        ..createFailure = const DesktopControlFailure(
          DesktopControlFailureKind.rejected,
        );
      await _pump(tester, gateway, picks: ['/srv/garden']);
      await _openCreate(tester);
      await _tap(tester, 'pc1215-create-add-folder');
      await _tap(tester, 'pc1215-create-submit');

      expect(_calls(gateway, 'projects.create'), hasLength(1));
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('pc1215-create-error')), findsOneWidget);
      expect(find.text('No se pudo crear el proyecto'), findsOneWidget);
      expect(_submitEnabled(tester), isTrue);
      expect(gateway.calls, isNot(contains('projects.project_sessions:p_new')));
    });

    testWidgets('generate idea uses llm.oneshot; templates fill the idea', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway);
      await _openCreate(tester);
      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-name')),
        'Huerto',
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'pc1215-create-generate');
      expect(_calls(gateway, 'llm.oneshot').single[1], {'name': 'Huerto'});
      TextField idea() =>
          tester.widget(find.byKey(const ValueKey('pc1215-create-idea')));
      expect(idea().controller!.text, gateway.idea);

      await _tap(tester, 'pc1215-idea-template-0');
      expect(idea().controller!.text, isNot(gateway.idea));
      expect(idea().controller!.text, isNotEmpty);
      expect(find.byKey(const ValueKey('pc1215-idea-template-5')), findsOne);
      await _tap(tester, 'pc1215-create-shuffle');
      expect(find.byKey(const ValueKey('pc1215-idea-template-5')), findsOne);
    });

    testWidgets('empty state offers the new project button', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway(
        tree: const ProjectTreeSnapshot(projects: []),
      );
      await _pump(tester, gateway);
      await _tap(tester, 'pc1215-empty-create');
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsOneWidget);
    });

    testWidgets('English copy is natural', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, locale: const Locale('en'));
      await _openCreate(tester);
      expect(find.text('New project'), findsWidgets);
      expect(find.text('No folders added yet.'), findsOneWidget);
    });
  });

  group('open folder (upsert)', () {
    testWidgets('a folder covered by a project enters it and starts a chat '
        'there; no projects.create', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      final harness = await _pump(
        tester,
        gateway,
        picks: ['/home/demo/code/hermes-console-wt/projects'],
      );
      await _tap(tester, 'pc1215-add');
      await _tap(tester, 'pc1215-add-open-folder');
      expect(_calls(gateway, 'projects.create'), isEmpty);
      expect(gateway.calls, contains('projects.project_sessions:p_console'));
      expect(
        harness.launched.single.workspace,
        '/home/demo/code/hermes-console-wt/projects',
      );
    });

    testWidgets('a new folder becomes a project named after it', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample()
        ..treeAfterCreate = _treeWithNew();
      final harness = await _pump(tester, gateway, picks: ['/srv/garden']);
      await _tap(tester, 'pc1215-add');
      await _tap(tester, 'pc1215-add-open-folder');
      expect(_calls(gateway, 'projects.create').single[1], {
        'name': 'garden',
        'folders': ['/srv/garden'],
        'primary_path': '/srv/garden',
        'use': true,
      });
      expect(gateway.calls, contains('projects.project_sessions:p_new'));
      expect(harness.launched.single.workspace, '/srv/garden');
    });

    testWidgets('a failed create still opens the folder as a chat', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample()
        ..createFailure = const DesktopControlFailure(
          DesktopControlFailureKind.rejected,
        );
      final harness = await _pump(tester, gateway, picks: ['/srv/garden']);
      await _tap(tester, 'pc1215-add');
      await _tap(tester, 'pc1215-add-open-folder');
      expect(_calls(gateway, 'projects.create'), hasLength(1));
      expect(harness.launched.single.workspace, '/srv/garden');
    });
  });

  group('add folder', () {
    testWidgets('saved project menu sends projects.add_folder and refreshes', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, picks: ['/home/demo/notes/photos']);
      final treeReads = gateway.calls.where((c) => c == 'projects.tree').length;
      await _tap(tester, 'pj1215-card-menu-p_notes');
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('pj1215-menu-add-folder')),
            )
            .enabled,
        isTrue,
      );
      await _tap(tester, 'pj1215-menu-add-folder');
      expect(_calls(gateway, 'projects.add_folder'), [
        [
          'projects.add_folder',
          {
            'id': 'p_notes',
            'path': '/home/demo/notes/photos',
            'is_primary': false,
          },
        ],
      ]);
      expect(
        gateway.calls.where((c) => c == 'projects.tree').length,
        greaterThan(treeReads),
      );
      expect(find.text('Carpeta añadida a «Notas de viaje»'), findsOneWidget);
    });

    testWidgets('a picked folder with a trailing slash is sent without it', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, picks: ['/home/demo/notes/photos/']);
      await _tap(tester, 'pj1215-card-menu-p_notes');
      await _tap(tester, 'pj1215-menu-add-folder');
      expect(_calls(gateway, 'projects.add_folder'), [
        [
          'projects.add_folder',
          {
            'id': 'p_notes',
            'path': '/home/demo/notes/photos',
            'is_primary': false,
          },
        ],
      ]);
    });

    testWidgets('cancelling the picker sends nothing', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway);
      await _tap(tester, 'pj1215-card-menu-p_notes');
      await _tap(tester, 'pj1215-menu-add-folder');
      expect(_calls(gateway, 'projects.add_folder'), isEmpty);
    });
  });

  group('folder owner (Desktop projectIdForCwd)', () {
    ProjectNode node(String id, String path) => ProjectNode.tryParse({
      'id': id,
      'label': id,
      'path': path,
      'isAuto': false,
      'sessionCount': 0,
      'repos': [],
    })!;

    test('nested owners: the longest path wins in either order', () {
      final app = node('p_app', '/srv/app');
      final sub = node('p_sub', '/srv/app/sub');
      for (final order in [
        [app, sub],
        [sub, app],
      ]) {
        expect(projectOwningFolder(order, '/srv/app/sub/src')?.id, 'p_sub');
        expect(projectOwningFolder(order, '/srv/app/sub')?.id, 'p_sub');
        expect(projectOwningFolder(order, '/srv/app/other')?.id, 'p_app');
        expect(projectOwningFolder(order, '/srv/application'), isNull);
      }
    });
  });

  group('IDEA.md guard', () {
    test(
      'a capped listing or a missing listing never allows the write',
      () async {
        final gateway = Pc1215CreatingProjectsGateway()
          ..folders['/big'] = [
            for (var i = 0; i < projectFsListingLimit; i++)
              ProjectFsEntry(name: 'f$i', path: '/big/f$i', isDirectory: false),
          ]
          ..folders['/small'] = const [];
        expect(
          await projectIdeaBlocker(gateway, '/big'),
          ProjectIdeaNotWritten.unverified,
        );
        expect(await projectIdeaBlocker(gateway, '/small'), isNull);
        expect(
          await projectIdeaBlocker(null, '/small'),
          ProjectIdeaNotWritten.unverified,
        );
        gateway.filesUnsupported = true;
        expect(
          await projectIdeaBlocker(gateway, '/small'),
          ProjectIdeaNotWritten.unverified,
        );
      },
    );
  });

  group('capability gating', () {
    testWidgets('a gateway without creation keeps the old honest state', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      expect(find.byKey(const ValueKey('pc1215-add')), findsNothing);
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('pj1215-create-desktop-only')),
            )
            .enabled,
        isFalse,
      );
      await _tap(tester, 'pj1215-card-menu-p_notes');
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('pj1215-menu-add-folder')),
            )
            .enabled,
        isFalse,
      );
    });

    testWidgets('read-only connection hides creation', (tester) async {
      final gateway = Pc1215CreatingProjectsGateway.sample();
      await _pump(tester, gateway, readOnly: true);
      expect(find.byKey(const ValueKey('pc1215-add')), findsNothing);
      expect(find.byKey(const ValueKey('pc1215-create')), findsNothing);
      await _tap(tester, 'pj1215-card-menu-p_notes');
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('pj1215-menu-add-folder')),
            )
            .enabled,
        isFalse,
      );
    });

    testWidgets('server without projects.create hides creation', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample()
        ..creationUnsupported = true;
      await _pump(tester, gateway);
      expect(find.byKey(const ValueKey('pc1215-add')), findsNothing);
    });

    testWidgets('server without the folder listing hides creation', (
      tester,
    ) async {
      final gateway = Pc1215CreatingProjectsGateway.sample()
        ..filesUnsupported = true;
      await _pump(tester, gateway);
      expect(find.byKey(const ValueKey('pc1215-add')), findsNothing);
    });
  });

  testWidgets('manual refresh asks the host to scan for repos first', (
    tester,
  ) async {
    final gateway = Pc1215CreatingProjectsGateway.sample();
    await _pump(tester, gateway);
    expect(gateway.calls, isNot(contains('projects.discover_repos:scan')));
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    final scan = gateway.calls.lastIndexOf('projects.discover_repos:scan');
    expect(scan, greaterThanOrEqualTo(0));
    expect(gateway.calls.lastIndexOf('projects.tree'), greaterThan(scan));
  });

  group('server folder picker', () {
    Future<String?> pick(
      WidgetTester tester,
      Pc1215CreatingProjectsGateway gateway, {
      String? start,
      Future<void> Function()? steps,
    }) async {
      String? result = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showServerFolderPicker(
                context,
                files: gateway,
                writes: gateway,
                startPath: start,
                failureText: (_) => 'x',
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await steps?.call();
      return result;
    }

    Pc1215CreatingProjectsGateway fs() => Pc1215CreatingProjectsGateway()
      ..folders.addAll({
        '/home/demo': const [
          ProjectFsEntry(
            name: 'code',
            path: '/home/demo/code',
            isDirectory: true,
          ),
          ProjectFsEntry(
            name: 'notes.md',
            path: '/home/demo/notes.md',
            isDirectory: false,
          ),
        ],
        '/home/demo/code': const [],
        '/home': const [
          ProjectFsEntry(name: 'demo', path: '/home/demo', isDirectory: true),
        ],
      });

    testWidgets('starts at the server folder, enters folders and returns the '
        'current one', (tester) async {
      final gateway = fs();
      String? picked;
      picked = await pick(
        tester,
        gateway,
        start: '/home/demo',
        steps: () async {
          expect(gateway.calls, contains('GET /api/fs/list:/home/demo'));
          await tester.tap(find.text('code'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('pc1215-pick-folder-use')),
          );
          await tester.pumpAndSettle();
        },
      );
      expect(picked, '/home/demo/code');
    });

    testWidgets('a file row in pick mode cannot be opened', (tester) async {
      final gateway = fs();
      // The same file opens in the normal project browser (control): the
      // fake really serves it, so only the pick-mode guard keeps it shut.
      expect(
        (await gateway.readProjectFileText('/home/demo/notes.md')).text,
        isNotEmpty,
      );
      gateway.calls.clear();
      final picked = await pick(
        tester,
        gateway,
        start: '/home/demo',
        steps: () async {
          await tester.tap(find.text('notes.md'));
          await tester.pumpAndSettle();
          expect(
            gateway.calls.where((c) => c.startsWith('GET /api/fs/read')),
            isEmpty,
          );
          // No viewer or file-info surface was pushed over the picker.
          expect(find.text('contents of /home/demo/notes.md'), findsNothing);
          expect(
            find.byKey(const ValueKey('pc1215-pick-folder-use')),
            findsOne,
          );
          expect(find.text('notes.md'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('pc1215-pick-folder-use')),
          );
          await tester.pumpAndSettle();
        },
      );
      // The picker still returns the folder, never the tapped file.
      expect(picked, '/home/demo');
    });

    testWidgets('breadcrumbs go up to the filesystem root; files are not '
        'opened; only "new folder" is offered', (tester) async {
      final gateway = fs();
      final picked = await pick(
        tester,
        gateway,
        start: '/home/demo',
        steps: () async {
          await tester.tap(find.text('notes.md'));
          await tester.pumpAndSettle();
          expect(gateway.calls.where((c) => c.contains('read')), isEmpty);
          // No per-entry edit/rename/delete menu on any row.
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(
                    'pw1215-fs-entry-menu-',
                  ),
            ),
            findsNothing,
          );
          await tester.tap(find.byKey(const ValueKey('pw1215-fs-add')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('pw1215-add-folder')), findsOne);
          expect(find.byKey(const ValueKey('pw1215-add-file')), findsNothing);
          expect(find.byKey(const ValueKey('pw1215-add-upload')), findsNothing);
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('pf1215-crumb-1')));
          await tester.pumpAndSettle();
          expect(gateway.calls, contains('GET /api/fs/list:/home'));
          await tester.tap(
            find.byKey(const ValueKey('pc1215-pick-folder-use')),
          );
          await tester.pumpAndSettle();
        },
      );
      expect(picked, '/home');
    });
  });
}
