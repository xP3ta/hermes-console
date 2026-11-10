// ARTCAUSA: one row of the transcript that cannot be read is left out and
// its error type logged (source `artifacts`); the other rows still list
// what they share, and the previews the other calls open stay open.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/agent_preview_extractor.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';

import 'support/malformed_artifact_rows.dart';

Map<String, dynamic> _assistant(String content) => {
  'role': 'assistant',
  'content': content,
};

Map<String, dynamic> _previewCall(String url) => {
  'function': {
    'name': agentPreviewToolName,
    'arguments': '{"action":"open","url":"$url"}',
  },
};

void main() {
  setUp(AppErrorLog.resetForTesting);
  tearDown(AppErrorLog.resetForTesting);

  test('an unreadable row is left out and logged, the rest is listed', () {
    final newestFirst = <Map<String, dynamic>>[
      _assistant('MEDIA:/out/notas.txt'),
      UnreadableRow(),
      _assistant('MEDIA:/out/informe.pdf'),
      UnreadableRow(),
      _assistant('Mira https://example.com/docs/uno'),
    ];
    late List<ChatContentItem> items;
    expect(() => items = collectChatContent(newestFirst), returnsNormally);
    expect(items.map((i) => i.value), [
      '/out/notas.txt',
      '/out/informe.pdf',
      'https://example.com/docs/uno',
    ]);
    expect(AppErrorLog.recent.map((r) => (r.source, r.errorType)), [
      ('artifacts', 'StateError'),
      ('artifacts', 'StateError'),
    ]);
  });

  test('a tool result that cannot be read keeps what its row named', () {
    // A coalesced tool result with a key that is not a string: copying it
    // to a Map<String, dynamic> throws. The text before it still counts.
    final newestFirst = <Map<String, dynamic>>[
      _assistant('MEDIA:/out/notas.txt'),
      {
        'role': 'assistant',
        'content': 'MEDIA:/out/informe.pdf',
        assistantToolResultEvidenceKey: [
          {1: 'not a string key'},
        ],
      },
      _assistant('Mira https://example.com/docs/uno'),
    ];
    late List<ChatContentItem> items;
    expect(() => items = collectChatContent(newestFirst), returnsNormally);
    expect(items.map((i) => i.value), [
      '/out/notas.txt',
      '/out/informe.pdf',
      'https://example.com/docs/uno',
    ]);
    expect(AppErrorLog.recent.map((r) => r.source), ['artifacts']);
  });

  test('an unreadable row or call does not close the other previews', () {
    final newestFirst = <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [UnreadableRow(), _previewCall('https://b.example.com')],
      },
      UnreadableRow(),
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [_previewCall('https://a.example.com')],
      },
    ];
    late List<AgentPreview> previews;
    expect(() => previews = collectAgentPreviews(newestFirst), returnsNormally);
    expect(previews.map((p) => p.target.url), [
      'https://a.example.com/',
      'https://b.example.com/',
    ]);
    expect(AppErrorLog.recent.map((r) => r.source), ['artifacts', 'artifacts']);
  });
}
