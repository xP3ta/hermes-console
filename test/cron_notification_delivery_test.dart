import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<String, dynamic> launchDetails;
  late bool failNextShow;
  late String deliveryPath;

  NotificationService testService(SharedPreferences prefs) =>
      NotificationService(
        prefs,
        deliveryStore: NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: deliveryPath,
        ),
      );

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('cron-delivery-');
    deliveryPath = '${directory.path}/notification_delivery_v1.db';
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = <MethodCall>[];
    failNextShow = false;
    launchDetails = <String, dynamic>{
      'notificationLaunchedApp': false,
      'notificationResponse': null,
    };
    SharedPreferences.setMockInitialValues({
      'app_locale': 'es',
      'notif_perm_requested': true,
      'notif_background_listen': true,
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'show' && failNextShow) {
        failNextShow = false;
        throw PlatformException(code: 'show_failed');
      }
      return switch (call.method) {
        'initialize' || 'areNotificationsEnabled' => true,
        'getNotificationAppLaunchDetails' => launchDetails,
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  String payload({String sessionId = 'cron_demo_001'}) => jsonEncode({
    'conn': 'demo-node',
    'sid': sessionId,
    'title': 'Resumen de Proyecto Aurora',
    'profile': 'research',
  });

  Future<void> emitTap({
    required String payload,
    String? actionId,
    int responseType = 0,
  }) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('didReceiveNotificationResponse', <String, dynamic>{
          'notificationId': 8099,
          'actionId': actionId,
          'input': null,
          'payload': payload,
          'notificationResponseType': responseType,
        }),
      ),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  test(
    'recurrent blocked transition gets a new stable event after ready snapshot',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = testService(prefs)..appInForeground = false;
      const scope = 'demo-node/default/kanban/discovery';
      const blocked = DurableDiscoveryNotification(
        identity: NotificationEventIdentity(
          connId: 'demo-node',
          profile: 'default',
          sourceKind: 'kanban',
          objectId: 'task-1',
          eventKind: 'blocked',
          sourceVersion: 'task-1:blocked',
        ),
        destinationKind: 'kanban_transition',
        kind: NotificationKind.run,
        title: 'Blocked',
        body: 'Task 1',
        taskId: 'task-1',
      );

      Future<void> deliver(
        String version,
        List<DurableDiscoveryNotification> events,
      ) => service.deliverDiscoveryBatch(
        scopeKey: scope,
        connId: 'demo-node',
        profile: 'default',
        sourceKind: 'kanban',
        objectId: 'discovery',
        sourceVersion: version,
        lastState: version.split(':').last,
        events: events,
        suppressByPolicy: false,
        versionEventsByPreviousSnapshot: true,
      );

      await deliver('task-1:blocked', const [blocked]);
      await deliver('task-1:blocked', const [blocked]);
      expect(
        calls.where((call) => call.method == 'show'),
        isEmpty,
        reason: 'an unchanged initial blocked snapshot must stay baseline-only',
      );
      await deliver('task-1:ready', const []);
      await deliver('task-1:blocked', const [blocked]);

      expect(calls.where((call) => call.method == 'show'), hasLength(1));
      await service.closeDelivery();
    },
  );

  test(
    'empty initial cron discovery seeds cursor and later terminal dispatches once',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = testService(prefs)..appInForeground = false;
      const scope = 'demo-node/default/cron/discovery';

      await service.deliverDiscoveryBatch(
        scopeKey: scope,
        connId: 'demo-node',
        profile: 'default',
        sourceKind: 'cron',
        objectId: 'discovery',
        sourceVersion: 'empty-snapshot',
        lastState: 'snapshot',
        events: const <DurableDiscoveryNotification>[],
        suppressByPolicy: false,
      );
      expect(calls.where((call) => call.method == 'show'), isEmpty);

      const identity = NotificationEventIdentity(
        connId: 'demo-node',
        profile: 'default',
        sourceKind: 'cron',
        objectId: 'execution-later',
        eventKind: 'terminal',
        sourceVersion: 'execution-later:completed',
      );
      const event = DurableDiscoveryNotification(
        identity: identity,
        destinationKind: 'cron_terminal',
        kind: NotificationKind.run,
        title: 'Cron completed',
        body: 'Done',
        jobId: 'job-later',
      );
      await service.deliverDiscoveryBatch(
        scopeKey: scope,
        connId: 'demo-node',
        profile: 'default',
        sourceKind: 'cron',
        objectId: 'discovery',
        sourceVersion: 'terminal-snapshot',
        lastState: 'snapshot',
        events: const <DurableDiscoveryNotification>[event],
        suppressByPolicy: false,
      );
      await service.deliverDiscoveryBatch(
        scopeKey: scope,
        connId: 'demo-node',
        profile: 'default',
        sourceKind: 'cron',
        objectId: 'discovery',
        sourceVersion: 'terminal-snapshot',
        lastState: 'snapshot',
        events: const <DurableDiscoveryNotification>[event],
        suppressByPolicy: false,
      );

      final shown = calls.where((call) => call.method == 'show').toList();
      expect(shown, hasLength(1));
      final args = Map<String, dynamic>.from(shown.single.arguments as Map);
      final open = NotificationOpen.tryParse(args['payload'] as String?);
      expect(open?.jobId, 'job-later');
      await service.closeDelivery();
    },
  );

  test('unknown cron terminal is accepted by the durable store', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs)..appInForeground = false;
    const event = DurableDiscoveryNotification(
      identity: NotificationEventIdentity(
        connId: 'demo-node',
        profile: 'default',
        sourceKind: 'cron',
        objectId: 'execution-unknown',
        eventKind: 'terminal',
        sourceVersion: 'execution-unknown:unknown',
      ),
      destinationKind: 'cron_terminal',
      kind: NotificationKind.run,
      title: 'Cron status unknown',
      body: 'Open Cron for details.',
      jobId: 'job-unknown',
    );

    await service.deliverDiscoveryBatch(
      scopeKey: 'demo-node/default/cron/discovery',
      connId: 'demo-node',
      profile: 'default',
      sourceKind: 'cron',
      objectId: 'discovery',
      sourceVersion: 'empty-snapshot',
      lastState: 'snapshot',
      events: const [],
      suppressByPolicy: false,
    );
    await service.deliverDiscoveryBatch(
      scopeKey: 'demo-node/default/cron/discovery',
      connId: 'demo-node',
      profile: 'default',
      sourceKind: 'cron',
      objectId: 'discovery',
      sourceVersion: 'execution-unknown:unknown',
      lastState: 'unknown',
      events: const [event],
      suppressByPolicy: false,
    );

    expect(calls.where((call) => call.method == 'show'), hasLength(1));
    await service.closeDelivery();
  });

  test('Desktop approval persists session and request routing', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs)..appInForeground = false;
    const scope = 'demo-node/default/approval/desktop-session';
    await service.deliverDiscoveryBatch(
      scopeKey: scope,
      connId: 'demo-node',
      profile: 'default',
      sourceKind: 'approval',
      objectId: 'desktop-session',
      sourceVersion: 'baseline',
      lastState: 'responded',
      events: const [],
      suppressByPolicy: false,
    );
    const event = DurableDiscoveryNotification(
      identity: NotificationEventIdentity(
        connId: 'demo-node',
        profile: 'default',
        sourceKind: 'approval',
        objectId: 'desktop-session',
        eventKind: 'pending',
        sourceVersion: 'request-desktop-1',
      ),
      destinationKind: 'approval',
      kind: NotificationKind.approval,
      title: 'Approval required',
      body: 'Open Hermes to review.',
      sessionId: 'desktop-session',
      requestId: 'request-desktop-1',
    );

    await service.deliverDiscoveryBatch(
      scopeKey: scope,
      connId: 'demo-node',
      profile: 'default',
      sourceKind: 'approval',
      objectId: 'desktop-session',
      sourceVersion: 'request-desktop-1',
      lastState: 'pending',
      events: const [event],
      suppressByPolicy: false,
    );

    final shown = calls.where((call) => call.method == 'show').single;
    final args = Map<String, dynamic>.from(shown.arguments as Map);
    final open = NotificationOpen.tryParse(args['payload'] as String?);
    expect(open?.sessionId, 'desktop-session');
    expect(open?.requestId, 'request-desktop-1');
    expect(open?.runId, isNull);
    await service.closeDelivery();
  });

  test('Cron muestra un resumen útil, acotado y conserva el destino', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs)..appInForeground = false;
    final longTail = List.filled(90, 'detalle').join(' ');

    await service.cronFinished(
      title: 'resumen-proyecto-aurora',
      ok: true,
      connId: 'demo-node',
      sessionId: 'cron_demo_001',
      executionId: 'execution-aurora-1',
      jobId: 'job-aurora',
      profile: 'research',
      preview:
          '**3 tareas verificadas**\n'
          '- [Checklist Android](https://example.test/private): 2 pendientes '
          '$longTail',
    );

    final shown = calls.where((call) => call.method == 'show').single;
    final args = Map<String, dynamic>.from(shown.arguments as Map);
    final android = Map<String, dynamic>.from(args['platformSpecifics'] as Map);
    final body = args['body'] as String;
    final decoded = Map<String, dynamic>.from(
      jsonDecode(args['payload'] as String) as Map,
    );

    expect(args['title'], 'Cron completado');
    expect(body, contains('3 tareas verificadas'));
    expect(body, contains('2 pendientes'));
    expect(body, isNot(contains('**')));
    expect(body, isNot(contains('https://')));
    expect(body.runes.length, lessThanOrEqualTo(280));
    expect(android['subText'], 'resumen-proyecto-aurora');
    expect(decoded['conn'], 'demo-node');
    expect(decoded['sid'], 'cron_demo_001');
    expect(decoded.containsKey('jid'), isFalse);
    expect(decoded['profile'], 'research');
    final open = NotificationOpen.tryParse(args['payload'] as String);
    expect(open, isNotNull);
    expect(open?.sessionId, 'cron_demo_001');
    expect(open?.jobId, isNull);
  });

  test(
    'Cron no filtra el resumen cuando se oculta contenido sensible',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'notif_perm_requested': true,
        'notif_background_listen': true,
        'notif_hide_sensitive_content': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final service = testService(prefs)..appInForeground = false;

      await service.cronFinished(
        title: 'resumen-proyecto',
        ok: true,
        connId: 'demo-node',
        sessionId: 'cron_demo_001',
        executionId: 'execution-project-1',
        jobId: 'job-project',
        profile: 'research',
        preview: '3 tareas: dato-demo-que-no-debe-salir',
      );

      final shown = calls.where((call) => call.method == 'show').single;
      final args = Map<String, dynamic>.from(shown.arguments as Map);
      expect(args['title'], 'Nueva actividad en Hermes');
      expect(args['body'], 'Abre la aplicación para ver los detalles.');
      expect(
        Map<String, dynamic>.from(args['platformSpecifics'] as Map)['subText'],
        'Hermes',
      );
      expect(jsonEncode(args), isNot(contains('dato-demo-que-no-debe-salir')));
    },
  );

  test('toque con la app viva entrega conexión, sesión y perfil', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs);
    final opened = <NotificationOpen>[];
    service.onOpenSession = (open) {
      opened.add(open);
      return true;
    };
    await service.init();

    await emitTap(payload: payload());

    expect(opened, hasLength(1));
    expect(opened.single.connId, 'demo-node');
    expect(opened.single.sessionId, 'cron_demo_001');
    expect(opened.single.profile, 'research');
  });

  test('arranque desde notificación entrega también el destino', () async {
    launchDetails = <String, dynamic>{
      'notificationLaunchedApp': true,
      'notificationResponse': <String, dynamic>{
        'notificationId': 8099,
        'actionId': 'open',
        'input': null,
        'payload': payload(),
        'notificationResponseType': 1,
      },
    };
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs);
    final opened = <NotificationOpen>[];
    service.onOpenSession = (open) {
      opened.add(open);
      return true;
    };

    await service.init();

    expect(opened, hasLength(1));
    expect(opened.single.connId, 'demo-node');
    expect(opened.single.sessionId, 'cron_demo_001');
    expect(opened.single.profile, 'research');
  });

  test('si la navegación aún no está lista el toque se reintenta', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs);
    var ready = false;
    var opened = 0;
    service.onOpenSession = (open) {
      if (!ready) return false;
      opened++;
      return true;
    };
    await service.init();

    await emitTap(payload: payload(), actionId: 'open', responseType: 1);
    expect(opened, 0);

    ready = true;
    expect(service.retryPendingOpen(), isTrue);
    expect(opened, 1);
  });

  test(
    'recupera un toque de reanudación perdido sin abrir dos veces',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = testService(prefs);
      final opened = <NotificationOpen>[];
      service.onOpenSession = (open) {
        opened.add(open);
        return true;
      };
      await service.init();

      launchDetails = <String, dynamic>{
        'notificationLaunchedApp': true,
        'notificationResponse': <String, dynamic>{
          'notificationId': 8099,
          'actionId': 'open',
          'input': null,
          'payload': payload(),
          'notificationResponseType': 1,
        },
      };

      expect(await service.recoverPlatformOpen(), isTrue);
      expect(await service.recoverPlatformOpen(), isFalse);
      expect(opened, hasLength(1));
    },
  );

  /// Llamadas `show` que son alertas reales (no el resumen de grupo).
  List<MethodCall> childShows() => calls.where((call) {
    if (call.method != 'show') return false;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final android = Map<String, dynamic>.from(args['platformSpecifics'] as Map);
    return android['setAsGroupSummary'] != true;
  }).toList();

  test(
    'productores concurrentes solo alertan una vez por terminal y approval',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final taskCenter = testService(prefs)..appInForeground = false;
      final runDetail = testService(prefs)..appInForeground = false;

      await taskCenter.runFinished(
        title: 'Título visto por TaskCenter',
        ok: false,
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-shared',
      );
      await runDetail.runFinished(
        title: 'Texto distinto visto por RunDetail',
        ok: false,
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-shared',
      );
      await taskCenter.approvalPending(
        tool: 'bash',
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-shared',
        approvalId: 'request-shared',
      );
      await runDetail.approvalPending(
        tool: 'shell con otro texto',
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-shared',
        approvalId: 'request-shared',
      );

      expect(childShows(), hasLength(2));
    },
  );

  test('identidad incompleta falla cerrada sin mostrar alertas', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs)..appInForeground = false;

    await service.runFinished(title: 'Fallo A', ok: false);
    await service.runFinished(title: 'Fallo B', ok: false);

    expect(childShows(), isEmpty);
  });

  test(
    'approval polling without authoritative request id fails closed',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = testService(prefs)..appInForeground = false;

      await service.approvalPending(
        tool: 'shell',
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-without-request-id',
      );

      expect(childShows(), isEmpty);
    },
  );

  test(
    'un fallo de plataforma libera el claim terminal para reintento',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = testService(prefs)..appInForeground = false;
      failNextShow = true;

      await service.runFinished(
        title: 'Fallo material',
        ok: false,
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-retryable',
      );

      expect(childShows(), hasLength(1));
    },
  );

  test('un fallo de plataforma libera el claim de aprobación', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs)..appInForeground = false;
    failNextShow = true;

    await service.approvalPending(
      tool: 'shell',
      connId: 'demo-node',
      profile: 'research',
      runId: 'run-approval-retry',
      approvalId: 'request-retry',
    );

    expect(childShows(), hasLength(1));
  });

  test('un fallo de plataforma libera el claim de cron', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = testService(prefs)..appInForeground = false;
    failNextShow = true;

    Future<void> emit() => service.cronFinished(
      title: 'Fichaje diario',
      ok: false,
      connId: 'demo-node',
      sessionId: 'cron-rrhh',
      executionId: 'execution-retry',
      jobId: 'job-rrhh',
      profile: 'rrhh',
    );

    await emit();

    expect(childShows(), hasLength(1));
  });

  test(
    'cron sin sessionId deriva IDs Android de executionId y jobId',
    () async {
      final directory = await Directory.systemTemp.createTemp('cron-identity-');
      addTearDown(() => directory.delete(recursive: true));
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(
        prefs,
        deliveryStore: NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        ),
      )..appInForeground = false;
      addTearDown(service.closeDelivery);

      for (final execution in const ['execution-1', 'execution-2']) {
        await service.cronFinished(
          title: 'Script sin sesión',
          ok: false,
          connId: 'demo-node',
          sessionId: '',
          executionId: execution,
          jobId: 'job-script',
          profile: 'ops',
        );
      }

      final shown = childShows();
      expect(shown, hasLength(2));
      expect(
        shown.map((call) => (call.arguments as Map)['id']).toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'approvals simultáneas usan identidad durable y cancelación exacta',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'service-delivery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
      );
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs, deliveryStore: store)
        ..appInForeground = false;
      addTearDown(service.closeDelivery);

      await service.approvalPending(
        tool: 'shell',
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-a',
        approvalId: 'request-a',
      );
      await service.approvalPending(
        tool: 'browser',
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-b',
        approvalId: 'request-b',
      );

      final shown = childShows();
      expect(shown, hasLength(2));
      final ids = shown.map((call) => (call.arguments as Map)['id']).toSet();
      final tags = shown
          .map(
            (call) =>
                ((call.arguments as Map)['platformSpecifics'] as Map)['tag'],
          )
          .toSet();
      expect(ids, hasLength(2));
      expect(tags, hasLength(2));
      expect(
        tags.every((tag) => tag.toString().startsWith('hermes.event.')),
        isTrue,
      );

      await service.cancelApproval(
        connId: 'demo-node',
        profile: 'research',
        runId: 'run-a',
        approvalId: 'request-a',
      );
      final cancels = calls.where((call) {
        if (call.method != 'cancel') return false;
        final tag = (call.arguments as Map)['tag']?.toString() ?? '';
        return tag.startsWith('hermes.event.');
      }).toList();
      expect(cancels, hasLength(1));
      final cancelled = (await store.allEvents()).singleWhere(
        (event) => event.status == DeliveryStatus.cancelled,
      );
      expect((cancels.single.arguments as Map)['id'], cancelled.androidId);
      expect((cancels.single.arguments as Map)['tag'], cancelled.androidTag);
      expect(await store.countByStatus(DeliveryStatus.cancelled), 1);
      expect(await store.countByStatus(DeliveryStatus.presented), 1);
    },
  );
}
