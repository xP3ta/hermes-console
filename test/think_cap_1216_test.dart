// think1216: the model's thinking in the chat stops at a height of its own and
// scrolls inside, so a very long thought no longer fills the screen. A short
// one keeps the height it has always had, and the chat never feels the scroll.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/compact_markdown.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The quote adds 4 + 4 of vertical padding around the capped box.
const double _pad = 8;

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
              child: TurnReasoningQuote(text: _long(120), live: live),
            ),
          ),
        );
        await tester.pump();
        // 35% of 800 is 280, inside the 160..320 band.
        expect(tester.getSize(_quote).height, 280 + _pad);
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
              child: TurnReasoningQuote(text: text, live: live),
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
              child: TurnReasoningQuote(text: text, live: live),
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
              child: TurnReasoningQuote(text: 'Short thought.', live: live),
            ),
          ),
        );
        await tester.pump();
        expect(_inner, findsOneWidget);
        expect(_innerPosition(tester).maxScrollExtent, 0);
      });
    });
  }

  testWidgets('the cap follows the keyboard and never passes 320', (
    tester,
  ) async {
    final text = _long(200);
    _screen(tester, w: 1200, h: 2000);
    await tester.pumpWidget(
      _app(SingleChildScrollView(child: TurnReasoningQuote(text: text))),
    );
    await tester.pump();
    expect(tester.getSize(_quote).height, 320 + _pad);

    _screen(tester);
    Widget withKeyboard(double bottom) => _app(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: EdgeInsets.only(bottom: bottom)),
          child: SingleChildScrollView(child: TurnReasoningQuote(text: text)),
        ),
      ),
    );
    await tester.pumpWidget(withKeyboard(300));
    await tester.pump();
    // (800 - 300) * 0.35 = 175.
    expect(tester.getSize(_quote).height, 175 + _pad);
    await tester.pumpWidget(withKeyboard(700));
    await tester.pump();
    expect(tester.getSize(_quote).height, 160 + _pad);
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
                TurnReasoningQuote(text: text, live: true),
                const SizedBox(height: 3000),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
    outer.jumpTo(100);
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
    expect(outer.offset, 100);

    // The reader scrolls up inside the thought: the stream stops following.
    await tester.drag(_quote, const Offset(0, 120));
    await tester.pump();
    inner = _innerPosition(tester);
    final held = inner.pixels;
    expect(held, lessThan(inner.maxScrollExtent));
    await stream(6, 12);
    inner = _innerPosition(tester);
    expect(inner.pixels, held);
    expect(outer.offset, 100);

    // Back at the end, it follows again.
    await tester.drag(_quote, const Offset(0, -5000));
    await tester.pump();
    await stream(12, 15);
    inner = _innerPosition(tester);
    expect(inner.pixels, inner.maxScrollExtent);
    expect(outer.offset, 100);
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
            child: TurnReasoningQuote(text: _long(120)),
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
