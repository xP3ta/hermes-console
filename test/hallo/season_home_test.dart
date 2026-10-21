import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/onboarding/halloween.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/app_header_title.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart'
    show DashboardAuthCheck;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/design_shots.dart';
import '../support/onboarding_fakes.dart';

class _Client extends ApiClient {
  _Client()
    : super(
        baseUrl: 'https://fixture.invalid:8642',
        apiKey: 'synthetic',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );
  @override
  Future<bool> healthCheck() async => true;
  @override
  Future<bool> healthReachable() async => true;
  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => <Session>[];
}

Future<void> pumpHome(
  WidgetTester tester,
  DateTime day, {
  Size size = const Size(390, 844),
  double scale = 1,
  String theme = 'dark',
  Key? root,
}) async {
  addTearDown(() => seasonClock = DateTime.now);
  seasonClock = () => day;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final manager = await onboardingManager();
  final connection = fakeFullPairing.toDraftConnection().copyWith(
    id: 'synthetic-season-home',
  );
  await manager.upsertConnection(connection);
  await manager.setActiveConnection(connection.id);
  await tester.pumpWidget(
    RepaintBoundary(
      key: root,
      child: onboardingHost(
        HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => _Client(),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          eventStreamOverride: const Stream.empty(),
          cronJobsLoader: (_, _) async => const [],
          tasksLoader: (_) async => const KanbanBoard(columns: []),
          serverInfoLoader: (_) async => (version: null, update: false),
          limitsLoader: (_) async => null,
        ),
        theme: theme,
        scale: scale,
      ),
    ),
  );
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const markKey = ValueKey('home-header-mark');

void main() {
  tearDown(() => headerTitleNotifier.value = kDefaultHeaderTitle);

  Future<(Rect, Season)> look(WidgetTester tester, DateTime day) async {
    await loadDesignFonts();
    await pumpHome(tester, day);
    final paint = find.descendant(
      of: find.byKey(markKey),
      matching: find.byKey(const ValueKey('console-mark')),
    );
    final p = tester.widget<CustomPaint>(paint).painter! as ConsoleMarkPainter;
    final rect = tester.getRect(paint);
    await tester.pumpWidget(const SizedBox.shrink());
    return (rect, p.season);
  }

  testWidgets('Home: the plain logo in July, the pumpkin, then Rudolph', (
    tester,
  ) async {
    final july = await look(tester, DateTime(2026, 7, 1));
    final hallo = await look(tester, DateTime(2026, 10, 31));
    final xmas = await look(tester, DateTime(2026, 12, 25));
    expect(july.$2, Season.none);
    expect(hallo.$2, Season.halloween);
    expect(xmas.$2, Season.christmas);
    expect(july.$1, hallo.$1);
    expect(july.$1, xmas.$1);
    expect(july.$1.size, const Size(21, 21));
  });

  testWidgets(
    'Home: logo 8 dp left of the title, centred on it, no semantics',
    (tester) async {
      await loadDesignFonts();
      await pumpHome(tester, DateTime(2026, 7, 1));
      final logo = tester.getRect(find.byKey(markKey));
      final title = tester.getRect(
        find.byKey(const ValueKey('home-header-title')),
      );
      expect(title.left - logo.right, 8);
      expect((logo.center.dy - title.center.dy).abs(), lessThan(2));
      expect(
        find.descendant(
          of: find.byKey(markKey),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'Home 320 dp ${scale}x with a long title: ellipsis, logo kept',
      (tester) async {
        await loadDesignFonts();
        headerTitleNotifier.value = 'MESA DE OPERACIONES EUROPA Y ASIA';
        await pumpHome(
          tester,
          DateTime(2026, 10, 31),
          size: const Size(320, 640),
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        final logo = tester.getRect(find.byKey(markKey));
        final title = tester.getRect(
          find.byKey(const ValueKey('home-header-title')),
        );
        expect(logo.size, const Size(21, 21));
        expect(logo.right + 8, lessThanOrEqualTo(title.left));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
