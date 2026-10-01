import 'dart:convert';

import 'connection_manager.dart';

/// Client for the Hermes-managed llama.cpp runtime (`/api/local-models/*`),
/// the same Dashboard REST surface Hermes Desktop drives in local mode
/// (`apps/desktop/src/api/local-models.ts`). Every path, method and body
/// here mirrors Desktop; nothing is invented.
///
/// Capability: the router ships with Hermes' Dashboard. An older Hermes
/// without it answers 404 on `GET /api/local-models/status`, surfaced as
/// [LocalModelsUnavailable] so the UI can hide or disable every write.
class LocalModelsClient {
  LocalModelsClient(this._dashboard, {this.profile = ''});

  final DashboardClient _dashboard;

  /// Profile whose `config.yaml` an activation writes (`?profile=`, exactly
  /// what Desktop's `profileScoped()` adds). Empty = default profile.
  final String profile;

  /// Eject drives the router with a 120 s budget server-side.
  static const ejectTimeout = Duration(seconds: 130);

  /// Start/stop runs off the event loop server-side and may take a while.
  static const serverTimeout = Duration(seconds: 90);

  String get _profileQuery => profile.isEmpty || profile == 'default'
      ? ''
      : '?profile=${Uri.encodeQueryComponent(profile)}';

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      return await _dashboard.apiGet(path);
    } on DashboardHttpException catch (e) {
      throw LocalModelsException.from(e);
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
  }) async {
    try {
      return timeout == null
          ? await _dashboard.apiPost(path, body: body)
          : await _dashboard.apiPost(path, body: body, timeout: timeout);
    } on DashboardHttpException catch (e) {
      throw LocalModelsException.from(e);
    }
  }

  /// `GET /api/local-models/status`. 404 ⇒ [LocalModelsUnavailable].
  Future<LocalModelsStatus> status() async {
    try {
      return LocalModelsStatus.fromJson(
        await _dashboard.apiGet('local-models/status'),
      );
    } on DashboardHttpException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 405) {
        throw const LocalModelsUnavailable();
      }
      throw LocalModelsException.from(e);
    }
  }

  /// `GET /api/local-models/catalog` — curated entries priced for the server.
  Future<List<LocalCatalogModel>> catalog() async {
    final data = await _get('local-models/catalog');
    return _maps(data['models']).map(LocalCatalogModel.fromJson).toList();
  }

  /// `GET /api/local-models/jobs` — running/paused first, then recent.
  Future<List<LocalRuntimeJob>> jobs() async {
    final data = await _get('local-models/jobs');
    return _maps(data['jobs']).map(LocalRuntimeJob.fromJson).toList();
  }

  /// `POST /api/local-models/download {model_id}`.
  Future<LocalJobStart> download(String modelId) async =>
      LocalJobStart.fromJson(
        await _post('local-models/download', {'model_id': modelId}),
      );

  /// `POST /api/local-models/download/pause {job_id}` → `{ok, paused}`.
  Future<bool> pause(String jobId) async =>
      (await _post('local-models/download/pause', {
        'job_id': jobId,
      }))['paused'] ==
      true;

  /// `POST /api/local-models/download/resume {job_id}` → `{ok, resumed}`.
  Future<bool> resume(String jobId) async =>
      (await _post('local-models/download/resume', {
        'job_id': jobId,
      }))['resumed'] ==
      true;

  /// `POST /api/local-models/activate?profile= {model_id}` → `{job_id}`:
  /// makes a downloaded model the default for new chats (config write).
  Future<String?> activate(String modelId) async {
    final data = await _post('local-models/activate$_profileQuery', {
      'model_id': modelId,
    });
    return _string(data['job_id']);
  }

  /// `POST /api/local-models/eject {model_id}` — frees its GPU memory.
  Future<void> eject(String modelId) async {
    await _post('local-models/eject', {
      'model_id': modelId,
    }, timeout: ejectTimeout);
  }

  /// `DELETE /api/local-models/models/{model_id}` — removes it from disk.
  Future<void> delete(String modelId) async {
    try {
      await _dashboard.apiDelete(
        'local-models/models/${Uri.encodeComponent(modelId)}',
      );
    } on DashboardHttpException catch (e) {
      throw LocalModelsException.from(e);
    }
  }

  /// `POST /api/local-models/server {action: start|stop}`.
  Future<void> setServer({required bool running}) async {
    await _post('local-models/server', {
      'action': running ? 'start' : 'stop',
    }, timeout: serverTimeout);
  }

  /// `POST /api/local-models/runtime/install {backend: null}` → `{job_id}`.
  Future<String?> installRuntime() async {
    final data = await _post('local-models/runtime/install$_profileQuery', {
      'backend': null,
    });
    return _string(data['job_id']);
  }

  /// `GET /api/local-models/search?q=&limit=` — GGUF repos on Hugging Face.
  Future<List<HfSearchHit>> search(String query, {int limit = 20}) async {
    final data = await _get(
      'local-models/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
    );
    return _maps(data['hits']).map(HfSearchHit.fromJson).toList();
  }

  /// `GET /api/local-models/search/files?repo=` — servable GGUF groups.
  Future<List<HfFileGroup>> repoFiles(String repo) async {
    final data = await _get(
      'local-models/search/files?repo=${Uri.encodeQueryComponent(repo)}',
    );
    return _maps(data['files']).map(HfFileGroup.fromJson).toList();
  }

  /// `POST /api/local-models/download-browsed {repo, paths}`.
  Future<LocalJobStart> downloadBrowsed(
    String repo,
    List<String> paths,
  ) async => LocalJobStart.fromJson(
    await _post('local-models/download-browsed', {
      'repo': repo,
      'paths': paths,
    }),
  );
}

/// The server has no `/api/local-models/*` routes (older Hermes).
class LocalModelsUnavailable implements Exception {
  const LocalModelsUnavailable();

  @override
  String toString() => 'local_models_unavailable';
}

/// A failed local-models call; [detail] is the server's own explanation
/// (FastAPI `{"detail": …}`), already written for people.
class LocalModelsException implements Exception {
  const LocalModelsException(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  factory LocalModelsException.from(DashboardHttpException e) {
    var detail = '';
    try {
      final decoded = jsonDecode(e.body);
      if (decoded is Map && decoded['detail'] is String) {
        detail = (decoded['detail'] as String).trim();
      }
    } catch (_) {
      // Non-JSON error body: keep the status only.
    }
    return LocalModelsException(e.statusCode, detail);
  }

  @override
  String toString() =>
      detail.isEmpty ? 'HTTP $statusCode' : 'HTTP $statusCode: $detail';
}

class LocalModelsStatus {
  const LocalModelsStatus({
    required this.enabled,
    required this.tag,
    required this.runtimeInstalled,
    required this.runtimeBackend,
    required this.serverRunning,
    required this.activeModelId,
    required this.loadedModels,
    required this.loadingPercent,
    required this.models,
  });

  final bool enabled;
  final String tag;
  final bool runtimeInstalled;
  final String? runtimeBackend;
  final bool serverRunning;
  final String? activeModelId;

  /// Resident models: id → `loaded` | `ready` | `loading`.
  final Map<String, String> loadedModels;

  /// Live load percent per model id (only while loading).
  final Map<String, int> loadingPercent;
  final List<LocalStagedModel> models;

  bool isLoaded(String id) {
    final state = loadedModels[id];
    return state == 'loaded' || state == 'ready';
  }

  bool isLoading(String id) =>
      loadedModels[id] == 'loading' || loadingPercent.containsKey(id);

  factory LocalModelsStatus.fromJson(Map<String, dynamic> json) {
    final loaded = <String, String>{};
    final rawLoaded = json['loaded_models'];
    if (rawLoaded is Map) {
      rawLoaded.forEach((k, v) => loaded[k.toString()] = v.toString());
    }
    final loading = <String, int>{};
    final rawLoading = json['loading'];
    if (rawLoading is Map) {
      rawLoading.forEach((k, v) {
        final percent = v is Map ? v['percent'] : null;
        loading[k.toString()] = percent is num ? percent.round() : 0;
      });
    }
    return LocalModelsStatus(
      enabled: json['enabled'] == true,
      tag: _string(json['tag']) ?? '',
      runtimeInstalled: json['runtime_installed'] == true,
      runtimeBackend: _string(json['runtime_backend']),
      serverRunning: json['server_running'] == true,
      activeModelId: _string(json['active_model_id']),
      loadedModels: loaded,
      loadingPercent: loading,
      models: _maps(json['models']).map(LocalStagedModel.fromJson).toList(),
    );
  }
}

/// A model file set staged in the server's managed models directory.
class LocalStagedModel {
  const LocalStagedModel({
    required this.id,
    required this.sizeBytes,
    required this.sizeLabel,
  });

  final String id;
  final int sizeBytes;
  final String sizeLabel;

  /// Quantisation read from the GGUF stem (`…-Q4_K_M`, `…-IQ3_XS`,
  /// `…-BF16`), or null when the name does not carry one.
  String? get quant => ggufQuantOf(id);

  factory LocalStagedModel.fromJson(Map<String, dynamic> json) =>
      LocalStagedModel(
        id: _string(json['id']) ?? '',
        sizeBytes: _int(json['size_bytes']),
        sizeLabel: _string(json['size_label']) ?? '',
      );
}

final _quantPattern = RegExp(
  r'(?:^|[-_.])((?:UD-)?(?:I?Q\d(?:_[A-Z0-9]+)*|BF16|F16|F32|MXFP4))$',
  caseSensitive: false,
);

String? ggufQuantOf(String id) =>
    _quantPattern.firstMatch(id)?.group(1)?.toUpperCase();

class LocalCatalogModel {
  const LocalCatalogModel({
    required this.id,
    required this.displayName,
    required this.description,
    required this.sizeLabel,
    required this.recommended,
    required this.downloaded,
    required this.downloadedModelId,
    required this.quant,
    required this.fits,
    required this.fitSummary,
    required this.needsEngine,
    required this.modelId,
  });

  final String id;
  final String displayName;
  final String description;
  final String sizeLabel;
  final bool recommended;
  final bool downloaded;
  final String? downloadedModelId;
  final String? quant;
  final bool fits;
  final String fitSummary;
  final bool needsEngine;

  /// The exact variant this server would download.
  final String? modelId;

  bool get canDownload => fits && !needsEngine && !downloaded;

  factory LocalCatalogModel.fromJson(Map<String, dynamic> json) =>
      LocalCatalogModel(
        id: _string(json['id']) ?? '',
        displayName: _string(json['display_name']) ?? _string(json['id']) ?? '',
        description: _string(json['description']) ?? '',
        sizeLabel: _string(json['size_label']) ?? '',
        recommended: json['recommended'] == true,
        downloaded: json['downloaded'] == true,
        downloadedModelId: _string(json['downloaded_model_id']),
        quant: _string(json['downloaded_quant']) ?? _string(json['quant']),
        fits: json['fits'] != false,
        fitSummary: _string(json['fit_summary']) ?? '',
        needsEngine: json['needs_engine'] == true,
        modelId: _string(json['model_id']),
      );
}

class LocalRuntimeJob {
  const LocalRuntimeJob({
    required this.jobId,
    required this.kind,
    required this.target,
    required this.modelId,
    required this.status,
    required this.phase,
    required this.detail,
    required this.totalBytes,
    required this.doneBytes,
    required this.percent,
    required this.error,
    required this.canPause,
    required this.canResume,
  });

  final String jobId;

  /// `model-download` | `model-activate` | `runtime-install` | `quickstart`.
  final String kind;
  final String target;
  final String? modelId;

  /// `running` | `paused` | `done` | `error`.
  final String status;
  final String phase;
  final String detail;
  final int? totalBytes;
  final int doneBytes;
  final int? percent;
  final String? error;
  final bool canPause;
  final bool canResume;

  bool get isRunning => status == 'running';
  bool get isPaused => status == 'paused';
  bool get isActive => isRunning || isPaused;

  factory LocalRuntimeJob.fromJson(Map<String, dynamic> json) {
    final total = json['total_bytes'];
    final percent = json['percent'];
    return LocalRuntimeJob(
      jobId: _string(json['job_id']) ?? '',
      kind: _string(json['kind']) ?? '',
      target: _string(json['target']) ?? '',
      modelId: _string(json['model_id']),
      status: _string(json['status']) ?? 'running',
      phase: _string(json['phase']) ?? '',
      detail: _string(json['detail']) ?? '',
      totalBytes: total is num && total > 0 ? total.toInt() : null,
      doneBytes: _int(json['done_bytes']),
      percent: percent is num ? percent.round().clamp(0, 100) : null,
      error: _string(json['error']),
      canPause: json['can_pause'] == true,
      canResume: json['can_resume'] == true,
    );
  }
}

class LocalJobStart {
  const LocalJobStart({
    required this.jobId,
    required this.modelId,
    required this.alreadyDownloaded,
  });

  final String? jobId;
  final String? modelId;
  final bool alreadyDownloaded;

  factory LocalJobStart.fromJson(Map<String, dynamic> json) => LocalJobStart(
    jobId: _string(json['job_id']),
    modelId: _string(json['model_id']),
    alreadyDownloaded: json['already_downloaded'] == true,
  );
}

class HfSearchHit {
  const HfSearchHit({
    required this.repo,
    required this.downloads,
    required this.likes,
    required this.gated,
  });

  final String repo;
  final int downloads;
  final int likes;
  final bool gated;

  factory HfSearchHit.fromJson(Map<String, dynamic> json) => HfSearchHit(
    repo: _string(json['repo']) ?? '',
    downloads: _int(json['downloads']),
    likes: _int(json['likes']),
    gated: json['gated'] == true,
  );
}

class HfFileGroup {
  const HfFileGroup({
    required this.label,
    required this.paths,
    required this.totalBytes,
    required this.fit,
  });

  final String label;
  final List<String> paths;
  final int totalBytes;

  /// `fits-gpu` | `needs-ram` | `too-big` | `unknown`.
  final String fit;

  factory HfFileGroup.fromJson(Map<String, dynamic> json) => HfFileGroup(
    label: _string(json['label']) ?? '',
    paths: [
      for (final p
          in (json['paths'] is List ? json['paths'] as List : const []))
        if (p is String && p.isNotEmpty) p,
    ],
    totalBytes: _int(json['total_bytes']),
    fit: _string(json['fit']) ?? 'unknown',
  );
}

/// `12.3 GB`, `850 MB` — matches the server's `_human_gb` style.
String formatLocalBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).round()} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).round()} KB';
  return '$bytes B';
}

List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) item.cast<String, dynamic>(),
];

String? _string(Object? value) {
  if (value == null) return null;
  final s = value.toString().trim();
  return s.isEmpty ? null : s;
}

int _int(Object? value) => value is num ? value.toInt() : 0;
