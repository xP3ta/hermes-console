import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesStickyControls;
import 'package:hermes_android/core/screens/sftp_browser_screen.dart';
import 'package:hermes_android/core/screens/sftp_file_preview_screen.dart';
import 'package:hermes_android/core/screens/ssh_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/save_to_device.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/ssh_transfer_bar.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _home = '/home/demo';

SftpName _file(String name, int size) => SftpName(
  filename: name,
  longname: name,
  attr: SftpFileAttrs(size: size, mode: const SftpFileMode.value(0x81A4)),
);

class _FakeFile implements SftpFile {
  _FakeFile(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async =>
      length == null || length >= bytes.length
      ? bytes
      : Uint8List.sublistView(bytes, 0, length);

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A remote file system: each path answers with its listing, or throws.
class _FakeSftp implements SftpClient {
  final Map<String, Object> listings = {};
  final Map<String, Uint8List> files = {};
  final List<String> listed = [];
  final List<String> opened = [];

  @override
  Future<List<SftpName>> listdir(String path) async {
    listed.add(path);
    final answer = listings[path];
    if (answer == null) return const [];
    if (answer is List<SftpName>) return answer;
    throw answer;
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    opened.add(path);
    return _FakeFile(files[path] ?? Uint8List(0));
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements SSHClient {
  _FakeClient(this.sftpClient);

  final _FakeSftp sftpClient;
  bool closed = false;

  @override
  Future<void> get authenticated => Future<void>.value();

  @override
  Future<SftpClient> sftp() async => sftpClient;

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async => Uint8List.fromList(utf8.encode('$_home\n'));

  @override
  void close() => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What a transfer tells the system tray, recorded instead of shown: the
/// real service needs the notifications plugin, which a widget test does
/// not have (its init never answers in the test's clock, so a download
/// would wait forever after its first block).
class _TransferNotices extends NotificationService {
  _TransferNotices(super.prefs);

  final progress = <int>[];
  final finished = <String>[];
  final ready = <NotificationOpen>[];

  @override
  Future<void> transferProgress({
    required int id,
    required String title,
    required String body,
    required int progress,
    required int max,
    bool indeterminate = false,
  }) async => this.progress.add(progress);

  @override
  Future<void> transferDone({
    required int id,
    required String title,
    required String body,
    required bool ok,
  }) async => finished.add(title);

  @override
  Future<void> downloadReady({
    required int id,
    required String title,
    required String body,
    required NotificationOpen open,
  }) async => ready.add(open);
}

class _FakeSsh extends SshManager {
  _FakeSsh(super.secure, super.connections);

  final _FakeSftp remote = _FakeSftp();

  /// The transfer service's notifications ([_app] sets them).
  late final _TransferNotices notices;
  int connects = 0;
  int failedLoads = 0;

  @override
  Future<SshConfig?> loadConfig(String connectionId) async {
    if (failedLoads > 0) {
      failedLoads--;
      throw PlatformException(code: 'keystore');
    }
    return const SshConfig(
      host: 'example.invalid',
      port: 22,
      username: 'demo',
      method: SshAuthMethod.password,
    );
  }

  /// The connection is read only (Files shows the padlock).
  bool readOnly = false;

  @override
  bool isReadOnly(String connectionId) => readOnly;

  @override
  Future<SSHClient> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async {
    connects++;
    return _FakeClient(remote);
  }
}

final _connection = SavedConnection(
  id: 'gaps-sftp',
  label: 'Remote',
  host: 'example.invalid',
  port: 443,
  apiKey: '',
  useHttps: true,
);

Future<_FakeSsh> _app(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  await manager.upsertConnection(_connection);
  final ssh = _FakeSsh(SecureStorage(), manager)
    ..notices = _TransferNotices(prefs);
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
      sftpTransfers: SftpTransferService(ssh, ssh.notices),
      sshSessions: SshSessionService(ssh),
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 500));
  return ssh;
}

Future<void> _push(WidgetTester tester, Widget screen) async {
  Navigator.of(tester.element(find.byType(Navigator).first)).push(
    MaterialPageRoute<void>(builder: (_) => screen),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
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

  testWidgets('an unreadable folder says why; Try again lists it again', (
    tester,
  ) async {
    final ssh = await _app(tester);
    ssh.remote.listings[_home] = SftpStatusError(
      SftpStatusCode.permissionDenied,
      'Permission denied',
    );
    await _push(tester, SftpBrowserScreen(connection: _connection));

    expect(find.byKey(const ValueKey('sftp-unreadable')), findsOneWidget);
    expect(find.text('Unreadable'), findsOneWidget);
    expect(
      find.text('Could not read this folder (Permission denied.)'),
      findsOneWidget,
    );
    // Not the misleading «Connection error».
    expect(find.textContaining('Connection error'), findsNothing);

    ssh.remote.listings[_home] = [_file('notes.txt', 5)];
    await tester.tap(find.text('Try again'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Same folder, same connection.
    expect(ssh.remote.listed, [_home, _home]);
    expect(ssh.connects, 1);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Audit 2.8 and T1 (Ola 1): in the workspace pane Files has no header of
  // its own (the pane's bar names the tab), upload and reload are in the
  // bar's «⋯», its page is the pane's, and the transfers sit at the foot.
  testWidgets('in the pane: no header, upload and reload in «⋯», '
      'transfers at the foot', (tester) async {
    final ssh = await _app(tester);
    ssh.remote.listings[_home] = [_file('notes.txt', 5)];
    final toolbar = ValueNotifier(ChatWorkspaceToolbar.none);
    addTearDown(toolbar.dispose);
    await _push(
      tester,
      ChatWorkspacePaneScope(
        tab: ChatWorkspaceTab.files,
        toolbar: toolbar,
        child: SftpBrowserScreen(connection: _connection),
      ),
    );
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.byType(HermesAppBar), findsNothing);
    expect(find.byKey(const ValueKey('sftp-upload')), findsNothing);
    final scaffold = tester.widget<Scaffold>(
      find
          .descendant(
            of: find.byType(SftpBrowserScreen),
            matching: find.byType(Scaffold),
          )
          .first,
    );
    expect(scaffold.backgroundColor, Colors.transparent);
    expect(toolbar.value.menu.map((entry) => entry.key), const [
      ValueKey('sftp-pane-menu-upload'),
      ValueKey('sftp-pane-menu-reload'),
    ]);
    // Reload from «⋯» lists the same folder again.
    toolbar.value.menu.last.onSelected();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ssh.remote.listed, [_home, _home]);
    // The transfers' pill is under the list, not over it (in the pane the
    // list is its card, Ola 6).
    final list = tester.getRect(find.byKey(const ValueKey('sftp-pane-card')));
    final bar = tester.getRect(find.byType(SshTransferBar));
    expect(bar.top, greaterThanOrEqualTo(list.bottom - 0.5));
    expect(tester.takeException(), isNull);
  });

  // Ola 6 (audit §2.8, mock 136 v2-A): in the pane the files are a card of
  // rows with their icon in a box, and the path is a pill at the foot with
  // «Subir nivel».
  testWidgets('in the pane: a card of rows, the path in a pill at the foot', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ssh = await _app(tester);
    ssh.remote.listings[_home] = [
      SftpName(
        filename: 'lib',
        longname: 'lib',
        attr: SftpFileAttrs(mode: const SftpFileMode.value(0x41ED)),
      ),
      _file('notes.txt', 5),
    ];
    ssh.remote.listings['/home'] = [
      SftpName(
        filename: 'demo',
        longname: 'demo',
        attr: SftpFileAttrs(mode: const SftpFileMode.value(0x41ED)),
      ),
    ];
    final toolbar = ValueNotifier(ChatWorkspaceToolbar.none);
    addTearDown(toolbar.dispose);
    await _push(
      tester,
      ChatWorkspacePaneScope(
        tab: ChatWorkspaceTab.files,
        toolbar: toolbar,
        child: SftpBrowserScreen(connection: _connection),
      ),
    );

    final card = find.byKey(const ValueKey('sftp-pane-card'));
    final decoration =
        tester.widget<DecoratedBox>(card).decoration as BoxDecoration;
    expect(
      decoration.borderRadius,
      BorderRadius.circular(HermesRadius.card),
    );
    // No floating path bar over the list in the pane.
    expect(find.byType(HermesStickyControls), findsNothing);
    for (final name in ['lib', 'notes.txt']) {
      final row = find.byKey(ValueKey('sftp-row-$name'));
      expect(find.descendant(of: card, matching: row), findsOneWidget);
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.byKey(ValueKey('sftp-row-icon-$name'))),
        const Size(32, 32),
      );
      expect(
        tester.widget<InkWell>(row).borderRadius,
        BorderRadius.circular(HermesRadius.row),
      );
    }
    expect(find.text('5 B'), findsOneWidget);

    // The path: a breadcrumb in a pill under the card, the whole path for
    // TalkBack, and «Up one level» beside it, 48 dp.
    final path = find.byKey(const ValueKey('sftp-pane-path'));
    expect(
      tester.getRect(path).top,
      greaterThanOrEqualTo(tester.getRect(card).bottom),
    );
    final crumb = tester.widget<Text>(
      find.byKey(const ValueKey('sftp-pane-breadcrumb')),
    );
    expect(crumb.data, 'home › demo');
    expect(find.bySemanticsLabel(_home), findsOneWidget);
    final up = find.byKey(const ValueKey('sftp-pane-up'));
    expect(tester.getSize(up).height, 48);
    expect(
      find.descendant(of: up, matching: find.text('Up one level')),
      findsOneWidget,
    );
    await tester.tap(up);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ssh.remote.listed.last, '/home');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('sftp-pane-breadcrumb')))
          .data,
      'home',
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  // REVIEW-T2-D P3-5: the padlock of a read-only connection is drawn in
  // the path's pill; TalkBack says it too.
  testWidgets('in the pane: a read-only path says so to TalkBack', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ssh = await _app(tester)..readOnly = true;
    ssh.remote.listings[_home] = [_file('notes.txt', 5)];
    final toolbar = ValueNotifier(ChatWorkspaceToolbar.none);
    addTearDown(toolbar.dispose);
    await _push(
      tester,
      ChatWorkspacePaneScope(
        tab: ChatWorkspaceTab.files,
        toolbar: toolbar,
        child: SftpBrowserScreen(connection: _connection),
      ),
    );
    expect(find.bySemanticsLabel('$_home, read only'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sftp-pane-path')),
        matching: find.byIcon(Icons.lock_outline),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  test('the breadcrumb keeps the last three folders', () {
    expect(sftpBreadcrumb('/'), '/');
    expect(sftpBreadcrumb('/home'), 'home');
    expect(
      sftpBreadcrumb('/srv/proyecto/lib/core'),
      '… › proyecto › lib › core',
    );
    expect(sftpBreadcrumb('/a/b/c'), 'a › b › c');
    expect(sftpBreadcrumb('/a//b/'), 'a › b');
  });

  testWidgets('full screen: its header with upload, transfers at the foot', (
    tester,
  ) async {
    final ssh = await _app(tester);
    ssh.remote.listings[_home] = [_file('notes.txt', 5)];
    await _push(tester, SftpBrowserScreen(connection: _connection));
    expect(find.byType(HermesAppBar), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-upload')), findsOneWidget);
    final list = tester.getRect(find.byType(HermesStickyControls));
    final bar = tester.getRect(find.byType(SshTransferBar));
    expect(bar.top, greaterThanOrEqualTo(list.bottom - 0.5));
  });

  testWidgets('an empty folder says so (Desktop copy)', (tester) async {
    await _app(tester);
    await _push(tester, SftpBrowserScreen(connection: _connection));
    expect(find.byKey(const ValueKey('sftp-empty')), findsOneWidget);
    expect(find.text('Empty'), findsOneWidget);
    expect(find.text('This folder is empty.'), findsOneWidget);
  });

  testWidgets('tapping a file opens its preview', (tester) async {
    final ssh = await _app(tester);
    ssh.remote.listings[_home] = [_file('notes.txt', 5)];
    ssh.remote.files['$_home/notes.txt'] = Uint8List.fromList(
      utf8.encode('hello'),
    );
    await _push(tester, SftpBrowserScreen(connection: _connection));

    await tester.tap(find.text('notes.txt'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(SftpFilePreviewScreen), findsOneWidget);
    expect(ssh.remote.opened, ['$_home/notes.txt']);
    expect(
      find.byKey(const ValueKey('sftp-preview-viewer')),
      findsOneWidget,
    );
  });

  testWidgets('from a chat, Files has the notch back; otherwise not', (
    tester,
  ) async {
    await _app(tester);
    var back = 0;
    await _push(
      tester,
      SftpBrowserScreen(connection: _connection, onBackToChat: () => back++),
    );
    expect(find.byKey(const ValueKey('sftp-notch')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sftp-notch')));
    expect(back, 1);

    await _push(tester, SftpBrowserScreen(connection: _connection));
    expect(find.byKey(const ValueKey('sftp-notch')), findsNothing);
  });

  testWidgets('SSH hub: unreadable settings offer Try again', (tester) async {
    final ssh = await _app(tester);
    ssh.failedLoads = 1;
    await _push(tester, SshScreen(connection: _connection));
    expect(find.byKey(const ValueKey('ssh-hub-load-error')), findsOneWidget);
    expect(find.text('Could not read the SSH settings.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('ssh-hub-load-error')), findsNothing);
    expect(find.text('demo@example.invalid:22'), findsOneWidget);
  });

  testWidgets('SSH hub opened from a chat passes the way back to Files', (
    tester,
  ) async {
    await _app(tester);
    var back = 0;
    await _push(
      tester,
      SshScreen(connection: _connection, onBackToChat: () => back++),
    );
    await tester.tap(find.text('Files (SFTP)'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(SftpBrowserScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sftp-notch')));
    expect(back, 1);
  });

  group('«Descargar» from the ⋮ of a real row (DESCARGAS-DIRECTAS)', () {
    const save = MethodChannel('hermes/save_to_device');
    const doc = 'content://com.android.externalstorage.documents/document/9';

    /// Android's side of «Guardar como»: every call, answered by [answer].
    List<MethodCall> android(Object? Function(MethodCall call) answer) {
      final calls = <MethodCall>[];
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(save, (call) async {
        calls.add(call);
        final result = answer(call);
        if (result is PlatformException) throw result;
        if (result is Future) return await result;
        return result;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(save, null));
      return calls;
    }

    Future<void> frames(WidgetTester tester, [int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// Pumps until [done] (at most 5 s of the test's clock), then checks it.
    Future<void> until(
      WidgetTester tester,
      bool Function() done,
      String what,
    ) async {
      for (var i = 0; i < 50 && !done(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue, reason: what);
    }

    Iterable<String> methods(List<MethodCall> calls) =>
        calls.map((c) => c.method);

    Map<Object?, Object?> args(MethodCall call) => call.arguments as Map;

    // A menu leaves in 180 ms: until it is gone its texts are still found,
    // and a tap on them reaches nothing. So each menu is found by its key,
    // its options inside it, and the next one waits for it to be gone.
    final rowMenu = find.byKey(const ValueKey('hermes-menu'));
    final savedMenu = find.byKey(const ValueKey('saved-document-menu'));

    Finder option(Finder menu, String label) =>
        find.descendant(of: menu, matching: find.text(label));

    /// Taps [opener], waits for [menu] with [label], taps it, and waits for
    /// the menu to be gone.
    Future<void> choose(
      WidgetTester tester,
      Finder opener,
      Finder menu,
      String label,
    ) async {
      await until(
        tester,
        () => menu.evaluate().isEmpty,
        'no menu is still leaving before opening $label',
      );
      await tester.tap(opener);
      await until(
        tester,
        () => option(menu, label).evaluate().isNotEmpty,
        'the menu offers $label',
      );
      // Its entrance (200 ms) done: the option is where it stays.
      await tester.pump(const Duration(milliseconds: 250));
      expect(option(menu, label), findsOneWidget);
      await tester.tap(option(menu, label));
      await until(
        tester,
        () => menu.evaluate().isEmpty,
        'the menu closes after $label',
      );
    }

    /// Waits for Android to get [count] calls in all, then gives the new
    /// ones.
    Future<List<String>> newCalls(
      WidgetTester tester,
      List<MethodCall> calls,
      int before,
      int count,
      String what,
    ) async {
      await until(tester, () => calls.length >= before + count, what);
      return [for (final c in calls.skip(before)) c.method];
    }

    /// Opens the browser on one file and taps its ⋮, then «Download».
    Future<_FakeSsh> tapDownload(WidgetTester tester) async {
      final ssh = await _app(tester);
      ssh.remote.listings[_home] = [_file('notes.txt', 5)];
      ssh.remote.files['$_home/notes.txt'] = Uint8List.fromList(
        utf8.encode('hello'),
      );
      await _push(tester, SftpBrowserScreen(connection: _connection));
      final row = find.widgetWithText(ListTile, 'notes.txt');
      expect(row, findsOneWidget);
      final more = find.descendant(
        of: row,
        matching: find.byIcon(Icons.more_vert),
      );
      await tester.tap(more);
      await until(
        tester,
        () => option(rowMenu, 'Download').evaluate().isNotEmpty,
        'the row menu offers Download',
      );
      expect(option(rowMenu, 'Share'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(option(rowMenu, 'Download'));
      await until(
        tester,
        () => rowMenu.evaluate().isEmpty,
        'the row menu closes after Download',
      );
      return ssh;
    }

    testWidgets('asks where, then writes the file straight there', (
      tester,
    ) async {
      final calls = android(
        (call) => switch (call.method) {
          'pick' => doc,
          'begin' => 1,
          'write' => 5,
          'finish' => 5,
          'copy' => 5,
          _ => null,
        },
      );
      final ssh = await tapDownload(tester);
      await until(
        tester,
        () => methods(calls).contains('finish'),
        'the document is closed: ${methods(calls).toList()}',
      );

      // «Guardar como» with the server's name, then the document chosen,
      // written block by block and closed; no copy made by the app.
      expect(methods(calls), ['pick', 'begin', 'write', 'finish']);
      expect(args(calls[0])['name'], 'notes.txt');
      expect(args(calls[1])['uri'], doc);
      expect(args(calls[2])['writer'], 1);
      expect(utf8.decode(args(calls[2])['bytes']! as Uint8List), 'hello');
      expect(args(calls[3])['writer'], 1);
      expect(ssh.remote.opened, ['$_home/notes.txt']);

      // The tray: progress, then «ready» carrying the document, not a path.
      expect(ssh.notices.progress, [100]);
      expect(ssh.notices.finished, isEmpty);
      final ready = ssh.notices.ready.single;
      expect(ready.connId, _connection.id);
      expect(ready.downloadUri, doc);
      expect(ready.downloadName, 'notes.txt');

      // On screen: «Saved», with «View»; the transfer bar has «View» too.
      await until(
        tester,
        () => find.text('Saved: notes.txt').evaluate().isNotEmpty,
        'the saved notice shows',
      );
      final barView = find.byKey(const ValueKey('sftp-transfer-show-d0'));
      expect(barView, findsOneWidget);

      // «View» of the notice → Open: the document, with the system.
      final notice = find.byKey(const ValueKey('hermes-notice-action'));
      expect(notice, findsOneWidget);
      await choose(tester, notice, savedMenu, 'Open');
      expect(
        await newCalls(tester, calls, 4, 1, 'Open reaches Android'),
        ['view'],
      );
      expect(args(calls[4])['uri'], doc);

      // «View» of the bar → Share: the document itself, no copy.
      await choose(tester, barView, savedMenu, 'Share');
      expect(
        await newCalls(tester, calls, 5, 1, 'Share reaches Android'),
        ['share'],
      );
      expect(args(calls[5])['uri'], doc);

      // «View» of the bar → Save another copy…: asks where, copies it.
      await choose(tester, barView, savedMenu, 'Save another copy…');
      expect(
        await newCalls(tester, calls, 6, 2, 'the other copy reaches Android'),
        ['pick', 'copy'],
      );
      expect(args(calls[6])['name'], 'notes.txt');
      expect(args(calls[7])['source'], doc);
      expect(args(calls[7])['uri'], doc);
      expect(args(calls[7]).containsKey('path'), isFalse);
      await until(
        tester,
        () => find.text('Saved: notes.txt').evaluate().isNotEmpty,
        'the other copy is said saved too',
      );
      expect(calls, hasLength(8));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('closing «Guardar como» does nothing', (tester) async {
      final calls = android((call) => null);
      final ssh = await tapDownload(tester);
      await frames(tester);
      expect(methods(calls), ['pick']);
      expect(ssh.remote.opened, isEmpty);
      expect(ssh.notices.progress, isEmpty);
      expect(find.textContaining('Saved'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('an error from Android says why, with Retry', (tester) async {
      final calls = android((call) => PlatformException(code: 'permission'));
      final ssh = await tapDownload(tester);
      const why =
          'The app no longer has permission to write there. '
          'Choose the place again.';
      await until(
        tester,
        () => find.text(why).evaluate().isNotEmpty,
        'the reason is said',
      );
      // Nothing was downloaded nor written.
      expect(methods(calls), ['pick']);
      expect(ssh.remote.opened, isEmpty);
      await tester.tap(find.text('Retry'));
      await until(
        tester,
        () => methods(calls).length == 2,
        'Retry asks where again',
      );
      expect(methods(calls), ['pick', 'pick']);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a channel that never answers ends in a notice', (
      tester,
    ) async {
      final calls = android(
        (call) => call.method == 'pick' ? Completer<String?>().future : null,
      );
      final ssh = await tapDownload(tester);
      expect(methods(calls), ['pick']);
      const why = 'Android didn’t open the “Save as” dialog. Try again.';
      expect(find.text(why), findsNothing);
      await tester.pump(SaveToDevice.pickerShowTimeout);
      await frames(tester, 4);
      expect(find.text(why), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(methods(calls), ['pick', 'cancelPick']);
      expect(ssh.remote.opened, isEmpty);
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
