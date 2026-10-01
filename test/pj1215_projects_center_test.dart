// Behavioural tests for the Desktop-parity Projects center. Every write goes
// through the fake gateway, which records the exact RPC / Dashboard route and
// params Hermes Desktop sends.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:hermes_android/core/utils/short_server_path.dart';
import 'package:hermes_android/core/widgets/projects/project_actions.dart';
import 'package:hermes_android/core/widgets/projects/project_appearance.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pj1215_fake_projects_gateway.dart';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'pj1215-${readOnly ? 'ro' : 'rw'}',
  label: 'Hermes QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  readOnly: readOnly,
);

class _Harness {
  final List<ProjectChatRequest> launched = [];
  late ConnectionManager manager;
}

Future<_Harness> _pump(
  WidgetTester tester,
  HermesDesktopControlGateway gateway, {
  bool readOnly = false,
  Locale locale = const Locale('es'),
}) async {
  SharedPreferences.setMockInitialValues({});
  final harness = _Harness()
    ..manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
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
        connectionManager: harness.manager,
        gateway: gateway,
        chatLauncher: (_, request) => harness.launched.add(request),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _openMenu(WidgetTester tester, String projectId) async {
  await tester.tap(find.byKey(ValueKey('pj1215-card-menu-$projectId')));
  await tester.pumpAndSettle();
}

Future<void> _tapMenu(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<Object> _w(Pj1215FakeProjectsGateway g) => [
  for (final (method, params) in g.writes) [method, params],
];

Object _r((String, Map<String, Object?>) write) => [write.$1, write.$2];

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<ListTile>(find.byKey(ValueKey(key))).enabled;

void main() {
  setUp(PrivateRenderCaches.clearAll);

  group('list', () {
    testWidgets('cards show name, short path, branch, count and activity', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());

      expect(find.text('Hermes Console'), findsOneWidget);
      expect(find.text('~/code/hermes-console'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('7 conversaciones · hace 20 min'), findsOneWidget);
      expect(find.text('Activo'), findsOneWidget);
      expect(find.text('Detectado'), findsOneWidget);
      expect(find.text('Sin proyecto'), findsOneWidget);
      // Desktop-only create stays visible but honest.
      final create = tester.widget<ListTile>(
        find.byKey(const ValueKey('pj1215-create-desktop-only')),
      );
      expect(create.enabled, isFalse);
      expect(find.textContaining('Solo desde Desktop'), findsOneWidget);
    });

    testWidgets('empty state explains what to do and opens the explainer', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway());
      expect(find.byKey(const ValueKey('pj1215-empty')), findsOneWidget);
      expect(find.text('Todavía no hay proyectos'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pj1215-help')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pj1215-explainer')), findsOneWidget);
      expect(find.text('¿Qué es un proyecto?'), findsOneWidget);
    });

    testWidgets('English copy is natural', (tester) async {
      await _pump(
        tester,
        Pj1215FakeProjectsGateway.sample(),
        locale: const Locale('en'),
      );
      expect(find.text('7 conversations · 20 min ago'), findsOneWidget);
      expect(find.text('Detected'), findsOneWidget);
    });
  });

  group('entered project', () {
    testWidgets('groups sessions by branch/worktree like Desktop', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await tester.tap(find.text('Hermes Console'));
      await tester.pumpAndSettle();

      expect(gateway.calls, contains('projects.project_sessions:p_console'));
      expect(find.text('hermes-console'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('feat/projects'), findsOneWidget);
      expect(find.text('Worktree'), findsOneWidget);
      expect(find.text('Arreglar notificaciones'), findsOneWidget);
      expect(find.text('Rediseñar Proyectos'), findsOneWidget);
    });

    testWidgets('new chat starts in the project root folder', (tester) async {
      final harness = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await tester.tap(find.text('Hermes Console'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pj1215-detail-new-chat')));
      await tester.pumpAndSettle();

      expect(harness.launched, hasLength(1));
      expect(harness.launched.single.isNewChat, isTrue);
      expect(
        harness.launched.single.workspace,
        '/home/demo/code/hermes-console',
      );
    });

    testWidgets('lane "+" starts the chat in that worktree folder', (
      tester,
    ) async {
      final harness = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await tester.tap(find.text('Hermes Console'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey(
            'pj1215-lane-new-/home/demo/code/hermes-console-wt/projects',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        harness.launched.single.workspace,
        '/home/demo/code/hermes-console-wt/projects',
      );
    });

    testWidgets('tapping a session opens that existing conversation', (
      tester,
    ) async {
      final harness = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await tester.tap(find.text('Hermes Console'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rediseñar Proyectos'));
      await tester.pumpAndSettle();
      expect(harness.launched.single.existing?.id, 'wt-0');
      expect(harness.launched.single.isNewChat, isFalse);
    });

    testWidgets('Home bucket new chat stays detached (no folder)', (
      tester,
    ) async {
      final harness = await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await tester.tap(find.text('Sin proyecto'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pj1215-detail-new-chat')));
      await tester.pumpAndSettle();
      expect(harness.launched.single.isNewChat, isTrue);
      expect(harness.launched.single.workspace, isNull);
    });
  });

  group('menu writes (same RPCs as Desktop)', () {
    testWidgets('rename sends projects.update {id, name}', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await _openMenu(tester, 'p_console');
      await _tapMenu(tester, 'pj1215-menu-rename');
      await tester.enterText(
        find.byKey(const ValueKey('pj1215-rename-field')),
        'Console Android',
      );
      await tester.tap(find.byKey(const ValueKey('pj1215-rename-save')));
      await tester.pumpAndSettle();

      expect(_w(gateway), [
        [
          'projects.update',
          {'id': 'p_console', 'name': 'Console Android'},
        ],
      ]);
      // The list is re-read after a write.
      expect(gateway.calls.where((c) => c == 'projects.tree'), hasLength(2));
    });

    testWidgets('appearance color sends Desktop swatch value', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await _openMenu(tester, 'p_notes');
      await _tapMenu(tester, 'pj1215-menu-appearance');
      await tester.tap(find.byKey(const ValueKey('pj1215-color-0')));
      await tester.pumpAndSettle();
      expect(_w(gateway), [
        [
          'projects.update',
          {'id': 'p_notes', 'color': 'hsl(0 68% 58%)'},
        ],
      ]);
    });

    testWidgets('appearance "no color" clears with an empty string', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await _openMenu(tester, 'p_notes');
      await _tapMenu(tester, 'pj1215-menu-appearance');
      await tester.tap(find.byKey(const ValueKey('pj1215-color-none')));
      await tester.pumpAndSettle();
      expect(_r(gateway.writes.single), [
        'projects.update',
        {'id': 'p_notes', 'color': ''},
      ]);
    });

    testWidgets('appearance on an auto project adopts it via projects.create', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await _openMenu(tester, '/srv/work/homelab');
      // Auto projects have no rename/set-active/delete, only hide.
      expect(find.byKey(const ValueKey('pj1215-menu-rename')), findsNothing);
      expect(find.byKey(const ValueKey('pj1215-menu-delete')), findsNothing);
      expect(find.byKey(const ValueKey('pj1215-menu-hide')), findsOneWidget);
      await _tapMenu(tester, 'pj1215-menu-appearance');
      expect(find.textContaining('se guarda como proyecto'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pj1215-icon-rocket')));
      await tester.pumpAndSettle();
      expect(_r(gateway.writes.single), [
        'projects.create',
        {
          'name': 'homelab',
          'primary_path': '/srv/work/homelab',
          'icon': 'rocket',
        },
      ]);
    });

    testWidgets('set active sends projects.set_active', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await _openMenu(tester, 'p_notes');
      await _tapMenu(tester, 'pj1215-menu-set-active');
      expect(_r(gateway.writes.single), [
        'projects.set_active',
        {'id': 'p_notes'},
      ]);
    });

    testWidgets('delete needs confirmation; cancel sends nothing', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      await _pump(tester, gateway);
      await _openMenu(tester, 'p_notes');
      await _tapMenu(tester, 'pj1215-menu-delete');
      expect(find.textContaining('no se tocan'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(gateway.writes, isEmpty);

      await _openMenu(tester, 'p_notes');
      await _tapMenu(tester, 'pj1215-menu-delete');
      await tester.tap(find.byKey(const ValueKey('pj1215-delete-confirm')));
      await tester.pumpAndSettle();
      expect(_r(gateway.writes.single), [
        'projects.delete',
        {'id': 'p_notes'},
      ]);
    });

    testWidgets('hide keeps an auto project off this phone only', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      final harness = await _pump(tester, gateway);
      await _openMenu(tester, '/srv/work/homelab');
      await _tapMenu(tester, 'pj1215-menu-hide');
      expect(find.text('homelab'), findsNothing);
      expect(gateway.writes, isEmpty);
      expect(
        harness.manager.prefs.getStringList(
          'pj1215.hiddenAutoProjects.pj1215-rw',
        ),
        ['/srv/work/homelab'],
      );
      await tester.tap(find.byKey(const ValueKey('pj1215-toggle-hidden')));
      await tester.pumpAndSettle();
      expect(find.text('homelab'), findsOneWidget);
    });

    testWidgets('copy path puts the full server path on the clipboard', (
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
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _openMenu(tester, 'p_console');
      await _tapMenu(tester, 'pj1215-menu-copy-path');
      expect(copied, '/home/demo/code/hermes-console');
    });

    testWidgets('folder-picker actions are disabled as "Solo desde Desktop"', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample());
      await _openMenu(tester, 'p_console');
      expect(_enabled(tester, 'pj1215-menu-add-folder'), isFalse);
      expect(_enabled(tester, 'pj1215-menu-reveal'), isFalse);
      expect(
        find.textContaining('explorador de archivos del ordenador'),
        findsNWidgets(2),
      );
    });
  });

  group('worktrees', () {
    testWidgets('new worktree: base picker defaults to origin/HEAD and the '
        'chat opens in the created folder', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      final harness = await _pump(tester, gateway);
      await _openMenu(tester, 'p_console');
      await _tapMenu(tester, 'pj1215-menu-new-worktree');

      expect(_r(gateway.writes.first), [
        'GET /api/git/base-branches',
        {'path': '/home/demo/code/hermes-console'},
      ]);
      expect(find.text('origin/main (principal)'), findsOneWidget);
      final create = find.byKey(const ValueKey('pj1215-worktree-create'));
      expect(tester.widget<FilledButton>(create).onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('pj1215-worktree-name')),
        'arreglar login',
      );
      await tester.pumpAndSettle();
      // Spaces become dashes, like Desktop's gitRef sanitiser.
      expect(find.text('arreglar-login'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pj1215-worktree-base')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('develop').last);
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();

      expect(_r(gateway.writes.last), [
        'POST /api/git/worktree/add',
        {
          'path': '/home/demo/code/hermes-console',
          'branch': 'arreglar-login',
          'base': 'develop',
        },
      ]);
      expect(
        harness.launched.single.workspace,
        '/home/demo/code/hermes-console-wt/arreglar-login',
      );
    });

    testWidgets('open existing branch: checked-out opens its folder, a free '
        'branch gets a worktree', (tester) async {
      final gateway = Pj1215FakeProjectsGateway.sample();
      final harness = await _pump(tester, gateway);
      await _openMenu(tester, 'p_console');
      await _tapMenu(tester, 'pj1215-menu-open-branch');
      expect(gateway.writes.single.$1, 'GET /api/git/branches');
      expect(find.text('nuevo worktree'), findsOneWidget);
      expect(find.text('traer del remoto'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('pj1215-branch-feat/projects')),
      );
      await tester.pumpAndSettle();
      expect(
        harness.launched.single.workspace,
        '/home/demo/code/hermes-console-wt/projects',
      );
      expect(gateway.writes, hasLength(1), reason: 'no write for open');

      await _openMenu(tester, 'p_console');
      await _tapMenu(tester, 'pj1215-menu-open-branch');
      await tester.tap(find.byKey(const ValueKey('pj1215-branch-fix/login')));
      await tester.pumpAndSettle();
      expect(_r(gateway.writes.last), [
        'POST /api/git/worktree/add',
        {
          'path': '/home/demo/code/hermes-console',
          'existingBranch': 'fix/login',
        },
      ]);
      expect(harness.launched, hasLength(2));
    });

    testWidgets('an older backend without /api/git disables worktrees', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample()
        ..gitFailure = const DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: 404,
        );
      await _pump(tester, gateway);
      await _openMenu(tester, 'p_console');
      await _tapMenu(tester, 'pj1215-menu-new-worktree');
      expect(
        find.textContaining('crear worktrees desde el móvil'),
        findsOneWidget,
      );
      // Close the sheet and reopen the menu: now gated with honest copy.
      Navigator.of(
        tester.element(find.byKey(const ValueKey('pj1215-worktree-name'))),
      ).pop();
      await tester.pumpAndSettle();
      await _openMenu(tester, 'p_console');
      expect(_enabled(tester, 'pj1215-menu-new-worktree'), isFalse);
      expect(_enabled(tester, 'pj1215-menu-open-branch'), isFalse);
    });
  });

  group('capability gating', () {
    testWidgets('gateway without write surface: writes disabled, new chat ok', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        Pj1215ReadOnlyProjectsGateway.sample(),
      );
      await _openMenu(tester, 'p_console');
      for (final key in const [
        'pj1215-menu-rename',
        'pj1215-menu-appearance',
        'pj1215-menu-delete',
        'pj1215-menu-new-worktree',
      ]) {
        expect(_enabled(tester, key), isFalse, reason: key);
      }
      expect(find.textContaining('no tiene esta función'), findsWidgets);
      expect(_enabled(tester, 'pj1215-menu-new-chat'), isTrue);
      await _tapMenu(tester, 'pj1215-menu-new-chat');
      expect(
        harness.launched.single.workspace,
        '/home/demo/code/hermes-console',
      );
    });

    testWidgets('read-only connection: writes disabled with that reason', (
      tester,
    ) async {
      await _pump(tester, Pj1215FakeProjectsGateway.sample(), readOnly: true);
      await _openMenu(tester, 'p_console');
      expect(_enabled(tester, 'pj1215-menu-rename'), isFalse);
      expect(_enabled(tester, 'pj1215-menu-delete'), isFalse);
      expect(find.textContaining('solo lectura'), findsWidgets);
    });

    testWidgets('method-not-found on a write gates the rest of the session', (
      tester,
    ) async {
      final gateway = Pj1215FakeProjectsGateway.sample()
        ..writeFailure = const DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: -32601,
        );
      await _pump(tester, gateway);
      await _openMenu(tester, 'p_notes');
      await _tapMenu(tester, 'pj1215-menu-set-active');
      expect(find.textContaining('no tiene esta función'), findsOneWidget);
      await _openMenu(tester, 'p_notes');
      expect(_enabled(tester, 'pj1215-menu-rename'), isFalse);
    });
  });

  group('helpers', () {
    test('shortServerPath', () {
      expect(shortServerPath('/home/demo/code/app'), '~/code/app');
      expect(shortServerPath('/srv/a/b/c/d'), '…/c/d');
      expect(shortServerPath('/Users/x/p'), '~/p');
      expect(shortServerPath(''), '');
    });

    test('git ref sanitiser matches Desktop rules', () {
      expect(sanitizeGitRef('mi rama'), 'mi-rama');
      expect(sanitizeGitRef('a..b~^:?*[]'), 'a.b');
      expect(isValidGitRef('feat/x'), isTrue);
      expect(isValidGitRef('-x'), isFalse);
      expect(isValidGitRef('x.lock'), isFalse);
      expect(isValidGitRef(''), isFalse);
    });

    test('Desktop swatches parse to colors', () {
      expect(projectColorSwatches, hasLength(12));
      expect(projectColorSwatches.first, 'hsl(0 68% 58%)');
      for (final swatch in projectColorSwatches) {
        expect(parseProjectColor(swatch), isNotNull, reason: swatch);
      }
      expect(parseProjectColor('#ff0000'), const Color(0xFFFF0000));
      expect(parseProjectColor('nonsense'), isNull);
    });

    test('lane flags parse isMain / isKanban', () {
      final lane = ProjectLane.tryParse({
        'id': 'x',
        'isMain': true,
        'isKanban': false,
      })!;
      expect(lane.isMain, isTrue);
      expect(lane.isKanban, isFalse);
    });
  });
}
