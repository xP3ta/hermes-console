// think1216: the model's thinking in the chat stops at a height of its own and
// scrolls inside, so a very long thought no longer fills the screen. A short
// one keeps the height it has always had, and the chat never feels the scroll.
//
// Mock 137 A (the owner, 1.4.0) sets that height: the box a thought opens to is
// six lines, whatever the screen or the keyboard (it was 35 % of the screen,
// 160 to 320 dp). The whole thought, a second tap, has no cap.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/compact_markdown.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The quote adds 4 + 4 of vertical padding around the capped box.
const double _pad = 8;

// Six lines of the thought's text (mock 137 A).
const double _six =
    TurnType.reasoning *
    TurnReasoningQuote.lineHeight *
    ThinkingLine.previewLines;

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: home!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

String _long(int paragraphs) => [
  for (var i = 0; i < paragraphs; i++) 'Paragraph $i of the thought.',
].join('\n\n');

Finder get _quote => find.byKey(const ValueKey('turn-reasoning'));

Finder get _inner =>
    find.descendant(of: _quote, matching: find.byType(Scrollable));

ScrollPosition _innerPosition(WidgetTester tester) =>
    tester.state<ScrollableState>(_inner.first).position;

void _screen(WidgetTester tester, {double w = 400, double h = 800}) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  for (final live in [false, true]) {
    final name = live ? 'live' : 'finished';
    group('think1216 $name', () {
      testWidgets('a long thought stops at the cap and scrolls inside', (
        tester,
      ) async {
        _screen(tester);
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: TurnReasoningQuote(text: _long(120), live: live, lines: 6),
            ),
          ),
        );
        await tester.pump();
        expect(tester.getSize(_quote).height, closeTo(_six + _pad, 0.5));
        expect(_inner, findsOneWidget);
        expect(_innerPosition(tester).maxScrollExtent, greaterThan(0));
      });

      testWidgets('a short thought keeps the height it always had', (
        tester,
      ) async {
        _screen(tester);
        const text = 'Reading the config.\n\nThen the tests.';
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: TurnReasoningQuote(text: text, live: live, lines: 6),
            ),
          ),
        );
        await tester.pump();
        // The same body in the same box with no cap: 2 rule + 12 gap to the
        // start of the text, 4 above and below.
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 0, 4),
                child: CompactMarkdown(
                  data: text,
                  fontSize: TurnType.reasoning,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final reference = tester.getSize(find.byType(CompactMarkdown)).height;
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: TurnReasoningQuote(text: text, live: live, lines: 6),
            ),
          ),
        );
        await tester.pump();
        expect(tester.getSize(_quote).height, reference + _pad);
      });

      testWidgets('a short thought has nothing to scroll', (tester) async {
        _screen(tester);
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: TurnReasoningQuote(
                text: 'Short thought.',
                live: live,
                lines: 6,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(_inner, findsOneWidget);
        expect(_innerPosition(tester).maxScrollExtent, 0);
      });
    });
  }

  testWidgets('the cap is six lines whatever the screen or the keyboard', (
    tester,
  ) async {
    final text = _long(200);
    Widget quote({double keyboard = 0, double scale = 1}) => _app(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewInsets: EdgeInsets.only(bottom: keyboard),
            textScaler: TextScaler.linear(scale),
          ),
          child: SingleChildScrollView(
            child: TurnReasoningQuote(text: text, lines: 6),
          ),
        ),
      ),
    );
    _screen(tester, w: 1200, h: 2000);
    await tester.pumpWidget(quote());
    await tester.pump();
    expect(tester.getSize(_quote).height, closeTo(_six + _pad, 0.5));
    _screen(tester);
    await tester.pumpWidget(quote(keyboard: 300));
    await tester.pump();
    expect(tester.getSize(_quote).height, closeTo(_six + _pad, 0.5));
    // The six lines are lines of the reader's text size.
    await tester.pumpWidget(quote(scale: 2));
    await tester.pump();
    expect(tester.getSize(_quote).height, closeTo(_six * 2 + _pad, 0.5));
  });

  testWidgets('the whole thought has no cap and no box of its own', (
    tester,
  ) async {
    _screen(tester);
    await tester.pumpWidget(
      _app(SingleChildScrollView(child: TurnReasoningQuote(text: _long(40)))),
    );
    await tester.pump();
    expect(_inner, findsNothing);
    expect(tester.getSize(_quote).height, greaterThan(_six + _pad));
  });

  testWidgets('streaming follows the end inside and never moves the chat', (
    tester,
  ) async {
    _screen(tester);
    final outer = ScrollController();
    addTearDown(outer.dispose);
    var text = _long(60);
    late StateSetter set;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return ListView(
              reverse: true,
              controller: outer,
              children: [
                TurnReasoningQuote(text: text, live: true, lines: 6),
                const SizedBox(height: 3000),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
    // The chat is scrolled a little, with the thought still on screen
    // (gint48: at 100 the six-line box of mock 137 A, ~130 dp, had its
    // centre below the screen and the drags below missed it).
    const scrolled = 20.0;
    outer.jumpTo(scrolled);
    await tester.pump();

    Future<void> stream(int from, int to) async {
      for (var i = from; i < to; i++) {
        set(() => text = '$text\n\nStreamed delta $i.');
        await tester.pump();
      }
    }

    await stream(0, 6);
    var inner = _innerPosition(tester);
    expect(inner.maxScrollExtent, greaterThan(0));
    expect(inner.pixels, inner.maxScrollExtent);
    expect(outer.offset, scrolled);

    // The reader scrolls up inside the thought: the stream stops following.
    await tester.drag(_quote, const Offset(0, 120));
    await tester.pump();
    inner = _innerPosition(tester);
    final held = inner.pixels;
    expect(held, lessThan(inner.maxScrollExtent));
    await stream(6, 12);
    inner = _innerPosition(tester);
    expect(inner.pixels, held);
    expect(outer.offset, scrolled);

    // Back at the end, it follows again.
    await tester.drag(_quote, const Offset(0, -5000));
    await tester.pump();
    await stream(12, 15);
    inner = _innerPosition(tester);
    expect(inner.pixels, inner.maxScrollExtent);
    expect(outer.offset, scrolled);
  });

  testWidgets('a scroll inside the thought is not heard by the chat', (
    tester,
  ) async {
    _screen(tester);
    var heard = 0;
    await tester.pumpWidget(
      _app(
        NotificationListener<ScrollNotification>(
          onNotification: (_) {
            heard++;
            return false;
          },
          child: SingleChildScrollView(
            child: TurnReasoningQuote(text: _long(120), lines: 6),
          ),
        ),
      ),
    );
    await tester.pump();
    heard = 0;
    await tester.drag(_quote, const Offset(0, -150));
    await tester.pumpAndSettle();
    // The thought did scroll (it has a scrollable and it moved) ...
    expect(_innerPosition(tester).pixels, greaterThan(0));
    // ... and nothing of it reached the listener above.
    expect(heard, 0);
  });
}
