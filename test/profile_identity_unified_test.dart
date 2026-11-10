// One visual identity per profile (1.4.0 «pfu»): a profile with a character
// saved in the Studio is drawn with THAT character in every list of profiles
// (Perfiles, the switcher, the profile hub) and by every avatar component
// (Bots and Inicio faces, drawer and sheet faces), because they all go
// through one resolver. The Perfiles list used its own avatar cache with no
// connection id, so it looked the character up under '|name' and never found
// it: it painted the seeded face instead.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_hub_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/characters/character_face.dart';
import 'package:hermes_android/core/characters/profile_identity_resolver.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/core/widgets/profile_switcher.dart';

import 'support/bot_roster_fakes.dart';
import 'support/nav_harness.dart';
import 'support/profile_model_fakes.dart';

final _forja = BotCharacter.fresh.copyWith(fur: true, gradient: 'bay');

/// The character painted for [name] inside [scope], or null.
CharacterFace? _character(WidgetTester tester, Finder scope, String name) {
  final found = find.descendant(
    of: scope,
    matching: find.byWidgetPredicate(
      (w) => w is CharacterFace && w.profileName == name,
    ),
  );
  if (found.evaluate().isEmpty) return null;
  return tester.widget<CharacterFace>(found.first);
}

void main() {
  late SavedConnection conn;
  late ConnectionManager manager;
  late BotRosterRegistry registry;

  setUp(() async {
    conn = navConnection();
    manager = await navManager();
    registry = navRoster(conn);
    BotCharacterStore.debugUse(BotCharacterStore.detached());
    ProfileFace.debugResetAvatarCaches();
    await BotCharacterStore.shared.save(conn.id, navSecondary, _forja);
  });
  tearDown(() {
    BotCharacterStore.debugUse(null);
    ProfileFace.debugResetAvatarCaches();
  });

  group('the resolver', () {
    test('a saved character is found only under its own connection', () {
      final withConn = resolveProfileIdentity(
        profileName: navSecondary,
        connectionId: conn.id,
      );
      expect(withConn.source, ProfileIdentitySource.character);
      expect(withConn.character, _forja);
      // The bug of Perfiles: no connection, no character.
      final without = resolveProfileIdentity(profileName: navSecondary);
      expect(without.source, ProfileIdentitySource.face);
    });

    test('a profile without a character keeps the seeded face', () {
      final other = resolveProfileIdentity(
        profileName: 'default',
        connectionId: conn.id,
      );
      expect(other.source, ProfileIdentitySource.face);
    });

    test('a photo wins over the character when it can be read', () {
      const photo = AgentProfile(
        name: navSecondary,
        hasAvatar: true,
        botModeUiMeta: {'imageKind': 'photo'},
      );
      expect(
        resolveProfileIdentity(
          profileName: navSecondary,
          connectionId: conn.id,
          profile: photo,
        ).source,
        ProfileIdentitySource.photo,
      );
      expect(
        resolveProfileIdentity(
          profileName: navSecondary,
          connectionId: conn.id,
          profile: photo,
          canLoadPhoto: false,
        ).source,
        ProfileIdentitySource.character,
      );
    });
  });

  group('every list and component paints the saved character', () {
    testWidgets('Perfiles', (tester) async {
      navView(tester);
      await tester.pumpWidget(
        navApp(
          ProfilesScreen(
            connection: conn,
            connManager: manager,
            rosterRegistry: registry,
            clientOverride: FakeProfilesServer().client,
            gatewayProfilesOverride: () async =>
                registry.store(conn.id).profiles,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final row = find.byKey(const ValueKey('profile-row-$navSecondary'));
      expect(_character(tester, row, navSecondary)?.character, _forja);
      // The profile without a character keeps its seeded face.
      expect(
        _character(
          tester,
          find.byKey(const ValueKey('profile-row-default')),
          'default',
        ),
        isNull,
      );
    });

    testWidgets('the profile hub', (tester) async {
      navView(tester);
      final gateway = FakeModelGateway();
      await tester.pumpWidget(
        navApp(
          ProfileHubScreen(
            connection: conn,
            connManager: manager,
            profile: navSecondary,
            rosterRegistry: registry,
            modelGateway: gateway,
            profileGateway: gateway,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _character(
          tester,
          find.byType(ProfileHubScreen),
          navSecondary,
        )?.character,
        _forja,
      );
    });

    testWidgets('the profile switcher', (tester) async {
      navView(tester);
      late BuildContext context;
      await tester.pumpWidget(
        navApp(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      unawaited(
        showProfileSwitcher(
          context,
          connection: conn,
          connManager: manager,
          rosterRegistry: registry,
          avatarLoader: (_) async => null,
          readRoster: () async => registry.store(conn.id).profiles,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _character(
          tester,
          find.byKey(const ValueKey('profile-switcher-sheet')),
          navSecondary,
        )?.character,
        _forja,
      );
    });

    testWidgets('ProfileFace, MissionProfileAvatar and LivingBotFace', (
      tester,
    ) async {
      navView(tester);
      final cache = ProfileFace.cacheFor(
        conn,
        rosterTicket: 1,
        loader: (_) async => null,
      );
      final profile = registry
          .store(conn.id)
          .profiles
          .singleWhere((p) => p.name == navSecondary);
      await tester.pumpWidget(
        navApp(
          Column(
            children: [
              ProfileFace(
                key: const ValueKey('face-a'),
                profileName: navSecondary,
                profile: profile,
                avatarCache: cache,
                connectionId: conn.id,
              ),
              MissionProfileAvatar(
                key: const ValueKey('face-b'),
                profileName: navSecondary,
                hasAvatar: false,
                cache: cache,
              ),
              // A surface that only knows the connection (no cache) too.
              MissionProfileAvatar(
                key: const ValueKey('face-c'),
                profileName: navSecondary,
                hasAvatar: false,
                cache: null,
                connectionId: conn.id,
              ),
              LivingBotFace(
                key: const ValueKey('face-d'),
                profileName: navSecondary,
                profile: profile,
                avatarCache: cache,
                signal: BotFaceSignal.idle,
                animate: false,
                entrance: false,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      for (final key in ['face-a', 'face-b', 'face-c', 'face-d']) {
        expect(
          _character(
            tester,
            find.byKey(ValueKey(key)),
            navSecondary,
          )?.character,
          _forja,
          reason: key,
        );
      }
    });
  });
}
