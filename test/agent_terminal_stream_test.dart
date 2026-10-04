// Live output of the agent's background processes: seeded from process.list,
// chunks routed by id, bounded like Desktop, and nothing kept once the page
// is closed.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/terminal_exec.dart';
import 'package:hermes_android/core/services/agent_terminal_stream.dart';

AgentProcessSeed _seed(String id, {String tail = '', bool closed = false}) =>
    AgentProcessSeed(
      id: id,
      command: 'cmd $id',
      outputTail: tail,
      closed: closed,
    );

void main() {
  test('seeding shows each process with its output tail', () {
    final s = AgentTerminalStream();
    s.seed([_seed('a', tail: 'one\n'), _seed('b', closed: true)]);
    expect(s.ids, ['a', 'b']);
    expect(s.backlog('a'), 'one\n');
    expect(s.isClosed('a'), isFalse);
    expect(s.isClosed('b'), isTrue);
  });

  test('chunks are appended to the process they name', () {
    final s = AgentTerminalStream();
    s.seed([_seed('a', tail: 'x'), _seed('b')]);
    s.onChunk('a', 'y');
    s.onChunk('b', 'z');
    expect(s.backlog('a'), 'xy');
    expect(s.backlog('b'), 'z');
  });

  test('a chunk for an unknown process opens it', () {
    final s = AgentTerminalStream();
    s.onChunk('late', 'hello');
    expect(s.ids, ['late']);
    expect(s.backlog('late'), 'hello');
  });

  test('close marks the process closed and keeps its output', () {
    final s = AgentTerminalStream();
    s.onChunk('a', 'done');
    s.onClose('a');
    expect(s.isClosed('a'), isTrue);
    expect(s.backlog('a'), 'done');
  });

  test('seeding again never erases chunks that already arrived', () {
    final s = AgentTerminalStream();
    s.onChunk('a', 'live');
    s.seed([_seed('a', tail: 'old tail')]);
    expect(s.backlog('a'), 'live');
  });

  test('a process backlog keeps its newest 256 000 characters', () {
    final s = AgentTerminalStream();
    s.onChunk('a', 'A' * 200000);
    s.onChunk('a', 'B' * 100000);
    final text = s.backlog('a');
    expect(text.length, 256000);
    expect(text.endsWith('B' * 100000), isTrue);
    expect(text.startsWith('A'), isTrue);
  });

  test('at most 24 processes are tracked, oldest evicted first', () {
    final s = AgentTerminalStream();
    for (var i = 0; i < 26; i++) {
      s.onChunk('p$i', 'x');
    }
    expect(s.ids.length, 24);
    expect(s.ids.first, 'p2');
    expect(s.ids.last, 'p25');
  });

  test('the visible process is never evicted', () {
    final s = AgentTerminalStream();
    s.onChunk('p0', 'x');
    s.setVisible('p0');
    for (var i = 1; i < 30; i++) {
      s.onChunk('p$i', 'x');
    }
    expect(s.ids, contains('p0'));
    expect(s.ids.length, 24);
  });

  test('the total is capped at 2 000 000 characters', () {
    final s = AgentTerminalStream();
    for (var i = 0; i < 10; i++) {
      s.onChunk('p$i', 'x' * 250000);
    }
    expect(s.totalChars, lessThanOrEqualTo(2000000));
    expect(s.ids, contains('p9'), reason: 'the newest survives');
    expect(s.ids, isNot(contains('p0')), reason: 'the oldest was evicted');
  });

  test('the visible process survives the total cap', () {
    final s = AgentTerminalStream();
    s.onChunk('keep', 'k' * 250000);
    s.setVisible('keep');
    for (var i = 0; i < 12; i++) {
      s.onChunk('p$i', 'x' * 250000);
    }
    expect(s.ids, contains('keep'));
    expect(s.totalChars, lessThanOrEqualTo(2000000));
  });

  test('listeners hear about every change', () {
    final s = AgentTerminalStream();
    var n = 0;
    s.addListener(() => n++);
    s.onChunk('a', 'x');
    s.onClose('a');
    expect(n, 2);
  });

  test('nothing is buffered once the stream is disposed', () {
    final s = AgentTerminalStream();
    s.onChunk('a', 'x');
    s.dispose();
    s.onChunk('a', 'secret-marker');
    s.seed([_seed('b', tail: 'secret-marker')]);
    expect(s.ids, isEmpty);
    expect(s.totalChars, 0);
  });

  test('received counts every character ever appended, trimming included', () {
    final s = AgentTerminalStream();
    s.onChunk('a', 'A' * 200000);
    s.onChunk('a', 'B' * 100000);
    expect(s.received('a'), 300000);
    expect(s.backlog('a').length, 256000);
    expect(s.received('missing'), 0);
  });

  group('a close that arrives before the process is known', () {
    test('is kept and applied when a stale seed later lists it open', () {
      final s = AgentTerminalStream();
      s.onClose('quiet');
      s.seed([_seed('quiet', tail: '')]);
      expect(s.isClosed('quiet'), isTrue);
    });

    test('is applied when the process first shows up through a chunk', () {
      final s = AgentTerminalStream();
      s.onClose('p');
      s.onChunk('p', 'late');
      expect(s.isClosed('p'), isTrue);
    });

    test('does not mark an unrelated process closed', () {
      final s = AgentTerminalStream();
      s.onClose('a');
      s.seed([_seed('b', tail: 'x')]);
      expect(s.isClosed('b'), isFalse);
    });

    test('the remembered closes are bounded and dropped on dispose', () {
      final s = AgentTerminalStream();
      for (var i = 0; i < 1000; i++) {
        s.onClose('p$i');
      }
      s.seed([_seed('p0', tail: ''), _seed('p999', tail: '')]);
      expect(s.isClosed('p999'), isTrue);
      expect(s.isClosed('p0'), isFalse, reason: 'oldest tombstone evicted');
      final t = AgentTerminalStream();
      t.onClose('gone');
      t.dispose();
      t.seed([_seed('gone', tail: '')]);
      expect(t.ids, isEmpty);
    });

    test(
      'a burst up to the cap is all kept and one more evicts the oldest',
      () {
        final s = AgentTerminalStream(maxProcesses: 1000);
        for (var i = 0; i < 256; i++) {
          s.onClose('p$i');
        }
        s.seed([for (var i = 0; i < 256; i++) _seed('p$i')]);
        for (var i = 0; i < 256; i++) {
          expect(s.isClosed('p$i'), isTrue, reason: 'p$i');
        }
        final t = AgentTerminalStream(maxProcesses: 1000);
        for (var i = 0; i < 257; i++) {
          t.onClose('q$i');
        }
        t.seed([_seed('q0'), _seed('q1'), _seed('q256')]);
        expect(t.isClosed('q0'), isFalse);
        expect(t.isClosed('q1'), isTrue);
        expect(t.isClosed('q256'), isTrue);
      },
    );

    test('two different early closes are both kept', () {
      final s = AgentTerminalStream();
      s.onClose('first');
      s.onClose('second');
      s.seed([_seed('first', tail: ''), _seed('second', tail: '')]);
      expect(s.isClosed('first'), isTrue);
      expect(s.isClosed('second'), isTrue);
    });
  });
}
