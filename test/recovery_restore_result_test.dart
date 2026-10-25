import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';

void main() {
  group('RecoveryRestoreResult.fromJson', () {
    test('older servers without the safe-restore fields report no omissions', () {
      final result = RecoveryRestoreResult.fromJson(const {
        'success': true,
        'history_removed': 3,
      });
      expect(result.success, isTrue);
      expect(result.historyRemoved, 3);
      expect(result.skippedUserEdits, 0);
      expect(result.skippedOversize, 0);
      expect(result.failedDeletes, 0);
      expect(result.hasOmissions, isFalse);
    });

    test('counts the files Hermes kept, skipped or could not delete', () {
      final result = RecoveryRestoreResult.fromJson(const {
        'success': true,
        'skipped_user_edits': ['a', 'b'],
        'skipped_oversize': ['c'],
        'failed_deletes': ['d', 'e', 'f'],
      });
      expect(result.skippedUserEdits, 2);
      expect(result.skippedOversize, 1);
      expect(result.failedDeletes, 3);
      expect(result.hasOmissions, isTrue);
    });

    test('malformed values are treated as empty and never throw', () {
      final result = RecoveryRestoreResult.fromJson(const {
        'success': true,
        'skipped_user_edits': 'a.txt',
        'skipped_oversize': {'a': 1},
        'failed_deletes': null,
      });
      expect(result.hasOmissions, isFalse);
    });

    test('non-string and blank entries are not counted as files', () {
      final result = RecoveryRestoreResult.fromJson(const {
        'success': true,
        'skipped_user_edits': [1, null, '', '  ', 'real.txt'],
      });
      expect(result.skippedUserEdits, 1);
    });

    test('the count is bounded', () {
      final result = RecoveryRestoreResult.fromJson({
        'success': true,
        'failed_deletes': List<String>.generate(200000, (i) => 'f$i'),
      });
      expect(result.failedDeletes, 100000);
    });
  });
}
