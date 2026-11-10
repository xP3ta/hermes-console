// T2-B (mock 138 v2): the agent's browser floats over its chat. «Ver
// <host>», a rounded window with its state, who drives the page and three
// actions, dragged over the chat without moving it, anchored at the top as
// a 64 dp pill, closed by dropping it on a target or with its button.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/agent_browser_bridge.dart';
import 'package:hermes_android/core/browser/agent_browser_pip.dart';
import 'package:hermes_android/core/browser/agent_preview_act.dart';
import 'package:hermes_android/core/browser/agent_preview_protocol.dart';
import 'package:hermes_android/core/browser/hermes_preview_engine.g.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

const _header = 120.0;
const _composer = 96.0;
const _notch = 48.0;
const _height = 800.0;
final _page = Uri.parse('https://news.example/today');

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  late FakeWebViewPlatform web;
  late AgentBrowserBridge bridge;
  late AgentBrowserPipController controller;
  late ValueNotifier<bool> working;
  late ValueNotifier<bool> connected;
  late ValueNotifier<double> bars;
  late List<(Uri, String, bool)> expanded;
  late int retries;

  setUp(() {
    web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;
    bridge = AgentBrowserBridge(
      engine: AgentPreviewActEngine(
        () async => hermesPreviewEngine,
        pollEvery: const Duration(milliseconds: 1),
      ),
    );
    controller = AgentBrowserPipController();
    working = ValueNotifier(true);
    connected = ValueNotifier(true);
    bars = ValueNotifier(_composer);
    expanded = [];
    retries = 0;
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 360,
    AppThemeMode mode = AppThemeMode.dark,
    bool reduce = false,
    FocusNode? composerField,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = Size(width, _height);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromMode(mode),
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: ListView(
                  key: const ValueKey('chat-under'),
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(
                        key: ValueKey('row-$i'),
                        height: 40,
                        child: Text('mensaje $i'),
                      ),
                  ],
                ),
              ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: _header,
                child: SizedBox(key: ValueKey('header')),
              ),
              ValueListenableBuilder<double>(
                valueListenable: bars,
                builder: (context, value, _) => Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: value,
                  child: SizedBox(
                    key: const ValueKey('composer'),
                    child: composerField == null
                        ? null
                        : TextField(focusNode: composerField),
                  ),
                ),
              ),
              Positioned.fill(
                child: AgentBrowserPipLayer(
                  controller: controller,
                  topInset: _header,
                  bottomBars: bars,
                  bottomClearance: _notch,
                  agentConnectionId: 'conn-a',
                  agentSessionId: () => 'rt-1',
                  changes: Listenable.merge([working, connected]),
                  working: () => working.value,
                  connected: () => connected.value,
                  onRetryConnection: () => retries++,
                  onExpand: (url, label, byAgent) =>
                      expanded.add((url, label, byAgent)),
                  bridge: bridge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> show(WidgetTester tester) async {
    controller.show(_page, 'News');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Rect window(WidgetTester tester) =>
      tester.getRect(_key('agent-browser-pip'));

  // What decides «anchored» (gint48): the room between the header and the
  // bars, and who has the focus.
  String why(WidgetTester tester, double barsNow) {
    final room = _height - barsNow - _notch - 8 - (_header + 8);
    return 'room $room (anchors below 400), window ${window(tester)}, '
        'focus ${FocusManager.instance.primaryFocus}';
  }

  AgentBrowserPage? page() => bridge.pageOf('conn-a', 'rt-1');

  for (final mode in [AppThemeMode.dark, AppThemeMode.light]) {
    for (final width in [360.0, 412.0, 480.0]) {
      testWidgets('${mode.name} $width dp: the window sits between the '
          'header and the composer, 48 dp targets', (tester) async {
        await pump(tester, width: width, mode: mode);
        await show(tester);
        expect(tester.takeException(), isNull);
        final rect = window(tester);
        expect(rect.left, greaterThanOrEqualTo(12));
        expect(rect.right, lessThanOrEqualTo(width - 12));
        expect(
          rect.top,
          greaterThanOrEqualTo(tester.getRect(_key('header')).bottom),
          reason: 'never over the header or the island',
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(tester.getRect(_key('composer')).top - _notch),
          reason: 'never over the composer or its notch',
        );
        for (final action in ['dock', 'expand', 'close']) {
          final size = tester.getSize(_key('agent-browser-pip-$action'));
          expect(size.width, greaterThanOrEqualTo(48), reason: action);
          expect(size.height, greaterThanOrEqualTo(48), reason: action);
        }
        // The page is the agent's, in the chat's own in-app browser.
        final browser = tester.widget<InAppBrowserScreen>(
          find.byType(InAppBrowserScreen),
        );
        expect(browser.initialUrl, _page);
        expect(browser.openedByAgent, isTrue);
        expect(browser.agentConnectionId, 'conn-a');
        expect(browser.agentSessionId?.call(), 'rt-1');
        expect(find.text('EN VIVO'), findsOneWidget);
        expect(find.text('Controla Hermes'), findsOneWidget);
      });
    }
  }

  testWidgets('open, the agent reaches the page; anchored as a 64 dp pill, '
      'out of sight, it does not', (tester) async {
    await pump(tester);
    await show(tester);
    expect(page()?.onScreen, isTrue);
    await tester.tap(_key('agent-browser-pip-dock'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.mode, AgentBrowserPipMode.docked);
    expect(window(tester).height, 64);
    expect(window(tester).top, greaterThanOrEqualTo(_header));
    expect(page()?.onScreen, isFalse, reason: 'what is not seen is not read');
    await tester.tap(_key('agent-browser-pip-dock'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.mode, AgentBrowserPipMode.open);
    expect(page()?.onScreen, isTrue);
  });

  testWidgets('dragged over the chat the chat never moves; dropped on the '
      'target it closes and «Ver» stays while Hermes works', (tester) async {
    await pump(tester);
    await show(tester);
    final row = tester.getRect(_key('row-5'));
    final before = window(tester).top;
    final grip = tester.getTopLeft(_key('agent-browser-pip-bar')) +
        const Offset(32, 24);
    final gesture = await tester.startGesture(grip);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump();
    }
    expect(window(tester).top, greaterThan(before));
    expect(tester.getRect(_key('row-5')), row, reason: 'the chat stays put');
    // Further down, onto the close target.
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
    }
    expect(_key('agent-browser-pip-close-target'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key('agent-browser-pip'), findsNothing);
    expect(controller.mode, AgentBrowserPipMode.pill);
    expect(_key('agent-browser-pip-watch'), findsOneWidget);
    expect(find.text('Ver news.example'), findsOneWidget);
    expect(
      tester.getRect(_key('agent-browser-pip-watch')).top,
      greaterThanOrEqualTo(_header),
    );
    expect(tester.getSize(_key('agent-browser-pip-watch')).height,
        greaterThanOrEqualTo(48));
    // «Ver» opens it again on the same page.
    await tester.tap(_key('agent-browser-pip-watch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key('agent-browser-pip'), findsOneWidget);
    expect(
      tester.widget<InAppBrowserScreen>(find.byType(InAppBrowserScreen))
          .initialUrl,
      _page,
    );
  });

  testWidgets('dragged up to the top it anchors itself', (tester) async {
    await pump(tester);
    await show(tester);
    controller.moveTo(_header + 200);
    await tester.pump();
    final grip = tester.getTopLeft(_key('agent-browser-pip-bar')) +
        const Offset(32, 24);
    final gesture = await tester.startGesture(grip);
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(controller.mode, AgentBrowserPipMode.docked);
    expect(window(tester).height, 64);
  });

  testWidgets('TalkBack closes it without dragging: labelled region and '
      'buttons', (tester) async {
    final handle = tester.ensureSemantics();
    working.value = false;
    await pump(tester);
    await show(tester);
    expect(
      find.bySemanticsLabel(RegExp('^Navegador de Hermes, ')),
      findsOneWidget,
    );
    // Each action is a button with its spoken name: no drag is needed.
    expect(find.byTooltip('Anclar arriba'), findsOneWidget);
    expect(find.byTooltip('Ampliar'), findsOneWidget);
    expect(find.byTooltip('Cerrar el navegador'), findsOneWidget);
    await tester.tap(_key('agent-browser-pip-close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Hermes finished: nothing is left over the chat.
    expect(controller.mode, AgentBrowserPipMode.hidden);
    expect(_key('agent-browser-pip-watch'), findsNothing);
    handle.dispose();
  });

  testWidgets('system Back puts the window away and leaves the chat', (
    tester,
  ) async {
    await pump(tester);
    await show(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key('agent-browser-pip'), findsNothing);
    expect(_key('chat-under'), findsOneWidget);
  });

  testWidgets('reduced motion: the window is simply there', (tester) async {
    await pump(tester, reduce: true);
    controller.show(_page, 'News');
    await tester.pump();
    expect(_key('agent-browser-pip'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('agent-browser-pip'),
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
      findsNothing,
    );
    final fades = tester.widgetList<Opacity>(
      find.ancestor(
        of: _key('agent-browser-pip-bar'),
        matching: find.byType(Opacity),
      ),
    );
    expect(fades.every((o) => o.opacity == 1), isTrue);
  });

  testWidgets('Hermes finished: you drive the page', (tester) async {
    await pump(tester);
    await show(tester);
    working.value = false;
    await tester.pump();
    expect(find.text('TERMINADO'), findsOneWidget);
    expect(find.text('Controlas tú'), findsOneWidget);
    expect(find.text('EN VIVO'), findsNothing);
  });

  testWidgets('offline: it says so and «Reintentar» is the chat\'s own', (
    tester,
  ) async {
    await pump(tester);
    await show(tester);
    connected.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'the bar fits at 360 dp');
    expect(find.text('SIN CONEXIÓN'), findsOneWidget);
    expect(find.byTooltip('Reintentar'), findsOneWidget);
    await tester.tap(_key('agent-browser-pip-retry'));
    expect(retries, 1);
    connected.value = true;
    await tester.pump();
    expect(_key('agent-browser-pip-retry'), findsNothing);
  });

  testWidgets('«Ampliar» opens the full browser on the page and puts the '
      'window away', (tester) async {
    await pump(tester);
    await show(tester);
    await tester.tap(_key('agent-browser-pip-expand'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(expanded, hasLength(1));
    expect(expanded.single.$2, 'News');
    expect(expanded.single.$3, isTrue);
    expect(_key('agent-browser-pip'), findsNothing);
    expect(controller.mode, AgentBrowserPipMode.pill);
  });

  testWidgets('the agent closing its page closes the window, never the chat', (
    tester,
  ) async {
    await pump(tester);
    await show(tester);
    bridge.onAgentPreviewEvent(
      connectionId: 'conn-a',
      sessionId: 'rt-1',
      type: 'preview.close',
      payload: const {},
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key('agent-browser-pip'), findsNothing);
    expect(controller.mode, AgentBrowserPipMode.hidden);
    expect(_key('chat-under'), findsOneWidget);
  });

  PreviewBridgeRequest read(String connection, String session) =>
      PreviewBridgeRequest(
        method: 'preview.read',
        connectionId: connection,
        sessionId: session,
        params: const {},
        isOpen: () => true,
      );

  testWidgets('with the window open, only its own chat\'s agent reads it', (
    tester,
  ) async {
    await pump(tester);
    await show(tester);
    web.last.javaScriptResponder = (script) =>
        script == agentPreviewTextScript ? '"Hola desde la ventana"' : '';
    // Another connection, or another session of this one, is declined.
    expect((await bridge.answer(read('conn-b', 'rt-1'))).notShown, isTrue);
    expect((await bridge.answer(read('conn-a', 'rt-2'))).notShown, isTrue);
    // This chat's agent reads the page it sees.
    final answer = bridge.answer(read('conn-a', 'rt-1'));
    await tester.pump();
    final own = await answer;
    expect(own.notShown, isFalse);
    expect(
      (jsonDecode(own.value) as Map<String, dynamic>)['text'],
      'Hola desde la ventana',
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the agent\'s page: «Ver» first, one tap opens the window '
      '(mock 138 v2)', (tester) async {
    await pump(tester);
    controller.offer(_page, 'News');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key('agent-browser-pip-watch'), findsOneWidget);
    expect(_key('agent-browser-pip'), findsNothing);
    expect(find.byType(InAppBrowserScreen), findsNothing);
    // Until the user looks, the agent has no page to read.
    expect(page(), isNull);
    await tester.tap(_key('agent-browser-pip-watch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key('agent-browser-pip'), findsOneWidget);
    final browser = tester.widget<InAppBrowserScreen>(
      find.byType(InAppBrowserScreen),
    );
    expect(browser.initialUrl, _page);
    expect(browser.agentLabel, 'News');
    expect(browser.openedByAgent, isTrue);
    expect(page()?.onScreen, isTrue);
  });

  testWidgets('a window the user already has open shows the agent\'s next '
      'page at once', (tester) async {
    await pump(tester);
    await show(tester);
    final next = Uri.parse('https://news.example/tomorrow');
    controller.offer(next, 'Mañana');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key('agent-browser-pip-watch'), findsNothing);
    expect(
      tester
          .widget<InAppBrowserScreen>(find.byType(InAppBrowserScreen))
          .initialUrl,
      next,
    );
  });

  testWidgets('«Ver» says «en vivo» while Hermes works', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    controller.offer(_page, 'News');
    await tester.pump();
    expect(
      find.bySemanticsLabel('Ver el navegador de Hermes, news.example, en vivo'),
      findsOneWidget,
    );
    working.value = false;
    await tester.pump();
    expect(
      find.bySemanticsLabel('Ver el navegador de Hermes, news.example'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('parked right above the composer it stays; only past it does '
      'it close', (tester) async {
    await pump(tester);
    await show(tester);
    // Lowest place: the room's bottom (800 − 96 − 48 − 8) minus its height.
    final lowest = _height - _composer - _notch - 8 - window(tester).height;
    final gesture = await tester.startGesture(
      tester.getTopLeft(_key('agent-browser-pip-bar')) + const Offset(32, 24),
    );
    for (var i = 0; i < 200 && window(tester).top < lowest + 12; i++) {
      await gesture.moveBy(const Offset(0, 4));
      await tester.pump();
    }
    expect(window(tester).top, greaterThanOrEqualTo(lowest + 12));
    expect(window(tester).top, lessThan(lowest + 28));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.mode, AgentBrowserPipMode.open);
    expect(window(tester).top, lowest, reason: 'parked at its lowest place');
  });

  testWidgets('a cancelled drag neither closes nor anchors it', (tester) async {
    await pump(tester);
    await show(tester);
    final before = window(tester).top;
    final gesture = await tester.startGesture(
      tester.getTopLeft(_key('agent-browser-pip-bar')) + const Offset(32, 24),
    );
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
    }
    expect(_key('agent-browser-pip-close-target'), findsOneWidget);
    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.mode, AgentBrowserPipMode.open);
    expect(window(tester).top, before);
    expect(_key('agent-browser-pip-close-target'), findsNothing);
  });

  // gint46: the chat writes its bottom bars' extent from a LayoutBuilder,
  // while it lays itself out. A layer that rebuilt right then threw
  // «setState() or markNeedsBuild() called during build» in every chat.
  testWidgets('the chat writes its bottom bars while it lays out: nothing '
      'rebuilds mid-build and the window follows on the next frame', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, _height);
    addTearDown(tester.view.reset);
    final extent = ValueNotifier<double>(_composer);
    final hidden = AgentBrowserPipController();
    var barsNow = _composer;
    late StateSetter relayout;
    Widget layer(AgentBrowserPipController pip) => Positioned.fill(
      child: AgentBrowserPipLayer(
        controller: pip,
        topInset: _header,
        bottomBars: extent,
        bottomClearance: _notch,
        agentConnectionId: 'conn-a',
        agentSessionId: () => 'rt-1',
        changes: working,
        working: () => working.value,
        connected: () => connected.value,
        onExpand: (url, label, byAgent) {},
        bridge: bridge,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromMode(AppThemeMode.dark),
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              relayout = setState;
              return Stack(
                children: [
                  // As chat_screen does: the extent is written during layout.
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (extent.value != barsNow) extent.value = barsNow;
                        return const SizedBox.expand();
                      },
                    ),
                  ),
                  layer(controller),
                  layer(hidden),
                ],
              );
            },
          ),
        ),
      ),
    );
    await show(tester);
    expect(window(tester).height, greaterThan(64));

    // The keyboard comes up: the composer rides on it.
    relayout(() => barsNow = _composer + 300);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(extent.value, _composer + 300);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      window(tester).height,
      64,
      reason: 'no room: it anchors itself; ${why(tester, extent.value)}',
    );
    expect(
      window(tester).bottom,
      lessThanOrEqualTo(_height - extent.value - _notch),
    );

    relayout(() => barsNow = _composer);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(window(tester).height, greaterThan(64));
    expect(
      window(tester).bottom,
      lessThanOrEqualTo(_height - _composer - _notch),
    );
    expect(hidden.mode, AgentBrowserPipMode.hidden);
  });

  // gint47: the window's own Navigator took the focus when it opened, so
  // the composer lost its keyboard and the layer believed the user was
  // typing in the browser (it never anchored itself for the keyboard).
  testWidgets('opening the window leaves the composer\'s focus alone', (
    tester,
  ) async {
    final typing = FocusNode();
    addTearDown(typing.dispose);
    await pump(tester, composerField: typing);
    typing.requestFocus();
    await tester.pump();
    expect(typing.hasPrimaryFocus, isTrue);
    await show(tester);
    expect(_key('agent-browser-pip'), findsOneWidget);
    expect(typing.hasPrimaryFocus, isTrue);
    // Typing with the keyboard up: no room, so it anchors itself.
    bars.value = _composer + 300;
    await tester.pump();
    expect(window(tester).height, 64);
    expect(typing.hasPrimaryFocus, isTrue);
  });

  testWidgets('with the keyboard up there is no room: it anchors itself', (
    tester,
  ) async {
    await pump(tester);
    await show(tester);
    // The composer rides on the keyboard.
    bars.value = _composer + 300;
    await tester.pump();
    expect(window(tester).height, 64, reason: why(tester, bars.value));
    expect(
      window(tester).bottom,
      lessThanOrEqualTo(tester.getRect(_key('composer')).top - _notch),
    );
    bars.value = _composer;
    await tester.pump();
    expect(window(tester).height, greaterThan(64));
  });

  // The keyboard is the window's own: the user types in its address bar.
  // It stays open (shorter) instead of anchoring away from the field.
  testWidgets('typing in the window\'s address bar it does not anchor '
      'itself', (tester) async {
    await pump(tester);
    await show(tester);
    final address = find.descendant(
      of: _key('agent-browser-pip'),
      matching: find.byKey(const ValueKey('in-app-browser-address')),
    );
    expect(address, findsOneWidget);
    tester.widget<TextField>(address).focusNode!.requestFocus();
    await tester.pump();
    bars.value = _composer + 300;
    await tester.pump();
    // Room: 800 − 396 − 48 − 8 − 128 = 220.
    expect(window(tester).height, 220, reason: why(tester, bars.value));
    // The field lets go: no room, so now it anchors itself.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump();
    expect(window(tester).height, 64, reason: why(tester, bars.value));
  });
}
