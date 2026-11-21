import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_dictation.dart';
import 'package:hermes_android/core/screens/ssh_terminal_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_compose_uploads.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _QaClient implements SSHClient {
  @override
  bool get isClosed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QaSessions extends SshSessionService {
  _QaSessions(super.ssh);

  SshTerminalSession? live;

  @override
  SshTerminalSession? of(String connectionId) =>
      live?.connectionId == connectionId ? live : null;

  @override
  Future<SshTerminalSession> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async => live!;

  @override
  void close(String connectionId) {}
}

class _QaDictation extends RoomDictation {
  @override
  bool get recording => false;

  @override
  bool get transcribing => false;

  @override
  ValueListenable<double>? get level => null;

  @override
  Future<void> start({
    required String currentText,
    required ValueChanged<String> onText,
    required ValueChanged<RoomDictationFailure> onFailure,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}

Future<({SshTerminalSession session, List<String> sent})> _mount(
  WidgetTester tester, {
  required Size size,
  double keyboardHeight = 0,
  bool inPane = false,
  ThemeMode themeMode = ThemeMode.dark,
}) async {
  tester.view
    ..physicalSize = size * 3
    ..devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    'theme_mode': themeMode == ThemeMode.light ? 'light' : 'dark',
  });
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  const id = 'qa-term';
  final connection = SavedConnection(
    id: id,
    label: 'devbox',
    host: 'devbox.invalid',
    port: 443,
    apiKey: '',
    useHttps: true,
  );
  await manager.upsertConnection(connection);
  final ssh = SshManager(SecureStorage(), manager);
  final sessions = _QaSessions(ssh);
  final terminal = Terminal(maxLines: 1000);
  final sent = <String>[];
  terminal.onOutput = (data) => sent.add(sessions.live!.applyModifiers(data));
  final session = SshTerminalSession(id, terminal)
    ..client = _QaClient()
    ..phase.value = SshSessionPhase.ready;
  sessions.live = session;

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

  final screen = SshTerminalScreen(
    connection: connection,
    paneTitle: inPane ? 'user@devbox:22' : null,
    composeDictation: _QaDictation(),
    composePicker: (_) async => <SshComposePick>[],
  );
  final paneToolbar = ValueNotifier<ChatWorkspaceToolbar>(
    const ChatWorkspaceToolbar(),
  );
  addTearDown(paneToolbar.dispose);

  Navigator.of(tester.element(find.byType(Navigator).first)).push(
    MaterialPageRoute<void>(
      builder: (_) => inPane
          ? ChatWorkspacePaneScope(
              tab: ChatWorkspaceTab.terminal,
              toolbar: paneToolbar,
              child: screen,
            )
          : screen,
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(SshTerminalScreen), findsOneWidget);

  if (keyboardHeight > 0) {
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight * 3);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  return (session: session, sent: sent);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
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

  group('Terminal compose glass and compact geometry QA', () {
    testWidgets(
      '360x630 narrow pane with 290 dp keyboard and multiline Compose keeps '
      'representative menu, prompt, scrollable multiline input, and dock visible',
      (tester) async {
        final h = await _mount(
          tester,
          size: const Size(360, 630),
          keyboardHeight: 290,
          inPane: true,
        );
        h.session.terminal.write(
          'Select workspace action:\r\n'
          '  1) Status overview\r\n'
          '  2) Build release\r\n'
          '  3) Run targeted suite\r\n'
          '  4) Inspect logs\r\n'
          '  5) Deploy staging\r\n'
          '  6) Tail journal\r\n'
          'user@devbox:~/proj\$ ',
        );
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('ssh-key-compose')));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        const multiline = 'line 1\nline 2\nline 3\nline 4\nline 5';
        await tester.enterText(
          find.byKey(const ValueKey('ssh-compose-field')),
          multiline,
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(tester.takeException(), isNull);

        final render = tester
            .state<TerminalViewState>(find.byType(TerminalView))
            .renderTerminal;
        final visibleRows =
            (render.size.height / render.cellSize.height).floor();
        expect(
          visibleRows,
          greaterThanOrEqualTo(9),
          reason:
              'Narrow pane 360x630 + 290 dp keyboard + multiline Compose '
              'should keep >= 9 visible rows (was 7); got $visibleRows',
        );

        final cardRect = tester.getRect(
          find.byKey(const ValueKey('ssh-compose-card')),
        );
        final dockRect = tester.getRect(
          find.byKey(const ValueKey('ssh-key-bar-pill')),
        );
        expect(cardRect.height, lessThanOrEqualTo(106));
        expect(cardRect.bottom, lessThanOrEqualTo(dockRect.top));
        expect(dockRect.bottom, lessThanOrEqualTo(630 - 290));

        final cursorBottom =
            render.localToGlobal(render.cursorOffset).dy +
            render.cellSize.height;
        expect(cursorBottom, lessThanOrEqualTo(cardRect.top));

        await tester.tap(find.byKey(const ValueKey('ssh-compose-send')));
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(h.sent, ['$multiline\r']);
      },
    );

    testWidgets(
      '360x630 phone full screen with 290 dp keyboard keeps expand off text, '
      'representative prompt visible, and dock visible',
      (tester) async {
        final h = await _mount(
          tester,
          size: const Size(360, 630),
          keyboardHeight: 290,
          inPane: false,
        );
        h.session.terminal.write(
          '1) Status\r\n2) Logs\r\n3) Deploy\r\nuser@devbox:~\$ ',
        );
        await tester.pump();

        final expandRect = tester.getRect(
          find.byKey(const ValueKey('ssh-terminal-expand')),
        );
        final termRect = tester.getRect(find.byType(TerminalView));
        expect(expandRect.overlaps(termRect), isFalse);

        await tester.tap(find.byKey(const ValueKey('ssh-key-compose')));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.enterText(
          find.byKey(const ValueKey('ssh-compose-field')),
          'first line\nsecond line\nthird line',
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(tester.takeException(), isNull);

        final render = tester
            .state<TerminalViewState>(find.byType(TerminalView))
            .renderTerminal;
        final visibleRows =
            (render.size.height / render.cellSize.height).floor();
        // 630 - 56 AppBar - 290 keyboard = 284 dp body; >= 6 rows keeps the
        // 4-line menu and prompt visible above the compact Compose card.
        expect(visibleRows, greaterThanOrEqualTo(6));
        final cardRect = tester.getRect(
          find.byKey(const ValueKey('ssh-compose-card')),
        );
        final dockRect = tester.getRect(
          find.byKey(const ValueKey('ssh-key-bar-pill')),
        );
        expect(cardRect.bottom, lessThanOrEqualTo(dockRect.top));
        expect(dockRect.bottom, lessThanOrEqualTo(630 - 290));
        final cursorBottom =
            render.localToGlobal(render.cursorOffset).dy +
            render.cellSize.height;
        expect(cursorBottom, lessThanOrEqualTo(cardRect.top));
      },
    );

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets(
        'Compose uses one chat surface in single-line and multiline '
        '(${mode.name} theme)',
        (tester) async {
          await _mount(
            tester,
            size: const Size(390, 800),
            themeMode: mode,
          );
          await tester.tap(find.byKey(const ValueKey('ssh-key-compose')));
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }

          final colors = Theme.of(
            tester.element(find.byKey(const ValueKey('ssh-compose-field'))),
          ).hermes;

          void expectSharedSurface() {
            final card = find.byKey(const ValueKey('ssh-compose-card'));
            final surface = tester.widget<HermesComposerSurface>(
              find.descendant(
                of: card,
                matching: find.byType(HermesComposerSurface),
              ),
            );
            expect(surface.focused, isTrue);
            final visible = tester.widget<AnimatedContainer>(
              find.descendant(
                of: card,
                matching: find.byKey(
                  const ValueKey('hermes-composer-visible-surface'),
                ),
              ),
            );
            final decoration = visible.decoration! as BoxDecoration;
            expect(decoration.color, HermesChrome.of(colors).opaque);
            expect(
              decoration.borderRadius,
              BorderRadius.circular(HermesRadius.pane),
            );

            // The field shares the capsule's surface instead of painting an
            // inner panel. Its hint and interactions still belong to Compose.
            final field = tester.widget<TextField>(
              find.byKey(const ValueKey('ssh-compose-field')),
            );
            final decorationField = field.decoration!;
            expect(decorationField.filled, isFalse);
            expect(decorationField.hintStyle!.color, colors.textSecondary);
            expect(decorationField.border, InputBorder.none);
            expect(decorationField.focusedBorder, InputBorder.none);
          }

          expectSharedSurface();

          // QA action order & alignment: Paste, Attach on left; Mic, Send on right.
          final pasteRect = tester.getRect(
            find.byKey(const ValueKey('ssh-compose-paste')),
          );
          final attachRect = tester.getRect(
            find.byKey(const ValueKey('ssh-compose-attach')),
          );
          final micRect = tester.getRect(
            find.byKey(const ValueKey('ssh-compose-mic')),
          );
          final sendRect = tester.getRect(
            find.byKey(const ValueKey('ssh-compose-send')),
          );
          expect(pasteRect.right, lessThanOrEqualTo(attachRect.left + 1));
          expect(attachRect.right, lessThan(micRect.left));
          expect(micRect.right, lessThan(sendRect.left));
          for (final r in [pasteRect, attachRect, micRect, sendRect]) {
            expect((r.center.dy - sendRect.center.dy).abs(), lessThanOrEqualTo(1));
          }

          // Growing a draft preserves the single visible surface.
          await tester.enterText(
            find.byKey(const ValueKey('ssh-compose-field')),
            'a\nb\nc\nd',
          );
          await tester.pump();
          expectSharedSurface();
        },
      );
    }
  });
}
