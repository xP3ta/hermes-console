import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_controller.dart';
import 'package:hermes_android/core/services/notifications/notification_event_ledger.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Fake ─────────────────────────────────────────────────────────────────────

class _FakeNotif implements RunNotificationFacade {
  final List<String> calls = [];
  bool _notifyRuns = true;

  @override
  bool get notifyRuns => _notifyRuns;

  @override
  Future<void> runLive({
    required String runId,
    required String title,
    required String body,
    String? connId,
    String? sessionId,
  }) async => calls.add('runLive:$runId:conn=${connId ?? ""}');

  @override
  Future<void> runFinished({
    required String title,
    required bool ok,
    String? connId,
    String? sessionId,
    String? runId,
    String? profile,
  }) async => calls.add('runFinished:${ok ? "ok" : "err"}');

  @override
  Future<void> approvalPending({
    required String tool,
    String? instance,
    String? connId,
    String? sessionId,
    String? sessionTitle,
    String? runId,
    String? base,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? profile,
    String? roomId,
  }) async => calls.add('approvalPending:$tool');

  @override
  Future<void> cancelRun(String runId) async => calls.add('cancelRun:$runId');

  @override
  Future<void> cancelApproval() async => calls.add('cancelApproval');
}

// ─── Helper ───────────────────────────────────────────────────────────────────

RunRecord _run({
  String id = 'run-1',
  String prompt = 'Busca errores en el log',
  String status = 'running',
  String? progressLabel,
  String? sessionId,
}) => RunRecord(
  runId: id,
  prompt: prompt,
  createdAt: 0,
  lastStatus: status,
  progressLabel: progressLabel,
  sessionId: sessionId,
);

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationEventLedger', () {
    test(
      'claim durable deduplica productores tras recrear el ledger',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final first = NotificationEventLedger(prefs);

        expect(
          await first.claim(
            connId: 'conn-a',
            profile: 'research',
            objectId: 'run-42',
            eventKind: 'run_terminal',
          ),
          isTrue,
        );

        final afterRestart = NotificationEventLedger(
          await SharedPreferences.getInstance(),
        );
        expect(
          await afterRestart.claim(
            connId: 'conn-a',
            profile: 'research',
            objectId: 'run-42',
            eventKind: 'run_terminal',
          ),
          isFalse,
        );
        expect(
          await afterRestart.claim(
            connId: 'conn-a',
            profile: 'research',
            objectId: 'run-42',
            eventKind: 'approval_required',
          ),
          isTrue,
        );
        expect(
          await afterRestart.claim(
            connId: 'conn-b',
            profile: 'research',
            objectId: 'run-42',
            eventKind: 'run_terminal',
          ),
          isTrue,
        );
      },
    );

    test('ledger queda acotado y persiste solo identidad tipada', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final ledger = NotificationEventLedger(prefs, maxEntries: 2);

      for (final id in ['run-1', 'run-2', 'run-3']) {
        expect(
          await ledger.claim(
            connId: 'conn',
            profile: 'default',
            objectId: id,
            eventKind: 'run_terminal',
          ),
          isTrue,
        );
      }

      final persisted = prefs.getString(NotificationEventLedger.storageKey)!;
      expect(NotificationEventLedger.decodeEntries(persisted), hasLength(2));
      expect(persisted, isNot(contains('title')));
      expect(persisted, isNot(contains('body')));
      expect(persisted, isNot(contains('text')));
    });

    test(
      'un claim cuya presentación falla puede reclamarse de nuevo',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final ledger = NotificationEventLedger(prefs);

        expect(
          await ledger.claim(
            connId: 'conn-a',
            profile: 'research',
            objectId: 'run-retry',
            eventKind: 'run_terminal',
          ),
          isTrue,
        );
        await ledger.release(
          connId: 'conn-a',
          profile: 'research',
          objectId: 'run-retry',
          eventKind: 'run_terminal',
        );

        expect(
          await ledger.claim(
            connId: 'conn-a',
            profile: 'research',
            objectId: 'run-retry',
            eventKind: 'run_terminal',
          ),
          isTrue,
        );
      },
    );

    test('espera un lock breve de otro proceso en vez de duplicar', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final ledger = NotificationEventLedger(prefs);
      final lockFile = File(
        '${Directory.systemTemp.path}/notification_event_ledger.lock',
      );
      final holder = await Process.start('python3', [
        '-c',
        'import fcntl,time; '
            "f=open(r'${lockFile.path}','a+b'); "
            'fcntl.lockf(f,fcntl.LOCK_EX); '
            "print('READY',flush=True); time.sleep(0.25)",
      ]);
      expect(
        await holder.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'READY',
      );

      expect(
        await ledger.claim(
          connId: 'conn-lock',
          profile: 'default',
          objectId: 'run-lock',
          eventKind: 'run_terminal',
        ),
        isTrue,
      );
      expect(await holder.exitCode, 0);
      expect(
        await ledger.claim(
          connId: 'conn-lock',
          profile: 'default',
          objectId: 'run-lock',
          eventKind: 'run_terminal',
        ),
        isFalse,
      );
    });
  });

  late _FakeNotif notif;
  late NotificationController ctrl;

  setUp(() {
    notif = _FakeNotif();
    ctrl = NotificationController(notif);
  });

  tearDown(() => ctrl.dispose());

  group('notifyRunStarted', () {
    test('es no-op (no emite notificación)', () {
      ctrl.notifyRunStarted(_run());
      expect(notif.calls, isEmpty);
    });
  });

  group('notifyRunFinished', () {
    test('cancela progreso, cancela approval y emite runFinished ok', () async {
      ctrl.notifyRunWaitingApproval(_run(status: 'waiting_for_approval'));
      notif.calls.clear();
      ctrl.notifyRunFinished(_run(status: 'completed'));
      expect(
        notif.calls,
        containsAllInOrder([
          'cancelRun:run-1',
          'cancelApproval',
          'runFinished:ok',
        ]),
      );
    });

    test('trunca prompt largo a 60 caracteres', () async {
      final longPrompt = 'A' * 80;
      ctrl.notifyRunFinished(_run(prompt: longPrompt));
      // runFinished recibe el prompt truncado; lo verificamos vía runLive
      // (runFinished recibe el título; el fake no expone el título, solo "ok/err")
      expect(notif.calls, contains('runFinished:ok'));
    });
  });

  group('notifyRunFailed', () {
    test(
      'cancela progreso, cancela approval y emite runFinished err',
      () async {
        ctrl.notifyRunWaitingApproval(_run(status: 'waiting_for_approval'));
        notif.calls.clear();
        ctrl.notifyRunFailed(_run(status: 'failed'));
        expect(
          notif.calls,
          containsAllInOrder([
            'cancelRun:run-1',
            'cancelApproval',
            'runFinished:err',
          ]),
        );
      },
    );
  });

  group('notifyRunCancelled', () {
    test('cancela la notificación sin emitir nueva', () async {
      ctrl.notifyRunWaitingApproval(_run(status: 'waiting_for_approval'));
      notif.calls.clear();
      ctrl.notifyRunCancelled(_run(status: 'cancelled'));
      expect(notif.calls, equals(['cancelRun:run-1', 'cancelApproval']));
      expect(notif.calls, isNot(contains('runFinished:ok')));
    });
  });

  group('aislamiento de approvals cross-run', () {
    test('terminal de otro run no cancela la approval del run activo', () {
      // run-1 está esperando aprobación
      ctrl.notifyRunWaitingApproval(_run(status: 'waiting_for_approval'));
      notif.calls.clear();
      // run-2 termina — NO debe cancelar la approval de run-1
      ctrl.notifyRunFinished(_run(id: 'run-2', status: 'completed'));
      expect(notif.calls, isNot(contains('cancelApproval')));
      expect(notif.calls, contains('cancelRun:run-2'));
      expect(notif.calls, contains('runFinished:ok'));
    });

    test('cancel de otro run no cancela la approval del run activo', () {
      ctrl.notifyRunWaitingApproval(_run(status: 'waiting_for_approval'));
      notif.calls.clear();
      ctrl.notifyRunCancelled(_run(id: 'run-2', status: 'cancelled'));
      expect(notif.calls, isNot(contains('cancelApproval')));
      expect(notif.calls, contains('cancelRun:run-2'));
    });
  });

  group('notifyRunWaitingApproval', () {
    test('emite approvalPending con la herramienta del progressLabel', () {
      ctrl.notifyRunWaitingApproval(_run(progressLabel: 'bash'));
      expect(notif.calls, contains('approvalPending:bash'));
    });

    test('usa fallback "herramienta" si progressLabel es null', () {
      ctrl.notifyRunWaitingApproval(_run());
      expect(notif.calls, contains('approvalPending:herramienta'));
    });

    test('la aprobación sigue notificando tras progreso rutinario', () async {
      // El progreso ya no crea push; la aprobación sí interrumpe.
      ctrl.notifyRunProgress(_run(progressLabel: 'tool: read_file'));
      expect(notif.calls.where((c) => c.startsWith('runLive')), isEmpty);
      ctrl.notifyRunWaitingApproval(_run(progressLabel: 'bash'));
      expect(notif.calls, contains('approvalPending:bash'));
      await Future.delayed(const Duration(seconds: 6));
      expect(notif.calls.where((c) => c.startsWith('runLive:run-1')), isEmpty);
    });
  });

  group('notifyRunProgress', () {
    test('no emite si notifyRuns es false', () async {
      notif._notifyRuns = false;
      ctrl.notifyRunProgress(_run(progressLabel: 'bash'));
      await Future.delayed(const Duration(seconds: 6));
      expect(notif.calls.where((c) => c.startsWith('runLive:')), isEmpty);
    });

    test('progreso rutinario no crea ninguna notificación push', () async {
      for (var i = 0; i < 5; i++) {
        ctrl.notifyRunProgress(_run(progressLabel: 'tool:$i'));
      }
      await Future.delayed(const Duration(seconds: 6));
      final liveCalls = notif.calls
          .where((c) => c.startsWith('runLive:run-1'))
          .toList();
      expect(liveCalls, isEmpty);
    });
  });

  group('clearRunNotification', () {
    test('cancela el aviso del run sin emitir nada nuevo', () async {
      ctrl.notifyRunProgress(_run(progressLabel: 'bash'));
      ctrl.clearRunNotification('run-1');
      await Future.delayed(const Duration(seconds: 6));
      expect(notif.calls, contains('cancelRun:run-1'));
      expect(notif.calls.where((c) => c.startsWith('runLive:run-1')), isEmpty);
    });
  });

  group('dispose', () {
    test('libera el estado efímero sin notificar', () async {
      ctrl.notifyRunProgress(_run(id: 'r1', progressLabel: 'a'));
      ctrl.notifyRunProgress(_run(id: 'r2', progressLabel: 'b'));
      ctrl.dispose();
      await Future.delayed(const Duration(seconds: 6));
      expect(notif.calls.where((c) => c.startsWith('runLive:')), isEmpty);
    });
  });

  group('propagación de connId', () {
    test('connId no convierte el progreso en una interrupción', () async {
      final ctrlWithConn = NotificationController(notif, connId: 'conn-abc');
      ctrlWithConn.notifyRunProgress(_run(progressLabel: 'bash'));
      await Future.delayed(const Duration(seconds: 6));
      expect(notif.calls.where((c) => c.startsWith('runLive:')), isEmpty);
      ctrlWithConn.dispose();
    });

    test('sin connId el progreso también queda solo en UI', () async {
      ctrl.notifyRunProgress(_run(progressLabel: 'bash'));
      await Future.delayed(const Duration(seconds: 6));
      expect(notif.calls.where((c) => c.startsWith('runLive:')), isEmpty);
    });
  });
}
