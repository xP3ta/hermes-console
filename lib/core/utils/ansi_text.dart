/// ANSI handling for terminal tool output (Desktop parity:
/// `apps/shared/src/ansi.ts` for stripping, `apps/desktop/src/lib/ansi.ts`
/// for the SGR colour/bold parser). Only foreground colour (30–37, 90–97),
/// bold (1/22) and resets (0/39) are honoured; every other escape is dropped.
library;

const String _esc = '\x1B';
const String _bel = '\x07';

final RegExp _osc = RegExp('$_esc\\][\\s\\S]*?(?:$_bel|$_esc\\\\)');
final RegExp _dcs = RegExp('$_esc[PX^_][\\s\\S]*?(?:$_bel|$_esc\\\\)');
final RegExp _incompleteCsi = RegExp('$_esc\\[[0-?]*[ -/]*(?=$_esc|\\n|\$)');
final RegExp _csi = RegExp('$_esc\\[([0-?]*)[ -/]*([@-~])');
final RegExp _nonCsiEsc = RegExp('$_esc(?!\\[|\\]|P|X|\\^|_)[ -/]*[0-~]');
final RegExp _strayEsc = RegExp('$_esc(?!\\[)[\\s\\S]?');
final RegExp _control = RegExp(
  '[\\x00-\\x08\\x0B\\x0C\\x0D\\x0E-\\x1A\\x1C-\\x1F\\x7F]',
);

bool hasAnsi(String s) => s.contains(_esc);

/// Removes every escape sequence and control byte (keeps `\n` and `\t`).
String stripAnsi(String s) {
  if (!hasAnsi(s) && !_control.hasMatch(s)) return s;
  return s
      .replaceAll(_osc, '')
      .replaceAll(_dcs, '')
      .replaceAll(_incompleteCsi, '')
      .replaceAll(_csi, '')
      .replaceAll(_incompleteCsi, '')
      .replaceAll(_nonCsiEsc, '')
      .replaceAll(_strayEsc, '')
      .replaceAll(_control, '');
}

/// Like [stripAnsi] but keeps SGR (`…m`) sequences for [parseAnsi].
String sanitizeAnsiForRender(String s) => s
    .replaceAll(_osc, '')
    .replaceAll(_dcs, '')
    .replaceAll(_incompleteCsi, '')
    .replaceAllMapped(_csi, (m) => m[2] == 'm' ? m[0]! : '')
    .replaceAll(_incompleteCsi, '')
    .replaceAll(_nonCsiEsc, '')
    .replaceAll(_strayEsc, '')
    .replaceAll(_control, '');

/// ANSI foreground palette slot: 0–7 normal, 8–15 bright.
typedef AnsiColorIndex = int;

final class AnsiSegment {
  final String text;
  final bool bold;
  final AnsiColorIndex? fg;
  const AnsiSegment(this.text, {this.bold = false, this.fg});
}

/// Splits [input] into styled runs. Adjacent runs with equal style merge.
List<AnsiSegment> parseAnsi(String input) {
  if (input.isEmpty) return const [];
  final cleaned = sanitizeAnsiForRender(input);
  final segments = <AnsiSegment>[];
  var bold = false;
  AnsiColorIndex? fg;
  var cursor = 0;

  void push(String text) {
    if (text.isEmpty) return;
    if (segments.isNotEmpty &&
        segments.last.bold == bold &&
        segments.last.fg == fg) {
      final last = segments.removeLast();
      segments.add(AnsiSegment(last.text + text, bold: bold, fg: fg));
      return;
    }
    segments.add(AnsiSegment(text, bold: bold, fg: fg));
  }

  for (final match in _csi.allMatches(cleaned)) {
    push(cleaned.substring(cursor, match.start));
    cursor = match.end;
    if (match[2] != 'm') continue;
    final params = match[1]!;
    final codes = params.isEmpty
        ? const [0]
        : params.split(';').map((p) => p.isEmpty ? 0 : int.tryParse(p) ?? -1);
    final list = codes.toList();
    for (var i = 0; i < list.length; i++) {
      final code = list[i];
      if (code == 0) {
        bold = false;
        fg = null;
      } else if (code == 1) {
        bold = true;
      } else if (code == 22) {
        bold = false;
      } else if (code == 39) {
        fg = null;
      } else if (code >= 30 && code <= 37) {
        fg = code - 30;
      } else if (code >= 90 && code <= 97) {
        fg = code - 90 + 8;
      } else if (code == 38 || code == 48) {
        // Extended colours (256/truecolour) are not mapped: skip their args.
        if (i + 1 < list.length && list[i + 1] == 5) {
          i += 2;
        } else if (i + 1 < list.length && list[i + 1] == 2) {
          i += 4;
        }
      }
    }
  }
  push(cleaned.substring(cursor));
  return segments;
}
