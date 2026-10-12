// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// QA (Pixel, cold start): the chat model picker sat on a spinner while the
// server built `model.options` (seconds when a provider key comes from a
// helper). Desktop loads the catalog at startup for its model menu; Console
// now reads it once Home is idle, over the socket Home already holds, into
// the caches the picker reads. It never opens a socket of its own.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/models/model_active_info.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';
import 'package:hermes_android/core/services/model_picker_prewarm.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _catalog = {
  'model': 'disk-model',
  'provider': 'provider-a',
  'providers': [
    {
      'slug': 'provider-a',
      'name': 'Provider A',
      'authenticated': true,
      'is_current': true,
      'models': ['disk-model', 'other-model'],
    },
    {'slug': 'empty', 'name': 'Empty', 'models': <String>[]},
  ],
};

final class _Socket implements HermesDesktopGlobalModelCatalogGateway {
  final calls = <({String profile, bool connectedOnly})>[];
  bool fail = false;

  @override
  Future<DesktopModelCatalog> globalModelOptions({
    String profile = '',
    bool refresh = false,
    Duration? timeout,
    bool connectedOnly = false,
  }) async {
    calls.add((profile: profile, connectedOnly: connectedOnly));
    if (fail) throw StateError('synthetic catalog failure');
    return DesktopModelCatalog.fromJson(_catalog);
  }
}

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'picker-prewarm',
  label: 'Synthetic picker',
  host: 'picker.example.test',
  port: 8642,
  apiKey: 'synthetic-gateway',
  readOnly: readOnly,
);

void main() {
  late ActiveChatService chats;
  late _Socket socket;
  late int leases;
  late int releases;
  late bool connected;

  setUp(() {
    chats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      globalActivity: GlobalActivityAggregate.inMemory(),
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    socket = _Socket();
    leases = 0;
    releases = 0;
    connected = true;
  });
  tearDown(() => chats.dispose());

  ModelPickerPrewarm prewarm() => ModelPickerPrewarm(
    leaseSource: (_) {
      if (!connected) return null;
      leases++;
      return (client: socket, release: () => releases++);
    },
  );

  String key(String owner) => ModelPickerCache.key('picker-prewarm', owner);

  test('an idle Home fills the picker cache over its open socket', () {
    fakeAsync((async) {
      prewarm().schedule(
        chats: chats,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      async.elapse(const Duration(seconds: 2));
      expect(socket.calls, isEmpty, reason: 'waits for Home to be idle');
      async.elapse(const Duration(seconds: 2));
      expect(socket.calls, [(profile: 'ana', connectedOnly: true)]);
      final entry = chats.modelPickerCache.peek(key('ana'));
      expect(entry, isNotNull);
      expect(entry!.fresh, isTrue);
      expect(entry.result.source, ModelPickerSource.socket);
      expect(entry.result.providers.map((p) => p.slug), ['provider-a']);
      expect(entry.result.info.model, 'disk-model');
      expect(chats.modelCatalogCache.read('picker-prewarm', 'ana'), isNotNull);
      expect(chats.modelPickerCache.peek(key('bob')), isNull);
      expect((leases, releases), (1, 1));
    });
  });

  test('no open socket: nothing is opened and nothing is cached', () {
    fakeAsync((async) {
      connected = false;
      final warm = prewarm();
      warm.schedule(
        chats: chats,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      async.elapse(const Duration(seconds: 5));
      expect(socket.calls, isEmpty);
      expect(chats.modelPickerCache.peek(key('ana')), isNull);

      // The next idle Home with the socket up reads it.
      connected = true;
      warm.schedule(
        chats: chats,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      async.elapse(const Duration(seconds: 5));
      expect(socket.calls, hasLength(1));
    });
  });

  test('a busy Home, a backgrounded app or a cached picker skip the read', () {
    fakeAsync((async) {
      final warm = prewarm();
      warm.schedule(
        chats: chats,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => false,
      );
      async.elapse(const Duration(seconds: 5));
      warm.schedule(
        chats: chats,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      warm.cancel();
      async.elapse(const Duration(seconds: 5));
      expect(socket.calls, isEmpty);

      chats.modelPickerCache.write(
        key('ana'),
        ModelPickerResult(
          info: ModelActiveInfo(
            model: 'other',
            provider: 'provider-b',
            effectiveContextLength: 0,
          ),
          providers: const [],
          source: ModelPickerSource.dashboard,
        ),
      );
      warm.schedule(
        chats: chats,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      async.elapse(const Duration(seconds: 5));
      expect(socket.calls, isEmpty);
    });
  });

  test('a failed read caches nothing and gives the socket back', () {
    fakeAsync((async) {
      socket.fail = true;
      prewarm().schedule(
        chats: chats,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      async.elapse(const Duration(seconds: 5));
      expect(socket.calls, hasLength(1));
      expect(chats.modelPickerCache.peek(key('ana')), isNull);
      expect((leases, releases), (1, 1));
    });
  });

  test('a failed read is not retried on every idle Home', () {
    fakeAsync((async) {
      socket.fail = true;
      final warm = prewarm();
      for (var i = 0; i < 3; i++) {
        warm.schedule(
          chats: chats,
          connection: _connection(),
          profileOwner: 'ana',
          stillIdle: () => true,
        );
        async.elapse(const Duration(seconds: 5));
      }
      expect(socket.calls, hasLength(1));
    });
  });

  test('a read-only connection never prewarms the picker', () {
    fakeAsync((async) {
      prewarm().schedule(
        chats: chats,
        connection: _connection(readOnly: true),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      async.elapse(const Duration(seconds: 5));
      expect(socket.calls, isEmpty);
      expect(leases, 0);
    });
  });
}
