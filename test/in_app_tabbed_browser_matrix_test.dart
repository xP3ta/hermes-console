// Q9-NAV (the owner: «que no se descuadre con el Z Fold y móviles normales; en
// tablet también, sin dejar espacios en blanco»): the browser with tabs at
// every size, measured with Rects. Phones 320 × 568, 360 × 640 and
// 412 × 915, a phone on its side 740 × 360 and 915 × 412, the closed Fold
// 360 × 800, the open Fold 884 × 1000 and its work pane (440 dp), tablets
// 800 × 1280 and 1280 × 800; dark and light; text at 1.0 and 1.3.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/browser_tabs.dart';
import 'package:hermes_android/core/browser/in_app_tabbed_browser.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

/// The card margin of the page (`HermesSpace.x2` each side).
const double _margin = 8;

/// Where the browser lives in a case: the whole window, or the open Fold's
/// work pane beside the chat.
const double _paneWidth = 440;

const _cases = <(String, Size, bool)>[
  ('phone 320x568', Size(320, 568), false),
  ('phone 360x640', Size(360, 640), false),
  ('phone 412x915', Size(412, 915), false),
  ('side 740x360', Size(740, 360), false),
  ('side 915x412', Size(915, 412), false),
  ('Fold closed 360x800', Size(360, 800), false),
  ('Fold open 884x1000', Size(884, 1000), false),
  ('Fold pane 440 of 884x1000', Size(884, 1000), true),
  ('tablet 800x1280', Size(800, 1280), false),
  ('tablet 1280x800', Size(1280, 800), false),
];

/// Hermes's tab and four of the user's, the second one in front.
BrowserTabs _fiveTabs() {
  final tabs = BrowserTabs()
    ..openAgent(Uri.parse('https://boletin.ejemplo.dev/semana-43'), 'Boletín');
  for (final host in ['docs', 'tienda', 'mapas', 'correo']) {
    tabs.open(url: Uri.parse('https://$host.ejemplo.dev/'));
  }
  tabs.activate(tabs.tabs[1].id);
  return tabs;
}

Future<BrowserTabs> _pump(
  WidgetTester tester, {
  required Size size,
  required bool pane,
  ThemeData? theme,
  double scale = 1,
  BrowserTabs? tabs,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
  final model = tabs ?? _fiveTabs();
  final browser = InAppTabbedBrowser(tabs: model);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.fromMode(AppThemeMode.dark),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: pane
          ? Row(
              children: [
                const Expanded(child: SizedBox.expand()),
                SizedBox(
                  width: _paneWidth,
                  child: ChatWorkspacePaneScope(
                    tab: ChatWorkspaceTab.browser,
                    child: browser,
                  ),
                ),
              ],
            )
          : browser,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return model;
}

/// The area the browser has: the window, or the pane.
Rect _area(Size size, bool pane) => pane
    ? Rect.fromLTWH(size.width - _paneWidth, 0, _paneWidth, size.height)
    : Offset.zero & size;

void _expectTarget(WidgetTester tester, Finder finder, String what) {
  final box = tester.getSize(finder);
  expect(box.width, greaterThanOrEqualTo(48), reason: '$what width');
  expect(box.height, greaterThanOrEqualTo(48), reason: '$what height');
}

void main() {
  setUp(() => WebViewPlatform.instance = FakeWebViewPlatform());

  for (final (name, size, pane) in _cases) {
    for (final (themeName, theme) in [
      ('dark', AppTheme.fromMode(AppThemeMode.dark)),
      ('light', AppTheme.fromMode(AppThemeMode.light)),
    ]) {
      for (final scale in const [1.0, 1.3]) {
        testWidgets('$name, $themeName, text $scale: strip, page and grid '
            'fill the room', (tester) async {
          final tabs = await _pump(
            tester,
            size: size,
            pane: pane,
            theme: theme,
            scale: scale,
          );
          expect(tester.takeException(), isNull);
          final area = _area(size, pane);

          // The strip: in its own row, or in the bar's on a phone on its
          // side; «+», the count and every × are whole 48 dp targets.
          final strip = tester.getRect(
            find.byKey(const ValueKey('browser-tab-strip')),
          );
          expect(strip.height, kBrowserTabStripHeight);
          expect(strip.left, greaterThanOrEqualTo(area.left));
          expect(strip.right, lessThanOrEqualTo(area.right + 0.5));
          final add = find.byKey(const ValueKey('browser-tab-new'));
          final count = find.byKey(const ValueKey('browser-tab-count'));
          _expectTarget(tester, add, '+');
          _expectTarget(tester, count, 'count');
          expect(tester.getRect(count).right, lessThanOrEqualTo(area.right));
          for (final tab in tabs.tabs) {
            final close = find.byKey(ValueKey('browser-tab-close-${tab.id}'));
            if (close.evaluate().isEmpty) continue; // scrolled away
            _expectTarget(tester, close, '× ${tab.id}');
          }

          // The page: the whole width but its card margin, and all the
          // height left between the bar and the notch. Nothing between the
          // bar and the page; the bar is its row of 48 dp targets (the
          // strip's 56 dp when it shares the row) and 4 dp above and below,
          // with the address inside it.
          final page = tester.getRect(
            find.byKey(const ValueKey('in-app-browser-webview')),
          );
          expect(page.left, closeTo(area.left + _margin, 1));
          expect(page.right, closeTo(area.right - _margin, 1));
          final bar = tester.getRect(
            find.byKey(const ValueKey('in-app-browser-bar')),
          );
          final address = tester.getRect(
            find.byKey(const ValueKey('in-app-browser-address')),
          );
          final inline = area.width > area.height && area.height < 480;
          final row = inline ? kBrowserTabStripHeight : HermesSpace.tap;
          expect(page.top, closeTo(bar.bottom, 1));
          expect(bar.height, closeTo(row + 2 * HermesSpace.x1, 1));
          expect(address.top, greaterThanOrEqualTo(bar.top));
          expect(address.bottom, lessThanOrEqualTo(bar.bottom));
          final notch = find.byKey(const ValueKey('in-app-browser-notch'));
          if (pane) {
            expect(notch, findsNothing);
            expect(page.bottom, closeTo(area.bottom - _margin, 1));
          } else {
            expect(page.bottom, closeTo(tester.getRect(notch).top, 1));
          }
          expect(page.height, greaterThan(area.height * 0.4));

          // The view of the tabs: columns by width, cards of one size.
          await tester.tap(count);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          final cards = [
            for (final tab in tabs.tabs)
              find.byKey(ValueKey('browser-tab-card-${tab.id}')),
          ].where((card) => card.evaluate().isNotEmpty).toList();
          expect(cards, isNotEmpty);
          final rects = [for (final card in cards) tester.getRect(card)];
          final columns = browserTabGridColumns(area.width);
          final lefts = {for (final r in rects) r.left.round()};
          // Five tabs fill a whole row at every number of columns.
          expect(lefts.length, columns);
          final width = rects.first.width;
          for (final r in rects) {
            expect(r.width, closeTo(width, 0.5), reason: 'one card size');
            expect(r.left, greaterThanOrEqualTo(area.left));
            expect(r.right, lessThanOrEqualTo(area.right));
          }
          expect(width, lessThanOrEqualTo(area.width / columns));
          expect(width * columns, greaterThan(area.width * 0.8));
          _expectTarget(
            tester,
            find.byKey(ValueKey('browser-tab-card-close-${tabs.tabs[1].id}')),
            'card ×',
          );
          _expectTarget(
            tester,
            find.byKey(const ValueKey('browser-tab-close-all')),
            'close all',
          );
          await tester.tap(cards.first);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byKey(const ValueKey('browser-tab-grid')), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }

    // With the keyboard up for the address, the strip steps aside and the
    // page keeps at least 35 % of what is left above the keyboard.
    testWidgets('$name: typing the address, the page is not squashed', (
      tester,
    ) async {
      await _pump(tester, size: size, pane: pane);
      final keyboard = size.height * (size.width > size.height ? 0.5 : 0.4);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.resetViewInsets);
      await tester.tap(find.byKey(const ValueKey('in-app-browser-address')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('browser-tab-strip')), findsNothing);
      final page = tester.getRect(
        find.byKey(const ValueKey('in-app-browser-webview')),
      );
      final above = size.height - keyboard;
      expect(page.height, greaterThanOrEqualTo(above * 0.35));
    });
  }
}
