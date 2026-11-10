// M2 (performance audit 1.4.0): a link preview reads a page only up to its
// title (at most 64 KB), and its title is parsed off the main isolate.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/link_preview_fetch.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A page served in [chunk]-byte pieces: [head] first, then filler for as
/// long as it is read. [pulled] counts every byte handed to the reader.
class _Page {
  _Page(this.head, {this.chunk = 4096, this.contentType});

  final List<int> head;
  final int chunk;
  final String? contentType;
  int pulled = 0;

  Stream<List<int>> _bytes() async* {
    for (var i = 0; i < head.length; i += chunk) {
      final piece = head.sublist(i, i + chunk > head.length ? null : i + chunk);
      pulled += piece.length;
      yield piece;
    }
    final filler = List<int>.filled(chunk, 0x61);
    for (var i = 0; i < 512; i++) {
      pulled += filler.length;
      yield filler;
    }
  }

  http.Client client() => MockClient.streaming(
    (request, _) async => http.StreamedResponse(
      _bytes(),
      200,
      headers: {'content-type': ?contentType},
    ),
  );
}

/// The cap plus what the page's generator may have run ahead: the piece
/// that crossed the cap and the one it was producing when reading stopped.
int _capped(_Page page) => kLinkPreviewMaxBytes + 2 * page.chunk;

Future<String?> _fetch(_Page page) => http.runWithClient(
  () => fetchLinkPreviewTitle(Uri.parse('https://pagina.example/articulo')),
  page.client,
);

void main() {
  final paths = <bool>[];
  setUp(() {
    paths.clear();
    debugLinkPreviewParseObserver = paths.add;
  });
  tearDown(() => debugLinkPreviewParseObserver = null);

  test('a page without a title is read only up to the cap', () async {
    final page = _Page(utf8.encode('<html><head>'));

    final title = await _fetch(page);

    expect(title, isNull);
    expect(page.pulled, lessThanOrEqualTo(_capped(page)));
    expect(page.pulled, greaterThanOrEqualTo(kLinkPreviewMaxBytes));
  });

  test('reading stops at the end of the title, parsed off the main '
      'isolate', () async {
    final page = _Page(
      utf8.encode(
        '<html><head><meta charset="utf-8"><title>\n  Canción   de\n'
        ' prueba </title></head><body>',
      ),
      contentType: 'text/html; charset=utf-8',
    );

    final title = await _fetch(page);

    expect(title, 'Canción de prueba');
    expect(page.pulled, lessThanOrEqualTo(2 * page.chunk));
    expect(paths, [true]);
  });

  test('a title split across two pieces is still found', () async {
    final head = utf8.encode('<head><title>Partido</ti');
    final page = _Page(
      [...head, ...utf8.encode('tle></head>')],
      chunk: head.length,
      contentType: 'text/html; charset=utf-8',
    );

    final title = await _fetch(page);

    expect(title, 'Partido');
    expect(page.pulled, lessThanOrEqualTo(3 * page.chunk));
  });

  test('the declared charset decodes the title, as before', () async {
    final page = _Page(
      latin1.encode('<head><title>Canción</title></head>'),
      contentType: 'text/html; charset=iso-8859-1',
    );

    expect(await _fetch(page), 'Canción');
  });

  test('a title past the cap is not looked for', () async {
    final page = _Page([
      ...List<int>.filled(kLinkPreviewMaxBytes, 0x20),
      ...utf8.encode('<title>Tarde</title>'),
    ], contentType: 'text/html; charset=utf-8');

    expect(await _fetch(page), isNull);
    expect(page.pulled, lessThanOrEqualTo(_capped(page)));
  });
}
