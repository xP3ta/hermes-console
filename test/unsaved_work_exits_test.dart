// A chat can hold a file being edited in its Files panel. The editor asked
// before closing itself and stayed when the folder changed, but leaving the
// chat (Back, a new chat, another conversation, the drawer, the dock, a
// notification) removed its route and the text with it, without a word.
// Every way out now asks «Discard changes?» first.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/navigation/chat_route.dart';
import 'package:hermes_android/core/navigation/unsaved_work_guard.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show pushNotificationOwnerRoute;
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'unsaved-exits',
  label: 'Exits QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

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

Widget _app(Widget home, {GlobalKey<NavigatorState>? navigatorKey}) =>
    MaterialApp(
      navigatorKey: navigatorKey,
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

final _question = find.text('Discard changes?');

Future<void> _answer(WidgetTester tester, Key action) async {
  expect(_question, findsOneWidget);
  await tester.tap(find.byKey(action));
  await _settle(tester);
  expect(_question, findsNothing);
}

/// Unsaved work under [navigator], as the chat's Files editor registers it.
({List<String> log}) _holdOn(NavigatorState navigator) {
  final log = <String>[];
  final hold = UnsavedWorkGuard.hold(
    navigator,
    onDiscarded: () => log.add('discarded'),
  );
  addTearDown(hold.release);
  return (log: log);
}

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('the guard', () {
    testWidgets('with nothing unsaved a navigation runs at once, in the same '
        'call', (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_app(const Text('home'), navigatorKey: key));
      final navigator = key.currentState!;
      expect(UnsavedWorkGuard.affects(navigator), isFalse);

      var ran = 0;
      UnsavedWorkGuard.leave(navigator, () => ran++);
      expect(ran, 1, reason: 'synchronous: nothing changes for the app');

      var asked = 0;
      final result = UnsavedWorkGuard.leaveWith<int>(navigator, () async {
        asked++;
        return 7;
      });
      expect(asked, 1);
      expect(await result, 7);
      expect(await UnsavedWorkGuard.confirm(navigator), isTrue);
      await tester.pump();
      expect(_question, findsNothing);
    });

    testWidgets('unsaved work: staying runs nothing and keeps the work; '
        'discarding tells the editor and then navigates', (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_app(const Text('home'), navigatorKey: key));
      final navigator = key.currentState!;
      final held = _holdOn(navigator);
      expect(UnsavedWorkGuard.affects(navigator), isTrue);

      var ran = 0;
      UnsavedWorkGuard.leave(navigator, () => ran++);
      await _settle(tester);
      expect(ran, 0);
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(ran, 0);
      expect(held.log, isEmpty);
      expect(UnsavedWorkGuard.affects(navigator), isTrue);

      int? value;
      UnsavedWorkGuard.leaveWith<int>(
        navigator,
        () async => 7,
      ).then((v) => value = v);
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(value, isNull, reason: 'the user stayed');

      UnsavedWorkGuard.leave(navigator, () => ran++);
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.discardKey);
      expect(ran, 1);
      expect(held.log, ['discarded']);
      expect(UnsavedWorkGuard.affects(navigator), isFalse);
    });

    testWidgets('two navigations at the same moment ask once', (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_app(const Text('home'), navigatorKey: key));
      final navigator = key.currentState!;
      _holdOn(navigator);
      var ran = 0;
      UnsavedWorkGuard.leave(navigator, () => ran++);
      UnsavedWorkGuard.leave(navigator, () => ran++);
      await _settle(tester);
      expect(_question, findsOneWidget);
      await _answer(tester, UnsavedWorkGuard.discardKey);
      expect(ran, 2);
    });

    testWidgets('work in a pane counts for the navigator around it, not for '
        'a pane next to it', (tester) async {
      final root = GlobalKey<NavigatorState>();
      final paneA = GlobalKey<NavigatorState>();
      final paneB = GlobalKey<NavigatorState>();
      Navigator pane(GlobalKey<NavigatorState> key) => Navigator(
        key: key,
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const SizedBox()),
      );
      await tester.pumpWidget(
        _app(
          Row(
            children: [
              Expanded(child: pane(paneA)),
              Expanded(child: pane(paneB)),
            ],
          ),
          navigatorKey: root,
        ),
      );
      _holdOn(paneA.currentState!);
      expect(UnsavedWorkGuard.affects(paneA.currentState!), isTrue);
      expect(UnsavedWorkGuard.affects(root.currentState!), isTrue);
      expect(UnsavedWorkGuard.affects(paneB.currentState!), isFalse);
    });
  });

  group('Back on the chat', () {
    // Home, and above it a chat with its workspace: an editor open in Files.
    Future<
      ({
        ChatWorkspaceController controller,
        GlobalKey<ScaffoldState> chat,
        _EditorState editor,
      })
    >
    pump(WidgetTester tester, {Size? phone}) async {
      if (phone == null) {
        _wide(tester);
      } else {
        tester.view.physicalSize = phone;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
      }
      final controller = ChatWorkspaceController();
      addTearDown(controller.dispose);
      final chat = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatWorkspaceHost(
                        controller: controller,
                        chat: Scaffold(
                          key: chat,
                          appBar: AppBar(
                            leading: const BackButton(),
                            title: const Text('chat'),
                          ),
                          drawer: const Drawer(child: Text('menu')),
                          body: const SizedBox.expand(),
                        ),
                        availableTabs: const [
                          ChatWorkspaceTab.files,
                          ChatWorkspaceTab.terminal,
                        ],
                        tabBuilder: (context, tab) => Material(
                          child: Center(
                            child: tab != ChatWorkspaceTab.files
                                ? const Text('terminal')
                                : TextButton(
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => const _Editor(),
                                      ),
                                    ),
                                    child: const Text('open file'),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('home'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('home'));
      await _settle(tester);
      controller.open(ChatWorkspaceTab.files);
      if (phone != null) controller.setMode(ChatWorkspaceMode.workspace);
      await _settle(tester);
      await tester.tap(find.text('open file'));
      await _settle(tester);
      final editor = tester.state<_EditorState>(find.byType(_Editor));
      return (controller: controller, chat: chat, editor: editor);
    }

    testWidgets('nothing unsaved: Back leaves the chat as before', (
      tester,
    ) async {
      final rig = await pump(tester);
      rig.controller.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(_question, findsNothing);
      expect(find.text('chat'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('unsaved text in another tab: system Back asks; staying '
        'keeps the chat and the editor, discarding leaves', (tester) async {
      final rig = await pump(tester);
      rig.editor.hold();
      // Another tab on screen: Back is not the editor's own any more.
      rig.controller.open(ChatWorkspaceTab.terminal);
      await _settle(tester);

      await tester.binding.handlePopRoute();
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(find.text('chat'), findsOneWidget);
      expect(
        identical(
          tester.state(find.byType(_Editor, skipOffstage: false)),
          rig.editor,
        ),
        isTrue,
        reason: 'the editor and its text are still there',
      );

      await tester.binding.handlePopRoute();
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.discardKey);
      expect(find.text('chat'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // The case found on the phone: the editor open in Files, the user back
    // on the Chat view, then Back out of the chat.
    for (final phone in const [Size(412, 915), Size(360, 780)]) {
      testWidgets('${phone.width.toInt()}x${phone.height.toInt()}: on a '
          'phone, back on the Chat view, Back asks before leaving', (
        tester,
      ) async {
        final rig = await pump(tester, phone: phone);
        rig.editor.hold();
        rig.controller.setMode(ChatWorkspaceMode.chat);
        await _settle(tester);

        await tester.binding.handlePopRoute();
        await _settle(tester);
        await _answer(tester, UnsavedWorkGuard.keepKey);
        expect(find.text('chat'), findsOneWidget);
        expect(find.text('home'), findsNothing);
        // The text is still in the panel when the user goes back to it.
        rig.controller.setMode(ChatWorkspaceMode.workspace);
        await _settle(tester);
        expect(find.text('editor'), findsOneWidget);
        expect(identical(tester.state(find.byType(_Editor)), rig.editor), isTrue);
        rig.controller.setMode(ChatWorkspaceMode.chat);
        await _settle(tester);

        await tester.binding.handlePopRoute();
        await _settle(tester);
        await _answer(tester, UnsavedWorkGuard.discardKey);
        expect(find.text('chat'), findsNothing);
        expect(find.text('home'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the arrow of the chat\'s bar asks like system Back', (
      tester,
    ) async {
      final rig = await pump(tester);
      rig.editor.hold();
      rig.controller.open(ChatWorkspaceTab.terminal);
      await _settle(tester);

      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(find.text('chat'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.discardKey);
      expect(find.text('chat'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('Back that belongs to the editor\'s own tab is not a way '
        'out: the chat does not ask', (tester) async {
      final rig = await pump(tester);
      rig.editor.hold();
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(_question, findsNothing, reason: 'the tab took this Back');
      expect(find.text('chat'), findsOneWidget);
    });

    testWidgets('Back that closes the chat\'s menu closes it, without '
        'asking and without leaving', (tester) async {
      final rig = await pump(tester);
      rig.editor.hold();
      rig.controller.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      rig.chat.currentState!.openDrawer();
      await _settle(tester);
      expect(find.text('menu'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(_question, findsNothing);
      expect(find.text('menu'), findsNothing);
      expect(find.text('chat'), findsOneWidget);
    });

    testWidgets('once the text is saved Back leaves at once again', (
      tester,
    ) async {
      final rig = await pump(tester);
      rig.editor.hold();
      rig.controller.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      rig.editor.release();
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(_question, findsNothing);
      expect(find.text('home'), findsOneWidget);
    });
  });

  group('opening another conversation', () {
    Future<NavigatorState> chatOpen(WidgetTester tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _app(const Scaffold(body: Text('home')), navigatorKey: key),
      );
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('chat A')),
        ),
      );
      await _settle(tester);
      return key.currentState!;
    }

    Future<void> check(
      WidgetTester tester,
      void Function(BuildContext chat) open,
    ) async {
      final navigator = await chatOpen(tester);
      final held = _holdOn(navigator);
      open(tester.element(find.text('chat A')));
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(find.text('chat A'), findsOneWidget);
      expect(find.text('chat B'), findsNothing);
      expect(held.log, isEmpty);

      open(tester.element(find.text('chat A')));
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.discardKey);
      expect(find.text('chat B'), findsOneWidget);
      expect(find.text('chat A'), findsNothing);
      expect(held.log, ['discarded']);
    }

    testWidgets('openChatFromHome asks', (tester) async {
      await check(
        tester,
        (chat) => openChatFromHome<void>(
          chat,
          builder: (_) => const Scaffold(body: Text('chat B')),
        ),
      );
    });

    testWidgets('openChatFromHomeNavigator asks', (tester) async {
      await check(
        tester,
        (chat) => openChatFromHomeNavigator<void>(
          Navigator.of(chat),
          builder: (_) => const Scaffold(body: Text('chat B')),
        ),
      );
    });

    testWidgets('openChatWithParent asks', (tester) async {
      await check(
        tester,
        (chat) => openChatWithParent<void>(
          chat,
          parentBuilder: (_) => const Scaffold(body: Text('library')),
          builder: (_) => const Scaffold(body: Text('chat B')),
        ),
      );
    });

    testWidgets('a notification that opens its owner asks', (tester) async {
      await check(
        tester,
        (chat) => pushNotificationOwnerRoute<void>(
          Navigator.of(chat),
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('chat B')),
          ),
        ),
      );
    });
  });

  group('the tablet pane', () {
    Future<GlobalKey<AdaptiveListDetailState>> pump(WidgetTester tester) async {
      _wide(tester);
      final pane = GlobalKey<AdaptiveListDetailState>();
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: AdaptiveListDetail(
              key: pane,
              placeholder: const Text('nothing open'),
              list: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump();
      pane.currentState!.show<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('chat A')),
        ),
      );
      await _settle(tester);
      expect(pane.currentState!.hasDetail, isTrue);
      return pane;
    }

    testWidgets('another conversation in the pane asks', (tester) async {
      final pane = await pump(tester);
      _holdOn(Navigator.of(tester.element(find.text('chat A'))));
      void open() => pane.currentState!.show<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('chat B')),
        ),
      );
      open();
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(find.text('chat A'), findsOneWidget);
      open();
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.discardKey);
      expect(find.text('chat B'), findsOneWidget);
      expect(find.text('chat A'), findsNothing);
    });

    testWidgets('closing the pane asks', (tester) async {
      final pane = await pump(tester);
      _holdOn(Navigator.of(tester.element(find.text('chat A'))));
      pane.currentState!.clear();
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(find.text('chat A'), findsOneWidget);
      pane.currentState!.clear();
      await _settle(tester);
      await _answer(tester, UnsavedWorkGuard.discardKey);
      expect(find.text('chat A'), findsNothing);
    });
  });

  group('the drawer of a chat', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final root = GlobalKey<NavigatorState>();
      final chat = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _app(const Scaffold(body: Text('home')), navigatorKey: root),
      );
      root.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            key: chat,
            drawer: HermesDrawer(
              connection: _connection,
              connManager: manager,
              current: DrawerSection.chat,
            ),
            body: const Text('chat A'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _holdOn(root.currentState!);
      chat.currentState!.openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Drawer), findsOneWidget);
    }

    Future<void> tapInDrawer(WidgetTester tester, String label) async {
      final item = find.descendant(
        of: find.byType(Drawer),
        matching: find.text(label),
      );
      final scrollable = find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(item, 80, scrollable: scrollable);
      await tester.tap(item);
      await _settle(tester);
    }

    testWidgets('a section asks before it replaces the chat', (tester) async {
      await pump(tester);
      await tapInDrawer(tester, 'Settings');
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(find.text('chat A', skipOffstage: false), findsOneWidget);
      expect(find.byType(Drawer), findsOneWidget, reason: 'nothing moved');

      await tapInDrawer(tester, 'Settings');
      await _answer(tester, UnsavedWorkGuard.discardKey);
      await tester.pumpAndSettle();
      expect(find.text('chat A', skipOffstage: false), findsNothing);
    });

    testWidgets('Home asks before it closes the chat', (tester) async {
      await pump(tester);
      await tapInDrawer(tester, 'Home');
      await _answer(tester, UnsavedWorkGuard.keepKey);
      expect(find.text('chat A', skipOffstage: false), findsOneWidget);

      await tapInDrawer(tester, 'Home');
      await _answer(tester, UnsavedWorkGuard.discardKey);
      await tester.pumpAndSettle();
      expect(find.text('chat A', skipOffstage: false), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });
  });

  // A navigation that removes routes in bulk and does not go through the
  // guard is a way out of the chat that loses the text again.
  test('every bulk navigation in lib goes through the guard', () {
    final bulk = RegExp(
      r'\b(popUntil|pushAndRemoveUntil|pushReplacement|'
      r'pushNamedAndRemoveUntil|pushReplacementNamed|popAndPushNamed|'
      r'restorablePushReplacement|restorablePushAndRemoveUntil)\s*'
      r'(<[^>(]*>)?\(',
    );
    // Not ways out of a chat: a screen that replaces itself with its own
    // next step, a settings pane's own navigator, a read-only probe of the
    // stack, and the guard itself.
    const allowed = <String, int>{
      'lib/core/capabilities/catalog_deep_link_screen.dart': 1,
      'lib/core/navigation/unsaved_work_guard.dart': 1,
      'lib/core/screens/chat_screen.dart': 1,
      'lib/core/screens/instance_edit_screen.dart': 2,
      'lib/core/screens/session_detail_screen.dart': 1,
      'lib/core/settings/settings_list_detail.dart': 1,
    };
    final unguarded = <String, List<int>>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (!bulk.hasMatch(lines[i])) continue;
        final from = i - 14 < 0 ? 0 : i - 14;
        final guarded = lines
            .sublist(from, i + 1)
            .any((line) => line.contains('UnsavedWorkGuard.'));
        if (!guarded) (unguarded[path] ??= []).add(i + 1);
      }
    }
    final problems = <String>[
      for (final entry in unguarded.entries)
        if (entry.value.length != (allowed[entry.key] ?? 0))
          '${entry.key}: lines ${entry.value} '
              '(allowed: ${allowed[entry.key] ?? 0})',
      for (final entry in allowed.entries)
        if (!unguarded.containsKey(entry.key)) '${entry.key}: stale allowance',
    ];
    expect(
      problems,
      isEmpty,
      reason:
          'wrap the navigation in UnsavedWorkGuard.leave/leaveWith/'
          'popToFirst, or allow it here with the reason',
    );
  });

  // Deleting the session from the chat's menu closes the chat: it asks
  // about unsaved text before anything is deleted on the server.
  test('deleting the open session asks before it deletes', () {
    final source = File('lib/core/screens/chat_screen.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _deleteCurrentChat() async {');
    expect(start, greaterThan(0));
    final asks = source.indexOf('UnsavedWorkGuard.confirm(', start);
    final deletes = source.indexOf('ApiClient.forConnection(', start);
    final closes = source.indexOf('Navigator.pop(context, true);', start);
    expect(asks, greaterThan(start));
    expect(asks, lessThan(deletes), reason: 'asked before deleting');
    expect(deletes, lessThan(closes));
  });
}
