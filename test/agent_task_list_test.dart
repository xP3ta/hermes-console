import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';

// Real-shaped payloads: `todo.updated` / `session.resume.todo_state` carry the
// full snapshot `{todos: [{id, content, status, parent?}], revision}` (see
// tui_gateway/tool_progress.py `_normalize_todo_state`).
Map<String, dynamic> _snapshot({
  int revision = 3,
  List<Map<String, dynamic>>? todos,
}) => {
  'revision': revision,
  'todos':
      todos ??
      [
        {'id': '1', 'content': 'Read the failing test', 'status': 'completed'},
        {'id': '2', 'content': 'Patch the parser', 'status': 'in_progress'},
        {
          'id': '2a',
          'content': 'Add regression test',
          'status': 'pending',
          'parent': '2',
        },
        {'id': '3', 'content': 'Try the cache flag', 'status': 'cancelled'},
        {'id': '4', 'content': 'Update the changelog', 'status': 'pending'},
      ],
};

void main() {
  group('AgentTaskList.tryParse', () {
    test('parses a real todo.updated snapshot with counts and current', () {
      final list = AgentTaskList.tryParse(_snapshot())!;
      expect(list.revision, 3);
      expect(list.items, hasLength(5));
      expect(list.items[1].status, AgentTaskStatus.inProgress);
      expect(list.items[2].parentId, '2');
      // cancelled work is not counted on either side of the fraction
      expect(list.total, 4);
      expect(list.done, 1);
      expect(list.cancelledCount, 1);
      expect(list.current?.id, '2');
      expect(list.isFinished, isFalse);
      expect(list.hasOpen, isTrue);
    });

    test('accepts the tool result as a JSON string and extra summary keys', () {
      final raw = jsonEncode({
        ..._snapshot(revision: 9),
        'summary': {'total': 5, 'pending': 2},
      });
      final list = AgentTaskList.tryParse(raw)!;
      expect(list.revision, 9);
      expect(list.items, hasLength(5));
    });

    test('rejects payloads that are not a todo snapshot', () {
      expect(AgentTaskList.tryParse(null), isNull);
      expect(AgentTaskList.tryParse(42), isNull);
      expect(AgentTaskList.tryParse('not json'), isNull);
      expect(AgentTaskList.tryParse({'revision': 1}), isNull);
      expect(AgentTaskList.tryParse({'todos': 'nope', 'revision': 1}), isNull);
      expect(AgentTaskList.tryParse('{"todos": 7}'), isNull);
    });

    test('an unused store (empty at revision 0) is not a snapshot', () {
      expect(AgentTaskList.tryParse({'todos': [], 'revision': 0}), isNull);
    });

    test('an empty list at revision >= 1 is a real clear', () {
      final list = AgentTaskList.tryParse({'todos': [], 'revision': 4})!;
      expect(list.items, isEmpty);
      expect(list.revision, 4);
      expect(list.isFinished, isFalse);
      expect(list.hasOpen, isFalse);
    });

    test(
      'unknown or missing status degrades to pending, junk items are skipped',
      () {
        final list = AgentTaskList.tryParse({
          'revision': 1,
          'todos': [
            {'id': 'a', 'content': 'Weird status', 'status': 'BLOCKED'},
            {'id': 'b', 'content': 'No status'},
            {'id': 'c', 'content': '  Upper  ', 'status': ' COMPLETED '},
            'not a map',
            {'id': '', 'content': 'No id', 'status': 'pending'},
            {'id': 'd', 'content': '   ', 'status': 'pending'},
            {'id': 'e', 'status': 'pending'},
            null,
            7,
          ],
        })!;
        expect(list.items.map((i) => i.id), ['a', 'b', 'c']);
        expect(list.items[0].status, AgentTaskStatus.pending);
        expect(list.items[1].status, AgentTaskStatus.pending);
        expect(list.items[2].status, AgentTaskStatus.completed);
        expect(list.items[2].content, 'Upper');
      },
    );

    test(
      'numeric ids are stringified and duplicates keep the last occurrence',
      () {
        final list = AgentTaskList.tryParse({
          'revision': 2,
          'todos': [
            {'id': 1, 'content': 'first', 'status': 'pending'},
            {'id': 2, 'content': 'other', 'status': 'pending'},
            {'id': '1', 'content': 'first v2', 'status': 'completed'},
          ],
        })!;
        expect(list.items.map((i) => i.id), ['2', '1']);
        expect(list.items.last.content, 'first v2');
        expect(list.items.last.status, AgentTaskStatus.completed);
      },
    );

    test('revision may be a numeric string; a missing revision is null', () {
      expect(
        AgentTaskList.tryParse({
          'todos': [_item('a')],
          'revision': '12',
        })!.revision,
        12,
      );
      expect(
        AgentTaskList.tryParse({
          'todos': [_item('a')],
        })!.revision,
        isNull,
      );
      expect(
        AgentTaskList.tryParse({
          'todos': [_item('a')],
          'revision': -3,
        })!.revision,
        isNull,
      );
    });

    test('caps items, keeps the omitted counter and caps text length', () {
      final many = [
        for (var i = 0; i < 260; i++)
          {'id': 'id$i', 'content': 'x' * 1000, 'status': 'pending'},
      ];
      final list = AgentTaskList.tryParse({'todos': many, 'revision': 1})!;
      expect(list.items, hasLength(AgentTaskList.maxItems));
      expect(list.omitted, 260 - AgentTaskList.maxItems);
      expect(
        list.items.first.content.length,
        lessThanOrEqualTo(AgentTaskList.maxContentChars),
      );
      expect(list.items.first.content.endsWith('…'), isTrue);
    });

    test('sanitises control, bidi and newline characters', () {
      final list = AgentTaskList.tryParse({
        'revision': 1,
        'todos': [
          {
            'id': 'a\u0000b',
            'content': 'line1\nline2\t\u202Eevil\u2066 end\u2028',
            'status': 'pending',
          },
        ],
      })!;
      expect(list.items.single.content, 'line1 line2 evil end');
      expect(list.items.single.id, 'ab');
    });

    test('keeps markup inert as plain text and masks secret-shaped tokens', () {
      final list = AgentTaskList.tryParse({
        'revision': 1,
        'todos': [
          {
            'id': 'a',
            'content':
                '**bold** <script>alert(1)</script> [x](javascript:1) sk-abcdefghijklmnopqrstuvwx',
            'status': 'pending',
          },
          {
            'id': 'b',
            'content':
                'deploy with api_key=hunter2secret and Bearer abcdefghijklmnop1234',
            'status': 'pending',
          },
          {
            'id': 'c',
            'content':
                'token ghp_abcdefghijklmnopqrstuvwxyz0123456789 and ${'a1' * 20}',
            'status': 'pending',
          },
        ],
      })!;
      final a = list.items[0].content;
      // markup is not interpreted anywhere (widgets render plain Text); it is
      // preserved verbatim, only the secret-shaped token is masked.
      expect(a, contains('<script>'));
      expect(a, contains('**bold**'));
      expect(a, isNot(contains('sk-abcdefghijklmnopqrstuvwx')));
      final b = list.items[1].content;
      expect(b, isNot(contains('hunter2secret')));
      expect(b, contains('api_key='));
      expect(b, isNot(contains('abcdefghijklmnop1234')));
      final c = list.items[2].content;
      expect(c, isNot(contains('ghp_')));
      expect(c, isNot(contains('a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1')));
    });

    test(
      'parent handling: self parent dropped, dangling kept as root, cycles flat',
      () {
        final list = AgentTaskList.tryParse({
          'revision': 1,
          'todos': [
            {'id': 'a', 'content': 'A', 'status': 'pending', 'parent': 'a'},
            {'id': 'b', 'content': 'B', 'status': 'pending', 'parent': 'ghost'},
            {'id': 'c', 'content': 'C', 'status': 'pending', 'parent': 'd'},
            {'id': 'd', 'content': 'D', 'status': 'pending', 'parent': 'c'},
          ],
        })!;
        expect(list.items[0].parentId, isNull);
        final rows = list.rows;
        expect(rows.map((r) => r.item.id).toSet(), {'a', 'b', 'c', 'd'});
        expect(rows.every((r) => r.depth <= 1), isTrue);
      },
    );
  });

  group('AgentTaskList derived state', () {
    test('rows are depth-first with parents before children', () {
      final list = AgentTaskList.tryParse(
        _snapshot(
          todos: [
            {'id': 'p', 'content': 'Parent', 'status': 'in_progress'},
            {'id': 'x', 'content': 'Other root', 'status': 'pending'},
            {
              'id': 'k1',
              'content': 'Kid 1',
              'status': 'pending',
              'parent': 'p',
            },
            {
              'id': 'k2',
              'content': 'Kid 2',
              'status': 'pending',
              'parent': 'p',
            },
            {
              'id': 'g',
              'content': 'Grandkid',
              'status': 'pending',
              'parent': 'k1',
            },
          ],
        ),
      )!;
      expect(list.rows.map((r) => '${r.item.id}:${r.depth}').toList(), [
        'p:0',
        'k1:1',
        'g:2',
        'k2:1',
        'x:0',
      ]);
    });

    test('finished means every item completed or cancelled', () {
      final done = AgentTaskList.tryParse(
        _snapshot(
          todos: [
            {'id': '1', 'content': 'a', 'status': 'completed'},
            {'id': '2', 'content': 'b', 'status': 'cancelled'},
          ],
        ),
      )!;
      expect(done.isFinished, isTrue);
      expect(done.hasOpen, isFalse);
      expect(done.current, isNull);
      expect(done.done, 1);
      expect(done.total, 1);
    });

    test('all cancelled has total 0 and never divides by zero', () {
      final list = AgentTaskList.tryParse(
        _snapshot(
          todos: [
            {'id': '1', 'content': 'a', 'status': 'cancelled'},
          ],
        ),
      )!;
      expect(list.total, 0);
      expect(list.progress, 0);
      expect(list.isFinished, isTrue);
    });

    test('progress is done/total over counted items', () {
      final list = AgentTaskList.tryParse(_snapshot())!;
      expect(list.progress, closeTo(0.25, 1e-9));
    });

    test('sameContentAs ignores identity but not content', () {
      final a = AgentTaskList.tryParse(_snapshot())!;
      final b = AgentTaskList.tryParse(_snapshot())!;
      expect(a.sameContentAs(b), isTrue);
      final c = AgentTaskList.tryParse(
        _snapshot(
          todos: [
            {
              'id': '1',
              'content': 'Read the failing test',
              'status': 'pending',
            },
          ],
        ),
      )!;
      expect(a.sameContentAs(c), isFalse);
    });
  });
}

Map<String, dynamic> _item(String id) => {
  'id': id,
  'content': 'Task $id',
  'status': 'pending',
};
