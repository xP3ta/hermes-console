import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_terminal_input.dart';
import 'package:hermes_android/core/design/floating.dart';
import 'package:hermes_android/core/design/gel_surface.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/widgets/ssh_session_kind_picker.dart';
import 'package:hermes_android/core/widgets/ssh_terminal_controls.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:xterm/xterm.dart';
import 'package:hermes_android/core/design/hicons.dart';

Widget _app(
  Widget child, {
  ThemeData? theme,
  bool reduceMotion = false,
  double textScale = 1,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: Scaffold(body: child),
);

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Bottom-anchored key bar over a terminal whose output is recorded.
/// The dock at the bottom of the screen over a terminal whose output is
/// recorded, its arrow pad open above it when ✥ opens it.
Widget _keyBar(
  Terminal terminal,
  ValueNotifier<bool> ctrl, {
  ValueNotifier<bool>? arrows,
  bool composeOpen = false,
  bool keyboardUp = false,
  VoidCallback? onCompose,
  VoidCallback? onKeyboard,
}) => Column(
  mainAxisAlignment: MainAxisAlignment.end,
  children: [
    if (arrows != null)
      ValueListenableBuilder<bool>(
        valueListenable: arrows,
        builder: (context, open, _) => open
            ? SshTerminalArrowPad(
                terminal: terminal,
                modifiers: SshKeyModifiers(ctrlArmed: ctrl),
              )
            : const SizedBox.shrink(),
      ),
    SshTerminalDock(
      terminal: terminal,
      ctrlArmed: ctrl,
      arrowsOpen: arrows,
      composeOpen: composeOpen,
      keyboardUp: keyboardUp,
      onCompose: onCompose ?? () {},
      onKeyboard: onKeyboard ?? () {},
    ),
  ],
);

/// Widgets whose key starts with [prefix].
Finder _keyed(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

/// Swipes the key strip until [cap] shows.
Future<void> _pageTo(WidgetTester tester, String cap) async {
  final dot = find.byKey(const ValueKey('ssh-key-page-dot-current'));
  var way = -1.0;
  for (var i = 0; i < 24; i++) {
    if (_key(cap).hitTestable().evaluate().isNotEmpty) return;
    final before = tester.getCenter(dot);
    // Most of a page: the strip moves one page.
    final strip = find.byKey(const ValueKey('ssh-key-bar'));
    await tester.drag(strip, Offset(tester.getSize(strip).width * 0.9 * way, 0));
    await tester.pumpAndSettle();
    // At the last page, back the other way.
    if (tester.getCenter(dot) == before) way = -way;
  }
  fail('$cap is on no page');
}

/// Taps [cap], swiping the strip to it first.
Future<void> _press(WidgetTester tester, String cap) async {
  await _pageTo(tester, cap);
  await tester.tap(_key(cap));
}

Finder _key(String cap) => find.byKey(ValueKey('ssh-key-$cap'));

Material _keyMaterial(WidgetTester tester, String cap) => tester.widget(
  find.descendant(of: _key(cap), matching: find.byType(Material)).first,
);

/// The haptic ticks asked of the platform while the test runs.
List<Object?> _recordHaptics(WidgetTester tester) {
  final ticks = <Object?>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') ticks.add(call.arguments);
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return ticks;
}

final _themes = <String, ThemeData>{
  'dark': AppTheme.hermesRedDark,
  'light': AppTheme.hermesRedLight,
};

void main() {
  group('SshTerminalDock', () {
    // 1.4.3 (herdr's dock): the keys are pages of a strip in a pill, the
    // actions a second pill. Keys a phone keyboard lacks still send what a
    // terminal expects.
    testWidgets('herdr\'s three pages first, then Console\'s own', (tester) async {
      expect(sshTerminalKeyPages.take(3), [
        ['esc', 'ctrl', 'alt', 'tab', '⇧tab', '✥'],
        ['/', '-', 'home', 'end', 'pgup', 'pgdn'],
        ['^C', '^D', '^Z', '^L', '|', '~'],
      ]);
      expect(sshTerminalKeyPages[3], ['_', ':', '⌫', 'paste']);
      expect(sshTerminalKeyPages.skip(4).expand((page) => page), [
        for (var i = 1; i <= 12; i++) 'F$i',
      ]);
    });

    testWidgets('keys send what a terminal expects', (tester) async {
      _setView(tester, const Size(500, 900));
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      for (final cap in [
        'esc',
        'tab',
        '⇧tab',
        '/',
        'home',
        'pgdn',
        '^C',
        '^D',
        '^Z',
        '^L',
        '|',
        '~',
        '⌫',
        'F5',
      ]) {
        await _press(tester, cap);
      }
      expect(out, [
        '\x1b',
        '\t',
        '\x1b[Z',
        '/',
        '\x1b[H',
        '\x1b[6~',
        '\x03',
        '\x04',
        '\x1a',
        '\x0c',
        '|',
        '~',
        '\x7f',
        '\x1b[15~',
      ]);
    });

    testWidgets('pages swipe, their dots follow, the pills hold at 48 dp', (
      tester,
    ) async {
      _setView(tester, const Size(500, 900));
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(Terminal(), ctrl)));

      double dotX() => tester
          .getCenter(find.byKey(const ValueKey('ssh-key-page-dot-current')))
          .dx;
      final first = dotX();
      expect(_key('esc').hitTestable(), findsOneWidget);
      expect(_key('/').hitTestable(), findsNothing);
      final strip = find.byKey(const ValueKey('ssh-key-bar'));
      await tester.drag(strip, Offset(-tester.getSize(strip).width * 0.9, 0));
      await tester.pumpAndSettle();
      expect(_key('/').hitTestable(), findsOneWidget);
      expect(dotX(), greaterThan(first));
      // herdr's dock: two pills of 44 dp, the strip's dots one per page,
      // hairlines between the three actions.
      for (final pill in ['ssh-key-bar-pill', 'ssh-dock-actions']) {
        expect(
          tester.getSize(find.byKey(ValueKey(pill))).height,
          SshTerminalDock.keyHeight,
        );
      }
      expect(tester.getSize(_key('/')).height, SshTerminalDock.keyHeight);
      expect(
        _keyed('ssh-key-page-dot'),
        findsNWidgets(sshTerminalKeyPages.length),
      );
      expect(_keyed('ssh-dock-divider'), findsNWidgets(2));
      final pill = tester.getRect(find.byKey(const ValueKey('ssh-key-bar-pill')));
      final actions = tester.getRect(
        find.byKey(const ValueKey('ssh-dock-actions')),
      );
      expect(actions.left - pill.right, 8);
      expect(actions.top, pill.top);
      // The dots sit on the strip's lower edge, inside it.
      final dot = tester.getRect(
        find.byKey(const ValueKey('ssh-key-page-dot-current')),
      );
      expect(dot.bottom, lessThanOrEqualTo(pill.bottom));
      expect(dot.top, greaterThan(pill.center.dy));
    });

    testWidgets('every key gives one selection tick', (tester) async {
      _setView(tester, const Size(500, 900));
      final ticks = _recordHaptics(tester);
      final terminal = Terminal();
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      await tester.tap(_key('esc'));
      await tester.tap(_key('ctrl'));
      await tester.tap(_key('tab'));
      expect(ticks, List.filled(3, 'HapticFeedbackType.selectionClick'));
    });

    testWidgets('ctrl is a toggle the screen reader can see', (tester) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(500, 900));
      final terminal = Terminal();
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      expect(
        tester.getSemantics(_key('ctrl')),
        isSemantics(isButton: true, hasToggledState: true, hasTapAction: true),
      );
      await tester.tap(_key('ctrl'));
      await tester.pump();
      expect(ctrl.value, isTrue);
      expect(tester.getSemantics(_key('ctrl')), isSemantics(isToggled: true));
      expect(
        tester.getSemantics(_key('esc')),
        isSemantics(label: 'Escape', isButton: true, hasTapAction: true),
      );
      // A second tap after the double-tap window lets the one-shot go.
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
      await tester.tap(_key('ctrl'));
      await tester.pump();
      expect(ctrl.value, isFalse);
      semantics.dispose();
    });

    testWidgets('ctrl and alt: a tap for the next key, a double tap locks', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(500, 900));
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      await tester.tap(_key('ctrl'));
      await tester.pump();
      expect(find.bySemanticsLabel('Control, for the next key'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(_key('tab'));
      await tester.tap(_key('esc'));
      expect(out, ['\t', '\x1b']);
      expect(ctrl.value, isFalse);

      // Double tap: locked, for every key, until it is tapped again.
      out.clear();
      await tester.tap(_key('ctrl'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(_key('ctrl'));
      await tester.pump();
      expect(find.bySemanticsLabel('Control, locked'), findsOneWidget);
      final locked = tester.widget<Material>(
        find.descendant(of: _key('ctrl'), matching: find.byType(Material)),
      );
      expect((locked.shape! as StadiumBorder).side.width, 2);
      await _press(tester, 'pgup');
      expect(out, ['\x1b[5;5~']);
      await _press(tester, '/');
      await _press(tester, '/');
      expect(ctrl.value, isTrue);
      await _pageTo(tester, 'ctrl');
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(_key('ctrl'));
      await tester.pump();
      expect(ctrl.value, isFalse);
      expect(find.bySemanticsLabel('Control'), findsOneWidget);

      // Alt: ESC before the next key.
      out.clear();
      await tester.tap(_key('alt'));
      await tester.pump();
      expect(find.bySemanticsLabel('Alt, for the next key'), findsOneWidget);
      await _press(tester, '-');
      await _press(tester, '-');
      expect(out, ['\x1b-', '-']);
      semantics.dispose();
    });

    testWidgets('✥ opens the arrow pad; it stays for repeated presses, '
        'repeats while held and closes with ✥', (tester) async {
      _setView(tester, const Size(500, 900));
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      final arrows = ValueNotifier<bool>(false);
      addTearDown(arrows.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl, arrows: arrows)));

      expect(find.byKey(const ValueKey('ssh-arrow-pad')), findsNothing);
      await tester.tap(_key('✥'));
      await tester.pump();
      expect(arrows.value, isTrue);
      final pad = find.byKey(const ValueKey('ssh-arrow-pad'));
      expect(pad, findsOneWidget);
      // ↑ over ← ↓ →.
      expect(
        tester.getCenter(_key('↑')).dy,
        lessThan(tester.getCenter(_key('↓')).dy),
      );
      expect(
        tester.getCenter(_key('←')).dx,
        lessThan(tester.getCenter(_key('→')).dx),
      );
      for (final cap in ['↑', '←', '↓', '→']) {
        expect(
          tester.getSize(_key(cap)),
          const Size.square(SshTerminalArrowPad.keySize),
          reason: cap,
        );
      }
      await tester.tap(_key('↑'));
      await tester.tap(_key('→'));
      await tester.pump();
      expect(out, ['\x1b[A', '\x1b[C']);
      expect(pad, findsOneWidget, reason: 'it stays open');

      out.clear();
      final hold = await tester.startGesture(tester.getCenter(_key('↓')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      expect(out, ['\x1b[B']);
      await tester.pump(HermesMotion.keyRepeat * 3);
      expect(out, List.filled(4, '\x1b[B'));
      await hold.up();
      await tester.pump(HermesMotion.keyRepeat * 3);
      expect(out.length, 4);

      await tester.tap(_key('✥'));
      await tester.pump();
      expect(pad, findsNothing);
    });

    testWidgets('repeat stops on pointer cancel, page scroll, unmount, and background', (
      tester,
    ) async {
      _setView(tester, const Size(500, 900));
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      final arrows = ValueNotifier<bool>(true);
      addTearDown(arrows.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl, arrows: arrows)));

      // Pointer cancel stops repeat immediately.
      final holdCancel = await tester.startGesture(tester.getCenter(_key('↓')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      expect(out, ['\x1b[B']);
      await holdCancel.cancel();
      await tester.pump(HermesMotion.keyRepeat * 4);
      expect(out.length, 1);

      // App backgrounding stops repeat immediately.
      out.clear();
      final holdBg = await tester.startGesture(tester.getCenter(_key('↓')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      expect(out, ['\x1b[B']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(HermesMotion.keyRepeat * 4);
      expect(out.length, 1);
      await holdBg.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      // Closing the arrow pad mid-hold stops repeat on unmount.
      out.clear();
      final holdHide = await tester.startGesture(tester.getCenter(_key('↑')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      expect(out, ['\x1b[A']);
      arrows.value = false;
      await tester.pump();
      await tester.pump(HermesMotion.keyRepeat * 4);
      expect(out.length, 1);
      await holdHide.up();

      // Holding backspace on the dock and swiping the pager stops repeat.
      out.clear();
      await _pageTo(tester, '⌫');
      final holdBs = await tester.startGesture(tester.getCenter(_key('⌫')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      final countAtHold = out.length;
      expect(countAtHold, greaterThanOrEqualTo(1));
      await tester.fling(
        find.byKey(const ValueKey('ssh-key-bar')),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      final countAfterSwipe = out.length;
      await tester.pump(HermesMotion.keyRepeat * 4);
      expect(out.length, countAfterSwipe);
      await holdBs.up();
    });

    testWidgets('the actions: ↵ sends Enter; Compose open or the keyboard '
        'up, ↵ steps aside; the pencil uses its accent while Compose is open', (
      tester,
    ) async {
      _setView(tester, const Size(500, 900));
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      var composes = 0;
      var keyboards = 0;
      Future<void> pump({bool composeOpen = false, bool keyboardUp = false}) =>
          tester.pumpWidget(
            _app(
              _keyBar(
                terminal,
                ctrl,
                composeOpen: composeOpen,
                keyboardUp: keyboardUp,
                onCompose: () => composes++,
                onKeyboard: () => keyboards++,
              ),
            ),
          );
      const enter = ValueKey('ssh-dock-enter');
      const keyboard = ValueKey('ssh-dock-keyboard');
      const pencil = ValueKey('ssh-key-compose');

      final semantics = tester.ensureSemantics();
      final pencilIcon = find.descendant(
        of: find.byKey(pencil),
        matching: find.byIcon(HIcons.edit_outlined),
      );
      final colors = AppTheme.hermesRedDark.hermes;

      await pump();
      expect(tester.widget<Icon>(pencilIcon).color, colors.textPrimary);
      expect(
        tester.getSemantics(find.byKey(pencil)),
        isSemantics(hasToggledState: true, isToggled: false),
      );
      await tester.tap(find.byKey(enter));
      await tester.tap(find.byKey(keyboard));
      await tester.tap(find.byKey(pencil));
      expect(out, ['\r']);
      expect((keyboards, composes), (1, 1));
      expect(find.byTooltip('Keyboard'), findsOneWidget);

      await pump(composeOpen: true);
      expect(find.byKey(enter), findsNothing);
      expect(find.byKey(keyboard), findsOneWidget);
      expect(tester.widget<Icon>(pencilIcon).color, colors.accentText);
      expect(
        tester.getSemantics(find.byKey(pencil)),
        isSemantics(hasToggledState: true, isToggled: true),
      );
      expect(
        find.descendant(of: find.byKey(pencil), matching: find.byType(Material)),
        findsNothing,
      );
      expect(_keyed('ssh-dock-divider'), findsOneWidget);

      await pump(keyboardUp: true);
      expect(find.byKey(enter), findsNothing);
      expect(find.byTooltip('Hide the keyboard'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('Paste sends the clipboard, bracketed when asked', (
      tester,
    ) async {
      _setView(tester, const Size(500, 900));
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (
        call,
      ) async {
        if (call.method == 'Clipboard.getData') return {'text': 'echo hi'};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      await _press(tester, 'paste');
      await tester.pump();
      terminal.write('\x1b[?2004h');
      await tester.tap(_key('paste'));
      await tester.pump();
      expect(out, ['echo hi', '\x1b[200~echo hi\x1b[201~']);
    });

    for (final entry in _themes.entries) {
      testWidgets('${entry.key}: the pills share the chat chrome and gel '
          'and the keys retain mono ink', (
        tester,
      ) async {
        _setView(tester, const Size(500, 900));
        final colors = entry.value.hermes;
        final chrome = HermesChrome.of(colors);
        final ctrl = ValueNotifier<bool>(false);
        addTearDown(ctrl.dispose);
        await tester.pumpWidget(
          _app(_keyBar(Terminal(), ctrl), theme: entry.value),
        );

        for (final key in ['ssh-key-bar-pill', 'ssh-dock-actions']) {
          final pill = find.byKey(ValueKey(key));
          final surface = tester.widget<HermesFloatingSurface>(
            find.descendant(of: pill, matching: find.byType(HermesFloatingSurface)),
          );
          expect(surface.fill, chrome.opaque, reason: key);
          expect(surface.shape, isA<StadiumBorder>(), reason: key);
          expect(surface.shadow, isTrue, reason: key);

          final gel = tester.widget<HermesGelSurface>(
            find.descendant(of: pill, matching: find.byType(HermesGelSurface)),
          );
          expect(gel.shape, isA<StadiumBorder>(), reason: key);
          expect(gel.sheenScale, HermesGel.textSheenScale(colors), reason: key);
          expect(gel.pressable, isFalse, reason: key);
        }
        Text text(String cap) => tester.widget<Text>(
          find.descendant(of: _key(cap), matching: find.byType(Text)),
        );
        expect(text('esc').style!.fontFamily, HermesType.monoFamily);
        expect(text('esc').style!.fontWeight, FontWeight.w500);
        expect(text('esc').style!.color, colors.textPrimary);
        // ctrl is a modifier: accent even when off (v2-A `.mod`).
        expect(text('ctrl').style!.color, colors.accentText);
        // In the pill a key has no chip unless it is on.
        expect(_keyMaterial(tester, 'esc').color, Colors.transparent);
        ctrl.value = true;
        await tester.pump();
        expect(_keyMaterial(tester, 'ctrl').color, colors.accent);
        expect(text('ctrl').style!.color, colors.onAccent);
      });
    }

    for (final (name, width, scale) in const [
      ('360 dp phone', 360.0, 1.0),
      ('narrow pane, 2x text', 300.0, 2.0),
      ('840 dp split', 840.0, 1.0),
      ('landscape', 900.0, 1.0),
    ]) {
      testWidgets('$name: no overflow, keys of 44 dp or more, every key on '
          'some page', (tester) async {
        _setView(tester, Size(width, 700));
        final semantics = tester.ensureSemantics();
        final ctrl = ValueNotifier<bool>(false);
        addTearDown(ctrl.dispose);
        await tester.pumpWidget(
          _app(_keyBar(Terminal(), ctrl), textScale: scale),
        );
        expect(tester.takeException(), isNull);
        for (final cap in sshTerminalKeyPages.expand((page) => page)) {
          await _pageTo(tester, cap);
          final size = tester.getSize(_key(cap));
          expect(size.width, greaterThanOrEqualTo(44), reason: cap);
          expect(size.height, SshTerminalDock.keyHeight, reason: cap);
          // Never shrunk under 12 sp to fit.
          final text = find.descendant(of: _key(cap), matching: find.byType(Text));
          if (text.evaluate().isNotEmpty) {
            final drawn = tester.getRect(text).height;
            expect(drawn, greaterThanOrEqualTo(12), reason: cap);
          }
        }
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  });


  group('SshTerminalExpandButton', () {
    Widget button(bool expanded, {VoidCallback? onPressed}) => Center(
      child: SshTerminalExpandButton(
        expanded: expanded,
        onPressed: onPressed ?? () {},
      ),
    );

    testWidgets('labels and icons for expand and shrink, 48 dp to touch', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(_app(button(false, onPressed: () => taps++)));

      expect(find.bySemanticsLabel('Expand terminal'), findsOneWidget);
      // Review P1-2: excludeSemantics must not take the tap away.
      expect(
        tester.getSemantics(find.byType(SshTerminalExpandButton)),
        isSemantics(
          label: 'Expand terminal',
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(find.byIcon(HIcons.open_in_full), findsOneWidget);
      expect(
        tester.getSize(find.byType(SshTerminalExpandButton)),
        const Size(48, 48),
      );
      await tester.tap(find.byType(SshTerminalExpandButton));
      expect(taps, 1);

      await tester.pumpWidget(_app(button(true)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.bySemanticsLabel('Shrink terminal'), findsOneWidget);
      expect(find.byIcon(HIcons.close_fullscreen), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('reduce motion swaps the icon without a cross-fade', (
      tester,
    ) async {
      await tester.pumpWidget(_app(button(false), reduceMotion: true));
      await tester.pumpWidget(_app(button(true), reduceMotion: true));
      await tester.pump();

      expect(find.byIcon(HIcons.open_in_full), findsNothing);
      expect(find.byIcon(HIcons.close_fullscreen), findsOneWidget);
    });

    for (final entry in _themes.entries) {
      testWidgets('${entry.key} theme: translucent surface circle', (
        tester,
      ) async {
        final colors = entry.value.hermes;
        await tester.pumpWidget(_app(button(false), theme: entry.value));

        final box = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(SshTerminalExpandButton),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.shape, BoxShape.circle);
        expect(decoration.color, colors.surface.withValues(alpha: 0.82));
        final icon = tester.widget<Icon>(find.byIcon(HIcons.open_in_full));
        expect(icon.color, colors.textPrimary);
      });
    }
  });

  group('SshSessionKindPicker', () {
    testWidgets('three choices, plain shell selected by default', (
      tester,
    ) async {
      final picked = <SshSessionKind>[];
      await tester.pumpWidget(
        _app(
          SshSessionKindPicker(
            value: SshSessionKind.shell,
            onChanged: picked.add,
          ),
        ),
      );

      expect(find.text('Session type'), findsOneWidget);
      ChoiceChip chip(String id) =>
          tester.widget(find.byKey(ValueKey('ssh-session-kind-$id')));
      expect(chip('shell').selected, isTrue);
      expect(chip('herdr').selected, isFalse);
      expect(chip('tmux').selected, isFalse);
      expect(find.text('Plain shell'), findsOneWidget);
      expect(find.text('Herdr'), findsOneWidget);
      expect(find.text('tmux'), findsOneWidget);

      await tester.tap(find.text('Herdr'));
      await tester.tap(find.text('tmux'));
      expect(picked, [SshSessionKind.herdr, SshSessionKind.tmux]);
    });

    for (final entry in _themes.entries) {
      testWidgets('${entry.key} theme and 2x text in 320 dp: no overflow', (
        tester,
      ) async {
        _setView(tester, const Size(320, 800));
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: SshSessionKindPicker(
                value: SshSessionKind.tmux,
                onChanged: (_) {},
              ),
            ),
            theme: entry.value,
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
