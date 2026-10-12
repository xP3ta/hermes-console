import 'package:flutter/foundation.dart';

/// Memory system status returned by GET /api/memory (Dashboard port 9119).
///
/// Shows the active provider, all available providers, and built-in file sizes.
enum MemoryProviderStatus {
  ready,
  needsConfig,
  unavailable,
  missing,

  /// Absent or not recognised: only [MemoryProvider.configured] is known.
  unknown;

  static MemoryProviderStatus parse(Object? value) => switch (value) {
    'ready' => ready,
    'needs_config' => needsConfig,
    'unavailable' => unavailable,
    'missing' => missing,
    _ => unknown,
  };
}

class MemoryProvider {
  final String name;
  final String description;
  final bool configured;

  /// `null` when the server does not say.
  final bool? available;
  final MemoryProviderStatus status;

  const MemoryProvider({
    required this.name,
    required this.description,
    required this.configured,
    this.available,
    this.status = MemoryProviderStatus.unknown,
  });

  factory MemoryProvider.fromJson(Map<String, dynamic> json) => MemoryProvider(
    name: (json['name'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    configured: (json['configured'] as bool?) ?? false,
    available: json['available'] as bool?,
    status: MemoryProviderStatus.parse(json['status']),
  );
}

class MemoryInfo {
  final String active;
  final List<MemoryProvider> providers;
  final Map<String, int> builtinFiles;

  const MemoryInfo({
    required this.active,
    required this.providers,
    required this.builtinFiles,
  });

  factory MemoryInfo.fromJson(Map<String, dynamic> json) {
    final rawProviders = json['providers'] as List? ?? [];
    final providers = rawProviders
        .whereType<Map<String, dynamic>>()
        .map(MemoryProvider.fromJson)
        .toList();

    final rawBuiltin = (json['builtin_files'] as Map?)?.cast<String, dynamic>() ?? {};
    final builtinFiles = rawBuiltin.map((k, v) {
      final bytes = v is int ? v : (v is num ? v.toInt() : 0);
      return MapEntry(k, bytes);
    });

    return MemoryInfo(
      active: (json['active'] as String?) ?? '',
      providers: providers,
      builtinFiles: builtinFiles,
    );
  }

  MemoryProvider? get activeProvider {
    try {
      return providers.firstWhere((p) => p.name == active);
    } catch (e) {
      debugPrint('[memory-info] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  int get configuredCount => providers.where((p) => p.configured).length;
}
