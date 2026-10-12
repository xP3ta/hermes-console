// Floating header (E1) and dissolving bottom edge (B2), one test per pattern
// of screen. A converted list keeps its place and its size, so what must
// hold everywhere is: at rest the first row starts below the header, a row
// scrolled past the list's edge is still there under the header, and the
// last row can be reached and rests clear of whatever floats at the bottom.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/screens/voice_guide_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/form_page.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _rows = 40;

List<Widget> _fill() => [
  for (var i = 0; i < _rows; i++) SizedBox(height: 56, child: Text('Fila $i')),
];

Widget _app(Widget home, {String themeId = 'classic-dark'}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId(themeId),
  home: home,
);

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.padding = const FakeViewPadding(top: 40 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 40 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

Clip _clipOf(WidgetTester tester, Finder scrollable) {
  final widget = tester.widget(scrollable);
  return switch (widget) {
    ScrollView(:final clipBehavior) => clipBehavior,
    SingleChildScrollView(:final clipBehavior) => clipBehavior,
    _ => throw StateError('not a scrollable: $widget'),
  };
}

/// The three things every converted page must keep.
Future<void> _expectUnderHeader(
  WidgetTester tester, {
  required Finder scrollable,
  double bottomLimit = 844,
}) async {
  final bar = tester.getRect(find.byType(AppBar));
  expect(bar.top, 0);
  // The header has no band: its bar is transparent.
  expect(
    tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
    Colors.transparent,
  );
  // 1 · At rest nothing is hidden under the header.
  expect(
    tester.getRect(find.text('Fila 0')).top,
    greaterThanOrEqualTo(bar.bottom),
  );
  // 2 · The list no longer cuts what it paints at its upper edge.
  expect(_clipOf(tester, scrollable), Clip.none);
  await tester.drag(scrollable, const Offset(0, -90));
  await tester.pump();
  final passed = tester.getRect(find.text('Fila 0', skipOffstage: false));
  expect(passed.top, lessThan(bar.bottom));
  expect(passed.bottom, greaterThan(0));
  // 3 · The last row is reachable and rests inside the page.
  await tester.drag(scrollable, const Offset(0, -6000));
  await tester.pumpAndSettle();
  final last = tester.getRect(find.text('Fila ${_rows - 1}'));
  expect(last.bottom, lessThanOrEqualTo(bottomLimit));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P3 · design-system scaffolds', () {
    testWidgets('HermesPage', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(HermesPage(title: 'Modelos locales', children: _fill())),
      );
      await _expectUnderHeader(tester, scrollable: find.byType(ListView));
    });

    testWidgets('HermesDetailScaffold: its title moves into the header pill', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(HermesDetailScaffold(title: 'Copia diaria', sections: _fill())),
      );
      const pill = ValueKey('hermes-app-bar-title');
      expect(find.byKey(pill), findsNothing, reason: 'the page shows it');
      await _expectUnderHeader(tester, scrollable: find.byType(ListView));
      expect(
        find.descendant(
          of: find.byKey(pill),
          matching: find.text('Copia diaria'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('HermesLogPage', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          HermesLogPage(
            title: 'Registro',
            text: [for (var i = 0; i < 400; i++) 'linea $i'].join('\n'),
          ),
        ),
      );
      final list = find.byKey(const ValueKey('hermes-log-page'));
      expect(_clipOf(tester, list), Clip.none);
      expect(
        tester.getRect(list).top,
        tester.getRect(find.byType(AppBar)).bottom,
      );
    });

    testWidgets('HermesFormPage: Guardar stays a button of its own', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          HermesFormPage(
            title: 'Nueva tarea',
            submitLabel: 'Guardar',
            onSubmit: () {},
            dirty: true,
            children: _fill(),
          ),
        ),
      );
      await _expectUnderHeader(
        tester,
        scrollable: find.byType(SingleChildScrollView),
      );
      final save = find.widgetWithText(FilledButton, 'Guardar');
      expect(save, findsOneWidget);
      expect(
        find.ancestor(of: save, matching: find.byType(AppBar)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('hermes-app-bar-actions')),
        findsNothing,
      );
    });
  });

  group('P2 · plain list pages', () {
    testWidgets('a real one (Guía de voz) at rest and scrolled', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const VoiceGuideScreen()));
      final bar = tester.getRect(find.byType(AppBar));
      final list = find.byType(ListView);
      expect(_clipOf(tester, list), Clip.none);
      expect(tester.getRect(list).top, bar.bottom);
      expect(
        find.byKey(const ValueKey('hermes-app-bar-title')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    test(
      'new settings pages inherit the page scaffold and its header scroll',
      () {
        for (final path in [
          'lib/core/screens/instance_edit_screen.dart',
          'lib/core/screens/dashboard_setup_screen.dart',
          'lib/core/screens/gateway_manager_screen.dart',
        ]) {
          expect(File(path).readAsStringSync(), contains('HermesPage('));
        }
        expect(
          File('lib/core/design/page.dart').readAsStringSync(),
          contains('clipBehavior: hermesUnderHeader'),
        );
      },
    );

    test('the first-run screens are not settings pages', () {
      // The first-run flow is its own full-bleed stage: no app bar, no list
      // rows, no page scaffold (the mockup's O2).
      for (final path in [
        'lib/core/screens/onboarding_screen.dart',
        'lib/core/screens/onboarding/onboarding_scanner.dart',
        'lib/core/screens/onboarding/onboarding_widgets.dart',
        'lib/core/screens/qr_scan_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        for (final forbidden in [
          'HermesPage(',
          'HermesAppBar',
          'HermesListRow',
          'HermesListGroup',
        ]) {
          expect(source, isNot(contains(forbidden)), reason: path);
        }
      }
    });

    test('every converted page still asks to scroll under the header', () {
      const pages = [
        'lib/core/design/page.dart',
        'lib/core/design/content.dart',
        'lib/core/design/schedule_builder.dart',
        'lib/core/widgets/form_page.dart',
        'lib/core/screens/appearance_screen.dart',
        'lib/core/screens/backup_restore_screen.dart',
        'lib/core/screens/bot_profile_settings_screen.dart',
        'lib/core/screens/chat_content_screen.dart',
        'lib/core/screens/credential_pool_screen.dart',
        'lib/core/screens/dock_settings_screen.dart',
        'lib/core/screens/embed_settings_screen.dart',
        'lib/core/screens/extensions_center_screen.dart',
        'lib/core/screens/external_provider_screen.dart',
        'lib/core/screens/foreign_session_import_screen.dart',
        'lib/core/screens/gesture_dock_settings_screen.dart',
        'lib/core/screens/guided_tours_screen.dart',
        'lib/core/screens/litert_store_screen.dart',
        'lib/core/screens/memory_entries_screen.dart',
        'lib/core/screens/moa_recipe_screen.dart',
        'lib/core/screens/models_api_keys_section.dart',
        'lib/core/screens/models_screen.dart',
        'lib/core/screens/notification_settings_screen.dart',
        'lib/core/screens/permissions_screen.dart',
        'lib/core/screens/projects_center_screen.dart',
        'lib/core/screens/recovery_center_screen.dart',
        'lib/core/screens/runs_screen.dart',
        'lib/core/screens/security_info_screen.dart',
        'lib/core/screens/session_branches_screen.dart',
        'lib/core/screens/settings_screen.dart',
        'lib/core/screens/ssh_credentials_screen.dart',
        'lib/core/screens/ssh_screen.dart',
        'lib/core/screens/subagent_detail_screen.dart',
        'lib/core/screens/task_center_screen.dart',
        'lib/core/screens/themes_screen.dart',
        'lib/core/screens/tools_hub_screen.dart',
        'lib/core/screens/voice_guide_screen.dart',
        'lib/core/screens/voice_settings_screen.dart',
      ];
      for (final path in pages) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('clipBehavior: hermesUnderHeader'),
          reason: path,
        );
        // One header for every page: none builds Material's own bar. (The
        // raw-text editor inside Ajustes is a full-screen editor, not a
        // page: it keeps its Cancel/Save bar.)
        if (path.endsWith('settings_screen.dart')) continue;
        expect(
          RegExp(r'appBar:\s*(const\s+)?AppBar\(').hasMatch(source),
          isFalse,
          reason: path,
        );
      }
    });
  });

  group('P1 · pages with the dock', () {
    final connection = SavedConnection(
      id: 'glass-dock',
      label: 'Dock QA',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-only',
    );
    const fade = ValueKey('dock-body-fade');
    const listKey = ValueKey('glass-list');

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async =>
                call.method == 'readAll' ? <String, String>{} : null,
          );
      FeatureFlags.instance.resetToDefaultForTesting();
      GestureDockController.instance.resetForTesting(
        settings: const GestureDockSettings(),
      );
      DockGeometry.instance.resetForTesting();
      DockModes.instance.resetForTesting();
    });
    tearDown(() async {
      FeatureFlags.instance.resetForTesting();
      await DockPreferencesController.instance.setUseDock(true);
    });

    Future<void> pumpDocked(WidgetTester tester) async {
      _phone(tester);
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        _app(
          Scaffold(
            appBar: const HermesAppBar(title: Text('Herramientas')),
            body: GeneralDockShell(
              connection: connection,
              connManager: manager,
              body: ListView(
                key: listKey,
                clipBehavior: hermesUnderHeader,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                children: _fill(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the list dissolves before the dock and nothing runs under it',
      (tester) async {
        await pumpDocked(tester);
        final dock = tester.getRect(
          find.byKey(const ValueKey('gesture-dock-pointer')),
        );
        final edge = tester.getRect(find.byKey(fade));
        final list = tester.getRect(find.byKey(listKey));
        expect(edge.height, HermesBottomFade.defaultExtent);
        expect(edge.bottom, list.bottom, reason: 'over the end of the list');
        expect(
          edge.bottom,
          lessThanOrEqualTo(dock.top),
          reason: 'above the dock',
        );
        // The body is cut at its lower edge (rows waiting below never show
        // behind the dock) and open upwards (they scroll under the header).
        expect(
          find.ancestor(
            of: find.byKey(listKey),
            matching: find.byType(HermesOpenTopClip),
          ),
          findsOneWidget,
        );
        final clip = tester.renderObject<RenderClipRect>(
          find
              .descendant(
                of: find.byType(HermesOpenTopClip),
                matching: find.byType(ClipRect),
              )
              .first,
        );
        final area = clip.clipper!.getClip(clip.size);
        expect(area.bottom, clip.size.height);
        expect(area.top, lessThan(-100));
        // The fade never takes a touch.
        expect(
          find.ancestor(
            of: find.byKey(fade),
            matching: find.byType(IgnorePointer),
          ),
          findsWidgets,
        );
        await _expectUnderHeader(
          tester,
          scrollable: find.byKey(listKey),
          // The last row rests above the dense half of the fade.
          bottomLimit: edge.bottom - HermesBottomFade.defaultExtent / 2,
        );
      },
    );

    testWidgets('a dock hidden by hand: its handle stays clear of the fade', (
      tester,
    ) async {
      await pumpDocked(tester);
      GestureDockController.instance.setHidden(true);
      await tester.pumpAndSettle();
      final handle = DockGeometry.instance.rect.value!;
      expect(DockGeometry.instance.hidden.value, isTrue);
      final edge = tester.getRect(find.byKey(fade));
      expect(edge.overlaps(handle), isFalse);
      expect(edge.bottom, lessThanOrEqualTo(handle.top));
    });

    testWidgets('with the dock off the list reaches the end of the screen', (
      tester,
    ) async {
      await DockPreferencesController.instance.setUseDock(false);
      await pumpDocked(tester);
      expect(find.byKey(fade), findsNothing);
      expect(find.byType(HermesOpenTopClip), findsNothing);
      expect(tester.getRect(find.byKey(listKey)).bottom, 844);
    });
  });

  group('P4 · pages with controls of their own', () {
    testWidgets('controls as the first rows: they leave with the list, and '
        'a field among them keeps the focus while its results change', (
      tester,
    ) async {
      _phone(tester);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var refreshes = 0;
      Widget page(bool hasRows) => _app(
        Scaffold(
          appBar: const HermesAppBar(title: Text('Conversaciones')),
          body: HermesControlsScroll(
            scrollKey: const ValueKey('scroll'),
            onRefresh: () async => refreshes++,
            controls: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  key: const ValueKey('search'),
                  controller: controller,
                ),
              ),
            ],
            slivers: [
              if (hasRows)
                HermesControlsScroll.children(
                  _fill(),
                  padding: const EdgeInsets.only(bottom: 24),
                )
              else
                HermesControlsScroll.fill(
                  const Center(child: Text('Sin resultados')),
                ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page(true));
      final scroll = find.byKey(const ValueKey('scroll'));
      final bar = tester.getRect(find.byType(AppBar));
      expect(_clipOf(tester, scroll), Clip.none);
      // At rest the field is the first thing below the header.
      final field = find.byKey(const ValueKey('search'));
      expect(tester.getRect(field).top, greaterThanOrEqualTo(bar.bottom));
      expect(
        tester.getRect(find.text('Fila 0')).top,
        greaterThan(tester.getRect(field).bottom),
      );

      // Typing down to nothing swaps the rows for a state; the field is the
      // same one and still has the focus.
      await tester.tap(field);
      await tester.pump();
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      expect(state.widget.focusNode.hasFocus, isTrue);
      await tester.pumpWidget(page(false));
      expect(find.text('Sin resultados'), findsOneWidget);
      expect(
        identical(
          tester.state<EditableTextState>(find.byType(EditableText)),
          state,
        ),
        isTrue,
      );
      expect(state.widget.focusNode.hasFocus, isTrue);
      // The state fills what the controls leave and can be pulled to refresh.
      expect(
        tester.getRect(find.text('Sin resultados')).center.dy,
        greaterThan(300),
      );
      await tester.drag(scroll, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(refreshes, 1);

      // With rows again: the controls scroll away with them.
      await tester.pumpWidget(page(true));
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pump();
      expect(
        tester
            .getRect(find.byKey(const ValueKey('search'), skipOffstage: false))
            .bottom,
        lessThan(bar.bottom),
      );
      await tester.drag(scroll, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('Fila ${_rows - 1}')).bottom,
        lessThanOrEqualTo(844),
      );
    });

    testWidgets('a floating view switch stays in place over the list', (
      tester,
    ) async {
      _phone(tester);
      var view = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            appBar: const HermesAppBar(title: Text('Tareas')),
            body: StatefulBuilder(
              builder: (context, setState) => HermesStickyControls(
                controls: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: HermesSegmentedControl<int>(
                        floating: true,
                        value: view,
                        onChanged: (v) => setState(() => view = v),
                        segments: const [
                          HermesSegment(value: 0, label: 'Lista'),
                          HermesSegment(value: 1, label: 'Tablero'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    HermesFloatingIconButton(
                      key: const ValueKey('filter'),
                      icon: Icons.filter_alt_outlined,
                      tooltip: 'Filtrar',
                      onPressed: () {},
                    ),
                  ],
                ),
                child: ListView(
                  key: const ValueKey('list'),
                  clipBehavior: hermesUnderHeader,
                  padding: const EdgeInsets.only(
                    top: HermesStickyControls.extent,
                  ),
                  children: _fill(),
                ),
              ),
            ),
          ),
        ),
      );
      final bar = tester.getRect(find.byType(AppBar));
      final pill = find.byKey(const ValueKey('hermes-segmented-floating'));
      expect(tester.widget(pill), isA<HermesFloatingSurface>());
      // A pill like every other floating piece, its selected half too.
      expect(
        tester.widget<HermesFloatingSurface>(pill).shape,
        isA<StadiumBorder>(),
      );
      final selected = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.text('Lista'),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(
        (selected.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(999),
      );
      final before = tester.getRect(pill);
      expect(before.top, greaterThanOrEqualTo(bar.bottom));
      expect(tester.getSize(find.byKey(const ValueKey('filter'))).height, 48);
      // At rest the first row is below the controls.
      expect(
        tester.getRect(find.text('Fila 0')).top,
        greaterThanOrEqualTo(bar.bottom + HermesStickyControls.extent),
      );
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -300),
      );
      await tester.pump();
      // The controls did not move, rows are behind them, and they still work.
      expect(tester.getRect(pill), before);
      await tester.tap(find.text('Tablero'));
      await tester.pump();
      expect(view, 1);
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -6000),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('Fila ${_rows - 1}')).bottom,
        lessThanOrEqualTo(844),
      );
    });

    test('each page of the pattern uses one of the two forms', () {
      const scroll = [
        'lib/core/screens/session_list_screen.dart',
        'lib/core/screens/activity_screen.dart',
      ];
      const sticky = [
        'lib/core/screens/tasks_screen.dart',
        'lib/core/screens/admin_integrations_screen.dart',
        'lib/core/screens/sftp_browser_screen.dart',
      ];
      const ownList = [
        'lib/core/screens/cron_screen.dart',
        'lib/core/screens/memory_screen.dart',
      ];
      for (final path in scroll) {
        expect(
          File(path).readAsStringSync(),
          contains('HermesControlsScroll('),
          reason: path,
        );
      }
      for (final path in sticky) {
        final source = File(path).readAsStringSync();
        expect(source, contains('HermesStickyControls('), reason: path);
        expect(source, contains('HermesStickyControls.extent'), reason: path);
      }
      for (final path in ownList) {
        expect(
          File(path).readAsStringSync(),
          contains('clipBehavior: hermesUnderHeader'),
          reason: path,
        );
      }
    });
  });

  group('P5 · pages with buttons at their lower edge', () {
    Widget page() => _app(
      Scaffold(
        appBar: const HermesAppBar(title: Text('Personalizar tema')),
        body: Column(
          children: [
            Expanded(
              child: HermesFadedEnd(
                child: ListView(
                  key: const ValueKey('list'),
                  clipBehavior: hermesUnderHeader,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    ..._fill(),
                    const TextField(key: ValueKey('last-field')),
                  ],
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 7, 16, 9),
                child: FilledButton(
                  key: const ValueKey('save'),
                  onPressed: () {},
                  child: const Text('Guardar'),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    testWidgets('the list dissolves before them and they are never over it', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(page());
      final list = tester.getRect(find.byKey(const ValueKey('list')));
      final save = tester.getRect(find.byKey(const ValueKey('save')));
      final edge = tester.getRect(find.byType(HermesBottomFade));
      expect(list.bottom, lessThanOrEqualTo(save.top));
      expect(edge.bottom, list.bottom);
      expect(edge.height, HermesBottomFade.defaultExtent);
      // No band behind the buttons: nothing but the page between them and
      // the scaffold.
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('save')),
          matching: find.byWidgetPredicate(
            (w) =>
                (w is ColoredBox) ||
                (w is DecoratedBox) ||
                (w is Container && (w.color != null || w.decoration != null)),
          ),
        ),
        findsNothing,
      );
      await _expectUnderHeader(
        tester,
        scrollable: find.byKey(const ValueKey('list')),
        bottomLimit: save.top,
      );
    });

    testWidgets('with the keyboard up they ride above it and the field '
        'being edited stays clear of them', (tester) async {
      _phone(tester);
      await tester.pumpWidget(page());
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -6000),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('last-field')));
      await tester.pump();
      // A 300 dp keyboard.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
      await tester.pumpAndSettle();
      final save = tester.getRect(find.byKey(const ValueKey('save')));
      final field = tester.getRect(find.byKey(const ValueKey('last-field')));
      expect(save.bottom, lessThanOrEqualTo(844 - 300));
      expect(field.bottom, lessThanOrEqualTo(save.top));
      expect(field.top, greaterThanOrEqualTo(0));
    });

    test('each page of the pattern ends its scroll with the fade', () {
      for (final path in const [
        'lib/core/design/content.dart',
        'lib/core/screens/theme_studio_screen.dart',
        'lib/core/screens/foreign_session_import_screen.dart',
        'lib/core/widgets/projects/project_files_browser.dart',
        'lib/core/screens/bot_create_screen.dart',
        'lib/core/screens/profile_editor_screen.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          contains('HermesFadedEnd('),
          reason: path,
        );
      }
    });

    test('the buttons of a bot and of a profile sit on the page, no line', () {
      for (final path in const [
        'lib/core/screens/bot_create_screen.dart',
        'lib/core/screens/profile_editor_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        final bar = source.substring(source.indexOf('Widget _buildFixed'));
        expect(
          bar.substring(0, bar.indexOf('Column(')),
          isNot(contains('BorderSide')),
          reason: path,
        );
      }
    });
  });

  testWidgets('the bottom fade is the page colour, clear at its top', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: HermesBottomFade(),
          ),
        ),
        themeId: 'classic',
      ),
    );
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(HermesBottomFade),
        matching: find.byType(DecoratedBox),
      ),
    );
    final gradient =
        (box.decoration as BoxDecoration).gradient! as LinearGradient;
    final page = AppTheme.fromId('classic').scaffoldBackgroundColor;
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors.last, page);
  });
}
