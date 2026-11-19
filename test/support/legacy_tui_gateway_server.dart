// Hermes' legacy tui_gateway (3b42157858) as the legacy_live_turn_socket_loss
// test pins it — the same WebSocket contract, copied unchanged — plus, on the
// same origin (the connection's dashboardUrl), the Dashboard's transcript
// REST as the suite's fake Dashboard pins it, so a widget test can run the
// real ApiClient/DashboardClient parser and the real ChatScreen passive
// reader against it. Session frames go only to sockets that attached the session.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:hermes_android/core/services/connection_manager.dart';

class LegacyTuiGatewayServer {
  LegacyTuiGatewayServer._(this.server) {
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        await _serveRest(request);
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      attached[socket] = <String>{};
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {
              'skin': <String, dynamic>{},
              'change_events': true,
              'heartbeat': heartbeat,
              'replay_epoch': replayEpoch,
            },
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add((socket, frame));
        if (socket.closeCode != null) continue;
        final method = frame['method'];
        if (method is! String) continue;
        final params = (frame['params'] as Map?) ?? const {};
        // session.resume (session_registry.py:785-806 at 3b42157858): the
        // transport is attached and the inflight cut in one locked section;
        // the persisted rows are read after it and the answer written later.
        Map<String, dynamic>? resumeAnswer;
        if (method == 'session.resume') {
          attached[socket]!.add(liveRuntime);
          final early = onResume;
          if (early != null) await early('beforeCut');
          // session_registry.py:795: inflight AND queued are read in the
          // same history_lock section as the attach.
          final cut = (
            running: running,
            inflight: inflightAssistant,
            user: inflightUser,
            todo: todoState,
            queued: serverQueue.isEmpty ? null : serverQueue.first.text,
            turnStartedAt: turnStartedAt,
          );
          final hook = onResume;
          if (hook != null) await hook('afterCut');
          resumeAnswer = snapshot(cut: cut);
          orderLog.add(
            '${clock.elapsedMilliseconds}ms resume served running=${cut.running} '
            'inflightLen=${cut.inflight.length} queued=${cut.queued ?? '-'}',
          );
          final hold = holdResume;
          if (hold != null) await hold.future;
        }
        if ((method == 'session.activate' || method == 'prompt.submit') &&
            params['session_id'] == liveRuntime) {
          attached[socket]!.add(liveRuntime);
        }
        // session.activate (methods_session.py:1152-1164): rebind, then the
        // payload is built outside the lock and written later. A test hook
        // runs after the payload is built and before it is written (frames it
        // emits reach the attached socket first).
        Map<String, dynamic>? activateAnswer;
        if (method == 'session.activate' && params['session_id'] == liveRuntime) {
          activateAnswer = snapshot();
          final hook = onActivate;
          if (hook != null) {
            onActivate = null;
            await hook();
          }
        }
        if (method == 'gateway.ping') {
          // ws.py answers the heartbeat on the read loop, whatever the
          // socket's session subscriptions are.
          try {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'ok': true},
              }),
            );
          } on StateError {
            // Closed.
          }
          continue;
        }
        // A test can make the next call of a method fail once, as a JSON-RPC
        // error (the producer's `_err(rid, code, message)` shape).
        if (failNextMethods.remove(method)) {
          orderLog.add('${clock.elapsedMilliseconds}ms rpc $method FAILED (fixture)');
          try {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'error': {'code': 5032, 'message': 'fixture failure'},
              }),
            );
          } on StateError {
            // Closed.
          }
          continue;
        }
        // fid36f: hold the next prompt.submit answer (oracle sensitivity).
        if (method == 'prompt.submit' && holdNextSubmitFor != null) {
          final hold = holdNextSubmitFor!;
          holdNextSubmitFor = null;
          await Future<void>.delayed(hold);
        }
        // Parity re-anchor (2026-11-16, C1): one-shot hook run BEFORE the
        // next `session.active_list` answer is built, i.e. on the client's
        // official healthy-socket recovery signal (apps/desktop/src/store/
        // session-states.ts:347-566 onEventSilence -> session.active_list;
        // use-background-sync.ts:1355-1395 on sessions.changed).
        if (method == 'session.active_list') {
          final before = beforeNextActiveListAnswer;
          if (before != null) {
            beforeNextActiveListAnswer = null;
            await before(socket);
          }
        }
        final Map<String, dynamic>? result0 = switch (method) {
          'client.capabilities' => {
            'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'session.resume' => resumeAnswer!,
          'session.activate' => activateAnswer ?? snapshot(),
          'session.events.since' => eventsSince(
            params['last_seen'] as int? ?? 0,
          ),
          // methods_session.py:1138-1149, session_registry `_session_live_item`.
          'session.active_list' => {
            'sessions': [
              {
                'current': false,
                'id': liveRuntime,
                'last_active': 2000.0,
                'message_count': rows.length,
                'model': 'hermes-agent',
                'preview': '',
                'session_key': stored,
                'started_at': 1000.0,
                'status': running ? 'working' : 'idle',
                'title': 'Live',
              },
            ],
          },
          'prompt.submit' when params['session_id'] == liveRuntime =>
            _admitSubmit(params),
          // Producer fidelity (tui_gateway/session_registry.py:304-320,
          // methods_prompt.py:841-843): a session-scoped RPC on a runtime id
          // the gateway no longer holds is rejected with 4001 «session not
          // found», never acknowledged.
          'prompt.submit' => null,
          _ => <String, dynamic>{'status': 'ok'},
        };
        if (result0 == null) {
          orderLog.add('${clock.elapsedMilliseconds}ms rpc $method REJECTED 4001 (stale runtime ${params['session_id']})');
          try {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'error': {'code': 4001, 'message': 'session not found'},
              }),
            );
          } on StateError {
            // Closed.
          }
          continue;
        }
        var result = result0;
        if (method == 'prompt.submit') {
          orderLog.add(
            '${clock.elapsedMilliseconds}ms rpc prompt.submit '
            'socket=${sockets.indexOf(socket)} text=${params['text']}',
          );
        }
        // Wire metadata of the answer (no content): which socket, what was
        // asked (`last_seen`), what the server had (`latest_seq`, running,
        // inflight text length) and what it returned.
        if (method == 'session.resume' ||
            method == 'session.activate' ||
            method == 'session.events.since') {
          final events = result['events'];
          orderLog.add(
            '${clock.elapsedMilliseconds}ms rpc $method '
            'socket=${sockets.indexOf(socket)} '
            'lastSeen=${params['last_seen'] ?? '-'} latest=$seq '
            'returned=${events is List ? events.length : '-'} '
            'running=$running inflightLen=${inflightAssistant.length} '
            'attached=${attached[socket]!.contains(liveRuntime)}',
          );
        }
        // fid36e (test-only knobs for the replayed-receipt unit negatives):
        // one-shot transform of the next events.since answer (truncated,
        // epoch, gap) and a hook awaited before it is written (socket
        // generation change between request and answer).
        if (method == 'session.events.since') {
          final transform = transformNextEventsSince;
          if (transform != null) {
            transformNextEventsSince = null;
            result = transform(Map<String, dynamic>.of(result));
          }
          final before = beforeEventsSinceAnswer;
          if (before != null) {
            beforeEventsSinceAnswer = null;
            await before(socket);
          }
        }
        try {
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        } on StateError {
          // Closed while the request was in flight.
        }
        // Parity re-anchor (C1): one-shot hook AFTER the next active_list
        // answer was written.
        if (method == 'session.active_list') {
          final after = afterNextActiveListAnswer;
          if (after != null) {
            afterNextActiveListAnswer = null;
            unawaited(after(socket));
          }
        }
        // fid36h: one-shot hook after a NON-EMPTY events.since answer.
        if (method == 'session.events.since' &&
            (result['events'] as List?)?.isNotEmpty == true) {
          final after = afterNextNonEmptyEventsSinceAnswer;
          if (after != null) {
            afterNextNonEmptyEventsSinceAnswer = null;
            unawaited(after(socket));
          }
        }
      }
    });
  }

  /// Every REST request this server answered (path and query).
  final restRequests = <Uri>[];

  /// One metadata line per REST answer: method, path, limit/offset, status,
  /// rows returned, newest row id, whether row 4 (the final) is in the page,
  /// whether the Dashboard session-token header came with it. No content.
  final restLog = <String>[];

  /// Real-time order of what this server did (ms since start): REST answers
  /// and session frames written. Metadata only.
  final clock = Stopwatch()..start();
  final orderLog = <String>[];

  /// While set, `/messages` answers wait for it (a deterministic order of the
  /// stored page against live frames).
  Completer<void>? holdMessages;
  bool _closed = false;

  /// The Dashboard origin (the connection's `dashboardUrl`), which
  /// `ApiClient.forConnection` reads the transcript from, as the suite's
  /// pinned fake Dashboard (test/support/fake_dashboard_sessions.dart):
  /// `GET /` serves the page token; `GET /api/status`;
  /// `GET /api/sessions/{id}/messages?limit&offset&order=latest` counts
  /// `offset` back from the newest row, the page oldest first,
  /// `{session_id, profile, messages, pagination}`; any other `/api/` path
  /// is 404.
  Future<void> _serveRest(HttpRequest request) async {
    restRequests.add(request.uri);
    final uri = request.uri;
    final token = request.headers.value('X-Hermes-Session-Token') != null;
    final response = request.response;
    Future<void> answer(int status, Object body, {String? note}) async {
      response.statusCode = status;
      if (body is String) {
        response.headers.contentType = ContentType.html;
        response.write(body);
      } else {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(body));
      }
      restLog.add(
        '${request.method} ${uri.path.replaceAll(stored, '<stored>')}'
        '?limit=${uri.queryParameters['limit']}'
        '&offset=${uri.queryParameters['offset']}'
        '&order=${uri.queryParameters['order']}'
        ' -> $status${note == null ? '' : ' $note'} token=$token',
      );
      await response.close();
    }

    if (uri.path == '/') {
      await answer(
        200,
        '<script>window.__HERMES_SESSION_TOKEN__="fake";</script>',
      );
      return;
    }
    if (!uri.path.startsWith('/api/')) {
      await answer(200, '<!doctype html><html><body></body></html>');
      return;
    }
    if (uri.path == '/api/status') {
      await answer(200, {'version': 'fake'});
      return;
    }
    final match = RegExp(
      r'^/api/sessions/([^/]+)/messages$',
    ).firstMatch(uri.path);
    if (match == null || Uri.decodeComponent(match.group(1)!) != stored) {
      await answer(404, {'detail': 'Not Found'});
      return;
    }
    if (failMessages) {
      orderLog.add('${clock.elapsedMilliseconds}ms rest /messages FAILED (fixture)');
      await answer(500, {'detail': 'fixture failure'});
      return;
    }
    final hold = holdMessages;
    if (hold != null) {
      orderLog.add('${clock.elapsedMilliseconds}ms rest /messages held');
      await hold.future;
    }
    final query = uri.queryParameters;
    final order = query['order'];
    final latest =
        order == 'latest' || (order == null && query['limit'] == null);
    final limit = math.min(int.parse(query['limit'] ?? '500'), 500);
    final offset = int.parse(query['offset'] ?? '0');
    final List<Map<String, dynamic>> page;
    if (latest) {
      final end = math.max(0, rows.length - offset);
      page = rows.sublist(math.max(0, end - limit), end);
    } else {
      final start = math.min(offset, rows.length);
      page = rows.sublist(start, math.min(rows.length, start + limit));
    }
    final ids = [for (final row in page) row['id'] as int];
    await answer(
      200,
      {
        'session_id': stored,
        'profile': 'default',
        'messages': [
          // A DB row as hermes_state_messages._row_to_message_dict returns
          // the table's columns (hermes_state_common.py:538-565;
          // note 153). `message_id` is not a column (it is `message_uid`): a
          // row a test added with one is served without it. finish_reason
          // 'stop' on every assistant row (Console does not read it) and
          // project_history_commentary are declared, not verified.
          for (final row in page)
            {
              for (final entry in row.entries)
                if (entry.key != 'message_id') entry.key: entry.value,
              'session_id': stored,
              if (row['role'] == 'assistant') 'finish_reason': 'stop',
            },
        ],
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': order ?? (query['limit'] == null ? 'latest' : 'oldest'),
          'returned': page.length,
        },
      },
      note:
          'returned=${page.length} maxId=${ids.isEmpty ? '-' : ids.reduce(math.max)} '
          'final=${ids.contains(4)}',
    );
    orderLog.add(
      '${clock.elapsedMilliseconds}ms rest /messages answered '
      'returned=${page.length}',
    );
  }

  /// Reply-frame identity as the producer stamps it (tui_gateway
  /// stream_segments.py:54-75, server.py:597 at 3b42157858): every
  /// `message.start`/`message.delta`/`message.interim` [emit] writes carries
  /// the running turn's [turnSegments] stamp. A payload that already holds a
  /// `turn_id` is written as given (a test's crafted copy of a frame).
  bool stampReplyFrames = true;

  /// The running turn's cursor (prompt_turn.py:1169-1172: created at turn
  /// start, dropped when the turn ends); null between turns.
  ProducerTurnSegments? turnSegments;

  final _turnIds = math.Random();

  String _newTurnId() => [
    for (var i = 0; i < 32; i++) _turnIds.nextInt(16).toRadixString(16),
  ].join();

  /// `prompt.submit` on this session (methods_prompt.py:893-973,
  /// session_auto_continue.py:400-454 at 3b42157858): while a turn runs the
  /// prompt is queued server-side (`queued:true` forces queue mode; the
  /// default busy mode would also end in `queued` here, the fake has no
  /// redirect) and its user row persisted at accept; on an idle session it
  /// starts a turn (`message.start` before the `streaming` answer).
  Map<String, dynamic> _admitSubmit(Map params) {
    final text = '${params['text'] ?? ''}';
    submitLog.add(
      '${clock.elapsedMilliseconds}ms submit text=$text '
      'serverRunning=$running queued=${params['queued'] == true}',
    );
    final userRowId = nextRowId();
    rows.add({
      'id': userRowId,
      'role': 'user',
      'content': text,
      'timestamp': 3000.0 + userRowId,
    });
    orderLog.add(
      '${clock.elapsedMilliseconds}ms admit submit serverRunning=$running '
      'queued=${params['queued'] == true} answer=${running ? 'queued' : 'streaming'}',
    );
    if (running) {
      serverQueue.add((text: text, userRowId: userRowId));
      return {'status': 'queued'};
    }
    _startServedTurn(text, userRowId);
    return {'status': 'streaming'};
  }

  /// Prompts the server queued behind a running turn, run in order when it
  /// ends (session_auto_continue.py `_drain_queued_prompt`).
  final serverQueue = <({String text, int userRowId})>[];

  /// Every `prompt.submit` this session got: when, what, whether the server
  /// ran a turn then (no content beyond the test's own prompt text).
  final submitLog = <String>[];

  /// The fake runs a turn it started for a submit to its end on its own:
  /// [serveDelay] later one delta `R:<prompt>` and the complete with the
  /// durable rows. False: the test drives that turn.
  bool serveSubmits = true;

  /// A served turn runs one tool round with this id before its reply.
  String? serveWithToolId;

  /// The served turn's receipt names no user row (agent/persisted_turn_receipt
  /// .py:43-60 adds `user_row_id(s)` only when it can address them).
  bool receiptWithoutUserIds = false;
  Duration serveDelay = const Duration(milliseconds: 300);

  void _startServedTurn(String text, int userRowId) {
    running = true;
    inflightUser = text;
    emit('message.start', <String, dynamic>{});
    if (!serveSubmits) return;
    final turn = turnSegments;
    Timer(serveDelay, () {
      if (_closed || !identical(turnSegments, turn)) return;
      final reply = 'R:$text';
      final toolId = serveWithToolId;
      final toolRows = <int>[];
      if (toolId != null) {
        // A tool round of the served turn, persisted before its side effects
        // (agent/turn_tool_round.py:130-133) and written as tool frames.
        toolRows.addAll(persistToolRound(toolId));
        emit('tool.start', {'tool_id': toolId, 'name': 'terminal'});
        emit('tool.complete', {'tool_id': toolId, 'name': 'terminal'});
      }
      emit('message.delta', {'text': reply});
      final assistantRowId = nextRowId();
      rows.add({
        'id': assistantRowId,
        'role': 'assistant',
        'content': reply,
        'timestamp': 3000.0 + assistantRowId,
      });
      emit('message.complete', {
        'text': reply,
        'status': 'complete',
        'persisted_turn': {
          'row_ids': [userRowId, ...toolRows, assistantRowId],
          'complete': true,
          if (!receiptWithoutUserIds) 'user_row_id': userRowId,
          if (!receiptWithoutUserIds) 'user_row_ids': [userRowId],
          'final_assistant_row_id': assistantRowId,
        },
      });
    });
  }

  /// prompt_turn.py:1214-1229: after `message.complete` is written the turn's
  /// finally clears `running`, the inflight turn and the cursor; the server
  /// queue drains after that.
  void _endTurnAfterFrame() {
    running = false;
    inflightAssistant = '';
    turnSegments = null;
    emitSettledSessionInfo();
    _drainServerQueueAfterTurn();
  }

  /// The end-of-turn `session.info` the producer writes after the turn's
  /// `finally` cleared `running` and before the queued prompt drains
  /// (prompt_turn.py:1214-1229 → :1251 `_emit_settled_session_info` →
  /// session_workdir.py:483-490; payload `running`/`turn_started_at`,
  /// server.py:1502-1503).
  void emitSettledSessionInfo() {
    emit('session.info', {'running': running, 'turn_started_at': null});
  }

  void _drainServerQueueAfterTurn() {
    if (serverQueue.isEmpty || !autoDrainServerQueue) return;
    Timer(serveDelay, () {
      if (_closed || running || serverQueue.isEmpty) return;
      final next = serverQueue.removeAt(0);
      _startServedTurn(next.text, next.userRowId);
    });
  }

  /// fid36h: REST /messages answers 500 while set.
  bool failMessages = false;

  /// C1 re-anchor: one-shot hooks around the next `session.active_list`.
  Future<void> Function(WebSocket socket)? beforeNextActiveListAnswer;
  Future<void> Function(WebSocket socket)? afterNextActiveListAnswer;

  /// fid36h: one-shot hook run after the next non-empty events.since answer.
  Future<void> Function(WebSocket socket)? afterNextNonEmptyEventsSinceAnswer;

  /// fid36f: one-shot delay before answering the next prompt.submit.
  Duration? holdNextSubmitFor;

  /// fid36e: see the request loop (events.since knobs; one-shot each).
  Map<String, dynamic> Function(Map<String, dynamic>)? transformNextEventsSince;
  Future<void> Function(WebSocket socket)? beforeEventsSinceAnswer;

  /// One-shot hook between building a `session.activate` answer and writing it.
  Future<void> Function()? onActivate;

  /// False: the server queue waits for [drainServerQueueNow] instead of
  /// running right after the turn ends (a test places the next turn).
  bool autoDrainServerQueue = true;

  /// Runs the head of the server queue now (as `_drain_queued_prompt`).
  void drainServerQueueNow() {
    if (running || serverQueue.isEmpty) return;
    final next = serverQueue.removeAt(0);
    _startServedTurn(next.text, next.userRowId);
  }

  /// Methods whose next call fails once (see the request loop).
  final failNextMethods = <String>{};

  /// The server's wall clock (seconds), strictly increasing.
  double _lastServerNow = 0;
  double serverNow() {
    final now = 1800000000.0 + clock.elapsedMicroseconds / 1e6;
    _lastServerNow = now > _lastServerNow ? now : _lastServerNow + 1e-6;
    return _lastServerNow;
  }

  /// `turn_started_at` of the turn the session runs (session_history.py
  /// :397-411 `_start_inflight_turn`, server.py:1409-1412): set when a turn
  /// starts (here at its `message.start`) and kept until the next one, so the
  /// complete→cleanup window still reports the closed turn's start.
  late double? turnStartedAt = serverNow();

  static const stored = 'stored-live';
  static const runtime = 'runtime-live';
  /// fid36h: the runtime id this fake serves now (a reattach may mint
  /// another one); defaults to [runtime].
  String liveRuntime = runtime;
  final HttpServer server;
  /// fid36h: mutable so a test can model a producer restart (new epoch).
  String replayEpoch = 'epoch-1';
  final sockets = <WebSocket>[];
  final attached = <WebSocket, Set<String>>{};
  final frames = <(WebSocket, Map<String, dynamic>)>[];
  final ring = <Map<String, dynamic>>[];
  int seq = 0;
  bool running = true;
  /// ws.py:656-661 announces `heartbeat: True` on every connection.
  bool heartbeat = true;
  Map<String, dynamic>? todoState;

  /// The running turn's reply text so far, as `session.resume` reports it in
  /// `inflight.assistant`: the producer accumulates every `message.delta` of
  /// the turn and starts empty on `message.start` / `message.complete`
  /// ([emit] keeps it so; a test may also seed it).
  String inflightAssistant = '';

  /// The running turn's prompt, as `session.resume` reports it in
  /// `inflight.user` ('QLIVE' by default, as before).
  String inflightUser = 'QLIVE';

  /// transport.py FanoutTransport._drain: a failed write prunes the peer from
  /// the session's fanout; the WebSocket is not closed, it still answers RPCs
  /// and gets session-less broadcasts. Only resume/activate/submit re-attach.
  void dropViewer(WebSocket socket) => attached[socket]!.remove(liveRuntime);

  /// The server closes [socket] (the OS or a proxy dropped the connection
  /// while the app was in the background: 1001 going away).
  Future<void> closeSocket(WebSocket socket) async {
    if (socket.closeCode == null) await socket.close(1001, 'going away');
  }

  /// The open sockets that attached the session now.
  List<WebSocket> get attachedSockets => [
    for (final socket in sockets)
      if (socket.closeCode == null && attached[socket]!.contains(liveRuntime))
        socket,
  ];

  /// A session-less broadcast (change_watcher `sessions.changed`) to every
  /// open socket, as `_broadcast_global_event` writes it.
  void broadcast(String type) {
    for (final socket in sockets) {
      if (socket.closeCode != null) continue;
      try {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': type,
              'session_id': '',
              'payload': <String, dynamic>{},
            },
          }),
        );
      } on StateError {
        // Closing.
      }
    }
  }

  /// The stored rows: Hermes saves the prompt at submit time. Every row gets
  /// its authoring `timestamp` from the server clock when it is written
  /// (agent/message_metadata.py:420-427, hermes_state_messages.py:416),
  /// whatever a test put there.
  late final rows = _ServerRows(serverNow)
    ..addAll(<Map<String, dynamic>>[
    {'id': 1, 'role': 'user', 'content': 'QOLD', 'timestamp': 1000.0},
    {'id': 2, 'role': 'assistant', 'content': 'AOLD', 'timestamp': 1005.0},
    {'id': 3, 'role': 'user', 'content': 'QLIVE', 'timestamp': 2000.0},
  ]);

  /// The next durable row id.
  int nextRowId() =>
      rows.fold<int>(0, (top, row) => (row['id'] as int) > top ? row['id'] as int : top) + 1;

  /// Hermes persists each tool round of a running turn before its side
  /// effects (agent/turn_tool_round.py:130-133, tool_executor.py:212-213 at
  /// 3b42157858) and `session.resume` reads that lineage
  /// (session_registry.py:773-776): an assistant row with `tool_calls` and the
  /// `tool` row of its result, with durable ids, after the turn's user row.
  /// Row shape as the suite's persisted tool rounds (active_chat_branch_test,
  /// active_chat_resume_snapshot_test). Returns the two row ids.
  List<int> persistToolRound(String callId, {String name = 'terminal'}) {
    final assistantId = nextRowId();
    rows.add({
      'id': assistantId,
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        {
          'id': callId,
          'type': 'function',
          'function': {'name': name, 'arguments': '{}'},
        },
      ],
      'timestamp': 2000.0 + assistantId,
    });
    final toolId = nextRowId();
    rows.add({
      'id': toolId,
      'role': 'tool',
      'tool_call_id': callId,
      'tool_name': name,
      'content': 'ok',
      'timestamp': 2000.0 + toolId,
    });
    return [assistantId, toolId];
  }

  /// Called inside `session.resume` after the attach and before the inflight
  /// cut ('beforeCut'), and after the cut, before the rows are read
  /// ('afterCut').
  Future<void> Function(String phase)? onResume;

  /// While set, `session.resume` answers only when it completes.
  Completer<void>? holdResume;

  /// The next [emit] is recorded in the ring but written to no socket (a
  /// frame this client never receives: a real sequence gap).
  bool skipNextDelivery = false;

  /// `session.events.since` (methods_session.py:2309-2322 at 3b42157858):
  /// `events` are the frames' PARAMS dicts {type, session_id, payload, seq}
  /// as event_replay.events_since returns them (:189-198), not the JSON-RPC
  /// envelope (the client parses `type` per row). The ring is unbounded
  /// (the producer keeps 512 events / 4 MiB): never `truncated` here.
  Map<String, dynamic> eventsSince(int lastSeen) {
    final events = [
      for (final event in ring)
        if ((event['params'] as Map)['seq'] as int > lastSeen)
          Map<String, dynamic>.from(event['params'] as Map),
    ];
    return {
      'events': events,
      'latest_seq': seq,
      'truncated': false,
      'count': events.length,
      'epoch': replayEpoch,
      'open_requests': <Object>[],
    };
  }

  /// `session.resume` / `session.activate` answer as
  /// session_registry.py `_live_session_payload` (3b42157858, :782-822):
  /// `inflight`/`queued` only when there is one; `turn_started_at` null when
  /// idle. `info` (`_fallback_session_info`) is not modelled (declared).
  Map<String, dynamic> snapshot({
    ({
      bool running,
      String inflight,
      String user,
      Map<String, dynamic>? todo,
      String? queued,
      double? turnStartedAt,
    })?
    cut,
  }) {
    final isRunning = cut?.running ?? running;
    final todo = cut == null ? todoState : cut.todo;
    final messages = displayMessages();
    return {
      'message_count': messages.length,
      'messages': messages,
      'messages_omitted': false,
      'running': isRunning,
      'turn_started_at': isRunning
          ? (cut == null ? turnStartedAt : cut.turnStartedAt)
          : null,
      'session_id': liveRuntime,
      'session_key': stored,
      'started_at': 1000.0,
      'status': isRunning ? 'working' : 'idle',
      if (isRunning)
        // session_auto_continue.py:528-556 `_inflight_snapshot`.
        'inflight': {
          'assistant': cut?.inflight ?? inflightAssistant,
          'streaming': true,
          'user': cut?.user ?? inflightUser,
        },
      // session_auto_continue.py:600-605 `_queued_prompt_snapshot`.
      if ((cut == null
              ? (serverQueue.isEmpty ? null : serverQueue.first.text)
              : cut.queued)
          case final String queuedUser)
        'queued': {'user': queuedUser},
      'todo_state': ?todo,
    };
  }

  /// The stored rows as session_history.py `_history_to_messages`
  /// (3b42157858, :297-372) projects them: an assistant row with only
  /// `tool_calls` and no text is skipped; a tool row is
  /// {role, name, context, tool_call_id, timestamp} (no row id, no text).
  List<Map<String, dynamic>> displayMessages() => [
    for (final row in rows)
      if (row['role'] == 'tool')
        {
          'role': 'tool',
          'name': row['tool_name'] ?? 'tool',
          'context': '',
          'tool_call_id': ?row['tool_call_id'],
          'timestamp': ?row['timestamp'],
        }
      else if ('${row['content'] ?? ''}'.trim().isNotEmpty)
        {
          'role': row['role'],
          'text': row['content'],
          'timestamp': ?row['timestamp'],
          'row_id': row['id'],
        },
  ];

  static Future<LegacyTuiGatewayServer> start() async =>
      LegacyTuiGatewayServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Iterable<(WebSocket, Map<String, dynamic>)> calls(String method) =>
      frames.where((entry) => entry.$2['method'] == method);

  /// One sequenced session event, recorded in the replay ring and written to
  /// every open socket that attached the session — and to no other.
  /// [emit] without touching the inflight text (a delta the producer already
  /// added to it under its lock and writes to the sockets afterwards).
  int emitRaw(String type, Map<String, dynamic> payload) {
    _rawEmit = true;
    try {
      return emit(type, payload);
    } finally {
      _rawEmit = false;
    }
  }

  bool _rawEmit = false;

  int emit(String type, Map<String, dynamic> payload) {
    // tool_progress.py:282-373 (note 153): tool.start carries
    // {tool_id, name, context} (+labels/args/args_text), tool.complete
    // {tool_id, name, args, result} (+duration_s/summary). Fields a test did
    // not give get the producer's neutral value. Declared: the producer emits
    // tool frames only when tool progress is enabled or the UI requires them.
    if (type == 'tool.start' && !payload.containsKey('context')) {
      payload = {...payload, 'context': ''};
    } else if (type == 'tool.complete') {
      payload = {
        ...payload,
        if (!payload.containsKey('args')) 'args': <String, dynamic>{},
        if (!payload.containsKey('result')) 'result': 'ok',
      };
    }
    if (stampReplyFrames && !payload.containsKey('turn_id')) {
      if (type == 'message.start') {
        turnStartedAt = serverNow();
        turnSegments = ProducerTurnSegments(_newTurnId());
        payload = {...payload, ...turnSegments!.start()};
      } else if ((type == 'message.interim') ||
          (type == 'message.delta' && payload['text'] is String)) {
        // A turn the test began without `message.start` (it ran before the
        // client connected) still has the producer's cursor: segment 0, every
        // delta already in the inflight text counted.
        final cursor = turnSegments ??= running
            ? ProducerTurnSegments(
                _newTurnId(),
                math.max(
                  0,
                  inflightAssistant.length -
                      (_rawEmit && type == 'message.delta'
                          ? (payload['text'] as String).length
                          : 0),
                ),
              )
            : null;
        if (cursor != null) {
          payload = {
            ...payload,
            ...(type == 'message.interim'
                ? cursor.seal()
                : cursor.delta(payload['text'])),
          };
        }
      }
    }
    if (_rawEmit) {
      // As written, not accumulated.
    } else if (type == 'message.delta' && running) {
      inflightAssistant += '${payload['text'] ?? ''}';
    } else if (type == 'message.start') {
      inflightAssistant = '';
    }
    seq += 1;
    final event = {
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': liveRuntime,
        'payload': payload,
        'seq': seq,
      },
    };
    ring.add(event);
    var delivered = 0;
    final at = clock.elapsedMilliseconds;
    if (skipNextDelivery) {
      skipNextDelivery = false;
      orderLog.add('${at}ms frame $type#$seq skipped');
      if (type == 'message.complete' || type == 'error') _endTurnAfterFrame();
      return 0;
    }
    for (final socket in sockets) {
      if (socket.closeCode != null || !attached[socket]!.contains(liveRuntime)) {
        continue;
      }
      try {
        socket.add(jsonEncode(event));
        delivered += 1;
      } on StateError {
        // Closing.
      }
    }
    orderLog.add('${at}ms frame $type#$seq delivered=$delivered');
    if (type == 'message.complete' || type == 'error') _endTurnAfterFrame();
    return delivered;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final socket in sockets) {
      if (socket.closeCode == null) await socket.close();
    }
    await server.close(force: true);
  }
}

/// The WebSocket ticket of the legacy test (no Dashboard behind it).
class LegacyTicketDashboardClient extends DashboardClient {
  LegacyTicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'ticket');
}

/// tui_gateway/stream_segments.py TurnSegments (3b42157858, lines 25-46) as the
/// fixture's producer: a delta is stamped with the cursor BEFORE it advances by
/// the text's UTF-16 code units (Dart `String.length`); a seal stamps the
/// segment it closes, then opens the next at offset 0.
class ProducerTurnSegments {
  ProducerTurnSegments(this.turnId, [this.offset = 0]);

  final String turnId;
  int segment = 0;
  int offset;

  Map<String, dynamic> start() => {'turn_id': turnId};

  Map<String, dynamic> delta(Object? text) {
    final stamp = {'turn_id': turnId, 'segment': segment, 'offset': offset};
    if (text is String) offset += text.length;
    return stamp;
  }

  Map<String, dynamic> seal() {
    final stamp = {'turn_id': turnId, 'segment': segment};
    segment += 1;
    offset = 0;
    return stamp;
  }
}


/// The stored rows, stamped on the server clock as they are written.
class _ServerRows extends ListBase<Map<String, dynamic>> {
  _ServerRows(this._now);

  final double Function() _now;
  final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];

  Map<String, dynamic> _stamp(Map<String, dynamic> row) =>
      {...row, 'timestamp': _now()};

  @override
  int get length => _rows.length;

  @override
  set length(int value) => _rows.length = value;

  @override
  Map<String, dynamic> operator [](int index) => _rows[index];

  @override
  void operator []=(int index, Map<String, dynamic> value) =>
      _rows[index] = value;

  @override
  void add(Map<String, dynamic> element) => _rows.add(_stamp(element));

  @override
  void addAll(Iterable<Map<String, dynamic>> iterable) {
    for (final row in iterable) {
      add(row);
    }
  }
}
