import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:hermes_android/core/services/prompt_client_surface.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'recording_desktop_gateway.dart';

/// `/api/ws` double for chat tests: the chat of a default remote profile goes
/// through the Dashboard socket only, as Hermes Desktop does (it has no REST
/// run path). Turns are 1-based and follow the order of `prompt.submit`.
///
/// Every payload mirrors the server emitter (Hermes `tui_gateway`):
/// - `message.start`: `prompt_turn.py` `_emit("message.start", sid)`.
/// - `message.delta`: `prompt_turn.py` `{"text": delta}`.
/// - `tool.start`: `tool_progress.py` `_on_tool_start`: `tool_id`, `name`,
///   `context`.
/// - `approval.request`: `server.py` `_approval_request_payload` (`request_id`,
///   `command`, `choices`; default choices once/session/always + deny).
/// - `message.complete`: `prompt_turn.py` `_complete_turn_payload` (`text`,
///   `status`; on error also `error` and `recoverable`).
/// Answers: `approval.respond` (`methods_prompt.py`, `request_id`, `choice`,
/// `all`) and `session.interrupt` (`methods_session_interrupt.py`).
class DesktopChatSocket extends RecordingDesktopGateway
    implements HermesDesktopIdempotentGateway {
  /// Every `approval.respond` the chat sent, in order.
  final List<({String? requestId, String choice, bool all})> approvals = [];

  /// When set, `prompt.submit` fails with it before anything is recorded:
  /// the socket was lost before the prompt reached the server.
  Object? submitError;

  int _started = 0;

  /// Texts handed to `prompt.submit`, one per turn.
  List<String> get submitTexts => [
    for (final call in submits) call['text']! as String,
  ];

  /// Number of `session.interrupt` frames.
  int get interrupts => calls.where((c) => c['call'] == 'interrupt').length;

  void _turn(int turn) {
    if (turn < 1 || submits.length < turn) {
      throw StateError('turn $turn was never submitted (${submits.length})');
    }
  }

  void _begin(int turn) {
    _turn(turn);
    if (_started >= turn) return;
    _started = turn;
    emit('message.start');
  }

  /// Assistant text delta of [turn].
  void token(int turn, String text) {
    _begin(turn);
    emit('message.delta', {'text': text});
  }

  /// A tool of [turn] starts running.
  void toolStarted(
    int turn,
    String name, {
    String id = 'call-1',
    String context = '',
  }) {
    _begin(turn);
    emit('tool.start', {'tool_id': id, 'name': name, 'context': context});
  }

  /// Hermes asks the user to approve a command during [turn].
  void approval(
    int turn, {
    String requestId = 'req-1',
    String command = 'git push origin fix/dock',
    List<String> choices = const ['once', 'session', 'always', 'deny'],
  }) {
    _begin(turn);
    emit('approval.request', {
      'request_id': requestId,
      'command': command,
      'choices': choices,
    });
  }

  /// The turn finishes with [text].
  void complete(int turn, String text) {
    _begin(turn);
    emit('message.complete', {'text': text, 'status': 'complete'});
  }

  /// The turn finishes with an error reported by the server.
  void fail(int turn, String message) {
    _begin(turn);
    emit('message.complete', {
      'text': message,
      'status': 'error',
      'error': message,
      'recoverable': true,
    });
  }

  void _failBeforeSubmit() {
    final error = submitError;
    if (error != null) throw error;
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    _failBeforeSubmit();
    await super.submitPrompt(runtimeSessionId, text);
  }

  @override
  Future<void> submitPromptWithSurface(
    String runtimeSessionId,
    String text,
    PromptClientSurface surface,
  ) async {
    _failBeforeSubmit();
    await super.submitPromptWithSurface(runtimeSessionId, text, surface);
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotentWithSurface(
    String runtimeSessionId,
    String text,
    String clientTurnId,
    PromptClientSurface surface,
  ) async {
    await submitPromptWithSurface(runtimeSessionId, text, surface);
    return _ack(clientTurnId);
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    await submitPrompt(runtimeSessionId, text);
    return _ack(clientTurnId);
  }

  DesktopTurnAck _ack(String clientTurnId) => DesktopTurnAck(
    accepted: true,
    clientTurnId: clientTurnId,
    serverTurnId: 'server-turn',
    state: DesktopTurnState.accepted,
    duplicate: false,
  );

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(clientTurnId: clientTurnId, known: false);

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {
    approvals.add((requestId: requestId, choice: choice, all: resolveAll));
  }
}

/// HTTP client double that counts requests per `host:port` and path. The
/// REST run API is gone from chat: `/v1/runs*` answers 503 and fails the test
/// at tear down, so no chat path can silently fall back to it.
class HostCounter extends http.BaseClient {
  /// Registers the tear-down check in the current test or `setUp` (or hands it
  /// to [register], so a test can run it). [handler] answers every other
  /// request; without one they get a 404.
  HostCounter({this.handler, void Function(void Function())? register}) {
    (register ?? addTearDown)(() {
      verify();
      verifiedAtTearDown = true;
    });
  }

  final Future<http.Response> Function(http.Request request)? handler;

  /// `host:port METHOD /path` of every request, in order.
  final List<String> requests = [];

  /// Set when the tear-down check ran and found nothing.
  bool verifiedAtTearDown = false;

  /// Requests per `host:port`.
  Map<String, int> get byHost => {
    for (final key in requests.map((r) => r.split(' ').first).toSet())
      key: requests.where((r) => r.startsWith('$key ')).length,
  };

  /// Requests to the REST run API.
  List<String> get runsRequests =>
      requests.where((r) => r.split(' ').last.startsWith('/v1/runs')).toList();

  /// Fails when anything reached `/v1/runs*`.
  void verify() {
    if (runsRequests.isNotEmpty) {
      fail('REST run API requested: ${runsRequests.join(', ')}');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    requests.add('${url.host}:$port ${request.method} ${url.path}');
    final answer = switch (url.path) {
      final p when p.startsWith('/v1/runs') => http.Response('{}', 503),
      _ when handler != null && request is http.Request => await handler!(
        request,
      ),
      _ => http.Response('{}', 404),
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(answer.body)),
      answer.statusCode,
      headers: answer.headers,
      request: request,
    );
  }
}
