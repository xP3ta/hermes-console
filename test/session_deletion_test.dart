import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/session_deletion.dart';

Session cronSession(String id) =>
    Session.fromJson({'id': id, 'title': 'Scheduled report', 'source': 'cron'});

Session childSession(String id, String parentId) => Session.fromJson({
  'id': id,
  'title': null,
  'source': 'cron',
  'parent_session_id': parentId,
});

LocalConversationLifecycle localLifecycle({
  String connectionId = 'instance-a',
  String profile = 'profile-a',
  String sessionId = 'session-a',
}) => LocalConversationCleanupFence.beginLifecycle(
  connectionId: connectionId,
  profile: profile,
  sessionId: sessionId,
);

Future<void> expectRejected(Future<Object?> write) =>
    expectLater(write, throwsA(isA<LocalConversationWriteRejected>()));

void main() {
  test('las superficies que borran delegan en el coordinador compartido', () {
    // El Inicio de widgets no ofrece borrar chats; no debe tener un camino
    // de borrado propio que se salte el coordinador.
    for (final path in const [
      'lib/core/screens/home_dashboard_screen.dart',
      'lib/core/home/board/home_board_view.dart',
      'lib/core/home/board/home_board_tiles.dart',
      'lib/core/home/board/home_board_sheets.dart',
      'lib/core/home/home_now.dart',
      'lib/core/home/home_sources.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(matches(RegExp(r'\.deleteSession(WithLinkedCron)?\('))),
        reason: '$path no debe borrar sesiones por su cuenta',
      );
    }
    const paths = [
      'lib/core/screens/session_list_screen.dart',
      'lib/core/screens/session_detail_screen.dart',
      'lib/core/screens/chat_screen.dart',
    ];
    for (final path in paths) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        contains('deleteSessionWithResolvedLineage('),
        reason: path,
      );
      expect(
        source,
        isNot(contains('deleteSessionWithLinkedCron(')),
        reason: '$path no debe saltarse la resolución compartida',
      );
      expect(
        source,
        contains('sessionDeletionFailureMessage('),
        reason: '$path debe presentar fallos mediante el helper ARB común',
      );
      expect(
        source,
        isNot(contains(r'${result.error}')),
        reason: '$path no debe filtrar errores técnicos a la UI',
      );
      expect(
        source,
        isNot(contains('DeleteFailed(e.toString())')),
        reason: '$path no debe mostrar excepciones de transporte sin tipar',
      );
      expect(
        source,
        contains('cronDeletion:'),
        reason: '$path debe declarar si conserva o elimina la programación',
      );
      // The Dashboard deletes the whole chain from any id: nothing reads
      // the lineage first.
      expect(
        source,
        isNot(contains('loadSessions:')),
        reason: '$path no debe leer el linaje antes de borrar',
      );
      expect(source, isNot(contains('serverDeletesChain:')), reason: path);
    }

    final chat = File('lib/core/screens/chat_screen.dart').readAsStringSync();
    expect(chat, isNot(contains('deleteSession: client.deleteSession')));
    expect(chat, contains('final ownerProfile = _chat.sessionProfile;'));
    expect(
      chat,
      contains('client.deleteSession(sessionId, profile: ownerProfile)'),
    );
    expect(chat, contains('remoteSessionId: _chat.serverSessionId'));
    expect(chat, contains('localRecoverySessionId: widget.session.id'));
    expect(chat, contains('clearLocalRecovery: _clearDeletedChatRecovery'));

    // Home (Inicio v3) has no delete path any more; the loop at the top
    // pins that it never deletes on its own.

    final detail = File(
      'lib/core/screens/session_detail_screen.dart',
    ).readAsStringSync();
    expect(
      detail,
      contains('final ownerProfile = Session.profileOwner(_session.profile);'),
    );
    expect(detail, contains('profile: ownerProfile'));

    final list = File(
      'lib/core/screens/session_list_screen.dart',
    ).readAsStringSync();
    expect(
      list,
      contains('_client.deleteSession(sessionId, profile: ownerProfile)'),
    );

    final service = File(
      'lib/core/services/session_deletion.dart',
    ).readAsStringSync();
    expect(service, isNot(contains('No se pudo identificar el cron')));
    expect(service, isNot(contains('No hay acceso al gestor de cron')));
  });

  test('borrado individual distingue confirmación, rechazo y error', () async {
    final deleted = await deleteRemoteSession(
      'chat-ok',
      delete: (_) async => true,
    );
    final rejected = await deleteRemoteSession(
      'cron-active',
      delete: (_) async => false,
    );
    final failed = await deleteRemoteSession(
      'chat-error',
      delete: (_) async => throw StateError('offline'),
    );

    expect(deleted.status, RemoteSessionDeleteStatus.deleted);
    expect(rejected.status, RemoteSessionDeleteStatus.rejected);
    expect(failed.status, RemoteSessionDeleteStatus.failed);
    expect(failed.error, isA<StateError>());
  });

  test(
    'borrado remoto confirmado expulsa antes y aísla fallos de limpieza local',
    () async {
      final calls = <String>[];
      final errors = <Object>[];

      await finalizeConfirmedRemoteDeletion(
        evict: () => calls.add('evict'),
        localCleanups: [
          () async {
            calls.add('cleanup-fails');
            throw StateError('local archive unavailable');
          },
          () async => calls.add('cleanup-continues'),
        ],
        onCleanupError: errors.add,
      );

      expect(calls, ['evict', 'cleanup-fails', 'cleanup-continues']);
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
    },
  );

  test(
    'la autorización falla cerrada antes de App Lock en solo lectura',
    () async {
      var verifications = 0;

      final readOnly = await authorizeHistoryCleanup(
        readOnly: true,
        verifyAppLock: () async {
          verifications++;
          return true;
        },
      );
      final rejected = await authorizeHistoryCleanup(
        readOnly: false,
        verifyAppLock: () async {
          verifications++;
          return false;
        },
      );
      final accepted = await authorizeHistoryCleanup(
        readOnly: false,
        verifyAppLock: () async {
          verifications++;
          return true;
        },
      );

      expect(readOnly, isFalse);
      expect(rejected, isFalse);
      expect(accepted, isTrue);
      expect(verifications, 2);
    },
  );

  test('la invalidación publica conexión y alcance exactos', () async {
    final bus = HistoryCleanupInvalidationBus();
    addTearDown(bus.close);
    final events = <HistoryCleanupInvalidation>[];
    final subscription = bus.events.listen(events.add);
    addTearDown(subscription.cancel);

    bus.publish(
      connectionId: 'qa',
      scope: HistoryCleanupScope.normalConversations,
    );
    bus.publish(
      connectionId: 'qa',
      scope: HistoryCleanupScope.normalConversations,
    );

    expect(events.map((event) => event.connectionId), ['qa', 'qa']);
    expect(events.map((event) => event.scope), [
      HistoryCleanupScope.normalConversations,
      HistoryCleanupScope.normalConversations,
    ]);
  });

  test(
    'REGRESSION_CLEANUP_BARRIER continúa stores tras error parcial',
    () async {
      final calls = <String>[];
      final result = await clearProfileLocalConversationState(
        connectionId: 'instance-a',
        profile: 'team_alpha',
        clearDrafts: ({required String profile}) async {
          calls.add('draft:$profile');
          return 2;
        },
        clearTranscripts: ({required String profile}) async {
          calls.add('transcript:$profile');
          throw StateError('sensitive keystore detail');
        },
        clearOutbox: ({required String profile}) async {
          calls.add('outbox:$profile');
          return 1;
        },
      );

      expect(calls, [
        'draft:team_alpha',
        'transcript:team_alpha',
        'outbox:team_alpha',
      ]);
      expect(result.drafts.removed, 2);
      expect(result.transcripts.succeeded, isFalse);
      expect(result.outbox.removed, 1);
      expect(result.localFailureCount, 1);
      expect(result.allSucceeded, isFalse);
    },
  );

  test('borra primero el cron vinculado y después su conversación', () async {
    final calls = <String>[];
    final result = await deleteSessionWithLinkedCron(
      cronSession('cron_job_with_underscores_20260715_214800'),
      cronDeletion: LinkedCronDeletionMode.deleteSchedule,
      deleteCronJob: (id) async => calls.add('cron:$id'),
      deleteSession: (id) async {
        calls.add('session:$id');
        return true;
      },
    );

    expect(result.status, LinkedSessionDeleteStatus.deleted);
    expect(result.cronDeleted, isTrue);
    expect(calls, [
      'cron:job_with_underscores',
      'session:cron_job_with_underscores_20260715_214800',
    ]);
  });

  test(
    'el contexto apunta a la fila elegida: el Dashboard borra la cadena',
    () async {
      final root = cronSession('cron_job123_20260715_214800');
      final leaf = childSession('compact-2', 'compact-1');

      final context = await resolveSessionDeletionContext(leaf);
      expect(context.target, same(leaf));
      expect(context.remoteSessionId, leaf.id);
      expect(context.localRecoverySessionId, leaf.id);

      // A cron run is deleted by its own id, never by a client-side id.
      final rootContext = await resolveSessionDeletionContext(
        root,
        remoteSessionId: 'desktop-runtime',
      );
      expect(rootContext.target, same(root));
      expect(rootContext.remoteSessionId, root.id);
    },
  );

  test(
    'cron sin vínculo o gestor devuelve códigos estables sin copy',
    () async {
      final missingLink = await deleteSessionWithLinkedCron(
        cronSession('legacy-cron-session'),
        cronDeletion: LinkedCronDeletionMode.deleteSchedule,
        deleteSession: (_) async => true,
      );
      final missingManager = await deleteSessionWithLinkedCron(
        cronSession('cron_job123_20260715_214800'),
        cronDeletion: LinkedCronDeletionMode.deleteSchedule,
        deleteSession: (_) async => true,
      );

      expect(
        missingLink.failure?.code,
        SessionDeletionFailureCode.missingCronJobId,
      );
      expect(
        missingManager.failure?.code,
        SessionDeletionFailureCode.cronManagerUnavailable,
      );
      expect(missingLink.failure?.cause, isNull);
      expect(missingManager.failure?.cause, isNull);
    },
  );

  test('si no puede detener el cron conserva la conversación', () async {
    var sessionDeleteCalled = false;
    final result = await deleteSessionWithLinkedCron(
      cronSession('cron_job123_20260715_214800'),
      cronDeletion: LinkedCronDeletionMode.deleteSchedule,
      deleteCronJob: (_) async => throw StateError('dashboard offline'),
      deleteSession: (_) async {
        sessionDeleteCalled = true;
        return true;
      },
    );

    expect(result.status, LinkedSessionDeleteStatus.cronDeleteFailed);
    expect(result.cronDeleted, isFalse);
    expect(sessionDeleteCalled, isFalse);
  });

  test(
    'borrar solo el chat conserva el cron incluso si conoce su id',
    () async {
      final scheduled = cronSession('cron_job123_20260715_214800');
      final calls = <String>[];

      final result = await deleteSessionWithResolvedLineage(
        scheduled,
        deleteCronJob: (id) async => calls.add('cron:$id'),
        deleteSession: (id) async {
          calls.add('session:$id');
          return true;
        },
      );

      expect(result.status, LinkedSessionDeleteStatus.deleted);
      expect(result.cronDeleted, isFalse);
      expect(calls, ['session:${scheduled.id}']);
    },
  );

  test('borrar solo el chat funciona también con un cron legacy', () async {
    final legacy = cronSession('legacy-cron-session');
    final calls = <String>[];

    final result = await deleteSessionWithResolvedLineage(
      legacy,
      deleteCronJob: (id) async => calls.add('cron:$id'),
      deleteSession: (id) async {
        calls.add('session:$id');
        return true;
      },
    );

    expect(result.status, LinkedSessionDeleteStatus.deleted);
    expect(result.cronDeleted, isFalse);
    expect(calls, ['session:legacy-cron-session']);
  });

  test(
    'separa el id remoto de la clave local y limpia solo tras éxito',
    () async {
      final local = Session.fromJson({
        'id': 'mob-local',
        'title': 'Nuevo chat',
        'source': 'mobile',
      });
      final remoteDeletes = <String>[];
      final localCleanups = <String>[];

      final result = await deleteSessionWithResolvedLineage(
        local,
        remoteSessionId: 'desktop-remote',
        deleteSession: (id) async {
          remoteDeletes.add(id);
          return true;
        },
        clearLocalRecovery: (id) async => localCleanups.add(id),
      );

      expect(result.status, LinkedSessionDeleteStatus.deleted);
      expect(remoteDeletes, ['desktop-remote']);
      expect(localCleanups, ['mob-local']);
    },
  );

  test('rechazo o fallo remoto no limpia la recuperación local', () async {
    final local = Session.fromJson({
      'id': 'mob-local',
      'title': 'Nuevo chat',
      'source': 'mobile',
    });
    final localCleanups = <String>[];

    final rejected = await deleteSessionWithResolvedLineage(
      local,
      remoteSessionId: 'desktop-rejected',
      deleteSession: (_) async => false,
      clearLocalRecovery: (id) async => localCleanups.add(id),
    );
    final failed = await deleteSessionWithResolvedLineage(
      local,
      remoteSessionId: 'desktop-failed',
      deleteSession: (_) async => throw StateError('offline'),
      clearLocalRecovery: (id) async => localCleanups.add(id),
    );

    expect(rejected.status, LinkedSessionDeleteStatus.sessionRejected);
    expect(failed.status, LinkedSessionDeleteStatus.sessionDeleteFailed);
    expect(localCleanups, isEmpty);
  });

  test('informa si el cron se borró pero el servidor retuvo el chat', () async {
    final result = await deleteSessionWithLinkedCron(
      cronSession('cron_job123_20260715_214800'),
      cronDeletion: LinkedCronDeletionMode.deleteSchedule,
      deleteCronJob: (_) async {},
      deleteSession: (_) async => false,
    );

    expect(result.status, LinkedSessionDeleteStatus.sessionRejected);
    expect(result.cronDeleted, isTrue);
  });

  test('no borra una sesión cron mientras el agente aún escribe', () async {
    final calls = <String>[];
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final active = Session.fromJson({
      'id': 'cron_job123_20260716_120000',
      'title': 'Running report',
      'source': 'cron',
      'started_at': now,
      'ended_at': null,
    });

    final result = await deleteSessionWithLinkedCron(
      active,
      cronDeletion: LinkedCronDeletionMode.deleteSchedule,
      deleteCronJob: (id) async => calls.add('cron:$id'),
      deleteSession: (id) async {
        calls.add('session:$id');
        return true;
      },
    );

    expect(result.status, LinkedSessionDeleteStatus.sessionRejected);
    expect(result.cronDeleted, isTrue);
    expect(calls, ['cron:job123']);
  });

  test(
    'rehydrate falla cerrado mientras el cleanup del perfil sigue activo',
    () async {
      LocalConversationCleanupFence.resetForTesting();
      final cleanupEntered = Completer<void>();
      final releaseCleanup = Completer<void>();
      final cleanup = LocalConversationCleanupFence.cleanupProfile(
        connectionId: 'instance-a',
        profile: 'profile-a',
        operation: () async {
          cleanupEntered.complete();
          await releaseCleanup.future;
        },
      );
      await cleanupEntered.future;
      final lifecycle = localLifecycle();
      expect(LocalConversationCleanupFence.rehydrate(lifecycle), isFalse);
      releaseCleanup.complete();
      await cleanup;
    },
  );

  test(
    'un owner nuevo rehidratado invalida autosaves del owner anterior',
    () async {
      LocalConversationCleanupFence.resetForTesting();
      await LocalConversationCleanupFence.cleanupProfile(
        connectionId: 'instance-a',
        profile: 'profile-a',
        operation: () async => 0,
      );
      final stale = localLifecycle();
      expect(LocalConversationCleanupFence.rehydrate(stale), isTrue);
      final current = localLifecycle();
      expect(LocalConversationCleanupFence.rehydrate(current), isTrue);
      await expectRejected(
        LocalConversationCleanupFence.write(
          lifecycle: stale,
          operation: () async => null,
        ),
      );
    },
  );

  test('lifecycle cerrado no puede rehidratar ni admitir autosave', () async {
    LocalConversationCleanupFence.resetForTesting();
    final lifecycle = localLifecycle();
    LocalConversationCleanupFence.endLifecycle(lifecycle);

    expect(LocalConversationCleanupFence.rehydrate(lifecycle), isFalse);
    await expectRejected(
      LocalConversationCleanupFence.write(
        lifecycle: lifecycle,
        operation: () async => null,
      ),
    );
  });

  test('scope V3 conserva perfiles canónicos con espacios distintos', () {
    LocalConversationCleanupFence.resetForTesting();
    final owners = [localLifecycle(), localLifecycle(profile: ' profile-a ')];
    expect(
      owners.map(LocalConversationCleanupFence.rehydrate),
      everyElement(isTrue),
    );
  });

  for (final connectionCleanup in [false, true]) {
    test('cleanups solapados ${connectionCleanup ? 'connection' : 'profile'} '
        'mantienen cerrado rehydrate hasta el último', () async {
      LocalConversationCleanupFence.resetForTesting();
      final enteredFirst = Completer<void>();
      final releaseFirst = Completer<void>();
      final enteredSecond = Completer<void>();
      final releaseSecond = Completer<void>();
      Future<void> cleanup(Future<void> Function() operation) =>
          connectionCleanup
          ? LocalConversationCleanupFence.cleanupConnection(
              connectionId: 'instance-a',
              operation: operation,
            )
          : LocalConversationCleanupFence.cleanupProfile(
              connectionId: 'instance-a',
              profile: 'profile-a',
              operation: operation,
            );
      final first = cleanup(() async {
        enteredFirst.complete();
        await releaseFirst.future;
      });
      await enteredFirst.future;
      final second = cleanup(() async {
        enteredSecond.complete();
        await releaseSecond.future;
      });
      releaseFirst.complete();
      await first;
      await enteredSecond.future;
      final lifecycle = localLifecycle();
      expect(
        LocalConversationCleanupFence.rehydrate(lifecycle),
        isFalse,
        reason: 'connectionCleanup=$connectionCleanup',
      );
      await expectRejected(
        LocalConversationCleanupFence.write(
          lifecycle: lifecycle,
          operation: () async => null,
        ),
      );
      releaseSecond.complete();
      await second;
    });
  }

  test(
    'aliases de sesión son explícitos y no autorizan ids arbitrarios',
    () async {
      LocalConversationCleanupFence.resetForTesting();
      final lifecycle = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'instance-a',
        profile: 'profile-a',
        sessionId: 'route-session',
        sessionAliases: const ['mob-room-room-a'],
      );
      expect(
        await LocalConversationCleanupFence.write(
          connectionId: 'instance-a',
          profile: 'profile-a',
          sessionId: 'mob-room-room-a',
          lifecycle: lifecycle,
          operation: () async => 1,
        ),
        1,
      );
      await expectRejected(
        LocalConversationCleanupFence.write(
          connectionId: 'instance-a',
          profile: 'profile-a',
          sessionId: 'arbitrary-session',
          lifecycle: lifecycle,
          operation: () async => 2,
        ),
      );
    },
  );

  test('ActiveChat captura y transporta lifecycle antes del primer await', () {
    final source = File(
      'lib/core/services/active_chat_service.dart',
    ).readAsStringSync();
    final capture = source.indexOf(
      'final transcriptLifecycle = actionLifecycle ?? _localConversationLifecycle;',
    );
    final firstTransfer = source.indexOf(
      'capturedLifecycle: transcriptLifecycle,',
      capture,
    );
    expect(capture, greaterThanOrEqualTo(0));
    expect(firstTransfer, greaterThan(capture));
    expect(source, contains('lifecycle: capturedLifecycle,'));
  });

  test('dispose revoca un write admitido pero todavía en cola', () async {
    LocalConversationCleanupFence.resetForTesting();
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'other',
      operation: () => release.future,
    );
    final lifecycle = localLifecycle();
    var executed = false;
    final queued = LocalConversationCleanupFence.write(
      lifecycle: lifecycle,
      operation: () async => executed = true,
    );
    LocalConversationCleanupFence.endLifecycle(lifecycle);
    release.complete();
    await blocker;
    await expectRejected(queued);
    expect(executed, isFalse);
  });

  test(
    'cleanup connection permite hijo profile cubierto sin deadlock',
    () async {
      final result = await LocalConversationCleanupFence.cleanupConnection(
        connectionId: 'instance-a',
        operation: () => LocalConversationCleanupFence.cleanupProfile(
          connectionId: 'instance-a',
          profile: 'profile-a',
          operation: () async => 7,
        ),
      ).timeout(const Duration(milliseconds: 300));
      expect(result, 7);
    },
  );

  test('cleanup anidado no cubierto se rechaza sin bloquear la cola', () async {
    await expectLater(
      LocalConversationCleanupFence.cleanupProfile(
        connectionId: 'instance-a',
        profile: 'profile-a',
        operation: () => LocalConversationCleanupFence.cleanupProfile(
          connectionId: 'instance-a',
          profile: 'profile-b',
          operation: () async => 0,
        ),
      ).timeout(const Duration(milliseconds: 300)),
      throwsA(isA<StateError>()),
    );
    expect(
      await LocalConversationCleanupFence.cleanupProfile(
        connectionId: 'other',
        profile: 'profile',
        operation: () async => 1,
      ).timeout(const Duration(milliseconds: 300)),
      1,
    );
  });

  test('identidades tuple son inyectivas para ids opacos', () {
    LocalConversationCleanupFence.resetForTesting();
    final first = localLifecycle(
      connectionId: 'c',
      profile: 'x\u001fp',
      sessionId: 's',
    );
    final second = localLifecycle(
      connectionId: 'c\u001fx',
      profile: 'p',
      sessionId: 's',
    );
    expect(LocalConversationCleanupFence.rehydrate(first), isTrue);
    expect(LocalConversationCleanupFence.rehydrate(second), isTrue);
  });

  test(
    'profile cleanup purges global public activity after local stores',
    () async {
      final calls = <String>[];
      await clearProfileLocalConversationState(
        connectionId: 'instance-a',
        profile: 'team_alpha',
        clearDrafts: ({required profile}) async {
          calls.add('draft');
          return 0;
        },
        clearTranscripts: ({required profile}) async {
          calls.add('transcript');
          return 0;
        },
        clearOutbox: ({required profile}) async {
          calls.add('outbox');
          return 0;
        },
        clearGlobalActivity: ({required connectionId, required profile}) async {
          calls.add('activity:$connectionId:$profile');
        },
      );
      expect(calls, [
        'draft',
        'transcript',
        'outbox',
        'activity:instance-a:team_alpha',
      ]);
    },
  );

  test('cleanup local normaliza el perfil vacío al owner default', () async {
    final owners = <String>[];
    final summary = await clearProfileLocalConversationState(
      connectionId: 'instance-a',
      profile: '',
      clearDrafts: ({required String profile}) async {
        owners.add(profile);
        return 0;
      },
      clearTranscripts: ({required String profile}) async {
        owners.add(profile);
        return 0;
      },
      clearOutbox: ({required String profile}) async {
        owners.add(profile);
        return 0;
      },
    );

    expect(owners, List.filled(3, 'default'));
    expect(summary.allSucceeded, isTrue);
  });
}
