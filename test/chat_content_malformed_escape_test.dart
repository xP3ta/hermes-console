// ARTCAUSA: «Artefactos» went blank on the Fold with a FormatException.
// Dart throws it, not ArgumentError, for a percent escape that is not
// UTF-8, and the extractor caught only ArgumentError. Desktop catches every
// error there (`decodeURIComponent` throws URIError): an undecodable
// `#media:` href is no media, and a URL with such an escape is still a URL,
// labelled by its undecoded last segment (`new URL(value).pathname`).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/agent_preview_extractor.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';

import 'support/malformed_artifact_rows.dart';

void main() {
  group('Dart throws FormatException on escapes that are not UTF-8', () {
    for (final escape in ['%FF', '%C3', '%E2%80']) {
      test(escape, () {
        expect(() => Uri.decodeComponent(escape), throwsFormatException);
        expect(() => Uri.decodeFull('/a/$escape'), throwsFormatException);
        // `Uri.tryParse` accepts it; `pathSegments` decodes, and throws.
        final uri = Uri.tryParse('https://x/$escape');
        expect(uri, isNotNull);
        expect(() => uri!.pathSegments, throwsFormatException);
      });
    }
  });

  test('the good artifacts come out beside the malformed escapes', () {
    final newestFirst = malformedArtifactRows().reversed.toList();
    late List<ChatContentItem> items;
    expect(() => items = collectChatContent(newestFirst), returnsNormally);
    expect(items.map((i) => i.value), [
      '/out/notas.txt',
      'file:///a/%FF.png',
      'https://x/%E2%80',
      '/out/informe.pdf',
      'https://example.com/docs/uno',
    ]);
    expect(
      collectChatContentChronological(newestFirst).map((i) => i.value),
      containsAllInOrder(malformedRowsGoodValues),
    );

    final byValue = {for (final item in items) item.value: item};
    expect(byValue['https://example.com/docs/uno']!.label, 'uno');
    expect(byValue['/out/informe.pdf']!.label, 'informe.pdf');
    expect(byValue['/out/notas.txt']!.label, 'notas.txt');
    // Desktop's undecoded `pathname` segment.
    expect(byValue['https://x/%E2%80']!.label, '%E2%80');
    expect(byValue['https://x/%E2%80']!.kind, ChatContentKind.link);
    expect(byValue['file:///a/%FF.png']!.label, '%FF.png');
    expect(byValue['file:///a/%FF.png']!.kind, ChatContentKind.image);
    expect(byValue['file:///a/%FF.png']!.href, 'file:///a/%FF.png');
  });

  test('an undecodable #media: href on a tool key is no media', () {
    final newestFirst = <Map<String, dynamic>>[
      {
        'role': 'tool',
        'tool_name': 'image_generate',
        'content': {'media_tag': '#media:%C3', 'output_path': '/out/a.png'},
      },
    ];
    late List<ChatContentItem> items;
    expect(() => items = collectChatContent(newestFirst), returnsNormally);
    expect(items.map((i) => i.value), ['/out/a.png']);
  });

  test('a Windows path Windows refuses keeps its value as href', () {
    final items = collectChatContent([
      {'role': 'assistant', 'content': r'MEDIA:C:\out\a|b.pdf'},
    ]);
    expect(items.map((i) => (i.value, i.href)), [
      (r'C:\out\a|b.pdf', r'C:\out\a|b.pdf'),
    ]);
  });

  test('a preview of a file URL with %FF is no preview, the rest stay', () {
    Map<String, dynamic> open(String url) => {
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        {
          'function': {
            'name': agentPreviewToolName,
            'arguments': '{"action":"open","url":"$url"}',
          },
        },
      ],
    };
    final newestFirst = [
      open('https://example.com/app'),
      open('file:///a/%FF.png'),
    ];
    late List<AgentPreview> previews;
    expect(() => previews = collectAgentPreviews(newestFirst), returnsNormally);
    expect(previews.map((p) => p.target.url), ['https://example.com/app']);
  });
}
