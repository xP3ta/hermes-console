/// Finds handwritten copy in UI arguments and notice helpers. It deliberately
/// does not inventory protocol values, arbitrary returns or language tables.
List<String> visibleDartLiterals(String source) {
  final tokens = _Strings(source).scan();
  final masked = source.codeUnits.toList();
  for (final token in tokens) {
    masked.fillRange(token.start, token.end, 32);
  }
  final withoutStrings = String.fromCharCodes(masked);
  final comments = _Strings(withoutStrings);
  for (var index = 0; index < masked.length;) {
    final end = comments.commentEnd(index);
    if (end != index) {
      masked.fillRange(index, end, 32);
      index = end;
    } else {
      index++;
    }
  }
  final code = String.fromCharCodes(masked);
  final frames = <_ArgumentFrame>[];
  final found = <String>[];
  var cursor = 0;
  for (final token in tokens) {
    while (cursor < token.start) {
      final char = code[cursor];
      if ('([{'.contains(char)) {
        final prefix = code.substring(cursor > 160 ? cursor - 160 : 0, cursor);
        final call = char == '(' ? _callName.firstMatch(prefix) : null;
        final name = call?.group(1);
        frames.add(_ArgumentFrame(char, name == null ? '' : name.split('.').last, cursor + 1));
      } else if (')]}'.contains(char)) {
        if (frames.isNotEmpty) frames.removeLast();
      } else if (char == ',' && frames.isNotEmpty && frames.last.char == '(') {
        frames.last
          ..argument = cursor + 1
          ..position++;
      }
      cursor++;
    }
    final prefix = source.substring(token.start > 60 ? token.start - 60 : 0, token.start);
    if (_dataInput.hasMatch(prefix) || _switchPattern.matchAsPrefix(code, token.end) != null) {
      continue; // Subscripts, comparisons and switch patterns are inputs.
    }
    var visible = false;
    for (final frame in frames.reversed.where((f) => f.char == '(')) {
      final argument = code.substring(frame.argument, token.start);
      final property = _namedArgument.firstMatch(argument)?[1];
      if (_dataCalls.contains(frame.name) ||
          property != null && (property.startsWith('on') || _dataArguments.contains(property)) ||
          frame.name == '_SoulTemplate') {
        break; // Document payloads, callbacks, keys and style metadata.
      }
      if (_visibleArguments.contains(property) ||
          frame.name == 'TextSpan' && property == 'text' ||
          _textCalls.contains(frame.name) && property == null && frame.position == 0 ||
          _noticeCalls.contains(frame.name) && (property == null || {'message', 'content', 'title', 'text', 'line', 'detail', 'more'}.contains(property))) {
        visible = true;
        break;
      }
    }
    if (!visible || token.nested && !_literalBranch.hasMatch(prefix)) continue;
    final text = token.text.replaceAll(_escapedWhitespace, '').trim();
    if (!_letter.hasMatch(text) || _technicalNames.contains(text) ||
        _units.contains(text.replaceAll(_notLetter, '')) ||
        _urlOrPath.hasMatch(text) || _filename.hasMatch(text) || text == '▸ hermes') {
      continue;
    }
    found.add(token.literal);
  }
  return found;
}

final _callName = RegExp(r'([A-Za-z_]\w*(?:\.\w+)*)\s*$');
final _namedArgument = RegExp(r'^\s*([A-Za-z_]\w*)\s*:');
final _dataInput = RegExp(r'(?:\[|==|!=|\bcase)\s*$');
final _switchPattern = RegExp(r'\s*=>');
final _literalBranch = RegExp(r'(?:\?\?|\?|:)\s*$');
final _escapedWhitespace = RegExp(r'\\(?:u(?:00[aA]0|2028|2029)|[nrtbfv])');
final _letter = RegExp(r'\p{L}', unicode: true);
final _notLetter = RegExp(r'[^\p{L}]', unicode: true);
final _urlOrPath = RegExp(r'^(?:https?://|/|\./|\.\./|[A-Za-z]:[\\/])');
final _filename = RegExp(r'^[^\s]+\.(?:md|dart|json|txt|png|webp)$');
const _visibleArguments = {
  'label', 'title', 'subtitle', 'hint', 'hintText', 'labelText', 'helperText',
  'tooltip', 'semanticLabel', 'semanticsLabel', 'content', 'errorText',
};
const _textCalls = {'Text', 'SelectableText'};
const _noticeCalls = {
  '_snack', '_toast', '_message', '_showMessage', 'notify', 'showSnackBar',
  'showDialog', 'Dialog', 'AlertDialog', 'SnackBar', 'showHermesDialog',
  'showHermesReviewPage', 'show', 'HermesNoticeCard', 'IslandEvent',
};
const _dataArguments = {'fontFamily', 'key', 'value', 'id', 'name', 'routeName', 'command', 'arguments'};
const _dataCalls = {
  'Key', 'ValueKey', 'GlobalKey', 'RegExp', 'FocusNode', 'FocusScopeNode',
  'Locale', 'contains', 'containsKey', 'startsWith', 'endsWith', 'getString',
  'getInt', 'getBool', '_titleFromTag',
};
const _units = {'v', 'ms', 's', 'B', 'KB', 'MB', 'GB', 'md'};
const _technicalNames = {
  'hermes', 'Hermes', 'Console', 'CONSOLE', 'HERMES', 'SOUL', 'SSH', 'HTTPS',
  'PIN', 'Dashboard', 'Nous', 'Bot Chat', 'Linux', 'macOS', 'Windows',
  'YouTube', 'Vimeo', 'Instagram', 'Pinterest', 'TikTok', 'X', 'Spotify',
  'OpenStreetMap', 'Google Maps', 'PDF', 'DOC', 'CSV', 'TXT', 'ZIP',
  'IMG', 'HTML', 'SVG', 'USD', 'HEX · #AARRGGBB', 'sk-…',
};

class _ArgumentFrame {
  _ArgumentFrame(this.char, this.name, this.argument);
  final String char;
  final String name;
  int argument;
  int position = 0;
}

class _StringToken {
  _StringToken(this.start, this.end, this.literal, this.text, this.nested);
  final int start;
  final int end;
  final String literal;
  final String text;
  final bool nested;
}

class _Strings {
  _Strings(this.source);
  final String source;
  final tokens = <_StringToken>[];
  var _stringDepth = 0;
  static final _identifierStart = RegExp(r'[A-Za-z_]');
  static final _identifierPart = RegExp(r'[A-Za-z0-9_]');

  List<_StringToken> scan() {
    _code(0);
    return tokens..sort((a, b) => a.start.compareTo(b.start));
  }

  int commentEnd(int start) {
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
      final end = commentEnd(index);
      if (end != index) {
        index = end;
        continue;
      }
      final raw = source[index] == 'r' && index + 1 < source.length && _quoteAt(index + 1);
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
    _stringDepth++;
    var index = start + (raw ? 1 : 0);
    final single = source[index];
    final triple = single * 3;
    final delimiter = source.startsWith(triple, index) ? triple : single;
    index += delimiter.length;
    final text = StringBuffer();
    while (index < source.length) {
      if (source.startsWith(delimiter, index)) {
        final end = index + delimiter.length;
        tokens.add(_StringToken(start, end, source.substring(start, end), text.toString(), _stringDepth > 1));
        _stringDepth--;
        return end;
      }
      if (!raw && source[index] == r'\') {
        text.write(source.substring(index, index + 2));
        index += 2;
      } else if (!raw && source.startsWith(r'${', index)) {
        index = _code(index + 2, interpolation: true);
      } else if (!raw && source[index] == r'$' && index + 1 < source.length && _identifierStart.hasMatch(source[index + 1])) {
        index += 2;
        while (index < source.length && _identifierPart.hasMatch(source[index])) {
          index++;
        }
      } else {
        text.write(source[index]);
        index++;
      }
    }
    throw const FormatException('Unclosed string');
  }
}
