import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<String, dynamic> launchDetails;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = <MethodCall>[];
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

  test('Cron muestra un resumen útil, acotado y conserva el destino', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = NotificationService(prefs)..appInForeground = false;
    final longTail = List.filled(90, 'detalle').join(' ');

    await service.cronFinished(
      title: 'resumen-proyecto-aurora',
      ok: true,
      connId: 'demo-node',
      sessionId: 'cron_demo_001',
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
    expect(decoded['profile'], 'research');
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
      final service = NotificationService(prefs)..appInForeground = false;

      await service.cronFinished(
        title: 'resumen-proyecto',
        ok: true,
        connId: 'demo-node',
        sessionId: 'cron_demo_001',
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
    final service = NotificationService(prefs);
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
    final service = NotificationService(prefs);
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
    final service = NotificationService(prefs);
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
      final service = NotificationService(prefs);
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
}
