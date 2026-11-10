import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screens/takeover_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

void main() {
  late FakeWebViewPlatform webPlatform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    webPlatform = FakeWebViewPlatform();
    WebViewPlatform.instance = webPlatform;
  });

  testWidgets('o controle ativo oferece teclado e alternância de touchpad', (
    tester,
  ) async {
    await _pumpActive(tester);
    expect(find.text('Teclado'), findsOneWidget);
    expect(find.text('Trackpad'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-trackpad')), findsNothing);
  });

  testWidgets('o botão de teclado mostra e esconde o teclado da página', (
    tester,
  ) async {
    await _pumpActive(tester);

    await tester.tap(find.text('Teclado'));
    await tester.pump();
    expect(webPlatform.last.javaScriptCalls.last, contains('showKeyboard()'));

    webPlatform.last.channelHandlers['TakeoverChannel']!(
      const JavaScriptMessage(message: 'kbd-on'),
    );
    await tester.pump();

    await tester.tap(find.text('Teclado'));
    await tester.pump();
    expect(webPlatform.last.javaScriptCalls.last, contains('hideKeyboard()'));

    webPlatform.last.channelHandlers['TakeoverChannel']!(
      const JavaScriptMessage(message: 'kbd-off'),
    );
    await tester.pump();
  });

  testWidgets('o toggle de touchpad liga o modo na página e persiste', (
    tester,
  ) async {
    await _pumpActive(tester);

    // Direct mode is the default: no pad command ever reaches the page.
    await tester.tap(find.byType(TakeoverScreen), warnIfMissed: false);
    await tester.pump();
    expect(
      webPlatform.last.javaScriptCalls.where(
        (call) => call.contains('setTouchpad'),
      ),
      isEmpty,
    );

    await tester.tap(find.text('Trackpad'));
    await tester.pump();
    expect(
      webPlatform.last.javaScriptCalls.last,
      contains('setTouchpad(true)'),
    );
    expect(find.byKey(const ValueKey('screen-trackpad')), findsOneWidget);
    expect(find.text('Clic derecho'), findsOneWidget);
    final store = await SharedPreferences.getInstance();
    expect(store.getBool('screen_touchpad_mode'), isTrue);

    await tester.tap(find.text('Trackpad'));
    await tester.pump();
    expect(
      webPlatform.last.javaScriptCalls.last,
      contains('setTouchpad(false)'),
    );
    expect(find.byKey(const ValueKey('screen-trackpad')), findsNothing);
    expect(find.text('Toca directamente en la pantalla'), findsOneWidget);
  });

  testWidgets('uma reconexão reaplica o modo touchpad na página', (
    tester,
  ) async {
    await _pumpActive(tester);

    await tester.tap(find.text('Trackpad'));
    await tester.pump();
    webPlatform.last.javaScriptCalls.clear();

    // The page reloads on reconnect and starts with the pad off; the
    // connected token must switch it back on.
    webPlatform.last.channelHandlers['TakeoverChannel']!(
      const JavaScriptMessage(message: 'connected'),
    );
    await tester.pump();
    expect(
      webPlatform.last.javaScriptCalls.last,
      contains('setTouchpad(true)'),
    );
  });

  testWidgets('a página já carrega com o modo touchpad salvo', (tester) async {
    SharedPreferences.setMockInitialValues({'screen_touchpad_mode': true});
    await _pumpActive(tester);

    final page = webPlatform.last.loadedRequests.last;
    expect(page.queryParameters['pad'], '1');
    // The app draws its own controls around the page.
    expect(page.queryParameters['chrome'], '0');
    expect(find.byKey(const ValueKey('screen-trackpad')), findsOneWidget);
  });

  group('the pad fits short windows', () {
    Future<void> pumpWith(
      WidgetTester tester, {
      required Size size,
      double keyboard = 0,
      double textScale = 1,
    }) async {
      SharedPreferences.setMockInitialValues({'screen_touchpad_mode': true});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpActive(tester);
      await tester.pump();
    }

    testWidgets('a phone on its side keeps the buttons, not the surface', (
      tester,
    ) async {
      await pumpWith(tester, size: const Size(740, 360));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('screen-trackpad')), findsNothing);
      expect(find.text('Clic derecho'), findsOneWidget);
      expect(find.byKey(const ValueKey('screen-pill-power')), findsOneWidget);
    });

    testWidgets('the keyboard up leaves only the buttons', (tester) async {
      await pumpWith(tester, size: const Size(360, 640), keyboard: 300);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('screen-trackpad')), findsNothing);
      expect(find.text('Clic'), findsOneWidget);
    });

    testWidgets('large text still fits and keeps the surface', (tester) async {
      await pumpWith(tester, size: const Size(360, 780), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.text('Clic derecho'), findsOneWidget);
    });

    testWidgets('a tall phone gets the whole surface', (tester) async {
      await pumpWith(tester, size: const Size(360, 780));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('screen-trackpad'))).height,
        210,
      );
    });
  });
}

/// Pumps a takeover screen already in the active phase.
Future<void> _pumpActive(WidgetTester tester) async {
  await _pump(tester, TakeoverScreen(controller: _controllerWithLease()));
  // The lease round-trips through async gateway calls before actions appear.
  await tester.pump();
  await tester.pump();
}

Future<void> _pump(WidgetTester tester, Widget home) {
  return tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: home,
    ),
  );
}

/// A controller whose display is running and whose lease is ours.
ScreenController _controllerWithLease() => ScreenController(
  rpc: (method, params) async {
    if (method == 'display.observe') {
      return {
        ..._runtime(),
        'ticket': 'ticket-1',
        'viewer_id': 'viewer-1',
        'path': '/api/display/ws',
      };
    }
    if (method == 'display.lease.acquire') {
      return {
        'lease': {
          'holder': 'human',
          'viewer_hash': displayViewerHash('viewer-1'),
          'epoch': 1,
          'since': 1,
        },
      };
    }
    return _runtime();
  },
  leasePayloads: const Stream.empty(),
  dashboardBase: () => Uri.parse('http://127.0.0.1:9119'),
);

Map<String, dynamic> _runtime() => {
  'profile': 'default',
  'supported': true,
  'installed': true,
  'missing': <String>[],
  'running': true,
  'geometry': '1280x800',
  'blocker': '',
  'lease': {'holder': 'agent', 'epoch': 1, 'since': 1},
  'profile_key': 'default',
};
