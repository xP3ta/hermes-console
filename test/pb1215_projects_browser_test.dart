// Behavioural tests for the folder-style Projects browser: the root lists
// projects as folders, a project opens like a folder (subfolders + chats),
// long-press carries the project actions, and search filters both levels.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:hermes_android/core/widgets/projects/project_folder_widgets.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pj1215_fake_projects_gateway.dart';

const _root = '/home/demo/code/hermes-console';
const _worktree = '/home/demo/code/hermes-console-wt/projects';

Future<List<ProjectChatRequest>> _pump(
  WidgetTester tester,
  HermesDesktopControlGateway gateway, {
  Size size = const Size(412, 915),
  double textScale = 1,
  Locale locale = const Locale('es'),
}) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final launched = <ProjectChatRequest>[];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ProjectsCenterScreen(
        connection: SavedConnection(
          id: 'pb1215',
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
  return launched;
}

Finder _folder(String id) => find.byKey(ValueKey('pj1215-card-$id'));

Future<void> _enter(WidgetTester tester, String id) async {
  await tester.tap(_folder(id));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('pb1215-search')).last,
    query,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(PrivateRenderCaches.clearAll);

  test('folder tints are calm: low chroma, none without a Desktop colour', () {
    ProjectNode node(String color) =>
        ProjectNode.tryParse({'id': 'p', 'color': color})!;
    final tint = HSLColor.fromColor(
      projectFolderTint(node('hsl(120 68% 58%)'))!,
    );
    expect(tint.hue, closeTo(120, 1));
    expect(tint.saturation, lessThanOrEqualTo(0.31)); // 8-bit rounding
    expect(projectFolderTint(node('')), isNull);
  });

  test('session rows keep the profile the server stamped on them', () {
    expect(
      ProjectSessionPreview.tryParse({'id': 's', 'profile': 'work'})!.profile,
      'work',
    );
    expect(ProjectSessionPreview.tryParse({'id': 's'})!.profile, '');
  });

  group('root', () {
    testWidgets('projects are folders: name and a short "N chats · when"', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());

      expect(find.text('Hermes Console'), findsOneWidget);
      expect(find.text('7 chats · hace 20 min'), findsOneWidget);
      expect(find.text('3 chats · hace 5 h'), findsOneWidget);
      // No raw path as row text, no per-row overflow menu, no intro prose.
      expect(find.text('~/code/hermes-console'), findsNothing);
      expect(
        find.byKey(const ValueKey('pj1215-card-menu-p_console')),
        findsNothing,
      );
      expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
      expect(find.byKey(const ValueKey('pj1215-intro-more')), findsNothing);
      // A single "+" in the app bar, only when the server can create.
      expect(
        find.byKey(const ValueKey('pc1215-add')),
        findsNothing,
        reason: 'this gateway cannot create projects',
      );
    });

    testWidgets('a server that can create shows one "+" (Nuevo proyecto) and '
        'no footer', (tester) async {
      await _pump(tester, Pc1215CreatingProjectsGateway.sample());
      final add = find.byKey(const ValueKey('pc1215-add'));
      expect(add, findsOneWidget);
      expect(find.byTooltip('Nuevo proyecto'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pj1215-create-desktop-only')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('pc1215-create')), findsNothing);
    });

    testWidgets('folders are plain shapes: no glyph inside any folder', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      Finder iconsIn(Finder row) => find.descendant(
        of: row,
        matching: find.descendant(
          of: find.byType(ProjectFolderGlyph),
          matching: find.byType(Icon),
        ),
      );
      for (final id in [
        'p_console',
        'p_notes',
        '/srv/work/homelab',
        '__no_project__',
      ]) {
        expect(_folder(id), findsOneWidget, reason: id);
        expect(iconsIn(_folder(id)), findsNothing, reason: id);
      }
      // "Otros chats" is told apart only by a more neutral (graphite) tint.
      final other = tester.widget<ProjectFolderGlyph>(
        find.descendant(
          of: _folder('__no_project__'),
          matching: find.byType(ProjectFolderGlyph),
        ),
      );
      expect(other.neutral, isTrue);
      final console = tester.widget<ProjectFolderGlyph>(
        find.descendant(
          of: _folder('p_console'),
          matching: find.byType(ProjectFolderGlyph),
        ),
      );
      expect(console.neutral, isFalse);

      await _enter(tester, 'p_console');
      final sub = find.byKey(const ValueKey('pb1215-subfolder-$_worktree'));
      expect(iconsIn(sub), findsNothing);
    });

    testWidgets('folders carry no status dot', (tester) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      // p_console is the active project: still no badge or dot on its row.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('pj1215-card-p_console')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).shape == BoxShape.circle,
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('chats without a folder are the last folder, "Otros chats"', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      final other = _folder('__no_project__');
      expect(other, findsOneWidget);
      expect(
        find.descendant(of: other, matching: find.text('Otros chats')),
        findsOneWidget,
      );
      expect(find.text('4 chats sin carpeta · hace 1 h'), findsOneWidget);
      final ys = [
        for (final id in ['p_console', 'p_notes', '/srv/work/homelab'])
          tester.getTopLeft(_folder(id)).dy,
      ];
      expect(
        tester.getTopLeft(other).dy,
        greaterThan(ys.reduce((a, b) => a > b ? a : b)),
      );
    });

    testWidgets('a project with no chats says so instead of "0"', (
      tester,
    ) async {
      final json = pj1215SampleTreeJson();
      (json['projects'] as List)[1]['sessionCount'] = 0;
      (json['projects'] as List)[1]['lastActive'] = 0;
      await _pump(
        tester,
        Pj1215FakeProjectsGateway(tree: ProjectTreeSnapshot.fromJson(json)),
      );
      expect(
        find.descendant(
          of: _folder('p_notes'),
          matching: find.text('Sin chats todavía'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('long-press opens the project actions (no ⋮ needed)', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await tester.longPress(_folder('p_console'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pj1215-menu-rename')), findsOneWidget);
      expect(find.byKey(const ValueKey('pj1215-menu-delete')), findsOneWidget);
    });

    testWidgets('TalkBack reaches the same actions through a custom action', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      final node = tester.getSemantics(_folder('p_console'));
      final data = node.getSemanticsData();
      expect(data.label, contains('Hermes Console'));
      expect(data.label, contains('7 chats'));
      final ids = data.customSemanticsActionIds ?? const <int>[];
      final labels = [
        for (final id in ids) CustomSemanticsAction.getAction(id)?.label,
      ];
      expect(labels, contains('Opciones del proyecto'));
      handle.dispose();
    });

    testWidgets('the Home bucket has no project actions on long-press', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await tester.longPress(_folder('__no_project__'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pj1215-menu-rename')), findsNothing);
      expect(find.byKey(const ValueKey('pj1215-menu-new-chat')), findsNothing);
    });

    testWidgets('search filters projects by name', (tester) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _search(tester, 'notas');
      expect(_folder('p_notes'), findsOneWidget);
      expect(_folder('p_console'), findsNothing);
      expect(_folder('/srv/work/homelab'), findsNothing);
      expect(_folder('__no_project__'), findsNothing);
    });

    testWidgets('search also finds chats and opens the one tapped', (
      tester,
    ) async {
      final launched = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _search(tester, 'notificaciones');
      expect(_folder('p_console'), findsNothing);
      final hit = find.byKey(const ValueKey('pb1215-chat-s2'));
      expect(hit, findsOneWidget);
      // The project it lives in is named on the row.
      expect(
        find.descendant(
          of: hit,
          matching: find.textContaining('Hermes Console'),
        ),
        findsOneWidget,
      );
      await tester.tap(hit);
      await tester.pumpAndSettle();
      expect(launched.single.existing?.id, 's2');
    });

    testWidgets('search with no match is friendly', (tester) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _search(tester, 'zzz');
      expect(find.byKey(const ValueKey('pb1215-no-results')), findsOneWidget);
    });

    testWidgets('fits 320 dp at 2x text without overflow', (tester) async {
      await _pump(
        tester,
        Pj1215FakeProjectsGateway.sample(),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(_folder('p_console'), findsOneWidget);
    });
  });

  group('inside a project', () {
    testWidgets('the folder shows its chats and its subfolders', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await _enter(tester, 'p_console');
      expect(gateway.calls, contains('projects.project_sessions:p_console'));

      // Trunk chats live directly in the project folder.
      for (final title in [
        'Arreglar notificaciones',
        'Revisar el login',
        'Probar modo oscuro',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      // The worktree is a subfolder with its own count; its chats are inside.
      final sub = find.byKey(const ValueKey('pb1215-subfolder-$_worktree'));
      expect(sub, findsOneWidget);
      expect(
        find.descendant(of: sub, matching: find.text('feat/projects')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sub, matching: find.textContaining('2 chats')),
        findsOneWidget,
      );
      expect(find.text('Rediseñar Proyectos'), findsNothing);
      // The path is a short, muted "~/…" line, not a monospace headline.
      final path = tester.widget<Text>(
        find.byKey(const ValueKey('pj1215-detail-path')),
      );
      expect(path.data, '~/code/hermes-console');
      expect(path.style?.fontFamily, isNot('monospace'));
      expect(find.text(_root), findsNothing);
    });

    testWidgets('a server that does not flag the trunk still keeps its chats '
        'in the folder', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      gateway.details['p_console'] = ProjectNode.tryParse({
        'id': 'p_console',
        'label': 'Hermes Console',
        'path': _root,
        'sessionCount': 2,
        'repos': [
          {
            'id': _root,
            'label': 'hermes-console',
            'path': _root,
            'groups': [
              {
                'id': '$_root::branch::main',
                'label': 'main',
                'path': _root,
                'sessions': [
                  {'id': 'a', 'title': 'Trunk chat'},
                ],
              },
              {
                'id': _worktree,
                'label': 'feat/projects',
                'path': _worktree,
                'sessions': [
                  {'id': 'b', 'title': 'Worktree chat'},
                ],
              },
            ],
          },
        ],
      })!;
      await _pump(tester, gateway);
      await _enter(tester, 'p_console');
      expect(find.text('Trunk chat'), findsOneWidget);
      expect(find.text('Worktree chat'), findsNothing);
      expect(
        find.byKey(const ValueKey('pb1215-subfolder-$_worktree')),
        findsOneWidget,
      );
    });

    testWidgets('a chat row opens that conversation', (tester) async {
      final launched = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _enter(tester, 'p_console');
      await tester.tap(find.text('Revisar el login'));
      await tester.pumpAndSettle();
      expect(launched.single.existing?.id, 'main-1');
    });

    testWidgets('+ starts a chat in the project folder', (tester) async {
      final launched = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _enter(tester, 'p_console');
      await tester.tap(find.byKey(const ValueKey('pj1215-detail-new-chat')));
      await tester.pumpAndSettle();
      expect(launched.single.isNewChat, isTrue);
      expect(launched.single.workspace, _root);
    });

    testWidgets('a subfolder lists its chats and its + uses that folder', (
      tester,
    ) async {
      final launched = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _enter(tester, 'p_console');
      await tester.tap(
        find.byKey(const ValueKey('pb1215-subfolder-$_worktree')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Rediseñar Proyectos'), findsOneWidget);
      expect(find.text('Selector de rama base'), findsOneWidget);
      expect(find.text('Arreglar notificaciones'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('pj1215-detail-new-chat')).last,
      );
      await tester.pumpAndSettle();
      expect(launched.single.workspace, _worktree);

      await tester.tap(find.text('Rediseñar Proyectos'));
      await tester.pumpAndSettle();
      expect(launched.last.existing?.id, 'wt-0');
    });

    testWidgets('search inside the project filters its chats', (tester) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _enter(tester, 'p_console');
      await _search(tester, 'login');
      expect(find.text('Revisar el login'), findsOneWidget);
      expect(find.text('Arreglar notificaciones'), findsNothing);
    });

    testWidgets('an empty project folder explains how chats get there', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _enter(tester, 'p_notes');
      expect(find.byKey(const ValueKey('pb1215-empty-folder')), findsOneWidget);
      expect(find.text('Esta carpeta aún no tiene chats'), findsOneWidget);
    });

    testWidgets('"Otros chats" lists its chats and + starts one detached', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      gateway.details['__no_project__'] = ProjectNode.tryParse({
        'id': '__no_project__',
        'label': 'Home',
        'isNoProject': true,
        'sessionCount': 2,
        'repos': [
          {
            'id': '__no_project__',
            'label': 'Home',
            'groups': [
              {
                'id': '__no_project__',
                'label': 'Home',
                'totalCount': 2,
                'sessions': [
                  {'id': 'h0', 'title': 'Receta de pan'},
                  {'id': 'h1', 'title': 'Plan de viaje'},
                ],
              },
            ],
          },
        ],
      })!;
      final launched = await _pump(tester, gateway);
      await _enter(tester, '__no_project__');
      expect(find.text('Otros chats'), findsWidgets);
      expect(find.text('Receta de pan'), findsOneWidget);
      expect(find.text('Plan de viaje'), findsOneWidget);
      expect(find.byKey(const ValueKey('pf1215-tab-files')), findsNothing);
      expect(find.byKey(const ValueKey('pj1215-detail-menu')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pj1215-detail-new-chat')));
      await tester.pumpAndSettle();
      expect(launched.single.isNewChat, isTrue);
      expect(launched.single.workspace, isNull);
    });

    testWidgets('English copy', (tester) async {
      await _pump(
        tester,
        Pj1215FakeProjectsGateway.sample(),
        locale: const Locale('en'),
      );
      expect(find.text('7 chats · 20 min ago'), findsOneWidget);
      expect(find.text('Other chats'), findsOneWidget);
    });
  });
}
