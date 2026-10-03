// One session state (#21): the home screen widget leaves a session the
// server confirmed deleted, from the shared SessionArchive, and a late event
// from the deleted chat cannot publish it again.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements HomeWidgetStore {
  final values = <String, Object?>{};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> requestUpdate() async {}

  /// What the launcher widget reads.
  String? get sessionId {
    final atomic = values[HermesHomeWidgetSnapshot.atomicStorageKey];
    if (atomic is! String) return null;
    return (jsonDecode(atomic) as Map)['session_id'] as String?;
  }
}

/// A launcher store whose first read (cold start hydration) is slow.
class _SlowStore extends _Store {
  final gate = Completer<void>();

  @override
  Future<Object?> read(String key) async {
    await gate.future;
    return super.read(key);
  }
}

Session _session(String id) => Session(
  id: id,
  title: 'Chat $id',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: '',
  startedAt: 1785312000,
);

HermesHomeWidgetSnapshot _chat(String sessionId, {String instance = 'c1'}) =>
    HermesHomeWidgetSnapshot(
      configured: true,
      instanceId: instance,
      instanceLabel: 'Server',
      connectionState: HomeWidgetConnectionState.connected,
      sessionId: sessionId,
      sessionTitle: 'Chat $sessionId',
      agentState: HomeWidgetAgentState.streaming,
      toolName: 'terminal',
      contextPercent: 40,
      inputTokens: 1200,
      lastActivityAtMs: 1785312000000,
    );

void main() {
  late SharedPreferences prefs;
  late _Store store;
  late HermesHomeWidgetPublisher publisher;
  late HomeWidgetDeletedSessionGuard guard;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = _Store();
    publisher = HermesHomeWidgetPublisher(store: store);
    guard = HomeWidgetDeletedSessionGuard(publisher, prefs);
    await guard.follow('c1');
  });

  tearDown(() => guard.dispose());

  test('a confirmed delete clears the widget session at once', () async {
    await publisher.publish(_chat('gone'));
    expect(store.sessionId, 'gone');

    final archive = await SessionArchive.load(prefs, 'c1');
    await archive.markSessionDeleted(_session('gone'));
    await publisher.flush();

    final latest = publisher.latest;
    expect(latest.sessionId, isNull);
    expect(latest.sessionTitle, isNull);
    expect(latest.toolName, isNull);
    expect(latest.contextPercent, isNull);
    expect(latest.inputTokens, isNull);
    expect(latest.agentState, HomeWidgetAgentState.idle);
    expect(latest.instanceId, 'c1');
    expect(latest.connectionState, HomeWidgetConnectionState.connected);
    expect(store.sessionId, isNull);
  });

  test('a late event from the deleted chat cannot republish it', () async {
    final archive = await SessionArchive.load(prefs, 'c1');
    await archive.markSessionDeleted(_session('gone'));
    // The chat service publishes whole snapshots...
    await publisher.publish(_chat('gone'));
    expect(publisher.latest.sessionId, isNull);
    expect(store.sessionId, isNull);
    // ...and throttled metrics through update.
    await publisher.update((current) => _chat('gone'));
    expect(publisher.latest.sessionId, isNull);
    expect(store.sessionId, isNull);

    // Another chat of the same instance still reaches the widget.
    await publisher.publish(_chat('kept'));
    expect(store.sessionId, 'kept');
    // So does the same id on another instance: tombstones are per connection.
    await publisher.publish(_chat('gone', instance: 'c2'));
    expect(store.sessionId, 'gone');
  });

  test('a snapshot restored at cold start leaves a deleted session', () async {
    final archive = await SessionArchive.load(prefs, 'c1');
    await archive.markSessionDeleted(_session('gone'));
    final restored = _SlowStore()
      ..values[HermesHomeWidgetSnapshot.atomicStorageKey] = _chat(
        'gone',
      ).toAtomicStorageValue();
    final coldPublisher = HermesHomeWidgetPublisher(store: restored);
    final coldGuard = HomeWidgetDeletedSessionGuard(coldPublisher, prefs);
    addTearDown(coldGuard.dispose);
    // The launcher store answers after the guard is already following.
    final following = coldGuard.follow('c1');
    await Future<void>.delayed(Duration.zero);
    restored.gate.complete();
    await following;
    await coldPublisher.flush();
    expect(coldPublisher.latest.sessionId, isNull);
    expect(restored.sessionId, isNull);
  });
}
