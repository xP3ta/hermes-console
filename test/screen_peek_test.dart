import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screens/screen_peek_screen.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
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
    expect(find.text('Solo mirando · se actualiza cada 4 s'), findsOneWidget);
    // TalkBack says what the frame is.
    expect(
      tester.widget<Image>(find.byType(Image)).semanticLabel,
      'Pantalla del bot',
    );
    expect(calls, containsAll(['display.status', 'display.thumbnail']));
  });

  testWidgets('el vistazo solo pinta imágenes data: de tamaño razonable', (
    tester,
  ) async {
    final huge = 'A' * ((screenPeekMaxFrameBytes ~/ 3 + 2) * 4);
    for (final dataUrl in [
      'data:text/html;base64,$_png',
      'https://evil.example/frame.png',
      'data:image/png;base64,$huge',
    ]) {
      final controller = _controller((method, params) async {
        if (method == 'display.thumbnail') return {'data_url': dataUrl};
        return _runtime();
      });
      await _pump(
        tester,
        ScreenPeekScreen(key: ValueKey(dataUrl), controller: controller),
      );
      await tester.pump();
      await tester.pump();
      final why = dataUrl.substring(0, 20);
      expect(find.byType(Image), findsNothing, reason: why);
      expect(find.text('Asumir el control'), findsNothing);
    }
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

  testWidgets('el vistazo distingue parada, no instalada y Hermes antiguo', (
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
    // Method not found: the bot's Hermes predates display.* (Desktop
    // isDisplayUnavailable), which is not the same as "not installed".
    expect(
      find.text('Actualiza el Hermes del bot para usar su pantalla.'),
      findsOneWidget,
    );
  });

  testWidgets('sin pila de pantalla o sin display.* deja de preguntar', (
    tester,
  ) async {
    for (final unlisted in [false, true]) {
      var polls = 0;
      final controller = _controller((method, params) async {
        if (method == 'display.status') polls += 1;
        if (unlisted) {
          throw const TuiGatewayRpcError(
            'display.status',
            'missing',
            code: -32601,
          );
        }
        return _runtime(installed: false);
      });
      await _pump(
        tester,
        ScreenPeekScreen(key: ValueKey(unlisted), controller: controller),
      );
      await tester.pump();
      expect(polls, 1, reason: 'unlisted: $unlisted');
      // REVIEW-R4 P2-VNC-4: nothing changes on its own, so no more asking.
      await tester.pump(const Duration(seconds: 20));
      expect(polls, 1, reason: 'unlisted: $unlisted');
      // «Actualizar ahora» asks again, once.
      await tester.tap(find.text('Actualizar ahora'));
      await tester.pump();
      expect(polls, 2, reason: 'unlisted: $unlisted');
      await tester.pump(const Duration(seconds: 20));
      expect(polls, 2, reason: 'unlisted: $unlisted');
    }
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

  testWidgets('tapado por otra pantalla no pide fotogramas (R5-B #25)', (
    tester,
  ) async {
    var polls = 0;
    final controller = _controller((method, params) async {
      if (method == 'display.status') polls += 1;
      return _runtime(running: false);
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    expect(polls, greaterThan(0));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Text('encima')),
      ),
    );
    await tester.pumpAndSettle();
    final covered = polls;
    await tester.pump(screenPeekPollInterval * 3);
    await tester.pump();
    expect(polls, covered, reason: 'nobody sees it: nothing is asked');
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(screenPeekPollInterval);
    await tester.pump();
    expect(polls, greaterThan(covered), reason: 'back in view, it asks again');
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

  testWidgets('un fallo suelto no envejece el fotograma; tres sí', (
    tester,
  ) async {
    var fail = false;
    final controller = _controller((method, params) async {
      if (method == 'display.thumbnail') {
        if (fail) throw StateError('gateway down');
        return {'data_url': 'data:image/png;base64,$_png'};
      }
      return _runtime();
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    await tester.pump();
    // The key sits on the caption Text itself, so the root must match.
    final caption = find.byKey(const ValueKey('screen-peek-caption'));
    expect(
      find.descendant(
        of: caption,
        matching: find.text('Solo mirando · se actualiza cada 4 s'),
        matchRoot: true,
      ),
      findsOneWidget,
    );

    fail = true;
    for (var miss = 1; miss < screenPeekStaleAfter; miss++) {
      await tester.pump(screenPeekPollInterval);
      await tester.pump();
    }
    // The last good frame stays up and still reads as live.
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Solo mirando · se actualiza cada 4 s'), findsOneWidget);

    await tester.pump(screenPeekPollInterval);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.text('Visto por última vez: la pantalla no responde'),
      findsOneWidget,
    );
    expect(find.text('No se pudo leer la pantalla del bot.'), findsNothing);

    fail = false;
    await tester.pump(screenPeekPollInterval);
    await tester.pump();
    expect(find.text('Solo mirando · se actualiza cada 4 s'), findsOneWidget);
  });

  testWidgets('sin fotograma previo, un fallo se muestra como error', (
    tester,
  ) async {
    final controller = _controller((method, params) async {
      if (method == 'display.thumbnail') throw StateError('gateway down');
      return _runtime();
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();
    await tester.pump();
    expect(find.text('No se pudo leer la pantalla del bot.'), findsOneWidget);
  });

  testWidgets('en segundo plano deja de pedir fotogramas y al volver sigue', (
    tester,
  ) async {
    var polls = 0;
    final controller = _controller((method, params) async {
      if (method == 'display.status') polls += 1;
      return _runtime(running: false);
    });
    await _pump(tester, ScreenPeekScreen(controller: controller));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final background = polls;
    await tester.pump(screenPeekPollInterval * 5);
    await tester.pump();
    expect(polls, background);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // Coming back asks at once, then keeps the interval.
    expect(polls, background + 1);
    await tester.pump(screenPeekPollInterval);
    await tester.pump();
    expect(polls, background + 2);
  });
}

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
