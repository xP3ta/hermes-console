import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_prompt_sheet.dart';

Widget _host({
  required List<String> previews,
  int? activeIndex,
  ValueChanged<int>? onSelect,
}) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: ChatPromptSheet(
      title: 'Prompts',
      emptyLabel: 'No prompts yet',
      previews: previews,
      activeIndex: activeIndex,
      onSelect: onSelect ?? (_) {},
    ),
  ),
);

void main() {
  testWidgets('lists the previews and reports the tapped index', (
    tester,
  ) async {
    int? tapped;
    await tester.pumpWidget(
      _host(previews: ['tres', 'dos', 'uno'], onSelect: (i) => tapped = i),
    );
    expect(find.text('Prompts'), findsOneWidget);
    expect(find.text('tres'), findsOneWidget);
    await tester.tap(find.text('dos'));
    expect(tapped, 1);
  });

  testWidgets('marks only the active entry as selected', (tester) async {
    await tester.pumpWidget(_host(previews: ['tres', 'dos'], activeIndex: 1));
    Tristate selectedOf(int index) => tester
        .getSemantics(find.byKey(ValueKey('chat-prompt-row-$index')))
        .flagsCollection
        .isSelected;
    expect(selectedOf(1), Tristate.isTrue);
    expect(selectedOf(0), isNot(Tristate.isTrue));
  });

  testWidgets('shows the empty note when there are no prompts', (tester) async {
    await tester.pumpWidget(_host(previews: const []));
    expect(
      find.byKey(const ValueKey('chat-prompt-sheet-empty')),
      findsOneWidget,
    );
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('builds only the visible rows of a long list', (tester) async {
    final previews = [for (var i = 0; i < 500; i++) 'prompt $i'];
    await tester.pumpWidget(_host(previews: previews));
    expect(find.byType(ListTile), findsNothing);
    expect(
      find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'chat-prompt-row-',
                ),
          )
          .evaluate()
          .length,
      lessThan(40),
    );
  });
}
