import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'respuesta usa aviso compacto sin Markdown ni acción redundante',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'notif_hide_sensitive_content': false, // these tests read the text of the notices (the default hides it)
        'notif_perm_requested': true,
      });
      final calls = <MethodCall>[];
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'initialize' ||
                call.method == 'areNotificationsEnabled') {
              return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final prefs = await SharedPreferences.getInstance();
      final notificationLogs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        notificationLogs.add(message ?? '');
      };
      addTearDown(() => debugPrint = previousDebugPrint);
      final service = NotificationService(prefs)..appInForeground = false;
      await service.replyReady(
        preview: '**Modelo recomendado**\n- texto privado',
        instance: '**Server privado**',
        session: '**Plan de precios**\n# detalle oculto',
        connId: 'conn-1',
        sessionId: 'session-1',
        surface: NotificationChatSurface.bot,
        profile: 'builder',
      );
      final shown = calls.where((call) => call.method == 'show').toList();
      expect(shown, hasLength(1));
      for (final call in shown) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final android = Map<String, dynamic>.from(
          args['platformSpecifics'] as Map,
        );
        expect(
          args['title'],
          'Hermes respondió en Server privado · Plan de precios detalle oculto',
        );
        expect(args['body'], 'Modelo recomendado texto privado');
        expect(android['style'], 0); // AndroidNotificationStyle.defaultStyle
        expect(android.containsKey('actions'), isFalse);
        expect(android['subText'], isNull);
        final payload = Map<String, dynamic>.from(
          jsonDecode(args['payload'] as String) as Map,
        );
        expect(payload['conn'], 'conn-1');
        expect(payload['sid'], 'session-1');
        expect(payload['title'], 'Plan de precios detalle oculto');
        expect(payload['surface'], 'bot');
        expect(payload['profile'], 'builder');
        expect(args['body'], contains('Modelo recomendado'));
        expect(args['body'], contains('texto privado'));
        expect(jsonEncode(args), isNot(contains('**')));
      }

      await service.replyFailed(
        instance: '**Server privado**',
        session: '**Plan de precios**\n# detalle oculto',
        detail: '**token-secreto**: fallo interno con Markdown',
        connId: 'conn-1',
        sessionId: 'session-1',
      );

      final failedCall = calls.where((call) => call.method == 'show').last;
      final failedArgs = Map<String, dynamic>.from(failedCall.arguments as Map);
      final failedAndroid = Map<String, dynamic>.from(
        failedArgs['platformSpecifics'] as Map,
      );
      expect(
        failedArgs['title'],
        'Problema en Server privado · Plan de precios detalle oculto',
      );
      expect(failedArgs['body'], 'El agente no pudo completar la tarea.');
      expect(failedAndroid['style'], 0);
      expect(failedAndroid.containsKey('actions'), isFalse);
      expect(failedAndroid['subText'], isNull);
      expect(jsonEncode(failedArgs), isNot(contains('token-secreto')));
      expect(jsonEncode(failedArgs), isNot(contains('Markdown')));
      expect(jsonEncode(failedArgs), isNot(contains('**')));
      expect(notificationLogs.join('\n'), isNot(contains('Server privado')));
      expect(notificationLogs.join('\n'), isNot(contains('Plan de precios')));
      expect(
        notificationLogs.join('\n'),
        isNot(contains('Modelo recomendado')),
      );
      expect(notificationLogs.join('\n'), isNot(contains('token-secreto')));

      final readyId = (shown.first.arguments as Map)['id'] as int;
      // FNV-1a estable también tras reiniciar el proceso, en el rango de
      // 28 bits de las respuestas (0x10000000–0x1FFFFFFF, e72933ab): el
      // mismo hash que antes daba 6000 + 201 en el rango viejo de 512.
      expect(readyId, 451121353);
      expect(readyId, inInclusiveRange(0x10000000, 0x1FFFFFFF));
      expect(readyId & 0x1ff, 201);
      expect((failedCall.arguments as Map)['id'], readyId);
      await service.replyReady(
        preview: 'otra respuesta privada',
        instance: 'Server privado',
        session: 'Otro chat',
        connId: 'conn-1',
        sessionId: 'session-2',
      );
      final otherCall = calls.where((call) => call.method == 'show').last;
      expect((otherCall.arguments as Map)['id'], isNot(readyId));
      await prefs.setBool('notif_hide_sensitive_content', true);
      await service.replyReady(preview: 'Respuesta oculta', session: 'Chat oculto',
          connId: 'conn-1', sessionId: 'session-hidden');
      final hidden = calls.where((call) => call.method == 'show').last.arguments as Map;
      expect(jsonEncode(hidden), isNot(contains('Respuesta oculta')));
      expect(hidden['title'], isNot(contains('Chat oculto')));
      expect((hidden['platformSpecifics'] as Map)['visibility'], NotificationVisibility.secret.index);
      expect(
        NotificationService.compactSessionLabel(
          '${'x' * 80}\u202E**control**',
        ).runes.length,
        56,
      );
    },
  );
}
