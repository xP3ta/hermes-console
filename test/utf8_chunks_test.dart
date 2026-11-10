// UTF-8 that arrives in pieces (an SSH shell's output): a character split
// between pieces comes out whole, invalid bytes still give one U+FFFD,
// closing flushes, and nothing is lost or doubled.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/utf8_chunks.dart';

const _replacement = '�';

/// Decodes [pieces] with one decoder, closed at the end.
String _decode(List<List<int>> pieces) {
  final out = StringBuffer();
  final decoder = Utf8ChunkDecoder(out.write);
  for (final piece in pieces) {
    decoder.add(piece);
  }
  decoder.close();
  return out.toString();
}

/// Every way to cut [bytes] into two pieces, then into three.
Iterable<List<List<int>>> _cuts(List<int> bytes) sync* {
  for (var i = 1; i < bytes.length; i++) {
    yield [bytes.sublist(0, i), bytes.sublist(i)];
  }
  for (var i = 1; i < bytes.length; i++) {
    for (var j = i + 1; j < bytes.length; j++) {
      yield [bytes.sublist(0, i), bytes.sublist(i, j), bytes.sublist(j)];
    }
  }
}

/// [bytes] in pieces of [sizes], taken in turn.
List<List<int>> _pieces(List<int> bytes, List<int> sizes) {
  final pieces = <List<int>>[];
  var at = 0;
  for (var k = 0; at < bytes.length; k++) {
    final end = math.min(at + sizes[k % sizes.length], bytes.length);
    pieces.add(bytes.sublist(at, end));
    at = end;
  }
  return pieces;
}

void main() {
  for (final (name, text) in [
    ('2-byte', 'añb'),
    ('3-byte', 'a€b'),
    ('4-byte', 'a😀b'),
    ('emoji with ZWJ', 'a👩‍👩‍👧b'),
  ]) {
    test('a $name character cut anywhere comes out whole', () {
      final bytes = utf8.encode(text);
      for (final pieces in _cuts(bytes)) {
        expect(_decode(pieces), text, reason: '$pieces');
      }
    });
  }

  test('invalid bytes still give one U+FFFD, wherever they are cut', () {
    for (final pieces in _cuts([0x61, 0xFF, 0x62])) {
      expect(_decode(pieces), 'a${_replacement}b', reason: '$pieces');
    }
    // A sequence that stops short, then plain text: one U+FFFD for it.
    for (final pieces in _cuts([0xE2, 0x82, 0x41])) {
      expect(_decode(pieces), '${_replacement}A', reason: '$pieces');
    }
  });

  test('closing with a character half-way flushes one U+FFFD', () {
    final out = StringBuffer();
    final decoder = Utf8ChunkDecoder(out.write)
      ..add(utf8.encode('ok'))
      ..add([0xE2, 0x82]);
    // Nothing yet: the rest of the character may still arrive.
    expect(out.toString(), 'ok');
    decoder.close();
    expect(out.toString(), 'ok$_replacement');
    expect(decoder.isClosed, isTrue);
    // Once closed, nothing more is decoded and nothing is written twice.
    decoder
      ..add([0xAC])
      ..close();
    expect(out.toString(), 'ok$_replacement');
  });

  test('a long mixed text in uneven pieces: nothing lost or doubled', () {
    final text = List.filled(40, 'ñ€😀 a👩‍👩‍👧 línea\n').join();
    final bytes = utf8.encode(text);
    for (final sizes in [
      [1],
      [2],
      [3],
      [5],
      [7],
      [1, 2, 3, 4, 5, 6, 7],
    ]) {
      final out = <String>[];
      final decoder = Utf8ChunkDecoder(out.add);
      _pieces(bytes, sizes).forEach(decoder.add);
      decoder.close();
      expect(out.join(), text, reason: 'pieces of $sizes');
      expect(out, everyElement(isNotEmpty));
      expect(out.join(), isNot(contains(_replacement)));
    }
  });
}
