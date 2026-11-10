// Q9-NAV (mock navegador-pestanas, approved by the owner): what the user does
// with the tabs. × closes one and the browser stays, with «Deshacer»; the
// last one leaves a blank tab; «+» and «Cerrar todas»; Hermes's tab marked
// and who drives the page; what TalkBack says; three live pages at most.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/browser_tabs.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/browser/in_app_tabbed_browser.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

final _boletin = Uri.parse('https://boletin.ejemplo.dev/semana-43');
final _docs = Uri.parse('https://docs.ejemplo.dev/');
final _tienda = Uri.parse('https://tienda.ejemplo.dev/');

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  setUp(() => WebViewPlatform.instance = FakeWebViewPlatform());

  Future<void> pump(
    WidgetTester tester,
    BrowserTabs tabs, {
    ValueNotifier<bool>? working,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromMode(AppThemeMode.dark),
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InAppTabbedBrowser(
          tabs: tabs,
          working: working == null ? null : () => working.value,
          changes: working,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Hermes's tab, then two of the user's; [front] in front.
  BrowserTabs three({int front = 1}) {
    final tabs = BrowserTabs()
      ..openAgent(_boletin, 'Boletín')
      ..open(url: _docs)
      ..open(url: _tienda);
    tabs.activate(tabs.tabs[front].id);
    return tabs;
  }

  testWidgets('× closes one tab and the browser stays; «Deshacer» brings '
      'it back', (tester) async {
    final tabs = three();
    await pump(tester, tabs);
    final docs = tabs.tabs[1];
    await tester.tap(_key('browser-tab-close-${docs.id}'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.length, 2);
    expect(tabs.active!.url, _tienda, reason: 'the one on its right');
    expect(_key('browser-tabs'), findsOneWidget);
    expect(find.text('Cerraste «docs.ejemplo.dev»'), findsOneWidget);
    final shown = tester.widget<InAppBrowserScreen>(
      find.byType(InAppBrowserScreen),
    );
    expect(shown.initialUrl, _tienda);

    await tester.tap(find.text('Deshacer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.length, 3);
    expect(tabs.tabs[1], same(docs));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('closing the last tab leaves a blank one, not the chat', (
    tester,
  ) async {
    final tabs = BrowserTabs()..open(url: _docs);
    await pump(tester, tabs);
    await tester.tap(_key('browser-tab-close-${tabs.tabs.single.id}'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.length, 1);
    expect(tabs.active!.blank, isTrue);
    expect(_key('browser-tabs'), findsOneWidget);
    expect(_key('in-app-browser-blank'), findsOneWidget);
    expect(find.text('Pestaña nueva'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('«+» opens a blank tab in front', (tester) async {
    final tabs = three();
    await pump(tester, tabs);
    await tester.tap(_key('browser-tab-new'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.length, 4);
    expect(tabs.active, same(tabs.tabs.last));
    expect(tabs.active!.blank, isTrue);
    expect(_key('in-app-browser-blank'), findsOneWidget);
  });

  testWidgets('the view of the tabs: one opens with a tap; «Cerrar todas» '
      'leaves a blank tab and offers «Deshacer»', (tester) async {
    final tabs = three();
    await pump(tester, tabs);
    await tester.tap(_key('browser-tab-count'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_key('browser-tab-grid'), findsOneWidget);
    expect(find.text('3 pestañas'), findsOneWidget);
    expect(_key('browser-tab-strip'), findsNothing);
    await tester.tap(_key('browser-tab-card-${tabs.tabs[2].id}'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_key('browser-tab-grid'), findsNothing);
    expect(tabs.active, same(tabs.tabs[2]));

    await tester.tap(_key('browser-tab-count'));
    await tester.pump();
    await tester.tap(_key('browser-tab-close-all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tabs.length, 1);
    expect(tabs.active!.blank, isTrue);
    expect(_key('browser-tab-grid'), findsNothing);
    expect(find.text('Cerraste 3 pestañas'), findsOneWidget);
    await tester.tap(find.text('Deshacer'));
    await tester.pump();
    expect(tabs.length, 3);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('Hermes\'s tab is marked, and the line says who drives', (
    tester,
  ) async {
    final working = ValueNotifier(true);
    addTearDown(working.dispose);
    final tabs = three(front: 0);
    await pump(tester, tabs, working: working);
    expect(
      find.descendant(
        of: _key('browser-tab-chip-${tabs.tabs[0].id}'),
        matching: _key('browser-tab-hermes'),
      ),
      findsOneWidget,
    );
    expect(find.text('EN VIVO'), findsOneWidget);
    expect(find.text(' · Controla Hermes'), findsOneWidget);

    // The user's tab: the user drives, and the agent sees it (it reads
    // and drives the tab on screen, as in Hermes Desktop).
    tabs.activate(tabs.tabs[1].id);
    await tester.pump();
    expect(find.text('Controlas tú'), findsOneWidget);
    expect(find.text('Hermes la ve'), findsOneWidget);

    // The turn ends: Hermes's tab says it finished; the user's says
    // nothing.
    working.value = false;
    await tester.pump();
    expect(_key('browser-tab-who'), findsNothing);
    tabs.activate(tabs.tabs[0].id);
    await tester.pump();
    expect(find.text('TERMINADO'), findsOneWidget);
  });

  testWidgets('TalkBack: each tab, its ×, «+» and the count are named', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final tabs = three();
    await pump(tester, tabs);
    expect(
      tester.getSemantics(_key('browser-tab-chip-${tabs.tabs[1].id}')),
      isSemantics(
        label: 'Pestaña 2 de 3, docs.ejemplo.dev',
        isButton: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(
      find.bySemanticsLabel('Pestaña de Hermes, Boletín'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Cerrar la pestaña docs.ejemplo.dev'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Ver las 3 pestañas'), findsOneWidget);
    expect(find.byTooltip('Nueva pestaña'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('three live pages at most; the others sleep', (tester) async {
    final tabs = three()
      ..open(url: Uri.parse('https://mapas.ejemplo.dev/'))
      ..open(url: Uri.parse('https://correo.ejemplo.dev/'));
    await pump(tester, tabs);
    expect(
      find.byType(InAppBrowserScreen, skipOffstage: false),
      findsNWidgets(BrowserTabs.maxLive),
    );
    expect(find.byType(InAppBrowserScreen), findsOneWidget);
    // A sleeping tab wakes on its page.
    tabs.activate(tabs.tabs[0].id);
    await tester.pump();
    final screen = tester.widget<InAppBrowserScreen>(
      find.byType(InAppBrowserScreen),
    );
    expect(screen.initialUrl, _boletin);
    expect(screen.openedByAgent, isTrue);
    expect(tester.takeException(), isNull);
  });
}
