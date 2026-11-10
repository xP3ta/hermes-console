import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/character_export.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('character_share_'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<Directory> temp() async => root;
  final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

  List<File> left() {
    final folder = Directory('${root.path}/$characterShareFolder');
    if (!folder.existsSync()) return const [];
    return folder.listSync(recursive: true).whereType<File>().toList();
  }

  test('the file exists while the sheet is open and is gone after', () async {
    String? seen;
    Uint8List? bytes;
    await shareCharacterPng(
      png,
      'Ana Bot',
      tempDirectory: temp,
      share: (file) async {
        seen = file.path;
        bytes = await file.readAsBytes();
        expect(left(), hasLength(1));
      },
    );
    expect(seen, endsWith('/ana-bot.png'));
    expect(bytes, png);
    expect(left(), isEmpty);
  });

  test('a failed share still deletes the file and rethrows', () async {
    await expectLater(
      shareCharacterPng(
        png,
        'ana',
        tempDirectory: temp,
        share: (_) async => throw StateError('no app'),
      ),
      throwsStateError,
    );
    expect(left(), isEmpty);
  });

  test('two shares of one name never use the same file', () async {
    final paths = <String>[];
    Future<void> one() => shareCharacterPng(
      png,
      'same',
      tempDirectory: temp,
      share: (file) async {
        paths.add(file.path);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
    );
    await Future.wait([one(), one()]);
    expect(paths.toSet(), hasLength(2));
    expect(left(), isEmpty);
  });

  test('clearing removes what an interrupted share left', () async {
    final stray = File('${root.path}/$characterShareFolder/1/x.png')
      ..createSync(recursive: true);
    expect(stray.existsSync(), isTrue);
    await clearCharacterShareFiles(tempDirectory: temp);
    expect(left(), isEmpty);
    // Nothing to clear is not an error.
    await clearCharacterShareFiles(tempDirectory: temp);
  });
}
