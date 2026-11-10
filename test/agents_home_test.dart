// The Agents section as a screen of its own (1.4.0): reached from the
// drawer, no chat open, over the SSH servers of the saved connections.
// Servers, states and the two-pane layout; the commands of the section itself
// are covered by the herdr_agents_* tests.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/screens/herdr_agents_screen.dart';
import 'package:hermes_android/core/screens/ssh_credentials_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/agent_processes.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_herdr_server.dart';
import 'support/in_memory_compression_restore_storage.dart';

late Map<String, String> _secure;

SavedConnection _conn(String id, String label) => SavedConnection(
  id: id,
  label: label,
  host: 'example.invalid',
  port: 443,
  apiKey: '',
  useHttps: true,
);

void _setSsh(String id) {
  _secure['ssh_user_$id'] = 'demo';
  _secure['ssh_host_$id'] = 'example.invalid';
}

FakeHerdrServer _withAgents(String name) => FakeHerdrServer(
  agents: [
    FakeAgent('w1:p1', 'claude', HerdrAgentStatus.working, name: name),
    FakeAgent('w1:p2', 'codex', HerdrAgentStatus.blocked, seq: 2),
  ],
);

class _Rig {
  _Rig(this.servers);

  /// What each server answers, by connection id.
  final Map<String, FakeHerdrServer> servers;

  SshRemoteRunner Function(SavedConnection) get runnerFor =>
      (connection) => servers[connection.id]!.call;
}

Future<void> _open(
  WidgetTester tester, {
  required List<SavedConnection> connections,
  required Set<String> withSsh,
  required _Rig rig,
  String? active,
  Size size = const Size(420, 900),
  Widget Function()? screen,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  for (final c in connections) {
    await manager.upsertConnection(c);
  }
  if (active != null) await manager.setActiveConnection(active);
  withSsh.forEach(_setSsh);
  final ssh = SshManager(SecureStorage(), manager);
  final activeChats = ActiveChatService(
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  addTearDown(activeChats.dispose);
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: ApprovalPolicyService(prefs),
      fontSize: FontSizeService(prefs),
      sshManager: ssh,
      sftpTransfers: SftpTransferService(ssh, NotificationService(prefs)),
      sshSessions: SshSessionService(ssh),
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 500));
  unawaited(
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: AgentsHomeScreen.routeName),
        builder: (_) =>
            screen?.call() ?? AgentsHomeScreen(runnerFor: rig.runnerFor),
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    _secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return _secure[args['key']];
          case 'write':
            _secure[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            _secure.remove(args['key']);
            return null;
          case 'readAll':
            return Map<String, String>.from(_secure);
          case 'containsKey':
            return _secure.containsKey(args['key']);
          case 'deleteAll':
            _secure.clear();
            return null;
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  final one = _conn('a1', 'Alpha');
  final two = _conn('b2', 'Beta');

  testWidgets('no SSH anywhere: says so and offers to add one', (tester) async {
    await _open(
      tester,
      connections: [one],
      withSsh: {},
      rig: _Rig({}),
      active: 'a1',
    );
    expect(find.byKey(const ValueKey('agents-no-ssh')), findsOneWidget);
    expect(find.text('Add an SSH connection'), findsOneWidget);
    expect(find.text('Configure SSH'), findsOneWidget);
    expect(find.byKey(const ValueKey('agents-servers')), findsNothing);
    expect(find.byType(HerdrAgentsScreen), findsNothing);
  });

  testWidgets('one server: its agents, waiting ones first, no selector', (
    tester,
  ) async {
    final server = _withAgents('reviewer');
    await _open(
      tester,
      connections: [one, two],
      withSsh: {'a1'},
      rig: _Rig({'a1': server}),
      active: 'a1',
    );
    expect(find.byKey(const ValueKey('agents-servers')), findsNothing);
    // One header only: the server's name is its title, with a way back for
    // a page pushed on the stack and no bar above it.
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(const ValueKey('hda-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-server-name')), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsOneWidget);
    final blocked = tester.getTopLeft(
      find.byKey(const ValueKey('hda-row-w1:p2')),
    );
    final working = tester.getTopLeft(
      find.byKey(const ValueKey('hda-row-w1:p1')),
    );
    expect(blocked.dy, lessThan(working.dy));
    // Agents with Herdr: no look at the process table.
    expect(server.commands, isNot(contains(sshAgentProcessesCommand)));
  });

  testWidgets('several servers: a selector, the active one first', (
    tester,
  ) async {
    final alpha = _withAgents('alpha-agent');
    final beta = FakeHerdrServer(
      agents: [FakeAgent('w9:p1', 'gemini', HerdrAgentStatus.idle)],
    );
    await _open(
      tester,
      connections: [one, two],
      withSsh: {'a1', 'b2'},
      rig: _Rig({'a1': alpha, 'b2': beta}),
      active: 'b2',
    );
    // The server is a drop-down in the header, not a row of chips.
    expect(find.byKey(const ValueKey('agents-servers')), findsNothing);
    expect(find.byKey(const ValueKey('hda-server-pick')), findsOneWidget);
    // Active first: Beta's agents are on screen, Alpha's are not.
    expect(find.byKey(const ValueKey('hda-row-w9:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsNothing);
    String shown() => tester
        .widget<Text>(find.byKey(const ValueKey('hda-server-name')))
        .data!;
    expect(shown(), 'Beta');

    await tester.tap(find.byKey(const ValueKey('hda-server-pick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agents-servers')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('agents-server-b2'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('agents-server-a1'))).dy,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('agents-server-a1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w9:p1')), findsNothing);
    expect(shown(), 'Alpha');

    // The section left behind stops asking its server.
    final before = beta.commands.length;
    await tester.pump(const Duration(seconds: 30));
    expect(beta.commands.length, before);
  });

  testWidgets('no Herdr on the server: one line to install, and the code '
      'agents running without it', (tester) async {
    final server = FakeHerdrServer(installed: false)
      ..processes = ['bash', 'claude', '/usr/bin/claude', 'node', 'sshd'];
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({'a1': server}),
      active: 'a1',
    );
    expect(find.byKey(const ValueKey('hda-install-hint')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-outside-processes')), findsOneWidget);
    expect(find.text('Running without Herdr: claude ×2'), findsOneWidget);
    expect(
      find.text('Open them with Herdr to control them from here.'),
      findsOneWidget,
    );
    // The whole look is the one constant command.
    expect(
      server.commands.where((c) => c == sshAgentProcessesCommand).length,
      1,
    );
  });

  testWidgets('no Herdr and no agents running: no process line', (
    tester,
  ) async {
    final server = FakeHerdrServer(installed: false)
      ..processes = ['bash', 'node'];
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({'a1': server}),
      active: 'a1',
    );
    expect(find.byKey(const ValueKey('hda-install-hint')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-outside-processes')), findsNothing);
  });

  testWidgets('Herdr without agents: the empty state, and the ones outside', (
    tester,
  ) async {
    final server = FakeHerdrServer()..processes = ['codex', 'pi'];
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({'a1': server}),
      active: 'a1',
    );
    expect(find.text('No agents running'), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-install-hint')), findsNothing);
    expect(find.text('Running without Herdr: codex, pi'), findsOneWidget);
  });

  testWidgets('phone: the agent takes the screen, back returns to the list', (
    tester,
  ) async {
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({'a1': _withAgents('reviewer')}),
      active: 'a1',
    );
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-detail-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('hda-detail-back')));
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsOneWidget);
  });

  testWidgets('wide: list on the left, the open agent on the right', (
    tester,
  ) async {
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({'a1': _withAgents('reviewer')}),
      active: 'a1',
      size: const Size(1100, 800),
    );
    // Nothing open yet: a prompt on the right, the list on the left.
    expect(find.text('Pick an agent to see its screen'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();
    // Two panes: the list is beside the agent, so no second back arrow.
    expect(find.byKey(const ValueKey('hda-detail-back')), findsNothing);
    expect(find.byKey(const ValueKey('hda-detail')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsOneWidget);
    final row = tester.getRect(find.byKey(const ValueKey('hda-row-w1:p1')));
    final detail = tester.getRect(find.byKey(const ValueKey('hda-detail')));
    expect(row.right, lessThan(detail.left));
    // Opening another agent swaps the right pane, the list stays.
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p2')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('hda-row-w1:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hda-detail')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unfolded Fold (700 dp): two panes too, no overflow', (
    tester,
  ) async {
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({'a1': _withAgents('reviewer')}),
      active: 'a1',
      size: const Size(700, 840),
    );
    await tester.tap(find.byKey(const ValueKey('hda-row-w1:p1')));
    await tester.pump();
    await tester.pump();
    final row = tester.getRect(find.byKey(const ValueKey('hda-row-w1:p1')));
    final detail = tester.getRect(find.byKey(const ValueKey('hda-detail')));
    expect(row.right, lessThan(detail.left));
    expect(find.byKey(const ValueKey('hda-row-w1:p2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('2x text on a phone: no overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _open(
      tester,
      connections: [one, two],
      withSsh: {'a1', 'b2'},
      rig: _Rig({'a1': _withAgents('reviewer'), 'b2': _withAgents('other')}),
      active: 'a1',
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('hda-server-pick')), findsOneWidget);
  });

  testWidgets('agentsHomeAvailable follows the SSH profiles', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    await manager.upsertConnection(one);
    final ssh = SshManager(SecureStorage(), manager);
    expect(await agentsHomeAvailable(connections: manager, ssh: ssh), isFalse);
    _setSsh('a1');
    expect(await agentsHomeAvailable(connections: manager, ssh: ssh), isTrue);
    expect(AgentsHomeScreen.routeName, '/agents');
  });

  testWidgets('the section is switched off in the app: no entry anywhere', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    await manager.upsertConnection(one);
    final ssh = SshManager(SecureStorage(), manager);
    _setSsh('a1');
    // The suites run with the section on; the app ships it off.
    FeatureFlags.instance.agentsSection = false;
    addTearDown(() => FeatureFlags.instance.agentsSection = true);
    expect(await agentsHomeAvailable(connections: manager, ssh: ssh), isFalse);
  });

  testWidgets('the drawer entry opens Agents, no chat needed', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          key: scaffoldKey,
          drawer: HermesDrawer(
            connection: one,
            connManager: manager,
            current: DrawerSection.home,
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final entry = find.byKey(const ValueKey('drawer-agents'));
    final scrollable = find
        .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(entry, 80, scrollable: scrollable);
    expect(
      find.descendant(of: entry, matching: find.text('Agents')),
      findsOneWidget,
    );
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AgentsHomeScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('agents-no-ssh')), findsOneWidget);
  });

  // The session type is an advanced, off-by-default choice of the profile.
  testWidgets('SSH profile: Herdr/tmux sit under Advanced, plain shell by '
      'default, and an old saved value does not count', (tester) async {
    _secure['ssh_session_a1'] = 'herdr';
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({}),
      active: 'a1',
      screen: () => SshCredentialsScreen(connection: one),
    );
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-session-kind-herdr')), findsNothing);
    await tester.ensureVisible(find.text('Advanced'));
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    ChoiceChip chip(String id) =>
        tester.widget(find.byKey(ValueKey('ssh-session-kind-$id')));
    expect(chip('shell').selected, isTrue);
    expect(chip('herdr').selected, isFalse);
    expect(chip('tmux').selected, isFalse);
  });

  testWidgets('SSH profile: an explicit Herdr choice opens Advanced', (
    tester,
  ) async {
    _secure['ssh_session_a1'] = 'herdr-explicit';
    await _open(
      tester,
      connections: [one],
      withSsh: {'a1'},
      rig: _Rig({}),
      active: 'a1',
      screen: () => SshCredentialsScreen(connection: one),
    );
    await tester.pumpAndSettle();
    final herdr = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('ssh-session-kind-herdr')),
    );
    expect(herdr.selected, isTrue);
  });
}
