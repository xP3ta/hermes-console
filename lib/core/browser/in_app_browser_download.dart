import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../widgets/artifact_viewer/pdf_document_view.dart';
import 'in_app_browser_policy.dart';

/// What an address the WebView refused to draw turned out to be.
///
/// Android's WebView does not paint a PDF, an archive or an office file: it
/// reports them as a download and never says the load ended (issue #232).
enum InAppBrowserDownloadKind {
  /// A PDF small enough for the app's own viewer: [bytes] holds it.
  pdf,

  /// A web page after all (a redirect back to the same address): the
  /// WebView may be asked once more.
  page,

  /// Anything else: it cannot be shown here.
  other,
}

final class InAppBrowserDownloadProbe {
  const InAppBrowserDownloadProbe(this.kind, {this.bytes});

  final InAppBrowserDownloadKind kind;
  final Uint8List? bytes;
}

/// Looks at what [uri] serves, the way the WebView just asked for it: one
/// plain GET, no Hermes credential and no cookie, `http`/`https` only.
/// A PDF is read whole (up to the viewer's limit); anything else is dropped
/// after its headers.
typedef InAppBrowserDownloadProber =
    Future<InAppBrowserDownloadProbe> Function(Uri uri);

const Duration _headerDeadline = Duration(seconds: 15);
const Duration _bodyIdle = Duration(seconds: 15);
const int _maxRedirects = 5;

Future<InAppBrowserDownloadProbe> probeInAppBrowserDownload(
  Uri uri, {
  http.Client? client,
}) async {
  const other = InAppBrowserDownloadProbe(InAppBrowserDownloadKind.other);
  final own = client == null;
  final http.Client transport = client ?? http.Client();
  try {
    var current = uri;
    http.StreamedResponse? response;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (!isBrowsableWebUri(current)) return other;
      final request = http.Request('GET', current)..followRedirects = false;
      final answer = await transport.send(request).timeout(_headerDeadline);
      // By status, not `isRedirect`: that is only set by the dart:io client.
      if (!const {301, 302, 303, 307, 308}.contains(answer.statusCode)) {
        response = answer;
        break;
      }
      final location = answer.headers['location'];
      await answer.stream.listen((_) {}).cancel();
      if (location == null || location.trim().isEmpty) return other;
      current = current.resolve(location.trim());
    }
    if (response == null) return other;
    Future<void> drop() => response!.stream.listen((_) {}).cancel();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await drop();
      return other;
    }
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    final attachment = (response.headers['content-disposition'] ?? '')
        .toLowerCase()
        .startsWith('attachment');
    if (!attachment &&
        (type.startsWith('text/html') ||
            type.startsWith('application/xhtml+xml'))) {
      await drop();
      return const InAppBrowserDownloadProbe(InAppBrowserDownloadKind.page);
    }
    final named = current.path.toLowerCase().endsWith('.pdf');
    if (!type.startsWith('application/pdf') && !named) {
      await drop();
      return other;
    }
    final declared = response.contentLength;
    if (declared != null && declared > PdfDocumentView.maxBytes) {
      await drop();
      return other;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(_bodyIdle)) {
      if (builder.length + chunk.length > PdfDocumentView.maxBytes) {
        return other;
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (!_looksLikePdf(bytes)) return other;
    return InAppBrowserDownloadProbe(
      InAppBrowserDownloadKind.pdf,
      bytes: bytes,
    );
  } on TimeoutException {
    return other;
  } on IOException {
    return other;
  } on http.ClientException {
    return other;
  } on FormatException {
    return other;
  } on ArgumentError {
    return other;
  } finally {
    if (own) transport.close();
  }
}

/// `%PDF-` within the first kilobyte, as readers accept it.
bool _looksLikePdf(Uint8List bytes) {
  const magic = [0x25, 0x50, 0x44, 0x46, 0x2d];
  final end = bytes.length < 1024 ? bytes.length : 1024;
  for (var at = 0; at + magic.length <= end; at++) {
    var match = true;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
