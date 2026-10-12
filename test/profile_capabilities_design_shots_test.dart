import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/screens/bot_profile_settings_screen.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';
import 'support/profile_capability_fakes.dart';
import 'support/profile_model_fakes.dart' show pumpModelUi;

const _shotKey = ValueKey('profile-capabilities-design-shot');

Future<void> _pump(WidgetTester tester, Widget home, ThemeData theme) async {
  await loadDesignFonts();
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await pumpModelUi(tester);
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('build/design_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
  expect(tester.takeException(), isNull);
}

Future<void> _open(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await pumpModelUi(tester);
}

void main() {
  for (final (mode, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('new profile and capability menus at 390x844 · $mode', (
      tester,
    ) async {
      final gateway = FakeProfileCapabilityGateway();
      await _pump(
        tester,
        BotCreateScreen(
          connection: capabilityConnection(),
          existing: const {'default'},
          gateway: gateway,
          modelOptionsLoader: (_) async => const [],
        ),
        theme,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.drag(
        find.byKey(const ValueKey('bot-create-form')),
        const Offset(0, -140),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _shot(tester, 'profile_create_$mode');
      for (final (field, prefix) in [
        ('skills', 'skill'),
        ('toolsets', 'toolsets'),
        ('mcp_servers', 'mcp_servers'),
      ]) {
        await _open(tester, 'bot-create-$field-row');
        expect(
          find.byKey(ValueKey('bot-create-$prefix-picker')),
          findsOneWidget,
        );
        await _shot(tester, 'profile_create_${field}_$mode');
        await tester.tap(find.byTooltip('Cerrar'));
        await pumpModelUi(tester);
      }
      await _open(tester, 'bot-create-identity-row');
      final palette = find.byKey(const ValueKey('bot-face-color-palette'));
      await Scrollable.ensureVisible(tester.element(palette), alignment: 1);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bot-face-color-#ef4444')));
      await tester.pump();
      await _shot(tester, 'profile_create_faces_$mode');
    });

    testWidgets('edit profile uses the same rows and menu · $mode', (
      tester,
    ) async {
      await _pump(
        tester,
        BotProfileSettingsScreen(
          profile: 'inbox-triage',
          gateway: FakeProfileCapabilityGateway(),
        ),
        theme,
      );
      await _shot(tester, 'profile_edit_capabilities_$mode');
      await _open(tester, 'bot-settings-toolsets-row');
      await _shot(tester, 'profile_edit_tools_$mode');
    });

    testWidgets(
      'edit restores the face colour and shares the palette · $mode',
      (tester) async {
        final gateway = FakeProfileCapabilityGateway();
        await _pump(
          tester,
          ProfileEditorScreen(
            connection: capabilityConnection(),
            profile: const AgentProfile(
              name: 'inbox-triage',
              botModeUiMeta: {
                'shape': 'blobatar::cloud',
                'color': '#ef4444',
                'useShapeColor': true,
                'imageKind': 'shape',
              },
            ),
            gateway: gateway,
            petService: ProfilePetService(gateway),
          ),
          theme,
        );
        await _open(tester, 'profile-editor-identity-row');
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const ValueKey('bot-face-color-palette'))),
          alignment: 1,
        );
        await _shot(tester, 'profile_edit_faces_$mode');
      },
    );
  }
}
