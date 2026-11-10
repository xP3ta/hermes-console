// Inline switches of the Installed list: they flip at once, ask the server,
// and go back with a reason when the server does not take the change.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayRpcError;

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

/// A server that holds every PUT until the test lets it go.
final class _HeldRest extends ScriptedRest {
  final Completer<void> gate = Completer<void>();
  Object? outcome;

  @override
  Future<Map<String, dynamic>> put(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    calls.add('PUT $endpoint');
    bodies.add(body);
    await gate.future;
    final value = outcome;
    if (value is Exception) throw value;
    return {'ok': true};
  }
}

Future<void> _pumpHub(
  WidgetTester tester,
  ScriptedRest rest, {
  CapabilitiesRpc? rpc,
  bool readOnly = false,
  ExtensionsTab? tab,
  CapabilitiesSegment segment = CapabilitiesSegment.installed,
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      CapabilitiesScreen(
        repository: repoOf(rest, rpc: rpc),
        readOnly: readOnly,
        initialTab: tab,
        initialSegment: segment,
        searchDebounce: Duration.zero,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _switch(String id) => find.byKey(ValueKey('spp-switch-$id'));

bool _on(WidgetTester tester, String id) =>
    tester.widget<Switch>(_switch(id)).value;

bool _enabled(WidgetTester tester, String id) =>
    tester.widget<Switch>(_switch(id)).onChanged != null;

const _notes = 'skill:installed:notes';
const _arxiv = 'skill:official:official/research/arxiv';

void main() {
  setUpAll(loadInterFont);

  testWidgets('the installed list counts what is installed and what is on', (
    tester,
  ) async {
    await _pumpHub(tester, populatedServer());
    expect(find.text('2 instalados · 1 activos'), findsOneWidget);
    expect(_on(tester, _arxiv), isTrue);
    expect(_on(tester, _notes), isFalse);
  });

  testWidgets('a confirmed switch sticks and patches the list in place', (
    tester,
  ) async {
    final rest = populatedServer()..puts['skills/toggle'] = {'ok': true};
    await _pumpHub(tester, rest);
    final readsBefore = rest.calls.where((c) => c.startsWith('GET')).length;

    await tester.tap(_switch(_notes));
    await tester.pumpAndSettle();

    expect(rest.mutations, ['PUT skills/toggle']);
    expect(rest.bodies.last, {'name': 'notes', 'enabled': true});
    expect(_on(tester, _notes), isTrue);
    expect(find.text('2 instalados · 2 activos'), findsOneWidget);
    // Patched, not reloaded.
    expect(rest.calls.where((c) => c.startsWith('GET')).length, readsBefore);
  });

  testWidgets('a refusal puts the switch back and says why', (tester) async {
    final rest = populatedServer()
      ..puts['skills/toggle'] = const DashboardHttpException(
        500,
        body: '{"detail":"disk full"}',
      );
    await _pumpHub(tester, rest);

    await tester.tap(_switch(_notes));
    await tester.pumpAndSettle();

    expect(rest.mutations, ['PUT skills/toggle']);
    expect(_on(tester, _notes), isFalse);
    expect(_enabled(tester, _notes), isTrue, reason: 'usable again');
    expect(find.textContaining('No se pudo cambiar notes'), findsOneWidget);
    expect(find.text('2 instalados · 1 activos'), findsOneWidget);
  });

  testWidgets('a server that rejects the change with a reason shows it', (
    tester,
  ) async {
    final rest = populatedServer()
      ..puts['skills/toggle'] = const DashboardHttpException(
        400,
        body: '{"detail":"skill is locked"}',
      );
    await _pumpHub(tester, rest);
    await tester.tap(_switch(_arxiv));
    await tester.pumpAndSettle();
    expect(_on(tester, _arxiv), isTrue);
    expect(find.textContaining('skill is locked'), findsOneWidget);
  });

  testWidgets('it flips before the answer and a second tap does nothing', (
    tester,
  ) async {
    final rest = _HeldRest();
    populatedServer()
      ..gets.forEach((key, value) => rest.gets[key] = value)
      ..posts.forEach((key, value) => rest.posts[key] = value);
    await _pumpHub(tester, rest);

    await tester.tap(_switch(_notes));
    await tester.pump();
    expect(_on(tester, _notes), isTrue, reason: 'optimistic');
    expect(_enabled(tester, _notes), isFalse, reason: 'no double tap');

    await tester.tap(_switch(_notes), warnIfMissed: false);
    await tester.pump();
    expect(rest.calls.where((c) => c.startsWith('PUT')), hasLength(1));

    rest.outcome = const DashboardHttpException(503);
    rest.gate.complete();
    await tester.pumpAndSettle();
    expect(_on(tester, _notes), isFalse, reason: 'rolled back');
    expect(_enabled(tester, _notes), isTrue);
  });

  testWidgets('a lost connection mid-change rolls back too', (tester) async {
    final rest = populatedServer()
      ..puts['skills/toggle'] = TimeoutException('slow');
    await _pumpHub(tester, rest);
    await tester.tap(_switch(_notes));
    await tester.pumpAndSettle();
    expect(_on(tester, _notes), isFalse);
    expect(find.textContaining('No se pudo cambiar notes'), findsOneWidget);
  });

  testWidgets('read-only: switches show the state and cannot be used', (
    tester,
  ) async {
    final rest = populatedServer();
    await _pumpHub(tester, rest, readOnly: true);
    expect(_on(tester, _arxiv), isTrue);
    expect(_enabled(tester, _arxiv), isFalse);
    await tester.tap(_switch(_arxiv), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(rest.mutations, isEmpty);
  });

  testWidgets('the state filter narrows the installed list', (tester) async {
    await _pumpHub(tester, populatedServer());
    await tester.tap(find.byKey(const ValueKey('spp-status-inactive')));
    await tester.pumpAndSettle();
    expect(find.text('notes'), findsOneWidget);
    expect(find.text('arxiv'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('spp-status-active')));
    await tester.pumpAndSettle();
    expect(find.text('notes'), findsNothing);
    expect(find.text('arxiv'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('spp-status-all')));
    await tester.pumpAndSettle();
    expect(find.text('notes'), findsOneWidget);
  });

  testWidgets('an empty filter result says so instead of a blank page', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..gets['skills'] = [
        {'name': 'one', 'enabled': true, 'provenance': 'agent'},
      ]
      ..gets['skills/hub/official'] = {'skills': <Object>[]};
    await _pumpHub(tester, rest);
    await tester.tap(find.byKey(const ValueKey('spp-status-inactive')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-empty-installed')), findsOneWidget);
  });

  group('plugins', () {
    Future<Map<String, dynamic>> manage(
      String method,
      Map<String, dynamic> params, {
      bool restart = false,
      Object? toggleError,
    }) async {
      if (method == 'plugins.manage') {
        if (params['action'] == 'list') {
          return {
            'plugins': [
              {
                'name': 'weather',
                'key': 'tools/weather',
                'catalog_name': 'weather',
                'status': 'enabled',
                'version': '1.2.0',
                'source': 'user',
              },
            ],
          };
        }
        if (params['action'] == 'toggle') {
          if (toggleError != null) throw toggleError;
          return {'ok': true, 'restart_required': restart};
        }
      }
      throw TuiGatewayRpcError(method, 'nope', code: -32601);
    }

    testWidgets('rows show version and origin', (tester) async {
      await _pumpHub(
        tester,
        populatedServer(),
        tab: ExtensionsTab.plugins,
        rpc: (m, p) => manage(m, p),
      );
      final row = find.byKey(
        const ValueKey('cph-row-plugin:community:weather'),
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('v1.2.0 · Usuario'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a server that wants a restart says so', (tester) async {
      await _pumpHub(
        tester,
        populatedServer(),
        tab: ExtensionsTab.plugins,
        rpc: (m, p) => manage(m, p, restart: true),
      );
      const id = 'plugin:community:weather';
      await tester.tap(_switch(id));
      await tester.pumpAndSettle();
      expect(_on(tester, id), isFalse);
      expect(find.textContaining('Reinicia el gateway'), findsOneWidget);
    });

    testWidgets('a refused plugin switch goes back', (tester) async {
      await _pumpHub(
        tester,
        populatedServer(),
        tab: ExtensionsTab.plugins,
        rpc: (m, p) => manage(
          m,
          p,
          toggleError: TuiGatewayRpcError(m, 'refused', code: -32000),
        ),
      );
      const id = 'plugin:community:weather';
      await tester.tap(_switch(id));
      await tester.pumpAndSettle();
      expect(_on(tester, id), isTrue);
      expect(find.textContaining('No se pudo cambiar Weather'), findsOneWidget);
    });

    testWidgets('a plugin without a canonical key cannot be switched', (
      tester,
    ) async {
      await _pumpHub(tester, populatedServer(), tab: ExtensionsTab.plugins);
      expect(_enabled(tester, 'plugin:community:weather'), isFalse);
    });
  });

  group('MCP servers', () {
    testWidgets('the row has a switch, state and target in the text', (
      tester,
    ) async {
      final rest = populatedServer()
        ..puts['mcp/servers/docs/enabled'] = {'ok': true};
      await _pumpHub(tester, rest, tab: ExtensionsTab.mcp);
      final row = find.byKey(const ValueKey('cph-row-mcp:server:docs'));
      expect(
        find.descendant(
          of: row,
          matching: find.text(
            '0 herramientas · Activa · https://mcp.example.com/docs',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(_switch('mcp:server:docs'));
      await tester.pumpAndSettle();
      expect(rest.mutations, ['PUT mcp/servers/docs/enabled']);
      expect(rest.bodies.last, {'enabled': false});
      expect(_on(tester, 'mcp:server:docs'), isFalse);
      expect(
        find.descendant(of: row, matching: find.textContaining('Desactivada')),
        findsOneWidget,
      );
    });

    testWidgets('a refused MCP switch goes back', (tester) async {
      final rest = populatedServer()
        ..puts['mcp/servers/docs/enabled'] = const DashboardHttpException(500);
      await _pumpHub(tester, rest, tab: ExtensionsTab.mcp);
      await tester.tap(_switch('mcp:server:docs'));
      await tester.pumpAndSettle();
      expect(_on(tester, 'mcp:server:docs'), isTrue);
      expect(find.textContaining('No se pudo cambiar docs'), findsOneWidget);
    });

    testWidgets('credentials in the address or arguments are never shown', (
      tester,
    ) async {
      final rest = populatedServer()
        ..gets['mcp/servers'] = {
          'servers': [
            {
              'name': 'secret-url',
              'transport': 'http',
              'url':
                  'https://user:pw-fake@mcp.example.com/sse?api_key=fake-key-123',
              'enabled': true,
              'env': {'API_TOKEN': 'sk-fakefakefakefakefake01'},
            },
            {
              'name': 'secret-cmd',
              'transport': 'stdio',
              'command': 'node',
              'args': ['server.js', '--api-key', 'fake-key-456', '--port=80'],
              'enabled': true,
              'env': {'API_TOKEN': 'sk-fakefakefakefakefake02'},
            },
          ],
        };
      await _pumpHub(tester, rest, tab: ExtensionsTab.mcp);

      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(shown, contains('https://mcp.example.com/sse?…'));
      expect(shown, contains('node server.js --api-key ••••'));
      for (final secret in [
        'pw-fake',
        'fake-key-123',
        'fake-key-456',
        'sk-fakefake',
        'API_TOKEN',
      ]) {
        expect(shown, isNot(contains(secret)), reason: secret);
      }
    });
  });
}
