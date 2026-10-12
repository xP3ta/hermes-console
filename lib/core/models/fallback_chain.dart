// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors

/// The top-level `fallback_providers` list of a Hermes profile: the models
/// tried in order when the main one fails.
///
/// Mirrors Desktop's `fallback-models-field.tsx`. An entry is
/// `{provider, model}` plus whatever routing the user hand-wrote (`base_url`,
/// `api_key`, `key_env`, `api_mode`…). Only the two names are edited here;
/// every other key rides along untouched, so a hand-written local-gateway
/// chain is never rewritten as bare pairs that route to the public provider.
library;

typedef FallbackEntry = Map<String, dynamic>;

/// Rows of a raw config value. Like Desktop's `normalizeEntries` it never
/// throws on odd data: a legacy `"provider/model"` string is split, anything
/// else becomes an empty pair.
List<FallbackEntry> fallbackChainFromConfig(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map)
        {
          ...item.map((key, value) => MapEntry(key.toString(), value)),
          'provider': _text(item['provider']),
          'model': _text(item['model']),
        }
      else if (item is String)
        _fromLegacyString(item)
      else
        {'provider': '', 'model': ''},
  ];
}

/// The chain of a `GET /api/config` answer. An answer that is not a
/// configuration object is a failed read, never "no fallbacks".
List<FallbackEntry> fallbackChainOfConfigAnswer(Map<String, dynamic> answer) {
  // The Dashboard client wraps a non-object JSON answer as `{data: …}`.
  if (answer.length == 1 && answer.containsKey('data')) {
    throw const FormatException('Invalid configuration response');
  }
  return fallbackChainFromConfig(answer['fallback_providers']);
}

FallbackEntry _fromLegacyString(String item) {
  final slash = item.indexOf('/');
  return slash > 0
      ? {
          'provider': item.substring(0, slash),
          'model': item.substring(slash + 1),
        }
      : {'provider': '', 'model': item};
}

String _text(Object? value) => value == null ? '' : value.toString();

bool isCompleteFallback(FallbackEntry entry) =>
    (entry['provider'] as String? ?? '').isNotEmpty &&
    (entry['model'] as String? ?? '').isNotEmpty;

/// The rows Hermes can use and this app persists (Desktop `completeEntries`).
List<FallbackEntry> completeFallbacks(List<FallbackEntry> chain) => [
  for (final entry in chain)
    if (isCompleteFallback(entry)) entry,
];

/// [chain] with [provider]/[model] appended as a new last resort.
List<FallbackEntry> fallbackAdded(
  List<FallbackEntry> chain,
  String provider,
  String model,
) => [
  ...completeFallbacks(chain),
  {'provider': provider, 'model': model},
];

/// [chain] with row [index] pointing at [provider]/[model]. The row keeps its
/// hand-written routing only while it stays on the same provider: an address
/// or key written for one provider is not a route of another.
List<FallbackEntry> fallbackReplaced(
  List<FallbackEntry> chain,
  int index,
  String provider,
  String model,
) {
  final rows = completeFallbacks(chain);
  if (index < 0 || index >= rows.length) return rows;
  final previous = rows[index];
  rows[index] = previous['provider'] == provider
      ? {...previous, 'model': model}
      : {'provider': provider, 'model': model};
  return rows;
}

/// [chain] without row [index]; the others keep their order and routing.
List<FallbackEntry> fallbackRemoved(List<FallbackEntry> chain, int index) {
  final rows = completeFallbacks(chain);
  if (index < 0 || index >= rows.length) return rows;
  return rows..removeAt(index);
}

/// Deep equality of two chains, independent of key order.
bool sameFallbackChain(List<FallbackEntry> a, List<FallbackEntry> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_same(a[i], b[i])) return false;
  }
  return true;
}

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
