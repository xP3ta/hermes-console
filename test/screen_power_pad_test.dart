import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screen/trackpad_pad.dart';
import 'package:hermes_android/core/screens/screen_peek_screen.dart';
import 'package:hermes_android/core/screens/takeover_screen.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

const _heldByHuman = TuiGatewayRpcError(
  'display.stop',
  'a human holds this screen',
  code: 5300,
  data: {'code': 'viewer_mismatch'},
);

class _Pad implements PadSink {
  final events = <String>[];

  @override
  void move(double dx, double dy) => events.add('move');

  @override
  void click(int mask) => events.add('click$mask');

  @override
  void down(int mask) => events.add('down$mask');

  @override
  void up(int mask) => events.add('up$mask');

  @override
  void wheel(int steps) => events.add('wheel$steps');
}

Map<String, dynamic> _runtime({bool running = true}) => {
  'supported': true,
  'installed': true,
  'running': running,
  'blocker': '',
  'lease': {'holder': 'agent', 'epoch': 1, 'since': 1},
};

ScreenController _controller(DisplayRpc rpc) => ScreenController(
  rpc: rpc,
  leasePayloads: const Stream.empty(),
  dashboardBase: () => Uri.parse('http://127.0.0.1:9119'),
);

Future<void> _pump(WidgetTester tester, Widget home) => tester.pumpWidget(
  MaterialApp(
    locale: const Locale('es'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: home,
  ),
);

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  late FakeWebViewPlatform webPlatform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    webPlatform = FakeWebViewPlatform();
    WebViewPlatform.instance = webPlatform;
  });

  group('display.stop', () {
    test('is a write: refused on a read-only connection', () {
      expect(
        TuiGatewayClient.displayRpcAllowed('display.stop', readOnly: true),
        isFalse,
      );
      expect(
        TuiGatewayClient.displayRpcAllowed('display.stop', readOnly: false),
        isTrue,
      );
    });

    test('sends the profile, and force only when asked', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final controller = _controller((method, params) async {
        calls.add((method, params));
        return _runtime(running: false);
      });
      final stopped = await controller.stop(profile: 'work');
      expect(stopped.running, isFalse);
      await controller.stop(profile: 'work', force: true);
      expect(calls[0].$1, 'display.stop');
      expect(calls[0].$2, {'profile': 'work'});
      expect(calls[1].$2, {'profile': 'work', 'force': true});
    });

    test('tells a human hold from any other failure', () async {
      Future<ScreenFailureKind> kindOf(Object error) async {
        try {
          await _controller((_, _) async => throw error).stop();
        } on ScreenControllerException catch (e) {
          return e.kind;
        }
        throw StateError('no failure');
      }

      expect(await kindOf(_heldByHuman), ScreenFailureKind.humanControl);
      expect(
        await kindOf(
          const TuiGatewayRpcError('display.stop', 'boom', code: 5300),
        ),
        ScreenFailureKind.stopFailed,
      );
      expect(await kindOf(StateError('x')), ScreenFailureKind.stopFailed);
      expect(
        await kindOf(
          const TuiGatewayRpcError('display.stop', 'nope', code: -32601),
        ),
        ScreenFailureKind.outdated,
      );
    });
  });

  group('peek', () {
    Future<List<(String, Map<String, dynamic>)>> pumpPeek(
      WidgetTester tester, {
      bool readOnly = false,
      Object? stopError,
    }) async {
      final calls = <(String, Map<String, dynamic>)>[];
      final controller = _controller((method, params) async {
        calls.add((method, params));
        if (method == 'display.stop') {
          if (stopError != null) throw stopError;
          return _runtime(running: false);
        }
        if (method == 'display.thumbnail') {
          return {'data_url': 'data:image/png;base64,$_png'};
        }
        return _runtime();
      });
      await _pump(
        tester,
        ScreenPeekScreen(
          controller: controller,
          profile: 'forja',
          botName: 'Forja',
          readOnly: readOnly,
        ),
      );
      await tester.pump();
      await tester.pump();
      return calls;
    }

    testWidgets('header names the bot and the state', (tester) async {
      await pumpPeek(tester);
      expect(find.text('Pantalla de Forja'), findsOneWidget);
      expect(find.text('Encendido'), findsOneWidget);
    });

    testWidgets('Apagar asks first; Cancelar leaves the computer on', (
      tester,
    ) async {
      final calls = await pumpPeek(tester);
      await tester.tap(find.byKey(const ValueKey('screen-peek-power')));
      await tester.pumpAndSettle();
      expect(find.text('¿Apagar el ordenador de Forja?'), findsOneWidget);
      expect(find.textContaining('Se cierran sus ventanas'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-power-cancel')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.$1 == 'display.stop'), isEmpty);
      expect(find.text('Encendido'), findsOneWidget);
    });

    testWidgets('confirming stops it and the peek shows it off', (
      tester,
    ) async {
      final calls = await pumpPeek(tester);
      await tester.tap(find.byKey(const ValueKey('screen-peek-power')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('screen-power-confirm')));
      await tester.pumpAndSettle();
      final stop = calls.singleWhere((c) => c.$1 == 'display.stop');
      expect(stop.$2, {'profile': 'forja'}, reason: 'not forced from the peek');
      expect(find.text('Apagado'), findsOneWidget);
      expect(find.text('Encender el ordenador del bot'), findsOneWidget);
    });

    testWidgets('a person holding the screen refuses it and it stays on', (
      tester,
    ) async {
      final calls = await pumpPeek(tester, stopError: _heldByHuman);
      await tester.tap(find.byKey(const ValueKey('screen-peek-power')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('screen-power-confirm')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.$1 == 'display.stop'), hasLength(1));
      expect(find.text('Encendido'), findsOneWidget);
      expect(find.text('Asumir el control'), findsOneWidget);
    });

    testWidgets('a read-only connection cannot turn it off', (tester) async {
      await pumpPeek(tester, readOnly: true);
      expect(find.byKey(const ValueKey('screen-peek-power')), findsNothing);
      expect(find.text('Asumir el control'), findsNothing);
    });
  });

  group('takeover', () {
    ScreenController active(
      List<(String, Map<String, dynamic>)> calls, {
      Object? stopError,
    }) => _controller((method, params) async {
      calls.add((method, params));
      switch (method) {
        case 'display.observe':
          return {
            ..._runtime(),
            'ticket': 't',
            'viewer_id': 'viewer-1',
            'path': '/api/display/ws',
          };
        case 'display.lease.acquire':
          return {
            'lease': {
              'holder': 'human',
              'viewer_hash': displayViewerHash('viewer-1'),
              'epoch': 2,
              'since': 1,
            },
          };
        case 'display.stop':
          if (stopError != null) throw stopError;
          return _runtime(running: false);
      }
      return _runtime();
    });

    Future<void> pumpActive(
      WidgetTester tester,
      ScreenController controller, {
      bool readOnly = false,
    }) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TakeoverScreen(
                  controller: controller,
                  profile: 'forja',
                  botName: 'Forja',
                  readOnly: readOnly,
                ),
              ),
            ),
            child: const Text('abrir'),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('header, state pill and the bar of text pills', (tester) async {
      await pumpActive(tester, active([]));
      expect(find.text('Pantalla de Forja'), findsOneWidget);
      expect(find.text('Controlando'), findsOneWidget);
      expect(find.text('Tienes el control'), findsOneWidget);
      for (final label in ['Trackpad', 'Teclado', 'Apagar', 'Devolver']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('zoom buttons drive the page and its percent follows', (
      tester,
    ) async {
      await pumpActive(tester, active([]));
      final platform = webPlatform;
      await tester.tap(find.byKey(const ValueKey('screen-zoom-in')));
      await tester.pump();
      expect(platform.last.javaScriptCalls.last, contains('zoomIn()'));
      platform.last.channelHandlers['TakeoverChannel']!(
        const JavaScriptMessage(message: 'zoom:125'),
      );
      await tester.pump();
      expect(find.text('125%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-zoom-out')));
      await tester.pump();
      expect(platform.last.javaScriptCalls.last, contains('zoomOut()'));
    });

    testWidgets('Apagar confirms, then stops (forced: the hold is ours)', (
      tester,
    ) async {
      final calls = <(String, Map<String, dynamic>)>[];
      await pumpActive(tester, active(calls));

      await tester.tap(find.text('Apagar'));
      await tester.pumpAndSettle();
      expect(find.text('¿Apagar el ordenador de Forja?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-power-cancel')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.$1 == 'display.stop'), isEmpty);
      expect(find.text('Pantalla de Forja'), findsOneWidget);

      await tester.tap(find.text('Apagar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('screen-power-confirm')));
      await tester.pumpAndSettle();
      final stop = calls.singleWhere((c) => c.$1 == 'display.stop');
      expect(stop.$2, {'profile': 'forja', 'force': true});
      // Back to the list: the screen closed with the computer.
      expect(find.text('Pantalla de Forja'), findsNothing);
      expect(find.text('abrir'), findsOneWidget);
    });

    testWidgets('a refused stop keeps the screen open', (tester) async {
      final calls = <(String, Map<String, dynamic>)>[];
      await pumpActive(tester, active(calls, stopError: _heldByHuman));
      await tester.tap(find.text('Apagar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('screen-power-confirm')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.$1 == 'display.stop'), hasLength(1));
      expect(find.text('Pantalla de Forja'), findsOneWidget);
      expect(find.text('Devolver'), findsOneWidget);
    });
  });

  group('trackpad', () {
    Future<_Pad> pumpPad(WidgetTester tester) async {
      final sink = _Pad();
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, Scaffold(body: ScreenTrackpad(sink: sink)));
      return sink;
    }

    Offset surface(WidgetTester tester, {double dx = 0, double dy = 0}) =>
        tester.getTopLeft(find.byKey(const ValueKey('screen-trackpad'))) +
        Offset(100 + dx, 100 + dy);

    testWidgets('a drag moves the pointer; nothing clicks', (tester) async {
      final sink = await pumpPad(tester);
      final gesture = await tester.startGesture(surface(tester));
      await gesture.moveBy(const Offset(30, 0));
      await gesture.moveBy(const Offset(0, 20));
      await gesture.up();
      await tester.pump();
      expect(sink.events.where((e) => e == 'move'), hasLength(2));
      expect(sink.events.where((e) => e.startsWith('click')), isEmpty);
    });

    testWidgets('a short tap clicks, two taps click twice', (tester) async {
      final sink = await pumpPad(tester);
      for (var i = 0; i < 2; i++) {
        final gesture = await tester.startGesture(surface(tester));
        await gesture.up();
        await tester.pump();
      }
      expect(sink.events, ['click1', 'click1']);
    });

    testWidgets('hold then drag drags with the left button', (tester) async {
      final sink = await pumpPad(tester);
      final gesture = await tester.startGesture(surface(tester));
      await tester.pump(padHoldToDrag + const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.up();
      await tester.pump();
      expect(sink.events, ['down1', 'move', 'up1']);
    });

    testWidgets('a second tap that moves also drags', (tester) async {
      final sink = await pumpPad(tester);
      var gesture = await tester.startGesture(surface(tester));
      await gesture.up();
      gesture = await tester.startGesture(surface(tester));
      await gesture.moveBy(const Offset(30, 0));
      await gesture.up();
      await tester.pump();
      expect(sink.events, ['click1', 'down1', 'move', 'up1']);
    });

    testWidgets('the rail scrolls: dragging up scrolls the content down', (
      tester,
    ) async {
      final sink = await pumpPad(tester);
      final rail = tester.getCenter(
        find.byKey(const ValueKey('screen-trackpad-rail')),
      );
      final gesture = await tester.startGesture(rail);
      await gesture.moveBy(const Offset(0, -padWheelStep * 2));
      await gesture.moveBy(const Offset(0, padWheelStep));
      await gesture.up();
      await tester.pump();
      expect(sink.events, ['wheel2', 'wheel-1']);
    });

    testWidgets('two fingers scroll and never move the pointer', (
      tester,
    ) async {
      final sink = await pumpPad(tester);
      final a = await tester.startGesture(surface(tester, dx: -30));
      final b = await tester.startGesture(surface(tester, dx: 30));
      await a.moveBy(const Offset(0, padWheelStep * 2));
      await b.moveBy(const Offset(0, padWheelStep * 2));
      await a.up();
      await b.up();
      await tester.pump();
      expect(sink.events.where((e) => e == 'move'), isEmpty);
      expect(sink.events.any((e) => e.startsWith('wheel-')), isTrue);
    });

    testWidgets('a two-finger tap right-clicks', (tester) async {
      final sink = await pumpPad(tester);
      final a = await tester.startGesture(surface(tester, dx: -30));
      final b = await tester.startGesture(surface(tester, dx: 30));
      await a.up();
      await b.up();
      await tester.pump();
      expect(sink.events, ['click4']);
    });

    testWidgets('the three buttons click left, wheel and right', (
      tester,
    ) async {
      final sink = await pumpPad(tester);
      await tester.tap(find.text('Clic'));
      await tester.tap(find.text('Rueda'));
      await tester.tap(find.text('Clic derecho'));
      expect(sink.events, ['click1', 'click2', 'click4']);
    });

    testWidgets('a pad torn down mid-drag lets the button go', (tester) async {
      final sink = await pumpPad(tester);
      final gesture = await tester.startGesture(surface(tester));
      await tester.pump(padHoldToDrag + const Duration(milliseconds: 20));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(sink.events, ['down1', 'up1']);
      await gesture.up();
    });
  });
}
