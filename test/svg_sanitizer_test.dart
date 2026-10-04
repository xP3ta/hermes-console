import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/embeds/svg_sanitizer.dart';

const _open = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">';

String? _clean(String inner) => sanitizeSvgForEmbed('$_open$inner</svg>');

void main() {
  test('a plain drawing survives untouched', () {
    final out = _clean('<rect width="4" height="4" fill="red"/>');
    expect(out, contains('<rect width="4" height="4" fill="red"/>'));
    expect(out, startsWith('<svg'));
    expect(out, endsWith('</svg>'));
  });

  test('script elements and their content are removed', () {
    final out = _clean('<script>alert(1)</script><circle r="2"/>')!;
    expect(out.toLowerCase(), isNot(contains('script')));
    expect(out, isNot(contains('alert')));
    expect(out, contains('<circle r="2"/>'));
  });

  test('event handler attributes are removed', () {
    final out = sanitizeSvgForEmbed(
      '<svg onload="steal()" xmlns="http://www.w3.org/2000/svg">'
      '<rect onclick="x()" ONMOUSEOVER="y()" width="1"/></svg>',
    )!;
    expect(out.toLowerCase(), isNot(contains('onload')));
    expect(out.toLowerCase(), isNot(contains('onclick')));
    expect(out.toLowerCase(), isNot(contains('onmouseover')));
    expect(out, contains('width="1"'));
  });

  test('foreignObject is removed with its children', () {
    final out = _clean(
      '<foreignObject><div xmlns="http://www.w3.org/1999/xhtml">hi</div>'
      '</foreignObject><rect width="1"/>',
    )!;
    expect(out.toLowerCase(), isNot(contains('foreignobject')));
    expect(out, isNot(contains('hi')));
    expect(out, contains('<rect width="1"/>'));
  });

  test('external hrefs are dropped, fragments and inline images stay', () {
    final out = _clean(
      '<use href="https://evil.example.test/a.svg#x"/>'
      '<use xlink:href="//evil.example.test/a.svg#x"/>'
      '<use href="javascript:alert(1)"/>'
      '<use href="#local"/>'
      '<image href="data:image/png;base64,AAAA"/>'
      '<image href="data:image/svg+xml;base64,AAAA"/>',
    )!;
    expect(out, isNot(contains('evil.example.test')));
    expect(out, isNot(contains('javascript')));
    expect(out, contains('href="#local"'));
    expect(out, contains('href="data:image/png;base64,AAAA"'));
    expect(out, isNot(contains('svg+xml')));
  });

  test('css url() to non-data targets is dropped', () {
    final out = _clean(
      '<rect style="fill:url(https://evil.example.test/p.png)"/>'
      '<rect fill="url(#grad)" style="fill:url(#grad)"/>'
      '<circle style="background:url(data:image/png;base64,AAAA)"/>',
    )!;
    expect(out, isNot(contains('evil.example.test')));
    expect(out, contains('fill="url(#grad)"'));
    expect(out, contains('style="fill:url(#grad)"'));
  });

  test('a style element that can fetch makes the whole svg fall back', () {
    expect(
      _clean('<style>@import url(https://evil.example.test/a.css);</style>'),
      isNull,
    );
    expect(
      _clean('<style>rect{fill:url(https://evil.example.test/a.png)}</style>'),
      isNull,
    );
    expect(
      _clean('<style>rect{fill:red}</style><rect/>'),
      contains('fill:red'),
    );
  });

  test('animations that rewrite href or handlers are removed', () {
    final out = _clean(
      '<a><set attributeName="href" to="javascript:alert(1)"/></a>'
      '<animate attributeName="onload" to="x"/>'
      '<animate attributeName="opacity" to="0"/>',
    )!;
    expect(out, isNot(contains('javascript')));
    expect(out, isNot(contains('onload')));
    expect(out, contains('attributeName="opacity"'));
  });

  test('doctype, entities and non-svg roots fall back to the code block', () {
    expect(
      sanitizeSvgForEmbed(
        '<!DOCTYPE svg [<!ENTITY x "y">]><svg xmlns="http://www.w3.org/2000/svg"/>',
      ),
      isNull,
    );
    expect(sanitizeSvgForEmbed('<html><body/></html>'), isNull);
    expect(sanitizeSvgForEmbed('just text'), isNull);
    expect(sanitizeSvgForEmbed('<svg><rect></svg>'), isNull);
    expect(sanitizeSvgForEmbed('<svg><rect/>'), isNull);
  });

  test('comments and processing instructions are stripped', () {
    final out = sanitizeSvgForEmbed(
      '<?xml version="1.0"?><!-- hi --><svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>',
    )!;
    expect(out, isNot(contains('<!--')));
    expect(out, isNot(contains('<?xml')));
  });

  test('more than 256 KB is not rendered', () {
    final big = '$_open${'<rect/>' * 40000}</svg>';
    expect(big.length, greaterThan(svgEmbedMaxBytes));
    expect(sanitizeSvgForEmbed(big), isNull);
  });

  test('attribute values cannot break out of their quotes', () {
    final out = sanitizeSvgForEmbed(
      "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect title='a\"b' width=\"1\"/></svg>",
    )!;
    expect(out, contains('title="a&quot;b"'));
  });
}
