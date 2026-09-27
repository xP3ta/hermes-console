import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_notification_presenter.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/widgets/bot_face_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<ui.Image> _decode(List<int> png) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
  return (await codec.getNextFrame()).image;
}

Future<Color> _pixel(List<int> png, double fx, double fy) async {
  final image = await _decode(png);
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final x = (image.width * fx).round().clamp(0, image.width - 1);
  final y = (image.height * fy).round().clamp(0, image.height - 1);
  final i = (y * image.width + x) * 4;
  return Color.fromARGB(
    data.getUint8(i + 3),
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shared identity resolver (a → b → c)', () {
    test('a) a configured photo avatar wins', () {
      const p = AgentProfile(
        name: 'hermes',
        model: 'm',
        provider: 'p',
        hasAvatar: true,
        botModeUiMeta: {'imageKind': 'photo', 'shape': 'blobatar::sun'},
      );
      final id = BotFaceIdentity.ofProfile(p);
      expect(id.source, BotFaceSource.avatar);
    });

    test('b) a configured Desktop face is painted procedurally', () {
      const p = AgentProfile(
        name: 'builder',
        model: 'm',
        provider: 'p',
        // A PNG next to shape metadata is Desktop's backfill, not a photo.
        hasAvatar: true,
        botModeUiMeta: {'shape': 'sun', 'color': '#38bdf8'},
      );
      final id = BotFaceIdentity.ofProfile(p);
      expect(id.source, BotFaceSource.procedural);
      expect(id.shapeWire, 'blobatar::sun');
      expect(id.visual.resolvedKind, 'sun');
    });

    test('c) nothing configured falls back to the coloured sphere', () {
      const p = AgentProfile(
        name: 'scout',
        model: 'm',
        provider: 'p',
        botModeUiMeta: {'color': '#e8932c'},
      );
      final id = BotFaceIdentity.ofProfile(p);
      expect(id.source, BotFaceSource.sphere);
      expect(id.sphere, 'orange');
      expect(
        BotFaceIdentity.ofProfile(null, name: 'x').source,
        BotFaceSource.sphere,
      );
    });

    test('sphere palette maps colours to the nearest entry', () {
      expect(BotSpherePalette.nearest('#46c49f', seed: 'a'), 'teal');
      expect(BotSpherePalette.nearest('#d7243f', seed: 'a'), 'red');
      expect(BotSpherePalette.nearest('#6d35ea', seed: 'a'), 'violet');
      expect(BotSpherePalette.nearest('#4c86f2', seed: 'a'), 'sky');
      expect(BotSpherePalette.nearest('#9a9a9a', seed: 'a'), 'grey');
      // No colour: stable per name.
      expect(
        BotSpherePalette.nearest(null, seed: 'lead'),
        BotSpherePalette.nearest(null, seed: 'lead'),
      );
    });

    test('cache keys differ per source so a config change re-renders', () {
      final a = BotFaceIdentity.resolve(profile: 'b', paintsPhoto: true);
      final b = BotFaceIdentity.resolve(profile: 'b', faceShape: 'blobatar');
      final c = BotFaceIdentity.resolve(profile: 'b');
      expect({a.cacheKey, b.cacheKey, c.cacheKey}, hasLength(3));
    });
  });

  group('sphere face frames', () {
    test('every state renders a distinct PNG', () async {
      final seen = <String>{};
      for (final state in BotFaceBitmapState.values) {
        final png = await BotFaceBitmapCache.renderSpherePng(
          'teal',
          state: state,
          size: 96,
          plate: false,
        );
        seen.add(String.fromCharCodes(png!));
      }
      expect(seen, hasLength(BotFaceBitmapState.values.length));
    });

    test('gaze is off-centre per state; failed eyes are flat', () {
      final idle = sphereEyePose(BotFaceBitmapState.idle, 0);
      final work = sphereEyePose(BotFaceBitmapState.working, 0);
      final done = sphereEyePose(BotFaceBitmapState.done, 0);
      final fail = sphereEyePose(BotFaceBitmapState.failed, 0);
      expect(idle.cx, isNot(50));
      expect(work.cx, lessThan(50));
      expect(sphereEyePose(BotFaceBitmapState.working, 1).cx, greaterThan(50));
      expect(done.cy, lessThan(idle.cy));
      expect(fail.h, lessThan(fail.w));
      // Big capsule eyes: ~27 % of the face height when open.
      expect(idle.h / 84, closeTo(.21, .05));
    });

    test(
      'vertical gradient: lighter top than bottom, black capsule eyes',
      () async {
        final png = await BotFaceBitmapCache.renderSpherePng(
          'grey',
          size: 100,
          plate: false,
        );
        final top = await _pixel(png!, .5, .14);
        final bottom = await _pixel(png, .5, .88);
        expect(top.computeLuminance(), greaterThan(bottom.computeLuminance()));
        // Idle left eye centre ≈ (48.6, 41) in face units.
        final eye = await _pixel(png, .486, .41);
        expect(eye.computeLuminance(), lessThan(.02));
      },
    );

    test(
      'badge: blue pill working, green done, amber needs, red failed',
      () async {
        Future<Color> badge(BotFaceBitmapState s, double fx, double fy) async =>
            _pixel(
              (await BotFaceBitmapCache.renderSpherePng(
                'grey',
                state: s,
                size: 100,
                plate: false,
              ))!,
              fx,
              fy,
            );
        expect(
          await badge(BotFaceBitmapState.working, .08, .16),
          BotStateColors.working,
        );
        expect(
          await badge(BotFaceBitmapState.done, .16, .17),
          BotStateColors.done,
        );
        expect(
          await badge(BotFaceBitmapState.needsYou, .16, .17),
          BotStateColors.needsYou,
        );
        expect(
          await badge(BotFaceBitmapState.failed, .16, .17),
          BotStateColors.failed,
        );
        final idle = await badge(BotFaceBitmapState.idle, .16, .17);
        expect(idle.a, 0);
      },
    );

    test('identity picks procedural vs sphere rendering', () async {
      final sphere = await BotFaceBitmapCache.renderIdentityPng(
        BotFaceIdentity.resolve(profile: 'builder', colorHex: '#46c49f'),
        size: 64,
      );
      final procedural = await BotFaceBitmapCache.renderIdentityPng(
        BotFaceIdentity.resolve(profile: 'builder', faceShape: 'blobatar::sun'),
        size: 64,
      );
      expect(
        String.fromCharCodes(sphere!),
        isNot(String.fromCharCodes(procedural!)),
      );
    });

    test(
      'botFacePath passes the avatar image only for avatar identities',
      () async {
        final dir = await Directory.systemTemp.createTemp('ident');
        addTearDown(() => dir.delete(recursive: true));
        final faces = BotFaceBitmapCache(directory: () async => dir);
        var imageCalls = 0;
        final photo = Uint8List.fromList(
          (await BotFaceBitmapCache.renderSpherePng('red', size: 32))!,
        );
        Future<String?> path(BotFaceIdentity id) => botFacePath(
          faces: faces,
          connId: 'c',
          profile: 'p',
          state: BotFaceBitmapState.done,
          identityFor: (_, _) => id,
          imageFor: (_, _) {
            imageCalls++;
            return photo;
          },
        );
        final sphere = await path(BotFaceIdentity.resolve(profile: 'p'));
        expect(imageCalls, 0);
        final avatar = await path(
          BotFaceIdentity.resolve(profile: 'p', paintsPhoto: true),
        );
        expect(imageCalls, 1);
        expect(sphere, isNotNull);
        expect(avatar, isNot(sphere));
      },
    );

    test('neutral glyph avatar for events without a Bot', () async {
      final png = await BotFaceBitmapCache.renderNeutralGlyphPng(size: 64);
      final corner = await _pixel(png!, .02, .02);
      final disc = await _pixel(png, .5, .2);
      expect(corner.a, 0);
      expect(disc.a, 1);
      expect(disc.computeLuminance(), lessThan(.05));
      final failed = await BotFaceBitmapCache.renderNeutralGlyphPng(
        size: 100,
        state: BotFaceBitmapState.failed,
      );
      expect(await _pixel(failed!, .16, .17), BotStateColors.failed);
    });
  });

  group('bot-owned cron routine wiring', () {
    test('job name [bot:x] marks the routine owner', () {
      final exec = CronExecutionSnapshot.fromJob({
        'id': 'j1',
        'name': '[bot:scout] Resumen diario',
        'profile': 'default',
        'latest_execution': {'id': 'e1', 'status': 'completed'},
      })!;
      expect(exec.ownerBot, 'scout');
      expect(exec.title, 'Resumen diario');
      expect(CronExecutionSnapshot.fromJson(exec.toJson())!.ownerBot, 'scout');
      final plain = CronExecutionSnapshot.fromJob({
        'id': 'j2',
        'name': 'Backup',
        'latest_execution': {'id': 'e2', 'status': 'completed'},
      })!;
      expect(plain.ownerBot, isNull);
    });

    group('delivery', () {
      sqfliteFfiInit();
      sqflite.databaseFactory = databaseFactoryFfi;
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late List<MethodCall> calls;
      late Directory dir;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('routine-');
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        calls = [];
        SharedPreferences.setMockInitialValues({
          'app_locale': 'es',
          'notif_perm_requested': true,
          'notif_background_listen': true,
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'initialize' || 'areNotificationsEnabled' => true,
            'getNotificationAppLaunchDetails' => {
              'notificationLaunchedApp': false,
              'notificationResponse': null,
            },
            _ => null,
          };
        });
      });

      tearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await dir.delete(recursive: true);
      });

      Future<(NotificationService, _Sink)> service() async {
        final prefs = await SharedPreferences.getInstance();
        final sink = _Sink();
        final s = NotificationService(
          prefs,
          deliveryStore: NotificationDeliveryStore(
            databaseFactory: databaseFactoryFfi,
            databasePath: '${dir.path}/d.db',
          ),
        )..appInForeground = false;
        s.setRichForTesting(
          sink,
          faces: BotFaceBitmapCache(directory: () async => dir),
        );
        addTearDown(s.closeDelivery);
        return (s, sink);
      }

      DurableDiscoveryNotification event({BotRoutineDisplay? routine}) =>
          DurableDiscoveryNotification(
            identity: const NotificationEventIdentity(
              connId: 'c1',
              profile: 'default',
              sourceKind: 'cron',
              objectId: 'exec.e1',
              eventKind: 'terminal',
              sourceVersion: 'e1:completed',
            ),
            destinationKind: 'cron_terminal',
            kind: NotificationKind.run,
            title: 'Rutina completada',
            body: '3 novedades',
            sessionId: 'cron_j1_1',
            botRoutine: routine,
          );

      Future<void> deliver(
        NotificationService s,
        DurableDiscoveryNotification e,
      ) => s.deliverDiscoveryBatch(
        scopeKey: 'c1/default/cron/job/x',
        connId: 'c1',
        profile: 'default',
        sourceKind: 'cron',
        objectId: 'job_x',
        lastState: 'snapshot',
        sourceVersion: 'e1:completed',
        events: [e],
        suppressByPolicy: false,
        suppressInitialEvents: false,
      );

      test(
        'a bot routine is a message from that bot, not a plain card',
        () async {
          final (s, sink) = await service();
          await deliver(
            s,
            event(
              routine: const BotRoutineDisplay(
                profile: 'scout',
                routineTitle: 'Resumen diario',
                ok: true,
                summary: '**3** novedades',
              ),
            ),
          );
          final card = sink.posts.single;
          expect(card['isGroup'], isFalse);
          final msg = (card['messages'] as List).single as Map;
          expect(msg['senderKey'], 'bot:scout');
          expect(msg['text'], 'Terminó «Resumen diario» · 3 novedades');
          expect(calls.where((c) => c.method == 'show'), isEmpty);
        },
      );

      test(
        'a non-bot cron result is a rich Hermes card with the glyph',
        () async {
          final (s, sink) = await service();
          await deliver(
            s,
            DurableDiscoveryNotification(
              identity: const NotificationEventIdentity(
                connId: 'c1',
                profile: 'default',
                sourceKind: 'cron',
                objectId: 'exec.e2',
                eventKind: 'terminal',
                sourceVersion: 'e2:failed',
              ),
              destinationKind: 'cron_terminal',
              kind: NotificationKind.run,
              title: 'Tarea programada fallida',
              body: 'x',
              sessionId: 'cron_j2_1',
              rich: NotificationService.cronRichSpec(
                t: NotifL10n.of(await SharedPreferences.getInstance()),
                title: 'Resumen de noticias',
                ok: false,
                jobId: 'j2',
              ),
            ),
          );
          final card = sink.posts.single;
          expect(card['title'], 'Resumen de noticias');
          expect(card['accent'], RichAccent.failed);
          final msg = (card['messages'] as List).single as Map;
          expect(msg['senderName'], 'Tareas programadas');
          expect(msg['text'], 'Falló · Resumen de noticias');
          expect(msg['iconPath'] as String, contains('glyph_'));
          expect(msg['iconPath'] as String, contains('failed'));
          final actions = [
            for (final a in card['actions'] as List) (a as Map)['id'],
          ];
          expect(actions, ['retry', 'open']);
          expect(
            NotificationActionPayload.tryParse(
              card['actionPayload'] as String,
            )!.route,
            NotificationActionRoute.cron,
          );
          expect(card['publicText'], 'No pudo terminar');
          expect(calls.where((c) => c.method == 'show'), isEmpty);
        },
      );
    });
  });
}

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
