// The Files panel's text editor used to close without a word when what the
// tab shows changed underneath (the agent moved to another folder, the
// session got a new id): the tab's routes were replaced and the edits lost.
// A screen holding unsaved work now keeps the routes until it lets go.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class _Editor extends StatefulWidget {
  const _Editor();

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  VoidCallback? _release;

  void hold() => _release = ChatWorkspacePaneScope.holdUnsaved(context);

  void release() {
    _release?.call();
    _release = null;
  }

  @override
  void dispose() {
    release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Material(child: Center(child: Text('editor')));
}

void main() {
  Future<({ChatWorkspaceController controller, ValueNotifier<String> folder})>
  pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ChatWorkspaceController();
    addTearDown(controller.dispose);
    final folder = ValueNotifier('/srv/a');
    addTearDown(folder.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: ValueListenableBuilder<String>(
          valueListenable: folder,
          builder: (context, path, _) => ChatWorkspaceHost(
            controller: controller,
            chat: const Material(child: Text('chat')),
            availableTabs: const [ChatWorkspaceTab.files],
            tabRouteScope: (tab) => path,
            tabBuilder: (context, tab) => Material(
              child: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const _Editor()),
                  ),
                  child: Text('files of $path'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    controller.open(ChatWorkspaceTab.files);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('files of /srv/a'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('editor'), findsOneWidget);
    return (controller: controller, folder: folder);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('an editor with nothing unsaved goes with the folder', (
    tester,
  ) async {
    final rig = await pump(tester);
    rig.folder.value = '/srv/b';
    await settle(tester);
    expect(find.text('editor'), findsNothing);
    expect(find.text('files of /srv/b'), findsOneWidget);
  });

  testWidgets('an editor with unsaved work stays when the folder changes, '
      'and the panel follows once it lets go', (tester) async {
    final rig = await pump(tester);
    final editor = tester.state<_EditorState>(find.byType(_Editor))..hold();

    rig.folder.value = '/srv/b';
    await settle(tester);
    expect(find.text('editor'), findsOneWidget, reason: 'nothing was lost');
    expect(identical(tester.state(find.byType(_Editor)), editor), isTrue);

    // Saved (or discarded by the user's own choice): the hold goes.
    editor.release();
    await settle(tester);
    expect(find.text('editor'), findsNothing);
    expect(find.text('files of /srv/b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an editor that closes while holding releases the panel', (
    tester,
  ) async {
    final rig = await pump(tester);
    tester.state<_EditorState>(find.byType(_Editor)).hold();
    rig.folder.value = '/srv/b';
    await settle(tester);
    expect(find.text('editor'), findsOneWidget);

    Navigator.of(tester.element(find.byType(_Editor))).pop();
    await settle(tester);
    await settle(tester);
    expect(find.text('editor'), findsNothing);
    expect(find.text('files of /srv/b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
