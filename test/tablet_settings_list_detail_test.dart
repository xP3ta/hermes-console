import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/embed_settings_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Settings on a tablet: in expanded windows (>= 840dp) the categories sit in
// a ~320dp pane on the left and the selected category's page on the right.
// Picking a category or opening one of its pages never pushes an app route.
// Phones and medium windows keep the single long list.

class _CountingObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

const _categories = ValueKey('settings-categories');
const _detail = ValueKey('settings-detail-pane');

ValueKey<String> _category(SettingsSection s) =>
    ValueKey('settings-category-${s.name}');

Future<_CountingObserver> _pump(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues(const {});
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final connection = SavedConnection(
    id: 'tablet-settings',
    label: 'Hermes',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'k',
    dashboardUrl: 'http://127.0.0.1:9119',
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final observer = _CountingObserver();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      navigatorObservers: [observer],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-settings'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(
                    connection: connection,
                    connManager: manager,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-settings')));
  await tester.pumpAndSettle();
  observer.pushes = 0;
  return observer;
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

bool _selected(WidgetTester tester, SettingsSection s) =>
    tester
        .widget<Semantics>(
          find
              .descendant(
                of: find.byKey(_category(s)),
                matching: find.byType(Semantics),
              )
              .first,
        )
        .properties
        .selected ==
    true;

Finder _inDetail(Finder f) =>
    find.descendant(of: find.byKey(_detail), matching: f);

void main() {
  tearDown(() => SettingsDeepLink.pending.value = null);

  testWidgets('phone 411x915 keeps the single list (no panes)', (tester) async {
    await _pump(tester, const Size(411, 915));

    expect(find.byKey(_categories), findsNothing);
    expect(find.byKey(_detail), findsNothing);
    expect(find.byType(ListView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium 700x1000 keeps the single list', (tester) async {
    await _pump(tester, const Size(700, 1000));

    expect(find.byKey(_categories), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(1280, 800), Size(1024, 768)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$label: categories left (320dp), page right', (tester) async {
      await _pump(tester, size);

      expect(find.byKey(_categories), findsOneWidget);
      expect(find.byKey(_detail), findsOneWidget);
      expect(tester.getSize(find.byKey(_categories)).width, 320);
      final left = tester.getRect(find.byKey(_categories));
      final right = tester.getRect(find.byKey(_detail));
      expect(right.left, greaterThanOrEqualTo(left.right));
      for (final s in SettingsSection.values) {
        expect(find.byKey(_category(s)), findsOneWidget, reason: s.name);
      }
      // The first category is open from the start.
      expect(_selected(tester, SettingsSection.connection), isTrue);
      expect(
        _inDetail(find.byKey(const ValueKey('settings-highlight-connection'))),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label: picking a category swaps the page in place', (
      tester,
    ) async {
      final observer = await _pump(tester, size);

      expect(
        _inDetail(find.byKey(const ValueKey('settings-rich-embeds'))),
        findsNothing,
      );
      await tester.tap(find.byKey(_category(SettingsSection.chat)));
      await tester.pumpAndSettle();

      expect(
        _inDetail(find.byKey(const ValueKey('settings-rich-embeds'))),
        findsOneWidget,
      );
      expect(_selected(tester, SettingsSection.chat), isTrue);
      expect(_selected(tester, SettingsSection.connection), isFalse);
      expect(observer.pushes, 0, reason: 'no app route for a category');
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label: a category page opens inside the right pane and '
        'Back closes it before leaving Settings', (tester) async {
      final observer = await _pump(tester, size);
      await tester.tap(find.byKey(_category(SettingsSection.chat)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('settings-rich-embeds')));
      await tester.pumpAndSettle();

      expect(_inDetail(find.byType(EmbedSettingsScreen)), findsOneWidget);
      expect(find.byKey(_categories), findsOneWidget, reason: 'list stays');
      expect(
        tester.getRect(find.byType(EmbedSettingsScreen)).left,
        greaterThanOrEqualTo(tester.getRect(find.byKey(_categories)).right),
      );
      expect(observer.pushes, 0, reason: 'pushed in the pane, not the app');

      // Back: the page closes, the category stays selected.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(EmbedSettingsScreen), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(_selected(tester, SettingsSection.chat), isTrue);

      // Back again leaves Settings.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
    });

    testWidgets('$label: picking another category closes the open page', (
      tester,
    ) async {
      await _pump(tester, size);
      await tester.tap(find.byKey(_category(SettingsSection.chat)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-rich-embeds')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_category(SettingsSection.about)));
      await tester.pumpAndSettle();

      expect(find.byType(EmbedSettingsScreen), findsNothing);
      expect(_selected(tester, SettingsSection.about), isTrue);
      expect(
        _inDetail(find.byKey(const ValueKey('settings-section-about'))),
        findsOneWidget,
      );
    });

    testWidgets('$label: a deep link opens its page in the right pane', (
      tester,
    ) async {
      await _pump(tester, size);

      SettingsDeepLink.request(SettingsSection.security);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_selected(tester, SettingsSection.security), isTrue);
      expect(
        _inDetail(find.byKey(const ValueKey('settings-highlight-security'))),
        findsOneWidget,
      );
      expect(SettingsDeepLink.pending.value, isNull, reason: 'consumed');
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a deep link while a page is open closes it and selects the '
      'requested category', (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.byKey(_category(SettingsSection.chat)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-rich-embeds')));
    await tester.pumpAndSettle();

    SettingsDeepLink.request(SettingsSection.about);
    await tester.pumpAndSettle();

    expect(find.byType(EmbedSettingsScreen), findsNothing);
    expect(_selected(tester, SettingsSection.about), isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('rotation 1280x800 -> 800x1280 -> back keeps the category', (
    tester,
  ) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.byKey(_category(SettingsSection.security)));
    await tester.pumpAndSettle();

    await _resize(tester, const Size(800, 1280));
    expect(find.byKey(_categories), findsNothing, reason: 'medium: one list');
    expect(tester.takeException(), isNull);

    await _resize(tester, const Size(1280, 800));
    expect(_selected(tester, SettingsSection.security), isTrue);
    expect(tester.takeException(), isNull);

    // A second round trip still shows the list, and Back leaves Settings
    // (no page is left counted as open in the rebuilt pane).
    await _resize(tester, const Size(800, 1280));
    expect(find.byKey(_categories), findsNothing);
    expect(find.byKey(_detail), findsNothing, reason: 'no page open');
    await _resize(tester, const Size(1280, 800));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('rotation 1024x768 -> 768x1024 keeps an open page', (
    tester,
  ) async {
    await _pump(tester, const Size(1024, 768));
    await tester.tap(find.byKey(_category(SettingsSection.chat)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-rich-embeds')));
    await tester.pumpAndSettle();

    await _resize(tester, const Size(768, 1024));
    expect(find.byType(EmbedSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Back closes the page and shows the single list again.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(EmbedSettingsScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);

    await _resize(tester, const Size(1024, 768));
    expect(_selected(tester, SettingsSection.chat), isTrue);
    expect(tester.takeException(), isNull);
  });
}
