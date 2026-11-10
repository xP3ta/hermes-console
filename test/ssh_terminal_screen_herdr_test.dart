import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/ssh_terminal_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/widgets/ssh_terminal_controls.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_compression_restore_storage.dart';

typedef _OnConnect =
    Future<SshTerminalSession> Function(
      int attempt,
      Future<bool> Function(SshHostKeyPrompt) onHostKey,
    );

/// Session service without sockets: the test decides what every connect
/// returns and sees every host-key decision.
class _FakeSessions extends SshSessionService {
  _FakeSessions(super.ssh);

  SshTerminalSession? live;
  _OnConnect? onConnect;
  int connects = 0;
  final List<String> closed = [];

  @override
  SshTerminalSession? of(String connectionId) =>
      live?.connectionId == connectionId ? live : null;

  @override
  Future<SshTerminalSession> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async {
    connects++;
    final session = await onConnect!(connects, onHostKey);
    live = session;
    return session;
  }

  @override
  void close(String connectionId) {
    closed.add(connectionId);
    final session = live;
    if (session != null) {
      session.end ??= SshSessionEnd.closedByApp;
      session.phase.value = SshSessionPhase.closed;
    }
    live = null;
  }
}

const _connection = 'ssh-f1';

class _Harness {
  _Harness(this.sessions, this.terminal, this.sent);

  final _FakeSessions sessions;
  final Terminal terminal;

  /// Everything the screen typed into the terminal's shell.
  final List<String> sent;

  SshTerminalSession session({
    SshSessionPhase phase = SshSessionPhase.ready,
    SshSessionKind kind = SshSessionKind.shell,
    Object? failure,
  }) => SshTerminalSession(_connection, terminal)
    ..kind = kind
    ..failure = failure
    ..phase.value = phase;

  /// The live connection drops (no exit status).
  void drop() {
    final session = sessions.live!;
    session.end = SshSessionEnd.connectionLost;
    session.phase.value = SshSessionPhase.closed;
  }
}

Future<_Harness> _open(
  WidgetTester tester, {
  SshSessionKind kind = SshSessionKind.shell,
  SshRemoteRunner? herdr,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final connection = SavedConnection(
    id: _connection,
    label: 'Remote',
    host: 'example.invalid',
    port: 443,
    apiKey: '',
    useHttps: true,
  );
  await manager.upsertConnection(connection);
  final ssh = SshManager(SecureStorage(), manager);
  final sessions = _FakeSessions(ssh);
  final terminal = Terminal(maxLines: 1000);
  final sent = <String>[];
  terminal.onOutput = sent.add;
  final harness = _Harness(sessions, terminal, sent);
  sessions.live = harness.session(kind: kind);
  if (herdr != null) sessions.live!.herdr = HerdrMonitor(run: herdr);
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
      sshSessions: sessions,
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 500));
  Navigator.of(tester.element(find.byType(Navigator).first)).push(
    MaterialPageRoute<void>(
      builder: (_) => SshTerminalScreen(connection: connection),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(SshTerminalScreen), findsOneWidget);
  return harness;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            secure.remove(args['key']);
            return null;
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
          case 'deleteAll':
            secure.clear();
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

  // 1.4.0 plain terminal: the terminal is a shell and nothing else. Herdr's
  // agents live in their own section, never over the terminal.
  for (final kind in SshSessionKind.values) {
    testWidgets('${kind.id} session: no banner, no panel, no polling', (
      tester,
    ) async {
      var runs = 0;
      final stdout = File(
        'test/fixtures/herdr/snapshot_0_9_5.json',
      ).readAsStringSync();
      final h = await _open(
        tester,
        kind: kind,
        herdr: (_) async {
          runs++;
          return SshRemoteResult(stdout: stdout, exitCode: 0);
        },
      );
      await tester.pump(const Duration(seconds: 12));

      expect(find.byKey(const ValueKey('herdr-agent-banner')), findsNothing);
      expect(find.byKey(const ValueKey('herdr-panel-button')), findsNothing);
      expect(find.byKey(const ValueKey('herdr-panel')), findsNothing);
      expect(find.text('Shell'), findsNothing);
      expect(find.textContaining('No agent detected'), findsNothing);
      expect(find.textContaining('Herdr'), findsNothing);
      expect(find.textContaining('tmux'), findsNothing);
      // The terminal never reads Herdr's state on its own.
      expect(runs, 0);
      expect(h.sent, isEmpty);
      expect(find.byType(TerminalView), findsOneWidget);
    });
  }

  testWidgets('a plain shell shows no Herdr banner or button', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('herdr-agent-banner')), findsNothing);
    expect(find.byKey(const ValueKey('herdr-panel-button')), findsNothing);
  });

  // The cropped terminal of build 9803: a card over the terminal and the
  // keyboard up left it a few rows, with the key row cut. At 2x text with
  // the keyboard open the terminal takes all the room the app bar, the key
  // row and the keyboard leave, and every key can be reached.
  testWidgets('keyboard open at 2x text: the terminal fills the space and '
      'every key is reachable', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearAllTestValues();
    });
    final h = await _open(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);

    final appBar = tester.getRect(find.byType(AppBar));
    final terminal = tester.getRect(find.byType(TerminalView));
    final keys = tester.getRect(find.byKey(const ValueKey('ssh-key-bar')));
    // Nothing between the app bar and the terminal.
    expect(terminal.top - appBar.bottom, lessThan(2));
    // The key row sits right under the terminal, above the keyboard.
    expect(keys.top, greaterThanOrEqualTo(terminal.bottom - 1));
    expect(keys.bottom, lessThanOrEqualTo(800 - 300));
    // All the room: app bar + key row + keyboard take the rest.
    expect(terminal.height, greaterThan(300));

    // The row shows a fade where more keys wait, and they all arrive.
    expect(find.byKey(const ValueKey('ssh-key-bar-fade-end')), findsOneWidget);
    final bar = find.byKey(const ValueKey('ssh-key-bar'));
    for (final cap in sshTerminalKeyCaps) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('ssh-key-$cap')),
        60,
        scrollable: find.descendant(of: bar, matching: find.byType(Scrollable)),
      );
      expect(find.byKey(ValueKey('ssh-key-$cap')), findsOneWidget);
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('ssh-key-bar-fade-end')), findsNothing);
    expect(
      find.byKey(const ValueKey('ssh-key-bar-fade-start')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('ssh-key-→')));
    await tester.tap(find.byKey(const ValueKey('ssh-key-↑')));
    await tester.pump();
    expect(h.sent, ['\x1b[C', '\x1b[A']);
    expect(tester.takeException(), isNull);
  });
}
