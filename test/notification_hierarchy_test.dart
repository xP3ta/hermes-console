import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Jerarquía de producto (A: acción requerida, B: resultado, C: respuesta,
/// D: servicio activo) verificada sobre el canal de plataforma real:
/// canal, importancia, prioridad, privacidad de lockscreen y agrupación.
///
/// El harness mantiene una bandeja fiel a Android: `show` inserta/reemplaza,
/// `cancel` retira y `getActiveNotifications` devuelve lo que sigue vivo, así
/// el resumen de grupo se evalúa contra el estado real entre instancias.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<int, Map<String, dynamic>> tray;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = <MethodCall>[];
    tray = <int, Map<String, dynamic>>{};
    SharedPreferences.setMockInitialValues({
      'app_locale': 'es',
      'notif_perm_requested': true,
      'notif_background_listen': true,
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'show':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          tray[args['id'] as int] = args;
          return null;
        case 'cancel':
          final raw = call.arguments;
          tray.remove(raw is Map ? raw['id'] : raw);
          return null;
        case 'cancelAll':
          tray.clear();
          return null;
        case 'getActiveNotifications':
          return tray.values.map((args) {
            final android = Map<String, dynamic>.from(
              args['platformSpecifics'] as Map,
            );
            return <String, dynamic>{
              'id': args['id'],
              'channelId': android['channelId'],
              'groupKey': android['groupKey'],
              'tag': null,
              'title': args['title'],
              'body': args['body'],
              'payload': args['payload'],
              'bigText': null,
            };
          }).toList();
        case 'initialize':
        case 'areNotificationsEnabled':
          return true;
        case 'getNotificationAppLaunchDetails':
          return <String, dynamic>{
            'notificationLaunchedApp': false,
            'notificationResponse': null,
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  List<Map<String, dynamic>> shownArgs({bool? groupSummary}) => calls
      .where((call) => call.method == 'show')
      .map((call) => Map<String, dynamic>.from(call.arguments as Map))
      .where((args) {
        final android = Map<String, dynamic>.from(
          args['platformSpecifics'] as Map,
        );
        final isSummary = android['setAsGroupSummary'] == true;
        return groupSummary == null || isSummary == groupSummary;
      })
      .toList();

  Map<String, dynamic> androidOf(Map<String, dynamic> args) =>
      Map<String, dynamic>.from(args['platformSpecifics'] as Map);

  List<String> actionIdsOf(Map<String, dynamic> args) =>
      ((androidOf(args)['actions'] as List?) ?? const [])
          .map((a) => Map<String, dynamic>.from(a as Map)['id'] as String)
          .toList();

  test(
    'A: aprobación usa canal de máxima prioridad y título de permiso',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs)..appInForeground = false;

      await service.approvalPending(
        tool: 'bash',
        connId: 'demo-node',
        runId: 'run-approval-1',
        base: 'https://hermes.example',
      );

      final shown = shownArgs(groupSummary: false);
      expect(shown, hasLength(1));
      final android = androidOf(shown.single);
      expect(shown.single['title'], 'Hermes necesita tu permiso');
      expect(android['channelId'], 'hermes_approvals');
      expect(android['importance'], Importance.max.value);
      expect(android['priority'], Priority.max.value);
    },
  );

  test(
    'B/C: resultado y respuesta usan canales y prioridades separadas',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs)..appInForeground = false;

      await service.runFinished(
        title: 'Copia de seguridad',
        ok: true,
        connId: 'demo-node',
        runId: 'run-result-1',
      );
      await service.replyReady(
        preview: 'preview',
        instance: 'Servidor',
        session: 'Chat',
        connId: 'demo-node',
        sessionId: 'session-1',
      );

      final shown = shownArgs(groupSummary: false);
      expect(shown, hasLength(2));
      final run = androidOf(shown.first);
      final reply = androidOf(shown.last);
      expect(run['channelId'], 'hermes_runs');
      expect(run['importance'], Importance.defaultImportance.value);
      expect(run['priority'], Priority.defaultPriority.value);
      expect(reply['channelId'], 'hermes_replies');
      expect(reply['importance'], Importance.high.value);
      expect(reply['priority'], Priority.high.value);
    },
  );

  test(
    'A: la aprobación nunca resuelve desde la bandeja, solo Abrir',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs)..appInForeground = false;

      // Sin redacción: tampoco hay Aprobar/Rechazar; la decisión exige abrir.
      await service.approvalPending(
        tool: 'bash',
        connId: 'demo-node',
        runId: 'run-unlocked-1',
        base: 'https://hermes.example',
      );

      var shown = shownArgs(groupSummary: false);
      expect(shown, hasLength(1));
      expect(actionIdsOf(shown.single), ['open']);

      // Con contenido oculto (lockscreen): mismo contrato, contenido privado.
      await service.setHideSensitiveContent(true);
      await service.approvalPending(
        tool: 'bash',
        connId: 'demo-node',
        runId: 'run-locked-1',
        base: 'https://hermes.example',
      );

      shown = shownArgs(groupSummary: false);
      expect(shown, hasLength(2));
      final locked = shown.last;
      final android = androidOf(locked);
      expect(locked['title'], 'Nueva actividad en Hermes');
      expect(locked['body'], 'Abre la aplicación para ver los detalles.');
      expect(android['visibility'], NotificationVisibility.secret.index);
      expect(actionIdsOf(locked), ['open']);
    },
  );

  test('B: cron usa título específico según resultado', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = NotificationService(prefs)..appInForeground = false;

    await service.cronFinished(
      title: 'Fichaje diario',
      ok: true,
      connId: 'demo-node',
      sessionId: 'cron-rrhh-1',
      executionId: 'execution-ok-1',
      jobId: 'job-rrhh',
      profile: 'rrhh',
    );
    await service.cronFinished(
      title: 'Fichaje diario',
      ok: false,
      connId: 'demo-node',
      sessionId: 'cron-rrhh-1',
      executionId: 'execution-fail-1',
      jobId: 'job-rrhh',
      profile: 'rrhh',
    );

    final shown = shownArgs(groupSummary: false);
    expect(shown, hasLength(2));
    expect(shown.first['title'], 'Cron completado');
    expect(shown.last['title'], 'Cron falló');
    expect(shown.first['id'], isNot(shown.last['id']));
  });

  test('B: kanban bloqueada abre la tarjeta exacta', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = NotificationService(prefs)..appInForeground = false;

    await service.kanbanTransition(
      connId: 'demo-node',
      taskId: 'task-42',
      title: 'Preparar publicación',
      status: 'blocked',
    );

    final shown = shownArgs(groupSummary: false);
    expect(shown, hasLength(1));
    final android = androidOf(shown.single);
    expect(shown.single['title'], 'Tarea de Kanban bloqueada');
    expect(shown.single['body'], 'Preparar publicación');
    expect(android['subText'], 'Kanban · task-42');
    final payload = Map<String, dynamic>.from(
      jsonDecode(shown.single['payload'] as String) as Map,
    );
    expect(payload['tid'], 'task-42');
    expect(payload['conn'], 'demo-node');
    expect(NotificationOpen.tryParse(shown.single['payload'] as String)?.taskId,
        'task-42');
  });

  test('B: cron y kanban tienen preferencias independientes', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = NotificationService(prefs)..appInForeground = false;

    // Kanban desactivado, cron activo: cron avisa, kanban calla.
    await service.setNotifyKanbanResults(false);
    await service.cronFinished(
      title: 'Fichaje diario',
      ok: true,
      connId: 'demo-node',
      sessionId: 'cron-ind',
      executionId: 'execution-ind-1',
      jobId: 'job-ind',
    );
    await service.kanbanTransition(
      connId: 'demo-node',
      taskId: 'task-ind-1',
      title: 'Tarea silenciada',
      status: 'blocked',
    );
    expect(shownArgs(groupSummary: false), hasLength(1));

    // Cron desactivado, kanban activo: kanban avisa, cron calla.
    await service.setNotifyCronResults(false);
    await service.setNotifyKanbanResults(true);
    await service.cronFinished(
      title: 'Fichaje diario',
      ok: true,
      connId: 'demo-node',
      sessionId: 'cron-ind',
      executionId: 'execution-ind-2',
      jobId: 'job-ind',
    );
    await service.kanbanTransition(
      connId: 'demo-node',
      taskId: 'task-ind-2',
      title: 'Tarea visible',
      status: 'done',
    );

    final shown = shownArgs(groupSummary: false);
    expect(shown, hasLength(2));
    expect(shown.last['title'], 'Tarea de Kanban completada');
  });

  test(
    'B: kanban no hereda el toggle de cron con la clave aún ausente',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs)..appInForeground = false;

      // Actualización desde una versión sin clave propia de Kanban: el
      // opt-in de automatizaciones (escucha) está activo y la clave
      // `notif_kanban_results` todavía no existe.
      expect(prefs.getBool('notif_kanban_results'), isNull);
      expect(service.notifyKanbanResults, isTrue);

      // Apagar solo Cron no puede apagar Kanban ni silenciar sus avisos.
      await service.setNotifyCronResults(false);
      expect(service.notifyCronResults, isFalse);
      expect(service.notifyKanbanResults, isTrue);

      await service.kanbanTransition(
        connId: 'demo-node',
        taskId: 'task-migration-1',
        title: 'Sigue avisando',
        status: 'blocked',
      );
      expect(shownArgs(groupSummary: false), hasLength(1));

      // Y al contrario: apagar Kanban tampoco arrastra a Cron.
      await service.setNotifyCronResults(true);
      await service.setNotifyKanbanResults(false);
      expect(service.notifyKanbanResults, isFalse);
      expect(service.notifyCronResults, isTrue);
    },
  );

  test(
    'varias alertas activas publican un resumen de grupo sin perder el tap',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs)..appInForeground = false;

      await service.runFinished(
        title: 'Primera tarea',
        ok: true,
        connId: 'demo-node',
        runId: 'run-group-1',
      );
      // Una sola alerta no necesita resumen.
      expect(shownArgs(groupSummary: true), isEmpty);

      await service.runFinished(
        title: 'Segunda tarea',
        ok: false,
        connId: 'demo-node',
        runId: 'run-group-2',
      );

      final summaries = shownArgs(groupSummary: true);
      expect(summaries, hasLength(1));
      final summaryAndroid = androidOf(summaries.single);
      expect(summaryAndroid['groupKey'], 'hermes');
      expect(summaryAndroid['onlyAlertOnce'], isTrue);
      expect(
        summaryAndroid['groupAlertBehavior'],
        GroupAlertBehavior.children.index,
      );

      final children = shownArgs(groupSummary: false);
      expect(children, hasLength(2));
      final childIds = children.map((args) => args['id']).toSet();
      expect(childIds, hasLength(2));
      final childRunIds = children
          .map(
            (args) =>
                (jsonDecode(args['payload'] as String) as Map)['rid'],
          )
          .toSet();
      expect(childRunIds, {'run-group-1', 'run-group-2'});
    },
  );

  test(
    'el resumen agrupa alertas de productores distintos y se retira al quedar una',
    () async {
      final prefs = await SharedPreferences.getInstance();
      // UI y listener/FGS son instancias (e isolates) distintas en producción.
      final ui = NotificationService(prefs)..appInForeground = false;
      final listener = NotificationService(prefs)..appInForeground = false;

      await ui.runFinished(
        title: 'Vista por la UI',
        ok: true,
        connId: 'demo-node',
        runId: 'run-prod-1',
      );
      expect(shownArgs(groupSummary: true), isEmpty);

      await listener.runFinished(
        title: 'Vista por el listener',
        ok: false,
        connId: 'demo-node',
        runId: 'run-prod-2',
      );
      expect(shownArgs(groupSummary: true), hasLength(1));

      // Una instancia NUEVA (reinicio de proceso) ve la bandeja real: al
      // cancelar una hija y quedar una sola, el resumen se retira.
      final restarted = NotificationService(prefs)..appInForeground = false;
      final firstId = NotificationService.eventNotificationId(
        base: 7100,
        span: 1024,
        parts: ['demo-node', '', 'run-prod-1', 'run_terminal'],
      );
      await restarted.cancelById(firstId, 'test');

      final cancels = calls
          .where((call) => call.method == 'cancel')
          .map((call) {
            final raw = call.arguments;
            return raw is Map ? raw['id'] : raw;
          })
          .toList();
      expect(cancels, containsAllInOrder([firstId, 500]));
      expect(tray.keys, isNot(contains(500)));
    },
  );
}
