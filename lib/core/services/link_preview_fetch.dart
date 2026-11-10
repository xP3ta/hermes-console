import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// M2: a link preview reads at most this much of a page. The `<title>` sits
/// in the head, so the rest of the page is never downloaded.
const int kLinkPreviewMaxBytes = 64 * 1024;

/// Test hook: observes where each title parse ran (true = off main).
@visibleForTesting
void Function(bool offMain)? debugLinkPreviewParseObserver;

final _titleEnd = ascii.encode('</title');

/// Title of the page at [uri], or null when its first
/// [kLinkPreviewMaxBytes] hold none. Reading stops at the end of the title;
/// decoding and the regex run off the main isolate.
Future<String?> fetchLinkPreviewTitle(
  Uri uri, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = 'HermesAndroid/1.0';
    final head = await () async {
      final response = await client.send(request);
      final bytes = await _readHead(response.stream);
      return (bytes: bytes, charset: _charset(response.headers));
    }().timeout(timeout);
    return await _parseOffMain(head.bytes, head.charset);
  } finally {
    client.close();
  }
}

// A top-level function so the isolate closure captures only its arguments.
Future<String?> _parseOffMain(Uint8List head, String? charset) {
  debugLinkPreviewParseObserver?.call(true);
  return Isolate.run(() => parseLinkPreviewTitle(head, charset));
}

/// The `<title>` of an HTML [head] encoded in [charset] (Latin-1 when
/// unknown, as `http.Response.body` decodes it).
@visibleForTesting
String? parseLinkPreviewTitle(Uint8List head, String? charset) {
  final encoding = charset == null ? null : Encoding.getByName(charset);
  final text = switch (encoding) {
    null => latin1.decode(head),
    final Utf8Codec _ => utf8.decode(head, allowMalformed: true),
    final Encoding other => other.decode(head),
  };
  final match = RegExp(
    r'<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(text);
  return match?.group(1)?.trim().replaceAll(RegExp(r'\s+'), ' ');
}

Future<Uint8List> _readHead(Stream<List<int>> body) async {
  final head = Uint8List(kLinkPreviewMaxBytes);
  var length = 0;
  await for (final chunk in body) {
    final take = chunk.length < head.length - length
        ? chunk.length
        : head.length - length;
    final from = length > _titleEnd.length ? length - _titleEnd.length : 0;
    head.setRange(length, length + take, chunk);
    length += take;
    if (length == head.length || _hasTitleEnd(head, from, length)) break;
  }
  return head.sublist(0, length);
}

bool _hasTitleEnd(Uint8List bytes, int from, int to) {
  outer:
  for (var i = from; i + _titleEnd.length <= to; i++) {
    for (var j = 0; j < _titleEnd.length; j++) {
      // ASCII lower-casing; the needle is all lower case.
      var byte = bytes[i + j];
      if (byte >= 0x41 && byte <= 0x5a) byte += 0x20;
      if (byte != _titleEnd[j]) continue outer;
    }
    return true;
  }
  return false;
}

String? _charset(Map<String, String> headers) {
  final type = headers['content-type'];
  if (type == null) return null;
  final match = RegExp(
    r'charset\s*=\s*"?([^";\s]+)',
    caseSensitive: false,
  ).firstMatch(type);
  return match?.group(1);
}
