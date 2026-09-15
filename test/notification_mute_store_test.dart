import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_mute_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<NotificationMuteStore> newStore() async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    return NotificationMuteStore(prefs);
  }

  test('un job/tarea nuevos no están silenciados por defecto', () async {
    final store = await newStore();
    expect(store.isJobMuted('job-1'), isFalse);
    expect(store.isTaskMuted('task-1'), isFalse);
  });

  test('silenciar un job lo marca sin afectar a otros ni a Kanban', () async {
    final store = await newStore();
    await store.setJobMuted('job-1', true);

    expect(store.isJobMuted('job-1'), isTrue);
    expect(store.isJobMuted('job-2'), isFalse);
    expect(store.isTaskMuted('job-1'), isFalse);
    expect(store.mutedCronJobIds, {'job-1'});
    expect(store.mutedKanbanTaskIds, isEmpty);
  });

  test('silenciar una tarea de Kanban la marca sin afectar a Cron', () async {
    final store = await newStore();
    await store.setTaskMuted('task-1', true);

    expect(store.isTaskMuted('task-1'), isTrue);
    expect(store.isJobMuted('task-1'), isFalse);
    expect(store.mutedKanbanTaskIds, {'task-1'});
    expect(store.mutedCronJobIds, isEmpty);
  });

  test('des-silenciar quita el id de la colección', () async {
    final store = await newStore();
    await store.setJobMuted('job-1', true);
    await store.setJobMuted('job-1', false);
    expect(store.isJobMuted('job-1'), isFalse);
    expect(store.mutedCronJobIds, isEmpty);
  });

  test('persiste entre instancias que comparten SharedPreferences', () async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await NotificationMuteStore(prefs).setJobMuted('job-durable', true);

    final reopened = NotificationMuteStore(prefs);
    expect(reopened.isJobMuted('job-durable'), isTrue);
  });

  test('ids vacíos o solo espacios se ignoran', () async {
    final store = await newStore();
    await store.setJobMuted('   ', true);
    await store.setTaskMuted('', true);
    expect(store.mutedCronJobIds, isEmpty);
    expect(store.mutedKanbanTaskIds, isEmpty);
  });

  test('recorta espacios al comprobar membership', () async {
    final store = await newStore();
    await store.setJobMuted('job-1', true);
    expect(store.isJobMuted('  job-1  '), isTrue);
  });
}
