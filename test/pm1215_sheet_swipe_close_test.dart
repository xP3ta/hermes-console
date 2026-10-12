// Owner report (1.2.15): "the notch: when it is about to close by swiping it
// does a weird animation that looks broken; review the other pills".
//
// A bottom pill-morph sheet (the notch sheet, the status pill's sheets) is
// sampled frame by frame through a swipe-to-dismiss. While it is dragged it
// must move whole with the finger; once released it must go from where the
// finger left it into its pill in ONE motion: no frame larger than the one
// before, no edge that leaves the path release → pill or turns back.
//
// The panel that hangs under the chat's island (a TOP pill morph) had the
// same defect and follows the same rules, with one difference: pulled up it
// would cover the island it hangs from, so it rolls up under its own top
// edge instead (rows and bottom edge 1:1 with the finger, the top edge
// still).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';
import 'package:hermes_android/core/widgets/pill_morph.dart';
import 'package:hermes_android/core/widgets/status_pill_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _phone = Size(412, 892);
const _frame = Duration(milliseconds: 16);
const _step = 8.0;

final _notchKey = GlobalKey(debugLabel: 'notch');
final _statusZoneKey = GlobalKey(debugLabel: 'status-zone');
const _notchSheet = ValueKey('chat-control-dialog');
const _statusSheet = ValueKey('status-sheet-under-test');

// Every row the chat gives the notch sheet: on a phone it is taller than the
// sheet's cap, so its list scrolls (like in the app).
const _labels = ChatControlLabels(
  title: 'Ajustes de esta conversación',
  scope: 'Solo esta conversación',
  sessionSection: 'Sesión',
  toolsSection: 'Herramientas',
  dangerSection: 'Zona sensible',
  permissions: 'Permisos',
  refresh: 'Actualizar',
  artifacts: 'Artefactos',
  content: 'Contenido',
  prompts: 'Prompts',
  branch: 'Ramificar',
  details: 'Detalles',
  cron: 'Programación',
  extensions: 'Extensiones',
  skills: 'Skills',
  memory: 'Memoria',
  delete: 'Eliminar conversación',
  readOnly: 'Solo lectura',
  findInChat: 'Buscar en este chat',
  previousChat: 'Chat anterior',
  nextChat: 'Chat siguiente',
  searchChats: 'Buscar chats',
  goTo: 'Ir a',
  chats: 'Chats',
  home: 'Inicio',
  projects: 'Proyectos',
  settings: 'Ajustes',
);

Rect? _grabber() {
  final notch = pillMorphRectOf(_notchKey);
  return notch == null ? null : chatNotchGrabberRect(notch);
}

/// The bottom of a chat: transcript, the notch on the composer's top edge,
/// the composer and the status pill under it.
Future<void> _pumpChatBottom(WidgetTester tester, {bool reduce = false}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              const Expanded(child: SizedBox.expand()),
              SizedBox(
                height: kChatNotchSlotHeight,
                child: Center(
                  child: ChatNotch(
                    key: _notchKey,
                    open: false,
                    semanticLabel: 'Ajustes de la conversación e Ir a',
                    onOpen: () => showChatNotchSheet<void>(
                      context: context,
                      liveOrigin: _grabber,
                      maxWidth: 480,
                      builder: (_) => ChatControlSheet(
                        labels: _labels,
                        conversationTitle: 'Conversación de prueba',
                        showDetails: true,
                        onPermissions: () {},
                        onRefresh: () {},
                        onArtifacts: () {},
                        onContent: () {},
                        onPrompts: () {},
                        onBranch: () {},
                        onDetails: () {},
                        onExtensions: () {},
                        onSkills: () {},
                        onMemory: () {},
                        onFindInChat: () {},
                        onPreviousChat: () {},
                        onNextChat: () {},
                        onNavigate: (_) {},
                        onDelete: () {},
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 56, child: Placeholder()),
              SizedBox(
                height: 40,
                child: Center(
                  child: GestureDetector(
                    key: _statusZoneKey,
                    onTap: () => showStatusPillSheet<void>(
                      context: context,
                      origin: () => pillMorphRectOf(_statusZoneKey),
                      surfaceKey: _statusSheet,
                      title: 'Uso de contexto',
                      builder: (_) => Column(
                        children: [
                          for (var i = 0; i < 5; i++)
                            SizedBox(height: 56, child: Text('Fila $i')),
                        ],
                      ),
                    ),
                    child: const SizedBox(
                      width: 120,
                      height: 28,
                      child: Center(child: Text('42 % · modelo')),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final _islandKey = GlobalKey(debugLabel: 'island');
const _headerPanel = ValueKey('header-panel-under-test');

/// The top of a chat: a pill under the status bar that opens a panel hanging
/// under it. The panel's list is longer than the panel, so it scrolls.
Future<void> _pumpChatTop(WidgetTester tester, {bool reduce = false}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 90),
              child: GestureDetector(
                key: _islandKey,
                onTap: () => Navigator.of(context).push(
                  PillMorphRoute<void>(
                    reduceMotion: reduce,
                    dismissLabel: 'Cerrar',
                    builder: (ctx, animation) => PillMorphSurface(
                      animation: animation,
                      origin: () => pillMorphRectOf(_islandKey),
                      edge: PillMorphEdge.top,
                      color: Colors.black,
                      maxHeight: 320,
                      reduceMotion: reduce,
                      dismissLabel: 'Cerrar',
                      surfaceKey: _headerPanel,
                      onDismiss: () => Navigator.of(ctx).maybePop(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            key: ValueKey('header-panel-title'),
                            height: 44,
                            child: Center(child: Text('Actividad')),
                          ),
                          Flexible(
                            child: ListView(
                              key: const ValueKey('header-panel-list'),
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              children: [
                                for (var i = 0; i < 9; i++)
                                  SizedBox(height: 48, child: Text('Paso $i')),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const SizedBox(
                  width: 132,
                  height: 36,
                  child: Center(child: Text('Hermes')),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pulls up from [from]: past the touch slop, then [steps] moves of [_step]
/// px, one frame each. Returns the finger (still down) and the rect painted
/// on every frame since the drag was taken.
Future<(TestGesture, List<Rect>)> _pullUp(
  WidgetTester tester,
  Offset from, {
  required int steps,
}) async {
  final finger = await tester.startGesture(from);
  await finger.moveBy(const Offset(0, -20));
  await tester.pump(_frame);
  final frames = <Rect>[_morph(tester).currentRect];
  for (var i = 0; i < steps; i++) {
    await finger.moveBy(const Offset(0, -_step));
    await tester.pump(_frame);
    frames.add(_morph(tester).currentRect);
  }
  return (finger, frames);
}

/// While dragged, a header panel is the open panel rolled up by the finger:
/// same width (nothing cropped from the sides), its top edge where it was
/// (never over the pill it hangs from), its bottom edge 1:1 with the pull.
void _expectRollsUpWithFinger(Rect open, List<Rect> frames) {
  final log = 'open ${_fmt(open)}\n${_dump(frames)}';
  expect(frames.first.bottom, closeTo(open.bottom, 20.01), reason: log);
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    expect(
      f.width,
      closeTo(open.width, 0.01),
      reason: 'drag frame $i: the sides were cropped\n$log',
    );
    expect(
      f.left,
      closeTo(open.left, 0.01),
      reason: 'drag frame $i: it moved sideways\n$log',
    );
    expect(
      f.top,
      closeTo(open.top, 0.01),
      reason: 'drag frame $i: the top edge went over the pill\n$log',
    );
    expect(
      frames.first.bottom - f.bottom,
      closeTo(i * _step, 0.01),
      reason: 'drag frame $i: the bottom edge left the finger\n$log',
    );
  }
}

final _layout = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_PillMorphLayout',
);

RenderPillMorph _morph(WidgetTester tester) =>
    tester.renderObject<RenderPillMorph>(_layout);

Future<Rect> _open(WidgetTester tester, Key trigger, Key sheet) async {
  await tester.tap(find.byKey(trigger));
  await tester.pump();
  await tester.pump(kPillMorphOpen + const Duration(milliseconds: 100));
  expect(find.byKey(sheet), findsOneWidget);
  final open = _morph(tester).currentRect;
  expect(open, _morph(tester).targetRect, reason: 'settled open');
  return open;
}

/// Pulls down from [from]: past the touch slop, then [steps] moves of
/// [_step] px, one frame each. Returns the finger (still down) and the rect
/// painted on every frame since the drag was taken.
Future<(TestGesture, List<Rect>)> _pullDown(
  WidgetTester tester,
  Offset from, {
  required int steps,
}) async {
  final finger = await tester.startGesture(from);
  await finger.moveBy(const Offset(0, 20));
  await tester.pump(_frame);
  final frames = <Rect>[_morph(tester).currentRect];
  for (var i = 0; i < steps; i++) {
    await finger.moveBy(const Offset(0, _step));
    await tester.pump(_frame);
    frames.add(_morph(tester).currentRect);
  }
  return (finger, frames);
}

/// The rect painted on every frame after the finger lifts, until the sheet's
/// route is gone.
Future<List<Rect>> _framesUntilGone(WidgetTester tester) async {
  final frames = <Rect>[];
  for (var i = 0; i < 60; i++) {
    await tester.pump(_frame);
    if (_layout.evaluate().isEmpty) break;
    frames.add(_morph(tester).currentRect);
  }
  return frames;
}

String _fmt(Rect r) =>
    '(${r.left.toStringAsFixed(1)}, ${r.top.toStringAsFixed(1)}) '
    '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';

String _dump(List<Rect> frames) => [
  for (var i = 0; i < frames.length; i++) '  $i: ${_fmt(frames[i])}',
].join('\n');

/// While dragged, the sheet is the open sheet moved by the finger: same
/// size (nothing cropped), 1:1 with the pull.
void _expectMovesWholeWithFinger(Rect open, List<Rect> frames) {
  final log = 'open ${_fmt(open)}\n${_dump(frames)}';
  expect(frames.first.top, closeTo(open.top, 20.01), reason: log);
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    expect(
      f.width,
      closeTo(open.width, 0.01),
      reason: 'drag frame $i: the sides were cropped\n$log',
    );
    expect(
      f.height,
      closeTo(open.height, 0.01),
      reason: 'drag frame $i: the sheet changed height\n$log',
    );
    expect(
      f.top - frames.first.top,
      closeTo(i * _step, 0.01),
      reason: 'drag frame $i: the top edge left the finger\n$log',
    );
  }
}

/// After the release: the close starts where the sheet was left, every frame
/// is inside the previous one's size and loses no more than a part of it,
/// every edge stays on its way from [release] to [pill] and never turns
/// back, and it lands on the pill (within [landing] px on its last frame) in
/// the close duration.
void _expectOneMotionIntoPill(
  Rect pill,
  Rect release,
  List<Rect> frames, {
  double landing = 6,
}) {
  final log = 'release ${_fmt(release)} → pill ${_fmt(pill)}\n${_dump(frames)}';
  expect(frames, isNotEmpty, reason: log);
  double edge(Rect r, int k) => [r.left, r.top, r.right, r.bottom][k];
  const names = ['left', 'top', 'right', 'bottom'];
  for (var k = 0; k < 4; k++) {
    expect(
      edge(frames.first, k),
      closeTo(edge(release, k), 0.5),
      reason: 'the close does not start where the sheet was left\n$log',
    );
  }
  var previous = release;
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    expect(
      f.width,
      lessThanOrEqualTo(previous.width + 0.01),
      reason: 'close frame $i grew wider\n$log',
    );
    expect(
      f.height,
      lessThanOrEqualTo(previous.height + 0.01),
      reason: 'close frame $i grew taller\n$log',
    );
    expect(
      previous.height - f.height,
      lessThanOrEqualTo(release.height * 0.4),
      reason: 'close frame $i: most of the sheet vanished at once\n$log',
    );
    for (var k = 0; k < 4; k++) {
      final from = edge(release, k), to = edge(pill, k);
      expect(
        edge(f, k),
        inInclusiveRange(math.min(from, to) - 0.01, math.max(from, to) + 0.01),
        reason: 'close frame $i: ${names[k]} edge left its path\n$log',
      );
      expect(
        (edge(f, k) - to).abs(),
        lessThanOrEqualTo((edge(previous, k) - to).abs() + 0.01),
        reason: 'close frame $i: ${names[k]} edge turned back\n$log',
      );
    }
    previous = f;
  }
  final last = frames.last;
  for (var k = 0; k < 4; k++) {
    expect(edge(last, k), closeTo(edge(pill, k), landing), reason: log);
  }
  expect(
    frames.length,
    lessThanOrEqualTo(kPillMorphClose.inMilliseconds ~/ 16 + 3),
    reason: 'closed in time\n$log',
  );
}

void main() {
  group('notch sheet, swiped down', () {
    final grabberStrip = find.byKey(const ValueKey('chat-notch-sheet-grabber'));

    testWidgets('pulled by its grabber it moves whole with the finger', (
      tester,
    ) async {
      await _pumpChatBottom(tester);
      final open = await _open(tester, _notchKey, _notchSheet);
      final (finger, frames) = await _pullDown(
        tester,
        tester.getCenter(grabberStrip),
        steps: 18,
      );
      _expectMovesWholeWithFinger(open, frames);
      await finger.up();
      await tester.pumpAndSettle();
    });

    testWidgets('released, it goes from the finger into the grabber in one '
        'motion', (tester) async {
      await _pumpChatBottom(tester);
      await _open(tester, _notchKey, _notchSheet);
      final (finger, frames) = await _pullDown(
        tester,
        tester.getCenter(grabberStrip),
        steps: 18,
      );
      final release = frames.last;
      await finger.up();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_notchSheet), findsNothing);
      _expectOneMotionIntoPill(_grabber()!, release, closing);
    });

    testWidgets('pulled by its content at the top of the list: the same', (
      tester,
    ) async {
      await _pumpChatBottom(tester);
      final open = await _open(tester, _notchKey, _notchSheet);
      final list = find.byKey(const ValueKey('chat-control-sheet'));
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0), reason: 'it scrolls');
      final (finger, frames) = await _pullDown(
        tester,
        tester.getCenter(find.byKey(const ValueKey('chat-control-find'))),
        steps: 18,
      );
      expect(position.pixels, 0);
      _expectMovesWholeWithFinger(open, frames);
      final release = frames.last;
      await finger.up();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_notchSheet), findsNothing);
      _expectOneMotionIntoPill(_grabber()!, release, closing);
    });

    group('Android overscroll stretch of its list', () {
      final list = find.byKey(const ValueKey('chat-control-sheet'));
      final effects = find.descendant(
        of: list,
        matching: find.byType(StretchEffect),
      );
      double stretch(WidgetTester tester) => tester
          .widgetList<StretchEffect>(effects)
          .fold(0, (peak, e) => math.max(peak, e.stretchStrength.abs()));

      testWidgets('none under the finger that is pulling the sheet down', (
        tester,
      ) async {
        await _pumpChatBottom(tester);
        await _open(tester, _notchKey, _notchSheet);
        expect(effects, findsOneWidget, reason: 'the list has the indicator');
        final finger = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('chat-control-find'))),
        );
        await finger.moveBy(const Offset(0, 20));
        await tester.pump(_frame);
        for (var i = 0; i < 18; i++) {
          await finger.moveBy(const Offset(0, _step));
          await tester.pump(_frame);
          expect(stretch(tester), 0, reason: 'frame $i: rows deformed');
        }
        expect(_morph(tester).currentRect.top, greaterThan(250));
        await finger.up();
        await tester.pumpAndSettle();
        expect(find.byKey(_notchSheet), findsNothing);
      });

      testWidgets('kept for a fling that runs the list into its top', (
        tester,
      ) async {
        await _pumpChatBottom(tester);
        final open = await _open(tester, _notchKey, _notchSheet);
        final position = tester
            .state<ScrollableState>(
              find.descendant(of: list, matching: find.byType(Scrollable)),
            )
            .position;
        await tester.drag(list, const Offset(0, -260));
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(200));
        await tester.fling(list, const Offset(0, 80), 5000);
        var peak = 0.0;
        for (var i = 0; i < 40; i++) {
          await tester.pump(_frame);
          peak = math.max(peak, stretch(tester));
          expect(_morph(tester).currentRect, open, reason: 'sheet stays put');
        }
        expect(position.pixels, 0);
        expect(peak, greaterThan(0));
        await tester.pumpAndSettle();
        expect(find.byKey(_notchSheet), findsOneWidget);
      });
    });

    testWidgets('a fast flick closes it the same way', (tester) async {
      await _pumpChatBottom(tester);
      await _open(tester, _notchKey, _notchSheet);
      final finger = await tester.startGesture(tester.getCenter(grabberStrip));
      // 40 px per frame: 2500 px/s, released after 60 px of travel.
      await finger.moveBy(const Offset(0, 20), timeStamp: _frame);
      await tester.pump(_frame);
      await finger.moveBy(const Offset(0, 40), timeStamp: _frame * 2);
      await tester.pump(_frame);
      await finger.moveBy(const Offset(0, 40), timeStamp: _frame * 3);
      await tester.pump(_frame);
      final release = _morph(tester).currentRect;
      await finger.up(timeStamp: _frame * 3);
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_notchSheet), findsNothing);
      _expectOneMotionIntoPill(_grabber()!, release, closing);
    });

    // Not part of the report: a guard that Back / an outside tap on a sheet
    // that is still opening keeps retracing the opening (no jump onto the
    // close curve). Its last frame is the opening's first, a few px off.
    testWidgets('closed before it has finished opening, it shrinks from the '
        'size it has', (tester) async {
      await _pumpChatBottom(tester);
      await tester.tap(find.byKey(_notchKey));
      await tester.pump();
      // Half-way through the opening route the sheet is almost all out.
      for (var i = 0; i < 10; i++) {
        await tester.pump(_frame);
      }
      final before = _morph(tester).currentRect;
      expect(before.height, greaterThan(_morph(tester).targetRect.height / 2));
      await tester.binding.handlePopRoute();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_notchSheet), findsNothing);
      _expectOneMotionIntoPill(_grabber()!, before, closing, landing: 40);
    });

    testWidgets('flung down while it is still opening: still one motion', (
      tester,
    ) async {
      await _pumpChatBottom(tester);
      await tester.tap(find.byKey(_notchKey));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(_frame);
      }
      // 80 ms in: about two thirds out. Grab it by its top and fling it.
      final growing = _morph(tester).currentRect;
      final finger = await tester.startGesture(
        Offset(growing.center.dx, growing.top + 10),
      );
      await finger.moveBy(const Offset(0, 40), timeStamp: _frame);
      await tester.pump(_frame);
      await finger.moveBy(const Offset(0, 40), timeStamp: _frame * 2);
      await tester.pump(_frame);
      final release = _morph(tester).currentRect;
      expect(release.height, lessThan(_morph(tester).targetRect.height - 20));
      await finger.up(timeStamp: _frame * 2);
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_notchSheet), findsNothing);
      _expectOneMotionIntoPill(_grabber()!, release, closing, landing: 40);
    });

    testWidgets('released short of the threshold it returns whole', (
      tester,
    ) async {
      await _pumpChatBottom(tester);
      final open = await _open(tester, _notchKey, _notchSheet);
      final (finger, _) = await _pullDown(
        tester,
        tester.getCenter(grabberStrip),
        steps: 6,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await finger.up();
      var previous = _morph(tester).currentRect;
      for (var i = 0; i < 40; i++) {
        await tester.pump(_frame);
        final f = _morph(tester).currentRect;
        expect(f.size, open.size, reason: 'spring frame $i');
        expect(f.top, lessThanOrEqualTo(previous.top + 0.01));
        expect(f.top, greaterThanOrEqualTo(open.top - 0.01));
        previous = f;
      }
      expect(find.byKey(_notchSheet), findsOneWidget);
      expect(previous.top, closeTo(open.top, 0.5));
    });

    testWidgets('reduced motion: follows the finger, then only fades where '
        'it was left', (tester) async {
      await _pumpChatBottom(tester, reduce: true);
      final open = await _open(tester, _notchKey, _notchSheet);
      final (finger, frames) = await _pullDown(
        tester,
        tester.getCenter(grabberStrip),
        steps: 18,
      );
      _expectMovesWholeWithFinger(open, frames);
      final release = frames.last;
      await finger.up();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_notchSheet), findsNothing);
      for (final f in closing) {
        expect(f, release, reason: 'no geometry under reduced motion');
      }
      expect(
        closing.length,
        lessThanOrEqualTo(kPillMorphFade.inMilliseconds ~/ 16 + 3),
      );
    });
  });

  group('status pill sheet, swiped down', () {
    final handle = find.byKey(const ValueKey('status-sheet-handle'));

    testWidgets('moves whole with the finger and closes into its pill in one '
        'motion', (tester) async {
      await _pumpChatBottom(tester);
      final open = await _open(tester, _statusZoneKey, _statusSheet);
      final (finger, frames) = await _pullDown(
        tester,
        tester.getCenter(handle),
        steps: 18,
      );
      _expectMovesWholeWithFinger(open, frames);
      final release = frames.last;
      await finger.up();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_statusSheet), findsNothing);
      _expectOneMotionIntoPill(
        pillMorphRectOf(_statusZoneKey)!,
        release,
        closing,
      );
    });
  });

  group('header panel, swiped up', () {
    final title = find.byKey(const ValueKey('header-panel-title'));
    final list = find.byKey(const ValueKey('header-panel-list'));

    testWidgets('pulled by its title it rolls up with the finger and never '
        'covers the pill it hangs from', (tester) async {
      await _pumpChatTop(tester);
      final pill = pillMorphRectOf(_islandKey)!;
      final open = await _open(tester, _islandKey, _headerPanel);
      expect(open.top, greaterThanOrEqualTo(pill.bottom));
      final row = find.text('Paso 0');
      final rowTop = tester.getTopLeft(row).dy;
      final (finger, frames) = await _pullUp(
        tester,
        tester.getCenter(title),
        steps: 18,
      );
      _expectRollsUpWithFinger(open, frames);
      // Its rows travel with the finger (they are not squashed in place).
      expect(
        rowTop - tester.getTopLeft(row).dy,
        closeTo(open.bottom - frames.last.bottom, 0.01),
      );
      await finger.up();
      await tester.pumpAndSettle();
    });

    testWidgets('released, it goes from the finger into the pill in one '
        'motion', (tester) async {
      await _pumpChatTop(tester);
      await _open(tester, _islandKey, _headerPanel);
      final (finger, frames) = await _pullUp(
        tester,
        tester.getCenter(title),
        steps: 18,
      );
      final release = frames.last;
      await finger.up();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_headerPanel), findsNothing);
      _expectOneMotionIntoPill(pillMorphRectOf(_islandKey)!, release, closing);
    });

    testWidgets('pulled by its list at the end of the list: the same', (
      tester,
    ) async {
      await _pumpChatTop(tester);
      final open = await _open(tester, _islandKey, _headerPanel);
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0), reason: 'it scrolls');
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      final (finger, frames) = await _pullUp(
        tester,
        tester.getCenter(list),
        steps: 18,
      );
      expect(position.pixels, position.maxScrollExtent);
      _expectRollsUpWithFinger(open, frames);
      final release = frames.last;
      await finger.up();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_headerPanel), findsNothing);
      _expectOneMotionIntoPill(pillMorphRectOf(_islandKey)!, release, closing);
    });

    testWidgets('a fast flick closes it the same way', (tester) async {
      await _pumpChatTop(tester);
      await _open(tester, _islandKey, _headerPanel);
      final finger = await tester.startGesture(tester.getCenter(title));
      await finger.moveBy(const Offset(0, -20), timeStamp: _frame);
      await tester.pump(_frame);
      await finger.moveBy(const Offset(0, -40), timeStamp: _frame * 2);
      await tester.pump(_frame);
      await finger.moveBy(const Offset(0, -40), timeStamp: _frame * 3);
      await tester.pump(_frame);
      final release = _morph(tester).currentRect;
      await finger.up(timeStamp: _frame * 3);
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_headerPanel), findsNothing);
      _expectOneMotionIntoPill(pillMorphRectOf(_islandKey)!, release, closing);
    });

    testWidgets('closed before it has finished opening, it shrinks from the '
        'size it has', (tester) async {
      await _pumpChatTop(tester);
      await tester.tap(find.byKey(_islandKey));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(_frame);
      }
      final before = _morph(tester).currentRect;
      expect(before.height, greaterThan(_morph(tester).targetRect.height / 2));
      await tester.binding.handlePopRoute();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_headerPanel), findsNothing);
      _expectOneMotionIntoPill(
        pillMorphRectOf(_islandKey)!,
        before,
        closing,
        landing: 40,
      );
    });

    testWidgets('released short of the threshold it unrolls whole', (
      tester,
    ) async {
      await _pumpChatTop(tester);
      final open = await _open(tester, _islandKey, _headerPanel);
      final (finger, _) = await _pullUp(
        tester,
        tester.getCenter(title),
        steps: 6,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await finger.up();
      var previous = _morph(tester).currentRect;
      for (var i = 0; i < 40; i++) {
        await tester.pump(_frame);
        final f = _morph(tester).currentRect;
        expect(f.width, open.width, reason: 'spring frame $i');
        expect(f.top, open.top, reason: 'spring frame $i');
        expect(f.bottom, greaterThanOrEqualTo(previous.bottom - 0.01));
        expect(f.bottom, lessThanOrEqualTo(open.bottom + 0.01));
        previous = f;
      }
      expect(find.byKey(_headerPanel), findsOneWidget);
      expect(previous.bottom, closeTo(open.bottom, 0.5));
    });

    testWidgets('reduced motion: follows the finger, then only fades where '
        'it was left', (tester) async {
      await _pumpChatTop(tester, reduce: true);
      final open = await _open(tester, _islandKey, _headerPanel);
      final (finger, frames) = await _pullUp(
        tester,
        tester.getCenter(title),
        steps: 18,
      );
      _expectRollsUpWithFinger(open, frames);
      final release = frames.last;
      await finger.up();
      final closing = await _framesUntilGone(tester);
      expect(find.byKey(_headerPanel), findsNothing);
      for (final f in closing) {
        expect(f, release, reason: 'no geometry under reduced motion');
      }
      expect(
        closing.length,
        lessThanOrEqualTo(kPillMorphFade.inMilliseconds ~/ 16 + 3),
      );
    });
  });
}
