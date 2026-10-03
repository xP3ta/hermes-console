import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Connection whose roster the cross-screen roster tests share.
final connection = SavedConnection(
  id: 'roster',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
  useHttps: true,
);

String roster(List<String> names) => jsonEncode({
  'profiles': [
    for (final name in names) {'name': name, 'is_default': name == 'default'},
  ],
});

/// Dashboard fake: each `GET /api/profiles` takes the next queued answer
/// (a pending completer lets a test hold a read on the wire).
final class FakeProfilesServer {
  final reads = <Completer<String>>[];
  int mutations = 0;
  late final DashboardClient client = DashboardClient(
    host: 'hermes.local',
    manualToken: 'token',
    httpClientOverride: MockClient((request) async {
      if (request.url.path == '/api/profiles' && request.method == 'GET') {
        final answer = Completer<String>();
        reads.add(answer);
        return http.Response(await answer.future, 200);
      }
      if (request.url.path.startsWith('/api/profiles/') &&
          (request.method == 'PATCH' || request.method == 'DELETE')) {
        mutations++;
        return http.Response('{}', 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<ConnectionManager> manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

/// Screens side by side under one app, each findable through [inPane].
Widget panes(List<(String, Widget)> children) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Row(
    children: [
      for (final (key, child) in children)
        Expanded(
          child: KeyedSubtree(key: ValueKey(key), child: child),
        ),
    ],
  ),
);

Finder inPane(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

void useWideView(WidgetTester tester) {
  tester.view.physicalSize = const Size(2400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Renames the [index]th profile through the Profiles screen in [pane] and
/// stops right after the server confirms (before its revalidation lands).
Future<void> renameOnProfilesScreen(
  WidgetTester tester,
  String pane,
  int index,
  String to,
) async {
  await tester.tap(inPane(pane, find.byTooltip('Rename')).at(index));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), to);
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pump();
  await tester.pump();
}
