// What an agent's screen is asking (1.4.0): the reason an agent waits for the
// user (a question with numbered options, an approval, or just «it waits»),
// the numbered options themselves and the one useful line of what the agent
// is doing. Pure text work on the lines `agent read` returns; nothing here
// talks to the server.
//
// Everything is conservative on purpose. Herdr says WHO is blocked; this
// only reads the screen to say what kind of block it is, and shows the
// agent's own lines as they are (cleaned), never a sentence of ours in their
// place. When the screen is not clear the answer is «waiting» and no options.
/// What kind of wait a blocked agent shows.
enum HerdrAskKind {
  /// A choice between numbered options that is not an approval.
  question,

  /// A permission or confirmation (a command, a trust prompt, yes/no).
  approval,

  /// Blocked, but the screen does not say more.
  waiting,
}

/// One numbered option of the screen: `number` is the key to send.
class HerdrOption {
  const HerdrOption(this.number, this.label);

  final int number;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is HerdrOption && other.number == number && other.label == label;

  @override
  int get hashCode => Object.hash(number, label);

  @override
  String toString() => 'HerdrOption($number, $label)';
}

/// The reading of a blocked agent's screen.
class HerdrAsk {
  const HerdrAsk({
    required this.kind,
    required this.options,
    required this.prompt,
    this.command,
  });

  final HerdrAskKind kind;

  /// Numbered options 1..n (n at most 9), empty when none were found.
  final List<HerdrOption> options;

  /// The screen's own lines just above the options (or the last ones when
  /// there are none), top to bottom, cleaned.
  final List<String> prompt;

  /// For an approval: the order or permission line as the screen shows it;
  /// null when the screen did not show one in a recognisable form.
  final String? command;

  bool get hasOptions => options.isNotEmpty;

  /// The question as the screen words it: its last line that asks (ends in
  /// a question mark), else its last line.
  String? get question {
    for (var i = prompt.length - 1; i >= 0; i--) {
      if (prompt[i].endsWith('?') || prompt[i].endsWith('？')) return prompt[i];
    }
    return prompt.isEmpty ? null : prompt.last;
  }

  /// Identity of this ask: the same question with the same options.
  String get signature =>
      '${kind.name}|${options.map((o) => '${o.number}:${o.label}').join('|')}|'
      '${prompt.isEmpty ? '' : prompt.last}';
}

final RegExp _boxEdge = RegExp(r'^[\s│┃║╎┆┊|]+|[\s│┃║╎┆┊|]+$');
final RegExp _decorOnly = RegExp(r'^[\s─━═╭╮╰╯┌┐└┘├┤┬┴┼╌╍┄┅\-_=~*·.]*$');
final RegExp _controls = RegExp(r'[\x00-\x1F\x7F]');
final RegExp _spaces = RegExp(r'\s+');

/// One screen line for reading: control characters and the frame an agent
/// draws around its dialogs gone, blanks collapsed; a line of only frame or
/// rule characters becomes empty.
String herdrScreenLine(String raw) {
  final s = raw
      .replaceAll(_controls, ' ')
      .replaceAll(_boxEdge, '')
      .replaceAll(_spaces, ' ')
      .trim();
  return _decorOnly.hasMatch(s) ? '' : s;
}

/// `1.` / `1)` / `1 -` at the start of a line, after an optional pointer.
final RegExp _optionLine = RegExp(
  r'^(?:[❯›>▶➤➜*•●○◉]\s*)?([1-9])(?:[.)]|\s-)\s+(\S.*)$',
);

const int _optionWindow = 18;
const int _optionFooterMax = 3;
const int _optionLabelMax = 100;

class _Block {
  const _Block(this.options, this.firstIndex);

  final List<HerdrOption> options;
  final int firstIndex;
}

/// The numbered options at the foot of the screen: a contiguous run 1..n
/// (2 <= n <= 9) in the last lines, short labels, at most three hint lines
/// after it. A numbered list inside long text, one that does not start at 1,
/// or one far from the end of the screen is not an ask.
_Block? _findOptions(List<String> lines) {
  var end = lines.length;
  while (end > 0 && lines[end - 1].isEmpty) {
    end--;
  }
  if (end == 0) return null;
  final start = end > _optionWindow ? end - _optionWindow : 0;
  var footer = 0;
  int? lastIndex;
  for (var i = end - 1; i >= start; i--) {
    final line = lines[i];
    if (line.isEmpty) continue;
    if (_optionLine.hasMatch(line)) {
      lastIndex = i;
      break;
    }
    footer++;
    if (footer > _optionFooterMax || line.length > 120) return null;
  }
  if (lastIndex == null) return null;
  final found = <HerdrOption>[];
  var pending = 0;
  var firstIndex = lastIndex;
  for (var i = lastIndex; i >= start; i--) {
    final line = lines[i];
    if (line.isEmpty) continue;
    final match = _optionLine.firstMatch(line);
    if (match == null) {
      // One line of description between two options is fine; more is text.
      pending++;
      if (pending > 1 || line.length > _optionLabelMax) return null;
      continue;
    }
    pending = 0;
    final number = int.parse(match.group(1)!);
    final label = match.group(2)!.trim();
    if (label.length > _optionLabelMax) return null;
    if (found.isNotEmpty && number != found.last.number - 1) return null;
    found.add(HerdrOption(number, label));
    firstIndex = i;
    if (number == 1) break;
  }
  if (found.length < 2 || found.last.number != 1) return null;
  return _Block(found.reversed.toList(), firstIndex);
}

/// The numbered options of [screen] (the lines of `agent read`), or an empty
/// list when the foot of the screen does not hold a clear 1..n choice.
List<HerdrOption> herdrNumberedOptions(List<String> screen) {
  final lines = [for (final line in screen) herdrScreenLine(line)];
  return _findOptions(lines)?.options ?? const [];
}

final RegExp _approvalWords = RegExp(
  r'permission|permiso|approve|approval|aprobar|aprobaci|aprueb|\ballow\b|'
  r'permitir|\btrust\b|\bconfiar\b|\bproceed\b|y/n|yes/no|sí/no|si/no',
);
final RegExp _yesLabel = RegExp(r'^(yes|sí|si|y)\b');
final RegExp _noLabel = RegExp(r'^(no|n)\b');
final RegExp _commandHeader = RegExp(
  r'^(bash|shell|command|bash command|run command|shell command)$',
  caseSensitive: false,
);
final RegExp _backticked = RegExp(r'`([^`]{2,200})`');

String _cap(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

String? _commandOf(List<String> prompt) {
  for (final line in prompt) {
    if (line.startsWith(r'$ ') && line.length > 2) {
      return _cap(line.substring(2).trim(), 200);
    }
  }
  for (var i = 0; i + 1 < prompt.length; i++) {
    if (_commandHeader.hasMatch(prompt[i])) return _cap(prompt[i + 1], 200);
  }
  for (final line in prompt) {
    final match = _backticked.firstMatch(line);
    if (match != null) return _cap(match.group(1)!.trim(), 200);
  }
  return null;
}

/// Reads what a blocked agent's [screen] asks. Only call it for an agent
/// Herdr reports as blocked: the same numbered text in an agent that works
/// is just its answer.
///
/// Approval wins over question: a permission prompt is usually a numbered
/// «1. Yes / 2. No», and it is the permission words (or the yes/no pair) that
/// tell it from a real choice. The options are kept either way, so they can
/// be answered with their number.
HerdrAsk herdrReadAsk(List<String> screen) {
  final lines = [for (final line in screen) herdrScreenLine(line)];
  final block = _findOptions(lines);
  final options = block?.options ?? const <HerdrOption>[];
  final List<String> prompt;
  if (block != null) {
    final above = <String>[];
    for (var i = block.firstIndex - 1; i >= 0 && above.length < 5; i--) {
      if (lines[i].isNotEmpty) above.add(_cap(lines[i], 200));
    }
    prompt = above.reversed.toList();
  } else {
    final tail = <String>[];
    for (var i = lines.length - 1; i >= 0 && tail.length < 6; i--) {
      if (lines[i].isNotEmpty) tail.add(_cap(lines[i], 200));
    }
    prompt = tail.reversed.toList();
  }
  final head = prompt.join(' ').toLowerCase();
  final labels = [for (final o in options) o.label.toLowerCase()];
  final yesNo =
      labels.length >= 2 &&
      labels.any(_yesLabel.hasMatch) &&
      labels.any(_noLabel.hasMatch);
  final approval = yesNo || _approvalWords.hasMatch(head);
  final kind = approval
      ? HerdrAskKind.approval
      : options.isNotEmpty
      ? HerdrAskKind.question
      : HerdrAskKind.waiting;
  return HerdrAsk(
    kind: kind,
    options: options,
    prompt: prompt,
    command: kind == HerdrAskKind.approval ? _commandOf(prompt) : null,
  );
}

final RegExp _hasLetter = RegExp(r'\p{L}', unicode: true);
final RegExp _leadingMarks = RegExp(r'^[●⏺✓✔✻✳✶·*•>$»›❯\-–—⎿│\s]+');
final RegExp _hintTail = RegExp(
  r'\s*[(\[][^)\]]*(esc|ctrl|token|interrupt|shift\+tab)[^)\]]*[)\]]',
  caseSensitive: false,
);
final RegExp _noiseLine = RegExp(
  r'(for shortcuts|shift\+tab|ctrl\+[a-z]|press enter|bypass permissions|'
  r'auto-accept|\bcontext (left|window)\b|^esc to|^\? )',
  caseSensitive: false,
);

/// One line, readable, for a row's subtitle: what the agent asks (when
/// [ask] is given) or the most recent useful line of its screen. Sanitised
/// (no frame, no leading bullet, no key hints, one space between words) and
/// at most [max] characters; null when the screen has nothing to say.
String? herdrActivityLine(List<String> screen, {HerdrAsk? ask, int max = 140}) {
  if (ask != null) {
    final said = ask.command ?? ask.question;
    if (said != null && said.isNotEmpty) return _cap(said, max);
  }
  var looked = 0;
  for (var i = screen.length - 1; i >= 0 && looked < 30; i--) {
    var line = herdrScreenLine(screen[i]);
    if (line.isEmpty) continue;
    looked++;
    line = line.replaceAll(_hintTail, '').replaceFirst(_leadingMarks, '');
    line = line.replaceAll(_spaces, ' ').trim();
    if (line.length < 3 || !_hasLetter.hasMatch(line)) continue;
    if (_noiseLine.hasMatch(line)) continue;
    return _cap(line, max);
  }
  return null;
}

const Map<String, String> _plainGlyphs = {
  '⏵': '>',
  '⏴': '<',
  '⏶': '^',
  '⏷': 'v',
  '⏸': '||',
  '⏺': '●',
  '⎿': '↳',
};
final RegExp _edgeBar = RegExp(r'^\s*[│┃║╎┆┊|]\s?|\s?[│┃║╎┆┊|]\s*$');

/// A terminal screen as text to read: control characters gone, the frame
/// and the rules an agent draws removed (their lines drop out), the few
/// symbols the monospaced font lacks written in plain characters, blank
/// runs collapsed to one blank line. Indentation inside the text stays.
List<String> herdrReadableLines(List<String> screen) {
  final out = <String>[];
  for (final raw in screen) {
    var line = raw.replaceAll(_controls, ' ');
    _plainGlyphs.forEach((glyph, plain) {
      line = line.replaceAll(glyph, plain);
    });
    line = line.replaceAll(_edgeBar, '').trimRight();
    if (_decorOnly.hasMatch(line)) line = '';
    if (line.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}
