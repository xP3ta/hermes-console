// 1.4.3: the SSH terminal worked by touch, on the real screen and its
// session fakes: select and copy, paste, Compose, a y/N question's
// answers, scrolling that sends no keys, two fingers and a pinch,
// tappable links, a hardware keyboard's chords, and the idle close that
// spares an open terminal.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
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
import 'package:hermes_android/core/services/ssh_terminal_input.dart';
import 'package:hermes_android/core/widgets/attachment_source_sheet.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _home = '/home/demo';
const _uploads = '$_home/.cache/hermes-console/uploads';

class _FakeSftpFile implements SftpFile {
  _FakeSftpFile(this.sftp, this.path);

  final _FakeSftp sftp;
  final String path;

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    await sftp.gate?.future;
    sftp.files[path]?.addAll(data);
  }

  @override
  Future<SftpFileAttrs> stat() async => SftpFileAttrs(
    size: sftp.files[path]?.length ?? 0,
    mode: const SftpFileMode.value(0x8180),
    modifyTime: 1700000000,
  );

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The server's file system as SFTP sees it.
class _FakeSftp implements SftpClient {
  final Map<String, int?> made = {};
  final Map<String, List<int>> files = {};
  final Map<String, SftpFileOpenMode> modes = {};
  final List<String> removed = [];

  /// Holds every write until completed.
  Completer<void>? gate;

  @override
  Future<String> absolute(String path) async => _home;

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    if (made.containsKey(path)) throw SftpStatusError(4, 'Failure');
    made[path] = attrs?.mode?.value;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (made.containsKey(path)) {
      return SftpFileAttrs(
        mode: SftpFileMode.value(0x4000 | (made[path] ?? 0x1ED)),
      );
    }
    if (files.containsKey(path)) {
      return SftpFileAttrs(
        size: files[path]!.length,
        mode: const SftpFileMode.value(0x8180),
        modifyTime: 1700000000,
      );
    }
    throw SftpStatusError(2, 'No such file');
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    if (made.containsKey(path) && attrs.mode != null) {
      made[path] = attrs.mode!.value;
    }
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    modes[path] = mode;
    files[path] = [];
    return _FakeSftpFile(this, path);
  }

  @override
  Future<void> remove(String filename) async {
    removed.add(filename);
    files.remove(filename);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The terminal's SSH client: only its presence matters here.
class _FakeClient implements SSHClient {
  bool closed = false;
  int closeCalls = 0;

  @override
  bool get isClosed => closed;

  @override
  void close() {
    closed = true;
    closeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Session service without sockets: one ready session on [terminal].
class _FakeSessions extends SshSessionService {
  _FakeSessions(super.ssh);

  SshTerminalSession? live;
  final _FakeSftp sftp = _FakeSftp();

  /// Opening SFTP fails this many more times.
  int sftpFailures = 0;
  int sftpOpens = 0;

  @override
  Future<SftpClient> openSftp(String connectionId) async {
    sftpOpens++;
    if (sftpFailures > 0) {
      sftpFailures--;
      throw StateError('subsystem request failed');
    }
    return sftp;
  }

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

const _connection = 'ssh-touch';

/// The chat composer's dictation, scripted: stopping it «hears» `minus
/// la` after what was in the box.
class _FakeDictation extends RoomDictation {
  bool _recording = false;
  bool _transcribing = false;
  bool deferTranscription = false;
  bool fail = false;
  int cancelCount = 0;
  String? startedWith;
  ValueChanged<String>? _onText;

  @override
  bool get recording => _recording;

  @override
  bool get transcribing => _transcribing;

  @override
  ValueListenable<double>? get level => null;

  @override
  Future<void> start({
    required String currentText,
    required ValueChanged<String> onText,
    required ValueChanged<RoomDictationFailure> onFailure,
  }) async {
    if (fail) {
      onFailure(RoomDictationFailure.unavailable);
      return;
    }
    startedWith = currentText;
    _onText = onText;
    _recording = true;
    _transcribing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _recording = false;
    if (deferTranscription) {
      _transcribing = true;
      notifyListeners();
      return;
    }
    _onText?.call('$startedWith minus la');
    notifyListeners();
  }

  void deliverDeferred([String? spoken]) {
    _transcribing = false;
    final words = spoken ?? 'minus la';
    final prefix = startedWith ?? '';
    _onText?.call(prefix.isEmpty ? words : '$prefix $words');
    notifyListeners();
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _recording = false;
    _transcribing = false;
    notifyListeners();
  }
}

class _ReadOnlySsh extends SshManager {
  _ReadOnlySsh(super.secure, super.connections);

  bool readOnly = false;

  @override
  bool isReadOnly(String connectionId) => readOnly;
}

final _connectionInfo = SavedConnection(
  id: _connection,
  label: 'Remote',
  host: 'example.invalid',
  port: 443,
  apiKey: '',
  useHttps: true,
);

class _Harness {
  _Harness(
    this.sessions,
    this.terminal,
    this.sent,
    this.opened,
    this.prefs,
    this.ssh,
    this.picks,
    this.dictation,
  );

  final _FakeSessions sessions;
  final Terminal terminal;

  /// Everything that reached the shell, as the session sends it.
  final List<String> sent;

  /// The web addresses handed to the link callback.
  final List<Uri> opened;
  final SharedPreferences prefs;
  final _ReadOnlySsh ssh;

  /// What the attachment pickers hand back, per source.
  final Map<AttachmentSourceChoice, List<SshComposePick>> picks;
  final _FakeDictation dictation;

  SshTerminalSession get session => sessions.live!;

  /// Opens the terminal screen again, as the user would.
  Future<void> reopen(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      MaterialPageRoute<void>(
        builder: (_) => SshTerminalScreen(
          connection: _connectionInfo,
          onOpenLink: opened.add,
          composePicker: (source) async => picks[source] ?? const [],
          composeDictation: dictation,
        ),
      ),
    );
    await _frames(tester);
  }
}

Future<_Harness> _open(WidgetTester tester) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  await manager.upsertConnection(_connectionInfo);
  final ssh = _ReadOnlySsh(SecureStorage(), manager);
  final sessions = _FakeSessions(ssh);
  // As the service makes it: a long press keeps a path in one word.
  final terminal = Terminal(
    maxLines: 1000,
    wordSeparators: sshTerminalWordSeparators,
  );
  final session = SshTerminalSession(_connection, terminal)
    ..client = _FakeClient()
    ..phase.value = SshSessionPhase.ready;
  final sent = <String>[];
  // As the service wires it: the key row's modifiers apply on the way.
  terminal.onOutput = (data) => sent.add(session.applyModifiers(data));
  sessions.live = session;
  final opened = <Uri>[];
  final picks = <AttachmentSourceChoice, List<SshComposePick>>{};
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
  final harness = _Harness(
    sessions,
    terminal,
    sent,
    opened,
    prefs,
    ssh,
    picks,
    _FakeDictation(),
  );
  await harness.reopen(tester);
  expect(find.byType(SshTerminalScreen), findsOneWidget);
  return harness;
}

Future<void> _frames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The middle of the cell at column [x] of buffer row [y], on screen.
Offset _cell(WidgetTester tester, int x, int y) {
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  final size = render.cellSize;
  return render.localToGlobal(
    render.getOffset(CellOffset(x, y)) +
        Offset(size.width / 2, size.height / 2),
  );
}

/// Taps a key of the dock's strip, swiping its pages to it first.
Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  final dot = find.byKey(const ValueKey('ssh-key-page-dot-current'));
  var way = -1.0;
  final strip = find.byKey(const ValueKey('ssh-key-bar'));
  bool shown() {
    if (finder.evaluate().isEmpty) return false;
    final bounds = tester.getRect(strip).inflate(1);
    final rect = tester.getRect(finder);
    return bounds.contains(rect.topLeft) && bounds.contains(rect.bottomRight);
  }

  for (var i = 0; i < 24; i++) {
    if (shown()) break;
    final before = tester.getCenter(dot);
    // Most of a page: the strip moves one page, then settles.
    await tester.drag(strip, Offset(tester.getSize(strip).width * 0.9 * way, 0));
    await _frames(tester, 15);
    if (tester.getCenter(dot) == before) way = -way;
  }
  await tester.tap(finder);
}

double _fontSize(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize;

class _Clipboard {
  String? text;
  final List<String> written = [];
}

/// The platform clipboard, seen by the test.
_Clipboard _clipboard(WidgetTester tester, {String? text}) {
  final clip = _Clipboard()..text = text;
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        clip.written.add((call.arguments as Map)['text'] as String);
        return null;
      case 'Clipboard.getData':
        final text = clip.text;
        return text == null ? null : {'text': text};
      case 'Clipboard.hasStrings':
        return {'value': clip.text != null};
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return clip;
}

bool _sentArrows(List<String> sent) {
  final all = sent.join();
  return ['\x1b[A', '\x1b[B', '\x1bOA', '\x1bOB'].any(all.contains);
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

  group('select and copy', () {
    for (final alternate in [false, true]) {
      testWidgets(
        'a long press selects a word; Copy puts exactly it on the '
        'clipboard (${alternate ? 'alternate' : 'normal'} screen)',
        (tester) async {
          final h = await _open(tester);
          final clip = _clipboard(tester);
          if (alternate) h.terminal.write('\x1b[?1049h');
          h.terminal.write('cat /var/log/app-1.log   \r\nnext line');
          await tester.pump();

          await tester.longPressAt(_cell(tester, 8, 0));
          await _frames(tester, 3);
          expect(find.text('Copy'), findsOneWidget);
          expect(find.text('Paste'), findsOneWidget);
          expect(find.text('Copy screen'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('ssh-terminal-handle-start')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('ssh-terminal-handle-end')),
            findsOneWidget,
          );

          await tester.tap(find.text('Copy'));
          await _frames(tester, 2);
          expect(clip.written, ['/var/log/app-1.log']);
          // Copied, the selection and its menu go.
          expect(find.text('Copy'), findsNothing);
          expect(
            find.byKey(const ValueKey('ssh-terminal-handle-end')),
            findsNothing,
          );
          // Nothing was typed into the shell.
          expect(h.sent, isEmpty);
        },
      );
    }

    testWidgets('the end handle stretches the selection', (tester) async {
      final h = await _open(tester);
      final clip = _clipboard(tester);
      h.terminal.write('hello brave new world\r\n');
      await tester.pump();

      await tester.longPressAt(_cell(tester, 1, 0));
      await _frames(tester, 3);
      final width = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal
          .cellSize
          .width;
      // From the end of «hello» to the middle of «new».
      await tester.drag(
        find.byKey(const ValueKey('ssh-terminal-handle-end')),
        Offset(width * 9.5, 0),
      );
      await _frames(tester, 3);
      await tester.tap(find.text('Copy'));
      await _frames(tester, 2);
      expect(clip.written, ['hello brave new']);
    });

    testWidgets('a long press on a blank offers Paste and Copy screen', (
      tester,
    ) async {
      final h = await _open(tester);
      final clip = _clipboard(tester, text: 'uptime');
      h.terminal.write('first\r\nsecond');
      await tester.pump();

      await tester.longPressAt(_cell(tester, 30, 4));
      await _frames(tester, 3);
      expect(find.text('Copy'), findsNothing);
      await tester.tap(find.text('Copy screen'));
      await _frames(tester, 2);
      expect(clip.written, ['first\nsecond']);

      await tester.longPressAt(_cell(tester, 30, 4));
      await _frames(tester, 3);
      await tester.tap(find.text('Paste'));
      await _frames(tester, 2);
      expect(h.sent, ['uptime']);
    });
  });

  group('paste and Compose', () {
    testWidgets('the Paste key: plain, then one bracketed paste', (
      tester,
    ) async {
      final h = await _open(tester);
      _clipboard(tester, text: 'ls -la');

      await _tapKey(tester, 'ssh-key-paste');
      await _frames(tester, 2);
      h.terminal.write('\x1b[?2004h');
      await _tapKey(tester, 'ssh-key-paste');
      await _frames(tester, 2);
      expect(h.sent, ['ls -la', '\x1b[200~ls -la\x1b[201~']);
    });

    testWidgets('an armed Ctrl does not touch a pasted letter', (
      tester,
    ) async {
      final h = await _open(tester);
      _clipboard(tester, text: 'c');
      await _tapKey(tester, 'ssh-key-ctrl');
      await tester.pump(kDoubleTapTimeout * 2);
      await _tapKey(tester, 'ssh-key-paste');
      await _frames(tester, 2);
      expect(h.sent, ['c']);
      expect(h.session.ctrlArmed.value, isTrue);
    });
  });

  group('Compose', () {
    const field = ValueKey('ssh-compose-field');
    const send = ValueKey('ssh-compose-send');
    const notice = ValueKey('ssh-compose-notice');
    const card = ValueKey('ssh-compose-card');
    const pencil = ValueKey('ssh-key-compose');

    Future<void> toggleCompose(WidgetTester tester) async {
      await tester.tap(find.byKey(pencil));
      await _frames(tester, 5);
    }

    String text(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(field)).controller!.text;

    bool sendEnabled(WidgetTester tester) =>
        tester
            .widget<InkWell>(
              find.descendant(
                of: find.byKey(send),
                matching: find.byType(InkWell),
              ),
            )
            .onTap !=
        null;

    Future<void> attach(
      WidgetTester tester,
      _Harness h,
      SshComposePick pick,
    ) async {
      h.picks[AttachmentSourceChoice.files] = [pick];
      await tester.tap(find.byKey(const ValueKey('ssh-compose-attach')));
      await _frames(tester, 2);
      await tester.tap(find.byKey(const ValueKey('ssh-compose-attach-files')));
      await _frames(tester, 5);
    }

    SshComposePick file(String name, [int size = 3]) =>
        SshComposePick.bytes(name, Uint8List(size), image: false);

    /// The bottom of the cursor's row, on screen.
    double cursorBottom(WidgetTester tester) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      return render.localToGlobal(render.cursorOffset).dy +
          render.cellSize.height;
    }

    testWidgets('herdr\'s card: the pencil opens it over the dock, the '
        'prompt line stays in sight, keyboard down or up; Send is one paste '
        'and Enter, a long press inserts without Enter', (tester) async {
      final h = await _open(tester);
      h.terminal.write('\x1b[?2004h');
      for (var i = 0; i < 80; i++) {
        h.terminal.write('line $i\r\n');
      }
      h.terminal.write('user@host:~\$ ');
      await _frames(tester, 2);
      const line = 'grep -rn "token" ~/src | head';

      expect(find.byKey(const ValueKey('ssh-dock-enter')), findsOneWidget);
      await toggleCompose(tester);
      expect(find.byKey(card), findsOneWidget);
      // The card sits on the dock; ↵ steps aside for its own send.
      expect(
        tester.getRect(find.byKey(card)).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('ssh-key-bar-pill'))).top,
        ),
      );
      // As wide as the dock, a little above it (herdr's card).
      final cardRect = tester.getRect(find.byKey(card));
      final strip = tester.getRect(
        find.byKey(const ValueKey('ssh-key-bar-pill')),
      );
      final actions = tester.getRect(
        find.byKey(const ValueKey('ssh-dock-actions')),
      );
      expect(cardRect.left, strip.left);
      expect(cardRect.right, actions.right);
      expect(strip.top - cardRect.bottom, 8);
      expect(find.byKey(const ValueKey('ssh-dock-enter')), findsNothing);
      expect(cursorBottom(tester), lessThanOrEqualTo(
        tester.getRect(find.byKey(card)).top,
      ));
      final box = tester.widget<TextField>(find.byKey(field));
      expect(box.enableSuggestions, isTrue);
      expect(box.autocorrect, isFalse);
      expect(box.enableIMEPersonalizedLearning, isFalse);
      expect(box.decoration!.hintText, 'Message or command');

      // The keyboard comes up: the card rides above it, the prompt still
      // above the card.
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      await _frames(tester, 3);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('ssh-key-bar-pill'))).bottom,
        lessThanOrEqualTo(600 - 300),
      );
      expect(cursorBottom(tester), lessThanOrEqualTo(
        tester.getRect(find.byKey(card)).top,
      ));

      await tester.enterText(find.byKey(field), line);
      await tester.pump();
      await tester.tap(find.byKey(send));
      await _frames(tester, 3);
      expect(h.sent, ['\x1b[200~$line\x1b[201~\r']);
      // Sent: the box is empty and stays open for the next.
      expect(text(tester), isEmpty);
      expect(find.byKey(card), findsOneWidget);

      await tester.enterText(find.byKey(field), 'echo a');
      await tester.pump();
      await tester.longPress(find.byKey(send));
      await _frames(tester, 3);
      expect(h.sent.sublist(1), ['\x1b[200~echo a\x1b[201~']);

      // What was sent, in memory only, a tap away.
      await tester.tap(find.byKey(const ValueKey('ssh-compose-history')));
      await _frames(tester, 2);
      final entry = find.byKey(const ValueKey('ssh-compose-history-1'));
      await tester.ensureVisible(entry);
      await tester.pump();
      await tester.tap(entry);
      await _frames(tester, 2);
      expect(text(tester), line);
      for (final key in h.prefs.getKeys()) {
        expect('${h.prefs.get(key)}', isNot(contains('token')), reason: key);
      }

      // The pencil, lit while open, closes it.
      await toggleCompose(tester);
      expect(find.byKey(card), findsNothing);
    });

    testWidgets('the draft outlives the card, a rotation and the screen', (
      tester,
    ) async {
      final h = await _open(tester);
      await toggleCompose(tester);
      await tester.enterText(find.byKey(field), 'half a thought');
      await tester.pump();
      await toggleCompose(tester);
      expect(find.byKey(field), findsNothing);

      await toggleCompose(tester);
      expect(text(tester), 'half a thought');

      // A rotation with the card open: laid out again, the text kept.
      tester.view.physicalSize = const Size(2400, 1080);
      addTearDown(tester.view.resetPhysicalSize);
      await _frames(tester, 3);
      expect(tester.takeException(), isNull);
      expect(text(tester), 'half a thought');

      Navigator.of(tester.element(find.byType(SshTerminalScreen))).pop();
      await _frames(tester, 5);
      await h.reopen(tester);
      await toggleCompose(tester);
      expect(text(tester), 'half a thought');
      expect(h.sent, isEmpty);
    });

    testWidgets('the keyboard key leaves Compose for typing straight into '
        'the terminal', (tester) async {
      await _open(tester);
      await toggleCompose(tester);
      await tester.tap(find.byKey(const ValueKey('ssh-dock-keyboard')));
      await _frames(tester, 3);
      expect(find.byKey(card), findsNothing);
      expect(
        tester.testTextInput.isVisible || tester.testTextInput.hasAnyClients,
        isTrue,
      );
    });

    testWidgets('a write that fails, or a dropped link, keeps the text and '
        'says so; nothing is sent twice', (tester) async {
      final h = await _open(tester);
      await toggleCompose(tester);
      await tester.enterText(find.byKey(field), 'make deploy');
      await tester.pump();

      final wired = h.terminal.onOutput;
      h.terminal.onOutput = (_) => throw StateError('channel closed');
      await tester.tap(find.byKey(send));
      await _frames(tester, 3);
      expect(find.byKey(notice), findsOneWidget);
      expect(text(tester), 'make deploy');
      expect(h.sent, isEmpty);
      expect(h.sessions.composeHistory(_connection), isEmpty);
      h.terminal.onOutput = wired;

      h.session.phase.value = SshSessionPhase.closed;
      await _frames(tester, 2);
      // Not connected, the dock and the card step aside; the draft stays.
      expect(find.byKey(card), findsNothing);
      h.session.phase.value = SshSessionPhase.ready;
      await _frames(tester, 2);
      expect(text(tester), 'make deploy');
      await tester.tap(find.byKey(send));
      await _frames(tester, 3);
      expect(h.sent, ['make deploy\r']);
      expect(text(tester), isEmpty);
    });

    testWidgets('closed transport refuses send; sudden drop after queued write '
        'recovers copy and communicates uncertainty without resending', (
      tester,
    ) async {
      final h = await _open(tester);
      final fakeClient = h.session.client! as _FakeClient;
      await toggleCompose(tester);
      await tester.enterText(find.byKey(field), 'git status');
      await tester.pump();

      // Already-closed client: write 0 times, keep draft, show error.
      fakeClient.closed = true;
      await tester.tap(find.byKey(send));
      await _frames(tester, 2);
      expect(h.sent, isEmpty);
      expect(text(tester), 'git status');
      expect(find.byKey(notice), findsOneWidget);

      // Open transport: write once, then drop the link immediately after.
      fakeClient.closed = false;
      await tester.tap(find.byKey(send));
      await _frames(tester, 2);
      expect(h.sent, ['git status\r']);
      expect(text(tester), isEmpty);

      h.session
        ..end = SshSessionEnd.connectionLost
        ..phase.value = SshSessionPhase.closed;
      await _frames(tester, 2);

      // Reconnected: recoverable copy is back, uncertainty is shown, and
      // nothing was auto-resent.
      h.session
        ..end = null
        ..phase.value = SshSessionPhase.ready;
      await _frames(tester, 2);
      expect(h.sent, ['git status\r']);
      expect(text(tester), 'git status');
      expect(
        tester.widget<Text>(find.byKey(notice)).data,
        'Connection dropped right after sending; check the terminal before '
        'sending again.',
      );
    });

    testWidgets('dictation joins the text; a failure says so', (tester) async {
      final h = await _open(tester);
      await toggleCompose(tester);
      await tester.enterText(find.byKey(field), 'ls');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      expect(h.dictation.recording, isTrue);
      expect(h.dictation.startedWith, 'ls');
      expect(find.byTooltip('Stop dictation'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      expect(text(tester), 'ls minus la');

      h.dictation.fail = true;
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      expect(
        find.text('Dictation is not available right now.'),
        findsOneWidget,
      );
    });

    testWidgets('late dictation merges with edits and is ignored after send or close', (
      tester,
    ) async {
      final h = await _open(tester);
      h.dictation.deferTranscription = true;
      await toggleCompose(tester);
      await tester.enterText(find.byKey(field), 'ls');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      expect(h.dictation.transcribing, isTrue);

      // User edits draft while transcription is in flight.
      await tester.enterText(find.byKey(field), 'ls -la');
      await tester.pump();
      h.dictation.deliverDeferred('docs');
      await _frames(tester, 2);
      expect(text(tester), 'ls -la docs');

      // Send cancels in-flight transcription and ignores late callbacks.
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      expect(h.dictation.transcribing, isTrue);
      final cancelsBeforeSend = h.dictation.cancelCount;
      await tester.tap(find.byKey(send));
      await _frames(tester, 2);
      expect(text(tester), isEmpty);
      expect(h.dictation.cancelCount, cancelsBeforeSend + 1);
      h.dictation.deliverDeferred('stale after send');
      await _frames(tester, 2);
      expect(text(tester), isEmpty);

      // Closing Compose cancels transcribing dictation and ignores late results.
      await tester.enterText(find.byKey(field), 'pwd');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      await tester.tap(find.byKey(const ValueKey('ssh-compose-mic')));
      await _frames(tester, 2);
      final cancelsBeforeClose = h.dictation.cancelCount;
      await toggleCompose(tester);
      expect(h.dictation.cancelCount, cancelsBeforeClose + 1);
      h.dictation.deliverDeferred('stale after close');
      await _frames(tester, 2);
      await toggleCompose(tester);
      expect(text(tester), 'pwd');
    });

    testWidgets('an attachment goes up to the private folder and its quoted '
        'path joins the text; the whole goes as one paste', (tester) async {
      final h = await _open(tester);
      h.terminal.write('\x1b[?2004h');
      await toggleCompose(tester);
      await tester.enterText(find.byKey(field), 'describe ');
      await tester.pump();

      await attach(tester, h, file("it's my photo.png", 5));
      final sftp = h.sessions.sftp;
      expect(sftp.made, {
        '$_home/.cache': null,
        '$_home/.cache/hermes-console': 0x1C0,
        _uploads: 0x1C0,
      });
      expect(sftp.files.length, 1);
      final remote = sftp.files.keys.single;
      expect(remote, startsWith('$_uploads/'));
      expect(remote, endsWith("-it_s_my_photo.png"));
      expect(sftp.files[remote], hasLength(5));
      expect(
        sftp.modes[remote]!.flag & SftpFileOpenMode.exclusive.flag,
        isNonZero,
        reason: 'never overwrites',
      );
      expect(text(tester), "describe '$remote' ");
      expect(
        find.byKey(const ValueKey('ssh-compose-attachment-0')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(send));
      await _frames(tester, 5);
      expect(h.sent, ["\x1b[200~describe '$remote' \x1b[201~\r"]);
      expect(sftp.removed, isEmpty, reason: 'sent: the program reads it');
    });

    testWidgets('a failed upload inserts nothing, says why and can be '
        'retried', (tester) async {
      final h = await _open(tester);
      h.sessions.sftpFailures = 1;
      await toggleCompose(tester);
      await attach(tester, h, file('notes.txt'));
      expect(text(tester), isEmpty);
      final said = tester.widget<Text>(find.byKey(notice)).data!;
      expect(said, startsWith('Upload failed · '));
      expect(sendEnabled(tester), isFalse);

      await tester.tap(
        find.byKey(const ValueKey('ssh-compose-attachment-retry-0')),
      );
      await _frames(tester, 5);
      final remote = h.sessions.sftp.files.keys.single;
      expect(text(tester), "'$remote' ");
      expect(h.sessions.sftpOpens, 2);
      expect(find.byKey(notice), findsNothing);
    });

    testWidgets('cancel stops an upload and removes what was written; a '
        'removed chip takes its path and its file away', (tester) async {
      final h = await _open(tester);
      final sftp = h.sessions.sftp;
      sftp.gate = Completer<void>();
      await toggleCompose(tester);
      await attach(tester, h, file('big.log'));
      final partial = sftp.files.keys.single;
      await tester.enterText(find.byKey(field), 'x');
      await tester.pump();
      // Still uploading: Send waits for it.
      expect(sendEnabled(tester), isFalse);
      await tester.tap(
        find.byKey(const ValueKey('ssh-compose-attachment-remove-0')),
      );
      sftp.gate!.complete();
      sftp.gate = null;
      await _frames(tester, 5);
      expect(sftp.removed, [partial]);
      expect(text(tester), 'x');
      expect(
        find.byKey(const ValueKey('ssh-compose-attachment-0')),
        findsNothing,
      );

      await tester.enterText(find.byKey(field), 'cat ');
      await tester.pump();
      await attach(tester, h, file('small.txt'));
      final uploaded = sftp.files.keys.single;
      expect(text(tester), "cat '$uploaded' ");
      await tester.tap(
        find.byKey(const ValueKey('ssh-compose-attachment-remove-0')),
      );
      await _frames(tester, 3);
      expect(text(tester), 'cat ');
      expect(sftp.removed, [partial, uploaded]);
    });

    testWidgets('too large or read-only: nothing goes up, and the card says '
        'why', (tester) async {
      final h = await _open(tester);
      await toggleCompose(tester);
      await attach(tester, h, file('huge.bin', 9 * 1024 * 1024));
      expect(find.text('The file exceeds the 8 MB limit.'), findsOneWidget);
      expect(h.sessions.sftpOpens, 0);
      await toggleCompose(tester);

      h.ssh.readOnly = true;
      await toggleCompose(tester);
      await tester.tap(find.byKey(const ValueKey('ssh-compose-attach')));
      await _frames(tester, 2);
      expect(
        find.text('This connection is read-only: files cannot be uploaded.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ssh-compose-attach-files')),
        findsNothing,
      );
      expect(h.sessions.sftpOpens, 0);
    });

    for (final (name, size, scale) in const [
      ('360 dp at 2x text', Size(360, 720), 2.0),
      ('landscape', Size(800, 360), 1.0),
      ('a 840 dp split', Size(840, 900), 1.0),
    ]) {
      testWidgets('$name, keyboard up: card and dock without overflow, the '
          'prompt in sight', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        tester.view
          ..physicalSize = size * 3
          ..devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final h = await _open(tester);
        h.terminal.write('user@host:~\$ ');
        await toggleCompose(tester);
        await attach(tester, h, file('a file with a long long name.txt'));
        await tester.enterText(find.byKey(field), 'x' * 300);
        tester.view.viewInsets = FakeViewPadding(bottom: size.height * 3 / 3);
        await _frames(tester, 3);
        expect(tester.takeException(), isNull);
        expect(
          cursorBottom(tester),
          lessThanOrEqualTo(tester.getRect(find.byKey(card)).top),
        );
      });
    }
  });

  group('a question the shell waits on', () {
    testWidgets('y/N offers its answers; a tap sends only that key', (
      tester,
    ) async {
      final h = await _open(tester);
      h.terminal.write('Answer (y/n) later\r\n\$ ');
      await _frames(tester, 2);
      expect(find.byKey(const ValueKey('ssh-terminal-prompt')), findsNothing);

      h.terminal.write('apt remove x\r\nDo you want to continue? [Y/n] ');
      await _frames(tester, 2);
      expect(find.byKey(const ValueKey('ssh-terminal-prompt')), findsOneWidget);
      expect(h.sent, isEmpty, reason: 'nothing is sent on its own');

      await tester.tap(find.byKey(const ValueKey('ssh-terminal-prompt-y')));
      await tester.tap(find.byKey(const ValueKey('ssh-terminal-prompt-⏎')));
      expect(h.sent, ['y', '\r']);

      h.terminal.write('y\r\n\$ ');
      await _frames(tester, 2);
      expect(find.byKey(const ValueKey('ssh-terminal-prompt')), findsNothing);
    });
  });

  group('scrolling sends no keys', () {
    testWidgets('one finger in a full-screen program: no arrow keys; the '
        'wheel once the program turns the mouse on', (tester) async {
      final h = await _open(tester);
      h.terminal.write('\x1b[?1049h');
      for (var i = 0; i < 10; i++) {
        h.terminal.write('row $i\r\n');
      }
      await tester.pump();
      final view = find.byType(TerminalView);

      await tester.drag(view, const Offset(0, 300));
      await _frames(tester, 2);
      await tester.drag(view, const Offset(0, -300));
      await _frames(tester, 2);
      expect(_sentArrows(h.sent), isFalse, reason: h.sent.join('|'));
      expect(h.sent, isEmpty);

      h.terminal.write('\x1b[?1000h\x1b[?1006h');
      await tester.drag(view, const Offset(0, 200));
      await _frames(tester, 2);
      expect(h.sent, isNotEmpty);
      expect(h.sent.every((s) => s.startsWith('\x1b[<64;')), isTrue);
      expect(_sentArrows(h.sent), isFalse);
    });

    testWidgets('one finger scrolls the scrollback; the chip goes back down',
        (tester) async {
      final h = await _open(tester);
      for (var i = 0; i < 200; i++) {
        h.terminal.write('line $i\r\n');
      }
      await _frames(tester, 2);
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TerminalView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final bottom = scrollable.position.maxScrollExtent;
      expect(scrollable.position.pixels, bottom);
      const chip = ValueKey('ssh-terminal-jump-bottom');
      expect(find.byKey(chip), findsNothing);

      await tester.drag(find.byType(TerminalView), const Offset(0, 300));
      await _frames(tester, 10);
      expect(scrollable.position.pixels, lessThan(bottom - 100));
      expect(find.byKey(chip), findsOneWidget);
      expect(h.sent, isEmpty);

      await tester.tap(find.byKey(chip));
      await _frames(tester, 2);
      expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);
      expect(find.byKey(chip), findsNothing);
    });

    testWidgets('two fingers page a full-screen program', (tester) async {
      final h = await _open(tester);
      h.terminal.write('\x1b[?1049h');
      await tester.pump();
      final center = tester.getCenter(find.byType(TerminalView));
      final a = await tester.startGesture(center - const Offset(40, 0));
      final b = await tester.startGesture(center + const Offset(40, 0));
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(0, 25));
        await b.moveBy(const Offset(0, 25));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await _frames(tester, 2);
      expect(h.sent, ['\x1b[5~']);
    });
  });

  testWidgets('a pinch changes the font size, kept for the next time', (
    tester,
  ) async {
    final h = await _open(tester);
    expect(_fontSize(tester), SshTerminalScreen.fontSize);
    final center = tester.getCenter(find.byType(TerminalView));
    final a = await tester.startGesture(center - const Offset(30, 0));
    final b = await tester.startGesture(center + const Offset(30, 0));
    for (var i = 0; i < 4; i++) {
      await a.moveBy(const Offset(-6, 0));
      await b.moveBy(const Offset(6, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await _frames(tester, 2);
    final pinched = _fontSize(tester);
    expect(pinched, greaterThan(SshTerminalScreen.fontSize));
    expect(h.prefs.getDouble(SshTerminalScreen.fontSizePrefsKey), pinched);
    expect(h.sent, isEmpty);

    // Opened again, the terminal comes back at that size.
    Navigator.of(tester.element(find.byType(SshTerminalScreen))).pop();
    await _frames(tester, 5);
    expect(find.byType(SshTerminalScreen), findsNothing);
    await h.reopen(tester);
    expect(_fontSize(tester), pinched);
  });

  group('links', () {
    testWidgets('a tapped address goes to the link callback', (tester) async {
      final h = await _open(tester);
      h.terminal.write('docs: https://example.com/docs/terminal now\r\n');
      await tester.pump();

      await tester.tapAt(_cell(tester, 0, 0));
      // Past the double-tap window: the next tap is a tap of its own.
      await _frames(tester, 5);
      expect(h.opened, isEmpty);
      await tester.tapAt(_cell(tester, 12, 0));
      await _frames(tester, 5);
      expect(h.opened, [Uri.parse('https://example.com/docs/terminal')]);
      expect(h.sent, isEmpty);
    });

    testWidgets('a long press on it offers Copy link and Open link', (
      tester,
    ) async {
      final h = await _open(tester);
      final clip = _clipboard(tester);
      h.terminal.write('see https://example.com/a?b=c.\r\n');
      await tester.pump();

      await tester.longPressAt(_cell(tester, 10, 0));
      await _frames(tester, 3);
      await tester.tap(find.text('Copy link'));
      await _frames(tester, 2);
      expect(clip.written, ['https://example.com/a?b=c']);

      await tester.longPressAt(_cell(tester, 10, 0));
      await _frames(tester, 3);
      await tester.tap(find.text('Open link'));
      await _frames(tester, 2);
      expect(h.opened, [Uri.parse('https://example.com/a?b=c')]);
    });
  });

  testWidgets('a hardware keyboard: Ctrl+A and Ctrl+V reach the shell, '
      'Ctrl+Shift+V pastes and Ctrl+Shift+C copies', (tester) async {
    final h = await _open(tester);
    final clip = _clipboard(tester, text: 'pwd');
    h.terminal.write('alpha beta\r\n');
    await tester.tap(find.byType(TerminalView));
    await _frames(tester, 2);
    h.sent.clear();

    Future<void> chord(LogicalKeyboardKey key, {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _frames(tester, 1);
    }

    await chord(LogicalKeyboardKey.keyA);
    await chord(LogicalKeyboardKey.keyV);
    expect(h.sent, ['\x01', '\x16']);
    expect(clip.written, isEmpty);

    await chord(LogicalKeyboardKey.keyV, shift: true);
    expect(h.sent, ['\x01', '\x16', 'pwd']);

    await tester.longPressAt(_cell(tester, 7, 0));
    await _frames(tester, 3);
    await chord(LogicalKeyboardKey.keyC, shift: true);
    await _frames(tester, 2);
    expect(clip.written, ['beta']);

    // Physical arrow keys consume armed sticky Ctrl/Alt instead of leaking
    // the modifier to the next plain character.
    h.sent.clear();
    h.session.modifiers.ctrl.tap();
    expect(h.session.modifiers.ctrl.armed.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(h.sent, ['\x1b[1;5D']);
    expect(h.session.modifiers.ctrl.armed.value, isFalse);
    h.terminal.textInput('a');
    expect(h.sent.last, 'a');

    h.sent.clear();
    h.session.modifiers.alt.tap();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(h.sent, ['\x1b[1;3C']);
    expect(h.session.modifiers.alt.armed.value, isFalse);
    h.terminal.textInput('b');
    expect(h.sent.last, 'b');
  });

  testWidgets('an open terminal tells the service, which spares it from the '
      'idle close; closed, it no longer does', (tester) async {
    final h = await _open(tester);
    expect(h.sessions.isViewed(_connection), isTrue);
    Navigator.of(tester.element(find.byType(SshTerminalScreen))).pop();
    await _frames(tester, 5);
    expect(h.sessions.isViewed(_connection), isFalse);
  });

  testWidgets('idle exemption applies only while visible and resumed', (
    tester,
  ) async {
    final h = await _open(tester);
    expect(h.sessions.isViewed(_connection), isTrue);

    // Covering the route releases the idle exemption until popped.
    final nav = Navigator.of(tester.element(find.byType(SshTerminalScreen)));
    nav.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
    await _frames(tester, 5);
    expect(h.sessions.isViewed(_connection), isFalse);
    nav.pop();
    await _frames(tester, 5);
    expect(h.sessions.isViewed(_connection), isTrue);

    // Backgrounding or losing resumed state releases the idle exemption.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(h.sessions.isViewed(_connection), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(h.sessions.isViewed(_connection), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(h.sessions.isViewed(_connection), isTrue);
  });

  testWidgets('hidden workspace tab (TickerMode disabled) releases idle exemption', (
    tester,
  ) async {
    final h = await _open(tester);
    final ticker = ValueNotifier<bool>(true);
    addTearDown(ticker.dispose);
    final nav = Navigator.of(tester.element(find.byType(SshTerminalScreen)));
    nav.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<bool>(
          valueListenable: ticker,
          builder: (context, enabled, _) => TickerMode(
            enabled: enabled,
            child: SshTerminalScreen(connection: _connectionInfo),
          ),
        ),
      ),
    );
    await _frames(tester, 5);
    expect(h.sessions.isViewed(_connection), isTrue);

    ticker.value = false;
    await _frames(tester, 3);
    expect(h.sessions.isViewed(_connection), isFalse);

    ticker.value = true;
    await _frames(tester, 3);
    expect(h.sessions.isViewed(_connection), isTrue);
  });
}
