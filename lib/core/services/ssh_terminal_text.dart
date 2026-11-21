// Reading the SSH terminal's text (1.4.3): what a selection copies, the
// address under a finger and the question the shell is waiting on. Reads
// the buffer only; nothing is logged or kept.
import 'package:xterm/xterm.dart';

/// The text of [range] in [terminal]'s buffer as it is copied: soft-wrapped
/// rows joined, each line without the blanks the screen pads it with.
String sshTerminalText(Terminal terminal, BufferRange range) {
  final text = terminal.buffer.getText(range);
  return text.replaceAll(_trailingBlanks, '');
}

final RegExp _trailingBlanks = RegExp(r'[ \t]+$', multiLine: true);

/// The screen (the last rows, what a program draws on), as copied, without
/// the blank rows under the last line with text.
String sshTerminalScreenText(Terminal terminal) {
  final buffer = terminal.buffer;
  final top = buffer.height - terminal.viewHeight;
  final text = sshTerminalText(
    terminal,
    BufferRangeLine(
      CellOffset(0, top < 0 ? 0 : top),
      CellOffset(terminal.viewWidth, buffer.height - 1),
    ),
  );
  return text.replaceFirst(RegExp(r'\n+$'), '');
}

/// The whole buffer, scrollback included, as a selection range.
BufferRangeLine sshTerminalAllRange(Terminal terminal) => BufferRangeLine(
  const CellOffset(0, 0),
  CellOffset(terminal.viewWidth, terminal.buffer.height - 1),
);

/// One logical line of the buffer (its soft-wrapped rows joined) and, for
/// each UTF-16 unit of [text], the row and column of its cell.
class _LogicalLine {
  _LogicalLine(this.text, this.cells);

  final String text;
  final List<CellOffset> cells;
}

_LogicalLine _logicalLine(Buffer buffer, int row) {
  final lines = buffer.lines;
  var first = row;
  while (first > 0 && lines[first].isWrapped) {
    first--;
  }
  var last = row;
  while (last + 1 < lines.length && lines[last + 1].isWrapped) {
    last++;
  }
  final text = StringBuffer();
  final cells = <CellOffset>[];
  for (var y = first; y <= last; y++) {
    final line = lines[y];
    final width = line.length < buffer.viewWidth
        ? line.length
        : buffer.viewWidth;
    for (var x = 0; x < width; x++) {
      final code = line.getCodePoint(x);
      if (code == 0) continue;
      final char = String.fromCharCode(code);
      text.write(char);
      for (var unit = 0; unit < char.length; unit++) {
        cells.add(CellOffset(x, y));
      }
    }
  }
  return _LogicalLine(text.toString(), cells);
}

/// A web address as it appears in a terminal: scheme, then anything up to
/// a blank, a quote or an angle bracket.
final RegExp _webAddress = RegExp(r'''https?://[^\s<>"'`]+''');

/// Punctuation that ends a sentence rather than the address.
final RegExp _trailingPunctuation = RegExp(r'''[.,;:!?'"]+$''');

/// The http(s) address written at [cell] of [terminal]'s buffer, wrapped
/// rows included, or null. A closing bracket with no opening one inside the
/// address and the punctuation after it are not part of it.
Uri? sshTerminalLinkAt(Terminal terminal, CellOffset cell) {
  final buffer = terminal.buffer;
  if (cell.y < 0 || cell.y >= buffer.height) return null;
  final line = _logicalLine(buffer, cell.y);
  for (final match in _webAddress.allMatches(line.text)) {
    var address = match.group(0)!;
    while (true) {
      final trimmed = address.replaceFirst(_trailingPunctuation, '');
      final unbalanced = _unbalancedClose(trimmed);
      final next = unbalanced
          ? trimmed.substring(0, trimmed.length - 1)
          : trimmed;
      if (next == address) break;
      address = next;
    }
    final start = match.start;
    final end = start + address.length;
    var hit = false;
    for (var i = start; i < end && i < line.cells.length; i++) {
      if (line.cells[i] == cell) {
        hit = true;
        break;
      }
    }
    if (!hit) continue;
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) return null;
    return uri;
  }
  return null;
}

bool _unbalancedClose(String address) {
  if (address.isEmpty) return false;
  const pairs = {')': '(', ']': '[', '}': '{'};
  final open = pairs[address[address.length - 1]];
  if (open == null) return false;
  final close = address[address.length - 1];
  final opened = open.allMatches(address).length;
  final closed = close.allMatches(address).length;
  return closed > opened;
}

/// One answer offered for a question the shell is waiting on: the chip's
/// [label] and what a tap on it types.
class SshPromptAnswer {
  const SshPromptAnswer(this.label, this.input);

  final String label;
  final String input;

  @override
  bool operator ==(Object other) =>
      other is SshPromptAnswer && other.label == label && other.input == input;

  @override
  int get hashCode => Object.hash(label, input);

  @override
  String toString() => 'SshPromptAnswer($label)';
}

/// What a chip of a prompt types: the answer itself (`y`, `yes`, `2`),
/// Enter or Ctrl+C. Each chip sends only its own key; nothing is sent
/// unless it is tapped.
const SshPromptAnswer sshPromptEnter = SshPromptAnswer('⏎', '\r');
const SshPromptAnswer sshPromptInterrupt = SshPromptAnswer('^C', '\x03');

final RegExp _yesNo = RegExp(r'[\[(]\s*[yY]\s*/\s*[nN]\s*[\])]\s*[:?]?$');
final RegExp _yesNoWords = RegExp(
  r'(?:\(\s*yes\s*/\s*no\b[^)]*\)|\[\s*yes\s*/\s*no\b[^\]]*\])\s*[:?]?$',
  caseSensitive: false,
);
final RegExp _pressEnter = RegExp(
  r'press\s+(?:\[?enter\]?|\[?return\]?|any\s+key)'
  r'(?:\s+to\s+[\w\s]+)?[.…:!\s]*$',
  caseSensitive: false,
);
final RegExp _choiceAsk = RegExp(r'(?:[:?>]|#\?)$');
final RegExp _choiceItem = RegExp(r'^\s*\[?(\d)[).:\]]\s+\S');

/// The answers for the question in [prompt], the text of the row the cursor
/// waits on (up to the cursor, nothing after it), or null when it is not a
/// question. [above] are the rows printed before it, the nearest last: a
/// numbered choice (`1) …`, `2) …` then `#?` or `Choice:`) is read from
/// them.
List<SshPromptAnswer>? sshPromptAnswers(
  String prompt, {
  List<String> above = const [],
}) {
  final line = prompt.trimRight();
  if (line.isEmpty) return null;
  if (_yesNoWords.hasMatch(line)) {
    return const [
      SshPromptAnswer('yes', 'yes'),
      SshPromptAnswer('no', 'no'),
      sshPromptEnter,
      sshPromptInterrupt,
    ];
  }
  if (_yesNo.hasMatch(line)) {
    return const [
      SshPromptAnswer('y', 'y'),
      SshPromptAnswer('n', 'n'),
      sshPromptEnter,
      sshPromptInterrupt,
    ];
  }
  if (_pressEnter.hasMatch(line)) {
    return const [sshPromptEnter, sshPromptInterrupt];
  }
  if (_choiceAsk.hasMatch(line)) {
    final count = _choiceCount(above);
    if (count != null) {
      return [
        for (var i = 1; i <= count; i++) SshPromptAnswer('$i', '$i'),
        sshPromptEnter,
        sshPromptInterrupt,
      ];
    }
  }
  return null;
}

/// How many numbered options (1 to 9, in order) end right above the
/// question; at most one row (a hint, a blank) may sit between them.
int? _choiceCount(List<String> above) {
  var index = above.length - 1;
  if (index >= 0 && !_choiceItem.hasMatch(above[index])) index--;
  final numbers = <int>[];
  while (index >= 0) {
    final match = _choiceItem.firstMatch(above[index]);
    if (match == null) break;
    numbers.insert(0, int.parse(match.group(1)!));
    index--;
  }
  if (numbers.length < 2) return null;
  for (var i = 0; i < numbers.length; i++) {
    if (numbers[i] != i + 1) return null;
  }
  return numbers.length;
}

/// How many rows above the prompt are read for numbered options.
const int _rowsAbovePrompt = 10;

/// The answers for what [terminal] is waiting on, read from the row of its
/// cursor in the main screen (a full-screen program draws its own
/// questions), or null. Text after the cursor means it is not waiting at
/// the end of a question.
List<SshPromptAnswer>? sshTerminalPrompt(Terminal terminal) {
  if (terminal.isUsingAltBuffer) return null;
  final buffer = terminal.buffer;
  final row = buffer.absoluteCursorY;
  if (row < 0 || row >= buffer.height) return null;
  final line = buffer.lines[row];
  final after = line.getText(buffer.cursorX).trim();
  if (after.isNotEmpty) return null;
  final prompt = _logicalLine(buffer, row);
  var first = row;
  while (first > 0 && buffer.lines[first].isWrapped) {
    first--;
  }
  final above = <String>[];
  var y = first - 1;
  while (y >= 0 && above.length < _rowsAbovePrompt) {
    final logical = _logicalLine(buffer, y);
    above.insert(0, logical.text);
    var start = y;
    while (start > 0 && buffer.lines[start].isWrapped) {
      start--;
    }
    y = start - 1;
  }
  return sshPromptAnswers(prompt.text, above: above);
}
