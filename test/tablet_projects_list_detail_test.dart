import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pj1215_fake_projects_gateway.dart';

// Projects on a tablet: in expanded windows the project list (360dp) and the
// open project side by side; selecting a project never pushes an app route.
// Medium windows show one at a time, phones keep the full-screen push.

final List<BuildContext> _launchContexts = [];
final GlobalKey<NavigatorState> _rootNavigator = GlobalKey<NavigatorState>();

class _CountingObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

const _pane = ValueKey('adaptive-detail-pane');
const _placeholder = ValueKey('projects-pane-placeholder');
const _detailPath = ValueKey('pj1215-detail-path');

ValueKey<String> _card(String id) => ValueKey('pj1215-card-$id');

Future<_CountingObserver> _pump(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final observer = _CountingObserver();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      navigatorKey: _rootNavigator,
      navigatorObservers: [observer],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-projects'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProjectsCenterScreen(
                    connection: SavedConnection(
                      id: 'tablet-projects',
                      label: 'Hermes QA',
                      host: '127.0.0.1',
                      port: 8642,
                      apiKey: 'k',
                    ),
                    connectionManager: manager,
                    gateway: Pj1215FakeProjectsGateway.sample(),
                    chatLauncher: (context, _) => _launchContexts.add(context),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-projects')));
  await tester.pumpAndSettle();
  observer.pushes = 0;
  return observer;
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

String? _openPath(WidgetTester tester) {
  final f = find.byKey(_detailPath);
  if (f.evaluate().isEmpty) return null;
  return tester.widget<SelectableText>(f).data;
}

void main() {
  setUp(PrivateRenderCaches.clearAll);
  setUp(_launchContexts.clear);

  testWidgets('phone 411x915: a project opens full screen as before', (
    tester,
  ) async {
    final observer = await _pump(tester, const Size(411, 915));
    expect(find.byKey(_pane), findsNothing);

    await tester.tap(find.byKey(_card('p_console')));
    await tester.pumpAndSettle();

    expect(observer.pushes, 1, reason: 'phone flow: an app route');
    expect(_openPath(tester), '/home/demo/code/hermes-console');
    expect(find.byKey(_card('p_console')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(1280, 800), Size(1024, 768)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$label: list (360dp) beside a placeholder', (tester) async {
      await _pump(tester, size);

      expect(find.byKey(_pane), findsOneWidget);
      expect(find.byKey(_placeholder), findsOneWidget);
      expect(find.byKey(_card('p_console')), findsOneWidget);
      final list = tester.getRect(find.byKey(_card('p_console')));
      final pane = tester.getRect(find.byKey(_pane));
      expect(list.right, lessThanOrEqualTo(pane.left));
      expect(pane.left - list.left, closeTo(360, 24));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label: selecting a project opens it in the pane, no push', (
      tester,
    ) async {
      final observer = await _pump(tester, size);

      await tester.tap(find.byKey(_card('p_console')));
      await tester.pumpAndSettle();

      expect(observer.pushes, 0);
      expect(_openPath(tester), '/home/demo/code/hermes-console');
      expect(
        find.descendant(
          of: find.byKey(_pane),
          matching: find.byKey(_detailPath),
        ),
        findsOneWidget,
      );
      expect(find.byKey(_card('p_console')), findsOneWidget, reason: 'list');
      expect(find.byKey(_placeholder), findsNothing);

      // Another project replaces it in place.
      await tester.tap(find.byKey(_card('p_notes')));
      await tester.pumpAndSettle();
      expect(observer.pushes, 0);
      expect(_openPath(tester), '/home/demo/notes/travel');
      expect(find.byKey(_detailPath), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label: Back closes the project, then leaves Projects', (
      tester,
    ) async {
      await _pump(tester, size);
      await tester.tap(find.byKey(_card('p_console')));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(_detailPath), findsNothing);
      expect(find.byKey(_placeholder), findsOneWidget);
      expect(find.byType(ProjectsCenterScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ProjectsCenterScreen), findsNothing);
    });
  }

  testWidgets('rotation 1280x800 -> 800x1280 -> back keeps the open project', (
    tester,
  ) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.byKey(_card('p_notes')));
    await tester.pumpAndSettle();

    await _resize(tester, const Size(800, 1280));
    expect(_openPath(tester), '/home/demo/notes/travel', reason: 'medium');
    expect(tester.takeException(), isNull);

    await _resize(tester, const Size(1280, 800));
    expect(_openPath(tester), '/home/demo/notes/travel');
    expect(find.byKey(_card('p_notes')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation 1024x768 -> 768x1024 keeps the open project', (
    tester,
  ) async {
    await _pump(tester, const Size(1024, 768));
    await tester.tap(find.byKey(_card('p_console')));
    await tester.pumpAndSettle();

    await _resize(tester, const Size(768, 1024));
    expect(_openPath(tester), '/home/demo/code/hermes-console');

    await _resize(tester, const Size(1024, 768));
    expect(_openPath(tester), '/home/demo/code/hermes-console');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chat started from a project in the pane opens on the app '
      'navigator, as on a phone', (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.byKey(_card('p_console')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pj1215-detail-new-chat')));
    await tester.pumpAndSettle();

    expect(_launchContexts, hasLength(1));
    expect(
      Navigator.of(_launchContexts.single),
      same(_rootNavigator.currentState),
    );
  });

  testWidgets('shrinking to a phone with a project open keeps it open full '
      'screen', (tester) async {
    final observer = await _pump(tester, const Size(1280, 800));
    await tester.tap(find.byKey(_card('p_notes')));
    await tester.pumpAndSettle();

    await _resize(tester, const Size(411, 915));
    expect(_openPath(tester), '/home/demo/notes/travel');
    expect(observer.pushes, 1, reason: 'continued with the phone flow');
    expect(tester.takeException(), isNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_card('p_notes')), findsOneWidget);
  });
}
