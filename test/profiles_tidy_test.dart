// Perfiles: a profile's model is a picker in its editor, "Nuevo perfil" is
// an action of the top bar, and each row ends in one menu.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_model_picker.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/list.dart' show HermesListRow;
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';

import 'support/bot_roster_fakes.dart';
import 'support/profile_model_fakes.dart';

Future<void> _pumpEditor(
  WidgetTester tester,
  FakeIdentityGateway gateway, {
  VoidCallback? onChanged,
}) async {
  phoneView(tester);
  await tester.pumpWidget(
    modelApp(
      ProfileEditorScreen(
        connection: connection,
        profile: modelBot,
        gateway: gateway,
        petService: ProfilePetService(gateway),
        modelCatalogs: ProfileModelCatalogs(),
        onChanged: onChanged,
      ),
    ),
  );
  await pumpModelUi(tester);
}

Future<void> _pumpProfiles(
  WidgetTester tester,
  List<AgentProfile> profiles, {
  double width = 420,
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    modelApp(
      ProfilesScreen(
        connection: connection,
        connManager: await manager(),
        rosterRegistry: BotRosterRegistry(),
        clientOverride: FakeProfilesServer().client,
        gatewayProfilesOverride: () async => profiles,
      ),
    ),
  );
  await pumpModelUi(tester);
}

void main() {
  group('the profile editor, its model', () {
    const row = ValueKey('profile-editor-model-row');

    testWidgets('is a picker of what that profile can use; the choice is '
        'saved', (tester) async {
      var changed = 0;
      final gateway = FakeModelGateway();
      await _pumpEditor(tester, gateway, onChanged: () => changed++);
      await tester.ensureVisible(find.byKey(row));
      await tester.pump();
      await tester.tap(find.byKey(row));
      await pumpModelUi(tester);
      expect(
        find.byKey(const ValueKey('profile-editor-model-picker')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-editor-model-openai-gpt-5.5-mini')),
      );
      await pumpModelUi(tester);

      expect(gateway.catalogReads, ['builder']);
      expect(gateway.configures.single.$1, 'builder');
      expect(gateway.configures.single.$2, {
        'model': 'gpt-5.5-mini',
        'provider': 'openai',
      });
      expect(
        find.descendant(
          of: find.byKey(row),
          matching: find.text('gpt-5.5-mini'),
        ),
        findsOneWidget,
      );
      expect(changed, 1);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a model the server wants acknowledged is asked once', (
      tester,
    ) async {
      final gateway = FakeModelGateway()..confirmFirst = true;
      await _pumpEditor(tester, gateway);
      await tester.ensureVisible(find.byKey(row));
      await tester.pump();
      await tester.tap(find.byKey(row));
      await pumpModelUi(tester);
      await tester.tap(
        find.byKey(const ValueKey('profile-editor-model-openai-gpt-5.5-mini')),
      );
      await pumpModelUi(tester);
      expect(find.text('Es de pago'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('profile-editor-model-confirm-save')),
      );
      await pumpModelUi(tester);

      expect(gateway.configures, hasLength(2));
      expect(gateway.configures.last.$2['confirm_expensive_model'], isTrue);
      await tester.pump(const Duration(seconds: 5));
    });

    for (final width in [320.0, 390.0, 412.0]) {
      testWidgets('its rows share their edges at ${width.toInt()} dp: labels '
          'start together, values and arrows end together', (tester) async {
        await _pumpEditor(tester, FakeModelGateway());
        tester.view.physicalSize = Size(width, 1800);
        await pumpModelUi(tester);
        await tester.ensureVisible(find.byKey(row));
        await tester.pump();
        final labels = {
          for (final label in [
            'Identidad visual',
            'Modelo',
            'Descripción',
            'Skills',
            'Configuración avanzada',
          ])
            tester.getTopLeft(find.text(label)).dx,
        };
        expect(labels, hasLength(1));
        Finder arrow(String key) => find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byIcon(Icons.chevron_right_rounded),
        );
        final ends = {
          tester.getTopRight(find.text('Sin descripción')).dx,
          tester.getTopRight(find.text('Ver skills')).dx,
          tester.getTopRight(arrow('profile-editor-model-row')).dx,
          tester.getTopRight(arrow('profile-editor-advanced-row')).dx,
          tester.getTopRight(arrow('profile-editor-identity-row')).dx,
        };
        expect(ends, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('on a server without model options the row only informs', (
      tester,
    ) async {
      await _pumpEditor(tester, FakeIdentityGateway());
      await tester.ensureVisible(find.byKey(row));
      await tester.pump();
      expect(tester.widget<HermesListRow>(find.byKey(row)).onTap, isNull);
      expect(
        find.descendant(of: find.byKey(row), matching: find.text('gpt-5.5')),
        findsOneWidget,
      );
    });
  });

  group('Perfiles', () {
    // The dock the app has.
    setUp(() {
      FeatureFlags.instance.resetToDefaultForTesting();
      GestureDockController.instance.resetForTesting();
    });
    tearDown(() {
      FeatureFlags.instance.resetForTesting();
      GestureDockController.instance.resetForTesting();
    });

    const profiles = [
      AgentProfile(name: 'default', isDefault: true, skillCount: 3),
      AgentProfile(name: 'ops', model: 'gpt-5.5', provider: 'openai'),
      AgentProfile(name: 'investigador-de-mercados-y-competencia-global'),
    ];

    testWidgets('«Nuevo perfil» is an action of the top bar; nothing at the '
        'bottom', (tester) async {
      await _pumpProfiles(tester, profiles);
      final action = find.descendant(
        of: find.byType(HermesAppBar),
        matching: find.byKey(const ValueKey('profiles-new')),
      );
      expect(action, findsOneWidget);
      final button = tester.widget<IconButton>(action);
      expect(button.tooltip, 'Nuevo perfil');
      expect(button.onPressed, isNotNull);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('a row ends in one menu: identity, rename and delete; the '
        'default profile has no delete', (tester) async {
      await _pumpProfiles(tester, profiles);
      await tester.tap(find.byKey(const ValueKey('profile-more-ops')));
      await pumpModelUi(tester);
      for (final key in ['profile-edit-bot', 'profile-rename']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('profile-delete')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await pumpModelUi(tester);

      await tester.tap(find.byKey(const ValueKey('profile-more-default')));
      await pumpModelUi(tester);
      expect(find.byKey(const ValueKey('profile-rename')), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-delete')), findsNothing);
    });

    for (final width in [320.0, 390.0, 412.0]) {
      testWidgets('names stay on one line and rows share their edges at '
          '${width.toInt()} dp', (tester) async {
        await _pumpProfiles(tester, profiles, width: width);
        final short = tester.getSize(find.text('ops'));
        final long = find.text('investigador-de-mercados-y-competencia-global');
        expect(tester.widget<Text>(long).maxLines, 1);
        expect(tester.getSize(long).height, short.height);
        // Every name starts at the same x and every menu ends at the same
        // one.
        final lefts = {
          for (final p in profiles) tester.getTopLeft(find.text(p.name)).dx,
        };
        final rights = {
          for (final p in profiles)
            tester
                .getTopRight(find.byKey(ValueKey('profile-more-${p.name}')))
                .dx,
        };
        expect(lefts, hasLength(1));
        expect(rights, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
