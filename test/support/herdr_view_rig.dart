// Shared pieces of the Agents view tests: a memory store, the app shell, and
// a rig that wires a controller to the fake Herdr server.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/herdr_agents_screen.dart';
import 'package:hermes_android/core/services/herdr_agents.dart';
import 'package:hermes_android/core/services/herdr_harness.dart';
import 'package:hermes_android/core/services/herdr_session_files.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'fake_herdr_server.dart';

class MemoryHerdrStore implements HerdrAgentsStore {
  bool dismissed = false;
  final List<String> remembered = [];
  final List<String> pinned = [];
  String? kind;

  @override
  bool get hintDismissed => dismissed;

  @override
  Future<void> dismissHint() async => dismissed = true;

  @override
  List<String> get folders => remembered;

  @override
  Future<void> rememberFolder(String folder) async {
    remembered
      ..remove(folder)
      ..insert(0, folder);
  }

  @override
  List<String> get favorites => pinned;

  @override
  Future<void> toggleFavorite(String folder) async {
    if (!pinned.remove(folder)) pinned.add(folder);
  }

  @override
  String? get lastKind => kind;

  @override
  Future<void> setLastKind(String value) async => kind = value;
}

Widget herdrTestApp(
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
  Locale locale = const Locale('en'),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: home!,
  ),
  home: Scaffold(body: child),
);

class HerdrRig {
  HerdrRig(
    WidgetTester tester,
    this.server, {
    HerdrSessionFiles? sessionFiles,
  }) {
    controller = HerdrAgentsController(
      run: server.call,
      store: MemoryHerdrStore(),
      now: () => tester.binding.clock.now(),
      startRetry: Duration.zero,
      detector: HerdrHarnessDetector(),
      sessionFiles: sessionFiles,
    );
  }

  final FakeHerdrServer server;
  late final HerdrAgentsController controller;

  /// Lines the view asked to type into a terminal.
  final List<String> typed = [];

  Widget view() => HerdrAgentsView(
    controller: controller,
    server: 'Demo server',
    onOpenTerminal: (line) async => typed.add(line),
  );
}

/// Opens the section on [server]. The first reads (list, then one screen
/// per agent) are done when it returns.
Future<HerdrRig> openHerdr(
  WidgetTester tester,
  FakeHerdrServer server, {
  ThemeData? theme,
  double textScale = 1,
  Locale locale = const Locale('en'),
  Size size = const Size(420, 900),
  HerdrSessionFiles? sessionFiles,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rig = HerdrRig(tester, server, sessionFiles: sessionFiles);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    rig.controller.dispose();
  });
  await tester.pumpWidget(
    herdrTestApp(
      rig.view(),
      theme: theme,
      textScale: textScale,
      locale: locale,
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
  return rig;
}

/// Opens the agent of [paneId] in the section and lets its first reads land.
Future<void> openAgent(WidgetTester tester, HerdrRig rig, String paneId) async {
  rig.controller.openDetail(paneId);
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}
