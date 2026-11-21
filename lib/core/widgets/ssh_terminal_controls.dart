// Controles de la pantalla del terminal SSH (1.4.0, F1): botón para agrandar
// el terminal y teclas auxiliares. Colores del tema; nada de hex en bruto.
// 1.4.3: the dock of herdr's mobile app, in Console's look. Two floating
// pills: the key strip in pages swiped sideways (sticky Ctrl and Alt, an
// arrow pad, the symbols a phone keyboard hides, F-keys) and the actions
// (Enter, the keyboard, Compose).
import 'dart:async';

import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../design/floating.dart' show HermesFloatingSurface;
import '../design/gel_surface.dart' show HermesGelSurface;
import '../feedback/haptics.dart';
import '../services/ssh_terminal_input.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

/// Round ⤢ button over the terminal: expands it to the whole screen and,
/// with the reduce icon, restores it. 38 dp visible, 48 dp to touch.
class SshTerminalExpandButton extends StatelessWidget {
  const SshTerminalExpandButton({
    required this.expanded,
    required this.onPressed,
    super.key,
  });

  final bool expanded;
  final VoidCallback onPressed;

  static const double size = 38;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      button: true,
      label: expanded ? strings.sshShrinkTerminal : strings.sshExpandTerminal,
      // excludeSemantics drops the InkResponse's tap: give it back here so
      // a screen reader's double tap works.
      onTap: onPressed,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: onPressed,
          radius: 24,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.surface.withValues(alpha: 0.82),
                  border: Border.all(
                    color: colors.divider.withValues(alpha: 0.5),
                  ),
                ),
                child: SizedBox(
                  width: size,
                  height: size,
                  child: AnimatedSwitcher(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: Icon(
                      expanded ? HIcons.close_fullscreen : HIcons.open_in_full,
                      key: ValueKey<bool>(expanded),
                      size: 18,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _KeyAction {
  /// A key xterm encodes ([_KeySpec.key]), with the armed modifiers.
  key,
  backTab,
  ctrl,
  alt,

  /// A fixed control character ([_KeySpec.text]): ^C, ^D, ^Z, ^L.
  chord,
  text,
  paste,
  arrows,
}

class _KeySpec {
  const _KeySpec(
    this.id,
    this.cap,
    this.action, {
    this.text,
    this.key,
    this.icon,
    this.repeats = false,
  });

  final String id;

  /// Printed keycap. Key names, not copy: they are not translated. A key
  /// with an [icon] shows the icon instead.
  final String cap;
  final _KeyAction action;
  final String? text;
  final TerminalKey? key;
  final IconData? icon;

  /// Held down, it repeats (arrows, backspace).
  final bool repeats;
}

const _KeySpec _arrowUp = _KeySpec(
  'up',
  '↑',
  _KeyAction.key,
  key: TerminalKey.arrowUp,
  repeats: true,
);
const _KeySpec _arrowDown = _KeySpec(
  'down',
  '↓',
  _KeyAction.key,
  key: TerminalKey.arrowDown,
  repeats: true,
);
const _KeySpec _arrowLeft = _KeySpec(
  'left',
  '←',
  _KeyAction.key,
  key: TerminalKey.arrowLeft,
  repeats: true,
);
const _KeySpec _arrowRight = _KeySpec(
  'right',
  '→',
  _KeyAction.key,
  key: TerminalKey.arrowRight,
  repeats: true,
);

/// The pages of the key strip, swiped sideways. The first three are
/// herdr's mobile strip: `esc ctrl alt tab ⇧tab ✥` (✥ opens the arrow
/// pad), `/ - home end pgup pgdn`, `^C ^D ^Z ^L | ~`. Then what Console had
/// besides: `_ :`, backspace and Paste, and the F-keys.
const List<List<_KeySpec>> _pages = [
  [
    _KeySpec('esc', 'esc', _KeyAction.key, key: TerminalKey.escape),
    _KeySpec('ctrl', 'ctrl', _KeyAction.ctrl),
    _KeySpec('alt', 'alt', _KeyAction.alt),
    _KeySpec('tab', 'tab', _KeyAction.key, key: TerminalKey.tab),
    _KeySpec('backtab', '⇧tab', _KeyAction.backTab),
    _KeySpec('arrows', '✥', _KeyAction.arrows),
  ],
  [
    _KeySpec('slash', '/', _KeyAction.text, text: '/'),
    _KeySpec('dash', '-', _KeyAction.text, text: '-'),
    _KeySpec('home', 'home', _KeyAction.key, key: TerminalKey.home),
    _KeySpec('end', 'end', _KeyAction.key, key: TerminalKey.end),
    _KeySpec('pgup', 'pgup', _KeyAction.key, key: TerminalKey.pageUp),
    _KeySpec('pgdn', 'pgdn', _KeyAction.key, key: TerminalKey.pageDown),
  ],
  [
    _KeySpec('ctrl-c', '^C', _KeyAction.chord, text: '\x03'),
    _KeySpec('ctrl-d', '^D', _KeyAction.chord, text: '\x04'),
    _KeySpec('ctrl-z', '^Z', _KeyAction.chord, text: '\x1a'),
    _KeySpec('ctrl-l', '^L', _KeyAction.chord, text: '\x0c'),
    _KeySpec('pipe', '|', _KeyAction.text, text: '|'),
    _KeySpec('tilde', '~', _KeyAction.text, text: '~'),
  ],
  [
    _KeySpec('underscore', '_', _KeyAction.text, text: '_'),
    _KeySpec('colon', ':', _KeyAction.text, text: ':'),
    _KeySpec(
      'backspace',
      '⌫',
      _KeyAction.key,
      key: TerminalKey.backspace,
      repeats: true,
    ),
    _KeySpec('paste', 'paste', _KeyAction.paste, icon: HIcons.content_paste),
  ],
  [
    _KeySpec('f1', 'F1', _KeyAction.key, key: TerminalKey.f1),
    _KeySpec('f2', 'F2', _KeyAction.key, key: TerminalKey.f2),
    _KeySpec('f3', 'F3', _KeyAction.key, key: TerminalKey.f3),
    _KeySpec('f4', 'F4', _KeyAction.key, key: TerminalKey.f4),
    _KeySpec('f5', 'F5', _KeyAction.key, key: TerminalKey.f5),
    _KeySpec('f6', 'F6', _KeyAction.key, key: TerminalKey.f6),
  ],
  [
    _KeySpec('f7', 'F7', _KeyAction.key, key: TerminalKey.f7),
    _KeySpec('f8', 'F8', _KeyAction.key, key: TerminalKey.f8),
    _KeySpec('f9', 'F9', _KeyAction.key, key: TerminalKey.f9),
    _KeySpec('f10', 'F10', _KeyAction.key, key: TerminalKey.f10),
    _KeySpec('f11', 'F11', _KeyAction.key, key: TerminalKey.f11),
    _KeySpec('f12', 'F12', _KeyAction.key, key: TerminalKey.f12),
  ],
];

/// The printed caps of the strip, page by page (tests and TalkBack
/// checks).
@visibleForTesting
List<List<String>> get sshTerminalKeyPages => [
  for (final page in _pages) [for (final key in page) key.cap],
];

/// The narrowest a key of the strip gets before its page is split in two
/// (a narrow pane, a 360 dp phone): the strip shows fewer keys per page
/// rather than keys too small to hit.
const double _minKeyWidth = 44;

/// [_pages] for a strip [width] wide: each page split in pieces that keep
/// every key at least [_minKeyWidth].
List<List<_KeySpec>> _pagesFor(double width) {
  final fit = (width / _minKeyWidth).floor().clamp(3, 6);
  return [
    for (final page in _pages)
      // Split evenly (six keys in two pages of three, not five and one).
      for (
        var start = 0, size = (page.length / (page.length / fit).ceil()).ceil();
        start < page.length;
        start += size
      )
        page.sublist(start, (start + size).clamp(0, page.length)),
  ];
}

/// What a screen reader says for the key [id], or null for a key whose
/// cap says it (an F-key).
String? sshTerminalKeyName(BuildContext context, Strings strings, String id) =>
    switch (id) {
      'esc' => strings.termUxKeyEscape,
      'tab' => strings.termUxKeyTab,
      'ctrl' => strings.termUxKeyControl,
      'alt' => strings.termUxKeyAlt,
      'backtab' => strings.termUxKeyBackTab,
      'arrows' => strings.termUxKeyArrows,
      'ctrl-c' => strings.sshKeyInterrupt,
      'ctrl-d' => strings.sshKeyEndOfInput,
      'ctrl-z' => strings.termUxKeySuspend,
      'ctrl-l' => strings.termUxKeyClear,
      'left' => strings.sshKeyArrowLeft,
      'down' => strings.sshKeyArrowDown,
      'up' => strings.sshKeyArrowUp,
      'right' => strings.sshKeyArrowRight,
      'pipe' => strings.sshKeyPipe,
      'tilde' => strings.sshKeyTilde,
      'paste' => MaterialLocalizations.of(context).pasteButtonLabel,
      'slash' => strings.termUxKeySlash,
      'dash' => strings.termUxKeyHyphen,
      'underscore' => strings.termUxKeyUnderscore,
      'colon' => strings.termUxKeyColon,
      'home' => strings.termUxKeyHome,
      'end' => strings.termUxKeyEnd,
      'pgup' => strings.termUxKeyPageUp,
      'pgdn' => strings.termUxKeyPageDown,
      'backspace' => strings.termUxKeyBackspace,
      _ => null,
    };

class _RepeatLifecycleObserver with WidgetsBindingObserver {
  _RepeatLifecycleObserver(this.onPause);

  final VoidCallback onPause;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) onPause();
  }
}

/// A key held down repeats ([HermesMotion.keyRepeat]) until released,
/// cancelled, scrolled away, hidden, or backgrounded.
mixin _KeyRepeat<T extends StatefulWidget> on State<T> {
  Timer? _repeat;
  late final _RepeatLifecycleObserver _lifecycleObserver =
      _RepeatLifecycleObserver(stopRepeat);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
  }

  void startRepeat(VoidCallback send) {
    _repeat?.cancel();
    HermesHaptics.selection();
    send();
    _repeat = Timer.periodic(HermesMotion.keyRepeat, (_) {
      if (!mounted) {
        stopRepeat();
        return;
      }
      send();
    });
  }

  void stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void deactivate() {
    stopRepeat();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    stopRepeat();
    super.dispose();
  }
}

/// Stops an active hold-repeat on pointer up/cancel, long-press end/cancel,
/// deactivation, or disposal so a key can never stay stuck repeating.
class _RepeatHoldDetector extends StatefulWidget {
  const _RepeatHoldDetector({
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.child,
    super.key,
  });

  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final Widget child;

  @override
  State<_RepeatHoldDetector> createState() => _RepeatHoldDetectorState();
}

class _RepeatHoldDetectorState extends State<_RepeatHoldDetector> {
  bool _holding = false;

  void _start() {
    _holding = true;
    widget.onHoldStart();
  }

  void _end() {
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd();
  }

  @override
  void deactivate() {
    _end();
    super.deactivate();
  }

  @override
  void dispose() {
    _end();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerUp: (_) => _end(),
      onPointerCancel: (_) => _end(),
      child: GestureDetector(
        onLongPressStart: (_) => _start(),
        onLongPressEnd: (_) => _end(),
        onLongPressUp: _end,
        onLongPressCancel: _end,
        child: widget.child,
      ),
    );
  }
}

/// The terminal's dock, after herdr's mobile app: two floating pills.
///
/// Left, the key strip, in pages swiped sideways with their dots under it:
/// `esc ctrl alt tab ⇧tab ✥`, `/ - home end pgup pgdn`, `^C ^D ^Z ^L | ~`,
/// then `_ : ⌫ Paste` and the F-keys. Ctrl and Alt are sticky: a tap for
/// the next key, a double tap locks them until tapped again. ✥ opens the
/// arrow pad above the dock ([arrowsOpen], drawn by the screen with
/// [SshTerminalArrowPad]).
///
/// Right, the actions: ↵ (Enter), the keyboard (typing straight into the
/// terminal; with it up, the key that hides it) and the pencil, Compose.
/// With Compose open the pencil is lit and ↵ steps aside (the card has its
/// own send); with the keyboard up ↵ steps aside too (the keyboard has
/// Enter).
class SshTerminalDock extends StatefulWidget {
  const SshTerminalDock({
    required this.terminal,
    required this.ctrlArmed,
    this.modifiers,
    this.arrowsOpen,
    this.onPaste,
    this.onCompose,
    this.onKeyboard,
    this.onShrink,
    this.composeOpen = false,
    this.keyboardUp = false,
    this.dense = false,
    super.key,
  });

  final Terminal terminal;

  /// Ctrl armed (for the next key, or locked).
  final ValueNotifier<bool> ctrlArmed;

  /// The session's sticky Ctrl (on [ctrlArmed]) and Alt; without them the
  /// dock keeps its own around [ctrlArmed].
  final SshKeyModifiers? modifiers;

  /// The arrow pad is open (✥).
  final ValueNotifier<bool>? arrowsOpen;

  /// Paste: the screen's own paste; the clipboard straight into the shell
  /// when null.
  final VoidCallback? onPaste;

  /// The pencil: opens Compose, or closes it when [composeOpen].
  final VoidCallback? onCompose;

  /// The keyboard key: shows the keyboard for the terminal, or hides it
  /// when [keyboardUp]. No keyboard key when null.
  final VoidCallback? onKeyboard;

  /// Shrinks an expanded full-screen terminal back to its header layout.
  final VoidCallback? onShrink;

  final bool composeOpen;

  /// The keyboard is up for typing straight into the terminal.
  final bool keyboardUp;

  /// No page dots: with the keyboard up in the workspace pane, where
  /// every line counts.
  final bool dense;

  /// The pills' height, herdr's 44 dp.
  static const double keyHeight = HermesSize.pill;

  @override
  State<SshTerminalDock> createState() => _SshTerminalDockState();
}

class _SshTerminalDockState extends State<SshTerminalDock>
    with _KeyRepeat<SshTerminalDock> {
  SshKeyModifiers? _ownModifiers;
  final PageController _pager = PageController();
  int _page = 0;

  SshKeyModifiers get _modifiers =>
      widget.modifiers ??
      (_ownModifiers ??= SshKeyModifiers(ctrlArmed: widget.ctrlArmed));

  @override
  void didUpdateWidget(SshTerminalDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ctrlArmed, widget.ctrlArmed)) {
      _ownModifiers?.dispose();
      _ownModifiers = null;
    }
  }

  @override
  void dispose() {
    _ownModifiers?.dispose();
    _pager.dispose();
    super.dispose();
  }

  void _press(_KeySpec key) {
    // Ola 7: each key answers under the finger, as Cadu's do.
    HermesHaptics.selection();
    _send(key);
  }

  void _send(_KeySpec key) {
    final terminal = widget.terminal;
    final modifiers = _modifiers;
    switch (key.action) {
      case _KeyAction.key:
        sshSendModifiedKey(terminal, modifiers, key.key!);
      case _KeyAction.backTab:
        sshSendModifiedKey(terminal, modifiers, TerminalKey.tab, shift: true);
      case _KeyAction.ctrl:
        modifiers.ctrl.tap();
      case _KeyAction.alt:
        modifiers.alt.tap();
      case _KeyAction.chord:
        modifiers.unmodified(() => terminal.textInput(key.text!));
      case _KeyAction.text:
        final text = modifiers.apply(key.text!);
        modifiers.unmodified(() => terminal.textInput(text));
      case _KeyAction.paste:
        final paste = widget.onPaste;
        if (paste != null) {
          paste();
        } else {
          unawaited(sshPasteClipboard(terminal, modifiers: modifiers));
        }
      case _KeyAction.arrows:
        final open = widget.arrowsOpen;
        if (open != null) open.value = !open.value;
    }
  }

  void _enter() {
    HermesHaptics.selection();
    final terminal = widget.terminal;
    _modifiers.unmodified(() => terminal.textInput('\r'));
  }

  Widget _keycap(BuildContext context, Strings strings, _KeySpec key) {
    final colors = Theme.of(context).hermes;
    final modifiers = _modifiers;
    final sticky = switch (key.action) {
      _KeyAction.ctrl => modifiers.ctrl,
      _KeyAction.alt => modifiers.alt,
      _ => null,
    };
    final armed = sticky?.armed.value ?? false;
    final locked = sticky?.locked.value ?? false;
    final arrows = key.action == _KeyAction.arrows
        ? (widget.arrowsOpen?.value ?? false)
        : null;
    final String label = switch (key.action) {
      _KeyAction.ctrl =>
        locked
            ? strings.termUxKeyControlLocked
            : armed
            ? strings.termUxKeyControlNext
            : strings.termUxKeyControl,
      _KeyAction.alt =>
        locked
            ? strings.termUxKeyAltLocked
            : armed
            ? strings.termUxKeyAltNext
            : strings.termUxKeyAlt,
      _ => sshTerminalKeyName(context, strings, key.id) ?? key.cap,
    };
    return _Keycap(
      key: ValueKey('ssh-key-${key.cap}'),
      cap: key.cap,
      icon: key.icon,
      semanticLabel: label,
      toggled: sticky != null ? armed : arrows,
      locked: locked,
      colors: colors,
      onTap: () => _press(key),
      onHoldStart: key.repeats ? () => startRepeat(() => _send(key)) : null,
      onHoldEnd: key.repeats ? stopRepeat : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final modifiers = _modifiers;
    final chrome = HermesChrome.of(colors);
    Widget pill(Key key, Widget child) => SizedBox(
      key: key,
      height: SshTerminalDock.keyHeight,
      child: HermesGelSurface(
        shape: const StadiumBorder(),
        pressable: false,
        sheenScale: HermesGel.textSheenScale(colors),
        child: HermesFloatingSurface(fill: chrome.opaque, child: child),
      ),
    );
    final actions = <Widget>[
      if (!widget.composeOpen && !widget.keyboardUp)
        _DockAction(
          key: const ValueKey('ssh-dock-enter'),
          icon: HIcons.keyboard_return_rounded,
          label: strings.termUxKeyEnter,
          colors: colors,
          accentIcon: true,
          onTap: _enter,
        ),
      if (widget.onKeyboard != null)
        _DockAction(
          key: const ValueKey('ssh-dock-keyboard'),
          icon: widget.keyboardUp
              ? HIcons.keyboard_arrow_down_rounded
              : HIcons.keyboard_outlined,
          label: widget.keyboardUp
              ? strings.termUxKeyboardHide
              : strings.termUxKeyboardShow,
          colors: colors,
          onTap: () {
            HermesHaptics.selection();
            widget.onKeyboard!();
          },
        ),
      if (widget.onCompose != null)
        _DockAction(
          key: const ValueKey('ssh-key-compose'),
          icon: HIcons.edit_outlined,
          label: strings.termUxCompose,
          colors: colors,
          selected: widget.composeOpen,
          onTap: () {
            HermesHaptics.selection();
            widget.onCompose!();
          },
        ),
      if (widget.onShrink != null)
        _DockAction(
          key: const ValueKey('ssh-terminal-expand'),
          icon: HIcons.close_fullscreen,
          label: strings.sshShrinkTerminal,
          colors: colors,
          onTap: () {
            HermesHaptics.selection();
            widget.onShrink!();
          },
        ),
    ];
    // Keycaps are symbols: past 1.3x they would only push the strip
    // taller than its pill without being easier to read.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Row(
        children: [
          Expanded(
            child: pill(
              const ValueKey('ssh-key-bar-pill'),
              LayoutBuilder(
                builder: (context, constraints) {
                  final pages = _pagesFor(
                    constraints.maxWidth - 2 * HermesSpace.x3,
                  );
                  final page = _page.clamp(0, pages.length - 1);
                  if (page != _page) {
                    // Narrower now (a rotation, a fold): fewer keys a page,
                    // more pages; stay within them.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_pager.hasClients) return;
                      _pager.jumpToPage(page);
                      setState(() => _page = page);
                    });
                  }
                  return ListenableBuilder(
                    listenable: Listenable.merge([
                      modifiers.ctrl.armed,
                      modifiers.ctrl.locked,
                      modifiers.alt.armed,
                      modifiers.alt.locked,
                      ?widget.arrowsOpen,
                    ]),
                    builder: (context, _) => Stack(
                      children: [
                        Positioned.fill(
                          child: Semantics(
                            // TalkBack reads the page it is on.
                            value: strings.termUxKeyPage(
                              '${page + 1}',
                              '${pages.length}',
                            ),
                            // The pill stays; its pages slide inside it.
                            child:
                                NotificationListener<ScrollStartNotification>(
                                  onNotification: (_) {
                                    stopRepeat();
                                    return false;
                                  },
                                  child: PageView.builder(
                                    key: const ValueKey('ssh-key-bar'),
                                    controller: _pager,
                                    itemCount: pages.length,
                                    onPageChanged: (i) {
                                      stopRepeat();
                                      setState(() => _page = i);
                                    },
                                    itemBuilder: (context, i) => Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: HermesSpace.x3,
                                      ),
                                      child: Row(
                                        children: [
                                          for (final key in pages[i])
                                            Expanded(
                                              child: _keycap(
                                                context,
                                                strings,
                                                key,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                          ),
                        ),
                        // The page dots, on the pill's lower edge.
                        if (!widget.dense && pages.length > 1)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: HermesSpace.x1,
                            child: IgnorePointer(
                              child: _PageDots(
                                count: pages.length,
                                current: page,
                                colors: colors,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: HermesSpace.x2),
            pill(
              const ValueKey('ssh-dock-actions'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, action) in actions.indexed) ...[
                      if (i > 0)
                        Container(
                          key: ValueKey('ssh-dock-divider-$i'),
                          width: 1,
                          height: HermesSpace.x5,
                          color: chrome.line,
                        ),
                      action,
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The small dots on the key strip's lower edge: which page it shows.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.current,
    required this.colors,
  });

  final int count;
  final int current;
  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              key: ValueKey(
                i == current
                    ? 'ssh-key-page-dot-current'
                    : 'ssh-key-page-dot-$i',
              ),
              width: HermesSpace.x1,
              height: HermesSpace.x1,
              margin: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x1 / 2,
              ),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == current
                    ? colors.textPrimary
                    : colors.textSecondary.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// A cell of the dock's right pill: 40 dp wide, its name for TalkBack.
class _DockAction extends StatelessWidget {
  const _DockAction({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
    this.accentIcon = false,
    this.selected,
    super.key,
  });

  final IconData icon;
  final String label;
  final HermesThemeColors colors;
  final VoidCallback onTap;

  /// ↵, in the accent.
  final bool accentIcon;

  /// The pencil's selected state while Compose is open.
  final bool? selected;

  /// The cell's width: herdr's three cells in their pill.
  static const double width = HermesSpace.x8 + HermesSpace.x2;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: SizedBox(
          width: width,
          height: SshTerminalDock.keyHeight,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Icon(
              icon,
              size: HermesIcon.lg,
              color: selected == true || accentIcon
                  ? colors.accentText
                  : colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades in and rises a few dp, as the Compose card and the arrow pad
/// appear ([HermesMotion.base]; at once when motion is reduced). Only
/// paint moves: the layout is final from the first frame, so nothing
/// under it jumps.
class SshDockEntrance extends StatelessWidget {
  const SshDockEntrance({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: HermesMotion.duration(context, HermesMotion.base),
      curve: HermesMotion.emphasized,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * HermesSpace.x2),
          child: child,
        ),
      ),
    );
  }
}

/// The arrow pad ✥ opens just above the dock: ↑ over ← ↓ →, rounded square
/// keys in a rounded tray, repeating while held, with the dock's Ctrl and
/// Alt. It stays open for one press after another; ✥ again, or a touch on
/// the terminal, closes it.
class SshTerminalArrowPad extends StatefulWidget {
  const SshTerminalArrowPad({
    required this.terminal,
    required this.modifiers,
    super.key,
  });

  final Terminal terminal;
  final SshKeyModifiers modifiers;

  /// A key of the pad.
  static const double keySize = HermesSize.pill;

  @override
  State<SshTerminalArrowPad> createState() => _SshTerminalArrowPadState();
}

class _SshTerminalArrowPadState extends State<SshTerminalArrowPad>
    with _KeyRepeat<SshTerminalArrowPad> {
  void _send(_KeySpec key) =>
      sshSendModifiedKey(widget.terminal, widget.modifiers, key.key!);

  Widget _key(BuildContext context, _KeySpec key, IconData chevron) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    void press() {
      HermesHaptics.selection();
      _send(key);
    }

    return Semantics(
      button: true,
      label: sshTerminalKeyName(context, strings, key.id),
      excludeSemantics: true,
      onTap: press,
      child: _RepeatHoldDetector(
        key: ValueKey('ssh-key-${key.cap}'),
        onHoldStart: () => startRepeat(() => _send(key)),
        onHoldEnd: stopRepeat,
        child: Material(
          color: colors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HermesRadius.control),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: press,
            child: SizedBox.square(
              dimension: SshTerminalArrowPad.keySize,
              child: Icon(chevron, color: colors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    const gap = SizedBox.square(dimension: HermesSpace.x2);
    return Container(
      key: const ValueKey('ssh-arrow-pad'),
      padding: const EdgeInsets.all(HermesSpace.x3),
      decoration: ShapeDecoration(
        color: chrome.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HermesRadius.card),
        ),
        shadows: chrome.shadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _key(context, _arrowUp, HIcons.keyboard_arrow_up_rounded),
          gap,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _key(context, _arrowLeft, HIcons.chevron_left_rounded),
              gap,
              _key(context, _arrowDown, HIcons.keyboard_arrow_down_rounded),
              gap,
              _key(context, _arrowRight, HIcons.chevron_right_rounded),
            ],
          ),
        ],
      ),
    );
  }
}

class _Keycap extends StatelessWidget {
  const _Keycap({
    required this.cap,
    required this.semanticLabel,
    required this.toggled,
    required this.colors,
    required this.onTap,
    this.icon,
    this.locked = false,
    this.onHoldStart,
    this.onHoldEnd,
    super.key,
  });

  final String cap;
  final IconData? icon;
  final String semanticLabel;
  final bool? toggled;

  /// A sticky modifier locked on: drawn with a ring, so it is not taken
  /// for one that only applies to the next key.
  final bool locked;
  final HermesThemeColors colors;
  final VoidCallback onTap;

  /// Held down: the key starts repeating, until [onHoldEnd].
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final on = toggled ?? false;
    final ink = on
        ? colors.onAccent
        : toggled != null
        ? colors.accentText
        : colors.textPrimary;
    final glyph = icon;
    Widget key = Material(
      color: on ? colors.accent : Colors.transparent,
      shape: StadiumBorder(
        side: locked
            ? BorderSide(color: colors.onAccent, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: SshTerminalDock.keyHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x1),
            child: Center(
              child: glyph != null
                  ? Icon(glyph, size: HermesIcon.lg, color: ink)
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        cap,
                        maxLines: 1,
                        // herdr's lowercase mono labels, in the bundled mono
                        // (audit T5). A modifier (ctrl, alt) reads in the
                        // accent even when off (v2-A `.mod`); locked, it is
                        // also underlined.
                        style: HermesType.text.copyWith(
                          fontFamily: HermesType.monoFamily,
                          fontWeight: FontWeight.w500,
                          color: ink,
                          decoration: locked
                              ? TextDecoration.underline
                              : TextDecoration.none,
                          decorationColor: ink,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    final holdStart = onHoldStart;
    if (holdStart != null) {
      key = _RepeatHoldDetector(
        onHoldStart: holdStart,
        onHoldEnd: onHoldEnd ?? () {},
        child: key,
      );
    }
    // The label replaces the children's semantics, so the tap is here too.
    return Semantics(
      button: true,
      toggled: toggled,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: key,
    );
  }
}
