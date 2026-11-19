// Regression tests for the Reddit report (profile scope):
// Projects shows the launch/default profile's projects whatever profile is
// selected in Console.
//
// Contract evidence (NousResearch/hermes-agent main 491f984, 2026-11-13):
//  * tui_gateway/methods_projects.py::_projects_method — every projects.*
//    handler is `profile_scoped`.
//  * tui_gateway/server.py::_profile_scoped — `params['profile']` selects that
//    profile's HERMES_HOME (and so its projects.db); without it the handler
//    runs in the connection's ticket profile or the LAUNCH profile.
//  * tui_gateway/server.py::_profile_home + hermes_cli/profiles.py
//    ::get_profile_dir — an explicit "default" resolves to the default home
//    even when the gateway was launched under another profile.
//  * apps/shared/src/gateway-contract.openrpc.json — ProjectsTreeParams,
//    ProjectsProjectSessionsParams, ProjectsCreateParams… all declare
//    `profile` (also present at 7e9eb8d, 2026-10-17).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/rpc_frame_helpers.dart';

final _connection = SavedConnection(
  id: 'projects-profile',
  label: 'Hermes QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
);

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'test');
}

/// A Hermes that keeps one projects.db per profile, like upstream.
final class _ProfileServer {
  final List<Map<String, dynamic>> requests = [];

  /// Every socket the client opened (a reconnect opens a new one).
  final List<_Channel> channels = [];

  /// Profiles whose `projects.tree` answer is held until released.
  final Map<String, Completer<void>> holds = {};

  /// Extra overview nodes, like the discovery tier of Hermes 0.23.1: a repo
  /// whose sessions the tree never lists (all `oneshot`), so `projects.tree`
  /// counts them while `projects.project_sessions` answers `project: null`.
  final List<Map<String, dynamic>> discovered = [];

  /// The saved projects have no chats (sessionCount 0) and the drill-in
  /// finds them.
  bool emptyProjects = false;

  Map<String, dynamic> _tree(String profile) => {
    'active_id': null,
    'projects': [
      {
        'id': 'p_$profile',
        'label': '${profile[0].toUpperCase()}${profile.substring(1)} project',
        'sessionCount': emptyProjects ? 0 : 1,
        'repos': <Object>[],
      },
      ...discovered,
    ],
  };

  Future<Map<String, dynamic>> answer(Map<String, dynamic> frame) async {
    final method = frame['method'] as String;
    final params = Map<String, dynamic>.from(
      (frame['params'] as Map?) ?? const {},
    );
    requests.add({'method': method, 'params': params});
    switch (method) {
      case 'projects.update' || 'projects.create' || 'projects.add_folder':
        return {
          'project': {
            'id': 'p_new',
            'folders': [
              {'path': '/srv/work'},
            ],
            'primary_path': '/srv/work',
          },
        };
      case 'projects.delete':
        return {'projects': <Object>[]};
      case 'projects.project_sessions':
        // A saved, empty project is found by the drill-in; everything else
        // here mirrors a project the drill-in does not build.
        if (emptyProjects) {
          return {
            'project': {
              'id': params['project_id'],
              'label': 'Work project',
              'sessionCount': 0,
              'repos': <Object>[],
            },
          };
        }
        return {'project': null};
    }
    if (method != 'projects.tree') return <String, dynamic>{};
    // No `profile` = the launch profile, exactly like `_profile_scoped`.
    final profile = (params['profile'] as String?)?.trim();
    final effective = profile == null || profile.isEmpty ? 'launch' : profile;
    await holds[effective]?.future;
    return _tree(effective);
  }

  /// `profile` of every call of [method], in order.
  List<Object?> profilesOf(String method) => [
    for (final r in requests)
      if (r['method'] == method)
        (r['params'] as Map<String, dynamic>)['profile'],
  ];

  List<Object?> treeProfiles() => [
    for (final r in requests)
      if (r['method'] == 'projects.tree')
        (r['params'] as Map<String, dynamic>)['profile'],
  ];
}

final class _Channel implements WebSocketChannel {
  _Channel(this.server) {
    server.channels.add(this);
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final _ProfileServer server;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  /// The server drops this socket (network change, gateway restart).
  Future<void> drop() => _incoming.close();

  @override
  int? get closeCode => _incoming.isClosed ? 1001 : null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  late final WebSocketSink sink = _Sink((data) async {
    final frame = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
    if (frame['method'] == 'gateway.ping') return;
    if (isClientCapabilitiesFrame(frame)) {
      _incoming.add(jsonEncode(clientCapabilitiesResponse(frame)));
      return;
    }
    final result = await server.answer(frame);
    if (_incoming.isClosed) return;
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
    );
  }, () => _incoming.close());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements WebSocketSink {
  _Sink(this.onAdd, this.onClose);
  final void Function(dynamic) onAdd;
  final void Function() onClose;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => onAdd(data);

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) {
      onClose();
      _done.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TuiGatewayClient _client(_ProfileServer server) => TuiGatewayClient(
  _connection,
  dashboard: _Dashboard(),
  channelFactory: (_, _) => _Channel(server),
  heartbeatInterval: const Duration(hours: 1),
  heartbeatDeadline: const Duration(hours: 2),
);

Future<ConnectionManager> _manager({String profile = ''}) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  if (profile.isNotEmpty) {
    await manager.setActiveProfile(_connection.id, profile);
  }
  return manager;
}

Future<void> _pump(
  WidgetTester tester,
  ConnectionManager manager,
  TuiGatewayClient client, {
  ProjectChatLauncher? chatLauncher,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: ProjectsCenterScreen(
        connection: _connection,
        connectionManager: manager,
        gateway: client,
        chatLauncher: chatLauncher,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('[RED] Projects reads the selected profile, not the launch one', (
    tester,
  ) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);

    expect(server.treeProfiles(), isNotEmpty);
    expect(server.treeProfiles().toSet(), {'work'});
    expect(find.text('Work project'), findsOneWidget);
    expect(find.text('Launch project'), findsNothing);
  });

  testWidgets('[RED] the default profile is asked for explicitly', (
    tester,
  ) async {
    final server = _ProfileServer();
    final manager = await _manager();
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);

    expect(server.treeProfiles().toSet(), {'default'});
    expect(find.text('Default project'), findsOneWidget);
  });

  testWidgets('[RED] switching profile reloads and drops the previous '
      "profile's projects", (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    expect(find.text('Work project'), findsOneWidget);

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);

    expect(server.treeProfiles().last, 'personal');
    expect(find.text('Personal project'), findsOneWidget);
    expect(find.text('Work project'), findsNothing);
  });

  testWidgets('[RED] an answer for the previous profile that lands after the '
      'switch is discarded', (tester) async {
    final server = _ProfileServer();
    final hold = server.holds['work'] = Completer<void>();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    expect(find.text('Work project'), findsNothing);

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    hold.complete();
    await _settle(tester);

    expect(find.text('Personal project'), findsOneWidget);
    expect(find.text('Work project'), findsNothing);
  });

  // Review B2 (console-reddit-independent-review.md): the screen used to
  // set the profile on the SHARED gateway, so a detail or a menu opened for
  // profile A wrote to profile B after a switch. Writes (and the detail's
  // own reads) belong to the profile the project was opened under.
  Future<void> openWorkProject(WidgetTester tester) async {
    await tester.tap(find.text('Work project'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('pj1215-detail-menu')), findsOneWidget);
  }

  // E7 (emulator QA against the real instance, 2026-11-14): «hermes-console ·
  // 131 chats» opened on «No chats in this folder yet». Read-only evidence:
  // all 140 sessions under that folder in the profile are `oneshot`, which
  // the 0.23.1 project tree excludes (methods_projects.py:321) while the
  // discovery scan counts them (:278-291); the drill-in (no discovery)
  // answers `project: null`. Console must not claim the folder is empty.
  testWidgets('[RED] E7 a folder the server counts but never lists says so, '
      'instead of «No chats yet»', (tester) async {
    final server = _ProfileServer()
      ..discovered.add({
        'id': '/srv/hermes-console',
        'label': 'hermes-console',
        'path': '/srv/hermes-console',
        'isAuto': true,
        'sessionCount': 131,
        'previewSessions': <Object>[],
        'repos': [
          {
            'id': '/srv/hermes-console',
            'label': 'hermes-console',
            'path': '/srv/hermes-console',
            'groups': <Object>[],
            'sessionCount': 0,
          },
        ],
      });
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await tester.tap(find.text('hermes-console'));
    await _settle(tester);

    expect(server.profilesOf('projects.project_sessions'), ['work']);
    expect(find.text('No chats in this folder yet'), findsNothing);
    expect(find.text("131 chats aren't listed here"), findsOneWidget);
  });

  testWidgets('[CONTROL] E7 a saved project with no chats keeps «No chats '
      'in this folder yet»', (tester) async {
    final server = _ProfileServer()..emptyProjects = true;
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await tester.tap(find.text('Work project'));
    await _settle(tester);
    expect(find.text('No chats in this folder yet'), findsOneWidget);
  });

  testWidgets('[RED] B2 detail opened under A, profile switched to B: '
      'delete goes to A', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await openWorkProject(tester);

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-detail-menu')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('pj1215-menu-delete')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-menu-delete')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-delete-confirm')));
    await _settle(tester);

    expect(server.profilesOf('projects.delete'), ['work']);
  });

  testWidgets('[RED] B2 detail opened under A, profile switched to B: '
      'rename goes to A', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await openWorkProject(tester);

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-detail-menu')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-menu-rename')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('pj1215-rename-field')),
      'Renamed',
    );
    await tester.tap(find.byKey(const ValueKey('pj1215-rename-save')));
    await _settle(tester);

    expect(server.profilesOf('projects.update'), ['work']);
  });

  testWidgets('[RED] B2 a menu opened under A, profile switched while it is '
      'open: set-active goes to A', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await openWorkProject(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-detail-menu')));
    await _settle(tester);

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-menu-set-active')));
    await _settle(tester);

    expect(server.profilesOf('projects.set_active'), ['work']);
  });

  testWidgets('[RED] B2 the detail re-reads its own project under A after '
      'a switch to B', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await openWorkProject(tester);
    expect(server.profilesOf('projects.project_sessions'), everyElement('work'));

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    final indicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator).last,
    );
    final refresh = indicator.onRefresh();
    await _settle(tester);
    await refresh;

    expect(server.profilesOf('projects.project_sessions'), isNotEmpty);
    expect(
      server.profilesOf('projects.project_sessions').toSet(),
      {'work'},
    );
  });

  testWidgets('[CONTROL] B2 the list itself follows the new profile after a '
      'switch made from a detail', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await openWorkProject(tester);
    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    expect(server.treeProfiles().last, 'personal');
  });

  test('every projects.* read and write carries the selected profile', () async {
    final server = _ProfileServer();
    final client = _client(server);
    addTearDown(client.close);
    // Review B2: the profile is a pinned view, never state of the client.
    final work = client.pinProjectProfile('work');

    await work.projectTree();
    await work.projectSessions('p_work');
    await work.updateProject('p_work', name: 'Renamed');
    await work.createProject(name: 'New', primaryPath: '/srv/work');
    await work.createProjectFromFolders(name: 'New', folders: ['/srv/work']);
    await work.addProjectFolder('p_work', '/srv/other');
    await work.setActiveProject('p_work');
    await work.deleteProject('p_work');
    await work.scanProjectRepos();

    final projectCalls = [
      for (final r in server.requests)
        if ((r['method'] as String).startsWith('projects.')) r,
    ];
    expect(
      [for (final r in projectCalls) r['method']],
      containsAll(<String>[
        'projects.tree',
        'projects.project_sessions',
        'projects.update',
        'projects.create',
        'projects.add_folder',
        'projects.set_active',
        'projects.delete',
        'projects.discover_repos',
      ]),
    );
    for (final r in projectCalls) {
      expect(
        (r['params'] as Map<String, dynamic>)['profile'],
        'work',
        reason: '${r['method']}',
      );
    }
  });

  testWidgets('after a switch, a pull-to-refresh keeps reading the new '
      'profile', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    final before = server.treeProfiles().length;

    final indicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator).first,
    );
    final refresh = indicator.onRefresh();
    await _settle(tester);
    await refresh;

    expect(server.treeProfiles().length, greaterThan(before));
    expect(server.treeProfiles().last, 'personal');
    expect(find.text('Personal project'), findsOneWidget);
    expect(find.text('Work project'), findsNothing);
  });

  test('the selected profile survives a reconnect of the socket', () async {
    final server = _ProfileServer();
    final client = _client(server);
    addTearDown(client.close);
    final work = client.pinProjectProfile('work');
    await work.projectTree();
    expect(server.channels, hasLength(1));

    await server.channels.single.drop();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        await work.projectTree();
        lastError = null;
        if (server.channels.length > 1) break;
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(lastError, isNull);
    expect(server.channels.length, greaterThan(1), reason: 'reconnected');
    expect(server.treeProfiles().toSet(), {'work'});
  });

  test('a one-off profile overrides the pinned one (move to project)', () async {
    final server = _ProfileServer();
    final client = _client(server);
    addTearDown(client.close);
    client.pinProjectProfile('work');
    await client.projectTree(profile: 'personal');
    expect(server.treeProfiles(), ['personal']);
  });

  test('B2: two pinned views of one client never leak into each other, '
      'even interleaved across awaits', () async {
    final server = _ProfileServer();
    final hold = server.holds['work'] = Completer<void>();
    final client = _client(server);
    addTearDown(client.close);
    final work = client.pinProjectProfile('work');
    final personal = client.pinProjectProfile('personal');
    final slow = work.projectTree();
    await personal.deleteProject('p_personal');
    await client.projectTree();
    hold.complete();
    await slow;
    expect(server.profilesOf('projects.delete'), ['personal']);
    expect(server.treeProfiles(), ['work', null]);
  });

  test('without a selected profile nothing changes on the wire', () async {
    final server = _ProfileServer();
    final client = _client(server);
    addTearDown(client.close);
    await client.projectTree();
    expect(server.requests.single['params'], {'preview_limit': 3});
  });

  // Review P2: «new chat» in a detail opened under A, after
  // the active profile changed to B, opened the chat under B with A's folder.
  testWidgets('[RED] P2 a chat launched from a detail opened under A, '
      'profile switched to B, opens under A', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    final launched = <ProjectChatRequest>[];
    await _pump(
      tester,
      manager,
      client,
      chatLauncher: (_, request) => launched.add(request),
    );
    await openWorkProject(tester);

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-detail-new-chat')));
    await _settle(tester);

    expect(launched, hasLength(1));
    expect(launched.single.isNewChat, isTrue);
    expect(launched.single.profile, 'work');
  });

  testWidgets('[CONTROL] P2 without a switch the chat opens under the '
      'active profile', (tester) async {
    final server = _ProfileServer();
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    final launched = <ProjectChatRequest>[];
    await _pump(
      tester,
      manager,
      client,
      chatLauncher: (_, request) => launched.add(request),
    );
    await openWorkProject(tester);
    await tester.tap(find.byKey(const ValueKey('pj1215-detail-new-chat')));
    await _settle(tester);
    expect(launched.single.profile, 'work');
  });

  // Review P1: an auto project's id is its folder path, the
  // same in every profile; hiding it under A hid it under B too.
  testWidgets('[RED] P1 hiding an auto folder under A keeps it visible '
      'under B, and hidden again back under A', (tester) async {
    final server = _ProfileServer()
      ..discovered.add({
        'id': '/srv/shared',
        'label': 'shared',
        'path': '/srv/shared',
        'isAuto': true,
        'sessionCount': 2,
        'previewSessions': <Object>[],
        'repos': <Object>[],
      });
    final manager = await _manager(profile: 'work');
    final client = _client(server);
    addTearDown(client.close);
    await _pump(tester, manager, client);
    expect(find.text('shared'), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('pj1215-card-/srv/shared')));
    await _settle(tester);
    final hide = find.byKey(const ValueKey('pj1215-menu-hide'));
    await tester.ensureVisible(hide);
    await _settle(tester);
    await tester.tap(hide);
    await _settle(tester);
    expect(find.text('shared'), findsNothing, reason: 'hidden under work');

    await manager.setActiveProfile(_connection.id, 'personal');
    await _settle(tester);
    expect(find.text('shared'), findsOneWidget, reason: 'visible under personal');

    await manager.setActiveProfile(_connection.id, 'work');
    await _settle(tester);
    expect(find.text('shared'), findsNothing, reason: 'still hidden under work');
  });
}
