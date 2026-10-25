// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../bots/data/gateway_socket_meter.dart';
import '../utils/transport_privacy.dart';

/// HTTP authority belongs to the caller's explicit URL, never its Location.
/// Reject all redirects (including same-origin ones) rather than contacting a
/// second recipient with stripped headers or replaying credential-bearing bodies.
/// Wrapping at send also covers BaseClient convenience and multipart requests.
/// `timeout | transport | other`; never a URL or a body.
String classifyTransportFailure(Object error) {
  if (error is TimeoutException || error is http.RequestAbortedException) {
    return 'timeout';
  }
  if (error is SocketException ||
      error is HttpException ||
      error is HandshakeException ||
      error is http.ClientException) {
    return 'transport';
  }
  return 'other';
}

/// Applies one total deadline (headers and body) to each call, and aborts the
/// request when it expires so the socket closes instead of lingering after the
/// caller stopped waiting. Callers see a [TimeoutException]. Each failure is
/// logged once as a body-free class. Plain [http.Request]s only: multipart and
/// streamed requests keep their own limits.
class DeadlineHttpClient extends http.BaseClient {
  DeadlineHttpClient(this._inner, this._deadline);

  final http.Client _inner;
  final Duration _deadline;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) return _inner.send(request);
    final abort = Completer<void>();
    final timer = Timer(_deadline, abort.complete);
    final abortable =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: abort.future,
          )
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
    try {
      // The plain timeout only matters for a client that ignores the trigger.
      final response = await _inner.send(abortable).timeout(_deadline);
      final code = response.statusCode;
      if (code >= 400) {
        _log(code == 401 || code == 403 ? 'auth' : 'http($code)');
      }
      return http.StreamedResponse(
        // A reader that stops early (a size cap, a refused declared length)
        // ends the call too: the deadline goes with it. Events pass through
        // exactly as before; only the reader's cancel is observed.
        _CancelNotifyingStream(
          response.stream.transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleError: (error, stack, sink) {
                _log('timeout');
                sink.addError(_asTimeout(error), stack);
              },
              handleDone: (sink) {
                timer.cancel();
                sink.close();
              },
            ),
          ),
          timer.cancel,
        ),
        code,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (error) {
      timer.cancel();
      _log(classifyTransportFailure(error));
      throw _asTimeout(error);
    }
  }

  Object _asTimeout(Object error) => error is http.RequestAbortedException
      ? TimeoutException('REST deadline', _deadline)
      : error;

  /// Same sink as QA-NET: off in release and in non-QA flavors.
  void _log(String failure) {
    if (GatewaySocketMeter.instance.enabled) {
      debugPrint('[rest] failed class=$failure');
    }
  }
}

/// A body stream whose subscription also runs [_onCancel] when its reader
/// cancels it. Data, errors and done reach the reader untouched.
final class _CancelNotifyingStream<T> extends StreamView<T> {
  _CancelNotifyingStream(super.stream, this._onCancel);

  final void Function() _onCancel;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _CancelNotifyingSubscription(
    super.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    _onCancel,
  );
}

final class _CancelNotifyingSubscription<T> implements StreamSubscription<T> {
  _CancelNotifyingSubscription(this._inner, this._onCancel);

  final StreamSubscription<T> _inner;
  final void Function() _onCancel;

  @override
  Future<void> cancel() {
    _onCancel();
    return _inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}

class OriginBoundHttpClient extends http.BaseClient {
  /// With no [inner], the default client's TCP connect also dies at
  /// [connectTimeout]: package:http only arms an abort after the socket is
  /// open (Desktop's `req.setTimeout` covers the connect, main.ts). A client
  /// substituted by `http.runWithClient` is kept as is.
  OriginBoundHttpClient([http.Client? inner, Duration? connectTimeout])
    : _inner = inner ?? _defaultClient(connectTimeout);

  static http.Client _defaultClient(Duration? connectTimeout) {
    final client = http.Client();
    if (connectTimeout == null || client is! IOClient) return client;
    client.close();
    return IOClient(
      dartHttpClientFactory()..connectionTimeout = connectTimeout,
    );
  }

  @visibleForTesting
  static HttpClient Function() dartHttpClientFactory = HttpClient.new;

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw ArgumentError('Expected an absolute HTTP(S) URL');
    }
    TransportPrivacy.requireAllowed(uri.toString());
    request.followRedirects = false;
    final meter = GatewaySocketMeter.instance;
    if (!meter.enabled) return _inner.send(request);
    final watch = Stopwatch()..start();
    int? status;
    var outcome = 'error';
    try {
      final response = await _inner.send(request);
      status = response.statusCode;
      return response;
    } on http.RequestAbortedException {
      outcome = 'aborted';
      rethrow;
    } on TimeoutException {
      outcome = 'timeout';
      rethrow;
    } finally {
      meter.recordRest(
        request.method,
        uri.path,
        status,
        watch.elapsedMilliseconds,
        outcome: outcome,
      );
    }
  }

  /// Calls made through the returned view are cut, and aborted, at [deadline].
  http.Client within(Duration deadline) => DeadlineHttpClient(this, deadline);

  @override
  void close() => _inner.close();
}
