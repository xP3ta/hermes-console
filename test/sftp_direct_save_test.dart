// SFTP «Descargar» writes straight to the place chosen (orden
// DESCARGAS-DIRECTAS, points 1-3): the remote file is read in blocks and
// each block goes to the document Android gave, in order, with no copy in
// the app; a cancel, a failed read or a failed write deletes the document
// half written; a connection that fails before anything is written deletes
// the empty document too. At start only APK 9708's private folder goes,
// after the first frame, and without the app's folders it is skipped,
// never failing the start.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/save_to_device.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('hermes/save_to_device');
const _doc = 'content://com.android.externalstorage.documents/document/1';
const _secureStorage = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

List<MethodCall> _android(Object? Function(MethodCall call) answer) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_channel, (call) async {
    calls.add(call);
    final result = answer(call);
    if (result is PlatformException) throw result;
    return result;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  return calls;
}

Object? _documentSide(MethodCall call) => switch (call.method) {
  'begin' => 1,
  'write' => 0,
  _ => null,
};

/// A remote file of [size] bytes, `i % 251` each; [reads] records offsets.
Future<Uint8List> Function(int, int) _remote(int size, List<int> reads) =>
    (offset, length) async {
      reads.add(offset);
      final end = (offset + length).clamp(0, size);
      return Uint8List.fromList([for (var i = offset; i < end; i++) i % 251]);
    };

class _Cancelled implements Exception {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = SaveToDevice();
  const size = 150 * 1024;
  const chunk = 64 * 1024;

  test('the remote file goes block by block into the document', () async {
    final calls = _android(_documentSide);
    final reads = <int>[];
    final progress = <int>[];
    var closedRemote = 0;
    await writeRemoteFile(
      read: _remote(size, reads),
      openSink: () => device.begin(_doc),
      totalBytes: size,
      onProgress: (done) async => progress.add(done),
      beforeClose: () async => closedRemote++,
    );
    expect(reads, [0, chunk, 2 * chunk]);
    expect(progress, [chunk, 2 * chunk, size]);
    expect(closedRemote, 1);
    expect(calls.map((c) => c.method), [
      'begin',
      'write',
      'write',
      'write',
      'finish',
    ]);
    expect((calls.first.arguments as Map)['uri'], _doc);
    // The bytes written are the remote file's, in order.
    final written = <int>[
      for (final c in calls.where((c) => c.method == 'write'))
        ...((c.arguments as Map)['bytes'] as Uint8List),
    ];
    expect(written.length, size);
    expect(written.take(3), [0, 1, 2]);
    expect(written[chunk], chunk % 251);
    expect(written.last, (size - 1) % 251);
    // Nothing goes through a copy of the app.
    expect(calls.where((c) => c.method == 'copy'), isEmpty);
  });

  test('a size the server does not give is read until the end', () async {
    final calls = _android(_documentSide);
    final reads = <int>[];
    await writeRemoteFile(
      read: _remote(size, reads),
      openSink: () => device.begin(_doc),
      totalBytes: 0,
    );
    // The read past the end comes back empty and ends it.
    expect(reads, [0, chunk, 2 * chunk, size]);
    expect(calls.last.method, 'finish');
  });

  test('a cancel deletes the document half written', () async {
    final calls = _android(_documentSide);
    var cancelled = false;
    await expectLater(
      writeRemoteFile(
        read: _remote(size, []),
        openSink: () => device.begin(_doc),
        totalBytes: size,
        checkCancelled: () {
          if (cancelled) throw _Cancelled();
        },
        onProgress: (_) async => cancelled = true,
      ),
      throwsA(isA<_Cancelled>()),
    );
    expect(calls.map((c) => c.method), ['begin', 'write', 'abort']);
  });

  test('a read that fails (the network) deletes the document', () async {
    final calls = _android(_documentSide);
    var n = 0;
    await expectLater(
      writeRemoteFile(
        read: (offset, length) async {
          if (n++ == 1) throw const SocketException('reset');
          return Uint8List(length);
        },
        openSink: () => device.begin(_doc),
        totalBytes: size,
      ),
      throwsA(isA<SocketException>()),
    );
    expect(calls.map((c) => c.method), ['begin', 'write', 'abort']);
  });

  test('a write that fails halfway deletes the document', () async {
    var writes = 0;
    final calls = _android((call) {
      if (call.method == 'write' && ++writes == 2) {
        return PlatformException(code: 'no_space');
      }
      return _documentSide(call);
    });
    await expectLater(
      writeRemoteFile(
        read: _remote(size, []),
        openSink: () => device.begin(_doc),
        totalBytes: size,
      ),
      throwsA(
        isA<SaveFailure>()
            .having((f) => f.problem, 'problem', SaveProblem.noSpace)
            .having((f) => f.bytes, 'bytes', chunk),
      ),
    );
    expect(calls.map((c) => c.method), ['begin', 'write', 'write', 'abort']);
  });

  test('a temporary copy to share is deleted when it fails', () async {
    final dir = await Directory.systemTemp.createTemp('sftp-share');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.bin');
    await expectLater(
      writeRemoteFile(
        read: (offset, length) async {
          if (offset > 0) throw const SocketException('reset');
          return Uint8List(length);
        },
        openSink: () async => FileSaveSink(file),
        totalBytes: size,
      ),
      throwsA(isA<SocketException>()),
    );
    expect(file.existsSync(), isFalse);
  });

  group('the transfer service', () {
    late Directory support;
    late Directory cache;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'app_locale': 'en'});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorage, (call) async {
            return call.method == 'readAll' ? <String, String>{} : null;
          });
      support = await Directory.systemTemp.createTemp('sftp-support');
      cache = await Directory.systemTemp.createTemp('sftp-cache');
    });

    tearDown(() async {
      await support.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    Future<SftpTransferService> service() async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      return SftpTransferService(
        SshManager(SecureStorage(), manager),
        null,
        cache: () async => cache,
        support: () async => support,
      );
    }

    test('no connection: the empty document chosen is deleted', () async {
      final calls = _android(_documentSide);
      final t = await (await service()).download(
        connectionId: 'missing',
        remotePath: '/srv/informe.pdf',
        fileName: 'informe.pdf',
        totalBytes: 10,
        document: _doc,
      );
      expect(t.status, TransferStatus.error);
      expect(t.problem, SaveProblem.network);
      expect(t.saved, isNull);
      expect(t.error, isNotEmpty);
      expect(calls.map((c) => c.method), ['delete']);
      expect((calls.single.arguments as Map)['uri'], _doc);
    });

    test('a share copy goes to the cache only, and is cleared', () async {
      final transfers = await service();
      final t = await transfers.downloadToShare(
        connectionId: 'missing',
        remotePath: '/srv/informe.pdf',
        fileName: 'informe.pdf',
        totalBytes: 10,
      );
      expect(t.forShare, isTrue);
      expect(t.status, TransferStatus.error);
      final left = Directory('${cache.path}/sftp_share/old')
        ..createSync(recursive: true);
      File('${left.path}/x.bin').writeAsBytesSync([1]);
      await transfers.clearShareCopies();
      expect(Directory('${cache.path}/sftp_share').listSync(), isEmpty);
      expect(support.listSync(), isEmpty);
    });

    test('at start, only 9708\'s private downloads folder goes', () async {
      final legacy = Directory('${support.path}/sftp_downloads')..createSync();
      File('${legacy.path}/informe.pdf').writeAsBytesSync([1, 2, 3]);
      final other = Directory('${support.path}/generated_media')..createSync();
      File('${other.path}/foto.png').writeAsBytesSync([4]);
      final index = File('${support.path}/sftp_downloads.json')
        ..writeAsStringSync('[]');
      final share = Directory('${cache.path}/sftp_share/d1')
        ..createSync(recursive: true);
      File('${share.path}/a.bin').writeAsBytesSync([5]);

      await (await service()).cleanUpAtStart();

      expect(legacy.existsSync(), isFalse);
      expect(File('${other.path}/foto.png').existsSync(), isTrue);
      expect(index.existsSync(), isTrue);
      expect(share.existsSync(), isFalse);
      // Twice is harmless.
      await (await service()).cleanUpAtStart();
      expect(File('${other.path}/foto.png').existsSync(), isTrue);
    });

    test('the clean up never fails the start; it says why', () async {
      final logged = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          logged.add(message ?? '');
      addTearDown(() => debugPrint = previous);
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      for (final (failure, type) in [
        (
          MissingPluginException('getTemporaryDirectory'),
          'MissingPluginException',
        ),
        (PlatformException(code: 'unavailable'), 'PlatformException'),
        (
          const FileSystemException('list', '/x', OSError('denied', 13)),
          'FileSystemException os=13',
        ),
      ]) {
        logged.clear();
        final transfers = SftpTransferService(
          SshManager(SecureStorage(), manager),
          null,
          cache: () async => throw failure,
          support: () async => support,
        );
        await expectLater(transfers.cleanUpAtStart(), completes);
        expect(logged, contains('[save] cleanup skipped=$type'), reason: type);
      }
      // Without the private folder either, the same.
      logged.clear();
      final noSupport = SftpTransferService(
        SshManager(SecureStorage(), manager),
        null,
        cache: () async => cache,
        support: () async =>
            throw MissingPluginException('getApplicationSupportDirectory'),
      );
      await expectLater(noSupport.cleanUpAtStart(), completes);
      expect(logged, contains('[save] cleanup skipped=MissingPluginException'));
    });

    test('the clean up waits for the first frame', () async {
      final asked = <String>[];
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final legacy = Directory('${support.path}/sftp_downloads')..createSync();
      final transfers = SftpTransferService(
        SshManager(SecureStorage(), manager),
        null,
        cache: () async {
          asked.add('cache');
          return cache;
        },
        support: () async {
          asked.add('support');
          return support;
        },
      );
      final firstFrame = Completer<void>();
      transfers.cleanUpAfter(firstFrame.future);
      // However long the start takes, nothing is touched before the frame.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(asked, isEmpty);
      expect(legacy.existsSync(), isTrue);

      firstFrame.complete();
      for (var i = 0; i < 200 && legacy.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(asked, ['cache', 'support']);
      expect(legacy.existsSync(), isFalse);
    });
  });
}
