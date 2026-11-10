// The publisher of the launcher widget pictures: it draws what Android
// placed, at its sizes, writes the files and the manifest, prunes what is
// no longer placed, and asks only the placed receivers to redraw.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_images.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_raster.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/models/launcher_widget_chats.dart';
import 'package:hermes_android/core/models/launcher_widget_cron.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'launcher_widget_fixtures.dart';

class _Store implements LauncherWidgetImageStore {
  _Store(this.dir);
  final Directory dir;
  final values = <String, String>{};
  final redraws = <List<String>>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> redraw(Iterable<String> providers) async =>
      redraws.add(providers.toList());

  @override
  Future<Directory> directory() async => dir;
}

LauncherWidgetImageEnvironment _env({double textScale = 1}) =>
    LauncherWidgetImageEnvironment(
      colors: () => AppTheme.presetById('console').colors,
      fontFamily: () => 'Inter',
      locale: () => const ui.Locale('es'),
      textScale: () => textScale,
      devicePixelRatio: () => 3,
      use24h: () => true,
      themeId: () => 'console',
    );

String _sizes(
  Map<String, List<List<int>>> sizes, {
  double density = 2.0,
  double fontScale = 1.0,
}) => jsonEncode({
  'v': 1,
  'density': density,
  'font_scale': fontScale,
  'locale': 'es-ES',
  'sizes': sizes,
});

const _everyReceiver = [
  'com.hermesagent.hermes_android.NewSessionWidgetProvider',
  'com.hermesagent.hermes_android.HermesCompactWidgetProvider',
  'com.hermesagent.hermes_android.HermesControlWidgetProvider',
  'com.hermesagent.hermes_android.HermesCronWidgetProvider',
  'com.hermesagent.hermes_android.HermesTasksWidgetProvider',
  'com.hermesagent.hermes_android.HermesChatsWidgetProvider',
];

class _ThrowingStore extends _Store {
  _ThrowingStore(super.dir);

  @override
  Future<Directory> directory() async =>
      throw const FileSystemException('no room');
}

void main() {
  late Directory tmp;
  late _Store store;
  late LauncherWidgetImagePublisher publisher;

  setUpAll(lwLoadFonts);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lw-images');
    store = _Store(tmp);
    publisher = LauncherWidgetImagePublisher(
      store: store,
      nowMs: () => lwNow,
      strings: lookupStrings,
    );
    final chat = HermesHomeWidgetSnapshot(
      configured: true,
      instanceId: 'home',
      instanceLabel: 'Casa',
      connectionState: HomeWidgetConnectionState.connected,
      agentState: HomeWidgetAgentState.waitingApproval,
      sessionId: 's1',
      sessionTitle: 'Viaje a Lisboa',
      updatedAtMs: lwMinutesAgo(1),
      active: [
        HomeWidgetChatActivity(
          sessionId: 's1',
          state: HomeWidgetAgentState.waitingApproval,
          title: 'Viaje a Lisboa',
          profile: 'nova',
          startedAtMs: lwMinutesAgo(2),
          need: const HomeWidgetNeed(
            requestId: 'r1',
            text: 'Ejecutar un comando',
            actionPayload: 'pay',
          ),
        ),
      ],
    );
    store.values[HermesHomeWidgetSnapshot.atomicStorageKey] = chat
        .toAtomicStorageValue();
    store.values[LauncherWidgetCronSnapshot.storageKey] =
        LauncherWidgetCronSnapshot(
          connectionId: 'home',
          updatedAtMs: lwMinutesAgo(3),
          jobs: [
            LauncherWidgetCronJob(
              id: 'j',
              name: 'Resumen diario',
              profile: 'default',
              nextRunAtMs: lwIn(60),
              openPayload: 'open-j',
            ),
          ],
        ).encode();
    store.values[LauncherWidgetChatsSnapshot.storageKey] =
        LauncherWidgetChatsSnapshot(
          connectionId: 'home',
          updatedAtMs: lwMinutesAgo(2),
          chats: [
            LauncherWidgetChat(
              id: 's1',
              title: 'Viaje a Lisboa',
              line: 'Hola',
              atMs: lwMinutesAgo(5),
              profile: 'nova',
            ),
          ],
        ).encode();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('without an environment the caller redraws itself', () async {
    // request() says no: the snapshot writer redraws its receivers.
    expect(publisher.request(), isFalse);
    expect(store.redraws, isEmpty);
  });

  test(
    'without placed widgets nothing is drawn, yet every receiver redraws',
    () async {
      // The snapshot that asked is stored: the receivers draw it natively and
      // tell their sizes on the way, so the next run has them.
      publisher.configure(_env());
      expect((await publisher.publishOnce()).skipped, 'no placed widgets');
      expect(store.redraws.single, unorderedEquals(_everyReceiver));
      store.values[lwSizesKey] = 'not json';
      expect((await publisher.publishOnce()).skipped, 'no placed widgets');
      expect(store.redraws.length, 2);
      expect(store.values.containsKey(lwImagesKey), isFalse);
    },
  );

  test('a failed run still redraws every receiver', () async {
    final failing = _ThrowingStore(tmp)..values.addAll(store.values);
    failing.values[lwSizesKey] = _sizes({
      'ahora': [
        [320, 170],
      ],
    });
    final p = LauncherWidgetImagePublisher(
      store: failing,
      nowMs: () => lwNow,
      strings: lookupStrings,
    )..configure(_env());
    expect(p.request(), isTrue);
    await p.flush();
    expect(failing.redraws.single, unorderedEquals(_everyReceiver));
    expect(failing.values.containsKey(lwImagesKey), isFalse);
  });

  test("the font scale Android reports wins over the engine's", () async {
    // Android shows a picture only when it was set at its own font scale.
    publisher.configure(_env(textScale: 1.0));
    store.values[lwSizesKey] = _sizes({
      'new': [
        [160, 170],
      ],
    }, fontScale: 1.3);
    await publisher.publishOnce();
    var manifest =
        jsonDecode(store.values[lwImagesKey]!) as Map<String, dynamic>;
    expect(manifest['font_scale'], 1.3);
    // Not told: the engine's.
    store.values[lwSizesKey] = jsonEncode({
      'v': 1,
      'density': 2.0,
      'sizes': {
        'new': [
          [160, 170],
        ],
      },
    });
    publisher.configure(_env(textScale: 1.15));
    await publisher.publishOnce();
    manifest = jsonDecode(store.values[lwImagesKey]!) as Map<String, dynamic>;
    expect(manifest['font_scale'], 1.15);
  });

  test(
    'one picture per placed size, at its pixel size, with zones and words',
    () async {
      publisher.configure(_env());
      store.values[lwSizesKey] = _sizes({
        'ahora': [
          [320, 170],
          [160, 170],
        ],
        'cron': [
          [160, 170],
        ],
        'bogus': [
          [160, 170],
        ],
      });
      final report = await publisher.publishOnce();
      expect(report.skipped, isNull);
      expect(report.images.map((i) => i.key), [
        'ahora:320x170',
        'ahora:160x170',
        'cron:160x170',
      ]);
      for (final image in report.images) {
        final file = File(image.path);
        expect(file.existsSync(), isTrue);
        final bytes = await file.readAsBytes();
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        expect(image.widthPx, (image.sizeDp.width * 2).round());
        expect(image.heightPx, (image.sizeDp.height * 2).round());
        expect(image.description, isNotEmpty);
        expect(image.zones, isNotEmpty);
      }
      final ahora = report.images.first;
      expect(
        ahora.description,
        'Nova necesita tu permiso: Ejecutar un comando',
      );
      expect(
        ahora.zones.map((z) => z.kind.name),
        containsAll(['session', 'approve', 'deny']),
      );
      final manifest =
          jsonDecode(store.values[lwImagesKey]!) as Map<String, dynamic>;
      expect(manifest['v'], lwImagesSchema);
      expect(manifest['stamp_ms'], lwNow);
      // The newest snapshot drawn: the chat's.
      expect(manifest['sources_ms'], lwMinutesAgo(1));
      expect(manifest['density'], 2.0);
      expect(manifest['font_scale'], 1.0);
      expect(manifest['locale'], 'es');
      final images = manifest['images'] as Map<String, dynamic>;
      expect(
        images.keys,
        containsAll(['ahora:320x170', 'ahora:160x170', 'cron:160x170']),
      );
      final entry = images['ahora:320x170'] as Map<String, dynamic>;
      expect(entry['dp_w'], 320);
      expect(entry['w'], 640);
      expect(entry['valid_until_ms'], lwMinutesAgo(1) + 15 * 60 * 1000 + 1);
      final zones = entry['zones'] as List;
      final approve = zones.firstWhere((z) => z['kind'] == 'approve') as Map;
      expect(approve['payload'], 'pay');
      expect(approve['label'], 'Permitir a Nova');
      expect(approve['r'], greaterThan(approve['l']));
      // Only the placed subjects' receivers are asked to redraw.
      expect(store.redraws.single, [
        'com.hermesagent.hermes_android.NewSessionWidgetProvider',
        'com.hermesagent.hermes_android.HermesCronWidgetProvider',
      ]);
    },
  );

  test(
    'publication uses roster names and connection-scoped characters',
    () async {
      publisher.configure(_env());
      store.values[lwSizesKey] = _sizes({
        'ahora': [
          [320, 170],
        ],
        'chats': [
          [320, 170],
        ],
      });
      BotCharacterStore.debugUse(BotCharacterStore.detached());
      try {
        final before = await publisher.publishOnce();
        final previous = {
          for (final image in before.images)
            image.subject: await File(image.path).readAsBytes(),
        };
        BotRosterRegistry.shared.publish('home', '', [
          const AgentProfile(
            name: 'nova',
            botModeUiMeta: {'title': 'Visible agent'},
          ),
        ]);
        await BotCharacterStore.shared.save(
          'home',
          'nova',
          BotCharacter.fresh.copyWith(fur: true, gradient: 'bay'),
        );
        final after = await publisher.publishOnce();
        expect(after.images.first.description, contains('Visible agent'));
        for (final image in after.images) {
          expect(
            await File(image.path).readAsBytes(),
            isNot(orderedEquals(previous[image.subject]!)),
          );
        }
      } finally {
        BotRosterRegistry.shared.forget('home');
        BotCharacterStore.debugUse(null);
      }
    },
  );

  test('a size no longer placed loses its file', () async {
    publisher.configure(_env());
    store.values[lwSizesKey] = _sizes({
      'ahora': [
        [320, 170],
        [160, 170],
      ],
    });
    await publisher.publishOnce();
    expect(tmp.listSync().length, 2);
    store.values[lwSizesKey] = _sizes({
      'ahora': [
        [320, 170],
      ],
    });
    final report = await publisher.publishOnce();
    expect(report.images.single.key, 'ahora:320x170');
    expect(tmp.listSync().map((f) => f.uri.pathSegments.last), [
      'lw_ahora_320x170.png',
    ]);
  });

  test('requests coalesce into one run after the current one', () async {
    publisher.configure(_env());
    store.values[lwSizesKey] = _sizes({
      'new': [
        [160, 72],
      ],
    });
    expect(publisher.request(), isTrue);
    expect(publisher.request(), isTrue);
    expect(publisher.request(), isTrue);
    await publisher.flush();
    expect(store.redraws.length, lessThanOrEqualTo(2));
    expect(publisher.last!.images.single.key, 'new:160x72');
  });

  test(
    'the density Android reports wins; the picture never exceeds the pixel cap',
    () async {
      publisher.configure(_env());
      store.values[lwSizesKey] = _sizes({
        'tasks': [
          [420, 470],
        ],
      }, density: 4.0);
      final report = await publisher.publishOnce();
      final image = report.images.single;
      expect(image.widthPx * image.heightPx, lessThanOrEqualTo(lwMaxPixels));
      expect(image.widthPx, lessThan(420 * 4));
      expect(lwRenderScale(const ui.Size(320, 170), 3), 3);
      expect(lwRenderScale(const ui.Size(420, 470), 4), lessThan(4));
    },
  );

  test('the sizes manifest is read defensively', () {
    expect(LwSizeManifest.parse(null), isNull);
    expect(LwSizeManifest.parse('{"v":2}'), isNull);
    final m = LwSizeManifest.parse(
      jsonEncode({
        'v': 1,
        'density': 2.75,
        'font_scale': 1.3,
        'sizes': {
          'ahora': [
            [320, 170],
            [320, 170],
            [10, 10],
            ['a', 'b'],
          ],
          'nope': [
            [1, 1],
          ],
        },
      }),
    )!;
    expect(m.density, 2.75);
    expect(m.fontScale, 1.3);
    expect(m.sizes.keys.map((s) => s.key), ['ahora']);
    expect(m.sizes.values.single, [const ui.Size(320, 170)]);
  });
}
