// The one Extensions screen: Skills · Plugins · MCP. Each tab is
// self-sufficient (search, «N installed · M active», status filter, flat rows
// with the switch), has its own «+» with its own actions, and the hubs open
// as a page over the tab and come back to it. The server-wide pieces live in
// the ⋯ of the header.
// ignore_for_file: deprecated_member_use
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart'
    show CapabilitiesRpc;
import 'package:hermes_android/core/capabilities/capability_models.dart'
    show CapabilityKind;
import 'package:hermes_android/core/capabilities/capability_plain_rows.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesSpace;
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

Future<List<(String, bool)>> _pump(
  WidgetTester tester,
  ScriptedRest rest, {
  ExtensionsTab? tab,
  CapabilitiesSegment segment = CapabilitiesSegment.installed,
  CapabilityKind? kind,
  bool readOnly = false,
  CapabilitiesRpc? rpc,
  bool withServer = false,
  bool withInstaller = false,
  bool withLearn = false,
  Locale locale = const Locale('es'),
  double textScale = 1,
  String theme = 'dark',
  Size? size,
}) async {
  final installs = <(String, bool)>[];
  if (size == null) {
    await setPhone(tester);
  } else {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size ?? const Size(390, 844),
        devicePixelRatio: size == null ? 3 : 2,
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        theme: AppTheme.fromId(theme),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: CapabilitiesScreen(
          repository: repoOf(rest, rpc: rpc),
          readOnly: readOnly,
          initialTab: tab,
          initialSegment: segment,
          initialKind: kind,
          searchDebounce: Duration.zero,
          learnLauncher: withLearn ? (context, prompt) async {} : null,
          toolsBuilder: withServer
              ? (_) => const Scaffold(body: Text('tools-page'))
              : null,
          serverBuilder: withServer
              ? (_) => const Scaffold(body: Text('server-page'))
              : null,
          sourceInstaller: withInstaller
              ? (identifier, {required enable}) async {
                  installs.add((identifier, enable));
                  return const DesktopExtensionInstallResult(accepted: true);
                }
              : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return installs;
}

Future<void> _tab(WidgetTester tester, ExtensionsTab tab) async {
  await tester.tap(find.byKey(ValueKey('exu-tab-${tab.name}')));
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('exu-add')));
  await tester.pumpAndSettle();
}

bool _selected(WidgetTester tester, ExtensionsTab tab) {
  final control = tester.widget<HermesSegmentedControl<ExtensionsTab>>(
    find.byType(HermesSegmentedControl<ExtensionsTab>),
  );
  return control.value == tab;
}

void main() {
  setUpAll(loadInterFont);

  group('three tabs, one screen', () {
    testWidgets('Skills · Plugins · MCP under one title, Skills first', (
      tester,
    ) async {
      await _pump(tester, populatedServer());
      expect(find.text('Extensiones'), findsOneWidget);
      for (final tab in ExtensionsTab.values) {
        expect(find.byKey(ValueKey('exu-tab-${tab.name}')), findsOneWidget);
      }
      expect(_selected(tester, ExtensionsTab.skills), isTrue);
      // The old second entry points are gone from the body.
      expect(find.text('Integraciones del servidor'), findsNothing);
      expect(find.text('Explorar catálogo MCP'), findsNothing);
    });

    testWidgets('each tab counts, filters and searches on its own', (
      tester,
    ) async {
      await _pump(tester, populatedServer());
      // Skills: arxiv (on) and notes (off).
      expect(find.text('2 instalados · 1 activos'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('spp-status-active')));
      await tester.pumpAndSettle();
      expect(find.text('arxiv'), findsOneWidget);
      expect(find.text('notes'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('cph-search')), 'arx');
      await tester.pumpAndSettle();

      await _tab(tester, ExtensionsTab.plugins);
      // Plugins: the filter and the search of the other tab do not follow.
      expect(find.text('Weather'), findsOneWidget);
      expect(find.text('1 instalados · 1 activos'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cph-search')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('spp-status-inactive')));
      await tester.pumpAndSettle();
      expect(find.text('Weather'), findsNothing);

      await _tab(tester, ExtensionsTab.mcp);
      expect(find.text('docs'), findsOneWidget);
      expect(find.text('1 instalados · 1 activos'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('cph-search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('docs'), findsNothing);

      // Back on Skills: its own filter and search are as they were left.
      await _tab(tester, ExtensionsTab.skills);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cph-search')))
            .controller!
            .text,
        'arx',
      );
      expect(find.text('arxiv'), findsOneWidget);
      expect(find.text('notes'), findsNothing);
    });

    testWidgets('a row opens its detail and the switch keeps its own tap', (
      tester,
    ) async {
      final rest = populatedServer()
        ..puts['mcp/servers/docs/enabled'] = {'ok': true};
      await _pump(tester, rest, tab: ExtensionsTab.mcp);
      await tester.tap(
        find.byKey(const ValueKey('spp-switch-mcp:server:docs')),
      );
      await tester.pumpAndSettle();
      expect(rest.mutations, ['PUT mcp/servers/docs/enabled']);
      await tester.tap(find.text('docs'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cph-detail-list')), findsOneWidget);
    });

    testWidgets('legacy arguments redirect to the right tab', (tester) async {
      await _pump(
        tester,
        populatedServer(),
        segment: CapabilitiesSegment.connectors,
      );
      expect(_selected(tester, ExtensionsTab.mcp), isTrue);
      expect(find.byKey(const ValueKey('cph-accounts-note')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _pump(tester, populatedServer(), tab: ExtensionsTab.plugins);
      expect(_selected(tester, ExtensionsTab.plugins), isTrue);
    });
  });

  group('the «+» of each tab', () {
    testWidgets('Skills: hub, new, learn and update', (tester) async {
      await _pump(tester, populatedServer(), withLearn: true);
      await _add(tester);
      expect(find.byKey(const ValueKey('exu-add-skill-hub')), findsOneWidget);
      expect(find.byKey(const ValueKey('spp-menu-new-skill')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('las-menu-learn-skill')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cph-menu-update-skills')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('exu-add-plugin-hub')), findsNothing);
      expect(find.byKey(const ValueKey('spp-menu-add-mcp')), findsNothing);
    });

    testWidgets('Plugins: hub and install from Git or owner/repo', (
      tester,
    ) async {
      await _pump(
        tester,
        populatedServer(),
        tab: ExtensionsTab.plugins,
        withInstaller: true,
      );
      await _add(tester);
      expect(find.byKey(const ValueKey('exu-add-plugin-hub')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('exu-add-plugin-source')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('spp-menu-new-skill')), findsNothing);
    });

    testWidgets('MCP: catalog and add a server by hand', (tester) async {
      await _pump(tester, populatedServer(), tab: ExtensionsTab.mcp);
      await _add(tester);
      expect(find.byKey(const ValueKey('exu-add-mcp-catalog')), findsOneWidget);
      expect(find.byKey(const ValueKey('spp-menu-add-mcp')), findsOneWidget);
    });

    testWidgets('the menu is opaque: nothing of the list reads through', (
      tester,
    ) async {
      await _pump(tester, populatedServer());
      await _add(tester);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('read-only: only the hubs, never a write entry', (
      tester,
    ) async {
      await _pump(
        tester,
        populatedServer(),
        tab: ExtensionsTab.plugins,
        readOnly: true,
        withInstaller: true,
      );
      await _add(tester);
      expect(find.byKey(const ValueKey('exu-add-plugin-hub')), findsOneWidget);
      expect(find.byKey(const ValueKey('exu-add-plugin-source')), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await _tab(tester, ExtensionsTab.mcp);
      await _add(tester);
      expect(find.byKey(const ValueKey('exu-add-mcp-catalog')), findsOneWidget);
      expect(find.byKey(const ValueKey('spp-menu-add-mcp')), findsNothing);
    });
  });

  group('install from Git or owner/repo', () {
    Future<List<(String, bool)>> open(WidgetTester tester) async {
      final installs = await _pump(
        tester,
        populatedServer(),
        tab: ExtensionsTab.plugins,
        withInstaller: true,
      );
      await _add(tester);
      await tester.tap(find.byKey(const ValueKey('exu-add-plugin-source')));
      await tester.pumpAndSettle();
      return installs;
    }

    testWidgets('validates, reviews and sends one typed request', (
      tester,
    ) async {
      final installs = await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('extensions-plugin-identifier')),
        'nousresearch/example-plugin',
      );
      await tester.tap(find.text('Revisar e instalar'));
      await tester.pumpAndSettle();
      expect(find.text('Confirmar instalación'), findsOneWidget);
      expect(
        find.textContaining('nousresearch/example-plugin'),
        findsOneWidget,
      );
      expect(installs, isEmpty);

      await tester.tap(find.text('Instalar'));
      await tester.pumpAndSettle();
      // Installs land switched off unless the person turns it on in the form.
      expect(installs, [('nousresearch/example-plugin', false)]);
    });

    testWidgets('declining the confirmation sends nothing', (tester) async {
      final installs = await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('extensions-plugin-identifier')),
        'nousresearch/example-plugin',
      );
      await tester.tap(find.text('Revisar e instalar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(installs, isEmpty);
    });

    testWidgets('an unsafe source never reaches the installer', (tester) async {
      final installs = await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('extensions-plugin-identifier')),
        'http://user:pass@example.test/plugin?token=secret',
      );
      await tester.tap(find.text('Revisar e instalar'));
      await tester.pump();
      expect(
        find.textContaining('Usa owner/repo o una URL Git HTTPS'),
        findsOneWidget,
      );
      expect(installs, isEmpty);
    });
  });

  group('hubs: a page over the tab, back returns to the same tab', () {
    for (final entry in <(ExtensionsTab, String, String, String)>[
      (ExtensionsTab.skills, 'exu-add-skill-hub', 'Skill Hub', 'Buscar skills'),
      (
        ExtensionsTab.plugins,
        'exu-add-plugin-hub',
        'Plugin Hub',
        'Buscar plugins',
      ),
      (
        ExtensionsTab.mcp,
        'exu-add-mcp-catalog',
        'Catálogo MCP',
        'Buscar servidores MCP',
      ),
    ]) {
      testWidgets('${entry.$3} opens and goes back to ${entry.$1.name}', (
        tester,
      ) async {
        await _pump(tester, populatedServer(), tab: entry.$1);
        await _add(tester);
        await tester.tap(find.byKey(ValueKey(entry.$2)));
        await tester.pumpAndSettle();
        // The hub is its own page: a title, no tabs, no «+».
        expect(find.text(entry.$3), findsOneWidget);
        expect(find.byKey(const ValueKey('exu-add')), findsNothing);
        expect(
          find.byType(HermesSegmentedControl<ExtensionsTab>),
          findsNothing,
        );

        tester.state<NavigatorState>(find.byType(Navigator).last).pop();
        await tester.pumpAndSettle();
        expect(_selected(tester, entry.$1), isTrue);
        expect(find.text('Extensiones'), findsOneWidget);
        expect(find.text(entry.$4), findsOneWidget);
      });
    }

    testWidgets('the Skill Hub lists the official catalog', (tester) async {
      await _pump(tester, populatedServer());
      await _add(tester);
      await tester.tap(find.byKey(const ValueKey('exu-add-skill-hub')));
      await tester.pumpAndSettle();
      expect(find.text('docker'), findsOneWidget);
      // Only skills: no plugin in this hub.
      expect(find.text('Weather'), findsNothing);
    });
  });

  testWidgets(
    'MCP rows count inventory tools, deduplicate aliases and keep one server switch',
    (tester) async {
      final calls = <String>[];
      final rest = populatedServer()
        ..gets['mcp/servers'] = {
          'servers': [
            {'name': 'docs', 'enabled': true},
            {'name': 'empty', 'enabled': false},
            {
              'name': 'static',
              'tools': ['one', 'two'],
            },
            {'name': 'runtime'},
          ],
        };
      await _pump(
        tester,
        rest,
        tab: ExtensionsTab.mcp,
        rpc: (method, params) async {
          calls.add(method);
          return switch (method) {
            'plugins.manage' => {'plugins': <Object>[]},
            'tools.list' => {
              'toolsets': [
                {
                  'name': 'docs',
                  'description': "MCP server 'docs' tools",
                  'tool_count': 7,
                },
                {
                  'name': 'mcp-docs',
                  'description': "MCP server 'docs' tools",
                  'tool_count': 7,
                },
                {'name': 'empty', 'tool_count': 0},
                {'name': 'browser', 'tool_count': 99},
              ],
            },
            'mcp.servers.status' => {
              'servers': [
                {'name': 'docs', 'status': 'connected', 'tools': 3},
                {'name': 'runtime', 'status': 'connected', 'tools': 4},
              ],
            },
            _ => <String, dynamic>{},
          };
        },
      );
      for (final entry in [
        ('docs', 7),
        ('empty', 0),
        ('static', 2),
        ('runtime', 4),
      ]) {
        final row = find.byKey(ValueKey('cph-row-mcp:server:${entry.$1}'));
        expect(
          find.descendant(
            of: row,
            matching: find.textContaining('${entry.$2} herramientas'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.byType(Switch)),
          findsOneWidget,
        );
      }
      expect(calls.where((method) => method == 'tools.list'), hasLength(1));
      expect(calls, isNot(contains('tools.configure')));
    },
  );

  testWidgets('320 dp at 2x keeps three tabs and opens Tool groups from more', (
    tester,
  ) async {
    await _pump(
      tester,
      populatedServer(),
      withServer: true,
      size: const Size(320, 900),
      textScale: 2,
    );
    final control = tester.widget<HermesSegmentedControl<ExtensionsTab>>(
      find.byType(HermesSegmentedControl<ExtensionsTab>),
    );
    expect(control.segments.map((s) => s.value), ExtensionsTab.values);
    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();
    expect(find.text('Grupos de herramientas'), findsOneWidget);
    expect(find.text('Webhooks y estado del servidor'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('exu-more-tools')));
    await tester.pumpAndSettle();
    expect(find.text('tools-page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('the ⋯ of the header', () {
    testWidgets('Tool groups and Webhooks and server status, nothing else', (
      tester,
    ) async {
      await _pump(tester, populatedServer(), withServer: true);
      await tester.tap(find.byTooltip('Más opciones'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('exu-more-tools')), findsOneWidget);
      expect(find.text('Grupos de herramientas'), findsOneWidget);
      expect(find.text('Herramientas'), findsNothing);
      expect(find.byKey(const ValueKey('exu-more-server')), findsOneWidget);
      expect(find.text('Webhooks y estado del servidor'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('exu-more-server')));
      await tester.pumpAndSettle();
      expect(find.text('server-page'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).last).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Más opciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('exu-more-tools')));
      await tester.pumpAndSettle();
      expect(find.text('tools-page'), findsOneWidget);
    });

    testWidgets('no ⋯ when there is nothing server-wide to open', (
      tester,
    ) async {
      await _pump(tester, populatedServer());
      expect(find.byTooltip('Más opciones'), findsNothing);
    });

    testWidgets('a hub page has neither ⋯ nor «+»', (tester) async {
      await _pump(
        tester,
        populatedServer(),
        segment: CapabilitiesSegment.catalog,
        withServer: true,
      );
      expect(find.byTooltip('Más opciones'), findsNothing);
      expect(find.byKey(const ValueKey('exu-add')), findsNothing);
    });
  });

  group('large text, nine languages', () {
    for (final locale in Strings.supportedLocales) {
      testWidgets('2x in ${locale.languageCode}: three tabs and «+» fit', (
        tester,
      ) async {
        await _pump(
          tester,
          populatedServer(),
          locale: locale,
          textScale: 2,
          withServer: true,
          withInstaller: true,
          withLearn: true,
        );
        for (final tab in ExtensionsTab.values) {
          await _tab(tester, tab);
          expect(tester.takeException(), isNull, reason: tab.name);
          await _add(tester);
          expect(tester.takeException(), isNull, reason: '${tab.name} menu');
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('accessibility', () {
    testWidgets('the tabs, the «+» and every switch are named', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, populatedServer(), withServer: true);
      expect(find.bySemanticsLabel('Secciones'), findsWidgets);
      expect(find.byTooltip('Añadir o explorar'), findsOneWidget);
      expect(find.byTooltip('Más opciones'), findsOneWidget);
      final named = find.bySemanticsLabel(RegExp('Activar arxiv'));
      expect(named, findsOneWidget);
      final data = tester.getSemantics(named).getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.hasToggledState), isTrue);
      // 48 dp targets for the controls that are tapped.
      for (final key in const ['exu-add']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      handle.dispose();
    });
  });

  group('spacing', () {
    for (final (width, variant) in [
      for (final width in const [360.0, 840.0])
        for (final variant in const [
          ('1x text, dark', 1.0, 'dark'),
          ('2x text, dark', 2.0, 'dark'),
          ('1x text, light', 1.0, 'console-light'),
          ('2x text, light', 2.0, 'console-light'),
        ])
          (width, variant),
    ]) {
      testWidgets('${width.toInt()} dp, 2x pixels, ${variant.$1}: first '
          'block below the header, siblings apart, no overlap', (tester) async {
        await _pump(
          tester,
          populatedServer(),
          size: Size(width, 900),
          textScale: variant.$2,
          theme: variant.$3,
        );
        for (final tab in ExtensionsTab.values) {
          await _tab(tester, tab);
          final header = tester.getRect(find.byType(HermesAppBar));
          final tabs = tester.getRect(
            find.byType(HermesSegmentedControl<ExtensionsTab>),
          );
          // Below the header the shared scaffold draws, never under or flush.
          expect(tabs.top, greaterThanOrEqualTo(header.bottom), reason: '$tab');
          final search = tester.getRect(
            find.byKey(const ValueKey('cph-search')),
          );
          final summary = tester.getRect(
            find.byKey(const ValueKey('spp-installed-summary')),
          );
          final status = tester.getRect(
            find.byKey(const ValueKey('spp-status-all')),
          );
          final list = tester.getRect(find.byType(CapabilityPlainList));
          final blocks = [tabs, search, summary, status, list];
          for (var i = 0; i < blocks.length - 1; i++) {
            expect(
              blocks[i + 1].top,
              greaterThanOrEqualTo(blocks[i].bottom - 0.5),
              reason: '$tab block $i overlaps the next',
            );
          }
          expect(
            search.top - tabs.bottom,
            greaterThanOrEqualTo(HermesSpace.x3 - 0.5),
            reason: '$tab tabs to search',
          );
          expect(
            list.top - status.bottom,
            greaterThanOrEqualTo(HermesSpace.x3 - 0.5),
            reason: '$tab filter to list',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('what the server wrote is never shown raw', () {
    testWidgets('a plugin row hides host paths and tokens, and a path is '
        'never an origin', (tester) async {
      final rest = populatedServer()
        ..gets['dashboard/plugins/catalog'] = {
          'entries': [
            {
              'name': 'weather',
              'title': 'Weather',
              'description':
                  'Notes kept in /private/host/plugins with sk-supersecret123',
              'tier': 'community',
              'version': '1.2.0',
              'installed': true,
              'runtime_status': 'enabled',
            },
          ],
        }
        ..gets['dashboard/plugins/hub'] = {
          'plugins': [
            {
              'name': 'weather',
              'runtime_status': 'enabled',
              'source': '/home/alice/.hermes/plugins/weather',
              'can_remove': true,
            },
          ],
        };
      await _pump(tester, rest, tab: ExtensionsTab.plugins);
      expect(find.text('Weather'), findsOneWidget);
      expect(find.textContaining('/private/host'), findsNothing);
      expect(find.textContaining('sk-supersecret'), findsNothing);
      expect(find.textContaining('/home/alice'), findsNothing);
      expect(find.textContaining('{"'), findsNothing);
    });

    testWidgets('an MCP row hides credentials in the address', (tester) async {
      final rest = populatedServer()
        ..gets['mcp/servers'] = {
          'servers': [
            {
              'name': 'remote-docs',
              'transport': 'http',
              'url': 'https://u:pw-fake@mcp.example.com/sse?api_key=fake-key-1',
              'enabled': true,
            },
          ],
        };
      await _pump(tester, rest, tab: ExtensionsTab.mcp);
      expect(find.text('remote-docs'), findsOneWidget);
      expect(find.textContaining('pw-fake'), findsNothing);
      expect(find.textContaining('fake-key-1'), findsNothing);
    });
  });
}
