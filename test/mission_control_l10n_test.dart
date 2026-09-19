import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/room_avatar_stack.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  for (final entry in const {
    'en': [
      'Work',
      'Create',
      'New bot',
      'New room',
      '1 member, incomplete team',
    ],
    'es': [
      'Trabajo',
      'Crear',
      'Nuevo bot',
      'Nueva sala',
      '1 miembro, equipo incompleto',
    ],
  }.entries) {
    testWidgets(
      'Mission Control generated localization is used for ${entry.key}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(entry.key),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId('dark'),
            home: Scaffold(
              body: Stack(
                children: [
                  const RoomAvatarStack(
                    connectionId: 'public-owner',
                    profiles: [],
                  ),
                  // Las etiquetas de las órbitas salen de las cadenas
                  // generadas, igual que en Mission Control: eso es
                  // justamente lo que este test comprueba.
                  Builder(
                    builder: (context) => Dock(
                      profileId: DockProfileId.bots,
                      actions: const {
                        DockItemId.home: DockItemAction(),
                        DockItemId.bots: DockItemAction(
                          selected: true,
                          semanticsKey: ValueKey('mission-destination-bots'),
                        ),
                        DockItemId.work: DockItemAction(
                          semanticsKey: ValueKey('mission-destination-work'),
                        ),
                        DockItemId.create: DockItemAction(),
                      },
                      createOrbits: [
                        DockCreateOrbit(
                          controlKey: const ValueKey('bot-mode-create-bot'),
                          label: Strings.of(context).missionCreateBotLabel,
                          icon: Icons.smart_toy_outlined,
                          onTap: () {},
                        ),
                        DockCreateOrbit(
                          controlKey: const ValueKey('bot-mode-create-room'),
                          label: Strings.of(context).missionCreateRoomLabel,
                          icon: Icons.groups_2_outlined,
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // El dock real pinta solo iconos (ver dock.dart): la
        // etiqueta ya no es un Text visible en la barra, así que la
        // localización se comprueba por el `label` semántico publicado.
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('mission-destination-work')),
              )
              .label,
          entry.value[0],
        );
        final create = find.byKey(const ValueKey('bot-mode-dock-create'));
        expect(tester.getSemantics(create).label, entry.value[1]);
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('bot-mode-create-bot')))
              .label,
          entry.value[2],
        );
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('bot-mode-create-room')))
              .label,
          entry.value[3],
        );
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('room-avatar-stack')))
              .label,
          entry.key == 'en' ? '0 members' : '0 miembros',
        );
        expect(
          Strings.of(tester.element(create)).roomAvatarMembers(1),
          entry.value[4],
        );
      },
    );
  }
}
