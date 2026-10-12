/// Home widget board (Inicio v4, direction A): which widgets the user put
/// on Home, in what order, at what size and with which options.
///
/// Pure data. Persisted on the device per connection + profile by
/// [HomeBoardStore]; nothing here is read from or sent to the server.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'home_board_catalog.dart';

/// Every widget type Home offers. The wire name ([name]) is what the stored
/// layout carries, so names are only ever added, never renamed or reused;
/// the names of retired kinds keep reading as their successor
/// ([HomeWidgetKind.fromWire]).
enum HomeWidgetKind {
  /// «Bots»: the bots with their state; large, one row per bot.
  team,

  /// «Bot»: one bot.
  bot,

  /// «Salas»: the rooms with who replies, who is next and what is unread.
  room,

  /// «Chat»: one pinned chat.
  chat,

  /// «Chats»: the most recent chats with their live state.
  continueChats,

  /// «Límites del plan».
  planLimits,

  /// «Servidor».
  server,

  /// «Hoy»: activity of today.
  today,

  /// «Ahora»: what needs the user, else what runs, else calm.
  now,

  /// «Cron»: the next run; bigger, the jobs by next run.
  cron,

  /// «Tareas»: the Kanban board, in progress and pending.
  tasks;

  /// Wire names of kinds that no longer exist, and the kind an instance
  /// stored under one becomes: «Lo siguiente» (`glance`) and «Te necesita»
  /// (`needsYou`) are «Ahora»; «Próxima» (`nextAutomation`) and
  /// «Automatizaciones» (`automations`) are «Cron».
  static const retired = <String, HomeWidgetKind>{
    'glance': HomeWidgetKind.now,
    'needsYou': HomeWidgetKind.now,
    'nextAutomation': HomeWidgetKind.cron,
    'automations': HomeWidgetKind.cron,
  };

  /// The kind stored as [raw], following [retired] names; null for a name
  /// this version does not know.
  static HomeWidgetKind? fromWire(Object? raw) {
    for (final kind in HomeWidgetKind.values) {
      if (kind.name == raw) return kind;
    }
    return retired[raw];
  }
}

/// Grid footprint: small 1×1, wide 2×1, large 2×2 (two columns).
enum HomeWidgetSize {
  small(1, 1),
  wide(2, 1),
  large(2, 2);

  const HomeWidgetSize(this.cols, this.rows);
  final int cols;
  final int rows;

  /// Cells of the grid it takes: small 1, wide 2, large 4.
  int get slots => cols * rows;
}

HomeWidgetSize? _sizeByName(Object? raw) {
  for (final size in HomeWidgetSize.values) {
    if (size.name == raw) return size;
  }
  return null;
}

/// One widget on the board.
@immutable
final class HomeWidgetInstance {
  /// Device-local identity, stable across edits and restarts.
  final String id;
  final HomeWidgetKind kind;
  final HomeWidgetSize size;

  /// Instance settings (e.g. `room`, `bot`, `chat`, `job`, `bots`,
  /// `onlyWorking`). Only identifiers and flags, never content.
  final Map<String, Object?> options;

  const HomeWidgetInstance({
    required this.id,
    required this.kind,
    required this.size,
    this.options = const {},
  });

  HomeWidgetInstance copyWith({
    HomeWidgetSize? size,
    Map<String, Object?>? options,
  }) => HomeWidgetInstance(
    id: id,
    kind: kind,
    size: size ?? this.size,
    options: options ?? this.options,
  );

  String? stringOption(String key) {
    final value = options[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  bool boolOption(String key) => options[key] == true;

  /// Most rooms one «Sala» widget follows.
  static const maxRooms = 3;

  /// Rooms a «Sala» follows, in the user's order: `rooms` (up to
  /// [maxRooms], duplicates dropped), else the single `room` of layouts
  /// stored before multi-room.
  List<String> get roomKeys {
    final keys = <String>[];
    for (final key in listOption('rooms') ?? const <String>[]) {
      if (key.trim().isEmpty || keys.contains(key)) continue;
      keys.add(key);
      if (keys.length == maxRooms) break;
    }
    if (keys.isEmpty) {
      final legacy = stringOption('room');
      if (legacy != null) keys.add(legacy);
    }
    return keys;
  }

  /// The same instance following [keys] (stored as `rooms`; the legacy
  /// `room` is dropped).
  HomeWidgetInstance withRooms(List<String> keys) {
    final options = Map<String, Object?>.of(this.options)..remove('room');
    final unique = <String>[];
    for (final key in keys) {
      if (key.trim().isEmpty || unique.contains(key)) continue;
      unique.add(key);
      if (unique.length == maxRooms) break;
    }
    if (unique.isEmpty) {
      options.remove('rooms');
    } else {
      options['rooms'] = List<String>.unmodifiable(unique);
    }
    return copyWith(options: Map.unmodifiable(options));
  }

  List<String>? listOption(String key) {
    final value = options[key];
    if (value is! List) return null;
    return [
      for (final v in value)
        if (v is String) v,
    ];
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'size': size.name,
    if (options.isNotEmpty) 'options': options,
  };

  /// Null for anything that is not a usable item of a known kind.
  static HomeWidgetInstance? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final kind = HomeWidgetKind.fromWire(raw['kind']);
    if (id is! String || id.isEmpty || kind == null) return null;
    final spec = HomeWidgetCatalog.of(kind);
    final size = _sizeByName(raw['size']);
    final rawOptions = raw['options'];
    final options = <String, Object?>{};
    if (rawOptions is Map) {
      for (final entry in rawOptions.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String) continue;
        if (value is String || value is bool || value is num) {
          options[key] = value;
        } else if (value is List) {
          options[key] = [
            for (final v in value)
              if (v is String) v,
          ];
        }
      }
    }
    return HomeWidgetInstance(
      id: id,
      kind: kind,
      size: size != null && spec.sizes.contains(size) ? size : spec.defaultSize,
      options: Map.unmodifiable(options),
    );
  }
}

/// The ordered board. Every operation returns a new layout; an operation
/// that does not apply returns `this`.
@immutable
final class HomeBoardLayout {
  /// Stored format version. A newer stored version is not trusted (the
  /// default layout is used instead).
  static const version = 1;

  final List<HomeWidgetInstance> items;

  /// «Widgets en color» off: every widget is neutral (no identity tint).
  final bool neutral;

  HomeBoardLayout(List<HomeWidgetInstance> items, {this.neutral = false})
    : items = List.unmodifiable(items);

  HomeBoardLayout withNeutral(bool value) =>
      value == neutral ? this : HomeBoardLayout(items, neutral: value);

  /// What a board nobody arranged shows. With bots or rooms ([team]):
  /// Ahora wide, Bots large, then Salas and Cron side by side. Without
  /// them (one agent): Ahora wide, Chats large, then Cron and Tareas.
  ///
  /// The ids are fixed, so the board is the same one on every build until
  /// the user changes it (and it is stored).
  factory HomeBoardLayout.defaults({required bool team}) => HomeBoardLayout([
    const HomeWidgetInstance(
      id: 'default-now',
      kind: HomeWidgetKind.now,
      size: HomeWidgetSize.wide,
    ),
    if (team) ...const [
      HomeWidgetInstance(
        id: 'default-bots',
        kind: HomeWidgetKind.team,
        size: HomeWidgetSize.large,
      ),
      HomeWidgetInstance(
        id: 'default-rooms',
        kind: HomeWidgetKind.room,
        size: HomeWidgetSize.small,
      ),
      HomeWidgetInstance(
        id: 'default-cron',
        kind: HomeWidgetKind.cron,
        size: HomeWidgetSize.small,
      ),
    ] else ...const [
      HomeWidgetInstance(
        id: 'default-chats',
        kind: HomeWidgetKind.continueChats,
        size: HomeWidgetSize.large,
      ),
      HomeWidgetInstance(
        id: 'default-cron',
        kind: HomeWidgetKind.cron,
        size: HomeWidgetSize.small,
      ),
      HomeWidgetInstance(
        id: 'default-tasks',
        kind: HomeWidgetKind.tasks,
        size: HomeWidgetSize.small,
      ),
    ],
  ]);

  /// The default board of the versions before «Ahora», as stored (wire
  /// names and sizes, in order).
  static const _formerDefault = <(String, String)>[
    ('glance', 'wide'),
    ('continueChats', 'wide'),
    ('team', 'wide'),
    ('nextAutomation', 'small'),
    ('today', 'small'),
  ];

  /// Whether [rawItems] is the former default exactly as it was made: the
  /// same widgets, sizes and order, nothing configured.
  static bool _isFormerDefault(
    List<Object?> rawItems, {
    required bool neutral,
  }) {
    if (neutral || rawItems.length != _formerDefault.length) return false;
    for (var i = 0; i < rawItems.length; i++) {
      final raw = rawItems[i];
      if (raw is! Map) return false;
      final (kind, size) = _formerDefault[i];
      final options = raw['options'];
      if (raw['kind'] != kind ||
          raw['size'] != size ||
          (options is Map && options.isNotEmpty)) {
        return false;
      }
    }
    return true;
  }

  int indexOf(String id) => items.indexWhere((i) => i.id == id);

  HomeWidgetInstance? byId(String id) {
    final at = indexOf(id);
    return at < 0 ? null : items[at];
  }

  bool contains(HomeWidgetKind kind) => items.any((i) => i.kind == kind);

  /// Appends a widget (the grid backfills the first hole). A second copy
  /// of a single-instance kind is refused.
  HomeBoardLayout add(
    HomeWidgetKind kind, {
    required String Function() newId,
    HomeWidgetSize? size,
    Map<String, Object?> options = const {},
  }) {
    final spec = HomeWidgetCatalog.of(kind);
    if (!spec.multiInstance && contains(kind)) return this;
    final chosen = size != null && spec.sizes.contains(size)
        ? size
        : spec.defaultSize;
    return HomeBoardLayout(neutral: neutral, [
      ...items,
      HomeWidgetInstance(
        id: newId(),
        kind: kind,
        size: chosen,
        options: Map.unmodifiable(options),
      ),
    ]);
  }

  HomeBoardLayout remove(String id) {
    if (indexOf(id) < 0) return this;
    return HomeBoardLayout(neutral: neutral, [
      for (final i in items)
        if (i.id != id) i,
    ]);
  }

  /// Moves [id] to [index] (clamped), keeping the others in order.
  HomeBoardLayout move(String id, int index) {
    final from = indexOf(id);
    if (from < 0) return this;
    final list = [...items];
    final item = list.removeAt(from);
    final to = index.clamp(0, list.length);
    if (to == from) return this;
    list.insert(to, item);
    return HomeBoardLayout(list, neutral: neutral);
  }

  HomeBoardLayout resize(String id, HomeWidgetSize size) {
    final at = indexOf(id);
    if (at < 0) return this;
    final item = items[at];
    if (item.size == size ||
        !HomeWidgetCatalog.of(item.kind).sizes.contains(size)) {
      return this;
    }
    return _replace(at, item.copyWith(size: size));
  }

  HomeBoardLayout configure(String id, Map<String, Object?> options) {
    final at = indexOf(id);
    if (at < 0) return this;
    return _replace(at, items[at].copyWith(options: Map.unmodifiable(options)));
  }

  HomeBoardLayout _replace(int at, HomeWidgetInstance item) =>
      HomeBoardLayout([...items]..[at] = item, neutral: neutral);

  String encode() => jsonEncode({
    'v': version,
    if (neutral) 'neutral': true,
    'items': [for (final i in items) i.toJson()],
  });

  /// Null when [raw] is not a layout this version can read, or when it is
  /// the former default untouched (the board then follows today's default).
  ///
  /// Instances stored under a retired kind become its successor in place,
  /// with their id, size and options ([HomeWidgetKind.retired]); unknown
  /// kinds are dropped, invalid sizes repaired, duplicate ids and second
  /// copies of single-instance kinds dropped.
  static HomeBoardLayout? decode(String raw) {
    Object? json;
    try {
      json = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (json is! Map) return null;
    final v = json['v'];
    final rawItems = json['items'];
    if (v is! int || v < 1 || v > version || rawItems is! List) return null;
    final neutral = json['neutral'] == true;
    if (_isFormerDefault(rawItems, neutral: neutral)) return null;
    final ids = <String>{};
    final singles = <HomeWidgetKind>{};
    final items = <HomeWidgetInstance>[];
    for (final rawItem in rawItems) {
      final item = HomeWidgetInstance.tryParse(rawItem);
      if (item == null || !ids.add(item.id)) continue;
      if (!HomeWidgetCatalog.of(item.kind).multiInstance &&
          !singles.add(item.kind)) {
        continue;
      }
      items.add(item);
    }
    return HomeBoardLayout(items, neutral: neutral);
  }
}

/// Where one widget sits on the two-column grid.
@immutable
final class HomeBoardSlot {
  final int col;
  final int row;
  final int cols;
  final int rows;

  const HomeBoardSlot({
    required this.col,
    required this.row,
    required this.cols,
    required this.rows,
  });

  @override
  bool operator ==(Object other) =>
      other is HomeBoardSlot &&
      other.col == col &&
      other.row == row &&
      other.cols == cols &&
      other.rows == rows;

  @override
  int get hashCode => Object.hash(col, row, cols, rows);

  @override
  String toString() => 'HomeBoardSlot($col,$row ${cols}x$rows)';
}

/// The board is a grid of whole rows that never scrolls: two columns and
/// as many rows as fit between the header and the dock.
abstract final class HomeBoardGridRule {
  static const columns = 2;

  /// Space between cells.
  static const gap = 11.0;

  /// Row height the widgets were designed at.
  static const rowHeight = 152.0;

  /// The least a row of the open board is.
  static const minRowHeight = 140.0;

  /// Rows of the board as designed (eight slots on a regular phone).
  static const designRows = 4;

  /// The least a row is tightened to while a notice sits above the board
  /// ([rowsUnder]): its widgets show less, and all of them stay.
  static const tightRowHeight = 104.0;

  /// Whole rows that fit in [height]: as many of [rowHeight] as fit; a
  /// screen short of [designRows] tightens the rows down to
  /// [minRowHeight] to reach them. Never fewer than one.
  static int rowsFor(double height) {
    int at(double row) => ((height + gap) / (row + gap)).floor();
    var rows = at(rowHeight);
    if (rows < designRows) rows = at(minRowHeight).clamp(rows, designRows);
    return rows < 1 ? 1 : rows;
  }

  /// Rows in [height] when a notice above the board has taken it down
  /// from [open]: the rows the open board has, as long as each one keeps
  /// [tightRowHeight], so a notice that comes and goes does not take
  /// widgets with it. A notice too tall for that leaves fewer rows.
  static int rowsUnder(double height, double open) {
    final least = rowsFor(height);
    for (var rows = rowsFor(open); rows > least; rows--) {
      if (rowHeightFor(height, rows) >= tightRowHeight) return rows;
    }
    return least;
  }

  /// Height of each of [rows] sharing [height].
  static double rowHeightFor(double height, int rows) {
    final each = (height - gap * (rows - 1)) / rows;
    return each < 0 ? 0 : each;
  }
}

/// Where the widgets of a layout go on a board of [rows] rows.
///
/// Dense first-fit in board order: each widget takes the first free place
/// it fits, so a small one fills the hole a wide one left without the
/// order changing. A widget whose size has no place left is shown at the
/// largest smaller size that has one (what it stores does not change: it
/// grows back when there is room); with no place at any size it is
/// [hidden]: it stays in the layout, in its place in the order, and comes
/// back as soon as it fits (a taller screen, something removed).
@immutable
final class HomeBoardPlan {
  final int rows;

  /// Widgets on the board, in board order, as the layout stores them, and
  /// where each one sits ([shown] has them at the size of their place).
  final List<HomeWidgetInstance> placed;
  final List<HomeBoardSlot> slots;

  /// Widgets that do not fit, in board order.
  final List<HomeWidgetInstance> hidden;

  /// Free cells, top to bottom and left to right.
  final List<HomeBoardSlot> holes;

  const HomeBoardPlan._({
    required this.rows,
    required this.placed,
    required this.slots,
    required this.hidden,
    required this.holes,
  });

  factory HomeBoardPlan.of(List<HomeWidgetInstance> items, int rows) {
    const columns = HomeBoardGridRule.columns;
    final taken = [for (var r = 0; r < rows; r++) List.filled(columns, false)];
    final placed = <HomeWidgetInstance>[];
    final slots = <HomeBoardSlot>[];
    final hidden = <HomeWidgetInstance>[];
    HomeBoardSlot? place(HomeWidgetSize size) {
      for (var row = 0; row + size.rows <= rows; row++) {
        for (var col = 0; col + size.cols <= columns; col++) {
          var free = true;
          for (var r = row; r < row + size.rows && free; r++) {
            for (var c = col; c < col + size.cols; c++) {
              if (taken[r][c]) {
                free = false;
                break;
              }
            }
          }
          if (free) {
            return HomeBoardSlot(
              col: col,
              row: row,
              cols: size.cols,
              rows: size.rows,
            );
          }
        }
      }
      return null;
    }

    for (final item in items) {
      HomeBoardSlot? slot;
      // Its own size first, then the smaller ones its kind offers.
      for (final size in HomeWidgetSize.values.reversed) {
        if (size.slots > item.size.slots ||
            !HomeWidgetCatalog.of(item.kind).sizes.contains(size)) {
          continue;
        }
        slot = place(size);
        if (slot != null) break;
      }
      if (slot == null) {
        hidden.add(item);
        continue;
      }
      for (var r = slot.row; r < slot.row + slot.rows; r++) {
        for (var c = slot.col; c < slot.col + slot.cols; c++) {
          taken[r][c] = true;
        }
      }
      placed.add(item);
      slots.add(slot);
    }
    return HomeBoardPlan._(
      rows: rows,
      placed: List.unmodifiable(placed),
      slots: List.unmodifiable(slots),
      hidden: List.unmodifiable(hidden),
      holes: List.unmodifiable([
        for (var r = 0; r < rows; r++)
          for (var c = 0; c < columns; c++)
            if (!taken[r][c]) HomeBoardSlot(col: c, row: r, cols: 1, rows: 1),
      ]),
    );
  }

  /// Slots of the board.
  int get capacity => rows * HomeBoardGridRule.columns;

  /// Slots without a widget.
  int get free => holes.length;
  int get used => capacity - free;
  bool get full => free == 0;

  HomeBoardSlot? slotOf(String id) {
    final at = placed.indexWhere((i) => i.id == id);
    return at < 0 ? null : slots[at];
  }

  static HomeWidgetSize _sizeOf(HomeBoardSlot slot) => HomeWidgetSize.values
      .firstWhere((s) => s.cols == slot.cols && s.rows == slot.rows);

  /// The size [id] is shown at: its own, or a smaller one when its own
  /// has no place. Null while it is hidden.
  HomeWidgetSize? shownSize(String id) => switch (slotOf(id)) {
    final slot? => _sizeOf(slot),
    null => null,
  };

  /// The widgets on the board at the size each one is shown at.
  List<HomeWidgetInstance> get shown => [
    for (final (i, item) in placed.indexed)
      item.size == _sizeOf(slots[i])
          ? item
          : item.copyWith(size: _sizeOf(slots[i])),
  ];

  /// Whether some widget is shown smaller than it is stored.
  bool get shrunk =>
      placed.indexed.any((e) => e.$2.size != _sizeOf(slots[e.$1]));

  bool shows(String id) => placed.any((i) => i.id == id);

  /// Whether one more widget of [size], added last, gets a place.
  bool fits(HomeWidgetSize size) {
    const columns = HomeBoardGridRule.columns;
    final free = {for (final h in holes) (h.col, h.row)};
    for (var row = 0; row + size.rows <= rows; row++) {
      for (var col = 0; col + size.cols <= columns; col++) {
        var ok = true;
        for (var r = row; r < row + size.rows && ok; r++) {
          for (var c = col; c < col + size.cols; c++) {
            if (!free.contains((c, r))) {
              ok = false;
              break;
            }
          }
        }
        if (ok) return true;
      }
    }
    return false;
  }

  /// Whether [id] can take [size] on a board of [rows]: it is then shown
  /// at exactly that size, and every widget the board shows now is still
  /// shown, none smaller than it is now.
  static bool allows(
    List<HomeWidgetInstance> items,
    int rows,
    String id,
    HomeWidgetSize size,
  ) {
    final before = HomeBoardPlan.of(items, rows);
    final after = HomeBoardPlan.of([
      for (final i in items) i.id == id ? i.copyWith(size: size) : i,
    ], rows);
    if (after.shownSize(id) != size) return false;
    for (final item in before.placed) {
      if (item.id == id) continue;
      final now = after.shownSize(item.id);
      if (now == null || now.slots < before.shownSize(item.id)!.slots) {
        return false;
      }
    }
    return true;
  }
}
