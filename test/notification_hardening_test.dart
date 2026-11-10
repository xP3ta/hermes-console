// SPDX-License-Identifier: GPL-3.0-only
// Notification hardening findings that live in the app (A1, A2/A3, A6, A8,
// A10): what a notification or a tap can and cannot make the app do.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_payload_seal.dart';
import 'package:hermes_android/core/services/notifications/notification_preview.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/utils/transport_privacy.dart';
import 'package:hermes_android/core/utils/vpn_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _Sink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
  @override
  Future<void> cancel({required int id, String? tag}) async {}
  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    posts.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('A1 · an approval nobody saw the command of cannot be approved', () {
    late String deliveryPath;
    late _Sink sink;

    NotificationService service(SharedPreferences prefs) {
      final service = NotificationService(
        prefs,
        deliveryStore: NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: deliveryPath,
        ),
      )..appInForeground = false;
      service.setRichForTesting(sink);
      return service;
    }

    setUp(() async {
      final directory = await Directory.systemTemp.createTemp('hardening-');
      deliveryPath = '${directory.path}/delivery.db';
      sink = _Sink();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'notif_perm_requested': true,
        'notif_background_listen': true,
        'notif_hide_sensitive_content': false,
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize' ||
            call.method == 'areNotificationsEnabled') {
          return true;
        }
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    List<String> actions(Map<String, Object?> post) => [
      for (final a in post['actions']! as List) (a as Map)['id'] as String,
    ];

    test('a run label (blind) offers only Deny and Open', () async {
      final prefs = await SharedPreferences.getInstance();
      await service(prefs).approvalPending(
        tool: 'terminal',
        connId: 'c1',
        sessionId: 's1',
        sessionTitle: 'Chat',
        runId: 's1',
        approvalId: 'req-blind',
        blind: true,
      );
      expect(sink.posts, hasLength(1));
      expect(actions(sink.posts.single), ['deny', 'open']);
    });

    test('blind never offers Approve even if the request lists it', () async {
      final prefs = await SharedPreferences.getInstance();
      await service(prefs).approvalPending(
        tool: 'terminal',
        connId: 'c1',
        sessionId: 's1',
        runId: 's1',
        approvalId: 'req-blind-2',
        approvalChoices: const ['once', 'session', 'always', 'deny'],
        blind: true,
      );
      expect(actions(sink.posts.single), ['deny', 'open']);
      final payload = jsonDecode(sink.posts.single['actionPayload']! as String);
      expect(payload['choices'], ['deny']);
    });

    test('with a command the app itself showed, Approve stays', () async {
      final prefs = await SharedPreferences.getInstance();
      await service(prefs).approvalPending(
        tool: 'rm -rf build',
        command: 'rm -rf build',
        connId: 'c1',
        sessionId: 's1',
        runId: 's1',
        approvalId: 'req-seen',
      );
      expect(actions(sink.posts.single), ['approve', 'deny', 'open']);
    });

    for (final surface in const [
      NotificationChatSurface.normal,
      NotificationChatSurface.bot,
    ]) {
      test(
        'hidden content (${surface.name}): Deny and Open, never Allow',
        () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('notif_hide_sensitive_content', true);
          await service(prefs).approvalPending(
            tool: 'rm -rf build',
            command: 'rm -rf build',
            connId: 'c1',
            sessionId: 's1',
            sessionTitle: 'Chat',
            runId: 's1',
            approvalId: 'req-hidden-${surface.name}',
            approvalChoices: const ['once', 'session', 'always', 'deny'],
            surface: surface,
          );
          expect(sink.posts, hasLength(1));
          expect(actions(sink.posts.single), ['deny', 'open']);
          final payload = jsonDecode(
            sink.posts.single['actionPayload']! as String,
          );
          expect(payload['choices'], ['deny']);
          expect('${sink.posts.single['text']}', isNot(contains('rm -rf')));
        },
      );
    }

    test('blind on a request that cannot be denied offers only Open', () async {
      final prefs = await SharedPreferences.getInstance();
      await service(prefs).approvalPending(
        tool: 'terminal',
        connId: 'c1',
        sessionId: 's1',
        runId: 's1',
        approvalId: 'req-blind-3',
        approvalChoices: const ['once'],
        blind: true,
      );
      expect(actions(sink.posts.single), ['open']);
    });
  });

  group('A6 · notice text is hidden unless the user chose otherwise', () {
    test('no choice stored: hidden; an explicit false stays false', () async {
      SharedPreferences.setMockInitialValues({});
      var prefs = await SharedPreferences.getInstance();
      expect(NotificationService(prefs).hideSensitiveContent, isTrue);
      SharedPreferences.setMockInitialValues({
        'notif_hide_sensitive_content': false,
      });
      prefs = await SharedPreferences.getInstance();
      expect(NotificationService(prefs).hideSensitiveContent, isFalse);
      SharedPreferences.setMockInitialValues({
        'notif_hide_sensitive_content': true,
      });
      prefs = await SharedPreferences.getInstance();
      expect(NotificationService(prefs).hideSensitiveContent, isTrue);
    });
  });

  group('A8 · a tap only opens what this install sealed', () {
    tearDown(() => NotificationPayloadSeal.installForTesting(null));

    test('without a key nothing is sealed and nothing is checked', () {
      NotificationPayloadSeal.installForTesting(null);
      const open = NotificationOpen(connId: 'c', sessionId: 's');
      expect(jsonDecode(open.toPayload()), isNot(contains('mac')));
      expect(NotificationPayloadSeal.verify('{"conn":"x"}'), isTrue);
    });

    test('a sealed payload verifies, parses and keeps its destination', () {
      NotificationPayloadSeal.installForTesting(List.filled(32, 7));
      const open = NotificationOpen(connId: 'c', sessionId: 's', title: 'T');
      final payload = open.toPayload();
      expect(jsonDecode(payload), contains('mac'));
      expect(NotificationPayloadSeal.verify(payload), isTrue);
      final back = NotificationOpen.tryParse(payload)!;
      expect((back.connId, back.sessionId, back.title), ('c', 's', 'T'));
    });

    test('an unsealed, forged or edited payload is refused', () {
      NotificationPayloadSeal.installForTesting(List.filled(32, 7));
      expect(NotificationPayloadSeal.verify('{"conn":"c","sid":"s"}'), isFalse);
      expect(NotificationPayloadSeal.verify(null), isFalse);
      expect(NotificationPayloadSeal.verify('not json'), isFalse);
      expect(NotificationPayloadSeal.verify('[1]'), isFalse);
      expect(NotificationPayloadSeal.verify('{"mac":""}'), isFalse);
      final sealed = const NotificationOpen(
        connId: 'c',
        sessionId: 's',
      ).toPayload();
      final edited = Map<String, dynamic>.from(jsonDecode(sealed) as Map)
        ..['sid'] = 'someone-elses';
      expect(NotificationPayloadSeal.verify(jsonEncode(edited)), isFalse);
      final other = Map<String, dynamic>.from(jsonDecode(sealed) as Map)
        ..['mac'] = 'AAAA${(jsonDecode(sealed) as Map)['mac']}';
      expect(NotificationPayloadSeal.verify(jsonEncode(other)), isFalse);
    });

    test('another install (another key) cannot forge this one\'s taps', () {
      NotificationPayloadSeal.installForTesting(List.filled(32, 1));
      final theirs = const NotificationOpen(
        connId: 'c',
        sessionId: 's',
      ).toPayload();
      NotificationPayloadSeal.installForTesting(List.filled(32, 2));
      expect(NotificationPayloadSeal.verify(theirs), isFalse);
    });

    test('ensure creates a key once and reuses the stored one', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      NotificationPayloadSeal.ensure(prefs);
      final first = const NotificationOpen(connId: 'c').toPayload();
      final stored = prefs.getString(NotificationPayloadSeal.prefsKey);
      expect(stored, isNotNull);
      NotificationPayloadSeal.installForTesting(null);
      NotificationPayloadSeal.ensure(prefs);
      expect(prefs.getString(NotificationPayloadSeal.prefsKey), stored);
      expect(NotificationPayloadSeal.verify(first), isTrue);
    });
  });

  group(
    'A2/A3 · credentials only go where nobody listens',
    () {
      test(
        'https, loopback and (with a VPN up) Tailscale are fine; a LAN is not',
        () {
          bool enc(String url, {bool vpn = false}) =>
              TransportPrivacy.isEncryptedPath(url, overlayActive: vpn);
          expect(enc('https://hermes.example.com:9119'), isTrue);
          expect(enc('wss://hermes.example.com'), isTrue);
          expect(enc('http://127.0.0.1:9119'), isTrue);
          expect(enc('http://localhost:9119'), isTrue);
          expect(enc('http://[::1]:9119'), isTrue);
          for (final lan in [
            'http://192.168.1.10:9119',
            'http://10.0.0.5:9119',
            'http://172.16.4.4:9119',
            'http://hermes.local:9119',
            'http://hermes:9119',
            'http://hermes.test:9119',
            'http://hermes.example:9119',
            'http://203.0.113.9:9119',
            'ftp://127.0.0.1',
            '',
            'http://',
          ]) {
            expect(enc(lan), isFalse, reason: lan);
            expect(
              enc(lan, vpn: true),
              isFalse,
              reason: '$lan even with a VPN',
            );
          }
          expect(enc('http://100.101.102.103:9119'), isFalse);
          expect(enc('http://100.101.102.103:9119', vpn: true), isTrue);
          expect(enc('http://mac.tail1234.ts.net:9119'), isFalse);
          expect(enc('http://mac.tail1234.ts.net:9119', vpn: true), isTrue);
          expect(
            enc('http://100.63.0.1:9119', vpn: true),
            isFalse,
          ); // not CGNAT
          expect(enc('http://100.128.0.1:9119', vpn: true), isFalse);
        },
      );

      test(
        'a Tailscale tunnel: a VPN interface with a 100.64/10 address',
        () async {
          Future<bool> up(Map<String, List<String>> interfaces) =>
              vpnInterfaceActive(
                interfaces: () async => [
                  for (final e in interfaces.entries)
                    (name: e.key, ipv4: e.value),
                ],
              );
          const ts = ['100.101.102.103'];
          expect(
            await up({
              'wlan0': ['192.168.1.5'],
              'lo': ['127.0.0.1'],
            }),
            isFalse,
          );
          expect(
            await up({
              'wlan0': ['192.168.1.5'],
              'tun0': ts,
            }),
            isTrue,
          );
          expect(await up({'tailscale0': ts}), isTrue);
          expect(await up({'wg0': ts}), isTrue);
          expect(await up({}), isFalse);
          // Any other VPN is not Tailscale (#13).
          expect(
            await up({
              'tun0': ['10.8.0.2'],
            }),
            isFalse,
          );
          expect(
            await up({
              'ppp0': ['100.63.0.1'],
            }),
            isFalse,
          );
          expect(await up({'tun0': []}), isFalse);
          // A 100.x address on Wi-Fi (carrier CGNAT) is not a tunnel either.
          expect(await up({'wlan0': ts}), isFalse);
          expect(
            await vpnInterfaceActive(
              interfaces: () async => throw Exception('x'),
            ),
            isFalse,
          );
        },
      );

      test(
        'a background read over plain http on a LAN is refused before any request',
        () async {
          var requests = 0;
          DashboardClient.vpnProbe = () async => false;
          addTearDown(() => DashboardClient.vpnProbe = vpnInterfaceActive);
          final client = DashboardClient(
            host: '192.168.1.10',
            manualToken: 'secret-session-token',
            httpClientOverride: MockClient((request) async {
              requests++;
              return http.Response('{}', 200);
            }),
          );
          await expectLater(
            client.notificationRead(
              'sessions/s1/export',
              timeout: const Duration(seconds: 2),
            ),
            throwsA(isA<BackgroundTransportRefused>()),
          );
          expect(requests, 0, reason: 'the token never left the phone');
        },
      );

      test('over a tunnel that is up the same read goes through', () async {
        final seen = <http.Request>[];
        DashboardClient.vpnProbe = () async => true;
        addTearDown(() => DashboardClient.vpnProbe = vpnInterfaceActive);
        final client = DashboardClient(
          host: '100.101.102.103',
          manualToken: 'secret-session-token',
          httpClientOverride: MockClient((request) async {
            seen.add(request);
            return http.Response('{"messages":[]}', 200);
          }),
        );
        final data = await client.notificationRead(
          'sessions/s1/export',
          timeout: const Duration(seconds: 2),
        );
        expect(data, {'messages': []});
        expect(seen, hasLength(1));
      });
    },
  );

  group('A10 · more secrets the preview never shows', () {
    test('JWT, cloud keys, PEM blocks and signed URLs are redacted', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      for (final secret in [
        jwt,
        'AKIAIOSFODNN7EXAMPLE',
        'ASIAIOSFODNN7EXAMPLE',
        'AIzaSyA1234567890abcdefghijklmnopqrstuv',
        'npm_abcdefghijklmnopqrstuvwxyz0123456789',
        '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----',
        '-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEAAAAA',
      ]) {
        final shown = notificationPreview('Tu clave es $secret y listo');
        expect(
          shown,
          isNot(contains(secret.split('\n').first.substring(0, 20))),
          reason: secret,
        );
        expect(shown, contains('redacted'), reason: secret);
      }
      expect(
        notificationPreview('Abre https://files.example/a.pdf?sig=abc123SECRET&x=1 ya'),
        allOf(
          isNot(contains('abc123SECRET')),
          contains('x=1'),
          contains('a.pdf?sig=[redacted]'),
          isNot(contains(r'$1')),
        ),
      );
      expect(
        notificationPreview('https://api.example/v1?key=supersecretvalue'),
        isNot(contains('supersecretvalue')),
      );
    });

    test('ordinary text and ordinary links are left alone', () {
      expect(
        notificationPreview('Termino el informe de ventas'),
        'Termino el informe de ventas',
      );
      expect(
        notificationPreview('Mira https://example.com/docs?page=2'),
        contains('page=2'),
      );
    });
  });
}
