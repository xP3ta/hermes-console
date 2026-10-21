import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// N10g: bodies above this size are decoded off the main isolate. The main
/// isolate is the platform/UI thread on Android, so a multi-hundred-KB
/// `jsonDecode` there blocks input.
const int kJsonDecodeOffMainBytes = 64 * 1024;

/// Test hook: observes every [decodeJsonOffMain] call that has no own `onPath`.
@visibleForTesting
void Function(bool offMain)? debugJsonDecodePathObserver;

/// Decodes [body]. Above [kJsonDecodeOffMainBytes] it runs in a short-lived
/// isolate (`Isolate.run`, SDK only); below it, inline, so small reads keep
/// their ordering and cost. [onPath] reports which path ran (test hook).
Future<Object?> decodeJsonOffMain(
  String body, {
  void Function(bool offMain)? onPath,
}) async {
  final offMain = body.length > kJsonDecodeOffMainBytes;
  (onPath ?? debugJsonDecodePathObserver)?.call(offMain);
  if (!offMain) return jsonDecode(body);
  return Isolate.run(() => jsonDecode(body));
}

bool _sameJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map) {
    if (b is! Map || a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !_sameJson(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List) {
    if (b is! List || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Returns [next] with every row that has the same stable `id` and identical
/// content as a row of [previous] replaced by that previous `Map`, so caches
/// keyed by row identity (list entries, sticky index, anchors, artifact
/// fingerprints) survive a recovery that changed nothing. Rows without an
/// `id`, or whose content changed, keep their new map.
List<Map<String, dynamic>> reuseUnchangedRowIdentities(
  Iterable<Map<String, dynamic>> previous,
  Iterable<Map<String, dynamic>> next,
) {
  final byId = <Object, Map<String, dynamic>>{};
  for (final row in previous) {
    final id = row['id'];
    if (id != null) byId.putIfAbsent(id, () => row);
  }
  final result = <Map<String, dynamic>>[];
  for (final row in next) {
    final id = row['id'];
    final old = id == null ? null : byId[id];
    result.add(old != null && _sameJson(old, row) ? old : row);
  }
  return result;
}
