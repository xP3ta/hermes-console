import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
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

  Widget wrap(Widget child) => MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromId('dark'),
    home: Scaffold(body: child),
  );

  Future<void> pumpActions(
    WidgetTester tester, {
    required bool readOnly,
    required VoidCallback onNormal,
    bool clearingNormal = false,
    ({int done, int total})? remoteProgress,
    VoidCallback? onCancelNormal,
  }) => tester.pumpWidget(
    wrap(
      HistoryCleanupActionList(
        readOnly: readOnly,
        clearingNormal: clearingNormal,
        onClearNormal: onNormal,
        remoteProgress: remoteProgress,
        onCancelNormal: onCancelNormal,
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
    'confirmar limpieza vacía servidor y local del perfil activo, y conserva vecinos',
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

      final deleted = <String>[];
      final remote = ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: connection.apiKey,
        connectionId: connection.id,
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/sessions')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'chat-1', 'source': 'mobile', 'title': 'chat'},
                  {'id': 'cron_job_1', 'source': 'cron', 'title': 'informe'},
                ],
              }),
              200,
            );
          }
          if (request.method == 'DELETE') {
            deleted.add(request.url.pathSegments.last);
            return http.Response(jsonEncode({'deleted': true}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(remote.close);

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
              remoteClientOverride: remote,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // La acción ya no borra a ciegas: pregunta el ámbito primero.
      expect(
        find.byKey(const ValueKey('history-cleanup-scope-chats')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('history-cleanup-scope-automations')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('history-cleanup-scope-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // El chat normal se borra en el SERVIDOR (antes solo se limpiaba lo
      // local y la sesión volvía al refrescar); Cron no estaba elegido.
      expect(deleted, ['chat-1']);
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

  test(
    'vaciar conversaciones borra servidor Y local, siempre del perfil activo',
    () {
      final source = File(
        'lib/core/screens/settings_screen.dart',
      ).readAsStringSync();
      final remoteStart = source.indexOf(
        'Future<RemoteConversationClearSummary> _clearRemote(',
      );
      final normalStart = source.indexOf('Future<void> _clearNormal()');
      final normalCleanup = source.substring(
        remoteStart,
        source.indexOf('  @override\n  Widget build', normalStart),
      );

      // El ámbito se elige antes de borrar nada.
      expect(normalCleanup, contains('HistoryCleanupScopeDialog()'));
      // Mitad remota: sin ella las sesiones seguían en el servidor y volvían
      // a la lista al refrescar ("no se borran todas").
      expect(normalCleanup, contains('.getSessions('));
      expect(normalCleanup, contains('includeChildren: true'));
      expect(normalCleanup, contains('historyCleanupDeleteOrder('));
      expect(normalCleanup, contains('clearRemoteConversations('));
      expect(normalCleanup, contains('.deleteSession('));
      // Mitad local, todavía enlazada al perfil activo y nunca a la conexión
      // completa.
      expect(normalCleanup, contains('activeProfileFor('));
      expect(normalCleanup, contains('clearProfileLocalConversationState('));
      expect(normalCleanup, contains('profile: targetProfile'));
      expect(normalCleanup, contains('ChatDraftStore('));
      expect(normalCleanup, contains(').deleteForProfile('));
      expect(normalCleanup, contains('LocalTranscriptStore.deleteForProfile('));
      expect(normalCleanup, contains('TurnOutboxStore().deleteForProfile('));
      expect(normalCleanup, isNot(contains('deleteForConnection(')));
      // Vaciar SOLO Cron no puede arrastrarse el estado local del perfil
      // (borradores y transcripciones son por perfil, no por origen).
      expect(normalCleanup, contains('selection.clearsLocalProfileState'));
    },
  );

  group('ámbito de la limpieza', () {
    Session row(
      String id, {
      String source = 'mobile',
      String? parentSessionId,
    }) => Session(
      id: id,
      title: id,
      model: 'hermes-agent',
      source: source,
      messageCount: 1,
      isActive: false,
      preview: '',
      startedAt: 1,
      parentSessionId: parentSessionId,
    );

    test('solo chats deja fuera cron, kanban y subagentes', () {
      final order = historyCleanupDeleteOrder([
        row('chat-1'),
        row('cron_job_a_1', source: 'cron'),
        row('kanban-1', source: 'kanban'),
        row('subagent-1', source: 'subagent'),
      ], HistoryCleanupSelection.chatsOnly);
      expect(order, ['chat-1']);
    });

    test('solo automatizaciones deja fuera los chats normales', () {
      final order = historyCleanupDeleteOrder([
        row('chat-1'),
        row('cron_job_a_1', source: 'cron'),
        row('webhook-1', source: 'webhook'),
      ], const HistoryCleanupSelection(chats: false, automations: true));
      expect(order, unorderedEquals(['cron_job_a_1', 'webhook-1']));
      expect(order, isNot(contains('chat-1')));
    });

    test(
      'un informe programado se detecta por el id aunque cambie el origen',
      () {
        // Las compactaciones de Hermes conservan el id `cron_<job>_…` pero no
        // siempre el `source`.
        expect(isAutomationSessionRow(row('cron_job_a_1', source: '')), isTrue);
        expect(isAutomationSessionRow(row('chat-1')), isFalse);
      },
    );

    test('las continuaciones se borran antes que su raíz', () {
      final order = historyCleanupDeleteOrder([
        row('root'),
        row('child', parentSessionId: 'root'),
        row('grandchild', parentSessionId: 'child'),
      ], HistoryCleanupSelection.chatsOnly);
      // Hojas primero: borrar la raíz antes convertía a la hija en una
      // conversación principal nueva que reaparecía en la lista.
      expect(order.indexOf('grandchild'), lessThan(order.indexOf('child')));
      expect(order.indexOf('child'), lessThan(order.indexOf('root')));
      expect(order.length, 3);
    });

    test('una fila huérfana (padre ya inexistente) se borra igualmente', () {
      final order = historyCleanupDeleteOrder([
        row('orphan', parentSessionId: 'gone'),
      ], HistoryCleanupSelection.chatsOnly);
      expect(order, ['orphan']);
    });

    test('sin ámbito elegido no se borra nada', () {
      expect(
        historyCleanupDeleteOrder([
          row('chat-1'),
        ], const HistoryCleanupSelection(chats: false, automations: false)),
        isEmpty,
      );
    });

    test('un borrador local nunca se intenta borrar en el servidor', () {
      expect(
        historyCleanupDeleteOrder([
          row('draft-1', source: 'mobile-draft'),
        ], HistoryCleanupSelection.chatsOnly),
        isEmpty,
      );
    });

    test(
      'una fila rechazada u errónea no aborta el lote y se cuenta aparte',
      () async {
        final progress = <int>[];
        final summary = await clearRemoteConversations(
          deleteOrder: const ['a', 'b', 'c'],
          deleteSession: (id) async {
            if (id == 'b') return false; // servidor respondió OK sin borrar
            if (id == 'c') throw Exception('boom');
            return true;
          },
          onProgress: (done, total) {
            expect(total, 3);
            progress.add(done);
          },
        );
        expect(summary.deleted, 1);
        expect(summary.rejected, 1);
        expect(summary.failed, 1);
        expect(summary.allSucceeded, isFalse);
        expect(progress, [1, 2, 3]);
        // Un lote que llega al final nunca es "cancelado" ni deja filas sin
        // intentar: ese es el contraste del caso de cancelación.
        expect(summary.cancelled, isFalse);
        expect(summary.skipped, 0);
        expect(summary.total, 3);
      },
    );

    test(
      'cancelar deja de emitir DELETEs y cuenta solo lo ya borrado',
      () async {
        final issued = <String>[];
        var cancelled = false;
        final summary = await clearRemoteConversations(
          deleteOrder: const ['a', 'b', 'c', 'd'],
          deleteSession: (id) async {
            issued.add(id);
            // El usuario cancela mientras 'b' está en vuelo.
            if (id == 'b') cancelled = true;
            return true;
          },
          isCancelled: () => cancelled,
        );

        // El DELETE en vuelo termina (no se puede deshacer a medias), pero no se
        // empieza ninguno nuevo.
        expect(issued, ['a', 'b']);
        expect(summary.deleted, 2);
        expect(summary.skipped, 2);
        expect(summary.total, 4);
        expect(summary.cancelled, isTrue);
        expect(summary.allSucceeded, isFalse);
      },
    );

    test('cancelar antes del primer DELETE no borra nada', () async {
      final issued = <String>[];
      final summary = await clearRemoteConversations(
        deleteOrder: const ['a', 'b'],
        deleteSession: (id) async {
          issued.add(id);
          return true;
        },
        isCancelled: () => true,
      );
      expect(issued, isEmpty);
      expect(summary.deleted, 0);
      expect(summary.skipped, 2);
      expect(summary.cancelled, isTrue);
    });

    test('un ámbito sin filas se distingue de un lote ejecutado', () {
      // `total == 0` es lo que permite decir "no había nada que borrar" en vez
      // de salir en silencio.
      expect(RemoteConversationClearSummary.none.total, 0);
      expect(RemoteConversationClearSummary.none.cancelled, isFalse);
      expect(
        const RemoteConversationClearSummary(
          deleted: 1,
          rejected: 0,
          failed: 0,
        ).total,
        1,
      );
    });
  });

  testWidgets('el diálogo de ámbito no permite confirmar sin nada elegido', (
    tester,
  ) async {
    HistoryCleanupSelection? result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<HistoryCleanupSelection>(
                  context: context,
                  builder: (_) => const HistoryCleanupScopeDialog(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Por defecto: chats sí, automatizaciones no.
    await tester.tap(find.byKey(const ValueKey('history-cleanup-scope-chats')));
    await tester.pumpAndSettle();
    final confirm = tester.widget<TextButton>(
      find.byKey(const ValueKey('history-cleanup-scope-confirm')),
    );
    expect(confirm.onPressed, isNull);

    await tester.tap(
      find.byKey(const ValueKey('history-cleanup-scope-automations')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('history-cleanup-scope-confirm')),
    );
    await tester.pumpAndSettle();
    expect(result?.chats, isFalse);
    expect(result?.automations, isTrue);
  });

  testWidgets('elegir solo Cron conserva el borrador de un chat normal', (
    tester,
  ) async {
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
    final drafts = ChatDraftStore(prefs);
    await drafts.save(connection.id, 'chat-1', 'keep this draft', const []);

    final deleted = <String>[];
    final remote = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      connectionId: connection.id,
      httpClient: MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path.endsWith('/api/sessions')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'chat-1', 'source': 'mobile', 'title': 'chat'},
                {'id': 'cron_job_1', 'source': 'cron', 'title': 'informe'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'DELETE') {
          deleted.add(request.url.pathSegments.last);
          return http.Response(jsonEncode({'deleted': true}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(remote.close);

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
            remoteClientOverride: remote,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('history-cleanup-scope-chats')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('history-cleanup-scope-automations')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('history-cleanup-scope-confirm')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(deleted, ['cron_job_1']);
    expect(
      (await drafts.load(connection.id, 'chat-1')).text,
      'keep this draft',
    );
  });

  group('vaciado en curso: cancelar y no descuadrarse', () {
    const cancelKey = ValueKey('history-cleanup-cancel');
    const rowKey = ValueKey('history-cleanup-normal');
    const progressKey = ValueKey('history-cleanup-progress');

    testWidgets('la fila ofrece cancelar mientras el lote remoto avanza', (
      tester,
    ) async {
      var cancels = 0;
      await pumpActions(
        tester,
        readOnly: false,
        onNormal: () =>
            fail('la fila no debe reabrir el diálogo mientras vacía'),
        clearingNormal: true,
        remoteProgress: (done: 3, total: 10),
        onCancelNormal: () => cancels++,
      );

      expect(find.byKey(progressKey), findsOneWidget);
      expect(find.byKey(cancelKey), findsOneWidget);
      // Objetivo táctil real (regla de 44dp de la app), no solo el icono.
      final size = tester.getSize(find.byKey(cancelKey));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));

      await tester.tap(find.byKey(cancelKey));
      await tester.pump();
      expect(cancels, 1);
    });

    testWidgets('sin lote en curso no hay botón de cancelar', (tester) async {
      await pumpActions(tester, readOnly: false, onNormal: () {});
      expect(find.byKey(cancelKey), findsNothing);
      expect(find.byKey(progressKey), findsNothing);

      // Ya pedida la cancelación (onCancelNormal null) el botón desaparece,
      // pero la barra de avance sigue informando.
      await pumpActions(
        tester,
        readOnly: false,
        onNormal: () {},
        clearingNormal: true,
        remoteProgress: (done: 9, total: 10),
      );
      expect(find.byKey(progressKey), findsOneWidget);
      expect(find.byKey(cancelKey), findsNothing);
    });

    testWidgets('el icono no se recoloca respecto al título al empezar', (
      tester,
    ) async {
      await pumpActions(tester, readOnly: false, onNormal: () {});
      final s = Strings.of(
        tester.element(find.byType(HistoryCleanupActionList)),
      );
      final title = find.text(s.setClearConvos);
      double iconToTitle() =>
          tester.getCenter(find.byIcon(Icons.forum_outlined)).dy -
          tester.getCenter(title).dy;

      final restingOffset = iconToTitle();
      final restingTitleY = tester.getCenter(title).dy;
      final restingHeight = tester.getSize(find.byKey(rowKey)).height;

      await pumpActions(
        tester,
        readOnly: false,
        onNormal: () {},
        clearingNormal: true,
        remoteProgress: (done: 1, total: 10),
        onCancelNormal: () {},
      );
      // Primer fotograma: la caja NO salta de golpe, crece animada.
      await tester.pump();
      final midHeight = tester.getSize(find.byKey(rowKey)).height;
      await tester.pump(const Duration(milliseconds: 400));
      final busyHeight = tester.getSize(find.byKey(rowKey)).height;

      expect(busyHeight, greaterThan(restingHeight));
      expect(midHeight, lessThan(busyHeight));
      expect(find.byType(AnimatedSize), findsOneWidget);
      // El descuadre real que vio el mantenedor: al crecer la fila, el icono
      // de la izquierda se recentraba y dejaba de alinear con el título.
      expect(iconToTitle(), closeTo(restingOffset, 0.5));
      // Y el bloque de texto tampoco se mueve: la banda solo se añade debajo.
      expect(tester.getCenter(title).dy, closeTo(restingTitleY, 0.5));
    });
  });

  group('la limpieza ya no falla en silencio', () {
    SavedConnection connectionWith(String id) => SavedConnection(
      id: id,
      label: 'Instancia $id',
      host: '127.0.0.2',
      port: 8642,
      apiKey: 'key-$id',
      kind: InstanceKind.vps,
    );

    Future<String> snackBarText(WidgetTester tester) async {
      final snack = find.byType(HermesNoticeCard);
      expect(snack, findsOneWidget);
      return tester
          .widget<Text>(
            find.descendant(of: snack, matching: find.byType(Text)).first,
          )
          .data!;
    }

    testWidgets('un ámbito sin conversaciones lo dice en vez de callarse', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final connection = connectionWith('instance-a');
      var deletes = 0;
      final remote = ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: connection.apiKey,
        connectionId: connection.id,
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/sessions')) {
            // Un gateway que acaba de reiniciarse puede responder 200 con la
            // lista vacía: no lanza, así que el `catch` no se enteraba.
            return http.Response(jsonEncode({'data': <Object>[]}), 200);
          }
          if (request.method == 'DELETE') deletes++;
          return http.Response('{}', 404);
        }),
      );
      addTearDown(remote.close);

      await tester.pumpWidget(
        wrap(
          HistoryCleanupSection(
            connection: connection,
            connManager: manager,
            verifyHistoryCleanupForTesting: () async => true,
            remoteClientOverride: remote,
          ),
        ),
      );
      final s = Strings.of(tester.element(find.byType(HistoryCleanupSection)));

      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.byKey(const ValueKey('history-cleanup-scope-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(deletes, 0);
      expect(await snackBarText(tester), contains(s.slEmptyFilter));
    });

    testWidgets('cambiar de instancia mientras autoriza se avisa', (
      tester,
    ) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final verification = Completer<bool>();
      Widget sectionFor(SavedConnection connection) => wrap(
        HistoryCleanupSection(
          // Key ESTABLE a propósito: se quiere el caso en el que el mismo
          // State ve cambiar `widget.connection` bajo sus pies.
          key: const ValueKey('history-cleanup-fixed'),
          connection: connection,
          connManager: manager,
          verifyHistoryCleanupForTesting: () => verification.future,
        ),
      );

      await tester.pumpWidget(sectionFor(connectionWith('instance-a')));
      final s = Strings.of(tester.element(find.byType(HistoryCleanupSection)));
      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
      await tester.pump();

      await tester.pumpWidget(sectionFor(connectionWith('instance-b')));
      verification.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Antes: `return` mudo. No aparecía ni el diálogo ni ningún aviso.
      expect(find.byType(AlertDialog), findsNothing);
      expect(await snackBarText(tester), s.setClearError(s.slNoGateway));
    });

    testWidgets(
      'perder la instancia DESPUÉS de borrar informa de lo ya borrado',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(prefs);
        final connection = connectionWith('instance-a');
        final drafts = ChatDraftStore(prefs);
        // Borrador de una sesión que NO está en el lote: borrar `chat-1` en el
        // servidor limpia por sí mismo el borrador de `chat-1` (recuperación
        // por sesión), así que aquí se vigila el estado del perfil.
        await drafts.save(connection.id, 'chat-9', 'keep this draft', const []);

        final deleted = <String>[];
        final firstDelete = Completer<void>();
        final remote = ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          connectionId: connection.id,
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/api/sessions')) {
              return http.Response(
                jsonEncode({
                  'data': [
                    {'id': 'chat-1', 'source': 'mobile', 'title': 'chat'},
                  ],
                }),
                200,
              );
            }
            if (request.method == 'DELETE') {
              deleted.add(request.url.pathSegments.last);
              await firstDelete.future;
              return http.Response(jsonEncode({'deleted': true}), 200);
            }
            return http.Response('{}', 404);
          }),
        );
        addTearDown(remote.close);

        Widget sectionFor(SavedConnection conn) => wrap(
          HistoryCleanupSection(
            key: const ValueKey('history-cleanup-fixed'),
            connection: conn,
            connManager: manager,
            verifyHistoryCleanupForTesting: () async => true,
            remoteClientOverride: remote,
          ),
        );

        await tester.pumpWidget(sectionFor(connection));
        final s = Strings.of(
          tester.element(find.byType(HistoryCleanupSection)),
        );
        await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(
          find.byKey(const ValueKey('history-cleanup-scope-confirm')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(deleted, ['chat-1']);

        // La instancia activa cambia con el DELETE ya en vuelo.
        await tester.pumpWidget(sectionFor(connectionWith('instance-b')));
        firstDelete.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        // Antes se salía en silencio: el borrado SÍ había ocurrido y nadie lo
        // contaba (de ahí "no se eliminaron, no sé qué ocurre").
        final text = await snackBarText(tester);
        expect(text, contains(s.slNoGateway));
        expect(text, contains(s.setConvosCleared(1)));
        // Lo local pertenece al perfil de la instancia que ya no está en
        // pantalla: no se toca.
        expect(
          (await drafts.load(connection.id, 'chat-9')).text,
          'keep this draft',
        );
      },
    );

    testWidgets('cancelar a mitad para el lote y conserva lo local', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final connection = connectionWith('instance-a');
      final drafts = ChatDraftStore(prefs);
      await drafts.save(connection.id, 'chat-9', 'keep this draft', const []);

      final deleted = <String>[];
      final firstDelete = Completer<void>();
      final remote = ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: connection.apiKey,
        connectionId: connection.id,
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/sessions')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'chat-1', 'source': 'mobile', 'title': 'a'},
                  {'id': 'chat-2', 'source': 'mobile', 'title': 'b'},
                  {'id': 'chat-3', 'source': 'mobile', 'title': 'c'},
                ],
              }),
              200,
            );
          }
          if (request.method == 'DELETE') {
            deleted.add(request.url.pathSegments.last);
            if (deleted.length == 1) await firstDelete.future;
            return http.Response(jsonEncode({'deleted': true}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(remote.close);

      await tester.pumpWidget(
        wrap(
          HistoryCleanupSection(
            connection: connection,
            connManager: manager,
            verifyHistoryCleanupForTesting: () async => true,
            remoteClientOverride: remote,
          ),
        ),
      );
      final s = Strings.of(tester.element(find.byType(HistoryCleanupSection)));

      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.byKey(const ValueKey('history-cleanup-scope-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // El lote está en marcha y ofrece cancelar.
      expect(deleted, ['chat-1']);
      expect(
        find.byKey(const ValueKey('history-cleanup-cancel')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('history-cleanup-cancel')));
      await tester.pump();

      firstDelete.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // El DELETE en vuelo termina; los otros dos no se emiten.
      expect(deleted, ['chat-1']);
      // Cancelar para TODO lo que quedaba, también la limpieza local.
      expect(
        (await drafts.load(connection.id, 'chat-9')).text,
        'keep this draft',
      );
      final text = await snackBarText(tester);
      expect(text, contains(s.chaStatusCancelled));
      expect(text, contains(s.crnCleanupPartial(1, 2)));
    });
  });
}
