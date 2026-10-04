import 'dart:async';

import 'package:flutter/foundation.dart';
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
    'a rehydration asked for another runtime leaves this watch alone',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();
      gateway.emit('watch-1', 'message.delta', {'text': 'sigo'});

      gateway.rehydrate('some-other-runtime');
      await pumpEventQueue();

      expect(watch.value.status, SubagentLiveWatchStatus.live);
      expect(watch.value.text, 'sigo');
      expect(gateway.resumes, hasLength(1));
      expect(gateway.released, isEmpty);
    },
  );

  test('a rehydration naming this runtime resumes a fresh one', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.rehydrate('watch-1');
    await pumpEventQueue();

    expect(gateway.resumes, hasLength(2));
    expect(gateway.released, ['watch-1']);
    expect(watch.value.status, SubagentLiveWatchStatus.live);
  });

  test(
    'the final summary is not appended again after deltas and a tool',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      gateway.emit('watch-1', 'message.delta', {'text': 'Voy a leer'});
      gateway.emit('watch-1', 'tool.start', {'name': 'read_file'});
      gateway.emit('watch-1', 'message.delta', {'text': 'Hecho'});
      gateway.emit('watch-1', 'message.complete', {
        'text': 'Voy a leer\nHecho',
      });
      await pumpEventQueue();

      expect(watch.value.text, 'Voy a leer\n› read_file\nHecho');
      expect(watch.value.status, SubagentLiveWatchStatus.finished);
    },
  );

  test('a corrected summary is kept when only a space differs', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.delta', {'text': 'SELECT * FROMusers'});
    gateway.emit('watch-1', 'message.complete', {
      'text': 'SELECT * FROM users',
    });
    await pumpEventQueue();

    expect(watch.value.text, contains('SELECT * FROM users'));
    expect(watch.value.text, 'SELECT * FROMusers\nSELECT * FROM users');
  });

  test(
    'both text buffers never exceed their budget, even for one huge frame',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      gateway.emit('watch-1', 'message.delta', {'text': 'x' * 1000000});
      expect(
        watch.deltaCharsForTesting,
        lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
      );
      expect(
        watch.liveRawCharsForTesting,
        lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
      );
      expect(
        watch.value.text.length,
        lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
      );

      final chunk = 'y' * 2000;
      for (var i = 0; i < 300; i++) {
        gateway.emit('watch-1', 'message.delta', {'text': chunk});
      }
      expect(
        watch.deltaCharsForTesting,
        lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
      );
      expect(
        watch.liveRawCharsForTesting,
        lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
      );
    },
  );

  test(
    'a summary that only restructures the text is kept, not swallowed',
    () async {
      for (final (streamed, summary) in <(String, String)>[
        ('uno dos', 'uno\n\ndos'),
        ('x\n a', 'x\n    a'),
        ('a | b', 'a\n---|---\nb'),
        ('print(1)', '```\nprint(1)\n```'),
      ]) {
        final gateway = FakeWatchGateway();
        final watch = _watch(gateway)..start();
        await pumpEventQueue();

        gateway.emit('watch-1', 'message.delta', {'text': streamed});
        gateway.emit('watch-1', 'message.complete', {'text': summary});
        await pumpEventQueue();

        expect(watch.value.text, '$streamed\n$summary', reason: summary);
      }
    },
  );

  test('line endings alone do not make a summary new', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.delta', {'text': 'uno\ndos'});
    gateway.emit('watch-1', 'message.complete', {'text': 'uno\r\ndos'});
    await pumpEventQueue();

    expect(watch.value.text, 'uno\ndos');
  });

  test(
    'an authoritative final survives a delta that filled the buffer',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      gateway.emit('watch-1', 'message.delta', {'text': 'x' * 1000000});
      gateway.emit('watch-1', 'message.complete', {'text': 'FINAL_CORREGIDO'});
      await pumpEventQueue();

      expect(watch.value.status, SubagentLiveWatchStatus.finished);
      expect(watch.value.text, endsWith('FINAL_CORREGIDO'));
      expect(
        watch.value.text.length,
        lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
      );
      expect(
        watch.liveRawCharsForTesting,
        lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
      );
    },
  );

  test('a final larger than the budget keeps its tail, bounded', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.delta', {'text': 'corto'});
    gateway.emit('watch-1', 'message.complete', {
      'text': '${'y' * 1000000}CONCLUSION',
    });
    await pumpEventQueue();

    expect(watch.value.text, endsWith('CONCLUSION'));
    expect(
      watch.value.text.length,
      lessThanOrEqualTo(SubagentLiveWatch.maxLiveChars),
    );
  });

  test('truncation never leaves half a surrogate pair', () async {
    bool wellFormed(String text) {
      for (var i = 0; i < text.length; i++) {
        final unit = text.codeUnitAt(i);
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          if (i + 1 >= text.length) return false;
          final next = text.codeUnitAt(i + 1);
          if (next < 0xDC00 || next > 0xDFFF) return false;
          i++;
        } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
          return false;
        }
      }
      return true;
    }

    // Head: the emoji straddles the very last code unit of the budget.
    var gateway = FakeWatchGateway();
    var watch = _watch(gateway)..start();
    await pumpEventQueue();
    gateway.emit('watch-1', 'message.delta', {
      'text': '${'a' * (SubagentLiveWatch.maxLiveChars - 1)}😀 fin',
    });
    expect(wellFormed(watch.value.text), isTrue);
    expect(watch.value.text, 'a' * (SubagentLiveWatch.maxLiveChars - 1));
    expect(wellFormed(watch.deltaTextForTesting), isTrue);

    // Tail: the cut falls between the two halves of an emoji.
    gateway = FakeWatchGateway();
    watch = _watch(gateway)..start();
    await pumpEventQueue();
    gateway.emit('watch-1', 'message.complete', {
      'text': '😀${'b' * (SubagentLiveWatch.maxLiveChars - 1)}',
    });
    await pumpEventQueue();
    expect(wellFormed(watch.value.text), isTrue);
    expect(watch.value.text, 'b' * (SubagentLiveWatch.maxLiveChars - 1));
  });

  test(
    'a short final keeps exactly the tail of the stream that fits',
    () async {
      const max = SubagentLiveWatch.maxLiveChars;
      // EARLY, a filler, a tool line and LATE leave exactly three code units
      // free, so the four-unit `\nFIN` pushes out one unit of the oldest text.
      final streamed = 'EARLY${'a' * (max - 25)}\n› read_file\nLATE';
      expect(streamed.length, max - 3);

      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();
      gateway.emit('watch-1', 'message.delta', {
        'text': 'EARLY${'a' * (max - 25)}',
      });
      gateway.emit('watch-1', 'tool.start', {'name': 'read_file'});
      gateway.emit('watch-1', 'message.delta', {'text': 'LATE'});
      expect(watch.value.text, streamed);
      gateway.emit('watch-1', 'message.complete', {'text': 'FIN'});
      await pumpEventQueue();

      expect(watch.value.text, '$streamed\nFIN'.substring(1));
      expect(watch.value.text, startsWith('ARLY'));
      expect(watch.value.text, contains('› read_file\nLATE\nFIN'));
      expect(watch.value.text.length, max);
    },
  );

  test('a short final with room left keeps everything before it', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.delta', {'text': 'EARLY'});
    gateway.emit('watch-1', 'tool.start', {'name': 'read_file'});
    gateway.emit('watch-1', 'message.delta', {'text': 'LATE'});
    gateway.emit('watch-1', 'message.complete', {'text': 'FIN'});
    await pumpEventQueue();

    expect(watch.value.text, 'EARLY\n› read_file\nLATE\nFIN');
  });

  test(
    'a final that only repeats the end of the stream is a duplicate',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      gateway.emit('watch-1', 'message.delta', {
        'text': 'Revisado. Resultado: 42',
      });
      gateway.emit('watch-1', 'message.complete', {'text': 'Resultado: 42'});
      await pumpEventQueue();

      expect(watch.value.text, 'Revisado. Resultado: 42');
    },
  );

  test(
    'a normal finish releases and closes the runtime exactly once',
    () async {
      final gateway = FakeWatchGateway();
      final watch = SubagentLiveWatch(
        gateway: gateway,
        childSessionId: _child,
        profile: _parentProfile,
        isCurrent: () => true,
      )..start();
      await pumpEventQueue();
      expect(gateway.retained, ['watch-1']);
      expect(gateway.released, isEmpty);

      gateway.emit('watch-1', 'message.complete', {'text': 'listo'});
      await pumpEventQueue();
      expect(gateway.released, ['watch-1']);
      expect(gateway.closed, ['watch-1']);

      // A late frame and the disposal must not release or close it again.
      gateway.emit('watch-1', 'message.complete', {'text': 'otra vez'});
      watch.dispose();
      await pumpEventQueue();
      expect(gateway.released, ['watch-1']);
      expect(gateway.closed, ['watch-1']);
    },
  );

  test('disposing while the close is still pending closes only once', () async {
    final gateway = FakeWatchGateway()..closeGate = Completer<void>();
    final watch = SubagentLiveWatch(
      gateway: gateway,
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => true,
    )..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.complete', {'text': 'listo'});
    await pumpEventQueue();
    // The first close is on the wire and has not answered yet.
    expect(gateway.closed, ['watch-1']);
    expect(gateway.released, ['watch-1']);

    watch.dispose();
    await pumpEventQueue();
    expect(gateway.closed, ['watch-1']);
    expect(gateway.released, ['watch-1']);

    gateway.closeGate!.complete();
    await pumpEventQueue();
    expect(gateway.closed, ['watch-1']);
    expect(gateway.released, ['watch-1']);
  });

  test(
    'a final that appeared mid-stream is kept when text follows it',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      gateway.emit('watch-1', 'message.delta', {
        'text': 'Resultado: 42\nPero lo corrijo despues',
      });
      gateway.emit('watch-1', 'message.complete', {'text': 'Resultado: 42'});
      await pumpEventQueue();

      expect(
        watch.value.text,
        'Resultado: 42\nPero lo corrijo despues\nResultado: 42',
      );
    },
  );

  test('a close that never answers still frees every listener', () async {
    final gateway = FakeWatchGateway()..closeGate = Completer<void>();
    final invalidation = _CountingListenable();
    SubagentLiveWatch(
      gateway: gateway,
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => true,
      invalidation: invalidation,
    ).start();
    await pumpEventQueue();
    expect(gateway.hasListeners, isTrue);
    expect(invalidation.listeners, 1);

    gateway.emit('watch-1', 'message.complete', {'text': 'listo'});
    await pumpEventQueue();

    // `session.close` is still pending, and nothing has disposed the watch.
    expect(gateway.closed, ['watch-1']);
    expect(gateway.hasListeners, isFalse);
    expect(invalidation.listeners, 0);
  });

  test(
    'a final equal to text streamed before a tool line is not shown twice',
    () async {
      final gateway = FakeWatchGateway();
      final watch = _watch(gateway)..start();
      await pumpEventQueue();

      gateway.emit('watch-1', 'message.delta', {'text': 'Resultado: 42'});
      gateway.emit('watch-1', 'tool.start', {'name': 'read_file'});
      gateway.emit('watch-1', 'message.complete', {'text': 'Resultado: 42'});
      await pumpEventQueue();

      // A tool line is not assistant text: the final repeats what is shown.
      expect(watch.value.text, 'Resultado: 42\n› read_file\n');
      expect(watch.value.status, SubagentLiveWatchStatus.finished);
    },
  );

  test('dispose frees every listener before a pending close answers', () async {
    final gateway = FakeWatchGateway()..closeGate = Completer<void>();
    final invalidation = _CountingListenable();
    final watch = SubagentLiveWatch(
      gateway: gateway,
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => true,
      invalidation: invalidation,
    )..start();
    await pumpEventQueue();
    expect(gateway.hasListeners, isTrue);
    expect(invalidation.listeners, 1);

    watch.dispose();
    await pumpEventQueue();

    // `session.close` has not been acknowledged yet.
    expect(gateway.closed, ['watch-1']);
    expect(gateway.hasListeners, isFalse);
    expect(invalidation.listeners, 0);

    gateway.closeGate!.complete();
    await pumpEventQueue();
  });

  test('a corrected final after a tool line is still appended', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.delta', {'text': 'SELECT * FROMusers'});
    gateway.emit('watch-1', 'tool.start', {'name': 'read_file'});
    gateway.emit('watch-1', 'message.complete', {
      'text': 'SELECT * FROM users',
    });
    await pumpEventQueue();

    expect(
      watch.value.text,
      'SELECT * FROMusers\n› read_file\nSELECT * FROM users',
    );
  });

  test('a normal finish cancels the event subscription', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();
    expect(gateway.hasListeners, isTrue);

    gateway.emit('watch-1', 'message.complete', {'text': 'listo'});
    await pumpEventQueue();

    expect(watch.value.status, SubagentLiveWatchStatus.finished);
    expect(gateway.hasListeners, isFalse);
  });

  test('a normal finish releases the invalidation listener too', () async {
    final gateway = FakeWatchGateway();
    final invalidation = _CountingListenable();
    final watch = SubagentLiveWatch(
      gateway: gateway,
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => true,
      invalidation: invalidation,
    )..start();
    await pumpEventQueue();
    expect(invalidation.listeners, 1);

    gateway.emit('watch-1', 'message.delta', {'text': 'listo'});
    gateway.emit('watch-1', 'message.complete', {'text': 'listo'});
    await pumpEventQueue();

    expect(watch.value.status, SubagentLiveWatchStatus.finished);
    expect(invalidation.listeners, 0);
    watch.dispose();
  });

  test('a genuinely new summary is still appended', () async {
    final gateway = FakeWatchGateway();
    final watch = _watch(gateway)..start();
    await pumpEventQueue();

    gateway.emit('watch-1', 'message.delta', {'text': 'Trabajando'});
    gateway.emit('watch-1', 'message.complete', {'text': 'Resumen distinto'});
    await pumpEventQueue();

    expect(watch.value.text, 'Trabajando\nResumen distinto');
  });

  test('a stale owner is noticed without any further event', () async {
    final gateway = FakeWatchGateway();
    final invalidation = ChangeNotifier();
    addTearDown(invalidation.dispose);
    var current = true;
    final watch = SubagentLiveWatch(
      gateway: gateway,
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => current,
      invalidation: invalidation,
    );
    addTearDown(watch.dispose);
    watch.start();
    await pumpEventQueue();
    expect(watch.value.status, SubagentLiveWatchStatus.live);

    current = false; // the active profile changed; nothing arrives after it
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    invalidation.notifyListeners();
    await pumpEventQueue();

    expect(watch.value.status, SubagentLiveWatchStatus.unavailable);
    expect(gateway.closed, ['watch-1']);
    expect(gateway.released, ['watch-1']);
  });

  test('closing and disposing release the invalidation listener', () async {
    final gateway = FakeWatchGateway();
    final invalidation = _CountingListenable();
    final watch = SubagentLiveWatch(
      gateway: gateway,
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => true,
      invalidation: invalidation,
    )..start();
    await pumpEventQueue();
    expect(invalidation.listeners, 1);

    await watch.close();
    expect(invalidation.listeners, 0);
    invalidation.notify();
    await pumpEventQueue();
    expect(gateway.closed, ['watch-1'], reason: 'one close, nothing after it');

    final other = SubagentLiveWatch(
      gateway: FakeWatchGateway(),
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => true,
      invalidation: invalidation,
    )..start();
    await pumpEventQueue();
    expect(invalidation.listeners, 1);
    other.dispose();
    await pumpEventQueue();
    expect(invalidation.listeners, 0);
    watch.dispose();
  });

  test('a watch that gave up on a stale owner stops listening too', () async {
    final gateway = FakeWatchGateway();
    final invalidation = _CountingListenable();
    var current = true;
    final watch = SubagentLiveWatch(
      gateway: gateway,
      childSessionId: _child,
      profile: _parentProfile,
      isCurrent: () => current,
      invalidation: invalidation,
    )..start();
    await pumpEventQueue();

    current = false;
    invalidation.notify();
    await pumpEventQueue();

    expect(watch.value.status, SubagentLiveWatchStatus.unavailable);
    expect(invalidation.listeners, 0);
    watch.dispose();
  });

  test(
    'a notification while the owner is still current changes nothing',
    () async {
      final gateway = FakeWatchGateway();
      final invalidation = ChangeNotifier();
      addTearDown(invalidation.dispose);
      final watch = SubagentLiveWatch(
        gateway: gateway,
        childSessionId: _child,
        profile: _parentProfile,
        isCurrent: () => true,
        invalidation: invalidation,
      );
      addTearDown(watch.dispose);
      watch.start();
      await pumpEventQueue();

      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      invalidation.notifyListeners();
      await pumpEventQueue();

      expect(watch.value.status, SubagentLiveWatchStatus.live);
      expect(gateway.closed, isEmpty);
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

/// A [Listenable] that counts its listeners, to prove they are released.
class _CountingListenable implements Listenable {
  final _listeners = <VoidCallback>[];
  int get listeners => _listeners.length;

  void notify() {
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}
