import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/responsive.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';
import 'package:hermes_android/core/widgets/workspace/chat_switcher.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_api_client.dart';

// Chats on a tablet: the conversation list and the open conversation side by
// side in expanded windows, one at a time in medium ones, and the phone flow
// (a full-screen chat route) on compact windows.

const _connectionId = 'conn-tablet-chats';

Map<String, dynamic> _row(String id, String title, int lastActive) => {
  'id': id,
  '_lineage_root_id': id,
  'title': title,
  'preview': '',
  'model': 'model-a',
  'source': 'mobile',
  'message_count': 2,
  'is_active': false,
  'started_at': lastActive - 30,
  'ended_at': lastActive - 1,
  'last_active': lastActive,
  'archived': false,
};

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Tablet QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

/// Stand-in for the chat: the real ChatScreen needs the whole app. It has a
/// composer-like field so the draft can be followed across rotations.
class _ChatProbe extends StatefulWidget {
  final Session session;
  const _ChatProbe(this.session);
  static int mounts = 0;
  @override
  State<_ChatProbe> createState() => _ChatProbeState();
}

class _ChatProbeState extends State<_ChatProbe> {
  final draft = TextEditingController();
  @override
  void initState() {
    super.initState();
    _ChatProbe.mounts++;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: ValueKey('chat-probe-${widget.session.id}'),
    body: ListView(
      children: [
        Text('chat ${widget.session.id}'),
        TextField(key: const ValueKey('probe-composer'), controller: draft),
      ],
    ),
  );
}

class _Recorder extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureValues = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    _ChatProbe.mounts = 0;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments is Map
                ? Map<Object?, Object?>.from(call.arguments as Map)
                : const <Object?, Object?>{};
            switch (call.method) {
              case 'write':
                secureValues[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureValues[args['key']];
              case 'readAll':
                return Map<String, String>.of(secureValues);
              case 'delete':
                secureValues.remove(args['key']);
                return null;
            }
            return null;
          },
        );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
    await DockPreferencesController.instance.setUseDock(true);
  });

  Future<_Recorder> pump(
    WidgetTester tester,
    Size size, {
    String firstTitle = 'Firma del keystore en CI',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = [
      _row('s-1', firstTitle, now - 60),
      _row('s-2', 'Notas de la release', now - 120),
    ];
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'sessions': rows,
              'total': rows.length,
              'limit': 50,
              'offset': 0,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final gateway = testApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      connectionId: _connectionId,
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/status' ||
            request.url.path == '/api/sessions') {
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });
    final recorder = _Recorder();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        navigatorObservers: [recorder],
        home: SessionListScreen(
          connection: _connection(),
          connManager: manager,
          clientOverride: gateway,
          repositoryOverride: repository,
          chatScreenBuilderOverride: (session) => _ChatProbe(session),
        ),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (find.text('Notas de la release').evaluate().isNotEmpty) break;
    }
    expect(find.text('Notas de la release'), findsOneWidget);
    return recorder;
  }

  Finder pane() => find.byKey(const ValueKey('adaptive-detail-pane'));
  Finder probe(String id) => find.byKey(ValueKey('chat-probe-$id'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  for (final size in const [Size(1024, 768), Size(1280, 800)]) {
    testWidgets('expanded ${size.width.toInt()}x${size.height.toInt()}: '
        'list beside the chat; a tap opens it in the pane', (tester) async {
      final recorder = await pump(tester, size);
      await settle(tester);
      expect(tester.takeException(), isNull);
      // the owner (mock 134): the side rail only on tablets, from 1100 dp.
      expect(
        find.byKey(const ValueKey('general-mode-dock-rail')),
        size.width >= kChatWorkspaceNavigationMinWidth
            ? findsOneWidget
            : findsNothing,
      );
      expect(pane(), findsOneWidget);
      final pushesBefore = recorder.pushes;
      final listTitle = tester.getRect(find.text('Notas de la release'));

      await tester.tap(find.text('Firma del keystore en CI'));
      await settle(tester);
      expect(recorder.pushes, pushesBefore, reason: 'no app route push');
      expect(
        find.descendant(of: pane(), matching: probe('s-1')),
        findsOneWidget,
      );
      // The list stays on screen, left of the chat, at the list width.
      expect(find.text('Notas de la release'), findsOneWidget);
      final chat = tester.getRect(probe('s-1'));
      expect(chat.left, greaterThan(listTitle.right));
      // Mock 134: the Chats list is 300 dp wide.
      expect(
        tester.getRect(pane()).left -
            tester.getRect(find.byType(SessionListScreen)).left,
        greaterThan(ChatWorkspaceController.listWidth),
      );

      // Selecting the same conversation again does not reopen it.
      await tester.tap(find.text('Firma del keystore en CI'));
      await settle(tester);
      expect(_ChatProbe.mounts, 1);

      // Another one replaces it in place.
      await tester.tap(find.text('Notas de la release'));
      await settle(tester);
      expect(probe('s-1'), findsNothing);
      expect(probe('s-2'), findsOneWidget);
      expect(recorder.pushes, pushesBefore);

      // Back closes the open conversation first, staying on the list.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(probe('s-2'), findsNothing);
      expect(find.text('Notas de la release'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('compact 411x915: the phone flow is unchanged', (tester) async {
    final recorder = await pump(tester, const Size(411, 915));
    await settle(tester);
    expect(pane(), findsNothing);
    expect(
      find.byKey(const ValueKey('general-mode-floating-dock')),
      findsOneWidget,
    );
    final before = recorder.pushes;
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    expect(recorder.pushes, before + 1, reason: 'full-screen chat route');
    expect(probe('s-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium 700x1000: the chat replaces the list; Back returns', (
    tester,
  ) async {
    final recorder = await pump(tester, const Size(700, 1000));
    await settle(tester);
    final before = recorder.pushes;
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    expect(recorder.pushes, before);
    expect(probe('s-1'), findsOneWidget);
    expect(find.text('Notas de la release'), findsNothing);
    final chat = tester.getRect(probe('s-1'));
    expect(chat.width, lessThanOrEqualTo(Responsive.maxContentWidth));
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('Notas de la release'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation keeps the open chat and its composer draft', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 800));
    await settle(tester);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('probe-composer')),
      'half a thought',
    );
    final state = tester.state(find.byType(_ChatProbe));
    for (final size in const [Size(800, 1280), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(probe('s-1'), findsOneWidget);
      expect(tester.state(find.byType(_ChatProbe)), same(state));
      expect(find.text('half a thought'), findsOneWidget);
    }
    expect(_ChatProbe.mounts, 1);
  });

  // ── Mock 134: one model of views (list, chat, workspace) ─────────────────

  ChatWorkspaceController views(WidgetTester tester, String id) =>
      ChatWorkspaceScope.maybeOf(tester.element(probe(id)))!;

  Finder listRow() => find.text('Notas de la release');
  Finder rail() => find.byKey(const ValueKey('general-mode-dock-rail'));
  Finder overlay() => find.byKey(const ValueKey('adaptive-list-overlay'));
  // The rail of agents that stands in for the folded list, and its edge
  // (the rail and its hairline).
  Finder switcher() => find.byKey(const ValueKey('chat-switcher-rail'));
  const railEdge = ChatSwitcherRail.width + 1;

  testWidgets('open Fold 933x704: the list has its own header, no rail; '
      'opening the workspace folds the list', (tester) async {
    await pump(tester, const Size(933, 704));
    await settle(tester);
    expect(rail(), findsNothing);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    final screen = tester.getRect(find.byType(SessionListScreen));
    // State A: the list (300 dp) with its header; the chat from the top of
    // the screen, no bar across it.
    final chatPane = tester.getRect(pane());
    expect(chatPane.top, screen.top);
    expect(chatPane.left, ChatWorkspaceController.listWidth + 1);
    final title = tester.getRect(find.text('Conversations').first);
    expect(title.right, lessThan(chatPane.left));
    // Ola 4 (mock 134-A, audit 2.1): beside the chat the time closes the
    // preview line under the title (here the row has no preview, so it is
    // the line), not a column of its own that took the title's width.
    final time = tester.getRect(find.byKey(const ValueKey('session-time-s-2')));
    final rowTitle = tester.getRect(listRow());
    expect(time.top, greaterThanOrEqualTo(rowTitle.bottom - 0.5));
    expect(time.left, closeTo(rowTitle.left, 0.5));

    // State C: a tab opened with the list showing folds the list.
    final c = views(tester, 's-1');
    expect(c.maxViews, 2);
    c.open(ChatWorkspaceTab.terminal);
    await settle(tester);
    expect(c.listVisible, isFalse);
    expect(c.chatVisible, isTrue);
    expect(c.workspaceVisible, isTrue);
    expect(listRow(), findsNothing);
    // The folded list leaves its agents on a rail at the chat's edge.
    expect(switcher(), findsOneWidget);
    expect(tester.getRect(pane()).left, screen.left + railEdge);

    // The list comes over the content, not pushing it.
    c.toggleList();
    await settle(tester);
    expect(overlay(), findsOneWidget);
    expect(listRow(), findsOneWidget);
    expect(tester.getRect(pane()).left, screen.left + railEdge);
    await tester.tapAt(Offset(screen.right - 40, screen.center.dy));
    await settle(tester);
    expect(c.listOverlay, isFalse);
    expect(listRow(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet 1280x800: the three views fit side by side', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 800));
    await settle(tester);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    final c = views(tester, 's-1');
    expect(c.maxViews, 3);
    c.open(ChatWorkspaceTab.terminal);
    await settle(tester);
    expect(c.visibleViews, ChatWorkspaceView.values);
    expect(listRow(), findsOneWidget);
    expect(rail(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // the owner's added rule: the open Fold upright (≈657x870) gets the phone's
  // chat, full screen, with no list bar and no rail around it.
  testWidgets('upright Fold 657x870: the chat takes the whole screen; the '
      'list comes over it', (tester) async {
    await pump(tester, const Size(657, 870));
    await settle(tester);
    expect(rail(), findsNothing);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    expect(tester.getRect(probe('s-1')), const Rect.fromLTWH(0, 0, 657, 870));
    expect(rail(), findsNothing);
    // No list header (or any of the list) above the chat.
    expect(find.text('Conversations'), findsNothing);
    expect(listRow(), findsNothing);

    final c = views(tester, 's-1');
    expect(c.stacked, isTrue);
    c.toggleList();
    await settle(tester);
    expect(overlay(), findsOneWidget);
    expect(listRow(), findsOneWidget);
    expect(tester.getRect(probe('s-1')), const Rect.fromLTWH(0, 0, 657, 870));
    // Picking a chat from it opens that chat and the list goes.
    await tester.tap(listRow());
    await settle(tester);
    expect(probe('s-2'), findsOneWidget);
    expect(c.listOverlay, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turning upright and back keeps the chat, its draft and the '
      'views chosen', (tester) async {
    await pump(tester, const Size(933, 704));
    await settle(tester);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('probe-composer')),
      'half a thought',
    );
    final state = tester.state(find.byType(_ChatProbe));
    final c = views(tester, 's-1');
    // State B: the list closed by the user.
    c.toggleList();
    await settle(tester);
    expect(c.listVisible, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(ChatWorkspaceController.listOpenKey(c.screen)),
      isFalse,
    );

    for (final size in const [Size(657, 870), Size(933, 704)]) {
      tester.view.physicalSize = size;
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(tester.state(find.byType(_ChatProbe)), same(state));
      expect(find.text('half a thought'), findsOneWidget);
      // Upright the chat has the whole width; on its side, the list folded,
      // the rail of agents keeps its edge.
      final folded = size.width >= Responsive.expandedBreakpoint;
      expect(switcher(), folded ? findsOneWidget : findsNothing);
      expect(
        tester.getRect(probe('s-1')).width,
        size.width - (folded ? railEdge : 0),
      );
    }
    // Back on its side, the list is still the way the user left it.
    expect(c.listVisible, isFalse);
    expect(_ChatProbe.mounts, 1);
  });

  testWidgets('open Fold 933x704, the list folded: the rail of agents switches '
      'the chat in the pane and «≡» brings the list back', (tester) async {
    await pump(tester, const Size(933, 704));
    await settle(tester);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    final c = views(tester, 's-1');
    c.toggleList();
    await settle(tester);
    expect(c.listVisible, isFalse);
    expect(switcher(), findsOneWidget);
    // Both chats belong to the main profile: one face, a count of two.
    final face = find.byKey(const ValueKey('chat-switcher-face-default'));
    expect(face, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-switcher-badge-default')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    final pushesBefore = _ChatProbe.mounts;
    await tester.tap(face);
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-switcher-panel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-switcher-current-s-1')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('chat-switcher-row-s-2')));
    await settle(tester);
    // The other chat took the pane, the panel went, no app route was pushed.
    expect(find.byKey(const ValueKey('chat-switcher-panel')), findsNothing);
    expect(probe('s-1'), findsNothing);
    expect(probe('s-2'), findsOneWidget);
    expect(_ChatProbe.mounts, pushesBefore + 1);
    expect(c.listVisible, isFalse);
    expect(tester.getRect(pane()).left, railEdge);

    // «≡» on the rail: the list back as a column (two views fit here).
    await tester.tap(find.byKey(const ValueKey('chat-switcher-open-list')));
    await settle(tester);
    expect(c.listVisible, isTrue);
    expect(listRow(), findsOneWidget);
    expect(switcher(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // the owner (ronda Fold 2), point 3: beside the chat the list is one surface
  // with it (mock 134 state A): under its own header, the page's own
  // background, a short faint line, rows rounded on their own, the open
  // conversation a card, and long titles on two lines.
  const longTitle = 'Comprobar problema de Reddit con la API de sesiones';

  testWidgets('open Fold 933x704: the list is one surface with the chat', (
    tester,
  ) async {
    await pump(tester, const Size(933, 704), firstTitle: longTitle);
    await settle(tester);
    expect(tester.takeException(), isNull);

    // Under its header: the body is clipped where the header ends, so a
    // scrolled row never paints over the header's round buttons.
    final body = find.byKey(const ValueKey('session-list-column-body'));
    expect(tester.widget(body), isA<ClipRect>());
    expect(
      tester.getRect(body).top,
      greaterThanOrEqualTo(
        tester.getRect(find.text('Conversations').first).bottom,
      ),
    );

    // A short, faint line between list and chat, not a full-height rule.
    final slotFinder = find.byKey(const ValueKey('adaptive-list-divider'));
    final ruleFinder = find.descendant(
      of: slotFinder,
      matching: find.byType(VerticalDivider),
    );
    final slot = tester.getRect(slotFinder);
    final line = tester.getRect(ruleFinder);
    expect(line.width, 1);
    expect(line.top - slot.top, 6);
    expect(slot.bottom - line.bottom, 14);
    expect(tester.widget<VerticalDivider>(ruleFinder).color!.a, lessThan(1));

    // Nothing filled until a conversation is open; then that one is a card.
    expect(find.byKey(const ValueKey('session-row-selected')), findsNothing);
    await tester.tap(find.text('Notas de la release'));
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-row-selected')),
        matching: find.text('Notas de la release'),
      ),
      findsOneWidget,
    );

    // Long titles take a second line instead of being cut at once.
    final title = tester.widget<Text>(find.text(longTitle));
    expect(title.maxLines, 2);
    expect(tester.getSize(find.text(longTitle)).height, greaterThan(15 * 1.5));
  });

  testWidgets('phone 412x915: the list rows stay as they were', (tester) async {
    await pump(tester, const Size(412, 915), firstTitle: longTitle);
    await settle(tester);
    expect(tester.widget<Text>(find.text(longTitle)).maxLines, 1);
    expect(
      find.byKey(const ValueKey('session-list-column-body')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('session-row-selected')), findsNothing);
  });

  // ── QA 9709: folding the Fold on Chats ─────────────────────────────────
  //
  // the owner (APK 9711): Chats open on the unfolded Fold, the list visible and
  // no conversation open; folded, the cover showed «Pick a conversation…»
  // and nothing could be touched. Below 600 dp the pane's navigator leaves
  // the tree; its observer kept counting the placeholder, so the next pane
  // navigator (any frame at 600 dp or more) counted two pages: an "open
  // item" that is only the placeholder, the list hidden, Back eaten.

  const unfolded = Size(884, 1000);
  const cover = Size(360, 800);
  const upright = Size(720, 1000);
  const placeholder = 'Pick a conversation to open it here';

  AdaptiveListDetailState panes(WidgetTester tester) =>
      tester.state<AdaptiveListDetailState>(find.byType(AdaptiveListDetail));

  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '$size');
  }

  /// The list is on screen and takes taps, nothing is open, and the
  /// placeholder shows only beside the list (expanded), never instead of it.
  void expectTouchableList(WidgetTester tester, String why) {
    final expanded =
        Responsive.sizeClassForWidth(tester.view.physicalSize.width) ==
        WindowSizeClass.expanded;
    expect(listRow().hitTestable(), findsOneWidget, reason: why);
    expect(
      find.text(placeholder),
      expanded ? findsOneWidget : findsNothing,
      reason: why,
    );
    expect(
      find.byKey(const ValueKey('adaptive-list-overlay-scrim')),
      findsNothing,
      reason: why,
    );
    expect(panes(tester).hasDetail, isFalse, reason: why);
  }

  testWidgets('Fold, list and no chat: folded in one frame, the list', (
    tester,
  ) async {
    final recorder = await pump(tester, unfolded);
    await settle(tester);
    expect(find.text(placeholder), findsOneWidget);
    expectTouchableList(tester, 'unfolded');
    await resize(tester, cover);
    expect(pane(), findsNothing);
    expectTouchableList(tester, 'folded');
    final before = recorder.pushes;
    await tester.tap(listRow());
    await settle(tester);
    expect(recorder.pushes, before + 1, reason: 'the phone flow');
    expect(probe('s-2'), findsOneWidget);
  });

  testWidgets('Fold, list and no chat: folded through medium, the list', (
    tester,
  ) async {
    await pump(tester, unfolded);
    await settle(tester);
    await resize(tester, upright);
    expectTouchableList(tester, 'medium on the way');
    await resize(tester, cover);
    expectTouchableList(tester, 'folded');
  });

  testWidgets('Fold, list and no chat: a wide frame after folding still '
      'shows the list, never the placeholder alone', (tester) async {
    await pump(tester, unfolded);
    await settle(tester);
    // Folded, then any frame at 600 dp or more (the cover reporting a
    // wide size for a moment, or unfolding again), in both orders.
    for (final size in const [cover, upright, cover, unfolded, cover]) {
      await resize(tester, size);
      expectTouchableList(tester, '$size');
    }
    await resize(tester, upright);
    expectTouchableList(tester, 'upright after folding twice');
    // Back is not held by a pane with nothing open.
    expect(panes(tester).hasDetail, isFalse);
  });

  testWidgets('Fold, a chat open: folded, the chat goes full screen; its '
      'Back returns to a list that takes taps', (tester) async {
    final recorder = await pump(tester, unfolded);
    await settle(tester);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    expect(find.descendant(of: pane(), matching: probe('s-1')), findsOneWidget);
    final before = recorder.pushes;
    await resize(tester, upright);
    await resize(tester, cover);
    expect(recorder.pushes, before + 1, reason: 'reopened as a phone chat');
    expect(probe('s-1').hitTestable(), findsOneWidget);
    expect(find.text(placeholder), findsNothing);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expectTouchableList(tester, 'back from the chat');
  });

  testWidgets('Fold, the list folded away beside a chat: folded, the chat; '
      'Back, the list', (tester) async {
    await pump(tester, const Size(933, 704));
    await settle(tester);
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    views(tester, 's-1').toggleList();
    await settle(tester);
    expect(listRow(), findsNothing);
    await resize(tester, cover);
    expect(probe('s-1').hitTestable(), findsOneWidget);
    expect(find.text(placeholder), findsNothing);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expectTouchableList(tester, 'back from the chat');
  });

  testWidgets('cover to unfolded: the list beside the placeholder; a row '
      'opens in the pane', (tester) async {
    final recorder = await pump(tester, cover);
    await settle(tester);
    expectTouchableList(tester, 'folded');
    await resize(tester, unfolded);
    expect(find.text(placeholder), findsOneWidget);
    expect(listRow().hitTestable(), findsOneWidget);
    expect(panes(tester).hasDetail, isFalse);
    final before = recorder.pushes;
    await tester.tap(listRow());
    await settle(tester);
    expect(recorder.pushes, before, reason: 'in the pane, no app route');
    expect(find.descendant(of: pane(), matching: probe('s-2')), findsOneWidget);
    expect(panes(tester).hasDetail, isTrue);
  });

  // the owner's capture 2219 (1546x2048 px: the unfolded Fold upright, about
  // 773x1024 dp, medium): only the placeholder, full screen, no list, no
  // dock. Opened upright, folded to the cover, unfolded again.
  const unfoldedUpright = Size(773, 1024);

  testWidgets('capture 2219: upright, folded, upright again: the list', (
    tester,
  ) async {
    await pump(tester, unfoldedUpright);
    await settle(tester);
    expectTouchableList(tester, 'upright');
    for (final size in const [cover, unfoldedUpright, cover, unfolded]) {
      await resize(tester, size);
      expectTouchableList(tester, '$size');
    }
    await resize(tester, unfoldedUpright);
    expectTouchableList(tester, 'upright at the end');
  });

  for (final close in const ['Back', 'clear']) {
    testWidgets('a chat opened and closed ($close) unfolded, then upright: '
        'the list, nothing open', (tester) async {
      await pump(tester, unfolded);
      await settle(tester);
      await tester.tap(find.text('Firma del keystore en CI'));
      await settle(tester);
      expect(panes(tester).hasDetail, isTrue);
      if (close == 'Back') {
        await tester.binding.handlePopRoute();
      } else {
        panes(tester).clear();
      }
      await settle(tester);
      expect(probe('s-1'), findsNothing);
      expectTouchableList(tester, 'closed, unfolded');
      await resize(tester, unfoldedUpright);
      expectTouchableList(tester, 'closed, upright');
      await resize(tester, cover);
      expectTouchableList(tester, 'closed, folded');
      await resize(tester, unfoldedUpright);
      expectTouchableList(tester, 'closed, upright again');
    });
  }
}
