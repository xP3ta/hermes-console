import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/agent_preview_extractor.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';

/// A chat's transcript is not the raw rows: it goes through
/// [coalesceAssistantTurnsNewestFirst], which keeps no tool arguments.
List<Map<String, dynamic>> _loaded(List<Map<String, dynamic>> chronological) =>
    coalesceAssistantTurnsNewestFirst(chronological.reversed);

Map<String, dynamic> _assistant(String id, String name, Object arguments) => {
  'role': 'assistant',
  'content': '',
  'tool_calls': [
    {
      'id': id,
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(arguments)},
    },
  ],
};

Map<String, dynamic> _result(String id, String name) => {
  'role': 'tool',
  'tool_call_id': id,
  'tool_name': name,
  'content': '{"ok":true}',
};

void main() {
  test('a loaded transcript still tells what the agent opened and closed', () {
    final transcript = _loaded([
      {'role': 'user', 'content': 'enséñame la web'},
      _assistant('c1', 'desktop_preview', {
        'action': 'open',
        'url': 'https://example.com/a',
        'label': 'Demo',
      }),
      _result('c1', 'desktop_preview'),
      _assistant('c2', 'desktop_preview', {
        'action': 'open',
        'url': 'https://example.com/b',
      }),
      _result('c2', 'desktop_preview'),
      _assistant('c3', 'desktop_preview', {
        'action': 'close',
        'url': 'https://example.com/a',
      }),
      _result('c3', 'desktop_preview'),
    ]);

    final previews = collectAgentPreviews(transcript);

    expect(previews.map((p) => p.target.url), ['https://example.com/b']);
  });

  test('the deferred tool bridge keeps a wrapped preview', () {
    final transcript = _loaded([
      _assistant('c1', 'tool_call', {
        'calls': [
          {
            'name': 'desktop_preview',
            'arguments': {
              'action': 'open',
              'url': 'https://example.com/w',
              'label': 'Wrapped',
            },
          },
        ],
      }),
      _result('c1', 'tool_call'),
    ]);

    final previews = collectAgentPreviews(transcript);

    expect(previews.single.label, 'Wrapped');
  });

  test('no other tool keeps its arguments in the loaded transcript', () {
    final transcript = _loaded([
      _assistant('c1', 'read_file', {'path': '/home/user/secret-notes.txt'}),
      _result('c1', 'read_file'),
      _assistant('c2', 'desktop_preview', {
        'action': 'open',
        'url': 'https://example.com/a',
        'cookie': 'session=abc123',
      }),
      _result('c2', 'desktop_preview'),
    ]);

    final dump = jsonEncode(transcript);

    expect(dump, isNot(contains('secret-notes')));
    expect(dump, isNot(contains('abc123')), reason: 'only action, url, label');
    expect(dump, contains('https://example.com/a'));
  });

  test('a wrapped preview keeps only action, url and label too', () {
    final transcript = _loaded([
      _assistant('c1', 'tool_call', {
        'calls': [
          {
            'name': 'desktop_preview',
            'arguments': {
              'action': 'open',
              'url': 'https://example.com/w',
              'label': 'Wrapped',
              'cookie': 'session=wrapped-secret',
              'token': 'tok-wrapped-secret',
            },
          },
          {
            'name': 'read_file',
            'arguments': {'path': '/home/user/wrapped-notes.txt'},
          },
        ],
      }),
      _result('c1', 'tool_call'),
    ]);

    final calls = jsonEncode(transcript.single['tool_calls']);

    expect(collectAgentPreviews(transcript).single.label, 'Wrapped');
    expect(jsonEncode(transcript), isNot(contains('wrapped-secret')));
    expect(calls, isNot(contains('/home/user/wrapped-notes.txt')));
  });

  test('the size bound counts UTF-8 bytes, not characters', () {
    // 2000 emoji are 4000 UTF-16 units but 8000 bytes.
    final transcript = _loaded([
      _assistant('c1', 'desktop_preview', {
        'action': 'open',
        'url': 'https://example.com/a',
        'label': '😀' * 2000,
      }),
      _result('c1', 'desktop_preview'),
    ]);

    expect(collectAgentPreviews(transcript), isEmpty);
    expect(utf8.encode(jsonEncode(transcript)).length, lessThan(5000));
  });

  test('a malformed close survives loading as a malformed close', () {
    for (final bad in <Object>[
      42,
      1.5,
      true,
      ['x'],
      {'a': 1},
    ]) {
      final transcript = _loaded([
        _assistant('c1', 'desktop_preview', {
          'action': 'open',
          'url': 'https://example.com/a',
        }),
        _result('c1', 'desktop_preview'),
        _assistant('c2', 'desktop_preview', {'action': 'close', 'url': bad}),
        _result('c2', 'desktop_preview'),
      ]);

      expect(collectAgentPreviews(transcript).map((p) => p.target.url), [
        'https://example.com/a',
      ], reason: 'a close with url: $bad must not become close-all');
    }
  });

  test('a wrapped malformed close of any type is dropped, not close-all', () {
    for (final bad in <Object>[
      42,
      1.5,
      true,
      ['x'],
      {'a': 1},
    ]) {
      final transcript = _loaded([
        _assistant('c1', 'desktop_preview', {
          'action': 'open',
          'url': 'https://example.com/a',
        }),
        _result('c1', 'desktop_preview'),
        _assistant('c2', 'tool_call', {
          'calls': [
            {
              'name': 'desktop_preview',
              'arguments': {'action': 'close', 'url': bad},
            },
          ],
        }),
        _result('c2', 'tool_call'),
      ]);

      expect(collectAgentPreviews(transcript).map((p) => p.target.url), [
        'https://example.com/a',
      ], reason: 'wrapped close with url: $bad');
    }
  });

  test('a wrapped malformed close is dropped too, keeping the others', () {
    final transcript = _loaded([
      _assistant('c1', 'desktop_preview', {
        'action': 'open',
        'url': 'https://example.com/a',
      }),
      _result('c1', 'desktop_preview'),
      _assistant('c2', 'tool_call', {
        'calls': [
          {
            'name': 'desktop_preview',
            'arguments': {'action': 'close', 'url': 42},
          },
          {
            'name': 'desktop_preview',
            'arguments': {'action': 'open', 'url': 'https://example.com/b'},
          },
        ],
      }),
      _result('c2', 'tool_call'),
    ]);

    expect(collectAgentPreviews(transcript).map((p) => p.target.url), [
      'https://example.com/a',
      'https://example.com/b',
    ]);
  });

  test('a close without a url still closes everything after loading', () {
    for (final close in <Map<String, Object?>>[
      {'action': 'close'},
      {'action': 'close', 'url': null},
      {'action': 'close', 'url': ''},
    ]) {
      final transcript = _loaded([
        _assistant('c1', 'desktop_preview', {
          'action': 'open',
          'url': 'https://example.com/a',
        }),
        _result('c1', 'desktop_preview'),
        _assistant('c2', 'desktop_preview', close),
        _result('c2', 'desktop_preview'),
      ]);

      expect(collectAgentPreviews(transcript), isEmpty, reason: '$close');
    }
  });

  test('an oversized argument blob is dropped, not kept', () {
    final transcript = _loaded([
      _assistant('c1', 'desktop_preview', {
        'action': 'open',
        'url': 'https://example.com/a',
        'label': 'x' * 20000,
      }),
      _result('c1', 'desktop_preview'),
    ]);

    expect(collectAgentPreviews(transcript), isEmpty);
    expect(jsonEncode(transcript).length, lessThan(5000));
  });
}
