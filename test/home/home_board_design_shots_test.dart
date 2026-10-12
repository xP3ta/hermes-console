// Visual evidence of the Home board at 390×844, dark, Spanish, with the
// data of the approved mockups: each of the six widgets at its three sizes
// and states, the default boards and edit mode. Writes PNGs only when
// `DESIGN_SHOTS_DIR` is set; otherwise it is a layout test (no overflow).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_view.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/models/profile_identity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/account_usage_fixtures.dart';
import '../support/design_shots.dart' show loadDesignFonts;
import '../support/home_board_fixtures.dart';

const _root = ValueKey('home-shot-root');
const _small = HomeWidgetSize.small;
const _wide = HomeWidgetSize.wide;
const _large = HomeWidgetSize.large;

Future<void> _pump(
  WidgetTester tester,
  Widget body, {
  Size size = const Size(390, 844),
  String theme = 'console',
}) async {
  await loadDesignFonts();
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _root,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId(theme),
        home: Scaffold(body: body),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  final dir = Platform.environment['DESIGN_SHOTS_DIR'] ?? 'build/design_shots';
  final boundary =
      tester.renderObject(find.byKey(_root)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// A page of tiles, as the mockup sheets lay them out: pairs of small
/// ones side by side, wide and large ones below.
Widget _sheet(List<Widget> rows) => SafeArea(
  child: SingleChildScrollView(
    padding: const EdgeInsets.all(17),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) const SizedBox(height: 11),
          row,
        ],
      ],
    ),
  ),
);

Widget _pair(Widget a, Widget b) =>
    Row(children: [a, const SizedBox(width: 11), b]);

final _calls = HomeCalls();

Widget _tile(
  HomeWidgetKind kind,
  HomeWidgetSize size,
  HomeBoardData data, {
  Map<String, Object?> options = const {},
}) => homeTile(
  kind: kind,
  size: size,
  data: data,
  actions: _calls.actions,
  options: options,
  // The mockup's rows are 152 tall.
  cell: homeCell(size, row: 152),
);

/// The mockups' moment: Forja replies in Console Devs, Hermes runs a chat
/// with subagents.
HomeBoardData _live({bool asks = false, bool permission = false}) => homeData(
  chats: [
    homeChat('t1', homeT1, working: true, step: '2 subagentes'),
    homeChat(
      't3',
      homeT3,
      agent: 'Fable',
      preview: 'Te dejo tres opciones de píldora',
      at: DateTime(2026, 10, 11, 21, 44),
    ),
    homeChat(
      't4',
      homeT4,
      draft: true,
      preview: 'Hola, necesito hacer unos retoques',
      at: DateTime(2026, 10, 11, 20, 15),
    ),
  ],
  bots: homeBots(astraWaits: asks),
  rooms: homeRooms(),
  questions: [if (asks) homeQuestionItem()],
  approvals: [if (permission) homeApproval()],
  automations: homeJobs(),
  tasks: homeTasksBoard(),
);

HomeBoardData _calm() => homeData(
  chats: [
    homeChat(
      't3',
      homeT3,
      agent: 'Fable',
      preview: 'Te dejo tres opciones de píldora',
    ),
    homeChat(
      't4',
      homeT4,
      draft: true,
      preview: 'Hola, necesito hacer unos retoques',
      ago: const Duration(hours: 1),
    ),
    homeChat('t5', homeT5, ago: const Duration(hours: 1)),
  ],
  bots: [
    homeBot(
      'Forja',
      lastTitle: 'Publicar 1.2.15',
      lastAt: homeAgoAt(const Duration(hours: 3)),
    ),
    homeBot(
      'Fable',
      lastTitle: 'Diseño de píldora de estados',
      lastAt: homeAgoAt(const Duration(minutes: 20)),
    ),
    homeBot('Astra'),
    homeBot('Radar'),
  ],
  rooms: homeRooms(live: false),
  automations: homeJobs(failure: false),
  tasks: homeTasksBoard(running: false),
);

/// A board in a phone: a plain header bar, the board, the dock's room.
Widget _board(
  HomeBoardLayout layout,
  HomeBoardData data, {
  bool editing = false,
  Widget? notice,
  Key? key,
}) => SafeArea(
  child: Column(
    children: [
      if (!editing)
        const SizedBox(
          height: kToolbarHeight,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 17),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'CONSOLE',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      Expanded(
        child: HomeBoardView(
          key: key,
          layout: layout,
          data: data,
          actions: _calls.actions,
          onChanged: (_) {},
          newId: () => 'new',
          clock: () => homeFixtureNow,
          leading: [?notice],
          // The floating dock's footprint.
          bottomPadding: 82,
          initiallyEditing: editing,
        ),
      ),
    ],
  ),
);

HomeWidgetInstance _w(String id, HomeWidgetKind kind, HomeWidgetSize size) =>
    HomeWidgetInstance(id: id, kind: kind, size: size);

/// A Petdex-style sprite sheet shipped with the app, standing for the
/// profile's chosen pet.
Companion _profilePet() => Companion(
  slug: 'nimbus',
  name: 'Nimbus',
  author: 'Hermes Console',
  license: 'CC0-1.0',
  spritesheetAsset: 'assets/companions/nimbus/spritesheet.webp',
  frameWidth: 192,
  frameHeight: 208,
  cols: 8,
  rows: 9,
  fps: 8,
  states: const {
    CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 8, loop: true),
  },
);

AccountUsageLimits _plusLimits() =>
    AccountUsageLimits.fromGateway(usage(account: codexLines));

void main() {
  setUp(() => debugLivingBotFacesStill = true);
  tearDown(() => ProfileIdentities.instance.reset());

  for (final theme in ['console', 'console-light']) {
    for (final editing in [false, true]) {
      testWidgets('owner Home · $theme · edit $editing', (tester) async {
        final data = homeData(
          chats: [
            homeChat(
              'vm',
              'Acceder a VM de Windows en Proxmox',
              working: true,
              running: const Duration(minutes: 2, seconds: 14),
              step: 'Ejecutando código',
            ),
            homeChat(
              'initial',
              'Mensaje de prueba inicial',
              preview: 'primer mensaje de prueba',
            ),
            homeChat('saludo', 'Saludo en español', preview: 'Hola?'),
            homeChat('saludo2', 'Saludo amistoso #2', preview: 'Hola, hola.'),
            homeChat('saludo3', 'Saludo amistoso en español', preview: 'Hola'),
          ],
        );
        await _pump(
          tester,
          _board(
            HomeBoardLayout([
              _w('now', HomeWidgetKind.now, _wide),
              _w('chats', HomeWidgetKind.continueChats, _large),
              _w('cron', HomeWidgetKind.cron, _wide),
            ]),
            data,
            editing: editing,
          ),
          theme: theme,
        );
        await _shot(tester, 'home-owner-$theme-edit-$editing');
      });

      testWidgets('owner Home with limits and a profile pet · $theme · '
          'edit $editing', (tester) async {
        ProfileIdentities.instance.connectionId = () => 'c1';
        ProfileIdentities.instance.publish('c1', 'default', _profilePet());
        final data = homeData(
          chats: [
            homeChat(
              'vm',
              'Acceder a VM de Windows en Proxmox',
              working: true,
              running: const Duration(minutes: 2, seconds: 14),
              step: 'Ejecutando código',
            ),
            homeChat(
              'initial',
              'Mensaje de prueba inicial',
              preview: 'primer mensaje de prueba',
            ),
            homeChat('saludo', 'Saludo en español', preview: 'Hola?'),
          ],
          limits: _plusLimits(),
        );
        await _pump(
          tester,
          _board(
            HomeBoardLayout([
              _w('now', HomeWidgetKind.now, _wide),
              _w('chats', HomeWidgetKind.continueChats, _wide),
              _w('limits', HomeWidgetKind.planLimits, _wide),
              _w('cron', HomeWidgetKind.cron, _small),
              _w('tasks', HomeWidgetKind.tasks, _small),
            ]),
            data,
            editing: editing,
          ),
          theme: theme,
        );
        // The sprite sheet decodes outside the test clock.
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump(const Duration(milliseconds: 60));
        }
        await _shot(tester, 'home-limits-$theme-edit-$editing');
      });
    }
  }

  testWidgets('Límites: whose limits they are, at each size', (tester) async {
    const kind = HomeWidgetKind.planLimits;
    final claude = homeData(
      limits: AccountUsageLimits.fromGateway(usage(account: claudeLines)),
    );
    final both = homeData(
      limits: AccountUsageLimits.fromGateway(
        usage(account: codexLines, credits: nousLines),
      ),
    );
    await _pump(
      tester,
      _sheet([
        _pair(
          _tile(kind, _small, homeData(limits: _plusLimits())),
          _tile(kind, _small, claude),
        ),
        _tile(kind, _wide, homeData(limits: _plusLimits())),
        _tile(kind, _wide, claude),
        _tile(kind, _large, both),
      ]),
      size: const Size(390, 1100),
    );
    await _shot(tester, '13-limites');
    await _pump(
      tester,
      _sheet([_tile(kind, _large, both)]),
      theme: 'console-light',
    );
    await _shot(tester, '13-limites-claro');
  });

  testWidgets('Ahora: small in its four moments, wide in its three, large', (
    tester,
  ) async {
    const kind = HomeWidgetKind.now;
    await _pump(
      tester,
      _sheet([
        _pair(
          _tile(kind, _small, _live(asks: true)),
          _tile(kind, _small, _live(permission: true)),
        ),
        _pair(_tile(kind, _small, _live()), _tile(kind, _small, _calm())),
        _tile(kind, _wide, _live(asks: true)),
        _tile(kind, _wide, _live()),
        _tile(kind, _wide, _calm()),
      ]),
      size: const Size(390, 900),
    );
    await _shot(tester, '01-ahora-pequeno-ancho');
    await _pump(
      tester,
      _sheet([
        _tile(kind, _large, _live(asks: true)),
        _tile(kind, _wide, _live(permission: true)),
        _tile(kind, _large, _calm()),
      ]),
      size: const Size(390, 900),
    );
    await _shot(tester, '01-ahora-grande');
  });

  testWidgets('Chats: small in two moments, wide, large', (tester) async {
    const kind = HomeWidgetKind.continueChats;
    final data = homeData(
      chats: homeChats(),
      questions: [
        homeQuestionItem(
          key: 'q2',
          sessionKey: 't2',
          actor: null,
          question: '¿Sigo con la versión de marzo?',
          choices: const [],
        ),
      ],
    );
    await _pump(
      tester,
      _sheet([
        _pair(
          _tile(kind, _small, data),
          _tile(kind, _small, homeData(chats: homeChats().sublist(2))),
        ),
        _tile(kind, _wide, data),
        _tile(kind, _large, data),
      ]),
    );
    await _shot(tester, '02-chats');
  });

  testWidgets('Bots: small in two moments, wide, large', (tester) async {
    const kind = HomeWidgetKind.team;
    await _pump(
      tester,
      _sheet([
        _pair(
          _tile(kind, _small, _live(asks: true)),
          _tile(kind, _small, _calm()),
        ),
        _tile(kind, _wide, _live(asks: true)),
        _tile(kind, _large, _live(asks: true)),
      ]),
    );
    await _shot(tester, '03-bots');
    await _pump(tester, _sheet([_tile(kind, _large, _live())]));
    await _shot(tester, '03-bots-grande-trabajando');
  });

  testWidgets('Salas: small in two moments, wide, large', (tester) async {
    const kind = HomeWidgetKind.room;
    await _pump(
      tester,
      _sheet([
        _pair(_tile(kind, _small, _live()), _tile(kind, _small, _calm())),
        _tile(kind, _wide, _live()),
        _tile(kind, _large, _live()),
      ]),
    );
    await _shot(tester, '04-salas');
  });

  testWidgets('Cron: small (the next, one fixed), wide, large', (tester) async {
    const kind = HomeWidgetKind.cron;
    await _pump(
      tester,
      _sheet([
        _pair(
          _tile(kind, _small, _live()),
          _tile(kind, _small, _calm(), options: const {'job': 'hr'}),
        ),
        _tile(kind, _wide, _live()),
        _tile(kind, _large, _live()),
      ]),
    );
    await _shot(tester, '05-cron');
  });

  testWidgets('Tareas: small in two moments, wide, large', (tester) async {
    const kind = HomeWidgetKind.tasks;
    await _pump(
      tester,
      _sheet([
        _pair(_tile(kind, _small, _live()), _tile(kind, _small, _calm())),
        _tile(kind, _wide, _live()),
        _tile(kind, _large, _live()),
      ]),
    );
    await _shot(tester, '06-tareas');
  });

  testWidgets('states: loading, could not read, offline, empty', (
    tester,
  ) async {
    final loading = homeData(
      automations: null,
      tasks: null,
      botsLoaded: false,
      chatsLoaded: false,
    );
    final failed = homeData(
      automations: null,
      automationsFailed: true,
      tasks: null,
      tasksFailed: true,
    );
    final offline = homeData(
      automations: null,
      automationsFailed: true,
      tasks: null,
      tasksFailed: true,
      botsLoaded: false,
      online: false,
    );
    final empty = homeData();
    await _pump(
      tester,
      _sheet([
        _pair(
          _tile(HomeWidgetKind.continueChats, _small, loading),
          _tile(HomeWidgetKind.team, _small, loading),
        ),
        _pair(
          _tile(HomeWidgetKind.cron, _small, failed),
          _tile(HomeWidgetKind.tasks, _small, failed),
        ),
        _pair(
          _tile(HomeWidgetKind.cron, _small, offline),
          _tile(HomeWidgetKind.room, _small, offline),
        ),
        _pair(
          _tile(HomeWidgetKind.tasks, _small, empty),
          _tile(HomeWidgetKind.room, _small, empty),
        ),
        _tile(HomeWidgetKind.continueChats, _wide, empty),
      ]),
    );
    await _shot(tester, '07-estados');
  });

  testWidgets('the default board with bots (I2), and with one agent', (
    tester,
  ) async {
    await _pump(tester, _board(HomeBoardLayout.defaults(team: true), _live()));
    await _shot(tester, '08-tablero-bots-primero');
    await _pump(tester, _board(HomeBoardLayout.defaults(team: false), _live()));
    await _shot(tester, '08-tablero-un-agente');
  });

  testWidgets('the other arrangements of the mockups', (tester) async {
    await _pump(
      tester,
      _board(
        HomeBoardLayout([
          _w('now', HomeWidgetKind.now, _wide),
          _w('chats', HomeWidgetKind.continueChats, _wide),
          _w('bots', HomeWidgetKind.team, _wide),
          _w('cron', HomeWidgetKind.cron, _small),
          _w('tasks', HomeWidgetKind.tasks, _small),
        ]),
        _live(asks: true),
      ),
    );
    await _shot(tester, '07-tablero-como-ahora');
    await _pump(
      tester,
      _board(
        HomeBoardLayout([
          _w('now', HomeWidgetKind.now, _wide),
          _w('chats', HomeWidgetKind.continueChats, _wide),
          _w('bots', HomeWidgetKind.team, _small),
          _w('rooms', HomeWidgetKind.room, _small),
          _w('cron', HomeWidgetKind.cron, _small),
          _w('tasks', HomeWidgetKind.tasks, _small),
        ]),
        _calm(),
      ),
    );
    await _shot(tester, '09-tablero-los-seis');
  });

  testWidgets('edit mode: full with the size control open, one slot free, '
      'and «Añadir widget»', (tester) async {
    final full = HomeBoardLayout([
      _w('now', HomeWidgetKind.now, _wide),
      _w('chats', HomeWidgetKind.continueChats, _wide),
      _w('bots', HomeWidgetKind.team, _wide),
      _w('cron', HomeWidgetKind.cron, _small),
      _w('tasks', HomeWidgetKind.tasks, _small),
    ]);
    await _pump(tester, _board(full, _live(asks: true), editing: true));
    await tester.tap(find.byKey(const ValueKey('home-resize-bots')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Inicio lleno'), findsOneWidget);
    await _shot(tester, '10-editar-lleno');

    await _pump(
      tester,
      _board(
        full.resize('bots', _small),
        _live(asks: true),
        editing: true,
        key: const ValueKey('one-free'),
      ),
    );
    expect(find.text('1 hueco'), findsOneWidget);
    await _shot(tester, '10-editar-un-hueco');
    await tester.tap(find.byKey(const ValueKey('home-edit-add')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('home-gallery')), findsOneWidget);
    await _shot(tester, '10-editar-anadir');
  });

  testWidgets('a notice above the board tightens its rows', (tester) async {
    await _pump(
      tester,
      _board(
        HomeBoardLayout.defaults(team: true),
        _live(asks: true),
        // The size of Home's «sin conexión» card.
        notice: Builder(
          builder: (context) => Container(
            height: 118,
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(18),
            ),
            alignment: Alignment.topLeft,
            child: const Text(
              'QA · sin conexión',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
    await _shot(tester, '12-tablero-con-aviso');
  });

  testWidgets('light theme and 2x text hold too', (tester) async {
    await _pump(
      tester,
      _board(HomeBoardLayout.defaults(team: true), _live(asks: true)),
      theme: 'console-light',
    );
    await _shot(tester, '11-tablero-claro');
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      _board(HomeBoardLayout.defaults(team: true), _live(asks: true)),
    );
    await _shot(tester, '11-tablero-texto-2x');
  });
}
