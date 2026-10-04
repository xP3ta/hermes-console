import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/session_branches_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Session _s(String id, {String? branchedFrom, double at = 1}) => Session(
  id: id,
  title: 'T-$id',
  model: 'm',
  source: 'mobile',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: at,
  updatedAt: at,
  branchedFromId: branchedFrom,
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

void main() {
  final rows = [
    _s('root', at: 1),
    _s('a', branchedFrom: 'root', at: 2),
    _s('b', branchedFrom: 'root', at: 3),
    _s('c', branchedFrom: 'a', at: 4),
    _s('lonely', at: 5),
  ];

  test('entry is offered only when the family has two or more rows', () {
    expect(SessionBranchesScreen.isAvailable(rows, 'c'), isTrue);
    expect(SessionBranchesScreen.isAvailable(rows, 'lonely'), isFalse);
    expect(SessionBranchesScreen.isAvailable(rows, 'missing'), isFalse);
  });

  test(
    'a lone row is still offered while more pages could reveal its family',
    () {
      expect(
        SessionBranchesScreen.isAvailable(rows, 'lonely', mayHaveMore: true),
        isTrue,
      );
      expect(
        SessionBranchesScreen.isAvailable(rows, 'lonely', mayHaveMore: false),
        isFalse,
      );
      expect(
        SessionBranchesScreen.isAvailable(rows, 'missing', mayHaveMore: true),
        isFalse,
        reason: 'a row that is not loaded has nothing to extend',
      );
    },
  );

  testWidgets('lists the family in tree order with stems', (tester) async {
    await tester.pumpWidget(
      _app(
        SessionBranchesScreen(
          sessions: rows,
          currentId: 'c',
          titleOf: (s) => s.title,
          onOpen: (_) {},
        ),
      ),
    );
    expect(find.text('Branches'), findsOneWidget);
    expect(find.text('lonely'), findsNothing);
    final titles = ['T-root', 'T-b', 'T-a', 'T-c'];
    final ys = [
      for (final t in titles)
        tester.getTopLeft(find.textContaining(t).first).dy,
    ];
    expect(ys, [...ys]..sort());
    expect(find.text('├─ T-b'), findsOneWidget);
    expect(find.text('└─ T-a'), findsOneWidget);
    expect(find.text('   └─ T-c'), findsOneWidget);
  });

  testWidgets('tapping a row opens that session', (tester) async {
    Session? opened;
    await tester.pumpWidget(
      _app(
        SessionBranchesScreen(
          sessions: rows,
          currentId: 'c',
          titleOf: (s) => s.title,
          onOpen: (s) => opened = s,
        ),
      ),
    );
    await tester.tap(find.text('├─ T-b'));
    expect(opened?.id, 'b');
  });

  testWidgets('shows Load more only when a loader is given', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      _app(
        SessionBranchesScreen(
          sessions: rows,
          currentId: 'c',
          titleOf: (s) => s.title,
          onOpen: (_) {},
          onLoadMore: () async {
            loads++;
            return [...rows, _s('late', branchedFrom: 'root', at: 6)];
          },
        ),
      ),
    );
    expect(find.textContaining('T-late'), findsNothing);
    await tester.tap(find.text('Load more'));
    await tester.pump();
    expect(loads, 1);
    expect(find.textContaining('T-late'), findsOneWidget);
  });
}
