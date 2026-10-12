// Tareas › Tablero under the floating header (E1) and before the dock (B2).
//
// Every column of the board is a list of its own, drawn like a section of
// the Lista and nothing else: its name is the first row, plain, and its
// cards scroll under the floating Lista/Tablero switch and under the header
// exactly like the rows of the Lista; the last card ends clear of the fade
// before the dock. Sideways the board moves alone.
//
// PNGs are written only with `--dart-define=GLASS_SHOTS=<dir>`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/scroll_behavior.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart';
import 'support/pump_until_loaded.dart';

const _dir = String.fromEnvironment('GLASS_SHOTS');
const _shotKey = ValueKey('kanban-board-shot');
const _top = 36.0;
const _bottom = 24.0;

const _titles = [
  'Revisar el aviso de disco al 92 %',
  'Traducir la guía de voz',
  'Copia de seguridad del homelab',
  'Notas de la versión 1.2.15',
  'Probar el widget de Cron en tres tamaños',
  'Arreglar la selección de modelo de reserva',
  'Restaurar los errores localizados',
  'Entrada de RRHH del lunes',
  'Ordenar las plantillas de SOUL',
  'Comparar proveedores de memoria',
  'Limpiar ramas antiguas',
  'Preparar la demo del viernes',
];

const _statuses = ['blocked', 'running', 'todo', 'done'];

final _connection = SavedConnection(
  id: 'kanban-board-header',
  label: 'casa',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
  useHttps: true,
);

MockClient _client() => MockClient((request) async {
  final path = request.url.path;
  if (path == '/api/plugins/kanban/board') {
    return http.Response(
      jsonEncode({
        'columns': [
          for (final status in _statuses)
            {
              'name': status,
              'tasks': [
                for (var i = 0; i < _titles.length; i++)
                  {
                    'id': '$status-$i',
                    'title': _titles[(i + _statuses.indexOf(status) * 3) % 12],
                    'body': 'Nota $i',
                    'status': status,
                    'assignee': i.isEven ? 'ana' : 'infra',
                  },
              ],
            },
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  if (path == '/api/plugins/kanban/profiles') {
    return http.Response(jsonEncode({'profiles': []}), 200);
  }
  return http.Response('{}', 404);
});

Future<ConnectionManager> _dockManager() async {
  SharedPreferences.setMockInitialValues({});
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
  FeatureFlags.instance.resetToDefaultForTesting();
  GestureDockController.instance.resetForTesting(
    settings: const GestureDockSettings(),
  );
  DockGeometry.instance.resetForTesting();
  DockModes.instance.resetForTesting();
  addTearDown(FeatureFlags.instance.resetForTesting);
  await DockPreferencesController.instance.setUseDock(true);
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

/// The Tareas screen on its Tablero, at [size], like the real app.
Future<void> _pumpBoard(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  bool dock = false,
  String themeId = 'classic-dark',
}) async {
  await loadDesignFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: _top, bottom: _bottom);
  tester.view.viewPadding = const FakeViewPadding(top: _top, bottom: _bottom);
  addTearDown(tester.view.reset);
  final manager = dock ? await _dockManager() : null;
  final events = StreamController<KanbanEvent>.broadcast();
  addTearDown(events.close);
  final client = KanbanClient(
    _connection,
    dashboardClient: DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: _client(),
    ),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        scrollBehavior: const MomentumScrollBehavior(),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId(themeId),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: TasksScreen(
          connection: _connection,
          connManager: manager,
          clientOverride: client,
          eventStreamOverride: events.stream,
        ),
      ),
    ),
  );
  await pumpUntilLoaded(tester);
  await tester.tap(find.byKey(const ValueKey('kanban-view-board')));
  await pumpUntilLoaded(tester);
}

Finder _keyed(String prefix, {bool skipOffstage = true}) =>
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith(prefix);
    }, skipOffstage: skipOffstage);

final _board = find.byKey(const ValueKey('kanban-board-columns'));
final _column = find.byKey(const ValueKey('kanban-board-column-attention'));
final _header = find.byKey(const ValueKey('kanban-board-header-attention'));
final _switch = find.byKey(const ValueKey('hermes-segmented-floating'));
final _filter = find.byKey(const ValueKey('kanban-filter-button'));
final _title = find.byKey(const ValueKey('hermes-app-bar-title'));

Finder _card(String id) =>
    find.byKey(ValueKey('kanban-board-task-$id'), skipOffstage: false);

ScrollPosition _position(WidgetTester tester, Finder list) => tester
    .state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    )
    .position;

Rect _rectOf(Element element) {
  final box = element.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The cards of the first column that are built, on screen or near it.
Iterable<Element> _cards() =>
    _keyed('kanban-board-task-blocked-', skipOffstage: false).evaluate();

/// True when a touch at [at] (the centre of [target] by default) lands on
/// [target]: it is on top there, nothing is drawn over it.
bool _hits(WidgetTester tester, Finder target, {Offset? at}) {
  final box = tester.renderObject<RenderBox>(target);
  final result = tester.hitTestOnBinding(at ?? tester.getCenter(target));
  return result.path.any((entry) => entry.target == box);
}

/// A finger drag in steps, like a real swipe.
Future<void> _drag(WidgetTester tester, Offset from, Offset step) async {
  final finger = await tester.startGesture(from, kind: PointerDeviceKind.touch);
  for (var i = 0; i < 10; i++) {
    await finger.moveBy(step);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await finger.up();
  await pumpUntilLoaded(tester);
}

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  if (_dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(_dir).createSync(recursive: true);
    File('$_dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('at rest: the controls, then each column\'s name as plain text, '
      'then its cards; nothing over anything', (tester) async {
    await _pumpBoard(tester);
    final body = tester.getRect(find.byType(HermesStickyControls));
    final controls = tester.getRect(_switch);
    final header = tester.getRect(_header);
    final first = tester.getRect(_card('blocked-0'));

    expect(body.top, _top + kToolbarHeight);
    // The board is the whole page: it starts where the Lista starts.
    expect(tester.getRect(_board).top, body.top);
    expect(tester.getRect(_column).top, body.top);
    expect(header.top, greaterThanOrEqualTo(controls.bottom));
    expect(header.top, body.top + HermesStickyControls.extent + 6);
    // The name is plain text on the page, as in the Lista: no surface of
    // its own.
    expect(
      find.descendant(
        of: _header,
        matching: find.byType(HermesFloatingSurface),
      ),
      findsNothing,
    );
    expect(first.top, greaterThanOrEqualTo(header.bottom + 4));
    expect(_hits(tester, _card('blocked-0')), isTrue);
    expect(_hits(tester, _switch), isTrue);
    expect(_hits(tester, _filter), isTrue);
    // Every column on screen has its name, one line each.
    for (final element in _keyed('kanban-board-header-').evaluate()) {
      final box = element.renderObject! as RenderBox;
      expect(box.size.height, lessThan(40));
    }
  });

  testWidgets('scrolled: the cards pass under the switch and the header, '
      'which stay on top; the column\'s name goes with them', (tester) async {
    await _pumpBoard(tester);
    final body = tester.getRect(find.byType(HermesStickyControls));
    expect(tester.widget<ListView>(_column).clipBehavior, hermesUnderHeader);

    await _drag(tester, tester.getCenter(_column), const Offset(0, -30));
    final scrolled = _position(tester, _column).pixels;
    expect(scrolled, greaterThan(200));
    expect(_position(tester, _board).pixels, 0, reason: 'the board stayed');

    // A card is now above the page's top edge: it is drawn under the header,
    // inside the header's reach and no further.
    final above = _cards()
        .map(_rectOf)
        .where((rect) => rect.top < body.top && rect.bottom > _top);
    expect(above, isNotEmpty, reason: 'cards reach under the header');
    final clip = tester.widget<ClipRect>(
      find
          .ancestor(
            of: _keyed('kanban-board-task-blocked-').first,
            matching: find.byWidgetPredicate(
              (w) => w is ClipRect && w.clipper is UnderHeaderClipper,
            ),
          )
          .first,
    );
    // The header's reach is the toolbar: nothing is drawn behind the status
    // bar.
    expect((clip.clipper! as UnderHeaderClipper).reach, kToolbarHeight);

    // The pieces are on top: a touch on each lands on it, not on a card.
    for (final piece in [_switch, _filter]) {
      expect(_hits(tester, piece), isTrue, reason: '$piece');
    }
    final titleCentre = tester.getCenter(_title);
    for (final element in _keyed(
      'kanban-board-task-',
      skipOffstage: false,
    ).evaluate()) {
      final box = element.renderObject! as RenderBox;
      expect(
        tester.hitTestOnBinding(titleCentre).path.any((e) => e.target == box),
        isFalse,
      );
    }
    // The column's name went up with its cards: it is a row like them (far
    // enough up, it is not even built any more).
    final name = find.byKey(
      const ValueKey('kanban-board-header-attention'),
      skipOffstage: false,
    );
    expect(
      name.evaluate().isEmpty ||
          tester.getRect(name).bottom < tester.getRect(_switch).top,
      isTrue,
    );
  });

  testWidgets('a column moves alone and the board moves alone', (tester) async {
    await _pumpBoard(tester);
    await _drag(tester, tester.getCenter(_column), const Offset(0, -24));
    final column = _position(tester, _column).pixels;
    expect(column, greaterThan(150));
    expect(_position(tester, _board).pixels, 0);

    await _drag(tester, tester.getCenter(_column), const Offset(-24, 0));
    expect(_position(tester, _board).pixels, greaterThan(150));
    expect(_position(tester, _column).pixels, column);

    // A sideways drag that starts on a column's name moves the board too.
    final before = _position(tester, _board).pixels;
    await _drag(
      tester,
      tester.getCenter(
        find.byKey(const ValueKey('kanban-board-header-working')),
      ),
      const Offset(-12, 0),
    );
    expect(_position(tester, _board).pixels, greaterThan(before));
    // Sideways the board ends at its own edges.
    expect(
      find.ancestor(of: _board, matching: find.byType(HermesOpenTopClip)),
      findsWidgets,
    );
  });

  testWidgets('the last card of a column ends clear of the fade before the '
      'dock, and takes the touch', (tester) async {
    await _pumpBoard(tester, dock: true);
    final fade = find.byKey(const ValueKey('dock-body-fade'));
    expect(fade, findsOneWidget);
    final position = _position(tester, _column);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final last = _card('blocked-${_titles.length - 1}');
    expect(
      tester.getRect(last).bottom,
      lessThanOrEqualTo(tester.getRect(fade).top),
    );
    expect(_hits(tester, last), isTrue);
    // The column itself runs down to the fade's end: the cards dissolve in
    // it, they are not cut above it.
    expect(tester.getRect(_column).bottom, tester.getRect(fade).bottom);

    position.jumpTo(0);
    await tester.pump();
    expect(_hits(tester, _card('blocked-0')), isTrue);
  });

  testWidgets('with no dock the last card ends above the system bar', (
    tester,
  ) async {
    await _pumpBoard(tester);
    final position = _position(tester, _column);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final last = _card('blocked-${_titles.length - 1}');
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(844 - _bottom));
    expect(_hits(tester, last), isTrue);
  });

  for (final width in const [320.0, 390.0, 412.0]) {
    for (final scale in const [1.0, 2.0]) {
      testWidgets('$width dp, text ×$scale: nothing overflows and the first '
          'card clears the column name', (tester) async {
        await _pumpBoard(tester, size: Size(width, 844), textScale: scale);
        expect(tester.takeException(), isNull);
        final header = tester.getRect(_header);
        expect(
          tester.getRect(_card('blocked-0')).top,
          greaterThanOrEqualTo(header.bottom + 4),
        );
        expect(
          header.top,
          greaterThanOrEqualTo(tester.getRect(_switch).bottom),
        );
        final name = tester.renderObject<RenderParagraph>(
          find.descendant(of: _header, matching: find.byType(RichText)).first,
        );
        expect(name.size.height, lessThanOrEqualTo(header.height));
        await _drag(tester, tester.getCenter(_column), const Offset(0, -30));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a screen reader gets the cards in sight, not the ones gone '
      'past the header', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpBoard(tester);
    bool hidden(String id) => tester
        .getSemantics(
          find
              .descendant(
                of: _card(id),
                matching: find.byType(Text, skipOffstage: false),
              )
              .first,
        )
        .flagsCollection
        .isHidden;
    expect(hidden('blocked-0'), isFalse);
    expect(hidden('blocked-1'), isFalse);

    // The first card goes past the header's reach.
    final first = tester.getRect(_card('blocked-0'));
    _position(tester, _column).jumpTo(first.bottom + 12);
    await tester.pump();
    expect(tester.getRect(_card('blocked-0')).bottom, lessThan(_top));
    expect(hidden('blocked-0'), isTrue);
    // One that is still partly under the header is offered.
    final under = _cards().where((e) {
      final rect = _rectOf(e);
      return rect.top < _top + kToolbarHeight && rect.bottom > _top + 8;
    }).toList();
    expect(under, isNotEmpty);
    final id = (under.first.widget.key! as ValueKey<String>).value.substring(
      'kanban-board-task-'.length,
    );
    expect(hidden(id), isFalse);
    handle.dispose();
  });

  for (final theme in const ['classic-dark', 'classic']) {
    testWidgets('design shot · Tablero · $theme', (tester) async {
      await _pumpBoard(tester, dock: true, themeId: theme);
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'p4_tablero_${theme}_top');
      await _drag(tester, tester.getCenter(_column), const Offset(0, -26));
      await _drag(
        tester,
        tester.getCenter(_column) + const Offset(200, 0),
        const Offset(0, -9),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'p4_tablero_${theme}_scrolled');
    });
  }
}
