import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../models/home_widget_snapshot.dart';

/// Applies app-level health/theme state without discarding the last known
/// session for the same instance during a cold start. A different (or missing)
/// instance always starts from a clean snapshot so data cannot cross profiles.
HermesHomeWidgetSnapshot mergeHomeWidgetBaseSnapshot({
  required HermesHomeWidgetSnapshot current,
  required bool configured,
  required String? instanceId,
  required String? instanceLabel,
  required HomeWidgetConnectionState connectionState,
  required HomeWidgetAgentState agentState,
  required HomeWidgetTheme theme,
}) {
  final sameInstance =
      configured &&
      instanceId != null &&
      current.instanceId != null &&
      current.instanceId == instanceId;
  if (!sameInstance) {
    return HermesHomeWidgetSnapshot(
      configured: configured,
      instanceId: instanceId,
      instanceLabel: instanceLabel,
      connectionState: connectionState,
      agentState: agentState,
      theme: theme,
    );
  }
  // A base refresh only knows that a connection attempt exists; it must not
  // overwrite a confirmed last-known online state (or an active agent state)
  // for the same instance. The real health probe publishes connecting and its
  // terminal connected/disconnected result explicitly.
  final preserveKnownOnline =
      connectionState == HomeWidgetConnectionState.connecting &&
      current.connectionState == HomeWidgetConnectionState.connected;
  final preserveKnownAgent =
      preserveKnownOnline &&
      current.agentState != HomeWidgetAgentState.disconnected &&
      current.agentState != HomeWidgetAgentState.error;
  return current.copyWith(
    configured: configured,
    instanceId: instanceId,
    instanceLabel: instanceLabel,
    connectionState: preserveKnownOnline
        ? HomeWidgetConnectionState.connected
        : connectionState,
    agentState: preserveKnownAgent ? current.agentState : agentState,
    clearToolName: !preserveKnownAgent,
    theme: theme,
  );
}

abstract interface class HomeWidgetStore {
  Future<Object?> read(String key);
  Future<void> write(String key, Object? value);
  Future<void> requestUpdate();
}

class PluginHomeWidgetStore implements HomeWidgetStore {
  const PluginHomeWidgetStore();

  static const _androidProviders = <String>[
    'com.hermesagent.hermes_android.NewSessionWidgetProvider',
    'com.hermesagent.hermes_android.HermesCompactWidgetProvider',
    'com.hermesagent.hermes_android.HermesControlWidgetProvider',
    // Bot Mode widgets also read this snapshot (connection label/state).
    'com.hermesagent.hermes_android.HermesBotsWidgetProvider',
    'com.hermesagent.hermes_android.HermesNeedsYouWidgetProvider',
    'com.hermesagent.hermes_android.HermesRoomWidgetProvider',
    'com.hermesagent.hermes_android.HermesQuickAskWidgetProvider',
    'com.hermesagent.hermes_android.HermesStatusWidgetProvider',
  ];

  @override
  Future<Object?> read(String key) => HomeWidget.getWidgetData<Object>(key);

  @override
  Future<void> write(String key, Object? value) async {
    switch (value) {
      case String value:
        await HomeWidget.saveWidgetData<String>(key, value);
      case int value:
        await HomeWidget.saveWidgetData<int>(key, value);
      case bool value:
        await HomeWidget.saveWidgetData<bool>(key, value);
      case double value:
        await HomeWidget.saveWidgetData<double>(key, value);
      case null:
        await HomeWidget.saveWidgetData<Object?>(key, null);
      default:
        throw ArgumentError.value(value, key, 'unsupported widget value');
    }
  }

  @override
  Future<void> requestUpdate() async {
    for (final provider in _androidProviders) {
      // Bot Mode receivers are disabled in release builds; a failed update of
      // one provider must never block the others.
      try {
        await HomeWidget.updateWidget(qualifiedAndroidName: provider);
      } catch (_) {}
    }
  }
}

/// Serial, idempotent owner of the widget snapshot.
///
/// Callers publish semantic snapshots, never write shared preferences directly.
/// Writes are queued so a terminal event cannot be overwritten by an older
/// asynchronous update that happened to finish later.
class HermesHomeWidgetPublisher {
  factory HermesHomeWidgetPublisher({
    HomeWidgetStore store = const PluginHomeWidgetStore(),
    int Function()? nowMs,
  }) => HermesHomeWidgetPublisher._(
    store,
    nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
  );

  HermesHomeWidgetPublisher._(this._store, this._nowMs) {
    _tail = _hydrate();
  }

  final HomeWidgetStore _store;
  final int Function() _nowMs;
  late Future<void> _tail;
  HermesHomeWidgetSnapshot _latest = HermesHomeWidgetSnapshot.empty;
  Map<String, Object?>? _lastWritten;

  HermesHomeWidgetSnapshot get latest => _latest;

  /// Applies a small semantic change without forcing each screen to maintain a
  /// second copy of the complete widget contract.
  Future<void> update(
    HermesHomeWidgetSnapshot Function(HermesHomeWidgetSnapshot current)
    transform,
  ) {
    final operation = _tail.then((_) {
      final stamped = transform(_latest).copyWith(updatedAtMs: _nowMs());
      _latest = stamped;
      return _write(stamped);
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> publish(HermesHomeWidgetSnapshot snapshot) {
    final stamped = snapshot.copyWith(updatedAtMs: _nowMs());
    final operation = _tail.then((_) {
      _latest = stamped;
      return _write(stamped);
    });
    // A launcher/plugin failure must not poison every later update. The caller
    // still receives this operation's error, while the internal queue recovers
    // and remains usable after the platform becomes available again.
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _hydrate() async {
    try {
      final atomic = await _store.read(
        HermesHomeWidgetSnapshot.atomicStorageKey,
      );
      if (atomic is String) {
        try {
          final decoded = jsonDecode(atomic);
          if (decoded is Map &&
              decoded['schema_version'] ==
                  HermesHomeWidgetSnapshot.schemaVersion) {
            final restored = HermesHomeWidgetSnapshot.fromMap(decoded);
            _latest = restored;
            _lastWritten = restored.toStorageMap();
            return;
          }
        } on FormatException {
          // Una copia atómica corrupta cae al contrato legado campo a campo.
        }
      }
      final raw = <String, Object?>{};
      for (final key in HermesHomeWidgetSnapshot.empty.toMap().keys) {
        raw[key] = await _store.read(
          '${HermesHomeWidgetSnapshot.storagePrefix}$key',
        );
      }
      final restored = HermesHomeWidgetSnapshot.fromMap(raw);
      _latest = restored;
      if (raw['schema_version'] == HermesHomeWidgetSnapshot.schemaVersion) {
        _lastWritten = restored.toStorageMap();
      }
    } catch (_) {
      // El launcher/plugin puede no estar disponible durante tests o arranque.
      // El primer publish seguirá partiendo del snapshot vacío seguro.
    }
  }

  Future<void> _write(HermesHomeWidgetSnapshot snapshot) async {
    final next = snapshot.toStorageMap();
    if (mapEquals(_lastWritten, next)) return;
    // Glance puede redibujar en cualquier punto (por ejemplo, justo al mandar
    // la app al fondo). Esta copia completa se reemplaza con una sola escritura
    // antes de tocar el espejo legado, evitando un frame «Sin configurar».
    await _store.write(
      HermesHomeWidgetSnapshot.atomicStorageKey,
      snapshot.toAtomicStorageValue(),
    );
    // Schema version is written last, acting as a tiny commit marker for the
    // legacy reader. New builds consume the atomic snapshot above.
    final schemaKey = '${HermesHomeWidgetSnapshot.storagePrefix}schema_version';
    await _store.write(schemaKey, null);
    for (final entry in next.entries) {
      if (entry.key == schemaKey) continue;
      await _store.write(entry.key, entry.value);
    }
    await _store.write(schemaKey, HermesHomeWidgetSnapshot.schemaVersion);
    await _store.requestUpdate();
    _lastWritten = next;
  }

  Future<void> flush() => _tail;
}
