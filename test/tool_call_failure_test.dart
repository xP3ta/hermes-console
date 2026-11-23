import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/tool_call_failure.dart';

bool failed(Object? result, {String? tool, bool isError = false}) =>
    toolCallFailed(toolName: tool, result: result, isError: isError);

void main() {
  group('a terminal call', () {
    test('a non-zero exit code is a failure, even with a null error', () {
      expect(
        failed(tool: 'terminal', {
          'output': "ls: cannot access '/x': No such file or directory",
          'exit_code': 2,
          'error': null,
        }),
        isTrue,
      );
      expect(
        failed(tool: 'terminal', '{"output":"","exit_code":1,"error":null}'),
        isTrue,
      );
    });

    test('exit code zero, or none, is not', () {
      expect(
        failed(tool: 'terminal', {
          'output': 'total 0',
          'exit_code': 0,
          'error': null,
        }),
        isFalse,
      );
      expect(failed(tool: 'terminal', {'output': 'started'}), isFalse);
    });

    test('an exit code only counts for the terminal', () {
      expect(failed(tool: 'process', {'exit_code': 1}), isFalse);
    });
  });

  group('the result body, as Hermes Desktop reads it', () {
    test('an error at the top level is a failure', () {
      expect(
        failed(tool: 'read_file', {'error': 'File not found: /tmp/x.txt'}),
        isTrue,
      );
      expect(
        failed(tool: 'read_file', '{"error": "File not found: /tmp/x.txt"}'),
        isTrue,
      );
    });

    test('success false and ok false are failures without a message', () {
      expect(failed({'success': false}), isTrue);
      expect(failed({'ok': false}), isTrue);
    });

    test('explicit success beats a stale error', () {
      expect(failed({'success': true, 'error': 'old'}), isFalse);
      expect(failed({'ok': true, 'error': 'old'}, isError: true), isFalse);
    });

    test('the envelope flag alone is a failure', () {
      expect(failed({'output': 'x'}, isError: true), isTrue);
      expect(failed('plain text', isError: true), isTrue);
    });

    test('returned data needs a failure envelope to count as an error', () {
      const payload = {
        'output': {
          'error': {'message': 'Connection refused'},
        },
      };
      for (final result in [
        payload,
        {'meta': payload},
        {'success': true, 'result': payload},
      ]) {
        expect(failed(result), isFalse);
      }
      expect(failed({'success': false, 'result': payload}), isTrue);
    });

    test('a successful payload with a message is not an error', () {
      expect(
        failed({
          'success': true,
          'message': 'Completed successfully',
          'data': {'count': 3},
        }),
        isFalse,
      );
    });

    test('placeholder error fields are not errors', () {
      for (final value in ['none', '', 'null', 'ok', '0', 'false', 'N/A']) {
        expect(failed({'error': value}), isFalse, reason: value);
      }
      expect(failed({'error': null}), isFalse);
      expect(failed({'error': 0}), isFalse);
      expect(failed({'error': false}), isFalse);
    });

    test('a failed status with its message is a failure', () {
      expect(failed({'status': 'error', 'message': 'boom'}), isTrue);
      expect(failed({'status': 'Failed', 'reason': 'boom'}), isTrue);
      expect(failed({'status': 'dispatched', 'count': 2}), isFalse);
    });

    test('a settled batch whose child failed is not a failed call', () {
      expect(
        failed({
          'results': [
            {'status': 'failed', 'error': 'boom'},
          ],
        }),
        isFalse,
      );
    });

    test('a whole-call rejection is', () {
      expect(
        failed(tool: 'delegate_task', {
          'error': 'Task 0 goal contains an unexpanded template marker.',
        }),
        isTrue,
      );
    });

    test('plain text and empty results are not failures', () {
      expect(failed('all good'), isFalse);
      expect(failed('Error: this is only text'), isFalse);
      expect(failed(null), isFalse);
      expect(failed(''), isFalse);
      expect(failed(const <Object?>[]), isFalse);
    });
  });

  group('a refused skill write', () {
    test('is the agent retrying, not a failure the user must see', () {
      expect(
        failed(tool: 'skill_manage', {
          'success': false,
          'error': 'old_string not found',
        }),
        isFalse,
      );
    });

    test('unless its rollback failed', () {
      expect(
        failed(tool: 'skill_manage', {
          'success': false,
          'error': 'ROLLBACK FAILED: partial changes left',
        }),
        isTrue,
      );
    });
  });
}
