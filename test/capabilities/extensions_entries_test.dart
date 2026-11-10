// Every way in lands on the one Extensions screen, on the right tab and with
// the right profile; the old centre redirects instead of breaking.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart'
    show CapabilityKind;
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/extensions_center_screen.dart';
import 'package:hermes_android/core/screens/extensions_tools_screen.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'exu-entries',
  label: 'Synthetic hub',
  host: '127.0.0.1',
  port: 9,
  apiKey: 'synth...ub',
  kind: InstanceKind.vps,
  readOnly: readOnly,
);

class _NoGateway implements HermesDesktopControlGateway {
  @override
  Future<ExtensionsInventory> extensionsInventory({
    String runtimeSessionId = '',
  }) async => const ExtensionsInventory(plugins: [], toolsets: []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadInterFont);
  setUp(
    () => SharedGatewayPool.debugDefaultLinger = const Duration(minutes: 5),
  );
  tearDown(() {
    SharedGatewayPool.instance.disconnectIdle();
    SharedGatewayPool.debugDefaultLinger = Duration.zero;
  });

  ExtensionsTab selected(WidgetTester tester) => tester
      .widget<HermesSegmentedControl<ExtensionsTab>>(
        find.byType(HermesSegmentedControl<ExtensionsTab>),
      )
      .value;

  Future<void> show(
    WidgetTester tester,
    Widget hub, {
    Size size = const Size(390, 844),
  }) async {
    await setPhone(tester);
    await tester.pumpWidget(spanishApp(hub));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // The pool keeps the socket for the next visit; no timer may outlive the
    // test.
    SharedGatewayPool.instance.disconnectIdle();
  }

  group('the tab and the profile of each entry', () {
    for (final entry in <(String, ExtensionsTab)>[
      ('skills', ExtensionsTab.skills),
      ('plugins', ExtensionsTab.plugins),
      ('mcp', ExtensionsTab.mcp),
    ]) {
      testWidgets('a secondary profile opens ${entry.$1} with its own '
          'repository, ⋯ included', (tester) async {
        await show(
          tester,
          CapabilitiesHub(
            connection: _connection(),
            profile: 'infra',
            initialTab: entry.$2,
          ),
        );
        expect(selected(tester), entry.$2);
        final screen = tester.widget<CapabilitiesScreen>(
          find.byType(CapabilitiesScreen),
        );
        expect(screen.repository.profile, 'infra');
        expect(screen.destinationLabel, endsWith('infra'));
        // Server-wide pages hang from the same ⋯ whatever the profile.
        expect(find.byTooltip('Más opciones'), findsOneWidget);
        await close(tester);
      });
    }

    testWidgets('legacy segment arguments redirect: connectors → MCP, '
        'installed plugin → Plugins, catalog → a hub page', (tester) async {
      await show(
        tester,
        CapabilitiesHub(
          connection: _connection(),
          initialSegment: CapabilitiesSegment.connectors,
        ),
      );
      expect(selected(tester), ExtensionsTab.mcp);
      await close(tester);

      await show(
        tester,
        CapabilitiesHub(
          connection: _connection(),
          initialKind: CapabilityKind.plugin,
        ),
      );
      expect(selected(tester), ExtensionsTab.plugins);
      await close(tester);

      await show(
        tester,
        CapabilitiesHub(
          connection: _connection(),
          initialSegment: CapabilitiesSegment.catalog,
          initialKind: CapabilityKind.plugin,
        ),
      );
      expect(find.byType(HermesSegmentedControl<ExtensionsTab>), findsNothing);
      expect(find.text('Plugin Hub'), findsOneWidget);
      await close(tester);
    });

    testWidgets('read-only connection: the screen is read-only too', (
      tester,
    ) async {
      await show(
        tester,
        CapabilitiesHub(connection: _connection(readOnly: true)),
      );
      expect(
        tester
            .widget<CapabilitiesScreen>(find.byType(CapabilitiesScreen))
            .readOnly,
        isTrue,
      );
      await close(tester);
    });

    testWidgets('a conversation opens the tool groups of that conversation', (
      tester,
    ) async {
      await show(
        tester,
        CapabilitiesHub(
          connection: _connection(),
          initialTab: ExtensionsTab.plugins,
          runtimeSessionId: 'runtime-a',
        ),
      );
      // The lists are still loading from a server that is not there: the
      // loader never settles, so the frames are pumped by hand.
      await tester.tap(find.byTooltip('Más opciones'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('exu-more-tools')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final tools = tester.widget<ExtensionsToolsScreen>(
        find.byType(ExtensionsToolsScreen),
      );
      expect(tools.runtimeSessionId, 'runtime-a');
      expect(find.text('Grupos de herramientas'), findsWidgets);
      await close(tester);
    });
  });

  group('the old Extensions centre redirects', () {
    testWidgets('with a live gateway: the Extensions screen on Plugins', (
      tester,
    ) async {
      final gateway = TuiGatewayClient(_connection());
      await show(tester, ExtensionsCenterScreen(gateway: gateway));
      expect(find.byType(CapabilitiesHub), findsOneWidget);
      expect(selected(tester), ExtensionsTab.plugins);
      await close(tester);
      await gateway.close();
    });

    testWidgets('without a connection to build from: the tool groups', (
      tester,
    ) async {
      await show(tester, ExtensionsCenterScreen(gateway: _NoGateway()));
      expect(find.byType(ExtensionsToolsScreen), findsOneWidget);
      expect(find.text('Grupos de herramientas'), findsWidgets);
      expect(
        find.text('Funciones integradas de Hermes que el agente puede usar'),
        findsOneWidget,
      );
      await close(tester);
    });
  });
}
