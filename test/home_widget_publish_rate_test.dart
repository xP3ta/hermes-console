// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';

/// Counts launcher redraw requests, which is what Android logs as
/// `AppWidgetServiceImpl: Trying to notify widget update`.
class _CountingStore implements HomeWidgetStore {
  final values = <String, Object?>{};
  final redraws = <Map<String, Object?>>[];

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> requestUpdate() async {
    redraws.add(Map<String, Object?>.from(values));
  }
}

const _t0 = 2000000000000;

final _connection = SavedConnection(
  id: 'conn-1',
  label: 'Test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
);

void main() {
  group('home widget publish rate during a running turn', () {
    late _CountingStore store;
    late HermesHomeWidgetPublisher publisher;
    late ActiveChatService service;
    late ActiveChat chat;
    late FakeAsync clock;

    int now() => _t0 + clock.elapsed.inMilliseconds;

    void boot(FakeAsync async) {
      clock = async;
      store = _CountingStore();
      publisher = HermesHomeWidgetPublisher(store: store, nowMs: now);
      service = ActiveChatService(homeWidgetNowMs: now)
        ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
      chat = service.attach(
        connection: _connection,
        sessionId: 'sess-1',
        sessionTitle: 'Rate',
        disableForegroundKeepAlive: true,
      );
      async.flushMicrotasks();
    }

    String? agentState(Map<String, Object?> values) =>
        values['hermes_widget_agent_state'] as String?;

    test('steady streaming redraws the launcher at most twice per minute', () {
      fakeAsync((async) {
        boot(async);
        chat.state = ChatPipelineState.streaming;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();
        final afterTransition = store.redraws.length;
        expect(
          agentState(store.redraws.last),
          HomeWidgetAgentState.streaming.name,
          reason: 'the transition into streaming must be published at once',
        );

        // One simulated minute of the owner's trace: token flushes, periodic
        // session.info and the live context meter, three paths per tick.
        var used = 1000;
        for (var tick = 0; tick < 90; tick++) {
          async.elapse(const Duration(milliseconds: 666));
          service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
          service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.sessionInfo);
          used += 37;
          service.updateHomeWidgetSessionContext(
            chat,
            contextUsed: used,
            contextMax: 200000,
            contextPercent: (used * 100 / 200000).round(),
          );
          async.flushMicrotasks();
        }
        final steady = store.redraws.length - afterTransition;
        // ignore: avoid_print
        print('steady-state redraws in 60 s: $steady');
        expect(steady, lessThanOrEqualTo(2));
        service.dispose();
      });
    });

    test('state transitions still reach the widget immediately', () {
      fakeAsync((async) {
        boot(async);
        chat.state = ChatPipelineState.streaming;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();

        chat.state = ChatPipelineState.executing;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.toolProgress);
        async.flushMicrotasks();
        expect(
          agentState(store.redraws.last),
          HomeWidgetAgentState.toolExecution.name,
        );

        chat.state = ChatPipelineState.completed;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.done);
        async.flushMicrotasks();
        expect(agentState(store.redraws.last), HomeWidgetAgentState.idle.name);
        expect(store.values['hermes_widget_last_activity_at_ms'], now());
        service.dispose();
      });
    });

    test('coalesced metrics land on the widget once the window closes', () {
      fakeAsync((async) {
        boot(async);
        chat.state = ChatPipelineState.streaming;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        service.updateHomeWidgetSessionContext(
          chat,
          contextUsed: 4242,
          contextMax: 10000,
          contextPercent: 42,
        );
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));

        expect(store.values['hermes_widget_context_used'], 4242);
        expect(store.values['hermes_widget_context_percent'], 42);
        service.dispose();
      });
    });

    test('dispose cancels a pending coalesced publication', () {
      fakeAsync((async) {
        boot(async);
        chat.state = ChatPipelineState.streaming;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        service.updateHomeWidgetSessionContext(
          chat,
          contextUsed: 10,
          contextMax: 100,
          contextPercent: 10,
        );
        final before = store.redraws.length;
        expect(
          async.pendingTimers.where((t) => t.duration.inSeconds >= 5),
          isNotEmpty,
        );
        service.dispose();
        // No timer may outlive the service and keep the isolate busy.
        expect(
          async.pendingTimers.where((t) => t.duration.inSeconds >= 5),
          isEmpty,
        );
        async.elapse(const Duration(minutes: 1));
        expect(store.redraws.length, before);
      });
    });
  });
}
