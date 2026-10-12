import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/responsive.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';

// List-detail panes (Material 3 canonical layout) used by Chats, Projects
// and Settings on tablets:
//   compact  — the list alone; opening an item pushes a full-screen page.
//   medium   — one pane: the open item replaces the list; Back returns.
//   expanded — list (~360dp) on the left, the open item on the right.

const _listKey = ValueKey('ld-list');
const _paneKey = ValueKey('adaptive-detail-pane');

class _Page extends StatefulWidget {
  final String id;
  const _Page(this.id);
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final controller = TextEditingController();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('page ${widget.id}'),
        TextField(key: ValueKey('draft-${widget.id}'), controller: controller),
      ],
    ),
  );
}

Widget _app({List<NavigatorObserver> observers = const []}) => MaterialApp(
  navigatorObservers: observers,
  home: Scaffold(
    body: AdaptiveListDetail(
      placeholder: const Center(child: Text('Pick one')),
      list: Builder(
        builder: (context) => ListView(
          key: _listKey,
          children: [
            for (final id in ['a', 'b', for (var i = 0; i < 40; i++) 'n$i'])
              ListTile(
                key: ValueKey('row-$id'),
                title: Text('row $id'),
                onTap: () => pushInDetailPane<void>(
                  context,
                  MaterialPageRoute(builder: (_) => _Page(id)),
                ),
              ),
          ],
        ),
      ),
    ),
  ),
);

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('compact: rows push a full-screen page (phone unchanged)', (
    tester,
  ) async {
    await _size(tester, const Size(411, 915));
    await tester.pumpWidget(_app());
    expect(find.byKey(_paneKey), findsNothing);
    await tester.tap(find.byKey(const ValueKey('row-a')));
    await tester.pumpAndSettle();
    expect(find.text('page a'), findsOneWidget);
    expect(find.byKey(_listKey), findsNothing, reason: 'list is covered');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_listKey), findsOneWidget);
  });

  for (final size in const [Size(1024, 768), Size(1280, 800)]) {
    testWidgets('expanded ${size.width.toInt()}: list and detail side by '
        'side; selecting opens in the pane without a route push', (
      tester,
    ) async {
      await _size(tester, size);
      final pushes = <Route<dynamic>>[];
      await tester.pumpWidget(_app(observers: [_Recorder(pushes)]));
      await tester.pumpAndSettle();
      final rootPushes = pushes.length;
      expect(find.text('Pick one'), findsOneWidget);
      final list = tester.getRect(find.byKey(_listKey));
      expect(list.width, closeTo(Responsive.listPaneWidth, 1));

      await tester.tap(find.byKey(const ValueKey('row-a')));
      await tester.pumpAndSettle();
      expect(pushes.length, rootPushes, reason: 'no root route push');
      expect(find.byKey(_listKey), findsOneWidget);
      final page = find.text('page a');
      expect(page, findsOneWidget);
      expect(
        find.descendant(of: find.byKey(_paneKey), matching: page),
        findsOneWidget,
      );
      expect(tester.getRect(page).left, greaterThan(list.right));

      // Selecting another item replaces the pane content, no stacking.
      await tester.tap(find.byKey(const ValueKey('row-b')));
      await tester.pumpAndSettle();
      expect(find.text('page a'), findsNothing);
      expect(find.text('page b'), findsOneWidget);

      // Back closes the pane content before leaving the screen.
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(find.text('page b'), findsNothing);
      expect(find.text('Pick one'), findsOneWidget);
      expect(find.byKey(_listKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('medium: the open item replaces the list; Back returns', (
    tester,
  ) async {
    await _size(tester, const Size(700, 1000));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byKey(_listKey), findsOneWidget);
    expect(find.text('Pick one'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('row-a')));
    await tester.pumpAndSettle();
    expect(find.text('page a'), findsOneWidget);
    expect(find.byKey(_listKey), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_listKey), findsOneWidget);
    expect(find.text('page a'), findsNothing);
  });

  testWidgets('rotation keeps the open item, its draft and the list scroll', (
    tester,
  ) async {
    await _size(tester, const Size(1280, 800));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('draft-a')), 'half typed');
    final pageState = tester.state(find.byType(_Page));

    // Landscape -> portrait (medium) -> landscape.
    for (final size in const [Size(800, 1280), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('page a'), findsOneWidget);
      expect(tester.state(find.byType(_Page)), same(pageState));
      expect(find.text('half typed'), findsOneWidget);
    }
  });

  testWidgets('rotation keeps the list scroll position', (tester) async {
    await _size(tester, const Size(1280, 800));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(_listKey), const Offset(0, -300));
    await tester.pumpAndSettle();
    double offset() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(_listKey),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    final before = offset();
    expect(before, greaterThan(100));
    for (final size in const [Size(800, 1280), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(offset(), before);
    }
  });
}

class _Recorder extends NavigatorObserver {
  final List<Route<dynamic>> pushes;
  _Recorder(this.pushes);
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushes.add(route);
}
