// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `/api/ws` double that follows the public Hermes v0.22.5 canonical session
/// authority contract (`tui_gateway/contracts/canonical_sessions.py`,
/// `gateway/session_controls.py`, `gateway/session_events.py`,
/// `gateway/session_pending_controls.py`, `tui_gateway/ws.py`):
///
/// * `gateway.ready` announces `session_authority` only when [advertise] says so.
/// * Strict closed key sets: an unknown key is `4001 invalid_params`.
/// * Verbs the authority neither serves nor lets the legacy sidecar answer
///   (`session.activate`, `turn.status`, ...) answer `-32601`; an UNMODELLED
///   method is a test failure, never a silent `ok({})`.
/// * `session.active_list` lists the live session (`gateway/session_active_list.py`),
///   `session.history` serves the transcript (`gateway/session_tui_ops.py`),
///   `session.steer`/`session.redirect` require `execution_generation`
///   (`CanonicalCorrectionParams`), `session.create` has the closed
///   `CanonicalCreateParams` key set and the `gui` surface.
/// * `pending` lists queued AND started admissions until they are terminal
///   (`gateway/session_queued_controls.py` `pending_rows`).
/// * Event frames carry `seq`, `replay_epoch`, `authority_epoch`,
///   `execution_generation` and `admission_id` exactly as `SessionEvents.publish`
///   stamps them (`session_id` is the durable id).
/// * `session.resume` returns a `CanonicalSnapshot` whose `last_sequence`,
///   history, pending admissions and prompts are one atomic read.
class CanonicalAuthorityServer {
  CanonicalAuthorityServer._(this.server) {
    server.listen(_onRequest);
  }

  static Future<CanonicalAuthorityServer> start({
    Object? advertise = true,
  }) async {
    final s = CanonicalAuthorityServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    s.advertise = advertise;
    return s;
  }

  final HttpServer server;
  Object? advertise = true;

  /// The endpoint behind the socket is a standalone `tui_gateway` serve (no
  /// authority): it answers the legacy shapes the app speaks today.
  bool legacyBackend = false;

  // ---- authority state -------------------------------------------------
  int authorityEpoch = 7;
  String replayEpoch = 'ring-1';
  int seq = 0;
  int generation = 3;
  int revision = 11;
  bool running = false;
  String? runningAdmission;
  final List<Map<String, dynamic>> ring = [];
  final List<Map<String, dynamic>> history = [];
  final List<Map<String, dynamic>> pending = [];
  final List<Map<String, dynamic>> prompts = [];
  final Map<String, Map<String, dynamic>> receipts = {};
  bool subscribed = false;

  /// The session is held by the authority (created, resumed or running): the
  /// only population `session.active_list` reports.
  bool live = false;

  /// Corrections the authority accepted: verb, text, generation.
  final List<Map<String, dynamic>> corrections = [];

  /// The `attachments` each accepted submit named (`CanonicalAttachment`).
  final List<List<Map<String, dynamic>>> submittedAttachments = [];

  /// `session.create` requests that were accepted.
  final List<Map<String, dynamic>> creates = [];

  /// Unmodelled methods the client sent (the fake never answers them).
  final List<String> unmodelled = [];

  /// The next [failResumes] `session.resume` calls fail with a transient
  /// storage error (`RuntimeStoreError('storage_unavailable')`).
  int failResumes = 0;

  /// Delays the HTTP transcript read (`/sessions/<id>/messages`).
  Completer<void>? messagesGate;
  int _admissionCounter = 0;
  String subscriptionId = 'sub-1';

  // ---- observation -----------------------------------------------------
  final List<Map<String, dynamic>> frames = [];
  final List<WebSocket> sockets = [];
  final Completer<void> firstSocket = Completer<void>();

  /// Called with every request frame before the reply is built; a returned
  /// future delays the reply (the event pump keeps running).
  Future<void> Function(Map<String, dynamic> frame)? beforeReply;

  /// Runs after a `session.resume` snapshot was cut and before its reply is written.
  void Function()? duringResume;

  /// Called after the reply was written.
  void Function(Map<String, dynamic> frame, Map<String, dynamic>? result)?
  afterReply;

  List<Map<String, dynamic>> framesOf(String method) =>
      frames.where((f) => f['method'] == method).toList(growable: false);

  Map<String, dynamic> get snapshotJson => {
    'session_id': 's',
    'stored_session_id': 's',
    'messages': [for (final row in history) Map<String, dynamic>.of(row)],
    'message_count': history.length,
    'running': running,
    'authority_epoch': authorityEpoch,
    'replay_epoch': replayEpoch,
    'last_sequence': seq,
    'subscription_id': subscriptionId,
    'revision': revision,
    'execution_generation': generation,
    'pending': [for (final p in pending) Map<String, dynamic>.of(p)],
    'prompts': [for (final p in prompts) Map<String, dynamic>.of(p)],
    'info': {'desktop_protocol': 'hermes-gateway-v1'},
  };

  // ---- event production (SessionEvents.publish) -----------------------
  Map<String, dynamic> stamp(
    String type,
    Map<String, dynamic> payload, {
    String? admission,
    int? gen,
    bool withExecution = true,
  }) {
    seq += 1;
    final params = <String, dynamic>{
      if (withExecution) ...{
        'authority_epoch': authorityEpoch,
        'execution_generation': gen ?? generation,
        'admission_id': ?(admission ?? runningAdmission),
      },
      'type': type,
      'session_id': 's',
      'payload': payload,
      'replay_epoch': replayEpoch,
      'seq': seq,
    };
    final frame = {'jsonrpc': '2.0', 'method': 'event', 'params': params};
    ring.add(Map<String, dynamic>.from(jsonDecode(jsonEncode(params)) as Map));
    return frame;
  }

  /// Publishes to the ring and, when attached, to the live socket.
  void publish(
    String type, [
    Map<String, dynamic> payload = const {},
    String? admission,
    int? gen,
  ]) {
    final frame = stamp(type, payload, admission: admission, gen: gen);
    _live(frame);
  }

  /// Stamps into the ring only: the live frame is returned for the test to
  /// deliver later (a fanout write queued behind an RPC reply).
  Map<String, dynamic> publishDeferred(
    String type, [
    Map<String, dynamic> payload = const {},
    String? admission,
    int? gen,
  ]) => stamp(type, payload, admission: admission, gen: gen);

  void deliver(Map<String, dynamic> frame) => _live(frame);

  void _live(Map<String, dynamic> frame) {
    if (!subscribed || sockets.isEmpty) return;
    _send(sockets.last, frame);
  }

  void _send(WebSocket socket, Map<String, dynamic> frame) {
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(frame));
    } on StateError {
      // The peer closed between the readyState check and the write.
    }
  }

  /// Starts an admission on the authority (the FIFO drain claim).
  String startTurn({String? admission, String text = '', int? gen}) {
    final id = admission ?? 'adm-${++_admissionCounter}';
    generation = gen ?? generation + 1;
    running = true;
    runningAdmission = id;
    revision += 1;
    live = true;
    final row = receipts[id];
    if (row != null) {
      row['status'] = 'started';
      row['execution_generation'] = generation;
    }
    final index = pending.indexWhere((p) => p['admission_id'] == id);
    if (index >= 0) {
      pending[index] = {
        ...pending[index],
        'status': 'started',
        'execution_generation': generation,
      };
    }
    publish('message.start', {'text': text}, id, generation);
    return id;
  }

  void completeTurn({String text = 'done', String? admission, int? gen}) {
    final id = admission ?? runningAdmission;
    final g = gen ?? generation;
    history.addAll([
      {
        'role': 'assistant',
        'text': text,
        'content': text,
        'row_id': history.length + 1,
      },
    ]);
    publish('message.complete', {'text': text, 'status': 'complete'}, id, g);
    if (id != null && receipts[id] != null) {
      receipts[id]!['status'] = 'terminal';
      receipts[id]!['outcome'] = 'completed';
    }
    pending.removeWhere((p) => p['admission_id'] == id);
    if (id == runningAdmission) {
      running = false;
      runningAdmission = null;
    }
    revision += 1;
  }

  /// Terminal bookkeeping of [completeTurn] (receipt terminal, admission leaves
  /// `pending`, running cleared when it was the running one) WITHOUT appending
  /// an answer row or publishing: the test already wrote the durable answer
  /// row and delivers the deferred `message.complete` frame itself.
  void settleTerminal(String admission) {
    final receipt = receipts[admission];
    if (receipt != null) {
      receipt['status'] = 'terminal';
      receipt['outcome'] = 'completed';
    }
    pending.removeWhere((p) => p['admission_id'] == admission);
    if (admission == runningAdmission) {
      running = false;
      runningAdmission = null;
    }
    revision += 1;
  }

  Map<String, dynamic> prompt(
    String kind,
    String id, {
    int? gen,
    String question = 'Proceed?',
    String command = 'rm -rf /home/ana/tmp',
  }) => {
    'kind': kind,
    'prompt_id': id,
    'execution_generation': gen ?? generation,
    if (kind == 'approval') ...{
      'command': command,
      'description': 'dangerous',
      'choices': ['once', 'deny', 'session', 'always'],
    } else ...{
      'question': question,
      'choices': <String>[],
      'multi_select': false,
    },
  };

  void openPrompt(Map<String, dynamic> p) {
    prompts.add(p);
    publish('${p['kind']}.request', p, null, p['execution_generation'] as int);
  }

  void settlePrompt(String id, {String reason = 'timeout'}) {
    final p = prompts.firstWhere((p) => p['prompt_id'] == id);
    prompts.remove(p);
    publish(
      '${p['kind']}.settled',
      {'prompt_id': id, 'execution_generation': p['execution_generation']},
      null,
      p['execution_generation'] as int,
    );
  }

  // ---- request handling ------------------------------------------------
  Map<String, dynamic> _error(Object? id, int code, String reason) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {
      'code': code,
      'message': reason,
      'data': {'reason': reason},
    },
  };

  static const _resumeKeys = {
    'profile',
    'session_id',
    'title',
    'latest',
    'workspace',
    'source',
    'editor',
    'api_key',
    'defer_history',
    'omit_messages',
    'cols',
    'display_projection',
  };
  static const _submitKeys = {
    'profile',
    'session_id',
    'text',
    'submission_id',
    'input_id',
    'queued',
    'attachments',
    'finite',
    'unattended',
    'surface',
    'voice_context',
    'interrupted',
    'voice_turn',
    'display_kind',
    'title_preview',
    'turn_author',
    'api_text',
    'model_override',
    'clarify_batch',
  };

  Map<String, dynamic>? _handle(Map<String, dynamic> frame) {
    final id = frame['id'];
    final method = frame['method'];
    final params = Map<String, dynamic>.from(
      (frame['params'] as Map?) ?? const {},
    );
    bool exact(Set<String> keys) {
      final got = params.keys.toSet()..remove('profile');
      return got.length == keys.length && got.containsAll(keys);
    }

    Map<String, dynamic> ok(Map<String, dynamic> r) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': r,
    };
    if (legacyBackend) {
      switch (method) {
        case 'gateway.capabilities':
          return ok({'per_session_exclusive_submit': true});
        case 'session.resume':
          return ok({
            'session_id': 'runtime-legacy',
            'stored_session_id': params['session_id'],
            'running': false,
            'status': 'idle',
            'messages': [
              for (final row in history) Map<String, dynamic>.of(row),
            ],
          });
        case 'prompt.submit':
          return ok({'status': 'streaming'});
        case 'client.capabilities':
          return ok({'server_requests': <Object>[]});
        default:
          return ok(<String, dynamic>{});
      }
    }
    switch (method) {
      case 'session.resume':
        if (!params.keys.every(_resumeKeys.contains)) {
          return _error(id, 4001, 'invalid_params');
        }
        if (params['session_id'] != 's') return _error(id, 4001, 'not_found');
        if (failResumes > 0) {
          failResumes -= 1;
          return _error(id, 4001, 'storage_unavailable');
        }
        subscribed = true;
        live = true;
        final snapshot = snapshotJson;
        // Frames the authority publishes right after the atomic cut reach the
        // socket BEFORE the reply bytes (the fanout writer is another lane).
        duringResume?.call();
        return ok(snapshot);
      case 'prompt.submit':
        if (!params.keys.every(_submitKeys.contains)) {
          return _error(id, 4001, 'invalid_params');
        }
        final sub = params['submission_id'] ?? params['input_id'];
        if (sub is! String || sub.isEmpty) {
          return _error(id, 4001, 'invalid_params');
        }
        if (!subscribed || params['session_id'] != 's') {
          return _error(id, 4001, 'permission_denied');
        }
        final attached = params['attachments'];
        if (attached != null &&
            (attached is! List ||
                attached.any(
                  (a) =>
                      a is! Map ||
                      a.length != 2 ||
                      a['path'] is! String ||
                      a['mime'] is! String,
                ))) {
          return _error(id, 4001, 'invalid_params');
        }
        final existing = receipts[sub];
        if (existing != null) return ok(Map<String, dynamic>.of(existing));
        if (attached != null) {
          submittedAttachments.add([
            for (final a in attached as List)
              Map<String, dynamic>.from(a as Map),
          ]);
        }
        final admissionId = 'adm-${++_admissionCounter}';
        final queued = running;
        final receipt = <String, dynamic>{
          'admission_id': admissionId,
          'ref': {'profile_id': 'default', 'session_id': 's'},
          'sequence': _admissionCounter,
          'status': queued ? 'queued' : 'started',
          'outcome': null,
          'authority_epoch': authorityEpoch,
          'execution_generation': queued ? null : generation + 1,
        };
        receipts[sub] = receipt;
        receipts[admissionId] = receipt;
        history.add({
          'role': 'user',
          'text': params['text'],
          'content': params['text'],
          'row_id': history.length + 1,
        });
        // Queued and started rows stay listed until their terminal.
        pending.add({...receipt, 'input_id': sub, 'text': params['text']});
        live = true;
        return ok(Map<String, dynamic>.of(receipt));
      case 'approval.respond':
        if (!exact({
          'session_id',
          'execution_generation',
          'prompt_id',
          'choice',
        })) {
          return _error(id, 4001, 'invalid_params');
        }
        return _respond(id, params, 'approval');
      case 'clarify.respond':
        if (!exact({
          'session_id',
          'execution_generation',
          'prompt_id',
          'answer',
        })) {
          return _error(id, 4001, 'invalid_params');
        }
        return _respond(id, params, 'clarify');
      case 'session.interrupt':
        if (!exact({'session_id', 'execution_generation'})) {
          return _error(id, 4001, 'invalid_params');
        }
        return ok({
          'ref': {'profile_id': 'default', 'session_id': 's'},
          'instance_id': 'inst',
          'authority_epoch': authorityEpoch,
          'revision': revision,
          'execution_generation': generation,
          'execution_state': running ? 'running' : 'idle',
        });
      case 'session.events.since':
        final seqParam = params['last_sequence'] ?? params['last_seen'] ?? 0;
        final missing =
            params['replay_epoch'] != replayEpoch || (seqParam as int) > seq;
        final events = missing
            ? <Map<String, dynamic>>[]
            : [
                for (final e in ring)
                  if ((e['seq'] as int) > seqParam) e,
              ];
        return ok({
          'events': events,
          'latest_seq': seq,
          'last_sequence': seq,
          'epoch': replayEpoch,
          'replay_epoch': replayEpoch,
          'truncated': missing,
          'snapshot_required': missing,
          'count': events.length,
        });
      case 'session.active_list':
        if (!params.keys.every(const {'current_session_id'}.contains)) {
          return _error(id, 4001, 'invalid_params');
        }
        return ok({'sessions': activeRows(params['current_session_id'])});
      case 'client.capabilities':
        return ok({'server_requests': <Object>[]});
      case 'gateway.capabilities':
        // Not an authority verb: `ws_legacy_fallback` lets the sidecar answer
        // it (it is outside the session namespaces).
        return ok({'per_session_exclusive_submit': true});
      case 'session.history':
        // `session_history`: closed {session_id, profile}, a live session.
        if (!exact({'session_id'}) || params['session_id'] != 's') {
          return _error(id, 4001, 'invalid_params');
        }
        if (!live) return _error(id, 4001, 'not_found');
        return ok({
          'count': history.length,
          'messages': [for (final row in history) Map<String, dynamic>.of(row)],
        });
      case 'subagent.list':
      case 'process.list':
        // `session_ancillary.read`: closed {session_id, profile}, a live
        // session; an empty roster (no child agents / processes).
        if (!exact({'session_id'}) || params['session_id'] != 's') {
          return _error(id, 4001, 'invalid_params');
        }
        if (!live) return _error(id, 4001, 'not_found');
        return ok(
          method == 'subagent.list'
              ? {'subagents': <Object>[], 'delegations': <Object>[]}
              : {'processes': <Object>[]},
        );
      case 'session.steer':
      case 'session.redirect':
        // `CanonicalCorrectionParams`: generation and text are mandatory.
        if (!exact({'session_id', 'execution_generation', 'text'}) ||
            params['execution_generation'] is! int ||
            params['text'] is! String) {
          return _error(id, 4001, 'invalid_params');
        }
        if (!subscribed || params['session_id'] != 's') {
          return _error(id, 4001, 'permission_denied');
        }
        if (params['execution_generation'] != generation) {
          return _error(id, 4001, 'stale_generation');
        }
        final correction = <String, dynamic>{
          'verb': method,
          'text': params['text'],
          'execution_generation': params['execution_generation'],
        };
        if (!running) {
          // No agent was live: nothing saw it, safe to admit as a prompt.
          return ok({
            'status': 'rejected',
            'text': params['text'],
            'execution_generation': generation,
            'authority_epoch': authorityEpoch,
            'delivered': false,
          });
        }
        corrections.add(correction);
        return ok({
          'status': method == 'session.redirect' ? 'redirected' : 'queued',
          'text': params['text'],
          'execution_generation': generation,
          'authority_epoch': authorityEpoch,
        });
      case 'session.create':
        return _create(id, params);
      case 'image.attach_bytes':
        // `session_images.attach_bytes`: strings only, a subscribed session.
        if (!params.keys.every(
              const {
                'session_id',
                'content_base64',
                'data',
                'filename',
                'ext',
              }.contains,
            ) ||
            params.values.any((v) => v is! String)) {
          return _error(id, 4001, 'invalid_params');
        }
        if (!subscribed || params['session_id'] != 's') {
          return _error(id, 4001, 'permission_denied');
        }
        final name = (params['filename'] as String?) ?? 'upload.png';
        return ok({
          'attached': true,
          'path': '/home/ana/cache/images/$name',
          'mime': 'image/png',
          'name': name,
          'count': 1,
          'remainder': '',
          'text': '[User attached image: $name]',
          'bytes': 4,
        });
      case 'file.attach':
        // `session_ancillary.attach_file`.
        if (!params.keys.every(
              const {'session_id', 'path', 'data_url', 'name'}.contains,
            ) ||
            params.values.any((v) => v is! String)) {
          return _error(id, 4001, 'invalid_params');
        }
        if (!subscribed || params['session_id'] != 's') {
          return _error(id, 4001, 'permission_denied');
        }
        return ok({
          'attached': true,
          'name': 'note.txt',
          'path': '/home/ana/attachments/note.txt',
          'ref_path': 'attachments/note.txt',
          'ref_text': '@file:attachments/note.txt',
          'uploaded': true,
        });
      case 'turn.status':
      case 'session.activate':
      case 'session.close':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': -32601,
            'message': 'unknown method: $method',
            'data': {'reason': 'unknown_method'},
          },
        };
      default:
        // The authority does not model it: surface it instead of pretending.
        unmodelled.add('$method');
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': -32601,
            'message': 'unmodelled method: $method',
            'data': {'reason': 'unknown_method'},
          },
        };
    }
  }

  /// `session.active_list` rows (`gateway/session_active_list.py`): `id` and
  /// `session_key` are both the session id; `status` is derived from the
  /// execution state, prompts and queued rows.
  List<Map<String, dynamic>> activeRows(Object? current) {
    if (!live) return const [];
    final status = running
        ? (prompts.isNotEmpty ? 'waiting' : 'working')
        : (pending.any((p) => p['status'] == 'queued') ? 'starting' : 'idle');
    return [
      {
        'current': current == 's',
        'id': 's',
        'session_key': 's',
        'last_active': 1700000100.0,
        'started_at': 1700000000.0,
        'message_count': history.length,
        'model': 'm',
        'preview': '',
        'title': 'fixture',
        'source': 'desktop',
        'status': status,
      },
    ];
  }

  static const _createKeys = {
    'request_id',
    'source',
    'cwd',
    'row_cwd',
    'model',
    'provider',
    'base_url',
    'api_key',
    'toolsets',
    'reasoning',
    'max_turns',
    'ignore_rules',
    'yolo',
    'safe_mode',
    'ignore_user_config',
    'skills',
    'checkpoints',
    'accept_hooks',
    'pass_session_id',
    'editor',
    'title',
    'hidden',
    'follow_profile_config',
    'service_tier',
    'cwd_explicit',
    'run_budget',
    'verbose',
    'client_env',
  };
  static const _surfaces = {'cli', 'tui', 'gui', 'acp', 'tool', 'oneshot'};

  /// `CanonicalCreateParams`: closed keys, a creating surface; answers a
  /// `CanonicalSnapshot` and attaches the caller (`session.create` attaches).
  Map<String, dynamic> _create(Object? id, Map<String, dynamic> params) {
    final source = params['source'] ?? 'cli';
    if (!params.keys.every((k) => k == 'profile' || _createKeys.contains(k)) ||
        source is! String ||
        !_surfaces.contains(source)) {
      return _error(id, 4001, 'invalid_params');
    }
    creates.add(Map<String, dynamic>.of(params));
    history.clear();
    pending.clear();
    prompts.clear();
    running = false;
    runningAdmission = null;
    subscribed = true;
    live = true;
    return {'jsonrpc': '2.0', 'id': id, 'result': snapshotJson};
  }

  Map<String, dynamic> _respond(
    Object? id,
    Map<String, dynamic> params,
    String kind,
  ) {
    final promptId = params['prompt_id'];
    final index = prompts.indexWhere((p) => p['prompt_id'] == promptId);
    if (index < 0) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': {'status': 'already_resolved', 'prompt_id': promptId},
      };
    }
    final p = prompts[index];
    if (p['execution_generation'] != params['execution_generation']) {
      return _error(id, 4001, 'stale_generation');
    }
    prompts.removeAt(index);
    publish(
      '$kind.settled',
      {
        'prompt_id': promptId,
        'execution_generation': p['execution_generation'],
      },
      null,
      p['execution_generation'] as int,
    );
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {'status': 'resolved', 'prompt_id': promptId},
    };
  }

  Future<void> _onRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/') {
      request.response.write(
        'window.__HERMES_SESSION_TOKEN__="fixture-token";',
      );
    } else if (path == '/api/auth/ws-ticket') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ticket': 'fixture-ticket'}));
    } else if (path.endsWith('/sessions/s/messages')) {
      await messagesGate?.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'session_id': 's', 'messages': history}),
      );
    } else if (path == '/api/ws') {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      subscribed = false; // a new connection has no subscription
      if (!firstSocket.isCompleted) firstSocket.complete();
      _send(socket, {
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {
            'heartbeat': false,
            'replay_epoch': 'process-1',
            'change_events': true,
            if (advertise != null && advertise != 'absent')
              'session_authority': advertise,
          },
        },
      });
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] == null) continue;
        frames.add(frame);
        await beforeReply?.call(frame);
        final reply = _handle(frame);
        if (reply != null) _send(socket, reply);
        afterReply?.call(frame, reply?['result'] as Map<String, dynamic>?);
      }
      return;
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
  }

  Future<void> close() async {
    for (final s in sockets) {
      await s.close();
    }
    await server.close(force: true);
  }

  /// Convenience for tests: waits until a request frame of [method] arrived.
  Future<void> waitFor(String method, {int count = 1}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (framesOf(method).length < count) {
      if (DateTime.now().isAfter(deadline)) {
        fail('no $method frame arrived; saw ${frames.map((f) => f['method'])}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
