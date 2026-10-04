import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/agent_preview_extractor.dart';
import 'package:hermes_android/core/services/agent_preview_target.dart';

AgentPreviewReach? _reach(String raw) => classifyAgentPreviewTarget(raw)?.reach;

Map<String, dynamic> _assistant(List<Map<String, dynamic>> calls) => {
  'role': 'assistant',
  'content': '',
  'tool_calls': calls,
};

Map<String, dynamic> _call(
  Object? arguments, {
  String name = 'desktop_preview',
  String id = 'c1',
}) => {
  'id': id,
  'type': 'function',
  'function': {
    'name': name,
    'arguments': arguments is String ? arguments : jsonEncode(arguments),
  },
};

Map<String, dynamic> _open(String url, {String? label}) => _assistant([
  _call({'action': 'open', 'url': url, 'label': label}),
]);

Map<String, dynamic> _close([String? url]) => _assistant([
  _call({'action': 'close', 'url': url}),
]);

List<String> _urls(List<Map<String, dynamic>> chronological) => [
  for (final p in collectAgentPreviews(chronological.reversed.toList()))
    p.target.url,
];

void main() {
  group('classification', () {
    const cases = <String, AgentPreviewReach?>{
      // Public web.
      'https://example.com/app': AgentPreviewReach.web,
      'http://example.com': AgentPreviewReach.web,
      'www.example.com': AgentPreviewReach.web,
      'example.com/docs?q=1': AgentPreviewReach.web,
      'https://93.184.216.34/x': AgentPreviewReach.web,
      // The agent's own machine or private networks: never opened.
      'localhost:3000': AgentPreviewReach.serverOnly,
      'http://localhost': AgentPreviewReach.serverOnly,
      'http://app.localhost:8080': AgentPreviewReach.serverOnly,
      'http://127.0.0.1:5173': AgentPreviewReach.serverOnly,
      'http://127.1.2.3': AgentPreviewReach.serverOnly,
      'http://0.0.0.0:8000': AgentPreviewReach.serverOnly,
      'http://[::1]:3000/': AgentPreviewReach.serverOnly,
      'http://[::]:3000/': AgentPreviewReach.serverOnly,
      'http://10.0.0.5': AgentPreviewReach.serverOnly,
      'http://172.16.0.1': AgentPreviewReach.serverOnly,
      'http://172.31.255.255': AgentPreviewReach.serverOnly,
      'http://192.168.1.20:3000': AgentPreviewReach.serverOnly,
      'http://169.254.169.254/latest': AgentPreviewReach.serverOnly,
      'http://100.64.0.1': AgentPreviewReach.serverOnly,
      'http://[fd00::1]/': AgentPreviewReach.serverOnly,
      'http://[fe80::1]/': AgentPreviewReach.serverOnly,
      'http://[::ffff:127.0.0.1]/': AgentPreviewReach.serverOnly,
      'http://2130706433/': AgentPreviewReach.serverOnly,
      'http://intranet/': AgentPreviewReach.serverOnly,
      'http://printer.local/': AgentPreviewReach.serverOnly,
      'http://box.tail1234.ts.net/': AgentPreviewReach.serverOnly,
      // The same private addresses written the way a browser still reads
      // them: octal, hex and zero-padded octets, expanded or hex IPv6.
      'http://0177.0.0.1': AgentPreviewReach.serverOnly,
      'http://012.0.0.1': AgentPreviewReach.serverOnly,
      'http://0x7f.0.0.1': AgentPreviewReach.serverOnly,
      'http://0xc0.0xa8.1.1': AgentPreviewReach.serverOnly,
      'http://[0:0:0:0:0:0:0:1]/': AgentPreviewReach.serverOnly,
      'http://[0000:0000:0000:0000:0000:0000:0000:0001]/':
          AgentPreviewReach.serverOnly,
      'http://[0:0:0:0:0:0:0:0]/': AgentPreviewReach.serverOnly,
      'http://[::ffff:7f00:1]/': AgentPreviewReach.serverOnly,
      'http://[::ffff:c0a8:101]/': AgentPreviewReach.serverOnly,
      'http://[0:0:0:0:0:ffff:7f00:1]/': AgentPreviewReach.serverOnly,
      'http://[::127.0.0.1]/': AgentPreviewReach.serverOnly,
      'http://[64:ff9b::7f00:1]/': AgentPreviewReach.serverOnly,
      'http://[2002:7f00:1::]/': AgentPreviewReach.serverOnly,
      'http://[fc00::1]/': AgentPreviewReach.serverOnly,
      'http://[ff02::1]/': AgentPreviewReach.serverOnly,
      // Public addresses in the same notations stay public.
      'http://[::ffff:808:808]/': AgentPreviewReach.web,
      'http://[2606:4700:4700::1111]/': AgentPreviewReach.web,
      'http://8.8.8.8/': AgentPreviewReach.web,
      // Just outside the private ranges.
      'http://172.32.0.1': AgentPreviewReach.web,
      'http://100.128.0.1': AgentPreviewReach.web,
      'http://192.169.1.1': AgentPreviewReach.web,
      // Server files.
      '/home/user/site/index.html': AgentPreviewReach.serverFile,
      'file:///home/user/site/index.html': AgentPreviewReach.serverFile,
      '~/site/index.html': AgentPreviewReach.serverFile,
      // A decoded NUL or newline hides a different path.
      'file:///srv/a%00b.html': null,
      'file:///srv/a%0Ab.html': null,
      // Not previews at all.
      '': null,
      '   ': null,
      'javascript:alert(1)': null,
      'data:text/html,<b>x</b>': null,
      'ftp://example.com/a': null,
      // Credentials in the URL are never carried into a tile or a launch.
      'https://user:pw@example.com/': null,
      'http://good.example@127.0.0.1/': null,
      'mailto:a@example.com': null,
    };
    for (final entry in cases.entries) {
      test('${entry.key.isEmpty ? '(empty)' : entry.key} → ${entry.value}', () {
        expect(_reach(entry.key), entry.value);
      });
    }

    test('one identity for scheme, host and port spelled differently', () {
      expect(
        classifyAgentPreviewTarget('HTTP://Example.COM:80/a')!.url,
        'http://example.com/a',
      );
      expect(
        classifyAgentPreviewTarget('https://EXAMPLE.com:443')!.url,
        'https://example.com/',
      );
      expect(
        classifyAgentPreviewTarget('https://example.com:8443/a?x=1')!.url,
        'https://example.com:8443/a?x=1',
      );
      expect(
        classifyAgentPreviewTarget('http://[::1]:3000/')!.url,
        'http://[::1]:3000/',
      );
    });

    test('an empty path and the root are one identity', () {
      for (final raw in [
        'https://example.com',
        'https://example.com/',
        'HTTPS://Example.com:443',
        'example.com',
        'example.com/',
      ]) {
        expect(classifyAgentPreviewTarget(raw)!.url, 'https://example.com/');
      }
      // The query keeps its own identity.
      expect(
        classifyAgentPreviewTarget('https://example.com?a=1')!.url,
        'https://example.com/?a=1',
      );
    });

    test('the empty path and the root stay one identity with a fragment', () {
      for (final raw in [
        'https://example.com#x',
        'https://example.com/#x',
        'example.com#x',
        'HTTPS://Example.com:443#x',
      ]) {
        expect(classifyAgentPreviewTarget(raw)!.url, 'https://example.com/#x');
      }
      expect(
        classifyAgentPreviewTarget('https://example.com?a=1#x')!.url,
        'https://example.com/?a=1#x',
      );
    });

    test('normalizes like the tool', () {
      expect(
        classifyAgentPreviewTarget('www.example.com')!.url,
        'https://www.example.com/',
      );
      expect(
        classifyAgentPreviewTarget('localhost:3000')!.url,
        'http://localhost:3000/',
      );
      expect(classifyAgentPreviewTarget('  /srv/a.html ')!.url, '/srv/a.html');
      final file = classifyAgentPreviewTarget('file:///srv/a%20b.html')!;
      expect(file.filePath, '/srv/a b.html');
    });
  });

  group('replaying desktop_preview from the transcript', () {
    test('open adds the target with its label, in order', () {
      final previews = collectAgentPreviews([
        _open('https://example.com/b', label: 'Second'),
        _open('https://example.com/a', label: 'First'),
      ]);
      expect(
        [for (final p in previews) p.target.url],
        ['https://example.com/a', 'https://example.com/b'],
      );
      expect([for (final p in previews) p.label], ['First', 'Second']);
    });

    test('a missing or null label falls back to the host or file name', () {
      final previews = collectAgentPreviews([
        _open('/srv/site/index.html', label: null),
        _open('https://www.example.com/x'),
      ]);
      expect(
        [for (final p in previews) p.label],
        ['example.com', 'index.html'],
      );
    });

    test('close removes one target; close with no url removes all', () {
      expect(
        _urls([
          _open('https://example.com/a'),
          _open('https://example.com/b'),
          _close('https://example.com/a'),
        ]),
        ['https://example.com/b'],
      );
      expect(
        _urls([
          _open('https://example.com/a'),
          _open('https://example.com/b'),
          _close(),
          _open('https://example.com/c'),
        ]),
        ['https://example.com/c'],
      );
      expect(
        _urls([
          _open('https://example.com/a'),
          _assistant([
            _call({'action': 'close', 'url': ''}),
          ]),
        ]),
        isEmpty,
      );
    });

    test(
      'close with the root spelled with or without a slash finds its open',
      () {
        expect(
          _urls([_open('https://example.com'), _close('https://example.com/')]),
          isEmpty,
        );
        expect(
          _urls([_open('https://example.com/'), _close('https://example.com')]),
          isEmpty,
        );
        expect(
          _urls([_open('https://example.com'), _open('https://example.com/')]),
          ['https://example.com/'],
        );
      },
    );

    test('open and close with a fragment find each other either way', () {
      expect(
        _urls([
          _open('https://example.com#x'),
          _close('https://example.com/#x'),
        ]),
        isEmpty,
      );
      expect(
        _urls([
          _open('https://example.com/#x'),
          _close('https://example.com#x'),
        ]),
        isEmpty,
      );
      expect(
        _urls([
          _open('https://example.com#x'),
          _open('https://example.com/#x'),
        ]),
        ['https://example.com/#x'],
      );
    });

    test('close matches an open written with another scheme or port form', () {
      expect(
        _urls([
          _open('https://example.com/a'),
          _open('http://example.com:8080/b'),
          _close('HTTPS://EXAMPLE.com:443/a'),
        ]),
        ['http://example.com:8080/b'],
      );
    });

    test('a close whose url has the wrong type is ignored, not close-all', () {
      for (final bad in <Object>[
        42,
        true,
        1.5,
        ['x'],
        {'a': 1},
      ]) {
        expect(
          _urls([
            _open('https://example.com/a'),
            _assistant([
              _call({'action': 'close', 'url': bad}),
            ]),
          ]),
          ['https://example.com/a'],
          reason: '$bad',
        );
      }
      // Absent, null or empty still mean every preview.
      for (final all in <Map<String, Object?>>[
        {'action': 'close'},
        {'action': 'close', 'url': null},
        {'action': 'close', 'url': '  '},
      ]) {
        expect(
          _urls([
            _open('https://example.com/a'),
            _assistant([_call(all)]),
          ]),
          isEmpty,
          reason: '$all',
        );
      }
    });

    test(
      'transcript order decides: a later open survives an earlier close',
      () {
        expect(
          _urls([
            _close('https://example.com/a'),
            _open('https://example.com/a'),
          ]),
          ['https://example.com/a'],
        );
      },
    );

    test('opening the same target twice lists it once', () {
      expect(
        _urls([
          _open('https://example.com/a'),
          _open('example.com/a'),
          _open('https://example.com/a'),
        ]),
        ['https://example.com/a'],
      );
    });

    test('unwraps the deferred tool bridge', () {
      final wrapped = _assistant([
        _call({
          'calls': [
            {
              'name': 'desktop_preview',
              'arguments': {
                'action': 'open',
                'url': 'https://example.com/w',
                'label': 'Wrapped',
              },
            },
            {
              'name': 'read_file',
              'arguments': {'path': '/x'},
            },
          ],
        }, name: 'tool_call'),
      ]);
      final previews = collectAgentPreviews([wrapped]);
      expect(previews.single.target.url, 'https://example.com/w');
      expect(previews.single.label, 'Wrapped');
    });

    test('null, odd or unrelated arguments never break the replay', () {
      final rows = <Map<String, dynamic>>[
        _assistant([_call('not json')]),
        _assistant([_call(null)]),
        _assistant([
          _call({'action': null, 'url': null, 'label': null}),
        ]),
        _assistant([
          _call({'action': 'open', 'url': 42}),
        ]),
        _assistant([
          _call({'action': 'open', 'url': 'javascript:alert(1)'}),
        ]),
        _assistant([
          _call({'action': 'read', 'start': 0, 'count': 5}),
        ]),
        _assistant([
          _call({'action': 'open', 'url': 'https://example.com/ok'}),
        ]),
        {'role': 'assistant', 'content': 'hi', 'tool_calls': null},
        {'role': 'user', 'content': 'hola'},
        {'role': 'tool', 'content': 'ignored'},
        _assistant([
          _call({'url': 'https://example.com/noaction'}, name: 'other'),
        ]),
      ];
      expect(_urls(rows), ['https://example.com/ok']);
    });

    test('other tools and user rows never open a preview', () {
      expect(
        _urls([
          {
            'role': 'user',
            'content': 'abre https://example.com/u',
            'tool_calls': [
              _call({'action': 'open', 'url': 'https://example.com/u'}),
            ],
          },
          _assistant([
            _call({
              'action': 'open',
              'url': 'https://example.com/o',
            }, name: 'browser_open'),
          ]),
        ]),
        isEmpty,
      );
    });
  });
}
