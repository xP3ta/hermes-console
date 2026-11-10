import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/widgets/ssh_session_kind_picker.dart';
import 'package:hermes_android/core/widgets/ssh_terminal_controls.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:xterm/xterm.dart';

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
Widget _keyBar(Terminal terminal, ValueNotifier<bool> ctrl) => Align(
  alignment: Alignment.bottomCenter,
  child: SshTerminalKeyBar(terminal: terminal, ctrlArmed: ctrl),
);

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
  group('SshTerminalKeyBar', () {
    testWidgets('scrolls sideways at 454 dp instead of cutting keys', (
      tester,
    ) async {
      _setView(tester, const Size(454, 900));
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      final bar = find.byKey(const ValueKey('ssh-key-bar'));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: bar, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(tester.getSize(bar).height, SshTerminalKeyBar.height);
      expect(tester.getRect(_key('esc')).left, greaterThanOrEqualTo(0));

      await tester.drag(bar, const Offset(-800, 0));
      await tester.pumpAndSettle();
      final tilde = tester.getRect(_key('~'));
      expect(tilde.right, lessThanOrEqualTo(454));
      expect(tilde.left, greaterThanOrEqualTo(0));

      await tester.tap(_key('~'));
      expect(out, ['~']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keys send what a terminal expects', (tester) async {
      _setView(tester, const Size(1000, 900));
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      for (final cap in ['esc', 'tab', '^C', '^D', '↑', '↓', '←', '→', '|']) {
        await tester.tap(_key(cap));
      }

      expect(out, [
        '\x1b',
        '\t',
        '\x03',
        '\x04',
        '\x1b[A',
        '\x1b[B',
        '\x1b[D',
        '\x1b[C',
        '|',
      ]);
    });

    // Ola 7 (AUDITORIA-PULIDO §4.2): every key ticks under the finger,
    // ctrl included; the platform skips it when the system's touch
    // feedback is off.
    testWidgets('every key gives one selection tick', (tester) async {
      _setView(tester, const Size(1000, 900));
      final ticks = _recordHaptics(tester);
      final terminal = Terminal();
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      await tester.tap(_key('esc'));
      await tester.tap(_key('ctrl'));
      await tester.tap(_key('^D'));
      expect(ticks, List.filled(3, 'HapticFeedbackType.selectionClick'));
    });

    testWidgets('ctrl is a one-shot toggle the screen reader can see', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(1000, 900));
      final terminal = Terminal();
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(terminal, ctrl)));

      expect(
        tester.getSemantics(_key('ctrl')),
        isSemantics(isButton: true, hasToggledState: true),
      );
      await tester.tap(_key('ctrl'));
      await tester.pump();
      expect(ctrl.value, isTrue);
      expect(tester.getSemantics(_key('ctrl')), isSemantics(isToggled: true));
      expect(find.bySemanticsLabel('Up arrow'), findsOneWidget);
      expect(find.bySemanticsLabel('Left arrow'), findsOneWidget);
      // Review P1-2: a labelled key replaces its children's semantics, so
      // it must carry the tap itself or TalkBack's double tap does nothing.
      expect(
        tester.getSemantics(_key('↑')),
        isSemantics(label: 'Up arrow', isButton: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(_key('^C')),
        isSemantics(
          label: 'Control C, interrupt',
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(_key('ctrl')),
        isSemantics(hasTapAction: true),
      );

      await tester.tap(_key('ctrl'));
      await tester.pump();
      expect(ctrl.value, isFalse);
      semantics.dispose();
    });

    for (final entry in _themes.entries) {
      testWidgets('${entry.key} theme: keycaps use the theme tokens', (
        tester,
      ) async {
        _setView(tester, const Size(1000, 900));
        final colors = entry.value.hermes;
        final ctrl = ValueNotifier<bool>(false);
        addTearDown(ctrl.dispose);
        await tester.pumpWidget(
          _app(_keyBar(Terminal(), ctrl), theme: entry.value),
        );

        expect(_keyMaterial(tester, 'esc').color, colors.surfaceVariant);
        expect(_keyMaterial(tester, 'esc').shape, isA<StadiumBorder>());
        final cap = tester.widget<Text>(
          find.descendant(of: _key('esc'), matching: find.byType(Text)),
        );
        expect(cap.style!.color, colors.textPrimary);

        ctrl.value = true;
        await tester.pump();
        expect(_keyMaterial(tester, 'ctrl').color, colors.accent);
        final armed = tester.widget<Text>(
          find.descendant(of: _key('ctrl'), matching: find.byType(Text)),
        );
        expect(armed.style!.color, colors.onAccent);
      });
    }

    // Review P2-3: every key is a 48 dp touch target.
    testWidgets('keys are at least 48 x 48 dp', (tester) async {
      _setView(tester, const Size(1000, 900));
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(Terminal(), ctrl)));

      for (final cap in ['esc', 'tab', 'ctrl', '^C', '^D', '↑', '|', '~']) {
        final size = tester.getSize(_key(cap));
        expect(size.height, greaterThanOrEqualTo(48), reason: cap);
        expect(size.width, greaterThanOrEqualTo(48), reason: cap);
      }
    });

    // Ola 6 (audit §2.7): the set and order of mock 136 v2-A.
    testWidgets('the keys are the mock\'s, in its order', (tester) async {
      _setView(tester, const Size(1400, 900));
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(Terminal(), ctrl)));

      const mock = [
        'esc',
        'tab',
        'ctrl',
        '^C',
        '^D',
        '←',
        '↓',
        '↑',
        '→',
        '|',
        '~',
      ];
      expect(sshTerminalKeyCaps, mock);
      final lefts = [for (final cap in mock) tester.getRect(_key(cap)).left];
      expect(lefts, [...lefts]..sort());
      expect(_key('/'), findsNothing);
    });

    testWidgets('every symbol key says what it is to TalkBack', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(1400, 900));
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(_app(_keyBar(Terminal(), ctrl)));

      for (final (cap, label) in const [
        ('^C', 'Control C, interrupt'),
        ('^D', 'Control D, end of input'),
        ('|', 'Vertical bar'),
        ('~', 'Tilde'),
        ('←', 'Left arrow'),
        ('↓', 'Down arrow'),
        ('↑', 'Up arrow'),
        ('→', 'Right arrow'),
      ]) {
        expect(
          tester.getSemantics(_key(cap)),
          isSemantics(label: label, isButton: true, hasTapAction: true),
          reason: cap,
        );
      }
      semantics.dispose();
    });

    for (final entry in _themes.entries) {
      testWidgets('${entry.key}: the pill is 48 dp of floating chrome with '
          'its shadow, and the caps are the bundled mono', (tester) async {
        _setView(tester, const Size(1400, 900));
        final colors = entry.value.hermes;
        final chrome = HermesChrome.of(colors);
        final ctrl = ValueNotifier<bool>(false);
        addTearDown(ctrl.dispose);
        await tester.pumpWidget(
          _app(
            Align(
              alignment: Alignment.bottomCenter,
              child: SshTerminalKeyBar(
                terminal: Terminal(),
                ctrlArmed: ctrl,
                pill: true,
              ),
            ),
            theme: entry.value,
          ),
        );

        final pill = find.byKey(const ValueKey('ssh-key-bar-pill'));
        expect(tester.getSize(pill).height, 48);
        final box = tester.widget<Container>(pill);
        final shape = box.decoration! as ShapeDecoration;
        expect(shape.color, chrome.opaque);
        expect(shape.shadows, chrome.shadow);
        expect(shape.shape, isA<StadiumBorder>());
        final edge =
            (box.foregroundDecoration! as ShapeDecoration).shape
                as StadiumBorder;
        expect(edge.side.color, chrome.line);
        for (final cap in sshTerminalKeyCaps) {
          expect(tester.getSize(_key(cap)).height, 48, reason: cap);
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

    testWidgets('large text keeps the bar height without overflow', (
      tester,
    ) async {
      _setView(tester, const Size(360, 800));
      final ctrl = ValueNotifier<bool>(false);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        _app(_keyBar(Terminal(), ctrl), textScale: 2),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('ssh-key-bar'))).height,
        SshTerminalKeyBar.height,
      );
      // The keys keep their 48 dp at 2x (the hairline does not eat 1 dp).
      expect(tester.getSize(_key('esc')).height, 48);
    });
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
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      expect(
        tester.getSize(find.byType(SshTerminalExpandButton)),
        const Size(48, 48),
      );
      await tester.tap(find.byType(SshTerminalExpandButton));
      expect(taps, 1);

      await tester.pumpWidget(_app(button(true)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.bySemanticsLabel('Shrink terminal'), findsOneWidget);
      expect(find.byIcon(Icons.close_fullscreen), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('reduce motion swaps the icon without a cross-fade', (
      tester,
    ) async {
      await tester.pumpWidget(_app(button(false), reduceMotion: true));
      await tester.pumpWidget(_app(button(true), reduceMotion: true));
      await tester.pump();

      expect(find.byIcon(Icons.open_in_full), findsNothing);
      expect(find.byIcon(Icons.close_fullscreen), findsOneWidget);
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
        final icon = tester.widget<Icon>(find.byIcon(Icons.open_in_full));
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
