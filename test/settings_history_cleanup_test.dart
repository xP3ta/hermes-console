import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureValues = <String, String>{};
  Completer<void>? blockedWriteEntered;
  Completer<void>? releaseBlockedWrite;
  bool Function(String key)? shouldBlockWrite;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    secureValues.clear();
    blockedWriteEntered = null;
    releaseBlockedWrite = null;
    shouldBlockWrite = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          switch (call.method) {
            case 'write':
              final key = args['key'] as String;
              if (shouldBlockWrite?.call(key) ?? false) {
                blockedWriteEntered?.complete();
                await releaseBlockedWrite?.future;
              }
              secureValues[key] = args['value'] as String;
              return null;
            case 'read':
              return secureValues[args['key']];
            case 'readAll':
              return Map<String, String>.of(secureValues);
            case 'delete':
              secureValues.remove(args['key']);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<void> pumpActions(
    WidgetTester tester, {
    required bool readOnly,
    required VoidCallback onNormal,
  }) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: HistoryCleanupActionList(
          readOnly: readOnly,
          clearingNormal: false,
          onClearNormal: onNormal,
        ),
      ),
    ),
  );

  testWidgets('Ajustes solo expone la limpieza local del perfil activo', (
    tester,
  ) async {
    var normalTaps = 0;
    await pumpActions(tester, readOnly: false, onNormal: () => normalTaps++);

    expect(
      find.byKey(const ValueKey('history-cleanup-normal')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('history-cleanup-cron')), findsNothing);
    final strings = Strings.of(
      tester.element(find.byType(HistoryCleanupActionList)),
    );
    expect(find.text(strings.setClearConvos), findsOneWidget);
    expect(find.text(strings.crnCleanupTitle), findsNothing);

    await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
    expect(normalTaps, 1);
  });

  testWidgets('solo lectura desactiva la limpieza local', (tester) async {
    await pumpActions(
      tester,
      readOnly: true,
      onNormal: () => fail('normal no debe habilitarse'),
    );

    final normal = tester.widget<InkWell>(
      find.byKey(const ValueKey('history-cleanup-normal')),
    );
    expect(normal.onTap, isNull);
    expect(find.byKey(const ValueKey('history-cleanup-cron')), findsNothing);
  });

  testWidgets(
    'congela la instancia y bloquea doble toque mientras verifica App Lock',
    (tester) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final connectionA = SavedConnection(
        id: 'instance-a',
        label: 'Instancia A',
        host: '127.0.0.2',
        port: 8642,
        apiKey: 'key-a',
        kind: InstanceKind.vps,
      );
      final connectionB = SavedConnection(
        id: 'instance-b',
        label: 'Instancia B',
        host: '127.0.0.3',
        port: 8642,
        apiKey: 'key-b',
        kind: InstanceKind.vps,
      );

      final verification = Completer<bool>();
      var verificationCalls = 0;
      Widget sectionFor(SavedConnection connection) => MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: HistoryCleanupSection(
            key: ValueKey('history-cleanup-${connection.id}'),
            connection: connection,
            connManager: manager,
            verifyHistoryCleanupForTesting: () {
              verificationCalls++;
              return verification.future;
            },
          ),
        ),
      );

      await tester.pumpWidget(sectionFor(connectionA));

      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));

      await tester.pumpWidget(sectionFor(connectionB));
      verification.complete(true);
      await tester.pump();
      await tester.pump();

      expect(verificationCalls, 1);
      expect(
        find.byKey(ValueKey('history-cleanup-${connectionB.id}')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmar limpieza local conserva perfiles y conexiones vecinas',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final connection = SavedConnection(
        id: 'instance-a',
        label: 'Instancia A',
        host: '127.0.0.2',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.vps,
      );
      await manager.setActiveProfile(connection.id, 'profile-a');
      final drafts = ChatDraftStore(prefs);
      await drafts.save(
        connection.id,
        'shared',
        'remove me',
        const [],
        profile: 'profile-a',
      );
      await drafts.save(
        connection.id,
        'shared',
        'keep profile',
        const [],
        profile: 'profile-b',
      );
      await drafts.save(
        'instance-b',
        'shared',
        'keep connection',
        const [],
        profile: 'profile-a',
      );
      await LocalTranscriptStore.saveFromNewestFirst(
        connection.id,
        'shared',
        const [
          {'role': 'assistant', 'content': 'remove transcript'},
        ],
        profile: 'profile-a',
      );
      await LocalTranscriptStore.saveFromNewestFirst(
        connection.id,
        'shared',
        const [
          {'role': 'assistant', 'content': 'keep transcript'},
        ],
        profile: 'profile-b',
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: Scaffold(
            body: HistoryCleanupSection(
              connection: connection,
              connManager: manager,
              verifyHistoryCleanupForTesting: () async => true,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final strings = Strings.of(tester.element(find.byType(AlertDialog)));
      expect(find.text(strings.setClearConvosBody), findsNothing);
      await tester.tap(find.text(strings.commonDelete));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        (await drafts.load(connection.id, 'shared', profile: 'profile-a')).text,
        isEmpty,
      );
      expect(
        (await drafts.load(connection.id, 'shared', profile: 'profile-b')).text,
        'keep profile',
      );
      expect(
        (await drafts.load('instance-b', 'shared', profile: 'profile-a')).text,
        'keep connection',
      );
      expect(
        await LocalTranscriptStore.load(
          connection.id,
          'shared',
          profile: 'profile-a',
        ),
        isEmpty,
      );
      expect(
        await LocalTranscriptStore.load(
          connection.id,
          'shared',
          profile: 'profile-b',
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'REGRESSION_CLEANUP_BARRIER serializa draft admitido y rechaza autosave tardío',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final lifecycle = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'instance-a',
        profile: 'profile-a',
        sessionId: 'session-a',
      );
      expect(LocalConversationCleanupFence.rehydrate(lifecycle), isTrue);
      final drafts = ChatDraftStore(prefs);
      final draftKey = ChatDraftStore.keyForTesting(
        'instance-a',
        'session-a',
        profile: 'profile-a',
      );
      blockedWriteEntered = Completer<void>();
      releaseBlockedWrite = Completer<void>();
      shouldBlockWrite = (key) => key == draftKey;

      final admitted = drafts.save(
        'instance-a',
        'session-a',
        'admitted before cleanup',
        const [],
        profile: 'profile-a',
        lifecycle: lifecycle,
      );
      await blockedWriteEntered!.future;
      final cleanup = clearProfileLocalConversationState(
        connectionId: 'instance-a',
        profile: 'profile-a',
        clearDrafts: ({required profile}) =>
            drafts.deleteForProfile('instance-a', profile),
        clearTranscripts: ({required profile}) =>
            LocalTranscriptStore.deleteForProfile('instance-a', profile),
        clearOutbox: ({required profile}) =>
            TurnOutboxStore().deleteForProfile('instance-a', profile),
      );
      shouldBlockWrite = null;
      final late = expectLater(
        drafts.save(
          'instance-a',
          'session-a',
          'late autosave',
          const [],
          profile: 'profile-a',
          lifecycle: lifecycle,
        ),
        throwsA(isA<LocalConversationWriteRejected>()),
      );

      releaseBlockedWrite!.complete();
      await admitted;
      final summary = await cleanup;
      await late;
      expect(summary.allSucceeded, isTrue);
      expect(secureValues.containsKey(draftKey), isFalse);
    },
  );

  test(
    'REGRESSION_CLEANUP_BARRIER serializa transcript V3 y rechaza callback tardío',
    () async {
      final lifecycle = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'instance-a',
        profile: 'profile-a',
        sessionId: 'session-a',
      );
      expect(LocalConversationCleanupFence.rehydrate(lifecycle), isTrue);
      blockedWriteEntered = Completer<void>();
      releaseBlockedWrite = Completer<void>();
      shouldBlockWrite = (key) => key.startsWith('hermes.transcript.v3.');

      final admitted = LocalTranscriptStore.saveFromNewestFirst(
        'instance-a',
        'session-a',
        const [
          {'role': 'assistant', 'content': 'admitted before cleanup'},
        ],
        profile: 'profile-a',
        lifecycle: lifecycle,
      );
      await blockedWriteEntered!.future;
      final cleanup = clearProfileLocalConversationState(
        connectionId: 'instance-a',
        profile: 'profile-a',
        clearDrafts: ({required profile}) async => 0,
        clearTranscripts: ({required profile}) =>
            LocalTranscriptStore.deleteForProfile('instance-a', profile),
        clearOutbox: ({required profile}) async => 0,
      );
      shouldBlockWrite = null;
      final late = expectLater(
        LocalTranscriptStore.saveFromNewestFirst(
          'instance-a',
          'session-a',
          const [
            {'role': 'assistant', 'content': 'late callback'},
          ],
          profile: 'profile-a',
          lifecycle: lifecycle,
        ),
        throwsA(isA<LocalConversationWriteRejected>()),
      );

      releaseBlockedWrite!.complete();
      await admitted;
      final summary = await cleanup;
      await late;
      expect(summary.allSucceeded, isTrue);
      expect(
        await LocalTranscriptStore.load(
          'instance-a',
          'session-a',
          profile: 'profile-a',
        ),
        isEmpty,
      );
    },
  );

  test(
    'REGRESSION_CLEANUP_BARRIER serializa cleanup de conexión contra first-key',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final lifecycle = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'instance-a',
        profile: 'profile-a',
        sessionId: 'session-a',
      );
      expect(LocalConversationCleanupFence.rehydrate(lifecycle), isTrue);
      final drafts = ChatDraftStore(prefs);
      final draftKey = ChatDraftStore.keyForTesting(
        'instance-a',
        'session-a',
        profile: 'profile-a',
      );
      blockedWriteEntered = Completer<void>();
      releaseBlockedWrite = Completer<void>();
      shouldBlockWrite = (key) => key == draftKey;

      final admitted = drafts.save(
        'instance-a',
        'session-a',
        'first key',
        const [],
        profile: 'profile-a',
        lifecycle: lifecycle,
      );
      await blockedWriteEntered!.future;
      final cleanup = drafts.deleteForConnection('instance-a');
      shouldBlockWrite = null;
      final late = expectLater(
        drafts.save(
          'instance-a',
          'session-a',
          'late callback',
          const [],
          profile: 'profile-a',
          lifecycle: lifecycle,
        ),
        throwsA(isA<LocalConversationWriteRejected>()),
      );

      releaseBlockedWrite!.complete();
      await admitted;
      expect(await cleanup, 1);
      await late;
      expect(secureValues.containsKey(draftKey), isFalse);
    },
  );

  test(
    'outbox corrupta marca fallo real y conserva cleanup best-effort de stores',
    () async {
      secureValues['chat_turn_outbox_v1'] = '{not-json';
      final calls = <String>[];
      final summary = await clearProfileLocalConversationState(
        connectionId: 'instance-a',
        profile: 'profile-a',
        clearDrafts: ({required profile}) async {
          calls.add('draft:$profile');
          return 2;
        },
        clearTranscripts: ({required profile}) async {
          calls.add('transcript:$profile');
          return 3;
        },
        clearOutbox: ({required profile}) async {
          calls.add('outbox:$profile');
          return TurnOutboxStore().deleteForProfile('instance-a', profile);
        },
      );

      expect(calls, [
        'draft:profile-a',
        'transcript:profile-a',
        'outbox:profile-a',
      ]);
      expect(summary.drafts.removed, 2);
      expect(summary.transcripts.removed, 3);
      expect(summary.outbox.succeeded, isFalse);
      expect(summary.allSucceeded, isFalse);
      expect(summary.localFailureCount, 1);
      expect(secureValues['chat_turn_outbox_v1'], '{not-json');
    },
  );

  test('ChatScreen liga rehydrate y autosaves al lifecycle owner vigente', () {
    final source = File('lib/core/screens/chat_screen.dart').readAsStringSync();
    final initStart = source.indexOf('  void initState()');
    final restoreStart = source.indexOf('  Future<void> _restoreDraft()');
    final restoreEnd = source.indexOf('\n  Future<', restoreStart + 1);
    final disposeStart = source.indexOf('  void dispose()');
    final disposeEnd = source.indexOf('\n  @override', disposeStart + 1);
    final init = source.substring(initStart, restoreStart);
    final restore = source.substring(restoreStart, restoreEnd);
    final dispose = source.substring(disposeStart, disposeEnd);

    expect(init, contains('LocalConversationCleanupFence.beginLifecycle('));
    expect(
      init.indexOf('LocalConversationCleanupFence.beginLifecycle('),
      lessThan(init.indexOf('unawaited(_restoreDraftAndRunInitialAction())')),
    );
    expect(restore, contains('if (!mounted || _disposed) return;'));
    expect(restore, contains('LocalConversationCleanupFence.rehydrate('));
    expect(restore, contains('lifecycle: _localConversationLifecycle'));
    expect(dispose, contains('LocalConversationCleanupFence.endLifecycle('));
    expect(dispose, contains('finalDraftSave.whenComplete('));
    expect(
      dispose.indexOf('finalDraftSave.whenComplete('),
      lessThan(dispose.indexOf('LocalConversationCleanupFence.endLifecycle(')),
    );
  });

  test('la limpieza local conserva App Lock sin callback remoto Cron', () {
    final source = File(
      'lib/core/screens/settings_screen.dart',
    ).readAsStringSync();

    expect(source, contains('authorizeHistoryCleanup('));
    expect(source, contains('scope: HistoryCleanupScope.normalConversations'));
    expect(source, isNot(contains('previewConversationCleanup()')));
    expect(source, isNot(contains('deleteCronConversations(')));
    expect(source, isNot(contains('HistoryCleanupScope.cronResults')));
  });

  test('vaciar conversaciones es local-only y enlaza el perfil activo', () {
    final source = File(
      'lib/core/screens/settings_screen.dart',
    ).readAsStringSync();
    final normalStart = source.indexOf('Future<void> _clearNormal()');
    final normalCleanup = source.substring(
      normalStart,
      source.indexOf('  @override\n  Widget build', normalStart),
    );

    expect(normalCleanup, contains('activeProfileFor('));
    expect(normalCleanup, contains('clearProfileLocalConversationState('));
    expect(normalCleanup, contains('profile: targetProfile'));
    expect(normalCleanup, contains('ChatDraftStore('));
    expect(normalCleanup, contains(').deleteForProfile('));
    expect(normalCleanup, contains('LocalTranscriptStore.deleteForProfile('));
    expect(normalCleanup, contains('TurnOutboxStore().deleteForProfile('));
    expect(normalCleanup, isNot(contains('ApiClient(')));
    expect(normalCleanup, isNot(contains('.getSessions(')));
    expect(normalCleanup, isNot(contains('.deleteSession(')));
    expect(normalCleanup, isNot(contains('setClearConvosBody')));
    expect(normalCleanup, isNot(contains('localizedApiError(')));
    expect(normalCleanup, isNot(contains('deleteForConnection(')));
  });
}
