// SPDX-License-Identifier: GPL-3.0-only
// H6: the STT models and the silero VAD are verified like the TTS models:
// published size and SHA-256 pinned in the app, checked while streaming, and
// a mismatch never reaches the extractor or the model folder.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('stt-verify-'));
  tearDown(() => root.deleteSync(recursive: true));

  final body = utf8.encode('silero-onnx-bytes');
  final good = sha256.convert(body).toString();

  http.Client serving(List<int> bytes, {int status = 200}) =>
      MockClient((_) async => http.Response.bytes(bytes, status));

  test('every model and the VAD pin a size and a SHA-256', () {
    final hex = RegExp(r'^[a-f0-9]{64}$');
    for (final m in kSherpaSttModels) {
      expect(m.archiveSha256, matches(hex), reason: m.id);
      expect(m.archiveBytes, greaterThan(1000000), reason: m.id);
    }
    expect(kSileroVad.sha256, matches(hex));
    expect(kSileroVad.bytes, greaterThan(100000));
  });

  test('a matching download is kept', () async {
    final out = File('${root.path}/silero_vad.onnx');
    await downloadSherpaVerified(
      serving(body),
      url: 'https://example.invalid/silero_vad.onnx',
      target: out,
      bytes: body.length,
      sha256Hex: good,
    );
    expect(out.readAsBytesSync(), body);
  });

  test('a different file of the same size is rejected and removed', () async {
    final out = File('${root.path}/silero_vad.onnx');
    final evil = utf8.encode('evil!-onnx-bytes!');
    expect(evil.length, body.length);
    await expectLater(
      downloadSherpaVerified(
        serving(evil),
        url: 'https://example.invalid/silero_vad.onnx',
        target: out,
        bytes: body.length,
        sha256Hex: good,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(out.existsSync(), isFalse);
    expect(File('${out.path}.part').existsSync(), isFalse);
  });

  test('a truncated or oversized download is rejected', () async {
    final out = File('${root.path}/model.tar.bz2');
    for (final bytes in [
      body.sublist(0, 5),
      [...body, ...body],
    ]) {
      await expectLater(
        downloadSherpaVerified(
          serving(bytes),
          url: 'https://example.invalid/model.tar.bz2',
          target: out,
          bytes: body.length,
          sha256Hex: good,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(out.existsSync(), isFalse);
    }
  });

  test('an HTTP error does not leave a file behind', () async {
    final out = File('${root.path}/model.tar.bz2');
    await expectLater(
      downloadSherpaVerified(
        serving(const [], status: 404),
        url: 'https://example.invalid/model.tar.bz2',
        target: out,
        bytes: body.length,
        sha256Hex: good,
      ),
      throwsException,
    );
    expect(out.existsSync(), isFalse);
  });
}
