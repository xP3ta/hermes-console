import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../config/flavor.dart';

/// Traza QA local de frames lentos. Nunca acepta ni conserva contenido del
/// transcript, IDs de sesión, rutas, prompts, herramientas o credenciales.
///
/// El colector vive solo en la variante QA cuando el build activa
/// `HERMES_PERFORMANCE_TRACE`; su salida estructurada se recoge por ADB tras
/// una reproducción guiada, sin subir datos fuera del dispositivo.
class PerformanceTrace {
  static const _slowFrameBudget = Duration(milliseconds: 16);

  final bool enabled;
  final int capacity;
  final Queue<_SlowFrame> _slowFrames = Queue<_SlowFrame>();
  var _slowFrameCount = 0;
  var _started = false;

  PerformanceTrace({required this.enabled, this.capacity = 120})
    : assert(capacity > 0);

  static final qa = PerformanceTrace(
    enabled:
        kHermesFlavor == 'qa' &&
        const bool.fromEnvironment(
          'HERMES_PERFORMANCE_TRACE',
          defaultValue: false,
        ),
  );

  void start() {
    if (!enabled || _started) return;
    _started = true;
    WidgetsBinding.instance.addTimingsCallback(_recordTimings);
    debugPrint('[perf-trace] enabled schema=1');
  }

  void _recordTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _record(
        buildMs: timing.buildDuration.inMilliseconds,
        rasterMs: timing.rasterDuration.inMilliseconds,
      );
    }
  }

  @visibleForTesting
  void recordFrameForTesting({required int buildMs, required int rasterMs}) {
    _record(buildMs: buildMs, rasterMs: rasterMs);
  }

  void _record({required int buildMs, required int rasterMs}) {
    final safeBuild = buildMs.clamp(0, 60000);
    final safeRaster = rasterMs.clamp(0, 60000);
    final total = safeBuild + safeRaster;
    if (total <= _slowFrameBudget.inMilliseconds) return;
    _slowFrameCount++;
    _slowFrames.add(
      _SlowFrame(buildMs: safeBuild, rasterMs: safeRaster, totalMs: total),
    );
    while (_slowFrames.length > capacity) {
      _slowFrames.removeFirst();
    }
    if (total >= 100) {
      debugPrint(
        '[perf-trace] slow-frame buildMs=$safeBuild rasterMs=$safeRaster '
        'totalMs=$total count=$_slowFrameCount',
      );
    }
  }

  /// Emite un informe pequeño y saneado a logcat cuando la persona que prueba
  /// avisa del tirón. El marcador no añade ningún dato de conversación.
  void markUserReportedIssue() {
    if (!enabled) return;
    final latest = _slowFrames.isEmpty ? null : _slowFrames.last;
    debugPrint(
      '[perf-trace] user-report slowFrameCount=$_slowFrameCount '
      'retained=${_slowFrames.length} '
      'latestBuildMs=${latest?.buildMs ?? 0} '
      'latestRasterMs=${latest?.rasterMs ?? 0} '
      'latestTotalMs=${latest?.totalMs ?? 0}',
    );
  }

  @visibleForTesting
  Map<String, dynamic> snapshotForTesting() => {
    'slowFrames': [for (final frame in _slowFrames) frame.toJson()],
    'slowFrameCount': _slowFrameCount,
  };
}

class _SlowFrame {
  final int buildMs;
  final int rasterMs;
  final int totalMs;

  const _SlowFrame({
    required this.buildMs,
    required this.rasterMs,
    required this.totalMs,
  });

  Map<String, int> toJson() => {
    'buildMs': buildMs,
    'rasterMs': rasterMs,
    'totalMs': totalMs,
  };
}
