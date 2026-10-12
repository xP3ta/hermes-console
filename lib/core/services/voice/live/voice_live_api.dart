import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' show ClientException;

import '../../connection_manager.dart'
    show
        DashboardClient,
        DashboardHttpException,
        DashboardAuthException,
        DashboardAuthFailureCode;
import 'voice_live_protocol.dart';

/// Typed failure of `POST /api/audio/voice-live/session`. For 503/502 the
/// [detail] is the server's own message (no key, vendor rejection).
final class VoiceLiveSessionException implements Exception {
  final int? statusCode;
  final String detail;

  const VoiceLiveSessionException({this.statusCode, required this.detail});

  @override
  String toString() => 'VoiceLiveSessionException($statusCode)';
}

enum VoiceLiveStatusFailure { transient, accessRequired, invalid }

final class VoiceLiveStatusException implements Exception {
  const VoiceLiveStatusException(this.failure);
  final VoiceLiveStatusFailure failure;
  bool get retryable => failure == VoiceLiveStatusFailure.transient;
  @override
  String toString() => 'VoiceLiveStatusException(${failure.name})';
}

/// SDP answer plus the vendor session id returned by the server.
final class VoiceLiveSessionAnswer {
  final String sdp;
  final String? sessionId;

  const VoiceLiveSessionAnswer({required this.sdp, this.sessionId});
}

/// The only two Hermes routes GPT-Live talks to. Everything else is WebRTC.
abstract interface class VoiceLiveApi {
  /// `null` for a server without the feature (404/405), any failure or
  /// `ok != true`: the caller then keeps the chained mode.
  Future<VoiceLiveStatus?> fetchStatus({String profile = ''});

  Future<VoiceLiveSessionAnswer> createSession({
    required String sdp,
    List<Map<String, dynamic>> history = const [],
    String profile = '',
  });

  /// Releases the HTTP client; the api must not be used afterwards.
  void close();
}

/// Typed admission read; preserves legacy nullable API for older consumers.
Future<VoiceLiveStatus?> readVoiceLiveStatus(
  VoiceLiveApi api, {
  String profile = '',
}) => api is DashboardVoiceLiveApi
    ? api.fetchStatusChecked(profile: profile)
    : api.fetchStatus(profile: profile);

/// [VoiceLiveApi] over the existing Dashboard client (same auth and cookies).
final class DashboardVoiceLiveApi implements VoiceLiveApi {
  static const Duration sessionTimeout = Duration(seconds: 45);

  final DashboardClient _client;

  const DashboardVoiceLiveApi(this._client);

  @override
  void close() => _client.close();

  static String _profileQuery(String profile) =>
      profile.isEmpty || profile == 'default'
      ? ''
      : '?profile=${Uri.encodeQueryComponent(profile)}';

  @override
  Future<VoiceLiveStatus?> fetchStatus({String profile = ''}) async {
    // Compatibility accessor. Admission must use readVoiceLiveStatus below.
    try {
      return await fetchStatusChecked(profile: profile);
    } catch (_) {
      return null;
    }
  }

  Future<VoiceLiveStatus?> fetchStatusChecked({String profile = ''}) async {
    try {
      final body = await _client.apiGet(
        'audio/voice-live/status${_profileQuery(profile)}',
      );
      return parseVoiceLiveStatus(body);
    } on DashboardAuthException catch (error) {
      final access =
          error.statusCode == 401 ||
          error.statusCode == 403 ||
          error.code == DashboardAuthFailureCode.loginRequired ||
          error.code == DashboardAuthFailureCode.invalidCredentials ||
          error.code == DashboardAuthFailureCode.sessionCookieMissing;
      throw VoiceLiveStatusException(
        access
            ? VoiceLiveStatusFailure.accessRequired
            : error.code == DashboardAuthFailureCode.rateLimited ||
                  (error.statusCode ?? 0) >= 500
            ? VoiceLiveStatusFailure.transient
            : VoiceLiveStatusFailure.invalid,
      );
    } on DashboardHttpException catch (error) {
      final code = error.statusCode;
      if (code == 404 || code == 405) return null;
      throw VoiceLiveStatusException(
        code == 401 || code == 403
            ? VoiceLiveStatusFailure.accessRequired
            : code >= 500 || code == 408 || code == 429
            ? VoiceLiveStatusFailure.transient
            : VoiceLiveStatusFailure.invalid,
      );
    } on TimeoutException {
      throw const VoiceLiveStatusException(VoiceLiveStatusFailure.transient);
    } on SocketException {
      throw const VoiceLiveStatusException(VoiceLiveStatusFailure.transient);
    } on ClientException {
      throw const VoiceLiveStatusException(VoiceLiveStatusFailure.transient);
    } catch (_) {
      throw const VoiceLiveStatusException(VoiceLiveStatusFailure.invalid);
    }
  }

  @override
  Future<VoiceLiveSessionAnswer> createSession({
    required String sdp,
    List<Map<String, dynamic>> history = const [],
    String profile = '',
  }) async {
    final Map<String, dynamic> body;
    try {
      body = await _client.apiPost(
        'audio/voice-live/session${_profileQuery(profile)}',
        body: {'sdp': sdp, if (history.isNotEmpty) 'history': history},
        timeout: sessionTimeout,
      );
    } on DashboardHttpException catch (error) {
      throw VoiceLiveSessionException(
        statusCode: error.statusCode,
        detail: _detailOf(error.body),
      );
    }
    final transport = body['transport'];
    final answerSdp = transport is Map ? transport['sdp'] : null;
    if (body['ok'] != true || answerSdp is! String || answerSdp.isEmpty) {
      throw const VoiceLiveSessionException(
        detail: 'Invalid GPT-Live session response',
      );
    }
    final session = body['session'];
    final id = session is Map ? session['id'] : null;
    return VoiceLiveSessionAnswer(
      sdp: answerSdp,
      sessionId: id is String && id.isNotEmpty ? id : null,
    );
  }

  static String _detailOf(String body) {
    try {
      final decoded = jsonDecode(body);
      final detail = decoded is Map ? decoded['detail'] : null;
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
    } catch (_) {}
    return '';
  }
}
