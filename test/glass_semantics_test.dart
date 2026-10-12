// What a screen reader gets from a list that scrolls under the floating
// header: a row that is visually under the header is on screen, so it is a
// normal node (announced once, after the header, reachable); a row waiting
// below the page is still a hidden one that scrolling reveals, as before.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/edges.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/scroll_behavior.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';

List<Widget> _rows() => [
  for (var i = 0; i < 60; i++) SizedBox(height: 56, child: Text('Fila $i')),
];

/// Labels of the whole tree, in the order a screen reader walks it.
List<String> _spoken() {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node
        .debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder)
        .forEach(visit);
  }

  visit(
    RendererBinding
        .instance
        .renderViews
        .single
        .owner!
        .semanticsOwner!
        .rootSemanticsNode!,
  );
  return labels;
}

SemanticsNode _node(WidgetTester tester, String row) =>
    tester.getSemantics(find.text(row, skipOffstage: false));

void main() {
  testWidgets('a row under the floating header is said once, after the '
      'header, and is not a hidden node', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const MomentumScrollBehavior(),
        theme: AppTheme.fromId('classic-dark'),
        home: Scaffold(
          appBar: const HermesAppBar(title: Text('Voz')),
          body: ListView(clipBehavior: hermesUnderHeader, children: _rows()),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -90));
    await tester.pump();

    // "Fila 0" is past the list's edge, under the header, still on screen.
    final bar = tester.getRect(find.byType(AppBar));
    final under = tester.getRect(find.text('Fila 0', skipOffstage: false));
    expect(under.bottom, lessThan(bar.bottom));
    expect(under.bottom, greaterThan(0));

    final spoken = _spoken();
    for (final row in const ['Fila 0', 'Fila 1', 'Fila 5']) {
      expect(spoken.where((l) => l == row), hasLength(1), reason: row);
    }
    // Header first, then the rows from the top down.
    expect(spoken.indexOf('Voz'), greaterThanOrEqualTo(0));
    expect(spoken.indexOf('Voz'), lessThan(spoken.indexOf('Fila 0')));
    expect(spoken.indexOf('Fila 0'), lessThan(spoken.indexOf('Fila 1')));
    expect(spoken.indexOf('Fila 1'), lessThan(spoken.indexOf('Fila 5')));

    // On screen, so not hidden; its rect is what is on screen of it.
    expect(_node(tester, 'Fila 0').flagsCollection.isHidden, isFalse);
    expect(_node(tester, 'Fila 5').flagsCollection.isHidden, isFalse);

    // Scrolled further, a row that is past the top of the screen itself is
    // hidden again: only what the header covers stays in sight.
    await tester.drag(find.byType(ListView), const Offset(0, -150));
    await tester.pump();
    final gone = tester.getRect(find.text('Fila 0', skipOffstage: false));
    expect(gone.bottom, lessThan(0));
    expect(_node(tester, 'Fila 0').flagsCollection.isHidden, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await tester.pump();

    // A row waiting below the screen is still there for the reader, hidden
    // until scrolled to.
    final below = tester.getRect(find.text('Fila 13', skipOffstage: false));
    expect(below.top, greaterThan(600));
    expect(_node(tester, 'Fila 13').flagsCollection.isHidden, isTrue);
    expect(spoken.where((l) => l == 'Fila 13'), hasLength(1));
    handle.dispose();
  });

  testWidgets('a page that ends above something floating hides the rows '
      'below its edge, not the ones under the header', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const MomentumScrollBehavior(),
        theme: AppTheme.fromId('classic-dark'),
        home: Scaffold(
          appBar: const HermesAppBar(title: Text('Herramientas')),
          body: Padding(
            // What a dock leaves free.
            padding: const EdgeInsets.only(bottom: 100),
            child: HermesOpenTopClip(
              child: ListView(
                clipBehavior: hermesUnderHeader,
                children: _rows(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -90));
    await tester.pump();
    expect(_node(tester, 'Fila 0').flagsCollection.isHidden, isFalse);
    // 600 high, 100 kept free: the page ends at 500. This row is below it.
    final cut = tester.getRect(find.text('Fila 10', skipOffstage: false));
    expect(cut.top, greaterThanOrEqualTo(500));
    expect(_node(tester, 'Fila 10').flagsCollection.isHidden, isTrue);
    handle.dispose();
  });
}
