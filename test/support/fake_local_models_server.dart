import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/local_models_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_models_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Fake Hermes Dashboard exposing `/api/local-models/*` exactly as
/// `hermes_cli/web_routers/local_models.py` answers it. Records every call so
/// tests can assert the method, path, query and body Console sent.
class FakeLocalModelsServer {
  FakeLocalModelsServer({this.routesPresent = true});

  bool routesPresent;
  final calls = <({String method, String path, String query, Object? body})>[];

  String? activeModelId = 'Qwen3-8B-Q4_K_M';
  bool serverRunning = true;
  bool runtimeInstalled = true;
  final models = <Map<String, Object?>>[
    {'id': 'Qwen3-8B-Q4_K_M', 'size_bytes': 5 << 30, 'size_label': '5.0 GB'},
    {
      'id': 'gemma-3-4b-it-UD-Q8_K_XL',
      'size_bytes': 4 << 30,
      'size_label': '4.0 GB',
    },
  ];
  final loaded = <String, String>{'Qwen3-8B-Q4_K_M': 'loaded'};
  final jobs = <Map<String, Object?>>[];

  /// Replaces the default two-row catalog when set.
  List<Map<String, Object?>>? catalog;

  /// Next response override per "METHOD path" (status, detail).
  final failures = <String, (int, String)>{};

  int _seq = 0;

  Map<String, Object?> status() => {
    'enabled': true,
    'tag': 'b6500',
    'configured_tag': 'b6500',
    'update_available': false,
    'runtime_installed': runtimeInstalled,
    'runtime_backend': runtimeInstalled ? 'cuda' : null,
    'server_running': serverRunning,
    'server_base_url': serverRunning ? 'http://127.0.0.1:8090/v1' : null,
    'active_model_id': activeModelId,
    'loaded_models': loaded,
    'loading': <String, Object?>{},
    'placement': <String, Object?>{},
    'models': models,
    'models_dir': '/srv/hermes/models',
  };

  Map<String, Object?> _job(String kind, String target, String? modelId) {
    final job = <String, Object?>{
      'job_id': 'job${++_seq}',
      'kind': kind,
      'target': target,
      'model_id': modelId,
      'status': 'running',
      'phase': 'downloading',
      'detail': 'Downloading $target',
      'total_bytes': 1000,
      'done_bytes': 250,
      'percent': 25,
      'error': null,
      'can_pause': kind == 'model-download',
      'can_resume': false,
      'pause_requested': false,
    };
    jobs.insert(0, job);
    return job;
  }

  void finishJob(String id, {String? error}) {
    final job = jobs.firstWhere((j) => j['job_id'] == id);
    job['status'] = error == null ? 'done' : 'error';
    job['error'] = error;
    job['can_pause'] = false;
    if (error == null && job['kind'] == 'model-activate') {
      activeModelId = job['model_id'] as String?;
    }
    if (error == null && job['kind'] == 'model-download') {
      models.add({
        'id': job['model_id'],
        'size_bytes': 1000,
        'size_label': '1.0 KB',
      });
    }
  }

  http.Client get client => MockClient((request) async {
    final path = request.url.path;
    Object? body;
    if (request.body.isNotEmpty) body = jsonDecode(request.body);
    calls.add((
      method: request.method,
      path: path,
      query: request.url.query,
      body: body,
    ));
    if (!path.startsWith('/api/local-models') || !routesPresent) {
      // FastAPI's SPA catch-all answers unknown /api/* with JSON 404.
      return http.Response(jsonEncode({'detail': 'Not Found'}), 404);
    }
    final failure = failures.remove('${request.method} $path');
    if (failure != null) {
      return http.Response(jsonEncode({'detail': failure.$2}), failure.$1);
    }
    Map<String, Object?> b() => (body as Map).cast<String, Object?>();
    switch ((request.method, path)) {
      case ('GET', '/api/local-models/status'):
        return _json(status());
      case ('GET', '/api/local-models/catalog'):
        final custom = catalog;
        if (custom != null) return _json({'models': custom});
        return _json({
          'models': [
            {
              'id': 'qwen3-14b',
              'display_name': 'Qwen3 14B',
              'description': 'Strong general model',
              'size_bytes': 9 << 30,
              'size_label': '9.0 GB',
              'recommended': true,
              'downloaded': false,
              'fits': true,
              'model_id': 'Qwen3-14B-Q4_K_M',
              'quant': 'Q4_K_M',
              'fit_summary': 'runs at its full 40K context',
              'needs_engine': false,
            },
            {
              'id': 'huge-405b',
              'display_name': 'Huge 405B',
              'description': '',
              'size_label': '220.0 GB',
              'recommended': false,
              'downloaded': false,
              'fits': false,
              'fit_summary': 'Needs more memory than this machine has',
              'needs_engine': false,
            },
          ],
        });
      case ('GET', '/api/local-models/jobs'):
        return _json({'jobs': jobs});
      case ('POST', '/api/local-models/activate'):
        final id = b()['model_id'] as String;
        if (!models.any((m) => m['id'] == id)) {
          return http.Response(
            jsonEncode({'detail': '$id is not downloaded'}),
            404,
          );
        }
        final job = _job('model-activate', id, id);
        job['phase'] = 'starting-server';
        job['total_bytes'] = null;
        job['percent'] = null;
        return _json({'job_id': job['job_id']});
      case ('POST', '/api/local-models/eject'):
        loaded.remove(b()['model_id']);
        return _json({'ok': true});
      case ('POST', '/api/local-models/download'):
        final job = _job('model-download', 'Qwen3 14B (Q4_K_M)', 'qwen3-14b');
        return _json({'job_id': job['job_id'], 'model_id': 'Qwen3-14B-Q4_K_M'});
      case ('POST', '/api/local-models/download/pause'):
        final job = jobs.firstWhere((j) => j['job_id'] == b()['job_id']);
        job['status'] = 'paused';
        job['can_pause'] = false;
        job['can_resume'] = true;
        return _json({'ok': true, 'paused': true});
      case ('POST', '/api/local-models/download/resume'):
        final job = jobs.firstWhere((j) => j['job_id'] == b()['job_id']);
        job['status'] = 'running';
        job['can_pause'] = true;
        job['can_resume'] = false;
        return _json({'ok': true, 'resumed': true});
      case ('POST', '/api/local-models/server'):
        serverRunning = b()['action'] == 'start';
        if (!serverRunning) loaded.clear();
        return _json({'ok': true, 'action': b()['action']});
      case ('POST', '/api/local-models/runtime/install'):
        final job = _job('runtime-install', 'llama.cpp b6500 (cuda)', null);
        return _json({
          'job_id': job['job_id'],
          'backend': 'cuda',
          'tag': 'b6500',
        });
      case ('GET', '/api/local-models/search'):
        return _json({
          'hits': [
            {
              'repo': 'unsloth/Qwen3-4B-GGUF',
              'downloads': 120000,
              'likes': 340,
              'updated': '2026-09-01',
              'gated': false,
            },
          ],
        });
      case ('GET', '/api/local-models/search/files'):
        return _json({
          'files': [
            {
              'label': 'Q4_K_M',
              'paths': ['Qwen3-4B-Q4_K_M.gguf'],
              'total_bytes': 2500000000,
              'fit': 'fits-gpu',
            },
            {
              'label': 'BF16',
              'paths': [
                'BF16/Qwen3-4B-BF16-00001-of-00002.gguf',
                'BF16/Qwen3-4B-BF16-00002-of-00002.gguf',
              ],
              'total_bytes': 8000000000,
              'fit': 'too-big',
            },
            {
              'label': 'Q8_0',
              'paths': [
                'Q8_0/Qwen3-4B-Q8_0-00001-of-00002.gguf',
                'Q8_0/Qwen3-4B-Q8_0-00002-of-00002.gguf',
              ],
              'total_bytes': 4300000000,
              'fit': 'needs-ram',
            },
          ],
        });
      case ('POST', '/api/local-models/download-browsed'):
        final paths = (b()['paths'] as List).cast<String>();
        final id = paths.first.split('/').last.replaceAll('.gguf', '');
        final job = _job('model-download', '$id (from ${b()['repo']})', id);
        return _json({'job_id': job['job_id'], 'model_id': id});
    }
    if (request.method == 'DELETE' &&
        path.startsWith('/api/local-models/models/')) {
      final id = Uri.decodeComponent(
        path.substring('/api/local-models/models/'.length),
      );
      final before = models.length;
      models.removeWhere((m) => m['id'] == id);
      if (models.length == before) {
        return http.Response(jsonEncode({'detail': 'model not found'}), 404);
      }
      if (activeModelId == id) activeModelId = null;
      loaded.remove(id);
      return _json({'ok': true});
    }
    return http.Response(jsonEncode({'detail': 'Not Found'}), 404);
  });

  http.Response _json(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json'},
  );

  Iterable<({String method, String path, String query, Object? body})>
  writes() => calls.where((c) => c.method != 'GET');
}

DashboardClient fakeDashboard(FakeLocalModelsServer server) => DashboardClient(
  host: 'hermes.local',
  port: 9119,
  manualToken: 'dashboard-token',
  httpClientOverride: server.client,
);

SavedConnection fakeConnection({bool readOnly = false}) => SavedConnection(
  id: 'c1',
  label: 'Server',
  host: 'hermes.example.net',
  port: 8642,
  apiKey: 'k',
  readOnly: readOnly,
);

Future<void> pumpLocalModels(
  WidgetTester tester,
  FakeLocalModelsServer server, {
  bool readOnly = false,
  String profile = '',
  ThemeData? theme,
  Locale locale = const Locale('es'),
  Size size = const Size(412, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: theme ?? AppTheme.hermesRedDark,
      home: LocalModelsScreen(
        connection: fakeConnection(readOnly: readOnly),
        profile: profile,
        client: LocalModelsClient(fakeDashboard(server), profile: profile),
        pollInterval: const Duration(milliseconds: 100),
        pausedPollInterval: const Duration(milliseconds: 300),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
