import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<NotificationService> service(Map<String, Object> saved) async {
    SharedPreferences.setMockInitialValues(saved);
    return NotificationService(await SharedPreferences.getInstance());
  }

  group('fresh install', () {
    test(
      'approvals, questions and replies are on without the listener',
      () async {
        final n = await service({});
        expect(n.enabled, isTrue);
        expect(n.notifyApprovals, isTrue);
        expect(n.notifyQuestions, isTrue);
        expect(n.notifyReplies, isTrue);
      },
    );

    test('runs and Automatic cron are on; Kanban and goals are off', () async {
      final n = await service({});
      expect(n.notifyRuns, isTrue);
      expect(n.notifyCronResults, isTrue);
      expect(n.notifyKanbanResults, isFalse);
      expect(n.notifyLocalAgentResults, isFalse);
      expect(n.evenInForeground, isFalse);
    });

    test('reading every default writes nothing (no migration pass)', () async {
      final n = await service({});
      final prefs = await SharedPreferences.getInstance();
      for (final read in [
        () => n.enabled,
        () => n.notifyApprovals,
        () => n.notifyQuestions,
        () => n.notifyReplies,
        () => n.notifyCronResults,
        () => n.notifyKanbanResults,
        () => n.notifyRuns,
      ]) {
        read();
      }
      expect(prefs.getKeys(), isEmpty);
    });
  });

  group('what the user already saved is respected', () {
    test('an explicit «off» stays off', () async {
      final n = await service({
        'notif_enabled': false,
        'notif_approvals': false,
        'notif_replies': false,
      });
      expect(n.enabled, isFalse);
      expect(n.notifyApprovals, isFalse);
      expect(n.notifyReplies, isFalse);
    });

    test(
      'questions follow the approvals value saved before they had a switch',
      () async {
        expect(
          (await service({'notif_approvals': false})).notifyQuestions,
          isFalse,
        );
        expect(
          (await service({'notif_approvals': true})).notifyQuestions,
          isTrue,
        );
        expect(
          (await service({
            'notif_approvals': false,
            'notif_questions': true,
          })).notifyQuestions,
          isTrue,
          reason: 'its own switch wins once it exists',
        );
      },
    );

    test(
      'turning approvals off later keeps the questions as they were',
      () async {
        final n = await service({});
        await n.setNotifyApprovals(false);
        expect(n.notifyApprovals, isFalse);
        expect(n.notifyQuestions, isTrue);
        await n.setNotifyQuestions(false);
        expect(n.notifyQuestions, isFalse);
        expect(n.notifyApprovals, isFalse);
      },
    );

    test(
      'the retired listener opt-in still seeds goals, cron and Kanban',
      () async {
        // Read-only migration: the old key is consulted, never written.
        final n = await service({'notif_background_listen': true});
        expect(n.notifyCronResults, isTrue);
        expect(n.notifyKanbanResults, isTrue);
        expect(n.notifyLocalAgentResults, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getKeys(), {'notif_background_listen'});
      },
    );

    test('an explicit cron «off» wins over the old opt-in', () async {
      final n = await service({
        'notif_background_listen': true,
        'notif_cron_results': false,
      });
      expect(n.notifyCronResults, isFalse);
      expect(n.notifyKanbanResults, isTrue);
    });
  });

  test('approvals never depended on the retired listener', () async {
    final off = await service({});
    expect(off.notifyApprovals, isTrue);
    final on = await service({'notif_background_listen': true});
    expect(on.notifyApprovals, isTrue);
  });
}
