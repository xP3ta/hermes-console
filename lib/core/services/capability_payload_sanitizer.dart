import '../models/command_descriptor.dart'
    show commandDispatchMessageMaxLength;

/// Frontera común para payloads de capacidades remotas.
///
/// Los métodos operacionales conservan únicamente los campos que necesita la
/// UI y siempre acotados. [sanitizeDiagnostic] es más estricto: jamás conserva
/// argumentos, prompts, output, secretos, headers, cookies, rutas o mapas raw.
final class CapabilityPayloadSanitizer {
  static const int maxCatalogDescription = 240;
  static const int maxCommandOutput = 4000;
  static const int maxCompletionText = 256;
  static const int maxDiagnosticText = 128;

  const CapabilityPayloadSanitizer();

  String? catalogDescription(Object? value) =>
      boundedText(value, maxCatalogDescription);

  String? commandOutput(Object? value) =>
      boundedText(value, maxCommandOutput, preserveNewlines: true);

  String? completionText(Object? value) =>
      boundedText(value, maxCompletionText);

  String? boundedText(
    Object? value,
    int maxLength, {
    bool preserveNewlines = false,
  }) {
    if (value is! String || maxLength < 0) return null;
    final controls = preserveNewlines
        ? RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')
        : RegExp(r'[\x00-\x1F\x7F]');
    final cleaned = value
        .replaceAll(controls, preserveNewlines ? '' : ' ')
        .trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length <= maxLength
        ? cleaned
        : cleaned.substring(0, maxLength);
  }

  /// Allowlist operacional para respuestas slash/dispatch.
  Map<String, Object?> sanitizeCommandResponse(Object? value) {
    if (value is! Map) return const {};
    final result = <String, Object?>{};
    final type = _identifier(value['type'], 32);
    final status = _identifier(value['status'], 32);
    final output = commandOutput(value['output']);
    // The prompt a command sends (`/goal` kickoff): never cut short.
    final message = boundedText(
      value['message'],
      commandDispatchMessageMaxLength,
      preserveNewlines: true,
    );
    final notice = boundedText(
      value['notice'] ?? value['warning'],
      1000,
      preserveNewlines: true,
    );
    final target = _commandName(value['target']);
    final name = _commandName(value['name']);
    if (type != null) result['type'] = type;
    if (status != null) result['status'] = status;
    if (value['accepted'] is bool) result['accepted'] = value['accepted'];
    if (output != null) result['output'] = output;
    if (message != null) result['message'] = message;
    if (notice != null) result['notice'] = notice;
    if (target != null) result['target'] = target;
    if (name != null) result['name'] = name;
    return Map<String, Object?>.unmodifiable(result);
  }

  /// Registro seguro y plano. El mapa resultante nunca contiene contenido de
  /// usuario/servidor ni valores anidados.
  Map<String, Object?> sanitizeDiagnostic(Object? value) {
    if (value is! Map) return const {};
    final result = <String, Object?>{};

    final method = _method(value['method']);
    final state = _enumValue(value['capability_state'], const {
      'available',
      'unsupported',
      'unavailable',
      'forbidden',
      'legacy',
      'unknown',
    });
    final source = _enumValue(value['capability_source'], const {
      'handshake',
      'probe',
      'catalog',
      'version',
      'cache',
    });
    final duration = _enumValue(value['duration_bucket'], const {
      'lt_100ms',
      'lt_500ms',
      'lt_2s',
      'lt_10s',
      'gte_10s',
      'timeout',
    });
    final errorClass = _identifier(value['error_class'], maxDiagnosticText);
    final connectionId = _opaqueLocalId(value['connection_id']);
    final responseSize = _boundedCount(value['response_size']);
    final responseCount = _boundedCount(value['response_count']);
    final errorCode = _safeErrorCode(value['error_code']);

    if (method != null) result['method'] = method;
    if (state != null) result['capability_state'] = state;
    if (source != null) result['capability_source'] = source;
    if (duration != null) result['duration_bucket'] = duration;
    if (responseSize != null) result['response_size'] = responseSize;
    if (responseCount != null) result['response_count'] = responseCount;
    if (errorCode != null) result['error_code'] = errorCode;
    if (errorClass != null) result['error_class'] = errorClass;
    if (connectionId != null) result['connection_id'] = connectionId;

    return Map<String, Object?>.unmodifiable(result);
  }

  /// Comprueba profundidad y número de nodos sin copiar el payload remoto.
  bool withinStructuralLimits(
    Object? value, {
    int maxDepth = 4,
    int maxNodes = 10000,
  }) {
    if (maxDepth < 0 || maxNodes <= 0) return false;
    final stack = <(Object?, int)>[(value, 0)];
    var visited = 0;
    while (stack.isNotEmpty) {
      final (current, depth) = stack.removeLast();
      if (++visited > maxNodes || depth > maxDepth) return false;
      if (current is Map) {
        for (final child in current.values) {
          if (child is Map || child is List) stack.add((child, depth + 1));
        }
      } else if (current is List) {
        for (final child in current) {
          if (child is Map || child is List) stack.add((child, depth + 1));
        }
      }
    }
    return true;
  }

  String? _method(Object? value) {
    final text = _identifier(value, 128);
    if (text == null || !RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(text)) {
      return null;
    }
    return text;
  }

  String? _commandName(Object? value) {
    if (value is! String) return null;
    var text = value.trim().toLowerCase();
    while (text.startsWith('/')) {
      text = text.substring(1);
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(text)) {
      return null;
    }
    return text;
  }

  String? _identifier(Object? value, int maxLength) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty || text.length > maxLength) return null;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]*$').hasMatch(text)) {
      return null;
    }
    return text;
  }

  String? _opaqueLocalId(Object? value) {
    final text = _identifier(value, maxDiagnosticText);
    if (text == null || text.contains('..')) return null;
    return text;
  }

  String? _enumValue(Object? value, Set<String> allowed) {
    final text = value?.toString().trim().toLowerCase();
    return allowed.contains(text) ? text : null;
  }

  int? _boundedCount(Object? value) {
    if (value is! int || value < 0) return null;
    return value.clamp(0, 1 << 31);
  }

  Object? _safeErrorCode(Object? value) {
    if (value is int) return value.clamp(-(1 << 31), 1 << 31);
    return _identifier(value, 32);
  }
}
