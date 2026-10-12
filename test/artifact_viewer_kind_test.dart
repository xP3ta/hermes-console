import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/artifact_viewer_kind.dart';

void main() {
  ArtifactViewerKind kind(String name, [String mime = '']) =>
      artifactViewerKindFor(name: name, mimeType: mime);

  test('routes each artifact type to its viewer by extension', () {
    expect(kind('page.html'), ArtifactViewerKind.html);
    expect(kind('PAGE.HTM'), ArtifactViewerKind.html);
    expect(kind('diagram.svg'), ArtifactViewerKind.svg);
    expect(kind('notes.md'), ArtifactViewerKind.markdown);
    expect(kind('main.py'), ArtifactViewerKind.text);
    expect(kind('data.json'), ArtifactViewerKind.text);
    expect(kind('table.csv'), ArtifactViewerKind.text);
    expect(kind('server.log'), ArtifactViewerKind.text);
    expect(kind('photo.JPG'), ArtifactViewerKind.image);
    expect(kind('report.pdf'), ArtifactViewerKind.pdf);
    expect(kind('archive.zip'), ArtifactViewerKind.unsupported);
    expect(kind('slides.pptx'), ArtifactViewerKind.unsupported);
  });

  test('the extension wins over a generic server MIME type', () {
    expect(kind('notes.md', 'text/plain'), ArtifactViewerKind.markdown);
    expect(
      kind('page.html', 'application/octet-stream'),
      ArtifactViewerKind.html,
    );
    expect(kind('a.svg', 'text/plain'), ArtifactViewerKind.svg);
  });

  test('falls back to the MIME type when there is no known extension', () {
    expect(kind('index', 'text/html; charset=utf-8'), ArtifactViewerKind.html);
    expect(kind('drawing', 'image/svg+xml'), ArtifactViewerKind.svg);
    expect(kind('readme', 'text/markdown'), ArtifactViewerKind.markdown);
    expect(kind('payload', 'application/json'), ArtifactViewerKind.text);
    expect(kind('blob', 'image/png'), ArtifactViewerKind.image);
    expect(kind('doc', 'application/pdf'), ArtifactViewerKind.pdf);
    expect(
      kind('blob', 'application/octet-stream'),
      ArtifactViewerKind.unsupported,
    );
  });

  test('picks a highlight language for code and none for prose', () {
    String? lang(String name, [String mime = '']) =>
        artifactHighlightLanguage(name: name, mimeType: mime);
    expect(lang('a.py'), 'python');
    expect(lang('a.json'), 'json');
    expect(lang('a.yml'), 'yaml');
    expect(lang('a.ts'), 'typescript');
    expect(lang('a.txt'), isNull);
    expect(lang('a.log'), isNull);
    expect(lang('payload', 'application/json'), 'json');
  });

  test('only PDF and unknown types skip the in-app renderer', () {
    expect(artifactViewerRendersInline(ArtifactViewerKind.pdf), isFalse);
    expect(
      artifactViewerRendersInline(ArtifactViewerKind.unsupported),
      isFalse,
    );
    for (final k in [
      ArtifactViewerKind.html,
      ArtifactViewerKind.svg,
      ArtifactViewerKind.markdown,
      ArtifactViewerKind.text,
      ArtifactViewerKind.image,
    ]) {
      expect(artifactViewerRendersInline(k), isTrue, reason: '$k');
    }
  });
}
