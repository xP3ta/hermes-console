import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import '../utils/chat_inline_refs.dart';
import '../utils/markdown_math.dart';
import 'chat/live_reply_reveal.dart';

/// Un segmento de una respuesta del asistente: o Markdown suelto, o una tabla
/// GFM ya parseada para pintarla con [MarkdownTable].
sealed class AnswerSegment {
  const AnswerSegment();
}

/// Trozo de Markdown normal (se pinta con el `MarkdownBody` de siempre).
class MarkdownSegment extends AnswerSegment {
  final String text;
  const MarkdownSegment(this.text);
}

/// Tabla GFM completa. `rows[0]` es la cabecera; el resto, el cuerpo.
class TableSegment extends AnswerSegment {
  final List<List<String>> rows;

  /// A table that is still being written (live text): it is drawn with room
  /// for the rows to come, so it does not grow in jumps.
  final bool live;
  const TableSegment(this.rows, {this.live = false});
}

/// The numbered sources of a reply («[1] https://… — what it is»), to be
/// drawn as rows instead of the running text they are written as.
class SourcesSegment extends AnswerSegment {
  final List<ChatSourceEntry> entries;
  const SourcesSegment(this.entries);
}

/// A table whose header is still arriving (live text): drawn as an empty
/// frame of the height it will have, never as the raw pipes.
class TableSkeletonSegment extends AnswerSegment {
  const TableSkeletonSegment();
}

final RegExp _separatorRow = RegExp(r'^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$');

bool _looksLikeRow(String line) => line.contains('|');

/// Parte las celdas de una fila GFM respetando los `|` exteriores opcionales y
/// las barras escapadas (`\|`), que NO separan celda.
List<String> _splitRow(String line) {
  final cells = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == r'\' && i + 1 < line.length && line[i + 1] == '|') {
      buf.write('|');
      i++;
      continue;
    }
    if (ch == '|') {
      cells.add(buf.toString().trim());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  cells.add(buf.toString().trim());
  // Los `|` exteriores producen una celda vacía al principio/final: se quitan.
  if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
  if (cells.isNotEmpty && cells.last.isEmpty) cells.removeLast();
  return cells;
}

/// Room around the text of a cell (a header, a row or a blank row).
const EdgeInsets _cellInsets = EdgeInsets.symmetric(
  horizontal: HermesSpace.x3,
  vertical: 9,
);

final RegExp _fenceLine = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})(.*)$');
final RegExp _partialSeparator = RegExp(r'^[\s:|-]*$');

/// Detecta tablas GFM **completas** (una fila de cabecera seguida de una fila
/// separadora `|---|---|`) dentro de [text] y las separa en [TableSegment]; el
/// resto queda como [MarkdownSegment]. Las tablas aún incompletas NO se tocan:
/// caen al render Markdown normal. También separa la lista de fuentes de la
/// respuesta («Fuentes» seguida de «[1] https://… — texto») en un
/// [SourcesSegment]. Nada de esto actúa dentro de un bloque de código.
///
/// Con [live] el texto aún se está escribiendo (su última línea no tiene salto
/// de línea): una tabla se pinta desde que hay cabecera y separadora, con las
/// filas que ya están enteras; la cabecera suelta se retiene como
/// [TableSkeletonSegment]; las fuentes salen una a una cuando están enteras.
/// Así ninguna barra `|` ni `[n] https://…` llega al texto visible.
///
/// Con `tables: false` solo se busca la lista de fuentes.
List<AnswerSegment> splitAnswerTables(
  String text, {
  bool live = false,
  bool tables = true,
}) {
  final hasPipe = tables && text.contains('|');
  // Live text can hold a heading whose first entry has not got an address
  // yet: its half-written number must not be shown either.
  final hasHttp =
      text.contains('http') || (live && chatMayHaveSourcesHeading(text));
  if (!hasPipe && !hasHttp) {
    return text.trim().isEmpty ? const [] : [MarkdownSegment(text)];
  }
  final lines = text.split('\n');
  final segments = <AnswerSegment>[];
  final pending = <String>[]; // Markdown acumulado antes de la tabla en curso.

  void flushPending() {
    if (pending.isEmpty) return;
    final md = pending.join('\n');
    if (md.trim().isNotEmpty) segments.add(MarkdownSegment(md));
    pending.clear();
  }

  final openLine = live && !text.endsWith('\n') ? lines.length - 1 : -1;
  final lastText = live ? lines.lastIndexWhere((l) => l.trim().isNotEmpty) : -1;
  String? fenceChar;
  var fenceLength = 0;
  var afterHeading = false;
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fence = _fenceLine.firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      if (fenceChar == null) {
        fenceChar = marker[0];
        fenceLength = marker.length;
      } else if (marker[0] == fenceChar &&
          marker.length >= fenceLength &&
          fence.group(2)!.trim().isEmpty) {
        fenceChar = null;
      }
      pending.add(line);
      i++;
      continue;
    }
    if (fenceChar != null) {
      pending.add(line);
      i++;
      continue;
    }

    if (hasHttp) {
      if (chatIsSourcesHeading(line)) {
        afterHeading = true;
        pending.add(line);
        i++;
        continue;
      }
      if (afterHeading && line.trim().isEmpty) {
        pending.add(line);
        i++;
        continue;
      }
      // Under a «Sources» heading; without one, only a finished text with
      // two or more entries in a row.
      final headed = afterHeading;
      afterHeading = false;
      if (headed || (!live && line.startsWith('['))) {
        final section = chatSourcesSectionAt(lines, i, live: live);
        if (section != null && (headed || section.entries.length >= 2)) {
          if (section.entries.isNotEmpty) {
            flushPending();
            segments.add(SourcesSegment(section.entries));
          }
          i = section.end;
          continue;
        }
      }
    }

    if (!hasPipe) {
      pending.add(line);
      i++;
      continue;
    }
    final isHeader = _looksLikeRow(line) && line.trim().isNotEmpty;
    final hasSeparator =
        isHeader &&
        i + 1 < lines.length &&
        _separatorRow.hasMatch(lines[i + 1]) &&
        lines[i + 1].contains('-');
    if (isHeader && hasSeparator) {
      // Arranca una tabla: cabecera (i), separadora (i+1), cuerpo (i+2…).
      final header = _splitRow(line);
      final rows = <List<String>>[header];
      var j = i + 2;
      while (j < lines.length &&
          _looksLikeRow(lines[j]) &&
          lines[j].trim().isNotEmpty) {
        rows.add(_splitRow(lines[j]));
        j++;
      }
      // La fila que aún se está escribiendo no se pinta: aparece entera.
      if (live && j - 1 == openLine && j - 1 >= i + 2) rows.removeLast();
      // Solo la tratamos como tabla si tiene al menos una fila de datos; si no,
      // es más seguro dejarla como Markdown. En vivo basta la cabecera.
      if (rows.length >= (live ? 1 : 2) && header.isNotEmpty) {
        flushPending();
        segments.add(TableSegment(_normalizeTable(rows), live: live));
        i = j;
        continue;
      }
    }
    if (live &&
        isHeader &&
        line.trimLeft().startsWith('|') &&
        (i == 0 || lines[i - 1].trim().isEmpty) &&
        (i == lastText ||
            (i + 1 == lastText &&
                lines[i + 1].trimLeft().startsWith('|') &&
                _partialSeparator.hasMatch(lines[i + 1])))) {
      // Cabecera (o cabecera y separador a medias) al final del texto: la
      // tabla aún no existe y las barras no se enseñan.
      flushPending();
      segments.add(const TableSkeletonSegment());
      break;
    }
    pending.add(line);
    i++;
  }
  flushPending();
  return segments;
}

/// Corrige el desajuste de columnas más común de las tablas mal formadas por el
/// modelo: una cabecera con celdas de más (una `-` o vacía inicial, un artefacto
/// típico) que desplaza las etiquetas respecto a los datos. Toma como fuente de
/// verdad el nº de columnas MÁS COMÚN de las filas de datos, quita las celdas
/// basura del inicio de la cabecera y cuadra todas las filas a ese ancho. Las
/// tablas bien formadas (todas las filas con el mismo nº de celdas) no cambian.
List<List<String>> _normalizeTable(List<List<String>> rows) {
  if (rows.length < 2) return rows;
  final counts = <int, int>{};
  for (var i = 1; i < rows.length; i++) {
    counts[rows[i].length] = (counts[rows[i].length] ?? 0) + 1;
  }
  var modal = rows[1].length;
  var best = 0;
  counts.forEach((len, n) {
    if (n > best) {
      best = n;
      modal = len;
    }
  });

  final fixed = <List<String>>[];
  for (var i = 0; i < rows.length; i++) {
    var cells = List<String>.from(rows[i]);
    if (i == 0) {
      // Cabecera con celdas de más: quita las vacías o `-` del inicio (el
      // artefacto que descuadra) y, si aún sobra, recorta por el final.
      while (cells.length > modal &&
          (cells.first.isEmpty || cells.first == '-')) {
        cells.removeAt(0);
      }
    }
    if (cells.length < modal) {
      cells = [...cells, ...List<String>.filled(modal - cells.length, '')];
    } else if (cells.length > modal) {
      cells = cells.sublist(0, modal);
    }
    fixed.add(cells);
  }
  return fixed;
}

/// Quita el marcado inline de una celda para pintarla como texto plano legible:
/// `[texto](url)` → `texto`, y elimina `**`, `__`, `` ` `` y `~~`. Es
/// deliberadamente conservador (las celdas casi siempre son texto o enlaces).
String stripInlineMarkdown(String s) {
  var t = s.trim();
  t = t.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  t = t.replaceAll(RegExp(r'\*\*|__|~~|`'), '');
  return t.trim();
}

/// Marks tables that their message selects with its own region, also while
/// that region is still off (a selectable `ChatMarkdownBody` that streams):
/// their cells stay plain, the way they are once the region arrives.
class MarkdownTableSelectedByMessage extends InheritedWidget {
  const MarkdownTableSelectedByMessage({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MarkdownTableSelectedByMessage>() !=
      null;

  @override
  bool updateShouldNotify(MarkdownTableSelectedByMessage oldWidget) => false;
}

/// Tabla GFM con estética limpia (borde redondeado, cabecera destacada, filas
/// con separadores finos). Cada columna toma su **ancho propio** según el
/// contenido (acotado a [_maxColumn], por encima la celda envuelve) y la tabla
/// se **desplaza en horizontal** si no cabe, en vez de apretar y partir la
/// cabecera. Las celdas se pintan con Markdown real (enlaces PULSABLES, negrita,
/// código) reusando el manejador de enlaces del chat vía [onLinkTap].
class MarkdownTable extends StatelessWidget {
  final List<List<String>> rows;

  /// Manejador de tap en enlaces de celda (mismo que el chat: apertura segura).
  final void Function(String? href)? onLinkTap;

  /// Empty body rows drawn below the real ones until there are this many: a
  /// table that is still arriving keeps its height while its rows come.
  final int minBodyRows;

  const MarkdownTable({
    required this.rows,
    this.onLinkTap,
    this.minBodyRows = 0,
    super.key,
  });

  /// Widths of recent tables by content: a live table is laid out again on
  /// every frame of its answer, and measuring every cell is the costly part.
  static final LinkedHashMap<String, List<double>> _widthCache =
      LinkedHashMap<String, List<double>>();

  // Relleno horizontal de cada celda (izq + der). Debe cuadrar con el Padding.
  static const double _cellPadding = 24;
  // Margen de seguridad para negrita/código/subrayado (la medición usa el texto
  // plano; el render puede ser algo más ancho).
  static const double _safety = 12;
  // Ancho mínimo legible y tope por columna (por encima, la celda envuelve).
  static const double _minColumn = 44;
  static const double _maxColumn = 300;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (rows.isEmpty) return const SizedBox.shrink();
    final colCount = rows.fold<int>(0, (m, r) => math.max(m, r.length));
    if (colCount == 0) return const SizedBox.shrink();

    final textScaler = MediaQuery.textScalerOf(context);
    // The cells are plain paragraphs in a live reply and wherever a
    // selection region around the message selects them (the chat's
    // finished bubble). The reveal reads plain cells with the prose around
    // them and keeps every row already read painted: selectable ones would
    // be invisible to it and the whole table would vanish on every arrival.
    // Drawn the same way live and finished, the table keeps its height
    // when the reply finishes: a selectable cell reserves a taller line and
    // room for a caret. Only a table no region selects, now or once its
    // message stops streaming, keeps its own selectable cells.
    final selectable =
        !LiveReplyReveal.live(context) &&
        SelectionContainer.maybeOf(context) == null &&
        !MarkdownTableSelectedByMessage.of(context);
    // While the reply reveals its text the blank rows are left out: the
    // reveal shows them only between arrivals, so they would make the reply
    // shrink and grow with every row; the reveal grows it instead.
    final revealing = LiveReplyReveal.revealing(context);
    // CLAVE: medir con la MISMA fuente con la que se pinta la celda. El tema usa
    // una fuente propia (más ancha que la de sistema); si midiéramos con la de
    // sistema, la columna quedaría corta y partiría palabras ("TechCrunc h").
    final themeBase =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final headerStyle = themeBase.copyWith(
      fontSize: 12.5,
      height: 1.35,
      fontWeight: FontWeight.w700,
      color: colors.textPrimary,
    );
    final bodyStyle = themeBase.copyWith(
      fontSize: 12.5,
      height: 1.35,
      fontWeight: FontWeight.w400,
      color: colors.textSecondary,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 360.0;
        final widths = _cachedColumnWidths(
          colCount,
          textScaler,
          headerStyle,
          bodyStyle,
        );
        final blankRows = revealing
            ? 0
            : math.max(0, minBodyRows - (rows.length - 1));
        final blankHeight = textScaler.scale(
          (bodyStyle.fontSize ?? 12.5) * (bodyStyle.height ?? 1.35),
        );
        final total = widths.fold<double>(0, (a, b) => a + b);

        final table = Table(
          columnWidths: {
            for (var c = 0; c < colCount; c++) c: FixedColumnWidth(widths[c]),
          },
          border: TableBorder(
            horizontalInside: BorderSide(
              color: colors.divider.withValues(alpha: 0.32),
            ),
            verticalInside: BorderSide(
              color: colors.divider.withValues(alpha: 0.32),
            ),
          ),
          children: [
            for (var r = 0; r < rows.length; r++)
              TableRow(
                decoration: BoxDecoration(
                  color: r == 0
                      ? colors.surfaceVariant.withValues(alpha: 0.65)
                      : null,
                ),
                children: [
                  for (var c = 0; c < colCount; c++)
                    TableCell(
                      verticalAlignment: TableCellVerticalAlignment.middle,
                      child: Padding(
                        padding: _cellInsets,
                        child: _cell(
                          context,
                          colors,
                          c < rows[r].length ? rows[r][c] : '',
                          r == 0 ? headerStyle : bodyStyle,
                          selectable: selectable,
                        ),
                      ),
                    ),
                ],
              ),
            for (var r = 0; r < blankRows; r++)
              TableRow(
                children: [
                  for (var c = 0; c < colCount; c++)
                    TableCell(
                      child: Padding(
                        padding: _cellInsets,
                        child: SizedBox(height: blankHeight),
                      ),
                    ),
                ],
              ),
          ],
        );

        // Ancho propio por columna; si excede la pantalla se desplaza en
        // horizontal (mejor que apretar y partir la cabecera). Si cabe, la
        // tabla ocupa solo su ancho (alineada a la izquierda).
        final Widget content = total > maxWidth
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: total, child: table),
              )
            : SizedBox(width: total, child: table);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          // In a live reply the border stays painted around the row being
          // read, not only between arrivals: its sides and the cells' side
          // padding (2 of 12 dp), and at the last row its foot, the cells'
          // bottom padding and the border (10 dp, the rounded corners too).
          child: LiveReplyFrame(
            edges: const EdgeInsets.fromLTRB(2, 0, 2, 10),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.55),
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: content,
            ),
          ),
        );
      },
    );
  }

  /// Celda pintada como Markdown real: enlaces pulsables (vía [onLinkTap]),
  /// negrita, código en línea, etc. Reusa el color de acento para los enlaces.
  /// [base] es el estilo (con la fuente del tema) con el que también se midió la
  /// columna, para que medida y render coincidan.
  Widget _cell(
    BuildContext context,
    HermesThemeColors colors,
    String data,
    TextStyle base, {
    required bool selectable,
  }) {
    final sheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      a: base.copyWith(
        color: colors.accent,
        decoration: TextDecoration.underline,
        decorationColor: colors.accent.withValues(alpha: 0.5),
      ),
      code: base.copyWith(
        fontFamily: 'JetBrainsMono',
        color: colors.textPrimary,
        backgroundColor: colors.surface,
      ),
      blockSpacing: 0,
      pPadding: EdgeInsets.zero,
    );
    return MarkdownBody(
      data: data.replaceAll(kMathInlineMarker, ''),
      selectable: selectable,
      softLineBreak: true,
      styleSheet: sheet,
      onTapLink: (text, href, title) => onLinkTap?.call(href),
    );
  }

  List<double> _cachedColumnWidths(
    int colCount,
    TextScaler textScaler,
    TextStyle headerStyle,
    TextStyle bodyStyle,
  ) {
    final key = StringBuffer()
      ..write(textScaler.scale(100))
      ..write('|')
      ..write(headerStyle.fontFamily)
      ..write('|')
      ..write(colCount);
    for (final row in rows) {
      key.write('\n');
      for (final cell in row) {
        key
          ..write(cell)
          ..write('\u0001');
      }
    }
    final id = key.toString();
    final hit = _widthCache.remove(id);
    if (hit != null) {
      _widthCache[id] = hit;
      return hit;
    }
    final widths = _columnWidths(colCount, textScaler, headerStyle, bodyStyle);
    _widthCache[id] = widths;
    if (_widthCache.length > 24) _widthCache.remove(_widthCache.keys.first);
    return widths;
  }

  /// Ancho de cada columna = ancho natural del texto en una línea (acotado entre
  /// [_minColumn] y [_maxColumn]). Se mide con [headerStyle]/[bodyStyle], que
  /// llevan la fuente REAL del tema, para que la columna no parta palabras. Sin
  /// repartos ni encogimientos; si la suma no cabe, el `build` la desplaza.
  List<double> _columnWidths(
    int colCount,
    TextScaler textScaler,
    TextStyle headerStyle,
    TextStyle bodyStyle,
  ) {
    final widths = List<double>.filled(colCount, 0);
    for (var r = 0; r < rows.length; r++) {
      final style = r == 0 ? headerStyle : bodyStyle;
      for (var c = 0; c < rows[r].length && c < colCount; c++) {
        final tp = TextPainter(
          text: TextSpan(text: stripInlineMarkdown(rows[r][c]), style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          textScaler: textScaler,
        )..layout();
        widths[c] = math.max(widths[c], tp.width + _cellPadding + _safety);
      }
    }
    for (var c = 0; c < colCount; c++) {
      widths[c] = widths[c].clamp(_minColumn, _maxColumn);
    }
    return widths;
  }
}

/// The frame of a table whose header has not arrived: a header row and two
/// body rows of muted bars, as tall as the table will be, so the answer does
/// not jump when the real one replaces it. No motion.
class ChatTableSkeleton extends StatelessWidget {
  const ChatTableSkeleton({super.key});

  static const double _width = 280;
  static const List<double> _bars = [0.5, 0.7, 0.4];

  @override
  Widget build(BuildContext context) {
    // A reply being revealed is clipped below the line it is reading: this
    // frame would show only between arrivals and flicker. The table that
    // replaces it grows in with the reveal.
    if (LiveReplyReveal.revealing(context)) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final line = MediaQuery.textScalerOf(context).scale(12.5 * 1.35);
    final bar = colors.divider.withValues(alpha: 0.5);
    Widget row(int r) => DecoratedBox(
      decoration: BoxDecoration(
        color: r == 0 ? colors.surfaceVariant.withValues(alpha: 0.65) : null,
        border: r == 0
            ? null
            : Border(
                top: BorderSide(color: colors.divider.withValues(alpha: 0.32)),
              ),
      ),
      child: Padding(
        padding: _cellInsets,
        child: SizedBox(
          height: line,
          child: Row(
            children: [
              for (var c = 0; c < _bars.length; c++) ...[
                if (c > 0) const SizedBox(width: 16),
                Expanded(
                  flex: (_bars[c] * 10).round(),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: r == 0 ? 0.7 : 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: bar,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const SizedBox(height: 8),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? math.min(_width, constraints.maxWidth)
            : _width;
        return Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            container: true,
            label: Localizations.of<Strings>(
              context,
              Strings,
            )?.mdpTablePreparing,
            excludeSemantics: true,
            child: Container(
              width: width,
              margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
              decoration: BoxDecoration(
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.55),
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [for (var r = 0; r < 3; r++) row(r)],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The live [text] without the list of sources it ends with, and the sources
/// whole enough to show; null when it ends with none. Used where the closed
/// blocks of a live reply are cached by their text: the list is cut off
/// before them so its rows come one by one and the text around them stays
/// as it was.
({String before, List<ChatSourceEntry> entries})? peelLiveSources(String text) {
  final segments = splitAnswerTables(text, live: true, tables: false);
  final before = StringBuffer();
  List<ChatSourceEntry> entries = const [];
  for (final (index, segment) in segments.indexed) {
    switch (segment) {
      case MarkdownSegment(:final text):
        if (index > 0) before.write('\n');
        before.write(text);
      case SourcesSegment(entries: final found):
        if (index != segments.length - 1) return null;
        entries = found;
      default:
        return null;
    }
  }
  final shown = before.toString();
  if (entries.isEmpty && shown.length >= text.length) return null;
  return (before: shown, entries: entries);
}
