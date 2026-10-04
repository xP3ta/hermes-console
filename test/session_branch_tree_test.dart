import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/utils/session_branch_tree.dart';

Session _s(
  String id, {
  String? parent,
  String? branchedFrom,
  String? resetFrom,
  String? root,
  List<String> lineage = const [],
  String? profile,
  double at = 1,
}) => Session(
  id: id,
  title: id,
  model: 'm',
  source: 'mobile',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: at,
  updatedAt: at,
  parentSessionId: parent,
  branchedFromId: branchedFrom,
  resetFromId: resetFrom,
  lineageRootId: root,
  lineageIds: lineage,
  profile: profile,
);

List<String> _ids(List<BranchTreeEntry> rows) =>
    rows.map((e) => e.session.id).toList();

void main() {
  group('forkParentId', () {
    test('a reset marker means a new conversation, not a fork', () {
      expect(forkParentId(_s('a', parent: 'p', resetFrom: 'p')), isNull);
    });
    test('the branch marker wins over the parent id', () {
      expect(forkParentId(_s('a', parent: 'p', branchedFrom: 'b')), 'b');
    });
    test('legacy forks fall back to parent_session_id', () {
      expect(forkParentId(_s('a', parent: ' p ')), 'p');
      expect(forkParentId(_s('a')), isNull);
    });
  });

  group('collapseCompressionLineages', () {
    test('rows of one lineage collapse to the tip nothing continues from', () {
      final rows = collapseCompressionLineages([
        _s('a', root: 'a', at: 3),
        _s('b', root: 'a', parent: 'a', at: 2),
      ]);
      expect(rows.map((e) => e.id), ['b']);
    });
    test('without a clear tip the freshest row is kept', () {
      final rows = collapseCompressionLineages([
        _s('a', root: 'r', at: 1),
        _s('b', root: 'r', at: 5),
      ]);
      expect(rows.map((e) => e.id), ['b']);
    });
    test('the same root in another profile is another conversation', () {
      final rows = collapseCompressionLineages([
        _s('a', root: 'r', profile: 'one'),
        _s('b', root: 'r', profile: 'two'),
      ]);
      expect(rows.length, 2);
    });
  });

  group('flattenSessionsWithBranches', () {
    test('/new children are not nested', () {
      final rows = flattenSessionsWithBranches([
        _s('a', at: 1),
        _s('b', parent: 'a', resetFrom: 'a', at: 2),
      ]);
      expect(rows.every((e) => e.depth == 0), isTrue);
      expect(rows.length, 2);
    });

    test('branch of a branch nests with Desktop stems', () {
      final rows = flattenSessionsWithBranches([
        _s('a', at: 1),
        _s('b', branchedFrom: 'a', at: 2),
        _s('c', branchedFrom: 'b', at: 3),
        _s('d', branchedFrom: 'a', at: 4),
      ]);
      expect(_ids(rows), ['a', 'd', 'b', 'c']);
      expect(rows.map((e) => e.depth), [0, 1, 1, 2]);
      expect(rows[1].prefix, '├─ ');
      expect(rows[2].prefix, '└─ ');
      expect(rows[3].prefix, '   └─ ');
    });

    test('children are sorted by recency, newest first', () {
      final rows = flattenSessionsWithBranches([
        _s('a', at: 1),
        _s('old', branchedFrom: 'a', at: 2),
        _s('new', branchedFrom: 'a', at: 9),
      ]);
      expect(_ids(rows), ['a', 'new', 'old']);
    });

    test('preserveOrder keeps the input order of roots', () {
      final rows = flattenSessionsWithBranches([
        _s('x', at: 1),
        _s('y', at: 9),
      ], preserveOrder: true);
      expect(_ids(rows), ['x', 'y']);
      expect(
        _ids(flattenSessionsWithBranches([_s('x', at: 1), _s('y', at: 9)])),
        ['y', 'x'],
      );
    });

    test('a child nests under a collapsed stale tip of its parent', () {
      final rows = flattenSessionsWithBranches([
        _s('a', root: 'a', at: 1),
        _s('a2', root: 'a', parent: 'a', at: 4),
        _s('c', branchedFrom: 'a', at: 5),
      ]);
      expect(_ids(rows), ['a2', 'c']);
      expect(rows[1].depth, 1);
    });

    test('a child never nests under its own lineage', () {
      final rows = flattenSessionsWithBranches([
        _s('a', root: 'r', at: 5),
        _s('b', root: 'r', branchedFrom: 'a', at: 4),
      ]);
      expect(rows.length, 1);
      expect(rows.single.depth, 0);
    });

    test('parent cycles terminate and nothing is dropped', () {
      final rows = flattenSessionsWithBranches([
        _s('a', branchedFrom: 'b', at: 1),
        _s('b', branchedFrom: 'a', at: 2),
        _s('self', branchedFrom: 'self', at: 3),
      ]);
      expect(_ids(rows).toSet(), {'a', 'b', 'self'});
      expect(rows.length, 3);
    });

    test('an unknown parent leaves the row at the root', () {
      final rows = flattenSessionsWithBranches([
        _s('a', branchedFrom: 'missing'),
      ]);
      expect(rows.single.depth, 0);
    });
  });

  group('branchFamily', () {
    final all = [
      _s('root', at: 1),
      _s('k1', branchedFrom: 'root', at: 2),
      _s('k2', branchedFrom: 'k1', at: 3),
      _s('other', at: 4),
    ];
    test('is the root of the tapped session and all its descendants', () {
      expect(branchFamily(all, 'k2').map((e) => e.id).toSet(), {
        'root',
        'k1',
        'k2',
      });
    });
    test('a lone session has a family of one', () {
      expect(branchFamily(all, 'other').length, 1);
    });
    test('an unknown id has no family', () {
      expect(branchFamily(all, 'nope'), isEmpty);
    });
  });
}
