// Attachment parsing and image surfaces, including the pending-attachment
// limit rules and generated-image slots.
part of 'chat_screen.dart';

enum PendingAttachmentLimitViolation { invalid, item, batch }

/// Clasifica el motivo exacto por el que una selección no cabe en el composer.
///
/// Los límites son inclusivos: 8 MiB por elemento y 24 MiB por lote siguen
/// siendo válidos. Mantener esta decisión pura evita mostrar el límite de un
/// fichero cuando el problema real es la suma del lote.
@visibleForTesting
PendingAttachmentLimitViolation? pendingAttachmentLimitViolation({
  required int sizeBytes,
  required int itemLimit,
  required int currentBatchBytes,
}) {
  if (sizeBytes <= 0) return PendingAttachmentLimitViolation.invalid;
  if (sizeBytes > itemLimit) return PendingAttachmentLimitViolation.item;
  if (currentBatchBytes + sizeBytes > AttachmentUploader.maxBatchBytes) {
    return PendingAttachmentLimitViolation.batch;
  }
  return null;
}

String _attachmentLimitLabel(int bytes) => bytes >= 1024 * 1024
    ? '${bytes ~/ (1024 * 1024)} MB'
    : '${bytes ~/ 1024} KB';

/// Parte Markdown únicamente en límites que conservan el mismo árbol GFM.
///
/// Hermes Desktop primero lexea la respuesta y entrega al renderer bloques
/// sintácticos completos. En móvil seguimos virtualizando respuestas largas,
/// pero comprobamos con el mismo parser que usa [MarkdownBody] que renderizar
/// las dos mitades por separado sea equivalente a renderizar el resto entero.
/// Así una línea en mitad de `**énfasis**`, un enlace, una lista o una cita no
/// puede convertirse en frontera y dejar marcadores Markdown visibles.
///
/// Es pública solo para las regresiones de scroll. No reescribe el contenido:
/// los saltos que delimitan dos partes quedan al final de la anterior. Si no
/// existe una frontera segura, el bloque se conserva entero aunque supere el
/// máximo; la corrección visual manda sobre la granularidad de virtualización.
@visibleForTesting
List<String> splitAssistantMarkdownForViewport(
  String markdown, {
  int targetChars = _assistantChunkTargetChars,
  int maxChars = _assistantChunkMaxChars,
}) {
  assert(targetChars > 0);
  assert(maxChars >= targetChars);
  if (markdown.length <= maxChars) return [markdown];

  final blockBreaks = <int>[];
  var cursor = 0;
  String? fenceChar;
  var fenceLength = 0;
  while (cursor < markdown.length) {
    final newline = markdown.indexOf('\n', cursor);
    final lineEnd = newline < 0 ? markdown.length : newline;
    final breakOffset = newline < 0 ? markdown.length : newline + 1;
    final line = markdown.substring(cursor, lineEnd);
    final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      final suffix = fence.group(2)!;
      if (fenceChar == null) {
        fenceChar = marker[0];
        fenceLength = marker.length;
      } else if (marker[0] == fenceChar &&
          marker.length >= fenceLength &&
          suffix.trim().isEmpty) {
        fenceChar = null;
        fenceLength = 0;
      }
    }
    if (fenceChar == null && line.trim().isEmpty) {
      blockBreaks.add(breakOffset);
    }
    cursor = breakOffset;
  }

  if (blockBreaks.isEmpty) return [markdown];

  // markdownToHtml usa el mismo Document + ExtensionSet GFM que
  // flutter_markdown. Comparar su salida evita reimplementar parcialmente la
  // gramática CommonMark (listas flojas, referencias, blockquotes, tablas…).
  final signatures = <String, String?>{};
  String? signature(String source) => signatures.putIfAbsent(source, () {
    try {
      return md.markdownToHtml(
        source,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      );
    } catch (_) {
      return null;
    }
  });

  bool preservesRendering(int start, int end) {
    final rest = markdown.substring(start);
    final whole = signature(rest);
    if (whole == null) return false;
    final left = signature(markdown.substring(start, end));
    final right = signature(markdown.substring(end));
    return left != null && right != null && '$left$right' == whole;
  }

  Iterable<int> candidatesFor(int start) sync* {
    final target = start + targetChars;
    final upper = math.min(start + maxChars, markdown.length);

    // Primero, una frontera cercana al objetivo sin exceder el máximo.
    for (final offset in blockBreaks) {
      if (offset >= target && offset <= upper && offset < markdown.length) {
        yield offset;
      }
    }
    // Si el bloque anterior es algo menor también resulta una buena unidad.
    for (final offset in blockBreaks.reversed) {
      if (offset <= start + (targetChars ~/ 2)) break;
      if (offset < target && offset > start && offset < markdown.length) {
        yield offset;
      }
    }
    // Un bloque Markdown indivisible puede ser mayor que el límite. Esperamos
    // a su siguiente frontera real en vez de cortarlo por una línea cualquiera.
    for (final offset in blockBreaks) {
      if (offset > upper && offset < markdown.length) yield offset;
    }
  }

  final chunks = <String>[];
  var start = 0;
  while (markdown.length - start > maxChars) {
    int? end;
    for (final candidate in candidatesFor(start)) {
      if (preservesRendering(start, candidate)) {
        end = candidate;
        break;
      }
    }
    if (end == null || end <= start || end >= markdown.length) break;
    chunks.add(markdown.substring(start, end));
    start = end;
  }
  if (start < markdown.length) chunks.add(markdown.substring(start));
  return chunks.where((chunk) => chunk.isNotEmpty).toList(growable: false);
}

final class _StructuredGeneratedImage {
  final GeneratedImageSourceKind kind;
  final String source;
  final String? basename;
  final String toolCallId;
  final List<String> echoSources;

  const _StructuredGeneratedImage({
    required this.kind,
    required this.source,
    this.basename,
    required this.toolCallId,
    required this.echoSources,
  });

  factory _StructuredGeneratedImage.textPath(String basename) =>
      _StructuredGeneratedImage(
        kind: GeneratedImageSourceKind.serverCache,
        source: basename,
        basename: basename,
        toolCallId: 'text',
        echoSources: const [],
      );

  ValueKey<String> get widgetKey {
    final digest = sha256
        .convert(utf8.encode('${kind.name}\u0000$source\u0000$toolCallId'))
        .toString()
        .substring(0, 24);
    return ValueKey<String>('generated-image-$digest');
  }
}

final RegExp _generatedImageBasenameRe = RegExp(
  r'^[A-Za-z0-9._-]+\.(?:png|jpe?g|webp)$',
  caseSensitive: false,
);

List<_StructuredGeneratedImage> _structuredGeneratedImages(
  Map<String, dynamic> metadata,
) {
  final raw = metadata['_generatedImages'];
  if (raw is! List) return const [];
  final refs = <_StructuredGeneratedImage>[];
  final seen = <String>{};
  for (final entry in raw.whereType<Map>()) {
    final toolCallId = entry['tool_call_id'];
    if (toolCallId is! String || toolCallId.trim().isEmpty) {
      continue;
    }
    final rawKind = entry['kind'];
    late final GeneratedImageSourceKind kind;
    late final String source;
    String? basename;
    if (rawKind == GeneratedImageSourceKind.https.name) {
      final candidate = entry['source'];
      if (candidate is! String) continue;
      final parsed = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'image': candidate,
      });
      if (parsed.isEmpty ||
          parsed.single.kind != GeneratedImageSourceKind.https) {
        continue;
      }
      kind = GeneratedImageSourceKind.https;
      source = parsed.single.source;
    } else if (rawKind == null ||
        rawKind == GeneratedImageSourceKind.serverCache.name) {
      final candidate = entry['basename'];
      if (candidate is! String ||
          !_generatedImageBasenameRe.hasMatch(candidate)) {
        continue;
      }
      kind = GeneratedImageSourceKind.serverCache;
      basename = candidate;
      final candidateSource = entry['source'];
      source = candidateSource is String && candidateSource.trim().isNotEmpty
          ? candidateSource.trim()
          : candidate;
    } else {
      continue;
    }
    if (!seen.add('$toolCallId\u0000$source')) continue;
    final echoes = entry['echo_sources'];
    refs.add(
      _StructuredGeneratedImage(
        kind: kind,
        source: source,
        basename: basename,
        toolCallId: toolCallId,
        echoSources: echoes is List
            ? List<String>.unmodifiable(
                echoes.whereType<String>().where((value) => value.isNotEmpty),
              )
            : const [],
      ),
    );
  }
  return List<_StructuredGeneratedImage>.unmodifiable(refs);
}

String _stripStructuredGeneratedImageEchoes(
  String text,
  List<_StructuredGeneratedImage> refs,
) => refs.isEmpty
    ? text
    : GeneratedImageService.stripImageEchoes(
        text,
        echoSources: refs.expand((ref) => ref.echoSources),
      );

/// Adjunto detectado en el texto de un mensaje de usuario.
class _ParsedAttachment {
  final String name;
  final String sizeLabel;

  /// Referencia versionada al almacén privado actual. Se resuelve y verifica
  /// únicamente al renderizar/abrir el chip.
  final AttachmentHistoryReference? historyReference;

  /// Ruta local persistente de la imagen, si el adjunto era una imagen. Permite
  /// leer historiales legacy `⟦img:...⟧` sin romper miniaturas existentes.
  final String? imagePath;
  const _ParsedAttachment(
    this.name,
    this.sizeLabel, {
    this.historyReference,
    this.imagePath,
  });
}

/// Separa el marcador de adjunto `[📎 nombre · tamaño]` (y la línea de ruta
/// interna, que es para el agente) del texto visible del usuario. Permite
/// renderizar el adjunto como tarjeta en vez de texto crudo.
/// Quita el preámbulo de sistema que el cron antepone al prompt de un job
/// ("[IMPORTANT: You are running as a scheduled cron job … [SILENT] …]"). Es
/// ruido de sistema para el agente; no debe verse en el chat. El prompt real va
/// tras el doble salto de línea (o tras el cierre del bloque).
String _stripCronPreamble(String raw) {
  final t = raw.trimLeft();
  final lower = t.toLowerCase();
  final looksCron =
      lower.contains('cron') ||
      lower.contains('[silent]') ||
      lower.contains('delivery:') ||
      lower.contains('scheduled') ||
      lower.contains('invoked');
  if (t.startsWith('[IMPORTANT:') && looksCron) {
    final sep = t.indexOf('\n\n');
    if (sep >= 0) return t.substring(sep + 2).trimLeft();
    final close = t.lastIndexOf(']');
    if (close >= 0 && close < t.length - 1) {
      return t.substring(close + 1).trimLeft();
    }
    // Todo (o el trozo recibido) es preámbulo de sistema: nada que mostrar.
    return '';
  }
  return raw;
}

/// Quita el resumen de COMPACTACIÓN de contexto que el gateway inyecta como
/// "mensaje de usuario" cuando la conversación se hace larga: arranca con
/// `[CONTEXT COMPACTION — REFERENCE ONLY]` y va hasta `--- END OF CONTEXT
/// SUMMARY … ---`. Es un handoff interno (no es del usuario): un muro de 17 KB
/// con "## Historical Task Snapshot", reglas de compactación, etc. Devuelve lo
/// que haya DESPUÉS del resumen (el mensaje real, si lo hay) o '' si todo es
/// resumen.
String _stripContextCompaction(String raw) {
  final t = raw.trimLeft();
  if (!t.startsWith('[CONTEXT COMPACTION')) return raw;
  final end = RegExp(
    r'---\s*END OF CONTEXT SUMMARY.*?---',
    caseSensitive: false,
  ).firstMatch(t);
  if (end != null) return t.substring(end.end).trim();
  return '';
}

/// Nombre de la skill si [raw] es la invocación de una skill (el primer
/// "mensaje" es el blob de sistema con el YAML de la skill), o null.
String? _invokedSkillName(String raw) {
  final m = RegExp(
    r'invoked the "([^"]+)" skill',
    caseSensitive: false,
  ).firstMatch(raw);
  return m?.group(1);
}

/// Si el "mensaje de usuario" es en realidad un BLOB de sistema de un job/skill
/// (no algo que escribió el usuario), devuelve una etiqueta limpia para el chip;
/// si no, null (mensaje normal, incl. un job de cron con prompt real visible).
/// El dispatcher del Kanban arranca el worker con el prompt interno
/// `work kanban task t_<id>`. No es un mensaje del usuario: se muestra como
/// chip limpio "Tarea del Kanban" (el id crudo no dice nada).
final RegExp _kanbanWorkRe = RegExp(
  r'^\s*work kanban task\s+t_\w+',
  caseSensitive: false,
);

String? _jobChipLabel(String raw) {
  if (_kanbanWorkRe.hasMatch(raw)) return 'Tarea del Kanban';
  final skill = _invokedSkillName(raw);
  if (skill != null) return 'Skill · $skill';
  final t = raw.trimLeft();
  // Handoff de compactación sin mensaje real detrás → chip discreto.
  if (t.startsWith('[CONTEXT COMPACTION') &&
      _stripContextCompaction(raw).trim().isEmpty) {
    return 'Contexto previo';
  }
  final lower = t.toLowerCase();
  final looksJob =
      t.startsWith('[IMPORTANT:') &&
      (lower.contains('cron') ||
          lower.contains('scheduled') ||
          lower.contains('[silent]') ||
          lower.contains('delivery:') ||
          lower.contains('invoked'));
  if (looksJob && _stripCronPreamble(raw).trim().isEmpty) {
    return 'Tarea programada';
  }
  return null;
}

({String title, String? detail, IconData icon})?
_timelineSystemEventPresentation(
  BuildContext context,
  Map<String, dynamic> message,
) {
  final kind = message['display_kind']?.toString().trim() ?? '';
  if (kind.isEmpty) return null;
  final strings = Strings.of(context);
  switch (kind) {
    case 'async_delegation_complete':
      final rawMetadata = message['display_metadata'];
      final metadata = rawMetadata is Map ? rawMetadata : const {};
      final taskCount = metadata['task_count'];
      final completedCount = metadata['completed_count'];
      final failedCount = metadata['failed_count'];
      final durationSeconds = metadata['duration_seconds'];
      final count = taskCount is int
          ? taskCount
          : completedCount is int
          ? completedCount
          : null;
      final details = <String>[
        if (count != null) strings.chaBackgroundAgentsFinished(count),
        if (failedCount is int && failedCount > 0)
          strings.chaBackgroundAgentsFailed(failedCount),
        if (durationSeconds is num)
          _compactTimelineDuration(durationSeconds.toDouble()),
      ];
      return (
        title: strings.chaBackgroundWorkTitle,
        detail: details.isEmpty
            ? strings.chaBackgroundWorkFinished
            : details.join(' · '),
        icon: Icons.hub_outlined,
      );
    case 'model_switch':
      return (
        title: strings.chaTimelineModelChanged,
        detail: null,
        icon: Icons.swap_horiz_rounded,
      );
    case 'auto_continue':
      return (
        title: strings.chaTimelineAutoContinued,
        detail: null,
        icon: Icons.replay_rounded,
      );
    default:
      return (
        title: strings.chaTimelineSystemEvent,
        detail: null,
        icon: Icons.info_outline_rounded,
      );
  }
}

String _compactTimelineDuration(double seconds) {
  final totalSeconds = seconds.round();
  if (totalSeconds < 60) return '$totalSeconds s';
  final minutes = totalSeconds ~/ 60;
  final remainder = totalSeconds % 60;
  return remainder == 0 ? '$minutes min' : '$minutes min $remainder s';
}

AssistantOperationalProjection _projectOperationalArtifacts(
  BuildContext context,
  String markdown,
) {
  final strings = Localizations.of<Strings>(context, Strings);
  final isSpanish = Localizations.maybeLocaleOf(context)?.languageCode == 'es';
  return projectAssistantOperationalArtifacts(
    markdown,
    subagentLabel:
        strings?.subagentActivityItem ??
        (index) => isSpanish ? 'Subagente $index' : 'Subagent $index',
    resultLabel: strings?.commonResult ?? (isSpanish ? 'Resultado' : 'Result'),
  );
}

({List<_ParsedAttachment> attachments, String text}) _parseUserContent(
  String raw,
) {
  // Quita los blobs de SISTEMA que no son del usuario: preámbulo de cron/skill y
  // el resumen de compactación de contexto. Si tras ellos hay un mensaje real,
  // se muestra ese; si no, el llamador ya lo habrá pintado como chip.
  raw = Session.stripTodoContinuation(
    _stripContextCompaction(_stripCronPreamble(raw)),
  );
  // Extrae primero el marcador actual, versionado y sin ruta absoluta. Los
  // formatos `⟦img:...⟧` se conservan solo para historiales antiguos.
  final historyReferences = <int, AttachmentHistoryReference>{};
  final indexedImagePaths = <int, String>{};
  final legacyImagePaths = <String>[];
  final indexedImgRe = RegExp(r'^⟦img:(\d+):(.+)⟧$');
  final legacyImgRe = RegExp(r'^⟦img:(.+)⟧$');
  final kept = <String>[];
  for (final l in raw.split('\n')) {
    final reference = AttachmentHistoryReference.tryParseMarker(l);
    if (reference != null) {
      historyReferences.putIfAbsent(reference.index, () => reference);
      continue;
    }
    final indexed = indexedImgRe.firstMatch(l.trim());
    if (indexed != null) {
      indexedImagePaths[int.parse(indexed.group(1)!)] = indexed.group(2)!;
      continue;
    }
    final legacy = legacyImgRe.firstMatch(l.trim());
    if (legacy != null) {
      legacyImagePaths.add(legacy.group(1)!);
      continue;
    }
    kept.add(l);
  }
  final lines = kept;
  if (lines.isEmpty) return (attachments: const [], text: '');

  final markerRe = RegExp(r'^\[📎 (.+?)\]$');
  final parsedAttachments = <_ParsedAttachment>[];
  var markerCount = 0;
  while (markerCount < lines.length) {
    final marker = markerRe.firstMatch(lines[markerCount].trim());
    if (marker == null) break;
    final inside = marker.group(1)!;
    final sep = inside.lastIndexOf(' · ');
    final name = sep >= 0 ? inside.substring(0, sep) : inside;
    final size = sep >= 0 ? inside.substring(sep + 3) : '';
    final indexedPath = indexedImagePaths[markerCount];
    final historyReference = historyReferences[markerCount];
    final legacyPath =
        historyReference == null &&
            indexedPath == null &&
            legacyImagePaths.isNotEmpty &&
            markerCount == 0
        ? legacyImagePaths.removeAt(0)
        : null;
    parsedAttachments.add(
      _ParsedAttachment(
        name,
        size,
        historyReference: historyReference,
        imagePath: historyReference == null ? indexedPath ?? legacyPath : null,
      ),
    );
    markerCount++;
  }
  if (parsedAttachments.isEmpty) {
    return (attachments: const [], text: lines.join('\n'));
  }

  var rest = lines.skip(markerCount).toList();
  // Todo lo que sigue al sentinel ⟦adjunto⟧ es payload para el modelo: se oculta.
  final sIdx = rest.indexWhere((l) => l.trim() == '⟦adjunto⟧');
  if (sIdx >= 0) {
    rest = rest.sublist(0, sIdx);
  } else if (rest.isNotEmpty &&
      rest.first.trimLeft().startsWith('(archivo subido al agente en:')) {
    // Compat con el formato anterior (línea de ruta entre paréntesis).
    rest = rest.skip(1).toList();
  }
  return (attachments: parsedAttachments, text: rest.join('\n').trim());
}

/// Imagen incrustada en una respuesta del agente. Las imágenes remotas
/// (`http`/`https`) NO se cargan solas — cargarlas automáticamente sería un
/// beacon de IP hacia el host que las sirve, disparado por texto que puede
/// venir de un modelo remoto. Se muestra un placeholder con el dominio y
/// solo se pide la imagen cuando el usuario la toca. Las URIs locales
/// (`data:`/`file:`, si las hubiera) se cargan igual que antes.
class _GatedChatImage extends StatefulWidget {
  final Uri uri;
  final double? width;
  final double? height;
  final HermesThemeColors colors;

  const _GatedChatImage({
    required this.uri,
    required this.colors,
    this.width,
    this.height,
  });

  @override
  State<_GatedChatImage> createState() => _GatedChatImageState();
}

class _GatedChatImageState extends State<_GatedChatImage> {
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
    final imgHost = widget.uri.host.isNotEmpty ? ' de ${widget.uri.host}' : '';
    return Semantics(
      image: true,
      button: true,
      label: 'Imagen$imgHost, toca para ampliar',
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

/// Slot de una imagen generada por el agente dentro de la burbuja (spec 030).
/// Las rutas del servidor pasan por Bridge; las fuentes HTTPS estructuradas se
/// descargan directamente a la misma caché privada endurecida. Sin reintentos
/// automáticos: solo el botón Reintentar.
class _GeneratedImageSlot extends StatefulWidget {
  final _StructuredGeneratedImage reference;
  const _GeneratedImageSlot({super.key, required this.reference});

  @override
  State<_GeneratedImageSlot> createState() => _GeneratedImageSlotState();
}

class _GeneratedImageSlotState extends State<_GeneratedImageSlot> {
  GeneratedImageStatus _status = GeneratedImageStatus.downloading;
  File? _file;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final state = context.findAncestorStateOfType<_ChatScreenState>();
    if (state == null) {
      if (mounted) setState(() => _status = GeneratedImageStatus.unsupported);
      return;
    }
    setState(() => _status = GeneratedImageStatus.downloading);
    try {
      late final File file;
      switch (widget.reference.kind) {
        case GeneratedImageSourceKind.serverCache:
          final basename = widget.reference.basename;
          if (basename == null) {
            throw const FormatException('server image has no name');
          }
          final supported = await state.resolveGeneratedImageSupport();
          if (!mounted) return;
          if (!supported) {
            setState(() => _status = GeneratedImageStatus.unsupported);
            return;
          }
          file = await state.downloadGeneratedImage(basename);
        case GeneratedImageSourceKind.https:
          file = await GeneratedImageService.ensureHttpsDownloaded(
            state.widget.connection.id,
            widget.reference.source,
          );
      }
      if (!mounted) return;
      setState(() {
        _file = file;
        _status = GeneratedImageStatus.ready;
      });
    } on BridgeException catch (e) {
      if (!mounted) return;
      // 404 = el archivo ya no está en el servidor (caché rotada): sin
      // reintento útil. Otros fallos (red, token) → reintentable.
      setState(
        () => _status = e.status == 404
            ? GeneratedImageStatus.gone
            : GeneratedImageStatus.error,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = GeneratedImageStatus.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GeneratedImageCard(
      status: _status,
      file: _file,
      onRetry: _status == GeneratedImageStatus.error ? _start : null,
    );
  }
}
