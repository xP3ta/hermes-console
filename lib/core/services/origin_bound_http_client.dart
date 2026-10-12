// SPDX-License-Identifier: GPL-3.0-only
import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';

/// HTTP authority belongs to the caller's explicit URL, never its Location.
/// Reject all redirects (including same-origin ones) rather than contacting a
/// second recipient with stripped headers or replaying credential-bearing bodies.
/// Wrapping at send also covers BaseClient convenience and multipart requests.
class OriginBoundHttpClient extends http.BaseClient {
  OriginBoundHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final uri = request.url;
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw ArgumentError('Expected an absolute HTTP(S) URL');
    }
    TransportPrivacy.requireAllowed(uri.toString());
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
