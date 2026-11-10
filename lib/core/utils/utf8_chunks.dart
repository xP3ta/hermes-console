import 'dart:convert';

/// Decodes one stream of UTF-8 bytes that arrives in pieces, such as an
/// SSH shell's output: text is passed on as soon as each character is
/// whole, so a character split across two pieces does not come out as
/// U+FFFD. Bytes that are not valid UTF-8 still become one U+FFFD each
/// sequence. [close] flushes a character left half-way as one U+FFFD; after
/// it, nothing more is decoded.
///
/// Use one per stream: stdout and stderr must not complete each other's
/// characters.
class Utf8ChunkDecoder {
  Utf8ChunkDecoder(void Function(String text) onText)
    : _bytes = _decoder.startChunkedConversion(_TextSink(onText));

  static const _decoder = Utf8Decoder(allowMalformed: true);

  final ByteConversionSink _bytes;
  bool _closed = false;

  bool get isClosed => _closed;

  void add(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    _bytes.add(bytes);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _bytes.close();
  }
}

class _TextSink implements Sink<String> {
  _TextSink(this.onText);

  final void Function(String text) onText;

  @override
  void add(String text) {
    if (text.isNotEmpty) onText(text);
  }

  @override
  void close() {}
}
