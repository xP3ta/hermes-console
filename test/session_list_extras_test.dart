// Conversations list extras: move a chat to a project, export it as JSON, copy
// its id, group by human day, sort and filter by project. All of it lives in
// the existing row menu and ⋯ menu: the screen gains no buttons.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/session_workspace_move.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/session_export_service.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connectionId = 'conn-se1215';

Map<String, dynamic> _row(
  String id, {
  required String title,
  required DateTime active,
  DateTime? started,
  String? cwd,
  String? gitRepoRoot,
  String? profile,
  int tokens = 0,
  double? cost,
}) {
  final last = active.millisecondsSinceEpoch ~/ 1000;
  final start =
      (started ?? active.subtract(const Duration(minutes: 5)))
          .millisecondsSinceEpoch ~/
      1000;
  return {
    'id': id,
    '_lineage_root_id': id,
    'title': title,
    'preview': '',
    'model': 'model-a',
    'source': 'mobile',
    'message_count': 2,
    'is_active': false,
    'started_at': start,
    'ended_at': last,
    'last_active': last,
    'archived': false,
    'cwd': ?cwd,
    'git_repo_root': ?gitRepoRoot,
    'profile': ?profile,
    'input_tokens': tokens,
    'estimated_cost_usd': ?cost,
  };
}

http.Response _page(Iterable<Map<String, dynamic>> rows) => http.Response(
  jsonEncode({
    'sessions': rows.toList(growable: false),
    'total': rows.length,
    'limit': 50,
    'offset': 0,
  }),
  200,
);

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: _connectionId,
  label: 'Extras QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'gateway-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
  readOnly: readOnly,
);

ApiClient _api() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'gateway-key',
  connectionId: _connectionId,
  httpClient: MockClient((request) async {
    if (request.url.path == '/health' || request.url.path == '/api/sessions') {
      return http.Response('{}', 200);
    }
    return http.Response('{}', 404);
  }),
);

/// A gateway that serves a fixed project tree and records every move.
final class _MoveGateway extends TuiGatewayClient {
  _MoveGateway(super.connection, {required this.tree});

  final ProjectTreeSnapshot tree;
  Object? moveError;
  Completer<void>? moveGate;
  int treeCalls = 0;
  int closes = 0;
  final List<({String key, String cwd, String? profile})> moves = [];

  @override
  Future<ProjectTreeSnapshot> projectTree() async {
    treeCalls++;
    return tree;
  }

  @override
  Future<SessionWorkspaceMoveResult> moveSessionWorkspace({
    required String sessionKey,
    required String cwd,
    String? profile,
  }) async {
    moves.add((key: sessionKey, cwd: cwd, profile: profile));
    await moveGate?.future;
    final error = moveError;
    if (error != null) throw error;
    return SessionWorkspaceMoveResult(
      cwd: cwd,
      branch: 'main',
      gitRepoRoot: cwd,
    );
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

ProjectTreeSnapshot _tree() => ProjectTreeSnapshot.fromJson({
  'projects': [
    {'id': 'p-a', 'label': 'Alpha', 'path': '/srv/work/alpha'},
    {'id': 'p-b', 'label': 'Beta', 'path': '/srv/work/beta'},
    {'id': 'p-old', 'label': 'Old', 'path': '/srv/work/old', 'archived': true},
    {'id': 'p-none', 'label': 'Loose', 'isNoProject': true, 'path': '/srv'},
  ],
});

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 80,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixedNow = DateTime(2026, 10, 14, 12, 0);
  late _MoveGateway gateway;
  final shared = <String>[];
  final secureValues = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // No socket lingers after its last lease: every test gets a fresh one.
    SharedGatewayPool.debugDefaultLinger = Duration.zero;
    SessionListScreen.debugResetMoveSupport();
    addTearDown(() => SharedGatewayPool.debugDefaultLinger = null);
    shared.clear();
    secureValues.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments is Map
                ? Map<Object?, Object?>.from(call.arguments as Map)
                : const <Object?, Object?>{};
            switch (call.method) {
              case 'write':
                secureValues[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureValues[args['key']];
              case 'readAll':
                return Map<String, String>.of(secureValues);
              case 'delete':
                secureValues.remove(args['key']);
                return null;
            }
            return null;
          },
        );
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  Future<ConnectionManager> pump(
    WidgetTester tester,
    List<Map<String, dynamic>> rows, {
    bool readOnly = false,
    DateTime Function()? clock,
    SessionExportService? exporter,
    ProjectTreeSnapshot? tree,
    Widget Function(Widget screen)? wrap,
    double height = 2532,
  }) async {
    tester.view.physicalSize = Size(1170, height);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          return _page(rows);
        }
        return http.Response('{}', 404);
      }),
    );
    final api = _api();
    final repository = SessionRepository(dashboard, api);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });
    final connection = _connection(readOnly: readOnly);
    gateway = _MoveGateway(connection, tree: tree ?? _tree());
    final screen = SessionListScreen(
      connection: connection,
      connManager: manager,
      clientOverride: api,
      repositoryOverride: repository,
      clockOverride: clock ?? () => fixedNow,
      gatewayFactory: (_) => gateway,
      sessionExporter: exporter,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: wrap == null ? screen : wrap(screen),
      ),
    );
    return manager;
  }

  Future<void> openRowMenu(WidgetTester tester, String title) async {
    await tester.longPress(find.text(title));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('session-actions-surface')),
      findsOneWidget,
    );
  }

  Strings strings(WidgetTester tester) =>
      Strings.of(tester.element(find.byType(SessionListScreen)));

  List<Map<String, dynamic>> twoRows({String? cwd}) => [
    _row(
      'stored-aaaa-1111',
      title: 'Plan de viaje',
      active: fixedNow.subtract(const Duration(hours: 1)),
      cwd: cwd,
      profile: 'default',
    ),
    _row(
      'stored-bbbb-2222',
      title: 'Otra charla',
      active: fixedNow.subtract(const Duration(hours: 2)),
    ),
  ];

  group('row menu', () {
    testWidgets('gains exactly the two new entries', (tester) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openRowMenu(tester, 'Plan de viaje');

      final s = strings(tester);
      expect(find.text(s.se1215MenuMove), findsOneWidget);
      expect(find.text(s.se1215MenuExport), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-actions-surface')),
          matching: find.byType(ListTile),
        ),
        findsNWidgets(9),
      );
    });

    testWidgets('read only: no move, export still there', (tester) async {
      await pump(tester, twoRows(), readOnly: true);
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openRowMenu(tester, 'Plan de viaje');

      final s = strings(tester);
      expect(find.text(s.se1215MenuMove), findsNothing);
      expect(find.text(s.se1215MenuExport), findsOneWidget);
    });

    testWidgets('the screen gains no buttons', (tester) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      final before = find.byType(IconButton).evaluate().length;
      await openRowMenu(tester, 'Plan de viaje');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton).evaluate().length, before);
    });

    testWidgets('Copy ID copies the stored id and says so', (tester) async {
      String? copied;
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openRowMenu(tester, 'Plan de viaje');

      await tester.tap(find.text(strings(tester).slMenuCopyId));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(copied, 'stored-aaaa-1111');
      expect(find.text(strings(tester).slIdCopied), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('move to project', () {
    Future<void> openMoveSheet(WidgetTester tester) async {
      await openRowMenu(tester, 'Plan de viaje');
      await tester.tap(find.text(strings(tester).se1215MenuMove));
      await tester.pumpAndSettle();
    }

    testWidgets('asks nothing until the entry is tapped', (tester) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openRowMenu(tester, 'Plan de viaje');
      expect(gateway.treeCalls, 0);
      await tester.tap(find.text(strings(tester).se1215MenuMove));
      await tester.pumpAndSettle();
      expect(gateway.treeCalls, 1);
    });

    testWidgets('lists only active projects with a folder, not the current', (
      tester,
    ) async {
      await pump(tester, twoRows(cwd: '/srv/work/alpha'));
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);

      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Old'), findsNothing);
      expect(find.text('Loose'), findsNothing);
    });

    testWidgets('moves with the stored id, the folder and the profile', (
      tester,
    ) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();

      expect(gateway.moves, [
        (key: 'stored-aaaa-1111', cwd: '/srv/work/beta', profile: 'default'),
      ]);
      expect(find.text(strings(tester).se1215MovedTo('Beta')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('the row follows the move without reloading the list', (
      tester,
    ) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));

      // Beta is now the session's own project: it is no longer a destination.
      await openMoveSheet(tester);
      expect(find.text('Beta'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('the lease goes back to the pool once', (tester) async {
      final before = SharedGatewayPool.instance.leaseCount;
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);
      expect(SharedGatewayPool.instance.leaseCount, before + 1);
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(SharedGatewayPool.instance.leaseCount, before);
      await tester.pump(const Duration(seconds: 6));
    });

    for (final code in const [4007, 4016, 4017, 5007]) {
      testWidgets('server error $code says it could not move and keeps the '
          'row', (tester) async {
        await pump(tester, twoRows());
        await _pumpUntil(tester, find.text('Plan de viaje'));
        await openMoveSheet(tester);
        gateway.moveError = DesktopControlFailure(
          code == 4007
              ? DesktopControlFailureKind.unavailable
              : DesktopControlFailureKind.rejected,
          code: code,
        );

        await tester.tap(find.text('Beta'));
        await tester.pumpAndSettle();

        expect(find.text(strings(tester).se1215MoveFailed), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        // Unchanged: Beta is still a destination.
        await openMoveSheet(tester);
        expect(find.text('Beta'), findsOneWidget);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(SharedGatewayPool.instance.leaseCount, 0);
      });
    }

    testWidgets('a socket drop during the move fails once, no retry', (
      tester,
    ) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);
      gateway.moveError = const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
      );

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));

      expect(gateway.moves, hasLength(1));
      expect(find.text(strings(tester).se1215MoveFailed), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('no other project with a folder says so', (tester) async {
      await pump(
        tester,
        twoRows(),
        tree: ProjectTreeSnapshot.fromJson({
          'projects': [
            {'id': 'p-none', 'label': 'Loose', 'isNoProject': true},
          ],
        }),
      );
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);

      expect(find.text(strings(tester).se1215MoveNoProjects), findsOneWidget);
      expect(gateway.moves, isEmpty);
      expect(SharedGatewayPool.instance.leaseCount, 0);
    });

    testWidgets('a server without the method hides the entry afterwards', (
      tester,
    ) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);
      gateway.moveError = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      );
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));

      await openRowMenu(tester, 'Plan de viaje');
      expect(find.text(strings(tester).se1215MenuMove), findsNothing);
    });

    testWidgets('an answer after leaving the screen changes nothing and '
        'throws nothing', (tester) async {
      await pump(tester, twoRows());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openMoveSheet(tester);
      gateway.moveGate = Completer<void>();
      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(gateway.moves, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      gateway.moveGate!.complete();
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(SharedGatewayPool.instance.leaseCount, 0);
    });
  });

  group('export JSON', () {
    Directory? temp;

    SessionExportService exporter({
      List<Map<String, dynamic>>? messages,
      Object? failWith,
      Completer<void>? gate,
      int cap = sessionExportMaxJsonChars,
    }) => SessionExportService(
      readMessages: (id, {profile, maxJsonChars}) async {
        await gate?.future;
        if (failWith != null) throw failWith;
        return messages ??
            [
              {'message_id': 'm0', 'role': 'user', 'content': 'hola'},
            ];
      },
      tempDir: () async =>
          temp ??= await Directory.systemTemp.createTemp('se1215-export'),
      shareFile: (file) async => shared.add(file.readAsStringSync()),
      clock: () => DateTime.utc(2026, 10, 4, 12),
      maxJsonChars: cap,
    );

    tearDown(() async {
      if (temp != null && temp!.existsSync()) {
        await temp!.delete(recursive: true);
      }
      temp = null;
    });

    testWidgets('opens the share sheet once with the Desktop shaped file', (
      tester,
    ) async {
      await pump(tester, twoRows(), exporter: exporter());
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openRowMenu(tester, 'Plan de viaje');

      await tester.runAsync(() async {
        await tester.tap(find.text(strings(tester).se1215MenuExport));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(shared, hasLength(1));
      final json = jsonDecode(shared.single) as Map<String, dynamic>;
      expect(json['session_id'], 'stored-aaaa-1111');
      expect(json['title'], 'Plan de viaje');
      expect(json['message_count'], 1);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('over the cap warns and shares nothing', (tester) async {
      await pump(
        tester,
        twoRows(),
        exporter: exporter(
          failWith: const SessionTranscriptTooLargeException(),
        ),
      );
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openRowMenu(tester, 'Plan de viaje');

      await tester.runAsync(() async {
        await tester.tap(find.text(strings(tester).se1215MenuExport));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(find.text(strings(tester).se1215ExportTooLarge), findsOneWidget);
      expect(shared, isEmpty);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('leaving the screen mid export shares nothing', (tester) async {
      final gate = Completer<void>();
      await pump(tester, twoRows(), exporter: exporter(gate: gate));
      await _pumpUntil(tester, find.text('Plan de viaje'));
      await openRowMenu(tester, 'Plan de viaje');
      await tester.runAsync(() async {
        await tester.tap(find.text(strings(tester).se1215MenuExport));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(seconds: 1));

      expect(shared, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('date sections', () {
    DateTime at(int y, int m, int d, [int h = 12, int min = 0]) =>
        DateTime(y, m, d, h, min);

    testWidgets('02:00 seen from 05:00 is yesterday', (tester) async {
      await pump(tester, [
        _row('night', title: 'De madrugada', active: at(2026, 10, 14, 2)),
      ], clock: () => at(2026, 10, 14, 5));
      await _pumpUntil(tester, find.text('De madrugada'));
      final s = strings(tester);
      expect(find.text(s.sesDateYesterday.toUpperCase()), findsOneWidget);
      expect(find.text(s.sesDateToday.toUpperCase()), findsNothing);
    });

    testWidgets('02:00 seen from 03:00 still shares the human day: today', (
      tester,
    ) async {
      await pump(tester, [
        _row('night', title: 'De madrugada', active: at(2026, 10, 14, 2)),
      ], clock: () => at(2026, 10, 14, 3));
      await _pumpUntil(tester, find.text('De madrugada'));
      final s = strings(tester);
      expect(find.text(s.sesDateToday.toUpperCase()), findsOneWidget);
      expect(find.text(s.sesDateYesterday.toUpperCase()), findsNothing);
    });

    testWidgets('weeks, months and years get their own sections', (
      tester,
    ) async {
      await pump(height: 7000, tester, [
        _row('r1', title: 'Hoy mismo', active: at(2026, 10, 14, 9)),
        _row('r2', title: 'Ayer', active: at(2026, 10, 13)),
        _row('r3', title: 'Lunes', active: at(2026, 10, 12)),
        _row('r4', title: 'Semana pasada', active: at(2026, 10, 7)),
        _row('r5', title: 'Principios de mes', active: at(2026, 10, 2)),
        _row('r6', title: 'En septiembre', active: at(2026, 9, 20)),
        _row('r7', title: 'El año pasado', active: at(2025, 12, 20)),
      ]);
      await _pumpUntil(tester, find.text('Hoy mismo'));
      final s = strings(tester);
      for (final label in [
        s.sesDateToday,
        s.sesDateYesterday,
        s.se1215DateThisWeek,
        s.se1215DateLastWeek,
        s.se1215DateThisMonth,
        'Septiembre',
        'Diciembre de 2025',
      ]) {
        expect(find.text(label.toUpperCase()), findsOneWidget, reason: label);
      }
    });
  });

  group('sort', () {
    List<Map<String, dynamic>> priced() => [
      _row(
        'cheap',
        title: 'Barata',
        active: fixedNow.subtract(const Duration(hours: 1)),
        cost: 0.1,
        tokens: 900,
      ),
      _row(
        'dear',
        title: 'Cara',
        active: fixedNow.subtract(const Duration(hours: 3)),
        cost: 9.5,
        tokens: 50,
      ),
      _row(
        'mid',
        title: 'Intermedia',
        active: fixedNow.subtract(const Duration(hours: 2)),
        cost: 1,
        tokens: 400,
      ),
    ];

    double top(WidgetTester tester, String title) =>
        tester.getTopLeft(find.text(title)).dy;

    Future<void> chooseSort(WidgetTester tester, String label) async {
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('the default is activity', (tester) async {
      await pump(tester, priced());
      await _pumpUntil(tester, find.text('Barata'));
      expect(top(tester, 'Barata'), lessThan(top(tester, 'Intermedia')));
      expect(top(tester, 'Intermedia'), lessThan(top(tester, 'Cara')));
    });

    testWidgets('by cost puts the dearest first and keeps pinned on top', (
      tester,
    ) async {
      await pump(tester, priced());
      await _pumpUntil(tester, find.text('Barata'));
      await chooseSort(tester, strings(tester).se1215SortCost);

      expect(top(tester, 'Cara'), lessThan(top(tester, 'Intermedia')));
      expect(top(tester, 'Intermedia'), lessThan(top(tester, 'Barata')));

      // Pin the cheapest one: it goes above the dearest.
      await tester.drag(find.text('Barata'), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(top(tester, 'Barata'), lessThan(top(tester, 'Cara')));
    });

    testWidgets('by tokens is one section, by cost too', (tester) async {
      await pump(tester, priced());
      await _pumpUntil(tester, find.text('Barata'));
      final s = strings(tester);
      await chooseSort(tester, s.se1215SortTokens);
      expect(top(tester, 'Barata'), lessThan(top(tester, 'Intermedia')));
      expect(top(tester, 'Intermedia'), lessThan(top(tester, 'Cara')));
      expect(find.text(s.sesDateToday.toUpperCase()), findsNothing);
    });

    testWidgets('the choice survives reopening the screen', (tester) async {
      await pump(tester, priced());
      await _pumpUntil(tester, find.text('Barata'));
      await chooseSort(tester, strings(tester).se1215SortCost);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, priced());
      await _pumpUntil(tester, find.text('Barata'));
      await tester.pumpAndSettle();

      expect(top(tester, 'Cara'), lessThan(top(tester, 'Barata')));
    });

    testWidgets('opening the menu makes no request', (tester) async {
      await pump(tester, priced());
      await _pumpUntil(tester, find.text('Barata'));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(gateway.treeCalls, 0);
    });
  });

  group('project filter', () {
    testWidgets('only appears once the project tree was loaded', (
      tester,
    ) async {
      await pump(tester, [
        _row(
          'in-a',
          title: 'En Alpha',
          active: fixedNow.subtract(const Duration(hours: 1)),
          cwd: '/srv/work/alpha/src',
        ),
        _row(
          'in-b',
          title: 'En Beta',
          active: fixedNow.subtract(const Duration(hours: 2)),
          gitRepoRoot: '/srv/work/beta',
        ),
        _row(
          'none',
          title: 'Suelta',
          active: fixedNow.subtract(const Duration(hours: 3)),
        ),
      ]);
      await _pumpUntil(tester, find.text('En Alpha'));
      final s = strings(tester);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text(s.se1215ProjectFilter), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Loading the tree for a move makes the filter available.
      await openRowMenu(tester, 'Suelta');
      await tester.tap(find.text(s.se1215MenuMove));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(gateway.treeCalls, 1);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.se1215ProjectFilter));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(find.text('En Alpha'), findsOneWidget);
      expect(find.text('En Beta'), findsNothing);
      expect(find.text('Suelta'), findsNothing);
      expect(gateway.treeCalls, 1, reason: 'the filter reuses the loaded tree');
    });
  });
}
