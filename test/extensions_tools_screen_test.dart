import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesSpace;
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/extensions_tools_screen.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class _ToolsGateway implements HermesDesktopControlGateway {
  ExtensionsInventory inventory = const ExtensionsInventory(
    plugins: [],
    toolsets: [],
  );
  Object? loadFailure;
  int loadCalls = 0;
  final List<(String, bool, String)> toolsetChanges = [];
  final List<(String, bool)> reloads = [];

  @override
  Future<ExtensionsInventory> extensionsInventory({
    String runtimeSessionId = '',
  }) async {
    loadCalls++;
    if (loadFailure case final failure?) throw failure;
    return inventory;
  }

  @override
  Future<void> setToolsetEnabled(
    String name,
    bool enabled, {
    String runtimeSessionId = '',
  }) async {
    toolsetChanges.add((name, enabled, runtimeSessionId));
  }

  @override
  Future<void> reloadMcp({
    String runtimeSessionId = '',
    required bool confirmed,
  }) async {
    reloads.add((runtimeSessionId, confirmed));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget home, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

ExtensionsInventory _inventory() => const ExtensionsInventory(
  plugins: [],
  toolsets: [
    DesktopToolsetEntry(
      name: 'web',
      description:
          'Herramientas web en /private/host/web con sk-supersecret123',
      toolCount: 2,
      enabled: false,
      tools: ['search', 'fetch'],
    ),
    DesktopToolsetEntry(
      name: 'files',
      description: 'Archivos',
      toolCount: 3,
      enabled: true,
      tools: ['read', 'write', 'list'],
    ),
  ],
);

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('lists the tool groups without paths, secrets or raw JSON', (
    tester,
  ) async {
    await _phone(tester);
    final gateway = _ToolsGateway()..inventory = _inventory();
    await tester.pumpWidget(
      _app(
        ExtensionsToolsScreen(gateway: gateway, runtimeSessionId: 'runtime-a'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Grupos de herramientas'), findsWidgets);
    expect(find.text('web'), findsOneWidget);
    expect(find.text('files'), findsOneWidget);
    expect(find.text('2 instalados · 1 activos'), findsOneWidget);
    expect(find.textContaining('/private/host'), findsNothing);
    expect(find.textContaining('sk-supersecret'), findsNothing);
    expect(find.textContaining('{"'), findsNothing);
  });

  testWidgets(
    'MCP descriptions and inventory names stay out of groups and totals',
    (tester) async {
      await _phone(tester);
      final gateway = _ToolsGateway()
        ..inventory = ExtensionsInventory.fromJson(
          plugins: const {'plugins': <Object>[]},
          toolsets: {
            'toolsets': [
              for (final name in ['browser', 'clarify', 'terminal'])
                {'name': name, 'description': 'Built in', 'tool_count': 1},
              {
                'name': 'blender',
                'description': "MCP server 'blender' tools",
                'tool_count': 30,
              },
              {
                'name': 'mcp-cloudflare',
                'description': "MCP server 'cloudflare' tools",
                'tool_count': 6,
              },
              // Older servers can omit the identifying description.
              {'name': 'inventory-only', 'description': 'External tools'},
            ],
          },
          mcp: const {
            'servers': [
              {'name': 'inventory-only'},
            ],
          },
        );
      await tester.pumpWidget(_app(ExtensionsToolsScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      expect(find.text('Grupos de herramientas'), findsWidgets);
      expect(
        find.text('Funciones integradas de Hermes que el agente puede usar'),
        findsOneWidget,
      );
      expect(find.text('3 instalados · 3 activos'), findsOneWidget);
      for (final name in ['browser', 'clarify', 'terminal']) {
        expect(find.text(name), findsOneWidget);
        expect(find.byKey(ValueKey('toolset-toggle-$name')), findsOneWidget);
      }
      for (final name in ['blender', 'mcp-cloudflare', 'inventory-only']) {
        expect(find.text(name), findsNothing);
        expect(find.byKey(ValueKey('toolset-toggle-$name')), findsNothing);
      }
      await tester.enterText(
        find.byKey(const ValueKey('extensions-search-tools')),
        'blender',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('toolset-toggle-blender')),
        findsNothing,
      );
      expect(find.text('No hay resultados con estos filtros.'), findsOneWidget);
      expect(find.text('3 instalados · 3 activos'), findsOneWidget);
      expect(gateway.toolsetChanges, isEmpty);
    },
  );

  testWidgets('an MCP-only inventory shows the built-in empty state', (
    tester,
  ) async {
    await _phone(tester);
    final gateway = _ToolsGateway()
      ..inventory = ExtensionsInventory.fromJson(
        plugins: const {'plugins': <Object>[]},
        toolsets: const {
          'toolsets': [
            {'name': 'blender', 'description': "MCP server 'blender' tools"},
          ],
        },
      );
    await tester.pumpWidget(_app(ExtensionsToolsScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('No hay grupos integrados disponibles'), findsOneWidget);
    expect(
      find.text(
        'Los servidores MCP y sus herramientas se gestionan en la pestaña MCP de Extensiones.',
      ),
      findsOneWidget,
    );
    expect(find.text('0 instalados · 0 activos'), findsOneWidget);
    expect(find.text('blender'), findsNothing);
    expect(find.text('No hay resultados'), findsNothing);
  });

  testWidgets('shows active groups first and filters and searches them', (
    tester,
  ) async {
    await _phone(tester);
    final gateway = _ToolsGateway()..inventory = _inventory();
    await tester.pumpWidget(_app(ExtensionsToolsScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('files')).dy,
      lessThan(tester.getTopLeft(find.text('web')).dy),
    );
    await tester.tap(find.byKey(const ValueKey('extensions-status-active')));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsNothing);
    expect(find.text('files'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('extensions-status-inactive')));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('files'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('extensions-status-all')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('extensions-search-tools')),
      'fetch',
    );
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('files'), findsNothing);
  });

  testWidgets('a tool group toggle asks first and then reads again', (
    tester,
  ) async {
    await _phone(tester);
    final gateway = _ToolsGateway()..inventory = _inventory();
    await tester.pumpWidget(
      _app(
        ExtensionsToolsScreen(gateway: gateway, runtimeSessionId: 'runtime-a'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('toolset-toggle-web')));
    await tester.pumpAndSettle();
    expect(gateway.toolsetChanges, isEmpty);
    await tester.tap(find.text('Confirmar cambio'));
    await tester.pumpAndSettle();
    expect(gateway.toolsetChanges, [('web', true, 'runtime-a')]);
    expect(gateway.loadCalls, 2);
  });

  testWidgets('the scope note appears only outside a conversation', (
    tester,
  ) async {
    await _phone(tester);
    final gateway = _ToolsGateway()..inventory = _inventory();
    await tester.pumpWidget(_app(ExtensionsToolsScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('extensions-tools-scope')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _app(
        ExtensionsToolsScreen(gateway: gateway, runtimeSessionId: 'runtime-a'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('extensions-tools-scope')), findsNothing);
  });

  testWidgets('MCP reload requires explicit confirmation=true', (tester) async {
    await _phone(tester);
    final gateway = _ToolsGateway()..inventory = _inventory();
    await tester.pumpWidget(
      _app(
        ExtensionsToolsScreen(gateway: gateway, runtimeSessionId: 'runtime-a'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('extensions-reload-mcp')),
    );
    await tester.tap(find.text('Recargar MCP'));
    await tester.pumpAndSettle();
    expect(gateway.reloads, isEmpty);
    await tester.tap(find.text('Recargar ahora'));
    await tester.pumpAndSettle();

    expect(gateway.reloads, [('runtime-a', true)]);
    expect(gateway.loadCalls, 2);
  });

  testWidgets('read-only disables every mutating control and sends zero RPCs', (
    tester,
  ) async {
    await _phone(tester);
    final gateway = _ToolsGateway()..inventory = _inventory();
    await tester.pumpWidget(
      _app(
        ExtensionsToolsScreen(
          gateway: gateway,
          runtimeSessionId: 'runtime-a',
          readOnly: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('solo lectura'), findsWidgets);
    final toolSwitch = tester.widget<Switch>(
      find.byKey(const ValueKey('toolset-toggle-web')),
    );
    expect(toolSwitch.onChanged, isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('extensions-reload-mcp')),
    );
    final reload = tester.widget<HermesListRow>(
      find.byKey(const ValueKey('extensions-reload-mcp')),
    );
    expect(reload.enabled, isFalse);
    expect(reload.onTap, isNull);
    expect(gateway.toolsetChanges, isEmpty);
    expect(gateway.reloads, isEmpty);
  });

  testWidgets('unsupported inventory is explicit instead of an empty claim', (
    tester,
  ) async {
    await _phone(tester);
    final gateway = _ToolsGateway()
      ..loadFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      );
    await tester.pumpWidget(_app(ExtensionsToolsScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(
      find.text('Esta versión de Hermes no publica plugins ni herramientas.'),
      findsOneWidget,
    );
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('says that no tool groups are published, in English', (
    tester,
  ) async {
    await _phone(tester);
    await tester.pumpWidget(
      _app(
        ExtensionsToolsScreen(gateway: _ToolsGateway()),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tool groups'), findsWidgets);
    expect(find.text('No built-in tool groups available'), findsOneWidget);
  });

  for (final locale in Strings.supportedLocales) {
    testWidgets('2x text in ${locale.languageCode}: aligned, no overflow', (
      tester,
    ) async {
      await _phone(tester);
      final gateway = _ToolsGateway()..inventory = _inventory();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: _app(ExtensionsToolsScreen(gateway: gateway), locale: locale),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('toolset-toggle-web')),
        120,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('extensions-tools-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('toolset-toggle-web'))).right,
        tester
            .getRect(find.byKey(const ValueKey('toolset-toggle-files')))
            .right,
      );
    });
  }

  for (final (width, variant) in [
    for (final width in const [360.0, 840.0])
      for (final variant in const [
        ('1x text, dark', 1.0, 'dark'),
        ('2x text, light', 2.0, 'console-light'),
      ])
        (width, variant),
  ]) {
    testWidgets('spacing at ${width.toInt()} dp, 2x pixels, ${variant.$1}: '
        'first block below the header, sibling sections apart', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(width * 2, 2400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final gateway = _ToolsGateway()..inventory = _inventory();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: Size(width, 1200),
            textScaler: TextScaler.linear(variant.$2),
          ),
          child: MaterialApp(
            locale: const Locale('es'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId(variant.$3),
            home: ExtensionsToolsScreen(gateway: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final header = tester.getRect(find.byType(HermesAppBar));
      final scope = tester.getRect(
        find.byKey(const ValueKey('extensions-tools-scope')),
      );
      expect(scope.top, greaterThanOrEqualTo(header.bottom));
      final first = tester.getRect(find.byType(HermesListSection).first);
      final search = tester.getRect(
        find.byKey(const ValueKey('extensions-search-tools')),
      );
      expect(search.top, greaterThanOrEqualTo(scope.bottom));
      expect(first.top, greaterThanOrEqualTo(search.bottom));
      // The new subtitle can push the runtime section outside the lazy list's
      // cache at 2x. Scroll it into view and compare content coordinates.
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('extensions-tools-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final firstBottom = first.bottom + position.pixels;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('extensions-reload-mcp')),
        120,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byType(HermesListSection), findsNWidgets(2));
      final second = tester.getRect(find.byType(HermesListSection).last);
      expect(
        second.top + position.pixels - firstBottom,
        greaterThanOrEqualTo(HermesSpace.x3 - 0.5),
        reason: 'sibling sections are a gap apart',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the switch is announced with the group name', (tester) async {
    await _phone(tester);
    final handle = tester.ensureSemantics();
    final gateway = _ToolsGateway()..inventory = _inventory();
    await tester.pumpWidget(_app(ExtensionsToolsScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Activar web'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('toolset-toggle-web'))).height,
      greaterThanOrEqualTo(40),
    );
    handle.dispose();
  });
}
