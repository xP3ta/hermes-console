import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../screens/image_viewer_screen.dart';
import '../../theme/app_theme.dart';
import '../../utils/assistant_content.dart';
import '../../utils/byte_bounded_lru_cache.dart';
import '../../utils/markdown_math.dart';
import '../../utils/semantic_markdown.dart';
import '../../utils/streaming_normalizer.dart';
import '../../utils/transport_privacy.dart';
import '../callout_card.dart';
import '../hermes_file_tree.dart';
import '../hermes_notice.dart';
import '../markdown_table.dart';
import 'chat_message_selection_area.dart';

/// Render compartido del Markdown de las respuestas del chat (spec 070, T102).
///
/// Es la misma ruta que usa el chat principal: hoja de estilo compacta,
/// bloques de código con cabecera/copiar y resaltado, tablas propias, enlaces
/// filtrados por esquema e imágenes remotas bajo demanda. No depende de
/// `ActiveChat`: basta un `String` de Markdown y el tema actual.

/// Markdown completo de una respuesta: aplica las reparaciones conservadoras
/// de estructura, parte las tablas GFM en [MarkdownTable] y pinta el resto con
/// [ChatMarkdownBlock]. Opcionalmente envuelve el resultado en una
/// [ChatMessageSelectionArea] (selección parcial sin `SelectableText`).
class ChatMarkdownBody extends StatelessWidget {
  const ChatMarkdownBody({
    super.key,
    required this.data,
    this.isStreaming = false,
    this.selectable = true,
    this.selectionIdentity,
    this.onLinkTap,
  });

  /// Markdown tal cual llegó (sin normalizar).
  final String data;

  /// Cierra vallas/énfasis a medias del bloque final mientras crece.
  final bool isStreaming;

  /// Envuelve el cuerpo en una [ChatMessageSelectionArea] (deshabilitada
  /// durante el streaming).
  final bool selectable;

  /// Identidad del mensaje; al cambiar se limpia la selección previa.
  final Object? selectionIdentity;

  /// Manejador de enlaces. Por defecto [openChatMarkdownLink].
  final void Function(String? href)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    void tap(String? href) => onLinkTap != null
        ? onLinkTap!(href)
        : unawaited(openChatMarkdownLink(context, href));
    final blocks = data.trim().isEmpty
        ? const <Widget>[]
        : buildAssistantAnswerBlocks(
            data,
            isStreaming: isStreaming,
            markdown: (d) => ChatMarkdownBlock(data: d, onLinkTap: tap),
            callout: (b) =>
                CalloutCard(kind: b.kind, title: b.title, body: b.body),
            onLinkTap: tap,
          );
    if (blocks.isEmpty) return const SizedBox.shrink();
    final Widget body = blocks.length == 1
        ? blocks.first
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: blocks,
          );
    if (!selectable) return body;
    return ChatMessageSelectionArea(
      enabled: !isStreaming,
      selectionIdentity: selectionIdentity,
      child: body,
    );
  }
}

/// Un único `MarkdownBody` ya normalizado, con la presentación del chat:
/// [assistantMarkdownStyleSheet], code blocks de Console, imágenes remotas
/// bajo demanda y saltos simples tratados como espacio (CommonMark).
class ChatMarkdownBlock extends StatelessWidget {
  const ChatMarkdownBlock({
    super.key,
    required this.data,
    this.onLinkTap,
    this.styleSheet,
  });

  final String data;

  /// Manejador de enlaces. Por defecto [openChatMarkdownLink].
  final void Function(String? href)? onLinkTap;

  /// Hoja alternativa; por defecto [assistantMarkdownStyleSheet].
  final MarkdownStyleSheet? styleSheet;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return MarkdownBody(
      data: data,
      selectable: false,
      // CommonMark conserva los párrafos (líneas en blanco) y trata un salto
      // simple como espacio. Mostrar cada salto interno del modelo partía
      // frases después de paréntesis y hacía la respuesta demasiado estrecha.
      softLineBreak: false,
      onTapLink: (text, href, title) => onLinkTap != null
          ? onLinkTap!(href)
          : openChatMarkdownLink(context, href),
      sizedImageBuilder: (config) => ChatGatedImage(
        uri: config.uri,
        width: config.width,
        height: config.height,
        colors: colors,
      ),
      styleSheet: styleSheet ?? assistantMarkdownStyleSheet(context, data),
      builders: {'pre': ChatCodeBlockBuilder()},
    );
  }
}

/// Entradas actuales de la caché de resaltado de bloques de código.
int chatCodeHighlightCacheLength() =>
    _CodeBlockWrapperState._highlightCache.length;

/// Esquemas permitidos para un enlace del markdown del chat. Pura (sin I/O)
/// para poder testearla: bloquea `intent://`, `file://`, `tel:` inyectado,
/// etc. — el `href` puede venir de un modelo remoto, no es de confiar sin
/// filtrar. Público para test unitario (`test/chat_markdown_link_test.dart`).
bool isAllowedMarkdownLinkScheme(String? href) {
  const allowedSchemes = {'http', 'https', 'mailto'};
  final uri = href == null ? null : Uri.tryParse(href);
  return uri != null && allowedSchemes.contains(uri.scheme);
}

/// Abre un enlace tocado dentro del markdown del chat (usuario o agente),
/// validando el esquema con [isAllowedMarkdownLinkScheme] antes de lanzarlo.
Future<void> openChatMarkdownLink(BuildContext context, String? href) async {
  if (!isAllowedMarkdownLinkScheme(href)) {
    debugPrint('Enlace de markdown bloqueado (esquema no permitido): $href');
    if (context.mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).chaLinkSchemeBlocked),
          duration: const Duration(seconds: 2),
        ),
        kind: HermesNoticeKind.warning,
      );
    }
    return;
  }
  try {
    await launchUrl(Uri.parse(href!), mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('No se pudo abrir el enlace de markdown ($href): $e');
  }
}

/// Construye la respuesta del asistente respetando la estructura que escribió el
/// modelo. La ruta compartida por el chat y [AssistantMarkdownView] solo aplica
/// reparaciones sintácticas conservadoras; no inventa títulos, callouts ni chips
/// inline a partir de prosa corriente.
///
/// [markdown] recibe el texto normalizado para un MarkdownBody. [callout] se
/// conserva en la firma por compatibilidad con los hosts existentes, pero los
/// callouts solo podrán volver a la ruta normal con una sintaxis explícita.
List<Widget> buildAssistantAnswerBlocks(
  String answer, {
  required bool isStreaming,
  bool structured = false,
  required Widget Function(String data) markdown,
  required Widget Function(CalloutContentBlock block) callout,
  void Function(String? href)? onLinkTap,
}) {
  // Conserva la estructura escrita por el modelo. Solo normalizamos comandos
  // inequívocos y encabezados Markdown pegados (`##Título`), sin convertir
  // prosa corta, etiquetas con `:` ni líneas sueltas en títulos o listas.
  final protectedAnswer = protectMarkdownMath(answer);
  final enhanced = structured
      ? protectedAnswer
      : prepareAssistantAnswerStructure(protectedAnswer);
  final blocks = enhanced.trim().isEmpty
      ? const <ContentBlock>[]
      : <ContentBlock>[MarkdownContentBlock(enhanced)];
  final widgets = <Widget>[];
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 4));
    if (b is MarkdownContentBlock) {
      // El streaming (cierre de vallas/backticks a medias) solo aplica al
      // último bloque, que es el que sigue creciendo.
      final streamingTail = isStreaming && i == blocks.length - 1;
      // Escapa primero los globs de rutas: sus asteriscos son literales y no
      // deben participar en el balanceo visual de énfasis Markdown. Las rutas
      // normales permanecen como texto; solo el backtick explícito crea código.
      final escaped = escapePathGlobs(b.text);
      // Durante el streaming se normalizan también los bloques cerrados para
      // que un delimitador huérfano como `**` no llegue como texto visible. El
      // bloque terminal se pinta tal cual llegó del servidor.
      final data = normalizeStreamingMarkdown(
        escaped,
        isStreaming: streamingTail,
      );
      // Las tablas GFM completas se pintan con un render propio (limpio, con
      // columnas dimensionadas y scroll horizontal) en vez del MarkdownBody, que
      // las descuadra. El bloque en streaming NO se trocea: una tabla a medias
      // parpadearía al llegar las filas, así que cae al Markdown hasta cerrar.
      if (streamingTail) {
        widgets.add(markdown(data));
      } else {
        var firstSeg = true;
        for (final seg in splitAnswerTables(data)) {
          if (!firstSeg) widgets.add(const SizedBox(height: 4));
          firstSeg = false;
          if (seg is TableSegment) {
            widgets.add(MarkdownTable(rows: seg.rows, onLinkTap: onLinkTap));
          } else if (seg is MarkdownSegment) {
            widgets.add(markdown(seg.text));
          }
        }
      }
    } else if (b is CalloutContentBlock) {
      widgets.add(callout(b));
    }
  }
  return widgets;
}

/// Primera fase pura del render del asistente. Separarla permite ejecutarla una
/// sola vez antes de dividir una respuesta larga en hijos virtualizados; la
/// ruta habitual sigue llamándola desde [buildAssistantAnswerBlocks].
String prepareAssistantAnswerStructure(String answer) =>
    enhanceCommandBlocks(tidyAssistantMarkdown(flattenInlineHtml(answer)));

void validateRemoteChatImageTransport(Uri uri) {
  TransportPrivacy.requireAllowed(uri.toString());
}

Uri validateRemoteChatImageRedirect(Uri current, String location) {
  final target = current.resolve(location);
  validateRemoteChatImageTransport(target);
  if (target.origin != current.origin) {
    throw ArgumentError.value(
      target,
      'location',
      'Redirect cross-origin no permitido',
    );
  }
  return target;
}

/// Imagen incrustada en una respuesta del agente. Las imágenes remotas
/// (`http`/`https`) NO se cargan solas — cargarlas automáticamente sería un
/// beacon de IP hacia el host que las sirve, disparado por texto que puede
/// venir de un modelo remoto. Se muestra un placeholder con el dominio y
/// solo se pide la imagen cuando el usuario la toca. Las URIs locales
/// (`data:`/`file:`, si las hubiera) se cargan igual que antes.
class ChatGatedImage extends StatefulWidget {
  final Uri uri;
  final double? width;
  final double? height;
  final HermesThemeColors colors;

  const ChatGatedImage({
    super.key,
    required this.uri,
    required this.colors,
    this.width,
    this.height,
  });

  @override
  State<ChatGatedImage> createState() => _ChatGatedImageState();
}

class _ChatGatedImageState extends State<ChatGatedImage> {
  bool _loadRequested = false;
  bool _loading = false;
  Uint8List? _bytes;
  Object? _loadError;
  final Object _heroTag = Object();

  static const int _maxRemoteImageBytes = 20 * 1024 * 1024;

  bool get _isRemote =>
      widget.uri.scheme == 'http' || widget.uri.scheme == 'https';

  Future<void> _loadRemoteImage() async {
    if (_loading) return;
    setState(() {
      _loadRequested = true;
      _loading = true;
      _loadError = null;
    });
    try {
      final client = http.Client();
      try {
        var current = widget.uri;
        http.StreamedResponse? response;
        for (var redirects = 0; redirects <= 5; redirects++) {
          validateRemoteChatImageTransport(current);
          final request = http.Request('GET', current)..followRedirects = false;
          final candidate = await client
              .send(request)
              .timeout(const Duration(seconds: 15));
          if (!candidate.isRedirect) {
            response = candidate;
            break;
          }
          final location = candidate.headers['location'];
          await candidate.stream.listen((_) {}).cancel();
          if (location == null || location.trim().isEmpty || redirects == 5) {
            throw const HttpException('Redirect de imagen no permitido');
          }
          current = validateRemoteChatImageRedirect(current, location);
        }
        if (response == null) {
          throw const HttpException('Demasiados redirects de imagen');
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        final type = (response.headers['content-type'] ?? '').toLowerCase();
        if (!type.startsWith('image/')) {
          throw const FormatException('The server did not return an image');
        }
        final declared = response.contentLength;
        if (declared != null && declared > _maxRemoteImageBytes) {
          throw const FormatException('Imagen demasiado grande');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 15),
        )) {
          if (builder.length + chunk.length > _maxRemoteImageBytes) {
            throw const FormatException('Imagen demasiado grande');
          }
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        if (!_hasSupportedImageMagic(bytes)) {
          throw const FormatException('Formato de imagen no permitido');
        }
        if (!mounted) return;
        setState(() => _bytes = bytes);
      } finally {
        client.close();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static bool _hasSupportedImageMagic(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return true;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return true;
    }
    return bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    if (_isRemote && !_loadRequested) {
      final host = widget.uri.host.isNotEmpty
          ? widget.uri.host
          : widget.uri.toString();
      final domain = host.length > 28 ? '${host.substring(0, 28)}…' : host;
      // A-115 (spec 028): la tarjeta "tocar para cargar" expone que es
      // accionable y de dónde viene la imagen (antes TalkBack solo leía el
      // dominio suelto).
      return Semantics(
        button: true,
        label: Strings.of(context).chaLoadImageFrom(domain),
        child: GestureDetector(
          onTap: _loadRemoteImage,
          child: Container(
            width: widget.width,
            height: widget.height ?? 80,
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.image_outlined,
                  color: colors.textDisabled,
                  size: 26,
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    domain,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    // A-112 (spec 028): texto informativo en textSecondary
                    // (textDisabled no llega a 4.5:1).
                    style: TextStyle(fontSize: 10, color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_isRemote && (_loading || _loadError != null)) {
      return GestureDetector(
        onTap: _loading ? null : _loadRemoteImage,
        child: Container(
          width: widget.width,
          height: widget.height ?? 80,
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
          ),
          child: Center(
            child: _loading
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.refresh_rounded,
                    color: colors.textSecondary,
                    size: 28,
                  ),
          ),
        ),
      );
    }
    // A-115 (spec 028): anuncia imagen + acción de ampliar para TalkBack.
    final imgLabel = widget.uri.host.isNotEmpty
        ? Strings.of(context).chatImageFromHostTapToEnlarge(widget.uri.host)
        : Strings.of(context).chatImageTapToEnlarge;
    return Semantics(
      image: true,
      button: true,
      label: imgLabel,
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(
              imageUrl: widget.uri.toString(),
              imageBytes: _bytes,
              heroTag: _heroTag,
            ),
            fullscreenDialog: true,
          ),
        ),
        child: Hero(
          tag: _heroTag,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _bytes != null
                ? Image.memory(
                    _bytes!,
                    width: widget.width,
                    height: widget.height,
                    fit: BoxFit.cover,
                    cacheWidth: 1600,
                  )
                : Image.network(
                    widget.uri.toString(),
                    width: widget.width,
                    height: widget.height,
                    fit: BoxFit.cover,
                    cacheWidth: 1600,
                    errorBuilder: (context, error, _) => Container(
                      height: 80,
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: colors.divider.withValues(alpha: 0.55),
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: colors.textDisabled,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

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

/// Builder de `pre` del chat: árbol de ficheros, prosa o bloque de código.
class ChatCodeBlockBuilder extends MarkdownElementBuilder {
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
  // Claves y spans son código de conversaciones privadas: se vacía con los
  // cambios de autoridad (borrar conexión, revocar keys, cambiar perfil).
  static final LinkedHashMap<(String, String), List<TextSpan>?>
  _highlightCache = _createHighlightCache();

  static LinkedHashMap<(String, String), List<TextSpan>?>
  _createHighlightCache() {
    // ignore: prefer_collection_literals
    final cache = LinkedHashMap<(String, String), List<TextSpan>?>();
    PrivateRenderCaches.register(cache.clear);
    return cache;
  }

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

// flutter_markdown constrains the marker to listIndent (padding is separate).
// Measure the rendered ordinals, including CommonMark's implicit increments,
// rather than guessing a fixed gutter or suppressing wrapping/clipping.
double _assistantListIndent(
  BuildContext context,
  String data,
  TextStyle style,
) {
  var width = 16.0;
  final painter = TextPainter(
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  );
  void measure(String marker) {
    painter.text = TextSpan(text: marker, style: style);
    painter.layout();
    width = math.max(width, painter.width.ceilToDouble());
  }

  void visit(md.Node node) {
    if (node is! md.Element) return;
    if (node.tag == 'ol') {
      var ordinal = int.tryParse(node.attributes['start'] ?? '') ?? 1;
      for (final child in node.children ?? const <md.Node>[]) {
        if (child is md.Element && child.tag == 'li') {
          measure('${ordinal++}.');
        }
      }
    }
    for (final child in node.children ?? const <md.Node>[]) {
      visit(child);
    }
  }

  try {
    measure('•');
    for (final node in md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ).parseLines(data.split('\n'))) {
      visit(node);
    }
    return width;
  } finally {
    painter.dispose();
  }
}

/// Hoja de estilo del Markdown del asistente en el chat principal. [data] se
/// usa para medir el sangrado de las listas ordenadas.
MarkdownStyleSheet assistantMarkdownStyleSheet(
  BuildContext context,
  String data,
) {
  final theme = Theme.of(context);
  final colors = theme.hermes;
  final listBullet = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: 15,
    height: 1.5,
    color: colors.textPrimary,
  );
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
    listIndent: _assistantListIndent(context, data, listBullet),
    listBulletPadding: const EdgeInsets.only(right: 6),
    listBullet: listBullet,
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
