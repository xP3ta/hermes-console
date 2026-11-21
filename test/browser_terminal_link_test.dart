// Terminal link wiring (chat Terminal panel -> Browser panel with SSH reach,
// and standalone SSH screen -> in-app browser with owned SSH loopback reach).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/browser_loopback_reach.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/browser/open_web_link.dart';
import 'package:hermes_android/core/screens/ssh_screen.dart';
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
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_webview_platform.dart';
import 'support/in_memory_compression_restore_storage.dart';

class _LiveSessionService extends SshSessionService {
  _LiveSessionService(super.ssh);

  SshTerminalSession? live;

  @override
  SshTerminalSession? of(String connectionId) =>
      live?.connectionId == connectionId ? live : super.of(connectionId);
}

Future<void> _expectPortRefuses(int port) async {
  for (var i = 0; i < 15; i++) {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 100),
      );
      s.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 25));
    } on SocketException {
      return;
    }
  }
  fail('expected port $port to stop listening');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebViewPlatform web;
  WebViewPlatform? previousWeb;

  setUp(() {
    previousWeb = WebViewPlatform.instance;
    web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;

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
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => Directory.systemTemp.path,
    );
  });

  tearDown(() {
    if (previousWeb != null) WebViewPlatform.instance = previousWeb;
  });

  testWidgets('SshScreen wires onOpenLink in-pane (forwarding to host) and '
      'standalone (opening browser with SSH loopback reach)', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'ssh-link-test',
      label: 'Remote',
      host: 'example.invalid',
      port: 443,
      apiKey: '',
      useHttps: true,
    );
    await manager.upsertConnection(connection);
    final ssh = SshManager(SecureStorage(), manager);
    await ssh.saveConfig(
      connection.id,
      host: 'remote.invalid',
      port: 22,
      username: 'dev',
      method: SshAuthMethod.password,
      password: 'not-a-real-secret',
    );
    final sessions = _LiveSessionService(ssh)
      ..live = (SshTerminalSession(connection.id, Terminal())
        ..phase.value = SshSessionPhase.ready);
    final activeChats = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(activeChats.dispose);
    final workspace = ChatWorkspaceController()
      ..open(ChatWorkspaceTab.terminal);
    addTearDown(workspace.dispose);
    final toolbar = ValueNotifier(ChatWorkspaceToolbar.none);
    addTearDown(toolbar.dispose);

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

    final nav = Navigator.of(tester.element(find.byType(Navigator).first));
    final forwardedLinks = <Uri>[];

    // 1. In-pane SshScreen forwards terminal link taps to host callback.
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => ChatWorkspacePaneScope(
          tab: ChatWorkspaceTab.terminal,
          controller: workspace,
          toolbar: toolbar,
          child: SshScreen(
            connection: connection,
            onOpenLink: forwardedLinks.add,
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final paneTerminal = tester.widget<SshTerminalScreen>(
      find.byType(SshTerminalScreen),
    );
    expect(paneTerminal.onOpenLink, isNotNull);
    paneTerminal.onOpenLink!(Uri.parse('http://localhost:5173/panel'));
    expect(forwardedLinks, [Uri.parse('http://localhost:5173/panel')]);

    // 2. Standalone SshScreen without host callback opens InAppBrowserScreen
    //    with SSH loopback reach (resolving to *.localhost, never phone).
    nav.pop();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => SshScreen(connection: connection),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('Open terminal'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final standaloneTerminal = tester.widget<SshTerminalScreen>(
      find.byType(SshTerminalScreen),
    );
    expect(standaloneTerminal.onOpenLink, isNotNull);
    standaloneTerminal.onOpenLink!(Uri.parse('http://localhost:5173/from-ssh'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final browser = tester.widget<InAppBrowserScreen>(
      find.byType(InAppBrowserScreen),
    );
    expect(browser.loopbackReach, isNotNull);

    Uri? loaded;
    for (var i = 0; i < 25 && loaded == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      loaded = web.controllers
          .expand((c) => c.loadedRequests)
          .where((u) => isInternalBrowserForwardHost(u.host))
          .firstOrNull;
    }
    expect(loaded, isNotNull);
    expect(loaded!.path, '/from-ssh');
    expect(
      web.controllers
          .expand((c) => c.loadedRequests)
          .where((u) => u.host == 'localhost'),
      isEmpty,
    );

    // Popping the standalone browser route closes the owned forward.
    await tester.tap(find.byKey(const ValueKey('in-app-browser-notch')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => _expectPortRefuses(loaded!.port));
  });

  testWidgets('openWebLinkInApp with owned reach revokes forwards on profile '
      'change/removal', (tester) async {
    final revision = ValueNotifier<int>(0);
    String? scope = 'profile-1';
    final created = <BrowserLoopbackReach>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => openWebLinkInApp(
                context,
                Uri.parse('http://localhost:5173/demo'),
                loopbackReach: () {
                  final r = BrowserLoopbackReach(
                    dial: (_, _) async => throw const SocketException('stub'),
                  );
                  created.add(r);
                  return r;
                },
                loopbackReachScope: () => scope,
                loopbackReachChanges: revision,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    Uri? loaded;
    for (var i = 0; i < 25 && loaded == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      loaded = web.controllers
          .expand((c) => c.loadedRequests)
          .where((u) => isInternalBrowserForwardHost(u.host))
          .firstOrNull;
    }
    expect(loaded, isNotNull);
    expect(created, hasLength(1));

    // Removing the profile immediately closes the reach and its listener.
    scope = null;
    revision.value++;
    await tester.pump();
    expect(created.single.isClosed, isTrue);
    await tester.runAsync(() => _expectPortRefuses(loaded!.port));
  });

  // A13: a terminal pushed without the hook opened `localhost` links on the
  // phone's own loopback instead of the server's.
  test('every terminal the app opens is given the link hook', () {
    final construct = RegExp(r'\bSshTerminalScreen\(');
    final missing = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in construct.allMatches(source)) {
        // The constructor's own declaration is not a call.
        final before = source.substring(
          match.start < 6 ? 0 : match.start - 6,
          match.start,
        );
        if (before.endsWith('const ')) continue;
        var depth = 0;
        var end = match.end;
        for (; end < source.length; end++) {
          final char = source[end];
          if (char == '(') depth++;
          if (char == ')') {
            if (depth == 0) break;
            depth--;
          }
        }
        if (!source.substring(match.end, end).contains('onOpenLink:')) {
          missing.add(entity.path);
        }
      }
    }
    expect(missing, isEmpty);
  });
}
