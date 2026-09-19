import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/bot_sections_editor.dart';
import 'package:hermes_android/core/screens/bot_profile_settings_screen.dart';
import 'package:hermes_android/core/services/bot_section_service.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/remote_bot_roster.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Finder label(String value) => find.byWidgetPredicate(
  (w) => w is Text && (w.data == value || w.semanticsLabel == value),
);
Widget host(Widget child, {String locale = 'en'}) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Scaffold(body: child),
);
void main() {
  test(
    'offline roster persists only display metadata and rejects changed endpoints',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = BotRosterCache(prefs);
      final connection = SavedConnection(
        id: 'c',
        label: 'C',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'secret',
      );
      await cache.write(connection, [
        AgentProfile(
          name: 'bot',
          botModeUiMeta: {
            'title': 'Saved',
            'chat': 'private-session',
            'image': 'private-image',
            'hidden': true,
          },
        ),
      ]);
      expect(cache.read(connection).single.botTitle, 'Saved');
      expect(cache.read(connection).single.botHidden, true);
      expect(cache.read(connection).single.botChatSessionId, isNull);
      expect(
        prefs.getString(prefs.getKeys().single),
        isNot(contains('private')),
      );
      expect(
        prefs.getString(prefs.getKeys().single),
        isNot(contains('secret')),
      );
      expect(cache.read(connection.copyWith(host: 'other.local')), isEmpty);
      await cache.remove(connection);
      expect(cache.read(connection), isEmpty);
    },
  );

  test('remote activity expires and rejects future worker clocks', () {
    final profile = AgentProfile.fromJson({
      'name': 'bot',
      'worker_session': {
        'id': 'worker',
        'source': 'kanban',
        'title': 'task',
        'last_active': 1000,
      },
    });
    expect(
      remoteBotIsActive(
        profile,
        now: DateTime.fromMillisecondsSinceEpoch(1100000),
      ),
      true,
    );
    expect(
      remoteBotIsActive(
        profile,
        now: DateTime.fromMillisecondsSinceEpoch(1200000),
      ),
      false,
    );
    expect(
      remoteBotIsActive(
        profile,
        now: DateTime.fromMillisecondsSinceEpoch(900000),
      ),
      false,
    );
  });
  testWidgets(
    'model warning requires an explicit confirmation before resending',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      final gateway = BotProfileClient((method, params) async {
        if (method == 'profiles.describe') {
          return {
            'model': {'provider': 'vendor', 'default': 'old'},
          };
        }
        writes.add(params);
        return params['confirm_expensive_model'] == true
            ? {
                'applied': {'model': true},
              }
            : {'confirm_required': true, 'confirm_message': 'Provider warning'};
      });
      await tester.pumpWidget(
        host(BotProfileSettingsScreen(profile: 'bot', gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bot-settings-model')),
        'new',
      );
      await tester.pump();
      await tester.tap(label('Save'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(label('Provider warning'), findsOneWidget);
      await tester.tap(
        find.descendant(of: find.byType(AlertDialog), matching: label('Save')),
      );
      await tester.pumpAndSettle();
      expect(writes, hasLength(2));
      expect(writes.last['confirm_expensive_model'], true);
      expect(writes.last['provider'], 'vendor');
    },
  );

  for (final locale in ['en', 'es']) {
    testWidgets(
      'floating section create/remove uses paired fields at 360dp $locale',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Map<String, BotSectionChange>? result;
        final bot = AgentProfile(
          name: 'bot',
          botModeUiMeta: {'sectionId': 'sec-old', 'sectionName': 'Old'},
        );
        await tester.pumpWidget(
          host(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await chooseBotSection(context, [bot], bot: bot);
                },
                child: const Text('open'),
              ),
            ),
            locale: locale,
          ),
        );
        await tester.tap(label('open'));
        await tester.pumpAndSettle();
        await tester.tap(
          label(locale == 'en' ? 'Remove from section' : 'Quitar de sección'),
        );
        await tester.pumpAndSettle();
        expect(result!['bot']!.patch, {'sectionId': null, 'sectionName': null});
        await tester.tap(label('open'));
        await tester.pumpAndSettle();
        await tester.tap(
          label(locale == 'en' ? 'New section…' : 'Nueva sección…'),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 40);
        await tester.enterText(find.byType(TextField), '  Team  ');
        await tester.pump();
        await tester.tap(label(locale == 'en' ? 'Save' : 'Guardar'));
        await tester.pumpAndSettle();
        expect(result!['bot']!.name, 'Team');
        expect(result!['bot']!.id, matches(r'^sec-[0-9a-z]+-[0-9a-z]{1,5}$'));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'advanced settings saves only touched supported fields, partial save stays open',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      final gateway = BotProfileClient((method, params) async {
        if (method == 'profiles.describe') {
          return {
            'description': 'Before',
            'soul': 'Old soul',
            'skills': [
              {'name': 'a', 'enabled': true},
            ],
          };
        }
        writes.add(params);
        return {
          'applied': {'description': false},
        };
      });
      await tester.pumpWidget(
        host(BotProfileSettingsScreen(profile: 'bot', gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bot-settings-model')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('bot-settings-description')),
        'After',
      );
      await tester.pump();
      await tester.ensureVisible(label('Save'));
      await tester.tap(label('Save'));
      await tester.pumpAndSettle();
      expect(writes.single, {'name': 'bot', 'description': 'After'});
      expect(find.byType(BotProfileSettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('missing advanced RPC is inert', (tester) async {
    var calls = 0;
    final gateway = BotProfileClient((method, params) async {
      calls++;
      throw StateError('unknown method');
    });
    await tester.pumpWidget(
      host(BotProfileSettingsScreen(profile: 'bot', gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(calls, 1);
  });
  testWidgets(
    'remote roster separates names, hides hidden bots, and drops replaced-connection response',
    (tester) async {
      final pending = Completer<List<AgentProfile>>();
      final a = SavedConnection(
        id: 'a',
        label: 'A',
        host: 'a.invalid',
        port: 8642,
        apiKey: '',
      );
      final b = SavedConnection(
        id: 'b',
        label: 'B',
        host: 'b.invalid',
        port: 8642,
        apiKey: '',
      );
      String? selected;
      Widget roster(List<SavedConnection> connections, {bool show = false}) =>
          host(
            RemoteBotRoster(
              connections: connections,
              query: '',
              showHidden: show,
              refreshedAt: DateTime(2026),
              loader: (c) async => c.host == 'a.invalid'
                  ? pending.future
                  : [
                      AgentProfile(name: 'bot'),
                      AgentProfile(
                        name: 'secret',
                        botModeUiMeta: {'hidden': true},
                      ),
                    ],
              onOpen: (c, p) => selected = '${c.id}/${p.name}',
              onDetails: (_, _) {},
            ),
          );
      await tester.pumpWidget(roster([a, b]));
      await tester.pumpAndSettle();
      expect(label('bot'), findsOneWidget);
      expect(label('secret'), findsNothing);
      await tester.tap(label('bot'));
      expect(selected, 'b/bot');
      await tester.pumpWidget(roster([a.copyWith(host: 'new.invalid')]));
      await tester.pumpAndSettle();
      pending.complete([AgentProfile(name: 'stale')]);
      await tester.pumpAndSettle();
      expect(label('stale'), findsNothing);
      expect(label('B'), findsNothing);
      await tester.pumpWidget(
        roster([a.copyWith(host: 'new.invalid')], show: true),
      );
      await tester.pumpAndSettle();
      expect(label('secret'), findsOneWidget);
    },
  );
}
