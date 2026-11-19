import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Issue #227: a model download reached 100 % and then failed with "Illegal
// argument in isolate message: object is unsendable". The extraction closure
// shared its context with the progress callback of the screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a downloaded model is extracted even when the progress callback '
      'holds something an isolate cannot receive', () async {
    final support = Directory.systemTemp.createTempSync('sherpa-dl-');
    addTearDown(() => support.deleteSync(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathProvider, (_) async => support.path);
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));

    const dirName = 'sherpa-test-model';
    final archive = Archive();
    for (final name in const ['tokens.txt', 'encoder.onnx', 'decoder.onnx']) {
      final bytes = utf8.encode('content of $name');
      archive.addFile(ArchiveFile('$dirName/$name', bytes.length, bytes));
    }
    final tarBz2 = BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(archive));
    final model = SherpaSttModel(
      kind: SherpaModelKind.whisperBase,
      displayName: 'test',
      quality: 'test',
      sizeMb: 1,
      ramMb: 1,
      url: 'https://example.invalid/model.tar.bz2',
      dirName: dirName,
      isTransducer: false,
      tokens: 'tokens.txt',
      encoder: 'encoder.onnx',
      decoder: 'decoder.onnx',
      archiveBytes: tarBz2.length,
      archiveSha256: sha256.convert(tarBz2).toString(),
    );
    final manager = SherpaSttModelManager();
    // The shared VAD is already there: only the model is fetched.
    File(await manager.sileroPath()).createSync(recursive: true);

    // What a settings screen passes: a callback closing over its State. A
    // ReceivePort stands for it here (neither can be sent to an isolate).
    final port = ReceivePort();
    addTearDown(port.close);
    final phases = <SherpaPrepPhase>[];
    await http.runWithClient(
      () => manager.download(
        model,
        onProgress: (progress) {
          port.hashCode;
          phases.add(progress.phase);
        },
      ),
      () => MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          Stream.value(tarBz2),
          200,
          contentLength: tarBz2.length,
        ),
      ),
    );

    expect(await manager.isReady(model), isTrue);
    expect(
      File(await manager.tokensPath(model)).readAsStringSync(),
      'content of tokens.txt',
    );
    expect(phases.last, SherpaPrepPhase.done);
  });
}
