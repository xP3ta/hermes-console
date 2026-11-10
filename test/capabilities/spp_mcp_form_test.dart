// Adding an MCP server: specific reasons, a cleartext warning, nothing run
// on the phone; and the detail never shows what the server list holds back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/capabilities/mcp_logs_screen.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesSelectField;
import 'package:hermes_android/core/models/admin_integrations.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/widgets/mcp_provisioning_surface.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

Future<void> _openForm(WidgetTester tester) async {
  await setPhone(tester);
  await tester.pumpWidget(spanishApp(const McpServerDraftSurface()));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
  // The plain-http notes wait until the address stops changing.
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _chooseHttp(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mcp-transport-http')));
  await tester.pumpAndSettle();
}

bool _submitEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('mcp-draft-submit')))
        .onPressed !=
    null;

void main() {
  setUpAll(loadInterFont);

  group('form', () {
    testWidgets('a name with spaces is explained, not just refused', (
      tester,
    ) async {
      await _openForm(tester);
      await _type(tester, 'mcp-draft-name', 'my server');
      expect(
        find.textContaining('Usa letras, números, punto, guion'),
        findsOneWidget,
      );
      await _type(tester, 'mcp-draft-name', 'my-server');
      expect(find.textContaining('Usa letras, números'), findsNothing);
    });

    testWidgets('an address with a query is refused for what it may hold', (
      tester,
    ) async {
      await _openForm(tester);
      await _chooseHttp(tester);
      await _type(tester, 'mcp-draft-name', 'docs');
      await _type(
        tester,
        'mcp-draft-url',
        'https://mcp.example.com/sse?token=fake',
      );
      expect(find.textContaining('No pongas parámetros'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mcp-draft-submit')));
      await tester.pumpAndSettle();
      // Still on the form: nothing was returned.
      expect(find.byKey(const ValueKey('mcp-draft-url')), findsOneWidget);
    });

    testWidgets('user info and a wrong scheme each get their own reason', (
      tester,
    ) async {
      await _openForm(tester);
      await _chooseHttp(tester);
      await _type(tester, 'mcp-draft-url', 'https://u:p@mcp.example.com/sse');
      expect(
        find.textContaining('No pongas usuario ni contraseña'),
        findsOneWidget,
      );
      await _type(tester, 'mcp-draft-url', 'ftp://mcp.example.com');
      expect(find.textContaining('debe empezar por https://'), findsOneWidget);
    });

    testWidgets(
      'public http gets one quiet line; private http and https say nothing',
      (tester) async {
        await _openForm(tester);
        await _chooseHttp(tester);
        const line = ValueKey('krh-http-line');
        await _type(tester, 'mcp-draft-url', 'https://mcp.example.com/sse');
        expect(find.byKey(const ValueKey('spp-mcp-insecure')), findsNothing);
        expect(find.byKey(line), findsNothing);

        await _type(tester, 'mcp-draft-url', 'http://mcp.example.com/sse');
        expect(find.byKey(line), findsOneWidget);
        expect(
          find.textContaining('lo que viaje puede leerse'),
          findsOneWidget,
        );
        // Not the strong notice: no token is involved.
        expect(find.byKey(const ValueKey('spp-mcp-insecure')), findsNothing);

        for (final url in [
          'http://localhost:9000/mcp',
          'http://192.168.1.20:9000/mcp',
          'http://100.101.102.103:9000/mcp',
          'http://box.tail1234.ts.net:9000/mcp',
          'http://printer.local:9000/mcp',
        ]) {
          await _type(tester, 'mcp-draft-url', url);
          expect(find.byKey(line), findsNothing, reason: url);
          expect(
            find.byKey(const ValueKey('spp-mcp-insecure')),
            findsNothing,
            reason: url,
          );
          expect(find.textContaining('Es una red privada'), findsNothing);
        }
      },
    );

    testWidgets('a token over public http gets the strongest warning', (
      tester,
    ) async {
      await _openForm(tester);
      await _chooseHttp(tester);
      await _type(tester, 'mcp-draft-url', 'http://mcp.example.com/sse');
      await tester.tap(find.byType(HermesSelectField<McpAuthMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cabecera Bearer').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('enviarías un token'), findsOneWidget);
      // The strong notice cannot be dismissed and is not the quiet line.
      expect(find.byKey(const ValueKey('spp-mcp-insecure')), findsOneWidget);
      expect(find.byKey(const ValueKey('krh-http-line')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('spp-mcp-insecure')),
          matching: find.byType(IconButton),
        ),
        findsNothing,
      );
    });

    testWidgets('a command with spaces gets a hint but can be sent', (
      tester,
    ) async {
      await _openForm(tester);
      await _type(tester, 'mcp-draft-name', 'files');
      await _type(tester, 'mcp-draft-command', 'npx -y server');
      expect(
        find.byKey(const ValueKey('spp-mcp-command-hint')),
        findsOneWidget,
      );
      expect(find.textContaining('uno por línea'), findsOneWidget);
      expect(_submitEnabled(tester), isTrue);

      await _type(tester, 'mcp-draft-command', 'npx && rm');
      expect(find.textContaining('sin intérprete de comandos'), findsOneWidget);

      await _type(tester, 'mcp-draft-command', 'npx');
      expect(find.byKey(const ValueKey('spp-mcp-command-hint')), findsNothing);
    });

    testWidgets('a command with a line break is a hard error', (tester) async {
      await _openForm(tester);
      await _type(tester, 'mcp-draft-name', 'files');
      await _type(tester, 'mcp-draft-command', 'npx\trm');
      expect(find.textContaining('saltos de línea'), findsOneWidget);
    });

    testWidgets('secret fields are obscured and never echoed', (tester) async {
      await _openForm(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('mcp-env-value-0')));
      await _type(tester, 'mcp-env-value-0', 'fake-env-secret');
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('mcp-env-value-0')),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isTrue,
      );
    });
  });

  group('hub entry', () {
    Future<void> openMenu(WidgetTester tester, ScriptedRest rest) async {
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(
          CapabilitiesScreen(
            repository: repoOf(rest),
            searchDebounce: Duration.zero,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('exu-tab-mcp')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('exu-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('spp-menu-add-mcp')));
      await tester.pumpAndSettle();
    }

    testWidgets('creates the server with the drafted request, once', (
      tester,
    ) async {
      final rest = populatedServer()
        ..posts['mcp/servers'] = {
          'name': 'reports',
          'transport': 'http',
          'url': 'https://mcp.example.com/mcp',
          'enabled': true,
        };
      await openMenu(tester, rest);
      await tester.tap(find.byKey(const ValueKey('mcp-transport-http')));
      await tester.pumpAndSettle();
      await _type(tester, 'mcp-draft-name', 'reports');
      await _type(tester, 'mcp-draft-url', 'https://mcp.example.com/mcp');
      await tester.tap(find.byKey(const ValueKey('mcp-draft-submit')));
      await tester.pumpAndSettle();

      expect(rest.mutations, ['POST mcp/servers']);
      expect(rest.bodies.last, {
        'name': 'reports',
        'url': 'https://mcp.example.com/mcp',
        'auth': 'none',
      });
    });

    testWidgets('a duplicate name is reported without losing the hub', (
      tester,
    ) async {
      final rest = populatedServer()
        ..posts['mcp/servers'] = const DashboardHttpException(409);
      await openMenu(tester, rest);
      await tester.tap(find.byKey(const ValueKey('mcp-transport-http')));
      await tester.pumpAndSettle();
      await _type(tester, 'mcp-draft-name', 'docs');
      await _type(tester, 'mcp-draft-url', 'https://mcp.example.com/mcp');
      await tester.tap(find.byKey(const ValueKey('mcp-draft-submit')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('no aceptó esta configuración'),
        findsOneWidget,
      );
      expect(find.text('Extensiones'), findsOneWidget);
    });
  });

  group('detail', () {
    CapabilityItem server(Map<String, dynamic> json) =>
        CapabilityItem.mcpServer({'name': 'srv', 'enabled': true, ...json})!;

    Future<void> open(WidgetTester tester, CapabilityItem item) async {
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(
          CapabilityDetailScreen(
            key: UniqueKey(),
            item: item,
            repository: repoOf(ScriptedRest()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> scrollToEnd(WidgetTester tester) async {
      await tester.drag(
        find.byKey(const ValueKey('cph-detail-list')),
        const Offset(0, -1500),
      );
      await tester.pumpAndSettle();
    }

    String allText(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');

    testWidgets('address and command are shown without credentials', (
      tester,
    ) async {
      await open(
        tester,
        server({
          'transport': 'http',
          'url': 'https://u:pw-fake@mcp.example.com/sse?api_key=fake-key-123',
          'env': {'API_TOKEN': 'sk-fakefakefakefakefake01'},
        }),
      );
      await scrollToEnd(tester);
      final text = allText(tester);
      expect(text, contains('https://mcp.example.com/sse?…'));
      for (final secret in [
        'pw-fake',
        'fake-key-123',
        'sk-fakefake',
        'API_TOKEN',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
    });

    testWidgets('a stdio command hides the value after a credential flag', (
      tester,
    ) async {
      await open(
        tester,
        server({
          'transport': 'stdio',
          'command': 'node',
          'args': ['server.js', '--password', 'fake-pass', '--port=80'],
        }),
      );
      await scrollToEnd(tester);
      final text = allText(tester);
      expect(text, contains('node server.js --password ••••'));
      expect(text, isNot(contains('fake-pass')));
    });

    testWidgets('a cleartext address is flagged on the detail too', (
      tester,
    ) async {
      await open(
        tester,
        server({'transport': 'http', 'url': 'http://mcp.example.com/sse'}),
      );
      await scrollToEnd(tester);
      expect(find.byKey(const ValueKey('spp-row-insecure')), findsOneWidget);
      expect(find.textContaining('red que no controlas'), findsOneWidget);

      await open(
        tester,
        server({'transport': 'http', 'url': 'http://localhost:9000/mcp'}),
      );
      await scrollToEnd(tester);
      // Plain http inside a private network is not worth a row.
      expect(find.byKey(const ValueKey('spp-row-insecure')), findsNothing);

      await open(
        tester,
        server({'transport': 'http', 'url': 'https://mcp.example.com/sse'}),
      );
      await scrollToEnd(tester);
      expect(find.byKey(const ValueKey('spp-row-insecure')), findsNothing);
    });
  });

  testWidgets('the server log is shown with its credentials hidden', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..gets['logs'] = {
        'lines': [
          'starting https://u:pw-fake@mcp.example.com/sse?api_key=fake-key',
          'Authorization: Bearer fake-bearer-value',
          'env API_TOKEN=fake-env-token PORT=80',
          'connected, 4 tools',
        ],
      };
    await setPhone(tester);
    await tester.pumpWidget(
      spanishApp(
        McpLogsScreen(repository: repoOf(rest), server: 'docs', stdio: false),
      ),
    );
    await tester.pumpAndSettle();
    final shown = tester
        .widget<SelectableText>(find.byKey(const ValueKey('cph-logs-text')))
        .data!;
    expect(shown, contains('https://mcp.example.com/sse?…'));
    expect(shown, contains('connected, 4 tools'));
    expect(shown, contains('PORT=80'));
    for (final secret in [
      'pw-fake',
      'fake-key',
      'fake-bearer',
      'fake-env-token',
    ]) {
      expect(shown, isNot(contains(secret)), reason: secret);
    }
  });
}
