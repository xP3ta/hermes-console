// Settings split by section (1.4.0): every part of Settings has a screen of
// its own with only its cards, the whole list stays as the engine behind
// them (no row in Ajustes, no badge), the deep links end on the section's
// screen, nothing was lost on the way and no two cards of a section touch.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesListGroup;
import 'package:hermes_android/core/screens/about_screen.dart';
import 'package:hermes_android/core/screens/app_settings_screen.dart';
import 'package:hermes_android/core/screens/notification_settings_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/message_reaction_prefs.dart';
import 'package:hermes_android/core/services/motion_prefs.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart'
    show HermesGroup, HermesPanel;
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/nav_harness.dart';

/// The keys each section owns. A section's screen has all of its own and none
/// of the others'.
final Map<SettingsSection, Set<String>> _own = {
  SettingsSection.security: {'settings-security-info', 'settings-vault'},
  SettingsSection.chat: {
    'settings-reactions',
    'settings-pinned-prompt',
    'settings-reasoning-collapsed',
    'settings-streaming-cursor',
  },
  SettingsSection.appearance: {
    'settings-dock',
    'settings-guided-tour',
    'settings-characters',
  },
  SettingsSection.data: {
    'settings-backup',
    'history-cleanup-normal',
    'orphan-data-clean',
  },
  SettingsSection.system: {'maint-nav-test'},
};

Set<String> _others(SettingsSection section) => {
  for (final entry in _own.entries)
    if (entry.key != section) ...entry.value,
};

Future<ConnectionManager> _pumpSection(
  WidgetTester tester,
  SettingsSection section, {
  Size size = const Size(390, 4000),
  double scale = 1,
  Locale locale = const Locale('es'),
  String themeId = 'dark',
}) async {
  navView(tester, size: size, scale: scale);
  final manager = await navManager();
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId(themeId),
      home: SettingsSectionScreen(
        section: section,
        connection: navConnection(),
        connManager: manager,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return manager;
}

Finder _key(String key) => find.byKey(ValueKey(key));

/// Taps the row [id] of Ajustes, which a lazy list has not built (or placed)
/// until it is scrolled to.
Future<void> _tapRow(WidgetTester tester, String id) async {
  final scrollable = find
      .descendant(of: _key('tools-hub-list'), matching: find.byType(Scrollable))
      .first;
  final bottom = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  for (var i = 0; i < 40; i++) {
    final row = _key('tool-$id');
    if (row.evaluate().isNotEmpty && tester.getRect(row).bottom < bottom - 8) {
      break;
    }
    await tester.drag(scrollable, const Offset(0, -200));
    await tester.pump();
  }
  await tester.tap(_key('tool-$id'));
}

/// The whole list, pushed from the Ajustes in front: it has no row there, but
/// stays as the engine of the deep links.
Future<void> _pushWholeList(
  WidgetTester tester,
  ConnectionManager manager,
) async {
  unawaited(
    Navigator.of(tester.element(find.byType(AppSettingsScreen))).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SettingsScreen(connection: navConnection(), connManager: manager),
      ),
    ),
  );
}

Rect _rectOf(Element element) {
  final box = element.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The painted boxes of the cards on screen: the groups as they are, a panel
/// without the 3 dp of margin it carries inside its own bounds. Cards inside
/// another card are not siblings of it and are left out.
List<Rect> _cards(WidgetTester tester) {
  final all = <Rect>[
    for (final e in find.byType(HermesGroup).evaluate()) _rectOf(e),
    for (final e in find.byType(HermesListGroup).evaluate()) _rectOf(e),
    for (final e in find.byType(HermesPanel).evaluate())
      Rect.fromLTRB(
        _rectOf(e).left,
        _rectOf(e).top + 3,
        _rectOf(e).right,
        _rectOf(e).bottom - 3,
      ),
  ].where((r) => r.height > 1 && r.width > 1).toList();
  return [
    for (final r in all)
      if (!all.any(
        (other) =>
            other != r &&
            other.left <= r.left &&
            other.right >= r.right &&
            other.top <= r.top &&
            other.bottom >= r.bottom &&
            (other.width > r.width || other.height > r.height),
      ))
        r,
  ]..sort((a, b) => a.top.compareTo(b.top));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SettingsDeepLink.pending.value = null);

  group('each section has a screen with only its own cards', () {
    for (final entry in _own.entries) {
      final section = entry.key;
      testWidgets('${section.name}: its keys, none of the other sections', (
        tester,
      ) async {
        await _pumpSection(tester, section);
        final strings = Strings.of(tester.element(find.byType(Scaffold).first));
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text(settingsSectionScreenTitle(strings, section)),
          ),
          findsOneWidget,
        );
        for (final key in entry.value) {
          expect(_key(key), findsOneWidget, reason: '${section.name}: $key');
        }
        for (final key in _others(section)) {
          expect(_key(key), findsNothing, reason: '${section.name} has $key');
        }
        expect(_key('settings-all-badge'), findsNothing);
        // Its one deep-link target is its own: nothing of another section.
        final targets = tester.widgetList<SettingsDeepLinkTarget>(
          find.byType(SettingsDeepLinkTarget),
        );
        expect(targets, isNotEmpty);
        expect(targets.every((t) => t.section == section), isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the cursor moved from Aspecto to Chat', (tester) async {
      await _pumpSection(tester, SettingsSection.appearance);
      expect(_key('settings-streaming-cursor'), findsNothing);
      await _pumpSection(tester, SettingsSection.chat);
      expect(_key('settings-streaming-cursor'), findsOneWidget);
    });
  });

  testWidgets('the whole list keeps every section and no longer wears a '
      'badge', (tester) async {
    navView(tester, size: const Size(390, 30000));
    final manager = await navManager();
    await tester.pumpWidget(
      navApp(SettingsScreen(connection: navConnection(), connManager: manager)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_key('settings-all-badge'), findsNothing);
    for (final entry in _own.entries) {
      for (final key in entry.value) {
        expect(_key(key), findsOneWidget, reason: key);
      }
    }
    expect(tester.takeException(), isNull);
  });

  group('preferences still save after the split', () {
    testWidgets('the Chat screen writes the same preferences', (tester) async {
      navView(tester, size: const Size(390, 4000));
      final manager = await navManager();
      final prefs = await SharedPreferences.getInstance();
      await MessageReactionPrefs.load(prefs);
      await PinnedPromptPrefs.load(prefs);
      await MotionPrefs.load(prefs);
      await tester.pumpWidget(
        navApp(
          SettingsSectionScreen(
            section: SettingsSection.chat,
            connection: navConnection(),
            connManager: manager,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(MessageReactionPrefs.shared.enabled, isFalse);
      await tester.tap(_key('settings-reactions'));
      await tester.pump();
      expect(MessageReactionPrefs.shared.enabled, isTrue);
      expect(prefs.getBool(MessageReactionPrefs.key), isTrue);

      final pinned = PinnedPromptPrefs.shared.enabled;
      await tester.tap(_key('settings-pinned-prompt'));
      await tester.pump();
      expect(PinnedPromptPrefs.shared.enabled, !pinned);

      final strings = Strings.of(tester.element(find.byType(Scaffold).first));
      await tester.tap(find.text(strings.motionCursorBlock));
      await tester.pump(const Duration(milliseconds: 50));
      expect(MotionPrefs.shared.cursor, StreamingCursorStyle.block);
      expect(prefs.getString(MotionPrefs.cursorKey), 'block');
      expect(tester.takeException(), isNull);

      // The full list shows what the Chat screen just saved.
      await tester.pumpWidget(
        navApp(
          SettingsScreen(connection: navConnection(), connManager: manager),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final row = tester.widget<Switch>(
        find.descendant(
          of: _key('settings-reactions'),
          matching: find.byType(Switch),
        ),
      );
      expect(row.value, isTrue);
    });
  });

  group('deep links end on the screen of their section', () {
    testWidgets('every section maps to its own screen', (tester) async {
      navView(tester);
      final manager = await navManager();
      for (final section in SettingsSection.values) {
        final screen = settingsSectionScreen(
          section: section,
          connection: navConnection(),
          connManager: manager,
        );
        switch (section) {
          case SettingsSection.voice:
            expect(screen, isA<VoiceSettingsScreen>());
          case SettingsSection.notifications:
            expect(screen, isA<NotificationSettingsScreen>());
          default:
            expect(screen, isA<SettingsSectionScreen>(), reason: section.name);
            expect((screen as SettingsSectionScreen).section, section);
        }
        expect(screen, isNot(isA<SettingsScreen>()), reason: section.name);
      }
    });

    testWidgets('a request while Ajustes is in front opens that screen', (
      tester,
    ) async {
      navView(tester, size: const Size(411, 915));
      final manager = await navManager();
      await tester.pumpWidget(
        navApp(
          AppSettingsScreen(connection: navConnection(), connManager: manager),
        ),
      );
      await tester.pump();
      SettingsDeepLink.request(SettingsSection.data);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final screen = tester.widget<SettingsSectionScreen>(
        find.byType(SettingsSectionScreen),
      );
      expect(screen.section, SettingsSection.data);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(SettingsDeepLink.pending.value, isNull, reason: 'consumed');
      expect(_key('orphan-data-clean'), findsOneWidget);
      expect(_key('settings-security-info'), findsNothing);
    });

    testWidgets('a request made before Ajustes exists is honoured', (
      tester,
    ) async {
      navView(tester, size: const Size(411, 915));
      final manager = await navManager();
      SettingsDeepLink.request(SettingsSection.chat);
      await tester.pumpWidget(
        navApp(
          AppSettingsScreen(connection: navConnection(), connManager: manager),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<SettingsSectionScreen>(find.byType(SettingsSectionScreen))
            .section,
        SettingsSection.chat,
      );
    });

    testWidgets('under the whole list the request still scrolls it', (
      tester,
    ) async {
      navView(tester, size: const Size(411, 915));
      final manager = await navManager();
      await tester.pumpWidget(
        navApp(
          AppSettingsScreen(connection: navConnection(), connManager: manager),
        ),
      );
      await tester.pump();
      await _pushWholeList(tester, manager);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsScreen), findsOneWidget);

      SettingsDeepLink.request(SettingsSection.security);
      await tester.pump();
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(SettingsSectionScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-highlight-security')),
        findsOneWidget,
      );
      expect(SettingsDeepLink.pending.value, isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('openSettingsSection pushes the section screen', (
      tester,
    ) async {
      navView(tester);
      final manager = await navManager();
      await tester.pumpWidget(
        navApp(
          Builder(
            builder: (context) => TextButton(
              key: const ValueKey('go'),
              onPressed: () => openSettingsSection(
                context,
                section: SettingsSection.security,
                connection: navConnection(),
                connManager: manager,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(_key('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_key('settings-security-info'), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
    });
  });

  group('a wide window keeps list and detail', () {
    testWidgets('the detail is the screen of the section picked', (
      tester,
    ) async {
      navView(tester, size: const Size(1100, 800));
      final manager = await navManager();
      final pushes = _Pushes();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          navigatorObservers: [pushes],
          home: AppSettingsScreen(
            connection: navConnection(),
            connManager: manager,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      pushes.count = 0;

      expect(tester.getSize(_key('app-settings-list')).width, 320);
      // Seguridad is open from the start.
      expect(_key('settings-security-info'), findsOneWidget);
      expect(_key('settings-reactions'), findsNothing);

      await tester.tap(_key('tool-chat'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_key('settings-reactions'), findsOneWidget);
      expect(_key('settings-security-info'), findsNothing);
      expect(
        tester.getRect(_key('settings-reactions')).left,
        greaterThanOrEqualTo(tester.getRect(_key('app-settings-list')).right),
      );
      expect(pushes.count, 0, reason: 'a section opens in the pane');

      // A row that is not a section still opens its own page.
      // The list is a column of 320 dp beside the rail and ends inside the
      // window, so its last row can be reached by scrolling.
      final list = tester.getRect(_key('app-settings-list'));
      expect(list.width, 320);
      expect(list.bottom, lessThanOrEqualTo(800));
      expect(
        tester.getRect(_key('tools-hub-list')).bottom,
        lessThanOrEqualTo(800),
      );
      await _tapRow(tester, 'about');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(pushes.count, 1);
      expect(find.byType(AboutScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a request selects its section in the pane', (tester) async {
      navView(tester, size: const Size(1100, 800));
      final manager = await navManager();
      await tester.pumpWidget(
        navApp(
          AppSettingsScreen(connection: navConnection(), connManager: manager),
        ),
      );
      await tester.pump();
      SettingsDeepLink.request(SettingsSection.data);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_key('orphan-data-clean'), findsOneWidget);
      expect(find.byType(SettingsSectionScreen), findsOneWidget);
    });
  });

  group('no two cards of a section touch', () {
    const sections = [
      SettingsSection.connection,
      SettingsSection.appearance,
      SettingsSection.chat,
      SettingsSection.security,
      SettingsSection.system,
      SettingsSection.data,
      SettingsSection.about,
    ];
    for (final width in const [360.0, 840.0]) {
      for (final scale in const [1.0, 2.0]) {
        for (final section in sections) {
          testWidgets(
            '${section.name} at ${width.toInt()} dp, ${scale}x text',
            (tester) async {
              await _pumpSection(
                tester,
                section,
                size: Size(width, 6000),
                scale: scale,
              );
              expect(tester.takeException(), isNull);
              final cards = _cards(tester);
              expect(cards, isNotEmpty, reason: section.name);
              for (var i = 0; i < cards.length; i++) {
                for (var j = i + 1; j < cards.length; j++) {
                  final a = cards[i];
                  final b = cards[j];
                  expect(a.overlaps(b), isFalse, reason: '$a over $b');
                  final shareColumn = a.left < b.right && b.left < a.right;
                  if (shareColumn && j == i + 1) {
                    expect(
                      b.top - a.bottom,
                      greaterThanOrEqualTo(settingsCardGap - 0.5),
                      reason:
                          '${section.name}: $a and $b are closer than the '
                          'gap between cards',
                    );
                  }
                }
              }
            },
          );
        }
      }
    }

    testWidgets('the data section has its three cards with the same gap', (
      tester,
    ) async {
      await _pumpSection(tester, SettingsSection.data);
      final cards = _cards(tester);
      expect(cards.length, 3);
      expect(cards[1].top - cards[0].bottom, closeTo(settingsCardGap, 0.5));
      expect(cards[2].top - cards[1].bottom, closeTo(settingsCardGap, 0.5));
    });
  });

  group('accessibility', () {
    for (final locale in Strings.supportedLocales) {
      testWidgets('${locale.languageCode}: 2x text, rows of 48 dp, no '
          'overflow', (tester) async {
        for (final section in const [
          SettingsSection.security,
          SettingsSection.chat,
          SettingsSection.appearance,
          SettingsSection.data,
        ]) {
          await _pumpSection(
            tester,
            section,
            size: const Size(360, 6000),
            scale: 2,
            locale: locale,
          );
          expect(tester.takeException(), isNull, reason: section.name);
          final strings = Strings.of(
            tester.element(find.byType(Scaffold).first),
          );
          expect(
            settingsSectionScreenTitle(strings, section),
            isNotEmpty,
            reason: '${locale.languageCode} ${section.name}',
          );
          for (final key in _own[section]!) {
            expect(
              tester.getSize(_key(key)).height,
              greaterThanOrEqualTo(48),
              reason: '${locale.languageCode} $key',
            );
          }
        }
      });
    }

    testWidgets('the screen of a section is announced by its title and its '
        'rows have names', (tester) async {
      final handle = tester.ensureSemantics();
      for (final section in _own.keys) {
        await _pumpSection(
          tester,
          section,
          size: const Size(360, 6000),
          scale: 2,
        );
        final strings = Strings.of(tester.element(find.byType(Scaffold).first));
        expect(
          find.bySemanticsLabel(settingsSectionScreenTitle(strings, section)),
          findsWidgets,
          reason: section.name,
        );
        for (final key in _own[section]!) {
          final label = tester
              .getSemantics(
                find
                    .descendant(of: _key(key), matching: find.byType(Text))
                    .first,
              )
              .label;
          expect(label, isNotEmpty, reason: '${section.name}: $key');
        }
      }
      handle.dispose();
    });

    testWidgets('a row of Ajustes and the screen it opens have the same '
        'name', (tester) async {
      navView(tester, size: const Size(390, 2400));
      final manager = await navManager();
      await tester.pumpWidget(
        navApp(
          AppSettingsScreen(connection: navConnection(), connManager: manager),
        ),
      );
      await tester.pump();
      final strings = Strings.of(tester.element(find.byType(Scaffold).first));
      for (final entry in appSettingsRowSections.entries) {
        final label = tester
            .widget<ToolsHubScreen>(find.byType(ToolsHubScreen))
            .destinations
            .singleWhere((d) => d.id == entry.key)
            .label;
        expect(
          label,
          settingsSectionScreenTitle(strings, entry.value),
          reason: entry.key,
        );
      }
    });

    testWidgets('the title of a section is the same in the app bar and the '
        'pane', (tester) async {
      navView(tester, size: const Size(1100, 800));
      final manager = await navManager();
      await tester.pumpWidget(
        navApp(
          AppSettingsScreen(connection: navConnection(), connManager: manager),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final strings = Strings.of(tester.element(find.byType(Scaffold).first));
      expect(
        tester.widget<Text>(_key('settings-section-pane-title')).data,
        strings.ssxTitleSecurity,
      );
    });
  });
}

class _Pushes extends NavigatorObserver {
  int count = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => count++;
}
