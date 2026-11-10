// Alternate QA entry point for the REAL application, never a demo scene.
// Starting/installing this build still requires the owner's device permission.
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/main.dart' as app;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final probe = _Probe();
  SchedulerBinding.instance.addTimingsCallback(probe.frames);
  developer.registerExtension('ext.hermes.liquidProbe', probe.call);
  app.main();
}

class _Probe {
  static const int maxFrames = 6000;
  final List<FrameTiming> _frames = [];
  HermesGlassTier? _savedCeiling;
  String _scenario = '';
  int _warmup = 0;
  bool _truncated = false;
  Map<String, Object?> _start = {};

  void frames(List<FrameTiming> timings) {
    if (_savedCeiling == null) return;
    for (final frame in timings) {
      if (_warmup > 0) {
        _warmup--;
      } else if (_frames.length < maxFrames) {
        _frames.add(frame);
      } else {
        _truncated = true;
      }
    }
  }

  Map<String, Object?> _metadata() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final view = views.isEmpty ? null : views.first;
    final accessibility =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
    return {
      'scenario': _scenario,
      'effectCeiling': FrostedBackdropPolicy.effectCeiling.value.name,
      'gpuValidationGate': FrostedBackdropPolicy.liquidGpuValidated.value,
      'knownHighEnd': FrostedBackdropPolicy.knownHighEnd.value,
      'blurAllowed': FrostedBackdropPolicy.blurAllowed.value,
      'reducedPerformance': FrostedBackdropPolicy.reducedPerformance.value,
      'shaderFilterSupported': HermesLiquidShader.supported,
      'shaderProgramLoaded': HermesLiquidShader.program != null,
      'physicalWidth': view?.physicalSize.width,
      'physicalHeight': view?.physicalSize.height,
      'devicePixelRatio': view?.devicePixelRatio,
      'refreshRate': view?.display.refreshRate,
      'disableAnimations': accessibility.disableAnimations,
      'highContrast': accessibility.highContrast,
      // FrameTiming is an engine timing. It does not establish GPU hardware,
      // actual shader activation, GPU completion, thermal state or jank.
      'gpuCertified': false,
      'samples': _frames.length,
      'remainingWarmupFrames': _warmup,
      'truncated': _truncated,
    };
  }

  Future<developer.ServiceExtensionResponse> call(
    String method,
    Map<String, String> params,
  ) async {
    developer.ServiceExtensionResponse bad(String message) =>
        developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.invalidParams,
          jsonEncode({'message': message}),
        );
    switch (params['action']) {
      case 'begin':
        if (_savedCeiling != null) {
          return bad('Finish the active sample first.');
        }
        final mode = switch (params['mode']) {
          'chrome' => HermesGlassTier.chrome,
          'glass' => HermesGlassTier.glass,
          'liquid' => HermesGlassTier.liquid,
          _ => null,
        };
        if (mode == null) return bad('mode must be chrome, glass or liquid.');
        final warmup = int.tryParse(params['warmupFrames'] ?? '120');
        if (warmup == null || warmup < 0 || warmup > 1200) {
          return bad('warmupFrames must be 0..1200.');
        }
        _savedCeiling = FrostedBackdropPolicy.effectCeiling.value;
        _scenario = params['scenario'] ?? 'unnamed';
        _frames.clear();
        _warmup = warmup;
        _truncated = false;
        // Only a temporary ceiling. It cannot enable a forbidden effect,
        // change dock opacity, write preferences or supply a fake device class.
        FrostedBackdropPolicy.effectCeiling.value = mode;
        _start = _metadata();
        return developer.ServiceExtensionResponse.result(jsonEncode(_start));
      case 'finish':
        final saved = _savedCeiling;
        if (saved == null) return bad('No active sample.');
        final metadata = _metadata();
        final samples = [
          for (final frame in _frames)
            {
              'frame': frame.frameNumber,
              'buildUs': frame.buildDuration.inMicroseconds,
              'rasterUs': frame.rasterDuration.inMicroseconds,
              'totalSpanUs': frame.totalSpan.inMicroseconds,
              'vsyncOverheadUs': frame.vsyncOverhead.inMicroseconds,
            },
        ];
        final result = {
          ...metadata,
          'start': _start,
          'environmentStable': [
            'physicalWidth',
            'physicalHeight',
            'devicePixelRatio',
            'refreshRate',
            'disableAnimations',
            'highContrast',
            'blurAllowed',
            'reducedPerformance',
            'knownHighEnd',
            'gpuValidationGate',
            'effectCeiling',
          ].every((key) => _start[key] == metadata[key]),
          'raster': _summary([
            for (final f in _frames) f.rasterDuration.inMicroseconds,
          ]),
          'build': _summary([
            for (final f in _frames) f.buildDuration.inMicroseconds,
          ]),
          'frames': samples,
        };
        _savedCeiling = null;
        FrostedBackdropPolicy.effectCeiling.value = saved;
        _frames.clear();
        return developer.ServiceExtensionResponse.result(jsonEncode(result));
      case 'cancel':
        final saved = _savedCeiling;
        _savedCeiling = null;
        if (saved != null) FrostedBackdropPolicy.effectCeiling.value = saved;
        _frames.clear();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'cancelled': true}),
        );
      case 'status':
        return developer.ServiceExtensionResponse.result(
          jsonEncode({..._metadata(), 'active': _savedCeiling != null}),
        );
      default:
        return bad('action must be begin, finish, cancel or status.');
    }
  }

  static Map<String, num?> _summary(List<int> values) {
    values.sort();
    num? at(double q) => values.isEmpty
        ? null
        : values[((values.length - 1) * q).round()] / 1000;
    return {'p50ms': at(.5), 'p90ms': at(.9), 'p95ms': at(.95)};
  }
}
