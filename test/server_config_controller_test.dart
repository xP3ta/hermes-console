// State of one Advanced page: the values read when it opens, one save in
// flight per field, the server's value after a failed one, and what a late
// answer may not touch.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/settings/server_config_controller.dart';

final class _Store implements ServerConfigStore {
  @override
  bool isWritable = true;

  Map<String, dynamic> config = {
    'agent': {'max_turns': 90},
    'timezone': 'UTC',
  };
  Object? readError;
  Completer<void>? holdRead;
  Completer<void>? holdSave;
  Object? saveError;
  final List<(String, Object?)> saves = [];
  int reads = 0;

  @override
  Future<Map<String, dynamic>> readConfig() async {
    reads++;
    final hold = holdRead;
    if (hold != null) await hold.future;
    final error = readError;
    if (error != null) throw error;
    return config;
  }

  @override
  Future<Map<String, dynamic>> readSchema() async => {'fields': {}};

  @override
  Future<Object?> save(String path, Object? value) async {
    saves.add((path, value));
    final hold = holdSave;
    if (hold != null) await hold.future;
    final error = saveError;
    if (error != null) throw error;
    return value;
  }
}

ServerConfigController _controller(
  _Store store, {
  bool Function()? isCurrent,
}) => ServerConfigController(store: store, isCurrent: isCurrent ?? () => true);

void main() {
  group('load', () {
    test('reads the config once and exposes values by dotted path', () async {
      final store = _Store();
      final controller = _controller(store);
      expect(controller.phase, ServerConfigPhase.idle);

      final loading = controller.load();
      expect(controller.phase, ServerConfigPhase.loading);
      await loading;

      expect(controller.phase, ServerConfigPhase.ready);
      expect(store.reads, 1);
      expect(controller.valueOf('agent.max_turns'), 90);
      expect(controller.valueOf('timezone'), 'UTC');
      expect(controller.valueOf('missing.path'), isNull);
    });

    test('a failure is the page failure, with its kind', () async {
      final store = _Store()
        ..readError = const ServerConfigException(
          ServerConfigFailureKind.permissionDenied,
        );
      final controller = _controller(store);
      await controller.load();

      expect(controller.phase, ServerConfigPhase.failed);
      expect(controller.loadFailure, ServerConfigFailureKind.permissionDenied);
    });

    test('an answer that is no longer current changes nothing', () async {
      final store = _Store()..holdRead = Completer<void>();
      var current = true;
      final controller = _controller(store, isCurrent: () => current);
      var notified = 0;
      controller.addListener(() => notified++);

      final loading = controller.load();
      final before = notified;
      current = false;
      store.holdRead!.complete();
      await loading;

      expect(notified, before);
      expect(controller.phase, ServerConfigPhase.loading);
      expect(controller.valueOf('timezone'), isNull);
    });

    test('an answer after dispose is dropped without notifying', () async {
      final store = _Store()..holdRead = Completer<void>();
      final controller = _controller(store);
      final loading = controller.load();
      controller.dispose();
      store.holdRead!.complete();

      await loading;
      expect(controller.phase, ServerConfigPhase.loading);
    });
  });

  group('save', () {
    test('marks the field saving until the store answers', () async {
      final store = _Store()..holdSave = Completer<void>();
      final controller = _controller(store);
      await controller.load();

      final saving = controller.save('agent.max_turns', 50);
      expect(controller.isSaving('agent.max_turns'), isTrue);
      expect(controller.isSaving('timezone'), isFalse);
      store.holdSave!.complete();

      expect(await saving, isTrue);
      expect(controller.isSaving('agent.max_turns'), isFalse);
      expect(controller.valueOf('agent.max_turns'), 50);
      expect(controller.errorOf('agent.max_turns'), isNull);
    });

    test('a second save of a field in flight is not started', () async {
      final store = _Store()..holdSave = Completer<void>();
      final controller = _controller(store);
      await controller.load();

      final first = controller.save('agent.max_turns', 50);
      final second = await controller.save('agent.max_turns', 60);
      store.holdSave!.complete();
      await first;

      expect(second, isFalse);
      expect(store.saves, [('agent.max_turns', 50)]);
    });

    test('a value the server did not keep shows the server value and the '
        'error', () async {
      final store = _Store()
        ..saveError = const ServerConfigException(
          ServerConfigFailureKind.notSaved,
          serverValue: 90,
        );
      final controller = _controller(store);
      await controller.load();

      expect(await controller.save('agent.max_turns', 50), isFalse);
      expect(controller.valueOf('agent.max_turns'), 90);
      expect(
        controller.errorOf('agent.max_turns'),
        ServerConfigFailureKind.notSaved,
      );
    });

    test('another failure keeps the value and records the kind', () async {
      final store = _Store()
        ..saveError = const ServerConfigException(
          ServerConfigFailureKind.remote,
        );
      final controller = _controller(store);
      await controller.load();

      expect(await controller.save('timezone', 'Europe/Madrid'), isFalse);
      expect(controller.valueOf('timezone'), 'UTC');
      expect(controller.errorOf('timezone'), ServerConfigFailureKind.remote);
    });

    test('an unconfirmed save keeps the value it had', () async {
      final store = _Store()
        ..saveError = const ServerConfigException(
          ServerConfigFailureKind.unconfirmed,
        );
      final controller = _controller(store);
      await controller.load();
      await controller.save('timezone', 'Europe/Madrid');
      expect(controller.valueOf('timezone'), 'UTC');
      expect(
        controller.errorOf('timezone'),
        ServerConfigFailureKind.unconfirmed,
      );
    });

    test(
      'starting another save clears the previous error of the field',
      () async {
        final store = _Store()
          ..saveError = const ServerConfigException(
            ServerConfigFailureKind.remote,
          );
        final controller = _controller(store);
        await controller.load();
        await controller.save('timezone', 'A');
        store.saveError = null;
        final again = controller.save('timezone', 'B');
        expect(controller.errorOf('timezone'), isNull);
        await again;
        expect(controller.valueOf('timezone'), 'B');
      },
    );

    test('a read-only store never saves', () async {
      final store = _Store()..isWritable = false;
      final controller = _controller(store);
      await controller.load();

      expect(controller.canWrite, isFalse);
      expect(await controller.save('timezone', 'A'), isFalse);
      expect(store.saves, isEmpty);
    });

    test('an answer that is no longer current is dropped', () async {
      final store = _Store()..holdSave = Completer<void>();
      var current = true;
      final controller = _controller(store, isCurrent: () => current);
      await controller.load();

      final saving = controller.save('agent.max_turns', 50);
      current = false;
      store.holdSave!.complete();
      await saving;

      expect(controller.valueOf('agent.max_turns'), 90);
    });

    test('an answer after dispose does not notify', () async {
      final store = _Store()..holdSave = Completer<void>();
      final controller = _controller(store);
      await controller.load();
      final saving = controller.save('agent.max_turns', 50);
      controller.dispose();
      store.holdSave!.complete();
      await saving;
      // Nothing to assert beyond: no exception from notifyListeners().
    });
  });
}
