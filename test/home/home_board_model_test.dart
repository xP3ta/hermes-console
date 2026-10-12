import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_catalog.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _seq = 0;
String _id() => 'w${_seq++}';

HomeWidgetInstance _w(
  String id,
  HomeWidgetKind kind,
  HomeWidgetSize size, [
  Map<String, Object?> options = const {},
]) => HomeWidgetInstance(id: id, kind: kind, size: size, options: options);

const _small = HomeWidgetSize.small;
const _wide = HomeWidgetSize.wide;
const _large = HomeWidgetSize.large;

String _stored(List<Object?> items, {bool neutral = false}) =>
    jsonEncode({'v': 1, if (neutral) 'neutral': true, 'items': items});

void main() {
  setUp(() => _seq = 0);

  group('catalog', () {
    test('every kind has a spec with its sizes and a default among them', () {
      for (final kind in HomeWidgetKind.values) {
        final spec = HomeWidgetCatalog.of(kind);
        expect(spec.kind, kind);
        expect(spec.sizes, isNotEmpty, reason: '$kind');
        expect(spec.sizes, contains(spec.defaultSize), reason: '$kind');
      }
    });

    test('the six boards of a subject come in the three sizes', () {
      for (final kind in const [
        HomeWidgetKind.now,
        HomeWidgetKind.continueChats,
        HomeWidgetKind.team,
        HomeWidgetKind.room,
        HomeWidgetKind.cron,
        HomeWidgetKind.tasks,
      ]) {
        expect(HomeWidgetCatalog.of(kind).sizes, [
          _small,
          _wide,
          _large,
        ], reason: '$kind');
      }
    });

    test('Ahora, Chats and Tareas are one per board; Bots, Salas, Cron and '
        'the single-target widgets can repeat', () {
      for (final kind in const [
        HomeWidgetKind.now,
        HomeWidgetKind.continueChats,
        HomeWidgetKind.tasks,
        HomeWidgetKind.planLimits,
        HomeWidgetKind.server,
      ]) {
        expect(
          HomeWidgetCatalog.of(kind).multiInstance,
          isFalse,
          reason: '$kind',
        );
      }
      for (final kind in const [
        HomeWidgetKind.team,
        HomeWidgetKind.room,
        HomeWidgetKind.cron,
        HomeWidgetKind.bot,
        HomeWidgetKind.chat,
      ]) {
        expect(
          HomeWidgetCatalog.of(kind).multiInstance,
          isTrue,
          reason: '$kind',
        );
      }
    });

    test('a bot or a chat needs its target; Salas and Cron show something '
        'without one', () {
      expect(HomeWidgetCatalog.of(HomeWidgetKind.bot).requiredOption, 'bot');
      expect(HomeWidgetCatalog.of(HomeWidgetKind.chat).requiredOption, 'chat');
      expect(HomeWidgetCatalog.of(HomeWidgetKind.room).requiredOption, isNull);
      expect(HomeWidgetCatalog.of(HomeWidgetKind.cron).requiredOption, isNull);
    });

    test('«Añadir widget» lists every kind once, the six subjects first', () {
      expect(HomeWidgetCatalog.kinds.toSet(), HomeWidgetKind.values.toSet());
      expect(HomeWidgetCatalog.kinds.length, HomeWidgetKind.values.length);
      expect(HomeWidgetCatalog.kinds.take(6), const [
        HomeWidgetKind.now,
        HomeWidgetKind.continueChats,
        HomeWidgetKind.team,
        HomeWidgetKind.room,
        HomeWidgetKind.cron,
        HomeWidgetKind.tasks,
      ]);
    });

    test('a single widget already on the board is not offered again; one '
        'that can repeat is', () {
      final layout = HomeBoardLayout.defaults(team: true);
      final offered = HomeWidgetCatalog.addable(layout);
      expect(offered, isNot(contains(HomeWidgetKind.now)));
      expect(offered, contains(HomeWidgetKind.room));
      expect(offered, contains(HomeWidgetKind.cron));
      expect(offered, contains(HomeWidgetKind.tasks));
    });
  });

  group('wire names', () {
    test('the names stored on devices never change', () {
      // A name here is what layouts saved on users' phones carry: adding a
      // kind adds a line, nothing in this list is ever edited or removed.
      expect(
        {for (final kind in HomeWidgetKind.values) kind.name},
        {
          'team',
          'bot',
          'room',
          'chat',
          'continueChats',
          'planLimits',
          'server',
          'today',
          'now',
          'cron',
          'tasks',
        },
      );
    });

    test('the names of the retired kinds still read, as their successor', () {
      expect(HomeWidgetKind.retired, {
        'glance': HomeWidgetKind.now,
        'needsYou': HomeWidgetKind.now,
        'nextAutomation': HomeWidgetKind.cron,
        'automations': HomeWidgetKind.cron,
      });
      for (final name in HomeWidgetKind.retired.keys) {
        expect(
          HomeWidgetKind.values.any((kind) => kind.name == name),
          isFalse,
          reason: '$name is never reused for a new kind',
        );
        expect(HomeWidgetKind.fromWire(name), HomeWidgetKind.retired[name]);
      }
      for (final kind in HomeWidgetKind.values) {
        expect(HomeWidgetKind.fromWire(kind.name), kind);
      }
      expect(HomeWidgetKind.fromWire('hologram'), isNull);
      expect(HomeWidgetKind.fromWire(null), isNull);
    });
  });

  group('migration of stored layouts', () {
    test('«Lo siguiente» becomes Ahora in its place, at its size, with its '
        'id and options', () {
      final layout = HomeBoardLayout.decode(
        _stored([
          {'id': 'r', 'kind': 'room', 'size': 'wide'},
          {
            'id': 'g',
            'kind': 'glance',
            'size': 'large',
            'options': {'tint': 'neutral'},
          },
          {'id': 't', 'kind': 'today', 'size': 'small'},
        ]),
      )!;
      expect(layout.items.map((i) => (i.id, i.kind, i.size)), [
        ('r', HomeWidgetKind.room, _wide),
        ('g', HomeWidgetKind.now, _large),
        ('t', HomeWidgetKind.today, _small),
      ]);
      expect(layout.items[1].stringOption('tint'), 'neutral');
    });

    test('«Te necesita» is absorbed: alone it becomes Ahora, next to «Lo '
        'siguiente» the first of the two stays', () {
      final alone = HomeBoardLayout.decode(
        _stored([
          {'id': 'c', 'kind': 'continueChats', 'size': 'small'},
          {'id': 'n', 'kind': 'needsYou', 'size': 'wide'},
        ]),
      )!;
      expect(alone.items.map((i) => (i.id, i.kind, i.size)), [
        ('c', HomeWidgetKind.continueChats, _small),
        ('n', HomeWidgetKind.now, _wide),
      ]);

      final both = HomeBoardLayout.decode(
        _stored([
          {'id': 'n', 'kind': 'needsYou', 'size': 'large'},
          {'id': 'c', 'kind': 'continueChats', 'size': 'small'},
          {'id': 'g', 'kind': 'glance', 'size': 'wide'},
        ]),
      )!;
      expect(both.items.map((i) => (i.id, i.kind, i.size)), [
        ('n', HomeWidgetKind.now, _large),
        ('c', HomeWidgetKind.continueChats, _small),
      ]);
    });

    test('«Próxima» and «Automatizaciones» become Cron at the same size; '
        'a fixed job stays fixed and every instance is kept', () {
      final layout = HomeBoardLayout.decode(
        _stored([
          {
            'id': 'p1',
            'kind': 'nextAutomation',
            'size': 'small',
            'options': {'job': 'daily'},
          },
          {'id': 'p2', 'kind': 'nextAutomation', 'size': 'wide'},
          {'id': 'a', 'kind': 'automations', 'size': 'large'},
          {'id': 'b', 'kind': 'team', 'size': 'small'},
        ]),
      )!;
      expect(layout.items.map((i) => (i.id, i.kind, i.size)), [
        ('p1', HomeWidgetKind.cron, _small),
        ('p2', HomeWidgetKind.cron, _wide),
        ('a', HomeWidgetKind.cron, _large),
        ('b', HomeWidgetKind.team, _small),
      ]);
      expect(layout.items.first.stringOption('job'), 'daily');
    });

    test('what is written back carries the new names', () {
      final layout = HomeBoardLayout.decode(
        _stored([
          {'id': 'g', 'kind': 'glance', 'size': 'wide'},
          {'id': 'a', 'kind': 'automations', 'size': 'wide'},
        ]),
      )!;
      final items = (jsonDecode(layout.encode()) as Map)['items'] as List;
      expect(
        [for (final item in items) (item as Map)['kind']],
        ['now', 'cron'],
      );
      expect(
        HomeBoardLayout.decode(layout.encode())!.encode(),
        layout.encode(),
      );
    });

    test('the former default left as it was is not a layout of the user: '
        'the board follows the new default', () {
      final former = _stored([
        {'id': 'w1', 'kind': 'glance', 'size': 'wide'},
        {'id': 'w2', 'kind': 'continueChats', 'size': 'wide'},
        {'id': 'w3', 'kind': 'team', 'size': 'wide'},
        {'id': 'w4', 'kind': 'nextAutomation', 'size': 'small'},
        {'id': 'w5', 'kind': 'today', 'size': 'small'},
      ]);
      expect(HomeBoardLayout.decode(former), isNull);
    });

    test('the former default with anything changed is the user\'s: kept, '
        'migrated', () {
      List<Map<String, Object?>> former() => [
        {'id': 'w1', 'kind': 'glance', 'size': 'wide'},
        {'id': 'w2', 'kind': 'continueChats', 'size': 'wide'},
        {'id': 'w3', 'kind': 'team', 'size': 'wide'},
        {'id': 'w4', 'kind': 'nextAutomation', 'size': 'small'},
        {'id': 'w5', 'kind': 'today', 'size': 'small'},
      ];
      // A size, an option, the order, the colour switch, one widget less.
      final resized = former()..[2] = {...former()[2], 'size': 'large'};
      final configured = former()
        ..[3] = {
          ...former()[3],
          'options': {'job': 'daily'},
        };
      final reordered = former().reversed.toList();
      final shorter = former()..removeLast();
      for (final items in [resized, configured, reordered, shorter]) {
        final layout = HomeBoardLayout.decode(_stored(items));
        expect(layout, isNotNull);
        expect(layout!.items.length, items.length);
        expect(layout.items.map((i) => i.id), items.map((i) => i['id']));
      }
      final neutral = HomeBoardLayout.decode(_stored(former(), neutral: true));
      expect(neutral!.neutral, isTrue);
      expect(neutral.items.map((i) => i.kind), [
        HomeWidgetKind.now,
        HomeWidgetKind.continueChats,
        HomeWidgetKind.team,
        HomeWidgetKind.cron,
        HomeWidgetKind.today,
      ]);
    });
  });

  group('default board', () {
    test('with bots or rooms: Ahora wide, Bots large, then Salas and Cron '
        'side by side (eight slots)', () {
      final layout = HomeBoardLayout.defaults(team: true);
      expect(layout.items.map((i) => (i.kind, i.size)), [
        (HomeWidgetKind.now, _wide),
        (HomeWidgetKind.team, _large),
        (HomeWidgetKind.room, _small),
        (HomeWidgetKind.cron, _small),
      ]);
      final plan = HomeBoardPlan.of(layout.items, 4);
      expect(plan.full, isTrue);
      expect(plan.hidden, isEmpty);
      expect(plan.slots, const [
        HomeBoardSlot(col: 0, row: 0, cols: 2, rows: 1),
        HomeBoardSlot(col: 0, row: 1, cols: 2, rows: 2),
        HomeBoardSlot(col: 0, row: 3, cols: 1, rows: 1),
        HomeBoardSlot(col: 1, row: 3, cols: 1, rows: 1),
      ]);
    });

    test('with one agent: Ahora wide, Chats large, then Cron and Tareas', () {
      final layout = HomeBoardLayout.defaults(team: false);
      expect(layout.items.map((i) => (i.kind, i.size)), [
        (HomeWidgetKind.now, _wide),
        (HomeWidgetKind.continueChats, _large),
        (HomeWidgetKind.cron, _small),
        (HomeWidgetKind.tasks, _small),
      ]);
      expect(HomeBoardPlan.of(layout.items, 4).full, isTrue);
    });

    test('its ids are the same on every build', () {
      for (final team in [true, false]) {
        final a = HomeBoardLayout.defaults(team: team);
        final b = HomeBoardLayout.defaults(team: team);
        expect(a.items.map((i) => i.id), b.items.map((i) => i.id));
        expect(a.items.map((i) => i.id).toSet().length, a.items.length);
      }
    });
  });

  group('layout', () {
    test('two Salas keep their own rooms; configuring one leaves the other '
        'alone', () {
      var layout = HomeBoardLayout.defaults(team: false);
      layout = layout.add(
        HomeWidgetKind.room,
        options: const {
          'rooms': ['room-devs'],
        },
        newId: _id,
      );
      layout = layout.add(
        HomeWidgetKind.room,
        options: const {
          'rooms': ['room-ops'],
        },
        size: _wide,
        newId: _id,
      );
      final rooms = layout.items
          .where((i) => i.kind == HomeWidgetKind.room)
          .toList();
      expect(rooms.map((r) => r.roomKeys), [
        ['room-devs'],
        ['room-ops'],
      ]);
      expect(rooms.last.size, _wide);

      layout = layout.configure(rooms.first.id, const {
        'rooms': ['room-qa'],
      });
      expect(
        layout.items
            .where((i) => i.kind == HomeWidgetKind.room)
            .map((r) => r.roomKeys),
        [
          ['room-qa'],
          ['room-ops'],
        ],
      );
    });

    test('adding a second copy of a single widget is refused', () {
      final layout = HomeBoardLayout.defaults(team: false);
      expect(
        identical(layout.add(HomeWidgetKind.now, newId: _id), layout),
        isTrue,
      );
      expect(layout.add(HomeWidgetKind.cron, newId: _id).items.length, 5);
    });

    test('move puts the item at the target index and keeps the others in '
        'order', () {
      final layout = HomeBoardLayout([
        _w('a', HomeWidgetKind.now, _wide),
        _w('b', HomeWidgetKind.team, _wide),
        _w('c', HomeWidgetKind.cron, _small),
        _w('d', HomeWidgetKind.tasks, _small),
      ]);
      expect(layout.move('d', 0).items.map((i) => i.id), ['d', 'a', 'b', 'c']);
      expect(layout.move('a', 9).items.map((i) => i.id), ['b', 'c', 'd', 'a']);
      expect(identical(layout.move('b', 1), layout), isTrue);
      expect(identical(layout.move('zz', 1), layout), isTrue);
    });

    test('resize only accepts a size the kind offers', () {
      final layout = HomeBoardLayout([
        _w('s', HomeWidgetKind.server, _small),
        _w('n', HomeWidgetKind.now, _wide),
      ]);
      expect(identical(layout.resize('s', _large), layout), isTrue);
      expect(layout.resize('s', _wide).byId('s')!.size, _wide);
      expect(layout.resize('n', _small).byId('n')!.size, _small);
    });
  });

  group('json', () {
    test('round trip keeps order, sizes and options', () {
      var layout = HomeBoardLayout.defaults(team: true);
      layout = layout.add(
        HomeWidgetKind.cron,
        options: const {'job': 'daily'},
        newId: _id,
      );
      layout = layout.resize(layout.items[2].id, _wide);
      layout = layout.withNeutral(true);
      final decoded = HomeBoardLayout.decode(layout.encode());
      expect(decoded, isNotNull);
      expect(decoded!.encode(), layout.encode());
      expect(decoded.items.last.options['job'], 'daily');
      expect(decoded.neutral, isTrue);
      expect(decoded.add(HomeWidgetKind.server, newId: _id).neutral, isTrue);
      expect(jsonDecode(layout.encode())['v'], HomeBoardLayout.version);
    });

    test('corrupt or foreign data decodes to null', () {
      expect(HomeBoardLayout.decode('{not json'), isNull);
      expect(HomeBoardLayout.decode('[]'), isNull);
      expect(HomeBoardLayout.decode('{"v": 99, "items": []}'), isNull);
      expect(HomeBoardLayout.decode('{"v": 1, "items": 3}'), isNull);
    });

    test('unknown kinds, bad sizes and duplicate ids are dropped or '
        'repaired, never thrown', () {
      final layout = HomeBoardLayout.decode(
        _stored([
          {'id': 'a', 'kind': 'now', 'size': 'wide'},
          {'id': 'b', 'kind': 'hologram', 'size': 'small'},
          {'id': 'c', 'kind': 'server', 'size': 'enormous'},
          {'id': 'a', 'kind': 'today', 'size': 'small'},
          {'id': 'd', 'kind': 'now', 'size': 'large'},
          {'kind': 'server'},
          'garbage',
        ]),
      )!;
      expect(layout.items.map((i) => i.id), ['a', 'c']);
      expect(
        layout.items[1].size,
        HomeWidgetCatalog.of(HomeWidgetKind.server).defaultSize,
      );
    });
  });

  group('store', () {
    test('per connection and profile; nothing stored, or nothing readable, '
        'is the default', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = HomeBoardStore(prefs, newId: _id);
      expect(store.read('c1', 'default'), isNull);
      final empty = store.load('c1', 'default');
      expect(
        empty.encode(),
        HomeBoardLayout.defaults(team: false).encode(),
        reason: 'one agent until a Bots read says otherwise',
      );

      final custom = empty.add(HomeWidgetKind.server, newId: _id);
      await store.save('c1', 'default', custom);
      expect(store.load('c1', 'default').encode(), custom.encode());
      expect(store.read('c1', 'astra'), isNull);
      expect(store.read('c2', 'default'), isNull);

      await prefs.setString(HomeBoardStore.keyFor('c1', 'default'), '{bad');
      expect(store.read('c1', 'default'), isNull);
      expect(
        store.load('c1', 'default').encode(),
        HomeBoardLayout.defaults(team: false).encode(),
      );
    });

    test(
      'which default applies is remembered per connection and profile',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = HomeBoardStore(prefs);
        expect(store.team('c1', 'default'), isNull);
        await store.rememberTeam('c1', 'default', true);
        expect(store.team('c1', 'default'), isTrue);
        expect(store.team('c1', 'astra'), isNull);
        expect(
          store.load('c1', 'default').encode(),
          HomeBoardLayout.defaults(team: true).encode(),
        );
        // What the read says now wins over what was remembered.
        expect(
          store.load('c1', 'default', team: false).encode(),
          HomeBoardLayout.defaults(team: false).encode(),
        );
        // A flag only: nothing of the server is written.
        expect(prefs.getKeys(), {HomeBoardStore.teamKeyFor('c1', 'default')});
      },
    );

    test('a stored former default gives way to the new one; a customised '
        'one is kept', () async {
      SharedPreferences.setMockInitialValues({
        HomeBoardStore.keyFor('c1', 'default'): _stored([
          {'id': 'w1', 'kind': 'glance', 'size': 'wide'},
          {'id': 'w2', 'kind': 'continueChats', 'size': 'wide'},
          {'id': 'w3', 'kind': 'team', 'size': 'wide'},
          {'id': 'w4', 'kind': 'nextAutomation', 'size': 'small'},
          {'id': 'w5', 'kind': 'today', 'size': 'small'},
        ]),
        HomeBoardStore.keyFor('c2', 'default'): _stored([
          {'id': 'w1', 'kind': 'glance', 'size': 'wide'},
          {'id': 'w5', 'kind': 'today', 'size': 'small'},
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      final store = HomeBoardStore(prefs);
      expect(
        store.load('c1', 'default', team: true).encode(),
        HomeBoardLayout.defaults(team: true).encode(),
      );
      expect(store.load('c2', 'default', team: true).items.map((i) => i.kind), [
        HomeWidgetKind.now,
        HomeWidgetKind.today,
      ]);
    });
  });

  group('grid capacity', () {
    test('rows by height: four rows of the designed height, tightened to '
        'reach four on a shorter screen, more on a taller one', () {
      const gap = HomeBoardGridRule.gap;
      double fits(int rows, double row) => rows * row + (rows - 1) * gap;
      // Exactly four designed rows, and anything up to the fifth.
      expect(HomeBoardGridRule.rowsFor(fits(4, 152)), 4);
      expect(HomeBoardGridRule.rowsFor(fits(5, 152) - 1), 4);
      expect(HomeBoardGridRule.rowsFor(fits(5, 152)), 5);
      expect(HomeBoardGridRule.rowsFor(fits(6, 152)), 6);
      // Short of four designed rows: the rows tighten down to 140.
      expect(HomeBoardGridRule.rowsFor(fits(4, 152) - 1), 4);
      expect(HomeBoardGridRule.rowsFor(fits(4, 140)), 4);
      expect(HomeBoardGridRule.rowsFor(fits(4, 140) - 1), 3);
      // Never more than four by tightening.
      expect(HomeBoardGridRule.rowsFor(fits(3, 152)), 3);
      expect(HomeBoardGridRule.rowsFor(fits(3, 140)), 3);
      expect(HomeBoardGridRule.rowsFor(fits(3, 140) - 1), 2);
      expect(HomeBoardGridRule.rowsFor(fits(2, 140)), 2);
      expect(HomeBoardGridRule.rowsFor(fits(1, 140)), 1);
      // Always at least one row.
      expect(HomeBoardGridRule.rowsFor(80), 1);
      expect(HomeBoardGridRule.rowsFor(0), 1);
    });

    test('a notice above the board tightens its rows before it takes one', () {
      double fits(int rows, double row) =>
          rows * row + (rows - 1) * HomeBoardGridRule.gap;
      const tight = HomeBoardGridRule.tightRowHeight;
      expect(tight, 104);
      final open = fits(4, 165);
      // Nothing above: the rule of the open board.
      expect(HomeBoardGridRule.rowsUnder(open, open), 4);
      // The four rows stay, down to the tight height each.
      expect(HomeBoardGridRule.rowsUnder(fits(4, 140) - 1, open), 4);
      expect(HomeBoardGridRule.rowsUnder(fits(4, tight), open), 4);
      expect(
        HomeBoardGridRule.rowHeightFor(fits(4, tight), 4),
        closeTo(tight, 0.001),
      );
      // Past that a row goes, and the ones left are roomy again.
      expect(HomeBoardGridRule.rowsUnder(fits(4, tight) - 1, open), 3);
      expect(HomeBoardGridRule.rowsUnder(fits(3, tight) - 1, open), 2);
      expect(HomeBoardGridRule.rowsUnder(fits(2, tight) - 1, open), 1);
      expect(HomeBoardGridRule.rowsUnder(0, open), 1);
      // Never more rows than the open board has.
      expect(HomeBoardGridRule.rowsUnder(fits(3, 152), fits(3, 152)), 3);
      expect(HomeBoardGridRule.rowsUnder(fits(5, 152), fits(5, 152)), 5);
      expect(HomeBoardGridRule.rowsUnder(fits(5, tight), fits(5, 152)), 5);
    });

    test('the rows share the height they are given', () {
      const gap = HomeBoardGridRule.gap;
      expect(HomeBoardGridRule.rowHeightFor(4 * 160 + 3 * gap, 4), 160);
      expect(HomeBoardGridRule.rowHeightFor(700, 4), closeTo(166.75, 0.01));
      expect(HomeBoardGridRule.rowHeightFor(0, 1), 0);
    });

    test('a size takes one, two or four slots', () {
      expect(_small.slots, 1);
      expect(_wide.slots, 2);
      expect(_large.slots, 4);
    });

    test('two smalls share a row; a wide takes a row; a later small fills '
        'the hole in order', () {
      final plan = HomeBoardPlan.of([
        _w('a', HomeWidgetKind.cron, _small),
        _w('b', HomeWidgetKind.now, _wide),
        _w('c', HomeWidgetKind.tasks, _small),
        _w('d', HomeWidgetKind.team, _large),
      ], 4);
      expect(plan.slots, const [
        HomeBoardSlot(col: 0, row: 0, cols: 1, rows: 1),
        HomeBoardSlot(col: 0, row: 1, cols: 2, rows: 1),
        HomeBoardSlot(col: 1, row: 0, cols: 1, rows: 1),
        HomeBoardSlot(col: 0, row: 2, cols: 2, rows: 2),
      ]);
      expect(plan.capacity, 8);
      expect(plan.used, 8);
      expect(plan.free, 0);
      expect(plan.full, isTrue);
      expect(plan.holes, isEmpty);
      expect(plan.hidden, isEmpty);
    });

    test('a size with no place left is shown smaller, and grows back; with '
        'no place at any size the widget waits, in its place in the order', () {
      final items = [
        _w('a', HomeWidgetKind.now, _wide),
        _w('b', HomeWidgetKind.team, _large),
        _w('c', HomeWidgetKind.continueChats, _large),
        _w('d', HomeWidgetKind.cron, _small),
        _w('e', HomeWidgetKind.room, _wide),
        _w('f', HomeWidgetKind.tasks, _small),
      ];
      final plan = HomeBoardPlan.of(items, 4);
      // The last row takes Chats, wide instead of large; nothing is left
      // for the three after it.
      expect(plan.placed.map((i) => i.id), ['a', 'b', 'c']);
      expect(
        plan.slots.last,
        const HomeBoardSlot(col: 0, row: 3, cols: 2, rows: 1),
      );
      expect(plan.shownSize('c'), _wide);
      expect(plan.shownSize('b'), _large);
      expect(plan.shown.map((i) => i.size), [_wide, _large, _wide]);
      // What the layout stores is untouched.
      expect(plan.placed.map((i) => i.size), [_wide, _large, _large]);
      expect(plan.shrunk, isTrue);
      expect(plan.hidden.map((i) => i.id), ['d', 'e', 'f']);
      expect(plan.full, isTrue);
      expect(plan.shows('d'), isFalse);
      expect(plan.slotOf('d'), isNull);
      expect(plan.shownSize('d'), isNull);
      // A taller screen brings everything back at its own size, in order.
      final tall = HomeBoardPlan.of(items, 7);
      expect(tall.placed.map((i) => i.id), ['a', 'b', 'c', 'd', 'e', 'f']);
      expect(tall.shown.map((i) => i.size), items.map((i) => i.size));
      expect(tall.shrunk, isFalse);
      expect(tall.hidden, isEmpty);
      // A shorter one shows less, never reorders.
      final short = HomeBoardPlan.of(items, 2);
      expect(short.placed.map((i) => i.id), ['a', 'b']);
      expect(short.shownSize('b'), _wide);
      expect(short.hidden.map((i) => i.id), ['c', 'd', 'e', 'f']);
    });

    test('a widget is only shown at a size its kind offers', () {
      // Servidor comes small or wide; a wide one in one free cell is small.
      final plan = HomeBoardPlan.of([
        _w('a', HomeWidgetKind.cron, _small),
        _w('s', HomeWidgetKind.server, _wide),
      ], 1);
      expect(plan.shownSize('s'), _small);
      expect(plan.hidden, isEmpty);
    });

    test('holes are the free cells; a new widget fits only where a hole '
        'has its shape', () {
      final plan = HomeBoardPlan.of([
        _w('a', HomeWidgetKind.now, _wide),
        _w('b', HomeWidgetKind.continueChats, _wide),
        _w('c', HomeWidgetKind.team, _small),
        _w('d', HomeWidgetKind.cron, _small),
        _w('e', HomeWidgetKind.tasks, _small),
      ], 4);
      expect(plan.holes, const [
        HomeBoardSlot(col: 1, row: 3, cols: 1, rows: 1),
      ]);
      expect(plan.free, 1);
      expect(plan.used, 7);
      expect(plan.full, isFalse);
      expect(plan.fits(_small), isTrue);
      expect(plan.fits(_wide), isFalse);
      expect(plan.fits(_large), isFalse);

      // Two free cells in different rows are not room for a wide one.
      final split = HomeBoardPlan.of([
        _w('a', HomeWidgetKind.cron, _small),
        _w('b', HomeWidgetKind.now, _wide),
        _w('c', HomeWidgetKind.team, _wide),
        _w('d', HomeWidgetKind.continueChats, _wide),
        _w('e', HomeWidgetKind.tasks, _small),
      ], 4);
      expect(split.free, 0);
      final loose = HomeBoardPlan.of([
        _w('a', HomeWidgetKind.cron, _small),
        _w('b', HomeWidgetKind.now, _wide),
        _w('c', HomeWidgetKind.team, _wide),
        _w('d', HomeWidgetKind.continueChats, _wide),
      ], 4);
      expect(loose.free, 1);
      expect(loose.fits(_wide), isFalse);

      final empty = HomeBoardPlan.of(const [], 4);
      expect(empty.free, 8);
      expect(empty.fits(_large), isTrue);
      final oneRow = HomeBoardPlan.of(const [], 1);
      expect(oneRow.fits(_wide), isTrue);
      expect(oneRow.fits(_large), isFalse);
    });

    test('a size is allowed only when everything on the board stays on it', () {
      // Full board: Ahora wide, Chats wide, Bots wide, Cron and Tareas.
      final full = [
        _w('now', HomeWidgetKind.now, _wide),
        _w('chats', HomeWidgetKind.continueChats, _wide),
        _w('bots', HomeWidgetKind.team, _wide),
        _w('cron', HomeWidgetKind.cron, _small),
        _w('tasks', HomeWidgetKind.tasks, _small),
      ];
      expect(HomeBoardPlan.of(full, 4).full, isTrue);
      expect(HomeBoardPlan.allows(full, 4, 'bots', _small), isTrue);
      expect(HomeBoardPlan.allows(full, 4, 'bots', _wide), isTrue);
      expect(HomeBoardPlan.allows(full, 4, 'bots', _large), isFalse);
      expect(HomeBoardPlan.allows(full, 4, 'cron', _wide), isFalse);
      // With a row to spare the large one fits.
      expect(HomeBoardPlan.allows(full, 6, 'bots', _large), isTrue);

      // A widget shown smaller than it stores: only the size it is shown
      // at, or a smaller one.
      final over = [
        ...full.take(3),
        _w('cron', HomeWidgetKind.cron, _small),
        _w('rooms', HomeWidgetKind.room, _large),
      ];
      final plan = HomeBoardPlan.of(over, 4);
      expect(plan.hidden, isEmpty);
      expect(plan.shownSize('rooms'), _small);
      expect(HomeBoardPlan.allows(over, 4, 'rooms', _small), isTrue);
      expect(HomeBoardPlan.allows(over, 4, 'rooms', _wide), isFalse);
      expect(HomeBoardPlan.allows(over, 4, 'rooms', _large), isFalse);

      // Growing one widget must not make another smaller.
      final tight = [
        _w('now', HomeWidgetKind.now, _wide),
        _w('bots', HomeWidgetKind.team, _wide),
        _w('chats', HomeWidgetKind.continueChats, _large),
      ];
      expect(HomeBoardPlan.of(tight, 4).shrunk, isFalse);
      expect(HomeBoardPlan.allows(tight, 4, 'bots', _large), isFalse);
      expect(HomeBoardPlan.allows(tight, 4, 'bots', _small), isTrue);
      // One more row and both are large.
      expect(HomeBoardPlan.allows(tight, 5, 'bots', _large), isTrue);
    });
  });

  group('Salas follows the liveliest rooms, or the ones chosen', () {
    test('a layout stored before multi-room still reads its room', () {
      const legacy = HomeWidgetInstance(
        id: 'r',
        kind: HomeWidgetKind.room,
        size: HomeWidgetSize.wide,
        options: {'room': 'room-devs'},
      );
      expect(legacy.roomKeys, ['room-devs']);
      final migrated = legacy.withRooms(['room-devs', 'room-ops']);
      expect(migrated.roomKeys, ['room-devs', 'room-ops']);
      expect(migrated.options.containsKey('room'), isFalse);
    });

    test('withRooms keeps the order, drops duplicates and blanks, caps at '
        'three; none chosen is none stored', () {
      const item = HomeWidgetInstance(
        id: 'r',
        kind: HomeWidgetKind.room,
        size: HomeWidgetSize.wide,
      );
      expect(item.roomKeys, isEmpty);
      final many = item.withRooms(['b', 'a', 'b', ' ', 'c', 'd']);
      expect(many.roomKeys, ['b', 'a', 'c']);
      expect(HomeWidgetInstance.maxRooms, 3);
      final none = many.withRooms(const []);
      expect(none.roomKeys, isEmpty);
      expect(none.options.containsKey('rooms'), isFalse);
    });

    test('two multi-room instances survive the stored round trip', () {
      final layout = HomeBoardLayout([
        const HomeWidgetInstance(
          id: 'r1',
          kind: HomeWidgetKind.room,
          size: HomeWidgetSize.wide,
        ).withRooms(['room-devs', 'room-ops']),
        const HomeWidgetInstance(
          id: 'r2',
          kind: HomeWidgetKind.room,
          size: HomeWidgetSize.small,
        ).withRooms(['room-qa']),
      ]);
      final decoded = HomeBoardLayout.decode(layout.encode())!;
      expect(decoded.items.map((i) => i.roomKeys), [
        ['room-devs', 'room-ops'],
        ['room-qa'],
      ]);
    });
  });
}
