// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/diagnostic_bundle_service.dart';
import 'package:hermes_android/core/services/sealed_local_files.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/diagnostic_bundle_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_sealed_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secure = <String, String>{};
  var fails = (String method, String key) => false;
  // What a platform error can carry; none of it may reach the export.
  const privateDetail = 'chat_draft_v3.private-key private draft text';
  const privateIds = ['conn-private', 'session-private', 'turn-private'];

  setUp(() {
    secure.clear();
    fails = (_, _) => false;
    SharedPreferences.setMockInitialValues({});
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = '${args['key']}';
      if (fails(call.method, key)) {
        throw PlatformException(
          code: 'Exception encountered',
          message: privateDetail,
        );
      }
      switch (call.method) {
        case 'write':
          secure[key] = args['value'] as String;
          return null;
        case 'read':
          return secure[key];
        case 'delete':
          secure.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(secure);
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// The diagnostic export the user can share from Settings.
  Future<String> export() async {
    fails = (_, _) => false;
    final prefs = await SharedPreferences.getInstance();
    final support = await Directory.systemTemp.createTemp('secure-diag-');
    addTearDown(() => support.delete(recursive: true));
    final controller = DiagnosticBundleController(
      manager: await ConnectionManager.create(prefs),
      service: DiagnosticBundleService(cacheDirectory: () async => support),
      runtimeInfo: () async => const DiagnosticRuntimeInfo(
        version: '1.4.1',
        build: 1,
        flavor: DiagnosticFlavor.qa,
        androidApi: 36,
      ),
      supportDirectory: () async => support,
    );
    return (await controller.prepare(DiagnosticFormFactor.phone)).preview;
  }

  Map<String, dynamic> failureOf(String preview, String operation) {
    final json = jsonDecode(preview) as Map<String, dynamic>;
    return (json['secureStorage'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((entry) => entry['operation'] == operation);
  }

  void expectNothingPrivate(String preview) {
    for (final private in [...privateIds, privateDetail, 'chat_draft_v3']) {
      expect(preview, isNot(contains(private)), reason: private);
    }
  }

  test('a draft read that fails is exported as its operation and error type, '
      'counted, and nothing else', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    fails = (method, key) =>
        method == 'read' && key.startsWith('chat_draft_v3.');
    for (var i = 0; i < 2; i++) {
      await expectLater(
        store.load('conn-private', 'session-private'),
        throwsA(isA<PlatformException>()),
      );
    }

    final preview = await export();

    final failure = failureOf(preview, 'draftLoad');
    expect(failure.keys.toSet(), {
      'operation',
      'errorType',
      'count',
      'firstAt',
      'lastAt',
    });
    expect(failure['errorType'], 'PlatformException');
    expect(failure['count'], 2);
    expect(DateTime.parse(failure['lastAt'] as String).isUtc, isTrue);
    expectNothingPrivate(preview);
  });

  test('a turn the outbox cannot store or read back is exported', () async {
    final outbox = TurnOutboxStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    final turn = PreparedTurn(
      connectionId: 'conn-private',
      sessionId: 'session-private',
      clientTurnId: 'turn-private',
      createdAtMs: now,
      updatedAtMs: now,
      text: 'private draft text',
      model: 'model',
      profile: 'default',
      attachments: const [],
    );
    // The outbox is a sealed file: the disk refuses it.
    final files = MemorySealedFileIo.of(SealedLocalFiles.outbox)..resetHooks();
    addTearDown(files.resetHooks);
    Never refuse(String _) =>
        throw const FileSystemException(privateDetail, '/private/path');
    files.beforeWrite = (name) async => refuse(name);
    await expectLater(outbox.save(turn), throwsA(isA<FileSystemException>()));
    files.beforeWrite = null;
    files.beforeRead = (name) async => refuse(name);
    await expectLater(
      outbox.loadAllForChat(
        'conn-private',
        'session-private',
        profile: 'default',
      ),
      throwsA(isA<FileSystemException>()),
    );
    files.beforeRead = null;

    final preview = await export();

    expect(
      failureOf(preview, 'outboxSave')['errorType'],
      'FileSystemException',
    );
    expect(
      failureOf(preview, 'outboxRead')['errorType'],
      'FileSystemException',
    );
    expectNothingPrivate(preview);
    expect(preview, isNot(contains('/private/path')));
  });

  test('a cold start whose index cannot be read is exported', () async {
    fails = (method, key) => method == 'read' && key == ColdStartStore.indexKey;

    expect(await ColdStartStore().routeFor('conn-private'), isNull);

    final preview = await export();
    final failure = failureOf(preview, 'coldStartIndex');
    expect(failure['errorType'], 'PlatformException');
    expectNothingPrivate(preview);
  });

  test('a draft list the app lock refuses is exported by its type', () async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    expect(AppLockService(prefs).locked.value, isTrue);

    await expectLater(
      ChatDraftStore(prefs).listForConnection('conn-private'),
      throwsA(isA<SensitiveReadUnavailable>()),
    );

    final preview = await export();
    expect(
      failureOf(preview, 'draftList')['errorType'],
      'SensitiveReadUnavailable',
    );
    expectNothingPrivate(preview);
  });
}
