// Controles de la pantalla del terminal SSH (1.4.0, F1): botón para agrandar
// el terminal y fila de teclas auxiliares con scroll horizontal (con un
// degradado en el borde que tiene más teclas detrás). Nada de Herdr aquí.
// Colores del tema; nada de hex en bruto.
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../feedback/haptics.dart';
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
                      expanded ? Icons.close_fullscreen : Icons.open_in_full,
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
  escape,
  tab,
  ctrl,
  interrupt,
  endOfInput,
  up,
  down,
  left,
  right,
  text,
}

class _KeySpec {
  const _KeySpec(this.cap, this.action, [this.text]);

  /// Printed keycap. Key names, not copy: they are not translated.
  final String cap;
  final _KeyAction action;
  final String? text;
}

/// The keys of mock 136 v2-A (Cadu's set), in its order: esc tab ctrl ^C
/// ^D ← ↓ ↑ → | ~. The phone keyboard has `/`; it has neither `|` nor `~`
/// within reach.
const List<_KeySpec> _keys = [
  _KeySpec('esc', _KeyAction.escape),
  _KeySpec('tab', _KeyAction.tab),
  _KeySpec('ctrl', _KeyAction.ctrl),
  _KeySpec('^C', _KeyAction.interrupt),
  _KeySpec('^D', _KeyAction.endOfInput),
  _KeySpec('←', _KeyAction.left),
  _KeySpec('↓', _KeyAction.down),
  _KeySpec('↑', _KeyAction.up),
  _KeySpec('→', _KeyAction.right),
  _KeySpec('|', _KeyAction.text, '|'),
  _KeySpec('~', _KeyAction.text, '~'),
];

/// The printed caps of the key bar, in order (tests and TalkBack checks).
@visibleForTesting
List<String> get sshTerminalKeyCaps => [for (final key in _keys) key.cap];

/// Row of keys a phone keyboard lacks. It scrolls sideways when it does not
/// fit. `ctrl` is one-shot: it applies to the next key and clears itself.
class SshTerminalKeyBar extends StatelessWidget {
  const SshTerminalKeyBar({
    required this.terminal,
    required this.ctrlArmed,
    this.dense = false,
    this.pill = false,
    super.key,
  });

  final Terminal terminal;
  final ValueNotifier<bool> ctrlArmed;

  /// One thin row, the keys at their 48 dp and nothing around them: with
  /// the keyboard up in the workspace pane, where every line counts.
  final bool dense;

  /// Mock 136 v2-A (Cadu's look): the keys are plain caps in one rounded
  /// pill under the terminal's card, not a band of chips. Same height and
  /// the same 48 dp keys.
  final bool pill;

  /// 48 dp keys (the touch target the rest of the app uses) plus 4 dp
  /// above and below.
  static const double height = 56;

  /// [dense]: the keys alone.
  static const double denseHeight = 48;

  /// [pill]: one 48 dp pill, the keys filling its height (Ola 6).
  static const double pillHeight = HermesSize.tap;

  void _press(_KeySpec key) {
    // Ola 7: each key answers under the finger, as Cadu's do.
    HermesHaptics.selection();
    switch (key.action) {
      case _KeyAction.escape:
        terminal.keyInput(TerminalKey.escape);
      case _KeyAction.tab:
        terminal.keyInput(TerminalKey.tab);
      case _KeyAction.ctrl:
        ctrlArmed.value = !ctrlArmed.value;
      case _KeyAction.interrupt:
        terminal.textInput('\x03');
      case _KeyAction.endOfInput:
        terminal.textInput('\x04');
      case _KeyAction.up:
        terminal.keyInput(TerminalKey.arrowUp);
      case _KeyAction.down:
        terminal.keyInput(TerminalKey.arrowDown);
      case _KeyAction.left:
        terminal.keyInput(TerminalKey.arrowLeft);
      case _KeyAction.right:
        terminal.keyInput(TerminalKey.arrowRight);
      case _KeyAction.text:
        terminal.textInput(key.text!);
    }
  }

  /// What a screen reader says for a symbol key; the named keys (esc, tab,
  /// ctrl) read their own cap.
  String? _semanticLabel(Strings strings, _KeySpec key) => switch (key.action) {
    _KeyAction.interrupt => strings.sshKeyInterrupt,
    _KeyAction.endOfInput => strings.sshKeyEndOfInput,
    _KeyAction.up => strings.sshKeyArrowUp,
    _KeyAction.down => strings.sshKeyArrowDown,
    _KeyAction.left => strings.sshKeyArrowLeft,
    _KeyAction.right => strings.sshKeyArrowRight,
    _KeyAction.text when key.text == '|' => strings.sshKeyPipe,
    _KeyAction.text when key.text == '~' => strings.sshKeyTilde,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    // Mock 136 v2-A `.keybar`: floating chrome (one step lighter than the
    // page), its hairline and its soft shadow.
    final chrome = HermesChrome.of(colors);
    // Keycaps are symbols: past 1.3x they would only push the row taller
    // than the bar without being easier to read.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        key: pill ? const ValueKey('ssh-key-bar-pill') : null,
        height: dense
            ? denseHeight
            : pill
            ? pillHeight
            : height,
        color: pill ? null : colors.surface,
        clipBehavior: pill ? Clip.antiAlias : Clip.none,
        decoration: pill
            ? ShapeDecoration(
                color: chrome.opaque,
                shape: const StadiumBorder(),
                shadows: chrome.shadow,
              )
            : null,
        // The hairline is painted over the row, not as decoration: a
        // decoration border adds its width as padding and the keys would
        // lose 1 dp of their 48.
        foregroundDecoration: pill
            ? ShapeDecoration(
                shape: StadiumBorder(side: BorderSide(color: chrome.line)),
              )
            : BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: colors.divider.withValues(alpha: 0.55),
                  ),
                ),
              ),
        child: _EdgeFade(
          color: pill ? chrome.opaque : colors.surface,
          child: ValueListenableBuilder<bool>(
            valueListenable: ctrlArmed,
            builder: (context, armed, _) => ListView.separated(
              key: const ValueKey('ssh-key-bar'),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: 8,
                vertical: dense || pill ? 0 : 4,
              ),
              itemCount: _keys.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final key = _keys[i];
                final isCtrl = key.action == _KeyAction.ctrl;
                return _Keycap(
                  key: ValueKey('ssh-key-${key.cap}'),
                  cap: key.cap,
                  semanticLabel: _semanticLabel(strings, key),
                  toggled: isCtrl ? armed : null,
                  colors: colors,
                  flat: pill,
                  onTap: () => _press(key),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades the edge of the key row that has more keys behind it, so a key cut
/// at the pill's edge reads as «scroll», not as the end of the row. Fades
/// only where there is more to see: nothing when every key fits.
class _EdgeFade extends StatefulWidget {
  const _EdgeFade({required this.color, required this.child});

  /// The surface under the row (the pill or the band).
  final Color color;
  final Widget child;

  @override
  State<_EdgeFade> createState() => _EdgeFadeState();
}

class _EdgeFadeState extends State<_EdgeFade> {
  bool _before = false;
  bool _after = false;

  bool _track(ScrollMetrics metrics) {
    final before = metrics.extentBefore > 1;
    final after = metrics.extentAfter > 1;
    if (before != _before || after != _after) {
      setState(() {
        _before = before;
        _after = after;
      });
    }
    return false;
  }

  Widget _fade(AlignmentGeometry from, AlignmentGeometry to, Key key) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: from,
          child: FractionallySizedBox(
            widthFactor: 0.12,
            heightFactor: 1,
            child: DecoratedBox(
              key: key,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: from,
                  end: to,
                  colors: [widget.color, widget.color.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => _track(n.metrics),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) => _track(n.metrics),
            child: widget.child,
          ),
        ),
        if (_before)
          _fade(
            AlignmentDirectional.centerStart,
            AlignmentDirectional.centerEnd,
            const ValueKey('ssh-key-bar-fade-start'),
          ),
        if (_after)
          _fade(
            AlignmentDirectional.centerEnd,
            AlignmentDirectional.centerStart,
            const ValueKey('ssh-key-bar-fade-end'),
          ),
      ],
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
    this.flat = false,
    super.key,
  });

  final String cap;
  final String? semanticLabel;
  final bool? toggled;
  final HermesThemeColors colors;
  final VoidCallback onTap;

  /// In the pill: no chip behind the cap unless it is on.
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final on = toggled ?? false;
    return Semantics(
      button: true,
      toggled: toggled,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      // With the label replacing the children, the tap must be here too.
      onTap: semanticLabel != null ? onTap : null,
      child: Material(
        color: on
            ? colors.accent
            : flat
            ? Colors.transparent
            : colors.surfaceVariant,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                widthFactor: 1,
                child: Text(
                  cap,
                  // The bundled mono (audit T5), 13/500 as v2-A's keys. A
                  // modifier (ctrl) reads in the accent even when off, so
                  // it never looks like a plain key (v2-A `.mod`).
                  style: HermesType.value.copyWith(
                    fontFamily: HermesType.monoFamily,
                    fontWeight: FontWeight.w500,
                    color: on
                        ? colors.onAccent
                        : toggled != null
                        ? colors.accentText
                        : colors.textPrimary,
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
