import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/screens/runs_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: child,
        ),
      ),
    ),
  ),
);

RunApprovalDecisionBlock _block({
  Map<String, dynamic> approval = const {
    'command': 'ls -la /home',
    'description': 'Listar el directorio',
  },
  bool busy = false,
  bool readOnly = false,
  bool allowAlways = true,
  ValueChanged<String>? onChoice,
  VoidCallback? onAlways,
}) => RunApprovalDecisionBlock(
  approval: approval,
  busy: busy,
  readOnly: readOnly,
  allowAlways: allowAlways,
  onChoice: onChoice ?? (_) {},
  onAlways: onAlways ?? () {},
);

void main() {
  test('A sustituida por B durante App Lock no emite ningún RPC', () async {
    var pendingRequestId = 'request-a';
    final unlocked = Completer<bool>();
    final resolved = <String>[];

    final operation = resolveRunApprovalWithLockFence(
      requestId: 'request-a',
      currentRequestId: () => pendingRequestId,
      verify: () => unlocked.future,
      resolve: () async {
        resolved.add('request-a');
        return true;
      },
    );
    pendingRequestId = 'request-b';
    unlocked.complete(true);

    expect(await operation, isFalse);
    expect(resolved, isEmpty);
    expect(pendingRequestId, 'request-b');
  });

  test('App Lock reintenta la apertura pendiente exacta al desbloquear', () {
    final main = File('lib/main.dart').readAsStringSync();
    final start = main.indexOf('void _onAppLockNoticeGateChanged()');
    final end = main.indexOf(
      'final Set<String> _hydratingNotificationRuns',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final gate = main.substring(start, end);
    expect(gate, contains('widget.notifications.retryPendingOpen()'));
  });

  test('todos los terminales, incluido run.cancelled, cancelan approval', () {
    for (final event in const [
      'run.completed',
      'run.failed',
      'run.cancelled',
    ]) {
      expect(runTerminalCancelsApproval(event), isTrue);
    }
    expect(runTerminalCancelsApproval('message.delta'), isFalse);
  });

  testWidgets(
    'riesgo bajo usa HermesDecisionBlock y conserva los 4 callbacks',
    (tester) async {
      final choices = <String>[];

      await tester.pumpWidget(
        _host(
          _block(onChoice: choices.add, onAlways: () => choices.add('always')),
        ),
      );

      expect(find.byType(HermesDecisionBlock), findsOneWidget);
      expect(find.text('RIESGO BAJO'), findsOneWidget);
      expect(find.text('Listar el directorio'), findsOneWidget);

      await tester.tap(find.text('Denegar'));
      await tester.tap(find.text('esta sesión'));
      await tester.tap(find.text('Permitir siempre'));
      await tester.tap(find.text('una vez'));
      await tester.pump();

      expect(choices, ['deny', 'session', 'always', 'once']);
    },
  );

  testWidgets('riesgo alto se deriva siempre del comando crudo', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _block(
          approval: const {
            'command': 'sudo rm -rf /srv/data',
            'description': 'Borrar datos',
          },
        ),
      ),
    );

    expect(find.text('RIESGO ALTO'), findsOneWidget);
  });

  testWidgets(
    'proyección multilínea se sanea y acota pero copiar conserva el raw',
    (tester) async {
      final raw = "printf 'uno\\ndos'\n\u0000${'x' * 5000}";
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        _host(
          _block(
            approval: {'command': raw, 'description': 'Comando multilínea'},
          ),
        ),
      );

      await tester.tap(find.text('ver detalles'));
      await tester.pumpAndSettle();

      final display = tester.widget<Text>(
        find.byKey(const ValueKey('run-approval-command-display')),
      );
      expect(display.data, contains('\n'));
      expect(display.data, isNot(contains('\u0000')));
      expect(display.data!.length, lessThanOrEqualTo(4000));

      final copyIcon = find.byIcon(Icons.content_copy_outlined);
      await tester.ensureVisible(copyIcon);
      await tester.tap(copyIcon);
      await tester.pump();
      expect(copied, raw);
    },
  );

  testWidgets('payload sin comando no inventa detalle ni riesgo', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _block(
          approval: const {'description': 'Confirmar una acción del agente'},
        ),
      ),
    );

    expect(find.text('Confirmar una acción del agente'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('run-approval-command-display')),
      findsNothing,
    );
    expect(find.text('ver detalles'), findsNothing);
    expect(find.text('RIESGO BAJO'), findsNothing);
  });

  testWidgets('solo lectura mantiene Denegar visible y funcional', (
    tester,
  ) async {
    final choices = <String>[];
    await tester.pumpWidget(
      _host(_block(readOnly: true, onChoice: choices.add)),
    );

    expect(find.text('SOLO LECTURA'), findsOneWidget);
    expect(find.text('Denegar'), findsOneWidget);
    expect(find.text('una vez'), findsNothing);
    expect(find.text('esta sesión'), findsNothing);
    expect(find.text('Permitir siempre'), findsNothing);

    await tester.tap(find.text('Denegar'));
    await tester.pump();
    expect(choices, ['deny']);
  });

  testWidgets('busy conserva las acciones visibles pero deshabilitadas', (
    tester,
  ) async {
    final choices = <String>[];
    await tester.pumpWidget(
      _host(
        _block(
          busy: true,
          onChoice: choices.add,
          onAlways: () => choices.add('always'),
        ),
      ),
    );

    for (final label in ['Denegar', 'esta sesión', 'Permitir siempre']) {
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'una vez'))
          .onPressed,
      isNull,
    );
    expect(choices, isEmpty);
  });

  testWidgets('Siempre respeta tanto el flag local como capacidad explícita', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_block(allowAlways: false)));
    expect(find.text('Permitir siempre'), findsNothing);

    await tester.pumpWidget(
      _host(
        _block(
          approval: const {
            'command': 'ls',
            'allowed_choices': ['once', 'session', 'deny'],
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Permitir siempre'), findsNothing);
  });

  testWidgets('un run expirado retira la aprobación pendiente', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var approvalEvents = 0;
    var statusRequests = 0;
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/events')) {
        approvalEvents++;
        return http.Response(
          'data: ${jsonEncode({'event': 'approval.request', 'command': 'ls -la', 'description': 'Listar archivos'})}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }

      if (request.url.path == '/v1/runs/run-expired') {
        statusRequests++;
        // El gateway ya barrió el run. La implementación debe ser segura tanto
        // si el 404 gana la carrera como si el frame SSE se procesa primero.
        return http.Response('{}', 404);
      }

      return http.Response('{}', 404);
    });

    final connection = SavedConnection(
      id: 'runs-expired-test',
      label: 'Test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
    );
    final client = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      httpClient: httpClient,
    );
    const record = RunRecord(
      runId: 'run-expired',
      prompt: 'Prueba',
      createdAt: 1,
      lastStatus: 'queued',
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: RunDetailScreen(
          connection: connection,
          record: record,
          client: client,
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(approvalEvents, 1);
    expect(statusRequests, greaterThanOrEqualTo(1));
    expect(find.textContaining('El gateway ya no conserva'), findsOneWidget);
    expect(find.byType(RunApprovalDecisionBlock), findsNothing);
  });

  testWidgets('cold/warm routing espera approval B exacta e ignora A retrasada', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var ready = 0;
    final connection = SavedConnection(
      id: 'runs-route-b',
      label: 'Test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'k',
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/events')) {
        return http.Response(
          'data: ${jsonEncode({'event': 'approval.request', 'request_id': 'request-a', 'command': 'ls a'})}\n\n'
          'data: ${jsonEncode({'event': 'approval.request', 'request_id': 'request-b', 'command': 'ls b'})}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (request.url.path == '/v1/runs/run-route-b') {
        return http.Response(
          jsonEncode({'status': 'waiting_for_approval'}),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: RunDetailScreen(
          connection: connection,
          record: const RunRecord(
            runId: 'run-route-b',
            prompt: 'Ruta B',
            createdAt: 1,
            lastStatus: 'running',
          ),
          initialApprovalId: 'request-b',
          onInitialApprovalReady: () => ready++,
          client: ApiClient(
            baseUrl: connection.baseUrl,
            apiKey: connection.apiKey,
            httpClient: client,
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(ready, 1);
    expect(find.text('ls b'), findsWidgets);
    expect(find.text('ls a'), findsNothing);
  });

  testWidgets('tras enfocar approval A deja pasar approval B posterior', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var ready = 0;
    final connection = SavedConnection(
      id: 'runs-route-a-then-b',
      label: 'Test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/events')) {
        return http.Response(
          'data: ${jsonEncode({'event': 'approval.request', 'request_id': 'request-a', 'command': 'ls a'})}\n\n'
          'data: ${jsonEncode({'event': 'approval.request', 'request_id': 'request-b', 'command': 'ls b'})}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (request.url.path == '/v1/runs/run-route-a-then-b') {
        return http.Response(
          jsonEncode({'status': 'waiting_for_approval'}),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: RunDetailScreen(
          connection: connection,
          record: const RunRecord(
            runId: 'run-route-a-then-b',
            prompt: 'Ruta A luego B',
            createdAt: 1,
            lastStatus: 'running',
          ),
          initialApprovalId: 'request-a',
          onInitialApprovalReady: () => ready++,
          client: ApiClient(
            baseUrl: connection.baseUrl,
            apiKey: connection.apiKey,
            httpClient: client,
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(ready, 1);
    expect(find.text('ls b'), findsWidgets);
  });

  testWidgets('approval.responded sin request_id falla cerrado y conserva B', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/events')) {
        return http.Response(
          'data: ${jsonEncode({'event': 'approval.request', 'request_id': 'request-b', 'command': 'ls b'})}\n\n'
          'data: ${jsonEncode({'event': 'approval.responded', 'choice': 'once'})}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (request.url.path == '/v1/runs/run-b') {
        return http.Response(
          jsonEncode({'status': 'waiting_for_approval'}),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final connection = SavedConnection(
      id: 'runs-approval-b',
      label: 'Test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'k',
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: RunDetailScreen(
          connection: connection,
          record: const RunRecord(
            runId: 'run-b',
            prompt: 'Prueba B',
            createdAt: 1,
            lastStatus: 'running',
          ),
          client: ApiClient(
            baseUrl: connection.baseUrl,
            apiKey: connection.apiKey,
            httpClient: httpClient,
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(find.byType(RunApprovalDecisionBlock), findsOneWidget);
    expect(find.text('ls b'), findsWidgets);
  });
}
