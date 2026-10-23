import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/tts_model_manager.dart';

const _dirName = 'vits-piper-test-voice';
const _onnxFile = 'test-voice.onnx';

File _writeArchive(Directory root, Archive archive) {
  final tar = TarEncoder().encodeBytes(archive);
  return _writeTar(root, tar);
}

File _writeTar(Directory root, List<int> tar) {
  final compressed = BZip2Encoder().encodeBytes(tar);
  return File('${root.path}/voice.tar.bz2')..writeAsBytesSync(compressed);
}

Archive _completeArchive({
  bool includePhondata = true,
  bool emptyDictionary = false,
  String dictionaryLanguage = 'es',
}) {
  final archive = Archive();
  archive.add(ArchiveFile.directory('$_dirName/'));
  archive.add(
    ArchiveFile.bytes('$_dirName/$_onnxFile', List<int>.filled(1024 * 1024, 1)),
  );
  archive.add(
    ArchiveFile.string('$_dirName/tokens.txt', 'a b c d e f g h i j k l'),
  );
  archive.add(
    ArchiveFile.string('$_dirName/espeak-ng-data/phontab', 'phontab'),
  );
  if (includePhondata) {
    archive.add(
      ArchiveFile.string('$_dirName/espeak-ng-data/phondata', 'phondata'),
    );
  }
  archive.add(
    ArchiveFile.string('$_dirName/espeak-ng-data/phonindex', 'phonindex'),
  );
  archive.add(
    ArchiveFile.string(
      '$_dirName/espeak-ng-data/${dictionaryLanguage}_dict',
      emptyDictionary ? '' : 'diccionario',
    ),
  );
  archive.add(
    ArchiveFile.string('$_dirName/espeak-ng-data/voices/es/test', 'name test'),
  );
  archive.add(
    ArchiveFile.string('$_dirName/$_onnxFile.json', '{"unused":true}'),
  );
  archive.add(ArchiveFile.string('$_dirName/MODEL_CARD', 'unused'));
  return archive;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('instala en staging solo los artefactos TTS que usa la app', () {
    final root = Directory.systemTemp.createTempSync('tts-model-archive-');
    try {
      final old = Directory('${root.path}/$_dirName')..createSync();
      File('${old.path}/resto-parcial').writeAsStringSync('stale');
      final input = _writeArchive(root, _completeArchive());

      extractTtsModelArchive(
        input.path,
        root.path,
        dirName: _dirName,
        onnxFile: _onnxFile,
        languageCode: 'es',
      );

      final target = Directory('${root.path}/$_dirName');
      expect(File('${target.path}/$_onnxFile').lengthSync(), 1024 * 1024);
      expect(File('${target.path}/tokens.txt').lengthSync(), greaterThan(16));
      expect(
        File('${target.path}/espeak-ng-data/voices/es/test').readAsStringSync(),
        'name test',
      );
      expect(File('${target.path}/$_onnxFile.json').existsSync(), isFalse);
      expect(File('${target.path}/MODEL_CARD').existsSync(), isFalse);
      expect(File('${target.path}/resto-parcial').existsSync(), isFalse);
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
      expect(
        Directory('${root.path}/$_dirName.previous').existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('Mandarin installs with cmn_dict and still rejects a missing dictionary', () {
    final root = Directory.systemTemp.createTempSync('tts-model-mandarin-');
    try {
      final voice = neuralVoiceById('zh_CN-huayan-medium')!;
      final input = _writeArchive(root, _completeArchive(dictionaryLanguage: 'cmn'));
      extractTtsModelArchive(input.path, root.path,
          dirName: _dirName, onnxFile: _onnxFile,
          languageCode: voice.dictionaryLanguage);
      final dictionary = File('${root.path}/$_dirName/espeak-ng-data/cmn_dict');
      expect(dictionary.existsSync(), isTrue);
      final incomplete = _writeArchive(root, _completeArchive());
      expect(() => extractTtsModelArchive(incomplete.path, root.path,
          dirName: _dirName, onnxFile: _onnxFile,
          languageCode: voice.dictionaryLanguage), throwsFormatException);
      expect(dictionary.existsSync(), isTrue);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('un TTS incompleto conserva la voz anterior y limpia staging', () {
    final root = Directory.systemTemp.createTempSync('tts-model-missing-');
    try {
      final target = Directory('${root.path}/$_dirName')..createSync();
      final sentinel = File('${target.path}/anterior')..writeAsStringSync('ok');
      final incomplete = _completeArchive(includePhondata: false);
      final input = _writeArchive(root, incomplete);

      expect(
        () => extractTtsModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          onnxFile: _onnxFile,
          languageCode: 'es',
        ),
        throwsFormatException,
      );

      expect(sentinel.readAsStringSync(), 'ok');
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('rechaza rutas que intentan salir del modelo TTS', () {
    final root = Directory.systemTemp.createTempSync('tts-model-path-');
    final escapeName = 'escape-${root.path.hashCode}.txt';
    final escaped = File('${root.parent.path}/$escapeName');
    try {
      final malicious = _completeArchive()
        ..add(ArchiveFile.string('../$escapeName', 'no'));
      final input = _writeArchive(root, malicious);

      expect(
        () => extractTtsModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          onnxFile: _onnxFile,
          languageCode: 'es',
        ),
        throwsFormatException,
      );

      expect(escaped.existsSync(), isFalse);
      expect(Directory('${root.path}/$_dirName').existsSync(), isFalse);
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
    } finally {
      if (escaped.existsSync()) escaped.deleteSync();
      root.deleteSync(recursive: true);
    }
  });

  test('rechaza ONNX o datos eSpeak vacíos', () {
    final root = Directory.systemTemp.createTempSync('tts-model-empty-');
    try {
      final emptyCore = _completeArchive(emptyDictionary: true);
      final input = _writeArchive(root, emptyCore);

      expect(
        () => extractTtsModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          onnxFile: _onnxFile,
          languageCode: 'es',
        ),
        throwsFormatException,
      );
      expect(Directory('${root.path}/$_dirName').existsSync(), isFalse);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('rechaza archivos requeridos duplicados y conserva la voz anterior', () {
    final root = Directory.systemTemp.createTempSync('tts-model-duplicate-');
    try {
      final target = Directory('${root.path}/$_dirName')..createSync();
      final sentinel = File('${target.path}/anterior')..writeAsStringSync('ok');
      final originalTar = TarEncoder().encodeBytes(_completeArchive());
      final duplicateEntry = Archive()
        ..add(
          ArchiveFile.string(
            '$_dirName/tokens.txt',
            'tokens duplicados que nunca deben reemplazar los originales',
          ),
        );
      final duplicateTar = TarEncoder().encodeBytes(duplicateEntry);
      final combinedTar = <int>[
        ...originalTar.sublist(0, originalTar.length - 1024),
        ...duplicateTar.sublist(0, duplicateTar.length - 1024),
        ...List<int>.filled(1024, 0),
      ];
      final input = _writeTar(root, combinedTar);

      expect(
        () => extractTtsModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          onnxFile: _onnxFile,
          languageCode: 'es',
        ),
        throwsFormatException,
      );

      expect(sentinel.readAsStringSync(), 'ok');
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('rechaza un tar cortado aunque el BZip2 sea válido', () {
    final root = Directory.systemTemp.createTempSync('tts-model-truncated-');
    try {
      final tar = TarEncoder().encodeBytes(_completeArchive());
      expect(tar.sublist(tar.length - 1024), everyElement(0));
      final input = _writeTar(root, tar.sublist(0, tar.length - 512));

      expect(
        () => extractTtsModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          onnxFile: _onnxFile,
          languageCode: 'es',
        ),
        throwsFormatException,
      );
      expect(Directory('${root.path}/$_dirName').existsSync(), isFalse);
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('rechaza un stream BZip2 corrupto y limpia staging', () {
    final root = Directory.systemTemp.createTempSync('tts-model-corrupt-');
    try {
      final input = _writeArchive(root, _completeArchive());
      final bytes = input.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0xff;
      input.writeAsBytesSync(bytes);

      expect(
        () => extractTtsModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          onnxFile: _onnxFile,
          languageCode: 'es',
        ),
        throwsFormatException,
      );
      expect(Directory('${root.path}/$_dirName').existsSync(), isFalse);
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('delete limpia modelo, staging, backup y descarga parcial', () async {
    final support = Directory.systemTemp.createTempSync('tts-model-delete-');
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return support.path;
      }
      return null;
    });
    try {
      final voice = kNeuralVoices.first;
      final base = Directory('${support.path}/tts_models')..createSync();
      final target = Directory('${base.path}/${voice.dirName}')..createSync();
      final stage = Directory('${target.path}.extracting')..createSync();
      final previous = Directory('${target.path}.previous')..createSync();
      final partial = File('${target.path}.tar.bz2.part')
        ..writeAsStringSync('partial');

      await TtsModelManager().delete(voice);

      expect(target.existsSync(), isFalse);
      expect(stage.existsSync(), isFalse);
      expect(previous.existsSync(), isFalse);
      expect(partial.existsSync(), isFalse);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    }
  });
}
