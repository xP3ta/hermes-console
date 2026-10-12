// Console never runs anything on the phone: every terminal command is a
// `shell.exec` request to the server. This scan fails if any file under lib/
// reaches for a dart:io process API.
//
// Mutant: adding `Process.run('sh', ['-c', cmd])` to the terminal controller
// makes the first test fail.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _processCall = RegExp(r'\bProcess\s*\.\s*(run|start|runSync|killPid)\b');
final _processImport = RegExp(
  r'''import\s+['"]dart:io['"]\s+show\s+[^;]*\bProcess\b''',
);
final _processTypes = RegExp(r'\b(ProcessResult|ProcessStartMode)\b');

String _stripComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//.*'), '');

List<String> _offences(String source) {
  final code = _stripComments(source);
  return [
    for (final m in _processCall.allMatches(code)) m.group(0)!,
    for (final m in _processImport.allMatches(code)) m.group(0)!,
    for (final m in _processTypes.allMatches(code)) m.group(0)!,
  ];
}

void main() {
  test('no file under lib/ uses a dart:io process API', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files.length, greaterThan(100), reason: 'scanner lost the files');
    final offending = {
      for (final f in files)
        if (_offences(f.readAsStringSync()).isNotEmpty) f.path,
    };
    expect(offending, isEmpty);
  });

  test('the scanner catches every forbidden spelling', () {
    for (final sample in [
      "Process.run('sh', ['-c', cmd]);",
      'await Process . start(exe, args);',
      'Process.runSync(a, b);',
      'Process.killPid(1);',
      "import 'dart:io' show File, Process;",
      'ProcessResult r;',
      'ProcessStartMode.detached',
    ]) {
      expect(_offences(sample), isNotEmpty, reason: sample);
    }
    expect(_offences('// Process.run is forbidden\nfinal x = 1;'), isEmpty);
  });
}
