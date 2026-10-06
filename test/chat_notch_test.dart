import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Chat notch (owner design, GUIA-CHAT §5 and §9): a small glass tab above the
// composer opens "Ajustes de esta conversación" with "Ir a" on top. These are
// the widget-level contracts; the chat integration lives in
// chat_screen_test.dart (group "chat notch").

Widget _host(
  Widget child, {
  bool reduceMotion = false,
  ThemeData? theme,
  double textScale = 1,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: Scaffold(body: child),
);

Widget _notch({
  bool open = false,
  bool attention = false,
  VoidCallback? onOpen,
  VoidCallback? onOpenGoTo,
  VoidCallback? onFindInChat,
  VoidCallback? onPreviousChat,
  VoidCallback? onNextChat,
  bool horizontalSwipeEnabled = true,
}) => Align(
  alignment: Alignment.bottomCenter,
  child: ChatNotch(
    open: open,
    attention: attention,
    semanticLabel: 'Ajustes de la conversación e Ir a',
    attentionLabel: 'Algo te necesita en otra conversación',
    onOpen: onOpen ?? () {},
    onOpenGoTo: onOpenGoTo,
    onFindInChat: onFindInChat,
    onPreviousChat: onPreviousChat,
    onNextChat: onNextChat,
    horizontalSwipeEnabled: horizontalSwipeEnabled,
    gestureLabels: const ChatNotchGestureLabels(
      goTo: 'Ir a',
      findInChat: 'Buscar en este chat',
      previousChat: 'Chat anterior',
      nextChat: 'Chat siguiente',
    ),
  ),
);

double _tabDy(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const ValueKey('chat-notch-tab'))).dy;

Color? _tabColor(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byKey(const ValueKey('chat-notch-tab')),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  return (box.decoration as BoxDecoration).color;
}

void main() {
  group('ChatNotch', () {
    testWidgets('draws a 54x22 tab inside a 48 dp tall touch target', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_notch(), reduceMotion: true));
      expect(
        tester.getSize(find.byKey(const ValueKey('chat-notch-tab'))),
        const Size(kChatNotchWidth, kChatNotchHeight),
      );
      final target = tester.getSize(find.byKey(const ValueKey('chat-notch')));
      expect(target.height, greaterThanOrEqualTo(48));
      expect(target.width, greaterThanOrEqualTo(48));
      expect(kChatNotchWidth, 54);
      expect(kChatNotchHeight, 22);
    });

    testWidgets('is a labelled button and a tap opens', (tester) async {
      final semantics = tester.ensureSemantics();
      var opened = 0;
      await tester.pumpWidget(
        _host(_notch(onOpen: () => opened++), reduceMotion: true),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('chat-notch'))),
        matchesSemantics(
          label: 'Ajustes de la conversación e Ir a',
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('chat-notch')));
      await tester.pump();
      expect(opened, 1);
      semantics.dispose();
    });

    testWidgets('swipe up opens the sheet straight on Ir a', (tester) async {
      var goTo = 0;
      await tester.pumpWidget(
        _host(_notch(onOpenGoTo: () => goTo++), reduceMotion: true),
      );
      await tester.drag(
        find.byKey(const ValueKey('chat-notch')),
        const Offset(0, -40),
      );
      await tester.pump();
      expect(goTo, 1);
    });

    testWidgets('horizontal swipes change recent chats and never open', (
      tester,
    ) async {
      var previous = 0;
      var next = 0;
      var opened = 0;
      await tester.pumpWidget(
        _host(
          _notch(
            onOpen: () => opened++,
            onPreviousChat: () => previous++,
            onNextChat: () => next++,
          ),
          reduceMotion: true,
        ),
      );
      final notch = find.byKey(const ValueKey('chat-notch'));
      await tester.drag(notch, const Offset(40, 0));
      await tester.pump();
      await tester.drag(notch, const Offset(-40, 0));
      await tester.pump();
      expect(previous, 1);
      expect(next, 1);
      expect(opened, 0);
    });

    testWidgets(
      'long press opens in-chat search and semantics expose every gesture',
      (tester) async {
        final semantics = tester.ensureSemantics();
        var findCalls = 0;
        await tester.pumpWidget(
          _host(
            _notch(
              onFindInChat: () => findCalls++,
              onPreviousChat: () {},
              onNextChat: () {},
            ),
            reduceMotion: true,
          ),
        );
        await tester.longPress(find.byKey(const ValueKey('chat-notch')));
        await tester.pump();
        expect(findCalls, 1);
        expect(
          tester.getSemantics(find.byKey(const ValueKey('chat-notch'))),
          matchesSemantics(
            hasTapAction: true,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            customActions: <CustomSemanticsAction>[
              const CustomSemanticsAction(label: 'Ir a'),
              const CustomSemanticsAction(label: 'Buscar en este chat'),
              const CustomSemanticsAction(label: 'Chat anterior'),
              const CustomSemanticsAction(label: 'Chat siguiente'),
            ],
          ),
        );
        semantics.dispose();
      },
    );

    testWidgets(
      'edge gesture inset disables horizontal swipe but keeps tap and search',
      (tester) async {
        var previous = 0;
        var opened = 0;
        await tester.pumpWidget(
          _host(
            _notch(
              onOpen: () => opened++,
              onPreviousChat: () => previous++,
              horizontalSwipeEnabled: false,
            ),
            reduceMotion: true,
          ),
        );
        final notch = find.byKey(const ValueKey('chat-notch'));
        await tester.drag(notch, const Offset(40, 0));
        await tester.tap(notch);
        await tester.pump();
        expect(previous, 0);
        expect(opened, 1);
      },
    );

    testWidgets('a short drag up that starts on it opens once', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(_notch(onOpen: () => opened++), reduceMotion: true),
      );
      await tester.drag(
        find.byKey(const ValueKey('chat-notch')),
        const Offset(0, -40),
      );
      await tester.pump();
      expect(opened, 1);

      // A drag down on it is not an opening gesture.
      await tester.drag(
        find.byKey(const ValueKey('chat-notch')),
        const Offset(0, 40),
      );
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('breathes 2.5 px a few times, then rests (idle never ticks)', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_notch()));
      final rest = _tabDy(tester);
      var minDy = rest;
      for (var i = 0; i < 34; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final dy = _tabDy(tester);
        if (dy < minDy) minDy = dy;
      }
      expect(rest - minDy, closeTo(kChatNotchBreath, 0.15));
      expect(kChatNotchBreath, 2.5);
      // After its cycles it settles and stops scheduling frames.
      await tester.pump(kChatNotchBreathPeriod * (kChatNotchBreathCycles + 1));
      expect(_tabDy(tester), closeTo(rest, 0.01));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reduced motion keeps it static', (tester) async {
      await tester.pumpWidget(_host(_notch(), reduceMotion: true));
      final rest = _tabDy(tester);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(_tabDy(tester), rest);
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('open: accent tint and still; closed: neutral glass', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_notch(open: true)));
      final colors = AppTheme.hermesRedDark.hermes;
      final openColor = _tabColor(tester)!;
      expect(openColor.r, closeTo(colors.accent.r, 0.01));
      expect(openColor.g, closeTo(colors.accent.g, 0.01));
      expect(openColor.b, closeTo(colors.accent.b, 0.01));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-notch-tab')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.color, colors.accent);
      final rest = _tabDy(tester);
      await tester.pump(const Duration(milliseconds: 1700));
      expect(_tabDy(tester), rest);

      await tester.pumpWidget(_host(_notch(open: false), reduceMotion: true));
      final closedColor = _tabColor(tester)!;
      expect(closedColor, isNot(equals(openColor)));
      expect(closedColor.r, isNot(closeTo(colors.accent.r, 0.01)));
    });

    testWidgets('amber dot only when something needs you elsewhere', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(_notch(), reduceMotion: true));
      expect(find.byKey(const ValueKey('chat-notch-attention')), findsNothing);

      await tester.pumpWidget(
        _host(_notch(attention: true), reduceMotion: true),
      );
      final dot = find.byKey(const ValueKey('chat-notch-attention'));
      expect(dot, findsOneWidget);
      final decoration =
          tester.widget<DecoratedBox>(dot).decoration as BoxDecoration;
      expect(decoration.color, AppTheme.hermesRedDark.hermes.warning);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('chat-notch'))).label,
        contains('Algo te necesita en otra conversación'),
      );
      semantics.dispose();
    });
  });

  group('chatNotchHorizontalSwipeSafe', () {
    test('a phone with normal edge insets keeps the swipe', () {
      expect(
        chatNotchHorizontalSwipeSafe(
          const Size(400, 800),
          const EdgeInsets.symmetric(horizontal: 32),
        ),
        isTrue,
      );
      // Exactly touching the inset on both sides is still clear.
      expect(
        chatNotchHorizontalSwipeSafe(
          const Size(400, 800),
          const EdgeInsets.symmetric(horizontal: 164),
        ),
        isTrue,
      );
    });

    test('a target inside a system gesture inset disables the swipe', () {
      expect(
        chatNotchHorizontalSwipeSafe(
          const Size(400, 800),
          const EdgeInsets.only(left: 165),
        ),
        isFalse,
      );
      expect(
        chatNotchHorizontalSwipeSafe(
          const Size(400, 800),
          const EdgeInsets.only(right: 165),
        ),
        isFalse,
      );
      expect(
        chatNotchHorizontalSwipeSafe(
          const Size(80, 800),
          const EdgeInsets.symmetric(horizontal: 16),
        ),
        isFalse,
      );
    });
  });

  group('chatNotchNeedsYouElsewhere', () {
    GlobalActivity activity({
      String connection = 'c1',
      String session = 's-other',
      bool action = true,
      bool terminal = false,
      bool stale = false,
    }) => GlobalActivity(
      scope: GlobalActivityScope(
        connectionId: connection,
        profile: 'default',
        durableSessionId: session,
        runtimeSessionId: 'rt-$session',
        replayEpoch: 'e',
      ),
      phase: action
          ? GlobalActivityPhase.waitingForUser
          : GlobalActivityPhase.generating,
      terminal: terminal,
      requiresAction: action,
      toolCount: 0,
      subagentCount: 0,
      processCount: 0,
      observedAt: DateTime(2026, 10, 6),
      authority: GlobalActivityAuthority.roster,
      stale: stale,
    );

    bool needs(List<GlobalActivity> all) => chatNotchNeedsYouElsewhere(
      all,
      connectionId: 'c1',
      currentSessionIds: const {'s-here', 'stored-here'},
    );

    test('another chat waiting for the user lights it', () {
      expect(needs([activity()]), isTrue);
      expect(needs([activity(connection: 'c2', session: 's-here')]), isTrue);
    });

    test('this chat, finished, stale or busy-only work never light it', () {
      expect(needs(const []), isFalse);
      expect(needs([activity(session: 's-here')]), isFalse);
      expect(needs([activity(session: 'stored-here')]), isFalse);
      expect(needs([activity(action: false)]), isFalse);
      expect(needs([activity(terminal: true)]), isFalse);
      expect(needs([activity(stale: true)]), isFalse);
    });
  });

  group('showChatNotchSheet', () {
    Future<void> pumpOpener(
      WidgetTester tester, {
      bool reduceMotion = false,
      FocusNode? composer,
      List<Object?>? results,
    }) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Column(
              children: [
                const Expanded(child: SizedBox.expand()),
                TextButton(
                  key: const ValueKey('open-notch-sheet'),
                  onPressed: () async {
                    final result = await showChatNotchSheet<String>(
                      context: context,
                      builder: (_) => ListView(
                        shrinkWrap: true,
                        children: [
                          for (var i = 0; i < 4; i++)
                            SizedBox(
                              height: 60,
                              child: Text('row $i', key: ValueKey('row-$i')),
                            ),
                        ],
                      ),
                    );
                    results?.add(result);
                  },
                  child: const Text('open'),
                ),
                if (composer != null)
                  SizedBox(
                    height: 56,
                    child: TextField(
                      key: const ValueKey('composer'),
                      focusNode: composer,
                    ),
                  ),
              ],
            ),
          ),
          reduceMotion: reduceMotion,
        ),
      );
    }

    final sheet = find.byKey(const ValueKey('chat-control-dialog'));

    testWidgets('opens with a spring between 0.5 and 0.8 s from the notch', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.byKey(const ValueKey('open-notch-sheet')));
      await tester.pump();
      expect(sheet, findsOneWidget);
      expect(kChatNotchSheetOpen.inMilliseconds, inInclusiveRange(500, 800));
      expect(kChatNotchSheetClose.inMilliseconds, inInclusiveRange(240, 340));
      // Mid-flight it is still growing; it overshoots (spring) and lands.
      await tester.pump(const Duration(milliseconds: 60));
      final early = tester.getRect(sheet);
      final scales = <double>[];
      for (var t = 0; t < kChatNotchSheetOpen.inMilliseconds; t += 20) {
        await tester.pump(const Duration(milliseconds: 20));
        final transform = tester
            .widgetList<Transform>(
              find.ancestor(of: sheet, matching: find.byType(Transform)),
            )
            .first;
        scales.add(transform.transform.getMaxScaleOnAxis());
      }
      await tester.pumpAndSettle();
      final landed = tester.getRect(sheet);
      expect(early.width, lessThan(landed.width));
      expect(scales.reduce((a, b) => a > b ? a : b), greaterThan(1.0));
      // It sits at the bottom, above the gesture bar, like the mock's sheet.
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(landed.bottom, lessThanOrEqualTo(screen.height - 12));
      expect(landed.bottom, greaterThan(screen.height - 40));
    });

    testWidgets('reduced motion: no spring, appears and leaves at once', (
      tester,
    ) async {
      await pumpOpener(tester, reduceMotion: true);
      await tester.tap(find.byKey(const ValueKey('open-notch-sheet')));
      await tester.pump();
      await tester.pump();
      expect(sheet, findsOneWidget);
      // Already at rest on the first frame: full size, fully opaque.
      final transform = tester
          .widgetList<Transform>(
            find.ancestor(of: sheet, matching: find.byType(Transform)),
          )
          .first;
      expect(transform.transform.getMaxScaleOnAxis(), 1);
      final opacity = tester
          .widgetList<Opacity>(
            find.ancestor(of: sheet, matching: find.byType(Opacity)),
          )
          .first;
      expect(opacity.opacity, 1);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(sheet, findsNothing);
    });

    testWidgets('outside tap and system back close it', (tester) async {
      await pumpOpener(tester);
      await tester.tap(find.byKey(const ValueKey('open-notch-sheet')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 40));
      await tester.pump();
      await tester.pump(
        kChatNotchSheetClose + const Duration(milliseconds: 120),
      );
      await tester.pump();
      expect(sheet, findsNothing);

      await tester.tap(find.byKey(const ValueKey('open-notch-sheet')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(
        kChatNotchSheetClose + const Duration(milliseconds: 120),
      );
      await tester.pump();
      expect(sheet, findsNothing);
    });

    testWidgets('dragging it down more than 100 px closes; less springs back', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.byKey(const ValueKey('open-notch-sheet')));
      await tester.pumpAndSettle();
      final rest = tester.getRect(sheet);

      // Short, slow pull from the grabber: returns.
      final grabber = find.byKey(const ValueKey('chat-notch-sheet-grabber'));
      expect(grabber, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(grabber));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(tester.getRect(sheet).top, greaterThan(rest.top + 20));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      expect(tester.getRect(sheet).top, closeTo(rest.top, 0.5));

      // Past the threshold: closes.
      final far = await tester.startGesture(tester.getCenter(grabber));
      for (var i = 0; i < 14; i++) {
        await far.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await far.up();
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    });

    testWidgets('a fast flick down on the content closes it', (tester) async {
      await pumpOpener(tester);
      await tester.tap(find.byKey(const ValueKey('open-notch-sheet')));
      await tester.pumpAndSettle();
      await tester.fling(
        find.byKey(const ValueKey('row-0')),
        const Offset(0, 70),
        1200,
      );
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    });

    for (final keyboardVisible in [false, true]) {
      testWidgets('closing never reopens the keyboard '
          '(keyboard ${keyboardVisible ? 'open' : 'hidden'} when it opened)', (
        tester,
      ) async {
        final composer = FocusNode(debugLabel: 'composer');
        addTearDown(composer.dispose);
        await pumpOpener(tester, composer: composer, reduceMotion: true);
        tester.view.viewInsets = FakeViewPadding(
          bottom: keyboardVisible ? 600 : 0,
        );
        addTearDown(tester.view.resetViewInsets);
        await tester.tap(find.byKey(const ValueKey('composer')));
        await tester.pump();
        expect(composer.hasFocus, isTrue);

        await tester.tap(find.byKey(const ValueKey('open-notch-sheet')));
        await tester.pump();
        await tester.pump();
        tester.view.viewInsets = FakeViewPadding.zero;
        tester.testTextInput.log.clear();
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump();

        expect(sheet, findsNothing);
        expect(composer.hasFocus, isFalse);
        expect(
          tester.testTextInput.log.any(
            (MethodCall c) => c.method == 'TextInput.show',
          ),
          isFalse,
        );
      });
    }
  });
}
