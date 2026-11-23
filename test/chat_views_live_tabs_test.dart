// Review A18: the «Vistas» menu floats in its own route. A panel that stops
// being available while it is open (SSH removed, a profile switched) must
// stop being offered there too.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets('the open menu follows the panels the chat can open', (
    tester,
  ) async {
    final controller = ChatWorkspaceController();
    addTearDown(controller.dispose);
    final tabs = ValueNotifier<List<ChatWorkspaceTab>>(const [
      ChatWorkspaceTab.terminal,
    ]);
    addTearDown(tabs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: ValueListenableBuilder<List<ChatWorkspaceTab>>(
              valueListenable: tabs,
              builder: (context, available, _) => ChatViewsButton(
                key: const ValueKey('test-views'),
                controller: controller,
                availableTabs: available,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-views')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('chat-workspace-views')), findsOneWidget);

    final strings = Strings.of(
      tester.element(find.byKey(const ValueKey('chat-views-layout'))),
    );
    final work = find.byKey(
      ValueKey('chat-views-layout-${ChatWorkspaceMode.workspace.name}'),
    );
    bool offered() => tester
        .getSemantics(work)
        .getSemanticsData()
        .hasAction(SemanticsAction.tap);
    final semantics = tester.ensureSemantics();
    expect(offered(), isTrue);
    expect(find.text(strings.cwsViewsHintNoPanel), findsNothing);

    // The only panel goes away while the menu is up.
    tabs.value = const [];
    await tester.pump();
    await tester.pump();
    expect(offered(), isFalse, reason: 'nothing left to open');
    expect(find.text(strings.cwsViewsHintNoPanel), findsOneWidget);

    // And comes back.
    tabs.value = const [ChatWorkspaceTab.files];
    await tester.pump();
    await tester.pump();
    expect(offered(), isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
