import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/fake_subagent_watch_gateway.dart';

const _child = watchTestChild;
const _parentProfile = 'parent-profile';

SubagentLiveWatch _watch(
  FakeWatchGateway gateway, {
  bool Function()? isCurrent,
  bool Function()? childIsLive,
}) {
  final watch = SubagentLiveWatch(
    gateway: gateway,
    childSessionId: _child,
    profile: _parentProfile,
    isCurrent: isCurrent ?? () => true,
    childIsLive: childIsLive ?? () => false,
  );
  addTearDown(watch.dispose);
  return watch;
}

void main() {
  test(
    'projects the upstream child mirror sequence and drops reasoning',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();
      expect(watch.value.status, SubagentLiveWatchStatus.live);

      // tests/tui_gateway/test_subagent_child_mirror.py::
      //   test_live_child_session_gets_native_stream
      gateway.emit('watch-1', 'message.start');
      gateway.emit('watch-1', 'tool.start', {
        'name': 'read_file',
        'tool_id': 'submirror:child:0',
        'args': {'path': 'secret-arg'},
        'preview': 'secret-preview',
      });
      gateway.emit('watch-1', 'reasoning.delta', {'text': 'secret thought'});
      gateway.emit('watch-1', 'tool.complete', {'name': 'read_file'});
      gateway.emit('watch-1', 'tool.start', {
        'name': 'write_file',
        'tool_id': 'submirror:child:1',
      });
      gateway.emit('watch-1', 'tool.complete', {'name': 'write_file'});
      expect(watch.value.status, SubagentLiveWatchStatus.live);
      gateway.emit('watch-1', 'message.complete', {'text': 'Resumen final'});
      await pumpEventQueue();

      expect(watch.value.text, '› read_file\n› write_file\nResumen final');
      expect(watch.value.text, isNot(contains('secret')));
      expect(watch.value.status, SubagentLiveWatchStatus.finished);
      // The finished child frees its runtime straight away.
      expect(gateway.closed, ['watch-1']);
    },
  );

  test('grows the child text token by token', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.start');
    gateway.emit('watch-1', 'message.delta', {'text': 'Hola '});
    expect(watch.value.text, 'Hola ');
    gateway.emit('watch-1', 'message.delta', {'text': 'mundo'});
    expect(watch.value.text, 'Hola mundo');
    expect(watch.value.status, SubagentLiveWatchStatus.live);
  });

  test('renders only public stored history before the live events', () async {
    final gateway = FakeWatchGateway()
      ..answer = (runtime) async => watchTestSnapshot(
        runtime,
        messages: [
          {'role': 'user', 'content': 'goal prompt'},
          {'role': 'assistant', 'content': 'Paso previo'},
          {
            'role': 'assistant',
            'content': '<think>private plan</think>Visible',
          },
        ],
      );
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    expect(watch.value.text, contains('Paso previo'));
    expect(watch.value.text, contains('Visible'));
    expect(watch.value.text, isNot(contains('private plan')));
    expect(watch.value.text, isNot(contains('goal prompt')));
  });

  test(
    'resumes the child lazily with the parent profile and one retain',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      watch.start(); // idempotent while opening
      await pumpEventQueue();
      watch.start(); // idempotent while live
      await pumpEventQueue();

      expect(gateway.resumes, [(childId: _child, profile: _parentProfile)]);
      expect(gateway.retained, ['watch-1']);
    },
  );

  test(
    'closing sends exactly one session.close and releases the runtime',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      await watch.close();
      await watch.close();
      expect(gateway.closed, ['watch-1']);
      expect(gateway.released, ['watch-1']);
    },
  );

  test(
    'a late delta after leaving the page paints nothing and throws nothing',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();
      gateway.emit('watch-1', 'message.delta', {'text': 'antes'});
      var notifications = 0;
      watch.addListener(() => notifications++);

      await watch.close();
      final afterClose = notifications;
      gateway.emit('watch-1', 'message.delta', {'text': 'tarde'});
      gateway.emit('watch-1', 'message.complete', {'text': 'tarde'});
      gateway.drop();
      await pumpEventQueue();

      expect(watch.value.text, 'antes');
      expect(notifications, afterClose);
      expect(gateway.closed, ['watch-1']);
      expect(gateway.resumes, hasLength(1));
    },
  );

  test(
    'a socket drop mid-stream resumes a fresh runtime without duplicating text',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();
      gateway.emit('watch-1', 'message.delta', {'text': 'parcial'});
      expect(watch.value.text, 'parcial');

      gateway.drop();
      expect(watch.value.status, SubagentLiveWatchStatus.reconnecting);
      await pumpEventQueue();

      expect(watch.value.status, SubagentLiveWatchStatus.live);
      expect(gateway.resumes, hasLength(2));
      expect(gateway.resumes.last.profile, _parentProfile);
      expect(watch.value.text, isEmpty, reason: 'live buffer is discarded');
      expect(gateway.released, ['watch-1']);
      expect(gateway.retained, ['watch-1', 'watch-2']);

      // The old runtime never paints again; the new one does, once.
      gateway.emit('watch-1', 'message.delta', {'text': 'viejo'});
      gateway.emit('watch-2', 'message.delta', {'text': 'nuevo'});
      expect(watch.value.text, 'nuevo');

      await watch.close();
      // The first runtime died with its socket: only the live one is closed.
      expect(gateway.closed, ['watch-2']);
    },
  );

  test(
    'a failed re-resume after a drop falls back to the polled tail',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      gateway.answer = (_) => Future.error(
        const TuiGatewayRpcError('session.resume', 'unreachable'),
      );
      gateway.drop();
      await pumpEventQueue();

      expect(watch.value.status, SubagentLiveWatchStatus.unavailable);
      expect(gateway.resumes, hasLength(2));
    },
  );

  test('a profile switch while the resume is in flight ignores the answer and '
      'closes the runtime', () async {
    final gateway = FakeWatchGateway();
    final pending = Completer<DesktopSessionSnapshot>();
    gateway.answer = (_) => pending.future;
    var current = true;
    final watch = _watch(gateway, isCurrent: () => current)..start();
    await pumpEventQueue();
    expect(watch.value.status, SubagentLiveWatchStatus.opening);

    current = false; // ActiveProfileScope epoch moved
    pending.complete(
      watchTestSnapshot(
        'watch-1',
        messages: [
          {'role': 'assistant', 'content': 'otro perfil'},
        ],
      ),
    );
    await pumpEventQueue();

    expect(watch.value.status, SubagentLiveWatchStatus.unavailable);
    expect(watch.value.text, isEmpty);
    expect(gateway.retained, isEmpty);
    expect(gateway.closed, ['watch-1']);
  });

  test(
    'an event after the owner moved on closes the runtime and stops painting',
    () async {
      final gateway = FakeWatchGateway();
      var current = true;
      final watch = _watch(gateway, isCurrent: () => current)..start();
      await pumpEventQueue();
      gateway.emit('watch-1', 'message.delta', {'text': 'uno'});

      current = false;
      gateway.emit('watch-1', 'message.delta', {'text': 'dos'});
      await pumpEventQueue();

      expect(watch.value.text, 'uno');
      expect(watch.value.status, SubagentLiveWatchStatus.unavailable);
      expect(gateway.closed, ['watch-1']);
    },
  );

  test(
    'closing while the resume is in flight closes the late runtime once',
    () async {
      final gateway = FakeWatchGateway();
      final pending = Completer<DesktopSessionSnapshot>();
      gateway.answer = (_) => pending.future;
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      await watch.close();
      pending.complete(watchTestSnapshot('watch-1'));
      await pumpEventQueue();

      expect(gateway.closed, ['watch-1']);
      expect(gateway.retained, isEmpty);
      expect(watch.value.text, isEmpty);
    },
  );

  test(
    'a child that already finished shows its history and keeps no runtime',
    () async {
      final gateway = FakeWatchGateway()
        ..answer = (runtime) async => watchTestSnapshot(
          runtime,
          running: false,
          messages: [
            {'role': 'assistant', 'content': 'Terminado'},
          ],
        );
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      expect(watch.value.status, SubagentLiveWatchStatus.finished);
      expect(watch.value.text, 'Terminado');
      expect(gateway.closed, ['watch-1']);
      expect(gateway.retained, isEmpty);
    },
  );

  test('a resume without a running turn keeps the watch while the parent '
      'still shows the child working', () async {
    final gateway = FakeWatchGateway()
      ..answer = (runtime) async => watchTestSnapshot(runtime, running: false);
    final watch = _watch(gateway, childIsLive: () => true)..start();
    await pumpEventQueue();

    expect(watch.value.status, SubagentLiveWatchStatus.live);
    expect(gateway.retained, ['watch-1']);
    expect(gateway.closed, isEmpty);

    // The mirror starts after the resume answered: it is still delivered.
    gateway.emit('watch-1', 'message.delta', {'text': 'ya arranca'});
    expect(watch.value.text, 'ya arranca');
  });

  test('an old server rejecting the resume degrades silently', () async {
    final gateway = FakeWatchGateway()
      ..answer = (_) => Future.error(
        const TuiGatewayRpcError(
          'session.resume',
          'Method not found',
          code: -32601,
        ),
      );
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    expect(watch.value.status, SubagentLiveWatchStatus.unavailable);
    expect(gateway.closed, isEmpty);
    expect(gateway.retained, isEmpty);
  });
}
