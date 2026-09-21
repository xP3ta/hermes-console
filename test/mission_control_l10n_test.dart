import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/mission_control_copy.dart';
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

  testWidgets('Mission Control copy uses zh-Hant at runtime', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
        ),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    final copy = MissionControlCopy.of(tester.element(find.byType(SizedBox)));
    expect(copy.allAgents, '所有 Bot');
    expect(copy.chooseWorkspace, '選擇工作區');
    expect(copy.workspaces, '工作區');
    expect(copy.createRoom, '建立房間');
    expect(copy.openChat, '開啟聊天');
    expect(copy.roomMembers, '房間成員');
    expect(copy.sendSharedMessage, '傳送訊息');
  });

  testWidgets('zh-Hant Mission Control copy covers Bots, Rooms and Work', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
        ),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    final copy = MissionControlCopy.of(tester.element(find.byType(SizedBox)));

    // Bots: empty state, actions, search and error copy.
    expect(copy.noBots, 'Bot 是具名隊友，擁有自己的記憶、技能和聊天。建立第一個 Bot 開始使用。');
    expect(copy.searchAgents, '搜尋 Bot');
    expect(copy.clearSearch, '清除搜尋');
    expect(copy.botRosterUpdateFailed, 'Hermes 未能更新此 Bot。');
    expect(copy.hideBot, '從 Bots 隱藏');

    // Rooms: empty state, status, form labels and accessibility text.
    expect(copy.noRooms, '建立房間，開始與團隊交流。');
    expect(copy.roomActivity, '房間活動');
    expect(copy.roomNoActivity, '此房間尚未發佈任何活動。');
    expect(copy.roomName, '房間名稱');
    expect(copy.roomPurposeHint, '例如：保持生產環境穩定');
    expect(copy.sharedRoomSemantics('平台', 2), '共享房間 平台，2 位成員');

    // Work: empty state, actions and error/status copy.
    expect(copy.noTasks, '這裡目前沒有任務。');
    expect(copy.noActivity, 'Hermes 尚未為此範圍發佈最近活動。');
    expect(copy.noApprovals, '沒有需要處理的已觀察批准。');
    expect(copy.openKanban, '完整任務板');
    expect(copy.status('approvalRequired'), '需要批准');
    expect(copy.taskStatus('running'), '進行中');
  });

  testWidgets('zh-Hant room avatar labels preserve incomplete-team semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
        ),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    final strings = Strings.of(tester.element(find.byType(SizedBox)));
    expect(strings.missionRoomAvatarMembers(1), '1 位成員，不完整團隊');
    expect(strings.missionRoomAvatarMembers(2), '2 位成員，不完整團隊');
  });
}
