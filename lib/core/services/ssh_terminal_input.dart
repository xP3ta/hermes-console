// What the SSH terminal sends besides plain typing (1.4.3): the sticky Ctrl
// and Alt of the key row and the one way text is pasted into the shell.
// Nothing here logs what is typed or pasted: a terminal carries secrets.
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'ssh_session_service.dart' show sshCtrlChord;

/// One modifier of the key row (Ctrl or Alt). A tap arms it for the next
/// key only; a second tap within a double tap locks it, and it stays on
/// until it is tapped again; tapped again later, an armed modifier is
/// released.
class SshStickyModifier {
  SshStickyModifier(this.armed) {
    armed.addListener(_released);
  }

  /// On for the next key (for every key while [locked]).
  final ValueNotifier<bool> armed;

  /// Kept on after each key: it was double tapped.
  final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  /// When the modifier was armed by a tap; a second tap before
  /// [kDoubleTapTimeout] has passed locks it.
  DateTime? _armedAt;

  void _released() {
    if (armed.value) return;
    locked.value = false;
    _armedAt = null;
  }

  /// The key of the row was tapped.
  void tap() {
    if (locked.value) {
      armed.value = false;
      return;
    }
    final now = clock.now();
    if (!armed.value) {
      armed.value = true;
      _armedAt = now;
      return;
    }
    final at = _armedAt;
    if (at != null && now.difference(at) <= kDoubleTapTimeout) {
      _armedAt = null;
      locked.value = true;
      return;
    }
    armed.value = false;
  }

  /// Whether the modifier applies to the key being sent. A one-shot
  /// modifier is used up by it.
  bool take() {
    if (!armed.value) return false;
    if (!locked.value) armed.value = false;
    return true;
  }

  void dispose() {
    armed.removeListener(_released);
    locked.dispose();
  }
}

/// The Ctrl and Alt of the key row, applied to what the user types.
class SshKeyModifiers {
  SshKeyModifiers({ValueNotifier<bool>? ctrlArmed})
    : ctrl = SshStickyModifier(ctrlArmed ?? ValueNotifier<bool>(false)),
      alt = SshStickyModifier(ValueNotifier<bool>(false));

  final SshStickyModifier ctrl;
  final SshStickyModifier alt;

  /// Set while text that must go as it is (a paste, a key that applied
  /// the modifiers itself) is sent.
  bool _bypass = false;

  /// Applies the armed modifiers, if any, to user input. Only a single
  /// character takes (and uses up) them: xterm also sends its own replies
  /// through the same output (cursor and focus reports, mouse, bracketed
  /// paste), and Herdr/tmux ask for them often.
  String apply(String data) {
    if (_bypass || data.length != 1) return data;
    if (!ctrl.armed.value && !alt.armed.value) return data;
    var out = data;
    if (ctrl.take()) out = sshCtrlChord(out);
    if (alt.take()) out = '\x1b$out';
    return out;
  }

  /// Runs [send] with the modifiers left alone: what it writes reaches the
  /// shell as it is.
  void unmodified(VoidCallback send) {
    final outer = _bypass;
    _bypass = true;
    try {
      send();
    } finally {
      _bypass = outer;
    }
  }

  void dispose() {
    ctrl.dispose();
    alt.dispose();
    alt.armed.dispose();
  }
}

const Map<TerminalKey, String> _arrowCodes = {
  TerminalKey.arrowUp: 'A',
  TerminalKey.arrowDown: 'B',
  TerminalKey.arrowRight: 'C',
  TerminalKey.arrowLeft: 'D',
};

/// Sends [key] with any armed sticky [modifiers] combined with physical
/// [shift], [ctrl], and [alt]. Modified arrows emit standard XTerm PC-style
/// CSI sequences (`CSI 1 ; Ps A/B/C/D`), keeping Alt distinct from Ctrl.
void sshSendModifiedKey(
  Terminal terminal,
  SshKeyModifiers modifiers,
  TerminalKey key, {
  bool shift = false,
  bool ctrl = false,
  bool alt = false,
}) {
  final useCtrl = modifiers.ctrl.take() || ctrl;
  final useAlt = modifiers.alt.take() || alt;
  final arrow = _arrowCodes[key];
  modifiers.unmodified(() {
    if (arrow != null && (shift || useAlt || useCtrl)) {
      final param = 1 + (shift ? 1 : 0) + (useAlt ? 2 : 0) + (useCtrl ? 4 : 0);
      terminal.textInput('\x1b[1;$param$arrow');
      return;
    }
    if (terminal.keyInput(key, shift: shift, ctrl: useCtrl, alt: useAlt)) {
      return;
    }
    if (useAlt) terminal.textInput('\x1b');
    terminal.keyInput(key, shift: shift);
  });
}

/// Maps physical navigation keys that consume sticky modifiers on a hardware
/// keyboard.
TerminalKey? sshTerminalKeyForLogical(LogicalKeyboardKey key) => switch (key) {
  LogicalKeyboardKey.arrowUp => TerminalKey.arrowUp,
  LogicalKeyboardKey.arrowDown => TerminalKey.arrowDown,
  LogicalKeyboardKey.arrowLeft => TerminalKey.arrowLeft,
  LogicalKeyboardKey.arrowRight => TerminalKey.arrowRight,
  LogicalKeyboardKey.home => TerminalKey.home,
  LogicalKeyboardKey.end => TerminalKey.end,
  LogicalKeyboardKey.pageUp => TerminalKey.pageUp,
  LogicalKeyboardKey.pageDown => TerminalKey.pageDown,
  _ => null,
};

final RegExp _bracketPasteMarker = RegExp(r'(?:\x1b\[|\x9b)20[01]~');
final RegExp _disallowedPasteControls = RegExp(
  r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]',
);

/// Removes bracketed-paste markers (including nested or overlapping forms and
/// 8-bit CSI) and control bytes other than tab, LF, and CR so pasted data
/// cannot be confused with terminal control functions.
String sshSanitizePaste(String text) {
  var clean = text;
  while (true) {
    final next = clean.replaceAll(_bracketPasteMarker, '');
    if (next == clean) break;
    clean = next;
  }
  return clean.replaceAll(_disallowedPasteControls, '');
}

/// Sanitizes bracketed-paste frames emitted directly by the terminal view
/// before they reach the SSH channel.
String sshSanitizeTerminalOutput(String data) {
  const open = '\x1b[200~';
  const close = '\x1b[201~';
  if (!data.startsWith(open)) return data;
  final withEnter = data.endsWith('$close\r');
  final end = withEnter
      ? data.length - close.length - 1
      : data.endsWith(close)
      ? data.length - close.length
      : -1;
  if (end < open.length) return data;
  final inner = sshSanitizePaste(data.substring(open.length, end));
  if (inner.isEmpty) return withEnter ? '\r' : '';
  return withEnter ? '$open$inner$close\r' : '$open$inner$close';
}

/// Pastes [text] into the shell the way a desktop terminal does: one
/// bracketed paste when the program asked for it (DECSET 2004), plain text
/// otherwise, never touched by an armed Ctrl or Alt. Bracket markers and
/// control bytes other than tab, LF, and CR are stripped from [text].
void sshPasteText(
  Terminal terminal,
  String text, {
  SshKeyModifiers? modifiers,
}) {
  final clean = sshSanitizePaste(text);
  if (clean.isEmpty) return;
  void send() => terminal.paste(clean);
  if (modifiers == null) {
    send();
  } else {
    modifiers.unmodified(send);
  }
}

/// What Compose writes for [text] in one go: the paste as [sshPasteText]
/// makes it (bracketed when the program asked for it, markers and unsafe
/// control bytes stripped), then Enter when [enter].
String sshPastePayload(Terminal terminal, String text, {bool enter = false}) {
  final clean = sshSanitizePaste(text);
  if (clean.isEmpty) return enter ? '\r' : '';
  final body = terminal.bracketedPasteMode ? '\x1b[200~$clean\x1b[201~' : clean;
  return enter ? '$body\r' : body;
}

/// Pastes the clipboard's text into the shell ([sshPasteText]). Returns
/// whether there was text to paste.
Future<bool> sshPasteClipboard(
  Terminal terminal, {
  SshKeyModifiers? modifiers,
}) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  if (text == null || text.isEmpty) return false;
  sshPasteText(terminal, text, modifiers: modifiers);
  return true;
}

/// The mouse wheel report a program that turned mouse reporting on
/// (DECSET 1000, 1002 or 1003) reads, or null when it did not or when the
/// cell coordinate cannot be represented in the active legacy mode.
///
/// Per XTerm Control Sequences (Mouse Tracking): wheel up is button 64 and
/// wheel down 65, 1-based screen coordinates. SGR (1006) and urxvt (1015)
/// encode unbounded decimal coordinates. In normal mode, `Terminal.onOutput`
/// encodes strings as UTF-8, so only coordinates up to 95 (code point <= 127)
/// remain single-byte; in UTF-8 mode (1005), coordinates up to 2015
/// (code point <= 2047) are representable. Out-of-range legacy coordinates
/// return null rather than clamping to a wrong column or row.
String? sshWheelReport(
  Terminal terminal, {
  required bool up,
  required CellOffset cell,
}) {
  if (!terminal.mouseMode.reportScroll) return null;
  final button = up ? 64 : 65;
  final x = math.max(cell.x + 1, 1);
  final y = math.max(cell.y - terminal.buffer.scrollBack + 1, 1);
  String? legacy(int limit) {
    if (x > limit || y > limit) return null;
    return '\x1b[M${String.fromCharCodes([32 + button, 32 + x, 32 + y])}';
  }

  return switch (terminal.mouseReportMode) {
    MouseReportMode.sgr => '\x1b[<$button;$x;${y}M',
    MouseReportMode.urxvt => '\x1b[${32 + button};$x;${y}M',
    MouseReportMode.normal => legacy(95),
    MouseReportMode.utf => legacy(2015),
  };
}

/// What breaks a word for a long press or a double tap in the terminal:
/// blanks, quotes and brackets. Unlike xterm's default, `/ . : -` keep a
/// path, an address or a flag in one piece.
final Set<int> sshTerminalWordSeparators = {
  0,
  ...' \t"\'`()[]{}<>|;,'.codeUnits,
};
