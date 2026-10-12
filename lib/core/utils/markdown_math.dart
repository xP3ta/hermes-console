/// Protection of TeX formulas in the assistant's Markdown (phase A).
///
/// Without a formula renderer, `$a_1 * b_2$` reached the Markdown parser, which
/// read `_` and `*` as emphasis and mangled the text. This pure pass finds the
/// math spans (`$…$`, `\(…\)`, `$$…$$`, `\[…\]`) and rewrites them as inline
/// code or a code block, so the TeX source shows intact in the existing code
/// style.
///
/// Rules ported from Desktop's preprocessing: money (`$5 and $10`, `R$ 12.345`)
/// is prose; fences and code spans are left alone; only a `math` fence would be a
/// formula and it is already painted as a code block.
library;

const int _cacheLimit = 32;

final Map<String, String> _cache = <String, String>{};

/// Returns [text] with the math spans turned into code. The result is
/// memoised per text: while an answer grows while streaming only the new text is
/// recomputed, and a repeated `build` does not repeat the pass.
String protectMarkdownMath(String text) {
  if (!text.contains(r'$') && !text.contains(r'\(') && !text.contains(r'\[')) {
    return text;
  }
  final cached = _cache.remove(text);
  if (cached != null) {
    _cache[text] = cached;
    return cached;
  }
  final result = _protectLines(text);
  _cache[text] = result;
  if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
  return result;
}

final RegExp _fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})');

String _protectLines(String text) {
  final pieces = <String>[];
  final prose = <String>[];
  String? fence;

  void flushProse() {
    if (prose.isEmpty) return;
    pieces.add(_protectProse(prose.join('\n')));
    prose.clear();
  }

  for (final line in text.split('\n')) {
    if (fence != null) {
      pieces.add(line);
      final trimmed = line.trim();
      if (trimmed.length >= fence.length &&
          trimmed.split('').every((c) => c == fence![0])) {
        fence = null;
      }
      continue;
    }
    final open = _fenceOpen.firstMatch(line);
    if (open != null) {
      flushProse();
      fence = open.group(1);
      pieces.add(line);
      continue;
    }
    prose.add(line);
  }
  flushProse();
  return pieces.join('\n');
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x30 && u <= 0x39;
}

int _longestBacktickRun(String s) {
  var best = 0;
  var run = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '`') {
      run++;
      if (run > best) best = run;
    } else {
      run = 0;
    }
  }
  return best;
}

String _inlineCode(String tex) {
  final flat = tex.replaceAll(RegExp(r'\s*\n\s*'), ' ');
  final fence = '`' * (_longestBacktickRun(flat) + 1);
  final pad = flat.startsWith('`') || flat.endsWith('`') ? ' ' : '';
  return '$fence$pad$flat$pad$fence';
}

String _displayBlock(String tex) {
  final longest = _longestBacktickRun(tex);
  final fence = '`' * (longest < 3 ? 3 : longest + 1);
  return '$fence\n$tex\n$fence';
}

final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWord(String c) => _wordChar.hasMatch(c);

/// Index of the `$` that closes the span opened by `s[open]`, or `null` if it
/// is not math. The span does not cross lines or stay empty. With attached
/// delimiters (`$x$`) the closing one cannot be preceded by a space or followed
/// by a digit (`$5 and $10` is money). With a spaced opening (`$ 2 * 2 $`, as
/// Desktop accepts) it also requires that the `$` does not hang off a word
/// (`R$ 12`), and that the closing one does not precede a number
/// (`$ 5 and $ 10`) or an attached word.
int? _inlineDollarEnd(String s, int open) {
  if (open + 1 >= s.length) return null;
  final spacedOpen = _isSpace(s[open + 1]);
  if (spacedOpen && open > 0 && _isWord(s[open - 1])) return null;
  for (var j = open + 1; j < s.length; j++) {
    final ch = s[j];
    if (ch == '\n') return null;
    if (ch == r'\') {
      if (j + 1 >= s.length || s[j + 1] == '\n') return null;
      j++;
      continue;
    }
    if (ch != r'$') continue;
    if (s.substring(open + 1, j).trim().isEmpty) return null;
    final spacedClose = _isSpace(s[j - 1]);
    if (spacedClose && !spacedOpen) return null;
    var next = j + 1;
    if (spacedOpen || spacedClose) {
      while (next < s.length && (s[next] == ' ' || s[next] == '\t')) {
        next++;
      }
    }
    if (next < s.length) {
      if (_isDigit(s[next])) return null;
      if (spacedClose && next == j + 1 && _isWord(s[next])) return null;
    }
    return j;
  }
  return null;
}

int? _displayDollarEnd(String s, int open) {
  for (var j = open + 2; j < s.length; j++) {
    if (s[j] == r'\') {
      j++;
      continue;
    }
    if (s[j] == r'$' && j + 1 < s.length && s[j + 1] == r'$') return j;
  }
  return null;
}

String _protectProse(String s) {
  final out = StringBuffer();
  var i = 0;

  /// Writes a formula block on its own lines and skips the whitespace around
  /// it.
  int emitDisplay(String tex, int after) {
    final before = out.toString().trimRight();
    out.clear();
    if (before.isNotEmpty) out.write('$before\n\n');
    out.write(_displayBlock(tex));
    var next = after;
    while (next < s.length && _isSpace(s[next])) {
      next++;
    }
    if (next < s.length) out.write('\n\n');
    return next;
  }

  while (i < s.length) {
    final c = s[i];
    if (c == r'\') {
      if (i + 1 < s.length) {
        final n = s[i + 1];
        if (n == '(') {
          final end = s.indexOf(r'\)', i + 2);
          final tex = end < 0 ? '' : s.substring(i + 2, end).trim();
          if (tex.isNotEmpty) {
            out.write(_inlineCode(tex));
            i = end + 2;
            continue;
          }
        } else if (n == '[') {
          final end = s.indexOf(r'\]', i + 2);
          final tex = end < 0 ? '' : s.substring(i + 2, end).trim();
          if (tex.isNotEmpty) {
            i = emitDisplay(tex, end + 2);
            continue;
          }
        }
        out.write(c);
        out.write(n);
        i += 2;
        continue;
      }
      out.write(c);
      i++;
      continue;
    }
    if (c == '`') {
      var run = 0;
      while (i + run < s.length && s[i + run] == '`') {
        run++;
      }
      var j = i + run;
      var closeEnd = -1;
      while (j < s.length) {
        if (s[j] != '`') {
          j++;
          continue;
        }
        var m = 0;
        while (j + m < s.length && s[j + m] == '`') {
          m++;
        }
        if (m == run) {
          closeEnd = j + m;
          break;
        }
        j += m;
      }
      if (closeEnd < 0) {
        out.write(s.substring(i, i + run));
        i += run;
      } else {
        out.write(s.substring(i, closeEnd));
        i = closeEnd;
      }
      continue;
    }
    if (c == r'$') {
      if (i + 1 < s.length && s[i + 1] == r'$') {
        final end = _displayDollarEnd(s, i);
        final tex = end == null ? '' : s.substring(i + 2, end).trim();
        if (tex.isNotEmpty) {
          i = emitDisplay(tex, end! + 2);
        } else {
          out.write(r'$$');
          i += 2;
        }
        continue;
      }
      final end = _inlineDollarEnd(s, i);
      if (end != null) {
        out.write(_inlineCode(s.substring(i + 1, end).trim()));
        i = end + 1;
        continue;
      }
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
