// Test-only reader of Hermes' published gateway wire contract
// (test/fixtures/contract/gateway-contract.openrpc.json, refreshed by
// tool/contract/update_contract.sh) plus a minimal JSON-Schema sample
// generator. It understands exactly the subset the upstream generator emits
// (scripts/gen_gateway_contracts.py): object/properties/required, primitives,
// enum, const, anyOf-with-null, array/items, $ref, oneOf + discriminator and
// additionalProperties. Anything else fails loudly so a contract change is
// noticed here instead of silently producing a weaker sample.
import 'dart:convert';
import 'dart:io';

/// Name of a key no contract schema defines; injected into every object of
/// the "extra fields" samples to prove readers ignore unknown keys.
const contractUnknownKey = 'x_console_future_field';

/// A value outside every contract enum; parsers must fall back, never drop.
const contractUnknownEnumValue = 'x_console_future_enum';

final class GatewayContract {
  final Map<String, dynamic> document;
  final Map<String, dynamic> schemas;

  GatewayContract._(this.document)
    : schemas = Map<String, dynamic>.from(
        (document['components'] as Map)['schemas'] as Map,
      );

  static GatewayContract? _cached;

  static GatewayContract load() => _cached ??= GatewayContract._(
    jsonDecode(
          File(
            'test/fixtures/contract/gateway-contract.openrpc.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>,
  );

  Iterable<Map<String, dynamic>> get _methods =>
      (document['methods'] as List).cast<Map<String, dynamic>>();
  Iterable<Map<String, dynamic>> get _events =>
      (document['x-notifications'] as List).cast<Map<String, dynamic>>();
  Iterable<Map<String, dynamic>> get _serverRequests =>
      (document['x-server-requests'] as List).cast<Map<String, dynamic>>();

  Set<String> get methodNames => {for (final m in _methods) m['name']};
  Set<String> get eventNames => {for (final e in _events) e['name']};
  Set<String> get serverRequestNames => {
    for (final r in _serverRequests) r['name'],
  };

  Map<String, dynamic> _entry(Iterable<Map<String, dynamic>> all, String n) =>
      all.firstWhere(
        (entry) => entry['name'] == n,
        orElse: () => throw StateError('contract does not define $n'),
      );

  Map<String, dynamic> eventPayloadSchema(String event) =>
      ((_entry(_events, event)['params'] as List).single as Map)['schema']
          as Map<String, dynamic>;

  Map<String, dynamic> serverRequestParamsSchema(String method) =>
      ((_entry(_serverRequests, method)['params'] as List).single
              as Map)['schema']
          as Map<String, dynamic>;

  Map<String, dynamic> methodResultSchema(String method) =>
      (_entry(_methods, method)['result'] as Map)['schema']
          as Map<String, dynamic>;

  Map<String, dynamic> schemaNamed(String name) =>
      schemas[name] as Map<String, dynamic>? ??
      (throw StateError('contract has no schema $name'));

  Map<String, dynamic> resolve(Map<String, dynamic> schema) {
    var current = schema;
    for (var hops = 0; current.containsKey(r'$ref'); hops++) {
      if (hops > 16) throw StateError('ref cycle at ${schema[r'$ref']}');
      final ref = current[r'$ref'] as String;
      const prefix = '#/components/schemas/';
      if (!ref.startsWith(prefix)) throw StateError('unsupported ref $ref');
      current = schemaNamed(ref.substring(prefix.length));
    }
    return current;
  }
}

/// One generated payload and the shape rule that produced it.
final class ContractSample {
  final String label;
  final Map<String, dynamic> value;

  const ContractSample(this.label, this.value);

  @override
  String toString() => '$label: ${jsonEncode(value)}';
}

enum _Shape {
  /// Required fields only; optional fields absent.
  minimal,

  /// Every field present; every nullable field explicitly `null`.
  nulls,

  /// Every field present with a concrete (non-null) value.
  full,
}

/// Minimal JSON-Schema → sample generator over [GatewayContract].
final class ContractSampler {
  final GatewayContract contract;
  final int maxDepth;

  ContractSampler(this.contract, {this.maxDepth = 6});

  /// The full sample matrix for an object schema: minimal, nulls, full, each
  /// with and without unknown extra keys, and one sample per value of every
  /// top-level enum property plus an unknown enum value.
  List<ContractSample> samples(Map<String, dynamic> schema) {
    final out = <ContractSample>[];
    for (final shape in _Shape.values) {
      final base = _object(shape, schema, extra: false);
      out.add(ContractSample(shape.name, base));
      out.add(
        ContractSample(
          '${shape.name}+extra',
          _object(shape, schema, extra: true),
        ),
      );
    }
    final resolved = contract.resolve(schema);
    final properties =
        (resolved['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    final required = {...?(resolved['required'] as List?)?.cast<String>()};
    for (final property in properties.entries) {
      // One field at a time on an otherwise complete payload: a parser that
      // only copes with "all null" or "all present" still fails here.
      if (!required.contains(property.key)) {
        out.add(
          ContractSample(
            'absent ${property.key}',
            _object(_Shape.full, schema, extra: false)..remove(property.key),
          ),
        );
      }
      if (_nullable(property.value as Map<String, dynamic>)) {
        out.add(
          ContractSample(
            'null ${property.key}',
            _object(_Shape.full, schema, extra: false)..[property.key] = null,
          ),
        );
      }
      final values = enumValues(property.value as Map<String, dynamic>);
      if (values == null) continue;
      for (final value in [...values, contractUnknownEnumValue]) {
        final sample = _object(_Shape.full, schema, extra: false);
        sample[property.key] = value;
        out.add(ContractSample('enum ${property.key}=$value', sample));
      }
    }
    return out;
  }

  bool _nullable(Map<String, dynamic> schema) {
    final resolved = contract.resolve(schema);
    final anyOf = resolved['anyOf'];
    return resolved['type'] == 'null' ||
        (anyOf is List && anyOf.any((b) => (b as Map)['type'] == 'null'));
  }

  /// Enum values reachable from a property schema (through `$ref` and a
  /// nullable `anyOf`), or null when the property is not an enum.
  List<Object?>? enumValues(Map<String, dynamic> schema) {
    final resolved = contract.resolve(schema);
    if (resolved['enum'] is List) return List.of(resolved['enum'] as List);
    final anyOf = resolved['anyOf'];
    if (anyOf is List) {
      for (final branch in anyOf.cast<Map<String, dynamic>>()) {
        final values = enumValues(branch);
        if (values != null) return values;
      }
    }
    return null;
  }

  Map<String, dynamic> _object(
    _Shape shape,
    Map<String, dynamic> schema, {
    required bool extra,
  }) {
    final value = _value(shape, schema, 'root', 0, extra: extra);
    if (value is! Map<String, dynamic>) {
      throw StateError('schema root is not an object: $schema');
    }
    return value;
  }

  Object? _value(
    _Shape shape,
    Map<String, dynamic> raw,
    String name,
    int depth, {
    required bool extra,
  }) {
    final schema = contract.resolve(raw);
    if (schema.containsKey('const')) return schema['const'];
    final enumeration = schema['enum'];
    if (enumeration is List) return enumeration.first;
    final anyOf = schema['anyOf'] ?? schema['oneOf'];
    if (anyOf is List) {
      final branches = anyOf.cast<Map<String, dynamic>>();
      final nullable = branches.any((b) => b['type'] == 'null');
      if (nullable && shape == _Shape.nulls) return null;
      final concrete = branches.firstWhere(
        (b) => b['type'] != 'null',
        orElse: () => const {'type': 'null'},
      );
      return _value(shape, concrete, name, depth, extra: extra);
    }
    final type = schema['type'];
    switch (type) {
      case null:
        // `{}`: any JSON value. A string is the most common concrete use.
        return 'any_$name';
      case 'null':
        return null;
      case 'string':
        return _string(schema, name);
      case 'integer':
        return 1;
      case 'number':
        return 1.5;
      case 'boolean':
        return true;
      case 'array':
        if (depth >= maxDepth || shape == _Shape.minimal) return <Object?>[];
        final items = schema['items'];
        if (items is! Map<String, dynamic>) return <Object?>['any_$name'];
        return <Object?>[
          _value(shape, items, '$name[0]', depth + 1, extra: extra),
        ];
      case 'object':
        return _objectValue(shape, schema, name, depth, extra: extra);
    }
    throw StateError('unsupported schema type $type at $name');
  }

  String _string(Map<String, dynamic> schema, String name) {
    final pattern = schema['pattern'];
    if (pattern == r'^[a-z0-9][a-z0-9_-]*$') return 'x0';
    if (pattern is String) return '01ARZ3NDEKTSV4RRFFQ69G5FAV';
    // Identifier-shaped so id fields pass identity sanity checks.
    return 'v_${name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_')}';
  }

  Map<String, dynamic> _objectValue(
    _Shape shape,
    Map<String, dynamic> schema,
    String name,
    int depth, {
    required bool extra,
  }) {
    final out = <String, dynamic>{};
    final properties =
        (schema['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    final required = {...?(schema['required'] as List?)?.cast<String>()};
    if (depth < maxDepth) {
      for (final entry in properties.entries) {
        if (shape == _Shape.minimal && !required.contains(entry.key)) continue;
        out[entry.key] = _value(
          shape,
          entry.value as Map<String, dynamic>,
          entry.key,
          depth + 1,
          extra: extra,
        );
      }
      final additional = schema['additionalProperties'];
      if (properties.isEmpty &&
          additional is Map<String, dynamic> &&
          shape != _Shape.minimal) {
        out['k:$name'] = _value(
          shape,
          additional,
          '$name.*',
          depth + 1,
          extra: extra,
        );
      }
    }
    // A typed dictionary (`additionalProperties: {schema}` without
    // `properties`) has no "unknown" keys: an extra one must match its schema.
    if (extra &&
        (properties.isNotEmpty || schema['additionalProperties'] is! Map)) {
      out[contractUnknownKey] = {'nested': true, 'n': 1};
    }
    return out;
  }
}
