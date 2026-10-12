import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/list.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/screens/bot_profile_settings_screen.dart';
import 'package:hermes_android/core/widgets/bot_capabilities.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

import 'support/profile_capability_fakes.dart';
import 'support/profile_model_fakes.dart';

Widget _create(FakeProfileCapabilityGateway gateway) => BotCreateScreen(
  connection: capabilityConnection(),
  existing: const {'default'},
  gateway: gateway,
  modelOptionsLoader: (_) async => const [],
);

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(modelApp(screen));
  await pumpModelUi(tester);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('bot-create-form')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await pumpModelUi(tester);
}

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Cerrar'));
  await pumpModelUi(tester);
}

HermesListRow _row(WidgetTester tester, String key) =>
    tester.widget<HermesListRow>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(HermesListRow),
      ),
    );

void main() {
  testWidgets(
    'create: capabilities share rows and floating switch editors; writes stay the same',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(tester, _create(gateway));
      expect(gateway.skillReads, 0); // No added work on the first frame.
      expect(gateway.capabilityReads, 1);
      await _tap(tester, 'bot-create-skills-row');
      expect(
        find.byKey(const ValueKey('bot-create-skill-picker')),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(HermesSwitchTile), findsNWidgets(3));
      expect(find.text('TRABAJO'), findsOneWidget);
      expect(find.text('Descripción de la skill 0'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bot-create-skill-search')),
        findsNothing,
      );
      await _tap(tester, 'bot-create-skill-skill-0');
      await _close(tester);
      expect(_row(tester, 'bot-create-skills-row').value, '1 de 3');

      await _tap(tester, 'bot-create-toolsets-row');
      expect(
        find.byKey(const ValueKey('bot-create-toolsets-picker')),
        findsOneWidget,
      );
      expect(find.byType(HermesSwitchTile), findsNWidgets(3));
      final switchRow = tester.widget<HermesSwitchTile>(
        find.byKey(const ValueKey('bot-create-toolsets-terminal')),
      );
      expect(switchRow.subtitle, 'Ejecutar comandos');
      expect(switchRow.subtitleMaxLines, 1);
      await _tap(tester, 'bot-create-toolsets-terminal');
      await _close(tester);
      expect(_row(tester, 'bot-create-toolsets-row').value, '3 de 3');

      await _tap(tester, 'bot-create-mcp_servers-row');
      expect(
        find.byKey(const ValueKey('bot-create-mcp_servers-picker')),
        findsOneWidget,
      );
      expect(find.text('Conectado'), findsOneWidget);
      await _tap(tester, 'bot-create-mcp_servers-calendar');
      await _close(tester);
      expect(_row(tester, 'bot-create-mcp_servers-row').value, 'Ninguno');

      await tester.ensureVisible(find.byKey(const ValueKey('bot-create-name')));
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('bot-create-name')),
          matching: find.byType(TextField),
        ),
        'inbox',
      );
      await tester.pump();
      expect(find.text('Configuración sin crear'), findsNothing);
      expect(find.text('Escribe el nombre para crear el perfil'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bot-create-submit')));
      await pumpModelUi(tester);
      expect(gateway.disabledSkillWrites, hasLength(1));
      expect(gateway.disabledSkillWrites.single.$1, 'inbox');
      expect(gateway.disabledSkillWrites.single.$2, ['skill-0', 'skill-1']);
      expect(gateway.configures, hasLength(1));
      expect(gateway.configures.single.$1, 'inbox');
      expect(gateway.configures.single.$2, {
        'enabled_toolsets': ['memory', 'terminal', 'web'],
        'enabled_mcp_servers': <String>[],
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edit: identical editors keep disabled-skills inversion and touched-only patches',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(
        tester,
        BotProfileSettingsScreen(profile: 'inbox', gateway: gateway),
      );
      expect(find.byType(BotCapabilitiesRow), findsNWidgets(3));
      expect(_row(tester, 'bot-settings-skills-row').value, '2 de 3');
      await _tap(tester, 'bot-settings-skills-row');
      await _tap(tester, 'bot-settings-skills-skill-1');
      await _close(tester);
      expect(_row(tester, 'bot-settings-skills-row').value, '3 de 3');
      await _tap(tester, 'bot-settings-toolsets-row');
      await _tap(tester, 'bot-settings-toolsets-web');
      await _close(tester);
      await _tap(tester, 'bot-settings-mcp_servers-row');
      await _tap(tester, 'bot-settings-mcp_servers-notes');
      await _close(tester);
      await tester.tap(find.byKey(const ValueKey('bot-settings-save')));
      await pumpModelUi(tester);
      expect(gateway.configures, hasLength(1));
      expect(gateway.configures.single.$1, 'inbox');
      expect(gateway.configures.single.$2, {
        'disabled_skills': <String>[],
        'enabled_toolsets': ['memory'],
        'enabled_mcp_servers': ['calendar', 'notes'],
      });
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('MCP empty state contains only the truthful message', (
    tester,
  ) async {
    final gateway = FakeProfileCapabilityGateway(
      snapshot: capabilitySnapshot(emptyMcp: true),
    );
    await _pump(tester, _create(gateway));
    await _tap(tester, 'bot-create-mcp_servers-row');
    final surface = find.byKey(const ValueKey('bot-create-mcp_servers-picker'));
    expect(find.text('No hay servidores MCP en este Hermes'), findsOneWidget);
    expect(
      find.descendant(of: surface, matching: find.byType(HermesSwitchTile)),
      findsNothing,
    );
    expect(
      find.descendant(of: surface, matching: find.byType(TextField)),
      findsNothing,
    );
    expect(
      find.descendant(of: surface, matching: find.byType(HermesPrimaryButton)),
      findsNothing,
    );
  });

  testWidgets(
    'search appears above 12 entries, filters descriptions, keeps hidden selections',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway(
        snapshot: capabilitySnapshot(skillCount: 13),
      );
      await _pump(tester, _create(gateway), width: 320, scale: 2);
      await _tap(tester, 'bot-create-skills-row');
      final search = find.descendant(
        of: find.byKey(const ValueKey('bot-create-skill-search')),
        matching: find.byType(TextField),
      );
      expect(search, findsOneWidget);
      await tester.enterText(search, 'Descripción de la skill 12');
      await tester.pump();
      expect(find.byType(HermesSwitchTile), findsOneWidget);
      final tile = find.byKey(const ValueKey('bot-create-skill-skill-12'));
      expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
      await tester.tap(tile);
      await tester.pump();
      await tester.enterText(search, 'no match');
      await tester.pump();
      expect(find.text('Sin resultados'), findsOneWidget);
      await _close(tester);
      expect(_row(tester, 'bot-create-skills-row').value, '11 de 13');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an empty tool selection describes inheritance and still sends an empty list',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(
        tester,
        BotProfileSettingsScreen(profile: 'inbox', gateway: gateway),
      );
      await _tap(tester, 'bot-settings-toolsets-row');
      await _tap(tester, 'bot-settings-toolsets-web');
      await _tap(tester, 'bot-settings-toolsets-memory');
      expect(
        find.text('Sin selección: usa las herramientas predeterminadas.'),
        findsOneWidget,
      );
      await _close(tester);
      expect(_row(tester, 'bot-settings-toolsets-row').value, 'Las incluidas');
      await tester.tap(find.byKey(const ValueKey('bot-settings-save')));
      await pumpModelUi(tester);
      expect(gateway.configures, hasLength(1));
      expect(gateway.configures.single.$1, 'inbox');
      expect(gateway.configures.single.$2, {'enabled_toolsets': <String>[]});
    },
  );

  testWidgets(
    'changing capabilities alone protects the create draft; the missing-name hint stays true',
    (tester) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(tester, _create(gateway));
      await _tap(tester, 'bot-create-toolsets-row');
      await _tap(tester, 'bot-create-toolsets-web');
      await _close(tester);
      expect(
        find.text('Escribe el nombre para crear el perfil'),
        findsOneWidget,
      );
      expect(find.text('Configuración sin crear'), findsNothing);
      expect(
        tester
            .widget<HermesPrimaryButton>(
              find.byKey(const ValueKey('bot-create-submit')),
            )
            .onTap,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await pumpModelUi(tester);
      expect(
        find.byKey(const ValueKey('bot-create-discard-dialog')),
        findsOneWidget,
      );
    },
  );
}
