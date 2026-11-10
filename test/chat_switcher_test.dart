import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/core/widgets/workspace/chat_switcher.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The rail of agents beside an open chat when the list of chats is folded:
// one face per agent, a count and a mark on the face, a panel of that
// agent's chats anchored beside the rail. Fake data: an agent with seven
// chats and three more agents.

ChatSwitcherChat _chat(
  String id,
  String title, {
  ChatSwitcherMark mark = ChatSwitcherMark.none,
  String time = '5 min',
}) => ChatSwitcherChat(id: id, title: title, time: time, mark: mark);

List<ChatSwitcherAgent> _agents() => [
  ChatSwitcherAgent(
    owner: 'xpeta',
    name: 'xPeta',
    profile: const AgentProfile(name: 'xpeta', displayName: 'xPeta'),
    chats: [
      _chat(
        'a-1',
        'Configure the relay for production',
        mark: ChatSwitcherMark.working,
      ),
      _chat(
        'a-2',
        'Independent review of the sender backoff',
        mark: ChatSwitcherMark.waiting,
      ),
      _chat(
        'a-3',
        'Add CLI lock tests and run the mutants',
        mark: ChatSwitcherMark.unread,
      ),
      _chat('a-4', 'Release notes for the beta'),
      _chat('a-5', 'Keystore signature in CI'),
      _chat('a-6', 'Migrate the settings page'),
      _chat(
        'a-7',
        'A very long conversation title that must stay on one line and ellipsize',
      ),
    ],
  ),
  ChatSwitcherAgent(
    owner: 'forja',
    name: 'Forja',
    profile: const AgentProfile(name: 'forja', displayName: 'Forja'),
    chats: [_chat('b-1', 'Forge the icons'), _chat('b-2', 'Forge the splash')],
  ),
  ChatSwitcherAgent(
    owner: 'studio',
    name: 'Studio',
    profile: const AgentProfile(name: 'studio'),
    chats: [_chat('c-1', 'One single studio chat')],
  ),
  const ChatSwitcherAgent(
    owner: 'ops',
    name: 'Ops',
    profile: AgentProfile(name: 'ops'),
    chats: [],
  ),
];

class _Calls {
  final opened = <String>[];
  final newWith = <String?>[];
  int listOpens = 0;
}

Finder _face(String owner) => find.byKey(ValueKey('chat-switcher-face-$owner'));
Finder _badge(String owner) =>
    find.byKey(ValueKey('chat-switcher-badge-$owner'));
Finder _mark(String owner) => find.byKey(ValueKey('chat-switcher-mark-$owner'));
Finder _row(String id) => find.byKey(ValueKey('chat-switcher-row-$id'));
final _panel = find.byKey(const ValueKey('chat-switcher-panel'));
final _pane = find.byKey(const ValueKey('probe-pane'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_Calls> pumpRail(
    WidgetTester tester, {
    Size size = const Size(1100, 800),
    Locale locale = const Locale('en'),
    String theme = 'dark',
    double textScale = 1,
    bool reduceMotion = false,
    List<ChatSwitcherAgent>? agents,
    String? currentChatId = 'a-3',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final calls = _Calls();
    final data = agents ?? _agents();
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.fromId(theme),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: ChatSwitcherRail(
            agents: data,
            currentChatId: currentChatId,
            onOpenChat: calls.opened.add,
            onNewChat: (agent) => calls.newWith.add(agent?.owner),
            onOpenList: () => calls.listOpens++,
            child: const ColoredBox(
              key: ValueKey('probe-pane'),
              color: Colors.transparent,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return calls;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> open(WidgetTester tester, String owner) async {
    await tester.tap(_face(owner));
    await settle(tester);
    expect(_panel, findsOneWidget);
  }

  testWidgets('one face per agent, a count from one chat on and the ring on '
      'the open chat\'s agent', (tester) async {
    await pumpRail(tester);
    expect(tester.takeException(), isNull);
    // Four agents, four faces (seven chats of the first, still one face).
    for (final owner in ['xpeta', 'forja', 'studio', 'ops']) {
      expect(_face(owner), findsOneWidget);
    }
    expect(find.byType(ProfileFace), findsNWidgets(4));
    expect(
      find.descendant(of: _badge('xpeta'), matching: find.text('7')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _badge('forja'), matching: find.text('2')),
      findsOneWidget,
    );
    // One chat is counted too: it must not look like an agent with none.
    expect(
      find.descendant(of: _badge('studio'), matching: find.text('1')),
      findsOneWidget,
    );
    expect(_badge('ops'), findsNothing);
    // The ring: only the agent of the open chat (a-3 is xPeta's).
    final rings = tester
        .widgetList<ProfileFace>(find.byType(ProfileFace))
        .where((face) => face.active)
        .map((face) => face.profileName)
        .toList();
    expect(rings, ['xpeta']);
    // The mark: xPeta has a chat waiting for the user (over working and
    // unread); the others have none.
    expect(_mark('xpeta'), findsOneWidget);
    expect(_mark('forja'), findsNothing);
    // The pane keeps the rest of the width beside the rail and its line.
    expect(tester.getRect(_pane).left, ChatSwitcherRail.width + 1);
    expect(tester.getRect(_pane).right, 1100);
  });

  testWidgets('a face opens the panel with the agent\'s chats; a row switches '
      'the chat and closes it', (tester) async {
    final calls = await pumpRail(tester);
    await open(tester, 'xpeta');
    expect(find.text('xPeta'), findsOneWidget);
    expect(find.text('7 chats'), findsOneWidget);
    for (var i = 1; i <= 7; i++) {
      expect(_row('a-$i'), findsOneWidget);
    }
    // The long title keeps to one line.
    final long = tester.widget<Text>(
      find.descendant(of: _row('a-7'), matching: find.byType(Text)).first,
    );
    expect(long.maxLines, 1);
    expect(long.overflow, TextOverflow.ellipsis);
    // Time and status on the row; the open one ticked.
    expect(find.text('5 min · Working…'), findsOneWidget);
    expect(find.text('5 min · Waiting for your reply'), findsOneWidget);
    expect(find.text('5 min · Unread'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-switcher-current-a-3')),
      findsOneWidget,
    );
    // Anchored beside the rail, within the window, opaque.
    final panel = tester.getRect(_panel);
    expect(panel.left, greaterThan(ChatSwitcherRail.width));
    expect(panel.width, ChatSwitcherRail.panelWidth);
    expect(panel.right, lessThan(1100));

    await tester.tap(_row('a-5'));
    await settle(tester);
    expect(calls.opened, ['a-5']);
    expect(_panel, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the scrim, Back and Escape close the panel', (tester) async {
    final calls = await pumpRail(tester);
    await open(tester, 'xpeta');
    await tester.tapAt(const Offset(1000, 400));
    await settle(tester);
    expect(_panel, findsNothing);

    await open(tester, 'xpeta');
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(_panel, findsNothing);

    await open(tester, 'xpeta');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(_panel, findsNothing);
    expect(calls.opened, isEmpty);
    // The rail is still there, with the pane.
    expect(_face('xpeta'), findsOneWidget);
    expect(_pane, findsOneWidget);
  });

  testWidgets('«Nueva conversación con …» hands the agent over; the pencil '
      'hands none', (tester) async {
    final calls = await pumpRail(tester);
    await open(tester, 'ops');
    expect(find.text('Ops'), findsOneWidget);
    expect(find.text('0 chats'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-switcher-empty')), findsOneWidget);
    expect(find.text('New conversation with Ops'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-switcher-new-with')));
    await settle(tester);
    expect(calls.newWith, ['ops']);
    expect(_panel, findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-switcher-new')));
    await settle(tester);
    expect(calls.newWith, ['ops', null]);

    await tester.tap(find.byKey(const ValueKey('chat-switcher-open-list')));
    await settle(tester);
    expect(calls.listOpens, 1);
  });

  testWidgets('an agent with one chat opens the same panel, one row', (
    tester,
  ) async {
    final calls = await pumpRail(tester);
    await open(tester, 'studio');
    expect(find.text('1 chat'), findsOneWidget);
    expect(_row('c-1'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-switcher-more')), findsNothing);
    expect(find.text('New conversation with Studio'), findsOneWidget);
    await tester.tap(_row('c-1'));
    await settle(tester);
    expect(calls.opened, ['c-1']);
  });

  testWidgets('many chats come a page at a time behind «Ver más»', (
    tester,
  ) async {
    final many = ChatSwitcherAgent(
      owner: 'xpeta',
      name: 'xPeta',
      chats: [for (var i = 0; i < 30; i++) _chat('m-$i', 'Chat $i')],
    );
    await pumpRail(tester, agents: [many], currentChatId: null);
    await open(tester, 'xpeta');
    final more = find.byKey(const ValueKey('chat-switcher-more'));
    final list = find.byKey(const ValueKey('chat-switcher-panel-list'));
    expect(find.text('30 chats'), findsOneWidget);
    await tester.scrollUntilVisible(
      more,
      80,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    expect(find.text('Show more (18)'), findsOneWidget);
    await tester.tap(more);
    await settle(tester);
    await tester.scrollUntilVisible(
      more,
      80,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    expect(find.text('Show more (6)'), findsOneWidget);
    await tester.tap(more);
    await settle(tester);
    expect(more, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('many agents: the rail scrolls to the last face', (tester) async {
    final crowd = [
      for (var i = 0; i < 30; i++)
        ChatSwitcherAgent(
          owner: 'agent-$i',
          name: 'Agent $i',
          chats: [_chat('s-$i', 'Chat of agent $i')],
        ),
    ];
    await pumpRail(
      tester,
      size: const Size(840, 600),
      agents: crowd,
      currentChatId: 's-0',
    );
    expect(tester.takeException(), isNull);
    expect(_face('agent-0'), findsOneWidget);
    expect(_face('agent-29'), findsNothing);
    await tester.scrollUntilVisible(
      _face('agent-29'),
      100,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('chat-switcher-faces')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(_face('agent-29'), findsOneWidget);
    // The pencil stays at the foot, outside the scroll.
    expect(find.byKey(const ValueKey('chat-switcher-new')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a face says its agent, count, open chat and mark; long press '
      'names it; faces and rows take the keyboard focus', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpRail(tester);
    expect(
      tester.getSemantics(_face('xpeta')),
      matchesSemantics(
        label:
            'xPeta, 7 conversations, '
            'current: Add CLI lock tests and run the mutants, '
            'Waiting for your reply',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    expect(
      tester.getSemantics(_face('studio')),
      matchesSemantics(
        label: 'Studio, 1 conversation',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    // The rail is named for a screen reader.
    expect(find.bySemanticsLabel('Agents'), findsOneWidget);

    // Long press: the tooltip with the agent's name (the rail shows none).
    expect(find.text('Forja'), findsNothing);
    await tester.longPress(_face('forja'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Forja'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);

    // Tab reaches the faces.
    final reached = <String>{};
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) continue;
      for (final owner in ['xpeta', 'forja', 'studio', 'ops']) {
        if (find
            .ancestor(of: find.byWidget(focused.widget), matching: _face(owner))
            .evaluate()
            .isNotEmpty) {
          reached.add(owner);
        }
      }
    }
    expect(reached, contains('xpeta'));

    // In the panel the open chat's row has the focus; Enter opens it.
    await open(tester, 'xpeta');
    final rowFocus = FocusManager.instance.primaryFocus?.context;
    expect(rowFocus, isNotNull);
    expect(
      find.ancestor(of: find.byWidget(rowFocus!.widget), matching: _row('a-3')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(_row('a-3')),
      matchesSemantics(
        label: 'Add CLI lock tests and run the mutants',
        value: '5 min · Unread, Open conversation',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('reduced motion: the panel is in place at once', (tester) async {
    await pumpRail(tester, reduceMotion: true);
    await tester.tap(_face('xpeta'));
    await tester.pump();
    await tester.pump();
    expect(_panel, findsOneWidget);
    final fade = tester.widget<FadeTransition>(
      find.ancestor(of: _panel, matching: find.byType(FadeTransition)).first,
    );
    expect(fade.opacity.value, 1);
  });

  for (final locale in Strings.supportedLocales) {
    for (final theme in ['dark', 'light']) {
      testWidgets('${locale.languageCode} $theme at 2x text: rail and panel '
          'without overflow', (tester) async {
        await pumpRail(
          tester,
          locale: locale,
          theme: theme,
          textScale: 2,
          size: const Size(840, 700),
        );
        expect(tester.takeException(), isNull);
        expect(_face('xpeta'), findsOneWidget);
        expect(
          find.descendant(of: _badge('xpeta'), matching: find.text('7')),
          findsOneWidget,
        );
        await open(tester, 'xpeta');
        expect(tester.takeException(), isNull);
        final s = Strings.of(tester.element(_panel));
        expect(find.text(s.cswChatCount(7)), findsOneWidget);
        final panel = tester.getRect(_panel);
        expect(panel.right, lessThanOrEqualTo(840));
        expect(panel.bottom, lessThanOrEqualTo(700));
        // The last row is reached by scrolling the panel's list.
        final newWith = find.byKey(const ValueKey('chat-switcher-new-with'));
        await tester.scrollUntilVisible(
          newWith,
          80,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('chat-switcher-panel-list')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(find.text(s.cswNewChatWith('xPeta')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await settle(tester);
        await open(tester, 'ops');
        expect(find.text(s.cswNoChats), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  // ── Where the rail shows: the list-detail layout ─────────────────────────

  Future<GlobalKey<AdaptiveListDetailState>> pumpLayout(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AdaptiveListDetailState>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: AdaptiveListDetail(
            key: key,
            listWidth: 300,
            listVisible: false,
            list: const ColoredBox(
              key: ValueKey('probe-list'),
              color: Colors.transparent,
            ),
            placeholder: const SizedBox.shrink(),
            foldedListRail: (pane) => ChatSwitcherRail(
              agents: _agents(),
              currentChatId: 'a-3',
              onOpenChat: (_) {},
              onNewChat: (_) {},
              onOpenList: () {},
              child: pane,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return key;
  }

  for (final width in const [600.0, 840.0, 1100.0, 1248.0]) {
    testWidgets('${width.toInt()} dp: the rail only beside a folded list in '
        'an expanded window', (tester) async {
      final key = await pumpLayout(tester, Size(width, 800));
      final rail = find.byKey(const ValueKey('chat-switcher-rail'));
      // Nothing open: the list, no rail.
      expect(rail, findsNothing);
      expect(find.byKey(const ValueKey('probe-list')), findsOneWidget);
      key.currentState!.show(
        MaterialPageRoute<void>(
          builder: (_) => const ColoredBox(
            key: ValueKey('probe-detail'),
            color: Colors.transparent,
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      final detail = find.byKey(const ValueKey('probe-detail'));
      expect(detail, findsOneWidget);
      if (width < 840) {
        // Medium: the item in place of the list, as before.
        expect(rail, findsNothing);
        expect(tester.getRect(detail).left, 0);
      } else {
        expect(rail, findsOneWidget);
        expect(tester.getRect(detail).left, ChatSwitcherRail.width + 1);
        expect(tester.getRect(detail).right, width);
        await open(tester, 'xpeta');
        final panel = tester.getRect(_panel);
        expect(panel.left, ChatSwitcherRail.width + 10);
        expect(panel.width, ChatSwitcherRail.panelWidth);
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(_panel, findsNothing);
        // The item is still open: Back closed only the panel.
        expect(detail, findsOneWidget);
      }
    });
  }
  testWidgets('an agent with chats past its first page says «N+» of the chats '
      'its panel lists, on its face, in its semantics and its panel header', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpRail(
      tester,
      agents: [
        ..._agents(),
        ChatSwitcherAgent(
          owner: 'console-builder',
          name: 'Forja builder',
          profile: const AgentProfile(name: 'console-builder'),
          chats: [_chat('d-1', 'Greeting'), _chat('d-2', 'Splash')],
          more: true,
        ),
      ],
    );
    expect(
      find.descendant(of: _badge('console-builder'), matching: find.text('2+')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(_face('console-builder')),
      matchesSemantics(
        label: 'Forja builder, 2+ conversations',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    await open(tester, 'console-builder');
    expect(find.text('2+ chats'), findsOneWidget);
    expect(_row('d-1'), findsOneWidget);
    expect(_row('d-2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  test('the count is the chats the panel lists, never a server total', () {
    ChatSwitcherAgent agent({bool more = false, int chats = 2}) =>
        ChatSwitcherAgent(
          owner: 'o',
          name: 'O',
          chats: [for (var i = 0; i < chats; i++) _chat('x-$i', 'chat $i')],
          more: more,
        );
    expect(agent().count, 2);
    expect(agent(more: true).count, 2);
    expect(agent(more: true).more, isTrue);
    expect(agent(chats: 0).count, 0);
  });
}
