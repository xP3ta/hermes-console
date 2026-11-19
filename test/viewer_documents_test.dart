// The documents the viewers draw themselves (a Mermaid diagram, a 3D model),
// the kinds that choose a viewer, and the Markdown links that point at files.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/artifact_viewer_kind.dart';
import 'package:hermes_android/core/utils/chat_inline_refs.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/web_preview.dart';

class _Bundle extends CachingAssetBundle {
  final List<String> asked = [];

  @override
  Future<ByteData> load(String key) async {
    asked.add(key);
    return ByteData.sublistView(Uint8List.fromList(utf8.encode('/*LIB*/')));
  }
}

void main() {
  group('viewer kinds', () {
    test('diagram sources and 3D models have their own viewers', () {
      ArtifactViewerKind kind(String name, [String mime = '']) =>
          artifactViewerKindFor(name: name, mimeType: mime);
      expect(kind('flow.mmd'), ArtifactViewerKind.mermaid);
      expect(kind('flow.mermaid'), ArtifactViewerKind.mermaid);
      expect(kind('chair.glb'), ArtifactViewerKind.model3d);
      expect(kind('scene.GLTF'), ArtifactViewerKind.model3d);
      expect(kind('x', 'model/gltf-binary'), ArtifactViewerKind.model3d);
      expect(modelMimeFor('a/b/chair.glb'), 'model/gltf-binary');
      expect(modelMimeFor('scene.gltf'), 'model/gltf+json');
      expect(modelMimeFor('mesh.stl'), isNull);
    });

    test('a sent attachment opens in the viewer unless it is a PDF, which '
        'keeps its verified page preview', () {
      for (final kind in ArtifactViewerKind.values) {
        expect(
          artifactViewerRendersInline(kind),
          kind != ArtifactViewerKind.unsupported &&
              kind != ArtifactViewerKind.pdf,
          reason: '$kind',
        );
      }
    });
  });

  group('Markdown links to files', () {
    test('a path, with or without line, is a file reference', () {
      expect(chatLinkFileRef('docs/note.md')?.path, 'docs/note.md');
      expect(chatLinkFileRef('/home/demo/a.py:12')?.line, 12);
      expect(chatLinkFileRef('a.dart:120')?.path, 'a.dart');
      expect(chatLinkFileRef('~/notes/todo.md')?.root, ChatPathRoot.home);
      expect(
        chatLinkFileRef('file:///home/demo/report.pdf')?.path,
        '/home/demo/report.pdf',
      );
      expect(
        chatLinkFileRef('/home/demo/my%20notes/a.md')?.path,
        isNull,
        reason: 'a space is not a path character in a reference',
      );
      expect(chatLinkFileRef('/home/demo/sub/')?.isFolder, isTrue);
    });

    test('web addresses, other schemes and anchors are not', () {
      for (final href in [
        null,
        '',
        '#section',
        '?q=1',
        'https://example.com/a.md',
        'http://example.com',
        'mailto:someone@example.com',
        'intent://x#Intent;end',
        'javascript:alert(1)',
        'example.com',
        'example.com/readme.md',
      ]) {
        expect(chatLinkFileRef(href), isNull, reason: '$href');
      }
    });
  });

  group('diagram document', () {
    test('inlines the packed library and denies every request', () async {
      final bundle = _Bundle();
      final html = await buildMermaidDocument(
        'graph TD; A-->B',
        dark: true,
        background: const Color(0xFF101418),
        ink: const Color(0xFFEEEEEE),
        bundle: bundle,
      );
      expect(bundle.asked, [kMermaidAsset]);
      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('/*LIB*/'));
      expect(html, contains("default-src 'none'"));
      expect(html, contains("connect-src 'none'"));
      expect(html, contains('securityLevel:"strict"'));
      expect(html, contains('theme:"dark"'));
      expect(html, contains('background:#101418'));
      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('https://')));
    });

    test('the source cannot close its script', () async {
      final html = await buildMermaidDocument(
        'graph TD; A["</script><script>alert(1)</script>"] <!-- x',
        dark: false,
        background: const Color(0xFFFFFFFF),
        ink: const Color(0xFF000000),
        bundle: _Bundle(),
      );
      expect('</script>'.allMatches(html).length, 2);
      expect(html, isNot(contains('<!-- x')));
      expect(html, contains('theme:"default"'));
    });
  });

  group('3D model document', () {
    test('embeds the model and reads nothing from the network', () async {
      final bundle = _Bundle();
      final bytes = Uint8List.fromList([0x67, 0x6C, 0x54, 0x46, 1, 2, 3]);
      final html = await buildModelDocument(
        bytes,
        mimeType: 'model/gltf-binary',
        background: const Color(0xFF000000),
        bundle: bundle,
      );
      expect(bundle.asked, [kModelViewerAsset]);
      expect(
        html,
        contains('src="data:model/gltf-binary;base64,${base64Encode(bytes)}"'),
      );
      expect(html, contains('<model-viewer '));
      expect(html, contains("default-src 'none'"));
      expect(html, contains('connect-src data: blob:'));
      expect(html, isNot(contains('https://')));
    });
  });
}
