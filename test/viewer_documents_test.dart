// The documents the viewers draw themselves (a Mermaid diagram, a 3D model),
// the kinds that choose a viewer, and the Markdown links that point at files.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/artifact_viewer_kind.dart';
import 'package:hermes_android/core/utils/chat_inline_refs.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/web_preview.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';

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
      // Three scripts: the page's error channel, the library and the
      // drawing; none closed early by the source.
      expect('</script>'.allMatches(html).length, 3);
      expect(html, isNot(contains('<!-- x')));
      expect(html, contains('theme:"default"'));
    });
  });

  group('3D model document', () {
    // The page no longer writes the model in a `src` attribute and its
    // policy now lets decoders run (WebAssembly in `blob:` workers): the
    // test states the new page, still with nothing from the network.
    test('embeds the model, an error channel and no network', () async {
      final bundle = _Bundle();
      final bytes = _glb({'asset': {'version': '2.0'}});
      final html = await buildModelDocument(
        bytes,
        mimeType: 'model/gltf-binary',
        background: const Color(0xFF000000),
        bundle: bundle,
      );
      expect(bundle.asked, [kModelViewerAsset]);
      expect(
        html,
        contains(
          'v.src="data:model/gltf-binary;base64,${base64Encode(bytes)}"',
        ),
      );
      expect(html, contains('document.createElement("model-viewer")'));
      expect(html, contains(kPageErrorChannel));
      expect(
        html.indexOf(kPageErrorChannel),
        lessThan(html.indexOf('/*LIB*/')),
        reason: 'the channel listens before the library runs',
      );
      expect(html, contains('addEventListener("unhandledrejection"'));
      expect(html, contains('v.addEventListener("error"'));
      expect(_csp(html), contains("default-src 'none'"));
      expect(
        _csp(html),
        contains("script-src 'unsafe-inline' 'wasm-unsafe-eval';"),
      );
      expect(_csp(html), contains('connect-src data: blob:;'));
      expect(_csp(html), contains('worker-src blob:;'));
      expect(_csp(html), isNot(contains("'unsafe-eval'")));
      expect(_csp(html), isNot(contains("'wasm-unsafe-eval' blob:")));
      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('https://')));
      expect(html, contains('if(false)c.meshoptDecoderLocation'));
      // No decoder: an engine without WebAssembly still draws it.
      expect(html, contains('if(false){try{new WebAssembly.Module('));
    });

    test('a Draco model gets the packed decoder, served by the page', () async {
      final bundle = _Bundle();
      final html = await buildModelDocument(
        _glb({
          'asset': {'version': '2.0'},
          'extensionsUsed': ['KHR_draco_mesh_compression'],
          'extensionsRequired': ['KHR_draco_mesh_compression'],
        }),
        mimeType: 'model/gltf-binary',
        background: const Color(0xFF000000),
        bundle: bundle,
      );
      expect(bundle.asked, [
        kModelViewerAsset,
        kDracoWrapperAsset,
        kDracoDecoderAsset,
      ]);
      expect(html, contains('"draco/draco_wasm_wrapper.js":{"t":"text/'));
      expect(html, contains('"draco/draco_decoder.wasm":{"t":"application/'));
      expect(html, contains('c.dracoDecoderLocation=base+"draco/"'));
      // An engine that cannot run the decoder says so at once.
      expect(html, contains('if(true){try{new WebAssembly.Module('));
      expect(html, contains('__hcFail("hc:wasm")'));
      expect(html, contains('base="hc-decoder:/"'));
      expect(_csp(html), isNot(contains("'wasm-unsafe-eval' blob:")));
      expect(_csp(html), isNot(contains("'unsafe-eval'")));
    });

    test('a meshopt model switches on the bundled decoder with a blob script '
        'and nothing else', () async {
      final bundle = _Bundle();
      final html = await buildModelDocument(
        _glb({
          'asset': {'version': '2.0'},
          'extensionsUsed': [
            'EXT_meshopt_compression',
            'KHR_mesh_quantization',
          ],
        }),
        mimeType: 'model/gltf-binary',
        background: const Color(0xFF000000),
        bundle: bundle,
      );
      expect(bundle.asked, [kModelViewerAsset]);
      expect(html, contains('if(true)c.meshoptDecoderLocation'));
      expect(
        _csp(html),
        contains("script-src 'unsafe-inline' 'wasm-unsafe-eval' blob:;"),
      );
      expect(_csp(html), isNot(contains("'unsafe-eval'")));
    });

    test('only KTX2 textures add unsafe-eval (the Basis transcoder builds '
        'functions from strings)', () async {
      final bundle = _Bundle();
      final html = await buildModelDocument(
        _glb({
          'asset': {'version': '2.0'},
          'extensionsRequired': ['KHR_texture_basisu'],
        }),
        mimeType: 'model/gltf-binary',
        background: const Color(0xFF000000),
        bundle: bundle,
      );
      expect(bundle.asked, [
        kModelViewerAsset,
        kBasisTranscoderAsset,
        kBasisTranscoderWasmAsset,
      ]);
      expect(
        _csp(html),
        contains("script-src 'unsafe-inline' 'wasm-unsafe-eval' "
            "'unsafe-eval';"),
      );
      expect(html, contains('"basis/basis_transcoder.wasm"'));
    });

    test('what a file asks of the viewer is read from its glTF JSON', () {
      expect(
        readModelNeeds(_glb({'asset': {'version': '2.0'}})),
        (draco: false, meshopt: false, basis: false),
      );
      expect(
        readModelNeeds(
          utf8.encode(
            jsonEncode({
              'asset': {'version': '2.0'},
              'extensionsUsed': [
                'KHR_draco_mesh_compression',
                'KHR_meshopt_compression',
                'KHR_texture_basisu',
              ],
              'buffers': [
                {'uri': 'data:application/octet-stream;base64,AAAA'},
              ],
            }),
          ),
        ),
        (draco: true, meshopt: true, basis: true),
      );
      // A binary whose JSON cannot be read is left for the page to report.
      final cut = _glb({'asset': {'version': '2.0'}}).sublist(0, 24);
      expect(
        readModelNeeds(cut),
        (draco: false, meshopt: false, basis: false),
      );
    });

    test('an empty file, a file that is not glTF and one that points to '
        'files it did not bring are refused before any page', () async {
      Matcher problem(ModelFileProblemKind kind, [List<String>? files]) =>
          isA<ModelFileProblem>()
              .having((p) => p.kind, 'kind', kind)
              .having((p) => p.files, 'files', files ?? isEmpty);
      expect(
        () => readModelNeeds(Uint8List(0)),
        throwsA(problem(ModelFileProblemKind.empty)),
      );
      expect(
        () => readModelNeeds(Uint8List.fromList(utf8.encode('hello'))),
        throwsA(problem(ModelFileProblemKind.notGltf)),
      );
      expect(
        () => readModelNeeds(Uint8List.fromList(utf8.encode('{"a":1}'))),
        throwsA(problem(ModelFileProblemKind.notGltf)),
      );
      final external = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'asset': {'version': '2.0'},
            'buffers': [
              {'uri': 'Box0.bin', 'byteLength': 648},
            ],
            'images': [
              {'uri': 'textures/wood.png'},
            ],
          }),
        ),
      );
      expect(
        () => readModelNeeds(external),
        throwsA(
          problem(ModelFileProblemKind.externalFiles, [
            'Box0.bin',
            'textures/wood.png',
          ]),
        ),
      );
      await expectLater(
        buildModelDocument(
          external,
          mimeType: 'model/gltf+json',
          background: const Color(0xFF000000),
          bundle: _Bundle(),
        ),
        throwsA(isA<ModelFileProblem>()),
      );
    });
  });

  test('what the model page names by a code is said in words', () {
    final strings = StringsEn();
    String title(String detail) => describeWebPageFailure(
      strings,
      WebPageFailure(WebPageFailureKind.reported, detail: detail),
      model: true,
    ).title;
    expect(title('hc:wasm'), strings.vwModelNeedsWasm);
    expect(title('hc:webgl'), strings.vwModelNeedsWebGl);
    expect(title('THREE.GLTFLoader: x'), strings.vwModelFailed);
  });

  test('the diagram page reports itself drawn through the same '
      'channel', () async {
    final html = await buildMermaidDocument(
      'graph TD; A-->B',
      dark: false,
      background: const Color(0xFFFFFFFF),
      ink: const Color(0xFF000000),
      bundle: _Bundle(),
    );
    expect(html, contains(kPageErrorChannel));
    expect(html, contains('document.title="done";__hcDone();'));
    expect(
      html.indexOf(kPageErrorChannel),
      lessThan(html.indexOf('/*LIB*/')),
    );
  });
}

/// The Content-Security-Policy of [html].
String _csp(String html) {
  final match = RegExp(
    r'http-equiv="Content-Security-Policy" content="([^"]*)"',
  ).firstMatch(html);
  return match!.group(1)!;
}

/// A GLB holding [json] and no binary chunk.
Uint8List _glb(Map<String, Object?> json) {
  final text = utf8.encode(jsonEncode(json));
  final padded = (text.length + 3) & ~3;
  List<int> word(int value) => [
    for (var shift = 0; shift < 32; shift += 8) (value >> shift) & 0xFF,
  ];
  return Uint8List.fromList([
    ...word(0x46546C67), // glTF
    ...word(2),
    ...word(20 + padded),
    ...word(padded),
    ...word(0x4E4F534A), // JSON
    ...text,
    for (var i = text.length; i < padded; i++) 0x20,
  ]);
}
