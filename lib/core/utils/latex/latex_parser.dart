/// Parser of the TeX subset that Console paints natively.
///
/// Pure and conservative: anything it does not understand (an unknown command,
/// an unbalanced brace, a missing argument, a double script) throws
/// [LatexParseException], and [tryParseLatex] turns that into `null` so the
/// caller keeps showing the source text.
library;

import 'latex_ast.dart';
import 'latex_symbols.dart';

/// Longest source the parser accepts (characters).
const int kLatexMaxLength = 4000;

/// Deepest group/command nesting the parser accepts.
const int kLatexMaxDepth = 24;

/// Most nodes a formula may create.
const int kLatexMaxNodes = 3000;

/// Most cells a matrix or aligned block may have.
const int kLatexMaxCells = 400;

class LatexParseException implements Exception {
  const LatexParseException(this.message, this.offset);

  final String message;
  final int offset;

  @override
  String toString() => 'LatexParseException($message at $offset)';
}

const int _cacheLimit = 128;

final Map<String, LatexNode?> _cache = <String, LatexNode?>{};

/// Parses [source], or returns `null` when it is not valid or supported TeX.
/// Memoised (LRU): a rebuild or a stable streaming block never parses twice.
LatexNode? tryParseLatex(String source) {
  if (_cache.containsKey(source)) {
    final hit = _cache.remove(source);
    _cache[source] = hit;
    return hit;
  }
  LatexNode? result;
  try {
    result = parseLatex(source);
  } on LatexParseException {
    result = null;
  }
  _cache[source] = result;
  if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
  return result;
}

/// Parses [source]; throws [LatexParseException] when it cannot.
LatexNode parseLatex(String source) {
  if (source.length > kLatexMaxLength) {
    throw const LatexParseException('too long', 0);
  }
  final parser = _Parser(source);
  final root = parser.parseDocument();
  if (root is LatexRow && root.children.isEmpty) {
    throw const LatexParseException('empty', 0);
  }
  return root;
}

enum _End { eof, brace, bracket, amp, rowSep, end, right }

bool _isLetter(int u) => (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);

bool _isDigit(int u) => u >= 0x30 && u <= 0x39;

bool _isSpaceUnit(int u) => u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D;

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;
  int depth = 0;
  int nodes = 0;

  Never _fail(String message) => throw LatexParseException(message, i);

  T _count<T extends LatexNode>(T node) {
    if (++nodes > kLatexMaxNodes) _fail('too many nodes');
    return node;
  }

  void _skipSpaces() {
    while (i < s.length && _isSpaceUnit(s.codeUnitAt(i))) {
      i++;
    }
  }

  bool _startsWithCommand(String name) {
    if (!s.startsWith('\\$name', i)) return false;
    final next = i + name.length + 1;
    return next >= s.length || !_isLetter(s.codeUnitAt(next));
  }

  void _enter() {
    if (++depth > kLatexMaxDepth) _fail('too deep');
  }

  void _leave() => depth--;

  LatexNode parseDocument() {
    final row = _parseRow(const {_End.eof});
    return row;
  }

  _End? _peekEnd() {
    if (i >= s.length) return _End.eof;
    final c = s[i];
    if (c == '}') return _End.brace;
    if (c == ']') return _End.bracket;
    if (c == '&') return _End.amp;
    if (c == '\\') {
      if (i + 1 < s.length && s[i + 1] == '\\') return _End.rowSep;
      if (_startsWithCommand('end')) return _End.end;
      if (_startsWithCommand('right')) return _End.right;
    }
    return null;
  }

  /// Parses atoms up to (not including) one of [allowed].
  LatexRow _parseRow(Set<_End> allowed) {
    final items = <LatexNode>[];
    while (true) {
      _skipSpaces();
      final end = _peekEnd();
      if (end != null) {
        if (allowed.contains(end)) return _count(LatexRow(items));
        if (end != _End.bracket) _fail('unexpected ${end.name}');
      }
      items.add(_parseAtomWithScripts());
    }
  }

  LatexNode _parseAtomWithScripts() {
    _skipSpaces();
    final c = s[i];
    LatexNode base;
    if (c == '^' || c == '_' || c == "'") {
      base = _count(const LatexRow([]));
    } else {
      base = _parseAtom();
    }
    var limits = LatexLimits.auto;
    _skipSpaces();
    if (_startsWithCommand('limits')) {
      if (!_isOperator(base)) _fail('limits without operator');
      i += 7;
      limits = LatexLimits.limits;
    } else if (_startsWithCommand('nolimits')) {
      if (!_isOperator(base)) _fail('nolimits without operator');
      i += 9;
      limits = LatexLimits.noLimits;
    }
    LatexNode? sub;
    var caret = false;
    final supParts = <LatexNode>[];
    while (true) {
      _skipSpaces();
      if (i >= s.length) break;
      final ch = s[i];
      if (ch == '^') {
        i++;
        if (caret) _fail('double superscript');
        caret = true;
        supParts.add(_parseScriptArgument());
      } else if (ch == '_') {
        i++;
        if (sub != null) _fail('double subscript');
        sub = _parseScriptArgument();
      } else if (ch == "'") {
        i++;
        supParts.add(_count(const LatexSymbol('′')));
      } else {
        break;
      }
    }
    if (sub == null && supParts.isEmpty) return base;
    final LatexNode? sup = supParts.isEmpty
        ? null
        : supParts.length == 1
        ? supParts.first
        : _count(LatexRow(supParts));
    return _count(LatexScripts(base, sub: sub, sup: sup, limits: limits));
  }

  bool _isOperator(LatexNode node) => node is LatexOperator;

  LatexNode _parseScriptArgument() {
    _skipSpaces();
    if (i >= s.length) _fail('missing script');
    final c = s[i];
    if (c == '^' || c == '_' || c == '}' || c == '&') _fail('bad script');
    return _parseArgument();
  }

  /// A command argument: a `{group}` or one token.
  LatexNode _parseArgument() {
    _skipSpaces();
    if (i >= s.length) _fail('missing argument');
    final c = s[i];
    if (c == '{') return _parseGroup();
    if (c == '}' || c == '&' || c == '^' || c == '_') _fail('missing argument');
    if (c == '\\' && _peekEnd() != null) _fail('missing argument');
    _enter();
    try {
      return _parseAtom(singleDigit: true);
    } finally {
      _leave();
    }
  }

  LatexNode _parseGroup() {
    if (i >= s.length || s[i] != '{') _fail('expected {');
    i++;
    _enter();
    final row = _parseRow(const {_End.brace});
    _leave();
    i++; // the closing brace
    if (row.children.length == 1) return row.children.first;
    return row;
  }

  LatexNode _parseAtom({bool singleDigit = false}) {
    _skipSpaces();
    if (i >= s.length) _fail('unexpected end');
    final unit = s.codeUnitAt(i);
    final c = s[i];
    if (c == '{') return _parseGroup();
    if (c == '\\') return _parseCommand();
    if (_isDigit(unit)) {
      final start = i;
      i++;
      if (!singleDigit) {
        while (i < s.length && _isDigit(s.codeUnitAt(i))) {
          i++;
        }
        if (i + 1 < s.length && s[i] == '.' && _isDigit(s.codeUnitAt(i + 1))) {
          i++;
          while (i < s.length && _isDigit(s.codeUnitAt(i))) {
            i++;
          }
        }
      }
      return _count(LatexSymbol(s.substring(start, i)));
    }
    if (_isLetter(unit)) {
      i++;
      return _count(LatexSymbol(c, italic: true));
    }
    if (c == '~') {
      i++;
      return _count(const LatexSpace(0.3333));
    }
    if (c == r'$' || c == '%' || c == '#' || c == '^' || c == '_') {
      _fail('unsupported character $c');
    }
    if (unit < 0x20 || unit == 0x7F) _fail('control character');
    final known = kLatexUnicodeAtoms[c];
    if (known != null) {
      i++;
      return _count(LatexSymbol(known.$1, kind: known.$2));
    }
    // Any other character (including a surrogate pair) is an ordinary atom.
    var length = 1;
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < s.length) {
      final low = s.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) length = 2;
    }
    final text = s.substring(i, i + length);
    i += length;
    return _count(LatexSymbol(text, italic: _isGreekLowerChar(text)));
  }

  bool _isGreekLowerChar(String t) {
    final u = t.codeUnitAt(0);
    return t.length == 1 && u >= 0x3B1 && u <= 0x3C9;
  }

  /// Reads `\name` (letters) or `\x` (one non-letter); the cursor is on `\`.
  String _readCommandName() {
    i++; // the backslash
    if (i >= s.length) _fail('dangling backslash');
    final start = i;
    if (_isLetter(s.codeUnitAt(i))) {
      while (i < s.length && _isLetter(s.codeUnitAt(i))) {
        i++;
      }
      // `\operatorname*` style star is not supported.
      return s.substring(start, i);
    }
    i++;
    return s.substring(start, i);
  }

  LatexNode _parseCommand() {
    _enter();
    try {
      return _parseCommandBody();
    } finally {
      _leave();
    }
  }

  LatexNode _parseCommandBody() {
    final name = _readCommandName();
    switch (name) {
      case 'frac':
      case 'dfrac':
      case 'tfrac':
        {
          final a = _parseArgument();
          final b = _parseArgument();
          return _count(LatexFrac(a, b));
        }
      case 'binom':
      case 'dbinom':
      case 'tbinom':
        {
          final a = _parseArgument();
          final b = _parseArgument();
          return _count(
            LatexDelimited('(', _count(LatexFrac(a, b, bar: false)), ')'),
          );
        }
      case 'sqrt':
        return _parseSqrt();
      case 'text':
      case 'textrm':
      case 'textnormal':
      case 'mbox':
        return _count(LatexText(_readRawText()));
      case 'textbf':
        return _count(LatexText(_readRawText(), bold: true));
      case 'textit':
        return _count(LatexText(_readRawText(), italic: true));
      case 'operatorname':
        {
          final text = _readRawText().trim();
          if (text.isEmpty) _fail('empty operator name');
          return _count(LatexOperator(text));
        }
      case 'left':
        return _parseDelimited();
      case 'begin':
        return _parseEnvironment();
      case 'right':
      case 'end':
        _fail('unmatched \\$name');
      case 'limits':
      case 'nolimits':
        _fail('misplaced \\$name');
      case r'\':
        _fail('line break outside an environment');
    }
    final font = kLatexFontCommands[name];
    if (font != null) {
      final body = _parseArgument();
      return _count(LatexStyled(font, body));
    }
    final accent = kLatexAccents[name];
    if (accent != null) {
      final body = _parseArgument();
      return _count(LatexAccent(accent, body));
    }
    final greekLower = kLatexGreekLower[name];
    if (greekLower != null) {
      return _count(LatexSymbol(greekLower, italic: true));
    }
    final greekUpper = kLatexGreekUpper[name];
    if (greekUpper != null) return _count(LatexSymbol(greekUpper));
    final bigOp = kLatexBigOperators[name];
    if (bigOp != null) {
      return _count(
        LatexOperator(bigOp.$1, large: true, limitsByDefault: bigOp.$2),
      );
    }
    final fn = kLatexFunctions[name];
    if (fn != null) return _count(LatexOperator(name, limitsByDefault: fn));
    final symbol = kLatexSymbols[name];
    if (symbol != null) {
      return _count(LatexSymbol(symbol.$1, kind: symbol.$2));
    }
    final space = kLatexSpaces[name];
    if (space != null) return _count(LatexSpace(space));
    if (kLatexIgnored.contains(name)) return _count(const LatexRow([]));
    final escaped = kLatexEscapes[name];
    if (escaped != null) return _count(LatexSymbol(escaped));
    if (kLatexSizedDelimiters.contains(name)) {
      final delim = _readDelimiter();
      if (delim == '.') _fail('empty delimiter');
      final opening = kLatexOpeningDelimiters.contains(delim);
      return _count(
        LatexSymbol(
          delim,
          kind: opening ? LatexAtomKind.open : LatexAtomKind.close,
        ),
      );
    }
    if (name == '|') return _count(const LatexSymbol('‖'));
    _fail('unknown command \\$name');
  }

  LatexNode _parseSqrt() {
    _skipSpaces();
    LatexNode? index;
    if (i < s.length && s[i] == '[') {
      i++;
      _enter();
      final row = _parseRow(const {_End.bracket});
      _leave();
      i++; // the closing bracket
      index = row.children.length == 1 ? row.children.first : row;
    }
    final body = _parseArgument();
    return _count(LatexSqrt(body, index: index));
  }

  /// The brace group as raw text (for `\text`): escapes and spaces only.
  String _readRawText() {
    _skipSpaces();
    if (i >= s.length || s[i] != '{') _fail('expected {');
    i++;
    final out = StringBuffer();
    var level = 1;
    while (i < s.length) {
      final c = s[i];
      if (c == '{') {
        level++;
        i++;
      } else if (c == '}') {
        level--;
        i++;
        if (level == 0) {
          return out.toString().replaceAll(RegExp(r'\s+'), ' ');
        }
      } else if (c == '\\') {
        final name = _readCommandName();
        if (kLatexEscapes.containsKey(name)) {
          out.write(kLatexEscapes[name]);
        } else if (name == ' ' ||
            name == ',' ||
            name == ';' ||
            name == ':' ||
            name == 'quad' ||
            name == 'qquad') {
          out.write(' ');
        } else if (name == '\\') {
          out.write(' ');
        } else {
          _fail('unsupported \\$name in text');
        }
      } else if (c == r'$' || c == '%' || c == '^' || c == '_') {
        _fail('unsupported character in text');
      } else {
        out.write(c);
        i++;
      }
    }
    _fail('unterminated text');
  }

  /// One delimiter after `\left`, `\right` or `\big`. `.` is the empty one.
  String _readDelimiter() {
    _skipSpaces();
    if (i >= s.length) _fail('missing delimiter');
    final c = s[i];
    if (c == '.') {
      i++;
      return '.';
    }
    if (c == '(' || c == ')' || c == '[' || c == ']' || c == '|') {
      i++;
      return c;
    }
    if (c == '<' || c == '>') {
      i++;
      return c == '<' ? '⟨' : '⟩';
    }
    if (c == '\\') {
      final name = _readCommandName();
      final mapped = kLatexDelimiterCommands[name];
      if (mapped != null) return mapped;
    }
    _fail('bad delimiter');
  }

  LatexNode _parseDelimited() {
    final left = _readDelimiter();
    _enter();
    final body = _parseRow(const {_End.right});
    _leave();
    i += 6; // \right
    final right = _readDelimiter();
    return _count(LatexDelimited(left, body, right));
  }

  String _readEnvironmentName() {
    _skipSpaces();
    if (i >= s.length || s[i] != '{') _fail('expected {');
    final close = s.indexOf('}', i);
    if (close < 0) _fail('unterminated environment name');
    final name = s.substring(i + 1, close).trim();
    i = close + 1;
    return name;
  }

  LatexNode _parseEnvironment() {
    final name = _readEnvironmentName();
    final env = kLatexEnvironments[name];
    if (env == null) _fail('unknown environment $name');
    List<String>? aligns;
    if (name == 'array') aligns = _readColumnSpec();
    _enter();
    final rows = <List<LatexNode>>[<LatexNode>[]];
    var cells = 0;
    while (true) {
      final cell = _parseRow(const {_End.amp, _End.rowSep, _End.end});
      rows.last.add(cell);
      if (++cells > kLatexMaxCells) _fail('too many cells');
      final end = _peekEnd();
      if (end == _End.amp) {
        i++;
      } else if (end == _End.rowSep) {
        i += 2;
        _skipSpaces();
        if (i < s.length && s[i] == '[') {
          final close = s.indexOf(']', i);
          if (close < 0) _fail('unterminated row spacing');
          i = close + 1;
        }
        rows.add(<LatexNode>[]);
      } else {
        break;
      }
    }
    _leave();
    i += 4; // \end
    final closing = _readEnvironmentName();
    if (closing != name) _fail('\\end{$closing} does not close $name');
    if (rows.length > 1 && rows.last.length == 1) {
      final only = rows.last.first;
      if (only is LatexRow && only.children.isEmpty) rows.removeLast();
    }
    return _count(
      LatexGrid(
        rows,
        kind: env.$3,
        left: env.$1,
        right: env.$2,
        aligns: aligns,
      ),
    );
  }

  List<String> _readColumnSpec() {
    _skipSpaces();
    if (i >= s.length || s[i] != '{') _fail('missing column spec');
    final close = s.indexOf('}', i);
    if (close < 0) _fail('unterminated column spec');
    final aligns = <String>[];
    for (final ch in s.substring(i + 1, close).split('')) {
      if (ch == 'l' || ch == 'c' || ch == 'r') {
        aligns.add(ch);
      } else if (ch != '|' && ch != ' ') {
        _fail('unsupported column spec');
      }
    }
    if (aligns.isEmpty) _fail('empty column spec');
    i = close + 1;
    return aligns;
  }
}
