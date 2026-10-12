import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/bot_identity.dart';
import 'package:hermes_android/core/bots/ui/room_avatar_tile.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/screens/mission_bot_task_sheet.dart';
import 'package:hermes_android/core/screens/mission_bot_routine_sheet.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_notification_presenter.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/widgets/bot_face_identity.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/core/widgets/room_avatar_stack.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/profile_capability_fakes.dart';
import 'support/profile_model_fakes.dart';

const _red = '#ef4444';
const _orange = '#f97316';
const _redColor = Color(0xffef4444);

AgentProfile _profile({String color = _red, bool explicit = true}) =>
    AgentProfile(
      name: 'inbox',
      botModeUiMeta: {
        'shape': 'blobatar::sun',
        'color': color,
        'imageKind': 'shape',
        if (explicit) 'useShapeColor': true,
      },
    );

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(modelApp(screen));
  await pumpModelUi(tester);
}

Future<void> _tap(
  WidgetTester tester,
  String key, {
  String form = 'bot-create-form',
}) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find
          .descendant(
            of: find.byKey(ValueKey(form)),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

HermesBotFace _face(WidgetTester tester, String key) =>
    tester.widget<HermesBotFace>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(HermesBotFace),
      ),
    );

void _expectBlobColour(WidgetTester tester, String key, String hex) {
  final visual = _face(tester, key).visual as HermesBlobatarFaceVisual;
  expect(visual.colorHex, hex);
  expect(
    visual.headColor.toARGB32(),
    0xff000000 | int.parse(hex.substring(1), radix: 16),
  );
}

Future<int> _pixelsOf(List<int> png, Color color) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
  final frame = await codec.getNextFrame();
  codec.dispose();
  final rgba = (await frame.image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!;
  frame.image.dispose();
  final argb = color.toARGB32();
  var count = 0;
  for (var i = 0; i < rgba.lengthInBytes; i += 4) {
    if (rgba.getUint8(i) == ((argb >> 16) & 255) &&
        rgba.getUint8(i + 1) == ((argb >> 8) & 255) &&
        rgba.getUint8(i + 2) == (argb & 255) &&
        rgba.getUint8(i + 3) == 255) {
      count++;
    }
  }
  return count;
}

void main() {
  test(
    'offline roster keeps the explicit colour while old dormant colours stay dormant',
    () async {
      SharedPreferences.setMockInitialValues({});
      final cache = BotRosterCache(await SharedPreferences.getInstance());
      final connection = capabilityConnection();
      await cache.write(connection, [_profile()]);
      final restored = cache.read(connection).single;
      expect(restored.botFaceColorHex, _red);
      expect(BotFaceIdentity.ofProfile(restored).visual.headColor, _redColor);
      await cache.write(connection, [_profile(explicit: false)]);
      expect(cache.read(connection).single.botFaceColorHex, isNull);
    },
  );

  testWidgets('a colour-only visual change repaints the same silhouette', (
    tester,
  ) async {
    const boundaryKey = ValueKey('face-paint');
    Widget face(String colour) => Center(
      child: RepaintBoundary(
        key: boundaryKey,
        child: HermesBotFace(
          size: 128,
          visual: HermesBlobatarFaceVisual.tryParse(
            shapeWire: 'blobatar::sun',
            profileName: 'inbox',
            colorHex: colour,
          )!,
        ),
      ),
    );
    Future<int?> count(Color colour) => tester.runAsync(() async {
      final boundary =
          tester.renderObject(find.byKey(boundaryKey)) as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return _pixelsOf(data!.buffer.asUint8List(), colour);
    });
    await _pump(tester, Scaffold(body: face(_red)));
    expect(await count(_redColor), greaterThan(500));
    await tester.pumpWidget(modelApp(Scaffold(body: face(_orange))));
    await tester.pump();
    expect(await count(_redColor), 0);
    expect(await count(const Color(0xfff97316)), greaterThan(500));
  });
  testWidgets(
    'one palette colours the selected family, its previews, random and unlocked faces, then persists it',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(
        tester,
        BotCreateScreen(
          connection: capabilityConnection(),
          existing: const {'default'},
          gateway: gateway,
          modelOptionsLoader: (_) async => const [],
        ),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('bot-create-name')),
          matching: find.byType(TextField),
        ),
        'inbox',
      );
      await tester.pump();
      expect(
        tester
            .widget<Container>(find.byKey(const ValueKey('bot-create-preview')))
            .decoration,
        isNull,
      );
      await _tap(tester, 'bot-create-identity-row');
      await _tap(tester, 'bot-create-blobatar-sun');
      await _tap(tester, 'bot-face-color-$_red');
      expect(
        find.byKey(const ValueKey('bot-face-color-palette')),
        findsOneWidget,
      );
      _expectBlobColour(tester, 'bot-create-blobatar-sun', _red);
      _expectBlobColour(tester, 'bot-create-blobatar-cloud', _red);
      expect(
        _face(tester, 'bot-face-classic-circle').visual,
        isA<HermesClassicFaceVisual>(),
      );
      expect(
        (_face(tester, 'bot-face-classic-circle').visual
                as HermesClassicFaceVisual)
            .colorHex,
        _red,
      );

      await _tap(tester, 'bot-face-classic-hexagon');
      await _tap(tester, 'bot-face-color-$_orange');
      final geometric =
          _face(tester, 'bot-face-classic-hexagon').visual
              as HermesClassicFaceVisual;
      expect(geometric.shape, 'hexagon');
      expect(geometric.colorHex, _orange);
      await _tap(tester, 'bot-create-blobatar-sun');
      await _tap(tester, 'bot-face-lock');
      expect(
        (_face(tester, 'bot-create-blobatar-sun').visual
                as HermesBlobatarFaceVisual)
            .seedPart,
        'inbox',
      );
      await _tap(tester, 'bot-face-random');
      _expectBlobColour(tester, 'bot-create-blobatar-sun', _orange);
      expect(
        (_face(tester, 'bot-create-blobatar-sun').visual
                as HermesBlobatarFaceVisual)
            .seedPart,
        isNotEmpty,
      );
      await _tap(tester, 'bot-face-lock');
      final unlocked =
          _face(tester, 'bot-create-blobatar-sun').visual
              as HermesBlobatarFaceVisual;
      expect(unlocked.shapeWire, 'blobatar::sun');
      expect(unlocked.colorHex, _orange);
      await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
      await pumpModelUi(tester);
      expect(gateway.identities, hasLength(1));
      expect(gateway.identities.single.toBotModeMetadata(), {
        'shape': 'blobatar::sun',
        'color': _orange,
        'useShapeColor': true,
        'imageKind': 'shape',
        'custom': true,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edit restores the silhouette colour and saves a change of colour alone',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(
        tester,
        ProfileEditorScreen(
          connection: capabilityConnection(),
          profile: _profile(),
          gateway: gateway,
          petService: ProfilePetService(gateway),
        ),
      );
      final save = find.byKey(const ValueKey('profile-editor-save'));
      expect(tester.widget<HermesPrimaryButton>(save).onTap, isNull);
      _expectBlobColour(tester, 'profile-editor-preview', _red);
      expect(
        find.byKey(const ValueKey('bot-face-color-palette')),
        findsNothing,
      );
      await _tap(
        tester,
        'profile-editor-identity-row',
        form: 'profile-editor-scroll',
      );
      await _tap(
        tester,
        'bot-face-color-$_orange',
        form: 'profile-editor-scroll',
      );
      expect(tester.widget<HermesPrimaryButton>(save).onTap, isNotNull);
      _expectBlobColour(tester, 'profile-editor-blobatar-sun', _orange);
      await tester.tap(save);
      await pumpModelUi(tester);
      final identity = gateway.identities.single as ProceduralFaceIdentity;
      expect(identity.shapeWire, 'blobatar::sun');
      expect(identity.dormantColorHex, _orange);
      expect(identity.useShapeColor, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'face choices and the one palette have 48 dp targets at 320 dp and double text',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(
        tester,
        ProfileEditorScreen(
          connection: capabilityConnection(),
          profile: _profile(),
          gateway: gateway,
          petService: ProfilePetService(gateway),
        ),
        width: 320,
        scale: 2,
      );
      await _tap(
        tester,
        'profile-editor-identity-row',
        form: 'profile-editor-scroll',
      );
      await _tap(
        tester,
        'bot-face-color-$_orange',
        form: 'profile-editor-scroll',
      );
      for (final key in [
        'bot-face-color-$_orange',
        'profile-editor-blobatar-sun',
        'bot-face-classic-circle',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      expect(
        find.byKey(const ValueKey('bot-face-color-palette')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Home, profile rows and both room renderers honour a restored silhouette colour',
    (tester) async {
      final profile = _profile();
      await _pump(
        tester,
        Scaffold(
          body: Column(
            children: [
              LivingBotFace(
                key: const ValueKey('home-face'),
                profileName: 'inbox',
                profile: profile,
                signal: BotFaceSignal.idle,
                animate: false,
                entrance: false,
              ),
              ProfileFace(
                key: const ValueKey('profile-row'),
                profileName: 'inbox',
                profile: profile,
              ),
              RoomAvatarTile(
                key: const ValueKey('room-tile'),
                members: [RoomAvatarTileMember('inbox', profile)],
                avatarCache: null,
              ),
              RoomAvatarStack(
                key: const ValueKey('room-stack'),
                connectionId: 'test',
                profiles: [profile],
              ),
            ],
          ),
        ),
      );
      for (final key in [
        'home-face',
        'profile-row',
        'room-tile',
        'room-stack',
      ]) {
        _expectBlobColour(tester, key, _red);
      }
      expect(botIdentityColor(profile), _redColor);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task and routine identity rows support the colour without changing legacy faces',
    (tester) async {
      for (final explicit in [false, true]) {
        for (final sheet in [
          MissionBotTaskSheet(
            profileName: 'inbox',
            displayName: 'Inbox',
            onSubmit: (_) async {},
            botShape: 'blobatar::sun',
            botColorHex: _red,
            botUsesShapeColor: explicit,
          ),
          MissionBotRoutineSheet(
            botProfile: 'inbox',
            onCreate: (_) async {},
            botShape: 'blobatar::sun',
            botColorHex: _red,
            botUsesShapeColor: explicit,
          ),
        ]) {
          await _pump(tester, Scaffold(body: sheet));
          final visual =
              tester.widget<HermesBotFace>(find.byType(HermesBotFace)).visual
                  as HermesBlobatarFaceVisual;
          expect(visual.colorHex, explicit ? _red : null);
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets(
    'notification and launcher bitmaps paint the actual colour, including state poses',
    (tester) async {
      final identity = BotFaceIdentity.ofProfile(_profile());
      final old = BotFaceIdentity.ofProfile(_profile(explicit: false));
      expect(old.visual.colorHex, isNull);
      expect(identity.cacheKey, isNot(old.cacheKey));
      expect(identity.visual.headColor, _redColor);
      expect(botAccent(identity), _redColor.toARGB32());
      for (final state in [
        BotFaceBitmapState.idle,
        BotFaceBitmapState.working,
        BotFaceBitmapState.done,
      ]) {
        final count = await tester.runAsync(() async {
          final png = (await BotFaceBitmapCache.renderIdentityPng(
            identity,
            state: state,
            size: 128,
            plate: false,
          ))!;
          return _pixelsOf(png, _redColor);
        });
        expect(count, greaterThan(500));
      }
    },
  );
}
