import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/subagent_finished_record.dart';
import 'package:hermes_android/core/services/subagent_tail_log.dart';

// The end of a real live transcript (`tools/delegation_live_log.py`), the one
// A review screenshot rendered as a wall of text: the window starts in the
// middle of a result line, then three `grep`/`sed` calls with their JSON
// results, one of them cut by the server (` …(+N chars)`), with `\r\n` line
// ends escaped inside the output. Home paths are anonymised.
const String _cutHead =
    r'''"exit=1\n/home/user/relay/node_modules/miniflare/dist/src/index.js:137505\n const error123 = new MiniflareCoreError(\n ^\n\nMiniflareCoreError [ERR_VALIDATION]: Unexpected options passed to `new Miniflare()` constructor:\n✖ Unrecognized keys: \"name\", \"modules\", \"compatibilityDate\", \"durableObjects\", \"ratelimits\", \"kvNamespaces\", \"bin …(+712 chars)''';

const List<String> _screenshot = [
  r'''16:56:09 tool     | -> terminal(grep -no "Persist[A-Za-z]*\??:\|defaultPersistRoot\|persist[A-Za-z]*?:" index.d.ts + 1 comando)''',
  r'''16:56:09 result   | terminal ok 0.1s: {"output": "3075:persist?:\n10076:export declare type V4SharedOptions = {", "exit_code": 0, "error": null, "cwd": "/home/user/relay/node_modules/miniflare/dist/src"}''',
  r'''16:56:11 tool     | -> terminal(sed -n 10060,10140p index.d.ts + 1 comando)''',
  r'''16:56:11 result   | terminal ok 0.2s: {"output": "};\r\n} | {\r\n external: {\r\n address: string;\r\n http?: unknown;\r\n https?: unknown;\r\n };\r\n} | {\r\n disk: {\r\n path: string;\r\n writable?: boolean;\r\n };\r\n} | {\r\n node: V4NodeHandler;\r\n} | V4FetchHandler;\r\n\r\nexport declare type V4SharedOptions = {\r\n [key: string]: unknown;\r\n rootPath?: string;\r\n host?: string;\r\n port?: number;\r\n https?: boolean;\r\n htt …(+2104 chars)''',
  r'''16:56:15 tool     | -> terminal(grep -n "Persist\|resourcePersistencePath\|telemetry" index.d.ts + 1 comando)''',
  r'''16:56:15 result   | terminal ok 0.2s: {"output": "750:export declare function getFlagshipExplorerService(sharedOptions: Pick<ParsedInstanceOptions, \"resourcePersistencePath\" | \"unsafeEnableSharedStorage\">): ServiceDesignator_2;\r\n801:export declare function getPersistPath(pluginName: string, tmpPath: string, resourcePersistencePath: string | undefined): string;\r\n805:export declare function getR2PublicService(allWorkerOpts: Pars …(+2855 chars)''',
];

const String _failedRun =
    r'''16:56:04 tool     | -> terminal(unshare -rn sh -c 'ip link set lo up && node --no-warnings harness.mjs' + 1 comando)
16:56:05 result   | terminal ok 0.9s: {"output": "exit=1\n/home/user/relay/node_modules/miniflare/dist/src/index.js:137505\n const error123 = new MiniflareCoreError(\n ^\n\nMiniflareCoreError [ERR_VALIDATION]: Unexpected options passed to `new Miniflare()` constructor:\n✖ Unrecognized keys: \"name\", \"modules\", \"compatibilityDate\", \"durableObjects\", \"ratelimits\", \"kvNamespaces\", \"bin …(+712 chars)''';

void _expectReadable(SubagentTailEntry row) {
  for (final text in [row.command ?? '', row.output, row.text]) {
    expect(text, isNot(contains('{"output"')));
    expect(text, isNot(contains('"exit_code"')));
    expect(text, isNot(contains('"cwd"')));
    expect(text, isNot(contains(r'\n')));
    expect(text, isNot(contains(r'\r')));
    expect(text, isNot(contains(r'\"')));
    expect(text, isNot(contains('\r')));
    expect(text, isNot(contains('chars)')));
  }
}

void main() {
  group('parseSubagentTailLog', () {
    test('the screenshot tail reads as three tool calls with their output', () {
      final text = [_cutHead, ..._screenshot].join('\n');
      expect(isSubagentTailLog(text), isTrue);
      final rows = parseSubagentTailLog(text, truncated: true);
      expect(rows, hasLength(3));
      for (final row in rows) {
        expect(row.kind, SubagentTailKind.tool);
        expect(row.tool, 'terminal');
        expect(row.finished, isTrue);
        expect(row.failed, isFalse);
        _expectReadable(row);
      }
      expect(rows.map((r) => r.time), ['16:56:09', '16:56:11', '16:56:15']);
      expect(
        rows[0].command,
        r'grep -no "Persist[A-Za-z]*\??:\|defaultPersistRoot\|persist[A-Za-z]*?:" index.d.ts + 1 comando',
      );
      expect(rows[0].output, '3075:persist?:\n10076:export declare type V4SharedOptions = {');
      expect(rows[0].exitCode, 0);
      expect(rows[0].durationSeconds, closeTo(.1, 1e-9));
      expect(rows[0].outputCut, isFalse);
      expect(rows[1].command, 'sed -n 10060,10140p index.d.ts + 1 comando');
      expect(rows[1].output.split('\n').take(3), ['};', '} | {', ' external: {']);
      expect(rows[1].outputCut, isTrue);
      expect(rows[1].exitCode, isNull);
      expect(
        rows[2].output.split('\n').first,
        contains('Pick<ParsedInstanceOptions, "resourcePersistencePath"'),
      );
      expect(rows[2].outputCut, isTrue);
    });

    test('the same tail joined on one line still splits into its events', () {
      final rows = parseSubagentTailLog(_screenshot.join(' '));
      expect(rows, hasLength(3));
      expect(rows.every((r) => r.finished), isTrue);
      rows.forEach(_expectReadable);
    });

    test('Windows line ends between events read the same', () {
      final rows = parseSubagentTailLog(_screenshot.join('\r\n'));
      expect(rows, hasLength(3));
      expect(rows[0].output, '3075:persist?:\n10076:export declare type V4SharedOptions = {');
      rows.forEach(_expectReadable);
    });

    test('a command that reports exit=1 is a failure with its exit code', () {
      final rows = parseSubagentTailLog(_failedRun);
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.finished, isTrue);
      expect(row.failed, isTrue);
      expect(row.exitCode, 1);
      expect(row.durationSeconds, closeTo(.9, 1e-9));
      expect(row.output, startsWith('/home/user/relay/node_modules/'));
      expect(row.output, contains('\n const error123 = new MiniflareCoreError(\n'));
      expect(row.output, contains('✖ Unrecognized keys: "name", "modules"'));
      expect(row.output, isNot(contains('exit=1')));
      expect(row.outputCut, isTrue);
      _expectReadable(row);
    });

    test('a window cut mid-line drops that first line only when truncated', () {
      final text = [_cutHead, ..._screenshot.take(2)].join('\n');
      expect(parseSubagentTailLog(text, truncated: true), hasLength(1));
      final untruncated = parseSubagentTailLog(text);
      expect(untruncated, hasLength(2));
      expect(untruncated.first.kind, SubagentTailKind.text);
      expect(untruncated.first.text.length, lessThan(kSubagentTailTextMaxChars + 2));
    });

    test('parallel calls get their own results, oldest first', () {
      const text = r'''10:00:00 tool     | -> read_file(lib/a.dart)
10:00:00 tool     | -> terminal(ls)
10:00:01 tool     | -> read_file(lib/b.dart)
10:00:02 result   | read_file ok 0.0s: {"content": "1|a", "total_lines": 1}
10:00:02 result   | terminal ok 0.1s: {"output": "x\ny", "exit_code": 0, "error": null}
10:00:03 result   | read_file ok 0.0s: {"content": "1|b", "total_lines": 1}''';
      final rows = parseSubagentTailLog(text);
      expect(rows.map((r) => r.command), ['lib/a.dart', 'ls', 'lib/b.dart']);
      expect(rows.map((r) => r.output), ['1|a', 'x\ny', '1|b']);
      expect(rows.every((r) => r.finished && !r.failed), isTrue);
    });

    test('a result whose call left the window is a row of its own', () {
      const text = r'''10:00:02 result   | patch ok 0.1s: {"success": true, "diff": "--- a/x\n+++ b/x"}''';
      final rows = parseSubagentTailLog(text);
      expect(rows.single.tool, 'patch');
      expect(rows.single.command, isNull);
      expect(rows.single.output, '--- a/x\n+++ b/x');
    });

    test('an ERROR with its exit code and error field fails in words', () {
      const text = r'''10:00:00 tool     | -> terminal(curl -s http://127.0.0.1:9/health)
10:00:01 result   | terminal ERROR 1.3s: {"output": "", "exit_code": 7, "error": "Failed to connect to host", "cwd": "/srv"}''';
      final row = parseSubagentTailLog(text).single;
      expect(row.failed, isTrue);
      expect(row.exitCode, 7);
      expect(row.output, 'Failed to connect to host');
      _expectReadable(row);
    });

    test('a result that is not JSON reads as its own words', () {
      const text = '''10:00:00 tool     | -> terminal(sleep 900)
10:07:00 result   | terminal ok 420.0s: Error executing tool 'terminal': timed out after 420.0s''';
      final row = parseSubagentTailLog(text).single;
      expect(row.failed, isTrue);
      expect(row.output, "Error executing tool 'terminal': timed out after 420.0s");
      expect(row.durationSeconds, 420);
    });

    test('an object with nothing readable at its top shows no braces', () {
      const text = r'''10:00:00 tool     | -> web_search(noticias)
10:00:01 result   | web_search ok 1.4s: { "success": true, "data": { "web": [ { "url": "https://example.com/a", "title": "A …(+900 chars)
10:00:02 tool     | -> vision_analyze(describe)
10:00:03 result   | vision_analyze ok 0.1s: {'_multimodal': True, 'content': [{'type': 'text', 'text': 'Image loaded …(+90 chars)''';
      final rows = parseSubagentTailLog(text);
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.output, isEmpty);
        expect(row.failed, isFalse);
      }
    });

    test('unicode escapes decode, and one cut short never throws', () {
      const text = r'''10:00:00 tool     | -> terminal(cat notas.md)
10:00:01 result   | terminal ok 0.1s: {"output": "Revisión 😀 lista\tok\náé \u00 …(+20 chars)''';
      final row = parseSubagentTailLog(text).single;
      expect(row.output, startsWith('Revisión 😀 lista  ok\náé'));
      expect(row.outputCut, isTrue);
    });

    test('header, kickoff and a thought repeated as the reply are left out', () {
      const text = '''=== Hermes subagent live transcript ===
delegation: deleg_f7bfc239   task: 0
goal: Produce y ejecuta un ensayo
started: 2026-11-08 16:50:00
(append-only; streams while the subagent runs — tail -f me)
========================================
16:50:00 user     | kickoff: Produce y ejecuta un ensayo
16:50:00 start    | Produce y ejecuta un ensayo
16:56:04 think    | Network namespace without external connectivity works. Running the rehearsal ins
16:56:04 assistant| Network namespace without external connectivity works. Running the rehearsal inside it.
16:57:00 final    | status=completed duration=286.91s summary: Hecho.
16:57:00 final    | end status=failed exit_reason=error error: HTTP 400: Your credit balance is too low''';
      final rows = parseSubagentTailLog(text);
      expect(rows.map((r) => r.kind), [
        SubagentTailKind.text,
        SubagentTailKind.error,
      ]);
      expect(
        rows.first.text,
        'Network namespace without external connectivity works. Running the rehearsal inside it.',
      );
      expect(rows.last.text, 'HTTP 400: Your credit balance is too low');
      for (final row in rows) {
        expect(row.text, isNot(contains('deleg_')));
      }
    });

    test('a call still running has no result yet', () {
      const text = '16:49:00 tool     | -> terminal(for i in 1 2 3 4 5 6 + 3 comandos)';
      final row = parseSubagentTailLog(text).single;
      expect(row.finished, isFalse);
      expect(row.command, 'for i in 1 2 3 4 5 6 + 3 comandos');
    });

    test('a line that is no event reads as one short paragraph', () {
      final blob = '16:50:00 tool     | -> terminal(ls)\n${'palabra   suelta\t' * 400}';
      final rows = parseSubagentTailLog(blob);
      expect(rows.last.kind, SubagentTailKind.text);
      expect(rows.last.text, isNot(contains('  ')));
      expect(rows.last.text.length, lessThanOrEqualTo(kSubagentTailTextMaxChars + 1));
      expect(rows.last.text, endsWith('…'));
    });

    test('prose the watch mirrored is not a log', () {
      expect(isSubagentTailLog('Leyendo ficheros\n\n- uno\n- dos'), isFalse);
      expect(isSubagentTailLog('cola sondeada'), isFalse);
    });

    test('commands and outputs are masked; server log paths withheld', () {
      const text = r'''10:00:00 tool     | -> terminal(curl --token abcdef123456 https://user:pw@example.com/x?api_key=zzz)
10:00:01 result   | terminal ok 0.1s: {"output": "API_KEY=sk-abcdefghijklmnopqrstuv\nmail ana@example.com\nlog /home/u/.hermes/cache/delegation/live/deleg_1/task-0.log\nfine line", "exit_code": 0}''';
      final row = parseSubagentTailLog(text).single;
      expect(row.command, isNot(contains('abcdef123456')));
      expect(row.command, isNot(contains('pw@')));
      expect(row.command, isNot(contains('zzz')));
      expect(row.output, isNot(contains('sk-abcdefghijklmnopqrstuv')));
      expect(row.output, isNot(contains('ana@example.com')));
      expect(row.output, isNot(contains('cache/delegation/live')));
      expect(row.output, isNot(contains('task-0.log')));
      expect(row.output, contains('fine line'));
      expect(row.output.split('\n'), hasLength(4));
    });
  });

  group('subagentLiveOutput', () {
    test('keeps lines and indentation, drops control characters', () {
      expect(
        subagentLiveOutput('a\n  b\r\n\tc\u0007d\n\n'),
        'a\n  b\n  c d',
      );
    });

    test('caps lines and characters', () {
      final many = List.generate(200, (i) => 'line $i').join('\n');
      expect(
        subagentLiveOutput(many).split('\n'),
        hasLength(kSubagentLiveOutputMaxLines),
      );
      final wide = List.generate(40, (i) => 'x' * 1000).join('\n');
      expect(
        subagentLiveOutput(wide).length,
        lessThan(kSubagentLiveOutputMaxChars + 1100),
      );
    });

    test('hides every line of a PEM block', () {
      const pem =
          'before\n-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\nAbCdEf\n-----END PRIVATE KEY-----\nafter';
      final out = subagentLiveOutput(pem);
      expect(out, isNot(contains('MIIEvQ')));
      expect(out, isNot(contains('AbCdEf')));
      expect(out, startsWith('before\n'));
      expect(out, endsWith('\nafter'));
    });
  });
}
