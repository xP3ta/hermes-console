import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/models/session_list_sort.dart';

Session _s(
  String id, {
  double started = 1,
  double? updated,
  int tokens = 0,
  double? cost,
}) => Session(
  id: id,
  title: id,
  model: 'm',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: '',
  startedAt: started,
  updatedAt: updated ?? started,
  endedAt: updated ?? started,
  inputTokens: tokens,
  estimatedCostUsd: cost,
);

List<String> _ids(Iterable<Session> rows) => [for (final r in rows) r.id];

void main() {
  bool noPins(Session _) => false;

  group('SessionListSort wire names', () {
    test('round-trip and fall back to activity', () {
      for (final sort in SessionListSort.values) {
        expect(SessionListSort.fromWire(sort.wire), sort);
      }
      expect(SessionListSort.fromWire('status'), SessionListSort.activity);
      expect(SessionListSort.fromWire(null), SessionListSort.activity);
    });

    test('activity is the default', () {
      expect(SessionListSort.values.first, SessionListSort.activity);
    });
  });

  group('sortSessionList', () {
    test('activity: most recent first, ties by id', () {
      final rows = [
        _s('b', updated: 10),
        _s('a', updated: 10),
        _s('c', updated: 30),
      ];
      expect(
        _ids(sortSessionList(rows, SessionListSort.activity, isPinned: noPins)),
        ['c', 'a', 'b'],
      );
    });

    test('created: newest start first, ties by activity', () {
      final rows = [
        _s('old', started: 100, updated: 900),
        _s('new-quiet', started: 500, updated: 510),
        _s('new-busy', started: 500, updated: 800),
      ];
      expect(
        _ids(sortSessionList(rows, SessionListSort.created, isPinned: noPins)),
        ['new-busy', 'new-quiet', 'old'],
      );
    });

    test('tokens: most input tokens first, ties by activity', () {
      final rows = [
        _s('few', tokens: 10, updated: 900),
        _s('many', tokens: 5000, updated: 100),
        _s('few-newer', tokens: 10, updated: 950),
      ];
      expect(
        _ids(sortSessionList(rows, SessionListSort.tokens, isPinned: noPins)),
        ['many', 'few-newer', 'few'],
      );
    });

    test('cost: most expensive first, unknown cost last, ties by activity', () {
      final rows = [
        _s('cheap', cost: 0.02, updated: 100),
        _s('unknown', updated: 999),
        _s('dear', cost: 4.5, updated: 50),
        _s('free', cost: 0, updated: 200),
        _s('cheap-newer', cost: 0.02, updated: 300),
      ];
      expect(
        _ids(sortSessionList(rows, SessionListSort.cost, isPinned: noPins)),
        ['dear', 'cheap-newer', 'cheap', 'free', 'unknown'],
      );
    });

    test('pinned rows stay on top whatever the key', () {
      final rows = [
        _s('pinned-cheap', cost: 0.01, updated: 5),
        _s('dear', cost: 9, updated: 6),
        _s('pinned-dear', cost: 3, updated: 7),
      ];
      bool pinned(Session s) => s.id.startsWith('pinned');
      expect(
        _ids(sortSessionList(rows, SessionListSort.cost, isPinned: pinned)),
        ['pinned-dear', 'pinned-cheap', 'dear'],
      );
    });

    test('pinned rows can be left in place for the archive view', () {
      final rows = [_s('a', updated: 1), _s('b', updated: 2)];
      expect(
        _ids(
          sortSessionList(
            rows,
            SessionListSort.activity,
            isPinned: (s) => s.id == 'a',
            pinnedFirst: false,
          ),
        ),
        ['b', 'a'],
      );
    });

    test('does not mutate its input', () {
      final rows = [_s('a', updated: 1), _s('b', updated: 2)];
      sortSessionList(rows, SessionListSort.activity, isPinned: noPins);
      expect(_ids(rows), ['a', 'b']);
    });
  });

  group('dateFor', () {
    final row = _s('x', started: 100, updated: 900);

    test('activity groups by last activity, created by start', () {
      expect(SessionListSort.activity.dateFor(row), 900);
      expect(SessionListSort.created.dateFor(row), 100);
    });

    test('tokens and cost have no date sections', () {
      expect(SessionListSort.tokens.dateFor(row), isNull);
      expect(SessionListSort.cost.dateFor(row), isNull);
    });
  });
}
