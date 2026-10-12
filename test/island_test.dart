// The island (owner decision, 1.2.15): the pill at the top centre of every
// chat surface. At rest it is the NAME after one state dot, with the still
// sprite standing on it. When something happens it grows in place to say it
// in ONE line with at most ONE action, and shrinks back. The app's notices
// are shown in it; on screens without an island they keep their top lane,
// drawn as the same island event. Nothing is ever placed over the composer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/motion.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _statusBar = 38.0;
const _frame = Duration(milliseconds: 16);

class _Scene {
  const _Scene({
    this.name = 'Hermes',
    this.status = IslandStatus.idle,
    this.events = const [],
    this.timer,
    this.mark,
    this.bare = false,
  });

  final String name;
  final IslandStatus status;
  final List<IslandEvent> events;
  final String? timer;

  /// What it has to open («4 en marcha»).
  final String? mark;

  /// Nothing to open: no tap, no long press.
  final bool bare;
}

final _scene = ValueNotifier<_Scene>(const _Scene());
var _transcriptBuilds = 0;
var _taps = 0;
var _longPresses = 0;

/// The chat's transcript: it must not be rebuilt by anything the island does.
class _Transcript extends StatelessWidget {
  const _Transcript();

  @override
  Widget build(BuildContext context) {
    _transcriptBuilds++;
    return ListView(
      children: [
        for (var i = 0; i < 30; i++)
          SizedBox(height: 48, child: Text('Mensaje $i')),
      ],
    );
  }
}

/// A chat screen reduced to what the island lives with: the transcript
/// under the floating header, the two round buttons, the sprite on the
/// island and the composer at the bottom.
class _Chat extends StatelessWidget {
  const _Chat({this.sprite = true});

  final bool sprite;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const Positioned.fill(child: _Transcript()),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingChatHeader(
            leading: FloatingHeaderButton(
              key: const ValueKey('menu'),
              icon: Icons.menu_rounded,
              tooltip: 'Menú',
              onPressed: () {},
            ),
            trailing: FloatingHeaderButton(
              key: const ValueKey('new'),
              icon: Icons.add_rounded,
              tooltip: 'Nuevo chat',
              onPressed: () {},
            ),
            faces: sprite
                ? const SizedBox.square(
                    key: ValueKey('sprite'),
                    dimension: FloatingChatHeader.faceSize,
                    child: ColoredBox(color: Colors.green),
                  )
                : const SizedBox.shrink(),
            pill: ValueListenableBuilder<_Scene>(
              valueListenable: _scene,
              builder: (context, scene, _) => ChatIsland(
                name: scene.name,
                status: scene.status,
                events: scene.events,
                notices: HermesNotice.feedOf(context),
                trailing: scene.timer == null
                    ? null
                    : Text(scene.timer!, key: const ValueKey('timer')),
                mark: scene.mark,
                hint: scene.bare ? null : 'Ver',
                onTap: scene.bare ? null : () => _taps++,
                onLongPress: scene.bare ? null : () => _longPresses++,
              ),
            ),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SizedBox(key: ValueKey('composer'), height: 72),
        ),
      ],
    ),
  );
}

Widget _app(
  Widget home, {
  bool reduce = true,
  double textScale = 1,
  ThemeData? theme,
  GlobalKey<NavigatorState>? navigatorKey,
}) => MaterialApp(
  navigatorKey: navigatorKey,
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduce,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: home,
);

void _phone(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size
    ..padding = const FakeViewPadding(top: _statusBar)
    ..viewPadding = const FakeViewPadding(top: _statusBar);
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder get _island => _key('island');
Finder get _line => _key('island-event-line');
Finder get _name => _key('island-name');
Finder get _composer => _key('composer');

BuildContext _ctx(WidgetTester tester) => tester.element(_composer);

String _text(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  return text.data ?? text.textSpan!.toPlainText();
}

Color _dotColor(WidgetTester tester, IslandStatus status) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: _key('island-dot-${status.name}'),
      matching: find.byType(DecoratedBox),
    ),
  );
  final decoration = box.decoration as BoxDecoration;
  return decoration.color ?? (decoration.border! as Border).top.color;
}

IslandEvent _needsYou({VoidCallback? onSee, VoidCallback? onDismissed}) =>
    IslandEvent(
      id: 'needs-you',
      tone: IslandTone.needsYou,
      sticky: true,
      line: 'Te necesita',
      action: IslandAction(label: 'Ver', onPressed: onSee ?? () {}),
      onDismissed: onDismissed,
    );

const _working = IslandEvent(
  id: 'working',
  line: 'Trabajando',
  detail: 'Terminal',
  duration: Duration(seconds: 3),
);

void main() {
  setUp(() {
    _scene.value = const _Scene();
    _transcriptBuilds = 0;
    _taps = 0;
    _longPresses = 0;
    IslandPresenters.resetForTesting();
  });

  group('at rest', () {
    testWidgets('a compact pill between the buttons: one dot and the name', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final island = tester.getRect(_island);
      final menu = tester.getRect(_key('menu'));
      final plus = tester.getRect(_key('new'));
      expect(island.center.dx, closeTo(195, 0.5), reason: 'centred');
      expect(island.left, greaterThan(menu.right));
      expect(island.right, lessThan(plus.left));
      expect(island.height, IslandMetrics.restHeight);
      expect(island.width, lessThan(160), reason: 'compact: $island');
      expect(_text(tester, _name), 'Hermes');
      expect(_key('island-dot-idle'), findsOneWidget);
      expect(_line, findsNothing);
      // The buttons line up with it.
      for (final button in [menu, plus]) {
        expect(button.center.dy, closeTo(island.center.dy, 0.5));
      }
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing, reason: 'no blur');
    });

    testWidgets('the dot says the state with the theme\'s own colours', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final colors = AppTheme.hermesRedDark.hermes;
      final expected = {
        IslandStatus.idle: colors.success,
        IslandStatus.working: colors.accent,
        IslandStatus.needsYou: colors.warning,
        IslandStatus.reconnecting: colors.warning,
        IslandStatus.offline: colors.error,
        IslandStatus.error: colors.error,
      };
      for (final MapEntry(key: status, value: color) in expected.entries) {
        _scene.value = _Scene(status: status);
        await tester.pump();
        expect(_dotColor(tester, status), color, reason: status.name);
        expect(_text(tester, _name), 'Hermes', reason: 'the name stays');
      }
      // Reconnecting is a ring: told from «needs you» without colour.
      _scene.value = const _Scene(status: IslandStatus.reconnecting);
      await tester.pump();
      final ring = tester.widget<DecoratedBox>(
        find.descendant(
          of: _key('island-dot-reconnecting'),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect((ring.decoration as BoxDecoration).color, isNull);
    });

    testWidgets('the name is the profile, the bot or the room', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      for (final name in ['Hermes', 'Forja', 'Console Devs']) {
        _scene.value = _Scene(name: name);
        await tester.pump();
        expect(_text(tester, _name), name);
      }
    });

    testWidgets('while a turn runs: the name, the working dot and the timer', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      _scene.value = const _Scene(status: IslandStatus.working, timer: '0:07');
      await tester.pump();
      expect(_text(tester, _name), 'Hermes');
      expect(_key('island-dot-working'), findsOneWidget);
      expect(
        find.descendant(of: _island, matching: _key('timer')),
        findsOneWidget,
      );
      expect(tester.getRect(_island).height, IslandMetrics.restHeight);
    });

    testWidgets('a tap on it, or on the sprite, does what it was given', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      await tester.tap(_island);
      expect(_taps, 1);
      await tester.tapAt(tester.getCenter(_key('sprite')));
      expect(_taps, 2);
      await tester.longPress(_island);
      expect(_longPresses, 1);
    });
  });

  group('what it has to open', () {
    testWidgets('only the name: no chevron, nothing to tap, no action for a '
        'screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      _phone(tester);
      _scene.value = const _Scene(bare: true);
      await tester.pumpWidget(_app(const _Chat()));
      expect(_key('island-mark'), findsNothing);
      expect(_key('island-chevron'), findsNothing);
      await tester.tap(_island, warnIfMissed: false);
      await tester.tapAt(tester.getCenter(_key('sprite')));
      await tester.longPress(_island, warnIfMissed: false);
      expect(_taps, 0);
      expect(_longPresses, 0);
      final node = tester.getSemantics(
        find.bySemanticsLabel('Hermes, Conectado'),
      );
      expect(node.flagsCollection.isButton, isFalse);
      final data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.hasAction(SemanticsAction.longPress), isFalse);
      handle.dispose();
    });

    testWidgets('with something alive it says how many, in the accent, with '
        'a chevron: the invitation', (tester) async {
      final handle = tester.ensureSemantics();
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final bare = tester.getRect(_island);
      _scene.value = const _Scene(mark: '4 en marcha');
      await _settle(tester);
      final colors = AppTheme.hermesRedDark.hermes;
      final mark = tester.widget<Text>(_key('island-mark'));
      expect(mark.data, '4 en marcha');
      expect(mark.style!.color, colors.accentText);
      expect(
        tester.widget<Icon>(_key('island-chevron')).icon,
        Icons.keyboard_arrow_down_rounded,
      );
      // Dot, name, count, chevron, in that order, on one line.
      final xs = [
        tester.getCenter(_key('island-dot-idle')).dx,
        tester.getCenter(_name).dx,
        tester.getCenter(_key('island-mark')).dx,
        tester.getCenter(_key('island-chevron')).dx,
      ];
      expect(xs, [...xs]..sort());
      final marked = tester.getRect(_island);
      expect(marked.width, greaterThan(bare.width));
      expect(marked.height, bare.height);
      expect(marked.center.dx, closeTo(195, 0.5));
      // Its hairline takes the accent.
      final shape =
          tester
                  .widget<Material>(
                    find.descendant(
                      of: _island,
                      matching: find.byType(Material),
                    ),
                  )
                  .shape!
              as RoundedRectangleBorder;
      expect(shape.side.color, colors.accent.withValues(alpha: 0.55));
      // The dot keeps saying what it said.
      expect(_key('island-dot-idle'), findsOneWidget);
      final node = tester.getSemantics(
        find.bySemanticsLabel('Hermes, Conectado, 4 en marcha'),
      );
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      await tester.tap(_island);
      expect(_taps, 1);
      handle.dispose();
    });

    testWidgets('an event takes the line; the count comes back after it', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      _scene.value = const _Scene(mark: '3 en marcha', events: [_working]);
      await _settle(tester);
      expect(_text(tester, _line), contains('Trabajando'));
      expect(_key('island-mark'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      expect(_line, findsNothing);
      expect(_text(tester, _key('island-mark')), '3 en marcha');
    });

    testWidgets('as the first line of its card it is flat, and its chevron '
        'points back up', (tester) async {
      var closed = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: SizedBox(
                width: 370,
                child: ChatIsland(
                  flat: true,
                  open: true,
                  name: 'Hermes',
                  status: IslandStatus.idle,
                  mark: '4 en marcha',
                  onTap: () => closed++,
                ),
              ),
            ),
          ),
        ),
      );
      expect(_island, findsNothing, reason: 'no shape of its own');
      expect(
        tester.getSize(find.byType(ChatIsland)).height,
        IslandMetrics.flatHeight,
      );
      expect(_text(tester, _key('island-mark')), '4 en marcha');
      expect(
        tester.widget<Icon>(_key('island-chevron')).icon,
        Icons.keyboard_arrow_up_rounded,
      );
      await tester.tap(_name);
      expect(closed, 1);
    });
  });

  group('the sprite', () {
    testWidgets('stands centred on the island, whole, below the status bar', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final sprite = tester.getRect(_key('sprite'));
      final island = tester.getRect(_island);
      expect(sprite.size, const Size.square(48));
      expect(sprite.top, greaterThanOrEqualTo(_statusBar), reason: 'no clip');
      expect(sprite.center.dx, closeTo(island.center.dx, 0.5));
      // Its feet rest on the island's top edge.
      expect(sprite.bottom - island.top, FloatingChatHeader.faceOverlap);
      // Nothing of the header reaches the clock.
      for (final key in ['menu', 'new', 'island']) {
        expect(tester.getRect(_key(key)).top, greaterThan(_statusBar));
      }
    });

    testWidgets('never moves: not when the island grows, not in any state', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat(), reduce: false));
      final at = tester.getRect(_key('sprite'));
      final top = tester.getRect(_island).top;
      for (final status in IslandStatus.values) {
        _scene.value = _Scene(status: status, events: [_needsYou()]);
        for (var i = 0; i < 20; i++) {
          await tester.pump(_frame);
          expect(tester.getRect(_key('sprite')), at, reason: status.name);
          expect(tester.getRect(_island).top, top, reason: 'top edge still');
        }
        _scene.value = _Scene(status: status);
        for (var i = 0; i < 20; i++) {
          await tester.pump(_frame);
          expect(tester.getRect(_key('sprite')), at, reason: status.name);
        }
      }
    });

    testWidgets('no sprite: the island simply has none on it', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat(sprite: false)));
      expect(_key('sprite'), findsNothing);
      final island = tester.getRect(_island);
      expect(island.center.dx, closeTo(195, 0.5));
      expect(_text(tester, _name), 'Hermes');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the header\'s extent is the same in every state', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final inset = FloatingChatHeader.insetFor(_ctx(tester));
      final heights = <double>{};
      for (final scene in [
        const _Scene(),
        const _Scene(status: IslandStatus.working, timer: '1:02'),
        _Scene(status: IslandStatus.needsYou, events: [_needsYou()]),
        const _Scene(status: IslandStatus.offline),
      ]) {
        _scene.value = scene;
        await _settle(tester);
        heights.add(tester.getSize(_key('floating-header')).height);
        expect(FloatingChatHeader.insetFor(_ctx(tester)), inset);
        // What the transcript keeps clear holds the island, event or not.
        expect(tester.getRect(_island).bottom, lessThanOrEqualTo(inset));
      }
      expect(heights, hasLength(1));
    });
  });

  group('when something happens', () {
    testWidgets('it grows in place to ONE line and ONE action', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final rest = tester.getRect(_island);
      var seen = 0;
      _scene.value = _Scene(
        status: IslandStatus.needsYou,
        events: [_needsYou(onSee: () => seen++)],
      );
      await _settle(tester);
      final grown = tester.getRect(_island);
      expect(grown.top, rest.top, reason: 'in place');
      expect(grown.center.dx, closeTo(rest.center.dx, 0.5));
      expect(grown.width, greaterThan(rest.width));
      expect(grown.height, IslandMetrics.eventHeight);
      expect(_name, findsNothing, reason: 'the island is the event');
      expect(_text(tester, _line), 'Te necesita');
      final line = tester.widget<Text>(_line);
      expect(line.maxLines, 1);
      expect(
        find.descendant(of: _island, matching: find.byType(InkWell)),
        findsOneWidget,
        reason: 'one action',
      );
      final action = tester.getRect(_key('island-action'));
      expect(action.height, greaterThanOrEqualTo(48));
      expect(action.width, greaterThanOrEqualTo(48));
      await tester.tap(_key('island-action'));
      await _settle(tester);
      expect(seen, 1);
      // Acted on: back to the name and the dot.
      expect(_line, findsNothing);
      expect(_text(tester, _name), 'Hermes');
      expect(tester.getRect(_island), rest);
    });

    testWidgets('a line without an action says it and leaves by itself', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final rest = tester.getRect(_island);
      _scene.value = const _Scene(
        status: IslandStatus.working,
        events: [_working],
      );
      await _settle(tester);
      expect(_text(tester, _line), 'Trabajando · Terminal');
      expect(_key('island-action'), findsNothing);
      // The step changes while it is being said: the same line, updated.
      _scene.value = const _Scene(
        status: IslandStatus.working,
        events: [
          IslandEvent(
            id: 'working',
            line: 'Trabajando',
            detail: 'Buscando',
            duration: Duration(seconds: 3),
          ),
        ],
      );
      await tester.pump();
      expect(_text(tester, _line), 'Trabajando · Buscando');
      await tester.pump(const Duration(milliseconds: 2500));
      expect(_line, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      await _settle(tester);
      // Still working, but the words were said: name, dot, nothing else.
      expect(_line, findsNothing);
      expect(_key('island-dot-working'), findsOneWidget);
      expect(tester.getRect(_island).height, rest.height);
      // The same turn does not say it again; the next one does.
      await tester.pump(const Duration(seconds: 10));
      expect(_line, findsNothing);
      _scene.value = const _Scene();
      await tester.pump();
      _scene.value = const _Scene(
        status: IslandStatus.working,
        events: [_working],
      );
      await _settle(tester);
      expect(_text(tester, _line), 'Trabajando · Terminal');
    });

    testWidgets('one continuous motion out and back', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat(), reduce: false));
      final rest = tester.getRect(_island);
      _scene.value = _Scene(events: [_needsYou()]);
      await tester.pump();
      final growing = <Rect>[];
      for (var i = 0; i < 20; i++) {
        await tester.pump(_frame);
        growing.add(tester.getRect(_island));
      }
      final grown = growing.last;
      expect(grown.height, IslandMetrics.eventHeight);
      var previous = rest;
      for (final f in growing) {
        expect(f.top, rest.top);
        expect(f.center.dx, closeTo(rest.center.dx, 0.5));
        expect(f.width, greaterThanOrEqualTo(previous.width - 0.01));
        expect(f.height, greaterThanOrEqualTo(previous.height - 0.01));
        previous = f;
      }
      expect(growing.first.width, lessThan(grown.width), reason: 'animated');
      expect(
        growing.indexWhere((f) => f == grown),
        lessThanOrEqualTo(Motion.base.inMilliseconds ~/ 16 + 2),
        reason: 'in the catalogue\'s time',
      );
      _scene.value = const _Scene();
      await tester.pump();
      previous = grown;
      for (var i = 0; i < 20; i++) {
        await tester.pump(_frame);
        final f = tester.getRect(_island);
        expect(f.top, rest.top);
        expect(f.width, lessThanOrEqualTo(previous.width + 0.01));
        expect(f.height, lessThanOrEqualTo(previous.height + 0.01));
        previous = f;
      }
      expect(previous, rest);
    });

    testWidgets('with animations off it just switches', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final rest = tester.getRect(_island);
      _scene.value = _Scene(events: [_needsYou()]);
      await tester.pump();
      final grown = tester.getRect(_island);
      expect(grown.height, IslandMetrics.eventHeight);
      await tester.pump(_frame);
      expect(tester.getRect(_island), grown);
      _scene.value = const _Scene();
      await tester.pump();
      expect(tester.getRect(_island), rest);
    });

    testWidgets('needs you is framed in amber, a failure in red', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final colors = AppTheme.hermesRedDark.hermes;
      Color frame() {
        final surface = tester.widget<Material>(
          find.descendant(of: _island, matching: find.byType(Material)).first,
        );
        return (surface.shape! as RoundedRectangleBorder).side.color;
      }

      final neutral = frame();
      _scene.value = _Scene(events: [_needsYou()]);
      await _settle(tester);
      expect(
        frame().toARGB32() & 0xFFFFFF,
        colors.warning.toARGB32() & 0xFFFFFF,
      );
      _scene.value = const _Scene(
        events: [
          IslandEvent(
            id: 'failed',
            tone: IslandTone.error,
            sticky: true,
            line: 'No se envió',
          ),
        ],
      );
      await _settle(tester);
      expect(frame().toARGB32() & 0xFFFFFF, colors.error.toARGB32() & 0xFFFFFF);
      _scene.value = const _Scene(events: [_working]);
      await _settle(tester);
      expect(frame(), neutral);
    });
  });

  group('one at a time', () {
    testWidgets('a second event waits behind with «+1»', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      _scene.value = _Scene(events: [_needsYou()]);
      await _settle(tester);
      expect(_key('island-waiting'), findsNothing);
      expect(_key('island-behind'), findsNothing);
      const failed = IslandEvent(
        id: 'failed',
        tone: IslandTone.error,
        sticky: true,
        line: 'No se envió',
      );
      _scene.value = _Scene(events: [_needsYou(), failed]);
      await _settle(tester);
      expect(_line, findsOneWidget, reason: 'one at a time');
      expect(_text(tester, _line), 'Te necesita');
      expect(
        find.descendant(of: _key('island-waiting'), matching: find.text('+1')),
        findsOneWidget,
      );
      // The one behind peeks out under the island, narrower.
      final front = tester.getRect(_island);
      final behind = tester.getRect(_key('island-behind'));
      expect(behind.bottom, greaterThan(front.bottom));
      expect(behind.bottom - front.bottom, lessThanOrEqualTo(10));
      expect(behind.left, greaterThan(front.left));
      expect(behind.right, lessThan(front.right));
    });

    testWidgets('needs you and failures go before information', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      const failed = IslandEvent(
        id: 'failed',
        tone: IslandTone.error,
        sticky: true,
        line: 'No se envió',
      );
      const info = IslandEvent(id: 'info', sticky: true, line: 'Información');
      _scene.value = const _Scene(events: [info, failed]);
      await _settle(tester);
      expect(_text(tester, _line), 'No se envió');
      _scene.value = _Scene(events: [info, failed, _needsYou()]);
      await _settle(tester);
      expect(_text(tester, _line), 'Te necesita');
      expect(
        find.descendant(of: _key('island-waiting'), matching: find.text('+2')),
        findsOneWidget,
      );
      // Acted on: the next most important one takes its place.
      await tester.tap(_key('island-action'));
      await _settle(tester);
      expect(_text(tester, _line), 'No se envió');
    });

    testWidgets('a sticky one stays until it is acted on or swiped up', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      var dismissed = 0;
      _scene.value = _Scene(
        status: IslandStatus.needsYou,
        events: [_needsYou(onDismissed: () => dismissed++)],
      );
      await _settle(tester);
      await tester.pump(const Duration(minutes: 5));
      expect(_text(tester, _line), 'Te necesita');
      await tester.fling(_line, const Offset(0, -60), 800);
      await _settle(tester);
      expect(dismissed, 1);
      expect(_line, findsNothing);
      // Dismissed, the state is still on the dot.
      expect(_key('island-dot-needsYou'), findsOneWidget);
      // The same event does not come back by itself…
      _scene.value = _Scene(
        status: IslandStatus.needsYou,
        events: [_needsYou()],
      );
      await _settle(tester);
      expect(_line, findsNothing);
      // …a new one of its kind does.
      _scene.value = const _Scene(
        status: IslandStatus.needsYou,
        events: [
          IslandEvent(
            id: 'needs-you',
            revision: 2,
            tone: IslandTone.needsYou,
            sticky: true,
            line: 'Te necesita',
          ),
        ],
      );
      await _settle(tester);
      expect(_text(tester, _line), 'Te necesita');
      // A swipe down does nothing.
      await tester.fling(_line, const Offset(0, 60), 800);
      await _settle(tester);
      expect(_line, findsOneWidget);
    });
  });

  group('a passing line', () {
    testWidgets('is said when it comes or not at all: it never waits behind '
        'what stays to be said late', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      _scene.value = _Scene(
        status: IslandStatus.needsYou,
        events: [_needsYou(), _working],
      );
      await _settle(tester);
      expect(_text(tester, _line), 'Te necesita');
      expect(_key('island-waiting'), findsNothing, reason: 'nothing queued');
      // Answered: the island rests; «Trabajando» is not said now.
      await tester.tap(_key('island-action'));
      await _settle(tester);
      expect(_line, findsNothing);
      expect(_text(tester, _name), 'Hermes');
    });
  });

  group('the rest of an event', () {
    IslandEvent recovered({
      VoidCallback? onRestore,
      VoidCallback? onDiscard,
      bool sticky = true,
    }) => IslandEvent(
      id: 'recovered',
      tone: IslandTone.warning,
      sticky: sticky,
      line: 'Sin confirmar',
      more: 'No se pudo confirmar si este turno llegó al servidor.',
      action: IslandAction(label: 'Restaurar', onPressed: onRestore ?? () {}),
      secondary: IslandAction(
        label: 'Descartar',
        onPressed: onDiscard ?? () {},
      ),
    );

    testWidgets('a tap opens it: the whole text and the second action', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      var restored = 0, discarded = 0;
      _scene.value = _Scene(
        events: [
          recovered(onRestore: () => restored++, onDiscard: () => discarded++),
        ],
      );
      await _settle(tester);
      final closed = tester.getRect(_island);
      expect(_key('island-secondary'), findsNothing);
      expect(_key('island-event-more'), findsNothing);
      await tester.tap(_line);
      await _settle(tester);
      final open = tester.getRect(_island);
      expect(open.top, closed.top);
      expect(open.height, greaterThan(closed.height));
      expect(
        _text(tester, _key('island-event-more')),
        'No se pudo confirmar si este turno llegó al servidor.',
      );
      // Opened it still takes its touches, below the header's own band.
      await tester.tap(_key('island-secondary'));
      await _settle(tester);
      expect((restored, discarded), (0, 1));
      expect(_line, findsNothing, reason: 'acted on');
    });

    testWidgets('opened, it never reaches the composer', (tester) async {
      _phone(tester, size: const Size(320, 480));
      await tester.pumpWidget(_app(const _Chat(), textScale: 2));
      _scene.value = _Scene(events: [recovered()]);
      await _settle(tester);
      await tester.tap(_line);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(_island).bottom,
        lessThan(tester.getRect(_composer).top),
      );
    });

    testWidgets('while it is being read it does not expire', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      _scene.value = _Scene(events: [recovered(sticky: false)]);
      await _settle(tester);
      await tester.tap(_line);
      await _settle(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(_key('island-event-more'), findsOneWidget);
      // Closed again, its time starts over and then it leaves.
      await tester.tap(_line);
      await _settle(tester);
      expect(_key('island-event-more'), findsNothing);
      await tester.pump(const Duration(seconds: 9));
      await _settle(tester);
      expect(_line, findsNothing);
    });

    testWidgets('a line that does not fit opens with a tap too', (
      tester,
    ) async {
      _phone(tester, size: const Size(320, 640));
      await tester.pumpWidget(_app(const _Chat()));
      _scene.value = const _Scene(
        events: [
          IslandEvent(
            id: 'long',
            sticky: true,
            line: 'Resumen diario falló',
            detail: 'a las 08:30 de la mañana en el servidor principal',
          ),
        ],
      );
      await _settle(tester);
      final closed = tester.getRect(_island);
      expect(closed.right, lessThanOrEqualTo(tester.getRect(_key('new')).left));
      await tester.tap(_line);
      await _settle(tester);
      expect(
        _text(tester, _key('island-event-more')),
        'a las 08:30 de la mañana en el servidor principal',
      );
      expect(_taps, 0, reason: 'the tap opened the event, not the panel');
    });

    testWidgets('a short line with nothing behind it: the tap is the '
        'island\'s', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      _scene.value = const _Scene(
        events: [
          IslandEvent(id: 'done', tone: IslandTone.success, line: 'Listo'),
        ],
      );
      await _settle(tester);
      await tester.tap(_line);
      expect(_taps, 1);
      expect(_key('island-event-more'), findsNothing);
    });
  });

  group('the app\'s notices', () {
    testWidgets('are said by the island: nothing floats over the chat or '
        'the composer', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      await tester.pump();
      final rest = tester.getRect(_island);
      var opened = 0;
      HermesNotice.of(_ctx(tester)).show(
        title: 'Fable terminó',
        message: 'Diseño de píldora de estados',
        action: HermesNoticeAction(label: 'Ver', onPressed: () => opened++),
      );
      await _settle(tester);
      // In the island, as one line and one action.
      final card = find.byType(HermesNoticeCard);
      expect(card, findsOneWidget);
      expect(find.descendant(of: _island, matching: card), findsOneWidget);
      expect(_key('hermes-notice-lane'), findsNothing);
      expect(
        _text(tester, _line),
        'Fable terminó · Diseño de píldora de estados',
      );
      final island = tester.getRect(_island);
      expect(island.top, rest.top);
      expect(island.height, IslandMetrics.eventHeight);
      expect(island.overlaps(tester.getRect(_composer)), isFalse);
      expect(island.bottom, lessThan(844 / 4));
      await tester.tap(_key('hermes-notice-action'));
      await _settle(tester);
      expect(opened, 1);
      expect(card, findsNothing);
      expect(tester.getRect(_island), rest);
    });

    testWidgets('each kind: its line, and it leaves when its time is up', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      await tester.pump();
      final notices = HermesNotice.of(_ctx(tester));
      for (final (kind, seconds) in [
        (HermesNoticeKind.success, 3),
        (HermesNoticeKind.info, 4),
        (HermesNoticeKind.warning, 6),
        (HermesNoticeKind.error, 6),
      ]) {
        notices.show(message: 'Aviso ${kind.name}', kind: kind);
        await _settle(tester);
        expect(_text(tester, _line), 'Aviso ${kind.name}', reason: kind.name);
        await tester.pump(Duration(milliseconds: seconds * 1000 - 600));
        expect(_line, findsOneWidget, reason: kind.name);
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        expect(_line, findsNothing, reason: kind.name);
        expect(_text(tester, _name), 'Hermes');
      }
    });

    testWidgets('a notice that waits for a decision stays, in amber, until '
        'it is swiped up', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      await tester.pump();
      var closed = 0;
      HermesNotice.of(_ctx(tester)).show(
        title: 'Forja pide permiso',
        message: 'git push',
        priority: HermesNoticePriority.high,
        sticky: true,
        action: HermesNoticeAction(
          label: 'Ir',
          onPressed: () {},
          closesNotice: false,
        ),
        onClosed: () => closed++,
      );
      await _settle(tester);
      await tester.pump(const Duration(minutes: 2));
      expect(_text(tester, _line), 'Forja pide permiso · git push');
      await tester.tap(_key('hermes-notice-action'));
      await _settle(tester);
      expect(_line, findsOneWidget, reason: 'its owner closes it');
      await tester.fling(_line, const Offset(0, -60), 800);
      await _settle(tester);
      expect(_line, findsNothing);
      expect(closed, 1);
    });

    testWidgets('two notices: one shown, the other behind with «+1»', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      await tester.pump();
      final notices = HermesNotice.of(_ctx(tester));
      notices.show(message: 'Copiado', kind: HermesNoticeKind.success);
      notices.show(message: 'No se envió', kind: HermesNoticeKind.error);
      await _settle(tester);
      expect(_text(tester, _line), 'Copiado');
      expect(
        find.descendant(of: _key('island-waiting'), matching: find.text('+1')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 2600));
      await _settle(tester);
      expect(_text(tester, _line), 'No se envió');
      expect(_key('island-waiting'), findsNothing);
    });

    testWidgets('feedback shows at once over what waits for you, which '
        'comes back', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      await tester.pump();
      _scene.value = _Scene(
        status: IslandStatus.needsYou,
        events: [_needsYou()],
      );
      await _settle(tester);
      HermesNotice.of(
        _ctx(tester),
      ).show(message: 'Copiado', kind: HermesNoticeKind.success);
      await _settle(tester);
      expect(_text(tester, _line), 'Copiado');
      expect(
        find.descendant(of: _key('island-waiting'), matching: find.text('+1')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(_text(tester, _line), 'Te necesita');
    });

    testWidgets('a notice that stays waits behind what needs you here', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      await tester.pump();
      _scene.value = _Scene(
        status: IslandStatus.needsYou,
        events: [_needsYou()],
      );
      await _settle(tester);
      HermesNotice.of(_ctx(tester)).show(
        message: 'Sesión caducada',
        kind: HermesNoticeKind.warning,
        sticky: true,
      );
      await _settle(tester);
      expect(_text(tester, _line), 'Te necesita');
      expect(_key('island-waiting'), findsOneWidget);
      await tester.tap(_key('island-action'));
      await _settle(tester);
      expect(_text(tester, _line), 'Sesión caducada');
    });

    testWidgets('a screen WITHOUT an island keeps the top lane, drawn as '
        'the same event', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SizedBox(key: ValueKey('composer'), height: 72),
                ),
              ],
            ),
          ),
        ),
      );
      var undone = 0;
      HermesNotice.of(_ctx(tester)).show(
        title: 'Conversación archivada',
        message: 'Proyecto de prueba',
        action: HermesNoticeAction(
          label: 'Deshacer',
          onPressed: () => undone++,
        ),
      );
      await _settle(tester);
      expect(_key('hermes-notice-lane'), findsOneWidget);
      expect(find.byType(ChatIsland), findsNothing, reason: 'no island here');
      final card = find.byType(HermesNoticeCard);
      final surface = find.descendant(
        of: card,
        matching: find.byType(IslandSurface),
      );
      final rect = tester.getRect(surface);
      expect(rect.top, _statusBar + 8);
      expect(rect.center.dx, closeTo(195, 0.5));
      expect(rect.height, IslandMetrics.eventHeight);
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(390 - 16));
      expect(
        _text(tester, _line),
        'Conversación archivada · Proyecto de prueba',
      );
      expect(tester.widget<Text>(_line).maxLines, 1);
      await tester.tap(_key('hermes-notice-action'));
      await _settle(tester);
      expect(undone, 1);
      expect(card, findsNothing);
    });

    testWidgets('covered by another screen the island hands them to the '
        'top lane, and takes them back', (tester) async {
      _phone(tester);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_app(const _Chat(), navigatorKey: navigator));
      await tester.pump();
      HermesNotice.of(_ctx(tester)).show(
        message: 'Aprobación pendiente',
        priority: HermesNoticePriority.high,
        sticky: true,
      );
      await _settle(tester);
      expect(
        find.descendant(of: _island, matching: find.byType(HermesNoticeCard)),
        findsOneWidget,
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Ajustes')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_key('hermes-notice-lane'), findsOneWidget);
      expect(find.text('Aprobación pendiente'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_key('hermes-notice-lane'), findsNothing);
      expect(
        find.descendant(of: _island, matching: find.byType(HermesNoticeCard)),
        findsOneWidget,
      );
    });
  });

  group('accessibility', () {
    testWidgets('at rest it is a button that says the name and the state', (
      tester,
    ) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const _Chat()));
      for (final (status, label) in [
        (IslandStatus.idle, 'Hermes, Conectado'),
        (IslandStatus.working, 'Hermes, Trabajando'),
        (IslandStatus.needsYou, 'Hermes, Te necesita'),
        (IslandStatus.reconnecting, 'Hermes, Reconectando…'),
        (IslandStatus.offline, 'Hermes, Sin conexión'),
        (IslandStatus.error, 'Hermes, Error'),
      ]) {
        _scene.value = _Scene(status: status);
        await tester.pump();
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        expect(node.flagsCollection.isButton, isTrue, reason: label);
        expect(node.hint, 'Ver');
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: label,
        );
      }
      handle.dispose();
    });

    testWidgets('an event is a polite live region; its action is a button', (
      tester,
    ) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const _Chat()));
      tester.takeAnnouncements();
      _scene.value = const _Scene(events: [_working]);
      await _settle(tester);
      final node = tester.getSemantics(
        find.bySemanticsLabel('Trabajando. Terminal'),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(tester.takeAnnouncements(), isEmpty);
      handle.dispose();
    });

    testWidgets('needs you and failures are announced at once', (tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const _Chat()));
      await tester.pump();
      tester.takeAnnouncements();
      _scene.value = _Scene(events: [_needsYou()]);
      await _settle(tester);
      var said = tester.takeAnnouncements();
      expect(said.map((a) => a.message), ['Te necesita']);
      expect(said.single.assertiveness, Assertiveness.assertive);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Ver'))
            .flagsCollection
            .isButton,
        isTrue,
      );
      // The app's notices too, with their severity in words.
      _scene.value = const _Scene();
      await _settle(tester);
      HermesNotice.of(
        _ctx(tester),
      ).show(message: 'No se pudo guardar', kind: HermesNoticeKind.error);
      await _settle(tester);
      said = tester.takeAnnouncements();
      expect(said.map((a) => a.message), ['Error. No se pudo guardar']);
      expect(said.single.assertiveness, Assertiveness.assertive);
      expect(
        find.bySemanticsLabel('Error. No se pudo guardar'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the screen reader can dismiss an event', (tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const _Chat()));
      var dismissed = 0;
      _scene.value = _Scene(
        events: [_needsYou(onDismissed: () => dismissed++)],
      );
      await _settle(tester);
      final node = tester.getSemantics(_key('island-event'));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.dismiss),
        isTrue,
      );
      tester.semantics.performAction(
        find.semantics.byPredicate((n) => n.id == node.id),
        SemanticsAction.dismiss,
      );
      await _settle(tester);
      expect(dismissed, 1);
      expect(_line, findsNothing);
      handle.dispose();
    });

    for (final (locale, size) in const [
      ('es', Size(320, 640)),
      ('es', Size(390, 844)),
    ]) {
      testWidgets('320 dp and text ×2 fit: the name gives way, the action '
          'never (${size.width.toInt()} dp, $locale)', (tester) async {
        _phone(tester, size: size);
        await tester.pumpWidget(_app(const _Chat(), textScale: 2));
        final menu = tester.getRect(_key('menu'));
        final plus = tester.getRect(_key('new'));
        _scene.value = const _Scene(
          name: 'Un bot con un nombre larguísimo que no cabe nunca jamás',
          status: IslandStatus.working,
          timer: '12:34',
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        var island = tester.getRect(_island);
        expect(island.left, greaterThanOrEqualTo(menu.right));
        expect(island.right, lessThanOrEqualTo(plus.left));
        expect(island.center.dx, closeTo(size.width / 2, 0.5));
        expect(tester.widget<Text>(_name).overflow, TextOverflow.ellipsis);
        expect(_key('timer'), findsOneWidget);
        // Like an app bar title, its text stops growing at 1.34.
        expect(
          MediaQuery.textScalerOf(tester.element(_name)).scale(10) / 10,
          closeTo(FloatingChatHeader.maxTextScale, 0.01),
        );
        _scene.value = _Scene(
          events: [
            IslandEvent(
              id: 'needs-you',
              tone: IslandTone.needsYou,
              sticky: true,
              line: 'Forja pide permiso para una orden muy larga',
              detail: 'git push --force-with-lease origin main',
              action: IslandAction(label: 'Permitir', onPressed: () {}),
            ),
          ],
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        island = tester.getRect(_island);
        expect(island.left, greaterThanOrEqualTo(menu.right));
        expect(island.right, lessThanOrEqualTo(plus.left));
        final action = tester.getRect(_key('island-action'));
        expect(action.right, lessThanOrEqualTo(island.right));
        expect(action.left, greaterThan(island.left));
        expect(action.size.height, greaterThanOrEqualTo(48));
        expect(find.text('Permitir'), findsOneWidget);
        final label = tester.getRect(find.text('Permitir'));
        expect(label.right, lessThanOrEqualTo(island.right));
        expect(tester.getRect(_line).width, greaterThan(0));
      });
    }
  });

  group('fluidity', () {
    testWidgets('nothing the island does rebuilds the transcript', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat(), reduce: false));
      await tester.pump();
      final builds = _transcriptBuilds;
      final notices = HermesNotice.of(_ctx(tester));
      // A turn: the line, then the timer ticking.
      _scene.value = const _Scene(
        status: IslandStatus.working,
        events: [_working],
        timer: '0:00',
      );
      for (var second = 1; second <= 6; second++) {
        await tester.pump(const Duration(seconds: 1));
        _scene.value = _Scene(
          status: IslandStatus.working,
          events: const [_working],
          timer: '0:0$second',
        );
      }
      // Notices come and go, one is acted on, one is swiped away.
      notices.show(message: 'Copiado', kind: HermesNoticeKind.success);
      await _settle(tester);
      notices.show(
        message: 'No se envió',
        kind: HermesNoticeKind.error,
        action: HermesNoticeAction(label: 'Reintentar', onPressed: () {}),
      );
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      await tester.tap(_key('hermes-notice-action'));
      await _settle(tester);
      _scene.value = _Scene(
        status: IslandStatus.needsYou,
        events: [_needsYou()],
      );
      await _settle(tester);
      await tester.fling(_line, const Offset(0, -60), 800);
      await _settle(tester);
      _scene.value = const _Scene();
      await _settle(tester);
      expect(_transcriptBuilds, builds);
    });
  });

  group('for the panel that hangs under it', () {
    testWidgets('its pill is found without the room the sprite stands in', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const _Chat()));
      final header = tester.element(find.byType(FloatingChatHeader));
      final rect = ChatIsland.surfaceRectIn(header)!;
      expect(rect, tester.getRect(_island));
      expect(rect.top, greaterThan(tester.getRect(_key('sprite')).center.dy));
      expect(ChatIsland.surfaceRectIn(tester.element(_composer)), isNull);
    });
  });
}
