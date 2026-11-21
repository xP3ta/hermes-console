import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_compose_uploads.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';

class _ControlledSftpFile implements SftpFile {
  _ControlledSftpFile(this.sftp, this.path);

  final _ControlledSftp sftp;
  final String path;

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    final gate = sftp.writeGate;
    if (gate != null) await gate.future;
    sftp.files[path]?.addAll(data);
  }

  @override
  Future<SftpFileAttrs> stat() async {
    final bytes = sftp.files[path];
    return SftpFileAttrs(
      size: bytes?.length ?? 0,
      mode: const SftpFileMode.value(0x8180),
      modifyTime: sftp.mtimes[path] ?? 1700000000,
    );
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledSftp implements SftpClient {
  final Map<String, int> dirs = {};
  final Set<String> symlinks = {};
  final Map<String, List<int>> files = {};
  final Map<String, int> mtimes = {};
  final List<String> removed = [];
  final List<String> setStatPaths = [];
  bool closed = false;
  Completer<void>? writeGate;

  @override
  Future<String> absolute(String path) async => '/home/demo';

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    if (dirs.containsKey(path) || symlinks.contains(path)) {
      throw SftpStatusError(4, 'Exists');
    }
    dirs[path] = attrs?.mode?.value ?? 0x1ED;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (!followLink && symlinks.contains(path)) {
      return SftpFileAttrs(mode: const SftpFileMode.value(0xA1FF));
    }
    if (symlinks.contains(path)) {
      return SftpFileAttrs(mode: const SftpFileMode.value(0x41ED));
    }
    if (dirs.containsKey(path)) {
      return SftpFileAttrs(mode: SftpFileMode.value(0x4000 | dirs[path]!));
    }
    if (files.containsKey(path)) {
      return SftpFileAttrs(
        size: files[path]!.length,
        mode: const SftpFileMode.value(0x8180),
        modifyTime: mtimes[path] ?? 1700000000,
      );
    }
    throw SftpStatusError(2, 'No such file');
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    setStatPaths.add(path);
    if (dirs.containsKey(path) && attrs.mode != null) {
      dirs[path] = attrs.mode!.value;
    }
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    files[path] = [];
    mtimes[path] = 1700000000;
    return _ControlledSftpFile(this, path);
  }

  @override
  Future<void> remove(String filename) async {
    removed.add(filename);
    files.remove(filename);
  }

  @override
  void close() {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SFTP upload deadlines, immediate cancel, and session close', () {
    test('hung writeBytes fails at stepTimeout and unblocks draft', () async {
      final sftp = _ControlledSftp()..writeGate = Completer<void>();
      var opens = 0;
      final uploader = SshComposeUploader(
        () async {
          opens++;
          return sftp;
        },
        stepTimeout: const Duration(milliseconds: 50),
        uploadTimeout: const Duration(seconds: 2),
        cleanupTimeout: const Duration(milliseconds: 50),
      );
      final draft = SshComposeDraft(uploader);
      addTearDown(draft.dispose);

      final attachment = await draft.attach(
        SshComposePick.bytes('a.bin', Uint8List(8)),
      );
      expect(attachment.state, SshUploadState.failed);
      expect(attachment.error, isA<TimeoutException>());
      expect(draft.uploading, isFalse);
      expect(sftp.closed, isTrue);

      // Next try opens a fresh SFTP session and succeeds once unblocked.
      sftp
        ..closed = false
        ..writeGate = null;
      await draft.retry(attachment);
      expect(opens, 2);
      expect(attachment.state, SshUploadState.done);
    });

    test('cancel settles immediately while writeBytes is stalled', () async {
      final sftp = _ControlledSftp()..writeGate = Completer<void>();
      final uploader = SshComposeUploader(
        () async => sftp,
        stepTimeout: const Duration(seconds: 10),
        uploadTimeout: const Duration(seconds: 10),
        cleanupTimeout: const Duration(milliseconds: 80),
      );
      final draft = SshComposeDraft(uploader);
      addTearDown(draft.dispose);

      final future = draft.attach(
        SshComposePick.bytes('hang.bin', Uint8List(8)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(draft.uploading, isTrue);

      final attachment = draft.attachments.value.single;
      uploader.cancel(attachment);

      final settled = await future.timeout(const Duration(milliseconds: 400));
      expect(settled.state, SshUploadState.cancelled);
      expect(draft.uploading, isFalse);
      expect(sftp.removed, hasLength(1));
    });

    test('session close aborts stalled upload promptly', () async {
      final sftp = _ControlledSftp()..writeGate = Completer<void>();
      final sessionDone = Completer<void>();
      final uploader = SshComposeUploader(
        () async => sftp,
        stepTimeout: const Duration(seconds: 10),
        uploadTimeout: const Duration(seconds: 10),
        cleanupTimeout: const Duration(milliseconds: 80),
        onSessionDone: () => sessionDone.future,
      );
      final draft = SshComposeDraft(uploader);
      addTearDown(draft.dispose);

      final future = draft.attach(
        SshComposePick.bytes('drop.bin', Uint8List(8)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      sessionDone.complete();

      final settled = await future.timeout(const Duration(milliseconds: 400));
      expect(settled.state, SshUploadState.failed);
      expect(draft.uploading, isFalse);
      expect(sftp.closed, isTrue);
    });
  });

  group('SFTP symlink safety, verified removal, and unsent cleanup', () {
    test('pre-existing symlink never receives setStat and uses private fallback', () async {
      final sftp = _ControlledSftp()
        ..dirs['/home/demo/.cache'] = 0x1ED
        ..symlinks.add('/home/demo/.cache/hermes-console');
      final uploader = SshComposeUploader(() async => sftp);
      final draft = SshComposeDraft(uploader);
      addTearDown(draft.dispose);

      final attachment = await draft.attach(
        SshComposePick.bytes('photo.png', Uint8List.fromList([1, 2, 3, 4])),
      );
      expect(attachment.state, SshUploadState.done);
      expect(sftp.setStatPaths, isEmpty);
      expect(
        attachment.remotePath,
        startsWith('/home/demo/.hermes-console-uploads-'),
      );
      final folder = attachment.remotePath!.substring(
        0,
        attachment.remotePath!.lastIndexOf('/'),
      );
      expect(sftp.dirs[folder], 0x1C0);
    });

    test('discard skips remove if file was replaced or swapped to a symlink', () async {
      final sftp = _ControlledSftp();
      final uploader = SshComposeUploader(() async => sftp);
      final draft = SshComposeDraft(uploader);
      addTearDown(draft.dispose);

      final a1 = await draft.attach(
        SshComposePick.bytes('a.txt', Uint8List.fromList([1, 2, 3])),
      );
      final path1 = a1.remotePath!;
      // Simulate external replacement (different mtime/size).
      sftp.mtimes[path1] = 1799999999;
      await draft.remove(a1);
      expect(sftp.removed, isNot(contains(path1)));

      final a2 = await draft.attach(
        SshComposePick.bytes('b.txt', Uint8List.fromList([4, 5, 6])),
      );
      final path2 = a2.remotePath!;
      // Simulate swap to symlink.
      sftp.files.remove(path2);
      sftp.symlinks.add(path2);
      await draft.remove(a2);
      expect(sftp.removed, isNot(contains(path2)));

      final a3 = await draft.attach(
        SshComposePick.bytes('c.txt', Uint8List.fromList([7, 8])),
      );
      final path3 = a3.remotePath!;
      // Unmodified file IS removed.
      await draft.remove(a3);
      expect(sftp.removed, contains(path3));
    });

    test('unsent uploads are cleaned up on session close; sent uploads stay', () async {
      final sftp = _ControlledSftp();
      final shell = _FakeShell();
      final client = _CloseTrackClient(sftp, shell);
      final svc = SshSessionService(_FakeSshMgr(client));
      const id = 'conn-cleanup';
      final session = await svc.connect(id, onHostKey: (_) async => true);
      expect(session.phase.value, SshSessionPhase.ready);

      final draft = svc.composeDraft(id);
      final sentAtt = await draft.attach(
        SshComposePick.bytes('sent.txt', Uint8List.fromList([1, 2])),
      );
      final sentPath = sentAtt.remotePath!;
      draft.clear();

      final unsentAtt = await draft.attach(
        SshComposePick.bytes('unsent.txt', Uint8List.fromList([3, 4, 5])),
      );
      final unsentPath = unsentAtt.remotePath!;

      svc.close(id);
      expect(shell.closed, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sftp.removed, contains(unsentPath));
      expect(sftp.removed, isNot(contains(sentPath)));
      expect(client.closed, isTrue);
      expect(client.removedWhileOpen, isTrue);
    });
  });
}

class _FakeShell implements SSHSession {
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();
  bool closed = false;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void close() => closed = true;

  @override
  void write(Uint8List data) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CloseTrackClient implements SSHClient {
  _CloseTrackClient(this._sftp, this._shell);

  final _ControlledSftp _sftp;
  final _FakeShell _shell;
  final _done = Completer<void>();
  bool closed = false;
  bool removedWhileOpen = false;

  @override
  bool get isClosed => closed;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> get authenticated => Future<void>.value();

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => _shell;

  @override
  Future<SftpClient> sftp() async => _sftp;

  @override
  void close() {
    if (_sftp.removed.isNotEmpty) removedWhileOpen = true;
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshMgr implements SshManager {
  _FakeSshMgr(this._client);

  final SSHClient _client;

  @override
  Future<SshSessionKind> loadSessionKind(String connectionId) async =>
      SshSessionKind.shell;

  @override
  Future<SSHClient> connect(
    String connectionId, {
    required Future<bool> Function(SshHostKeyPrompt) onHostKey,
  }) async => _client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
