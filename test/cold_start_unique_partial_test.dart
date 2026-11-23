// Two writers of the same sealed file (the app and the process that answers
// from a notification, or two stores of one process) used to fill the same
// `<file>.part`: a mix of both could be renamed over the good file and leave
// it unreadable until the next save. Each write has its own temporary file.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';

void main() {
  late Directory dir;
  SecureColdStartStorage storage() =>
      SecureColdStartStorage(directory: () async => dir);

  setUp(() => dir = Directory.systemTemp.createTempSync('unique_partial_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('each write gets a temporary file of its own', () {
    final names = {
      for (var i = 0; i < 50; i++) SecureColdStartStorage.partialName('a.b.ct'),
    };
    expect(names, hasLength(50));
    for (final name in names) {
      expect(name, endsWith(SecureColdStartStorage.partialSuffix));
      expect(SecureColdStartStorage.partialTarget(name), 'a.b.ct');
    }
  });

  test('the file an unfinished write was for is read from both name forms', () {
    expect(SecureColdStartStorage.partialTarget('a.b.ct.part'), 'a.b.ct');
    expect(SecureColdStartStorage.partialTarget('a.b.ct.k3-1f.part'), 'a.b.ct');
    expect(SecureColdStartStorage.partialTarget('a.b.ct'), isNull);
  });

  test('concurrent writes of one file leave one whole value and no '
      'temporary file', () async {
    // Two stores, as two processes have: neither queues behind the other.
    final first = storage();
    final second = storage();
    const size = 4 * 1024 * 1024;
    final a = Uint8List(size)..fillRange(0, size, 0xAA);
    final b = Uint8List(size)..fillRange(0, size, 0xBB);

    for (var round = 0; round < 6; round++) {
      await Future.wait([
        first.writeFile('x.y.ct', a),
        second.writeFile('x.y.ct', b),
      ]);
      final stored = (await first.readFile('x.y.ct'))!;
      expect(stored, hasLength(size));
      expect(
        stored.every((byte) => byte == stored.first),
        isTrue,
        reason: 'one writer\'s bytes, never a mix',
      );
      expect(await first.fileNames(), ['x.y.ct']);
    }
  });

  test('a write that fails leaves no temporary file behind', () async {
    final files = storage();
    // The target is a directory: the rename cannot succeed.
    Directory('${dir.path}/x.y.ct').createSync(recursive: true);
    File('${dir.path}/x.y.ct/keep').writeAsStringSync('k');
    await expectLater(
      files.writeFile('x.y.ct', Uint8List.fromList([1, 2, 3])),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      dir.listSync().whereType<File>().map((f) => f.path),
      isEmpty,
    );
  });

  test('a write of a file sweeps what a dead process left for it, and '
      'leaves alone a write another process has in flight', () async {
    final files = storage();
    final bytes = Uint8List.fromList([1, 2, 3]);
    File old(String name) => File('${dir.path}/$name');
    // An earlier version's name: nothing writes it any more.
    old('x.y.ct.part').writeAsBytesSync(bytes);
    // This version's, from a process that died long ago.
    old('x.y.ct.dead-1.part')
      ..writeAsBytesSync(bytes)
      ..setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 5)),
      );
    // A write in flight in another process, and one of another file.
    old('x.y.ct.live-1.part').writeAsBytesSync(bytes);
    old('other.ct.part').writeAsBytesSync(bytes);

    await files.writeFile('x.y.ct', bytes);

    expect(
      (await files.fileNames())..sort(),
      ['other.ct.part', 'x.y.ct', 'x.y.ct.live-1.part'],
    );
  });
}
