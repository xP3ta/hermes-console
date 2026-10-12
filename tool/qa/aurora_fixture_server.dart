// Fictional "Project Aurora" Hermes, for the public screenshot set.
//
// A synthetic stand-in for a Hermes Agent: Gateway REST (port 18642), Dashboard
// REST + JSON-RPC WebSocket (port 19119). Everything it serves is invented: a
// small product team shipping the launch of a fictional mobile app, with bots,
// rooms, scheduled tasks and a task board. It holds no secret, reads nothing
// from the host and never talks to the network; the emulator reaches it at
// 10.0.2.2. It is NOT the real Hermes: do not point it at, or run it next to,
// anything private.
//
//   dart run tool/qa/aurora_fixture_server.dart [--gateway-port=18642]
//       [--dashboard-port=19119]
//
// Control endpoints (Dashboard port, loopback use only):
//   GET /__aurora/hold      hold the next live turn open (reasoning/tools/tasks
//                           shown, never completed) so it can be photographed
//   GET /__aurora/release   finish the held turn
//   GET /__aurora/log       request counters
//   GET /__aurora/unknown   RPC methods and paths the fixture did not know
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'aurora_data.dart';

final class AuroraFixture {
  AuroraFixture({required this.gatewayPort, required this.dashboardPort});

  final int gatewayPort;
  final int dashboardPort;
  final data = AuroraData();
  final Map<String, int> _counts = {};
  final Set<String> _unknown = {};
  final List<WebSocket> _sockets = [];
  bool _hold = false;
  Completer<void>? _release;
  var _runtimeSerial = 0;
  final Map<String, String> _runtimeToStored = {};

  Future<void> run() async {
    final gateway = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      gatewayPort,
    );
    final dashboard = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      dashboardPort,
    );
    gateway.listen(_handleGateway);
    dashboard.listen(_handleDashboard);
    stdout.writeln(
      'Aurora fixture ready: gateway=$gatewayPort dashboard=$dashboardPort',
    );
    await ProcessSignal.sigint.watch().first;
    await Future.wait([
      gateway.close(force: true),
      dashboard.close(force: true),
    ]);
  }

  void _count(String key) =>
      _counts.update(key, (value) => value + 1, ifAbsent: () => 1);

  // ---------------------------------------------------------------- gateway

  Future<void> _handleGateway(HttpRequest request) async {
    final path = request.uri.path;
    _count('gateway:${request.method}:$path');
    if (request.method == 'GET' && path == '/health') {
      return _json(request.response, {'status': 'ok', 'version': '0.20.1'});
    }
    if (request.method == 'GET' && path == '/api/sessions') {
      return _json(request.response, {'data': data.sessionRows()});
    }
    final messages = RegExp(
      r'^(?:/p/[^/]+)?/api/sessions/([^/]+)/messages$',
    ).firstMatch(path);
    if (request.method == 'GET' && messages != null) {
      final id = Uri.decodeComponent(messages.group(1)!);
      return _json(request.response, _transcript(id));
    }
    if (request.method == 'GET' && path == '/v1/models') {
      return _json(request.response, {
        'object': 'list',
        'data': [
          {'id': 'hermes-agent', 'object': 'model', 'owned_by': 'hermes'},
        ],
      });
    }
    if (request.method == 'GET' && path == '/v1/capabilities') {
      return _json(request.response, {
        'object': 'hermes.api_server.capabilities',
        'version': '0.20.1',
        'features': {
          'chat': true,
          'streaming': true,
          'sessions': true,
          'skills_api': true,
          'toolsets': true,
        },
        'endpoints': {'chat': '/v1/chat/completions', 'sessions': '/api/sessions'},
      });
    }
    if (request.method == 'GET' && path == '/v1/skills') {
      return _json(request.response, {'skills': data.skills()});
    }
    if (request.method == 'GET' && path == '/v1/toolsets') {
      return _json(request.response, {'toolsets': data.toolsets()});
    }
    _unknown.add('gateway ${request.method} $path');
    return _json(request.response, {'error': 'not_found'}, status: 404);
  }

  // -------------------------------------------------------------- dashboard

  Future<void> _handleDashboard(HttpRequest request) async {
    final path = request.uri.path;
    _count('dashboard:${request.method}:$path');

    if (path == '/api/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      unawaited(_serveSocket(socket));
      return;
    }
    if (path == '/api/plugins/kanban/events' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      // Live Kanban events: accepted and left quiet.
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {}, onError: (_) {});
      return;
    }
    if (path == '/__aurora/hold') {
      _hold = true;
      return _json(request.response, {'hold': true});
    }
    if (path == '/__aurora/release') {
      _hold = false;
      _release?.complete();
      return _json(request.response, {'hold': false});
    }
    if (path == '/__aurora/clock') {
      final epoch = double.tryParse(request.uri.queryParameters['epoch'] ?? '');
      if (epoch != null) {
        clockOffsetSeconds =
            epoch - DateTime.now().millisecondsSinceEpoch / 1000;
      }
      return _json(request.response, {'offset': clockOffsetSeconds});
    }
    if (path == '/__aurora/log') {
      return _json(request.response, _counts);
    }
    if (path == '/__aurora/unknown') {
      return _json(request.response, _unknown.toList()..sort());
    }
    if (request.method == 'GET' && path == '/') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><script>'
          'window.__HERMES_SESSION_TOKEN__="aurora-demo-token";'
          '</script>',
        );
      return request.response.close();
    }
    if (request.method == 'GET' &&
        RegExp(r'^(/p/[^/]+)?/api/files/download$').hasMatch(path)) {
      final file = File('${_fixtureDir()}/aurora-brief.pdf');
      if (!file.existsSync()) {
        return _json(request.response, {'error': 'not_found'}, status: 404);
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'pdf')
        ..add(file.readAsBytesSync());
      return request.response.close();
    }
    if (request.method == 'POST' && path == '/api/auth/ws-ticket') {
      return _json(request.response, {'ticket': 'aurora-ws-ticket'});
    }
    final body = await _body(request);
    final json = _dashboardJson(request, path, body);
    if (json != null) return _json(request.response, json);
    _unknown.add('dashboard ${request.method} $path');
    if (request.method == 'GET' && path.startsWith('/api/')) {
      return _json(request.response, <String, dynamic>{});
    }
    if (request.method == 'POST' && path.startsWith('/api/')) {
      return _json(request.response, {'ok': true});
    }
    return _json(request.response, {'error': 'not_found'}, status: 404);
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.method == 'GET') return {};
    try {
      final text = await utf8.decoder.bind(request).join();
      final decoded = text.isEmpty ? null : jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Map<String, dynamic> _transcript(String id) {
    final rows = data.messages(id);
    return {
      'session_id': id,
      'messages': rows,
      'data': rows,
      'pagination': {
        'limit': 500,
        'offset': 0,
        'total': rows.length,
        'has_more': false,
      },
    };
  }

  Object? _dashboardJson(
    HttpRequest request,
    String path,
    Map<String, dynamic> body,
  ) {
    final method = request.method;
    final query = request.uri.queryParameters;
    if (method == 'GET' && path == '/api/status') {
      return {
        'status': 'ok',
        'version': '0.20.1',
        'release_date': '2026-10-08',
        'gateway_running': true,
        'gateway_state': 'running',
        'active_sessions': 2,
        'config_version': 4,
        'latest_config_version': 4,
        'auth_required': false,
      };
    }
    if (method == 'GET' && path == '/api/config') return data.serverConfig();
    if (method == 'GET' && path == '/api/config/schema') {
      return data.configSchema();
    }
    if (method == 'GET' && path == '/api/model/info') return data.modelInfo();
    if (method == 'GET' && path == '/api/model/options') {
      return data.modelCatalog();
    }
    if (method == 'GET' && path == '/api/profiles') {
      return {'profiles': data.profileNames()};
    }
    if (method == 'GET' && path == '/api/skills') {
      return {'skills': data.skills()};
    }
    if (method == 'GET' && path == '/api/logs') return {'lines': <String>[]};
    if (method == 'GET' && path == '/api/model/auxiliary') {
      return data.auxiliary();
    }
    if (method == 'GET' && path == '/api/providers/oauth') {
      return {'providers': data.oauthProviders()};
    }
    if (method == 'GET' && path == '/api/providers/custom-endpoints') {
      return {'endpoints': <Object>[]};
    }
    if (method == 'GET' && path == '/api/env') return data.env();
    if (method == 'GET' && path == '/api/local-models/status') {
      return {'enabled': false};
    }
    final detail = RegExp(r'^/api/sessions/([^/]+)(/messages)?$').firstMatch(path);
    if (method == 'GET' && detail != null) {
      final id = Uri.decodeComponent(detail.group(1)!);
      if (detail.group(2) != null) return _transcript(id);
      final row = data.sessionRows().where((r) => r['id'] == id).firstOrNull;
      return row == null ? null : {'session': row};
    }
    if (method == 'GET' && path == '/api/sessions') {
      final rows = data.sessionRows();
      final profile = query['profile'];
      final listed = [
        for (final row in rows)
          if (profile == null || profile == 'all' || row['profile'] == profile)
            row,
      ];
      return {'sessions': listed, 'total': listed.length};
    }
    if (method == 'GET' && path == '/api/profiles/sessions') {
      final rows = data.sessionRows();
      return {'sessions': rows, 'total': rows.length};
    }
    if (method == 'GET' && path == '/api/cron/jobs') {
      return data.cronJobs(query['profile']);
    }
    if (path.startsWith('/api/plugins/kanban/')) {
      return data.kanban(method, path, query, body);
    }
    return null;
  }

  // -------------------------------------------------------------- websocket

  Future<void> _serveSocket(WebSocket socket) async {
    try {
      // Every Hermes socket opens with a global gateway.ready; without it the
      // app treats the connection as not established.
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'heartbeat': false, 'change_events': false},
          },
        }),
      );
      await for (final raw in socket) {
        if (raw is! String) continue;
        if (Platform.environment['AURORA_DEBUG'] == '1') {
          stdout.writeln('ws< ${raw.length > 240 ? raw.substring(0, 240) : raw}');
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final frame = Map<String, dynamic>.from(decoded);
        final method = frame['method']?.toString() ?? '';
        final id = frame['id'];
        final params = frame['params'] is Map
            ? Map<String, dynamic>.from(frame['params'] as Map)
            : <String, dynamic>{};
        _count('rpc:$method');
        Object? result;
        try {
          result = _rpc(socket, method, params);
        } catch (error) {
          stdout.writeln('rpc $method failed: $error');
          result = const _RpcError(-32000, 'fixture error');
        }
        if (result is _RpcError) {
          _unknown.add('rpc $method');
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': result.code, 'message': result.message},
            }),
          );
          continue;
        }
        socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
        if (method == 'prompt.submit') {
          unawaited(_emitTurn(socket, params));
        }
      }
    } on WebSocketException {
      // The emulator closed the walkthrough; the next socket carries on.
    } finally {
      _sockets.remove(socket);
    }
  }

  Object _rpc(WebSocket socket, String method, Map<String, dynamic> params) {
    switch (method) {
      case 'client.capabilities':
        return {
          'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
        };
      case 'gateway.capabilities':
        return {'per_session_exclusive_submit': true};
      case 'ping':
        return {'ok': true};
      case 'session.resume':
        final stored = _str(params['session_id']) ?? AuroraData.defaultSessionId;
        return _snapshot(stored);
      case 'session.create':
        final stored = 'aurora-new-${DateTime.now().microsecondsSinceEpoch}';
        data.newSession(stored, _str(params['profile']));
        final snapshot = _snapshot(stored);
        snapshot['stored_session_id'] = stored;
        return snapshot;
      case 'session.activate':
        final runtime = _str(params['session_id']);
        final stored = runtime == null
            ? null
            : _runtimeToStored[runtime] ?? data.storedForRuntime(runtime);
        if (runtime == null || stored == null) {
          return const _RpcError(4007, 'session not found');
        }
        return _snapshot(stored, runtime: runtime);
      case 'session.list':
        return {'sessions': data.rpcSessionRows(params)};
      case 'session.active_list':
        return {'sessions': data.activeSessions()};
      case 'free_tier.status':
        return {'available': false};
      case 'session.control.read':
        return {'controls': <String, dynamic>{}};
      case 'prompt.submit':
        return {'status': 'accepted'};
      case 'session.history':
        final runtime = _str(params['session_id']);
        final stored = runtime == null
            ? null
            : _runtimeToStored[runtime] ?? data.storedForRuntime(runtime);
        return {'messages': data.messages(stored ?? AuroraData.defaultSessionId)};
      case 'session.foreign.list':
        return {'sessions': <Object>[]};
      case 'subagent.list':
        return {'subagents': <Object>[]};
      case 'pet.info':
        return {'enabled': false};
      case 'session.usage':
        return data.sessionUsage();
      case 'usage.bars':
        return data.usageBars();
      case 'session.interrupt':
        return {'status': 'interrupted'};
      case 'session.steer':
        return {'status': 'queued'};
      case 'session.title':
      case 'session.set_hidden':
      case 'session.compress':
      case 'config.set':
      case 'profiles.configure':
        return {'ok': true};
      case 'session.context_breakdown':
        return data.contextBreakdown();
      case 'profiles.list':
        return data.profilesList();
      case 'profiles.describe':
        return data.profileDescribe(_str(params['name']) ?? 'default');
      case 'groups.capabilities':
        return data.groupsCapabilities();
      case 'groups.list':
        return data.groupsList();
      case 'groups.state':
        return data.groupsState(_str(params['room_id']) ?? '');
      case 'groups.log':
        return data.groupsLog(params);
      case 'groups.send':
        return data.groupsSend(params);
      case 'model.options':
        return data.modelCatalog();
      case 'commands.catalog':
        return data.commandsCatalog();
      case 'complete.slash':
        return {'replace_from': 1, 'items': <Object>[]};
      case 'tools.list':
        return {'toolsets': data.toolsets()};
      case 'plugins.manage':
        return {'plugins': <Object>[]};
      case 'process.list':
        return {'processes': <Object>[]};
      case 'spawn_tree.list':
        return {'entries': <Object>[]};
      case 'projects.tree':
        return data.projectsTree();
      case 'config.get':
        return {'value': null};
      default:
        return data.rpcFallback(method, params) ??
            const _RpcError(-32601, 'method unavailable');
    }
  }

  Map<String, dynamic> _snapshot(String stored, {String? runtime}) {
    final runtimeId = runtime ?? 'rt-aurora-${++_runtimeSerial}';
    _runtimeToStored[runtimeId] = stored;
    return data.snapshot(stored, runtimeId);
  }

  // ------------------------------------------------------------ live turns

  Future<void> _emitTurn(WebSocket socket, Map<String, dynamic> params) async {
    final runtime = _str(params['session_id']);
    if (runtime == null) return;
    final stored = _runtimeToStored[runtime] ?? AuroraData.defaultSessionId;
    final prompt = params['text'] is String ? params['text'] as String : '';
    final hold = _hold || prompt.contains('AURORA_LIVE');
    final script = data.liveTurn(stored, prompt, hold: hold);
    var assistant = StringBuffer();
    for (final step in script) {
      if (socket.readyState != WebSocket.open) return;
      if (step is TurnPause) {
        _release = Completer<void>();
        await _release!.future;
        continue;
      }
      await Future<void>.delayed(Duration(milliseconds: step.delayMs));
      _event(socket, runtime, step.type, step.payload);
      if (step.type == 'message.delta') {
        assistant.write(step.payload['text']);
      }
    }
    data.appendTurn(stored, prompt, assistant.toString());
    if (socket.readyState == WebSocket.open) {
      _event(socket, runtime, 'session.info', {
        'info': data.snapshot(stored, runtime)['info'],
      });
    }
  }

  void _event(
    WebSocket socket,
    String runtime,
    String type,
    Map<String, dynamic> payload,
  ) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': type, 'session_id': runtime, 'payload': payload},
      }),
    );
  }

  /// Directory of the fixture files next to this script.
  String _fixtureDir() =>
      '${File.fromUri(Platform.script).parent.path}/fixtures';

  Future<void> _json(
    HttpResponse response,
    Object body, {
    int status = HttpStatus.ok,
  }) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }

  String? _str(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

final class _RpcError {
  const _RpcError(this.code, this.message);
  final int code;
  final String message;
}

Future<void> main(List<String> args) async {
  var gatewayPort = 18642;
  var dashboardPort = 19119;
  for (final arg in args) {
    if (arg.startsWith('--gateway-port=')) {
      gatewayPort = int.parse(arg.substring('--gateway-port='.length));
    } else if (arg.startsWith('--dashboard-port=')) {
      dashboardPort = int.parse(arg.substring('--dashboard-port='.length));
    } else {
      stderr.writeln('Unknown argument: $arg');
      exitCode = 64;
      return;
    }
  }
  if (gatewayPort == 8642 ||
      dashboardPort == 9119 ||
      gatewayPort == dashboardPort ||
      gatewayPort < 1024 ||
      dashboardPort < 1024) {
    stderr.writeln(
      'Fixture ports must be distinct, >= 1024 and never the real Hermes '
      'ports (8642, 9119).',
    );
    exitCode = 64;
    return;
  }
  await AuroraFixture(
    gatewayPort: gatewayPort,
    dashboardPort: dashboardPort,
  ).run();
}
