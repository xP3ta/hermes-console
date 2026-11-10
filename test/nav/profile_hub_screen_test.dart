// The profile of a bot (1.4.0): everything that is of THAT bot in one page.
// The suite opens the hub of a secondary profile while the active one is the
// main profile, so a screen that quietly followed the active profile would
// show or write `default` and fail here.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_hub_screen.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/screens/activity_screen.dart';
import 'package:hermes_android/core/screens/artifacts_screen.dart';
import 'package:hermes_android/core/screens/backup_restore_screen.dart';
import 'package:hermes_android/core/screens/bot_profile_settings_screen.dart';
import 'package:hermes_android/core/screens/characters/character_studio_screen.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/env_keys_screen.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/screens/soul_screen.dart';
import 'package:hermes_android/core/screens/task_center_screen.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/screens/usage_analytics_screen.dart';
import 'package:hermes_android/core/screens/vault_screen.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ssh_profile_presence.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/owned_resource_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/nav_harness.dart';
import '../support/profile_model_fakes.dart';

class _Rig {
  _Rig(this.manager, this.gateway, this.registry, this.connection);

  final ConnectionManager manager;
  final FakeModelGateway gateway;
  final BotRosterRegistry registry;
  final SavedConnection connection;
}

Future<_Rig> _pump(
  WidgetTester tester, {
  String profile = navSecondary,
  ConnectionManager? manager,
  VoidCallback? onChat,
  VoidCallback? onOpenBotCard,
  CapabilitiesSnapshotCache? cache,
  bool ssh = false,
  bool readOnly = false,
  bool editorSaves = false,
  VoidCallback? onEdited,
  Locale locale = const Locale('es'),
  Size size = const Size(390, 1800),
  double scale = 1,
}) async {
  navView(tester, size: size, scale: scale);
  final connection = navConnection(readOnly: readOnly);
  final resolved = manager ?? await navManager();
  final gateway = FakeModelGateway();
  final registry = navRoster(connection);
  SshProfilePresence.instance.value = ssh;
  addTearDown(() => SshProfilePresence.instance.value = false);
  await tester.pumpWidget(
    navApp(
      ProfileHubScreen(
        connection: connection,
        connManager: resolved,
        profile: profile,
        rosterRegistry: registry,
        modelGateway: gateway,
        profileGateway: gateway,
        capabilitiesCache: cache ?? CapabilitiesSnapshotCache(),
        onChat: onChat,
        onOpenBotCard: onOpenBotCard,
        onEdited: onEdited,
        editorBuilder: (context, edited) => Scaffold(
          body: Column(
            children: [
              Text('editor:${edited.name}', key: const ValueKey('stub-editor')),
              TextButton(
                key: const ValueKey('stub-editor-save'),
                onPressed: () => Navigator.of(context).pop(editorSaves),
                child: const Text('save'),
              ),
            ],
          ),
        ),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return _Rig(resolved, gateway, registry, connection);
}

Finder _row(String id) => find.byKey(ValueKey('tool-$id'));

Future<void> _openAdvanced(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('profile-hub-advanced'));
  // The list builds lazily: scroll down to it first.
  await tester.scrollUntilVisible(
    toggle,
    200,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('profile-hub-list')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pump();
}

/// The hub's own entries, read from its state with the context it shows them
/// in (the screens are built, never mounted: they need a server).
List<ProfileHubEntry> _entries(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(ProfileHubScreen));
  return (state.entries(tester.element(find.byType(ProfileHubScreen)))
          as List<dynamic>)
      .cast<ProfileHubEntry>();
}

Widget _built(WidgetTester tester, List<ProfileHubEntry> entries, String id) =>
    entries
        .singleWhere((e) => e.destination.id == id)
        .destination
        .builder(tester.element(find.byType(ProfileHubScreen)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('header', () {
    testWidgets('shows the avatar, name and description of the profile it '
        'opens, not of the active one', (tester) async {
      await _pump(tester);
      expect(find.byKey(const ValueKey('profile-hub-avatar')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('profile-hub-name')))
            .data,
        navSecondary,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('profile-hub-description')))
            .data,
        'Revisa pull requests y mantiene el changelog',
      );
      // It is not the active profile: «Hacer activo», no «Activo» pill.
      expect(find.byKey(const ValueKey('profile-hub-active')), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-hub-make-active')),
        findsOneWidget,
      );
    });

    testWidgets('the main profile, when it is the active one, says so', (
      tester,
    ) async {
      await _pump(tester, profile: 'default');
      expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-hub-make-active')),
        findsNothing,
      );
    });

    testWidgets('a tap on the avatar and name opens the profile editor with '
        'this profile', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('profile-hub-edit')));
      await tester.pumpAndSettle();
      expect(find.text('editor:$navSecondary'), findsOneWidget);
    });

    testWidgets('a saved edit tells whoever lists the profile; a cancelled '
        'one does not', (tester) async {
      var edited = 0;
      await _pump(tester, editorSaves: true, onEdited: () => edited++);
      await tester.tap(find.byKey(const ValueKey('profile-hub-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stub-editor-save')));
      await tester.pumpAndSettle();
      expect(edited, 1);

      await _pump(tester, onEdited: () => edited++);
      await tester.tap(find.byKey(const ValueKey('profile-hub-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stub-editor-save')));
      await tester.pumpAndSettle();
      expect(edited, 1);
    });

    testWidgets('a read-only server cannot edit the profile', (tester) async {
      await _pump(tester, readOnly: true);
      await tester.tap(find.byKey(const ValueKey('profile-hub-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stub-editor')), findsNothing);
    });

    testWidgets('the Chat pill is there only when the hub can open the chat', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byKey(const ValueKey('profile-hub-chat')), findsNothing);
      var chats = 0;
      await _pump(tester, onChat: () => chats++);
      await tester.tap(find.byKey(const ValueKey('profile-hub-chat')));
      expect(chats, 1);
    });
  });

  group('sections', () {
    testWidgets('Model and Skills on top, then Integraciones, Trabajo, '
        'Agente; Avanzado is folded', (tester) async {
      await _pump(tester);
      final strings = Strings.of(tester.element(find.byType(ProfileHubScreen)));
      expect(find.byKey(const ValueKey('profile-hub-model')), findsOneWidget);
      expect(_row('skills'), findsOneWidget);
      for (final label in [
        strings.navSecIntegrations,
        strings.navSecWork,
        strings.navSecAgent,
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final id in [
        'connections',
        'plugins',
        'mcp',
        'projects',
        'routines',
        'artifacts',
        'kanban',
        'soul',
        'memory',
        'usage',
      ]) {
        expect(_row(id), findsOneWidget, reason: id);
      }
      // Folded: none of Advanced's rows is built.
      for (final id in ['voice', 'keys', 'vault', 'logs', 'task-center']) {
        expect(_row(id), findsNothing, reason: id);
      }
    });

    testWidgets('counters: Skills from the profile; Plugins and MCP only '
        'from what is already read', (tester) async {
      final connection = navConnection();
      final cache = CapabilitiesSnapshotCache()
        ..write(
          CapabilitiesSnapshotCache.keyOf(connection, navSecondary),
          const CapabilitiesSnapshot(
            installed: [
              CapabilityItem(
                kind: CapabilityKind.plugin,
                id: 'plugin:a',
                name: 'a',
                installed: true,
              ),
              CapabilityItem(
                kind: CapabilityKind.plugin,
                id: 'plugin:b',
                name: 'b',
                installed: true,
              ),
              CapabilityItem(
                kind: CapabilityKind.skill,
                id: 'skill:c',
                name: 'c',
                installed: true,
              ),
            ],
            mcpServers: [
              CapabilityItem(kind: CapabilityKind.mcp, id: 'mcp:x', name: 'x'),
            ],
          ),
        );
      await _pump(tester, cache: cache);
      Finder value(String id, String text) =>
          find.descendant(of: _row(id), matching: find.text(text));
      expect(value('skills', '7'), findsOneWidget);
      expect(value('plugins', '2'), findsOneWidget);
      expect(value('mcp', '1'), findsOneWidget);

      // Nothing read yet: no counter, and no request to make one.
      await _pump(tester);
      expect(value('plugins', '2'), findsNothing);
      expect(
        find.descendant(of: _row('mcp'), matching: find.text('0')),
        findsNothing,
      );
    });

    testWidgets('«Avanzado» remembers its state', (tester) async {
      final manager = await navManager();
      await _pump(tester, manager: manager);
      expect(_row('keys'), findsNothing);
      await _openAdvanced(tester);
      for (final id in ['voice', 'keys', 'vault', 'logs', 'task-center']) {
        expect(_row(id), findsOneWidget, reason: id);
      }
      expect(manager.prefs.getBool(ProfileHubScreen.advancedOpenKey), isTrue);

      // Another visit: still open.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, manager: manager);
      expect(_row('keys'), findsOneWidget);

      await _openAdvanced(tester);
      expect(_row('keys'), findsNothing);
      expect(manager.prefs.getBool(ProfileHubScreen.advancedOpenKey), isFalse);
    });

    testWidgets('Agentes is in Trabajo only with an SSH profile', (
      tester,
    ) async {
      await _pump(tester);
      expect(_row('agents'), findsNothing);
      await _pump(tester, ssh: true);
      expect(_row('agents'), findsOneWidget);
    });

    testWidgets('«Ficha del bot» is in Avanzado only when the hub came from '
        'Bots, and opens the card', (tester) async {
      await _pump(tester);
      await _openAdvanced(tester);
      expect(_row('bot-card'), findsNothing);

      var cards = 0;
      final manager = await navManager();
      // Taller than the default view: with the «Hacer activo» pill beside
      // «Cambiar de perfil» the header takes one more line in the test font.
      await _pump(
        tester,
        manager: manager,
        onOpenBotCard: () => cards++,
        size: const Size(390, 2400),
      );
      expect(_row('bot-card'), findsOneWidget);
      await tester.ensureVisible(_row('bot-card'));
      await tester.tap(_row('bot-card'));
      await tester.pump();
      expect(cards, 1);
    });
  });

  group('every row acts on this profile', () {
    testWidgets('each screen the hub opens is built with the hub\'s profile, '
        'while the active one is the main profile', (tester) async {
      final rig = await _pump(tester, ssh: true, onOpenBotCard: () {});
      expect(rig.manager.activeProfileFor(rig.connection.id), isEmpty);
      final entries = _entries(tester);

      void hub(String id, ExtensionsTab tab) {
        final screen = _built(tester, entries, id) as CapabilitiesHub;
        expect(screen.profile, navSecondary, reason: id);
        // One screen, three tabs: each row opens its own.
        expect(screen.initialTab, tab, reason: id);
      }

      hub('connections', ExtensionsTab.mcp);
      hub('plugins', ExtensionsTab.plugins);
      hub('mcp', ExtensionsTab.mcp);

      final cron = _built(tester, entries, 'routines') as CronScreen;
      expect(cron.profileOverride, navSecondary);
      expect(cron.botRoutines, isTrue);
      expect(
        (_built(tester, entries, 'artifacts') as ArtifactsScreen).profile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'kanban') as TasksScreen).initialAssignee,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'soul') as SoulScreen).profileOverride,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'memory') as MemoryScreen).profileOverride,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'usage') as UsageAnalyticsScreen).profile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'voice') as VoiceSettingsScreen).profile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'keys') as EnvKeysScreen).profile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'vault') as VaultScreen).profile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'logs') as ActivityScreen).initialProfile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'task-center') as TaskCenterScreen).profile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'characters') as CharacterStudioScreen)
            .profileName,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'backup') as BackupRestoreScreen).profile,
        navSecondary,
      );
      expect(
        (_built(tester, entries, 'advanced-settings')
                as BotProfileSettingsScreen)
            .profile,
        navSecondary,
      );
      // Built on the machine's own gateway, not on a bot's data.
      expect(
        _built(tester, entries, 'projects'),
        isA<OwnedResourceHost<TuiGatewayClient>>(),
      );
      expect(
        _built(tester, entries, 'bot-screen'),
        isA<OwnedResourceHost<TuiGatewayClient>>(),
      );
      expect(_built(tester, entries, 'agents'), isA<Scaffold>());
    });

    testWidgets('the model is read and written for this profile', (
      tester,
    ) async {
      final rig = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('profile-hub-model')));
      await pumpModelUi(tester);
      expect(
        find.byKey(const ValueKey('profile-hub-model-picker')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-hub-model-openai-gpt-5.5-mini')),
      );
      await pumpModelUi(tester);
      expect(rig.gateway.configures.single.$1, navSecondary);
      expect(rig.gateway.configures.single.$2, {
        'model': 'gpt-5.5-mini',
        'provider': 'openai',
      });
      // And nothing of it touched the active profile.
      expect(rig.manager.activeProfileFor(rig.connection.id), isEmpty);
      expect(rig.gateway.catalogReads, everyElement(navSecondary));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Projects has no profile of its own: opening it makes this '
        'profile the active one, and says so', (tester) async {
      final rig = await _pump(tester);
      final projects = _entries(
        tester,
      ).singleWhere((e) => e.destination.id == 'projects').destination;
      // The row tells it before it is opened.
      final strings = Strings.of(tester.element(find.byType(ProfileHubScreen)));
      expect(projects.subtitle, strings.navFollowsActiveHint);
      expect(rig.manager.activeProfileFor(rig.connection.id), isEmpty);

      await tester.runAsync(() => projects.beforeOpen!());
      await tester.pump();
      expect(rig.manager.activeProfileFor(rig.connection.id), navSecondary);
      expect(
        find.text(strings.navActiveProfileNotice(navSecondary)),
        findsOneWidget,
      );
      // The page now shows it is the active one, and the row no longer warns.
      expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);
      final again = _entries(
        tester,
      ).singleWhere((e) => e.destination.id == 'projects').destination;
      expect(again.subtitle, isNull);
    });

    testWidgets('the main profile\'s Projects row changes nothing', (
      tester,
    ) async {
      final rig = await _pump(tester, profile: 'default');
      final projects = _entries(
        tester,
      ).singleWhere((e) => e.destination.id == 'projects').destination;
      expect(projects.subtitle, isNull);
      await tester.runAsync(() => projects.beforeOpen!());
      await tester.pump();
      expect(rig.manager.activeProfileFor(rig.connection.id), isEmpty);
      final strings = Strings.of(tester.element(find.byType(ProfileHubScreen)));
      expect(
        find.text(strings.navActiveProfileNotice('default')),
        findsNothing,
      );
    });

    testWidgets('Keys, opened from the hub, reads and writes the .env of '
        'this profile', (tester) async {
      await _pump(tester);
      await _openAdvanced(tester);
      final built = _built(tester, _entries(tester), 'keys') as EnvKeysScreen;
      expect(built.profile, navSecondary);

      // The screen the hub builds, on a server that records what it is asked.
      final env = _FakeEnv();
      final connection = built.connection.copyWith(useHttps: true);
      await tester.pumpWidget(
        navApp(
          EnvKeysScreen(
            connection: connection,
            profile: built.profile,
            clientOverride: env,
            secureScope: () async => () async {},
            appLocked: ValueNotifier(false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(env.reads, [navSecondary]);
      await tester.tap(
        find.byKey(const ValueKey('env-key-BROWSER_SESSION_TIMEOUT')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('env-value-input')),
        'zz-synthetic-secret',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('env-save')));
      await tester.tap(find.byKey(const ValueKey('env-save')));
      await tester.pumpAndSettle();
      expect(env.writes.single.key, 'BROWSER_SESSION_TIMEOUT');
      expect(env.writes.single.profile, navSecondary);
    });

    testWidgets('Memory, opened from the hub, reads this profile\'s files', (
      tester,
    ) async {
      await _pump(tester);
      final built = _built(tester, _entries(tester), 'memory') as MemoryScreen;
      expect(built.profileOverride, navSecondary);
      final requests = <Uri>[];
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            '{}',
            request.url.path == '/api/memory' ? 200 : 404,
          );
        }),
      );
      await tester.pumpWidget(
        navApp(
          MemoryScreen(
            connection: built.connection,
            profileOverride: built.profileOverride,
            dashboardClientForTesting: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final reads = requests.where((u) => u.path == '/api/memory');
      expect(reads, isNotEmpty);
      expect(
        reads.every((u) => u.queryParameters['profile'] == navSecondary),
        isTrue,
        reason: '$reads',
      );
    });

    testWidgets('a server that does not offer a feature disables its row '
        'and says why', (tester) async {
      final manager = await navManager();
      await manager.saveCapabilities(
        'nav-test',
        const CapabilityMatrix(memoryRead: CapState.no),
      );
      await _pump(tester, manager: manager);
      final memory = _entries(
        tester,
      ).singleWhere((e) => e.destination.id == 'memory').destination;
      expect(memory.enabled, isFalse);
      await tester.ensureVisible(_row('memory'));
      await tester.tap(_row('memory'));
      await tester.pump();
      final strings = Strings.of(tester.element(find.byType(ProfileHubScreen)));
      expect(find.text(strings.drawerUnsupported), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('accessibility', () {
    testWidgets('targets are at least 48 dp and the toggle announces its '
        'state', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, onChat: () {});
      for (final key in const [
        'profile-hub-edit',
        'profile-hub-chat',
        'profile-hub-make-active',
        'profile-hub-switch',
        'profile-hub-advanced',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
      }
      for (final id in ['skills', 'connections', 'soul', 'memory']) {
        expect(
          tester.getSize(_row(id)).height,
          greaterThanOrEqualTo(48),
          reason: id,
        );
      }
      final strings = Strings.of(tester.element(find.byType(ProfileHubScreen)));
      final toggle = tester.getSemantics(
        find.byKey(const ValueKey('profile-hub-advanced')),
      );
      expect(toggle.label, contains(strings.navAdvanced));
      expect(toggle.flagsCollection.isExpanded, Tristate.isFalse);
      await _openAdvanced(tester);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('profile-hub-advanced')))
            .flagsCollection
            .isExpanded,
        Tristate.isTrue,
      );
      // The header names the profile and offers the edit.
      final edit = tester.getSemantics(
        find.byKey(const ValueKey('profile-hub-edit')),
      );
      expect(edit.label, contains(navSecondary));
      expect(edit.hint, strings.navEditProfile);
      handle.dispose();
    });

    for (final locale in Strings.supportedLocales) {
      testWidgets('${locale.languageCode}: 2x text, phone width, no '
          'overflow, folded and open', (tester) async {
        await _pump(
          tester,
          locale: locale,
          scale: 2,
          size: const Size(360, 800),
          ssh: true,
          onChat: () {},
          onOpenBotCard: () {},
        );
        expect(tester.takeException(), isNull);
        await _openAdvanced(tester);
        await tester.drag(
          find.byKey(const ValueKey('profile-hub-list')),
          const Offset(0, -3000),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('the list component is the one Ajustes uses', (tester) async {
    await _pump(tester);
    expect(find.byType(HermesToolGroup), findsWidgets);
    expect(find.byType(HermesToolRow), findsWidgets);
  });
}

/// A Dashboard whose `.env` is in memory and that records what it is asked.
class _FakeEnv extends DashboardClient {
  _FakeEnv()
    : super(
        host: 'keys.example.test',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 500)),
      );

  final rows = <String, Map<String, dynamic>>{
    'BROWSER_SESSION_TIMEOUT': {
      'is_set': false,
      'redacted_value': null,
      'description': 'Seconds before a browser session ends',
      'category': 'tool',
      'is_password': true,
      'channel_managed': false,
      'custom': false,
    },
  };
  final reads = <String?>[];
  final writes = <({String key, String? profile})>[];

  @override
  Future<Map<String, dynamic>> getEnvVars({String? profile}) async {
    reads.add(profile);
    return {for (final e in rows.entries) e.key: e.value};
  }

  @override
  Future<bool> setEnvVar(String key, String value, {String? profile}) async {
    writes.add((key: key, profile: profile));
    return true;
  }
}
