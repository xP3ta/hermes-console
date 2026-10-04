/// Estado de disponibilidad del contrato nativo de autocompresion.
enum CompressionConfigSupport { supported, unsupported }

/// Codigos seguros y estables para presentar fallos sin conservar respuestas
/// remotas, URLs, credenciales ni valores de configuracion.
enum CompressionConfigFailureCode {
  closed('compression_config_closed'),
  invalidProfile('compression_config_invalid_profile'),
  unsupported('compression_config_unsupported'),
  invalidResponse('compression_config_invalid_response'),
  invalidValue('compression_config_invalid_value'),
  authentication('compression_config_authentication'),
  permissionDenied('compression_config_permission_denied'),
  readOnly('compression_config_read_only'),
  rejected('compression_config_rejected'),
  transport('compression_config_transport'),
  remote('compression_config_remote'),

  /// El servidor respondio `ok` pero la re-lectura muestra otro valor.
  notSaved('compression_config_not_saved'),

  /// El servidor respondio `ok` pero no se pudo re-leer para confirmarlo.
  unconfirmed('compression_config_unconfirmed');

  final String stableCode;

  const CompressionConfigFailureCode(this.stableCode);
}

/// Fallo sanitizado del repositorio de autocompresion.
///
/// Solo conserva un codigo estable, un status HTTP opcional y, para errores de
/// validacion local, uno de los nombres de campo permitidos. No guarda
/// el body del Dashboard ni el error original.
final class CompressionConfigException implements Exception {
  final CompressionConfigFailureCode code;
  final int? statusCode;
  final String? field;

  const CompressionConfigException(this.code, {this.statusCode, this.field});

  @override
  String toString() {
    final text = StringBuffer(code.stableCode);
    final status = statusCode;
    if (status != null) text.write(':http_$status');
    final fieldName = field;
    if (fieldName != null) text.write(':$fieldName');
    return text.toString();
  }
}

/// Valores nativos de autocompresion publicados por Hermes.
final class CompressionConfig {
  static const Object _unchanged = Object();

  final bool enabled;
  final double threshold;
  final double targetRatio;
  final int protectLastN;
  final int? thresholdTokens;
  final int? minTailUserMessages;
  final bool? progressNotices;

  const CompressionConfig({
    required this.enabled,
    required this.threshold,
    required this.targetRatio,
    required this.protectLastN,
    this.thresholdTokens,
    this.minTailUserMessages,
    this.progressNotices,
  });

  CompressionConfig copyWith({
    bool? enabled,
    double? threshold,
    double? targetRatio,
    int? protectLastN,
    Object? thresholdTokens = _unchanged,
    Object? minTailUserMessages = _unchanged,
    Object? progressNotices = _unchanged,
  }) => CompressionConfig(
    enabled: enabled ?? this.enabled,
    threshold: threshold ?? this.threshold,
    targetRatio: targetRatio ?? this.targetRatio,
    protectLastN: protectLastN ?? this.protectLastN,
    thresholdTokens: identical(thresholdTokens, _unchanged)
        ? this.thresholdTokens
        : thresholdTokens as int?,
    minTailUserMessages: identical(minTailUserMessages, _unchanged)
        ? this.minTailUserMessages
        : minTailUserMessages as int?,
    progressNotices: identical(progressNotices, _unchanged)
        ? this.progressNotices
        : progressNotices as bool?,
  );

  /// Reemplazos acotados para `config.compression`.
  ///
  /// Los valores 0.20 nulos significan "no tocar" y no se materializan con
  /// defaults locales. El repositorio impide enviar uno que el snapshot no
  /// publicara en config y schema.
  Map<String, Object> toDashboardPatch() => <String, Object>{
    'enabled': enabled,
    'threshold': threshold,
    'target_ratio': targetRatio,
    'protect_last_n': protectLastN,
    'threshold_tokens': ?thresholdTokens,
    'min_tail_user_messages': ?minTailUserMessages,
    'progress_notices': ?progressNotices,
  };

  @override
  bool operator ==(Object other) =>
      other is CompressionConfig &&
      other.enabled == enabled &&
      other.threshold == threshold &&
      other.targetRatio == targetRatio &&
      other.protectLastN == protectLastN &&
      other.thresholdTokens == thresholdTokens &&
      other.minTailUserMessages == minTailUserMessages &&
      other.progressNotices == progressNotices;

  @override
  int get hashCode => Object.hash(
    enabled,
    threshold,
    targetRatio,
    protectLastN,
    thresholdTokens,
    minTailUserMessages,
    progressNotices,
  );
}

/// Campos 0.20 que aparecieron simultáneamente en config y schema.
///
/// Se conserva separado del valor porque `threshold_tokens: null` es una
/// capacidad publicada y, a la vez, una instrucción de no modificar el cap.
final class CompressionConfigOptionalFields {
  final bool thresholdTokens;
  final bool minTailUserMessages;
  final bool progressNotices;

  const CompressionConfigOptionalFields({
    this.thresholdTokens = false,
    this.minTailUserMessages = false,
    this.progressNotices = false,
  });

  bool get any => thresholdTokens || minTailUserMessages || progressNotices;

  void requireCompatible(CompressionConfig value) {
    if (!thresholdTokens && value.thresholdTokens != null) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'threshold_tokens',
      );
    }
    if (!minTailUserMessages && value.minTailUserMessages != null) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'min_tail_user_messages',
      );
    }
    if (!progressNotices && value.progressNotices != null) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'progress_notices',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CompressionConfigOptionalFields &&
      other.thresholdTokens == thresholdTokens &&
      other.minTailUserMessages == minTailUserMessages &&
      other.progressNotices == progressNotices;

  @override
  int get hashCode =>
      Object.hash(thresholdTokens, minTailUserMessages, progressNotices);
}

/// Handle opaco del registro completo y redactado que entrega el Dashboard.
///
/// Replica la semantica de Hermes Desktop: el guardado parte de una copia del
/// registro leido y sustituye unicamente los campos publicados conocidos. El
/// contenido solo vive en memoria, se congela defensivamente y nunca aparece
/// en [toString].
final class CompressionConfigRecordHandle {
  final Map<String, dynamic> _redactedRecord;

  CompressionConfigRecordHandle.fromRedactedRecord(Map<String, dynamic> record)
    : _redactedRecord = _freezeStringMap(record);

  /// Devuelve una copia nueva apta para el PUT nativo. Conserva hermanos tanto
  /// en la raiz como dentro de `compression`, incluidos campos futuros.
  Map<String, dynamic> buildRecordWith(CompressionConfig configuration) {
    final record = _mutableStringMap(_redactedRecord);
    final existing = _mutableStringMap(
      _stringMap(record['compression']) ?? const <String, dynamic>{},
    );
    existing.addAll(configuration.toDashboardPatch());
    record['compression'] = existing;
    return record;
  }

  @override
  String toString() => 'CompressionConfigRecordHandle(redacted)';
}

/// Limites efectivos. Se parte de un rango local conservador y se estrecha con
/// los limites publicados por `/api/config/schema`, nunca se ensancha.
final class CompressionConfigLimits {
  static const native = CompressionConfigLimits(
    thresholdMinimum: 0.1,
    thresholdMaximum: 0.95,
    targetRatioMinimum: 0.05,
    targetRatioMaximum: 0.8,
    protectLastNMinimum: 0,
    protectLastNMaximum: 200,
  );

  final double thresholdMinimum;
  final double thresholdMaximum;
  final double targetRatioMinimum;
  final double targetRatioMaximum;
  final int protectLastNMinimum;
  final int protectLastNMaximum;

  const CompressionConfigLimits({
    required this.thresholdMinimum,
    required this.thresholdMaximum,
    required this.targetRatioMinimum,
    required this.targetRatioMaximum,
    required this.protectLastNMinimum,
    required this.protectLastNMaximum,
  });

  /// Valida antes de cualquier mutacion remota.
  void requireValid(CompressionConfig value) {
    if (!value.threshold.isFinite ||
        value.threshold < thresholdMinimum ||
        value.threshold > thresholdMaximum) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'threshold',
      );
    }
    if (!value.targetRatio.isFinite ||
        value.targetRatio < targetRatioMinimum ||
        value.targetRatio > targetRatioMaximum) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'target_ratio',
      );
    }
    if (value.protectLastN < protectLastNMinimum ||
        value.protectLastN > protectLastNMaximum) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'protect_last_n',
      );
    }
    final thresholdTokens = value.thresholdTokens;
    if (thresholdTokens != null && thresholdTokens <= 0) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'threshold_tokens',
      );
    }
    final minTailUserMessages = value.minTailUserMessages;
    if (minTailUserMessages != null && minTailUserMessages < 1) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.invalidValue,
        field: 'min_tail_user_messages',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CompressionConfigLimits &&
      other.thresholdMinimum == thresholdMinimum &&
      other.thresholdMaximum == thresholdMaximum &&
      other.targetRatioMinimum == targetRatioMinimum &&
      other.targetRatioMaximum == targetRatioMaximum &&
      other.protectLastNMinimum == protectLastNMinimum &&
      other.protectLastNMaximum == protectLastNMaximum;

  @override
  int get hashCode => Object.hash(
    thresholdMinimum,
    thresholdMaximum,
    targetRatioMinimum,
    targetRatioMaximum,
    protectLastNMinimum,
    protectLastNMaximum,
  );
}

/// Lectura coherente de config + schema dentro de un unico perfil.
///
/// [enabled] es deliberadamente nullable: `null` significa contrato no
/// soportado, `false` significa soportado y desactivado, y `true` soportado y
/// activo. Los errores de red/formato no se representan aqui: el repositorio
/// los entrega como [CompressionConfigException].
final class CompressionConfigSnapshot {
  final CompressionConfigSupport support;
  final String? profile;
  final CompressionConfig? configuration;
  final CompressionConfigLimits? limits;
  final CompressionConfigOptionalFields optionalFields;
  final CompressionConfigRecordHandle? recordHandle;
  final DateTime fetchedAt;

  const CompressionConfigSnapshot._({
    required this.support,
    required this.profile,
    required this.configuration,
    required this.limits,
    required this.optionalFields,
    required this.recordHandle,
    required this.fetchedAt,
  });

  const CompressionConfigSnapshot.supported({
    required String? profile,
    required CompressionConfig configuration,
    required CompressionConfigLimits limits,
    CompressionConfigOptionalFields optionalFields =
        const CompressionConfigOptionalFields(),
    required CompressionConfigRecordHandle recordHandle,
    required DateTime fetchedAt,
  }) : this._(
         support: CompressionConfigSupport.supported,
         profile: profile,
         configuration: configuration,
         limits: limits,
         optionalFields: optionalFields,
         recordHandle: recordHandle,
         fetchedAt: fetchedAt,
       );

  const CompressionConfigSnapshot.unsupported({
    required String? profile,
    required DateTime fetchedAt,
  }) : this._(
         support: CompressionConfigSupport.unsupported,
         profile: profile,
         configuration: null,
         limits: null,
         optionalFields: const CompressionConfigOptionalFields(),
         recordHandle: null,
         fetchedAt: fetchedAt,
       );

  bool get isSupported => support == CompressionConfigSupport.supported;

  bool? get enabled => configuration?.enabled;

  /// Interpreta tanto el schema plano real del Dashboard (`fields` con rutas
  /// dot-separated) como JSON Schema anidado (`properties`), usado tambien por
  /// fixtures contractuales.
  factory CompressionConfigSnapshot.fromDashboard({
    required String? profile,
    required Map<String, dynamic> config,
    required Map<String, dynamic> schema,
    required DateTime fetchedAt,
  }) {
    final fields = _compressionSchemaFields(schema);
    if (fields == null) {
      return CompressionConfigSnapshot.unsupported(
        profile: profile,
        fetchedAt: fetchedAt,
      );
    }

    _requireSchemaType(fields.enabled, const {'boolean', 'bool'});
    _requireSchemaType(fields.threshold, const {'number'});
    _requireSchemaType(fields.targetRatio, const {'number'});
    _requireSchemaType(fields.protectLastN, const {'integer', 'number'});

    final limits = CompressionConfigLimits(
      thresholdMinimum: _boundedDoubleMinimum(
        fields.threshold,
        CompressionConfigLimits.native.thresholdMinimum,
      ),
      thresholdMaximum: _boundedDoubleMaximum(
        fields.threshold,
        CompressionConfigLimits.native.thresholdMaximum,
      ),
      targetRatioMinimum: _boundedDoubleMinimum(
        fields.targetRatio,
        CompressionConfigLimits.native.targetRatioMinimum,
      ),
      targetRatioMaximum: _boundedDoubleMaximum(
        fields.targetRatio,
        CompressionConfigLimits.native.targetRatioMaximum,
      ),
      protectLastNMinimum: _boundedIntMinimum(
        fields.protectLastN,
        CompressionConfigLimits.native.protectLastNMinimum,
      ),
      protectLastNMaximum: _boundedIntMaximum(
        fields.protectLastN,
        CompressionConfigLimits.native.protectLastNMaximum,
      ),
    );
    if (limits.thresholdMinimum > limits.thresholdMaximum ||
        limits.targetRatioMinimum > limits.targetRatioMaximum ||
        limits.protectLastNMinimum > limits.protectLastNMaximum) {
      throw const FormatException('invalid compression schema bounds');
    }

    final record = _configRecord(config);
    final compression = _stringMap(record['compression']);
    if (compression == null) {
      throw const FormatException('missing compression config');
    }
    final optionalFields = CompressionConfigOptionalFields(
      thresholdTokens:
          fields.thresholdTokens != null &&
          compression.containsKey('threshold_tokens'),
      minTailUserMessages:
          fields.minTailUserMessages != null &&
          compression.containsKey('min_tail_user_messages'),
      progressNotices:
          fields.progressNotices != null &&
          compression.containsKey('progress_notices'),
    );
    if (optionalFields.thresholdTokens) {
      _requireSchemaType(fields.thresholdTokens!, const {
        'integer',
        'number',
        'string',
      });
    }
    if (optionalFields.minTailUserMessages) {
      _requireSchemaType(fields.minTailUserMessages!, const {
        'integer',
        'number',
      });
    }
    if (optionalFields.progressNotices) {
      _requireSchemaType(fields.progressNotices!, const {'boolean', 'bool'});
    }

    final enabled = compression['enabled'];
    final threshold = _finiteDouble(compression['threshold']);
    final targetRatio = _finiteDouble(compression['target_ratio']);
    final protectLastN = _integer(compression['protect_last_n']);
    if (enabled is! bool ||
        threshold == null ||
        targetRatio == null ||
        protectLastN == null) {
      throw const FormatException('invalid compression config');
    }
    final thresholdTokens = optionalFields.thresholdTokens
        ? _nullablePositiveInteger(compression['threshold_tokens'])
        : null;
    final minTailUserMessages = optionalFields.minTailUserMessages
        ? _nullablePositiveInteger(compression['min_tail_user_messages'])
        : null;
    final progressNotices = optionalFields.progressNotices
        ? compression['progress_notices'] as bool?
        : null;
    if (optionalFields.thresholdTokens &&
        compression['threshold_tokens'] != null &&
        thresholdTokens == null) {
      throw const FormatException('invalid compression threshold_tokens');
    }
    if (optionalFields.minTailUserMessages &&
        compression['min_tail_user_messages'] != null &&
        minTailUserMessages == null) {
      throw const FormatException('invalid compression min_tail_user_messages');
    }
    if (optionalFields.progressNotices &&
        compression['progress_notices'] != null &&
        progressNotices == null) {
      throw const FormatException('invalid compression progress_notices');
    }
    final configuration = CompressionConfig(
      enabled: enabled,
      threshold: threshold,
      targetRatio: targetRatio,
      protectLastN: protectLastN,
      thresholdTokens: thresholdTokens,
      minTailUserMessages: minTailUserMessages,
      progressNotices: progressNotices,
    );
    try {
      limits.requireValid(configuration);
    } on CompressionConfigException {
      throw const FormatException('compression config outside schema bounds');
    }
    return CompressionConfigSnapshot.supported(
      profile: profile,
      configuration: configuration,
      limits: limits,
      optionalFields: optionalFields,
      recordHandle: CompressionConfigRecordHandle.fromRedactedRecord(record),
      fetchedAt: fetchedAt,
    );
  }
}

final class _CompressionSchemaFields {
  final Map<String, dynamic> enabled;
  final Map<String, dynamic> threshold;
  final Map<String, dynamic> targetRatio;
  final Map<String, dynamic> protectLastN;
  final Map<String, dynamic>? thresholdTokens;
  final Map<String, dynamic>? minTailUserMessages;
  final Map<String, dynamic>? progressNotices;

  const _CompressionSchemaFields({
    required this.enabled,
    required this.threshold,
    required this.targetRatio,
    required this.protectLastN,
    this.thresholdTokens,
    this.minTailUserMessages,
    this.progressNotices,
  });
}

_CompressionSchemaFields? _compressionSchemaFields(
  Map<String, dynamic> schema,
) {
  final flat = _stringMap(schema['fields']);
  if (flat != null) {
    final enabled = _stringMap(flat['compression.enabled']);
    final threshold = _stringMap(flat['compression.threshold']);
    final targetRatio = _stringMap(flat['compression.target_ratio']);
    final protectLastN = _stringMap(flat['compression.protect_last_n']);
    if (enabled != null &&
        threshold != null &&
        targetRatio != null &&
        protectLastN != null) {
      return _CompressionSchemaFields(
        enabled: enabled,
        threshold: threshold,
        targetRatio: targetRatio,
        protectLastN: protectLastN,
        thresholdTokens: _stringMap(flat['compression.threshold_tokens']),
        minTailUserMessages: _stringMap(
          flat['compression.min_tail_user_messages'],
        ),
        progressNotices: _stringMap(flat['compression.progress_notices']),
      );
    }
    return null;
  }

  final rootProperties = _stringMap(schema['properties']);
  final compressionSchema = _stringMap(rootProperties?['compression']);
  final properties = _stringMap(compressionSchema?['properties']);
  if (properties == null) return null;
  final enabled = _stringMap(properties['enabled']);
  final threshold = _stringMap(properties['threshold']);
  final targetRatio = _stringMap(properties['target_ratio']);
  final protectLastN = _stringMap(properties['protect_last_n']);
  if (enabled == null ||
      threshold == null ||
      targetRatio == null ||
      protectLastN == null) {
    return null;
  }
  return _CompressionSchemaFields(
    enabled: enabled,
    threshold: threshold,
    targetRatio: targetRatio,
    protectLastN: protectLastN,
    thresholdTokens: _stringMap(properties['threshold_tokens']),
    minTailUserMessages: _stringMap(properties['min_tail_user_messages']),
    progressNotices: _stringMap(properties['progress_notices']),
  );
}

Map<String, dynamic> _configRecord(Map<String, dynamic> response) {
  if (response['compression'] is Map) return response;
  return _stringMap(response['config']) ?? response;
}

Map<String, dynamic>? _stringMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, dynamic> _freezeStringMap(Map<String, dynamic> value) {
  final frozen = <String, dynamic>{};
  for (final entry in value.entries) {
    frozen[entry.key] = _freezeJson(entry.value);
  }
  return Map<String, dynamic>.unmodifiable(frozen);
}

Object? _freezeJson(Object? value) {
  if (value == null || value is bool || value is String) return value;
  if (value is num) {
    if (!value.isFinite) {
      throw const FormatException('invalid config number');
    }
    return value;
  }
  if (value is Map) {
    final mapped = _stringMap(value);
    if (mapped == null) throw const FormatException('invalid config map');
    return _freezeStringMap(mapped);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  throw const FormatException('invalid config value');
}

Map<String, dynamic> _mutableStringMap(Map<String, dynamic> value) {
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    result[entry.key] = _mutableJson(entry.value);
  }
  return result;
}

Object? _mutableJson(Object? value) {
  if (value is Map) {
    final mapped = _stringMap(value);
    if (mapped == null) throw const FormatException('invalid config map');
    return _mutableStringMap(mapped);
  }
  if (value is List) return value.map(_mutableJson).toList();
  return value;
}

void _requireSchemaType(Map<String, dynamic> definition, Set<String> expected) {
  final type = definition['type'];
  if (type is! String || !expected.contains(type.toLowerCase())) {
    throw const FormatException('invalid compression schema type');
  }
}

double _boundedDoubleMinimum(Map<String, dynamic> definition, double fallback) {
  final value = _optionalFiniteDouble(
    definition['minimum'] ?? definition['min'],
  );
  return value == null || value < fallback ? fallback : value;
}

double _boundedDoubleMaximum(Map<String, dynamic> definition, double fallback) {
  final value = _optionalFiniteDouble(
    definition['maximum'] ?? definition['max'],
  );
  return value == null || value > fallback ? fallback : value;
}

int _boundedIntMinimum(Map<String, dynamic> definition, int fallback) {
  final value = _optionalInteger(definition['minimum'] ?? definition['min']);
  return value == null || value < fallback ? fallback : value;
}

int _boundedIntMaximum(Map<String, dynamic> definition, int fallback) {
  final value = _optionalInteger(definition['maximum'] ?? definition['max']);
  return value == null || value > fallback ? fallback : value;
}

double? _optionalFiniteDouble(Object? value) {
  if (value == null) return null;
  final parsed = _finiteDouble(value);
  if (parsed == null) {
    throw const FormatException('invalid compression schema bound');
  }
  return parsed;
}

int? _optionalInteger(Object? value) {
  if (value == null) return null;
  final parsed = _integer(value);
  if (parsed == null) {
    throw const FormatException('invalid compression schema bound');
  }
  return parsed;
}

double? _finiteDouble(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}

int? _integer(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final integer = value.toInt();
  return value == integer ? integer : null;
}

int? _nullablePositiveInteger(Object? value) {
  if (value == null) return null;
  final numeric = _integer(value);
  if (numeric != null) return numeric > 0 ? numeric : null;
  if (value is! String || !RegExp(r'^\d+$').hasMatch(value.trim())) {
    return null;
  }
  final parsed = int.tryParse(value.trim());
  return parsed != null && parsed > 0 ? parsed : null;
}
