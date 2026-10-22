import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screens/screen_peek_screen.dart';
import 'package:hermes_android/core/screens/takeover_screen.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  late FakeWebViewPlatform webPlatform;

  setUp(() {
    webPlatform = FakeWebViewPlatform();
    WebViewPlatform.instance = webPlatform;
  });

  testWidgets('el vistazo muestra el fotograma y ofrece tomar el control', (
    tester,
  ) async {
    final calls = <String>[];
    final controller = _controller((method, params) async {
      calls.add(method);
      if (method == 'display.thumbnail') {
        return {'data_url': 'data:image/png;base64,$_png', 'suppressed': null};
      }
      return _runtime();
    });
    await _pump(
      tester,
      ScreenPeekScreen(controller: controller, profile: 'work'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Pantalla del bot'), findsOneWidget);
    expect(find.text('Asumir el control'), findsOneWidget);
    expect(find.text('Se actualiza cada 4 s'), findsOneWidget);
    expect(calls, containsAll(['display.status', 'display.thumbnail']));
  });

  testWidgets('un vistazo suprimido avisa y solo lectura no toma el control', (
    tester,
  ) async {
    final controller = _controller((method, params) async {
      if (method == 'display.thumbnail') {
        return {'data_url': '', 'suppressed': 'human_has_control'};
      }
      return _runtime();
    });
    await _pump(
      tester,
      ScreenPeekScreen(controller: controller, readOnly: true),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'Un humano controla la pantalla. Los fotogramas están en pausa.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Conexión de solo lectura. No se puede tomar el control.'),
      findsOneWidget,
    );
    expect(find.text('Asumir el control'), findsNothing);
  });

  testWidgets('el vistazo distingue parada, no instalada y method not found', (
    tester,
  ) async {
    await _pump(
      tester,
      ScreenPeekScreen(
        key: const ValueKey('stopped'),
        controller: _controller(
          (method, params) async => _runtime(running: false, installed: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('El ordenador del bot está parado.'), findsOneWidget);
    expect(find.text('Encender el ordenador del bot'), findsOneWidget);

    await _pump(
      tester,
      ScreenPeekScreen(
        key: const ValueKey('missing'),
        controller: _controller(
          (method, params) async => _runtime(installed: false),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('La pantalla no está instalada en esta instancia.'),
      findsOneWidget,
    );

    await _pump(
      tester,
      ScreenPeekScreen(
        key: const ValueKey('unlisted'),
        controller: _controller(
          (method, params) async => throw const TuiGatewayRpcError(
            'display.status',
            'missing',
            code: -32601,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('La pantalla no está instalada en esta instancia.'),
      findsOneWidget,
    );
  });

  testWidgets('encender el ordenador del bot retoma el vistazo', (
    tester,
  ) async {
    var started = false;
    final controller = _controller((method, params) async {
      if (method == 'display.start') {
        started = true;
        return _runtime();
      }
      if (method == 'display.thumbnail') {
        return {'data_url': 'data:image/png;base64,$_png'};
      }
      return _runtime(running: started);
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    await tester.tap(find.text('Encender el ordenador del bot'));
    await tester.pump();
    await tester.pump();
    expect(started, isTrue);
    expect(find.text('Asumir el control'), findsOneWidget);
  });

  testWidgets('el vistazo vuelve a preguntar al cumplirse el intervalo', (
    tester,
  ) async {
    var polls = 0;
    final controller = _controller((method, params) async {
      if (method == 'display.status') polls += 1;
      return _runtime(running: false);
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    final first = polls;
    expect(first, greaterThan(0));
    await tester.pump(screenPeekPollInterval);
    await tester.pump();
    expect(polls, greaterThan(first));
  });

  testWidgets('tomar el control abre noVNC y devolver suelta el lease', (
    tester,
  ) async {
    final calls = <String>[];
    final leases = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(leases.close);
    final controller = _controller((method, params) async {
      calls.add(method);
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
            'viewer_hash': 'hash-us',
            'epoch': 2,
            'since': 1,
          },
        };
      }
      return _runtime();
    }, leases: leases.stream);

    await _pump(
      tester,
      TakeoverScreen(controller: controller, profile: 'work'),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Tienes el control. Toca, arrastra y escribe con normalidad.'),
      findsOneWidget,
    );
    expect(calls, [
      'display.status',
      'display.observe',
      'display.lease.acquire',
    ]);
    expect(webPlatform.controllers, isNotEmpty);
    expect(webPlatform.last.javaScriptChannels, contains('TakeoverChannel'));
    final loaded = webPlatform.last.loadedRequests.single;
    expect(loaded.scheme, 'https');
    expect(loaded.host, 'appassets.androidplatform.net');
    expect(loaded.path, '/assets/novnc/bridge.html');
    expect(loaded.queryParameters['ws'], contains('display_ticket=ticket-1'));
    expect(loaded.queryParameters['connecting'], 'Conectando…');

    leases.add({
      'lease': {'holder': 'agent', 'epoch': 1, 'since': 0},
    });
    await tester.pump();
    expect(
      find.text('Tienes el control. Toca, arrastra y escribe con normalidad.'),
      findsOneWidget,
    );

    leases.add({
      'lease': {'holder': 'agent', 'epoch': 3, 'since': 2},
    });
    await tester.pump();
    expect(find.text('Otro cliente asumió el control.'), findsOneWidget);

    await tester.tap(find.text('Devolver'));
    await tester.pump();
    expect(calls.where((method) => method == 'display.lease.release'), [
      'display.lease.release',
    ]);
  });

  testWidgets('una pantalla parada se inicia y un bloqueo no ofrece el botón', (
    tester,
  ) async {
    var started = false;
    final controller = _controller((method, params) async {
      if (method == 'display.start') {
        started = true;
        return _runtime();
      }
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
            'viewer_hash': 'hash-us',
            'epoch': 1,
            'since': 1,
          },
        };
      }
      return _runtime(running: started, blocker: started ? '' : '');
    });
    await _pump(
      tester,
      TakeoverScreen(key: const ValueKey('start'), controller: controller),
    );
    await tester.pump();
    expect(find.text('Iniciar pantalla'), findsOneWidget);
    await tester.tap(find.text('Iniciar pantalla'));
    await tester.pump();
    await tester.pump();
    expect(started, isTrue);
    expect(
      find.text('Tienes el control. Toca, arrastra y escribe con normalidad.'),
      findsOneWidget,
    );

    await _pump(
      tester,
      TakeoverScreen(
        key: const ValueKey('blocked'),
        controller: _controller(
          (method, params) async => _runtime(running: false, blocker: 'memory'),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('La pantalla está bloqueada y no se puede iniciar.'),
      findsOneWidget,
    );
    expect(find.text('Iniciar pantalla'), findsNothing);
  });

  testWidgets('sin display y en solo lectura no se abre el websocket', (
    tester,
  ) async {
    await _pump(
      tester,
      TakeoverScreen(
        key: const ValueKey('unsupported'),
        controller: _controller(
          (method, params) async =>
              _runtime(supported: false, installed: false),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        'La pantalla no está instalada en esta instancia. Instálala desde Hermes Desktop.',
      ),
      findsOneWidget,
    );
    expect(webPlatform.controllers, isEmpty);

    await _pump(
      tester,
      TakeoverScreen(
        key: const ValueKey('readonly'),
        controller: _controller((method, params) async => _runtime()),
        readOnly: true,
      ),
    );
    await tester.pump();
    expect(
      find.text('Conexión de solo lectura. No se puede tomar el control.'),
      findsOneWidget,
    );
    expect(webPlatform.controllers, isEmpty);
  });

  testWidgets('a lost socket mints a new display ticket', (tester) async {
    var observes = 0;
    final controller = _controller((method, params) async {
      if (method == 'display.observe') {
        observes += 1;
        return {
          ..._runtime(),
          'ticket': 'ticket-$observes',
          'viewer_id': 'viewer-1',
          'path': '/api/display/ws',
        };
      }
      if (method == 'display.lease.acquire') {
        return {
          'lease': {
            'holder': 'human',
            'viewer_hash': 'hash-us',
            'epoch': 2,
            'since': 1,
          },
        };
      }
      return _runtime();
    });
    await _pump(tester, TakeoverScreen(controller: controller));
    await tester.pump();
    await tester.pump();
    webPlatform.last.channelHandlers['TakeoverChannel']!(
      const JavaScriptMessage(message: 'lost'),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(observes, 2);
    expect(
      webPlatform.last.loadedRequests.last.queryParameters['ws'],
      contains('display_ticket=ticket-2'),
    );
    expect(
      webPlatform.last.loadedRequests.last.queryParameters['ws'],
      isNot(contains('display_ticket=ticket-1')),
    );
  });

  testWidgets('a failure after acquire releases the lease', (tester) async {
    final calls = <String>[];
    final controller = ScreenController(
      rpc: (method, params) async {
        calls.add(method);
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
              'viewer_hash': 'hash-us',
              'epoch': 1,
              'since': 1,
            },
          };
        }
        return _runtime();
      },
      leasePayloads: const Stream.empty(),
      dashboardBase: () => throw StateError('asset host failed'),
    );
    await _pump(tester, TakeoverScreen(controller: controller));
    await tester.pump();
    await tester.pump();
    expect(calls, contains('display.lease.acquire'));
    expect(calls.where((method) => method == 'display.lease.release'), [
      'display.lease.release',
    ]);
    expect(
      find.text('No se pudo tomar el control de la pantalla.'),
      findsOneWidget,
    );
    expect(webPlatform.controllers, isEmpty);
  });

  testWidgets('leaving the screen releases the lease', (tester) async {
    final calls = <String>[];
    final controller = _controller((method, params) async {
      calls.add(method);
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
            'viewer_hash': 'hash-us',
            'epoch': 1,
            'since': 1,
          },
        };
      }
      return _runtime();
    });
    await _pump(tester, TakeoverScreen(controller: controller));
    await tester.pump();
    await tester.pump();
    expect(find.text('Devolver'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(calls.where((method) => method == 'display.lease.release'), [
      'display.lease.release',
    ]);
  });

  testWidgets('backgrounding the app releases the lease', (tester) async {
    final calls = <String>[];
    final controller = _controller((method, params) async {
      calls.add(method);
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
            'viewer_hash': 'hash-us',
            'epoch': 4,
            'since': 1,
          },
        };
      }
      return _runtime();
    });
    await _pump(tester, TakeoverScreen(controller: controller));
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(calls.where((method) => method == 'display.lease.release'), [
      'display.lease.release',
    ]);
  });

  testWidgets('a socket that keeps dropping stops retrying on its own', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await _pump(tester, TakeoverScreen(controller: _controller(gateway.call)));
    await tester.pump();
    await tester.pump();
    expect(gateway.count('display.observe'), 1);

    await _bridge(tester, webPlatform, 'lost');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(gateway.count('display.observe'), 2);

    await _bridge(tester, webPlatform, 'lost');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(gateway.count('display.observe'), 2);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(gateway.count('display.observe'), 3);

    await _bridge(tester, webPlatform, 'lost');
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(gateway.count('display.observe'), 3);

    await _bridge(tester, webPlatform, 'reconnect');
    await tester.pump();
    await tester.pump();
    expect(gateway.count('display.observe'), 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a page that stays connected restores the reconnect budget', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await _pump(tester, TakeoverScreen(controller: _controller(gateway.call)));
    await tester.pump();
    await tester.pump();
    for (var round = 2; round <= 5; round++) {
      await _bridge(tester, webPlatform, 'lost');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(gateway.count('display.observe'), round);
      await _bridge(tester, webPlatform, 'connected');
      await tester.pump(const Duration(seconds: 10));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a page that connects and drops at once keeps a spent budget', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await _pump(tester, TakeoverScreen(controller: _controller(gateway.call)));
    await tester.pump();
    await tester.pump();
    for (var round = 0; round < 6; round++) {
      await _bridge(tester, webPlatform, 'lost');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await _bridge(tester, webPlatform, 'connected');
      await tester.pump(const Duration(seconds: 2));
    }
    expect(gateway.count('display.observe'), 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a reconnect that fails shows the retry button and stays quiet', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await _pump(tester, TakeoverScreen(controller: _controller(gateway.call)));
    await tester.pump();
    await tester.pump();
    await _bridge(tester, webPlatform, 'lost');
    gateway.failObserve = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Reintentar'), findsOneWidget);
    expect(gateway.count('display.lease.release'), 1);
    await tester.pump(const Duration(minutes: 1));
    expect(gateway.count('display.observe'), 2);
    expect(gateway.count('display.lease.acquire'), 1);
  });

  testWidgets('backgrounding while the lease is being taken releases it', (
    tester,
  ) async {
    final gate = Completer<void>();
    final calls = <String>[];
    final controller = _controller((method, params) async {
      calls.add(method);
      if (method == 'display.observe') {
        return {
          ..._runtime(),
          'ticket': 'ticket-1',
          'viewer_id': 'viewer-1',
          'path': '/api/display/ws',
        };
      }
      if (method == 'display.lease.acquire') {
        await gate.future;
        return {
          'lease': {
            'holder': 'human',
            'viewer_hash': 'hash-us',
            'epoch': 2,
            'since': 1,
          },
        };
      }
      return _runtime();
    });
    await _pump(tester, TakeoverScreen(controller: controller));
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(calls.where((method) => method == 'display.lease.release'), [
      'display.lease.release',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a lost socket never retakes a lease another client holds', (
    tester,
  ) async {
    final leases = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(leases.close);
    final gateway = _FakeGateway();
    await _pump(
      tester,
      TakeoverScreen(
        controller: _controller(gateway.call, leases: leases.stream),
      ),
    );
    await tester.pump();
    await tester.pump();

    leases.add({
      'lease': {
        'holder': 'human',
        'viewer_hash': 'hash-other',
        'epoch': 3,
        'since': 2,
      },
    });
    await tester.pump();
    expect(find.text('Otro cliente asumió el control.'), findsOneWidget);

    gateway.viewer = 'viewer-2';
    await _bridge(tester, webPlatform, 'lost');
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(gateway.count('display.observe'), 1);

    await _bridge(tester, webPlatform, 'reconnect');
    await tester.pump();
    await tester.pump();
    expect(gateway.count('display.observe'), 2);
    expect(gateway.count('display.lease.acquire'), 1);
    expect(find.text('Otro cliente asumió el control.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('coming back to the app takes the screen again when it is free', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await _pump(tester, TakeoverScreen(controller: _controller(gateway.call)));
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(gateway.count('display.lease.release'), 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(gateway.count('display.observe'), 2);
    expect(gateway.count('display.lease.acquire'), 2);
    expect(find.text('Otro cliente asumió el control.'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the echo of our own release is not a takeover', (tester) async {
    final leases = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(leases.close);
    final gateway = _FakeGateway();
    await _pump(
      tester,
      TakeoverScreen(
        controller: _controller(gateway.call, leases: leases.stream),
      ),
    );
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    leases.add({
      'lease': {'holder': 'agent', 'epoch': 3, 'since': 3},
    });
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(gateway.count('display.lease.acquire'), 2);
    expect(find.text('Otro cliente asumió el control.'), findsNothing);

    leases.add({
      'lease': {
        'holder': 'human',
        'viewer_hash': 'hash-other',
        'epoch': 5,
        'since': 5,
      },
    });
    await tester.pump();
    expect(find.text('Otro cliente asumió el control.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a new attempt after a failure gets the reconnect budget back', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await _pump(tester, TakeoverScreen(controller: _controller(gateway.call)));
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 2; i++) {
      await _bridge(tester, webPlatform, 'lost');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    }
    expect(gateway.count('display.observe'), 3);

    gateway.failObserve = true;
    await _bridge(tester, webPlatform, 'reconnect');
    await tester.pump();
    await tester.pump();
    gateway.failObserve = false;
    await tester.tap(find.text('Reintentar'));
    // Cancelling the previous (empty) lease stream completes in the root zone.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
    expect(find.text('Devolver'), findsOneWidget);
    final before = gateway.count('display.observe');

    await _bridge(tester, webPlatform, 'lost');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(gateway.count('display.observe'), before + 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('coming back to the app does not take a screen a person holds', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await _pump(tester, TakeoverScreen(controller: _controller(gateway.call)));
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    gateway.observedLease = {
      'holder': 'human',
      'viewer_hash': 'hash-other',
      'epoch': 3,
      'since': 2,
    };
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(gateway.count('display.observe'), 2);
    expect(gateway.count('display.lease.acquire'), 1);
    expect(find.text('Otro cliente asumió el control.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('el vistazo no pregunta mientras el control está abierto', (
    tester,
  ) async {
    var polls = 0;
    final controller = _controller((method, params) async {
      if (method == 'display.thumbnail') {
        polls += 1;
        return {'data_url': 'data:image/png;base64,$_png'};
      }
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
            'viewer_hash': 'hash-us',
            'epoch': 1,
            'since': 1,
          },
        };
      }
      return _runtime();
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    final open = polls;
    await tester.tap(find.text('Asumir el control'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Devolver'), findsOneWidget);
    await tester.pump(screenPeekPollInterval);
    expect(polls, open);
    navigatorOf(tester).pop();
    await tester.pump();
    await tester.pump();
    expect(polls, greaterThan(open));
  });
}

NavigatorState navigatorOf(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator));

ScreenController _controller(
  DisplayRpc rpc, {
  Stream<Map<String, dynamic>>? leases,
}) => ScreenController(
  rpc: rpc,
  leasePayloads: leases ?? const Stream.empty(),
  dashboardBase: () => Uri.parse('http://127.0.0.1:9119'),
);

Map<String, dynamic> _runtime({
  bool supported = true,
  bool installed = true,
  bool running = true,
  String blocker = '',
}) => {
  'profile': 'default',
  'supported': supported,
  'installed': installed,
  'missing': <String>[],
  'running': running,
  'geometry': '1280x800',
  'blocker': blocker,
  'lease': {'holder': 'agent', 'epoch': 1, 'since': 1},
  'profile_key': 'default',
};

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

Future<void> _bridge(
  WidgetTester tester,
  FakeWebViewPlatform platform,
  String message,
) async {
  platform.last.channelHandlers['TakeoverChannel']!(
    JavaScriptMessage(message: message),
  );
  await tester.pump();
}

/// Gateway stub: each observe mints `ticket-N` for [viewer] and reports
/// [observedLease]; an acquire always answers with this client's lease.
class _FakeGateway {
  String viewer = 'viewer-1';
  Map<String, dynamic> observedLease = {
    'holder': 'agent',
    'epoch': 1,
    'since': 1,
  };
  bool failObserve = false;
  final calls = <String>[];

  int count(String method) => calls.where((call) => call == method).length;

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add(method);
    if (method == 'display.observe') {
      if (failObserve) throw StateError('gateway down');
      return {
        ..._runtime(),
        'lease': observedLease,
        'ticket': 'ticket-${count(method)}',
        'viewer_id': viewer,
        'path': '/api/display/ws',
      };
    }
    if (method == 'display.lease.acquire') {
      return {
        'lease': {
          'holder': 'human',
          'viewer_hash': 'hash-us',
          'epoch': 2,
          'since': 1,
        },
      };
    }
    return _runtime();
  }
}
