// Assistant markdown rendering: code blocks with copy/run affordances and
// link preview cards.
part of 'chat_screen.dart';

/// Intercepts fenced code blocks so they render inside [_CodeBlockWrapper]
/// (horizontal scroll + copy button). The default `codeblockDecoration`
/// container is still applied by flutter_markdown around the returned widget.
/// Bloque verbatim que el modelo envolvió en ``` pero que es prosa (no código).
/// Se muestra legible y proporcional, con un fondo/borde sutiles para seguir
/// señalando que es un bloque, sin la dureza monoespaciada de un code block.
class _PlainTextBlock extends StatelessWidget {
  final String text;
  const _PlainTextBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.divider.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.textPrimary,
          height: 1.5,
        ),
      ),
    );
  }
}

class _PreCodeBuilder extends MarkdownElementBuilder {
  // Como registramos un builder para `pre`, flutter_markdown enruta el texto
  // interno del code block a ESTE builder vía visitText. El contenido ya lo
  // extraemos del elemento en visitElementAfter, así que aquí devolvemos un
  // widget vacío: si devolviéramos null, el texto se filtraría como inline y
  // dispararía el assert `_inlines.isEmpty` (pantalla rota con código).
  @override
  Widget visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    final lang = _languageOf(element);
    final normalizedLanguage = (lang ?? '').toLowerCase();
    if (normalizedLanguage == 'tree' || normalizedLanguage == 'filetree') {
      final nodes = parseHermesFileTree(code);
      if (nodes != null) return HermesFileTree(nodes: nodes);
    }
    // Vallas sin lenguaje / "text" cuyo contenido NO parece código (un resumen,
    // una nota, una lista que el modelo metió en ```): se muestran como texto
    // legible en vez de caja monoespaciada estilo "log".
    if (_isPlainProse(code, lang)) {
      return _PlainTextBlock(text: code);
    }
    return _CodeBlockWrapper(code: code, lang: lang);
  }

  /// Heurística conservadora: solo es "prosa" si NO hay lenguaje real y el
  /// contenido no presenta señales de código/log/tabla (llaves, indentación,
  /// columnas alineadas, prompts de shell, tags…). Ante la duda → código.
  static bool _isPlainProse(String code, String? lang) {
    final l = (lang ?? '').toLowerCase();
    // `markdown`/`md` incluidos: un modelo que envuelve PROSA en ```markdown no
    // debe verse como caja de código. Si el contenido tiene señales de código
    // reales (abajo) se mantiene como bloque; aquí solo lo habilitamos.
    const texty = {'', 'text', 'txt', 'plain', 'plaintext', 'markdown', 'md'};
    if (!texty.contains(l)) return false;
    if (code.trim().isEmpty) return false;
    final codeSignals = RegExp(
      r'[{};]|=>|=&|\|\||&&|</?[a-zA-Z]|^\s*[#$>]\s',
      multiLine: true,
    );
    for (final line in code.split('\n')) {
      if (codeSignals.hasMatch(line)) return false;
      if (RegExp(r'^\s{2,}\S').hasMatch(line)) return false; // indentación
      if (RegExp(r'\S {2,}\S').hasMatch(line.trimRight())) {
        return false; // columnas alineadas (tablas ascii / logs)
      }
      if (line.split('|').length > 2) return false; // tabla con pipes
    }
    return true;
  }

  /// Infiere el lenguaje del bloque a partir de la clase `language-xxx` que
  /// flutter_markdown pone en el `<code>` hijo del `<pre>` (```python, etc.).
  static String? _languageOf(md.Element pre) {
    final children = pre.children;
    if (children == null) return null;
    for (final child in children) {
      if (child is md.Element && child.tag == 'code') {
        final cls = child.attributes['class'];
        if (cls != null && cls.startsWith('language-')) {
          return cls.substring('language-'.length);
        }
      }
    }
    return null;
  }
}

class _CodeBlockWrapper extends StatefulWidget {
  final String code;

  /// Lenguaje inferido del bloque (p. ej. `python`, `bash`), o null.
  final String? lang;

  const _CodeBlockWrapper({required this.code, this.lang});

  @override
  State<_CodeBlockWrapper> createState() => _CodeBlockWrapperState();
}

class _CodeBlockWrapperState extends State<_CodeBlockWrapper> {
  static const int _maxSyntaxHighlightChars = 16000;
  static const int _maxHighlightCacheEntries = 32;
  static final LinkedHashMap<(String, String), List<TextSpan>?>
  _highlightCache = LinkedHashMap<(String, String), List<TextSpan>?>();

  bool _copied = false;
  Timer? _resetTimer;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    HapticFeedback.selectionClick();
    _resetTimer?.cancel();
    setState(() => _copied = true);
    _resetTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final spans = _highlightSpans();
    // Texto resaltado (tema oscuro) o plano: el plano conserva el look ámbar
    // actual; si el resaltado falla, NUNCA se rompe el render.
    final TextStyle baseStyle = TextStyle(
      // Monoespaciado: el código/comando se lee como en una terminal y, sobre
      // todo, las columnas (logs, tablas ascii) quedan alineadas.
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.45,
      color: spans == null
          ? colors.textPrimary.withValues(alpha: 0.92)
          : const Color(0xFFE6E6E6),
    );
    final Widget codeText = spans == null
        ? Text(widget.code, style: baseStyle)
        : Text.rich(TextSpan(style: baseStyle, children: spans));

    final bool highlighted = spans != null;
    // Fondo del cuerpo: editor oscuro cuando hay resaltado real; si no, hereda
    // el surfaceVariant del marco sin teñir el texto con el acento del tema.
    final Color bodyColor = highlighted
        ? const Color(0xFF1E1E1E)
        : colors.surfaceVariant;

    final Widget body = ColoredBox(
      color: bodyColor,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: codeText,
      ),
    );

    // Cabecera: etiqueta del lenguaje + botón copiar (estilo editor/terminal).
    final Widget header = Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
      color: highlighted
          ? const Color(0xFF161616)
          : colors.surfaceVariant.withValues(alpha: 0.6),
      child: Row(
        children: [
          Text(
            _languageLabel,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              letterSpacing: 0.5,
              color: colors.textSecondary,
            ),
          ),
          const Spacer(),
          Tooltip(
            message: Strings.of(context).chaCodeCopyTooltip,
            child: GestureDetector(
              onTap: _copy,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        transitionBuilder: (child, anim) =>
                            ScaleTransition(scale: anim, child: child),
                        child: Icon(
                          _copied ? Icons.check : Icons.content_copy,
                          key: ValueKey<bool>(_copied),
                          size: 14,
                          color: _copied ? colors.accent : colors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _copied
                            ? Strings.of(context).chaCodeCopied
                            : Strings.of(context).chaCodeCopy,
                        style: TextStyle(
                          fontSize: 11,
                          color: _copied ? colors.accent : colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [header, body],
      ),
    );
  }

  /// Etiqueta legible del lenguaje para la cabecera. Sin lenguaje declarado
  /// muestra "texto" (no inventa nada).
  String get _languageLabel {
    final raw = widget.lang?.trim();
    if (raw == null || raw.isEmpty) return 'texto';
    return raw.toLowerCase();
  }

  // ── Syntax highlighting (paquete `highlight`) ──────────────────────────────
  //
  // Alias de lenguajes markdown comunes → ids registrados en `highlight`.
  static const Map<String, String> _langAliases = {
    'sh': 'bash',
    'shell': 'bash',
    'zsh': 'bash',
    'console': 'bash',
    'js': 'javascript',
    'ts': 'typescript',
    'py': 'python',
    'yml': 'yaml',
    'html': 'xml',
    'c++': 'cpp',
    'rs': 'rust',
    'kt': 'kotlin',
  };

  /// Devuelve los spans coloreados del código, o null si no hay lenguaje
  /// inferible o el parser falla (se cae a texto plano sin romper el render).
  List<TextSpan>? _highlightSpans() {
    final raw = widget.lang;
    if (raw == null) return null;
    final lang =
        _langAliases[raw.toLowerCase().trim()] ?? raw.toLowerCase().trim();
    if (lang.isEmpty) return null;
    // highlight.parse es síncrono. En un bloque enorme el color no compensa
    // bloquear el hilo UI; se conserva el código completo como texto mono.
    if (widget.code.length > _maxSyntaxHighlightChars) return null;
    final key = (lang, widget.code);
    if (_highlightCache.containsKey(key)) {
      final cached = _highlightCache.remove(key);
      _highlightCache[key] = cached;
      return cached;
    }
    List<TextSpan>? spans;
    try {
      final result = highlight.parse(widget.code, language: lang);
      final nodes = result.nodes;
      if (nodes != null && nodes.isNotEmpty) spans = _spansForNodes(nodes);
    } catch (_) {}
    _highlightCache[key] = spans;
    while (_highlightCache.length > _maxHighlightCacheEntries) {
      _highlightCache.remove(_highlightCache.keys.first);
    }
    return spans;
  }

  List<TextSpan> _spansForNodes(List<Node> nodes) {
    final out = <TextSpan>[];
    for (final n in nodes) {
      final color = _classColor(n.className);
      final style = color == null ? null : TextStyle(color: color);
      final children = n.children;
      if (n.value != null) {
        out.add(TextSpan(text: n.value, style: style));
      } else if (children != null && children.isNotEmpty) {
        out.add(TextSpan(style: style, children: _spansForNodes(children)));
      }
    }
    return out;
  }

  /// Mapea la clase hljs a un color del tema oscuro simple.
  static Color? _classColor(String? cls) {
    switch (cls) {
      case 'keyword':
      case 'built_in':
      case 'literal':
      case 'type':
      case 'meta':
      case 'meta-keyword':
      case 'selector-tag':
        return const Color(0xFFE8821C); // ámbar (keywords)
      case 'string':
      case 'regexp':
      case 'symbol':
      case 'template-string':
      case 'addition':
      case 'attr':
      case 'attribute':
        return const Color(0xFF6BBF59); // verde (strings)
      case 'comment':
      case 'quote':
      case 'deletion':
        return const Color(0xFF7A7A7A); // gris (comentarios)
      case 'number':
        return const Color(0xFFB5CEA8); // verde suave (números)
      case 'title':
      case 'function':
      case 'section':
        return const Color(0xFFDCB67A); // ámbar suave (nombres/funciones)
      default:
        return null; // hereda el blanco base
    }
  }
}

List<String> _buildMetaLines(bool verbose, Map<String, dynamic> metadata) {
  if (!verbose) return const [];
  final lines = <String>['role: ${metadata['role'] ?? 'unknown'}'];
  for (final entry in metadata.entries) {
    if (entry.key == 'role' || entry.key == 'content') continue;
    final value = entry.value?.toString() ?? 'null';
    lines.add(
      '${entry.key}: ${value.length > 80 ? '${value.substring(0, 80)}…' : value}',
    );
  }
  return lines;
}

String? _formatMessageTimestamp(Map<String, dynamic> metadata) {
  final raw =
      metadata['created_at'] ?? metadata['timestamp'] ?? metadata['createdAt'];
  if (raw == null) return null;

  final double? value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw);
  } else {
    value = null;
  }
  if (value == null || value <= 0) return null;

  // The Gateway sends Unix timestamps in seconds (float), like
  // Session.started_at. Values >= 1e12 can only be milliseconds, so
  // accept both defensively.
  final milliseconds = value < 1e12 ? (value * 1000).round() : value.round();
  final dt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

class _LinkPreviewData {
  final String title;
  final String domain;

  _LinkPreviewData({required this.title, required this.domain});
}

class _LinkPreviewCard extends StatelessWidget {
  final _LinkPreviewData data;
  final String url;

  const _LinkPreviewCard({required this.data, required this.url});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return GestureDetector(
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
        ),
        child: Row(
          children: [
            Icon(Icons.link, size: 16, color: colors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.textPrimary),
                  ),
                  Text(
                    data.domain,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// On-demand link preview widget.
///
/// Shows a small "vista previa" chip first. Fetching only starts when the user
/// taps it — no network request is made automatically on render. Uses the
/// parent-level [linkCache] so repeated renders / re-builds never re-fetch.
class _LinkPreviewLoader extends StatefulWidget {
  final String url;
  final Map<String, _LinkPreviewData?> linkCache;
  final Future<void> Function(String url) fetchLinkPreview;

  const _LinkPreviewLoader({
    required this.url,
    required this.linkCache,
    required this.fetchLinkPreview,
  });

  @override
  State<_LinkPreviewLoader> createState() => _LinkPreviewLoaderState();
}

class _LinkPreviewLoaderState extends State<_LinkPreviewLoader> {
  bool _loading = false;
  bool _failed = false;

  Future<void> _onTapPreview() async {
    // Already cached (successfully or as null-sentinel) — trigger rebuild to
    // show result. The null-sentinel means an in-flight request was started
    // externally; treat as loading until the parent cache is populated.
    if (widget.linkCache.containsKey(widget.url)) {
      final cached = widget.linkCache[widget.url];
      if (cached != null) {
        setState(() {}); // force rebuild to show card
        return;
      }
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await widget.fetchLinkPreview(widget.url);
      if (!mounted) return;
      final result = widget.linkCache[widget.url];
      setState(() {
        _loading = false;
        _failed = result == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final cached = widget.linkCache[widget.url];

    // If we have a valid preview, show the full card.
    if (cached != null) {
      return _LinkPreviewCard(data: cached, url: widget.url);
    }

    // While loading, show a small inline indicator.
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: colors.textDisabled,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              Strings.of(context).chaLinkLoading,
              // A-112 (spec 028): texto informativo en textSecondary.
              style: TextStyle(fontSize: 11, color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    // After a failed fetch.
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          Strings.of(context).chaLinkFailed,
          // A-112 (spec 028): texto informativo en textSecondary.
          style: TextStyle(fontSize: 11, color: colors.textSecondary),
        ),
      );
    }

    // Default: show a discrete affordance chip.
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: GestureDetector(
        onTap: _onTapPreview,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link, size: 12, color: colors.textSecondary),
              const SizedBox(width: 4),
              Text(
                Strings.of(context).chaLinkPreview,
                // A-112 (spec 028): la acción "vista previa" es texto que hay
                // que poder leer — textSecondary (≥4.5:1).
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Render del Markdown del asistente expuesto para golden/widget tests.
///
/// Usa exactamente la misma configuración que [_AssistantMessage] (hoja de
/// estilo [_assistantSheet], code blocks vía [_PreCodeBuilder] y el
/// normalizador de streaming), para que las pruebas cubran la ruta real de
/// renderizado sin depender de un modelo/servidor.
@visibleForTesting
class AssistantMarkdownView extends StatelessWidget {
  final String data;
  final bool isStreaming;

  const AssistantMarkdownView({
    super.key,
    required this.data,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final operationalProjection = _projectOperationalArtifacts(context, data);
    // Misma ruta que el chat: separa razonamiento y normaliza el streaming sin
    // inventar jerarquías que el modelo no escribió.
    final split = splitReasoning(operationalProjection.visibleMarkdown);
    final blocks = split.answer.isEmpty
        ? const <Widget>[]
        : buildAssistantAnswerBlocks(
            split.answer,
            isStreaming: isStreaming,
            markdown: (d) => MarkdownBody(
              data: d,
              selectable: false,
              softLineBreak: false,
              styleSheet: _assistantSheet(theme, colors),
              builders: {'pre': _PreCodeBuilder()},
            ),
            callout: (b) =>
                CalloutCard(kind: b.kind, title: b.title, body: b.body),
            onLinkTap: (href) => _openMarkdownLink(context, href),
          );

    // Sin razonamiento y un único bloque: render idéntico al anterior (preserva
    // los goldens del caso markdown válido, donde la capa semántica es no-op).
    if (!split.hasReasoning) {
      if (blocks.isEmpty && !operationalProjection.hasTechnicalDetails) {
        return const SizedBox.shrink();
      }
      if (blocks.length == 1 && !operationalProjection.hasTechnicalDetails) {
        return ChatMessageSelectionArea(
          enabled: !isStreaming,
          child: blocks.first,
        );
      }
      return ChatMessageSelectionArea(
        enabled: !isStreaming,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ...blocks,
            if (operationalProjection.hasTechnicalDetails)
              _AssistantTechnicalDetails(
                details: operationalProjection.technicalDetails,
              ),
          ],
        ),
      );
    }
    return ChatMessageSelectionArea(
      enabled: !isStreaming,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ReasoningBlock(
            reasoning: split.reasoning,
            inProgress: split.reasoningInProgress,
          ),
          ...blocks,
          if (operationalProjection.hasTechnicalDetails)
            _AssistantTechnicalDetails(
              details: operationalProjection.technicalDetails,
            ),
        ],
      ),
    );
  }
}

MarkdownStyleSheet _assistantSheet(ThemeData theme, HermesThemeColors colors) {
  return MarkdownStyleSheet(
    p: theme.textTheme.bodyMedium?.copyWith(
      color: colors.textPrimary,
      fontSize: 15,
      height: 1.5,
    ),
    blockSpacing: 10,
    pPadding: const EdgeInsets.only(bottom: 2),
    code: TextStyle(
      backgroundColor: Colors.transparent,
      fontFamily: 'monospace',
      fontSize: 13,
      color: colors.textPrimary.withValues(alpha: 0.92),
    ),
    codeblockDecoration: BoxDecoration(
      color: colors.surfaceVariant,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
    ),
    // El padding interno lo gestiona _CodeBlockWrapper (necesita que la
    // cabecera de lenguaje quede a ras del borde); aquí lo anulamos.
    codeblockPadding: EdgeInsets.zero,
    // Enlaces en el color de contraste del tema (como en el resto de la app).
    a: TextStyle(
      color: colors.secondary,
      decoration: TextDecoration.underline,
      decorationColor: colors.secondary.withValues(alpha: 0.5),
    ),
    // Jerarquía compacta para móvil: los encabezados deben ordenar la respuesta
    // sin convertirse en carteles ni romper la densidad del chat.
    h1: theme.textTheme.titleLarge?.copyWith(
      color: colors.textPrimary,
      fontSize: 18,
      height: 1.32,
      fontWeight: FontWeight.w700,
    ),
    h2: theme.textTheme.titleMedium?.copyWith(
      color: colors.textPrimary,
      fontSize: 16.5,
      height: 1.35,
      fontWeight: FontWeight.w700,
    ),
    h3: theme.textTheme.bodyLarge?.copyWith(
      color: colors.textPrimary,
      fontSize: 15.5,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    h4: theme.textTheme.bodyLarge?.copyWith(
      color: colors.textPrimary,
      fontSize: 15,
      height: 1.45,
      fontWeight: FontWeight.w600,
    ),
    h5: theme.textTheme.bodyMedium?.copyWith(
      color: colors.textPrimary,
      fontSize: 15,
      height: 1.45,
      fontWeight: FontWeight.w600,
    ),
    h6: theme.textTheme.bodyMedium?.copyWith(
      color: colors.textPrimary,
      fontSize: 15,
      height: 1.45,
      fontWeight: FontWeight.w600,
    ),
    h1Padding: const EdgeInsets.only(top: 11, bottom: 3),
    h2Padding: const EdgeInsets.only(top: 10, bottom: 3),
    h3Padding: const EdgeInsets.only(top: 8, bottom: 2),
    h4Padding: const EdgeInsets.only(top: 8, bottom: 2),
    h5Padding: const EdgeInsets.only(top: 7, bottom: 2),
    h6Padding: const EdgeInsets.only(top: 7, bottom: 2),
    blockquote: TextStyle(
      color: colors.textSecondary,
      fontStyle: FontStyle.italic,
    ),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: colors.divider.withValues(alpha: 0.65),
          width: 2,
        ),
      ),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 2, 0, 2),
    listIndent: 16,
    listBulletPadding: const EdgeInsets.only(right: 6),
    listBullet: theme.textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      height: 1.5,
      color: colors.textPrimary,
    ),
    // Tablas legibles: bordes sutiles, cabecera marcada y celdas con aire.
    tableHead: theme.textTheme.bodyMedium?.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w700,
    ),
    tableBody: theme.textTheme.bodyMedium?.copyWith(color: colors.textPrimary),
    tableBorder: TableBorder.all(
      color: colors.divider.withValues(alpha: 0.45),
      width: 1,
    ),
    // Ajusta cada columna a su contenido en vez de comprimirlas por igual; con
    // anchos intrínsecos flutter_markdown envuelve la tabla en scroll
    // horizontal, así una tabla ancha se desplaza en lugar de partir el texto
    // letra a letra en pantallas estrechas.
    tableColumnWidth: const IntrinsicColumnWidth(),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tableCellsDecoration: BoxDecoration(
      color: colors.surfaceVariant.withValues(alpha: 0.25),
    ),
    // El énfasis hereda tamaño y color del bloque. Así una palabra en negrita
    // dentro de un heading no fragmenta visualmente el título.
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: const TextStyle(fontWeight: FontWeight.w700),
  );
}

const double _dictationComposerHeight = 48;
const double _dictationWaveHeight = 28;
