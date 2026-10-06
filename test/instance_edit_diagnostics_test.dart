import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class _FakeDiagnostics extends ConnectionDiagnostics {
  _FakeDiagnostics(this.report);

  final DiagnosticsReport report;
  int runCalls = 0;

  @override
  Future<DiagnosticsReport> run(
    Strings s,
    SavedConnection conn,
    DashboardSecrets secrets, {
    String? bridgeUrl,
    String? bridgeToken,
  }) async {
    runCalls++;
    return report;
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  SavedConnection savedConnection({String host = '192.168.1.20'}) =>
      SavedConnection(
        id: 'demo',
        label: 'Server',
        host: host,
        port: 8642,
        apiKey: '',
        dashboardUrl: 'http://$host:9119',
        dashboardAuthMode: AuthMode.basicAuth,
        kind: InstanceKind.homelab,
      );

  const verified = CapabilityMatrix(
    gatewayOnline: CapState.yes,
    dashboardOnline: CapState.yes,
    chatSupported: CapState.yes,
    sessionsRead: CapState.yes,
    memoryRead: CapState.yes,
    checkedAtMs: 1784062800000,
  );

  const allVerified = CapabilityMatrix(
    gatewayOnline: CapState.yes,
    dashboardOnline: CapState.yes,
    gatewayAuthValid: CapState.yes,
    dashboardAuthValid: CapState.yes,
    chatSupported: CapState.yes,
    sessionsRead: CapState.yes,
    sessionsWrite: CapState.yes,
    sessionsDelete: CapState.yes,
    streamingSupported: CapState.yes,
    skillsRead: CapState.yes,
    skillsToggle: CapState.yes,
    skillsInstall: CapState.yes,
    toolsetsRead: CapState.yes,
    cronRead: CapState.yes,
    cronWrite: CapState.yes,
    memoryRead: CapState.yes,
    memoryWrite: CapState.yes,
    modelsRead: CapState.yes,
    modelsWrite: CapState.yes,
    configRead: CapState.yes,
    configWrite: CapState.yes,
    logsRead: CapState.yes,
    pluginsSupported: CapState.yes,
    checkedAtMs: 1784062800000,
  );

  Future<ConnectionManager> managerWith(SavedConnection connection) async {
    SharedPreferences.setMockInitialValues({
      'saved_connections': [jsonEncode(connection.toMap())],
    });
    final prefs = await SharedPreferences.getInstance();
    return ConnectionManager.create(prefs);
  }

  Future<void> pumpEditor(
    WidgetTester tester,
    ConnectionManager manager, {
    ConnectionDiagnostics? diagnostics,
    Locale locale = const Locale('es'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InstanceEditScreen(
          connManager: manager,
          initial: manager.getConnections().single,
          diagnostics: diagnostics,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    for (var attempt = 0; attempt < 12; attempt++) {
      if (target.evaluate().isNotEmpty) {
        await tester.ensureVisible(target.first);
        await tester.pump();
        return;
      }
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await tester.pump();
    }
    throw TestFailure('No se pudo revelar $target');
  }

  Future<void> openDiagnostics(
    WidgetTester tester, {
    bool english = false,
  }) async {
    final entry = find.text(
      english ? 'Check connection' : 'Comprobar conexión',
    );
    await reveal(tester, entry);
    await tester.tap(entry.first);
    await tester.pumpAndSettle();
  }

  Future<void> expandTechnicalDetails(
    WidgetTester tester, {
    bool english = false,
  }) async {
    final disclosure = find.text(
      english ? 'Technical details' : 'Detalles técnicos',
    );
    await reveal(tester, disclosure);
    await tester.tap(disclosure.first);
    await tester.pumpAndSettle();
  }

  Finder semanticsLabel(String label) => find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );

  test(
    'una matriz verificada sobre la conexión viva sobrevive al reabrir',
    () async {
      final manager = await managerWith(savedConnection());

      final persisted = await persistVerifiedCapabilityMatrix(
        manager: manager,
        probedConnection: savedConnection(),
        matrix: verified,
        credentialsOverridden: false,
      );

      expect(persisted, isTrue);
      final reopened = manager.loadCapabilities('demo');
      expect(reopened.chatSupported, CapState.yes);
      expect(reopened.sessionsRead, CapState.yes);
      expect(reopened.memoryRead, CapState.yes);
      expect(reopened.checkedAtMs, verified.checkedAtMs);
    },
  );

  test(
    'no asocia a la conexión viva un diagnóstico de una URL editada',
    () async {
      final manager = await managerWith(savedConnection());

      final persisted = await persistVerifiedCapabilityMatrix(
        manager: manager,
        probedConnection: savedConnection(host: '192.0.2.99'),
        matrix: verified,
        credentialsOverridden: false,
      );

      expect(persisted, isFalse);
      expect(manager.loadCapabilities('demo').checkedAtMs, isNull);
    },
  );

  test(
    'no persiste el resultado si se probaron credenciales sin guardar',
    () async {
      final manager = await managerWith(savedConnection());

      final persisted = await persistVerifiedCapabilityMatrix(
        manager: manager,
        probedConnection: savedConnection(),
        matrix: verified,
        credentialsOverridden: true,
      );

      expect(persisted, isFalse);
      expect(manager.loadCapabilities('demo').checkedAtMs, isNull);
    },
  );

  test(
    'no persiste una matriz que no representa un diagnóstico completo',
    () async {
      final manager = await managerWith(savedConnection());

      final persisted = await persistVerifiedCapabilityMatrix(
        manager: manager,
        probedConnection: savedConnection(),
        matrix: const CapabilityMatrix(chatSupported: CapState.yes),
        credentialsOverridden: false,
      );

      expect(persisted, isFalse);
      expect(manager.loadCapabilities('demo').checkedAtMs, isNull);
    },
  );

  testWidgets('comprobar todo, salir sin guardar y reabrir conserva verdes', (
    tester,
  ) async {
    final manager = await managerWith(savedConnection());
    final fake = _FakeDiagnostics(
      DiagnosticsReport(
        gateway: const [
          ProbeResult(name: 'health', status: ProbeStatus.ok),
          ProbeResult(name: 'sessions', status: ProbeStatus.ok),
        ],
        dashboard: const [ProbeResult(name: 'status', status: ProbeStatus.ok)],
        bridge: const [ProbeResult(name: 'health', status: ProbeStatus.ok)],
        matrix: allVerified,
        suggestions: const [],
        ranAt: DateTime.fromMillisecondsSinceEpoch(1784062800000),
      ),
    );

    await pumpEditor(tester, manager, diagnostics: fake);
    await openDiagnostics(tester);

    expect(fake.runCalls, 1);
    expect(manager.loadCapabilities('demo').chatSupported, CapState.yes);
    expect(semanticsLabel('Estado del diagnóstico: correcto'), findsOneWidget);
    await expandTechnicalDetails(tester);
    await reveal(tester, find.text('CAPACIDADES DETECTADAS'));
    final colors = Theme.of(
      tester.element(find.text('CAPACIDADES DETECTADAS').first),
    ).hermes;
    for (final label in const [
      'CHAT: SÍ',
      'SESIONES R/W: SÍ',
      'STREAMING: SÍ',
      'MEMORIA (LECTURA): SÍ',
    ]) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.style?.color, colors.success);
    }
    // Sustituir el árbol equivale a salir sin guardar y abrir otra vez.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await pumpEditor(tester, manager);
    await openDiagnostics(tester);
    await expandTechnicalDetails(tester);
    await reveal(tester, find.text('CAPACIDADES DETECTADAS'));

    expect(find.text('CHAT: SÍ'), findsOneWidget);
    expect(find.text('STREAMING: SÍ'), findsOneWidget);
    expect(find.text('MEMORIA (LECTURA): SÍ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sí, no y desconocido son inequívocos sin depender del color', (
    tester,
  ) async {
    final manager = await managerWith(savedConnection());
    await manager.saveCapabilities(
      'demo',
      const CapabilityMatrix(
        chatSupported: CapState.yes,
        streamingSupported: CapState.unknown,
        skillsToggle: CapState.no,
        checkedAtMs: 1784062800000,
      ),
    );

    await pumpEditor(tester, manager);
    await openDiagnostics(tester);
    await expandTechnicalDetails(tester);
    await reveal(tester, find.text('CAPACIDADES DETECTADAS'));
    final colors = Theme.of(
      tester.element(find.text('CAPACIDADES DETECTADAS').first),
    ).hermes;

    expect(
      tester.widget<Text>(find.text('CHAT: SÍ')).style?.color,
      colors.success,
    );
    expect(
      tester.widget<Text>(find.text('STREAMING: ?')).style?.color,
      colors.warning,
    );
    expect(
      tester.widget<Text>(find.text('SKILLS (TOGGLE): NO')).style?.color,
      colors.textTertiary,
    );
    expect(semanticsLabel('CHAT: SÍ'), findsOneWidget);
    expect(semanticsLabel('STREAMING: ?'), findsOneWidget);
    expect(semanticsLabel('SKILLS (TOGGLE): NO'), findsOneWidget);
  });

  testWidgets('un fallo real conserva texto y badge rojo', (tester) async {
    final manager = await managerWith(savedConnection());
    final fake = _FakeDiagnostics(
      DiagnosticsReport(
        gateway: const [
          ProbeResult(
            name: 'health',
            status: ProbeStatus.timeout,
            detail: 'synthetic',
          ),
        ],
        dashboard: const [],
        bridge: const [],
        matrix: const CapabilityMatrix(
          gatewayOnline: CapState.no,
          checkedAtMs: 1784062800000,
        ),
        suggestions: const [],
        ranAt: DateTime.fromMillisecondsSinceEpoch(1784062800000),
      ),
    );

    await pumpEditor(tester, manager, diagnostics: fake);
    await openDiagnostics(tester);
    expect(
      semanticsLabel('Estado del diagnóstico: sin conexión'),
      findsOneWidget,
    );
    await reveal(tester, find.text('SIN RESPUESTA'));

    final colors = Theme.of(
      tester.element(find.text('SIN RESPUESTA').first),
    ).hermes;
    expect(
      tester.widget<Text>(find.text('SIN RESPUESTA')).style?.color,
      colors.error,
    );
    expect(semanticsLabel('SIN RESPUESTA'), findsOneWidget);
  });

  testWidgets('locale inglés no filtra textos españoles del diagnóstico', (
    tester,
  ) async {
    final manager = await managerWith(savedConnection());
    final fake = _FakeDiagnostics(
      DiagnosticsReport(
        gateway: const [
          ProbeResult(
            name: 'health',
            status: ProbeStatus.timeout,
            detail: 'sin respuesta en 8s',
          ),
        ],
        dashboard: const [],
        bridge: const [],
        matrix: const CapabilityMatrix(
          gatewayOnline: CapState.no,
          checkedAtMs: 1784062800000,
        ),
        suggestions: const [],
        ranAt: DateTime.fromMillisecondsSinceEpoch(1784062800000),
      ),
    );

    await pumpEditor(
      tester,
      manager,
      diagnostics: fake,
      locale: const Locale('en'),
    );

    expect(find.text('Edit instance'), findsOneWidget);
    expect(find.text('Editar instancia'), findsNothing);

    await openDiagnostics(tester, english: true);
    await expandTechnicalDetails(tester, english: true);
    await reveal(tester, find.text('NO RESPONSE'));

    expect(find.text('NO RESPONSE'), findsWidgets);
    expect(find.textContaining('The server did not respond'), findsOneWidget);
    expect(find.textContaining('sin respuesta'), findsNothing);
    await reveal(tester, find.text('MEMORY (READ): ?'));
    expect(find.text('MEMORY (READ): ?'), findsOneWidget);
  });

  testWidgets('alta nueva usa el título inglés', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: InstanceEditScreen(connManager: manager),
      ),
    );
    await tester.pump();

    expect(find.text('New instance'), findsOneWidget);
    await reveal(tester, find.text('save instance'));
    expect(find.text('save instance'), findsOneWidget);
    expect(find.text('Nueva instancia'), findsNothing);
    expect(find.text('guardar instancia'), findsNothing);
  });

  test('diagnóstico copiable respeta locale inglés', () {
    final report = DiagnosticsReport(
      gateway: const [
        ProbeResult(
          name: 'sessions',
          status: ProbeStatus.authInvalid,
          detail: 'revisa el usuario y la contraseña',
        ),
      ],
      dashboard: const [],
      matrix: const CapabilityMatrix(),
      suggestions: const ['Check the token.'],
      ranAt: DateTime.fromMillisecondsSinceEpoch(1784062800000),
    );

    final copied = report.toCopyText(lookupStrings(const Locale('en')));

    expect(copied, contains('hermes console diagnostics'));
    expect(copied, contains('sessions: invalid auth'));
    expect(copied, contains('Check the configured credentials.'));
    expect(copied, contains('[suggestions]'));
    expect(copied, isNot(contains('contraseña')));
    expect(copied, isNot(contains('sugerencias')));
  });
}
