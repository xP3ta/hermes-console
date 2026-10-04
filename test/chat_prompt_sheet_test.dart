import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_prompt_sheet.dart';

Widget _host(
  ValueNotifier<ChatPromptSheetModel> model, {
  ValueChanged<int>? onSelect,
  VoidCallback? onMore,
}) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: ChatPromptSheet(
      title: 'Prompts',
      emptyLabel: 'No prompts yet',
      moreLabel: 'Load earlier',
      model: model,
      onSelect: onSelect ?? (_) {},
      onMore: onMore ?? () {},
    ),
  ),
);

ValueNotifier<ChatPromptSheetModel> _model(
  List<String> previews, {
  int? activeIndex,
  bool hasMore = false,
  bool loading = false,
}) => ValueNotifier(
  ChatPromptSheetModel(
    previews: previews,
    activeIndex: activeIndex,
    hasMore: hasMore,
    loading: loading,
  ),
);

void main() {
  testWidgets('lists the previews and reports the tapped index', (
    tester,
  ) async {
    int? tapped;
    await tester.pumpWidget(
      _host(_model(['tres', 'dos', 'uno']), onSelect: (i) => tapped = i),
    );
    expect(find.text('Prompts'), findsOneWidget);
    expect(find.text('tres'), findsOneWidget);
    await tester.tap(find.text('dos'));
    expect(tapped, 1);
  });

  testWidgets('marks only the active entry as selected', (tester) async {
    await tester.pumpWidget(_host(_model(['tres', 'dos'], activeIndex: 1)));
    Tristate selectedOf(int index) => tester
        .getSemantics(find.byKey(ValueKey('chat-prompt-row-$index')))
        .flagsCollection
        .isSelected;
    expect(selectedOf(1), Tristate.isTrue);
    expect(selectedOf(0), isNot(Tristate.isTrue));
  });

  testWidgets('shows the empty note when there are no prompts', (tester) async {
    await tester.pumpWidget(_host(_model(const [])));
    expect(
      find.byKey(const ValueKey('chat-prompt-sheet-empty')),
      findsOneWidget,
    );
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('builds only the visible rows of a long list', (tester) async {
    final previews = [for (var i = 0; i < 500; i++) 'prompt $i'];
    await tester.pumpWidget(_host(_model(previews)));
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

  testWidgets('the earlier-prompts row only shows when more can be read', (
    tester,
  ) async {
    var more = 0;
    final model = _model(['uno']);
    await tester.pumpWidget(_host(model, onMore: () => more++));
    expect(find.byKey(const ValueKey('chat-prompt-more')), findsNothing);

    model.value = ChatPromptSheetModel(previews: ['uno'], hasMore: true);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-prompt-more')));
    expect(more, 1);

    model.value = ChatPromptSheetModel(
      previews: ['uno'],
      hasMore: true,
      loading: true,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-prompt-more')), findsNothing);
    expect(
      find.byKey(const ValueKey('chat-prompt-loading')),
      findsOneWidget,
    );
  });

  testWidgets('a second tap before the next frame does not ask twice', (
    tester,
  ) async {
    var more = 0;
    final model = _model(['uno'], hasMore: true);
    await tester.pumpWidget(_host(model, onMore: () => more++));
    final row = find.byKey(const ValueKey('chat-prompt-more'));
    await tester.tap(row);
    await tester.tap(row);
    expect(more, 1);
  });

  testWidgets('the list follows model updates without rebuilding the sheet', (
    tester,
  ) async {
    final model = _model(['uno']);
    await tester.pumpWidget(_host(model));
    expect(find.text('dos'), findsNothing);
    model.value = ChatPromptSheetModel(previews: ['uno', 'dos']);
    await tester.pump();
    expect(find.text('dos'), findsOneWidget);
  });
}
