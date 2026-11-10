// Ratchet of DESCARGAS-DIRECTAS (point 6): every «Guardar» of the app goes
// through the one helper (lib/core/services/save_to_device.dart). No
// `FilePicker.platform.saveFile` in lib/ (it takes the whole file as bytes
// through the plugin's channel and fails silently on large ones), no
// `readAsBytes` in the save of the sites that had it, and no silent catch
// in the save path.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _helper = 'lib/core/services/save_to_device.dart';

/// `FilePicker.platform.saveFile`, however it is spaced.
final _pluginSave = RegExp(r'FilePicker\s*\.\s*platform\s*\.\s*saveFile');

/// The body of the function of [source] declared by [signature] (which
/// ends before its body): from its `{` or `=>` to the matching end.
String _body(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: signature);
  expect(
    source.indexOf(signature, start + 1),
    -1,
    reason: 'one declaration: $signature',
  );
  final open = source.indexOf(RegExp(r'\{|=>'), start + signature.length);
  if (source.startsWith('=>', open)) {
    return source.substring(open, source.indexOf(';\n', open) + 1);
  }
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  fail('unbalanced: $signature');
}

void main() {
  test('no FilePicker.platform.saveFile in lib/ outside the helper', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path == _helper) continue;
      final source = entity.readAsStringSync();
      if (_pluginSave.hasMatch(source)) offenders.add(entity.path);
    }
    expect(offenders, isEmpty);
  });

  test('the old save sites save from the file, never its bytes', () {
    for (final (path, signature, call) in const [
      (
        'lib/core/widgets/attachment_card.dart',
        'Future<void> _save()',
        'saveFileToDevice(',
      ),
      (
        'lib/core/widgets/media_viewer/media_viewer.dart',
        'Future<void> _save(File file)',
        'saveFileToDevice(',
      ),
      (
        'lib/core/widgets/attachment_preview.dart',
        'Future<void> _saveCopy(',
        'saveFileToDevice(',
      ),
      (
        'lib/core/bots/ui/room/room_gateway.dart',
        '@override\n  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, '
            'File file)',
        'exporter.saveFile(',
      ),
      (
        'lib/core/services/artifact_export_service.dart',
        '@override\n  Future<ArtifactSaveResult> saveFile({',
        'device.saveFile(',
      ),
      (
        'lib/core/screens/tasks_screen.dart',
        'Future<void> _downloadTaskAttachment(',
        'saveBytesToDevice(',
      ),
    ]) {
      final body = _body(File(path).readAsStringSync(), signature);
      expect(body, isNot(contains('readAsBytes')), reason: path);
      expect(body, isNot(contains('FilePicker')), reason: path);
      expect(body, contains(call), reason: path);
    }
    // Bytes already in memory (artifacts, tasks) go straight to the
    // document, block by block: no plugin saveFile there either.
    final export = File(
      'lib/core/services/artifact_export_service.dart',
    ).readAsStringSync();
    expect(
      _body(export, '@override\n  Future<ArtifactSaveResult> saveBytes({'),
      contains('device.saveBytes('),
    );
  });

  test('the save path has no silent catch', () {
    for (final path in const [
      _helper,
      'lib/core/widgets/save_to_device_feedback.dart',
      'lib/core/services/sftp_transfer_service.dart',
      'lib/core/screens/sftp_browser_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        RegExp(r'catch\s*\(\s*_\s*\)\s*\{\s*\}').hasMatch(source),
        isFalse,
        reason: path,
      );
      expect(
        RegExp(r'catch\s*\(\s*_\s*\)').hasMatch(source),
        isFalse,
        reason: '$path: every catch names what it catches',
      );
    }
  });

  test('each step of a save leaves a [save] line, without private data', () {
    final helper = File(_helper).readAsStringSync();
    for (final line in const [
      "saveLog('invoke method=",
      "saveLog('result method=",
      "saveLog('error method=",
      'type=MissingPluginException',
      'type=TimeoutException',
      'type=PlatformException',
      "saveLog('stage=",
    ]) {
      expect(helper, contains(line), reason: line);
    }
    // What is logged: steps, codes and counts, never a name, path or Uri.
    for (final match in RegExp(r'saveLog\(([^;]*)\);').allMatches(helper)) {
      final logged = match.group(1)!;
      for (final private in const [r'$name', r'$uri', 'file.path']) {
        expect(logged, isNot(contains(private)), reason: logged);
      }
    }
    final feedback = File(
      'lib/core/widgets/save_to_device_feedback.dart',
    ).readAsStringSync();
    expect(feedback, contains("saveLog('tap source=\$source')"));
    final browser = File(
      'lib/core/screens/sftp_browser_screen.dart',
    ).readAsStringSync();
    expect(browser, contains("saveLog('tap source=sftp action=download')"));
  });
}
