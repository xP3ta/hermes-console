import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/session_pull_requests.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_pull_request_row.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

PullRequestInfo _pr({
  String state = 'open',
  bool draft = false,
  String url = 'https://github.example.test/o/r/pull/7',
}) => PullRequestInfo(
  branch: 'feat/x',
  number: 7,
  state: state,
  draft: draft,
  title: 't',
  url: url,
);

Widget _app(
  Future<PullRequestInfo?> Function() load, {
  Future<void> Function(Uri)? openUrl,
}) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: SessionPullRequestRow(
      key: UniqueKey(),
      load: load,
      openUrl: openUrl,
      builder: (context, label, onTap) =>
          ListTile(title: Text(label), onTap: onTap),
    ),
  ),
);

void main() {
  testWidgets('nothing is drawn while loading or without a PR', (tester) async {
    final gate = Completer<PullRequestInfo?>();
    await tester.pumpWidget(_app(() => gate.future));
    expect(find.byType(ListTile), findsNothing);
    gate.complete(null);
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a failing read draws nothing', (tester) async {
    await tester.pumpWidget(_app(() async => throw StateError('x')));
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('shows number and state for every bucket', (tester) async {
    for (final (pr, text) in [
      (_pr(), 'PR #7 · open'),
      (_pr(draft: true), 'PR #7 · draft'),
      (_pr(state: 'merged'), 'PR #7 · merged'),
      (_pr(state: 'closed'), 'PR #7 · closed'),
    ]) {
      await tester.pumpWidget(_app(() async => pr));
      await tester.pump();
      expect(find.text(text), findsOneWidget);
    }
  });

  testWidgets('tap opens only https links', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      _app(() async => _pr(), openUrl: (u) async => opened.add(u)),
    );
    await tester.pump();
    await tester.tap(find.byType(ListTile));
    expect(opened.single.scheme, 'https');

    opened.clear();
    await tester.pumpWidget(
      _app(
        () async => _pr(url: 'http://github.example.test/x'),
        openUrl: (u) async => opened.add(u),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(ListTile));
    expect(opened, isEmpty);
  });
}
