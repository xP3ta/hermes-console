// The plain-http note: quiet and shown once per connection.
//
// Private networks (LAN, Tailscale, localhost, .local) get nothing; a public
// host gets one short line, once, remembered per connection; a secret headed
// for a public http host keeps the strong, undismissable notice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesSelectField;
import 'package:hermes_android/core/models/admin_integrations.dart';
import 'package:hermes_android/core/utils/cleartext_notice_memory.dart';
import 'package:hermes_android/core/widgets/cleartext_once_line.dart';
import 'package:hermes_android/core/widgets/mcp_provisioning_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capabilities/capabilities_fakes.dart';
import 'support/inter_font.dart';

const _line = ValueKey('krh-http-line');
const _strong = ValueKey('spp-mcp-insecure');

Future<void> _openForm(WidgetTester tester, {String? connectionId}) async {
  await setPhone(tester);
  // A fresh route each time, as when the form is opened again.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    spanishApp(McpServerDraftSurface(connectionId: connectionId)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('mcp-transport-http')));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
  // The plain-http notes wait until the address stops changing.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(loadInterFont);

  group('memory', () {
    test('the key ends with the connection id and starts as unseen', () async {
      SharedPreferences.setMockInitialValues({});
      final memory = CleartextNoticeMemory(
        await SharedPreferences.getInstance(),
      );
      expect(memory.seen('c1'), isFalse);
      await memory.markSeen('c1');
      expect(memory.seen('c1'), isTrue);
      expect(memory.seen('c2'), isFalse);
      expect(CleartextNoticeMemory.keyFor('c1'), 'krh_http_seen_c1');
    });
  });

  group('MCP form', () {
    testWidgets('private networks and https show nothing at all', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _openForm(tester, connectionId: 'c1');
      for (final url in [
        'https://mcp.example.com/sse',
        'http://localhost:9000/mcp',
        'http://127.0.0.1:9000/mcp',
        'http://10.0.0.5:9000/mcp',
        'http://172.16.4.2:9000/mcp',
        'http://192.168.1.20:9000/mcp',
        'http://100.64.0.1:9000/mcp',
        'http://100.127.255.254:9000/mcp',
        'http://box.tail1234.ts.net:9000/mcp',
        'http://nas.local:9000/mcp',
      ]) {
        await _type(tester, 'mcp-draft-url', url);
        await tester.pumpAndSettle();
        expect(find.byKey(_line), findsNothing, reason: url);
        expect(find.byKey(_strong), findsNothing, reason: url);
        expect(find.textContaining('sin cifrar'), findsNothing, reason: url);
      }
      // Just outside Tailscale's block it is a public address.
      await _type(tester, 'mcp-draft-url', 'http://100.128.0.1:9000/mcp');
      await tester.pumpAndSettle();
      expect(find.byKey(_line), findsOneWidget);
    });

    testWidgets('typing a private address flashes nothing and spends nothing', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _openForm(tester, connectionId: 'c1');
      final prefs = await SharedPreferences.getInstance();
      // Half-typed private addresses read as public ("192." is not yet an IP).
      for (final typed in [
        for (final url in [
          'http://192.168.1.5:9000/mcp',
          'http://100.101.102.103:9000/mcp',
          'http://box.tail1234.ts.net/mcp',
        ])
          for (var n = 8; n <= url.length; n++) url.substring(0, n),
      ]) {
        await tester.enterText(
          find.byKey(const ValueKey('mcp-draft-url')),
          typed,
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(_line), findsNothing, reason: typed);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_line), findsNothing);
      expect(CleartextNoticeMemory(prefs).seen('c1'), isFalse);

      // A public host shows it once the typing stops, and only then is it spent.
      await tester.enterText(
        find.byKey(const ValueKey('mcp-draft-url')),
        'http://mcp.example.com/sse',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_line), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(_line), findsOneWidget);
      expect(CleartextNoticeMemory(prefs).seen('c1'), isTrue);
    });

    testWidgets('a public http host gets one line, once per connection', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _openForm(tester, connectionId: 'c1');
      await _type(tester, 'mcp-draft-url', 'http://mcp.example.com/sse');
      await tester.pumpAndSettle();
      expect(find.byKey(_line), findsOneWidget);
      expect(find.textContaining('lo que viaje puede leerse'), findsOneWidget);
      // A single line: no banner, no dialog, no strong notice.
      expect(find.byKey(_strong), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);

      // It was marked as seen when it appeared, even without dismissing it.
      final prefs = await SharedPreferences.getInstance();
      expect(CleartextNoticeMemory(prefs).seen('c1'), isTrue);

      // Dismissing hides it for the form.
      await tester.tap(
        find.descendant(
          of: find.byKey(_line),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_line), findsNothing);

      // The next time, for the same connection: nothing.
      await _openForm(tester, connectionId: 'c1');
      await _type(tester, 'mcp-draft-url', 'http://mcp.example.com/sse');
      await tester.pumpAndSettle();
      expect(find.byKey(_line), findsNothing);

      // Another connection has not seen it yet.
      await _openForm(tester, connectionId: 'c2');
      await _type(tester, 'mcp-draft-url', 'http://mcp.example.com/sse');
      await tester.pumpAndSettle();
      expect(find.byKey(_line), findsOneWidget);
    });

    testWidgets('a token for a public http host keeps the strong notice', (
      tester,
    ) async {
      // Already seen: the memory must not silence what protects a secret.
      SharedPreferences.setMockInitialValues({'krh_http_seen_c1': true});
      await _openForm(tester, connectionId: 'c1');
      await _type(tester, 'mcp-draft-url', 'http://mcp.example.com/sse');
      await tester.tap(find.byType(HermesSelectField<McpAuthMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cabecera Bearer').last);
      await tester.pumpAndSettle();

      expect(find.byKey(_strong), findsOneWidget);
      expect(find.textContaining('enviarías un token'), findsOneWidget);
      expect(find.byKey(_line), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(_strong),
          matching: find.byType(IconButton),
        ),
        findsNothing,
      );

      // And on a private network the token needs no notice.
      await _type(tester, 'mcp-draft-url', 'http://100.101.102.103:9000/mcp');
      await tester.pumpAndSettle();
      expect(find.byKey(_strong), findsNothing);
    });
  });

  group('the line on its own', () {
    testWidgets('without a connection it lasts as long as the widget', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      for (var i = 0; i < 2; i++) {
        await tester.pumpWidget(
          spanishApp(
            const Scaffold(body: CleartextOnceLine(message: 'Línea de prueba')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Línea de prueba'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}
