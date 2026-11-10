import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/ssh_terminal_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/utils/ssh_error.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/ssh_terminal_controls.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
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

  /// What the screen asked to type into the shell.
  final List<String> typed = [];

  @override
  void send(String connectionId, String data) => typed.add(data);

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
  ChatWorkspaceController? workspace,
  ValueNotifier<ChatWorkspaceToolbar>? paneToolbar,
  Widget Function(SavedConnection connection)? route,
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
      builder: (_) => route != null
          ? route(connection)
          : paneToolbar == null
          ? SshTerminalScreen(connection: connection)
          // As the workspace's Terminal tab builds it (v25).
          : ChatWorkspacePaneScope(
              tab: ChatWorkspaceTab.terminal,
              controller: workspace,
              toolbar: paneToolbar,
              child: SshTerminalScreen(
                connection: connection,
                paneTitle: 'deploy@example.invalid:22',
                paneMenu: [
                  ChatWorkspaceMenuEntry(
                    label: 'Edit credentials',
                    icon: Icons.edit_outlined,
                    onSelected: () {},
                  ),
                ],
              ),
            ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(SshTerminalScreen), findsOneWidget);
  return harness;
}

/// Lets a timer fire and the attempt it starts land on screen.
Future<void> _advance(WidgetTester tester, Duration by) async {
  await tester.pump(by);
  await tester.pump();
  await tester.pump();
}

const _bar = ValueKey('ssh-reconnect-bar');
const _expand = ValueKey('ssh-terminal-expand');

String _barText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('ssh-reconnect-message')))
    .data!;

/// The scrollback as text, with soft-wrapped rows joined back: the app's
/// fixed 1.10 text scale leaves ~54 columns at 800 dp, so a long notice
/// spans two buffer lines.
String _scrollback(Terminal terminal) {
  final out = StringBuffer();
  for (final line in terminal.buffer.lines.toList()) {
    if (!line.isWrapped && out.isNotEmpty) out.write('\n');
    out.write(line.toString());
  }
  return out.toString();
}

double _fontSize(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize;

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

  testWidgets('expand hides the header and grows the font, Back shrinks', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _open(tester);
    final terminalState = tester.state(find.byType(TerminalView));

    expect(find.byType(HermesAppBar), findsOneWidget);
    // the owner (ronda Fold 2): no quick commands row, expanded or not.
    expect(find.byTooltip('Edit quick commands'), findsNothing);
    expect(find.byKey(const ValueKey('ssh-key-bar')), findsOneWidget);
    expect(_fontSize(tester), SshTerminalScreen.fontSize);
    expect(find.bySemanticsLabel('Expand terminal'), findsOneWidget);

    await tester.tap(find.byKey(_expand));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(HermesAppBar), findsNothing);
    expect(find.byTooltip('Edit quick commands'), findsNothing);
    expect(find.byKey(const ValueKey('ssh-key-bar')), findsOneWidget);
    expect(_fontSize(tester), SshTerminalScreen.expandedFontSize);
    expect(find.bySemanticsLabel('Shrink terminal'), findsOneWidget);
    expect(
      identical(tester.state(find.byType(TerminalView)), terminalState),
      isTrue,
    );

    await tester.tap(find.byKey(_expand));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HermesAppBar), findsOneWidget);
    expect(_fontSize(tester), SshTerminalScreen.fontSize);

    // Back while expanded shrinks the terminal instead of leaving.
    await tester.tap(find.byKey(_expand));
    await tester.pump(const Duration(milliseconds: 300));
    final navigator = Navigator.of(
      tester.element(find.byType(SshTerminalScreen)),
    );
    await navigator.maybePop();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SshTerminalScreen), findsOneWidget);
    expect(find.byType(HermesAppBar), findsOneWidget);
    expect(
      identical(tester.state(find.byType(TerminalView)), terminalState),
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('missing Herdr: the terminal says nothing, plain shell goes on', (
    tester,
  ) async {
    final h = await _open(tester, kind: SshSessionKind.herdr);
    h.sessions.live!.missingProgram.value = SshSessionKind.herdr;
    await tester.pump();

    // No notice, no install command, no «keep the plain shell» button: the
    // hint lives in the Agents section.
    expect(find.byKey(const ValueKey('ssh-missing-program')), findsNothing);
    expect(find.byKey(const ValueKey('ssh-use-plain-shell')), findsNothing);
    expect(find.textContaining('install.sh'), findsNothing);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(h.sent, isEmpty);
    expect(h.sessions.connects, 0);
  });

  testWidgets('a dropped plain shell reconnects and says it is a new one', (
    tester,
  ) async {
    final h = await _open(tester);
    h.sessions.onConnect = (attempt, _) async => attempt == 1
        ? h.session(
            phase: SshSessionPhase.error,
            failure: TimeoutException('timed out'),
          )
        : h.session();

    h.drop();
    await tester.pump();
    expect(find.byKey(_bar), findsOneWidget);
    expect(_barText(tester), 'Reconnecting…');
    expect(find.byKey(const ValueKey('ssh-key-bar')), findsNothing);

    await _advance(tester, const Duration(milliseconds: 999));
    expect(h.sessions.connects, 0);
    await _advance(tester, const Duration(milliseconds: 1));
    expect(h.sessions.connects, 1);
    // The failed attempt keeps the terminal and its scrollback on screen.
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(_barText(tester), 'Reconnecting…');

    await _advance(tester, const Duration(seconds: 2));
    expect(h.sessions.connects, 2);
    expect(
      _barText(tester),
      'Reconnected to a new shell: the previous process was lost.',
    );
    expect(
      _scrollback(h.terminal),
      contains('Reconnected to a new shell: the previous process was lost.'),
    );
    expect(find.byKey(const ValueKey('ssh-key-bar')), findsOneWidget);

    await _advance(tester, const Duration(seconds: 4));
    expect(find.byKey(_bar), findsNothing);
    expect(h.sessions.connects, 2);
  });

  testWidgets('a dropped tmux session is reattached, not replaced', (
    tester,
  ) async {
    final h = await _open(tester, kind: SshSessionKind.tmux);
    h.sessions.onConnect = (_, _) async => h.session(kind: SshSessionKind.tmux);

    h.drop();
    await tester.pump();
    await _advance(tester, const Duration(seconds: 1));

    expect(h.sessions.connects, 1);
    expect(_barText(tester), 'Reconnected: session reattached.');
    expect(_scrollback(h.terminal), isNot(contains('new shell')));
  });

  testWidgets('gives up after five attempts and offers the manual button', (
    tester,
  ) async {
    final h = await _open(tester);
    h.sessions.onConnect = (_, _) async => h.session(
      phase: SshSessionPhase.error,
      failure: Exception('Connection refused'),
    );

    h.drop();
    await tester.pump();
    for (final seconds in [1, 2, 4, 8, 15]) {
      await _advance(tester, Duration(seconds: seconds));
    }
    expect(h.sessions.connects, 5);
    expect(_barText(tester), 'Offline');
    expect(find.byKey(const ValueKey('ssh-reconnect-button')), findsOneWidget);

    await _advance(tester, const Duration(minutes: 3));
    expect(h.sessions.connects, 5);
  });

  testWidgets('a changed host key stops the automatic attempts (TOFU)', (
    tester,
  ) async {
    final h = await _open(tester);
    final decisions = <bool>[];
    const prompt = SshHostKeyPrompt(
      type: 'ssh-ed25519',
      fingerprint: 'SHA256:changed',
      isNew: false,
      changed: true,
    );
    h.sessions.onConnect = (_, onHostKey) async {
      final trusted = await onHostKey(prompt);
      decisions.add(trusted);
      return trusted
          ? h.session()
          : h.session(
              phase: SshSessionPhase.error,
              failure: SSHHostkeyError('Hostkey verification failed'),
            );
    };

    h.drop();
    await tester.pump();
    await _advance(tester, const Duration(seconds: 1));

    expect(decisions, [false]);
    expect(
      _barText(tester),
      'The server key needs your review: reconnect manually.',
    );
    expect(find.text('Server key changed'), findsNothing);
    await _advance(tester, const Duration(minutes: 2));
    expect(h.sessions.connects, 1);

    // The manual button asks the user through the TOFU dialog.
    await tester.tap(find.byKey(const ValueKey('ssh-reconnect-button')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Server key changed'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(decisions, [false, false]);
    expect(h.sessions.connects, 2);
  });

  testWidgets('a shell that exits waits for the user', (tester) async {
    final h = await _open(tester);
    h.sessions.onConnect = (_, _) async => h.session();

    final session = h.sessions.live!;
    session.end = SshSessionEnd.remoteExit;
    session.phase.value = SshSessionPhase.closed;
    await tester.pump();

    expect(_barText(tester), 'Session closed');
    expect(find.byKey(const ValueKey('ssh-reconnect-button')), findsOneWidget);
    await _advance(tester, const Duration(minutes: 1));
    expect(h.sessions.connects, 0);
  });

  testWidgets('leaving the screen cancels the pending reconnect', (
    tester,
  ) async {
    final h = await _open(tester);
    h.sessions.onConnect = (_, _) async => h.session();

    h.drop();
    await tester.pump();
    Navigator.of(tester.element(find.byType(SshTerminalScreen))).pop();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(SshTerminalScreen), findsNothing);

    await _advance(tester, const Duration(minutes: 1));
    expect(h.sessions.connects, 0);
    expect(tester.takeException(), isNull);
  });

  // Review R5A P2-B4-2: a terminal that stops being seen (a route over it,
  // an off-screen tab) does not go on reconnecting beside the one that is
  // seen; it carries on when seen again.
  testWidgets('a covered terminal waits to reconnect until it is seen', (
    tester,
  ) async {
    final h = await _open(tester);
    h.sessions.onConnect = (_, _) async => h.session();

    h.drop();
    await tester.pump();
    expect(_barText(tester), 'Reconnecting…');
    final navigator = Navigator.of(
      tester.element(find.byType(SshTerminalScreen)),
    );
    unawaited(
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _advance(tester, const Duration(seconds: 30));
    expect(h.sessions.connects, 0, reason: 'nothing tried while covered');

    navigator.pop();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _advance(tester, const Duration(seconds: 2));
    expect(h.sessions.connects, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the session on purpose never reconnects', (
    tester,
  ) async {
    final h = await _open(tester);
    h.sessions.onConnect = (_, _) async => h.session();

    await tester.tap(find.byTooltip('Close SSH session'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(h.sessions.closed, [_connection]);
    await _advance(tester, const Duration(minutes: 1));
    expect(h.sessions.connects, 0);
  });

  // the owner (ronda Fold 2): the terminal shows only the key buttons. The
  // quick commands row («Tiempo activo · Disco · Mem · ⚙») is gone; the
  // commands a user saved for a server stay stored, untouched.
  testWidgets('no quick commands row; saved commands stay stored', (
    tester,
  ) async {
    const saved = '[{"label":"Logs","command":"journalctl -n 50"}]';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ssh_cmds_$_connection', saved);
    await _open(tester);

    expect(find.byKey(const ValueKey('ssh-key-bar')), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.byTooltip('Edit quick commands'), findsNothing);
    expect(find.text('Logs'), findsNothing);
    expect(prefs.getString('ssh_cmds_$_connection'), saved);
  });

  // Review P2-1: a failure no retry can fix says what it is.
  testWidgets('rejected credentials say so instead of «Offline»', (
    tester,
  ) async {
    final h = await _open(tester);
    final failure = SSHAuthFailError('denied');
    h.sessions.onConnect = (_, _) async =>
        h.session(phase: SshSessionPhase.error, failure: failure);

    h.drop();
    await tester.pump();
    await _advance(tester, const Duration(seconds: 1));

    expect(h.sessions.connects, 1);
    final expected = localizedSshError(
      lookupStrings(const Locale('en')),
      failure,
    );
    expect(expected, isNot('Offline'));
    expect(_barText(tester), expected);
    expect(find.byKey(const ValueKey('ssh-reconnect-button')), findsOneWidget);
    await _advance(tester, const Duration(minutes: 1));
    expect(h.sessions.connects, 1);
  });

  // ORDEN-WS-FIDELIDAD point 2: in the workspace pane the Terminal tab is
  // the terminal, its header and actions on the floating bar.
  testWidgets('in the pane: no header, the bar gets keys and the menu', (
    tester,
  ) async {
    final workspace = ChatWorkspaceController();
    addTearDown(workspace.dispose);
    workspace.open(ChatWorkspaceTab.terminal);
    final toolbar = ValueNotifier(ChatWorkspaceToolbar.none);
    addTearDown(toolbar.dispose);
    final h = await _open(tester, workspace: workspace, paneToolbar: toolbar);

    expect(find.byType(HermesAppBar), findsNothing);
    expect(find.byKey(_expand), findsNothing);
    // Ola 1 (audit T1): the pane's surface shows, not a page grey of its
    // own over it.
    expect(
      tester
          .widget<Scaffold>(
            find
                .descendant(
                  of: find.byType(SshTerminalScreen),
                  matching: find.byType(Scaffold),
                )
                .first,
          )
          .backgroundColor,
      Colors.transparent,
    );
    // Ola 6 (mock 136 v2-A `.ctx`): two lines. The server in mono with
    // its name, «SSH» with the shield; the folder once the shell says it.
    expect(
      find.text('deploy@example.invalid:22 · Remote', findRichText: true),
      findsOneWidget,
    );
    final host = tester.widget<Text>(
      find.byKey(const ValueKey('ssh-terminal-pane-host')),
    );
    final hostSpans = host.textSpan! as TextSpan;
    expect(
      (hostSpans.children!.first as TextSpan).style!.fontFamily,
      HermesType.monoFamily,
    );
    expect(host.maxLines, 1);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ssh-terminal-pane-header')),
        matching: find.text('SSH'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ssh-terminal-pane-folder')),
      findsNothing,
    );
    final header = find.byKey(const ValueKey('ssh-terminal-pane-header'));
    final headerBefore = tester.getSize(header);
    final terminalBefore = tester.getSize(find.byType(TerminalView));
    // The shell says where it is (OSC 7, as zsh, fish or vte.sh do).
    h.terminal.write('\x1b]7;file://example.invalid/home/deploy/proyecto\x07');
    await tester.pump();
    // REVIEW-T2-D P3-4: its line was already kept; nothing resizes, so the
    // server's shell is not resized under what is running.
    expect(tester.getSize(header), headerBefore);
    expect(tester.getSize(find.byType(TerminalView)), terminalBefore);
    final folder = tester.widget<Text>(
      find.byKey(const ValueKey('ssh-terminal-pane-folder')),
    );
    expect(folder.data, '~/proyecto');
    expect(folder.style!.fontFamily, HermesType.monoFamily);
    expect(
      find.byKey(const ValueKey('ssh-terminal-pane-card')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ssh-key-bar')), findsOneWidget);
    // Mock 136 v2-A (Cadu's look): the terminal in its card, the keys in a
    // rounded pill under it, outside the card.
    const card = ValueKey('ssh-terminal-pane-card');
    const pill = ValueKey('ssh-key-bar-pill');
    expect(find.byKey(pill), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(card), matching: find.byKey(pill)),
      findsNothing,
    );
    expect(
      tester.getRect(find.byKey(pill)).top,
      greaterThanOrEqualTo(tester.getRect(find.byKey(card)).bottom),
    );
    final pillBox = tester.widget<Container>(find.byKey(pill));
    expect(
      (pillBox.decoration! as ShapeDecoration).shape,
      isA<StadiumBorder>(),
    );
    // The composer keeps the keyboard beside it (review P2-F4-5).
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).autofocus,
      isFalse,
    );

    final tools = toolbar.value;
    expect(tools.keysShown, isTrue);
    expect(tools.onToggleKeys, isNotNull);
    // A plain shell has no Herdr.
    expect(tools.onHerdr, isNull);
    expect(tools.menu.map((entry) => entry.label), [
      'Files (SFTP)',
      'Sessions',
      'Edit credentials',
      'Close SSH session',
    ]);

    tools.onToggleKeys!();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('ssh-key-bar')), findsNothing);
    expect(toolbar.value.keysShown, isFalse);

    // Files is the workspace's own tab, beside the terminal.
    toolbar.value.menu.first.onSelected();
    expect(workspace.active, ChatWorkspaceTab.files);
    expect(workspace.tabs, contains(ChatWorkspaceTab.terminal));
  });

  // the owner (ronda Fold 2), point 1: on the open Fold held sideways, with
  // the keyboard up, the Terminal in the workspace pane had one line left.
  // Measured as the terminal's rows (what TerminalView lays out).
  group('the Terminal in the pane with the keyboard up', () {
    Future<(_Harness, ChatWorkspaceController)> openInHost(
      WidgetTester tester,
      Size physical,
    ) async {
      tester.view
        ..physicalSize = physical
        ..devicePixelRatio = 2.2;
      addTearDown(tester.view.reset);
      final workspace = ChatWorkspaceController()
        ..open(ChatWorkspaceTab.terminal);
      addTearDown(workspace.dispose);
      final h = await _open(
        tester,
        route: (connection) => ChatWorkspaceHost(
          controller: workspace,
          chat: const Scaffold(body: SizedBox.expand()),
          tabBuilder: (_, tab) => SshTerminalScreen(
            connection: connection,
            paneTitle: 'deploy@example.invalid:22',
          ),
        ),
      );
      return (h, workspace);
    }

    Future<void> keyboard(WidgetTester tester, double physical) async {
      tester.view.viewInsets = FakeViewPadding(bottom: physical);
      await tester.pump();
      await tester.pump();
      // Ola 7: the pane's bar folds and comes back in HermesMotion.base.
      await tester.pump(HermesMotion.base);
    }

    for (final (name, physical) in const [
      ('2048x1546 px', Size(2048, 1546)),
      ('933x704 dp', Size(933 * 2.2, 704 * 2.2)),
    ]) {
      testWidgets('$name, an 800 px keyboard: 8 lines or more', (tester) async {
        final (h, _) = await openInHost(tester, physical);
        expect(find.byKey(const ValueKey('ssh-key-bar')), findsOneWidget);
        final before = h.terminal.viewHeight;

        await keyboard(tester, 800);
        expect(tester.takeException(), isNull);
        final after = h.terminal.viewHeight;
        debugPrint('[fold2] $name: $before rows, $after with the keyboard');
        expect(after, greaterThanOrEqualTo(8));
        // The pane's bar (selector and actions) and the server line step
        // aside behind one button; the keys stay, in one thin row.
        expect(
          find.byKey(const ValueKey('chat-workspace-tabs-folded')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('chat-workspace-tabs')), findsNothing);
        expect(
          find.byKey(const ValueKey('ssh-terminal-pane-header')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('chat-workspace-actions')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('chat-workspace-show-tools')),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('ssh-key-bar'))).height,
          SshTerminalKeyBar.denseHeight,
        );

        // Closed again: everything as it was.
        await keyboard(tester, 0);
        expect(tester.takeException(), isNull);
        expect(h.terminal.viewHeight, before);
        expect(
          find.byKey(const ValueKey('chat-workspace-tabs')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('chat-workspace-actions')),
          findsOneWidget,
        );
      });
    }

    testWidgets('typing, the pane goes to the whole width and comes back '
        'when the keyboard closes, the session kept', (tester) async {
      final (h, workspace) = await openInHost(tester, const Size(2048, 1546));
      final terminalState = tester.state(find.byType(TerminalView));
      await keyboard(tester, 800);

      // The folded bar opens from its one button; «Ampliar» is in its pill
      // of actions.
      await tester.tap(find.byKey(const ValueKey('chat-workspace-show-tools')));
      await tester.pump();
      await tester.pump(HermesMotion.base);
      expect(
        find.byKey(const ValueKey('chat-workspace-actions')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('chat-workspace-expand')));
      await tester.pump();
      await tester.pump();
      expect(workspace.mode, ChatWorkspaceMode.workspace);
      expect(tester.takeException(), isNull);

      // Back to the split once the keyboard has closed: waited for (a few
      // frames at most), then checked.
      await keyboard(tester, 0);
      for (var frame = 0; frame < 10; frame++) {
        if (workspace.mode == ChatWorkspaceMode.split) break;
        await tester.pump();
      }
      expect(workspace.mode, ChatWorkspaceMode.split);
      expect(
        identical(tester.state(find.byType(TerminalView)), terminalState),
        isTrue,
      );
      expect(h.sessions.closed, isEmpty);
      expect(h.sessions.connects, 0);
    });
  });

  group('a line to type (attach a session)', () {
    testWidgets('is typed once into the live shell, with its Enter', (
      tester,
    ) async {
      final h = await _open(
        tester,
        route: (c) => SshTerminalScreen(
          connection: c,
          initialCommand: "'/x/herdr' 'agent' 'attach' 'w1:p1'",
        ),
      );
      expect(h.sessions.typed, ["'/x/herdr' 'agent' 'attach' 'w1:p1'\n"]);
      await tester.pump(const Duration(seconds: 2));
      expect(h.sessions.typed.length, 1);
    });

    final unsafe = ['a\nrm -rf x', 'a\u0000b', 'a\u001bb', 'a\u007fb', ''];
    for (var i = 0; i < unsafe.length; i++) {
      testWidgets('an unsafe line #$i is not typed', (tester) async {
        final h = await _open(
          tester,
          route: (c) =>
              SshTerminalScreen(connection: c, initialCommand: unsafe[i]),
        );
        expect(h.sessions.typed, isEmpty);
      });
    }

    testWidgets('a plain terminal types nothing on its own', (tester) async {
      final h = await _open(tester);
      expect(h.sessions.typed, isEmpty);
    });
  });
}
