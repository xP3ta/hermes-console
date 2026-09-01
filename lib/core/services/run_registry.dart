import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Registro local de ejecuciones (/v1/runs) lanzadas desde esta app.
///
/// El gateway NO expone listado de runs (GET /v1/runs → 405, verificado
/// contra api_server.py del upstream): los estados viven en memoria del
/// servidor indexados por run_id y se barren al terminar. La única forma
/// honesta de tener una lista en el móvil es recordar los run_id que esta
/// app creó. Clave: `runs_<connectionId>`.
class RunRecord {
  final String runId;
  final String prompt;
  final String? sessionId;
  final double createdAt; // epoch seconds

  /// Último estado conocido (queued/running/waiting_for_approval/completed/
  /// failed/cancelled) o `expired` cuando el gateway ya no lo conserva.
  final String lastStatus;
  final String? output;
  final String? error;

  // Campos opcionales añadidos en Fase 1 del Task Center.
  // Todos son null en registros antiguos; fromJson los ignora si no están.

  /// Etiqueta del último paso visible (p.ej. "tool: read_file"). Solo se
  /// rellena cuando hay eventos SSE en curso; null si el run no ha empezado
  /// o ya terminó.
  final String? progressLabel;

  /// Tipo del último evento SSE procesado (p.ej. "tool.started"). Útil para
  /// depuración y para que la pantalla sepa qué se vio por última vez.
  final String? lastEvent;

  /// Epoch seconds del último cambio de estado registrado localmente.
  final double? updatedAt;

  /// ID de la conexión desde la que se lanzó este run. Null en registros
  /// antiguos que no lo guardaron (backward-compatible: fromJson lo ignora
  /// si no está presente).
  final String? connId;

  /// Perfil propietario del runtime. Los registros legacy que no lo guardaban
  /// pertenecen a `default` para mantener una migración determinista.
  final String profile;

  const RunRecord({
    required this.runId,
    required this.prompt,
    required this.createdAt,
    required this.lastStatus,
    this.sessionId,
    this.output,
    this.error,
    this.progressLabel,
    this.lastEvent,
    this.updatedAt,
    this.connId,
    this.profile = 'default',
  });

  RunRecord copyWith({
    String? lastStatus,
    String? output,
    String? error,
    String? progressLabel,
    String? lastEvent,
    double? updatedAt,
    String? profile,
  }) => RunRecord(
    runId: runId,
    prompt: prompt,
    sessionId: sessionId,
    createdAt: createdAt,
    lastStatus: lastStatus ?? this.lastStatus,
    output: output ?? this.output,
    error: error ?? this.error,
    progressLabel: progressLabel ?? this.progressLabel,
    lastEvent: lastEvent ?? this.lastEvent,
    updatedAt: updatedAt ?? this.updatedAt,
    connId: connId,
    profile: profile ?? this.profile,
  );

  bool get isTerminal => const {
    'completed',
    'failed',
    'cancelled',
    'expired',
  }.contains(lastStatus);

  Map<String, dynamic> toJson() => {
    'run_id': runId,
    'prompt': prompt,
    if (sessionId != null) 'session_id': sessionId,
    'created_at': createdAt,
    'last_status': lastStatus,
    if (output != null) 'output': output,
    if (error != null) 'error': error,
    if (progressLabel != null) 'progress_label': progressLabel,
    if (lastEvent != null) 'last_event': lastEvent,
    if (updatedAt != null) 'updated_at': updatedAt,
    if (connId != null) 'conn_id': connId,
    'profile': profile,
  };

  factory RunRecord.fromJson(Map<String, dynamic> json) => RunRecord(
    runId: json['run_id'] ?? '',
    prompt: json['prompt'] ?? '',
    sessionId: json['session_id'] as String?,
    createdAt: (json['created_at'] as num?)?.toDouble() ?? 0,
    lastStatus: json['last_status'] ?? 'unknown',
    output: json['output'] as String?,
    error: json['error'] as String?,
    progressLabel: json['progress_label'] as String?,
    lastEvent: json['last_event'] as String?,
    updatedAt: (json['updated_at'] as num?)?.toDouble(),
    connId: json['conn_id'] as String?,
    profile: switch ((json['profile'] ?? '').toString().trim()) {
      final value when value.isNotEmpty => value,
      _ => 'default',
    },
  );
}

class RunRegistry {
  static const _prefix = 'runs_';
  static const _maxRecords = 50;

  final SharedPreferences _prefs;
  final String _key;
  List<RunRecord> _records;

  RunRegistry._(this._prefs, this._key, this._records);

  static Future<RunRegistry> load(
    SharedPreferences prefs,
    String connectionId,
  ) async {
    final key = '$_prefix$connectionId';
    final raw = prefs.getString(key);
    var records = <RunRecord>[];
    if (raw != null) {
      try {
        records = (jsonDecode(raw) as List)
            .whereType<Map<String, dynamic>>()
            .map(RunRecord.fromJson)
            .where((r) => r.runId.isNotEmpty)
            .toList();
      } catch (e) {
        debugPrint(
          '[run-registry] excepción silenciada (fallback: records = []): $e',
        );
        records = [];
      }
    }
    return RunRegistry._(prefs, key, records);
  }

  /// Más reciente primero.
  List<RunRecord> get records {
    final sorted = [..._records]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  Future<void> add(RunRecord record) async {
    final profile = _normalizeRunProfile(record.profile);
    final owned = profile == record.profile
        ? record
        : record.copyWith(profile: profile);
    _records.removeWhere(
      (r) => r.runId == owned.runId && r.profile == owned.profile,
    );
    _records.add(owned);
    // Mantener el registro acotado: los más antiguos salen primero.
    if (_records.length > _maxRecords) {
      _records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _records = _records.sublist(_records.length - _maxRecords);
    }
    await _persist();
  }

  Future<void> update(
    String runId, {
    String profile = 'default',
    String? lastStatus,
    String? output,
    String? error,
    String? progressLabel,
    String? lastEvent,
    double? updatedAt,
  }) async {
    final ownerProfile = _normalizeRunProfile(profile);
    final i = _records.indexWhere(
      (r) => r.runId == runId && r.profile == ownerProfile,
    );
    if (i < 0) return;
    _records[i] = _records[i].copyWith(
      lastStatus: lastStatus,
      output: output,
      error: error,
      progressLabel: progressLabel,
      lastEvent: lastEvent,
      updatedAt: updatedAt,
    );
    await _persist();
  }

  Future<void> remove(String runId, {String profile = 'default'}) async {
    final ownerProfile = _normalizeRunProfile(profile);
    _records.removeWhere((r) => r.runId == runId && r.profile == ownerProfile);
    await _persist();
  }

  /// Vacía el historial local de ejecuciones de esta conexión. No afecta al
  /// servidor (que ya no las conserva): solo limpia la lista del móvil.
  Future<void> clear() async {
    _records = [];
    await _persist();
  }

  Future<void> _persist() => _prefs.setString(
    _key,
    jsonEncode(_records.map((r) => r.toJson()).toList()),
  );
}

String _normalizeRunProfile(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? 'default' : normalized;
}
