/// Dependency-free lexical scanner for the visible-copy ratchet. Counts all
/// strings, including nested interpolation. No visibility/data-flow guesses.
List<String> dartStringLiterals(String source) => _DartStrings(source).scan();

class _DartStrings {
  _DartStrings(this.source);
  final String source;
  final List<String> literals = [];
  static final _identifierStart = RegExp(r'[A-Za-z_]');
  static final _identifierPart = RegExp(r'[A-Za-z0-9_]');

  List<String> scan() {
    _code(0);
    return literals;
  }

  int _comment(int start) {
    if (source.startsWith('//', start)) {
      final end = source.indexOf('\n', start);
      return end < 0 ? source.length : end;
    }
    if (!source.startsWith('/*', start)) return start;
    var index = start + 2;
    var depth = 1;
    while (index < source.length && depth > 0) {
      if (source.startsWith('/*', index)) {
        depth++;
        index += 2;
      } else if (source.startsWith('*/', index)) {
        depth--;
        index += 2;
      } else {
        index++;
      }
    }
    return index;
  }

  bool _quoteAt(int index) => source[index] == "'" || source[index] == '"';

  int _code(int start, {bool interpolation = false}) {
    var index = start;
    var depth = 1;
    while (index < source.length) {
      final end = _comment(index);
      if (end != index) {
        index = end;
        continue;
      }
      final raw = source[index] == 'r' &&
          index + 1 < source.length && _quoteAt(index + 1);
      if (_quoteAt(index) || raw) {
        index = _string(index, raw: raw);
      } else if (interpolation && source[index] == '{') {
        depth++;
        index++;
      } else if (interpolation && source[index] == '}') {
        depth--;
        index++;
        if (depth == 0) return index;
      } else {
        index++;
      }
    }
    if (interpolation) throw const FormatException('Unclosed interpolation');
    return index;
  }

  int _string(int start, {required bool raw}) {
    var index = start + (raw ? 1 : 0);
    final single = source[index];
    final triple = single * 3;
    final delimiter = source.startsWith(triple, index) ? triple : single;
    index += delimiter.length;
    while (index < source.length) {
      if (source.startsWith(delimiter, index)) {
        final end = index + delimiter.length;
        literals.add(source.substring(start, end));
        return end;
      }
      if (!raw && source[index] == r'\') {
        index += 2;
      } else if (!raw && source.startsWith(r'${', index)) {
        index = _code(index + 2, interpolation: true);
      } else if (!raw && source[index] == r'$' &&
          index + 1 < source.length &&
          _identifierStart.hasMatch(source[index + 1])) {
        index += 2;
        while (index < source.length &&
            _identifierPart.hasMatch(source[index])) {
          index++;
        }
      } else {
        index++;
      }
    }
    throw const FormatException('Unclosed string');
  }
}
