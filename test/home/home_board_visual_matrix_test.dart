// The Home board's visual layer, tile by tile and state by state: nothing
// overflows its cell, no text is cut or laid over another, every tile sits
// inside the board clear of the next one, the header and the dock, at the
// widths of a narrow phone to a tablet, at 1x, 1.3x and 2x text, in the
// four themes and in the nine languages, with hostile data.
//
// With a shots directory (DESIGN_SHOTS_DIR, or an `evidence` directory
// beside the project, as the gate has) it also writes PNGs of a curated
// set, to be looked at. Without one it is a plain layout test.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_view.dart';
import 'package:hermes_android/core/home/home_now.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/account_usage_fixtures.dart';
import '../support/design_shots.dart' show loadDesignFonts;
import '../support/home_board_fixtures.dart';

// ── the matrix ─────────────────────────────────────────────────────────

/// The states a tile can be in.
enum _Mood { calm, asks, working, offline, unconfigured, empty }

/// Data that is hard on a layout.
enum _Hostile {
  none,
  longName,
  emoji,
  noTitle,
  bigCounts,
  longTime,
  zero,
  many,
}

const _widths = [320.0, 360.0, 390.0, 412.0, 600.0, 840.0, 1100.0, 1248.0];
const _scales = [1.0, 1.3, 2.0];
const _themes = ['console', 'console-light', 'midnight', 'midnight-light'];
const _langs = ['es', 'en', 'de', 'ja', 'zh'];
const _allLangs = ['es', 'en', 'de', 'fr', 'it', 'ja', 'ko', 'pt', 'zh'];

// This matrix exercises layouts, not theme construction. Reusing immutable
// themes also lets their palette/material caches work across thousands of cases.
final _themeData = <String, ThemeData>{};
const _kinds = HomeWidgetKind.values;

const _longName = 'Agente de nombre extraordinariamente largo';
const _emoji = '🚀 Lanzar la versión 1.4.0 con 🎉 confeti y 🦊';

String _name(_Hostile h, String plain) => switch (h) {
  _Hostile.longName => _longName,
  _ => plain,
};

String _title(_Hostile h, String plain) => switch (h) {
  _Hostile.emoji => _emoji,
  _Hostile.noTitle => '',
  _Hostile.longName => '$_longName · $plain',
  _ => plain,
};

int _count(_Hostile h, int plain) => switch (h) {
  _Hostile.bigCounts => 120,
  _Hostile.zero => 0,
  _Hostile.many => 50,
  _ => plain,
};

DateTime _next(_Hostile h, Duration plain) => switch (h) {
  _Hostile.longTime => homeIn(const Duration(days: 40, hours: 13)),
  _ => homeIn(plain),
};

HomeAutomation _job(
  String key,
  String name, {
  DateTime? next,
  bool failed = false,
  int? every,
  DateTime? last,
}) => HomeAutomation(
  key: key,
  name: name,
  ref: key,
  nextRun: next,
  failed: failed,
  everyMinutes: every,
  lastRunAt: last,
);

/// The board's data in [mood], twisted by [h].
HomeBoardData _data(_Mood mood, [_Hostile h = _Hostile.none]) {
  final n = _count(h, 3);
  final names = [for (var i = 0; i < n; i++) _name(h, 'Bot $i')];
  final who = names.isEmpty ? 'Hermes' : names.first;
  final last = names.isEmpty ? null : names.last;
  List<T> many<T>(T Function(int i) make) => [
    for (var i = 0; i < n; i++) make(i),
  ];
  final server = HomeBoardServer(
    label: _name(h, 'Casa'),
    online: mood != _Mood.offline,
    version: '1.4.0',
    latencyMs: h == _Hostile.bigCounts ? 12345 : 12,
    updateAvailable: mood == _Mood.asks,
  );
  final today = HomeBoardToday(
    chats: _count(h, 14),
    messages: _count(h, 48),
    tools: _count(h, 9),
  );
  switch (mood) {
    case _Mood.empty:
      return HomeBoardData(
        now: homeFixtureNow,
        automations: const [],
        tasks: const HomeTasks(),
        server: server,
        today: const HomeBoardToday(chats: 0, messages: 0, tools: 0),
        botsLoaded: true,
        roomsState: HomeRoomsState.known,
        mainName: 'Hermes',
      ).withGlance();
    case _Mood.offline:
      return HomeBoardData(
        now: homeFixtureNow,
        chats: many((i) => homeChat('c$i', _title(h, 'Chat $i'))),
        bots: many((i) => homeBot(names[i])),
        automations: null,
        automationsFailed: true,
        tasks: null,
        tasksFailed: true,
        server: server,
        botsLoaded: false,
        roomsState: HomeRoomsState.unavailable,
        roomsFailedReads: 2,
        mainName: 'Hermes',
      ).withGlance();
    case _Mood.unconfigured:
      // The single-target widgets without their target: a bot and a chat
      // that are gone, rooms chosen that no longer exist, a cron fixed to
      // a job that is not there. The data itself is calm.
      return _data(_Mood.calm, h);
    case _Mood.calm:
    case _Mood.asks:
    case _Mood.working:
      final asks = mood == _Mood.asks;
      final working = mood == _Mood.working;
      final chats = many(
        (i) => homeChat(
          'c$i',
          _title(h, 'Conversación $i sobre el viaje'),
          agent: names[i],
          working: working && i.isEven,
          step: working ? _title(h, 'Buscando hoteles') : null,
          asks: asks && i == 1,
          unread: i == 0,
          preview: _title(h, 'Te paso tres hoteles cerca del centro'),
          ago: Duration(minutes: 20 + i * 37),
        ),
      );
      final bots = many(
        (i) => homeBot(
          names[i],
          state: asks && i == 0
              ? HomeBotState.waiting
              : working && i.isEven
              ? HomeBotState.working
              : HomeBotState.idle,
          step: working ? _title(h, 'Informe semanal') : null,
          running: const Duration(minutes: 4, seconds: 13),
          lastTitle: _title(h, 'Recetas de la semana'),
          lastAt: homeAgoAt(Duration(hours: 1 + i)),
        ),
      );
      final rooms = many(
        (i) => homeRoom(
          'r$i',
          _title(h, '#general-$i'),
          members: names.take(3).toList().map((s) => s.toLowerCase()).toList(),
          unread: _count(h, i == 0 ? 2 : 0),
          mentions: asks && i == 0 ? _count(h, 1) : 0,
          replying: working ? who : null,
          next: working ? last : null,
          author: who,
          line: _title(h, 'Lista de la compra lista'),
          lastAt: homeAgoAt(Duration(minutes: 9 + i)),
        ),
      );
      final jobs = many(
        (i) => _job(
          'j$i',
          _title(h, 'Resumen diario $i'),
          next: _next(h, Duration(hours: 2 + i * 3, minutes: 14)),
          failed: asks && i == 1,
          every: i == 0 ? 360 : null,
          last: homeAgoAt(const Duration(hours: 5)),
        ),
      );
      final tasks = HomeTasks(
        running: working || asks
            ? many(
                (i) => homeTask(
                  'k$i',
                  _title(h, 'Preparar la demo $i'),
                  assignee: names[i].toLowerCase(),
                ),
              )
            : const [],
        pending: many((i) => homeTask('p$i', _title(h, 'Reservar hotel $i'))),
      );
      return HomeBoardData(
        now: homeFixtureNow,
        chats: chats,
        bots: bots,
        rooms: rooms,
        approvals: asks
            ? [
                homeApproval(
                  actor: who,
                  command: _title(h, 'git push origin fix/dock'),
                ),
              ]
            : const [],
        questions: asks && n > 1
            ? [
                homeQuestionItem(
                  actor: names[1],
                  question: _title(h, homeQuestion),
                ),
              ]
            : const [],
        automations: jobs,
        tasks: tasks,
        limits: AccountUsageLimits.fromGateway(usage(account: codexLines)),
        server: server,
        today: today,
        botsLoaded: true,
        roomsState: HomeRoomsState.known,
        chatsLoaded: true,
        mainName: _name(h, 'Hermes'),
      ).withGlance();
  }
}

/// Options of a [kind] in [mood]: the targets the single-target widgets
/// follow (the first ones of the data), or gone ones when unconfigured.
Map<String, Object?> _options(HomeWidgetKind kind, _Mood mood) {
  final gone = mood == _Mood.unconfigured;
  return switch (kind) {
    HomeWidgetKind.bot => {'bot': gone ? 'gone' : 'bot 0'},
    HomeWidgetKind.chat => {'chat': gone ? 'gone' : 'c0'},
    HomeWidgetKind.room when gone => {
      'rooms': ['gone'],
    },
    HomeWidgetKind.cron when gone => {'job': 'gone'},
    _ => const {},
  };
}

/// The cell a tile of [size] gets on a board [width] dp wide, with rows
/// of [row] dp: the board's own rule (two columns under 840 dp, four from
/// there, the board's width capped).
Size _cell(HomeWidgetSize size, double width, {double row = 152}) {
  final columns = HomeBoardGridRule.columnsFor(width);
  final board = (width - 2 * HomeBoardMetrics.sidePadding).clamp(
    0.0,
    HomeBoardMetrics.maxWidthFor(columns),
  );
  final cell = (board - HomeBoardGridRule.gap * (columns - 1)) / columns;
  return Size(
    size.cols * cell + (size.cols - 1) * HomeBoardGridRule.gap,
    size.rows * row + (size.rows - 1) * HomeBoardGridRule.gap,
  );
}

// ── pumping ────────────────────────────────────────────────────────────

const _root = ValueKey('matrix-root');
const _tileKey = ValueKey('matrix-tile');
bool _resetScheduled = false;

Future<void> _pumpApp(
  WidgetTester tester,
  Widget body, {
  required Size size,
  String theme = 'console',
  String lang = 'es',
  double scale = 1,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  if (!_resetScheduled) {
    _resetScheduled = true;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(
    RepaintBoundary(
      key: _root,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: Locale(lang),
        theme: _themeData.putIfAbsent(theme, () => AppTheme.fromId(theme)),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        // The edit mode's wiggle turns the texts a little: measured
        // without it (as with «reduce motion»), the boxes are the texts'.
        builder: reduceMotion
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              )
            : null,
        home: Scaffold(body: body),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 120));
}

/// One tile in its cell, at the top start of the page.
Future<void> _pumpTile(
  WidgetTester tester, {
  required HomeWidgetKind kind,
  required HomeWidgetSize size,
  required _Mood mood,
  required double width,
  double row = 152,
  double scale = 1,
  String theme = 'console',
  String lang = 'es',
  _Hostile hostile = _Hostile.none,
  bool editing = false,
}) => _pumpApp(
  tester,
  Align(
    alignment: AlignmentDirectional.topStart,
    child: Padding(
      padding: const EdgeInsets.all(HomeBoardMetrics.sidePadding),
      child: homeTile(
        key: _tileKey,
        kind: kind,
        size: size,
        data: _data(mood, hostile),
        actions: HomeCalls().actions,
        options: _options(kind, mood),
        editing: editing,
        cell: _cell(size, width, row: row),
      ),
    ),
  ),
  size: Size(width, 900),
  theme: theme,
  lang: lang,
  scale: scale,
);

/// The designed boards: the phone's six, the wide one's ten.
HomeBoardLayout _layout(double width) {
  HomeWidgetInstance w(
    String id,
    HomeWidgetKind kind,
    HomeWidgetSize size, [
    Map<String, Object?> options = const {},
  ]) => HomeWidgetInstance(id: id, kind: kind, size: size, options: options);
  final wide = HomeBoardGridRule.columnsFor(width) == 4;
  return HomeBoardLayout([
    w('now', HomeWidgetKind.now, HomeWidgetSize.wide),
    if (wide) w('chats', HomeWidgetKind.continueChats, HomeWidgetSize.large),
    w('cron', HomeWidgetKind.cron, HomeWidgetSize.small),
    w('tasks', HomeWidgetKind.tasks, HomeWidgetSize.small),
    if (!wide) w('chats', HomeWidgetKind.continueChats, HomeWidgetSize.wide),
    w(
      'bots',
      HomeWidgetKind.team,
      wide ? HomeWidgetSize.wide : HomeWidgetSize.small,
    ),
    if (wide) w('limits', HomeWidgetKind.planLimits, HomeWidgetSize.wide),
    w('today', HomeWidgetKind.today, HomeWidgetSize.small),
    if (wide) w('server', HomeWidgetKind.server, HomeWidgetSize.small),
    if (wide) w('rooms', HomeWidgetKind.room, HomeWidgetSize.small),
    if (wide)
      w('bot', HomeWidgetKind.bot, HomeWidgetSize.small, {'bot': 'bot 0'}),
  ]);
}

const _headerKey = ValueKey('matrix-header');
const _dockKey = ValueKey('matrix-dock');
const _dock = 82.0;

/// The whole board under a header and over the dock's room, as Home has
/// it.
Future<HomeBoardGeometry> _pumpBoard(
  WidgetTester tester, {
  required _Mood mood,
  required Size size,
  double scale = 1,
  String theme = 'console',
  String lang = 'es',
  _Hostile hostile = _Hostile.none,
  bool editing = false,
  ValueNotifier<HomeBoardLayout>? live,
}) async {
  final reduceMotion = editing;
  final key = GlobalKey<HomeBoardViewState>();
  final layout = live ?? ValueNotifier(_layout(size.width));
  await _pumpApp(
    tester,
    Stack(
      children: [
        Column(
          children: [
            SizedBox(key: _headerKey, height: kToolbarHeight),
            Expanded(
              child: ValueListenableBuilder<HomeBoardLayout>(
                valueListenable: layout,
                builder: (context, current, _) => HomeBoardView(
                  key: key,
                  layout: current,
                  data: _data(mood, hostile),
                  actions: HomeCalls().actions,
                  onChanged: (next) => layout.value = next,
                  newId: () => 'new',
                  clock: () => homeFixtureNow,
                  bottomPadding: _dock,
                  initiallyEditing: editing,
                ),
              ),
            ),
          ],
        ),
        Positioned(
          key: _dockKey,
          left: 0,
          right: 0,
          bottom: 0,
          height: _dock,
          child: const SizedBox.expand(),
        ),
      ],
    ),
    size: size,
    theme: theme,
    lang: lang,
    scale: scale,
    reduceMotion: reduceMotion,
  );
  // The widgets glide to their rows.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return key.currentState!.geometry!;
}

// ── checks ─────────────────────────────────────────────────────────────

Rect _global(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), box.paintBounds);

/// The texts inside [root] (icons are text too).
List<RenderParagraph> _paragraphs(RenderObject root) {
  final found = <RenderParagraph>[];
  void visit(RenderObject node) {
    if (node is RenderParagraph) found.add(node);
    node.visitChildren(visit);
  }

  visit(root);
  return found;
}

RenderClipRect? _clipOf(RenderObject node, RenderObject stop) {
  var at = node.parent;
  while (at != null && at != stop) {
    if (at is RenderClipRect) return at;
    at = at.parent;
  }
  return null;
}

bool _touches(Rect a, Rect b, [double slack = 1]) {
  final o = a.intersect(b);
  return o.width > slack && o.height > slack;
}

/// Every text of the tile at [finder] is whole: inside its clip (or left
/// out of it entirely, never cut at its edge), inside the tile, not laid
/// over another text, and not hard-cut by a clip overflow.
void _expectTexts(WidgetTester tester, Finder finder, String reason) {
  expect(tester.takeException(), isNull, reason: reason);
  final tileBox = tester.renderObject(finder) as RenderBox;
  final tile = _global(tileBox);
  final shown = <(Rect, String)>[];
  for (final p in _paragraphs(tileBox)) {
    if (!p.attached || p.size.isEmpty) continue;
    final rect = _global(p);
    final text = p.text.toPlainText();
    // Left out by its clip (the header's note on a second run, a piece
    // the cell has no room for): not shown, so nothing to check.
    final clip = _clipOf(p, tileBox);
    if (clip != null) {
      final visible = _global(clip);
      if (!_touches(rect, visible, 0.5)) continue;
      expect(
        rect.top,
        greaterThanOrEqualTo(visible.top - 1),
        reason: '$reason: «$text» cut at the top of its clip',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(visible.bottom + 1),
        reason: '$reason: «$text» cut at the bottom of its clip',
      );
      expect(
        rect.left,
        greaterThanOrEqualTo(visible.left - 1),
        reason: '$reason: «$text» cut at the start of its clip',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(visible.right + 1),
        reason: '$reason: «$text» cut at the end of its clip',
      );
    }
    expect(
      tile.inflate(1).contains(rect.topLeft) &&
          tile.inflate(1).contains(rect.bottomRight),
      isTrue,
      reason: '$reason: «$text» $rect outside its tile $tile',
    );
    // A text that needs more than its box and may not say so with an
    // ellipsis or a fade is a hard cut, down (more lines than it may
    // have) or across (a single line wider than its box).
    final hard =
        p.overflow == TextOverflow.clip || p.overflow == TextOverflow.visible;
    if (hard && p.didExceedMaxLines) {
      fail('$reason: «$text» is cut without an ellipsis');
    }
    if (hard && p.textSize.width > p.size.width + 0.5) {
      fail('$reason: «$text» is wider than its box and cut');
    }
    for (final (other, otherText) in shown) {
      expect(
        _touches(rect, other),
        isFalse,
        reason: '$reason: «$text» $rect over «$otherText» $other',
      );
    }
    shown.add((rect, text));
  }
  // The accent ring of a waiting face: whole, never cut by a clip.
  for (final ring
      in find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'home-face-ring-',
                ),
          )
          .evaluate()) {
    final box = ring.renderObject! as RenderBox;
    final rect = _global(box);
    if (!_touches(rect, tile, 0.5)) continue;
    final clip = _clipOf(box, tileBox);
    final visible = clip == null ? tile : _global(clip);
    expect(
      visible.inflate(0.5).contains(rect.topLeft) &&
          visible.inflate(0.5).contains(rect.bottomRight),
      isTrue,
      reason: '$reason: a face ring cut by its clip ($rect in $visible)',
    );
  }
  // The faces: never under a text.
  for (final face in find.byType(LivingBotFace).evaluate()) {
    final rect = tester.getRect(find.byWidget(face.widget));
    if (!_touches(rect, tile, 0.5)) continue;
    for (final (other, otherText) in shown) {
      expect(
        _touches(rect, other),
        isFalse,
        reason: '$reason: a face under «$otherText»',
      );
    }
  }
}

/// Every placed tile of the board inside the page between the header and
/// the dock, none over another.
void _expectBoard(
  WidgetTester tester,
  HomeBoardGeometry geometry,
  Size size,
  String reason,
) {
  expect(tester.takeException(), isNull, reason: reason);
  final header = tester.getRect(find.byKey(_headerKey));
  final dock = tester.getRect(find.byKey(_dockKey));
  final rects = <String, Rect>{};
  for (final item in geometry.plan.placed) {
    final finder = find.byKey(
      ValueKey('home-tile-${item.kind.name}-${item.id}'),
    );
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '$reason ${item.id}');
    expect(
      rect.right,
      lessThanOrEqualTo(size.width + 0.5),
      reason: '$reason ${item.id}',
    );
    expect(
      rect.top,
      greaterThanOrEqualTo(header.bottom - 0.5),
      reason: '$reason ${item.id} under the header',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(dock.top + 0.5),
      reason: '$reason ${item.id} under the dock',
    );
    for (final other in rects.entries) {
      expect(
        _touches(rect, other.value, 0.5),
        isFalse,
        reason: '$reason: ${item.id} over ${other.key}',
      );
    }
    rects[item.id] = rect;
    _expectTexts(tester, finder, '$reason ${item.id}');
  }
}

// ── evidence ───────────────────────────────────────────────────────────

String? _shotsDir() {
  final env = Platform.environment['DESIGN_SHOTS_DIR'];
  if (env != null && env.isNotEmpty) return env;
  // The gate keeps `evidence` beside the sources it unpacks.
  if (Directory('../evidence').existsSync()) return '../evidence/shots';
  return null;
}

/// What still animates: each implicitly animated widget whose animation
/// runs, with the widgets above it.
String _animating(WidgetTester tester) {
  final found = <String>[];
  for (final element in tester.allElements) {
    if (element is! StatefulElement) continue;
    final state = element.state;
    if (state is! ImplicitlyAnimatedWidgetState) continue;
    // ignore: invalid_use_of_protected_member
    if (!state.controller.isAnimating) continue;
    final chain = ['${element.widget}'];
    element.visitAncestorElements((above) {
      final key = above.widget.key;
      chain.add('${above.widget.runtimeType}${key == null ? '' : '($key)'}');
      return chain.length < 16;
    });
    found.add(chain.join(' < '));
  }
  return found.isEmpty ? 'no implicit animation runs' : found.join('\n');
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = _shotsDir();
  if (dir == null) return;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignFonts);
  setUp(() {
    debugLivingBotFacesStill = true;
    _resetScheduled = false;
  });

  group('every tile, state, width and text size (Console dark, es)', () {
    for (final scale in _scales) {
      testWidgets('text at ${scale}x', (tester) async {
        for (final kind in _kinds) {
          for (final size in HomeWidgetSize.values) {
            for (final mood in _Mood.values) {
              for (final width in _widths) {
                // 152: the designed row; at 390 dp also 140 (the shortest
                // of an open board) and 104 (the rows under a notice).
                for (final row in [152.0, if (width == 390) 140.0, 104.0]) {
                  await _pumpTile(
                    tester,
                    kind: kind,
                    size: size,
                    mood: mood,
                    width: width,
                    row: row,
                    scale: scale,
                  );
                  _expectTexts(
                    tester,
                    find.byKey(_tileKey),
                    '$kind $size $mood ${width}dp row $row ${scale}x',
                  );
                }
              }
            }
          }
        }
      });
    }
  });

  group('every tile, state, width and text size in the other languages', () {
    for (final lang in _langs.where((l) => l != 'es')) {
      for (final scale in _scales) {
        testWidgets('$lang, text at ${scale}x', (tester) async {
          for (final kind in _kinds) {
            for (final size in HomeWidgetSize.values) {
              for (final mood in _Mood.values) {
                for (final width in _widths) {
                  await _pumpTile(
                    tester,
                    kind: kind,
                    size: size,
                    mood: mood,
                    width: width,
                    scale: scale,
                    lang: lang,
                  );
                  _expectTexts(
                    tester,
                    find.byKey(_tileKey),
                    '$lang $kind $size $mood ${width}dp ${scale}x',
                  );
                }
              }
            }
          }
        });
      }
    }
  });

  group('themes and languages at 2x on a narrow phone and a wide screen', () {
    for (final theme in _themes) {
      // Console dark carries the five languages at both widths; the other
      // themes the Latin and the CJK one on the narrow phone.
      final langs = theme == 'console' ? _langs : const ['es', 'ja'];
      final widths = theme == 'console' ? const [360.0, 840.0] : const [360.0];
      testWidgets(theme, (tester) async {
        for (final lang in langs) {
          for (final kind in _kinds) {
            for (final size in HomeWidgetSize.values) {
              for (final mood in _Mood.values) {
                for (final width in widths) {
                  await _pumpTile(
                    tester,
                    kind: kind,
                    size: size,
                    mood: mood,
                    width: width,
                    scale: 2,
                    theme: theme,
                    lang: lang,
                  );
                  _expectTexts(
                    tester,
                    find.byKey(_tileKey),
                    '$theme $lang $kind $size $mood ${width}dp 2x',
                  );
                }
              }
            }
          }
        }
      });
    }

    testWidgets('the nine languages at 2x, 390 dp, calm and asking', (
      tester,
    ) async {
      for (final lang in _allLangs) {
        for (final kind in _kinds) {
          for (final size in HomeWidgetSize.values) {
            for (final mood in [_Mood.calm, _Mood.asks]) {
              await _pumpTile(
                tester,
                kind: kind,
                size: size,
                mood: mood,
                width: 390,
                scale: 2,
                lang: lang,
              );
              _expectTexts(
                tester,
                find.byKey(_tileKey),
                '$lang $kind $size $mood 390dp 2x',
              );
            }
          }
        }
      }
    });
  });

  group('hostile data', () {
    for (final hostile in _Hostile.values.skip(1)) {
      testWidgets(hostile.name, (tester) async {
        for (final kind in _kinds) {
          for (final size in HomeWidgetSize.values) {
            for (final mood in [_Mood.asks, _Mood.working]) {
              for (final width in [320.0, 840.0]) {
                for (final scale in [1.0, 2.0]) {
                  await _pumpTile(
                    tester,
                    kind: kind,
                    size: size,
                    mood: mood,
                    width: width,
                    scale: scale,
                    hostile: hostile,
                  );
                  _expectTexts(
                    tester,
                    find.byKey(_tileKey),
                    '$hostile $kind $size $mood ${width}dp ${scale}x',
                  );
                }
              }
            }
          }
        }
      });
    }
  });

  group('the whole board', () {
    for (final theme in _themes) {
      testWidgets('$theme: every width, text size and state', (tester) async {
        for (final width in _widths) {
          for (final scale in _scales) {
            for (final mood in _Mood.values) {
              final size = Size(width, width >= 840 ? 800 : 844);
              final geometry = await _pumpBoard(
                tester,
                mood: mood,
                size: size,
                scale: scale,
                theme: theme,
              );
              _expectBoard(
                tester,
                geometry,
                size,
                '$theme ${width}dp ${scale}x $mood',
              );
            }
          }
        }
      });
    }

    testWidgets('edit mode keeps the grid: the tiles stay in their cells '
        'after a move, a removal and an addition', (tester) async {
      for (final width in [390.0, 840.0]) {
        final size = Size(width, width >= 840 ? 800 : 844);
        final live = ValueNotifier(_layout(width));
        var geometry = await _pumpBoard(
          tester,
          mood: _Mood.calm,
          size: size,
          editing: true,
          live: live,
        );
        await _shot(tester, 'edit-${width.round()}-open');
        _expectBoard(tester, geometry, size, 'edit ${width}dp');
        final state = tester.state<HomeBoardViewState>(
          find.byType(HomeBoardView),
        );
        expect(state.editing, isTrue);
        // A hole, when the board has one, is a cell of the grid too.
        for (final hole in geometry.plan.holes) {
          final rect = tester.getRect(
            find.byKey(ValueKey('home-hole-${hole.col}-${hole.row}')),
          );
          expect(rect.width, closeTo(geometry.cellWidth, 1));
          expect(rect.height, closeTo(geometry.rowHeight, 1));
        }
        // Remove the first tile: the rest reflow into whole cells.
        final first = geometry.plan.placed.first;
        await tester.tap(find.byKey(ValueKey('home-remove-${first.id}')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        geometry = state.geometry!;
        expect(live.value.byId(first.id), isNull);
        expect(geometry.plan.free, greaterThan(0));
        _expectBoard(tester, geometry, size, 'edit ${width}dp after remove');
        // Move the last tile first: whole cells still.
        final lastId = live.value.items.last.id;
        live.value = live.value.move(lastId, 0);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        geometry = state.geometry!;
        expect(geometry.plan.placed.first.id, lastId);
        _expectBoard(tester, geometry, size, 'edit ${width}dp after move');
        // Add a repeatable tile (the wide fixture already has its one
        // Server widget): the new tile takes the hole, like the gallery.
        live.value = live.value.add(
          HomeWidgetKind.bot,
          newId: () => 'added',
          size: HomeWidgetSize.small,
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        geometry = state.geometry!;
        expect(geometry.plan.shows('added'), isTrue);
        _expectBoard(tester, geometry, size, 'edit ${width}dp after add');
        await _shot(tester, 'edit-${width.round()}');
      }
    });
  });

  group('evidence', () {
    testWidgets('boards per theme, width and state', (tester) async {
      for (final theme in _themes) {
        for (final width in [390.0, 840.0]) {
          for (final mood in _Mood.values) {
            final size = Size(width, width >= 840 ? 800 : 844);
            await _pumpBoard(tester, mood: mood, size: size, theme: theme);
            await _shot(tester, 'board-$theme-${width.round()}-${mood.name}');
          }
        }
      }
    });

    testWidgets('2x text, hostile data and the nine languages', (tester) async {
      for (final mood in _Mood.values) {
        await _pumpBoard(
          tester,
          mood: mood,
          size: const Size(390, 844),
          scale: 2,
        );
        await _shot(tester, 'board-2x-390-${mood.name}');
      }
      for (final hostile in _Hostile.values.skip(1)) {
        await _pumpBoard(
          tester,
          mood: _Mood.asks,
          size: const Size(390, 844),
          hostile: hostile,
        );
        await _shot(tester, 'board-hostile-${hostile.name}');
        await _pumpBoard(
          tester,
          mood: _Mood.working,
          size: const Size(840, 800),
          hostile: hostile,
        );
        await _shot(tester, 'board-hostile-${hostile.name}-840');
      }
      for (final lang in _allLangs) {
        await _pumpBoard(
          tester,
          mood: _Mood.asks,
          size: const Size(390, 844),
          scale: 2,
          lang: lang,
        );
        await _shot(tester, 'board-lang-$lang-2x');
        await _pumpBoard(
          tester,
          mood: _Mood.working,
          size: const Size(360, 780),
          scale: 1.3,
          lang: lang,
        );
        await _shot(tester, 'board-lang-$lang-360');
      }
    });

    testWidgets('every tile at every size in its states', (tester) async {
      Widget tile(HomeWidgetKind kind, HomeWidgetSize size, _Mood mood) =>
          Padding(
            padding: const EdgeInsets.only(bottom: HomeBoardGridRule.gap),
            child: homeTile(
              kind: kind,
              size: size,
              data: _data(mood),
              actions: HomeCalls().actions,
              options: _options(kind, mood),
              cell: _cell(size, 390),
            ),
          );
      for (final kind in _kinds) {
        for (final theme in ['console', 'midnight-light']) {
          await _pumpApp(
            tester,
            SingleChildScrollView(
              padding: const EdgeInsets.all(HomeBoardMetrics.sidePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final mood in _Mood.values)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        tile(kind, HomeWidgetSize.small, mood),
                        const SizedBox(width: HomeBoardGridRule.gap),
                        tile(kind, HomeWidgetSize.wide, mood),
                        const SizedBox(width: HomeBoardGridRule.gap),
                        tile(kind, HomeWidgetSize.large, mood),
                      ],
                    ),
                ],
              ),
            ),
            size: const Size(
              960,
              6 * (2 * 152 + 3 * HomeBoardGridRule.gap) + 40,
            ),
            theme: theme,
          );
          expect(tester.takeException(), isNull, reason: '$kind $theme');
          await _shot(tester, 'tile-${kind.name}-$theme');
        }
      }
    });
  });

  group('no timers of its own', () {
    testWidgets('a calm board schedules nothing: no animation, no clock, '
        'no poll', (tester) async {
      await _pumpBoard(tester, mood: _Mood.calm, size: const Size(390, 844));
      // The one-shot entrances are over well within this.
      await tester.pump(const Duration(seconds: 5));
      // Names what is still ticking, if anything is.
      expect(
        tester.binding.debugAssertNoTransientCallbacks('a calm board'),
        isTrue,
      );
      expect(tester.binding.transientCallbackCount, 0);
      // A minute passes: nothing asked the screen for anything.
      final calls = HomeCalls();
      await _pumpApp(
        tester,
        HomeBoardView(
          layout: _layout(390),
          data: _data(_Mood.calm),
          actions: calls.actions,
          onChanged: (_) => fail('a calm board wrote its layout'),
          newId: () => 'new',
          clock: () => homeFixtureNow,
          bottomPadding: _dock,
        ),
        size: const Size(390, 844),
      );
      // The app's own one-shot transitions of a new mount (the page's text
      // style settling) run their course, as on the first board.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(const Duration(minutes: 1));
      expect(calls.log, isEmpty);
      expect(calls.answers, isEmpty);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: _animating(tester),
      );
    });
  });
}
