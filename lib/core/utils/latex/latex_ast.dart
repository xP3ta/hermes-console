/// Syntax tree of the TeX subset that Console paints natively.
///
/// Pure Dart (no Flutter): the parser builds it, the layout reads it. Every
/// node has a [debug] form (a short s-expression) so the parser can be tested
/// without painting anything.
library;

/// How an atom is spaced against its neighbours (a reduced TeX atom class).
enum LatexAtomKind { ord, bin, rel, open, close, punct }

/// Font variant a `\mathXX` command asks for.
enum LatexFontStyle {
  roman,
  bold,
  italic,
  boldItalic,
  blackboard,
  calligraphic,
  sans,
  mono,
}

/// Mark placed over or under a body.
enum LatexAccentKind {
  hat,
  tilde,
  bar,
  vec,
  dot,
  ddot,
  overline,
  underline,
  wideHat,
  wideTilde,
  overRightArrow,
}

/// Whether big operators put their scripts above/below or at the side.
enum LatexLimits { auto, limits, noLimits }

/// Block layouts for the supported environments.
enum LatexGridKind { matrix, cases, aligned }

sealed class LatexNode {
  const LatexNode();

  /// Compact form used by tests and diagnostics.
  String get debug;

  @override
  String toString() => debug;
}

/// One glyph run: a letter, a number, an operator sign, a punctuation mark.
final class LatexSymbol extends LatexNode {
  const LatexSymbol(
    this.text, {
    this.kind = LatexAtomKind.ord,
    this.italic = false,
  });

  final String text;
  final LatexAtomKind kind;

  /// Letters and lower-case Greek are italic unless a `\mathrm` says no.
  final bool italic;

  @override
  String get debug => text;
}

/// Sequence of nodes laid out left to right.
final class LatexRow extends LatexNode {
  const LatexRow(this.children);

  final List<LatexNode> children;

  @override
  String get debug => '{${children.map((c) => c.debug).join(' ')}}';
}

/// Upright prose from `\text{...}`.
final class LatexText extends LatexNode {
  const LatexText(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;

  @override
  String get debug => 'text($text)';
}

/// Operator names (`\sin`, `\lim`) and big operators (`\sum`, `\int`).
final class LatexOperator extends LatexNode {
  const LatexOperator(
    this.name, {
    this.large = false,
    this.limitsByDefault = false,
  });

  final String name;

  /// Drawn as a tall glyph (sum, product, integrals).
  final bool large;

  /// Display style puts the scripts above and below (sum, `\lim`).
  final bool limitsByDefault;

  @override
  String get debug => 'op($name)';
}

final class LatexStyled extends LatexNode {
  const LatexStyled(this.style, this.body);

  final LatexFontStyle style;
  final LatexNode body;

  @override
  String get debug => '${style.name}(${body.debug})';
}

final class LatexFrac extends LatexNode {
  const LatexFrac(this.numerator, this.denominator, {this.bar = true});

  final LatexNode numerator;
  final LatexNode denominator;

  /// `\binom` has no rule.
  final bool bar;

  @override
  String get debug =>
      '${bar ? 'frac' : 'stack'}(${numerator.debug},${denominator.debug})';
}

final class LatexSqrt extends LatexNode {
  const LatexSqrt(this.body, {this.index});

  final LatexNode body;
  final LatexNode? index;

  @override
  String get debug => index == null
      ? 'sqrt(${body.debug})'
      : 'sqrt[${index!.debug}](${body.debug})';
}

final class LatexScripts extends LatexNode {
  const LatexScripts(
    this.base, {
    this.sub,
    this.sup,
    this.limits = LatexLimits.auto,
  });

  final LatexNode base;
  final LatexNode? sub;
  final LatexNode? sup;
  final LatexLimits limits;

  @override
  String get debug {
    final b = StringBuffer(base.debug);
    if (sub != null) b.write('_{${sub!.debug}}');
    if (sup != null) b.write('^{${sup!.debug}}');
    return b.toString();
  }
}

/// `\left( ... \right)`: the delimiters grow with [body]. `.` means none.
final class LatexDelimited extends LatexNode {
  const LatexDelimited(this.left, this.body, this.right);

  final String left;
  final LatexNode body;
  final String right;

  @override
  String get debug => 'delim($left,${body.debug},$right)';
}

final class LatexAccent extends LatexNode {
  const LatexAccent(this.kind, this.body);

  final LatexAccentKind kind;
  final LatexNode body;

  @override
  String get debug => '${kind.name}(${body.debug})';
}

/// Horizontal space in em (negative for `\!`).
final class LatexSpace extends LatexNode {
  const LatexSpace(this.em);

  final double em;

  @override
  String get debug => 'space($em)';
}

/// Matrices, `cases` and aligned equations.
final class LatexGrid extends LatexNode {
  const LatexGrid(
    this.rows, {
    this.kind = LatexGridKind.matrix,
    this.left = '.',
    this.right = '.',
    this.aligns,
  });

  final List<List<LatexNode>> rows;
  final LatexGridKind kind;
  final String left;
  final String right;

  /// One of `l`, `c`, `r` per column; null means the default of [kind].
  final List<String>? aligns;

  @override
  String get debug {
    final body = rows.map((r) => r.map((c) => c.debug).join(',')).join(';');
    return 'grid:${kind.name}[$body]';
  }
}
