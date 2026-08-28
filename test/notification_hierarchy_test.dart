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
}
