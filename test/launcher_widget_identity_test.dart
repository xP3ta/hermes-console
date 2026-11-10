import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_identity.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_painter.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_raster.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_scene.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/models/launcher_widget_chats.dart';
import 'package:hermes_android/core/models/launcher_widget_cron.dart';
import 'package:hermes_android/core/models/launcher_widget_tasks.dart';
import 'package:hermes_android/core/models/profile_identity.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';

import 'launcher_widget_fixtures.dart';

const _connection = 'widget-identity-test';
const _name = 'default';
const _profile = AgentProfile(name: _name, displayName: 'Primary agent');

HermesHomeWidgetSnapshot _chat({bool active = true}) =>
    HermesHomeWidgetSnapshot(
      configured: true,
      instanceId: _connection,
      connectionState: HomeWidgetConnectionState.connected,
      agentState: HomeWidgetAgentState.waitingApproval,
      updatedAtMs: lwNow,
      active: active
          ? [
              const HomeWidgetChatActivity(
                sessionId: 's',
                profile: _name,
                state: HomeWidgetAgentState.waitingApproval,
              ),
            ]
          : const [],
    );

Companion _pet(String path) => Companion(
  slug: 'test',
  name: 'Test sprite',
  author: '',
  license: '',
  spritesheetAsset: path,
  frameWidth: 32,
  frameHeight: 32,
  cols: 2,
  rows: 2,
  fps: 1,
  origin: CompanionOrigin.imported,
  states: const {
    CompanionAnimationState.idle: RowSpec(row: 1, frameCount: 2, loop: true),
  },
);

Future<Uint8List> _sprite() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFFFF0000), ui.BlendMode.src);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 32, 32, 32),
    ui.Paint()..color = const ui.Color(0xFF00FF00),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(32, 32, 32, 32),
    ui.Paint()..color = const ui.Color(0xFF0000FF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _render(LwAvatar avatar) async {
  final frame = paintLauncherWidget(
    LwPaintRequest(
      subject: LwSubject.ahora,
      scene: LwAhoraScene.from(_chat(), nowMs: lwNow, agentName: 'Agent'),
      sizeDp: const ui.Size(320, 160),
      palette: lwThemes.first.palette,
      words: lwWords('es'),
      fontScale: 1,
      avatars: {_name: avatar},
    ),
  );
  try {
    final rendered = (await lwRenderPng(frame, density: 1))!;
    expect(rendered.png.length, greaterThan(100));
    expect(
      rendered.widthPx * rendered.heightPx,
      lessThanOrEqualTo(lwMaxPixels),
    );
    return rendered.png;
  } finally {
    frame.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(lwLoadFonts);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('widget-identity');
    BotRosterRegistry.shared.forget(_connection);
    BotCharacterStore.debugUse(BotCharacterStore.detached());
    ProfileIdentities.instance.reset();
  });
  tearDown(() async {
    BotRosterRegistry.shared.forget(_connection);
    BotCharacterStore.debugUse(null);
    ProfileIdentities.instance.reset();
    await temp.delete(recursive: true);
  });

  test('roster list names win in every scene, scoped to the connection', () {
    expect(lwProfileName(_connection, _name, fallback: 'Agent'), 'Agent');
    expect(lwProfileName(_connection, 'nova'), 'Nova');
    BotRosterRegistry.shared.publish(_connection, '', [_profile]);
    expect(lwProfileName(_connection, _name), 'Primary agent');
    expect(lwProfileName('other', _name, fallback: 'Agent'), 'Agent');
    final scene = LwAhoraScene.from(_chat(), nowMs: lwNow, agentName: 'Agent');
    expect(scene.needs.single.who, 'Primary agent');
    expect(scene.agentName, 'Primary agent');
    expect(scene.faces.single.name, 'Primary agent');
    expect(
      LwAhoraScene.from(
        _chat(active: false),
        nowMs: lwNow,
        agentName: 'Agent',
      ).needs.single.who,
      'Primary agent',
    );
    expect(
      LwChatsScene.from(
        LauncherWidgetChatsSnapshot(
          connectionId: _connection,
          updatedAtMs: lwNow,
          chats: const [
            LauncherWidgetChat(id: 's', title: 'Chat', profile: _name),
          ],
        ),
        _chat(),
        nowMs: lwNow,
      ).rows.single.who,
      'Primary agent',
    );
    expect(
      LwCronScene.from(
        LauncherWidgetCronSnapshot(
          connectionId: _connection,
          updatedAtMs: lwNow,
          jobs: const [
            LauncherWidgetCronJob(id: 'j', name: 'Job', profile: _name),
          ],
        ),
        nowMs: lwNow,
      ).jobs.single.who,
      'Primary agent',
    );
    expect(
      LwTasksScene.from(
        LauncherWidgetTasksSnapshot(
          connectionId: _connection,
          updatedAtMs: lwNow,
          runningCount: 1,
          tasks: const [
            LauncherWidgetTask(
              id: 't',
              title: 'Task',
              state: LauncherWidgetTaskState.running,
              assignee: _name,
            ),
          ],
        ),
        nowMs: lwNow,
      ).firstAssignee,
      'Primary agent',
    );
  });

  test(
    'pet, cached photo, character and sphere draw distinct widget images',
    () async {
      final avatars = <LwAvatar>[];
      final cache = MissionProfileAvatarCache(
        connectionId: _connection,
        loader: (_) async =>
            AgentProfileAvatar(mimeType: 'image/png', bytes: await _sprite()),
      );
      try {
        avatars.add(await lwLoadAvatar(_connection, _name));
        await BotCharacterStore.shared.save(
          _connection,
          _name,
          BotCharacter.fresh.copyWith(fur: true, gradient: 'bay'),
        );
        avatars.add(await lwLoadAvatar(_connection, _name));
        BotRosterRegistry.shared.publish(_connection, '', [
          const AgentProfile(
            name: _name,
            hasAvatar: true,
            botModeUiMeta: {'imageKind': 'photo'},
          ),
        ]);
        await cache.load(_name);
        avatars.add(await lwLoadAvatar(_connection, _name));
        final file = File('${temp.path}/sprite.png');
        await file.writeAsBytes(await _sprite());
        ProfileIdentities.instance.publish(_connection, _name, _pet(file.path));
        avatars.add(await lwLoadAvatar(_connection, _name));
        expect(avatars[1].character, isNotNull);
        expect(avatars[2].image, isNotNull);
        expect(avatars[3].image, isNotNull);
        expect(avatars[3].image!.width, 32);
        final pixels = await avatars[3].image!.toByteData();
        expect(
          pixels!.getUint32(0),
          0x00FF00FF,
          reason: 'First idle cell only',
        );
        final images = <Uint8List>[];
        for (final avatar in avatars) {
          images.add(await _render(avatar));
        }
        for (var i = 0; i < images.length; i++) {
          for (var j = i + 1; j < images.length; j++) {
            expect(images[i], isNot(orderedEquals(images[j])));
          }
        }
      } finally {
        cache.clear();
        for (final avatar in avatars) {
          avatar.dispose();
        }
      }
    },
  );

  test(
    'missing photo cache chooses the character; failed loads use sphere',
    () async {
      BotRosterRegistry.shared.publish(_connection, '', [
        const AgentProfile(
          name: _name,
          hasAvatar: true,
          botModeUiMeta: {'imageKind': 'photo'},
        ),
      ]);
      await BotCharacterStore.shared.save(
        _connection,
        _name,
        BotCharacter.fresh,
      );
      final character = await lwLoadAvatar(_connection, _name);
      expect(character.character, isNotNull);
      character.dispose();
      final sphere = await lwLoadAvatar('unknown', _name);
      final baseline = await _render(sphere);
      sphere.dispose();
      ProfileIdentities.instance.publish(
        _connection,
        _name,
        _pet('${temp.path}/missing.png'),
      );
      final failed = await lwLoadAvatar(_connection, _name);
      expect(failed.image, isNull);
      expect(failed.character, isNull);
      expect(await _render(failed), orderedEquals(baseline));
      failed.dispose();
      final unscoped = await lwLoadAvatar(null, _name);
      expect(unscoped.character, isNull);
      expect(unscoped.image, isNull);
      unscoped.dispose();
    },
  );
  test(
    'invalid cached bytes fail to sphere without another photo request',
    () async {
      BotRosterRegistry.shared.publish(_connection, '', [
        const AgentProfile(
          name: _name,
          hasAvatar: true,
          botModeUiMeta: {'imageKind': 'photo'},
        ),
      ]);
      var loads = 0;
      final cache = MissionProfileAvatarCache(
        connectionId: _connection,
        loader: (_) async {
          loads++;
          return AgentProfileAvatar(
            mimeType: 'image/png',
            bytes: Uint8List.fromList([1, 2, 3]),
          );
        },
      );
      final uncached = await lwLoadAvatar(_connection, _name);
      expect(loads, 0);
      final baseline = await _render(uncached);
      uncached.dispose();
      await cache.load(_name);
      final failed = await lwLoadAvatar(_connection, _name);
      try {
        expect(loads, 1);
        expect(failed.image, isNull);
        expect(await _render(failed), orderedEquals(baseline));
      } finally {
        failed.dispose();
        cache.clear();
      }
    },
  );
  test(
    'configured sphere keeps its color and legacy characters use their painter',
    () async {
      final plain = await lwLoadAvatar(_connection, _name);
      final baseline = await _render(plain);
      plain.dispose();
      BotRosterRegistry.shared.publish(_connection, '', [
        const AgentProfile(name: _name, botModeUiMeta: {'color': '#46c49f'}),
      ]);
      final configured = await lwLoadAvatar(_connection, _name);
      try {
        expect(configured.fallback.sphere, 'teal');
        expect(await _render(configured), isNot(orderedEquals(baseline)));
      } finally {
        configured.dispose();
      }
      await BotCharacterStore.shared.save(
        _connection,
        _name,
        BotCharacter.standard.copyWith(topper: BotCharacterTopper.sprout),
      );
      final legacy = await lwLoadAvatar(_connection, _name);
      try {
        expect(legacy.character!.isStudio, isFalse);
        expect(await _render(legacy), isNot(orderedEquals(baseline)));
      } finally {
        legacy.dispose();
      }
    },
  );

  test('a list of another instance takes no live state from the chat', () {
    LwChatsScene chats(String connectionId) => LwChatsScene.from(
      LauncherWidgetChatsSnapshot(
        connectionId: connectionId,
        updatedAtMs: lwNow,
        chats: const [LauncherWidgetChat(id: 's', title: 'Chat')],
      ),
      _chat(),
      nowMs: lwNow,
    );
    final same = chats(_connection);
    expect(same.rows.single.waits, isTrue);
    expect(same.waiting, 1);
    final other = chats('another-connection');
    expect(other.rows.single.waits, isFalse);
    expect(other.rows.single.running, isFalse);
    expect(other.waiting, 0);
  });

  test('decoded photos stay within the avatar pixel budget', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF00FF00), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2048, 128);
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
    BotRosterRegistry.shared.publish(_connection, '', [
      const AgentProfile(
        name: _name,
        hasAvatar: true,
        botModeUiMeta: {'imageKind': 'photo'},
      ),
    ]);
    final cache = MissionProfileAvatarCache(
      connectionId: _connection,
      loader: (_) async =>
          AgentProfileAvatar(mimeType: 'image/png', bytes: bytes),
    );
    await cache.load(_name);
    final avatar = await lwLoadAvatar(_connection, _name);
    try {
      expect(avatar.image!.width, lwAvatarEdge);
      expect(avatar.image!.height, lessThanOrEqualTo(lwAvatarEdge));
      await _render(avatar);
    } finally {
      avatar.dispose();
      cache.clear();
    }
  });
}
