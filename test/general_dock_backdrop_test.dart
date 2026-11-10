import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'dock-backdrop',
  label: 'Dock backdrop QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

Widget _app(Widget home, {String theme = 'classic-dark'}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId(theme),
  home: home,
);

Widget _shell(
  ConnectionManager manager, {
  String theme = 'classic-dark',
  GlobalKey<_DraftListState>? draft,
}) => _app(
  Scaffold(
    body: GeneralDockShell(
      connection: _connection,
      connManager: manager,
      bodyBuilder: (_, clearance) => draft == null
          ? ListView(
              key: const ValueKey('backdrop-list'),
              padding: EdgeInsets.fromLTRB(16, 16, 16, 28 + clearance),
              children: [
                for (var i = 0; i < 30; i++)
                  SizedBox(
                    key: ValueKey('backdrop-row-$i'),
                    height: 64,
                    child: ColoredBox(
                      color: i.isEven ? Colors.red : Colors.blue,
                      child: Text('Fila $i'),
                    ),
                  ),
              ],
            )
          : _DraftList(key: draft, clearance: clearance),
    ),
  ),
  theme: theme,
);

void _phone(WidgetTester tester, {double safeBottom = 34}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.padding = FakeViewPadding(bottom: safeBottom);
  tester.view.viewPadding = FakeViewPadding(bottom: safeBottom);
  addTearDown(tester.view.reset);
}

Finder _bar(bool gesture) => find.byKey(
  ValueKey(gesture ? 'gesture-dock-pointer' : 'general-mode-floating-dock'),
);

Future<ConnectionManager> _manager() async =>
    ConnectionManager.create(await SharedPreferences.getInstance());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final prefs = DockPreferencesController.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(
        tabs: GestureDockTab.legacyDefaultLayout,
      ),
    );
    DockGeometry.instance.resetForTesting();
    await prefs.ensureLoaded();
    await prefs.setUseDock(true);
  });
  tearDown(() async {
    FeatureFlags.instance.resetForTesting();
    await prefs.setUseDock(true);
  });

  for (final gesture in [true, false]) {
    for (final safeBottom in [0.0, 34.0]) {
      for (final theme in ['classic-dark', 'console-light']) {
        testWidgets('real content crosses behind the single dock; last row '
            'stays clear: gesture=$gesture safe=$safeBottom $theme', (
          tester,
        ) async {
          FeatureFlags.instance.resetForTesting(gestureDock: gesture);
          _phone(tester, safeBottom: safeBottom);
          await tester.pumpWidget(_shell(await _manager(), theme: theme));
          await tester.pumpAndSettle();
          final list = find.byKey(const ValueKey('backdrop-list'));
          final viewport = tester.getRect(list);
          final bar = tester.getRect(_bar(gesture));
          final page = tester.getRect(find.byType(Scaffold));
          expect(_bar(gesture), findsOneWidget);
          expect(viewport.bottom, page.bottom);
          expect(viewport.contains(bar.center), isTrue);

          await tester.drag(list, const Offset(0, -600));
          await tester.pumpAndSettle();
          final paintedRows = <Rect>[
            for (var i = 0; i < 30; i++)
              if (find.byKey(ValueKey('backdrop-row-$i')).evaluate().isNotEmpty)
                tester.getRect(find.byKey(ValueKey('backdrop-row-$i'))),
          ];
          expect(
            paintedRows.any((rect) => rect.contains(bar.center)),
            isTrue,
            reason: 'a real row occupies the backdrop, outside the bottom fade',
          );

          await tester.drag(list, const Offset(0, -10000));
          await tester.pumpAndSettle();
          final last = tester.getRect(
            find.byKey(const ValueKey('backdrop-row-29')),
          );
          expect(last.bottom, lessThan(bar.top));
          expect(bar.top - last.bottom, closeTo(28 + 8, .5));
          expect(tester.getRect(list), viewport);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('dock off removes its scroll reserve without remounting a draft; '
      'rotation keeps focus, selection and scroll', (tester) async {
    _phone(tester);
    final key = GlobalKey<_DraftListState>();
    await tester.pumpWidget(_shell(await _manager(), draft: key));
    await tester.pumpAndSettle();
    final state = key.currentState!;
    state.text.value = const TextEditingValue(
      text: 'SSH draft kept',
      selection: TextSelection(baseOffset: 2, extentOffset: 8),
    );
    state.focus.requestFocus();
    await tester.pump();
    state.scroll.jumpTo(280);
    await tester.pump();
    final offset = state.scroll.offset;
    for (final width in [933.0, 390.0]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pump();
      expect(key.currentState, same(state));
      expect(state.focus.hasFocus, isTrue);
      expect(state.text.text, 'SSH draft kept');
      expect(
        state.text.selection,
        const TextSelection(baseOffset: 2, extentOffset: 8),
      );
      expect(state.scroll.offset, offset);
    }
    await prefs.setUseDock(false);
    await tester.pump();
    expect(key.currentState, same(state));
    expect(state.focus.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('gesture-dock-pointer')), findsNothing);
    expect(state.widget.clearance, 0);
    debugPrint(
      'dock-end before: pixels=${state.scroll.position.pixels} '
      'min=${state.scroll.position.minScrollExtent} '
      'max=${state.scroll.position.maxScrollExtent} '
      'viewport=${state.scroll.position.viewportDimension}',
    );
    await tester.drag(
      find.byKey(const ValueKey('draft-list')),
      const Offset(0, -10000),
    );
    await tester.pumpAndSettle();
    final resolvedMax = state.scroll.position.maxScrollExtent;
    final remaining = resolvedMax - state.scroll.position.pixels;
    debugPrint(
      'dock-end resolved: pixels=${state.scroll.position.pixels} '
      'max=$resolvedMax remaining=$remaining',
    );
    // Laying out the last children resolves the sliver's estimated extent.
    // One further real drag reaches that measured end; no retry loop.
    if (remaining > 0) {
      await tester.drag(
        find.byKey(const ValueKey('draft-list')),
        Offset(0, -(remaining + 64)),
      );
      await tester.pumpAndSettle();
    }
    expect(state.scroll.position.maxScrollExtent, resolvedMax);
    expect(state.scroll.position.pixels, closeTo(resolvedMax, .5));
    final last = tester.getRect(find.byKey(const ValueKey('draft-last')));
    final viewport = tester.getRect(find.byKey(const ValueKey('draft-list')));
    debugPrint(
      'dock-end after: pixels=${state.scroll.position.pixels} '
      'min=${state.scroll.position.minScrollExtent} '
      'max=${state.scroll.position.maxScrollExtent} '
      'viewport=${state.scroll.position.viewportDimension} '
      'gap=${viewport.bottom - last.bottom}',
    );
    expect(viewport.bottom - last.bottom, closeTo(28, .5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(state.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Tools uses the full backdrop viewport and its last action stays '
      'reachable with Back returning to the same list', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ToolsHubScreen(
          connection: _connection,
          connManager: await _manager(),
          destinations: [
            for (var i = 0; i < 30; i++)
              HermesToolDestination(
                id: 'destination-$i',
                group: 'QA',
                icon: Icons.code,
                label: 'Destino $i',
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text('Página $i')),
                  body: Text('Contenido $i'),
                ),
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ToolsHubScreen));
    final list = find.byKey(const ValueKey('tools-hub-list'));
    final viewport = tester.getRect(list);
    expect(viewport.contains(tester.getCenter(_bar(true))), isTrue);
    await tester.drag(list, const Offset(0, -10000));
    await tester.pumpAndSettle();
    final last = find.text('Destino 29');
    expect(last.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(last).bottom,
      lessThan(tester.getRect(_bar(true)).top),
    );
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(find.text('Contenido 29'), findsOneWidget);
    final backTooltip = MaterialLocalizations.of(
      tester.element(find.text('Contenido 29')),
    ).backButtonTooltip;
    final back = find.byTooltip(backTooltip);
    expect(back, findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ToolsHubScreen)), same(state));
    expect(last.hitTestable(), findsOneWidget);
    expect(tester.getRect(list), viewport);
    expect(tester.takeException(), isNull);
  });
}

class _DraftList extends StatefulWidget {
  const _DraftList({required this.clearance, super.key});
  final double clearance;

  @override
  State<_DraftList> createState() => _DraftListState();
}

class _DraftListState extends State<_DraftList> {
  final text = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    text.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    key: const ValueKey('draft-list'),
    controller: scroll,
    padding: EdgeInsets.only(bottom: 28 + widget.clearance),
    children: [
      TextField(controller: text, focusNode: focus),
      for (var i = 0; i < 29; i++) SizedBox(height: 64, child: Text('Fila $i')),
      const SizedBox(
        key: ValueKey('draft-last'),
        height: 64,
        child: Text('Final'),
      ),
    ],
  );
}
