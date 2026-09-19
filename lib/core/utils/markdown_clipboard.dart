import 'bot_mention_text.dart';
import 'package:markdown/markdown.dart' as md;

/// Texto que se copia desde un mensaje escrito por la propia persona.
///
/// Se mantiene separado del copiado de respuestas para poder preservar el
/// contrato de round-trip del mensaje original.
String userMessageClipboardText(String markdown) => stripBotMentionNote(markdown);

/// Convierte el Markdown de un mensaje en el texto legible que ve el usuario.
///
/// Se usa únicamente al copiar mensajes completos. Los botones específicos de
/// código y diagnóstico deben seguir copiando su contenido literal.
String markdownToClipboardText(String markdown) {
  if (markdown.isEmpty) return '';

  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    // El AST se usa como representación de texto, no para generar HTML. Si se
    // deja activo, operadores y comillas de código llegan como `&gt;`/`&quot;`.
    encodeHtml: false,
  );
  final rendered = _ClipboardMarkdownRenderer().render(
    document.parse(markdown),
  );
  return rendered.replaceAll('\r\n', '\n').replaceAll(RegExp(r'^\n+|\n+$'), '');
}

/// Convierte Markdown en una sola línea de texto legible para previews.
///
/// A diferencia del texto de portapapeles, aquí los saltos y espacios no
/// tienen valor semántico: una tarjeta corta nunca debe enseñar `**`, `##` ni
/// ocupar varias líneas por el formato original de la respuesta.
String markdownToCompactText(String markdown) {
  // Las referencias privadas de adjuntos viajan en el contenido para que el
  // chat pueda reabrir los bytes enviados, pero nunca son texto del usuario.
  // El servidor puede devolverlas con o sin saltos en previews de sesión.
  markdown = markdown.replaceAll(
    RegExp(r'⟦hatt:v1:[A-Za-z0-9_-]{16,1024}⟧'),
    '',
  );
  final plain = markdownToClipboardText(
    markdown,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (plain.isEmpty) return '';

  // Algunos backends ya han aplanado los saltos antes de enviar el preview.
  // En ese caso `## Sección` deja de ser un heading válido para el parser y
  // sobrevive como texto literal; se limpia aquí sin tocar hashtags normales.
  return plain
      .replaceAllMapped(
        RegExp(r'(^|\s)#{1,6}\s+'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class _ClipboardMarkdownRenderer {
  String render(List<md.Node> nodes) => _renderBlocks(nodes);

  String _renderBlocks(List<md.Node>? nodes) {
    if (nodes == null || nodes.isEmpty) return '';
    return nodes
        .map((node) => _renderNode(node))
        .where((text) => text.isNotEmpty)
        .join('\n\n');
  }

  String _renderInline(List<md.Node>? nodes) {
    if (nodes == null || nodes.isEmpty) return '';
    return nodes.map((node) => _renderNode(node)).join();
  }

  String _renderNode(md.Node node) {
    if (node is md.Text) return node.text;
    if (node is! md.Element) return node.textContent;

    switch (node.tag) {
      case 'p':
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
      case 'em':
      case 'strong':
      case 'del':
      case 'code':
      case 'mark':
        return _renderInline(node.children);
      case 'a':
        final label = _renderInline(node.children);
        return label.isNotEmpty ? label : (node.attributes['href'] ?? '');
      case 'img':
        return node.attributes['alt'] ?? '';
      case 'br':
        return '\n';
      case 'hr':
        return '';
      case 'pre':
        return node.textContent.replaceFirst(RegExp(r'\n$'), '');
      case 'blockquote':
        return _renderBlocks(node.children);
      case 'ul':
        return _renderList(node, ordered: false, depth: 0);
      case 'ol':
        return _renderList(node, ordered: true, depth: 0);
      case 'li':
        return _renderListItemBody(node, depth: 0);
      case 'table':
        return _renderTable(node);
      case 'thead':
      case 'tbody':
      case 'tfoot':
        return _renderBlocks(node.children);
      case 'tr':
        return _renderTableRow(node);
      case 'th':
      case 'td':
        return _renderInline(node.children);
      case 'input':
        return '';
      default:
        return _renderInline(node.children);
    }
  }

  String _renderList(
    md.Element list, {
    required bool ordered,
    required int depth,
  }) {
    final items = (list.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((child) => child.tag == 'li')
        .toList();
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final indent = '  ' * depth;

    return <String>[
      for (var index = 0; index < items.length; index++)
        _prefixListItem(
          _renderListItemBody(items[index], depth: depth),
          prefix: ordered ? '${start + index}. ' : '• ',
          indent: indent,
        ),
    ].join('\n');
  }

  String _renderListItemBody(md.Element item, {required int depth}) {
    final mainBlocks = <md.Node>[];
    final nestedLists = <md.Element>[];
    for (final child in item.children ?? const <md.Node>[]) {
      if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
        nestedLists.add(child);
      } else {
        mainBlocks.add(child);
      }
    }

    final parts = <String>[];
    final main = _renderBlocks(mainBlocks);
    if (main.isNotEmpty) parts.add(main);
    for (final nested in nestedLists) {
      parts.add(
        _renderList(nested, ordered: nested.tag == 'ol', depth: depth + 1),
      );
    }
    return parts.join('\n');
  }

  String _prefixListItem(
    String body, {
    required String prefix,
    required String indent,
  }) {
    final lines = body.split('\n');
    if (lines.isEmpty) return '$indent$prefix';
    final continuationIndent = '$indent${' ' * prefix.length}';
    final continuation = lines.length == 1
        ? ''
        : '\n${lines.skip(1).map((line) {
            if (line.startsWith('  ')) return line;
            return '$continuationIndent$line';
          }).join('\n')}';
    return '$indent$prefix${lines.first}$continuation';
  }

  String _renderTable(md.Element table) {
    final rows = <md.Element>[];

    void collectRows(md.Node node) {
      if (node is! md.Element) return;
      if (node.tag == 'tr') {
        rows.add(node);
        return;
      }
      for (final child in node.children ?? const <md.Node>[]) {
        collectRows(child);
      }
    }

    collectRows(table);
    return rows.map(_renderTableRow).where((row) => row.isNotEmpty).join('\n');
  }

  String _renderTableRow(md.Element row) {
    return (row.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((cell) => cell.tag == 'th' || cell.tag == 'td')
        .map((cell) => _renderInline(cell.children).trim())
        .join('\t');
  }
}
