// Create/edit forms are full-screen pages (owner: "project folder comes up
// tiny with a mini scroll; same for cron… horrible to work without seeing
// what you write"). One shared scaffold: ✕ / title / Create-Save (disabled
// until valid), long text grows with the page scroll, unsaved changes ask
// before leaving, the keyboard never hides the focused line.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/admin_integrations.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/services/run_template_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:hermes_android/core/widgets/form_page.dart';
import 'package:hermes_android/core/widgets/mcp_provisioning_surface.dart';
import 'package:hermes_android/core/widgets/run_template_composer.dart';
import 'package:hermes_android/core/widgets/webhook_admin_surfaces.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pj1215_fake_projects_gateway.dart';
import 'support/pump_until_loaded.dart';

const _phoneWidths = [320.0, 360.0, 390.0, 430.0];

void _phone(WidgetTester tester, double width, {double height = 800}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

MaterialApp _app(Widget home, {Locale locale = const Locale('es')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: home,
    );

String _lines(int n) => [for (var i = 1; i <= n; i++) 'Line $i'].join('\n');

/// The form's page fills the whole window (not a floating card).
void _expectFullScreen(WidgetTester tester, Finder body) {
  final scaffold = find.ancestor(of: body, matching: find.byType(Scaffold));
  final size = tester.getSize(scaffold.first);
  final view = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(size.width, view.width);
  expect(size.height, view.height);
  expect(find.byKey(const ValueKey('hermes-floating-surface')), findsNothing);
}

/// A long text grows the field: its own scrollable never scrolls (no inner
/// mini box) while the page has room to scroll.
void _expectGrowsWithPage(WidgetTester tester, Finder field, Finder page) {
  final inner = tester.state<ScrollableState>(
    find.descendant(of: field, matching: find.byType(Scrollable)).first,
  );
  expect(inner.position.maxScrollExtent, 0);
  final outer = tester.state<ScrollableState>(
    find.descendant(of: page, matching: find.byType(Scrollable)).first,
  );
  expect(outer.position.maxScrollExtent, greaterThan(0));
  final editable = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  expect(tester.getSize(editable).height, greaterThan(400));
}

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed != null;

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

// ── shared scaffold ──────────────────────────────────────────────────────

class _Harness extends StatefulWidget {
  final bool busy;
  const _Harness({this.busy = false});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = TextEditingController();
  int submits = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HermesFormPage(
    bodyKey: const ValueKey('harness-body'),
    title: 'Form',
    submitLabel: 'Save',
    submitKey: const ValueKey('harness-save'),
    busy: widget.busy,
    dirty: controller.text.isNotEmpty,
    onSubmit: controller.text.trim().isEmpty
        ? null
        : () => Navigator.of(context).pop('saved'),
    children: [
      TextField(
        key: const ValueKey('harness-field'),
        controller: controller,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

Future<List<Object?>> _openHarness(
  WidgetTester tester, {
  bool busy = false,
}) async {
  final results = <Object?>[];
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => results.add(
              await pushHermesFormPage<String>(
                context,
                builder: (_) => _Harness(busy: busy),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  // A busy page shows a spinner, which never settles.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return results;
}

void main() {
  setUp(PrivateRenderCaches.clearAll);

  group('HermesFormPage', () {
    testWidgets('Save is disabled until valid, then submits', (tester) async {
      _phone(tester, 360);
      final results = await _openHarness(tester);
      _expectFullScreen(tester, find.byKey(const ValueKey('harness-body')));
      expect(_enabled(tester, 'harness-save'), isFalse);
      await tester.enterText(find.byKey(const ValueKey('harness-field')), 'x');
      await tester.pump();
      expect(_enabled(tester, 'harness-save'), isTrue);
      await _tap(tester, 'harness-save');
      expect(results, ['saved']);
    });

    testWidgets('closing untouched leaves at once; with changes it asks', (
      tester,
    ) async {
      _phone(tester, 360);
      final results = await _openHarness(tester);
      await _tap(tester, 'form-page-close');
      expect(find.byKey(const ValueKey('harness-body')), findsNothing);
      expect(
        find.byKey(const ValueKey('form-page-discard-dialog')),
        findsNothing,
      );
      expect(results, [null]);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('harness-field')), 'x');
      await tester.pump();
      await _tap(tester, 'form-page-close');
      expect(
        find.byKey(const ValueKey('form-page-discard-dialog')),
        findsOneWidget,
      );
      expect(find.text('¿Descartar los cambios?'), findsOneWidget);
      await _tap(tester, 'form-page-keep-editing');
      expect(find.byKey(const ValueKey('harness-body')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('harness-field')))
            .controller!
            .text,
        'x',
      );

      // System back takes the same guard.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('form-page-discard-dialog')),
        findsOneWidget,
      );
      await _tap(tester, 'form-page-discard');
      expect(find.byKey(const ValueKey('harness-body')), findsNothing);
      expect(results, [null, null]);
    });

    testWidgets('while busy neither close nor Save is offered', (tester) async {
      _phone(tester, 360);
      await _openHarness(tester, busy: true);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('form-page-close')))
            .onPressed,
        isNull,
      );
      expect(_enabled(tester, 'harness-save'), isFalse);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('harness-body')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('form-page-discard-dialog')),
        findsNothing,
      );
    });

    testWidgets('English copy of the discard question', (tester) async {
      _phone(tester, 360);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => pushHermesFormPage<void>(
                  context,
                  builder: (_) => const _Harness(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('harness-field')), 'x');
      await tester.pump();
      await _tap(tester, 'form-page-close');
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);
    });
  });

  group('new project form', () {
    Future<Pc1215CreatingProjectsGateway> openCreate(
      WidgetTester tester, {
      double width = 390,
      List<String> picks = const ['/srv/garden'],
    }) async {
      _phone(tester, width);
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final gateway = Pc1215CreatingProjectsGateway.sample();
      final queue = [...picks];
      await tester.pumpWidget(
        _app(
          ProjectsCenterScreen(
            connection: SavedConnection(
              id: 'fp1215',
              label: 'QA',
              host: '127.0.0.1',
              port: 8642,
              apiKey: 'k',
            ),
            connectionManager: manager,
            gateway: gateway,
            chatLauncher: (_, _) {},
            folderPicker: (_, _) async =>
                queue.isEmpty ? null : queue.removeAt(0),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'pc1215-add');
      await _tap(tester, 'pc1215-add-create');
      return gateway;
    }

    for (final width in _phoneWidths) {
      testWidgets('opens full screen at ${width.toInt()} dp; the idea grows '
          'with the page instead of a mini scroll box', (tester) async {
        await openCreate(tester, width: width);
        final page = find.byKey(const ValueKey('pc1215-create-sheet'));
        _expectFullScreen(tester, page);
        expect(_enabled(tester, 'pc1215-create-submit'), isFalse);
        final idea = find.byKey(const ValueKey('pc1215-create-idea'));
        await tester.enterText(idea, _lines(40));
        await tester.pumpAndSettle();
        _expectGrowsWithPage(tester, idea, page);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('folder path preview and where IDEA.md lands', (tester) async {
      await openCreate(tester);
      expect(
        find.byKey(const ValueKey('pc1215-create-path-preview')),
        findsNothing,
      );
      await _tap(tester, 'pc1215-create-add-folder');
      expect(
        find.text('Los chats nuevos se abrirán en /srv/garden'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-idea')),
        'Plan the beds',
      );
      await tester.pumpAndSettle();
      expect(find.text('Se guardará como /srv/garden/IDEA.md'), findsOneWidget);
      expect(_enabled(tester, 'pc1215-create-submit'), isTrue);
    });

    testWidgets('closing with typed work asks first and never creates', (
      tester,
    ) async {
      final gateway = await openCreate(tester);
      await tester.enterText(
        find.byKey(const ValueKey('pc1215-create-name')),
        'Huerto',
      );
      await tester.pump();
      await _tap(tester, 'form-page-close');
      expect(
        find.byKey(const ValueKey('form-page-discard-dialog')),
        findsOneWidget,
      );
      await _tap(tester, 'form-page-keep-editing');
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsOne);
      await _tap(tester, 'form-page-close');
      await _tap(tester, 'form-page-discard');
      expect(find.byKey(const ValueKey('pc1215-create-sheet')), findsNothing);
      expect(gateway.writes.where((w) => w.$1 == 'projects.create'), isEmpty);
    });

    testWidgets('with the keyboard up the line being typed stays visible', (
      tester,
    ) async {
      await openCreate(tester, width: 360);
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      final idea = find.byKey(const ValueKey('pc1215-create-idea'));
      await tester.ensureVisible(idea);
      await tester.pumpAndSettle();
      final text = _lines(30);
      await tester.enterText(idea, text);
      await tester.pumpAndSettle();
      final editable = tester
          .state<EditableTextState>(
            find.descendant(of: idea, matching: find.byType(EditableText)),
          )
          .renderEditable;
      final caret = editable.localToGlobal(
        editable
            .getLocalRectForCaret(TextPosition(offset: text.length))
            .bottomLeft,
      );
      const keyboardTop = 800.0 - 336;
      expect(caret.dy, lessThanOrEqualTo(keyboardTop));
      expect(caret.dy, greaterThan(56));
      // Create stays reachable in the top bar.
      final save = tester.getRect(
        find.byKey(const ValueKey('pc1215-create-submit')),
      );
      expect(save.bottom, lessThan(keyboardTop));
    });
  });

  group('scheduled task (cron) editor', () {
    Future<List<Map<String, dynamic>>> openEditor(
      WidgetTester tester, {
      double width = 360,
    }) async {
      _phone(tester, width);
      final created = <Map<String, dynamic>>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path == '/api/cron/jobs') {
            return http.Response('[]', 200);
          }
          if (path == '/api/cron/delivery-targets') {
            return http.Response(
              jsonEncode({
                'targets': [
                  {'id': 'local', 'name': 'Local', 'home_target_set': true},
                ],
              }),
              200,
            );
          }
          if (path == '/api/model/options') {
            return http.Response(jsonEncode({'providers': []}), 200);
          }
          if (path == '/api/cron/blueprints') {
            return http.Response(jsonEncode({'blueprints': []}), 200);
          }
          if (request.method == 'POST' && path == '/api/cron/jobs') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            created.add(body);
            return http.Response(
              jsonEncode({'id': 'c1', ...body, 'enabled': true}),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      await tester.pumpWidget(
        _app(
          CronScreen(
            connection: SavedConnection(
              id: 'fp1215-cron',
              label: 'QA',
              host: 'hermes.local',
              port: 8642,
              apiKey: 'k',
              useHttps: true,
            ),
            clientOverride: client,
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New task'));
      await tester.pumpAndSettle();
      return created;
    }

    for (final width in _phoneWidths) {
      testWidgets('full screen at ${width.toInt()} dp; the instruction grows '
          'with the page', (tester) async {
        await openEditor(tester, width: width);
        final page = find.byKey(const ValueKey('cron-editor'));
        _expectFullScreen(tester, page);
        final prompt = find.byKey(const ValueKey('cron-prompt-field'));
        await tester.enterText(
          find.descendant(of: prompt, matching: find.byType(EditableText)),
          _lines(40),
        );
        await tester.pumpAndSettle();
        _expectGrowsWithPage(tester, prompt, page);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Save waits for an instruction; the payload is unchanged', (
      tester,
    ) async {
      final created = await openEditor(tester);
      expect(_enabled(tester, 'cron-editor-submit'), isFalse);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('cron-prompt-field')),
          matching: find.byType(EditableText),
        ),
        '   ',
      );
      await tester.pump();
      expect(_enabled(tester, 'cron-editor-submit'), isFalse);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('cron-prompt-field')),
          matching: find.byType(EditableText),
        ),
        'Summarize the day',
      );
      await tester.pump();
      expect(_enabled(tester, 'cron-editor-submit'), isTrue);
      await _tap(tester, 'cron-editor-submit');
      expect(created.single['prompt'], 'Summarize the day');
      expect(created.single['schedule'], '0 9 * * *');
      expect(created.single['deliver'], 'local');
    });

    testWidgets('shows the schedule in words and the next three runs', (
      tester,
    ) async {
      await openEditor(tester);
      expect(find.byKey(const ValueKey('cron-next-runs')), findsOneWidget);
      expect(find.text('Next runs'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        expect(
          tester.widget<Text>(find.byKey(ValueKey('cron-next-run-$i'))).data,
          endsWith('· 09:00'),
        );
      }
      expect(find.byKey(const ValueKey('cron-next-run-3')), findsNothing);
    });

    testWidgets('closing untouched leaves; typed work asks first', (
      tester,
    ) async {
      final created = await openEditor(tester);
      await _tap(tester, 'form-page-close');
      expect(find.byKey(const ValueKey('cron-editor')), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'New task'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('cron-name-field')),
          matching: find.byType(EditableText),
        ),
        'Brief',
      );
      await tester.pump();
      await _tap(tester, 'form-page-close');
      expect(find.text('Discard changes?'), findsOneWidget);
      await _tap(tester, 'form-page-discard');
      expect(find.byKey(const ValueKey('cron-editor')), findsNothing);
      expect(created, isEmpty);
    });

    test('upcoming runs are strictly increasing and stop when unknown', () {
      final from = DateTime(2026, 10, 9, 19); // Friday evening
      expect(cronUpcomingRuns('30 18 * * 1-5', from), [
        DateTime(2026, 10, 12, 18, 30),
        DateTime(2026, 10, 13, 18, 30),
        DateTime(2026, 10, 14, 18, 30),
      ]);
      expect(cronUpcomingRuns('0 9 * * *', DateTime(2026, 10, 7, 8)), [
        DateTime(2026, 10, 7, 9),
        DateTime(2026, 10, 8, 9),
        DateTime(2026, 10, 9, 9),
      ]);
      expect(cronUpcomingRuns('every 2h', from), isEmpty);
    });
  });

  group('kanban task form', () {
    testWidgets('new task is a full-screen form; Create waits for a title and '
        'sends the same payload', (tester) async {
      _phone(tester, 360);
      final events = StreamController<KanbanEvent>.broadcast();
      addTearDown(events.close);
      final posts = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/api/plugins/kanban/board':
            return http.Response('{"columns":[]}', 200);
          case '/api/plugins/kanban/profiles':
            return http.Response(
              '{"profiles":[{"name":"builder","is_default":true}]}',
              200,
            );
          case '/api/plugins/kanban/tasks':
            if (request.method == 'POST') {
              posts.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response('{"id":"t1","title":"x"}', 200);
            }
            return http.Response('{}', 404);
          default:
            return http.Response('{}', 404);
        }
      });
      final connection = SavedConnection(
        id: 'fp1215-kanban',
        label: 'QA',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'k',
        useHttps: true,
      );
      await tester.pumpWidget(
        _app(
          TasksScreen(
            connection: connection,
            clientOverride: KanbanClient(
              connection,
              dashboardClient: DashboardClient(
                host: 'hermes.local',
                manualToken: 'session-token',
                httpClientOverride: client,
              ),
            ),
            eventStreamOverride: events.stream,
          ),
          locale: const Locale('en'),
        ),
      );
      await pumpUntilLoaded(tester);
      await tester.tap(find.text('Create first task'));
      await pumpUntilLoaded(tester);

      final page = find.byKey(const ValueKey('kanban-task-form-surface'));
      _expectFullScreen(tester, page);
      expect(_enabled(tester, 'kanban-task-form-submit'), isFalse);
      final body = find.byKey(const ValueKey('kanban-task-form-body'));
      await tester.enterText(body, 'notes');
      await tester.pump();
      expect(_enabled(tester, 'kanban-task-form-submit'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('kanban-task-form-title')),
        'Ship it',
      );
      await tester.pump();
      expect(_enabled(tester, 'kanban-task-form-submit'), isTrue);

      await tester.enterText(body, _lines(40));
      await tester.pumpAndSettle();
      final inner = tester.state<ScrollableState>(
        find.descendant(of: body, matching: find.byType(Scrollable)).first,
      );
      expect(inner.position.maxScrollExtent, 0);
      await _tap(tester, 'kanban-task-form-submit');
      await pumpUntilLoaded(tester);
      expect(page, findsNothing);
      expect(posts.single['title'], 'Ship it');
      expect(posts.single['body'], _lines(40));
    });
  });

  group('integrations forms', () {
    Future<List<Object?>> open(WidgetTester tester, Widget form) async {
      _phone(tester, 360);
      final results = <Object?>[];
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => results.add(
                  await pushHermesFormPage<Object>(
                    context,
                    builder: (_) => form,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('MCP server: full screen, Create waits for name and command', (
      tester,
    ) async {
      final results = await open(tester, const McpServerDraftSurface());
      final page = find.byKey(const ValueKey('mcp-manual-create-surface'));
      _expectFullScreen(tester, page);
      expect(_enabled(tester, 'mcp-draft-submit'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('mcp-draft-name')),
        'files',
      );
      await tester.pump();
      expect(_enabled(tester, 'mcp-draft-submit'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('mcp-draft-command')),
        'npx',
      );
      final args = find.byKey(const ValueKey('mcp-draft-arguments'));
      await tester.enterText(args, _lines(30));
      await tester.pumpAndSettle();
      expect(
        tester
            .state<ScrollableState>(
              find
                  .descendant(of: args, matching: find.byType(Scrollable))
                  .first,
            )
            .position
            .maxScrollExtent,
        0,
      );
      expect(_enabled(tester, 'mcp-draft-submit'), isTrue);
      await _tap(tester, 'mcp-draft-submit');
      expect(results.single, isA<McpServerDraft>());
    });

    testWidgets('webhook: full screen, Create waits for a name', (
      tester,
    ) async {
      final results = await open(tester, const WebhookDraftSurface());
      _expectFullScreen(
        tester,
        find.byKey(const ValueKey('webhook-create-surface')),
      );
      expect(_enabled(tester, 'webhook-draft-submit'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('webhook-draft-name')),
        'deploy-hook',
      );
      await tester.pump();
      expect(_enabled(tester, 'webhook-draft-submit'), isTrue);
      await _tap(tester, 'webhook-draft-submit');
      expect(results.single, isNotNull);
    });
  });

  group('run template editor', () {
    testWidgets('new template opens full screen; Save waits for name and '
        'prompt and stores it', (tester) async {
      _phone(tester, 360);
      SharedPreferences.setMockInitialValues({});
      final store = await RunTemplateStore.load(
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showRunComposer(context, store),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nueva plantilla').last);
      await tester.pumpAndSettle();
      final page = find.byKey(const ValueKey('run-template-editor-surface'));
      _expectFullScreen(tester, page);
      expect(_enabled(tester, 'run-template-editor-save'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('run-template-editor-name')),
        'Resumen',
      );
      await tester.pump();
      expect(_enabled(tester, 'run-template-editor-save'), isFalse);
      final prompt = find.byKey(const ValueKey('run-template-editor-prompt'));
      await tester.enterText(prompt, _lines(30));
      await tester.pumpAndSettle();
      _expectGrowsWithPage(tester, prompt, page);
      expect(_enabled(tester, 'run-template-editor-save'), isTrue);
      await _tap(tester, 'run-template-editor-save');
      expect(page, findsNothing);
      expect(store.custom.where((t) => t.name == 'Resumen'), hasLength(1));
    });
  });
}
