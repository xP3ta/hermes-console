import '../models/bot_mention.dart';
import '../widgets/chat_mention_palette.dart';
// Chat screen with real-time streaming via REST API.
// Uses REST endpoints: POST /api/sessions/{id}/chat and
// GET /api/sessions/{id}/messages.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, visibleForTesting;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        BoxParentData,
        ChildLayoutHelper,
        ChildLayouter,
        MatrixUtils,
        RenderAbstractViewport,
        RenderBox,
        RenderObject,
        RenderProxyBox,
        RenderShiftedBox,
        RenderSliverMultiBoxAdaptor,
        ScrollCacheExtent,
        ScrollDirection;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';
import '../app_header_title.dart';
import '../companion/render/companion_message_presence.dart';
import '../companion/render/companion_status_indicator.dart';
import '../companion/models/companion_presence_level.dart';
import '../config/flavor.dart';
import '../models/activity_snapshot.dart';
import '../models/attachment_draft.dart';
import '../models/agent_profile.dart';
import '../models/chat_preferences.dart';
import '../models/compaction_progress.dart';
import '../models/command_descriptor.dart';
import '../models/desktop_compression_result.dart';
import '../models/desktop_context_breakdown.dart';
import '../models/desktop_model_catalog.dart';
import '../models/desktop_session_config.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/generated_artifact.dart';
import '../models/interactive_prompt.dart';
import '../models/prepared_turn.dart';
import '../models/session_activity.dart';
import '../models/session_artifact.dart';
import '../models/subagent_activity.dart';
import '../navigation/chat_route.dart';
import '../models/desktop_control_center.dart' show SessionGoalSnapshot;
import '../services/hermes_update_monitor.dart';
import '../services/active_chat_service.dart';
import '../services/approval_policy.dart';
import '../services/compaction_tracker.dart';
import '../services/session_reconciler.dart';
import '../services/artifact_export_service.dart';
import '../services/attachment_uploader.dart';
import '../services/command_risk.dart';
import '../services/bridge_client.dart';
import '../services/bridge_update_service.dart';
import '../services/chat_draft_store.dart';
import '../services/chat_preference_store.dart';
import '../services/desktop_gateway_capabilities.dart';
import '../services/mission_bot_chat_store.dart';
import '../services/notifications/notification_service.dart';
import '../services/recent_interrupt_guard.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/turn_outbox_store.dart';
import '../services/generated_image_service.dart';
import '../services/generated_media_service.dart';
import '../services/generated_artifact_registry.dart';
import '../services/connection_manager.dart';
import '../services/session_archive.dart';
import '../services/session_artifact_download_service.dart';
import '../services/session_config_reducer.dart';
import '../services/session_deletion.dart';
import '../services/subagent_transcript_projection.dart';
import '../services/tui_gateway_client.dart'
    show TuiGatewayClient, TuiGatewayRpcError;
import '../widgets/chat_connection_recovery_row.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/inline_message_editor.dart';
import '../widgets/stale_running_session_banner.dart';
import 'foreground_conversation_reader.dart';
import '../services/voice/conversation/native_voice.dart';
import '../services/voice/conversation/native_voice_session_configurator.dart';
import '../services/voice/conversation/local_voice_conversation_controller.dart';
import '../services/voice/read_aloud_session.dart';
import '../services/voice/stt_engine.dart';
import '../services/voice/voice_tool_phase.dart';
import '../services/voice/voice_response_policy.dart';
import '../services/voice/voice_phase.dart';
import '../services/voice/session/voice_ui_surface.dart';
import '../services/voice/voice_service.dart';
import '../services/voice/voice_settings.dart';
import 'voice_settings_screen.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../utils/api_error.dart';
import '../utils/voice_error.dart';
import '../utils/chat_error.dart';
import '../utils/byte_bounded_lru_cache.dart';
import '../utils/chat_turn.dart';
import '../utils/markdown_clipboard.dart';
import '../utils/responsive.dart';
import '../utils/slash_commands.dart';
import '../utils/assistant_content.dart';
import '../utils/assistant_operational_artifacts.dart';
import '../utils/assistant_suggestions.dart';
import '../utils/generated_artifact_markdown_scanner.dart';
import '../utils/semantic_markdown.dart';
import '../utils/streaming_normalizer.dart';
import '../utils/transport_privacy.dart';
import 'activity_screen.dart';
import 'cron_screen.dart';
import 'extensions_center_screen.dart';
import 'memory_screen.dart';
import 'models_screen.dart';
import 'recovery_center_screen.dart';
import 'session_detail_screen.dart';
import 'skills_screen.dart';
import 'soul_screen.dart';
import 'tasks_screen.dart';
import 'chat_render_projection.dart';
import '../widgets/action_approval.dart';
import '../widgets/agent_task_widgets.dart';
import '../widgets/attachment_card.dart';
import '../widgets/attachment_history_preview.dart';
import '../widgets/attachment_source_sheet.dart';
import '../widgets/generated_image_card.dart';
import '../widgets/generated_video_card.dart';
import '../widgets/generated_artifact_viewer.dart';
import '../widgets/callout_card.dart';
import '../widgets/chat_event_cards.dart';
import '../widgets/chat_control_sheet.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_file_tree.dart';
import '../widgets/hermes_bot_face.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_suggestions.dart';
import '../widgets/message_avatar_header.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_spark_mascot.dart';
import '../widgets/interactive_prompt_card.dart';
import '../widgets/markdown_table.dart';
import '../widgets/mission_profile_avatar.dart';
import '../widgets/motion_entrance.dart';
import '../widgets/subagent_activity_card.dart';
import '../widgets/activity_panel.dart';
import '../widgets/activity_task_linger.dart';
import '../widgets/compaction_dock.dart';
import '../widgets/platform_setup_commands.dart';
import '../widgets/read_only.dart';
import '../widgets/read_aloud_button.dart';
import '../widgets/session_deletion_dialogs.dart';
import '../widgets/session_artifacts_sheet.dart';
import '../widgets/session_context_usage.dart';
import '../widgets/voice_disclosure_dialog.dart';
import '../widgets/voice_stage.dart';
import 'image_viewer_screen.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';

/// El streaming sustituye mapas de mensaje completos. Esta caché usa identidad
/// porque las anclas pertenecen al objeto renderizado, así que hay que retirar
/// cada snapshot que ya no forme parte de las unidades visibles.
@visibleForTesting
void pruneAssistantAnchorCache<T>(
  Map<Map<String, dynamic>, T> anchors,
  Iterable<Object> renderUnits,
) {
  final liveMessages = Set<Map<String, dynamic>>.identity();
  for (final unit in renderUnits) {
    if (unit is Map<String, dynamic> &&
        unit['role'] == 'assistant' &&
        unit['_pipeline'] != true) {
      liveMessages.add(unit);
    }
  }
  anchors.removeWhere((message, _) => !liveMessages.contains(message));
}

@visibleForTesting
void pruneMessageAnchorCache<T>(
  Map<Map<String, dynamic>, T> anchors,
  Iterable<Map<String, dynamic>> messages,
) {
  final liveMessages = Set<Map<String, dynamic>>.identity()..addAll(messages);
  anchors.removeWhere((message, _) => !liveMessages.contains(message));
}

// Un MarkdownBody construye de una vez todo el árbol de su `data`. Una
// respuesta de varias decenas de KB, por tanto, anulaba la virtualización del
// ListView aunque el resto del historial fuese lazy. Estos límites mantienen
// cada hijo cerca de una o dos pantallas de texto y dejan un margen para no
// partir una sección Markdown justo al alcanzar el objetivo.
const int _assistantChunkTargetChars = 3200;
const int _assistantChunkMaxChars = 5200;

const int _assistantTerminalProjectionCacheLimit = 64;
// Respuestas vivas más largas que esto se reparten en prefijo estable (se
// proyecta una vez por contenido) + cola mutable (se reprocesa por frame).
// Por debajo, el parseo completo por frame es suficientemente barato y se
// conserva la ruta de un único bloque.
const int _liveAssistantStableSplitMinChars = 1600;
// Planes de troceado terminal indexados por CONTENIDO (no por identidad del
// Map del mensaje): el servicio sustituye ese Map en cada flush y una
// respuesta reemitida reutiliza el plan ya calculado.
//
// El troceado verifica cada frontera contra el render CommonMark del resto
// del documento, así que su coste crece con el cuadrado de la longitud: una
// respuesta de 63 KB tarda ~520 ms. Un historial largo tiene muchas más de 48
// respuestas troceables, de modo que al recorrerlo los planes salían del LRU y
// se recalculaban al reentrar en viewport — el tirón intermitente al hacer
// scroll. Un plan son unas pocas cadenas que ya viven en el transcript, así
// que el techo se sube a 512: barato en memoria frente a medio segundo de
// frames perdidos.
const int _assistantRenderPlanCacheLimit = 512;

/// Techo en bytes (aprox.) de la caché estática de planes: las claves son el
/// texto completo de la respuesta y cada plan duplica sus trozos. 512
/// respuestas de 60 KB serían ~60 MB sin este límite.
const int _assistantRenderPlanCacheMaxBytes = 8 * 1024 * 1024;

/// Tamaño aproximado (UTF-16: 2 bytes por code unit) de clave + plan.
int _assistantRenderPlanCacheBytes(
  String content,
  _CachedAssistantRenderPlan cached,
) {
  var units = content.length;
  final plan = cached.plan;
  if (plan != null) {
    units += plan.split.answer.length + plan.split.reasoning.length;
    for (final chunk in plan.chunks) {
      units += switch (chunk) {
        _AssistantMarkdownChunk(:final data) => data.length,
        _AssistantGeneratedImageChunk(:final basename) => basename.length,
        _AssistantGeneratedMediaChunk(:final reference) =>
          reference.source.length + reference.displayName.length,
      };
    }
  }
  return units * 2 + 64;
}

/// Compilada una vez: el troceado la evalúa por cada línea del documento.
final RegExp _markdownFenceRe = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// Definición de referencia CommonMark (`[etiqueta]: destino`). Su presencia
/// obliga a verificar cada frontera contra el documento entero, porque un
/// tramo puede usar una etiqueta declarada mucho más abajo.
final RegExp _linkReferenceDefinitionRe = RegExp(
  r'^ {0,3}\[[^\]]+\]:',
  multiLine: true,
);

/// Construcciones cuyo render depende de las líneas vecinas: listas (flojas o
/// apretadas según el entorno), citas, tablas GFM, vallas de código,
/// definiciones de referencia, encabezados subrayados y HTML embebido.
/// Deliberadamente amplia: un falso positivo sólo cuesta tomar la ruta
/// verificada con `markdownToHtml`, mientras que un falso negativo cambiaría
/// el render. Ante la duda, verificar.
final RegExp _contextDependentMarkdownRe = RegExp(
  r'^ {0,3}(?:'
  r'[-*+][ \t]'
  r'|\d{1,9}[.)][ \t]'
  r'|>'
  r'|```|~~~'
  r'|\[[^\]]+\]:'
  r'|={2,}[ \t]*$'
  r'|-{2,}[ \t]*$'
  r'|\|'
  r'|<[A-Za-z!/]'
  r')'
  r'|\|[^\n]*\|'
  r'|^\t'
  r'|^ {4,}\S',
  multiLine: true,
);

@visibleForTesting
bool isDeterministicRoomTaskWriteFailure(Object error) =>
    error is DashboardHttpException &&
    const <int>{400, 401, 403, 404, 405, 422}.contains(error.statusCode);

/// Ancla estable del asistente vivo para comprobar que un reflow de Markdown
/// no desplaza el viewport que el lector eligió durante el streaming.
@visibleForTesting
const chatLiveAssistantViewportKey = ValueKey('chat-live-assistant-viewport');

/// Las acciones sugeridas solo pertenecen al cierre del turno más reciente.
///
/// Mantener esta decisión pura permite probar que un rebuild, un mensaje
/// histórico o un draft nuevo nunca convierten una pill en steering ni pisan
/// contenido que el usuario ya estaba preparando.
@visibleForTesting
bool canOfferAssistantSuggestions({
  required bool isLatestAssistant,
  required bool isTerminal,
  required bool chatBusy,
  required bool writable,
  required bool composerEmpty,
  required bool attachmentsEmpty,
}) =>
    isLatestAssistant &&
    isTerminal &&
    !chatBusy &&
    writable &&
    composerEmpty &&
    attachmentsEmpty;

/// Paridad con `apps/desktop/src/lib/voice-stop-word.ts` del Desktop oficial.
///
/// El matcher sigue siendo de locución completa. Esta segunda guarda pertenece
/// al composer: una frase Stop escrita solo se convierte en control cuando la
/// conversación de Voz está viva, el lote no lleva adjuntos y la superficie es
/// realmente interactiva. En cualquier otra combinación el texto conserva su
/// semántica normal.
@visibleForTesting
bool interceptsTypedVoiceStop({
  required bool typedComposerSubmission,
  required bool voiceRuntimeActive,
  required bool attachmentsEmpty,
  required bool composerAccessible,
  required String text,
}) =>
    typedComposerSubmission &&
    voiceRuntimeActive &&
    attachmentsEmpty &&
    composerAccessible &&
    LocalVoiceConversationController.isExactVoiceStopPhrase(text);

bool _sameAttachmentDrafts(
  List<AttachmentDraft> left,
  List<AttachmentDraft> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a.localId != b.localId ||
        a.type != b.type ||
        a.name != b.name ||
        a.mimeType != b.mimeType ||
        a.sizeBytes != b.sizeBytes ||
        a.localPath != b.localPath) {
      return false;
    }
  }
  return true;
}

@visibleForTesting
Future<List<XFile>> pickPendingGalleryImages(
  ImagePicker picker, {
  required int remaining,
}) async {
  if (remaining <= 0) return const [];
  final implementation = ImagePickerPlatform.instance;
  if (implementation is ImagePickerAndroid) {
    implementation.useAndroidPhotoPicker = true;
  }
  // `pickMultiImage(limit: 1)` es inválido en la API pública del plugin. Al
  // quedar un único hueco usamos el mismo Photo Picker en modo individual.
  if (remaining == 1) {
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 2048,
      maxHeight: 2048,
    );
    return file == null ? const [] : [file];
  }
  return picker.pickMultiImage(
    imageQuality: 82,
    maxWidth: 2048,
    maxHeight: 2048,
    limit: remaining,
  );
}

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
    final fence = _markdownFenceRe.firstMatch(line);
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

  // Atajo para prosa simple. Verificar fronteras con `markdownToHtml` cuesta
  // ~11ms por ventana de 10KB, y una respuesta larga tiene decenas de tramos
  // (medido: 349ms para 68KB, 727ms para 137KB). Ese parseo sólo hace falta
  // si el documento contiene alguna construcción cuyo render dependa de las
  // líneas vecinas: listas, citas, tablas, vallas, definiciones de
  // referencia, encabezados subrayados o HTML embebido. Un texto de párrafos
  // separados por línea en blanco no tiene ninguna, así que cortar en un
  // salto de bloque es seguro por construcción y el corte se decide sin
  // parsear nada (0,2ms para el documento entero).
  if (!_contextDependentMarkdownRe.hasMatch(markdown)) {
    final simpleChunks = <String>[];
    var simpleStart = 0;
    while (markdown.length - simpleStart > maxChars) {
      final target = simpleStart + targetChars;
      final upper = math.min(simpleStart + maxChars, markdown.length);
      var cut = -1;
      for (final offset in blockBreaks) {
        if (offset > simpleStart &&
            offset <= upper &&
            offset < markdown.length) {
          cut = offset;
          if (offset >= target) break;
        }
      }
      if (cut <= simpleStart) break;
      simpleChunks.add(markdown.substring(simpleStart, cut));
      simpleStart = cut;
    }
    simpleChunks.add(markdown.substring(simpleStart));
    return List<String>.unmodifiable(simpleChunks);
  }

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

  // Comparar la firma del resto del documento (no la del documento entero)
  // es lo que permite trocear textos cuyas definiciones de referencia viven
  // al final: un tramo aislado no resuelve `[texto][ref]`, pero la cola que
  // lo acompaña sí, y la concatenación reproduce el render original.
  //
  // Parsear el resto entero en cada tramo hace que el coste crezca con el
  // cuadrado de la longitud (las colas suman ~10x el documento; medido: 520ms
  // para 63KB). Cuando el documento no declara ninguna definición de
  // referencia, ningún tramo puede depender de lo que viene después, así que
  // basta comparar contra una ventana acotada: el tramo más el siguiente.
  final hasLinkReferenceDefinitions = _linkReferenceDefinitionRe.hasMatch(
    markdown,
  );
  int restEndFor(int start) => hasLinkReferenceDefinitions
      ? markdown.length
      : math.min(start + 2 * maxChars, markdown.length);

  // La cola se memoiza por `start`: dentro de un tramo se prueban varios
  // candidatos y todos comparten la misma, así que sin esto se reparsea la
  // ventana una vez por candidato.
  var restStart = -1;
  String? restSignature;
  String? signatureOfRest(int start) {
    if (restStart != start) {
      restStart = start;
      restSignature = signature(markdown.substring(start, restEndFor(start)));
    }
    return restSignature;
  }

  bool preservesRendering(int start, int end) {
    final whole = signatureOfRest(start);
    if (whole == null) return false;
    final left = signature(markdown.substring(start, end));
    if (left == null || !whole.startsWith(left)) {
      // Sin prefijo común no hay frontera válida: ahorra parsear la derecha.
      return false;
    }
    final right = signature(markdown.substring(end, restEndFor(start)));
    return right != null && '$left$right' == whole;
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

sealed class _AssistantBodyChunk {
  const _AssistantBodyChunk();
}

final class _AssistantMarkdownChunk extends _AssistantBodyChunk {
  final String data;

  const _AssistantMarkdownChunk(this.data);
}

final class _AssistantGeneratedImageChunk extends _AssistantBodyChunk {
  final String basename;

  const _AssistantGeneratedImageChunk(this.basename);
}

final class _AssistantGeneratedMediaChunk extends _AssistantBodyChunk {
  final GeneratedMediaReference reference;

  const _AssistantGeneratedMediaChunk(this.reference);
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

final class _StructuredGeneratedVideo {
  final GeneratedMediaReference reference;
  final String toolCallId;

  const _StructuredGeneratedVideo({
    required this.reference,
    required this.toolCallId,
  });

  ValueKey<String> get widgetKey {
    final digest = sha256
        .convert(
          utf8.encode(
            '${reference.sourceKind.name}\u0000${reference.source}\u0000$toolCallId',
          ),
        )
        .toString()
        .substring(0, 24);
    return ValueKey<String>('generated-video-$digest');
  }
}

List<_StructuredGeneratedVideo> _structuredGeneratedVideos(
  Map<String, dynamic> metadata,
) {
  final raw = metadata['_generatedImages'];
  if (raw is! List) return const [];
  final refs = <_StructuredGeneratedVideo>[];
  final seen = <String>{};
  for (final entry in raw.whereType<Map>()) {
    if (entry['media_kind'] != GeneratedMediaKind.video.name) continue;
    final toolCallId = entry['tool_call_id'];
    final source = entry['source'];
    if (toolCallId is! String ||
        toolCallId.trim().isEmpty ||
        source is! String) {
      continue;
    }
    final reference = GeneratedMediaService.referenceFromSource(source);
    if (reference == null || reference.kind != GeneratedMediaKind.video) {
      continue;
    }
    if (entry['kind'] != reference.sourceKind.name) continue;
    if (!seen.add('$toolCallId\u0000${reference.source}')) continue;
    refs.add(
      _StructuredGeneratedVideo(reference: reference, toolCallId: toolCallId),
    );
  }
  return List<_StructuredGeneratedVideo>.unmodifiable(refs);
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

final class _AssistantRenderPlan {
  final String sourceContent;
  final ReasoningSplit split;
  final List<_AssistantBodyChunk> chunks;

  const _AssistantRenderPlan({
    required this.sourceContent,
    required this.split,
    required this.chunks,
  });
}

final class _CachedAssistantRenderPlan {
  final _AssistantRenderPlan? plan;

  const _CachedAssistantRenderPlan(this.plan);
}

final class _AssistantRenderSlice {
  final _AssistantRenderPlan plan;
  final int index;

  const _AssistantRenderSlice(this.plan, this.index);

  _AssistantBodyChunk get body => plan.chunks[index];
  bool get showHeader => index == 0;
  bool get showFooter => index == plan.chunks.length - 1;
}

final class _AssistantTerminalProjectionKey {
  final String sourceContent;
  final String sliceKey;
  final bool suggestionsEnabled;

  const _AssistantTerminalProjectionKey({
    required this.sourceContent,
    required this.sliceKey,
    required this.suggestionsEnabled,
  });

  @override
  bool operator ==(Object other) =>
      other is _AssistantTerminalProjectionKey &&
      other.sourceContent == sourceContent &&
      other.sliceKey == sliceKey &&
      other.suggestionsEnabled == suggestionsEnabled;

  @override
  int get hashCode => Object.hash(sourceContent, sliceKey, suggestionsEnabled);
}

sealed class _ProjectedAssistantBlock {
  const _ProjectedAssistantBlock();
}

final class _ProjectedAssistantMarkdown extends _ProjectedAssistantBlock {
  final String data;
  const _ProjectedAssistantMarkdown(this.data);
}

final class _ProjectedAssistantTable extends _ProjectedAssistantBlock {
  final List<List<String>> rows;
  const _ProjectedAssistantTable(this.rows);
}

final class _ProjectedAssistantImage extends _ProjectedAssistantBlock {
  final String basename;
  const _ProjectedAssistantImage(this.basename);
}

final class _ProjectedAssistantMedia extends _ProjectedAssistantBlock {
  final GeneratedMediaReference reference;
  const _ProjectedAssistantMedia(this.reference);
}

ValueKey<String> _generatedMediaWidgetKey(
  GeneratedMediaReference reference,
  int ordinal,
) {
  final digest = sha256
      .convert(utf8.encode(reference.source))
      .toString()
      .substring(0, 24);
  return ValueKey<String>('generated-media-$digest-$ordinal');
}

final class _ProjectedAssistantGap extends _ProjectedAssistantBlock {
  const _ProjectedAssistantGap();
}

final class _AssistantTerminalProjection {
  final ReasoningSplit split;
  final AssistantSuggestionsProjection suggestions;
  final List<_ProjectedAssistantBlock> blocks;

  const _AssistantTerminalProjection({
    required this.split,
    required this.suggestions,
    required this.blocks,
  });
}

sealed class _ChatListEntry {
  ChatRenderUnitPlan get sourcePlan;
}

final class _WholeChatListEntry extends _ChatListEntry {
  @override
  final ChatRenderUnitPlan sourcePlan;

  _WholeChatListEntry(this.sourcePlan);
}

final class _AssistantSliceChatListEntry extends _ChatListEntry {
  @override
  final ChatMessageUnitPlan sourcePlan;
  final _AssistantRenderSlice slice;

  _AssistantSliceChatListEntry(this.sourcePlan, this.slice);
}

/// Conserva el host del asistente en el mismo slot cuando un error terminal
/// añade su tarjeta debajo de una respuesta parcial.
///
/// En una lista `reverse:true` virtualizada, convertir de golpe el índice 0 en
/// dos filas hace que `maxScrollExtent` mezcle geometría real y estimaciones
/// lazy. Agruparlas mientras el lector está apartado permite que el reporter
/// vivo mida el delta real del conjunto en el mismo layout.
final class _RetainedTerminalErrorChatListEntry extends _ChatListEntry {
  final ChatMessageUnitPlan errorPlan;
  final ChatMessageUnitPlan assistantPlan;

  _RetainedTerminalErrorChatListEntry({
    required this.errorPlan,
    required this.assistantPlan,
  });

  @override
  ChatRenderUnitPlan get sourcePlan => assistantPlan;
}

int? messageIndexForArtifactSource(
  List<Map<String, dynamic>> messagesNewestFirst,
  SessionArtifactSource source,
) {
  final sourceIdentity = TranscriptMessageIdentity(
    messageId: source.messageId,
    rowId: source.rowId,
  );
  if (sourceIdentity.isDurable) {
    var found = -1;
    for (var index = 0; index < messagesNewestFirst.length; index++) {
      final message = messagesNewestFirst[index];
      if (!transcriptIdentityAliasesAreConsistent(message)) {
        if (transcriptIdentityAliasesShareExactCoordinate(
          message,
          sourceIdentity,
        )) {
          return null;
        }
        continue;
      }
      final candidate = canonicalTranscriptIdentity(message);
      if (candidate == null ||
          !sourceIdentity.sharesExactCoordinate(candidate)) {
        continue;
      }
      if (!sourceIdentity.matches(candidate) || found >= 0) return null;
      found = index;
    }
    if (found >= 0) return found;
    // Un ID estable que ya no existe pertenece a otra revisión/compresión. No
    // degradar a un ordinal que ahora podría señalar otro mensaje.
    return null;
  }
  var serverOrdinal = 0;
  for (var index = messagesNewestFirst.length - 1; index >= 0; index--) {
    final message = messagesNewestFirst[index];
    if (message['_steer'] == true ||
        message['_pipeline'] == true ||
        message['_desktopSnapshotKind'] == 'inflight') {
      continue;
    }
    if (serverOrdinal == source.messageOrdinal) return index;
    serverOrdinal++;
  }
  return null;
}

/// Fuente de lectura del catálogo. La selección siempre se aplica al runtime
/// de esta sesión; ninguna de estas rutas autoriza una mutación global.
enum _ModelSource { desktop, bridge, dashboard, gateway }

enum _ChatControlAction {
  permissions,
  refresh,
  artifacts,
  details,
  cron,
  recovery,
  extensions,
  releaseDesktop,
  delete,
}

// ChatPipelineState vive ahora en active_chat_service.dart (el streaming lo
// posee el servicio singleton, no el widget) y se reexporta vía ese import.
//
// La orquestación del modo voz (bucle, fases, feed de TTS) vive en el
// controlador local global (sobrevive a la navegación y al 2º plano).
// La pantalla solo observa ese servicio para pintar el overlay. VoicePhase se
// reexporta vía ese import.

/// Nombre corto y amigable de un modelo, para mostrarlo en la UI sin el id
/// crudo del servidor. Quita el prefijo de proveedor y la fecha del build:
///
///   "claude-opus-4-8-20251101"  → "Opus 4.8"
///   "anthropic/claude-sonnet-4-6" → "Sonnet 4.6"
///   "claude-haiku-4-5"          → "Haiku 4.5"
///   "gpt-4o"                    → "GPT-4o"
///
/// Modelos desconocidos: el id (sin proveedor) tal cual, truncado a 20 chars.
String friendlyModelName(String id) {
  // "anthropic/claude-…" → "claude-…": nos quedamos con el segmento del modelo.
  final slash = id.lastIndexOf('/');
  final raw = slash >= 0 && slash < id.length - 1
      ? id.substring(slash + 1)
      : id;
  final lower = raw.toLowerCase();

  // Familia Claude: "claude-familia-major-minor[-fecha]" → "Familia major.minor".
  final claude = RegExp(
    r'^claude-(opus|sonnet|haiku)-(\d+)-(\d+)',
  ).firstMatch(lower);
  if (claude != null) {
    final family = claude.group(1)!;
    final capitalized = family[0].toUpperCase() + family.substring(1);
    return '$capitalized ${claude.group(2)}.${claude.group(3)}';
  }

  // Familia GPT: mantiene "GPT-" en mayúsculas y conserva el resto del nombre.
  final gpt = RegExp(r'^gpt-(.+)$').firstMatch(lower);
  if (gpt != null) return 'GPT-${gpt.group(1)}';

  return raw.length > 20 ? '${raw.substring(0, 19)}…' : raw;
}

/// Contadores opt-in para demostrar que el streaming queda aislado del árbol
/// histórico. Solo se inyecta desde widget tests; en producción permanece null.
@visibleForTesting
class ChatPerformanceProbe {
  int publicTranscriptReads = 0;
  int screenBuilds = 0;
  int composerBuilds = 0;
  int terminalAssistantBuilds = 0;
  int liveAssistantBuilds = 0;
  int terminalProjectionComputations = 0;
  int liveStableProjectionComputations = 0;

  /// Proyecciones completas del transcript (`ChatRenderProjection.build`).
  int renderProjectionBuilds = 0;

  /// Reconstrucciones de la lista de entradas del transcript.
  int listEntryProjections = 0;

  /// Planes de troceado de respuestas largas calculados (fallos de caché).
  int assistantRenderPlanComputations = 0;

  void reset() {
    publicTranscriptReads = 0;
    screenBuilds = 0;
    composerBuilds = 0;
    terminalAssistantBuilds = 0;
    liveAssistantBuilds = 0;
    terminalProjectionComputations = 0;
    liveStableProjectionComputations = 0;
    renderProjectionBuilds = 0;
    listEntryProjections = 0;
    assistantRenderPlanComputations = 0;
  }
}

bool chatRefreshMessagesShareAnchorIdentity(
  Map<String, dynamic> selected,
  Map<String, dynamic> candidate,
) {
  if (!transcriptIdentityAliasesAreConsistent(selected) ||
      !transcriptIdentityAliasesAreConsistent(candidate)) {
    return false;
  }
  final selectedIdentity = canonicalTranscriptIdentity(selected);
  final candidateIdentity = canonicalTranscriptIdentity(candidate);
  if (selectedIdentity != null &&
      candidateIdentity != null &&
      selectedIdentity.matches(candidateIdentity)) {
    return true;
  }
  // Sin identidad durable no hay equivalencia entre proyecciones: dos turnos
  // legítimos pueden compartir rol y texto. Solo el mismo objeto conserva el
  // ancla mientras la lista no haya sido sustituida.
  return identical(selected, candidate);
}

@visibleForTesting
Map<String, dynamic>? chatRefreshFindAnchorMessage(
  Map<String, dynamic> selected,
  Iterable<Map<String, dynamic>> candidates,
) {
  if (!transcriptIdentityAliasesAreConsistent(selected)) return null;
  final selectedIdentity = canonicalTranscriptIdentity(selected);
  Map<String, dynamic>? match;
  for (final candidate in candidates) {
    if (selectedIdentity != null) {
      if (!transcriptIdentityAliasesAreConsistent(candidate)) {
        if (transcriptIdentityAliasesShareExactCoordinate(
          candidate,
          selectedIdentity,
        )) {
          return null;
        }
        continue;
      }
      final candidateIdentity = canonicalTranscriptIdentity(candidate);
      if (candidateIdentity == null ||
          !selectedIdentity.sharesExactCoordinate(candidateIdentity)) {
        continue;
      }
      if (!selectedIdentity.matches(candidateIdentity)) return null;
    } else if (!identical(selected, candidate)) {
      continue;
    }
    if (match != null) return null;
    match = candidate;
  }
  return match;
}

@visibleForTesting
String chatReadAloudMessageKey(
  String sessionId,
  Map<String, dynamic>? message,
  String answer,
) {
  final identity = message == null
      ? null
      : canonicalTranscriptIdentity(message);
  final durableKey = identity?.rowId != null
      ? 'row:${identity!.rowId}'
      : identity?.messageId != null
      ? 'message:${identity!.messageId}'
      : null;
  return '$sessionId:assistant:'
      '${durableKey ?? 'content:${_stableChatReadAloudHash(answer)}'}';
}

String _stableChatReadAloudHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

class ChatScreen extends StatefulWidget {
  /// Vacía la caché estática de planes de render (aislamiento entre tests).
  @visibleForTesting
  static void resetAssistantRenderPlanCacheForTesting() =>
      _ChatScreenState._assistantRenderPlans.clear();

  /// Entradas de la caché estática de resaltado de bloques de código.
  @visibleForTesting
  static int get codeHighlightCacheLengthForTesting =>
      _CodeBlockWrapperState._highlightCache.length;

  @visibleForTesting
  static ({int entries, int bytes})
  get assistantRenderPlanCacheStatsForTesting => (
    entries: _ChatScreenState._assistantRenderPlans.length,
    bytes: _ChatScreenState._assistantRenderPlans.bytes,
  );

  @visibleForTesting
  static const int assistantRenderPlanCacheMaxBytes =
      _assistantRenderPlanCacheMaxBytes;

  final SavedConnection connection;
  final Session session;
  final String? initialPrompt;
  final AttachmentSourceChoice? initialAttachmentSource;
  final bool initialDictation;
  final bool initialVoiceMode;
  final bool requestComposerFocus;
  final String? initialStoredSessionId;

  /// Caché de identidad que Mission Control ya mantiene para Bot Chat.
  final MissionProfileAvatarCache? missionAvatarCache;

  /// Identidad del bot cuando la superficie es un Bot Chat (`_isBotChatSurface`).
  /// La aporta Mission Control, que ya tiene el `AgentProfile` autoritativo;
  /// sin ella la cabecera cae al nombre del profile de la sesión.
  final AgentProfile? missionBotProfile;
  @visibleForTesting
  final ChatPerformanceProbe? performanceProbe;
  @visibleForTesting
  final Future<AttachmentDraft?> Function(AttachmentDraft)?
  attachmentMaterializer;
  @visibleForTesting
  final Future<bool> Function(AttachmentDraft)? attachmentPrivateCopyDeleter;
  @visibleForTesting
  final Future<void> Function()? cancelStreamOverride;
  @visibleForTesting
  final VoidCallback? sendAttemptObserver;
  @visibleForTesting
  final ChatDraftStore? draftStoreOverride;

  const ChatScreen({
    required this.connection,
    required this.session,
    this.initialPrompt,
    this.initialAttachmentSource,
    this.initialDictation = false,
    this.initialVoiceMode = false,
    this.requestComposerFocus = false,
    this.initialStoredSessionId,
    this.missionAvatarCache,
    this.missionBotProfile,
    this.performanceProbe,
    this.attachmentMaterializer,
    this.attachmentPrivateCopyDeleter,
    this.cancelStreamOverride,
    this.sendAttemptObserver,
    this.draftStoreOverride,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, RouteAware {
  // El estado del chat (mensajes, trace, pipeline) vive en el ActiveChat del
  // servicio singleton para sobrevivir al pop de la ruta. Estos getters/setters
  // delegan en él; así el streaming continúa en segundo plano y al volver se
  // reengancha mostrando lo que llegó mientras la pantalla estaba fuera.
  late final ActiveChatService _chatService;
  late final ActiveChat _chat;
  StreamSubscription<ActiveChatEvent>? _chatSub;
  bool _chatBound = false;
  final ValueNotifier<SessionContextMetrics> _sessionContextMetrics =
      ValueNotifier(SessionContextMetrics.unknown);
  late Session _sessionUsageSnapshot;
  DateTime? _sessionUsageRefreshedAt;
  Future<void>? _sessionUsageRefreshInFlight;
  String? _sessionContextBootstrapRuntimeId;
  String? _sessionContextBootstrapInFlightRuntimeId;
  Timer? _sessionContextBootstrapRetryTimer;
  Completer<bool>? _sessionContextBootstrapRetryCompleter;
  bool _sessionContextAwaitingPostCompactionMetrics = false;
  int? _desktopRuntimePresentationFingerprint;
  (bool, int, int, int, int)? _activityPresentationFingerprint;
  bool _lastDesktopCompacting = false;
  PendingSessionConfigChange? _pendingModelConfirmation;
  NavigatorState? _modelConfirmationNavigator;
  Route<bool>? _modelConfirmationRoute;
  // Se marca en cuanto empieza dispose(). El stream del chat es un broadcast
  // que puede entregar un evento ya en cola vía microtask durante el desmontaje
  // (la ventana en que el Element ya es defunct pero `mounted` aún es true);
  // ese setState tardío reventaba con "_lifecycleState != defunct". Filtrar por
  // este flag además de `mounted` corta esos eventos diferidos.
  bool _disposed = false;
  late final LocalConversationLifecycle _localConversationLifecycle;

  bool _editingUserMessage = false;
  Map<String, dynamic>? _editingUserMessageTarget;
  double? _editingUserMessageWidth;
  String? _editingUserMessageText;
  int? _editingUserMessageOrdinal;
  String? _editingQueuedEntryId;
  bool _editingRewriteSubmitted = false;
  List<Map<String, dynamic>>? _editingMessagesSnapshot;
  ChatPipelineState? _editingPipelineSnapshot;

  /// Congela la proyección visual mientras el editor está abierto. El agente
  /// puede avanzar en segundo plano, pero su respuesta no aparece mientras se
  /// edita: Cancelar revela el progreso real y Guardar rebobina el turno.
  List<Map<String, dynamic>> get _messages {
    final probe = widget.performanceProbe;
    if (probe != null) probe.publicTranscriptReads += 1;
    return _editingMessagesSnapshot ?? _chat.messages;
  }

  bool get _editingTranscriptChanged {
    final before = _editingMessagesSnapshot;
    if (before == null) return false;
    final current = _chat.messages;
    if (before.length != current.length) return true;
    for (var index = 0; index < before.length; index++) {
      if (before[index]['role'] != current[index]['role'] ||
          before[index]['content'] != current[index]['content']) {
        return true;
      }
    }
    return false;
  }

  void _clearUserMessageEditingState() {
    _editingUserMessage = false;
    _editingUserMessageTarget = null;
    _editingUserMessageWidth = null;
    _editingUserMessageText = null;
    _editingUserMessageOrdinal = null;
    _editingRewriteSubmitted = false;
    _editingMessagesSnapshot = null;
    _editingPipelineSnapshot = null;
  }

  ChatPipelineState get _pipelineState =>
      _editingPipelineSnapshot ?? _chat.state;
  set _pipelineState(ChatPipelineState v) => _chat.state = v;
  String get _lastPrompt => _chat.lastPrompt;

  String? _error;
  bool _loadingEarlierMessages = false;
  int _messageRefreshEpoch = 0;
  ({int epoch, bool passiveOnly, bool published})? _messageRefreshInFlight;
  int? get _messageRefreshInFlightEpoch => _messageRefreshInFlight?.epoch;
  int? get _messageRefreshPublishedEpoch =>
      _messageRefreshInFlight?.published == true
      ? _messageRefreshInFlight?.epoch
      : null;

  // Only the current interactive read awaiting transcript publication fences
  // editing. REST can publish before runtime resume finishes; passive polling
  // and superseded futures must never keep a usable transcript's composer shut.
  // Identity, kind and publication travel together, with no separate busy flag
  // to inherit from a predecessor or forget to clear on an early return.
  bool get _interactiveMessageRefreshPending =>
      _messageRefreshInFlight != null &&
      !_messageRefreshInFlight!.passiveOnly &&
      !_messageRefreshInFlight!.published;
  int? _messageRefreshAnchorEpoch;
  bool _messageRefreshReanchorScheduled = false;
  ForegroundConversationReader? _passiveConversationReader;
  bool _chatRouteVisible = false;
  late bool _appInForeground;
  // Relative delays place the follow-up checks at +1.5s and +4s.
  static const _postControlRepairDelays = [
    Duration(milliseconds: 1500),
    Duration(milliseconds: 2500),
  ];
  Timer? _subagentPollTimer;
  Timer? _subagentRepairDebounce;
  Timer? _processControlRepairDebounce;
  int _postControlRepairDelayIndex = -1;
  String? _subagentPollingRuntimeId;
  bool _adaptiveSnapshotInFlight = false;
  bool _adaptiveSnapshotQueued = false;
  bool _queuedSubagentRefresh = false;
  bool _queuedProcessRefresh = false;
  bool _queuedControlRefresh = false;
  int _adaptiveRefreshFailureIndex = 0;
  int _seenAdaptiveEventRevision = 0;
  int _seenAdaptiveFullRefreshRevision = 0;
  int _seenAdaptiveSubagentRepairRevision = 0;
  int _seenAdaptiveProcessRepairRevision = 0;
  int _seenAdaptiveControlRepairRevision = 0;
  SubagentPresentationOwnerToken? _subagentPresentationOwner;
  int _viewerAttachGeneration = 0;

  /// A-201 (spec 028): la excepción cruda del error de carga solo se muestra
  /// bajo demanda ("ver detalles"), nunca como cuerpo del estado de error.
  bool _showErrorDetail = false;

  // La cobertura es una advertencia de esta vista, no un bloqueo ni estado
  // durable del transcript. El lector puede descartarla y seguir cargando
  // páginas anteriores al llegar al extremo del timeline.
  bool _coreReadCoverageNoticeDismissed = false;

  // The subagent-activity pill is a UI-layer cache on top of
  // `_chat.subagentActivities`: the service clears that list once work is
  // retired (see active_chat_service.dart's `_rememberRetiredSubagentTerminals`
  // + `_subagentActivities = null`), which used to make the pill vanish the
  // instant everything finished — right when someone actually wants to open
  // it and check what happened. This widget-local copy keeps showing the
  // last known activities after they go empty, until the person dismisses
  // it (×) or genuinely new work starts. It never touches the service's own
  // retirement/reconciliation logic, only what this screen displays.
  List<SubagentActivity> _lastNonEmptySubagentActivities =
      const <SubagentActivity>[];
  bool _subagentPillDismissed = false;

  List<SubagentActivity> get _displaySubagentActivities {
    final live = _chat.subagentActivities;
    if (live.isNotEmpty) {
      _lastNonEmptySubagentActivities = live;
      if (live.any((a) => !a.isTerminal)) _subagentPillDismissed = false;
    } else if (_chat.subagentLiveRosterConfirmedEmpty) {
      // Keeping the rows is the point of this cache; keeping them *running*
      // is not. A turn that dies without a successor (`_failRun`'s "Modelo
      // sin respuesta", a cancel, any end that never emits another
      // `started`) left the cached non-terminal rows spinning a "trabajando"
      // label until the next prompt. Settle them the moment the service has
      // authority that nothing is live — a fenced `subagent.list` that no
      // longer reports them — and only then: a background delegation keeps
      // running after its parent turn ends, so the turn ending is not
      // evidence, and neither is a list that failed to answer.
      _lastNonEmptySubagentActivities = _settledSubagentActivities(
        _lastNonEmptySubagentActivities,
      );
    }
    // A momentarily empty `live` (a poll gap, a cover/pause/reconnect cycle)
    // is not proof of retirement — this getter runs on every build, so
    // clearing the cache here on a single empty read reintroduces the exact
    // flicker it exists to prevent. Genuine retirement is instead confirmed
    // event-driven, at a new turn's `ActiveChatEvent.started` (see
    // `_onChatEvent`), which is the actual authoritative "this is over" signal.
    return _subagentPillDismissed
        ? const <SubagentActivity>[]
        : _lastNonEmptySubagentActivities;
  }

  /// A row the pill still counts and paints as live work.
  static bool _presentsAsRunning(SubagentActivity activity) =>
      !activity.isTerminal && activity.phase != SubagentActivityPhase.unknown;

  /// Copies of [activities] with every still-running row presented as stopped,
  /// so the pill reads as finished/interrupted (no spinner, no "trabajando")
  /// instead of pretending the work is still going. Terminal rows keep their
  /// real phase (completed, failed), and an `unknown` row stays unknown:
  /// absence is not evidence of what that one did.
  static List<SubagentActivity> _settledSubagentActivities(
    List<SubagentActivity> activities,
  ) {
    if (!activities.any(_presentsAsRunning)) return activities;
    return List<SubagentActivity>.unmodifiable([
      for (final activity in activities)
        if (!_presentsAsRunning(activity))
          activity
        else
          SubagentActivity(
            key: activity.key,
            source: activity.source,
            phase: SubagentActivityPhase.cancelled,
            subagentId: activity.subagentId,
            delegationId: activity.delegationId,
            childSessionId: activity.childSessionId,
            legacyToolCallId: activity.legacyToolCallId,
            eventRevision: activity.eventRevision,
            seenEventIds: activity.seenEventIds,
            details: activity.details,
          ),
    ]);
  }

  void _dismissSubagentPill() {
    setState(() => _subagentPillDismissed = true);
  }

  // Chat sending state — derived from pipeline state.
  late final TextEditingController _textController;
  final _textFocusNode = FocusNode();
  bool get _sending => _chat.sending;
  bool _compressionCommandInFlight = false;
  bool? _lastDesktopCompressionPresentation;
  bool _compressionDraftFocusRetained = false;
  bool get _compressingSession =>
      _compressionCommandInFlight ||
      (_chatBound && _chat.desktopManualCompressionInFlight);

  // Dictado por voz (STT del sistema vía VoiceService) para el composer.
  bool _isRecording = false;
  bool _composerEmpty = true;
  // Sugerencias de comandos slash mientras se escribe `/…` en el compositor.
  List<SlashCommand> _slashSuggestions = const [];
  // The navigation drawer paints below overlay-hosted composer popovers
  // (slash palette, floating notices): they must hide while it is open.
  bool _navigationDrawerOpen = false;
  DesktopCommandCatalog? _desktopCommandCatalog;
  Timer? _slashCompletionDebounce;
  int _slashCompletionEpoch = 0;
  // Resolviendo una aprobación del agente (deshabilita los botones).
  bool _resolvingApproval = false;
  bool _resolvingInteractivePrompt = false;
  final Set<String> _openingSubagentSessionIds = {};
  StreamSubscription<SttResult>? _sttSub;
  // Salvaguarda: si tras pulsar "parar" el reconocedor no emite resultado final
  // (p.ej. se quedó colgado sin pack de idioma), reseteamos la UI igualmente
  // para que el botón no parezca que "no hace nada".
  Timer? _stopFallback;
  // Referencia estable para el teardown: durante dispose() ya no es seguro
  // buscar ancestros en el BuildContext.
  VoiceService? _voiceService;

  // Modo voz manos libres: TODA la orquestación (bucle, fases, feed de TTS) vive
  // en el controlador global. VoiceStage solo observa y proyecta ese estado.
  // Superficie estable del único controlador público, resuelta en
  // didChangeDependencies.
  VoiceUiSurface? _vc;
  StreamSubscription<SttCheck>? _vcUnavailableSub;
  NativeVoicePreparation? _nativeVoicePreparation;

  // Adjuntos seleccionados, pendientes de subir al filesystem gestionado del
  // agente cuando el usuario envíe el mensaje. La galería puede añadir varias
  // imágenes en una sola selección; cámara y archivos se agregan a esta lista.
  final List<AttachmentDraft> _pendingAttachments = [];
  int? _producerAttachmentOwner;
  bool _queueExpanded = false;
  ChatDraftStore? _draftStore;
  String? _normalCanonicalDraftId;
  Future<void> _draftSnapshotTail = Future<void>.value();
  MissionBotChatStore? _botChatStore;
  String? _persistedCanonicalBotPinId;
  String? _canonicalBotPinFlightId;
  Future<void>? _canonicalBotPinFlight;
  String? _hiddenCanonicalBotRuntimeId;
  String? _hiddenCanonicalBotFlightId;
  Future<void>? _hiddenCanonicalBotFlight;
  TurnOutboxStore? _turnOutbox;
  PreparedTurn? _preparedTurn;
  String? _composerPreparedTurnClientTurnId;
  String? _failedTurnDiscardInFlightId;
  final Completer<bool> _initialOutboxRead = Completer<bool>();
  ActiveTurnDelivery? _attachmentDelivery;
  late final ValueChanged<List<AttachmentDraft>> _attachmentListener;
  Timer? _draftTimer;
  bool _restoringDraft = false;
  bool _draftLoaded = false;
  // Un composer vacío NO prueba que nadie lo haya tocado: también es el estado
  // exacto en el que queda cuando el usuario borra el texto a mano. La
  // recuperación de un turno puede reconciliar mucho después de abrir el chat
  // (una sesión desconectada tarda hasta que el transporte responde o expira),
  // y sin esta marca reinyectaría en el composer el texto que el usuario acaba
  // de borrar; al salir, el flush de `dispose` volvía a persistirlo y la sesión
  // seguía anunciando «borrador» con ese mismo texto.
  bool _composerEmptiedByUser = false;
  // Cubre el intervalo previo a ActiveChat.send (aprobación + subida + copia
  // local). Sin este estado, varios taps podían iniciar la misma subida.
  bool _attachmentSubmitting = false;
  Future<void> _attachmentMutationTail = Future<void>.value();
  int _attachmentMutationsPending = 0;
  bool get _attachmentMutationInFlight => _attachmentMutationsPending > 0;
  // Valla de submit desde el primer tap/Enter hasta el ACK de transporte. No
  // sustituye `_sending`: después del ACK el composer vuelve a aceptar texto y
  // Hermes puede tratarlo como steering durante el run actual.
  bool _composerSubmissionInFlight = false;
  Timer? _stopConfirmationDismissTimer;
  bool _confirmedStopStatusDismissed = false;
  final RecentInterruptGuard _recentInterrupt = RecentInterruptGuard();
  bool _imagePickerOpen = false;
  bool _documentPickerOpen = false;
  static const int _maxPendingImages = 10;

  // Developer diagnostics mode (ex verbose)
  bool _devDiagnostics = false;
  ChatPreferences _chatPreferences = const ChatPreferences();
  ChatPreferenceStore? _chatPreferenceStore;
  String? _chatPreferenceLogicalId;
  int _chatPreferenceScopeEpoch = 0;
  String? _markedNotificationSessionId;
  // Nombre del agente para el marcador del mensaje y el chat vacío — refleja
  // VERBATIM el título del header configurable en Ajustes ('header_title').
  // Por defecto coincide con el del Home. Solo display.
  String _agentName = 'HERMES CONSOLE';

  // Selected model from settings (falls back to hermes-agent)
  String _selectedModel = 'hermes-agent';
  String _selectedProvider = '';
  DesktopReasoningEffort? _selectedReasoning;
  DesktopFastMode? _selectedFastMode;

  // De dónde se cargó el catálogo de modelos: decide por dónde se PERSISTE la
  // selección (bridge con token, Dashboard con login, o solo gateway local).
  _ModelSource _modelSource = _ModelSource.dashboard;

  // Scroll management
  final _scrollController = ScrollController();
  Timer? _keyboardScrollTimer;
  // La flecha "ir al final" se aísla en un notifier: mostrarla/ocultarla no
  // reconstruye la pantalla (crítico cuando se pausa el seguimiento con el
  // dedo durante el streaming).
  final ValueNotifier<bool> _scrollToBottomVisibility = ValueNotifier(false);
  set _showScrollToBottom(bool value) {
    if (_scrollToBottomVisibility.value == value) return;
    _recordTranscriptOverlayExtentChange(value ? 48 : -48);
    _scrollToBottomVisibility.value = value;
  }

  // Alto medido del hueco de las pastillas de actividad. Notifier aparte por
  // la misma razón que la flecha: cambiar no reconstruye la pantalla.
  final ValueNotifier<double> _activityPillExtent = ValueNotifier(0);

  /// Compactación (automática o manual) de la sesión abierta: mide el tiempo,
  /// aprende la duración típica y conserva el resultado unos segundos. La
  /// pastilla de actividad la enseña como una actividad más.
  final CompactionTracker _compaction = CompactionTracker();
  final SubagentActivityController _subagentController =
      SubagentActivityController();
  Map<String, dynamic>? _consumedCompressionResult;
  int _seenCompactedEdges = 0;

  /// El fin de esta compactación ya se conoce (resultado o borde `compacted`)
  /// aunque el servicio aún no haya soltado su bandera: no debe arrancar otra.
  bool _compactionSettledEarly = false;

  /// Texto de `/compress …` que sigue en el composer mientras la compactación
  /// está en marcha; se consume al terminar bien y se conserva si falla.
  String? _compressionInvocation;
  void _setActivityPillExtent(double value) {
    if (_disposed || _activityPillExtent.value == value) return;
    _recordTranscriptOverlayExtentChange(value - _activityPillExtent.value);
    _activityPillExtent.value = value;
  }

  void _recordTranscriptOverlayExtentChange(double delta) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels <= position.minScrollExtent + 0.5) return;
    _streamingViewportLock.recordOverlayExtentChange(delta);
  }

  bool _autoFollowStreaming = true;
  int? _streamingScrollPointer;
  Offset? _streamingScrollOrigin;
  bool _streamingScrollGestureMoved = false;
  final _streamingViewportLock = _ChatStreamingViewportLock();
  final Map<Map<String, dynamic>, RenderBox> _messageAnchors =
      Map<Map<String, dynamic>, RenderBox>.identity();
  final Set<Map<String, dynamic>> _readerPreservedTurnInsertions =
      Set<Map<String, dynamic>>.identity();
  ChatRenderProjection? _renderProjection;
  ChatRenderProjection? _listEntriesProjection;
  List<_ChatListEntry>? _listEntries;
  // Estática (proceso): el plan es puro por contenido. Con caché por State,
  // cada ChatScreen nuevo (volver de la lista, reabrir) repetía el troceado
  // verificado de todas las respuestas largas dentro del frame que aplica la
  // página REST (QA 9340; parte del frame lento al reabrir sesiones largas).
  static final ByteBoundedLruCache<String, _CachedAssistantRenderPlan>
  _assistantRenderPlans = _createAssistantRenderPlanCache();

  static ByteBoundedLruCache<String, _CachedAssistantRenderPlan>
  _createAssistantRenderPlanCache() {
    final cache = ByteBoundedLruCache<String, _CachedAssistantRenderPlan>(
      maxEntries: _assistantRenderPlanCacheLimit,
      maxBytes: _assistantRenderPlanCacheMaxBytes,
      sizeOf: _assistantRenderPlanCacheBytes,
    );
    // Borrar conexión, revocar API keys o cambiar de perfil vacían la caché:
    // las claves son texto de conversaciones de esa autoridad.
    PrivateRenderCaches.register(cache.clear);
    return cache;
  }

  final LinkedHashMap<
    _AssistantTerminalProjectionKey,
    _AssistantTerminalProjection
  >
  _assistantTerminalProjections = LinkedHashMap();
  final Map<String, _LinkPreviewData?> _linkCache = {};
  final Map<Map<String, dynamic>, int> _generatedArtifactFingerprints =
      Map<Map<String, dynamic>, int>.identity();
  final GeneratedArtifactRegistry _generatedArtifactRegistry =
      GeneratedArtifactRegistry.shared;
  static const ArtifactExportActions _artifactExporter =
      PlatformArtifactExportActions();

  String get _generatedArtifactScope =>
      '${widget.connection.id}:${widget.session.logicalId}';

  // El servicio coalesca deltas a 30 Hz; el ritmo de revelado lo marca
  // [_streamingRevealTimer]. Este notifier limita cada delta al subtree del
  // asistente vivo; el Scaffold, el composer y las filas históricas no se
  // reconstruyen por token.
  final ValueNotifier<_LiveAssistantFrame?> _liveAssistantFrame = ValueNotifier(
    null,
  );
  bool _liveAssistantMaterialized = false;
  bool _liveFollowFramePending = false;
  bool _terminalLiveHostReleasePending = false;
  Map<String, dynamic>? _retainedTerminalAssistant;
  Map<String, dynamic>? _retainedTerminalError;
  int _revealedChars = 0;
  // Revelado gradual del asistente vivo (sucesor del typewriter de fa0e8c0,
  // esta vez en la capa VISUAL): el servicio publica el contenido autoritativo
  // completo a 30 Hz y lo que avanza a ritmo constante es solo el recorte
  // [_revealedChars]. Así el transcript nunca contiene medias palabras ni
  // grafemas partidos (lección de 37d43f7) y la cola visible la repara el
  // normalizador de streaming. Solo se aplica siguiendo el fondo y con
  // animaciones habilitadas; al pausar el seguimiento se muestra todo.
  Timer? _streamingRevealTimer;
  // Identidad visual del turno, independiente de los Map de mensajes. El
  // servicio sustituye el Map del asistente en cada fragmento para publicar un
  // snapshot nuevo; usar esa identidad como Key reiniciaba el fundido cada
  // 33 ms y dejaba crecer una respuesta completamente transparente.
  int _assistantEntranceSerial = 0;
  int? _surfaceTurnSerial;
  bool _surfaceTurnTerminal = false;

  // Aspecto acotado a propósito: `MediaQuery.maybeOf` suscribía este State
  // entero a CUALQUIER cambio de MediaQuery (cada frame de la animación del
  // teclado incluido), no solo a la preferencia de movimiento reducido.
  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _clearRetainedTerminalReferences() {
    final retained = _retainedTerminalAssistant;
    if (retained != null) _messageAnchors.remove(retained);
    _retainedTerminalAssistant = null;
    _retainedTerminalError = null;
  }

  void _beginSurfaceTurn() {
    final retained = _retainedTerminalAssistant;
    // Un turno que empieza con el lector ARRIBA en el historial (pausó el
    // seguimiento tras el terminal anterior, o un run de cron/bot de Room
    // aterriza en la sesión abierta mientras lee) NO hereda el "sigue el
    // fondo": sin el lock, cada reflow de la burbuja viva desplazaría el
    // texto que está leyendo. Solo sigue el fondo quien ya está en el fondo.
    final readerIsAtBottom = _isNearBottom;
    final hasRetainedAnchor =
        !_autoFollowStreaming && _liveAssistantMaterialized && retained != null;
    final preserveReaderViewport = !readerIsAtBottom;
    _readerPreservedTurnInsertions.clear();
    if (preserveReaderViewport) {
      if (hasRetainedAnchor) {
        _expectRetainedReaderAnchorChange(retained);
        // `ActiveChat.send` inserta el placeholder y la petición nueva antes
        // de emitir `started`. Si esa petición es más alta que el cache del
        // sliver, el ancla retenida deja de materializarse y no puede medirse
        // al final del layout. Reportar la altura inicial REAL de esas dos
        // filas deja un fallback determinista sin depender de la estimación
        // de maxScrollExtent.
        _readerPreservedTurnInsertions.addAll(_messages.take(2));
      } else {
        // Sin host retenido, la fila del placeholder es sustituida por el host
        // vivo, que ya reporta su altura inicial completa: reportarla aquí
        // también la contaría dos veces. Solo la petición del usuario es
        // altura nueva neta en la inserción.
        if (_messages.length > 1) {
          _readerPreservedTurnInsertions.add(_messages[1]);
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _readerPreservedTurnInsertions.clear();
      });
      _streamingViewportLock.enable();
    } else {
      _streamingViewportLock.disable();
    }
    _assistantEntranceSerial++;
    _surfaceTurnSerial = _assistantEntranceSerial;
    _surfaceTurnTerminal = false;
    _clearRetainedTerminalReferences();
    _streamingRevealTimer?.cancel();
    _revealedChars = 0;
    _liveAssistantMaterialized = false;
    _liveAssistantFrame.value = null;
    _autoFollowStreaming = readerIsAtBottom;
    _showScrollToBottom = !readerIsAtBottom;
  }

  Map<String, dynamic>? _currentLiveAssistantMessage() {
    if (_messages.isEmpty) return null;
    final message = _messages.first;
    return message['role'] == 'assistant' && message['_pipeline'] != true
        ? message
        : null;
  }

  Map<String, dynamic>? _terminalSurfaceAssistantMessage(
    _LiveAssistantFrame? previousFrame,
  ) {
    final head = _currentLiveAssistantMessage();
    if (head != null) return head;
    if (previousFrame == null || _messages.length < 2) return null;

    final error = _messages[0];
    final partial = _messages[1];
    if (error['role'] != 'assistant_error' ||
        partial['role'] != 'assistant' ||
        partial['_cancelled'] != true ||
        partial['_pipeline'] == true) {
      return null;
    }
    final previous = previousFrame.content;
    final terminal = (partial['content'] as String?) ?? '';
    if (previous.isEmpty || terminal.isEmpty) return null;
    final continuesSameResponse =
        terminal == previous ||
        terminal.startsWith(previous) ||
        previous.startsWith(terminal);
    return continuesSameResponse ? partial : null;
  }

  bool _messageKeepsLiveHost(Map<String, dynamic> message) {
    if (!_liveAssistantMaterialized || _autoFollowStreaming) return false;
    final retained = _retainedTerminalAssistant;
    if (retained != null) return identical(message, retained);
    return _messages.isNotEmpty && identical(message, _messages.first);
  }

  void _syncStreamingSegmentBoundary() {
    if (!_chat.isStreaming || !_liveAssistantMaterialized) return;
    if (_messages.isEmpty) return;
    final head = _messages.first;
    if (head['role'] != 'assistant' || head['_pipeline'] != true) return;
    final frame = _liveAssistantFrame.value;
    if (frame == null ||
        frame.turnSerial != _assistantEntranceSerial ||
        identical(frame.metadata, head)) {
      return;
    }
    // El texto ya sellado del turno sigue siendo visible: la actividad abre un
    // tramo NUEVO detrás de él, no vacía la burbuja. Publicar '' aquí borraba
    // de pantalla la narración previa a la herramienta («Voy a revisar…») y
    // solo reaparecía al cerrar el turno, cuando el terminal reconstruye la
    // burbuja entera. El servicio nunca perdió ese texto — lo conserva en
    // `content` — así que el frame vivo debe reflejarlo tal cual.
    final content = (head['content'] as String?) ?? '';
    _revealedChars = content.length;
    _liveAssistantFrame.value = _LiveAssistantFrame(
      turnSerial: _assistantEntranceSerial,
      content: content,
      metadata: head,
      isStreaming: true,
    );
  }

  void _publishLiveAssistantFrame({
    bool isStreaming = true,
    Map<String, dynamic>? message,
  }) {
    if (_disposed) return;
    final target = message ?? _currentLiveAssistantMessage();
    if (target == null) return;
    final content = (target['content'] as String?) ?? '';
    final visibleLength = _autoFollowStreaming
        ? math.min(_revealedChars, content.length)
        : content.length;
    final visible = content.substring(0, visibleLength);
    final previous = _liveAssistantFrame.value;
    if (previous != null &&
        previous.turnSerial == _assistantEntranceSerial &&
        previous.content == visible &&
        identical(previous.metadata, target) &&
        previous.isStreaming == isStreaming) {
      return;
    }
    _liveAssistantFrame.value = _LiveAssistantFrame(
      turnSerial: _assistantEntranceSerial,
      content: visible,
      metadata: target,
      isStreaming: isStreaming,
    );
  }

  void _scheduleLiveFollowFrame() {
    if (_liveFollowFramePending ||
        !_autoFollowStreaming ||
        !_isNearBottom ||
        _userIsDragging) {
      return;
    }
    _liveFollowFramePending = true;
    final turnSerial = _assistantEntranceSerial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liveFollowFramePending = false;
      if (_disposed ||
          !mounted ||
          turnSerial != _assistantEntranceSerial ||
          !_autoFollowStreaming ||
          !_isNearBottom ||
          _userIsDragging ||
          !_scrollController.hasClients) {
        return;
      }
      final position = _scrollController.position;
      if (position.pixels > position.minScrollExtent) {
        _scrollController.jumpTo(position.minScrollExtent);
      }
    });
  }

  /// Avanza el revelado gradual un paso (o lo completa cuando no aplica:
  /// lector que pausó el seguimiento, movimiento reducido o fin del stream).
  /// El paso se alinea a GRAFEMAS (`characters`), nunca a unidades UTF-16
  /// sueltas, y acelera con el tamaño de la ráfaga para no quedar rezagado.
  void _advanceStreamingReveal() {
    final content = _chat.assistantContent;
    if (!_chat.isStreaming || !_autoFollowStreaming || _reduceMotion) {
      _streamingRevealTimer?.cancel();
      if (_revealedChars != content.length) {
        _revealedChars = content.length;
        _publishLiveAssistantFrame();
      }
      return;
    }
    if (_revealedChars >= content.length) return;
    final pendingUnits = content.length - _revealedChars;
    // Mínimo ~6 grafemas por tick (33 ms, ritmo de lectura cómodo); una
    // ráfaga grande se drena en ~8 ticks para que el texto no se quede atrás.
    final step = pendingUnits ~/ 8;
    final target = step < 6 ? 6 : step;
    var units = 0;
    var graphemes = 0;
    for (final grapheme in content.substring(_revealedChars).characters) {
      units += grapheme.length;
      if (++graphemes >= target) break;
    }
    _revealedChars += units;
    if (_revealedChars < content.length) _ensureStreamingRevealTimer();
  }

  void _ensureStreamingRevealTimer() {
    if (_disposed || (_streamingRevealTimer?.isActive ?? false)) return;
    _streamingRevealTimer = Timer.periodic(const Duration(milliseconds: 33), (
      _,
    ) {
      if (_disposed || !mounted) {
        _streamingRevealTimer?.cancel();
        return;
      }
      _advanceStreamingReveal();
      _publishLiveAssistantFrame();
      _scheduleLiveFollowFrame();
    });
  }

  @override
  void initState() {
    super.initState();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appInForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _textController = _SlashAccentTextEditingController();
    _attachmentListener = _applyAttachmentProjection;
    _sessionUsageSnapshot = widget.session;
    _compaction.addListener(_onCompactionChanged);
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
    _loadActiveModel();
    _profileReady = _loadActiveProfile();
    _localConversationLifecycle = LocalConversationCleanupFence.beginLifecycle(
      connectionId: widget.connection.id,
      profile: Session.profileOwner(widget.session.profile),
      sessionId: widget.session.id,
      sessionAliases: {_draftRecoverySessionId, ..._draftRecoveryAliases},
    );
    _scrollController.addListener(_onScroll);
    _textController.addListener(_onComposerChanged);
    _textFocusNode.addListener(_onComposerFocusChanged);
    unawaited(_restoreDraftAndRunInitialAction());
  }

  void _onComposerFocusChanged() {
    if (mounted && !_disposed) setState(() {});
  }

  Future<void> _restoreDraftAndRunInitialAction() async {
    try {
      await _restoreDraft();
      if (!_initialOutboxRead.isCompleted) _initialOutboxRead.complete(true);
    } catch (error) {
      // La lectura segura forma parte del ownership del turno. Fallar abierto
      // permitiría crear otra entrada y duplicar una entrega todavía oculta.
      debugPrint('[turn-outbox] secure recovery failed (${error.runtimeType})');
      if (!_initialOutboxRead.isCompleted) _initialOutboxRead.complete(false);
    }
    if (!mounted) return;

    if (widget.initialVoiceMode || widget.initialDictation) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (widget.initialVoiceMode) {
        await _enterVoiceMode();
      } else {
        await _startDictation();
      }
      return;
    }

    final initialAttachmentSource = widget.initialAttachmentSource;
    if (initialAttachmentSource != null) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      switch (initialAttachmentSource) {
        case AttachmentSourceChoice.camera:
          await _pickImage(ImageSource.camera);
          break;
        case AttachmentSourceChoice.photos:
          await _pickImage();
          break;
        case AttachmentSourceChoice.files:
          await _pickDocument();
          break;
      }
      return;
    }

    final initialPrompt = widget.initialPrompt?.trim();
    if (widget.requestComposerFocus &&
        (initialPrompt == null || initialPrompt.isEmpty)) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _textFocusNode.requestFocus();
      }
    }
    if (initialPrompt == null ||
        initialPrompt.isEmpty ||
        _textController.text.trim().isNotEmpty) {
      return;
    }

    // didChangeDependencies enlaza ActiveChat durante el primer frame. Esperar
    // ese frame evita una ruta paralela y hace que el texto use exactamente el
    // mismo submit/steering/cola que el composer visible. El texto viaja como
    // override y no se pinta primero en el campo del chat: Inicio ya confirmó
    // el envío y mostrarlo ahí hasta el ACK parecía un bloqueo.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_chatBound) return;
    final promptBefore = _chat.lastPrompt;
    final messageCountBefore = _chat.messages.length;
    await _sendMessage(initialText: initialPrompt);
    if (!mounted ||
        _textController.text.isNotEmpty ||
        _chat.lastPrompt != promptBefore ||
        _chat.messages.length != messageCountBefore) {
      return;
    }
    // Si falló antes de entregar el turno a ActiveChat (por ejemplo, no pudo
    // persistirse el outbox), lo devolvemos al compositor para que se pueda
    // reintentar sin perderlo.
    _textController.value = TextEditingValue(
      text: initialPrompt,
      selection: TextSelection.collapsed(offset: initialPrompt.length),
    );
  }

  String get _draftRecoverySessionId {
    if (!_isBotChatSurface &&
        widget.session.isUnpersistedMobileDraft &&
        _chatBound &&
        _chat.sessionId == widget.session.id &&
        _chat.sessionProfile == _recoveryProfile) {
      // Unacknowledged delivery still belongs to the provisional outbox key.
      // Moving only its composer would bypass recovery/idempotency on reopen.
      final pendingState = _preparedTurn?.state;
      if (_composerPreparedTurnClientTurnId != null ||
          pendingState == PreparedTurnState.prepared ||
          pendingState == PreparedTurnState.submitting ||
          pendingState == PreparedTurnState.ambiguous ||
          pendingState == PreparedTurnState.failedBeforeAcceptance) {
        return widget.session.id;
      }
      return _chat.createdDraftSessionId ?? widget.session.id;
    }
    return widget.session.id;
  }

  void _authorizeDraftDestination(String sessionId) {
    if (!_isBotChatSurface && sessionId != widget.session.id) {
      LocalConversationCleanupFence.authorizeCreatedSession(
        _localConversationLifecycle,
        sessionId,
      );
      _normalCanonicalDraftId = sessionId;
    }
  }

  String get _recoveryProfile => _localConversationLifecycle.profile;

  bool get _isBotChatSurface => const {
    'mobile-bot',
    'bot-mode',
    'bot-mode-local',
    'bot-mode-canonical',
  }.contains(widget.session.source.trim().toLowerCase());

  bool get _allowsDedicatedVoiceLaunch => !_isBotChatSurface;

  Set<String> get _draftRecoveryAliases {
    if (!_isBotChatSurface) return <String>{};
    return <String>{
      widget.session.id,
      widget.session.logicalId,
      ?widget.initialStoredSessionId?.trim(),
    }..removeWhere((id) => id.isEmpty || id == _draftRecoverySessionId);
  }

  bool _hasDraftContent(ChatDraft draft) =>
      draft.text.isNotEmpty || draft.attachments.isNotEmpty;

  Future<ChatDraft> _loadDraftWithRecoveryMigration(
    ChatDraftStore store,
  ) async {
    final recoveryId = _draftRecoverySessionId;
    final profile = _recoveryProfile;
    final draft = await store.load(
      widget.connection.id,
      recoveryId,
      profile: profile,
    );
    if (_hasDraftContent(draft)) {
      // The stable scope is authoritative once present. Aliases belong to an
      // older identity scheme; retaining a divergent one would resurrect an
      // already superseded operation after the stable draft reaches terminal.
      for (final alias in _draftRecoveryAliases) {
        await store.clear(
          widget.connection.id,
          alias,
          profile: profile,
          includeUnscoped: true,
        );
      }
      return draft;
    }

    for (final alias in _draftRecoveryAliases) {
      final legacy = await store.load(
        widget.connection.id,
        alias,
        profile: profile,
        claimUnscopedLegacy: true,
      );
      if (!_hasDraftContent(legacy)) continue;
      await store.save(
        widget.connection.id,
        recoveryId,
        legacy.text,
        legacy.attachments,
        profile: profile,
        preparedTurnClientTurnId: legacy.preparedTurnClientTurnId,
        lifecycle: _localConversationLifecycle,
      );
      await store.clear(
        widget.connection.id,
        alias,
        profile: profile,
        includeUnscoped: true,
      );
      return legacy;
    }
    return draft;
  }

  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _disposed) return;
    if (!LocalConversationCleanupFence.rehydrate(_localConversationLifecycle)) {
      return;
    }
    final store = widget.draftStoreOverride ?? ChatDraftStore(prefs);
    final outbox = TurnOutboxStore(lifecycle: _localConversationLifecycle);
    // El borrador pinta primero: la reconciliación adicional de outbox no debe
    // retrasar el composer ni introducir una carrera visible al navegar rápido.
    _draftStore = store;
    var draft = widget.connection.readOnly
        ? const ChatDraft(text: '', attachments: [])
        : await _loadDraftWithRecoveryMigration(store);
    if (!mounted) return;
    _turnOutbox = outbox;
    final linkedDiscard = draft.preparedTurnClientTurnId;
    if (linkedDiscard != null &&
        await outbox.isFailedBeforeAcceptanceDiscarded(
          connectionId: widget.connection.id,
          profile: _recoveryProfile,
          sessionId: widget.session.id,
          clientTurnId: linkedDiscard,
        )) {
      // El tombstone manda incluso si el proceso murió entre los dos stores.
      // El clear es compactación exacta; la UI no depende de que termine.
      await store.clear(
        widget.connection.id,
        _draftRecoverySessionId,
        profile: _recoveryProfile,
      );
      draft = const ChatDraft(text: '', attachments: []);
    }
    if (!mounted || _disposed) return;
    _draftLoaded = true;
    final liveDeliveryAtRestore = _chatBound ? _chat.activeTurnDelivery : null;
    final liveOwnsRestoredDraft =
        liveDeliveryAtRestore != null &&
        draft.text == liveDeliveryAtRestore.current.text &&
        _sameAttachmentDrafts(
          draft.attachments,
          liveDeliveryAtRestore.current.attachments,
        );
    _restoringDraft = true;
    setState(() {
      _composerPreparedTurnClientTurnId = draft.preparedTurnClientTurnId;
      if (!liveOwnsRestoredDraft &&
          !_composerEmptiedByUser &&
          _textController.text.isEmpty) {
        _textController.text = draft.text;
      }
      if (!liveOwnsRestoredDraft &&
          !_composerEmptiedByUser &&
          _pendingAttachments.isEmpty) {
        _pendingAttachments.addAll(draft.attachments);
      }
    });
    _restoringDraft = false;
    _syncProducerAttachmentRetention();

    // Si el servicio sigue vivo, él posee la frontera de transporte. Leer la
    // outbox con `loadForChat` convertiría un `submitting` legítimo en ambiguo
    // como si hubiese muerto el proceso. Solo reconciliamos storage cuando no
    // hay evidencia viva para esta ruta.
    final liveDelivery = liveDeliveryAtRestore;
    if (liveDelivery != null) _observeAttachmentDelivery(liveDelivery);
    PreparedTurn? loaded = liveDelivery?.current;
    List<PreparedTurn> recoveredQueued = const [];
    if (liveDelivery == null) {
      final recovered = await outbox.loadAllForChat(
        widget.connection.id,
        widget.session.id,
        profile: _recoveryProfile,
      );
      recoveredQueued = recovered.where((turn) => turn.queued).toList();
      final nonQueued = recovered.where((turn) => !turn.queued).toList();
      loaded = nonQueued.isEmpty ? null : nonQueued.last;
    }
    if (!mounted) return;
    if (!_initialOutboxRead.isCompleted) _initialOutboxRead.complete(true);
    if (loaded == null) {
      _composerPreparedTurnClientTurnId = null;
      await _chat.restoreQueuedTurns(recoveredQueued, outbox);
      return;
    }
    _preparedTurn = loaded;
    var prepared = loaded;
    if (liveDelivery == null &&
        (prepared.state == PreparedTurnState.ambiguous ||
            prepared.state == PreparedTurnState.accepted ||
            prepared.state == PreparedTurnState.running)) {
      prepared = await _chat.reconcileAmbiguousTurn(prepared, outbox);
      if (!mounted) return;
    }
    await _chat.restoreQueuedTurns(
      recoveredQueued,
      outbox,
      scheduleDrain: prepared.state != PreparedTurnState.ambiguous,
    );
    if (!mounted) return;
    final reconciledDelivery = _chatBound ? _chat.activeTurnDelivery : null;
    if (reconciledDelivery != null) {
      _observeAttachmentDelivery(reconciledDelivery);
    }
    _preparedTurn = prepared;
    // Sin `turn.status` el turno seguiría incierto para siempre: el transcript
    // durable puede demostrar que sí llegó (mismas reglas que la cola).
    if (liveDelivery == null) _scheduleComposerTurnTranscriptSettle();
    if (!prepared.restoresComposer) {
      _showHiddenRecoveredTurn(prepared);
      return;
    }
    final recoverPrepared = liveOwnsRestoredDraft
        ? false
        : switch (prepared.state) {
            PreparedTurnState.prepared ||
            PreparedTurnState.submitting ||
            PreparedTurnState.ambiguous ||
            PreparedTurnState.failedBeforeAcceptance => true,
            PreparedTurnState.accepted ||
            PreparedTurnState.running ||
            PreparedTurnState.terminal => false,
          };
    // Solo reconciliamos si el usuario no empezó a editar mientras se leía el
    // Keystore. Nunca pisamos escritura nueva con un snapshot tardío. Vaciar el
    // composer a mano cuenta como escritura nueva: un vacío deliberado no es un
    // composer intacto, aunque el texto coincida con «nada».
    final composerStillAtDraft =
        !_composerEmptiedByUser &&
        (_textController.text.isEmpty || _textController.text == draft.text);
    final attachmentsStillAtDraft = _sameAttachmentDrafts(
      _pendingAttachments,
      draft.attachments,
    );
    if (!composerStillAtDraft || !attachmentsStillAtDraft) return;
    _restoringDraft = true;
    setState(() {
      if (recoverPrepared) {
        _composerPreparedTurnClientTurnId =
            prepared.state == PreparedTurnState.failedBeforeAcceptance
            ? prepared.clientTurnId
            : null;
        _textController.text = prepared.text;
        _pendingAttachments
          ..clear()
          ..addAll(prepared.attachments);
      } else {
        // ACK ya persistido: el draft antiguo no vuelve a ofrecerse para envío.
        _textController.clear();
        _pendingAttachments.clear();
        _composerPreparedTurnClientTurnId = null;
      }
    });
    _restoringDraft = false;
    _syncProducerAttachmentRetention();
    if (recoverPrepared &&
        prepared.state == PreparedTurnState.failedBeforeAcceptance &&
        draft.preparedTurnClientTurnId != prepared.clientTurnId) {
      // Backfill para drafts creados por v23: a partir de aquí cualquier
      // corte entre tombstone y clear puede atribuirlos al intento exacto.
      await _saveDraftSnapshot(
        prepared.text,
        prepared.attachments,
        preparedTurnClientTurnId: prepared.clientTurnId,
      );
      if (!mounted) return;
    }
    if (!recoverPrepared) {
      // accepted/running se conservan cifrados hasta el terminal para permitir
      // reattach tras process death. Solo el draft/composer viejo se retira.
      final transportAccepted =
          prepared.state == PreparedTurnState.accepted ||
          prepared.state == PreparedTurnState.running ||
          prepared.state == PreparedTurnState.terminal;
      // Un submit vivo anterior al ACK se oculta para impedir reenvío, pero su
      // copia cifrada sigue disponible si Android mata el proceso en esa ventana.
      if (transportAccepted) await _clearDraft();
      if (prepared.state == PreparedTurnState.terminal) {
        try {
          await outbox.delete(prepared);
        } catch (error) {
          debugPrint(
            '[turn-outbox] reconciled cleanup failed (${error.runtimeType})',
          );
        }
        if (identical(_preparedTurn, prepared)) _preparedTurn = null;
      }
      return;
    }
    if (prepared.state == PreparedTurnState.ambiguous) {
      _showHiddenRecoveredTurn(prepared);
    }
  }

  bool _composerTurnSettleInFlight = false;

  /// Resuelve como entregado el turno del composer cuya confirmación se
  /// perdió si el transcript durable lo demuestra. No toca el turno en vuelo,
  /// no restaura el borrador ni reenvía; ante cualquier duda lo deja pendiente.
  void _scheduleComposerTurnTranscriptSettle() {
    final prepared = _preparedTurn;
    if (_composerTurnSettleInFlight ||
        prepared == null ||
        prepared.queued ||
        !const {
          PreparedTurnState.ambiguous,
          PreparedTurnState.accepted,
          PreparedTurnState.running,
        }.contains(prepared.state) ||
        !_chatBound ||
        _chat.activeTurnDelivery != null) {
      return;
    }
    _composerTurnSettleInFlight = true;
    Timer.run(() {
      unawaited(
        _settleComposerTurnFromTranscript(prepared).whenComplete(() {
          _composerTurnSettleInFlight = false;
        }),
      );
    });
  }

  Future<void> _settleComposerTurnFromTranscript(PreparedTurn prepared) async {
    if (!mounted || !identical(_preparedTurn, prepared)) return;
    final delivered = await _chat.composerTurnDeliveredPerTranscript(prepared);
    if (!delivered || !mounted || !identical(_preparedTurn, prepared)) return;
    try {
      await (await _outboxStore()).delete(prepared);
    } catch (error) {
      debugPrint(
        '[turn-outbox] delivered composer cleanup failed '
        '(${error.runtimeType})',
      );
      return;
    }
    if (!mounted || !identical(_preparedTurn, prepared)) return;
    _preparedTurn = null;
    _composerPreparedTurnClientTurnId = null;
    // La cola restaurada quedó suspendida mientras este turno era ambiguo.
    _chat.resumeQueueDrainAfterComposerTurnResolved();
    _chat.removeLatestFailedPromptProjection(
      prepared.fullText,
      allowLegacyContentPair: true,
    );
    if (prepared.restoresComposer &&
        _textController.text.trim() == prepared.text.trim()) {
      _restoringDraft = true;
      setState(() {
        _textController.clear();
        _pendingAttachments.clear();
      });
      _restoringDraft = false;
      await _clearDraft();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _showHiddenRecoveredTurn(PreparedTurn prepared) {
    if (!mounted || prepared.state == PreparedTurnState.terminal) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_preparedTurn, prepared)) return;
      final ambiguous = prepared.state == PreparedTurnState.ambiguous;
      final acknowledged =
          prepared.state == PreparedTurnState.accepted ||
          prepared.state == PreparedTurnState.running;
      final english = Localizations.localeOf(context).languageCode == 'en';
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ambiguous
                ? Strings.of(context).chaAmbiguousRestored
                : acknowledged
                ? english
                      ? 'Hermes could not reattach a turn that may still be running. Send retries the check; discard only after verifying Hermes because this does not cancel the remote turn.'
                      : 'Hermes no pudo reanexar un turno que aún podría seguir activo. Enviar repite la comprobación; descarta solo tras verificar Hermes porque esto no cancela el turno remoto.'
                : english
                ? 'A pending turn was recovered. Discard the recovery to continue.'
                : 'Se recuperó un turno pendiente. Descarta la recuperación para continuar.',
          ),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: Strings.of(context).chaDiscardRecovered,
            onPressed: () => unawaited(_discardRecoveredTurn(prepared)),
          ),
        ),
      );
    });
  }

  Future<void> _discardRecoveredTurn(PreparedTurn prepared) async {
    final composerStillMatches = prepared.matchesBatch(
      text: _textController.text,
      attachments: List<AttachmentDraft>.of(_pendingAttachments),
      model: prepared.model,
      profile: prepared.profile,
    );
    try {
      await (await _outboxStore()).delete(prepared);
    } catch (error) {
      debugPrint(
        '[turn-outbox] recovered discard failed (${error.runtimeType})',
      );
      return;
    }
    if (identical(_preparedTurn, prepared)) {
      _preparedTurn = null;
      _composerPreparedTurnClientTurnId = null;
    }
    if (!mounted || !composerStillMatches) return;
    _restoringDraft = true;
    setState(() {
      _textController.clear();
      _pendingAttachments.clear();
    });
    _restoringDraft = false;
    _syncProducerAttachmentRetention();
    await _clearDraft();
  }

  void _maybeDiscardFailedTurnFromExplicitEmptyComposer() {
    if (_restoringDraft ||
        _composerSubmissionInFlight ||
        _textController.text.isNotEmpty ||
        _pendingAttachments.isNotEmpty) {
      return;
    }
    final prepared = _preparedTurn;
    if (prepared == null ||
        prepared.state != PreparedTurnState.failedBeforeAcceptance ||
        !prepared.restoresComposer ||
        _composerPreparedTurnClientTurnId != prepared.clientTurnId ||
        _failedTurnDiscardInFlightId != null) {
      return;
    }
    // Se fija antes del primer await: ningún debounce, lifecycle flush o
    // successor puede heredar por accidente la autoridad de P0.
    _failedTurnDiscardInFlightId = prepared.storageId;
    _composerPreparedTurnClientTurnId = null;
    unawaited(_discardFailedTurnFromEmptyComposer(prepared));
  }

  Future<void> _discardFailedTurnFromEmptyComposer(
    PreparedTurn prepared,
  ) async {
    var discarded = false;
    try {
      final live = _chatBound ? _chat.activeTurnDelivery : null;
      final observed = live?.current.storageId == prepared.storageId
          ? live
          : _attachmentDelivery?.current.storageId == prepared.storageId
          ? _attachmentDelivery
          : null;
      if (observed != null) {
        discarded = await observed.discardFailedBeforeAcceptance();
        if (discarded && identical(live, observed)) {
          _chat.releaseTurnDelivery(observed);
        }
      } else {
        discarded = await (await _outboxStore()).discardFailedBeforeAcceptance(
          prepared,
        );
      }
    } catch (error) {
      debugPrint(
        '[turn-outbox] rejected discard failed (${error.runtimeType})',
      );
    }
    if (!discarded) {
      if (_preparedTurn?.storageId == prepared.storageId &&
          _composerPreparedTurnClientTurnId == null) {
        _composerPreparedTurnClientTurnId = prepared.clientTurnId;
      }
      if (_failedTurnDiscardInFlightId == prepared.storageId) {
        _failedTurnDiscardInFlightId = null;
      }
      return;
    }

    if (_preparedTurn?.storageId == prepared.storageId) {
      _preparedTurn = null;
    }
    if (_attachmentDelivery?.current.storageId == prepared.storageId) {
      _observeAttachmentDelivery(null);
    }
    final removedProjection = _removeLatestFailedPromptProjection(
      prepared.fullText,
    );
    final composerStillEmpty =
        !mounted ||
        (_textController.text.isEmpty && _pendingAttachments.isEmpty);
    if (mounted && removedProjection) {
      setState(() {
        if (_pipelineState == ChatPipelineState.failed) {
          _pipelineState = ChatPipelineState.idle;
        }
      });
    }
    // El tombstone ya es autoritativo. Este clear exacto solo compacta el
    // segundo store; si Android corta aquí, restore suprime el draft enlazado.
    if (composerStillEmpty) await _clearDraft();
    if (_failedTurnDiscardInFlightId == prepared.storageId) {
      _failedTurnDiscardInFlightId = null;
    }
  }

  Future<void> _retireProducerAttachments(
    List<AttachmentDraft> attachments,
  ) async {
    final store =
        _draftStore ?? ChatDraftStore(await SharedPreferences.getInstance());
    _draftStore ??= store;
    await store.retireAttachments(attachments);
  }

  void _syncProducerAttachmentRetention() {
    final current = _producerAttachmentOwner;
    if (_pendingAttachments.isNotEmpty) {
      if (current == null) {
        _producerAttachmentOwner =
            AttachmentOwnershipCoordinator.retainProducer(_pendingAttachments);
      } else {
        AttachmentOwnershipCoordinator.updateProducerRetention(
          current,
          _pendingAttachments,
        );
      }
      return;
    }
    if (current == null) return;
    _producerAttachmentOwner = null;
    unawaited(
      AttachmentOwnershipCoordinator.releaseProducer(
        current,
        _retireProducerAttachments,
      ),
    );
  }

  void _scheduleDraftSave() {
    _syncProducerAttachmentRetention();
    if (_restoringDraft) return;
    _draftTimer?.cancel();
    final text = _textController.text;
    final attachments = List<AttachmentDraft>.of(_pendingAttachments);
    final preparedTurnClientTurnId = _composerPreparedTurnClientTurnId;
    if (text.isEmpty &&
        attachments.isEmpty &&
        _failedTurnDiscardInFlightId != null) {
      // El clear de draft nunca adelanta al tombstone durable.
      return;
    }
    _draftTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(
        _saveDraftSnapshot(
          text,
          attachments,
          preparedTurnClientTurnId: preparedTurnClientTurnId,
          preparedTurnAuthorityCaptured: true,
        ),
      );
    });
  }

  Future<bool> _saveDraftSnapshot(
    String text,
    List<AttachmentDraft> attachments, {
    String? preparedTurnClientTurnId,
    bool preparedTurnAuthorityCaptured = false,
    bool finalDisposeSnapshot = false,
  }) async {
    if (widget.connection.readOnly) return false;
    if (_disposed && !finalDisposeSnapshot) return false;
    // Leaving during secure restore must not replace unread content with empty UI.
    if (!_draftLoaded &&
        text.isEmpty &&
        attachments.isEmpty &&
        !_composerEmptiedByUser) {
      return false;
    }
    final previous = _draftSnapshotTail;
    final completed = Completer<void>();
    _draftSnapshotTail = completed.future;
    try {
      final recoveryId = _draftRecoverySessionId;
      _authorizeDraftDestination(recoveryId);
      final retiredId = _isBotChatSurface
          ? null
          : recoveryId == widget.session.id
          ? _normalCanonicalDraftId
          : widget.session.id;
      // Admit both keys before waiting, so session cleanup sees queued saves.
      final store =
          _draftStore ?? ChatDraftStore(await SharedPreferences.getInstance());
      _draftStore ??= store;
      final saved = store.save(
        widget.connection.id,
        recoveryId,
        text,
        attachments,
        profile: _recoveryProfile,
        preparedTurnClientTurnId: preparedTurnAuthorityCaptured
            ? preparedTurnClientTurnId
            : preparedTurnClientTurnId ?? _composerPreparedTurnClientTurnId,
        lifecycle: _localConversationLifecycle,
        afterSave: previous.then((_) => true),
      );
      final saves = <Future<bool>>[saved];
      if (retiredId != null && retiredId != recoveryId) {
        // Both directions use only the proven create mapping. An unresolved
        // turn stays with its provisional outbox; ACK moves free drafts back.
        saves.add(
          store.save(
            widget.connection.id,
            retiredId,
            '',
            const [],
            profile: _recoveryProfile,
            lifecycle: _localConversationLifecycle,
            afterSave: saved,
          ),
        );
      }
      return (await Future.wait(saves)).every((committed) => committed);
    } catch (error) {
      // El borrador puede contener secretos: no se degrada a almacenamiento en
      // claro ni se incluye el error del plugin en logs.
      debugPrint(
        '[chat-draft] secure persistence failed (${error.runtimeType})',
      );
      return false;
    } finally {
      await previous;
      completed.complete();
    }
  }

  Future<bool> _clearDraft() async {
    _draftTimer?.cancel();
    if (widget.connection.readOnly) return true;
    if (!_isBotChatSurface) {
      return _saveDraftSnapshot('', const []);
    }
    try {
      final store =
          _draftStore ?? ChatDraftStore(await SharedPreferences.getInstance());
      _draftStore ??= store;
      await store.clear(
        widget.connection.id,
        _draftRecoverySessionId,
        profile: _recoveryProfile,
      );
      return true;
    } catch (error) {
      debugPrint('[chat-draft] secure cleanup failed (${error.runtimeType})');
      return false;
    }
  }

  /// El DELETE puede usar un ID persistido por Desktop distinto del ID móvil
  /// con el que esta pantalla guardó draft/outbox. Esta limpieza usa de forma
  /// deliberada la identidad local y solo se invoca tras éxito remoto.
  Future<void> _clearDeletedChatRecovery(String localSessionId) async {
    final activeChats = context
        .findAncestorStateOfType<HermesAppState>()
        ?.activeChats;
    try {
      final prefs = await SharedPreferences.getInstance();
      final drafts =
          _draftStore ?? widget.draftStoreOverride ?? ChatDraftStore(prefs);
      final outbox = TurnOutboxStore(lifecycle: _localConversationLifecycle);
      final aliases = <String>{
        localSessionId,
        _draftRecoverySessionId,
        ..._draftRecoveryAliases,
        _chat.serverSessionId,
      }..removeWhere((id) => id.isEmpty);
      for (final alias in aliases) {
        await drafts.clear(
          widget.connection.id,
          alias,
          profile: _recoveryProfile,
          includeUnscoped: true,
        );
        await outbox.deleteForChat(
          widget.connection.id,
          alias,
          profile: _recoveryProfile,
        );
      }
      await activeChats?.clearCancelledTurnsForSession(
        connectionId: widget.connection.id,
        profile: _recoveryProfile,
        sessionId: _chat.logicalSessionId,
      );
    } catch (error) {
      debugPrint(
        '[chat-delete] recovery cleanup failed (${error.runtimeType})',
      );
    }
  }

  Future<TurnOutboxStore> _outboxStore() async {
    final store =
        _turnOutbox ?? TurnOutboxStore(lifecycle: _localConversationLifecycle);
    _turnOutbox = store;
    return store;
  }

  void _observeAttachmentDelivery(ActiveTurnDelivery? delivery) {
    if (identical(_attachmentDelivery, delivery)) return;
    _attachmentDelivery?.removeAttachmentListener(_attachmentListener);
    _attachmentDelivery = delivery;
    delivery?.addAttachmentListener(
      _attachmentListener,
      notifyImmediately: true,
    );
  }

  void _applyAttachmentProjection(List<AttachmentDraft> projected) {
    if (_disposed || !mounted || _pendingAttachments.isEmpty) {
      return;
    }
    final byId = <String, AttachmentDraft>{
      for (final item in projected)
        if (item.localId.isNotEmpty) item.localId: item,
    };
    if (byId.isEmpty) return;
    var matchedVisibleItem = false;
    final next = <AttachmentDraft>[];
    for (final visible in _pendingAttachments) {
      final updated = byId[visible.localId];
      if (updated == null) {
        next.add(visible);
        continue;
      }
      matchedVisibleItem = true;
      if (updated.uploadState != AttachmentUploadState.removed) {
        next.add(updated);
      }
    }
    if (!matchedVisibleItem) return;
    setState(() {
      _pendingAttachments
        ..clear()
        ..addAll(next);
    });
    final delivery = _attachmentDelivery;
    if (delivery != null) _preparedTurn = delivery.current;
    _scheduleDraftSave();
  }

  Future<ActiveTurnDelivery?> _attachmentDeliveryForMutation() async {
    final live = _chatBound ? _chat.activeTurnDelivery : null;
    if (live != null) {
      _observeAttachmentDelivery(live);
      return live;
    }
    final current = _attachmentDelivery;
    if (current != null) return current;
    final prepared = _preparedTurn;
    if (prepared == null) return null;
    final restored = ActiveTurnDelivery(
      prepared: prepared,
      store: await _outboxStore(),
    );
    _observeAttachmentDelivery(restored);
    return restored;
  }

  Future<void> _removePendingAttachment(String localId) async {
    final delivery = await _attachmentDeliveryForMutation();
    if (delivery != null &&
        delivery.current.attachments.any((item) => item.localId == localId)) {
      if (identical(delivery, _chat.activeTurnDelivery)) {
        await _chat.removeActiveAttachment(localId);
      } else {
        await delivery.removeAttachment(localId);
      }
      _applyAttachmentProjection(delivery.current.attachments);
      _maybeDiscardFailedTurnFromExplicitEmptyComposer();
      return;
    }
    if (!mounted) return;
    final removed = _pendingAttachments.indexWhere(
      (item) => item.localId == localId,
    );
    if (removed < 0) return;
    final removedAttachment = _pendingAttachments[removed];
    setState(() {
      _pendingAttachments.removeAt(removed);
    });
    _maybeDiscardFailedTurnFromExplicitEmptyComposer();
    _scheduleDraftSave();
    // Puede retirarse antes de que el primer autosave llegue a referenciar la
    // copia privada. En esa ventana el store no tiene un snapshot anterior que
    // limpiar; el owner localId hace que rutas externas o de otro chip fallen
    // cerrado en AttachmentUploader.
    await _deletePrivateAttachmentCopy(removedAttachment);
  }

  Future<void> _retryPendingAttachment(String localId) async {
    final delivery = await _attachmentDeliveryForMutation();
    if (delivery == null) return;
    await delivery.retryAttachment(localId);
    _applyAttachmentProjection(delivery.current.attachments);
  }

  Future<bool> _persistPreparedTurn(
    TurnOutboxStore outbox,
    PreparedTurn turn,
  ) async {
    try {
      await outbox.save(turn);
      _preparedTurn = turn;
      return true;
    } catch (error) {
      // Fail-closed: antes del ACK nunca se envía si no podemos conservar la
      // evidencia local. No se imprime texto, ruta, sesión ni detalle del error.
      debugPrint('[turn-outbox] secure write failed (${error.runtimeType})');
      return false;
    }
  }

  void _showOutboxUnavailable() {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).chaOutboxUnavailable)),
      kind: HermesNoticeKind.warning,
    );
  }

  /// Fija una sola vez el perfil propietario de la sesión.
  ///
  /// Una fila persistida manda siempre. Solo los borradores legacy sin sello
  /// capturan `active_profile_<connId>` al enlazarse; cambios posteriores de la
  /// preferencia global no pueden mover esta conversación a otro perfil.
  Future<void> _loadActiveProfile() async {
    try {
      // Deja que didChangeDependencies enlace primero el ActiveChat. Así una
      // sesión ya viva aporta su owner antes de consultar cualquier fallback.
      await Future<void>.value();
      var owner = widget.session.profile?.trim() ?? '';
      if (_chatBound && _chat.sessionProfile.isNotEmpty) {
        owner = _chat.sessionProfile;
      }
      if (owner.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        owner = Session.profileOwner(
          null,
          fallback: prefs.getString('active_profile_${widget.connection.id}'),
        );
      }
      if (!mounted) return;
      if (_chatBound) owner = _chat.bindSessionProfile(owner);
      // El perfil por defecto no es un "contexto especial": sin chip para él.
      final show = owner.isNotEmpty && owner != 'default';
      setState(() => _activeProfile = show ? owner : null);
    } catch (_) {
      // Sin perfil → sin chip; no es crítico.
    }
  }

  void _onComposerChanged() {
    final text = _textController.text;
    if (_isRecording || _transcribing) {
      return;
    }
    final isEmpty = text.isEmpty;
    // Intención explícita del usuario sobre ESTE composer. Los vaciados
    // programáticos (restaurar, descartar, soltar el lote al enviar) ya se
    // envuelven en `_restoringDraft` y no la marcan.
    if (isEmpty && !_restoringDraft) _composerEmptiedByUser = true;
    final suggestions = slashSuggestionsFor(text, Strings.of(context));
    final changed =
        isEmpty != _composerEmpty ||
        suggestions.length != _slashSuggestions.length ||
        (suggestions.isNotEmpty &&
            _slashSuggestions.isNotEmpty &&
            suggestions.first.name != _slashSuggestions.first.name);
    if (changed) {
      setState(() {
        _composerEmpty = isEmpty;
        _slashSuggestions = suggestions;
      });
    }
    _slashCompletionDebounce?.cancel();
    final completionEpoch = ++_slashCompletionEpoch;
    if (text.startsWith('/') &&
        !text.contains(RegExp(r'\s')) &&
        text.length <= 65) {
      _slashCompletionDebounce = Timer(
        const Duration(milliseconds: 150),
        () => unawaited(_refreshDesktopSlashSuggestions(text, completionEpoch)),
      );
    }
    _maybeDiscardFailedTurnFromExplicitEmptyComposer();
    _scheduleDraftSave();
  }

  Future<bool> _useAssistantSuggestion(
    Map<String, dynamic> sourceMessage,
    String suggestion,
  ) async {
    // Revalidamos al pulsar: el árbol puede seguir visible durante el frame en
    // que empieza otro run o el usuario crea un draft. Una sugerencia nunca se
    // convierte en steering ni se mezcla con texto/adjuntos existentes.
    final allowed = canOfferAssistantSuggestions(
      isLatestAssistant: _isLatestAssistant(sourceMessage),
      isTerminal: sourceMessage['_cancelled'] != true,
      chatBusy:
          _interactiveMessageRefreshPending ||
          _sending ||
          _attachmentSubmitting ||
          _compressingSession,
      writable: !widget.connection.readOnly,
      composerEmpty: _textController.text.trim().isEmpty,
      attachmentsEmpty: _pendingAttachments.isEmpty,
    );
    if (!allowed) return false;
    return _sendMessage(initialText: suggestion);
  }

  Future<DesktopCommandCatalog?> _loadDesktopCommandCatalog() async {
    final cached = _desktopCommandCatalog;
    if (cached != null) return cached;
    try {
      final catalog = await _chat.loadDesktopCommandCatalog();
      if (!_disposed && mounted && catalog != null) {
        _desktopCommandCatalog = catalog;
      }
      return catalog;
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshDesktopSlashSuggestions(
    String input,
    int completionEpoch,
  ) async {
    final catalog = await _loadDesktopCommandCatalog();
    SlashCompletionBatch? completion;
    try {
      completion = await _chat.completeDesktopSlash(input);
    } catch (_) {
      // El catálogo sigue siendo un fallback válido para Gateway modernos que
      // no publiquen complete.slash.
    }
    if (_disposed ||
        !mounted ||
        completionEpoch != _slashCompletionEpoch ||
        _textController.text != input) {
      return;
    }

    final strings = Strings.of(context);
    final local = slashSuggestionsFor(input, strings);
    final byName = <String, SlashCommand>{
      for (final item in local) item.name: item,
    };
    final prefix = input.substring(1).toLowerCase();
    final catalogByName = <String, CommandCatalogEntry>{
      for (final item in catalog?.commands ?? const <CommandCatalogEntry>[])
        item.canonicalName: item,
    };

    final candidates = completion?.suggestions
        .map((item) => item.replacement.trim().split(RegExp(r'\s+')).first)
        .map(CommandDescriptor.tryNormalizeName)
        .whereType<String>();
    final names =
        candidates ??
        catalogByName.keys.where((name) => name.startsWith(prefix));
    for (final name in names) {
      if (isUnavailableSlashName(name) || byName.containsKey(name)) continue;
      final entry = catalogByName[name];
      // Una completion desconocida puede mostrarse, pero al enviar se vuelve a
      // resolver contra el catálogo y no adquiere disponibilidad por aparecer.
      String? meta;
      for (final item
          in completion?.suggestions ?? const <SlashCompletionSuggestion>[]) {
        final suggestionName = CommandDescriptor.tryNormalizeName(
          item.replacement.trim().split(RegExp(r'\s+')).first,
        );
        if (suggestionName == name) {
          meta = item.meta;
          break;
        }
      }
      byName[name] = SlashCommand.remote(
        name: name,
        description: entry?.description ?? meta ?? '',
      );
      if (byName.length >= 20) break;
    }
    setState(() => _slashSuggestions = byName.values.toList(growable: false));
  }

  /// No hay nada que enviar: ni texto ni adjunto en cola. Un adjunto solo (sin
  /// texto) ya es enviable, así que el botón debe pasar a modo "enviar".
  bool get _nothingToSend => _composerEmpty && _pendingAttachments.isEmpty;

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final defaultProfile = _sessionPreferenceProfile == 'default';
    final legacyModel = defaultProfile
        ? prefs.getString(_legacyConnectionSessionModelKey)
        : null;
    final scopedModel = prefs.getString(_sessionModelKey);
    final model = scopedModel ?? legacyModel ?? 'hermes-agent';
    final provider =
        prefs.getString(_sessionProviderKey) ??
        (defaultProfile
            ? prefs.getString(_legacyConnectionSessionProviderKey)
            : null) ??
        '';
    final rawReasoning = prefs.getString(_sessionReasoningKey);
    final rawFast = prefs.getString(_sessionFastKey);
    DesktopReasoningEffort? reasoning;
    for (final value in DesktopReasoningEffort.values) {
      if (value.wire == rawReasoning) reasoning = value;
    }
    DesktopFastMode? fastMode;
    for (final value in DesktopFastMode.values) {
      if (value.wire == rawFast) fastMode = value;
    }
    setState(() {
      _devDiagnostics = prefs.getBool('dev_diagnostics') ?? false;
      final header = headerTitleNotifier.value.trim();
      if (header.isNotEmpty) _agentName = header;
      _selectedModel = model;
      _selectedProvider = provider;
      _selectedReasoning = reasoning;
      _selectedFastMode = fastMode;
    });
    if (scopedModel == null && legacyModel != null) {
      await Future.wait([
        prefs.setString(_sessionModelKey, legacyModel),
        if (provider.isNotEmpty) prefs.setString(_sessionProviderKey, provider),
      ]);
    }
    if (_chatBound) {
      _chat.stageFirstSubmitConfig(_firstSubmitConfig);
      _chatService.updateHomeWidgetSessionMetadata(
        _chat,
        model: _selectedModel,
        provider: _selectedProvider,
      );
    }
  }

  String get _sessionPreferenceProfile =>
      Session.profileOwner(widget.session.profile);
  String get _legacyConnectionSessionScope =>
      '${widget.connection.id}_${widget.session.id}';
  String get _sessionPreferenceScope =>
      '${widget.connection.id}_${_sessionPreferenceProfile}_${widget.session.id}';
  String get _sessionModelKey => 'selected_model_$_sessionPreferenceScope';

  String get _legacyConnectionSessionModelKey =>
      'selected_model_$_legacyConnectionSessionScope';
  String get _legacyConnectionSessionProviderKey =>
      'selected_provider_$_legacyConnectionSessionScope';
  String get _sessionProviderKey =>
      'selected_provider_$_sessionPreferenceScope';
  String get _sessionReasoningKey =>
      'selected_reasoning_$_sessionPreferenceScope';
  String get _sessionFastKey => 'selected_fast_$_sessionPreferenceScope';

  DesktopModelSelection? get _selectedModelPair {
    if (_selectedProvider.isEmpty ||
        _selectedProvider == 'gateway' ||
        _selectedModel.isEmpty ||
        _selectedModel == 'hermes-agent') {
      return null;
    }
    try {
      return DesktopModelSelection(
        modelId: _selectedModel,
        providerSlug: _selectedProvider,
      );
    } on FormatException {
      return null;
    }
  }

  DesktopSessionCreateConfig get _firstSubmitConfig {
    final source = widget.session.source.trim().toLowerCase();
    final createsBotChat = source == 'mobile-bot' || source == 'bot-mode-local';
    final resumesStoredBotChat =
        source == 'bot-mode' || source == 'bot-mode-canonical';
    return DesktopSessionCreateConfig(
      model: _selectedModelPair,
      reasoningEffort: _selectedReasoning,
      fastMode: _selectedFastMode,
      title: createsBotChat ? 'Bot Chat' : null,
      hidden: createsBotChat,
      createIfMissing: !resumesStoredBotChat,
      // Bot surfaces own a durable canonical pin. Their -32601 compatibility
      // fallback is handled by the pin hook itself; falling back to REST here
      // would submit without the verified pin after an RMW failure.
      allowTransportFallback:
          widget.connection.kind == InstanceKind.localhost &&
          widget.connection.onDeviceLoopback &&
          !resumesStoredBotChat &&
          !createsBotChat,
    );
  }

  // ── Configuración efectiva de esta sesión ─────────────────────────────────
  // Hermes 0.19 publica el valor efectivo en `session.info`; el catálogo puede
  // venir del Dashboard/Bridge, pero una selección del chat nunca cambia el
  // default global.

  /// Modelo efectivo de esta conversación (o herencia mientras es borrador).
  ModelActiveInfo? _activeModel;
  bool _settingModel = false;

  /// Perfil de agente activo para esta instancia (vacío/null = por defecto).
  /// Solo informativo en el chat: el gateway sirve un único home, así que el
  /// perfil se refleja en el chat por su MODELO (aplicado al activarlo en
  /// Perfiles); el chip avisa de qué perfil está en contexto.
  String? _activeProfile;
  late final Future<void> _profileReady;
  String get _effectiveSessionProfile {
    if (_chatBound && _chat.sessionProfile.isNotEmpty) {
      return _chat.sessionProfile;
    }
    return Session.profileOwner(
      widget.session.profile,
      fallback: _activeProfile,
    );
  }

  Future<(ModelActiveInfo, List<ModelProvider>)>? _modelOptionsFuture;
  DesktopModelCatalog? _desktopModelCatalog;

  /// Modelo que debe pintar esta sesión mientras haya una elección del usuario
  /// registrada en el reducer de config.
  ///
  /// Hermes Desktop pinta el pick de forma optimista en cuanto el `config.set`
  /// es aceptado y solo lo revierte ante un rechazo real del RPC. Un
  /// `session.info` emitido antes de que el servidor aplique el cambio (p.ej.
  /// un switch diferido a mitad de turno) sigue reportando el modelo anterior,
  /// así que una confirmación cuyo valor autoritativo coincide con el efectivo
  /// previo se trata como obsoleta y NO repinta la cabecera. Si el info
  /// reporta un modelo distinto tanto del pedido como del previo, es un cambio
  /// efectivo en el servidor y sí reconcilia.
  SessionModelConfigValue? get _displayedSessionModel {
    if (!_chatBound) return null;
    final pending = _chat.pendingSessionConfigChange(
      DesktopSessionConfigKey.model,
    );
    if (pending == null) return null;
    final value = pending.displayValue;
    return value is SessionModelConfigValue ? value : null;
  }

  /// Etiqueta corta del modelo activo para el AppBar (p.ej. "GPT-5.5"). Cae a un
  /// texto neutro mientras carga o si el Dashboard no está accesible.
  String get _activeModelLabel {
    final model = _displayedSessionModel?.modelId ?? _activeModel?.model;
    if (model == null || model.isEmpty || model == 'hermes-agent') {
      return Strings.of(context).chaModelServer;
    }
    return friendlyModelName(model);
  }

  void _syncDesktopSessionConfig() {
    if (!_chatBound) return;
    final info = _chat.desktopRuntimeInfo;
    final effective = _chat.effectiveSessionConfig;
    final model = effective.model ?? info.model;
    final provider = effective.provider ?? info.provider;
    if (model != null && model.isNotEmpty) {
      _activeModel = ModelActiveInfo(
        model: model,
        provider: provider ?? '',
        effectiveContextLength: info.usage?.contextMax ?? 0,
      );
    }

    final displayedModel = _displayedSessionModel;
    if (displayedModel != null) {
      _selectedModel = displayedModel.modelId;
      _selectedProvider = displayedModel.providerSlug ?? provider ?? '';
    } else if (model != null && model.isNotEmpty) {
      _selectedModel = model;
      _selectedProvider = provider ?? '';
    }

    final reasoning = effective.reasoningEffort ?? info.reasoningEffort;
    if (reasoning != null) {
      for (final value in DesktopReasoningEffort.values) {
        if (value.wire == reasoning) _selectedReasoning = value;
      }
    }
    final fast = effective.fast ?? info.fast;
    if (fast != null) {
      _selectedFastMode = fast ? DesktopFastMode.fast : DesktopFastMode.normal;
    }
  }

  /// Keeps context chrome on its own listenable. `session.info` can publish a
  /// new live occupancy without rebuilding the transcript or composer.
  void _commitSessionContextMetrics(SessionContextMetrics metrics) {
    if (_sessionContextMetrics.value != metrics) {
      _sessionContextMetrics.value = metrics;
    }
    if (_chatBound) {
      _chatService.updateHomeWidgetSessionContext(
        _chat,
        contextUsed: metrics.contextUsed,
        contextMax: metrics.contextMax,
        contextPercent: metrics.percent,
      );
    }
  }

  void _syncSessionContextMetrics({bool preserveKnownWindow = false}) {
    var next = SessionContextMetrics.fromUsage(
      _chat.desktopRuntimeInfo.usage,
      sessionFallback: _sessionUsageSnapshot,
      observedFirstTokenLatencyMs: _chat.observedFirstTokenLatencyMs,
    );
    if (preserveKnownWindow &&
        !next.hasWindow &&
        _sessionContextMetrics.value.hasWindow) {
      final current = _sessionContextMetrics.value;
      next = SessionContextMetrics(
        contextUsed: current.contextUsed,
        contextMax: current.contextMax,
        percent: current.percent,
        cumulativeTotal: next.cumulativeTotal,
        inputTokens: next.inputTokens,
        cacheReadTokens: next.cacheReadTokens,
        cacheWriteTokens: next.cacheWriteTokens,
        observedFirstTokenLatencyMs: next.observedFirstTokenLatencyMs,
      );
    }
    _commitSessionContextMetrics(next);
  }

  Future<void> _refreshPublishedSessionUsage({bool force = false}) {
    if (_disposed || !mounted || !_chatBound) return Future<void>.value();
    // Un draft `mob-*` todavía no existe en state.db. Consultar su detalle
    // siempre devuelve 404 y ensucia cada entrada por voz con una falsa
    // excepción de contexto. Tras el primer envío hay mensajes/runtime real y
    // el refresh forzado vuelve a usar la identidad persistida autoritativa.
    if (widget.session.isUnpersistedMobileDraft &&
        !_chat.hasDesktopRuntime &&
        _chat.messages.isEmpty) {
      return Future<void>.value();
    }
    final inFlight = _sessionUsageRefreshInFlight;
    if (inFlight != null) return inFlight;
    final refreshedAt = _sessionUsageRefreshedAt;
    if (!force &&
        refreshedAt != null &&
        DateTime.now().difference(refreshedAt) < const Duration(seconds: 5)) {
      return Future<void>.value();
    }

    final refresh = () async {
      try {
        final snapshot = await _chat.loadPersistedSessionSnapshot();
        if (_disposed || !mounted || snapshot == null) return;
        _sessionUsageSnapshot = snapshot;
        _sessionUsageRefreshedAt = DateTime.now();
        _chatService.updateHomeWidgetSessionMetadata(_chat, session: snapshot);
        _syncSessionContextMetrics(preserveKnownWindow: true);
      } catch (error) {
        debugPrint(
          '[chat-context] Persisted usage snapshot unavailable '
          '(${error.runtimeType})',
        );
      }
    }();
    _sessionUsageRefreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_sessionUsageRefreshInFlight, refresh)) {
        _sessionUsageRefreshInFlight = null;
      }
    });
  }

  Future<DesktopContextBreakdown?> _loadSessionContextDetails() async {
    await _refreshPublishedSessionUsage();
    return _chat.loadDesktopContextBreakdown();
  }

  /// Warms the Desktop channel and fills the compact gauge once when
  /// `session.info` has not published a real context window yet. This is a
  /// single gateway snapshot, never a poll and never a model invocation.
  Future<void> _ensureDesktopRuntimeAndBootstrapContext() async {
    if (_disposed ||
        !mounted ||
        !_chatRouteVisible ||
        !_appInForeground ||
        !_chat.attachesDesktopRuntimeOnLoad) {
      return;
    }
    final generation = _viewerAttachGeneration;
    bool stillOwningVisible() =>
        !_disposed &&
        mounted &&
        _chatRouteVisible &&
        _appInForeground &&
        generation == _viewerAttachGeneration;
    try {
      if (_chat.desktopRuntimeSessionId == null &&
          !await _chat.attachExistingRuntimeViewer(
            stillOwningVisible: stillOwningVisible,
          )) {
        return;
      }
      if (!stillOwningVisible()) return;
      _syncSessionContextMetrics(preserveKnownWindow: true);
      await _bootstrapSessionContextForCurrentRuntime();
    } catch (error) {
      debugPrint(
        '[chat-context] Initial context snapshot unavailable '
        '(${error.runtimeType})',
      );
    }
  }

  /// Loads one initial snapshot for each runtime identity. A mobile draft has
  /// no runtime until its first submit, so the `connected` event retries here
  /// without polling or creating a session just to populate the gauge.
  Future<void> _bootstrapSessionContextForCurrentRuntime() async {
    if (_disposed || !mounted) return;
    final runtimeId = _chat.desktopRuntimeSessionId;
    final viewerGeneration = _viewerAttachGeneration;
    if (runtimeId == null || runtimeId == _sessionContextBootstrapRuntimeId) {
      return;
    }
    if (_sessionContextBootstrapInFlightRuntimeId == runtimeId) return;
    _syncSessionContextMetrics();
    if (_sessionContextMetrics.value.hasWindow) {
      _sessionContextBootstrapRuntimeId = runtimeId;
      return;
    }
    _sessionContextBootstrapInFlightRuntimeId = runtimeId;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final breakdown = await _chat.loadDesktopContextBreakdown();
        if (_disposed ||
            !mounted ||
            breakdown == null ||
            _chat.desktopRuntimeSessionId != runtimeId) {
          return;
        }
        final current = _sessionContextMetrics.value;
        // A live session.info received while the snapshot was loading wins.
        if (current.hasWindow) {
          _sessionContextBootstrapRuntimeId = runtimeId;
          return;
        }
        final next = SessionContextMetrics.fromBreakdown(
          breakdown,
          fallback: current,
        );
        if (next.hasWindow) {
          _commitSessionContextMetrics(next);
          _sessionContextBootstrapRuntimeId = runtimeId;
          return;
        }
        if (attempt == 0) {
          final retryAuthorized = await _waitForSessionContextBootstrapRetry(
            runtimeId: runtimeId,
            viewerGeneration: viewerGeneration,
          );
          if (!retryAuthorized ||
              _disposed ||
              !mounted ||
              viewerGeneration != _viewerAttachGeneration ||
              _chat.desktopRuntimeSessionId != runtimeId) {
            return;
          }
        }
      }
    } catch (error) {
      debugPrint(
        '[chat-context] Runtime context snapshot unavailable '
        '(${error.runtimeType})',
      );
    } finally {
      if (_sessionContextBootstrapInFlightRuntimeId == runtimeId) {
        _sessionContextBootstrapInFlightRuntimeId = null;
      }
    }
  }

  Future<bool> _waitForSessionContextBootstrapRetry({
    required String runtimeId,
    required int viewerGeneration,
  }) {
    _cancelSessionContextBootstrapRetry();
    final completer = Completer<bool>();
    _sessionContextBootstrapRetryCompleter = completer;
    late final Timer timer;
    timer = Timer(const Duration(milliseconds: 350), () {
      if (!identical(_sessionContextBootstrapRetryTimer, timer)) return;
      _sessionContextBootstrapRetryTimer = null;
      _sessionContextBootstrapRetryCompleter = null;
      completer.complete(
        !_disposed &&
            mounted &&
            _chatRouteVisible &&
            _appInForeground &&
            viewerGeneration == _viewerAttachGeneration &&
            _chat.desktopRuntimeSessionId == runtimeId,
      );
    });
    _sessionContextBootstrapRetryTimer = timer;
    return completer.future;
  }

  void _cancelSessionContextBootstrapRetry() {
    _sessionContextBootstrapRetryTimer?.cancel();
    _sessionContextBootstrapRetryTimer = null;
    final completer = _sessionContextBootstrapRetryCompleter;
    _sessionContextBootstrapRetryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete(false);
  }

  /// Everything in `session.info` that may change chat chrome, except usage.
  /// Maps are reduced to their stable textual payload because the parser
  /// freezes a fresh map for every event even when its contents are unchanged.
  int _runtimePresentationFingerprint(DesktopSessionRuntimeInfo info) =>
      Object.hashAll([
        info.model,
        info.provider,
        info.reasoningEffort,
        info.serviceTier,
        info.fast,
        info.yolo,
        info.approvalMode,
        info.toolCount,
        info.skillCount,
        info.cwd,
        info.branch,
        info.project?.toString(),
        info.personality,
        info.running,
        info.lazy,
        info.title,
        info.storedSessionId,
        info.desktopContract,
        info.version,
        info.releaseDate,
        info.updateBehind?.toString(),
        info.updateCommand,
        info.profileName,
        info.mcpServerCount,
        info.configWarning,
        info.credentialWarning,
        info.installWarning,
      ]);

  /// Lee el modelo activo para pintar el badge del AppBar. Intenta primero el
  /// BRIDGE (un token, automático: no necesita login del Dashboard) — el mismo
  /// camino que el selector de modelos — y solo si no hay bridge cae al
  /// Dashboard. Así el modelo del servidor se muestra aunque el Dashboard no
  /// esté configurado (antes solo miraba el Dashboard y salía vacío).
  Future<void> _loadActiveModel() async {
    if (_chatBound && _chat.hasDesktopRuntime) {
      _syncDesktopSessionConfig();
      if (_activeModel?.model.isNotEmpty == true) return;
    }
    // 1) Bridge: mismo camino "un token" que la pantalla de Modelos.
    try {
      final viaBridge = await _bridgeModelOptions();
      if (viaBridge != null) {
        final (info, providers) = viaBridge;
        // Punto 2 (spec 028): no mostrar como activo el model.default del
        // servidor (p.ej. claude-opus-4.6 de fábrica) si NINGÚN proveedor
        // tiene credencial detrás — en un servidor virgen sin key el modelo
        // no es usable; el badge cae a "servidor" en vez de fingir uno activo.
        final usable = providers.any((p) => p.authenticated);
        if (info.model.isNotEmpty && usable) {
          if (mounted) {
            setState(() => _activeModel = info);
            if (_chatBound) {
              _chatService.updateHomeWidgetSessionMetadata(
                _chat,
                model: info.model,
                provider: info.provider,
              );
            }
          }
          return;
        }
        if (!usable) return; // hay default declarado pero sin key: no fingir.
      }
    } catch (_) {
      // Sigue con el Dashboard.
    }
    // 2) Fallback: Dashboard (si está configurado/accesible).
    final client = DashboardClient.lazy(widget.connection);
    try {
      final info = await client.getModelInfo();
      if (mounted) {
        setState(() => _activeModel = info);
        if (_chatBound) {
          _chatService.updateHomeWidgetSessionMetadata(
            _chat,
            model: info.model,
            provider: info.provider,
          );
        }
      }
    } catch (_) {
      // El Dashboard puede no estar configurado/accesible: el badge cae al
      // texto neutro. No es fatal para el chat.
    } finally {
      client.close();
    }
  }

  /// Carga modelo activo + proveedores configurados (autenticados y con modelos)
  /// para el selector. Reutiliza el mismo camino que la pantalla de Modelos.
  /// Fija un modelo del GATEWAY localmente: se persiste y se manda en cada
  /// petición (`model:`), y el gateway lo enruta. NO toca el Dashboard, así que
  /// funciona con el mismo token y no se rompe cuando la cookie del dashboard
  /// caduca. Vale igual para instancias remotas y locales.
  Future<void> _stageSessionModel(String providerSlug, String modelId) =>
      _rememberSessionModel(
        providerSlug,
        modelId,
        updateEffectiveDisplay: true,
      );

  Future<void> _rememberSessionModel(
    String providerSlug,
    String modelId, {
    required bool updateEffectiveDisplay,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(_sessionModelKey, modelId),
      prefs.setString(_sessionProviderKey, providerSlug),
    ]);
    if (!mounted) return;
    setState(() {
      _selectedModel = modelId;
      _selectedProvider = providerSlug;
      if (updateEffectiveDisplay) {
        _activeModel = ModelActiveInfo(
          model: modelId,
          provider: providerSlug,
          effectiveContextLength: 0,
        );
      }
      _modelOptionsFuture = null;
    });
    if (_chatBound) {
      _chat.stageFirstSubmitConfig(_firstSubmitConfig);
      _chatService.updateHomeWidgetSessionMetadata(
        _chat,
        model: modelId,
        provider: providerSlug,
      );
    }
  }

  // ── Imágenes generadas por el agente (spec 030) ───────────────────────────
  // El toolset image_gen guarda las imágenes en el servidor y el agente cita
  // su ruta en texto; la burbuja del asistente (`_AssistantMessage`) las
  // detecta y pide su descarga a estos helpers vía el ancestro _ChatScreenState.

  /// ¿El bridge de esta instancia sirve imágenes generadas (>= 1.12.0)? Se
  /// resuelve una sola vez por pantalla y se cachea. Sin bridge/versión vieja
  /// → false (la burbuja muestra la pista de degradación).
  bool? _bridgeImagesSupported;
  DateTime? _bridgeImagesSupportAt;
  Future<bool>? _bridgeImagesSupportFuture;
  Future<String>? _bridgeImageTokenFuture;
  Future<bool> resolveGeneratedImageSupport() async {
    final cached = _bridgeImagesSupported;
    final checkedAt = _bridgeImagesSupportAt;
    if (cached == true) return true;
    if (cached == false &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < const Duration(seconds: 15)) {
      return false;
    }
    final inFlight = _bridgeImagesSupportFuture;
    if (inFlight != null) return inFlight;
    final future = _resolveGeneratedImageSupportOnce();
    _bridgeImagesSupportFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_bridgeImagesSupportFuture, future)) {
        _bridgeImagesSupportFuture = null;
      }
    }
  }

  Future<bool> _resolveGeneratedImageSupportOnce() async {
    bool ok;
    try {
      final check = await BridgeUpdateService.check(widget.connection);
      ok =
          check.reachable &&
          GeneratedImageService.bridgeSupportsImages(check.installed);
    } catch (_) {
      ok = false;
    }
    _bridgeImagesSupported = ok;
    _bridgeImagesSupportAt = DateTime.now();
    return ok;
  }

  Future<String> _bridgeImageToken() async {
    final existing = _bridgeImageTokenFuture;
    if (existing != null) return existing;
    final future = () async {
      final url = widget.connection.derivedBridgeUrl;
      if (url.isEmpty) throw Exception('bridge no configurado');
      final token = await BridgeClient.provision(
        url,
        widget.connection.apiKey.trim(),
      );
      if (token == null || token.isEmpty) {
        throw Exception('bridge no disponible');
      }
      return token;
    }();
    _bridgeImageTokenFuture = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_bridgeImageTokenFuture, future)) {
        _bridgeImageTokenFuture = null;
      }
      rethrow;
    }
  }

  /// Descarga (o reutiliza de caché) el archivo local de una imagen generada
  /// por [basename], vía `GET /bridge/image` con el token del bridge. Lanza si
  /// no hay bridge o la descarga falla (la burbuja lo traduce a estado de error).
  Future<File> downloadGeneratedImage(String basename) {
    return GeneratedImageService.ensureDownloaded(
      widget.connection.id,
      basename,
      fetch: (name) async {
        final url = widget.connection.derivedBridgeUrl;
        if (url.isEmpty) throw Exception('bridge no configurado');
        final token = await _bridgeImageToken();
        final client = BridgeClient(baseUrl: url, token: token);
        try {
          return await client.fetchGeneratedImage(name);
        } finally {
          client.close();
        }
      },
    );
  }

  /// Resolves canonical `MEDIA:` paths through the authenticated Dashboard
  /// managed-files endpoint, then stores them only in app-private cache. This
  /// supports generated files outside Hermes' legacy image cache without
  /// publishing a bearer token or a server-local path to another Android app.
  Future<File> downloadGeneratedMedia(
    GeneratedMediaReference reference, {
    GeneratedMediaProgress? onProgress,
    bool Function()? isCancelled,
  }) {
    final profile = _effectiveSessionProfile;
    final cacheScope = '${widget.connection.id}\u0000$profile';
    final maxBytes = switch (reference.kind) {
      GeneratedMediaKind.image => GeneratedMediaService.maxImageBytes,
      GeneratedMediaKind.video => GeneratedMediaService.maxVideoBytes,
      GeneratedMediaKind.audio ||
      GeneratedMediaKind.file => GeneratedMediaService.maxFileBytes,
    };
    return GeneratedMediaService.ensureDownloaded(
      cacheScope,
      reference,
      fetchServerPathToFileWithProgress:
          (path, destination, reportProgress, downloadCancelled) async {
            final client = DashboardClient.lazy(widget.connection);
            try {
              await client.apiDownloadToFile(
                'files/download?path=${Uri.encodeQueryComponent(path)}',
                destination,
                maxBytes: maxBytes,
                profile: profile,
                timeout: const Duration(minutes: 3),
                onProgress: reportProgress,
                isCancelled: downloadCancelled,
              );
            } finally {
              client.close();
            }
          },
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<(ModelActiveInfo, List<ModelProvider>)> _loadModelOptions() async {
    final (info, providers) = await _loadModelOptionsRaw();
    // Respeta lo que el usuario ocultó en la pantalla de Modelos (spec 028 U-05):
    // esas mismas claves de SharedPreferences se aplican también aquí, para que
    // el selector del chat no muestre proveedores/modelos que el usuario quitó
    // de la vista. Proveedores = slugs; modelos = "slug/modelId".
    try {
      final prefs = await SharedPreferences.getInstance();
      final hiddenProviders =
          (prefs.getStringList('hidden_providers') ?? const []).toSet();
      final hiddenModels = (prefs.getStringList('hidden_models') ?? const [])
          .toSet();
      if (hiddenProviders.isEmpty && hiddenModels.isEmpty) {
        return (info, providers);
      }
      final filtered = <ModelProvider>[];
      for (final p in providers) {
        if (hiddenProviders.contains(p.slug)) continue;
        final models = p.models.where(
          (m) => !hiddenModels.contains('${p.slug}/$m'),
        );
        filtered.add(p.copyWith(models: models.toList()));
      }
      return (info, filtered);
    } catch (_) {
      // Prefs ilegibles: no filtramos (peor que mostrar de más sería ocultar
      // todo por un fallo de lectura).
      return (info, providers);
    }
  }

  Future<(ModelActiveInfo, List<ModelProvider>)> _loadModelOptionsRaw() async {
    // 1) RPC oficial 0.19 para una sesión viva. Nunca crea runtimes solo para
    // listar: los borradores degradan a las superficies de lectura existentes.
    final desktop = await _desktopSessionModelOptions();
    if (desktop != null) {
      _modelSource = _ModelSource.desktop;
      return desktop;
    }
    _desktopModelCatalog = null;

    // 2) BRIDGE: un SOLO token (auto-provisionado desde la API key del
    // gateway) lista TODOS los modelos configurados, sin el login del Dashboard.
    // Es el camino que recupera la experiencia "un token, automático".
    final bridge = await _bridgeModelOptions();
    if (bridge != null) {
      _modelSource = _ModelSource.bridge;
      return bridge;
    }
    // 3) DASHBOARD (con su propio login si lo exige).
    final client = DashboardClient.lazy(widget.connection);
    try {
      final info = await client.getModelInfo();
      final providers = await client.getModelOptions();
      final usable = providers
          .where((p) => p.authenticated && p.models.isNotEmpty)
          .toList();
      if (usable.isNotEmpty) {
        _modelSource = _ModelSource.dashboard;
        return (info, usable);
      }
      // El Dashboard respondió pero sin proveedores usables: prueba el gateway.
      final gw = await _gatewayModelOptions();
      if (gw != null) {
        _modelSource = _ModelSource.gateway;
        return gw;
      }
      _modelSource = _ModelSource.dashboard;
      return (info, usable);
    } catch (_) {
      // 4) GATEWAY como último recurso: /v1/models (alias hermes-agent) + tags
      // Ollama; enruta el modelo por petición con el mismo token.
      final fb = await _gatewayModelOptions();
      if (fb != null) {
        _modelSource = _ModelSource.gateway;
        return fb;
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<(ModelActiveInfo, List<ModelProvider>)?>
  _desktopSessionModelOptions() async {
    try {
      final catalog = await _chat.loadDesktopModelCatalog();
      if (catalog == null) return null;
      final providers = <ModelProvider>[
        for (final provider in catalog.providers)
          if (provider.models.isNotEmpty)
            ModelProvider(
              slug: provider.slug,
              name: provider.name,
              isCurrent: provider.isCurrent,
              authenticated: provider.authenticated == true,
              authType: provider.authType ?? '',
              oauthProviderId: '',
              keyEnv: provider.keyEnv ?? '',
              warning: provider.warning ?? '',
              models: provider.models,
            ),
      ];
      if (providers.isEmpty) return null;
      _desktopModelCatalog = catalog;
      return (
        ModelActiveInfo(
          model: catalog.currentModel ?? _selectedModel,
          provider: catalog.currentProvider ?? _selectedProvider,
          effectiveContextLength: 0,
        ),
        providers,
      );
    } catch (_) {
      return null;
    }
  }

  /// Catálogo de modelos vía Mobile Bridge. El token se auto-provisiona desde la
  /// API key del gateway (`/bridge/provision`), así basta UNA credencial y no se
  /// depende del login del Dashboard. Devuelve null si no hay bridge (el llamante
  /// cae al Dashboard). El bridge devuelve la misma forma que `/api/model/options`.
  Future<(ModelActiveInfo, List<ModelProvider>)?> _bridgeModelOptions() async {
    final url = widget.connection.derivedBridgeUrl;
    if (url.isEmpty) return null;
    String? token;
    try {
      token = await BridgeClient.provision(
        url,
        widget.connection.apiKey.trim(),
      );
    } catch (_) {
      return null;
    }
    if (token == null || token.isEmpty) return null;
    final client = BridgeClient(baseUrl: url, token: token);
    try {
      final data = await client.modelOptions();
      if (data['ok'] != true) return null;
      final raw = data['providers'];
      final maps = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) maps.add(e.cast<String, dynamic>());
        }
      } else if (raw is Map) {
        raw.forEach((k, v) {
          if (v is Map) {
            maps.add({'slug': k.toString(), ...v.cast<String, dynamic>()});
          }
        });
      }
      final providers = maps
          .map(ModelProvider.fromJson)
          .where((p) => p.models.isNotEmpty)
          .toList();
      if (providers.isEmpty) return null;
      final info = ModelActiveInfo(
        model: (data['model'] ?? '').toString(),
        provider: (data['provider'] ?? '').toString(),
        effectiveContextLength: 0,
      );
      return (info, providers);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Opciones de modelo a partir SOLO del gateway (con el token de la conexión).
  /// Devuelve null si el gateway tampoco da modelos.
  Future<(ModelActiveInfo, List<ModelProvider>)?> _gatewayModelOptions() async {
    try {
      final api = ApiClient(
        baseUrl: widget.connection.gatewayUrl,
        apiKey: widget.connection.apiKey,
      );
      final results = await Future.wait([
        api.getModels(),
        api.getBackendModels(),
      ]);
      final seen = <String>{};
      final models = <String>[
        for (final m in [...results[0], ...results[1]])
          if (m.isNotEmpty && seen.add(m)) m,
      ];
      if (models.isEmpty) return null;
      final provider = ModelProvider(
        slug: 'gateway',
        name: 'Gateway',
        isCurrent: true,
        authenticated: true,
        authType: '',
        oauthProviderId: '',
        keyEnv: '',
        warning: '',
        models: models,
      );
      final info = ModelActiveInfo(
        model: _selectedModel,
        provider: 'gateway',
        effectiveContextLength: 0,
      );
      return (info, [provider]);
    } catch (_) {
      return null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.findAncestorStateOfType<HermesAppState>()!;
    _voiceService = app.voice;
    // Engancha (una sola vez) el chat activo del servicio singleton. Si ya hay
    // un stream en curso para esta sesión (la dejamos corriendo al salir antes),
    // se reaprovecha y mostramos lo que llegó mientras estábamos fuera.
    if (!_chatBound) {
      _chatBound = true;
      _chatService = app.activeChats;
      _botChatStore = MissionBotChatStore(app.connManager.prefs);
      final resolvedSessionProfile = Session.profileOwner(
        widget.session.profile,
        fallback: app.connManager.activeProfileFor(widget.connection.id),
      );
      _chat = _chatService.attach(
        connection: widget.connection,
        sessionId: widget.session.id,
        logicalSessionId: widget.session.logicalId,
        sessionTitle: widget.session.displayTitle,
        sessionSnapshot: widget.session,
        sessionProfile: resolvedSessionProfile,
        initialStoredSessionId: widget.initialStoredSessionId,
        localConversationLifecycle: _localConversationLifecycle,
        authoritativeStoredSessionBinding: _isBotChatSurface,
        notificationSurface: _isBotChatSurface
            ? NotificationChatSurface.bot
            : NotificationChatSurface.normal,
        selectedProvider: _selectedProvider,
      );
      _passiveConversationReader = ForegroundConversationReader(
        successInterval: const Duration(seconds: 3),
        failureIntervals: const [
          Duration(seconds: 5),
          Duration(seconds: 15),
          Duration(seconds: 30),
          Duration(seconds: 60),
        ],
        changeEventsAvailable: _chat.desktopChangeEventsAvailable,
        durableChatId: () => _chat.serverSessionId,
        externallyOwnedTurnActive: () => _chat.remoteSurfaceOwnsLiveTurn,
        recoveryConverging: () => _chat.resumeReconciliationInFlight,
        canRead: () => _canProbePassiveRemoteActivity,
        read: _refreshPassiveTranscript,
      );
      if (widget.session.isUnpersistedMobileDraft &&
          _chat.messages.isEmpty &&
          !_chat.isStreaming) {
        _chat.markStoredSessionMissing();
      }
      _chat.stageFirstSubmitConfig(_firstSubmitConfig);
      _chatSub = _chat.changes.listen(_onChatEvent);
      _syncStopConfirmationVisibility();
      // Al entrar sobre un turno que ya venía corriendo (volver a la pantalla,
      // resume en frío) no llega ningún evento nuevo hasta el siguiente frame
      // del agente, así que sin esto el cronómetro del turno nunca arrancaba.
      _syncTurnActivityClock();
      _syncCompaction();
      unawaited(_persistBotChatPin());
      unawaited(_loadChatPreferences());
      app.voice.voiceConsent.addListener(_onVoicePreferenceChanged);
      _chat.smoothStreaming = !_reduceMotion;
      _syncSessionContextMetrics();
      _desktopRuntimePresentationFingerprint = _runtimePresentationFingerprint(
        _chat.desktopRuntimeInfo,
      );
      _lastDesktopCompacting = _compressingSession;
      _syncDesktopSessionConfig();
      unawaited(_chat.warmDesktopGatewayForAutomaticBootstrap());
      if (_chat.messagesLoaded) {
        unawaited(_ensureDesktopRuntimeAndBootstrapContext());
        unawaited(_refreshPublishedSessionUsage());
      }
      unawaited(_loadDesktopCommandCatalog());
      unawaited(_chat.loadMentionRoster());
      // Observa el modo voz global: re-renderiza el overlay al cambiar de fase,
      // y muestra el diálogo de "dictado no disponible" cuando el servicio lo
      // pida (necesita un BuildContext, que el servicio no tiene).
      // Pipeline v2 (spec 025) tras flag; el viejo sigue siendo el default.
      _attachVoiceSurface(app);
      // Si volvemos a una sesión con el modo voz ya activo (sobrevivió a la
      // navegación), sincroniza VoiceStage con la fase actual.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onVoiceState();
      });
      if (_chat.isStreaming || _chat.messagesLoaded) {
        // Reengancha a un chat ya vivo o ya cargado: no recargues (clobbearía
        // el parcial en curso).
        // Al volver a una sesión viva materializa el subtree aislado con todo lo
        // que el servicio ya publicó. No espera otro token ni reconstruye el
        // Scaffold para continuar el stream.
        if (_chat.isStreaming) {
          _beginSurfaceTurn();
          _revealedChars = _chat.assistantContent.length;
          if (_currentLiveAssistantMessage() != null) {
            _liveAssistantMaterialized = true;
            _publishLiveAssistantFrame();
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollToBottom(animate: false);
        });
      } else if (widget.session.isUnpersistedMobileDraft) {
        // Un chat recién creado todavía no existe en Hermes. Intentar
        // session.resume + REST aquí solo enseña un loader hasta recibir el
        // 4007 esperado; el borrador local está listo para escribir al instante.
        _chat.messagesLoaded = true;
      } else {
        // A screen created while the app is already backgrounded may perform
        // its one durable read, but it must not connect to or acquire a live
        // runtime until it becomes the owning foreground route.
        _fetchMessages(passiveOnly: !_appInForeground);
      }
      // Fase G: comprueba (una vez) si el bridge de esta instancia está
      // desactualizado y, según el ajuste, lo auto-actualiza o avisa.
      _maybeCheckBridgeUpdate();
    }
    // MediaQuery puede cambiar con la preferencia de accesibilidad del sistema.
    if (_chatBound) _chat.smoothStreaming = !_reduceMotion;
    // Suscríbete al observador global de rutas para saber cuándo esta pantalla
    // es la visible en pila (push/pop). Mientras lo sea, fijamos la sesión
    // visible en la capa de notificaciones: si un evento de ESTE chat llega con
    // la app delante, la UI inline ya lo muestra → no duplicamos con notif del
    // sistema (Regla 1/6). Es idempotente; re-suscribir a la misma ruta es seguro.
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      hermesRouteObserver.subscribe(this, route);
      if (route.isCurrent) _markChatVisible(true);
    }
  }

  /// Keep the latest message visible when the keyboard slides in.
  ///
  /// Lo alimenta [_KeyboardInsetWatcher] (ver [build]), no una lectura de
  /// `MediaQuery.of(context).viewInsets` en [didChangeDependencies]: aquella
  /// suscribía este State entero a cada cambio de `viewInsets`, y Android
  /// anima la entrada/salida del teclado frame a frame, así que CADA frame
  /// reconstruía la pantalla completa (transcript incluido) solo para
  /// reprogramar este temporizador.
  void _onKeyboardBottomInset(double bottomInset) {
    if (_disposed || !mounted || bottomInset <= 0) return;
    // Si ya está al fondo, el resize del viewport mantiene visible el último
    // mensaje. No programes un scroll/setState durante la animación del IME.
    if (_isNearBottom) return;
    _keyboardScrollTimer?.cancel();
    _keyboardScrollTimer = Timer(const Duration(milliseconds: 150), () {
      // El teclado solo ajusta el viewport: nunca invalida las proyecciones del
      // transcript. Estas se reconstruyen exclusivamente cuando cambia el
      // contenido, no por un cambio de `viewInsets`.
      _scrollToBottom(animate: false, invalidateTerminalProjection: false);
    });
  }

  void _onVoicePreferenceChanged() {
    if (mounted) setState(() {});
  }

  bool get _autoReadReplies => switch (_chatPreferences.autoRead) {
    ChatPreferenceToggle.on => true,
    ChatPreferenceToggle.off => false,
    ChatPreferenceToggle.inherit => _voice?.settings.autoSpeak ?? false,
  };

  Future<void> _loadChatPreferences() async {
    // Reserva el epoch antes del primer await. De lo contrario una elección
    // hecha por el usuario mientras SharedPreferences se inicializa podría ser
    // sobrescrita después por esta carga inicial más antigua.
    final epoch = ++_chatPreferenceScopeEpoch;
    final prefs = await SharedPreferences.getInstance();
    final store = ChatPreferenceStore(prefs);
    final logicalId = _desiredChatPreferenceLogicalId;
    await store.load(
      connectionId: widget.connection.id,
      logicalSessionId: logicalId,
      legacySessionIds: {
        widget.session.logicalId,
        widget.session.id,
        ?_chat.storedSessionId,
      },
    );
    // ADR-063 retiró estos overrides del único lugar donde podían revisarse.
    // Eliminar el registro evita que una densidad/autolectura/notificación
    // antigua siga gobernando el chat de forma invisible.
    await store.clear(
      connectionId: widget.connection.id,
      logicalSessionId: logicalId,
    );
    if (_disposed || !mounted || epoch != _chatPreferenceScopeEpoch) return;
    _chatPreferenceStore = store;
    _chatPreferenceLogicalId = logicalId;
    _applyNotificationPreference(ChatPreferenceToggle.inherit);
    setState(() => _chatPreferences = const ChatPreferences());
  }

  String get _desiredChatPreferenceLogicalId {
    final lineage = _chat.desktopCompactionLineageId.trim();
    return lineage.isEmpty ? widget.session.logicalId : lineage;
  }

  /// Una sesión abierta desde un id físico puede descubrir su lineage real al
  /// llegar `status(kind=compacting)`. Migra el override local al scope lógico
  /// antes de seguir guardando para que densidad, lectura y notificaciones
  /// sobrevivan a la continuación creada por Hermes.
  Future<void> _reconcileChatPreferenceScope() async {
    final target = _desiredChatPreferenceLogicalId;
    final current = _chatPreferenceLogicalId ?? widget.session.logicalId;
    if (target == current) return;

    final epoch = ++_chatPreferenceScopeEpoch;
    final store =
        _chatPreferenceStore ??
        ChatPreferenceStore(await SharedPreferences.getInstance());
    await store.load(
      connectionId: widget.connection.id,
      logicalSessionId: target,
      legacySessionIds: {
        current,
        widget.session.logicalId,
        widget.session.id,
        ?_chat.storedSessionId,
      },
    );
    await store.clear(
      connectionId: widget.connection.id,
      logicalSessionId: target,
    );
    if (_disposed || !mounted || epoch != _chatPreferenceScopeEpoch) return;
    _chatPreferenceStore = store;
    _chatPreferenceLogicalId = target;
    _applyNotificationPreference(ChatPreferenceToggle.inherit);
    setState(() => _chatPreferences = const ChatPreferences());
  }

  void _applyNotificationPreference(ChatPreferenceToggle value) {
    _chat.notifyRepliesOverride = switch (value) {
      ChatPreferenceToggle.inherit => null,
      ChatPreferenceToggle.on => true,
      ChatPreferenceToggle.off => false,
    };
  }

  /// Marca (o desmarca) esta sesión como la que el usuario está mirando, en la
  /// capa de notificaciones. Solo la limpia si seguía siendo la nuestra, para no
  /// pisar a otro chat que ya se haya marcado visible (navegación apilada).
  void _markChatVisible(bool visible) {
    final changed = _chatRouteVisible != visible;
    if (changed) {
      _viewerAttachGeneration += 1;
      _cancelSessionContextBootstrapRetry();
    }
    _chatRouteVisible = visible;
    if (changed && mounted && !_disposed) setState(() {});
    _syncPassiveTranscriptRefresh();
    _syncSubagentPolling();
    unawaited(DrawerGestureExclusion.setEnabled(visible));
    if (!_chatBound) return;
    final notif = _chatService.notifications;
    if (notif == null) return;
    if (visible) {
      final durableId = _chat.serverSessionId;
      notif.visibleSessionId = durableId;
      _markedNotificationSessionId = durableId;
    } else {
      final marked = _markedNotificationSessionId;
      if (marked != null && notif.visibleSessionId == marked) {
        notif.visibleSessionId = null;
      }
      _markedNotificationSessionId = null;
    }
  }

  void _syncSubagentPolling() {
    final shouldOwnPresentation =
        !_disposed &&
        mounted &&
        _chatBound &&
        _chatRouteVisible &&
        _appInForeground;
    if (shouldOwnPresentation) {
      _subagentPresentationOwner ??= _chat
          .acquireSubagentForegroundPresentation();
    } else {
      final owner = _subagentPresentationOwner;
      _subagentPresentationOwner = null;
      if (owner != null) {
        _chat.releaseSubagentForegroundPresentation(owner);
      }
    }
    final runtimeId = _chatBound ? _chat.desktopRuntimeSessionId : null;
    final shouldPoll = shouldOwnPresentation && runtimeId != null;
    if (!shouldPoll) {
      _cancelAdaptiveSnapshotTimers();
      _subagentPollingRuntimeId = null;
      return;
    }
    if (_subagentPollingRuntimeId != runtimeId) {
      _cancelAdaptiveSnapshotTimers();
      _subagentPollingRuntimeId = runtimeId;
      _adaptiveRefreshFailureIndex = 0;
      _captureAdaptiveRefreshRevisions();
      unawaited(_runAdaptiveSnapshot());
      return;
    }

    _consumeAdaptiveRefreshSignals();
    if (_subagentPollTimer == null && !_adaptiveSnapshotInFlight) {
      _scheduleAdaptiveSnapshot(_adaptiveBackstopDelay());
    }
  }

  void _captureAdaptiveRefreshRevisions() {
    _seenAdaptiveEventRevision = _chat.adaptiveRefreshEventRevision;
    _seenAdaptiveFullRefreshRevision = _chat.adaptiveFullRefreshRevision;
    _seenAdaptiveSubagentRepairRevision = _chat.adaptiveSubagentRepairRevision;
    _seenAdaptiveProcessRepairRevision = _chat.adaptiveProcessRepairRevision;
    _seenAdaptiveControlRepairRevision = _chat.adaptiveControlRepairRevision;
  }

  void _cancelAdaptiveSnapshotTimers() {
    _subagentPollTimer?.cancel();
    _subagentPollTimer = null;
    _subagentRepairDebounce?.cancel();
    _subagentRepairDebounce = null;
    _processControlRepairDebounce?.cancel();
    _processControlRepairDebounce = null;
    _postControlRepairDelayIndex = -1;
    _adaptiveSnapshotQueued = false;
    _queuedSubagentRefresh = false;
    _queuedProcessRefresh = false;
    _queuedControlRefresh = false;
  }

  Duration _adaptiveBackstopDelay() {
    if (!_chat.desktopChangeEventsAvailable) {
      return const Duration(seconds: 5);
    }
    final hasActiveItems =
        _chat.safeActiveSubagentCount > 0 ||
        _chat.sessionActivity.backgroundItemCount > 0;
    return Duration(seconds: hasActiveItems ? 30 : 60);
  }

  void _scheduleAdaptiveSnapshot(
    Duration delay, {
    bool subagents = true,
    bool processes = true,
    bool control = true,
  }) {
    _subagentPollTimer?.cancel();
    _subagentPollTimer = Timer(delay, () {
      _subagentPollTimer = null;
      unawaited(
        _runAdaptiveSnapshot(
          subagents: subagents,
          processes: processes,
          control: control,
        ),
      );
    });
  }

  void _consumeAdaptiveRefreshSignals() {
    final eventRevision = _chat.adaptiveRefreshEventRevision;
    if (eventRevision != _seenAdaptiveEventRevision) {
      _seenAdaptiveEventRevision = eventRevision;
      _adaptiveRefreshFailureIndex = 0;
      _scheduleAdaptiveSnapshot(_adaptiveBackstopDelay());
    }

    final fullRevision = _chat.adaptiveFullRefreshRevision;
    if (fullRevision != _seenAdaptiveFullRefreshRevision) {
      _captureAdaptiveRefreshRevisions();
      _postControlRepairDelayIndex = 0;
      _subagentRepairDebounce?.cancel();
      _subagentRepairDebounce = null;
      _processControlRepairDebounce?.cancel();
      _processControlRepairDebounce = null;
      unawaited(_runAdaptiveSnapshot());
      return;
    }

    final subagentRevision = _chat.adaptiveSubagentRepairRevision;
    if (subagentRevision != _seenAdaptiveSubagentRepairRevision) {
      _seenAdaptiveSubagentRepairRevision = subagentRevision;
      _subagentRepairDebounce?.cancel();
      _subagentRepairDebounce = Timer(const Duration(milliseconds: 250), () {
        _subagentRepairDebounce = null;
        unawaited(_runAdaptiveSnapshot(processes: false, control: false));
      });
    }

    final processRevision = _chat.adaptiveProcessRepairRevision;
    final controlRevision = _chat.adaptiveControlRepairRevision;
    if (processRevision != _seenAdaptiveProcessRepairRevision ||
        controlRevision != _seenAdaptiveControlRepairRevision) {
      final refreshProcesses =
          processRevision != _seenAdaptiveProcessRepairRevision;
      final refreshControl =
          controlRevision != _seenAdaptiveControlRepairRevision;
      _seenAdaptiveProcessRepairRevision = processRevision;
      _seenAdaptiveControlRepairRevision = controlRevision;
      _processControlRepairDebounce?.cancel();
      _processControlRepairDebounce = Timer(
        const Duration(milliseconds: 250),
        () {
          _processControlRepairDebounce = null;
          unawaited(
            _runAdaptiveSnapshot(
              subagents: false,
              processes: refreshProcesses,
              control: refreshControl,
            ),
          );
        },
      );
    }
  }

  Future<void> _runAdaptiveSnapshot({
    bool subagents = true,
    bool processes = true,
    bool control = true,
  }) async {
    final runtimeId = _subagentPollingRuntimeId;
    if (runtimeId == null ||
        _disposed ||
        !mounted ||
        !_chatRouteVisible ||
        !_appInForeground ||
        _chat.desktopRuntimeSessionId != runtimeId) {
      return;
    }
    if (_adaptiveSnapshotInFlight) {
      _adaptiveSnapshotQueued = true;
      _queuedSubagentRefresh |= subagents;
      _queuedProcessRefresh |= processes;
      _queuedControlRefresh |= control;
      return;
    }

    _subagentPollTimer?.cancel();
    _subagentPollTimer = null;
    _adaptiveSnapshotInFlight = true;
    final failureRevision = _chat.adaptiveSnapshotFailureRevision;
    await Future.wait<void>([
      if (subagents) _chat.refreshSubagents(),
      if (processes) _chat.refreshBackgroundProcesses(),
      if (control) _chat.refreshSessionControl(),
    ]);
    final failed = _chat.adaptiveSnapshotFailureRevision != failureRevision;
    _adaptiveSnapshotInFlight = false;
    if (_disposed ||
        !mounted ||
        !_chatRouteVisible ||
        !_appInForeground ||
        _subagentPollingRuntimeId != runtimeId ||
        _chat.desktopRuntimeSessionId != runtimeId) {
      return;
    }

    if (_adaptiveSnapshotQueued) {
      final queuedSubagents = _queuedSubagentRefresh;
      final queuedProcesses = _queuedProcessRefresh;
      final queuedControl = _queuedControlRefresh;
      _adaptiveSnapshotQueued = false;
      _queuedSubagentRefresh = false;
      _queuedProcessRefresh = false;
      _queuedControlRefresh = false;
      unawaited(
        _runAdaptiveSnapshot(
          subagents: queuedSubagents,
          processes: queuedProcesses,
          control: queuedControl,
        ),
      );
      return;
    }

    if (failed) {
      _postControlRepairDelayIndex = -1;
      const delays = [5, 15, 30, 60];
      final index = _adaptiveRefreshFailureIndex.clamp(0, delays.length - 1);
      _adaptiveRefreshFailureIndex = (index + 1).clamp(0, delays.length - 1);
      _scheduleAdaptiveSnapshot(
        Duration(seconds: delays[index]),
        subagents: subagents,
        processes: processes,
        control: control,
      );
      return;
    }

    _adaptiveRefreshFailureIndex = 0;
    if (_postControlRepairDelayIndex >= 0 &&
        _postControlRepairDelayIndex < _postControlRepairDelays.length) {
      final delay = _postControlRepairDelays[_postControlRepairDelayIndex];
      _postControlRepairDelayIndex += 1;
      _scheduleAdaptiveSnapshot(delay);
      return;
    }
    _postControlRepairDelayIndex = -1;
    _scheduleAdaptiveSnapshot(_adaptiveBackstopDelay());
  }

  // El sondeo del roster no está condicionado por el turno vivo: una lista
  // `session.active_list` completa es la única autoridad capaz de desmentir un
  // `busy` colgado cuando el turno muere sin emitir su terminal. La lectura
  // durable del transcript sí sigue vetada mientras el turno emite.
  bool get _canProbePassiveRemoteActivity =>
      !_disposed &&
      mounted &&
      _chatBound &&
      _chatRouteVisible &&
      _appInForeground &&
      !_chat.resumeReconciliationInFlight;

  bool get _canPassivelyRefreshTranscript =>
      _canProbePassiveRemoteActivity &&
      !_chat.isStreaming &&
      (!_chat.hasDesktopRuntime || _chat.remoteSurfaceOwnsLiveTurn) &&
      _messageRefreshInFlightEpoch == null;

  void _syncPassiveTranscriptRefresh({
    bool refreshNow = false,
    bool recoveryConverging = false,
    bool terminal = false,
    String? changedDurableChatId,
  }) {
    final reader = _passiveConversationReader;
    reader?.setChangeEventsAvailable(
      _chat.desktopChangeEventsAvailable,
      immediate: false,
    );
    final shouldRun = _canProbePassiveRemoteActivity;
    if (!shouldRun) {
      // Lifecycle, reconciliation, or local production is an authority
      // transition. Retire both the reader timer and any REST request that
      // captured the previous observation tuple before it can publish.
      reader?.setVisible(false);
      _invalidatePassiveMessageRefresh();
      return;
    }
    // Un turno vivo sigue siendo una transición de autoridad para la lectura
    // durable: retira la petición REST en vuelo, pero conserva el sondeo.
    if (_chat.isStreaming) _invalidatePassiveMessageRefresh();
    reader?.setVisible(true);
    if (!refreshNow) return;
    if (changedDurableChatId != null) {
      reader?.notifySessionsChanged(changedDurableChatId);
      return;
    }
    reader?.notifyRelevantEvent(
      recoveryConverging: recoveryConverging,
      terminal: terminal,
    );
  }

  Future<bool> _refreshPassiveTranscript() async {
    if (!_canProbePassiveRemoteActivity) return true;
    final ownedLiveTurn = _chat.remoteSurfaceOwnsLiveTurn;
    await _chat.refreshPassiveRemoteActivity();
    if (!_canProbePassiveRemoteActivity) return true;
    // El sondeo ya cumplió su parte; el transcript durable no se lee mientras
    // el turno siga vivo (una lectura así reaparece como burbuja duplicada).
    if (_chat.isStreaming) return true;
    // Another surface's assistant is not in REST until the turn ends. The
    // busy poll therefore never sees the reply; fetch once more on idle.
    final remoteTurnSettled = ownedLiveTurn && !_chat.remoteSurfaceOwnsLiveTurn;
    if (!_canPassivelyRefreshTranscript && !remoteTurnSettled) {
      return true;
    }
    if (!_composerEmpty &&
        !_chat.remoteSurfaceOwnsLiveTurn &&
        !remoteTurnSettled) {
      return true;
    }
    return _fetchMessages(passiveOnly: true);
  }

  void _invalidatePassiveMessageRefresh() {
    if (!_chatBound || _messageRefreshInFlight?.passiveOnly != true) return;
    _chat.invalidatePassiveRead();
    _messageRefreshEpoch += 1;
    _messageRefreshInFlight = null;
    _cancelMessageRefreshViewportAnchor();
    if (!_disposed && mounted) setState(() {});
  }

  void _invalidateOwnedNativeVoicePreparation() {
    final preparation = _nativeVoicePreparation;
    if (preparation == null) return;
    _nativeVoicePreparation = null;
    _voice?.cancelNativeVoicePreparation(preparation);
  }

  // ── RouteAware: visibilidad en la pila de navegación ──────────────────────
  @override
  void didPush() {
    _markChatVisible(true); // esta pantalla acaba de entrar
    unawaited(_ensureDesktopRuntimeAndBootstrapContext());
  }

  @override
  void didPopNext() {
    _markChatVisible(true); // volvió al frente (pop de la de encima)
    unawaited(_ensureDesktopRuntimeAndBootstrapContext());
    _syncPassiveTranscriptRefresh(refreshNow: true);
    // Recarga el perfil activo: pudo cambiarse en Perfiles mientras estábamos
    // fuera. Antes el chat se quedaba con el perfil viejo hasta reabrirlo.
    unawaited(_loadActiveProfile());
    // Reconcilia el estado efectivo de la sesión y sus preferencias de borrador.
    _loadActiveModel();
    _refreshSelectedModelFromPrefs();
  }

  /// Relee el modelo elegido desde `SharedPreferences` (sin tocar otras prefs).
  /// La clave incluye conexión + sesión para que dos servidores con el mismo id
  /// durable nunca compartan una elección local.
  Future<void> _refreshSelectedModelFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final defaultProfile = _sessionPreferenceProfile == 'default';
    final next =
        prefs.getString(_sessionModelKey) ??
        (defaultProfile
            ? prefs.getString(_legacyConnectionSessionModelKey)
            : null) ??
        'hermes-agent';
    final provider =
        prefs.getString(_sessionProviderKey) ??
        (defaultProfile
            ? prefs.getString(_legacyConnectionSessionProviderKey)
            : null) ??
        '';
    if (next != _selectedModel || provider != _selectedProvider) {
      setState(() {
        _selectedModel = next;
        _selectedProvider = provider;
      });
      _chat.stageFirstSubmitConfig(_firstSubmitConfig);
      _chatService.updateHomeWidgetSessionMetadata(
        _chat,
        model: next,
        provider: provider,
      );
    }
  }

  @override
  void didPushNext() {
    _invalidateOwnedNativeVoicePreparation();
    _markChatVisible(false); // la tapó otra pantalla
  }

  @override
  void didPop() {
    _invalidateOwnedNativeVoicePreparation();
    _markChatVisible(false); // esta pantalla se va
  }

  /// ¿El modo voz global está activo y atado a ESTA sesión? La orquestación de
  /// voz (hablar, fases) la lleva el controlador local; la pantalla solo
  /// necesita saberlo para no duplicar el auto-leer ni tapar el overlay ajeno.
  bool get _voiceForThisSession =>
      _vc?.active == true && (_vc?.ownsChat(_chat) ?? false);

  /// La sesión puede apartar temporalmente la superficie para que la tarjeta
  /// de aprobación real vuelva a ser táctil. El audio/runtime siguen ligados
  /// al chat; solo cambia qué árbol visual ocupa el cuerpo.
  bool get _voiceOverlayVisible =>
      _voiceForThisSession && !(_vc?.overlayMinimized ?? false);

  /// El submit puede entrar también desde shortcuts, sugerencias o callbacks
  /// diferidos. Solo el composer visible y editable puede consumir un Stop
  /// escrito; una superficie tapada/bloqueada nunca pierde su borrador.
  bool get _composerAccessibleForTypedVoiceStop =>
      mounted &&
      !_disposed &&
      ModalRoute.of(context)?.isCurrent == true &&
      !_interactiveMessageRefreshPending &&
      !widget.connection.readOnly &&
      !_attachmentSubmitting &&
      !_compressingSession &&
      !_isRecording &&
      !_transcribing &&
      !_imagePickerOpen &&
      !_documentPickerOpen &&
      !_voiceOverlayVisible;

  /// Reacciona a un cambio del chat activo (token, herramienta, fin, error):
  /// re-renderiza desde el estado del servicio. La parte de voz la maneja el
  /// controlador de conversación, suscrito al mismo chat por su cuenta.
  /// Origen del cronómetro de la pastilla de actividad. El servicio solo publica
  /// `desktopTurnStartedAt` para los turnos que nacen en el runtime remoto, así
  /// que el turno local se marca aquí, donde llegan todas las transiciones.
  DateTime? _turnActivityStartedAt;

  /// Hay un turno propio vivo: lo que mantiene encendida la pastilla de
  /// actividad. El texto del turno ya no vive en la burbuja.
  bool get _turnLive => _chat.isStreaming;

  Future<void> _runBackgroundAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaBackgroundActionFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  /// Pasos (herramientas/skills) del turno vivo, del mensaje-placeholder que el
  /// servicio va actualizando. Se memoiza por identidad de la lista para no
  /// renormalizar 256 pasos en cada token.
  Object? _activityStepsSource;
  ({ActivityStep? current, List<ActivityStep> done}) _activitySteps = (
    current: null,
    done: const <ActivityStep>[],
  );

  ({ActivityStep? current, List<ActivityStep> done}) _liveActivitySteps() {
    Map<String, dynamic>? live;
    for (final message in _messages) {
      if (message['role'] != 'assistant') continue;
      if ((message['display_kind']?.toString().trim().isNotEmpty ?? false)) {
        continue;
      }
      if (message['_pipeline'] == true) live = message;
      break;
    }
    final source = live?[assistantActivityTraceKey];
    if (live == null) {
      _activityStepsSource = null;
      return (current: null, done: const <ActivityStep>[]);
    }
    if (!identical(source, _activityStepsSource)) {
      _activityStepsSource = source;
      _activitySteps = ActivitySnapshot.splitSteps(
        normalizeAssistantActivityTrace(source),
      );
    }
    return _activitySteps;
  }

  /// Un solo valor con todo lo que está vivo: turno, tareas, compactación,
  /// segundo plano y subagentes. La pastilla y el panel se pintan desde aquí.
  ActivitySnapshot _buildActivitySnapshot() {
    final turnActive = _turnLive;
    final activity = _chat.sessionActivity;
    final steps = turnActive
        ? _liveActivitySteps()
        : (current: null, done: const <ActivityStep>[]);
    final passiveTotal = _chat.hasRecentPassiveRemoteActivity
        ? _chat.passiveActivityAggregate.total
        : 0;
    final subagents = _displaySubagentActivities;
    return ActivitySnapshot(
      turnActive: turnActive,
      tasksActive: turnActive || _chat.remoteSurfaceOwnsLiveTurn,
      turnStartedAt: turnActive
          ? (_turnActivityStartedAt ?? _chat.desktopTurnStartedAt)
          : null,
      headline: turnActive ? _traceHeadline() : null,
      waitingForUser: turnActive && _turnWaitsForUser,
      noActivityHint: turnActive && _chat.noActivityHint,
      current: steps.current,
      done: steps.done,
      tasks: _chat.agentTasks,
      processes: activity.processes,
      schedules: activity.schedules,
      goal: activity.goal,
      processesStale: activity.stale,
      backgroundStartedAt: activity.startedAt,
      subagents: subagents,
      subagentGenericCount: math.max(
        _chat.safeActiveSubagentCount,
        passiveTotal,
      ),
      passiveRemote:
          _chat.hasRecentPassiveRemoteActivity ||
          _chat.safeActiveSubagentCount > 0,
    );
  }

  ActivityPanelActions? _activityActions;
  (bool, bool, bool)? _activityActionCapabilities;

  /// Las acciones por elemento del panel: los mismos controladores que tenían
  /// las hojas de segundo plano y de subagentes.
  ActivityPanelActions _buildActivityActions() {
    final capabilities = (
      _chat.canStopBackgroundProcesses,
      _chat.canControlSessionActivity,
      _chat.canControlGoal,
    );
    final cached = _activityActions;
    if (cached != null && _activityActionCapabilities == capabilities) {
      return cached;
    }
    // Mantén estables los callbacks: el panel abierto compara esta identidad.
    final actions = ActivityPanelActions(
      canStopProcesses: capabilities.$1,
      stopProcess: (id) =>
          _runBackgroundAction(() => _chat.stopBackgroundProcess(id)),
      canControlSchedules: capabilities.$2,
      scheduleAction: (schedule, action) {
        final isLoop = schedule.kind == SessionActivityScheduleKind.loop;
        final name = switch (action) {
          ActivityScheduleAction.pause =>
            isLoop ? 'loop.pause' : 'heartbeat.pause',
          ActivityScheduleAction.resume =>
            isLoop ? 'loop.resume' : 'heartbeat.resume',
          ActivityScheduleAction.stop =>
            isLoop ? 'loop.stop' : 'heartbeat.clear',
        };
        return _runBackgroundAction(() => _chat.sendSessionControlAction(name));
      },
      canControlGoal: capabilities.$3,
      goalAction: (action) =>
          _runBackgroundAction(() => _chat.sendGoalAction(action)),
      goalDetails: () {
        final snapshot = _chat.goal;
        if (snapshot != null) unawaited(_showGoalSheet(snapshot));
      },
      openSubagent: _subagentController.open,
      dismissSubagents: _dismissSubagentPill,
    );
    _activityActionCapabilities = capabilities;
    return _activityActions = actions;
  }

  /// Sincroniza el seguimiento de compactación con el servicio. Barato e
  /// idempotente: se llama en cada evento del chat.
  void _onCompactionChanged() {
    if (_disposed || !mounted) return;
    setState(() {});
  }

  void _syncCompaction() {
    if (!_chatBound) return;
    // Live compaction of this process, or one the gateway positively reports
    // as still running after a restart (display-only: never a lock).
    final serviceActive =
        _chat.desktopCompactionVisible || _compressionCommandInFlight;
    if (!serviceActive) _compactionSettledEarly = false;
    final active = serviceActive && !_compactionSettledEarly;
    final manual =
        _chat.desktopManualCompressionInFlight || _compressionCommandInFlight;
    Map<String, dynamic>? head;
    for (final message in _messages) {
      if (message['display_kind'] == 'compression_result') {
        head = message;
        break;
      }
    }
    if (!active && !_compaction.running && _compressionInvocation == null) {
      _consumedCompressionResult = head;
    }
    // Solo hechos: lo que la línea de estado de Hermes dice y el tiempo local.
    _compaction.sync(
      active: active,
      manual: manual,
      startedAt: _chat.desktopCompactionStartedAt,
      tokensBefore: _chat.desktopCompactionTokensBefore,
      messagesBefore: _chat.desktopCompactionMessagesBefore,
      chunkIndex: _chat.desktopCompactionChunkIndex,
      chunkCount: _chat.desktopCompactionChunkCount,
    );
    var settled = false;
    if (head != null && !identical(head, _consumedCompressionResult)) {
      _consumedCompressionResult = head;
      final meta = head['display_metadata'];
      if (meta is Map) {
        int? number(String key) =>
            meta[key] is num ? (meta[key] as num).toInt() : null;
        final noop = meta['noop'] == true;
        final after = number('after_tokens');
        _compaction.reportResult(
          tokensBefore: number('before_tokens'),
          tokensAfter: after,
          messagesBefore: number('before_messages'),
          messagesAfter: number('after_messages'),
          noop: noop,
        );
        if (after != null && !noop) _applyPostCompactionContext(after);
        _compactionSettledEarly = serviceActive;
      }
      settled = true;
    }
    // Una compactación manual cuyo resultado llegó tarde (`pending` y luego
    // `status.update(compacted)`) termina por ese borde, sin cifras.
    final edges = _chat.desktopCompactedEdgeCount;
    if (edges != _seenCompactedEdges) {
      _seenCompactedEdges = edges;
      if (_compaction.running) {
        _compaction.reportResult();
        _compactionSettledEarly = serviceActive;
      }
      settled = true;
    }
    // The live reply's outcome, independent of the transcript projection
    // (a refresh racing a fast no-op used to drop it): the pill morphs to
    // it right away.
    final live = _chat.takeLiveCompressionOutcome();
    if (live != null) {
      _compaction.reportResult(
        tokensBefore: live.tokensBefore,
        tokensAfter: live.noop ? null : live.tokensAfter,
        messagesBefore: live.messagesBefore,
        messagesAfter: live.noop ? null : live.messagesAfter,
        noop: live.noop,
      );
      _compactionSettledEarly = serviceActive;
      settled = true;
    }
    if (settled) _consumeCompressionInvocation();
    _announceRestoredCompressionOutcome();
  }

  /// A restored compression the gateway now reports finished: the pill that
  /// was showing it turns into "Compactado · <time>". Only THAT it finished
  /// is known after a restart, so no facts and never "nothing to compact";
  /// with no pill showing, nothing new appears.
  void _announceRestoredCompressionOutcome() {
    if (!_chat.takeRestoredCompressionFinished()) return;
    if (_compaction.running) _compaction.reportResult();
  }

  /// El resultado del RPC `session.compress` cierra la barra al instante: con
  /// éxito enseña lo que Hermes midió (solo los recuentos que trajo); sin nada
  /// que compactar, abortada o bloqueada se retira (el aviso ya lo da el chat).
  void _finishCompactionBar(DesktopCommandDispatch result) {
    final compression = result.compressionResult;
    switch (result.compressionStatus) {
      case DesktopCompressionStatus.compressed:
        _compaction.reportResult(
          tokensBefore: compression?.beforeTokens,
          tokensAfter: compression?.afterTokens,
          messagesBefore: compression?.beforeMessages,
          messagesAfter: compression?.afterMessages,
        );
        _compactionSettledEarly = _chat.desktopCompressionInFlight;
      case DesktopCompressionStatus.noOp:
        _compaction.reportResult(
          tokensBefore: compression?.beforeTokens,
          messagesBefore: compression?.beforeMessages,
          noop: true,
        );
        _compactionSettledEarly = _chat.desktopCompressionInFlight;
      case DesktopCompressionStatus.aborted ||
          DesktopCompressionStatus.lockHeld:
        _compaction.reset();
        _compactionSettledEarly = _chat.desktopCompressionInFlight;
      case DesktopCompressionStatus.pending || null:
        break;
    }
  }

  /// La compactación acabó bien: el `/compress` que sigue en el composer se
  /// consume y la paleta de comandos se cierra.
  void _consumeCompressionInvocation() {
    final invocation = _compressionInvocation;
    if (invocation == null) return;
    _compressionInvocation = null;
    _consumeSlashInvocation(invocation);
  }

  /// Tras compactar, el tamaño exacto que Hermes acaba de medir sustituye al
  /// porcentaje anterior hasta que llegue el uso real del runtime.
  void _applyPostCompactionContext(int after) {
    final current = _sessionContextMetrics.value;
    final max = current.contextMax;
    if (max == null || max <= 0) return;
    _commitSessionContextMetrics(
      SessionContextMetrics(
        contextUsed: after,
        contextMax: max,
        percent: (after * 100 / max).round().clamp(0, 100),
        cumulativeTotal: current.cumulativeTotal,
        inputTokens: current.inputTokens,
        cacheReadTokens: current.cacheReadTokens,
        cacheWriteTokens: current.cacheWriteTokens,
        observedFirstTokenLatencyMs: current.observedFirstTokenLatencyMs,
      ),
    );
  }

  /// La cabecera del Bot Chat («@nombre · Pensando») y la pastilla de actividad
  /// narraban el mismo estado a la vez (reportado en dispositivo real). Antes de
  /// que la pastilla se revele —los 2 s del antiparpadeo— la cabecera sigue
  /// siendo la única señal de un turno recién empezado; después se calla.
  bool get _turnActivityPillRevealed {
    final startedAt = _turnActivityStartedAt;
    if (!_turnLive || startedAt == null) return false;
    return DateTime.now().difference(startedAt) >= const Duration(seconds: 2);
  }

  void _syncTurnActivityClock() {
    if (_chat.isStreaming) {
      // Un solo origen por turno: los tics posteriores no deben reiniciarlo o
      // el contador volvería a cero en cada herramienta.
      //
      // Deliberadamente local y no `desktopTurnStartedAt`: ese campo pertenece
      // al turno del runtime remoto y sobrevive a la reconciliación, así que
      // usarlo podía pintar un contador ya en marcha (o directamente de otro
      // turno). Tras un resume en frío esto se queda corto, lo que subestima la
      // espera — nunca la exagera, que es el único error que alarmaría.
      _turnActivityStartedAt ??= DateTime.now();
      return;
    }
    _turnActivityStartedAt = null;
  }

  bool get _confirmedStopStatusVisible =>
      _chat.stopConfirmationState == StopConfirmationState.confirmed &&
      !_chat.backgroundStopVerificationInFlight &&
      (_chat.backgroundStopRemainingTasks ?? 0) == 0;

  void _syncStopConfirmationVisibility() {
    if (!_confirmedStopStatusVisible) {
      _stopConfirmationDismissTimer?.cancel();
      _stopConfirmationDismissTimer = null;
      _confirmedStopStatusDismissed = false;
      return;
    }
    if (_confirmedStopStatusDismissed ||
        _stopConfirmationDismissTimer != null) {
      return;
    }
    _stopConfirmationDismissTimer = Timer(const Duration(seconds: 4), () {
      _stopConfirmationDismissTimer = null;
      if (_disposed || !mounted || !_confirmedStopStatusVisible) return;
      setState(() => _confirmedStopStatusDismissed = true);
    });
  }

  void _onChatEvent(ActiveChatEvent event) {
    if (_disposed || !mounted) return;
    // An externally observed successor can become live without a local
    // `started` event. Retire the old terminal host before publishing its
    // successor's frame, or both rows would read the same live notifier.
    if (event != ActiveChatEvent.started &&
        _surfaceTurnTerminal &&
        _chat.isStreaming) {
      _beginSurfaceTurn();
    }
    _syncStopConfirmationVisibility();
    if (event == ActiveChatEvent.started) {
      _lastNonEmptySubagentActivities = const <SubagentActivity>[];
      _subagentPillDismissed = false;
    }
    _syncTurnActivityClock();
    _syncCompaction();
    _syncSubagentPolling();
    final passiveTerminalEvent =
        event == ActiveChatEvent.done ||
        event == ActiveChatEvent.error ||
        event == ActiveChatEvent.cancelled;
    final passiveRecoveryEvent =
        event == ActiveChatEvent.connected ||
        event == ActiveChatEvent.sessionInfo ||
        (event == ActiveChatEvent.messagesHydrated &&
            _messageRefreshInFlightEpoch == null);
    final passiveRuntimeEvent =
        event == ActiveChatEvent.started ||
        event == ActiveChatEvent.waiting ||
        event == ActiveChatEvent.approvalRequest ||
        event == ActiveChatEvent.interactiveRequest;
    _syncPassiveTranscriptRefresh(
      refreshNow:
          passiveTerminalEvent || passiveRecoveryEvent || passiveRuntimeEvent,
      recoveryConverging: passiveRecoveryEvent,
      terminal: passiveTerminalEvent,
    );
    if (_editingRewriteSubmitted &&
        ((event == ActiveChatEvent.started && _editingTranscriptChanged) ||
            event == ActiveChatEvent.done ||
            event == ActiveChatEvent.error ||
            event == ActiveChatEvent.cancelled ||
            event == ActiveChatEvent.messagesHydrated)) {
      _clearUserMessageEditingState();
    }
    final delivery = _attachmentDelivery;
    if (delivery != null) _preparedTurn = delivery.current;
    if ((event == ActiveChatEvent.done ||
            event == ActiveChatEvent.error ||
            event == ActiveChatEvent.cancelled) &&
        delivery?.acknowledged == true) {
      // A terminal runtime event is the authoritative end of an acknowledged
      // delivery. ActiveChat deletes its outbox asynchronously, so the
      // observed delivery may still expose `running` during this callback.
      // Detach it now so stale recovery state cannot re-lock the composer after
      // the remote run has already ended.
      _preparedTurn = null;
      _observeAttachmentDelivery(null);
    }
    if (event == ActiveChatEvent.responseMetrics) {
      // The context trigger/panel owns its own ValueListenable. Refresh only
      // that narrow subtree; TTFT must not rebuild Markdown or move the chat.
      _syncSessionContextMetrics(preserveKnownWindow: true);
      return;
    }
    // El uso de contexto solo cambia con session.info/responseMetrics, no por
    // token: sincronizarlo a 30 Hz repetía el mismo cálculo en cada flush.
    if (event == ActiveChatEvent.started || event == ActiveChatEvent.done) {
      _syncSessionContextMetrics(preserveKnownWindow: true);
    }
    var contextOnlySessionInfo = false;
    if (event == ActiveChatEvent.messagesHydrated) {
      // Una carga iniciada por esta pantalla conserva su propia valla de estado
      // y su ancla visual. El evento del servicio solo fuerza el rebuild; no
      // puede cerrar el overlay ni programar otro scroll por fuera de ese vuelo.
      if (_messageRefreshInFlightEpoch == null) {
        _error = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // La hidratación diferida del historial (0.20) o una compactación
          // pueden aterrizar a mitad de stream con el lector arriba. Solo
          // reengancha el fondo si el seguimiento sigue activo; si el usuario
          // pausó el seguimiento para leer, la hidratación no le roba la vista.
          if (mounted && _autoFollowStreaming) _scrollToBottom(animate: false);
        });
      }
    }
    if (event == ActiveChatEvent.sessionInfo) {
      final presentationFingerprint = _runtimePresentationFingerprint(
        _chat.desktopRuntimeInfo,
      );
      final compacting = _compressingSession;
      final compressionPresentation = _chat.desktopRestoredCompressionRunning;
      final contextCompacting = _chat.desktopCompressionInFlight;
      final passiveAggregate = _chat.passiveActivityAggregate;
      final activityPresentation = (
        _chat.hasRecentPassiveRemoteActivity,
        passiveAggregate.total,
        passiveAggregate.active,
        passiveAggregate.completed,
        _chat.safeActiveSubagentCount,
      );
      if (contextCompacting) {
        _sessionContextAwaitingPostCompactionMetrics = true;
      }
      final invalidateAfterCompaction =
          _sessionContextAwaitingPostCompactionMetrics && !contextCompacting;
      contextOnlySessionInfo =
          _desktopRuntimePresentationFingerprint != null &&
          _desktopRuntimePresentationFingerprint == presentationFingerprint &&
          _lastDesktopCompacting == compacting &&
          _lastDesktopCompressionPresentation == compressionPresentation &&
          _activityPresentationFingerprint == activityPresentation;
      _lastDesktopCompressionPresentation = compressionPresentation;
      _activityPresentationFingerprint = activityPresentation;
      _desktopRuntimePresentationFingerprint = presentationFingerprint;
      _lastDesktopCompacting = compacting;
      // Tras compactar el uso real llega más tarde: hasta entonces se conserva
      // el último porcentaje en vez de caer a los tokens acumulados.
      _syncSessionContextMetrics(preserveKnownWindow: true);
      if (invalidateAfterCompaction) {
        _sessionContextAwaitingPostCompactionMetrics = false;
      }
      _syncDesktopSessionConfig();
      unawaited(_reconcileChatPreferenceScope());
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        _markChatVisible(true);
      }
    }
    if (event == ActiveChatEvent.connected ||
        event == ActiveChatEvent.sessionInfo ||
        event == ActiveChatEvent.done ||
        event == ActiveChatEvent.responseMetrics ||
        event == ActiveChatEvent.messagesHydrated) {
      unawaited(_bootstrapSessionContextForCurrentRuntime());
    }
    if (event == ActiveChatEvent.connected ||
        event == ActiveChatEvent.sessionInfo ||
        event == ActiveChatEvent.done) {
      unawaited(_persistBotChatPin());
    }
    // Los tokens solo sustituyen el mapa de cabeza y pueden reutilizar el plan
    // por índices. Herramientas, terminales y cambios de cola sí alteran la
    // estructura y deben reconstruirla en el siguiente frame.
    if (event != ActiveChatEvent.token) _renderProjection = null;
    var materializeLiveAssistant = false;
    if (event == ActiveChatEvent.token) {
      if (!_liveAssistantMaterialized &&
          _currentLiveAssistantMessage() != null) {
        _liveAssistantMaterialized = true;
        materializeLiveAssistant = true;
      }
      _advanceStreamingReveal();
      _publishLiveAssistantFrame();
      _scheduleLiveFollowFrame();
    }
    // message.interim sella la burbuja y abre otro segmento del mismo turno
    // (llega como toolProgress): el host vivo suelta el texto ya sellado.
    if (event == ActiveChatEvent.toolProgress) {
      _syncStreamingSegmentBoundary();
    }
    // Un estado terminal revela siempre todo el contenido recibido, sin
    // reactivar el auto-scroll ni mover al usuario de donde estaba leyendo.
    if (event == ActiveChatEvent.done ||
        event == ActiveChatEvent.error ||
        event == ActiveChatEvent.cancelled) {
      final previousFrame = _liveAssistantFrame.value;
      final hadLiveHost =
          _liveAssistantMaterialized &&
          previousFrame != null &&
          previousFrame.turnSerial == _assistantEntranceSerial;
      final terminalAssistant = _terminalSurfaceAssistantMessage(previousFrame);
      _streamingRevealTimer?.cancel();
      _revealedChars =
          ((terminalAssistant?['content'] as String?) ?? '').length;
      if (terminalAssistant != null) {
        _publishLiveAssistantFrame(
          isStreaming: false,
          message: terminalAssistant,
        );
      }
      _surfaceTurnTerminal = _surfaceTurnSerial == _assistantEntranceSerial;
      if (event == ActiveChatEvent.done) {
        unawaited(_refreshPublishedSessionUsage(force: true));
      }
      // Si el lector se apartó del fondo, conserva el mismo RenderObject hasta
      // que él decida volver. Sustituir aquí el host vivo por los chunks
      // terminales cambia toda la geometría en el último frame y vuelve a
      // secuestrar el viewport aunque los tokens intermedios estuvieran bien.
      final terminalFrame = _liveAssistantFrame.value;
      final canRetainTerminalHost =
          !_autoFollowStreaming &&
          hadLiveHost &&
          terminalAssistant != null &&
          terminalFrame != null &&
          terminalFrame.turnSerial == _assistantEntranceSerial &&
          identical(terminalFrame.metadata, terminalAssistant);
      _retainedTerminalAssistant = canRetainTerminalHost
          ? terminalAssistant
          : null;
      final terminalError = _messages.isNotEmpty ? _messages.first : null;
      _retainedTerminalError =
          canRetainTerminalHost &&
              terminalError?['role'] == 'assistant_error' &&
              _messages.length > 1 &&
              identical(_messages[1], terminalAssistant)
          ? terminalError
          : null;
      if (_retainedTerminalError != null) {
        _expectReportedTerminalStructuralChange();
      }
      if (!_autoFollowStreaming && !canRetainTerminalHost) {
        _expectTerminalStructuralChange();
      }
      _liveAssistantMaterialized = canRetainTerminalHost;
      if (canRetainTerminalHost) {
        _showScrollToBottom = !_isNearBottom;
      } else {
        _liveAssistantFrame.value = null;
      }
    }
    // Solo el primer token cambia la estructura (placeholder -> host vivo).
    // Los siguientes deltas actualizan exclusivamente ValueListenableBuilder.
    if ((event != ActiveChatEvent.token || materializeLiveAssistant) &&
        !contextOnlySessionInfo) {
      setState(() {});
    }
    switch (event) {
      case ActiveChatEvent.started:
        // Nuevo turno: reinicia la identidad del host y espera al primer token.
        _beginSurfaceTurn();
      case ActiveChatEvent.token:
      // El revelado gradual avanza con cada delta; el notifier limita el
      // repintado al mensaje vivo y el post-frame conserva el seguimiento.
      case ActiveChatEvent.toolProgress:
      case ActiveChatEvent.subagentActivity:
      case ActiveChatEvent.approvalRequest:
      case ActiveChatEvent.interactiveRequest:
        // Tarjetas (no texto): si el usuario sigue el fondo, baja con ellas; si
        // lee arriba, no lo arrastramos.
        if (_isNearBottom) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _autoScrollIfNearBottom(),
          );
        }
      case ActiveChatEvent.done:
        _scheduleComposerTurnTranscriptSettle();
        // Auto-leer la respuesta si está activado y NO estamos en modo voz (ahí
        // el bucle de voz ya se encarga de hablarla).
        if (!_editingUserMessage &&
            !_voiceForThisSession &&
            _autoReadReplies &&
            _chat.assistantContent.isNotEmpty &&
            _pipelineState == ChatPipelineState.completed) {
          // A-015 (spec 028): mismo filtrado que el botón altavoz — leer solo
          // la respuesta final, nunca el razonamiento interno (`<think>`).
          final rawAnswer = splitReasoning(_chat.assistantContent).answer;
          final answer = GeneratedMediaService.stripDirectives(rawAnswer);
          final message = _assistantMessageForAnswer(rawAnswer);
          final voice = _voice;
          if (voice != null && answer.trim().isNotEmpty) {
            unawaited(
              voice.startAutoRead(
                messageKey: _readAloudMessageKey(message, answer),
                revision: _readAloudRevision(answer),
                markdown: answer,
              ),
            );
          }
        }
      case ActiveChatEvent.error:
        final rewindRestored = _chat.takeRewindRestoredOnError();
        final dashboardAuthRequired = _chat.takeRewindDashboardAuthRequired();
        if (rewindRestored) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(
                dashboardAuthRequired
                    ? Strings.of(context).dashboardAuthLoginRequired
                    : Strings.of(context).chaEditFailed,
              ),
            ),
          );
        }
        break;
      case ActiveChatEvent.warning:
        final warning = _chat.takeTerminalWarning();
        if (warning != null && warning.isNotEmpty) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(warning),
              duration: const Duration(seconds: 8),
            ),
            kind: HermesNoticeKind.warning,
          );
        }
        break;
      case ActiveChatEvent.queueChanged:
        // El panel ya refleja la entrada atascada con el setState genérico de
        // arriba, pero eso solo se ve si el panel está abierto. Desktop avisa
        // además con un toast al agotar `MAX_AUTO_DRAIN_ATTEMPTS`
        // (`use-composer-queue.ts` / `use-background-queue-drain.ts`).
        _notifyExhaustedQueuedRetries();
        break;
      case ActiveChatEvent.cancelled:
      case ActiveChatEvent.connected:
      case ActiveChatEvent.waiting:
        break;
      case ActiveChatEvent.messagesHydrated:
        _scheduleComposerTurnTranscriptSettle();
        break;
      case ActiveChatEvent.earlierMessagesLoaded:
      case ActiveChatEvent.responseMetrics:
      case ActiveChatEvent.sessionInfo:
      case ActiveChatEvent.dashboardAuthChanged:
      case ActiveChatEvent.goalUpdated:
      // The generic setState above already repaints _buildGoalStrip; no
      // extra behavior (scrolling, etc.) is needed for a status change.
      case ActiveChatEvent.backgroundTaskComplete:
        break;
    }
  }

  /// Ids ya avisados. `queueChanged` se emite muchas veces por turno (y otra
  /// vez por cada reintento de la misma entrada), así que sin esto el mismo
  /// atasco repetiría el snackbar. Mismo criterio que `_queuedRetryAttempts`:
  /// el estado se lleva por id de entrada, no por evento.
  final Set<String> _notifiedExhaustedQueueIds = <String>{};

  void _notifyExhaustedQueuedRetries() {
    final exhausted = _chat.queuedRetriesExhausted;
    // Una entrada que volvió a la cola viva (reenvío manual, edición) puede
    // agotarse otra vez más tarde y merece un aviso nuevo.
    _notifiedExhaustedQueueIds.retainWhere(exhausted.contains);
    final fresh = exhausted
        .where((id) => !_notifiedExhaustedQueueIds.contains(id))
        .toList(growable: false);
    if (fresh.isEmpty) return;
    _notifiedExhaustedQueueIds.addAll(fresh);
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        key: const ValueKey('chat-queue-stuck-snackbar'),
        content: Text(Strings.of(context).chaQueueStuck),
        duration: const Duration(seconds: 8),
      ),
      kind: HermesNoticeKind.warning,
    );
  }

  Future<void> _persistBotChatPin() async {
    if (widget.connection.readOnly) return;
    final source = widget.session.source.trim().toLowerCase();
    if (source == 'bot-mode' || source == 'bot-mode-canonical') {
      try {
        await _botChatStore?.clear(
          connectionId: widget.connection.id,
          profile: _chat.sessionProfile,
        );
        await _ensureOfficialBotChatHidden();
      } catch (_) {}
      return;
    }
    if (source != 'mobile-bot' && source != 'bot-mode-local') return;
    final store = _botChatStore;
    final durableId = _chat.storedSessionId?.trim();
    if (store == null || durableId == null || durableId.isEmpty) return;
    try {
      await _persistBotChatPinBeforePrompt(durableId);
    } catch (_) {}
  }

  bool get _usesLocalBotChatPin {
    final source = widget.session.source.trim().toLowerCase();
    return source == 'mobile-bot' || source == 'bot-mode-local';
  }

  bool get _usesOfficialBotChatPin =>
      widget.session.source.trim().toLowerCase() == 'bot-mode';

  TuiGatewayClient? get _botModeGateway {
    final gateway = _chat.desktopControlGateway;
    return gateway is TuiGatewayClient ? gateway : null;
  }

  Future<void> _ensureOfficialBotChatHidden() async {
    final runtimeId = _chat.desktopRuntimeSessionId?.trim();
    final gateway = _botModeGateway;
    if (runtimeId == null ||
        runtimeId.isEmpty ||
        gateway == null ||
        runtimeId == _hiddenCanonicalBotRuntimeId) {
      return;
    }
    final active = _hiddenCanonicalBotFlight;
    if (active != null && _hiddenCanonicalBotFlightId == runtimeId) {
      await active;
      return;
    }
    final Future<void> flight = () async {
      try {
        // A runtime exists here only after ActiveChat resumed the stored pin
        // directly. Never infer pin validity from session.list: hidden sessions
        // are intentionally absent from that roster on current Hermes Agent.
        await gateway.ensureCanonicalBotChatHidden(runtimeId);
      } on TuiGatewayRpcError catch (error) {
        if (error.code != -32601) rethrow;
      }
    }();
    _hiddenCanonicalBotFlightId = runtimeId;
    _hiddenCanonicalBotFlight = flight;
    try {
      await flight;
      _hiddenCanonicalBotRuntimeId = runtimeId;
    } finally {
      if (identical(_hiddenCanonicalBotFlight, flight)) {
        _hiddenCanonicalBotFlight = null;
        _hiddenCanonicalBotFlightId = null;
      }
    }
  }

  Future<void> _assertOfficialBotChatPinBeforePrompt(
    String durableSessionId,
  ) async {
    if (!_usesOfficialBotChatPin) return;
    final gateway = _botModeGateway;
    if (gateway == null) {
      throw StateError('Official Bot Chat verification is unavailable');
    }
    await gateway.assertCanonicalBotChat(
      profile: _chat.sessionProfile,
      storedSessionId: durableSessionId,
    );
  }

  Future<void> _persistBotChatPinBeforePrompt(String durableSessionId) async {
    if (!_usesLocalBotChatPin) return;
    final store = _botChatStore;
    if (widget.connection.readOnly || store == null) {
      throw StateError('Bot Chat pin persistence is unavailable');
    }
    final durableId = durableSessionId.trim();
    if (durableId.isEmpty) {
      throw StateError('Hermes did not confirm a durable Bot Chat id');
    }
    if (_persistedCanonicalBotPinId == durableId) return;
    final active = _canonicalBotPinFlight;
    if (active != null && _canonicalBotPinFlightId == durableId) {
      await active;
      return;
    }
    final Future<void> flight = () async {
      final gateway = _botModeGateway;
      var needsLocalFallback = gateway == null;
      if (gateway != null) {
        final runtimeId = _chat.desktopRuntimeSessionId?.trim();
        if (runtimeId == null || runtimeId.isEmpty) {
          throw StateError('Hermes did not confirm a Bot Chat runtime');
        }
        try {
          // Materialises + hides the row and then performs a fresh namespaced
          // read-modify-write before prompt.submit. Any ambiguous server failure
          // propagates so the encrypted draft stays retryable and no unpinned
          // hidden conversation is started.
          await gateway.persistCanonicalBotChat(
            profile: _chat.sessionProfile,
            runtimeSessionId: runtimeId,
            storedSessionId: durableId,
          );
        } on TuiGatewayRpcError catch (error) {
          // Legacy gateways keep the existing encrypted local fallback. Network,
          // validation and concurrent-pin failures remain fail-closed.
          if (error.code != -32601) rethrow;
          needsLocalFallback = true;
        }
      }
      if (needsLocalFallback) {
        await store.save(
          connectionId: widget.connection.id,
          profile: _chat.sessionProfile,
          sessionId: durableId,
        );
      } else {
        // Official metadata is authoritative. Do not resurrect a stale local
        // pin if the Desktop plugin later changes or removes its canonical id.
        await store.clear(
          connectionId: widget.connection.id,
          profile: _chat.sessionProfile,
        );
      }
    }();
    _canonicalBotPinFlightId = durableId;
    _canonicalBotPinFlight = flight;
    try {
      await flight;
      _persistedCanonicalBotPinId = durableId;
    } finally {
      if (identical(_canonicalBotPinFlight, flight)) {
        _canonicalBotPinFlight = null;
        _canonicalBotPinFlightId = null;
      }
    }
  }

  /// El modo voz global cambió de estado: [VoiceStage] posee únicamente su
  /// ambiente visual; la pantalla se limita a reconstruir su proyección.
  void _onVoiceState() {
    if (_disposed || !mounted) return;
    setState(() {});
  }

  /// Resuelve la aprobación pendiente del agente desde el chat
  /// (once|session|always|deny). Respeta solo-lectura y App Lock como en runs.
  Future<void> _resolveChatApproval(String choice) async {
    if (_resolvingApproval) return;
    final app = context.findAncestorStateOfType<HermesAppState>();
    final policy = app?.approvalPolicy;
    final mode = policy?.effectiveMode(widget.session.id);
    // Solo lectura (de instancia o de modo) bloquea aprobar; denegar se permite.
    if (choice != 'deny' &&
        (widget.connection.readOnly || mode == ApprovalMode.readOnly)) {
      showReadOnlyNotice(context);
      return;
    }
    // App Lock antes de aprobar acciones sensibles (deny nunca pide lock).
    if (choice != 'deny' && (policy?.requireLock ?? true)) {
      final lock = app?.appLock;
      if (lock != null && lock.enabled) {
        final reason = choice == 'always'
            ? Strings.of(context).chaApproveAlways
            : Strings.of(context).chaApproveOnce;
        final verified = await LockScreen.verify(context, lock, reason: reason);
        if (!verified) return;
      }
    }
    if (!mounted) return;
    final approval = _chat.pendingApproval;
    setState(() => _resolvingApproval = true);
    try {
      await _chat.resolveApproval(choice);
      // "Permitir siempre" persiste una regla local para auto-aprobar en el
      // futuro (mismo comportamiento que RunsScreen; el Gateway no guarda reglas).
      if (choice == 'always' && (policy?.allowAlways ?? true)) {
        final command = (approval?['command'] ?? '').toString();
        final patternKey = approval?['pattern_key']?.toString();
        await policy?.saveRule(
          ApprovalRule(
            id: patternKey ?? command,
            description: (approval?['description'] ?? command).toString(),
            instanceId: widget.connection.id,
            scope: ApprovalScope.always,
            risk: assessCommandRisk(command.isEmpty ? null : command),
            createdAt: DateTime.now(),
            command: command.isEmpty ? null : command,
            patternKey: patternKey,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).chaCantSendApproval(humanizeApiError(e)),
            ),
          ),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _resolvingApproval = false);
    }
  }

  Future<void> _resolveInteractivePrompt(String submittedValue) async {
    if (_resolvingInteractivePrompt) return;
    final entry = _chat.pendingInteractivePrompt;
    final request = entry?.request;
    if (entry == null || request == null) return;
    final sensitive =
        request.kind == InteractivePromptKind.sudo ||
        request.kind == InteractivePromptKind.secret;
    if (sensitive && widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }

    setState(() => _resolvingInteractivePrompt = true);
    try {
      switch (request.kind) {
        case InteractivePromptKind.clarify:
          await _chat.respondToClarify(entry.key, submittedValue);
        case InteractivePromptKind.sudo:
          final password = EphemeralSensitiveValue(submittedValue);
          submittedValue = '';
          await _chat.respondToSudo(entry.key, password);
        case InteractivePromptKind.secret:
          final value = EphemeralSensitiveValue(submittedValue);
          submittedValue = '';
          await _chat.respondToSecret(entry.key, value);
        case InteractivePromptKind.terminalRead:
          submittedValue = '';
          await _chat.respondToTerminalRead(entry.key);
      }
    } catch (error) {
      submittedValue = '';
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(
                context,
              ).interactiveRespondFailed(humanizeApiError(error)),
            ),
          ),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      submittedValue = '';
      if (mounted) setState(() => _resolvingInteractivePrompt = false);
    }
  }

  Future<void> _resolveInteractivePromptBatch(
    Map<String, String> answers,
  ) async {
    if (_resolvingInteractivePrompt) return;
    final entry = _chat.pendingInteractivePrompt;
    final request = entry?.request;
    if (entry == null || request == null) return;
    if (request is! ClarifyPromptRequest || !request.isBatch) return;

    setState(() => _resolvingInteractivePrompt = true);
    try {
      await _chat.respondToClarifyBatch(entry.key, answers);
    } catch (error) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(
                context,
              ).interactiveRespondFailed(humanizeApiError(error)),
            ),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _resolvingInteractivePrompt = false);
    }
  }

  Future<void> _cancelInteractivePrompt() async {
    if (_resolvingInteractivePrompt) return;
    _recentInterrupt.markInterrupted();
    try {
      final result = await _chat.stopSessionWork();
      _chat.clearStaleResumedSessionStopOffer();
      if (!result.allBackgroundWorkStopped && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(
                context,
              ).chaBackgroundWorkRemaining(result.remainingBackgroundTasks),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
    } catch (_) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chatStopSaveFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  @override
  void dispose() {
    // Corta YA la suscripción a los cambios del chat y marca el desmontaje, para
    // que ningún evento diferido del stream dispare setState sobre este State ya
    // defunct. El stream del agente NO se cancela aquí: el servicio lo mantiene
    // vivo en segundo plano (se suelta más abajo con _chatService.release).
    _disposed = true;
    final modelConfirmationNavigator = _modelConfirmationNavigator;
    final modelConfirmationRoute = _modelConfirmationRoute;
    _modelConfirmationNavigator = null;
    _modelConfirmationRoute = null;
    if (modelConfirmationNavigator != null &&
        modelConfirmationNavigator.mounted &&
        modelConfirmationRoute != null &&
        modelConfirmationRoute.isActive) {
      modelConfirmationNavigator.removeRoute(modelConfirmationRoute);
    }
    final pendingModelConfirmation = _pendingModelConfirmation;
    _pendingModelConfirmation = null;
    if (pendingModelConfirmation != null) {
      _chat.dismissSessionConfigConfirmation(pendingModelConfirmation);
    }
    _cancelSessionContextBootstrapRetry();
    _passiveConversationReader?.dispose();
    _passiveConversationReader = null;
    _subagentPollTimer?.cancel();
    _subagentPollTimer = null;
    _subagentPollingRuntimeId = null;
    _invalidatePassiveMessageRefresh();
    WidgetsBinding.instance.removeObserver(this);
    hermesRouteObserver.unsubscribe(this);
    // Al salir de la pantalla deja de ser la sesión visible (si lo era).
    _markChatVisible(false);
    _chatSub?.cancel();
    _chatSub = null;
    _attachmentDelivery?.removeAttachmentListener(_attachmentListener);
    _attachmentDelivery = null;
    // El modo voz YA NO se destruye al cerrar la pantalla: vive en el servicio
    // global y debe sobrevivir a la navegación (el agente sigue hablando y al
    // volver retomas la conversación). Solo nos desuscribimos de su estado.
    _vc?.removeListener(_onVoiceState);
    _voice?.voiceConsent.removeListener(_onVoicePreferenceChanged);
    _vcUnavailableSub?.cancel();
    _slashCompletionDebounce?.cancel();
    _stopFallback?.cancel();
    _stopConfirmationDismissTimer?.cancel();
    // Detén SOLO el dictado del composer (el de esta pantalla), no el TTS del
    // modo voz: ese debe seguir si está hablando en segundo plano.
    if (_isRecording) {
      _sttSub?.cancel();
      _voice?.stopDictation();
    }
    _sttSub = null;
    final voice = _voice;
    if (voice != null) {
      voice.cancelNativeVoicePreparationOwnedBy(this);
      _nativeVoicePreparation = null;
      voice.disableHermesServerDictation(owner: this);
      unawaited(
        voice.stopManualReadAloud(messageKeyPrefix: '${widget.session.id}:'),
      );
    }

    // La suscripción a los cambios ya se canceló arriba. Soltamos el chat del
    // servicio: si sigue en curso lo mantiene vivo en segundo plano; si no,
    // lo libera.
    if (_chatBound) {
      _chatService.release(
        widget.connection.id,
        widget.session.id,
        profile: widget.session.profile,
      );
    }

    _draftTimer?.cancel();
    _keyboardScrollTimer?.cancel();
    _streamingRevealTimer?.cancel();
    if (!_composerSubmissionInFlight && _failedTurnDiscardInFlightId == null) {
      final finalDraftSave = _saveDraftSnapshot(
        _textController.text,
        List<AttachmentDraft>.of(_pendingAttachments),
        finalDisposeSnapshot: true,
      );
      // Let this captured flush settle before retiring its producer. Storage
      // still rechecks replacement owners and cleanup epochs at each effect.
      unawaited(
        finalDraftSave.whenComplete(() {
          LocalConversationCleanupFence.endLifecycle(
            _localConversationLifecycle,
          );
        }),
      );
    } else {
      LocalConversationCleanupFence.endLifecycle(_localConversationLifecycle);
    }
    _textController.removeListener(_onComposerChanged);
    _textFocusNode
      ..removeListener(_onComposerFocusChanged)
      ..dispose();
    _textController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _liveAssistantFrame.dispose();
    _scrollToBottomVisibility.dispose();
    _activityPillExtent.dispose();
    _compaction.dispose();
    _sessionContextMetrics.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final wasInForeground = _appInForeground;
    _appInForeground = state == AppLifecycleState.resumed;
    if (wasInForeground != _appInForeground) {
      _viewerAttachGeneration += 1;
      _cancelSessionContextBootstrapRetry();
    }
    if (wasInForeground != _appInForeground && mounted && !_disposed) {
      setState(() {});
    }
    _syncPassiveTranscriptRefresh(
      refreshNow:
          wasInForeground != _appInForeground &&
          state == AppLifecycleState.resumed,
      recoveryConverging: state == AppLifecycleState.resumed,
    );
    _syncSubagentPolling();
    // El modo voz lo gobierna el controlador global (vía HermesAppState), que
    // ya recibe el ciclo de vida globalmente. Aquí solo paramos el dictado del
    // COMPOSER si la app pasa al fondo; el TTS del modo voz NO se toca para que el
    // agente termine de hablar en segundo plano.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // A setup that began while this route owned the foreground cannot regain
      // authority after an asynchronous dashboard response. This only revokes
      // the opaque preparation; an already-active opted-in conversation stays
      // under the global controller's lifecycle policy.
      _invalidateOwnedNativeVoicePreparation();
      // No dependas del debounce si Android congela o termina el proceso justo
      // después de mandar la app al fondo. Persistimos el estado exacto del
      // composer (texto + adjuntos) antes de perder tiempo de ejecución.
      _draftTimer?.cancel();
      if (!_composerSubmissionInFlight &&
          _failedTurnDiscardInFlightId == null) {
        unawaited(
          _saveDraftSnapshot(
            _textController.text,
            List<AttachmentDraft>.of(_pendingAttachments),
          ),
        );
      }
      if (_isRecording) {
        _voice?.stopDictation();
        _resetDictation();
      }
    }
    // Al volver a primer plano, repinta la configuración conocida sin mutarla.
    if (state == AppLifecycleState.resumed) {
      _loadActiveModel();
      if (_chatBound) {
        unawaited(_chat.warmDesktopGatewayForAutomaticBootstrap());
      }
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final refreshEpoch = _messageRefreshInFlightEpoch;
    if (refreshEpoch != null &&
        _messageRefreshPublishedEpoch != refreshEpoch &&
        _userIsDragging) {
      // La intención del lector manda sobre el ancla capturada al iniciar el
      // refresh. Retirarla dentro del propio callback de scroll evita que la
      // física interprete el drag como un reflow y lo corrija de vuelta. El
      // post-frame siguiente captura otra burbuja desde el viewport elegido.
      _cancelMessageRefreshViewportAnchor();
    }
    _scheduleMessageRefreshViewportReanchor();
    // Lista reverse:true → offset 0 es el FONDO (mensaje más nuevo) y
    // maxScrollExtent es lo más antiguo. "Estás abajo" = cerca de
    // minScrollExtent; medir contra maxScrollExtent detectaría lo contrario
    // (cerca de lo más viejo) → el botón "ir abajo" salía invertido en chats
    // largos y el auto-seguimiento del streaming no enganchaba.
    final atBottom = _isNearBottom;
    // El historial anterior es una acción explícita. Llegar al borde solo hace
    // visible el control flotante; nunca dispara red ni encadena páginas por un
    // rebote de física/semántica de "scroll to top".
    // La flecha representa una distancia real al final, no el estado interno
    // del seguimiento. Un toque sin desplazamiento puede pausar el auto-follow
    // durante unos milisegundos, pero no debe enseñar una acción inútil si el
    // viewport ya está abajo.
    final shouldShowBottom = !atBottom;
    // ValueNotifier: la flecha se repinta sola, sin setState de pantalla.
    _showScrollToBottom = shouldShowBottom;
    if (atBottom &&
        !_chat.isStreaming &&
        !_autoFollowStreaming &&
        _liveAssistantMaterialized) {
      _scheduleTerminalLiveHostRelease();
    }
  }

  Future<void> _loadEarlierMessages() async {
    if (_loadingEarlierMessages || !_chat.hasEarlierMessages) return;
    final position = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final previousPixels = position?.pixels;
    final previousMax = position?.maxScrollExtent;
    setState(() {
      _loadingEarlierMessages = true;
      _coreReadCoverageNoticeDismissed = false;
    });
    await _chat.loadEarlierMessages(continuePastInvisible: true);
    if (_disposed || !mounted) return;
    setState(() => _loadingEarlierMessages = false);
    if (previousPixels == null || previousMax == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted || !_scrollController.hasClients) return;
      final next = _scrollController.position;
      final extentDelta = next.maxScrollExtent - previousMax;
      if (extentDelta <= 0) return;
      // The transcript is reverse:true: older rows extend the far (max) edge,
      // while every existing row keeps its bottom-origin coordinate. Consume
      // the measured extent delta by retaining the captured coordinate rather
      // than following the new max edge.
      next.jumpTo(
        previousPixels.clamp(next.minScrollExtent, next.maxScrollExtent),
      );
    });
  }

  void _scheduleTerminalLiveHostRelease() {
    if (_terminalLiveHostReleasePending) return;
    _terminalLiveHostReleasePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _terminalLiveHostReleasePending = false;
      if (_disposed ||
          !mounted ||
          _chat.isStreaming ||
          _autoFollowStreaming ||
          !_liveAssistantMaterialized ||
          !_isNearBottom) {
        return;
      }
      _streamingViewportLock.disable();
      setState(() {
        _autoFollowStreaming = true;
        _liveAssistantMaterialized = false;
        _clearRetainedTerminalReferences();
        _showScrollToBottom = false;
        _renderProjection = null;
        _listEntriesProjection = null;
        _listEntries = null;
      });
      _liveAssistantFrame.value = null;
    });
  }

  void _expectTerminalStructuralChange() {
    _streamingViewportLock.expectStructuralChange();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _streamingViewportLock.expireStructuralChange();
    });
  }

  void _expectReportedTerminalStructuralChange() {
    _streamingViewportLock.expectReportedStructuralChange();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _streamingViewportLock.expireReportedStructuralChange();
    });
  }

  void _expectRetainedReaderAnchorChange(Map<String, dynamic> retained) {
    final anchor = _messageAnchors[retained];
    if (anchor == null || !anchor.attached) return;
    if (!_streamingViewportLock.expectAnchorVisualChange(
      anchor,
      () => _messageAnchors[retained],
    )) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _streamingViewportLock.expireAnchorVisualChange();
    });
  }

  /// Congela el seguimiento desde el PRIMER contacto, antes incluso de que el
  /// gesto se convierta en scroll. Además cancela cualquier `animateTo` que
  /// estuviera terminando para que la vista no se deslice unos píxeles más.
  void _pauseStreamingFollow(PointerDownEvent event) {
    if (!_chat.isStreaming) return;
    _streamingScrollPointer = event.pointer;
    _streamingScrollOrigin = event.position;
    _streamingScrollGestureMoved = false;
    _freezeStreamingFollow();
  }

  void _trackStreamingScrollInteraction(PointerMoveEvent event) {
    final origin = _streamingScrollOrigin;
    if (origin == null || event.pointer != _streamingScrollPointer) return;
    if ((event.position - origin).distance >= kTouchSlop) {
      _streamingScrollGestureMoved = true;
    }
  }

  bool _finishTrackedStreamingPointer(PointerEvent event) {
    if (event.pointer != _streamingScrollPointer) return false;
    final moved = _streamingScrollGestureMoved;
    _streamingScrollPointer = null;
    _streamingScrollOrigin = null;
    _streamingScrollGestureMoved = false;
    return moved;
  }

  void _freezeStreamingFollow() {
    if (!_chat.isStreaming || !_autoFollowStreaming) return;
    _streamingViewportLock.enable();
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      _scrollController.jumpTo(
        pos.pixels.clamp(pos.minScrollExtent, pos.maxScrollExtent),
      );
    }
    // Sin setState de pantalla: la lista no cambia de estructura (el host vivo
    // sigue siendo la misma entrada), la física del viewport compensa la
    // extensión y la flecha se repinta por su ValueNotifier. Congelar el
    // seguimiento significa conservar el viewport, no recortar el mensaje al
    // contador del último frame: todo lo recibido es contenido autoritativo y
    // debe seguir visible mientras el usuario desplaza la conversación.
    _streamingRevealTimer?.cancel();
    _revealedChars = _chat.assistantContent.length;
    _autoFollowStreaming = false;
    _showScrollToBottom = !_isNearBottom;
    _publishLiveAssistantFrame();
  }

  /// Si el gesto termina sin alejarse del fondo, restaura el seguimiento que
  /// se congeló en PointerDown. Si sí hubo scroll, conserva el viewport del
  /// lector y la flecha aparece por posición mediante [_onScroll].
  void _finishStreamingScrollInteraction(PointerEvent event) {
    final gestureMoved = _finishTrackedStreamingPointer(event);
    if (!_chat.isStreaming ||
        _autoFollowStreaming ||
        !_scrollController.hasClients) {
      return;
    }
    // Un arrastre real expresa intención de lectura incluso si termina dentro
    // del margen de 100 px usado por la flecha. Reengancharlo aquí hacía que el
    // siguiente token devolviera la lista al fondo y peleara con el dedo.
    if (gestureMoved && _transcriptOverflows) {
      _onScroll();
      return;
    }
    if (!_isNearBottom) return;
    final target = _chat.assistantContent.length;
    _streamingViewportLock.disable();
    // Reenganche sin setState: la estructura de la lista no cambia; el host
    // vivo se actualiza por su notifier y la flecha por el suyo.
    _autoFollowStreaming = true;
    _revealedChars = target;
    _showScrollToBottom = false;
    _publishLiveAssistantFrame();
    _scheduleLiveFollowFrame();
  }

  void _cancelStreamingScrollInteraction(PointerCancelEvent event) {
    _finishTrackedStreamingPointer(event);
  }

  /// ¿El usuario está arrastrando la lista en este instante? Si lo está, el
  /// auto-scroll y la compensación de ancla NO deben mover la vista (competirían
  /// con su gesto y la lista "se traba" al intentar subir mientras genera texto).
  bool get _userIsDragging {
    if (!_scrollController.hasClients) return false;
    return _scrollController.position.userScrollDirection !=
        ScrollDirection.idle;
  }

  /// Scroll to bottom only if the user is already near the bottom (within 100px).
  /// Si el usuario subió a leer, NO lo arrastramos: sigue el botón "ir al final".
  void _autoScrollIfNearBottom() {
    if (!_scrollController.hasClients) return;
    if (!_autoFollowStreaming) return;
    if (_userIsDragging) return; // respeta el gesto activo del usuario
    final pos = _scrollController.position;
    // reverse:true → el fondo (más nuevo) está en minScrollExtent, no en max.
    final nearBottom = pos.pixels <= pos.minScrollExtent + 100;
    if (nearBottom) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  bool get _transcriptOverflows {
    if (!_scrollController.hasClients) return false;
    final pos = _scrollController.position;
    return pos.hasContentDimensions &&
        pos.maxScrollExtent > pos.minScrollExtent + 1;
  }

  /// ¿El usuario está pegado al fondo (siguiendo el mensaje nuevo)?
  bool get _isNearBottom {
    if (!_transcriptOverflows) return true;
    final pos = _scrollController.position;
    return pos.pixels <= pos.minScrollExtent + 100;
  }

  void _scrollToBottom({
    bool animate = true,
    bool invalidateTerminalProjection = true,
  }) {
    final target = _chat.assistantContent.length;
    _streamingViewportLock.disable();
    if (!_autoFollowStreaming || _revealedChars != target) {
      setState(() {
        _autoFollowStreaming = true;
        _revealedChars = target;
        _showScrollToBottom = false;
        if (!_chat.isStreaming && invalidateTerminalProjection) {
          _liveAssistantMaterialized = false;
          _clearRetainedTerminalReferences();
          _renderProjection = null;
          _listEntriesProjection = null;
          _listEntries = null;
        }
      });
      if (_chat.isStreaming) {
        _publishLiveAssistantFrame();
        _scheduleLiveFollowFrame();
      }
    }
    if (!_chat.isStreaming && _autoFollowStreaming) {
      _liveAssistantFrame.value = null;
    }
    if (!_scrollController.hasClients) return;
    if (animate && !_reduceMotion) {
      _scrollController.animateTo(
        0,
        duration: chatNavigationDuration,
        curve: chatNavigationCurve,
      );
    } else {
      // Posicionamiento inicial / reenganche: aterriza al fondo de inmediato,
      // sin animación que compita con la transición de navegación.
      _scrollController.jumpTo(0);
    }
  }

  ChatRenderProjection get _currentRenderProjection {
    final messages = _messages;
    final cached = _renderProjection;
    if (cached != null && cached.canReuseFor(messages)) return cached;
    widget.performanceProbe?.renderProjectionBuilds++;
    return _renderProjection = ChatRenderProjection.build(messages);
  }

  List<_ChatListEntry> get _currentListEntries {
    final projection = _currentRenderProjection;
    final cached = _listEntries;
    if (cached != null && identical(_listEntriesProjection, projection)) {
      return cached;
    }
    widget.performanceProbe?.listEntryProjections++;

    // ActiveChat.messages computes the privacy/editorial projection. Read one
    // coherent snapshot for this synchronous pass, not the full history once
    // per row (quadratic on a cached long chat, before any network request).
    final messages = _messages;
    final entries = <_ChatListEntry>[];
    final retainedErrorPair =
        !_chat.isStreaming &&
        _liveAssistantMaterialized &&
        !_autoFollowStreaming &&
        _retainedTerminalError != null &&
        _retainedTerminalAssistant != null &&
        messages.length > 1 &&
        identical(messages[0], _retainedTerminalError) &&
        identical(messages[1], _retainedTerminalAssistant);
    if (retainedErrorPair) {
      entries.add(
        _RetainedTerminalErrorChatListEntry(
          errorPlan: const ChatMessageUnitPlan(0),
          assistantPlan: const ChatMessageUnitPlan(1),
        ),
      );
    }
    if (_chat.isStreaming && messages.isNotEmpty) {
      final head = messages.first;
      // El servicio puede retirar `_pipeline` antes del primer token. Como el
      // planner omite texto vacío, conserva una unidad para proyectar el estado
      // vivo en vez de dejar solo la petición del usuario.
      final liveAssistantWithoutRenderUnit =
          head['role'] == 'assistant' &&
          projection.nearestRenderableMessageIndex(0) != 0 &&
          (head['_pipeline'] != true ||
              (_liveAssistantMaterialized &&
                  _liveAssistantFrame.value != null));
      if (liveAssistantWithoutRenderUnit) {
        entries.add(_WholeChatListEntry(const ChatMessageUnitPlan(0)));
      }
    }
    for (final sourcePlan in projection.units) {
      if (retainedErrorPair &&
          sourcePlan is ChatMessageUnitPlan &&
          (sourcePlan.messageIndex == 0 || sourcePlan.messageIndex == 1)) {
        continue;
      }
      if (sourcePlan is ChatMessageUnitPlan) {
        final message = messages[sourcePlan.messageIndex];
        final plan = _assistantRenderPlanFor(message);
        if (plan != null) {
          // La lista es reverse:true: la última parte debe tener el índice más
          // bajo para quedar visualmente debajo de la primera.
          for (var index = plan.chunks.length - 1; index >= 0; index--) {
            entries.add(
              _AssistantSliceChatListEntry(
                sourcePlan,
                _AssistantRenderSlice(plan, index),
              ),
            );
          }
          continue;
        }
      }
      entries.add(_WholeChatListEntry(sourcePlan));
    }
    _listEntriesProjection = projection;
    return _listEntries = List<_ChatListEntry>.unmodifiable(entries);
  }

  _AssistantRenderPlan? _assistantRenderPlanFor(Map<String, dynamic> message) {
    // Una respuesta cancelada también se trocea: su parcial puede ser largo y
    // pintarlo como un único MarkdownBody gigante congela el frame terminal.
    if (message['role'] != 'assistant' || message['_pipeline'] == true) {
      return null;
    }
    final content = (message['content'] as String?) ?? '';
    if (content.length <= _assistantChunkMaxChars ||
        _jobChipLabel(content) != null ||
        _messageKeepsLiveHost(message) ||
        (_chat.isStreaming &&
            _messages.isNotEmpty &&
            identical(message, _messages.first))) {
      return null;
    }
    // La caché va por contenido: un Map nuevo con el mismo texto (cada flush
    // del streaming sustituye el mapa de cabeza) reutiliza el plan, así el
    // split con verificación CommonMark se ejecuta UNA vez por respuesta.
    final cached = _assistantRenderPlans.lookup(content);
    if (cached != null) return cached.value.plan;
    widget.performanceProbe?.assistantRenderPlanComputations++;

    final split = ReasoningSplit(
      reasoning: '',
      answer: finalizedPublicAssistantText(content),
    );
    if (split.answer.length <= _assistantChunkMaxChars) {
      _cacheAssistantRenderPlan(content, null);
      return null;
    }

    final chunks = <_AssistantBodyChunk>[];
    for (final mediaSegment in GeneratedMediaService.parseSegments(
      split.answer,
    )) {
      switch (mediaSegment) {
        case GeneratedMediaFileSegment(:final reference):
          chunks.add(_AssistantGeneratedMediaChunk(reference));
        case GeneratedMediaTextSegment(:final text):
          for (final imageSegment in GeneratedImageService.segments(text)) {
            switch (imageSegment) {
              case ImageSegment(:final basename):
                chunks.add(_AssistantGeneratedImageChunk(basename));
              case TextSegment(:final text):
                if (text.trim().isEmpty) continue;
                final structured = prepareAssistantAnswerStructure(text);
                for (final part in splitAssistantMarkdownForViewport(
                  structured,
                )) {
                  if (part.trim().isNotEmpty) {
                    chunks.add(_AssistantMarkdownChunk(part));
                  }
                }
            }
          }
      }
    }
    final plan = chunks.length > 1
        ? _AssistantRenderPlan(
            sourceContent: content,
            split: split,
            chunks: List<_AssistantBodyChunk>.unmodifiable(chunks),
          )
        : null;
    _cacheAssistantRenderPlan(content, plan);
    return plan;
  }

  void _cacheAssistantRenderPlan(String content, _AssistantRenderPlan? plan) {
    _assistantRenderPlans.put(content, _CachedAssistantRenderPlan(plan));
  }

  static final _urlRegex = RegExp(r'https?://[^\s\)\"]+');

  String? _firstUrl(String text) => _urlRegex.firstMatch(text)?.group(0);

  Future<void> _fetchLinkPreview(String url) async {
    if (_linkCache.containsKey(url)) return;
    _linkCache[url] = null;
    try {
      final uri = Uri.parse(url);
      final res = await http
          .get(uri, headers: {'User-Agent': 'HermesAndroid/1.0'})
          .timeout(const Duration(seconds: 5));
      final body = res.body;
      final titleMatch = RegExp(
        r'<title[^>]*>(.*?)</title>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(body);
      final title =
          titleMatch?.group(1)?.trim().replaceAll(RegExp(r'\s+'), ' ') ??
          uri.host;
      if (mounted) {
        setState(() {
          _linkCache[url] = _LinkPreviewData(title: title, domain: uri.host);
        });
      }
    } catch (_) {
      if (mounted) {
        final uri = Uri.parse(url);
        setState(() {
          _linkCache[url] = _LinkPreviewData(title: uri.host, domain: uri.host);
        });
      }
    }
  }

  void _cancelMessageRefreshViewportAnchor() {
    _messageRefreshAnchorEpoch = null;
    _streamingViewportLock.disable();
  }

  void _beginMessageRefreshViewportAnchor(int refreshEpoch) {
    _cancelMessageRefreshViewportAnchor();
    if (!_scrollController.hasClients || _isNearBottom) return;
    final viewportHeight = _scrollController.position.viewportDimension;
    Map<String, dynamic>? selectedMessage;
    RenderBox? selectedAnchor;
    var bestDistance = double.infinity;
    for (final entry in _messageAnchors.entries) {
      final anchor = entry.value;
      final top = _ChatStreamingViewportLock._visualOffsetInViewport(anchor);
      final height = anchor is ChatAnswerAnchorRenderBox
          ? anchor.laidOutHeight
          : null;
      if (top == null ||
          height == null ||
          top >= viewportHeight ||
          top + height <= 0) {
        continue;
      }
      final distance = (top + height / 2 - viewportHeight / 2).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        selectedMessage = entry.key;
        selectedAnchor = anchor;
      }
    }
    if (selectedMessage == null || selectedAnchor == null) return;

    if (!_messages.any((message) => identical(message, selectedMessage))) {
      return;
    }

    RenderBox? lookup() {
      if (_messageRefreshAnchorEpoch != refreshEpoch) return null;
      final message = chatRefreshFindAnchorMessage(selectedMessage!, _messages);
      return message == null ? null : _messageAnchors[message];
    }

    _streamingViewportLock.enable();
    _messageRefreshAnchorEpoch = refreshEpoch;
    if (!_streamingViewportLock.expectAnchorVisualChange(
      selectedAnchor,
      lookup,
    )) {
      _cancelMessageRefreshViewportAnchor();
    }
  }

  void _releaseMessageRefreshViewportAnchorAfterLayout(int refreshEpoch) {
    if (_messageRefreshAnchorEpoch != refreshEpoch) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_messageRefreshAnchorEpoch == refreshEpoch) {
        _cancelMessageRefreshViewportAnchor();
      }
    });
  }

  void _scheduleMessageRefreshViewportReanchor() {
    final refreshEpoch = _messageRefreshInFlightEpoch;
    if (refreshEpoch == null ||
        _messageRefreshPublishedEpoch == refreshEpoch ||
        _messageRefreshReanchorScheduled) {
      return;
    }
    _messageRefreshReanchorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _messageRefreshReanchorScheduled = false;
      if (_messageRefreshInFlightEpoch != refreshEpoch ||
          _messageRefreshPublishedEpoch == refreshEpoch) {
        return;
      }
      _beginMessageRefreshViewportAnchor(refreshEpoch);
    });
  }

  Future<bool> _fetchMessages({bool passiveOnly = false}) async {
    await _profileReady;
    if (_disposed || !mounted) return false;
    // No recargues sobre un stream en curso: clobbearía el parcial que llega.
    if (_chat.isStreaming) {
      if (!passiveOnly && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).chaStatusExecuting)),
        );
      }
      return true;
    }
    if (widget.session.isUnpersistedMobileDraft && _messages.isEmpty) {
      _chat.markStoredSessionMissing();
      _chat.messagesLoaded = true;
      if (mounted) {
        setState(() {
          _error = null;
        });
      }
      return true;
    }
    final refreshEpoch = ++_messageRefreshEpoch;
    final viewerGeneration = _viewerAttachGeneration;
    bool stillOwningVisible() =>
        !_disposed &&
        mounted &&
        _chatRouteVisible &&
        _appInForeground &&
        viewerGeneration == _viewerAttachGeneration;
    final hadTranscript = _messages.isNotEmpty;
    setState(() {
      _messageRefreshInFlight = (
        epoch: refreshEpoch,
        passiveOnly: passiveOnly,
        published: false,
      );
      if (!passiveOnly) _error = null;
    });
    try {
      if (hadTranscript) {
        _beginMessageRefreshViewportAnchor(refreshEpoch);
      }
      await _chat.loadMessages(
        expectedMessageCount: widget.session.messageCount,
        profile: _effectiveSessionProfile,
        passiveOnly: passiveOnly,
        stillOwningVisible: passiveOnly ? null : stillOwningVisible,
        onMessagesPublished: () {
          if (_disposed ||
              !mounted ||
              refreshEpoch != _messageRefreshEpoch ||
              _messageRefreshInFlightEpoch != refreshEpoch) {
            return;
          }
          setState(() {
            _messageRefreshInFlight = (
              epoch: refreshEpoch,
              passiveOnly: passiveOnly,
              published: true,
            );
          });
        },
      );
      if (_disposed || !mounted || refreshEpoch != _messageRefreshEpoch) {
        return false;
      }
      if (!passiveOnly) {
        // Una carga interactiva puede enlazar una sesión durable anterior. El
        // observador pasivo nunca intenta enlazar, reanudar ni adquirir runtime.
        unawaited(_ensureDesktopRuntimeAndBootstrapContext());
        _syncDesktopSessionConfig();
      }
      if (!hadTranscript) {
        _scrollToBottom();
      } else {
        _releaseMessageRefreshViewportAnchorAfterLayout(refreshEpoch);
      }
      return true;
    } catch (e) {
      if (_disposed || !mounted || refreshEpoch != _messageRefreshEpoch) {
        return false;
      }
      _cancelMessageRefreshViewportAnchor();
      if (passiveOnly) return false;
      final errStr = e.toString();
      if (errStr.contains('404') || errStr.contains('not found')) {
        final isUnpersistedMobileChat =
            widget.session.source == 'mobile' &&
            widget.session.messageCount == 0 &&
            _messages.isEmpty;
        // Hermes Desktop drops a verifiably gone id (its transcript AND its
        // row 404) to a fresh draft instead of an error; a 404 on the
        // transcript alone keeps the stable error with retry.
        final storedSessionGone =
            !isUnpersistedMobileChat &&
            _messages.isEmpty &&
            await _storedSessionIsGone();
        if (_disposed || !mounted || refreshEpoch != _messageRefreshEpoch) {
          return false;
        }
        if (storedSessionGone) {
          _chat.markStoredSessionGone();
          setState(() => _error = null);
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(Strings.of(context).chaSessionGone)),
            kind: HermesNoticeKind.warning,
          );
          return false;
        }
        if (isUnpersistedMobileChat) {
          // Un chat recién creado solo existe en el móvil hasta el primer
          // envío. Que el servidor aún no tenga transcript es el estado
          // esperado, no un error que debamos enseñar al usuario.
          _chat.markStoredSessionMissing();
          _chat.messagesLoaded = true;
        }
        setState(() {
          if (!isUnpersistedMobileChat) {
            _error = errStr;
          }
        });
        if (!isUnpersistedMobileChat) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(Strings.of(context).chaMessagesError)),
            kind: HermesNoticeKind.error,
          );
        }
        return false;
      }
      setState(() {
        _error = errStr;
      });
      return false;
    } finally {
      // Success, failure and early returns all retire the same owner. An
      // obsolete completion cannot retire (or re-lock) any newer request,
      // irrespective of how many requests have superseded it.
      if (_messageRefreshInFlightEpoch == refreshEpoch) {
        _messageRefreshInFlight = null;
        if (!_disposed && mounted) setState(() {});
      }
    }
  }

  /// The session's own row answers 404 too: deleted (here or on another
  /// surface), not a transient transcript read failure.
  Future<bool> _storedSessionIsGone() async {
    try {
      await _chat.loadPersistedSessionSnapshot();
      return false;
    } catch (error) {
      final text = error.toString();
      return text.contains('404') || text.toLowerCase().contains('not found');
    }
  }

  /// Envía con teclado físico: Ctrl/Cmd+Enter envía; Enter suelto sigue siendo
  /// newline en campos multiline. Durante dictado, el mismo atajo envía la
  /// transcripción.
  void _composerKeyboardSubmit() {
    if (_isRecording) {
      unawaited(_sendDictation());
    } else {
      unawaited(_sendMessage());
    }
  }

  /// Send message via SSE streaming (Gateway API Server).
  ///
  /// When [_pendingAttachments] are staged, text files are embedded and binary
  /// files are uploaded through the Dashboard file API before chat streaming.
  Future<bool> _sendMessage({
    String? initialText,
    bool queueOnly = false,
  }) async {
    if (_composerSubmissionInFlight ||
        _attachmentSubmitting ||
        _attachmentMutationInFlight ||
        _compressingSession) {
      return false;
    }
    // Claim the in-flight slot BEFORE any await: two same-tick sends (double
    // tap) must never both pass the guard above and submit twice.
    _composerSubmissionInFlight = true;
    try {
      await _recentInterrupt.interruptBeforeSend(_chat.cancel);
    } catch (_) {
      if (mounted) {
        setState(() => _composerSubmissionInFlight = false);
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).chaStopFailed)),
          kind: HermesNoticeKind.error,
        );
      } else {
        _composerSubmissionInFlight = false;
      }
      return false;
    }
    _passiveConversationReader?.setVisible(false);
    _invalidatePassiveMessageRefresh();
    widget.sendAttemptObserver?.call();
    if (mounted) {
      setState(() => _composerSubmissionInFlight = true);
    } else {
      _composerSubmissionInFlight = true;
    }
    final submitsAttachment = _pendingAttachments.isNotEmpty;
    if (submitsAttachment && mounted) {
      setState(() => _attachmentSubmitting = true);
    }
    try {
      return await _sendMessageOnce(
        textOverride: initialText,
        queueOnly: queueOnly,
      );
    } finally {
      if (mounted) {
        setState(() {
          _composerSubmissionInFlight = false;
          if (submitsAttachment) _attachmentSubmitting = false;
        });
      } else {
        _composerSubmissionInFlight = false;
        if (submitsAttachment) _attachmentSubmitting = false;
      }
      _syncPassiveTranscriptRefresh(refreshNow: true);
    }
  }

  Future<bool> _sendMessageOnce({
    bool skipSlashRouting = false,
    String? textOverride,
    bool includeComposerAttachments = true,
    bool queueOnly = false,
  }) async {
    await _profileReady;
    final outboxRecoveryAvailable = await _initialOutboxRead.future;
    if (!mounted) return false;
    if (_chat.mutationsBlockedByOwnershipConflict &&
        !_chat.manualOwnershipProbeAvailable) {
      return false;
    }
    if (!outboxRecoveryAvailable) {
      _showOutboxUnavailable();
      return false;
    }
    final str = Strings.of(context);
    final composerTextAtSubmit = _textController.text;
    final usesComposerState =
        textOverride == null || includeComposerAttachments;
    final rawComposerText = (textOverride ?? _textController.text).trim();
    if (!skipSlashRouting &&
        rawComposerText.startsWith('/') &&
        shouldRouteSlashBeforeBusyAttachmentQueue(rawComposerText)) {
      final invocation = parseSlashInvocation(rawComposerText);
      final local = parseSlashCommand(rawComposerText);
      if (local?.command.action == SlashAction.unavailable) {
        await _executeSlash(local!.command, local.arg);
        return true;
      }
      if (invocation == null) {
        final unknownName = rawComposerText.substring(1);
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(str.chaCommandUnknown(unknownName))),
          kind: HermesNoticeKind.warning,
        );
        return false;
      }
      if (_pendingAttachments.isNotEmpty) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(str.chaCommandAttachmentsUnsupported)),
          kind: HermesNoticeKind.warning,
        );
        return false;
      }
      if (local != null) {
        await _executeSlash(local.command, local.arg);
        return true;
      }
      if (!isUnavailableSlashName(invocation.name)) {
        final catalog = await _loadDesktopCommandCatalog();
        if (!mounted) return false;
        CommandCatalogEntry? remote;
        for (final entry
            in catalog?.commands ?? const <CommandCatalogEntry>[]) {
          if (entry.canonicalName == invocation.name ||
              entry.aliases.contains(invocation.name)) {
            remote = entry;
            break;
          }
        }
        if (remote != null) {
          await _executeSlash(
            SlashCommand.remote(
              name: remote.canonicalName,
              description: remote.description,
            ),
            invocation.arg,
          );
          return true;
        }
      }
      final unknownName = invocation.name;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(str.chaCommandUnknown(unknownName))),
        kind: HermesNoticeKind.warning,
      );
      return false;
    }
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return false;
    }
    final text = (textOverride ?? _textController.text).trim();
    final attachments = includeComposerAttachments
        ? List<AttachmentDraft>.of(_pendingAttachments)
        : const <AttachmentDraft>[];
    final selectedModel = _selectedModel;
    final firstSubmitConfig = _firstSubmitConfig;
    if (text.isEmpty && attachments.isEmpty) return false;

    // Un turno recuperado tras perder el ACK puede haberse ejecutado ya. Volver
    // a pulsar Enviar sobre el mismo texto no es una intención nueva y jamás
    // debe convertirlo en `prepared`, especialmente en transportes sin
    // idempotencia. Un texto editado sí continúa por la ruta normal con otro ID.
    final recoveredAmbiguous = _preparedTurn;
    if (usesComposerState &&
        recoveredAmbiguous != null &&
        recoveredAmbiguous.restoresComposer &&
        recoveredAmbiguous.state == PreparedTurnState.ambiguous &&
        recoveredAmbiguous.text == text) {
      // Solo la evidencia durable decide: sin fila nueva de usuario tras la
      // frontera el turno nunca llegó y se reenvía con el mismo clientTurnId.
      if (!await _settleAmbiguousTurnForRetry(recoveredAmbiguous)) {
        return false;
      }
    }

    // Desktop consume el envío como aceptado para que el draft desaparezca y
    // termina el runtime de Voz, pero solo desde el composer real. Overrides de
    // Inicio/Share/sugerencias, adjuntos o superficies no interactivas siguen el
    // flujo normal y jamás se convierten en un control oculto.
    if (interceptsTypedVoiceStop(
      typedComposerSubmission: textOverride == null && !skipSlashRouting,
      voiceRuntimeActive: _voiceForThisSession,
      attachmentsEmpty: attachments.isEmpty,
      composerAccessible: _composerAccessibleForTypedVoiceStop,
      text: text,
    )) {
      final voice = _vc!;
      final exitFuture = voice.exit();
      if (_textController.text == composerTextAtSubmit) {
        _textController.clear();
        await _clearDraft();
      } else {
        _scheduleDraftSave();
      }
      try {
        await exitFuture;
      } catch (error) {
        // La intención terminal ya fue consumida. Un teardown nativo tardío no
        // debe convertir `Stop` en prompt ni restaurarlo en el composer.
        debugPrint(
          '[voice-stab] typed stop teardown failed (${error.runtimeType})',
        );
      }
      return true;
    }
    if (attachments.isNotEmpty &&
        !await AttachmentUploader.validateBatch(attachments)) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(str.chaAttachmentValidationFailed)),
          kind: HermesNoticeKind.error,
        );
      }
      return false;
    }

    // Si estabas dictando y mandas (sin pulsar parar antes), cerramos el dictado
    // y descartamos lo que llegue después: enviar = "ya terminé este texto". Sin
    // esto, el dictado continuo seguía vivo y volvía a rellenar el composer con
    // lo ya enviado (texto duplicado).
    if (usesComposerState) _finishDictationForSend();

    // Build final message. El marcador `[📎 …]` se muestra como tarjeta; el
    // texto del usuario va visible; el payload tras el sentinel ⟦adjunto⟧ es
    // SOLO para el modelo (oculto en pantalla).
    //  - Archivos de texto → incrustamos el contenido (fiable, sin depender de
    //    librerías del servidor; no escribe nada → sin gate de aprobación).
    //  - Binarios (PDF/imagen/doc) → subimos al agente (gate) y pasamos la ruta.
    final String fullText;
    String? desktopText;
    if (attachments.isNotEmpty) {
      final payloads = <String>[];
      final binaries = <AttachmentDraft>[];

      // Valida y lee todos los textos antes de escribir nada en el servidor.
      // Si uno falla, el lote completo permanece en el composer para revisar.
      for (final attachment in attachments) {
        if (!AttachmentUploader.isTextEmbeddable(attachment)) {
          binaries.add(attachment);
          continue;
        }
        final content = await AttachmentUploader.readTextContent(attachment);
        if (content == null) {
          if (mounted) {
            final tooBig =
                attachment.sizeBytes > AttachmentUploader.maxTextBytes;
            HermesNotice.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  tooBig
                      ? Strings.of(context).chaTextFileTooBig(
                          AttachmentUploader.maxTextBytes ~/ 1024,
                        )
                      : Strings.of(context).chaTextFileError,
                ),
              ),
            );
          }
          return false;
        }
        final lang = AttachmentUploader.langHint(attachment);
        payloads.add(
          '${str.chaAttachContent(attachment.name)}'
          '```$lang\n$content\n```',
        );
      }

      // Una única aprobación cubre el lote binario completo. El canal Desktop
      // envía después los bytes por sus RPC nativos; solo si ese protocolo no
      // está disponible, ActiveChat usa la subida Dashboard de compatibilidad.
      if (binaries.isNotEmpty) {
        if (!mounted) return false;
        final approved = await confirmMutatingAction(
          context,
          instanceId: widget.connection.id,
          readOnlyInstance: widget.connection.readOnly,
          risk: CommandRisk.low,
          title: str.chaUploadTitle,
          detail: binaries.map((a) => a.messageLabel).join('\n'),
        );
        if (!approved || !mounted) return false;
      }

      // El historial conserva una copia privada verificable de cada elemento,
      // no la ruta efímera del picker/draft. Se prepara antes del transporte:
      // un fallo local mantiene intacto el composer y ejecuta cero RPC.
      final historyReferences = <AttachmentHistoryReference>[];
      for (var index = 0; index < attachments.length; index++) {
        final reference = await AttachmentUploader.persistForHistory(
          attachments[index],
          index: index,
        );
        if (reference == null) {
          if (mounted) {
            HermesNotice.of(context).showSnackBar(
              SnackBar(content: Text(str.chaAttachmentPreparationFailed)),
              kind: HermesNoticeKind.error,
            );
          }
          return false;
        }
        historyReferences.add(reference);
      }

      final buf = StringBuffer();
      final nativeBuf = StringBuffer();
      for (final attachment in attachments) {
        buf.writeln('[📎 ${attachment.messageLabel}]');
        nativeBuf.writeln('[📎 ${attachment.messageLabel}]');
      }
      if (text.isNotEmpty) buf.write(text);
      if (text.isNotEmpty) nativeBuf.write(text);
      if (payloads.isNotEmpty) {
        if (text.isNotEmpty) buf.writeln();
        buf
          ..writeln('⟦adjunto⟧')
          ..write(payloads.join('\n'));
      }
      for (final reference in historyReferences) {
        final marker = reference.toMarker();
        buf.write('\n$marker');
        nativeBuf.write('\n$marker');
      }
      fullText = buf.toString().trimRight();
      // En `/api/ws` los bytes viajan por image.attach_bytes/file.attach. El
      // texto conserva únicamente la presentación visible; las referencias de
      // archivo devueltas por Hermes se añaden justo antes de prompt.submit.
      desktopText = nativeBuf.toString().trimRight();
    } else {
      fullText = text;
    }

    if (RegExp(r'(^|\s)@[a-z0-9]', caseSensitive: false).hasMatch(text)) {
      await _chat.loadMentionRoster();
    }
    final mentions = List<BotMention>.unmodifiable(
      _chat.mentionResolver.resolve(text),
    );
    final mentionAnnotation = buildBotMentionAnnotation(mentions);
    final waitsForExternalOwner = _chat.hasAuthoritativePassiveRemoteActivity;
    // Every queued composer turn is written to the encrypted outbox before the
    // composer is cleared. This preserves FIFO across process death and keeps a
    // rejected head visible for explicit retry instead of dropping it.
    if (_sending || waitsForExternalOwner) {
      // Normal sends are next turns, never implicit steering: redirecting can
      // interrupt the live parent and its children. Steer stays a queue action.
      final now = DateTime.now().millisecondsSinceEpoch;
      final prepared = PreparedTurn(
        connectionId: widget.connection.id,
        sessionId: widget.session.id,
        clientTurnId: const Uuid().v4(),
        createdAtMs: now,
        updatedAtMs: now,
        text: text,
        fullText: fullText,
        desktopText: desktopText,
        mentions: mentions,
        mentionAnnotation: mentionAnnotation,
        attachments: attachments,
        model: selectedModel,
        profile: _effectiveSessionProfile,
        state: PreparedTurnState.prepared,
        restoresComposer: usesComposerState,
        queued: true,
      );
      final delivery = ActiveTurnDelivery(
        prepared: prepared,
        store: await _outboxStore(),
      );
      if (!await _chat.enqueuePreparedTurn(delivery)) {
        if (usesComposerState) await _saveDraftSnapshot(text, attachments);
        _showOutboxUnavailable();
        return false;
      }
      if (usesComposerState &&
          _textController.text == composerTextAtSubmit &&
          _sameAttachmentDrafts(_pendingAttachments, attachments)) {
        _draftTimer?.cancel();
        _restoringDraft = true;
        setState(() {
          _textController.clear();
          _pendingAttachments.clear();
        });
        _restoringDraft = false;
        await _clearDraft();
      } else {
        _scheduleDraftSave();
      }
      if (mounted) {
        HermesNotice.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(str.chaSteerQueued)));
      }
      return true;
    }

    final unresolvedHiddenTurn = _preparedTurn;
    if (unresolvedHiddenTurn != null &&
        !unresolvedHiddenTurn.restoresComposer &&
        unresolvedHiddenTurn.state != PreparedTurnState.terminal) {
      _showHiddenRecoveredTurn(unresolvedHiddenTurn);
      return false;
    }

    // Quitar un chip sigue disponible mientras se prepara el lote. Si cambió
    // antes de tocar la outbox, abortamos este intento y conservamos el draft
    // visible en vez de enviar una copia obsoleta.
    if (usesComposerState &&
        !_sameAttachmentDrafts(_pendingAttachments, attachments)) {
      _scheduleDraftSave();
      return false;
    }

    // Crea la identidad recuperable antes del último trabajo local y, sobre
    // todo, antes de tocar el transporte. Un retry manual del mismo composer
    // reutiliza el ID; servidores heredados no reciben este campo todavía.
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _preparedTurn;
    final profile = _effectiveSessionProfile;
    final sameRecoveredBatch =
        existing?.matchesBatch(
          text: text,
          attachments: attachments,
          model: selectedModel,
          profile: profile,
          restoresComposer: usesComposerState,
        ) ??
        false;
    final replacesProvenRejectedProjection =
        sameRecoveredBatch &&
        existing!.state == PreparedTurnState.failedBeforeAcceptance;
    final prepared = PreparedTurn(
      connectionId: widget.connection.id,
      sessionId: widget.session.id,
      clientTurnId: sameRecoveredBatch
          ? existing!.clientTurnId
          : const Uuid().v4(),
      createdAtMs: sameRecoveredBatch ? existing!.createdAtMs : now,
      updatedAtMs: now,
      text: text,
      fullText: sameRecoveredBatch ? existing!.fullText : fullText,
      desktopText: sameRecoveredBatch ? existing!.desktopText : desktopText,
      mentions: sameRecoveredBatch ? existing!.mentions : mentions,
      mentionAnnotation: sameRecoveredBatch
          ? existing!.mentionAnnotation
          : mentionAnnotation,
      attachments: attachments,
      model: selectedModel,
      profile: profile,
      state: PreparedTurnState.prepared,
      restoresComposer: usesComposerState,
    );
    final outbox = await _outboxStore();
    if (!await _persistPreparedTurn(outbox, prepared)) {
      if (usesComposerState) await _saveDraftSnapshot(text, attachments);
      _showOutboxUnavailable();
      return false;
    }

    await _persistAutoTitleIfNeeded(fullText);

    // Última fence local: entre la escritura segura y ActiveChat.send todavía
    // puede llegar un remove. No se entrega al transporte un lote distinto del
    // que la pantalla sigue mostrando.
    if (usesComposerState &&
        !_sameAttachmentDrafts(_pendingAttachments, attachments)) {
      final currentPrepared = _attachmentDelivery?.current ?? prepared;
      try {
        await outbox.delete(currentPrepared);
      } catch (_) {}
      if (identical(_preparedTurn, prepared) ||
          _preparedTurn?.storageId == prepared.storageId) {
        _preparedTurn = null;
      }
      _observeAttachmentDelivery(null);
      _scheduleDraftSave();
      return false;
    }

    if (replacesProvenRejectedProjection) {
      _removeLatestFailedPromptProjection(prepared.fullText);
    }

    // Historial conversacional para el run (formato OpenAI, orden cronológico).
    // Solo turnos reales de user/assistant con texto: descarta placeholders del
    // pipeline, errores y eventos de herramienta para no ensuciar el contexto.
    // Texto y voz comparten exactamente la misma reconstrucción. En particular,
    // Stop conserva lo visible como contexto con una nota de no-reanudación.
    final history = _chat.buildHistory();

    // Guarda de ciclo de vida: la pantalla puede cerrarse durante el await
    // anterior. Solo protegemos los setState/scroll del widget; el envío al
    // ActiveChat sigue ejecutándose siempre (el chat sobrevive a la navegación).
    // El streaming vive en el servicio singleton (sobrevive a la navegación): el
    // ActiveChat inserta los mensajes optimistas, acumula tokens/trace, refresca
    // al terminar y notifica si la app está en 2º plano. La UI reacciona vía
    // _onChatEvent. Registramos la sesión como activa para el indicador de lista.
    final delivery = ActiveTurnDelivery(prepared: prepared, store: outbox);
    _observeAttachmentDelivery(delivery);
    final acceptedFuture = _chat.send(
      fullText: prepared.fullText,
      model: selectedModel,
      history: history,
      profile: _effectiveSessionProfile,
      nativeAttachments: attachments,
      desktopText: prepared.desktopText,
      delivery: delivery,
      sessionConfig: firstSubmitConfig,
      beforeDesktopPromptSubmit: _usesLocalBotChatPin
          ? _persistBotChatPinBeforePrompt
          : _usesOfficialBotChatPin
          ? _assertOfficialBotChatPinBeforePrompt
          : null,
    );
    _chatService.markStarted(widget.connection.id, widget.session.id);

    // ActiveChat ya insertó la burbuja optimista. Liberamos visualmente el lote
    // en ese mismo frame, sin esperar al ACK, y dejamos outbox + draft cifrado
    // como fuente de recuperación. La valla exterior impide un segundo tap o
    // Enter durante esta ventana. Si el transporte rechaza el turno, el lote se
    // restaura exactamente debajo.
    final ownsComposerBatch =
        textOverride == null &&
        mounted &&
        _textController.text == composerTextAtSubmit &&
        _sameAttachmentDrafts(_pendingAttachments, attachments);
    var composerReleasedBeforeAcceptance = false;
    if (ownsComposerBatch) {
      _draftTimer?.cancel();
      _restoringDraft = true;
      setState(() {
        _textController.clear();
        _pendingAttachments.clear();
        _composerPreparedTurnClientTurnId = null;
        _showScrollToBottom = false;
      });
      _restoringDraft = false;
      composerReleasedBeforeAcceptance = true;
      FocusManager.instance.primaryFocus?.unfocus();
    }
    final accepted = await acceptedFuture;
    if (!accepted) {
      // El transporte no confirmó el turno. Texto y lote permanecen tanto en
      // pantalla como en el borrador persistente; reintentar no pierde imágenes.
      _preparedTurn = delivery.current;
      _composerPreparedTurnClientTurnId =
          delivery.current.state == PreparedTurnState.failedBeforeAcceptance &&
              delivery.current.restoresComposer
          ? delivery.current.clientTurnId
          : null;
      if (mounted && composerReleasedBeforeAcceptance) {
        _restoringDraft = true;
        setState(() {
          if (_textController.text.isEmpty && _pendingAttachments.isEmpty) {
            _textController.value = TextEditingValue(
              text: composerTextAtSubmit,
              selection: TextSelection.collapsed(
                offset: composerTextAtSubmit.length,
              ),
            );
            _pendingAttachments.addAll(attachments);
          }
        });
        _restoringDraft = false;
      }
      if (usesComposerState) {
        await _saveDraftSnapshot(
          text,
          attachments,
          preparedTurnClientTurnId: _composerPreparedTurnClientTurnId,
        );
      }
      if (delivery.persistenceFailed && !delivery.transportStarted) {
        _showOutboxUnavailable();
      }
      return false;
    }

    // ActiveChat guardó accepted ANTES de devolver true. Conserva la propiedad
    // aunque esta ruta se haya destruido mientras esperaba el ACK.
    final acceptedTurn = delivery.current;
    _preparedTurn = acceptedTurn;
    _composerPreparedTurnClientTurnId = null;
    if (delivery.persistenceFailed) {
      // El servidor ya confirmó el prompt; no se vuelve a habilitar como si no
      // se hubiera enviado. Intentamos retirar cualquier marca obsoleta.
      try {
        await outbox.delete(prepared);
      } catch (error) {
        debugPrint(
          '[turn-outbox] secure cleanup failed (${error.runtimeType})',
        );
      }
    }

    // La UI solo entrega la propiedad del turno después del ACK. Antes de este
    // punto cualquier timeout, lectura o attach fallido conserva el lote exacto.
    final composerUnchanged =
        mounted && _textController.text == composerTextAtSubmit;
    final attachmentsUnchanged =
        mounted && _sameAttachmentDrafts(_pendingAttachments, attachments);
    final canReleaseSubmittedDraft =
        composerReleasedBeforeAcceptance ||
        (textOverride == null && composerUnchanged && attachmentsUnchanged);
    if (mounted &&
        canReleaseSubmittedDraft &&
        !composerReleasedBeforeAcceptance) {
      _textController.clear();
      setState(() {
        _showScrollToBottom = false;
        _pendingAttachments.clear();
      });
      // Cierra el teclado al enviar: la respuesta suele ocupar gran parte de la
      // pantalla y el usuario ya no necesita editar el lote aceptado.
      FocusManager.instance.primaryFocus?.unfocus();
    }
    if (canReleaseSubmittedDraft) {
      await _clearDraft();
    } else {
      // El usuario empezó un turno nuevo mientras esperaba el ACK. Ese draft
      // no pertenece al envío aceptado y nunca debe borrarse junto con él.
      _scheduleDraftSave();
    }
    _preparedTurn = acceptedTurn;

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    return true;
  }

  Future<void> _persistAutoTitleIfNeeded(String prompt) async {
    final hasPriorUserTurn = _messages.any((m) => m['role'] == 'user');
    if (hasPriorUserTurn) return;
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, widget.connection.id);
    await archive.autoTitleIfPlaceholder(
      sessionId: widget.session.id,
      currentTitle: widget.session.title,
      prompt: prompt,
    );
  }

  Future<void> _cancelStream() async {
    if (!_chat.gatewayConnected) return;
    _recentInterrupt.markInterrupted();
    var cancelled = false;
    try {
      final override = widget.cancelStreamOverride;
      SessionStopResult? result;
      if (override != null) {
        await override();
      } else {
        result = await _chat.stopSessionWork();
      }
      _chat.clearStaleResumedSessionStopOffer();
      if (result != null && !result.allBackgroundWorkStopped && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(
                context,
              ).chaBackgroundWorkRemaining(result.remainingBackgroundTasks),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
      cancelled = true;
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).chaStopFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    }
    if (!cancelled || !mounted) return;
    setState(() {});
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted && _pipelineState == ChatPipelineState.cancelled) {
        setState(() => _pipelineState = ChatPipelineState.idle);
      }
    });
  }

  /// Retry the last failed send.
  Future<void> _retryLastPrompt([String? bubblePrompt]) async {
    // The error bubble remembers its own prompt; after a relaunch the screen's
    // last prompt can be empty while the bubble is still on screen.
    final prompt = _lastPrompt.isNotEmpty ? _lastPrompt : (bubblePrompt ?? '');
    if (_chat.awaitingDurableTurnRecovery) {
      final reconciled = await _chat.reconcileAfterResume();
      if (reconciled || !mounted || _chat.state != ChatPipelineState.failed) {
        return;
      }
      // The server holds no evidence of this turn: reconciling cannot recover
      // anything, so the retry the user asked for is a real resend.
    }
    if (prompt.isEmpty) return;
    // Un fallo de transporte antes del ACK deja el turno `ambiguous`. Hay que
    // resolverlo ANTES de retirar la proyección fallida: si no se puede
    // demostrar que el servidor no lo tiene, la burbuja y el error se quedan.
    // La burbuja se empareja con su lote por clientTurnId (el texto puede
    // diferir por adjuntos/menciones). Solo burbujas legadas sin identidad
    // caen al texto exacto.
    final pending = _preparedTurn;
    final failedClientTurnId = _chat.latestFailedTurnClientTurnId;
    if (pending != null &&
        pending.restoresComposer &&
        pending.state == PreparedTurnState.ambiguous &&
        (failedClientTurnId != null
            ? failedClientTurnId == pending.clientTurnId
            : pending.text == prompt.trim())) {
      if (!await _settleAmbiguousTurnForRetry(pending) || !mounted) return;
    }
    _removeLatestFailedPromptProjection(prompt, allowLegacyContentPair: true);
    // En un fallo previo al ACK, el composer ya conserva el texto y todos los
    // adjuntos originales. Solo reconstruimos desde lastPrompt para sesiones
    // antiguas o fallos posteriores al ACK donde el composer sí estaba vacío.
    if (_textController.text.trim().isEmpty && _pendingAttachments.isEmpty) {
      _textController.text = prompt;
    }
    setState(() => _pipelineState = ChatPipelineState.idle);
    await _sendMessage();
  }

  /// Resuelve un turno `ambiguous` del composer contra el transcript durable.
  /// Devuelve true solo cuando está demostrado que el servidor no lo recibió
  /// (el lote queda como `failedBeforeAcceptance` y el envío reutiliza su ID).
  /// Si el servidor ya lo persistió, se adopta el transcript sin reenviar.
  Future<bool> _settleAmbiguousTurnForRetry(PreparedTurn prepared) async {
    final evidence = await _chat.resolveAmbiguousRetryFromTranscript(prepared);
    if (!mounted || !identical(_preparedTurn, prepared)) return false;
    switch (evidence) {
      case AmbiguousRetryEvidence.notDelivered:
        final proven = prepared.copyWith(
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          state: PreparedTurnState.failedBeforeAcceptance,
        );
        if (!await _persistPreparedTurn(await _outboxStore(), proven)) {
          _showOutboxUnavailable();
          return false;
        }
        _composerPreparedTurnClientTurnId = proven.clientTurnId;
        return mounted;
      case AmbiguousRetryEvidence.delivered:
        try {
          await (await _outboxStore()).delete(prepared);
        } catch (error) {
          debugPrint(
            '[turn-outbox] delivered retry cleanup failed '
            '(${error.runtimeType})',
          );
          return false;
        }
        if (identical(_preparedTurn, prepared)) {
          _preparedTurn = null;
          _composerPreparedTurnClientTurnId = null;
        }
        _chat.removeLatestFailedPromptProjection(
          prepared.fullText,
          allowLegacyContentPair: true,
        );
        if (mounted && _textController.text.trim() == prepared.text) {
          _restoringDraft = true;
          setState(() {
            _textController.clear();
            _pendingAttachments.clear();
          });
          _restoringDraft = false;
          await _clearDraft();
        }
        if (mounted) setState(() => _pipelineState = ChatPipelineState.idle);
        await _chat.reconcileAfterResume();
        return false;
      case AmbiguousRetryEvidence.unknown:
        _showHiddenRecoveredTurn(prepared);
        return false;
    }
  }

  bool _removeLatestFailedPromptProjection(
    String prompt, {
    bool allowLegacyContentPair = false,
  }) => _chat.removeLatestFailedPromptProjection(
    prompt,
    allowLegacyContentPair: allowLegacyContentPair,
  );

  int? _userOrdinalFor(Map<String, dynamic> target) {
    return _currentRenderProjection.userOrdinalFor(target);
  }

  bool _attachmentsCanBeReused(List<_ParsedAttachment> attachments) =>
      attachments.every((attachment) => attachment.historyReference != null);

  Future<List<AttachmentDraft>?> _resolveAttachmentsForEdit(
    List<_ParsedAttachment> attachments,
  ) async {
    final drafts = <AttachmentDraft>[];
    for (final attachment in attachments) {
      final reference = attachment.historyReference;
      if (reference == null) return null;
      final file = await AttachmentUploader.resolveHistoryReference(reference);
      if (file == null) return null;
      drafts.add(
        AttachmentDraft(
          localId: 'edit-${reference.index}-${reference.storageKey}',
          type: reference.type,
          name: attachment.name,
          mimeType: reference.mimeType,
          sizeBytes: reference.sizeBytes,
          localPath: file.path,
        ),
      );
    }
    return drafts;
  }

  String _editedAttachmentContent({
    required String raw,
    required List<_ParsedAttachment> attachments,
    required String editedText,
    required bool includePayload,
  }) {
    final result = <String>[
      for (final attachment in attachments)
        '[📎 ${attachment.name}${attachment.sizeLabel.isEmpty ? '' : ' · ${attachment.sizeLabel}'}]',
      editedText,
    ];
    final lines = stripBotMentionNote(raw).split('\n');
    final sentinel = lines.indexWhere((line) => line.trim() == '⟦adjunto⟧');
    if (includePayload && sentinel >= 0) {
      result.add('⟦adjunto⟧');
      result.addAll(
        lines
            .skip(sentinel + 1)
            .where(
              (line) => AttachmentHistoryReference.tryParseMarker(line) == null,
            ),
      );
    }
    result.addAll(
      attachments.map((attachment) => attachment.historyReference!.toMarker()),
    );
    return result.join('\n').trimRight();
  }

  bool _canEditUserMessage(Map<String, dynamic> message) {
    final parsed = _parseUserContent((message['content'] ?? '').toString());
    final ordinal = _userOrdinalFor(message);
    if (widget.connection.readOnly ||
        _editingUserMessage ||
        _compressingSession ||
        ordinal == null ||
        parsed.text.trim().isEmpty ||
        !_attachmentsCanBeReused(parsed.attachments)) {
      return false;
    }
    return true;
  }

  /// ¿Es una fila del asistente cuyo único contenido es traza (razonamiento /
  /// herramientas), sin texto visible, medios ni desenlace parado/cancelado?
  bool _isTraceOnlyAssistantRow(Map<String, dynamic> row) {
    if (row['role'] != 'assistant' ||
        (row['display_kind']?.toString().trim().isNotEmpty ?? false) ||
        row['_pipeline'] == true ||
        row['_cancelled'] == true ||
        row['_stopped'] == true ||
        ((row['content'] as String?) ?? '').trim().isNotEmpty ||
        _structuredGeneratedImages(row).isNotEmpty ||
        _structuredGeneratedVideos(row).isNotEmpty) {
      return false;
    }
    return normalizeAssistantActivityTrace(
          row[assistantActivityTraceKey],
        ).isNotEmpty ||
        (row['reasoning'] is String &&
            (row['reasoning'] as String).trim().isNotEmpty);
  }

  /// ¿Es una respuesta con texto visible, terminada y sin parar/cancelar?
  bool _isMergeTargetAnswer(Map<String, dynamic> row) =>
      row['role'] == 'assistant' &&
      !(row['display_kind']?.toString().trim().isNotEmpty ?? false) &&
      row['_pipeline'] != true &&
      row['_cancelled'] != true &&
      row['_stopped'] != true &&
      ((row['content'] as String?) ?? '').trim().isNotEmpty;

  /// Fusión de filas solo-traza con la respuesta que las sigue en el MISMO turno
  /// (adyacentes, sin mensaje de usuario entre ellas):
  ///  * en la fila solo-traza, `hidden` (no se pinta);
  ///  * en la respuesta, `merged` con los pasos de todas (más antiguos primero).
  /// El turno en vivo no se fusiona, ni se cruza un mensaje de usuario ni un
  /// desenlace parado/cancelado.
  ({bool hidden, Map<String, dynamic>? merged})? _traceMergeFor(
    Map<String, dynamic> msg,
  ) {
    final projection = _currentRenderProjection;
    final index = projection.messageIndexOf(msg);
    if (index == null) return null;
    if (_isTraceOnlyAssistantRow(msg)) {
      final newerIndex = index - 1;
      if (newerIndex < 0) return null;
      final newer = _messages[newerIndex];
      // Una fila solo-traza seguida de otra solo-traza se funde con la cadena
      // completa: la oculta es cada una salvo que la cadena acabe en respuesta.
      var probe = newerIndex;
      var row = newer;
      while (_isTraceOnlyAssistantRow(row) && probe > 0) {
        probe -= 1;
        row = _messages[probe];
      }
      final liveHead = _chat.isStreaming && probe == 0;
      if (!liveHead && _isMergeTargetAnswer(row)) {
        return (hidden: true, merged: null);
      }
      return null;
    }
    if (!_isMergeTargetAnswer(msg)) return null;
    final older = <Map<String, dynamic>>[];
    var probe = index + 1;
    while (probe < _messages.length &&
        _isTraceOnlyAssistantRow(_messages[probe])) {
      older.add(_messages[probe]);
      probe += 1;
    }
    if (older.isEmpty) return null;
    // La copia fusionada se reutiliza mientras las filas de origen no cambien:
    // su identidad alimenta la selección de texto y no debe variar por frame.
    final cached = _traceMergeCache[msg];
    if (cached != null &&
        cached.sources.length == older.length &&
        [
          for (var i = 0; i < older.length; i++)
            identical(cached.sources[i], older[i]),
        ].every((same) => same)) {
      return (hidden: false, merged: cached.merged);
    }
    // `older` va del más nuevo al más antiguo: se invierte para el orden real.
    final chain = [...older.reversed, msg];
    final steps = <Map<String, dynamic>>[
      for (final row in chain)
        ...normalizeAssistantActivityTrace(row[assistantActivityTraceKey]),
    ];
    final reasoning = [
      for (final row in chain)
        if (row['reasoning'] is String &&
            (row['reasoning'] as String).trim().isNotEmpty)
          (row['reasoning'] as String).trim(),
    ].join('\n\n');
    var seconds = 0.0;
    var hasSeconds = false;
    for (final row in chain) {
      final value = row['_activity_duration_seconds'];
      if (value is num && value.isFinite && value > 0) {
        seconds += value;
        hasSeconds = true;
      }
    }
    final merged = <String, dynamic>{
      ...msg,
      if (steps.isNotEmpty) assistantActivityTraceKey: steps,
      if (reasoning.isNotEmpty) 'reasoning': reasoning,
      if (hasSeconds) '_activity_duration_seconds': seconds,
    };
    if (_traceMergeCache.length > 64) _traceMergeCache.clear();
    _traceMergeCache[msg] = (sources: older, merged: merged);
    return (hidden: false, merged: merged);
  }

  final Map<
    Map<String, dynamic>,
    ({List<Map<String, dynamic>> sources, Map<String, dynamic> merged})
  >
  _traceMergeCache = Map.identity();

  bool _isLatestAssistant(Map<String, dynamic> target) {
    final indexes = _currentRenderProjection.assistantMessageIndexesNewestFirst;
    return indexes.isNotEmpty && identical(_messages[indexes.first], target);
  }

  void _editUserMessage(Map<String, dynamic> message, double bubbleWidth) {
    final ordinal = _userOrdinalFor(message);
    if (ordinal == null) return;
    final rawContent = (message['content'] ?? '').toString();
    final parsed = _parseUserContent(rawContent);
    if (parsed.text.trim().isEmpty ||
        !_attachmentsCanBeReused(parsed.attachments)) {
      return;
    }
    Map<String, dynamic>? target;
    final snapshot = _chat.messages.map((entry) {
      final copy = Map<String, dynamic>.from(entry);
      if (identical(entry, message)) target = copy;
      return copy;
    }).toList();
    if (target == null) return;
    setState(() {
      _editingUserMessage = true;
      _editingUserMessageTarget = target;
      _editingUserMessageWidth = bubbleWidth;
      _editingUserMessageText = parsed.text.trim();
      _editingUserMessageOrdinal = ordinal;
      _editingRewriteSubmitted = false;
      _editingMessagesSnapshot = snapshot;
      _editingPipelineSnapshot = _chat.state;
    });
  }

  void _cancelUserMessageEdit() {
    if (_editingRewriteSubmitted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(_clearUserMessageEditingState);
  }

  Future<void> _saveUserMessageEdit(String edited) async {
    final message = _editingUserMessageTarget;
    if (message == null || _editingRewriteSubmitted) return;
    final ordinal = _editingUserMessageOrdinal;
    if (ordinal == null) return;
    final rawContent = (message['content'] ?? '').toString();
    final parsed = _parseUserContent(rawContent);
    if (edited.isEmpty || edited == parsed.text.trim()) return;
    setState(() => _editingRewriteSubmitted = true);

    final nativeAttachments = parsed.attachments.isEmpty
        ? const <AttachmentDraft>[]
        : await _resolveAttachmentsForEdit(parsed.attachments);
    if (!mounted) return;
    if (nativeAttachments == null) {
      setState(_clearUserMessageEditingState);
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaEditFailed)),
        kind: HermesNoticeKind.error,
      );
      return;
    }
    final rewriteText = parsed.attachments.isEmpty
        ? edited
        : _editedAttachmentContent(
            raw: rawContent,
            attachments: parsed.attachments,
            editedText: edited,
            includePayload: true,
          );
    final desktopRewriteText = parsed.attachments.isEmpty
        ? null
        : _editedAttachmentContent(
            raw: rawContent,
            attachments: parsed.attachments,
            editedText: edited,
            includePayload: false,
          );

    var failed = false;
    var authRequired = false;
    Object? failure;
    _editingRewriteSubmitted = true;
    try {
      await _chat.rewrite(
        userOrdinal: ordinal,
        text: rewriteText,
        model: _selectedModel,
        profile: _effectiveSessionProfile,
        desktopText: desktopRewriteText,
        mentionText: edited,
        nativeAttachments: nativeAttachments,
      );
      // Un rechazo previo al arranque no lanza: `rewrite` rebobina y lo deja
      // marcado. Sin consultarlo, la edición fracasaba en silencio — el turno
      // vivo ya interrumpido y ni respuesta ni aviso en pantalla.
      if (_chat.takeRewindRestoredOnError()) {
        failed = true;
        authRequired = _chat.takeRewindDashboardAuthRequired();
      } else {
        _chatService.markStarted(widget.connection.id, widget.session.id);
      }
    } catch (error) {
      final rpc = error is TuiGatewayRpcError ? error : null;
      debugPrint(
        '[chat-edit] rewrite failed '
        '(${error.runtimeType}'
        '${rpc == null ? '' : ', method=${rpc.method}, code=${rpc.code}'})',
      );
      failed = true;
      failure = error;
    }
    if (!mounted) return;
    setState(() {
      if (failed || _editingMessagesSnapshot == null) {
        _clearUserMessageEditingState();
      }
    });
    if (failed) {
      final str = Strings.of(context);
      final message = failure is DashboardAuthException
          ? localizedApiError(str, failure)
          : (authRequired ? str.dashboardAuthLoginRequired : str.chaEditFailed);
      HermesNotice.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _editQueuedEntry(QueuedEntryView entry) async {
    if (_editingQueuedEntryId != null ||
        entry.kind == QueuedEntryKind.desktopAccepted) {
      return;
    }
    setState(() => _editingQueuedEntryId = entry.id);
    final edited = await showHermesFloatingSurface<String>(
      context: context,
      surfaceKey: ValueKey('chat-queue-edit-dialog-${entry.id}'),
      maxWidth: 560,
      maxHeightFactor: 1,
      builder: (_) => _EditQueuedEntrySheet(initialText: entry.text),
    );
    if (!mounted) return;
    var saved = true;
    if (edited != null &&
        edited.trim().isNotEmpty &&
        edited.trim() != entry.text) {
      saved = await _chat.editQueuedTurn(entry.id, edited);
    }
    if (!mounted) return;
    setState(() => _editingQueuedEntryId = null);
    if (!saved) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaQueueEditFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<void> _steerQueuedEntry(String id) async {
    final outcome = await _chat.steerQueuedTurnWithOutcome(id);
    if (!mounted) return;
    final strings = Strings.of(context);
    final message = switch (outcome) {
      QueuedSteerOutcome.accepted || QueuedSteerOutcome.rejected => null,
      QueuedSteerOutcome.unconfirmed => strings.chaQueueSteerUnconfirmed,
      QueuedSteerOutcome.queueRemovalFailed =>
        strings.chaQueueSteerCleanupFailed,
    };
    if (message == null) return;
    HermesNotice.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _regenerateLastResponse() async {
    final projection = _currentRenderProjection;
    final user = projection.latestUserMessage;
    if (user == null) return;
    final userOrdinal = projection.userOrdinalFor(user);
    if (userOrdinal == null) return;
    final prompt = (user['content'] ?? '').toString().trim();
    if (prompt.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(Strings.of(dialogContext).chaRegenerate),
        content: Text(Strings.of(dialogContext).chaRegenerateWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(Strings.of(dialogContext).chaRegenerate),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _chat.rewrite(
        userOrdinal: userOrdinal,
        text: prompt,
        model: _selectedModel,
        profile: _effectiveSessionProfile,
      );
      if (_chat.takeRewindRestoredOnError()) {
        _chat.takeRewindDashboardAuthRequired();
        throw StateError('regenerate rejected before it started');
      }
      _chatService.markStarted(widget.connection.id, widget.session.id);
      if (mounted) setState(() {});
    } catch (_) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaRegenerateFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  /// Reinicia el gateway del servidor desde el error del chat (cuando el agente
  /// parece colgado). Pide confirmación y avisa del resultado. Reutiliza el
  /// mismo endpoint que Ajustes (POST /api/gateway/restart vía Dashboard).
  Future<void> _restartGatewayFromChat() async {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    if (HermesUpdateGuard.isActive(widget.connection.id)) {
      HermesNotice.of(
        context,
      ).showSnackBar(SnackBar(content: Text(str.setUpdateAlreadyRunning)));
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        content: Text(
          str.chaRestartGatewayConfirm,
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(str.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(str.chaRestartGateway),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final messenger = HermesNotice.of(context);
    final client = DashboardClient.lazy(widget.connection);
    try {
      await client.restartGateway();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(str.chaRestartGatewayDone)),
        kind: HermesNoticeKind.success,
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(str.chaRestartGatewayFail(e.toString()))),
        kind: HermesNoticeKind.error,
      );
    }
  }

  /// Abre una sesión nueva vacía sobre la misma instancia (mismo flujo que crear
  /// desde la lista de sesiones). Reemplaza la ruta actual para no apilar chats:
  /// el chat anterior sigue vivo en `ActiveChatService` y es accesible desde la
  /// lista. El stream en curso (si lo hay) no se interrumpe.
  void _newChat() {
    final session = Session(
      id: GatewayChatClient.generateSessionId(),
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
      profile: _effectiveSessionProfile,
    );
    Navigator.pushReplacement(
      context,
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (context, animation, _) =>
            ChatScreen(connection: widget.connection, session: session),
        transitionsBuilder: (context, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(opacity: curved, child: child);
        },
      ),
    );
  }

  // ── Comandos slash ─────────────────────────────────────────────────────────

  /// El usuario elige un comando de la paleta. Los que llevan argumento rellenan
  /// `/nombre ` y mantienen el foco; el resto se ejecutan al instante.
  void _pickSlash(SlashCommand cmd) {
    if (cmd.takesArg) {
      _textController.text = '/${cmd.name} ';
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
      setState(() => _slashSuggestions = const []);
      return;
    }
    _executeSlash(cmd, '');
  }

  /// La paleta de comandos slash está a la vista sobre el compositor.
  ///
  /// Como el menú de Hermes Desktop (se cierra al perder el foco), solo vive
  /// mientras el composer tiene el foco, y nunca sobre el drawer abierto: el
  /// overlay que la aloja pinta por encima del Scaffold entero.
  bool get _slashPaletteVisible =>
      !(_isRecording ||
          _transcribing ||
          _compressingSession ||
          _navigationDrawerOpen ||
          !_textFocusNode.hasFocus ||
          _slashSuggestions.isEmpty);

  void _consumeSlashInvocation(String invocation) {
    if (_textController.text != invocation) return;
    _textController.clear();
    setState(() => _slashSuggestions = const []);
  }

  /// Restaura un `/comando` en el composer tras un rechazo definitivo — el
  /// mismo trato que un mensaje normal que el transporte no aceptó. Solo si
  /// el usuario no empezó a escribir algo nuevo mientras tanto.
  void _restoreSlashInvocation(String invocation) {
    if (!mounted || _textController.text.isNotEmpty) return;
    setState(
      () => _textController.value = TextEditingValue(
        text: invocation,
        selection: TextSelection.collapsed(offset: invocation.length),
      ),
    );
  }

  /// Ejecuta un comando slash conocido sin decidir el foco globalmente. Las
  /// rutas y superficies modales gestionan su propio foco; los errores conservan
  /// la invocación y las acciones aceptadas consumen el composer.
  Future<void> _executeSlash(SlashCommand cmd, String arg) async {
    if (cmd.action == SlashAction.remote) {
      await _executeRemoteSlash(cmd, arg);
      return;
    }
    if (cmd.action == SlashAction.unavailable) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).chaCompactUnavailable),
          duration: const Duration(seconds: 7),
        ),
        kind: HermesNoticeKind.warning,
      );
      return;
    }
    if (cmd.action == SlashAction.model && arg.trim().isNotEmpty) {
      final invocation = _textController.text;
      final consumed = await _setModelByName(arg.trim());
      if (!mounted || !consumed) return;
      _consumeSlashInvocation(invocation);
      return;
    }
    if (cmd.action == SlashAction.compress) {
      final invocation = _textController.text;
      final consumed = await _compressDesktopSession(arg);
      if (!mounted || !consumed) return;
      _consumeSlashInvocation(invocation);
      return;
    }
    _textController.clear();
    setState(() => _slashSuggestions = const []);
    switch (cmd.action) {
      case SlashAction.help:
        _showSlashHelp();
      case SlashAction.newChat:
        _newChat();
      case SlashAction.compress:
        return;
      case SlashAction.model:
        if (arg.trim().isEmpty) {
          _showModelSheet();
        } else {
          await _setModelByName(arg.trim());
        }
      case SlashAction.skills:
        _pushScreen(SkillsScreen(connection: widget.connection));
      case SlashAction.memory:
        _pushScreen(MemoryScreen(connection: widget.connection));
      case SlashAction.soul:
        _pushScreen(SoulScreen(connection: widget.connection));
      case SlashAction.models:
        _pushScreen(ModelsScreen(connection: widget.connection));
      case SlashAction.activity:
        _pushScreen(ActivityScreen(connection: widget.connection));
      case SlashAction.kanban:
        _pushScreen(TasksScreen(connection: widget.connection));
      case SlashAction.unavailable:
        return;
      case SlashAction.remote:
        // Se maneja antes de limpiar el compositor para conservarlo si falla.
        return;
    }
  }

  Future<void> _executeRemoteSlash(SlashCommand cmd, String arg) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    // Se limpia como un mensaje normal en cuanto se envía, sin esperar a que
    // el RPC vuelva: el composer no debe quedarse enseñando "/comando" el
    // tiempo que tarde el backend. Si el envío termina fallando de forma
    // definitiva se restaura, igual que un mensaje normal rechazado.
    final invocation = _textController.text;
    setState(() {
      _textController.clear();
      _slashSuggestions = const [];
    });
    try {
      final result = await _chat.executeDesktopSlash(cmd.name, arg: arg);
      if (!mounted) return;
      if (result.accepted != DesktopCommandAcceptance.accepted) {
        _restoreSlashInvocation(invocation);
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).chaCommandFailed)),
          kind: HermesNoticeKind.error,
        );
        return;
      }

      final directedMessage = result.message?.trim() ?? '';
      final submitsDirectedTurn =
          directedMessage.isNotEmpty &&
          (result.kind == DesktopCommandDispatchKind.send ||
              result.kind == DesktopCommandDispatchKind.skill);

      final notice = result.notice?.trim();
      final output = result.output?.trim();
      final feedback = output?.isNotEmpty == true
          ? output!
          : notice?.isNotEmpty == true
          ? notice!
          : Strings.of(context).chaCommandAccepted('/${cmd.name}');
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(feedback), duration: const Duration(seconds: 7)),
      );

      if (submitsDirectedTurn) {
        await _sendMessageOnce(
          skipSlashRouting: true,
          textOverride: directedMessage,
          includeComposerAttachments: false,
        );
      }
    } on TuiGatewayRpcError catch (error) {
      if (!mounted) return;
      _restoreSlashInvocation(invocation);
      final message = error.code == -32601
          ? Strings.of(context).chaCompressionUnsupported
          : Strings.of(context).chaCommandFailed;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 7)),
      );
    } catch (_) {
      if (!mounted) return;
      _restoreSlashInvocation(invocation);
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaCommandFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<bool> _compressDesktopSession(String focusTopic) async {
    if (_compressingSession) {
      _restoreComposerFocusAfterCompression();
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaCompressionBusy)),
        kind: HermesNoticeKind.warning,
      );
      return false;
    }
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return false;
    }

    // Se limpia como un mensaje normal en cuanto se envía — la barra
    // flotante ya es la señal de que sigue en marcha, así que el composer no
    // debe volver a enseñar "/compress" el tiempo que dure. Solo se restaura
    // ante un rechazo definitivo, igual que un mensaje normal rechazado; si
    // queda pendiente de confirmar (resultado tardío), el composer se queda
    // limpio y `_consumeCompressionInvocation` cierra el resto del estado
    // cuando por fin se resuelva.
    final invocation = _textController.text;
    _compressionInvocation = invocation;
    setState(() {
      _compressionCommandInFlight = true;
      _compressionDraftFocusRetained = false;
      _slashSuggestions = const [];
      _textController.clear();
    });
    _syncCompaction();
    try {
      final presentation = await _chat.compressDesktopSessionForPresentation(
        focusTopic: focusTopic.trim(),
      );
      if (!mounted) return false;
      if (!presentation.projection.isCurrent) {
        // Superseded before we ever reached the gateway (e.g. a concurrent
        // refresh invalidated the read while still preparing): nothing was
        // actually sent, so — unlike a dispatched attempt that later went
        // stale, where the floating dock is already the live signal — the
        // user's typed command comes back, same as any other locally
        // abandoned send.
        if (!presentation.projection.dispatchAttempted) {
          _restoreComposerFocusAfterCompression();
          _restoreSlashInvocation(invocation);
        }
        return false;
      }
      if (presentation.failure case final failure?) throw failure;
      final result = presentation.command!;
      final strings = Strings.of(context);
      // A finished compression (compacted or nothing to compact) has ONE
      // feedback surface: the compaction pill turns into its outcome, the way
      // Hermes Desktop's toast carries the headline. Only the other outcomes
      // (aborted, lock held, pending, legacy route) need a notice.
      final pillOutcome =
          result.compressionStatus == DesktopCompressionStatus.compressed ||
          result.compressionStatus == DesktopCompressionStatus.noOp;
      if (!pillOutcome) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(_compressionResultMessage(strings, result)),
            duration: const Duration(seconds: 7),
          ),
        );
      }
      final succeeded = _compressionSucceeded(result);
      _finishCompactionBar(result);
      if (!succeeded) {
        // Dos preguntas distintas, no una: si el composer se desbloquea
        // (`retainWhileFenced`, sin cambios: solo la ruta legacy —
        // `compressionStatus` null — se desbloquea; un `pending` nativo
        // fiable se queda bloqueado, igual que antes de esta noche) y si el
        // texto se restaura. Para esto último, `compressionStatus` es la
        // señal fiable en la ruta nativa (`pending` es lo único genuinamente
        // incierto; aborted/lock_held son un rechazo real). La ruta legacy
        // nunca la toca — ahí `accepted` es la señal: unknown == genuinamente
        // pendiente/incierto (pending, o un fallo de transporte donde no se
        // sabe si el backend llegó a aceptarlo), rejected == rechazo
        // definitivo, igual que un mensaje normal rechazado.
        final fenced = result.compressionStatus != null
            ? result.compressionStatus == DesktopCompressionStatus.pending
            : result.accepted != DesktopCommandAcceptance.rejected;
        _restoreComposerFocusAfterCompression(
          retainWhileFenced: result.compressionStatus == null,
        );
        if (!fenced) _restoreSlashInvocation(invocation);
      }
      return succeeded;
    } on TuiGatewayRpcError catch (error) {
      if (!mounted) return false;
      _restoreComposerFocusAfterCompression();
      _restoreSlashInvocation(invocation);
      final strings = Strings.of(context);
      final message = _compressionFailureMessage(strings, error.code);
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
      );
      return false;
    } catch (_) {
      if (!mounted) return false;
      _restoreComposerFocusAfterCompression();
      _restoreSlashInvocation(invocation);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).chaCompressionUnknown),
          duration: const Duration(seconds: 8),
        ),
        kind: HermesNoticeKind.warning,
      );
      return false;
    } finally {
      _compressionCommandInFlight = false;
      // Si el servicio ya soltó la compactación y no hubo éxito, la invocación
      // se conserva tal cual; si sigue en marcha (resultado tardío), el final
      // la consumirá.
      if (!_chat.desktopCompressionInFlight) _compressionInvocation = null;
      if (mounted) setState(() {});
    }
  }

  void _restoreComposerFocusAfterCompression({bool retainWhileFenced = true}) {
    _compressionDraftFocusRetained = retainWhileFenced;
    _textFocusNode.canRequestFocus = true;
    _textFocusNode.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
  }

  String _compressionFailureMessage(Strings strings, int? code) =>
      switch (code) {
        4009 => strings.chaCompressionBusy,
        4007 => strings.chaCompressionNoRuntime,
        -32601 => strings.chaCompressionUnsupported,
        5005 => strings.chaCompressionBackendFailed,
        _ => strings.chaCompressionUnknown,
      };

  String _compressionResultMessage(
    Strings strings,
    DesktopCommandDispatch result,
  ) => switch (result.compressionStatus) {
    DesktopCompressionStatus.compressed => strings.chaCompressionCompleted,
    DesktopCompressionStatus.noOp => strings.chaCompressionNoop(
      result.compressionResult?.beforeMessages ?? 0,
      (result.compressionResult?.beforeTokens ?? 0).toString(),
    ),
    DesktopCompressionStatus.aborted => strings.chaCompressionAborted,
    DesktopCompressionStatus.pending => strings.chaCompressionPending,
    DesktopCompressionStatus.lockHeld => strings.chaCompressionLockHeld,
    null =>
      result.accepted == DesktopCommandAcceptance.accepted
          ? (result.output?.trim().isNotEmpty == true
                ? result.output!.trim()
                : strings.chaCompressionAccepted)
          : _compressionFailureMessage(strings, result.failure?.code),
  };

  bool _compressionSucceeded(DesktopCommandDispatch result) =>
      result.compressionStatus == DesktopCompressionStatus.compressed ||
      result.compressionStatus == DesktopCompressionStatus.noOp ||
      (result.compressionStatus == null &&
          result.accepted == DesktopCommandAcceptance.accepted);

  void _pushScreen(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// `/model <nombre>`: busca el modelo por nombre en las opciones reales. Si hay
  /// exactamente una coincidencia lo aplica; si hay 0 o varias, abre el selector.
  Future<bool> _setModelByName(String arg) async {
    final q = arg.toLowerCase();
    try {
      if (!_chat.hasDesktopRuntime &&
          !await _chat.ensureDesktopRuntime(acquireForExplicitAction: true)) {
        return false;
      }
      final (_, providers) = await _loadModelOptions();
      final matches = <(ModelProvider, String)>[];
      for (final p in providers) {
        for (final m in p.models) {
          if (m.toLowerCase().contains(q) ||
              friendlyModelName(m).toLowerCase().contains(q)) {
            matches.add((p, m));
          }
        }
      }
      if (matches.length == 1) {
        return await _applyModelDirect(matches.first.$1, matches.first.$2);
      } else if (mounted) {
        if (matches.isEmpty) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(Strings.of(context).chaNoMatch(arg))),
            kind: HermesNoticeKind.warning,
          );
        }
        _showModelSheet();
        return true;
      }
    } catch (_) {
      if (mounted) {
        _showModelSheet();
        return true;
      }
    }
    return false;
  }

  Future<bool> _applySessionModelSelection(
    ModelProvider provider,
    String modelId, {
    BuildContext? dialogContext,
  }) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return false;
    }
    final str = Strings.of(context);
    final targetContext = dialogContext ?? context;

    if (!_chat.hasDesktopRuntime) {
      try {
        await _chat.ensureDesktopRuntime(acquireForExplicitAction: true);
      } catch (error) {
        if (mounted) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(str.chaModelChangeFailed(humanizeApiError(error))),
            ),
            kind: HermesNoticeKind.error,
          );
        }
        return false;
      }
    }
    if (!mounted) return false;

    if (!_chat.hasDesktopRuntime) {
      if (widget.connection.kind == InstanceKind.localhost) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              str.chaModelChangeFailed(str.chaSessionConfigRequires019),
            ),
          ),
          kind: HermesNoticeKind.error,
        );
        return false;
      }
      await _stageSessionModel(provider.slug, modelId);
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(str.chaModelActive(friendlyModelName(modelId))),
          ),
        );
      }
      return true;
    }

    if (!_chat.canConfigureDesktopSession || provider.slug == 'gateway') {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            str.chaModelChangeFailed(str.chaSessionModelUnsupported),
          ),
        ),
        kind: HermesNoticeKind.error,
      );
      return false;
    }

    late final DesktopModelSelection selection;
    try {
      selection = DesktopModelSelection(
        modelId: modelId,
        providerSlug: provider.slug,
      );
    } on FormatException {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(str.chaModelChangeFailed(str.chaSessionInvalidModel)),
        ),
        kind: HermesNoticeKind.error,
      );
      return false;
    }

    PendingSessionConfigChange result;
    try {
      result = await _chat.setSessionModel(selection);
      if (result.status == SessionConfigChangeStatus.confirmRequired) {
        final confirmation = result;
        _pendingModelConfirmation = confirmation;
        try {
          if (!targetContext.mounted) {
            _chat.dismissSessionConfigConfirmation(confirmation);
            return false;
          }
          final navigator = Navigator.of(targetContext, rootNavigator: true);
          final route = DialogRoute<bool>(
            context: targetContext,
            builder: (dctx) => AlertDialog(
              backgroundColor: Theme.of(dctx).hermes.surface,
              title: Text(str.chaModelChangeTitle),
              content: Text(confirmation.confirmMessage ?? ''),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dctx, false),
                  child: Text(str.chaCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dctx, true),
                  child: Text(str.chaChange),
                ),
              ],
            ),
          );
          _modelConfirmationNavigator = navigator;
          _modelConfirmationRoute = route;
          final bool? confirmed;
          try {
            confirmed = await navigator.push(route);
          } finally {
            if (identical(_modelConfirmationRoute, route)) {
              _modelConfirmationNavigator = null;
              _modelConfirmationRoute = null;
            }
          }
          if (confirmed != true) {
            _chat.dismissSessionConfigConfirmation(confirmation);
            return false;
          }
          result = await _chat.confirmSessionModel(confirmation);
        } finally {
          if (identical(_pendingModelConfirmation, confirmation)) {
            _pendingModelConfirmation = null;
          }
        }
      }
    } catch (error) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(str.chaModelChangeFailed(humanizeApiError(error))),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      return false;
    }

    if (result.status != SessionConfigChangeStatus.accepted &&
        result.status != SessionConfigChangeStatus.confirmed) {
      if (mounted) {
        final reason = result.status == SessionConfigChangeStatus.timedOut
            ? str.chaSessionReconciling
            : result.failureKind?.name ?? result.status.name;
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(str.chaModelChangeFailed(reason))),
          kind: HermesNoticeKind.error,
        );
      }
      return false;
    }

    await _rememberSessionModel(
      provider.slug,
      modelId,
      updateEffectiveDisplay: false,
    );
    if (mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(str.chaModelActive(friendlyModelName(modelId)))),
      );
    }
    return true;
  }

  Future<void> _applySessionReasoning(DesktopReasoningEffort effort) async {
    final str = Strings.of(context);
    if (!_chat.hasDesktopRuntime) {
      try {
        await _chat.ensureDesktopRuntime(acquireForExplicitAction: true);
      } catch (error) {
        if (mounted) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(str.chaModelChangeFailed(humanizeApiError(error))),
            ),
            kind: HermesNoticeKind.error,
          );
        }
        return;
      }
    }
    if (!mounted) return;
    if (!_chat.hasDesktopRuntime) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionReasoningKey, effort.wire);
      if (!mounted) return;
      setState(() => _selectedReasoning = effort);
      _chat.stageFirstSubmitConfig(_firstSubmitConfig);
      return;
    }
    if (!_chat.canConfigureDesktopSession) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            str.chaModelChangeFailed(str.chaSessionReasoningUnsupported),
          ),
        ),
        kind: HermesNoticeKind.error,
      );
      return;
    }
    final result = await _chat.setSessionReasoning(effort);
    if (result.status != SessionConfigChangeStatus.accepted &&
        result.status != SessionConfigChangeStatus.confirmed) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              str.chaModelChangeFailed(
                result.failureKind?.name ?? result.status.name,
              ),
            ),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionReasoningKey, effort.wire);
    if (mounted) setState(() => _selectedReasoning = effort);
  }

  Future<void> _applySessionFastMode(DesktopFastMode mode) async {
    final str = Strings.of(context);
    if (!_chat.hasDesktopRuntime) {
      try {
        await _chat.ensureDesktopRuntime(acquireForExplicitAction: true);
      } catch (error) {
        if (mounted) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(str.chaModelChangeFailed(humanizeApiError(error))),
            ),
            kind: HermesNoticeKind.error,
          );
        }
        return;
      }
    }
    if (!mounted) return;
    if (!_chat.hasDesktopRuntime) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionFastKey, mode.wire);
      if (!mounted) return;
      setState(() => _selectedFastMode = mode);
      _chat.stageFirstSubmitConfig(_firstSubmitConfig);
      return;
    }
    if (!_chat.canConfigureDesktopSession) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            str.chaModelChangeFailed(str.chaSessionFastUnsupported),
          ),
        ),
        kind: HermesNoticeKind.error,
      );
      return;
    }
    final result = await _chat.setSessionFastMode(mode);
    if (result.status != SessionConfigChangeStatus.accepted &&
        result.status != SessionConfigChangeStatus.confirmed) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              str.chaModelChangeFailed(
                result.failureKind?.name ?? result.status.name,
              ),
            ),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionFastKey, mode.wire);
    if (mounted) setState(() => _selectedFastMode = mode);
  }

  /// Aplica un modelo activo directamente (desde `/model <nombre>`), con la misma
  /// salvaguarda de solo-lectura y confirmación que el selector.
  Future<bool> _applyModelDirect(ModelProvider provider, String modelId) =>
      _applySessionModelSelection(provider, modelId);

  void _showSlashHelp() {
    final colors = Theme.of(context).hermes;
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('chat-slash-help-dialog'),
      maxWidth: 580,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
        children: [
          Text(
            Strings.of(ctx).chaSlashHelpTitle,
            style: TextStyle(
              color: colors.accent,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            Strings.of(ctx).chaSlashHelpBody,
            style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          for (final c in slashCommands(Strings.of(context)))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(
                      '/${c.name} ${c.argHint}'.trim(),
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      c.description,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openRecoveryCenter() async {
    final runtime = _chat.desktopRuntimeSessionId;
    final gateway = _chat.desktopControlGateway;
    if (runtime == null || runtime.isEmpty || gateway == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecoveryCenterScreen(
          gateway: gateway,
          runtimeSessionId: runtime,
          readOnly: widget.connection.readOnly,
        ),
      ),
    );
  }

  Future<void> _openExtensionsCenter() async {
    final runtime = _chat.desktopRuntimeSessionId;
    final gateway = _chat.desktopControlGateway;
    if (runtime == null || runtime.isEmpty || gateway == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ExtensionsCenterScreen(
          gateway: gateway,
          runtimeSessionId: runtime,
          readOnly: widget.connection.readOnly,
        ),
      ),
    );
  }

  bool _desktopControlCenterAvailable(DesktopGatewayCapability capability) {
    if (_chat.desktopRuntimeSessionId == null ||
        _chat.desktopControlGateway == null) {
      return false;
    }
    final state = _chat.desktopCapabilityState(capability);
    return state != DesktopGatewayCapabilityState.unsupported &&
        state != DesktopGatewayCapabilityState.invalid;
  }

  Future<void> _showChatControlSheet() async {
    final strings = Strings.of(context);
    final policy = context
        .findAncestorStateOfType<HermesAppState>()
        ?.approvalPolicy;
    final sessionReadOnly =
        widget.connection.readOnly ||
        policy?.effectiveMode(widget.session.id) == ApprovalMode.readOnly;

    final action = await showHermesFloatingSurface<_ChatControlAction>(
      context: context,
      surfaceKey: const ValueKey('chat-control-dialog'),
      maxWidth: 480,
      builder: (dialogContext) {
        void select(_ChatControlAction action) =>
            Navigator.of(dialogContext).pop(action);

        return ChatControlSheet(
          labels: ChatControlLabels(
            title: strings.chaControlTitle,
            scope: strings.chaControlScope,
            sessionSection: strings.chaControlSectionSession,
            toolsSection: strings.chaControlSectionTools,
            dangerSection: strings.chaControlSectionDanger,
            permissions: strings.chaPermissionsTitle,
            refresh: strings.chaUpdateTitle,
            artifacts: strings.chaArtifactsAction,
            details: strings.chaSessionDetailsAction,
            cron: strings.crnOpenFromConversation,
            recovery: strings.chaControlRecovery,
            extensions: strings.drawerExtensions,
            delete: strings.sesDelete,
            readOnly: strings.statusReadOnly,
            releaseDesktop: strings.chaControlReleaseDesktop,
            releaseUnavailable: strings.chaRuntimeReleaseUnavailable,
          ),
          conversationTitle: widget.session.displayTitle,
          readOnly: sessionReadOnly,
          showReleaseDesktop: _chat.showReleaseToDesktopControl,
          releaseDesktopEnabled: _chat.canReleaseToDesktop,
          releaseInFlight: _chat.runtimeReleaseInFlight,
          showDetails: _devDiagnostics,
          showCron: widget.session.isJob,
          onPermissions: () => select(_ChatControlAction.permissions),
          onRefresh: () => select(_ChatControlAction.refresh),
          onArtifacts: () => select(_ChatControlAction.artifacts),
          onDetails: () => select(_ChatControlAction.details),
          onCron: () => select(_ChatControlAction.cron),
          onRecovery:
              !_desktopControlCenterAvailable(
                DesktopGatewayCapability.recoveryCenter,
              )
              ? null
              : () => select(_ChatControlAction.recovery),
          onExtensions:
              !_desktopControlCenterAvailable(
                DesktopGatewayCapability.extensionsCenter,
              )
              ? null
              : () => select(_ChatControlAction.extensions),
          onReleaseDesktop: () => select(_ChatControlAction.releaseDesktop),
          onDelete: () => select(_ChatControlAction.delete),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ChatControlAction.permissions:
        if (policy != null) _showModeSheet(policy);
      case _ChatControlAction.refresh:
        unawaited(_fetchMessages());
      case _ChatControlAction.artifacts:
        unawaited(_showSessionArtifacts());
      case _ChatControlAction.details:
        _showSessionDetails();
      case _ChatControlAction.cron:
        _openLinkedCron();
      case _ChatControlAction.recovery:
        unawaited(_openRecoveryCenter());
      case _ChatControlAction.extensions:
        unawaited(_openExtensionsCenter());
      case _ChatControlAction.releaseDesktop:
        unawaited(_releaseRuntimeForDesktop());
      case _ChatControlAction.delete:
        unawaited(_deleteCurrentChat());
    }
  }

  Future<void> _releaseRuntimeForDesktop() async {
    final strings = Strings.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('chat-runtime-release-confirm-dialog'),
        title: Text(strings.chaRuntimeReleaseConfirmTitle),
        content: Text(strings.chaRuntimeReleaseConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.sesCancel),
          ),
          FilledButton(
            key: const ValueKey('chat-runtime-release-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.chaRuntimeReleaseConfirm),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final released = await _chat.releaseRuntimeForDesktop();
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(
          released
              ? strings.chaRuntimeReleased
              : strings.chaRuntimeReleaseFailed,
        ),
      ),
    );
  }

  void _showSessionDetails() {
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('chat-session-details-dialog'),
      maxWidth: 520,
      builder: (dialogContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                Strings.of(dialogContext).chaSessionDetailsTitle,
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _detailRow(
                Strings.of(dialogContext).chaDetailId,
                widget.session.id,
              ),
              _detailRow(
                Strings.of(dialogContext).chaDetailModel,
                widget.session.model,
              ),
              _detailRow(
                Strings.of(dialogContext).chaDetailMessages,
                '${widget.session.messageCount}',
              ),
              _detailRow(
                Strings.of(dialogContext).chaDetailSource,
                widget.session.source,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSessionArtifacts() async {
    _rebuildGeneratedArtifactsFromTranscript();
    final artifacts = _chat.resolveSessionArtifacts();
    final downloads = SessionArtifactDownloadService(
      connection: widget.connection,
    );
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('chat-artifacts-dialog'),
      maxWidth: 620,
      builder: (dialogContext) => SessionArtifactsSheet(
        artifacts: artifacts,
        generatedArtifactRegistry: _generatedArtifactRegistry,
        generatedArtifactSessionId: _generatedArtifactScope,
        showDragHandle: false,
        onOpenGeneratedArtifact: (artifactId) {
          Navigator.of(dialogContext).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(
              showGeneratedArtifactViewer(
                context: context,
                registry: _generatedArtifactRegistry,
                artifactId: artifactId,
                exporter: _artifactExporter,
              ),
            );
          });
        },
        canDownloadArtifact: downloads.canDownload,
        onDownloadArtifact: _downloadSessionArtifact,
        onJumpToSource: (source) {
          Navigator.of(dialogContext).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_jumpToArtifactSource(source));
          });
        },
      ),
    );
  }

  void _rebuildGeneratedArtifactsFromTranscript() {
    final artifacts = <GeneratedArtifactInput>[];
    for (final message in _messages.reversed) {
      if (message['role']?.toString().trim().toLowerCase() != 'assistant' ||
          message['_pipeline'] == true ||
          message['_cancelled'] == true) {
        continue;
      }
      final content = message['content'];
      if (content is! String || content.trim().isEmpty) continue;
      final terminalAnswer = projectAssistantSuggestions(
        splitReasoning(content).answer,
      ).body;
      for (final artifact in GeneratedArtifactMarkdownScanner.scan(
        terminalAnswer,
      )) {
        artifacts.add(
          GeneratedArtifactInput(
            detection: artifact.detection,
            content: artifact.content,
          ),
        );
      }
    }
    _generatedArtifactRegistry.replaceSession(
      _generatedArtifactScope,
      artifacts,
    );
  }

  Future<void> _downloadSessionArtifact(SessionArtifact artifact) async {
    final strings = Strings.of(context);
    try {
      final result = await SessionArtifactDownloadService(
        connection: widget.connection,
      ).downloadAndSave(artifact, _artifactExporter);
      if (mounted && result == ArtifactSaveResult.saved) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(strings.artifactDownloadSaved)),
          kind: HermesNoticeKind.success,
        );
      }
    } on SessionArtifactDownloadException catch (error) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              sessionArtifactDownloadMessage(strings, error.failure),
            ),
          ),
        );
      }
    } on ArtifactExportTooLarge {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(strings.artifactDownloadTooLarge)),
          kind: HermesNoticeKind.warning,
        );
      }
    } on Object {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(strings.artifactDownloadFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    }
  }

  Future<void> _jumpToArtifactSource(SessionArtifactSource source) async {
    final sourceIndex = messageIndexForArtifactSource(_messages, source);
    final messageIndex = sourceIndex == null
        ? null
        : _currentRenderProjection.nearestRenderableMessageIndex(sourceIndex);
    if (messageIndex == null || !_scrollController.hasClients) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).artifactSourceUnavailable),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
      return;
    }
    final target = _messages[messageIndex];
    _freezeStreamingFollow();
    final position = _scrollController.position;

    Future<bool> alignIfMounted() async {
      final anchor = _messageAnchors[target];
      if (anchor == null || !anchor.attached) return false;
      await scrollChatAnswerToStart(
        anchor,
        position,
        duration: _reduceMotion ? Duration.zero : chatNavigationDuration,
      );
      return true;
    }

    if (await alignIfMounted()) return;
    position.jumpTo(position.minScrollExtent);
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted || !_scrollController.hasClients) return;
    if (await alignIfMounted()) return;

    for (var attempt = 0; attempt < 80; attempt++) {
      if (!mounted || !_scrollController.hasClients) return;
      if (position.pixels >= position.maxScrollExtent - 1) break;
      position.jumpTo(
        (position.pixels + position.viewportDimension * 0.9).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await SchedulerBinding.instance.endOfFrame;
      if (await alignIfMounted()) return;
    }

    if (mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).artifactSourceUnavailable)),
        kind: HermesNoticeKind.warning,
      );
    }
  }

  bool _isSubagentOpenPending(SubagentActivity activity) {
    final childSessionId = activity.childSessionId;
    return childSessionId != null &&
        _openingSubagentSessionIds.contains(childSessionId);
  }

  SubagentActivity? _currentSubagentActivity(SubagentActivityKey key) {
    for (final activity in _chat.subagentActivities) {
      if (activity.key == key) return activity;
    }
    return null;
  }

  /// Carga la sesión hija solo tras una acción explícita. La ruta recibe una
  /// copia solo lectura de la conexión para que inspeccionar el transcript no
  /// pueda enviar prompts, duplicar ni borrar la conversación del subagente.
  Future<void> _openSubagentConversation(SubagentActivity activity) async {
    final childSessionId = activity.childSessionId?.trim();
    if (childSessionId == null ||
        childSessionId.isEmpty ||
        !_openingSubagentSessionIds.add(childSessionId)) {
      return;
    }
    setState(() {});

    final readOnlyConnection = widget.connection.copyWith(readOnly: true);
    final client = ApiClient(
      baseUrl: readOnlyConnection.baseUrl,
      apiKey: readOnlyConnection.apiKey,
      connectionId: readOnlyConnection.id,
    );
    Session? childSession;
    try {
      childSession = await client.getSession(
        childSessionId,
        profile: _chat.sessionProfile,
      );
    } catch (_) {
      if (!_disposed && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).subagentOpenFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      client.close();
      _openingSubagentSessionIds.remove(childSessionId);
      if (!_disposed && mounted) setState(() {});
    }

    if (childSession == null || _disposed || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SessionDetailScreen(
          connection: readOnlyConnection,
          session: childSession!,
          skipInitialSessionRefresh: true,
        ),
      ),
    );
  }

  /// La confirmación y el pending son por hijo. El reducer conserva el estado
  /// actual hasta que Hermes emita un evento autoritativo de cancelación.
  Future<bool> _confirmInterruptSubagent(SubagentActivity activity) async {
    if (_chat.isSubagentInterruptPending(activity)) return false;
    final strings = Strings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.subagentInterruptTitle),
        content: Text(strings.subagentInterruptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.sesCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              strings.subagentInterruptConfirm,
              style: TextStyle(color: Theme.of(context).hermes.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || _disposed || !mounted) return false;

    // Puede llegar progreso mientras el diálogo está abierto. Resolver de
    // nuevo por la key estable evita operar con un snapshot de fila obsoleto.
    final current = _currentSubagentActivity(activity.key);
    if (current == null || !_chat.canInterruptSubagent(current)) return false;
    try {
      final found = await _chat.interruptSubagent(current);
      if (_disposed || !mounted) return false;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            found
                ? Strings.of(context).subagentInterruptRequested
                : Strings.of(context).subagentInterruptNotFound,
          ),
        ),
      );
      return found;
    } on StateError {
      // Otro toque/evento ganó la carrera. El estado visible ya se actualiza
      // desde ActiveChat; no mostrar un error falso al usuario.
      return false;
    } catch (_) {
      if (!_disposed && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).subagentInterruptFailed)),
          kind: HermesNoticeKind.error,
        );
      }
      return false;
    }
  }

  void _openLinkedCron() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CronScreen(
          connection: widget.connection,
          initialJobId: widget.session.cronJobId,
        ),
      ),
    );
  }

  /// Elimina la sesión actual (DELETE /api/sessions/{id}) tras confirmar y, si
  /// tiene éxito, cierra el chat devolviendo `true` para que la lista refresque.
  Future<void> _deleteCurrentChat() async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    final policy = app?.approvalPolicy;
    bool isReadOnly() =>
        widget.connection.readOnly ||
        policy?.effectiveMode(widget.session.id) == ApprovalMode.readOnly;
    if (isReadOnly()) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    var cronDeletion = LinkedCronDeletionMode.keepSchedule;
    if (widget.session.isJob) {
      final choice = await showCronConversationDeleteDialog(
        context,
        widget.session,
      );
      if (choice == null || !mounted) return;
      cronDeletion = choice;
    } else {
      final colors = Theme.of(context).hermes;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(s.sesDeleteTitle),
          content: Text(s.sesDeleteContent(widget.session.displayTitle)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.sesCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.sesDelete, style: TextStyle(color: colors.error)),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    // El borrado es destructivo incluso en YOLO. Si App Lock está activo se
    // verifica siempre, independientemente del ajuste pensado para approvals de
    // herramientas; después se vuelve a comprobar el modo solo lectura por si
    // cambió mientras estaban abiertos los diálogos.
    final lock = app?.appLock;
    if (lock != null && lock.enabled) {
      final verified = await LockScreen.verify(
        context,
        lock,
        reason: s.sesDeleteContent(widget.session.displayTitle),
      );
      if (!verified || !mounted || isReadOnly()) return;
    }
    if (isReadOnly()) {
      showReadOnlyNotice(context);
      return;
    }
    final client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      connectionId: widget.connection.id,
    );
    final dashboard =
        widget.session.isJob &&
            cronDeletion == LinkedCronDeletionMode.deleteSchedule &&
            app == null
        ? DashboardClient.lazy(widget.connection)
        : null;
    final ownerProfile = _chat.sessionProfile;
    try {
      final result = await deleteSessionWithResolvedLineage(
        widget.session,
        loadSessions: ({bool includeChildren = false}) => client.getSessions(
          includeChildren: includeChildren,
          profile: ownerProfile,
        ),
        deleteSession: (sessionId) =>
            client.deleteSession(sessionId, profile: ownerProfile),
        remoteSessionId: _chat.serverSessionId,
        localRecoverySessionId: widget.session.id,
        clearLocalRecovery: _clearDeletedChatRecovery,
        cronDeletion: cronDeletion,
        deleteCronJob:
            !widget.session.isJob ||
                cronDeletion == LinkedCronDeletionMode.keepSchedule
            ? null
            : (jobId) => app != null
                  ? app.connManager.deleteLinkedCronJob(
                      widget.connection,
                      jobId,
                      profile: ownerProfile,
                    )
                  : dashboard!.deleteCronJob(jobId, profile: ownerProfile),
      );
      if (!mounted) return;
      switch (result.status) {
        case LinkedSessionDeleteStatus.deleted:
          app?.activeChats.globalActivity.clearSession(
            widget.connection.id,
            ownerProfile,
            widget.session.id,
          );
          await app?.activeChats.globalActivity.flushJournal();
          if (!mounted) return;
          Navigator.pop(context, true);
          break;
        case LinkedSessionDeleteStatus.cancelled:
          break;
        case LinkedSessionDeleteStatus.sessionRejected:
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.cronDeleted
                    ? s.cronStoppedChatKept
                    : s.slOfferHideContent,
              ),
            ),
          );
          break;
        case LinkedSessionDeleteStatus.cronDeleteFailed:
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
            kind: HermesNoticeKind.error,
          );
          break;
        case LinkedSessionDeleteStatus.sessionDeleteFailed:
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
            kind: HermesNoticeKind.error,
          );
          break;
      }
    } finally {
      client.close();
      dashboard?.close();
    }
  }

  Widget _detailRow(String label, String value) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Cabecera de la ThinkingTraceCard mientras aún no hay herramientas.
  String _traceHeadline() {
    final s = Strings.of(context);
    final activityHeadline = switch (_pipelineState) {
      ChatPipelineState.connecting => s.chaPipelineConnecting,
      ChatPipelineState.executing => s.chaPipelineExecuting,
      ChatPipelineState.streaming => s.chaPipelineStreaming,
      _ => s.chaPipelineThinking,
    };
    return chatActivityHeadlineForTransport(
      status: _chat.transportStatus,
      authRequired: _chat.dashboardAuthRequired,
      activityHeadline: activityHeadline,
      reconnectingHeadline: s.chaConnectionLostReconnecting,
    );
  }

  // ─── Attachment handling ──────────────────────────────────────────────────

  Future<void> _selectAttachmentSource(AttachmentSourceChoice source) async {
    switch (source) {
      case AttachmentSourceChoice.camera:
        await _pickImage(ImageSource.camera);
        break;
      case AttachmentSourceChoice.photos:
        await _pickImage();
        break;
      case AttachmentSourceChoice.files:
        await _pickDocument();
        break;
    }
  }

  Future<String?> _attachmentContentDigest(String path) async {
    if (path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return (await sha256.bind(file.openRead()).first).toString();
    } catch (_) {
      return null;
    }
  }

  Future<Set<String>> _knownAttachmentDigests() async {
    final digests = <String>{};
    for (final attachment in _pendingAttachments) {
      final digest = await _attachmentContentDigest(attachment.localPath);
      if (digest != null) digests.add(digest);
    }
    return digests;
  }

  Future<AttachmentDraft?> _materializeAttachment(AttachmentDraft attachment) {
    final materializer = widget.attachmentMaterializer;
    return materializer != null
        ? materializer(attachment)
        : AttachmentUploader.materializeForDraft(attachment);
  }

  Future<bool> _deletePrivateAttachmentCopy(AttachmentDraft attachment) {
    final deleter = widget.attachmentPrivateCopyDeleter;
    return deleter != null
        ? deleter(attachment)
        : AttachmentUploader.deletePrivateDraftCopy(attachment);
  }

  Future<void> _deleteUncommittedAttachmentCopies(
    List<AttachmentDraft> drafts,
  ) async {
    for (final draft in drafts) {
      await _deletePrivateAttachmentCopy(draft);
    }
    drafts.clear();
  }

  Future<void> _serializeAttachmentMutation(Future<void> Function() operation) {
    _attachmentMutationsPending++;
    if (mounted && _attachmentMutationsPending == 1) setState(() {});
    final run = _attachmentMutationTail.then((_) => operation());
    final completed = run.whenComplete(() {
      _attachmentMutationsPending--;
      if (mounted && _attachmentMutationsPending == 0) setState(() {});
    });
    _attachmentMutationTail = completed.catchError((Object _) {});
    return completed;
  }

  Future<void> _insertKeyboardContent(KeyboardInsertedContent content) =>
      _serializeAttachmentMutation(() => _insertKeyboardContentNow(content));

  Future<void> _insertKeyboardContentNow(
    KeyboardInsertedContent content,
  ) async {
    if (_attachmentSubmitting) return;
    final bytes = content.data;
    if (bytes == null || bytes.isEmpty) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaAttachmentPreparationFailed),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      return;
    }
    final currentImages = _pendingAttachments
        .where((item) => item.isImage)
        .length;
    final currentBatchBytes = _pendingAttachments.fold<int>(
      0,
      (sum, item) => sum + item.sizeBytes,
    );
    if (currentImages >= _maxPendingImages ||
        pendingAttachmentLimitViolation(
              sizeBytes: bytes.length,
              itemLimit: AttachmentUploader.maxBytes,
              currentBatchBytes: currentBatchBytes,
            ) !=
            null) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaAttachmentPreparationFailed),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      return;
    }
    final digest = sha256.convert(bytes).toString();
    if ((await _knownAttachmentDigests()).contains(digest)) return;

    final extension = switch (content.mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };
    final source = File(
      '${Directory.systemTemp.path}/hermes-ime-${const Uuid().v4()}.$extension',
    );
    AttachmentDraft? persisted;
    try {
      await source.writeAsBytes(bytes, flush: true);
      persisted = await _materializeAttachment(
        AttachmentDraft(
          localId: const Uuid().v4(),
          type: AttachmentType.image,
          name: 'pasted-image.$extension',
          mimeType: content.mimeType,
          sizeBytes: bytes.length,
          localPath: source.path,
        ),
      );
      if (persisted == null || !mounted) {
        if (persisted != null) await _deletePrivateAttachmentCopy(persisted);
        return;
      }
      setState(() {
        _pendingAttachments.add(persisted!);
      });
      _scheduleDraftSave();
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaAttachmentPreparationFailed),
          ),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (persisted?.localPath != source.path) {
        try {
          if (await source.exists()) await source.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _pickImage([ImageSource source = ImageSource.gallery]) =>
      _serializeAttachmentMutation(() => _pickImageNow(source));

  Future<void> _pickImageNow(ImageSource source) async {
    if (_imagePickerOpen || _attachmentSubmitting) {
      return;
    }
    _imagePickerOpen = true;
    final drafts = <AttachmentDraft>[];
    try {
      final currentImages = _pendingAttachments.where((a) => a.isImage).length;
      final remaining = _maxPendingImages - currentImages;
      if (remaining <= 0) {
        if (mounted) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(
                Strings.of(
                  context,
                ).chaAttachmentImageLimitReached(_maxPendingImages),
              ),
            ),
            kind: HermesNoticeKind.warning,
          );
        }
        return;
      }

      final picker = ImagePicker();
      final List<XFile> files;
      if (source == ImageSource.camera) {
        final file = await picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 82,
          maxWidth: 2048,
          maxHeight: 2048,
        );
        files = file == null ? const [] : [file];
      } else {
        // ACTION_GET_CONTENT + EXTRA_ALLOW_MULTIPLE abre en GrapheneOS el
        // PhotoPickerGetContentActivity en modo de selección única. Fuerza el
        // Photo Picker nativo (PickMultipleVisualMedia) y limita el lote al
        // espacio restante del composer.
        files = await pickPendingGalleryImages(picker, remaining: remaining);
      }
      if (files.isEmpty || !mounted) return;

      var rejectedForItemLimit = false;
      var rejectedForBatchLimit = false;
      var rejectedForPersistence = false;
      final knownDigests = await _knownAttachmentDigests();
      final availableAfterPicker =
          _maxPendingImages -
          _pendingAttachments.where((attachment) => attachment.isImage).length;
      var batchBytes = _pendingAttachments.fold<int>(
        0,
        (sum, attachment) => sum + attachment.sizeBytes,
      );
      for (final file in files) {
        if (drafts.length >= math.max(0, availableAfterPicker)) break;
        late final int sizeBytes;
        try {
          sizeBytes = await File(file.path).length();
        } catch (_) {
          rejectedForPersistence = true;
          continue;
        }
        switch (pendingAttachmentLimitViolation(
          sizeBytes: sizeBytes,
          itemLimit: AttachmentUploader.maxBytes,
          currentBatchBytes: batchBytes,
        )) {
          case PendingAttachmentLimitViolation.invalid:
            rejectedForPersistence = true;
            continue;
          case PendingAttachmentLimitViolation.item:
            rejectedForItemLimit = true;
            continue;
          case PendingAttachmentLimitViolation.batch:
            rejectedForBatchLimit = true;
            continue;
          case null:
            break;
        }
        final ext = file.name.contains('.')
            ? file.name.split('.').last.toLowerCase()
            : '';
        final digest = await _attachmentContentDigest(file.path);
        if (digest == null) {
          rejectedForPersistence = true;
          continue;
        }
        if (knownDigests.contains(digest)) continue;
        final selected = AttachmentDraft(
          localId: const Uuid().v4(),
          type: AttachmentType.image,
          name: file.name,
          mimeType: _mimeForExtension(ext),
          sizeBytes: sizeBytes,
          localPath: file.path,
        );
        // image_picker entrega una copia en caché que Android puede borrar en
        // cuanto se abandona esta pantalla. Materialízala antes de guardar el
        // borrador para que texto + imagen sobrevivan al volver al listado.
        final persisted = await _materializeAttachment(selected);
        if (persisted == null) {
          rejectedForPersistence = true;
          continue;
        }
        drafts.add(persisted);
        knownDigests.add(digest);
        batchBytes += persisted.sizeBytes;
      }
      if (!mounted) {
        await _deleteUncommittedAttachmentCopies(drafts);
        return;
      }
      if (drafts.isNotEmpty) {
        setState(() {
          _pendingAttachments.addAll(drafts);
        });
        _scheduleDraftSave();
        drafts.clear();
      }
      // Si el lote mezclaba imágenes válidas y demasiado grandes, conserva las
      // válidas y avisa una sola vez por las rechazadas.
      if (rejectedForItemLimit) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(
                context,
              ).chaImageTooBig(AttachmentUploader.maxBytes ~/ (1024 * 1024)),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
      if (rejectedForBatchLimit && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).chaAttachmentBatchTooBig(
                _attachmentLimitLabel(AttachmentUploader.maxBatchBytes),
              ),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
      if (rejectedForPersistence && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaAttachmentPreparationFailed),
          ),
          kind: HermesNoticeKind.error,
        );
      }
    } catch (_) {
      await _deleteUncommittedAttachmentCopies(drafts);
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaGalleryError)),
        kind: HermesNoticeKind.error,
      );
    } finally {
      _imagePickerOpen = false;
    }
  }

  Future<void> _pickDocument() =>
      _serializeAttachmentMutation(_pickDocumentNow);

  Future<void> _pickDocumentNow() async {
    if (_documentPickerOpen || _attachmentSubmitting) {
      return;
    }
    _documentPickerOpen = true;
    final drafts = <AttachmentDraft>[];
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final knownDigests = await _knownAttachmentDigests();
      var batchBytes = _pendingAttachments.fold<int>(
        0,
        (sum, attachment) => sum + attachment.sizeBytes,
      );
      String? rejectedItemLimitLabel;
      var rejectedForBatchLimit = false;
      var rejectedForPersistence = false;
      for (final file in result.files) {
        if (!AttachmentUploader.isAllowedDocumentName(file.name)) {
          rejectedForPersistence = true;
          continue;
        }
        final path = file.path ?? '';
        late final int sizeBytes;
        try {
          sizeBytes = path.isEmpty ? 0 : await File(path).length();
        } catch (_) {
          rejectedForPersistence = true;
          continue;
        }
        final selected = AttachmentDraft(
          localId: const Uuid().v4(),
          type: AttachmentType.document,
          name: file.name,
          mimeType: _mimeForExtension(file.extension),
          sizeBytes: sizeBytes,
          localPath: path,
        );
        // A-011 (spec 028): validar al seleccionar según el destino real
        // (256 KB si se incrusta como texto, 8 MB si se sube al agente).
        final limit = AttachmentUploader.isTextEmbeddable(selected)
            ? AttachmentUploader.maxTextBytes
            : AttachmentUploader.maxBytes;
        switch (pendingAttachmentLimitViolation(
          sizeBytes: sizeBytes,
          itemLimit: limit,
          currentBatchBytes: batchBytes,
        )) {
          case PendingAttachmentLimitViolation.invalid:
            rejectedForPersistence = true;
            continue;
          case PendingAttachmentLimitViolation.item:
            rejectedItemLimitLabel ??= _attachmentLimitLabel(limit);
            continue;
          case PendingAttachmentLimitViolation.batch:
            rejectedForBatchLimit = true;
            continue;
          case null:
            break;
        }
        final digest = await _attachmentContentDigest(path);
        if (digest == null) {
          rejectedForPersistence = true;
          continue;
        }
        if (knownDigests.contains(digest)) continue;
        final persisted = await _materializeAttachment(selected);
        if (persisted == null) {
          rejectedForPersistence = true;
          continue;
        }
        drafts.add(persisted);
        knownDigests.add(digest);
        batchBytes += persisted.sizeBytes;
      }
      if (!mounted) {
        await _deleteUncommittedAttachmentCopies(drafts);
        return;
      }
      if (drafts.isNotEmpty) {
        setState(() {
          _pendingAttachments.addAll(drafts);
        });
        _scheduleDraftSave();
        drafts.clear();
      }
      if (rejectedItemLimitLabel != null) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).chaFileTooBig(rejectedItemLimitLabel),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
      if (rejectedForBatchLimit && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(context).chaAttachmentBatchTooBig(
                _attachmentLimitLabel(AttachmentUploader.maxBatchBytes),
              ),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
      if (rejectedForPersistence && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaAttachmentPreparationFailed),
          ),
          kind: HermesNoticeKind.error,
        );
      }
    } catch (error) {
      await _deleteUncommittedAttachmentCopies(drafts);
      if (!mounted) return;
      debugPrint('[attachment] document picker failed (${error.runtimeType})');
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaFilesError)),
        kind: HermesNoticeKind.error,
      );
    } finally {
      _documentPickerOpen = false;
    }
  }

  static String _mimeForExtension(String? ext) {
    switch (ext?.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'md':
        return 'text/markdown';
      case 'csv':
        return 'text/csv';
      case 'json':
        return 'application/json';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument'
            '.wordprocessingml.document';
      case 'doc':
        return 'application/msword';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  Widget build(BuildContext context) {
    widget.performanceProbe?.screenBuilds++;
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final voiceSessionActive = kVoiceRuntimeEnabled && _voiceForThisSession;
    final showVoiceSurface = kVoiceRuntimeEnabled && _voiceOverlayVisible;
    final connManager = context
        .findAncestorStateOfType<HermesAppState>()
        ?.connManager;
    // Un Bot Chat es una superficie propia: identidad del bot en la cabecera,
    // sin drawer ni "nueva sesión", y modelo/controles al overflow.
    final botSurface = _isBotChatSurface;
    final dedicatedChrome = botSurface;
    // El observador del teclado envuelve al Scaffold en vez de leerse desde
    // este State: así la dependencia de `viewInsets` (que cambia en cada
    // frame de la animación del IME) vive en un elemento hoja y el Scaffold
    // —misma instancia de widget— no se vuelve a construir por ello.
    return _KeyboardInsetWatcher(
      onBottomInset: _onKeyboardBottomInset,
      child: Scaffold(
        drawerEnableOpenDragGesture: true,
        drawerEdgeDragWidth: HermesDrawer.edgeDragWidth(context),
        onDrawerChanged: (open) {
          if (_navigationDrawerOpen == open || !mounted) return;
          setState(() => _navigationDrawerOpen = open);
        },
        drawer: dedicatedChrome || connManager == null
            ? null
            : HermesDrawer(
                connection: widget.connection,
                connManager: connManager,
                current: DrawerSection.chat,
                connected: true,
              ),
        appBar: HermesAppBar(
          centerTitle: !dedicatedChrome,
          titleSpacing: 0,
          // Cabecera plana: sin línea/sombra de elevación al hacer scroll del
          // transcript por debajo (Material 3 la añade por defecto vía
          // `scrolledUnderElevation`). Se funde con el chat en vez de
          // cortarlo con un borde.
          scrolledUnderElevation: 0,
          bottom: dedicatedChrome || _activeProfile == null
              ? null
              : _ProfileContextChip(
                  label: str.chaProfileChip(_activeProfile!),
                  colors: colors,
                ),
          automaticallyImplyLeading: dedicatedChrome || connManager == null,
          leading: dedicatedChrome || connManager == null
              ? null
              : Builder(
                  builder: (ctx) => Center(
                    child: IconButton(
                      icon: const Icon(Icons.menu_rounded, size: 20),
                      tooltip: str.chaMenuTooltip,
                      // Botón circular sutil, estilo Claude.
                      style: IconButton.styleFrom(
                        backgroundColor: colors.surfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                        shape: const CircleBorder(),
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
                ),
          title: botSurface
              ? _BotChatAppBarTitle(
                  key: const ValueKey('bot-chat-header'),
                  profile: widget.missionBotProfile,
                  fallbackName: Session.profileOwner(widget.session.profile),
                  activity: _chatBound && !_turnActivityPillRevealed
                      ? _chat.activityKind
                      : null,
                  avatarCache: widget.missionAvatarCache,
                )
              : Semantics(
                  button: !showVoiceSurface,
                  label: str.chaModelSheetTitle,
                  excludeSemantics: true,
                  child: InkWell(
                    onTap: showVoiceSurface ? null : _showModelSheet,
                    borderRadius: BorderRadius.circular(10),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Padding(
                          key: ValueKey(_activeModelLabel),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  _activeModelLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700,
                                    color: colors.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 3),
                              Icon(
                                Icons.expand_more_rounded,
                                size: 19,
                                color: colors.textSecondary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          actions: showVoiceSurface
              ? [
                  IconButton(
                    key: const ValueKey('voice-stage-minimize'),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 26,
                    ),
                    tooltip: str.chaVoiceMinimizeTooltip,
                    onPressed: _vc?.minimizeOverlay,
                  ),
                  const SizedBox(width: 4),
                ]
              : botSurface
              ? [
                  PopupMenuButton<_BotChatHeaderAction>(
                    key: const ValueKey('bot-chat-overflow-appbar'),
                    tooltip: str.chaControlTitle,
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (action) {
                      switch (action) {
                        case _BotChatHeaderAction.model:
                          _showModelSheet();
                        case _BotChatHeaderAction.controls:
                          unawaited(_showChatControlSheet());
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        key: const ValueKey('bot-chat-model-action'),
                        value: _BotChatHeaderAction.model,
                        child: Row(
                          children: [
                            const Icon(Icons.tune_rounded, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                str.chaModelSheetTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        key: const ValueKey('bot-chat-control-action'),
                        value: _BotChatHeaderAction.controls,
                        child: Row(
                          children: [
                            const Icon(Icons.settings_outlined, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                str.chaControlTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                ]
              : [
                  // La presencia del Companion ya NO vive en el AppBar (ni el
                  // spinner de carga): el estado vivo lo expresa la mascota
                  // dentro del propio turno de Hermes.
                  // El indicador de contexto+modo (antes aquí, como pill de
                  // modo + SessionContextPopoverButton) ya no vive en la
                  // AppBar: flota como una sola píldora combinada bajo el
                  // composer — ver `_buildFloatingStatusPill` en
                  // `_buildInputBar`.
                  IconButton(
                    key: const ValueKey('chat-new-session'),
                    icon: Transform.translate(
                      offset: const Offset(3, 0),
                      child: const Icon(Icons.add_rounded, size: 26),
                    ),
                    tooltip: str.chaNewChatTooltip,
                    color: (_messages.isNotEmpty || _sending)
                        ? colors.accent
                        : colors.textSecondary,
                    onPressed: _newChat,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const ValueKey('chat-control-trigger'),
                    icon: const Icon(Icons.more_vert),
                    tooltip: str.chaControlTitle,
                    onPressed: _showChatControlSheet,
                  ),
                ],
        ),
        body: showVoiceSurface
            ? ColoredBox(
                color: colors.background,
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: Responsive.isTablet(context)
                          ? 800
                          : double.infinity,
                    ),
                    child: _voiceConversationSurface(),
                  ),
                ),
              )
            : Stack(
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: Responsive.isTablet(context)
                            ? 800
                            : double.infinity,
                      ),
                      child: Column(
                        children: [
                          if (_chat.dashboardAuthRequired)
                            _DesktopAuthRequiredBanner(
                              message: str.chaDesktopAuthRequiredBanner,
                            ),
                          ValueListenableBuilder<ChatTransportStatus>(
                            valueListenable: _chat.transportStatusListenable,
                            builder: (_, status, _) =>
                                ChatConnectionRecoveryRow(
                                  status: status,
                                  activeTurn: _chat.isStreaming,
                                  authRequired: _chat.dashboardAuthRequired,
                                  appForeground: _appInForeground,
                                  offlineLabel: str.chaConnectionOffline,
                                  reconnectingLabel:
                                      str.chaConnectionReconnecting,
                                  recoveredLabel: str.chaConnectionRecovered,
                                ),
                          ),
                          if (_chat.localTranscriptOlderHistoryTruncated)
                            _LocalTranscriptTruncationNotice(
                              message: str.chaLocalTranscriptTruncated,
                            ),
                          // En flujo bajo la cabecera, como los avisos de
                          // arriba: ya no flota sobre el botón «cargar
                          // anteriores» ni sobre los primeros mensajes.
                          if (_chat.earlierMessagesLoadFailed &&
                              !_coreReadCoverageNoticeDismissed)
                            _CoreReadPartialCoverageNotice(
                              message: str.chaEarlierMessagesError,
                              onDismiss: () => setState(
                                () => _coreReadCoverageNoticeDismissed = true,
                              ),
                            ),
                          Expanded(
                            child: Stack(
                              children: [
                                AgentTaskScope(
                                  tasks: _chat.agentTasks,
                                  ownerStepId: _chat.agentTasks.isEmpty
                                      ? null
                                      : latestAgentTaskStepId(_messages),
                                  child: _buildBody(),
                                ),
                                Positioned(
                                  top: 8,
                                  left: 0,
                                  right: 0,
                                  height: 48,
                                  child: _ChatTopButton(
                                    controller: _scrollController,
                                    hasEarlierMessages:
                                        _chat.hasEarlierMessages,
                                    loading: _loadingEarlierMessages,
                                    contentChanges: _liveAssistantFrame,
                                    transcriptOverlayExtent: () =>
                                        _activityPillExtent.value +
                                        (_scrollToBottomVisibility.value
                                            ? 48
                                            : 0),
                                    onLoadEarlier: _loadEarlierMessages,
                                  ),
                                ),
                                // Bottom overlay of the transcript. The
                                // scroll-to-bottom arrow and the floating
                                // activity pills share one bottom-centre
                                // anchor, so they are STACKED in a single
                                // bottom-anchored Column instead of two
                                // Positioned children layered on top of each
                                // other: the pills paint last, so the arrow
                                // used to end up underneath them — invisible
                                // and, once a pill owns the gesture, impossible
                                // to tap. Stacking makes the arrow ride just
                                // above whichever pill is showing and drop back
                                // to its resting spot (8 dp) when none is, with
                                // no measure-then-reposition frame in between.
                                //
                                // The pills stay glued near the composer like
                                // the design mockup, but always INSIDE this
                                // transcript Stack, never over the input.
                                // Reply text keeps its clearance because the
                                // measured stack extent pads the transcript by
                                // the same amount.
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 8,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: double.infinity,
                                        height: 48,
                                        child: ValueListenableBuilder<bool>(
                                          valueListenable:
                                              _scrollToBottomVisibility,
                                          builder: (context, showScrollToBottom, _) {
                                            return ExcludeSemantics(
                                              excluding: !showScrollToBottom,
                                              child: IgnorePointer(
                                                ignoring: !showScrollToBottom,
                                                child: Center(
                                                  child: AnimatedOpacity(
                                                    key: ValueKey(
                                                      showScrollToBottom
                                                          ? 'scroll-to-bottom-visible'
                                                          : 'scroll-to-bottom-hidden',
                                                    ),
                                                    opacity: showScrollToBottom
                                                        ? 1
                                                        : 0,
                                                    duration: _reduceMotion
                                                        ? Duration.zero
                                                        : const Duration(
                                                            milliseconds: 160,
                                                          ),
                                                    curve: Curves.easeOutCubic,
                                                    child: AnimatedScale(
                                                      scale: showScrollToBottom
                                                          ? 1
                                                          : 0.94,
                                                      duration: _reduceMotion
                                                          ? Duration.zero
                                                          : const Duration(
                                                              milliseconds: 160,
                                                            ),
                                                      curve:
                                                          Curves.easeOutCubic,
                                                      child: _ScrollToBottomButton(
                                                        key: const ValueKey(
                                                          'chat-scroll-to-bottom',
                                                        ),
                                                        onTap: _scrollToBottom,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      // The pill area collapses to zero when
                                      // nothing is running, and the gap below
                                      // it collapses with it so the arrow lands
                                      // back on its resting offset.
                                      _BottomGapWhenVisible(
                                        gap: 12,
                                        onExtent: _setActivityPillExtent,
                                        // Una sola pastilla para todo lo vivo
                                        // (turno, tareas, segundo plano,
                                        // subagentes, compactación): un único
                                        // hueco medido, un único cronómetro. El
                                        // panel sale de ella al tocarla.
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ActivityTaskLingerHost(
                                              key: const ValueKey(
                                                'chat-activity-pill',
                                              ),
                                              snapshot:
                                                  _buildActivitySnapshot(),
                                              actions: _buildActivityActions(),
                                              suspended: _slashPaletteVisible,
                                            ),
                                            KeyedSubtree(
                                              key: const ValueKey(
                                                'chat-session-activity',
                                              ),
                                              child: SubagentActivityCard(
                                                key: const ValueKey(
                                                  'chat-subagent-status',
                                                ),
                                                hidden: true,
                                                controller: _subagentController,
                                                activities:
                                                    _displaySubagentActivities,
                                                onDismiss: _dismissSubagentPill,
                                                safeChildCount:
                                                    _chat.safeActiveSubagentCount >
                                                        (_chat.hasRecentPassiveRemoteActivity
                                                            ? _chat
                                                                  .passiveActivityAggregate
                                                                  .total
                                                            : 0)
                                                    ? _chat
                                                          .safeActiveSubagentCount
                                                    : (_chat.hasRecentPassiveRemoteActivity
                                                          ? _chat
                                                                .passiveActivityAggregate
                                                                .total
                                                          : 0),
                                                background:
                                                    _chat
                                                        .hasRecentPassiveRemoteActivity ||
                                                    _chat.safeActiveSubagentCount >
                                                        0,
                                                canInterrupt:
                                                    _chat.canInterruptSubagent,
                                                canSteer:
                                                    _chat.canSteerSubagent,
                                                isInterruptPending: _chat
                                                    .isSubagentInterruptPending,
                                                appForeground:
                                                    _appInForeground &&
                                                    _chatRouteVisible,
                                                onTail: (activity) async {
                                                  final result = await _chat
                                                      .tailSubagent(activity);
                                                  return SubagentTailView(
                                                    available: result.available,
                                                    content: result.content,
                                                    truncated: result.truncated,
                                                  );
                                                },
                                                onSteer:
                                                    (activity, text) async {
                                                      final result = await _chat
                                                          .steerSubagent(
                                                            activity,
                                                            text,
                                                          );
                                                      return SubagentSteerView(
                                                        status: result.status,
                                                      );
                                                    },
                                                isOpenPending:
                                                    _isSubagentOpenPending,
                                                onOpenConversation: (activity) {
                                                  unawaited(
                                                    _openSubagentConversation(
                                                      activity,
                                                    ),
                                                  );
                                                },
                                                onStopRequested:
                                                    _confirmInterruptSubagent,
                                              ),
                                            ),
                                            // Nearest the composer: the
                                            // compaction pill, padded into
                                            // the same measured gap.
                                            _buildCompactionPill(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_chat.pendingInteractivePrompt != null)
                                  Positioned.fill(
                                    child: Stack(
                                      children: [
                                        // Light, un-blurred barrier — same
                                        // idiom as the app's other floating
                                        // popovers (session_context_usage.dart)
                                        // — instead of a ~70% dim: the agent is
                                        // just paused, not blocking the whole
                                        // screen, so the transcript stays
                                        // legible behind the card.
                                        Positioned.fill(
                                          child: ColoredBox(
                                            color: colors.background.withAlpha(
                                              41,
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: 16,
                                          right: 16,
                                          bottom: 16,
                                          child: InteractivePromptCard(
                                            key: ValueKey(
                                              'interactive-${_chat.pendingInteractivePrompt!.key.runtimeSessionId}-'
                                              '${_chat.pendingInteractivePrompt!.key.requestId}',
                                            ),
                                            entry:
                                                _chat.pendingInteractivePrompt!,
                                            busy:
                                                _resolvingInteractivePrompt ||
                                                _chat
                                                        .pendingInteractivePrompt!
                                                        .status ==
                                                    InteractivePromptStatus
                                                        .responding,
                                            onSubmit: (value) {
                                              unawaited(
                                                _resolveInteractivePrompt(
                                                  value,
                                                ),
                                              );
                                            },
                                            onSubmitBatch: (answers) {
                                              return _resolveInteractivePromptBatch(
                                                answers,
                                              );
                                            },
                                            onCancel: _cancelInteractivePrompt,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Lo que vive bajo el transcript (avisos en flujo,
                          // tiras y composer) es un grupo en flujo: ningun
                          // aviso transitorio flota sobre el, viven arriba.
                          KeyedSubtree(
                            key: const ValueKey('chat-bottom-bars'),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_chat.offerStaleResumedSessionStop)
                                  StaleRunningSessionBanner(
                                    enabled: _chat.gatewayConnected,
                                    onStop: _cancelStream,
                                    onDismiss: _chat
                                        .dismissStaleResumedSessionStopOffer,
                                  ),
                                // Ownership conflicts keep the transcript and composer
                                // mounted while fencing every mutation.
                                if (_chat.conflictReadOnly)
                                  _buildRuntimeOwnershipBanner(),
                                // Aprobación inline: aparece justo encima del composer cuando el
                                // agente pide permiso (motor /v1/runs).
                                if (_chat.pendingApproval != null)
                                  ChatApprovalCard(
                                    approval: _chat.pendingApproval!,
                                    busy: _resolvingApproval,
                                    onChoice: _resolveChatApproval,
                                    companion: context
                                        .findAncestorStateOfType<
                                          HermesAppState
                                        >()
                                        ?.companion,
                                  ),
                                if (_chat.desktopContinuationRequired)
                                  Semantics(
                                    container: true,
                                    label: Strings.of(
                                      context,
                                    ).chatContinueOnDesktop,
                                    child: Card(
                                      key: const ValueKey(
                                        'desktop-continuation-required',
                                      ),
                                      child: Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.desktop_windows_outlined,
                                            ),
                                            SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                Strings.of(
                                                  context,
                                                ).chatContinueOnDesktop,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                // The subagent activity indicator now floats as an
                                // overlay anchored above the transcript (see the
                                // inner Stack below) instead of living here, so its
                                // live/completed count changes never resize this
                                // Column or shift the composer.
                                _buildStopStatusStrip(colors),
                                _buildBackgroundTaskStrip(colors),
                                _buildQueueStrip(colors),
                                if ((_vc?.active ?? false) && !showVoiceSurface)
                                  _buildVoiceReturnBar(
                                    colors,
                                    ownsCurrentChat: voiceSessionActive,
                                  ),
                                if (!showVoiceSurface)
                                  Opacity(
                                    opacity: _editingUserMessage ? 0.62 : 1,
                                    child: _buildInputBar(),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // ─── Selector de modelo del agente ───────────────────────────────────────
  // El catálogo sigue viniendo de la conexión autenticada ya configurada, pero
  // una selección dentro del chat se aplica únicamente al runtime vivo con
  // `config.set`. En un borrador se captura hasta `session.create`; nunca cambia
  // el default global del servidor.

  /// Selector de modelo: lista los proveedores configurados y sus modelos
  /// (Dashboard/Bridge) y cambia solo el modelo de esta conversación.
  /// Instala el Mobile Bridge en la instancia remota vía el agente del gateway
  /// (un toque + aprobar una vez). Al terminar recarga el catálogo: el selector
  /// pasa a usar el bridge y muestra TODOS los modelos configurados. Si el
  /// servidor no lo permite (sin shell/systemd), ofrece el comando para pegarlo.
  // ── Actualización del Mobile Bridge (Fase G) ──────────────────────────────
  bool _bridgeUpdateChecked = false;

  /// Comprueba UNA vez si el bridge de esta instancia está desactualizado. El
  /// canal remoto solo se consulta aquí cuando el usuario autorizó el
  /// mantenimiento automático; sin esa autorización se compara con el fallback
  /// empaquetado y la consulta remota queda para la acción manual de Ajustes.
  Future<void> _maybeCheckBridgeUpdate() async {
    if (_bridgeUpdateChecked) return;
    if (widget.connection.readOnly) return;
    if (widget.connection.kind == InstanceKind.localhost) return;
    _bridgeUpdateChecked = true;
    final autoUpdate = await BridgeUpdateService.autoUpdateEnabled();
    final check = await BridgeUpdateService.check(
      widget.connection,
      allowRemote: autoUpdate,
    );
    if (!mounted || !check.reachable || !check.outdated) return;
    if (autoUpdate) {
      _doBridgeUpdate(silent: true);
      return;
    }
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          Strings.of(context).bridgeUpdateAvailable(
            check.installed ?? '?',
            check.available ?? BridgeUpdateService.packagedVersion,
          ),
        ),
        action: SnackBarAction(
          label: Strings.of(context).commonUpdate,
          onPressed: _doBridgeUpdate,
        ),
      ),
    );
  }

  /// Actualiza el bridge a la mejor release validada. Con [silent] no muestra el
  /// aviso de inicio (auto-update en 2º plano); siempre informa del resultado.
  Future<void> _doBridgeUpdate({bool silent = false}) async {
    final messenger = HermesNotice.of(context);
    if (!silent) {
      messenger.showSnackBar(
        SnackBar(content: Text(Strings.of(context).bridgeUpdating)),
      );
    }
    final res = await BridgeUpdateService.update(
      widget.connection,
      automatic: silent,
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? 'Mobile Bridge actualizado.'
              : 'No se pudo actualizar el bridge: ${res.detail}',
        ),
      ),
    );
  }

  Future<void> _promptInstallBridge(BuildContext sheetCtx) async {
    Navigator.of(sheetCtx).pop(); // cierra el selector
    final strings = Strings.of(context);
    final progress = ValueNotifier<String>(strings.bridgeUpdating);
    BuildContext? progressDialogContext;
    final progressDialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        progressDialogContext = dialogContext;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(Strings.of(context).chaInstallingMobileBridge),
            content: Row(
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: progress,
                    builder: (_, v, _) => Text(v),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    // Espera a que exista el contexto de la ruta: si el servicio devolviese de
    // inmediato, no debemos quedarnos aguardando un diálogo que nunca cerramos.
    while (mounted && progressDialogContext == null) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) {
      progress.dispose();
      return;
    }
    BridgeUpdateResult res = BridgeUpdateResult.failure(
      BridgeUpdateFailure.repairFailed,
      strings.bridgeNotDetected,
    );
    try {
      res = await BridgeUpdateService.update(
        widget.connection,
        onProgress: (stage) => progress.value = stage,
      );
    } catch (error) {
      res = BridgeUpdateResult.failure(
        BridgeUpdateFailure.repairFailed,
        '${strings.bridgeNotDetected} (${error.runtimeType})',
      );
    }
    final dialogContext = progressDialogContext;
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
    await progressDialog;
    progress.dispose();
    if (!mounted) return;

    if (res.ok) {
      // `health` y versión no bastan para este flujo: la pantalla necesita el
      // catálogo real. Sin esta comprobación, un bridge vivo pero sin
      // `/bridge/model/options` reabría la misma hoja y ofrecía instalarlo en
      // bucle, aparentando éxito sin explicar nada.
      final catalog = await _bridgeModelOptions();
      if (!mounted) return;
      if (catalog != null) {
        _modelSource = _ModelSource.bridge;
        _modelOptionsFuture = Future.value(catalog);
        HermesNotice.of(
          context,
        ).showSnackBar(SnackBar(content: Text(res.detail)));
        _showModelSheet();
        return;
      }
      res = BridgeUpdateResult.failure(
        BridgeUpdateFailure.verificationFailed,
        strings.bridgeNotDetected,
      );
    }

    // El agente declinó, el servidor no tiene gestor persistente o el bridge
    // arrancó sin el catálogo requerido. Mostramos siempre el motivo que antes
    // quedaba oculto y mantenemos la vía fiable de copia-pega + verificación.
    final verifying = ValueNotifier<bool>(false);
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(Strings.of(context).bridgeInstallServerTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                res.detail,
                style: TextStyle(color: Theme.of(context).hermes.error),
              ),
              const SizedBox(height: 10),
              Text(Strings.of(context).bridgeInstallBody),
              const SizedBox(height: 12),
              const PlatformSetupCommands(),
            ],
          ),
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: verifying,
            builder: (_, busy, _) => TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final messenger = HermesNotice.of(context);
                      final nav = Navigator.of(dctx);
                      final strConnected = Strings.of(context).bridgeConnected;
                      final strNotDetected = Strings.of(
                        context,
                      ).bridgeNotDetected;
                      verifying.value = true;
                      final ok = await _verifyBridge();
                      verifying.value = false;
                      if (!mounted) return;
                      if (ok) {
                        nav.pop();
                        _modelOptionsFuture = null;
                        messenger.showSnackBar(
                          SnackBar(content: Text(strConnected)),
                          kind: HermesNoticeKind.success,
                        );
                        _showModelSheet();
                      } else {
                        messenger.showSnackBar(
                          SnackBar(content: Text(strNotDetected)),
                          kind: HermesNoticeKind.warning,
                        );
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(Strings.of(context).bridgeAlreadyRanVerify),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(Strings.of(context).commonClose),
          ),
        ],
      ),
    ).then((_) => verifying.dispose());
  }

  /// Comprueba que el Mobile Bridge responde y entrega el catálogo que necesita
  /// este flujo ("Ya lo ejecuté — Verificar").
  Future<bool> _verifyBridge() async {
    try {
      return await _bridgeModelOptions() != null;
    } catch (_) {
      return false;
    }
  }

  void _showModelSheet() {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    // El catálogo se refresca al abrir; si ya hay runtime, `session.info` sigue
    // siendo la única fuente del badge efectivo.
    _modelOptionsFuture ??= _loadModelOptions()
      ..then((res) {
        if (!mounted ||
            _modelSource == _ModelSource.gateway ||
            _chat.hasDesktopRuntime) {
          return;
        }
        final info = res.$1;
        if (info.model.isNotEmpty) setState(() => _activeModel = info);
      }).catchError((_) {});
    var modelQuery = '';
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('chat-model-dialog'),
      maxWidth: 620,
      builder: (ctx) {
        final colors = Theme.of(ctx).hermes;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.8,
            ),
            child: StatefulBuilder(
              builder: (ctx, setSheet) {
                return FutureBuilder<(ModelActiveInfo, List<ModelProvider>)>(
                  future: _modelOptionsFuture ??= _loadModelOptions(),
                  builder: (ctx, snap) {
                    final loading =
                        snap.connectionState == ConnectionState.waiting;
                    final active = _chat.hasDesktopRuntime
                        ? _activeModel
                        : snap.data?.$1;
                    final providers = snap.data?.$2 ?? const <ModelProvider>[];
                    final visibleProviders = filterModelProviders(
                      providers,
                      modelQuery,
                    );
                    final selectedOption = _desktopModelCatalog?.optionFor(
                      _selectedProvider,
                      _selectedModel,
                    );
                    final reasoningSupported =
                        selectedOption?.capabilities.reasoning != false;
                    final fastSupported =
                        selectedOption?.capabilities.fast != false;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  Strings.of(ctx).chaModelSheetTitle,
                                  style: Theme.of(ctx).textTheme.titleMedium,
                                ),
                                Text(
                                  active == null
                                      ? Strings.of(
                                          ctx,
                                        ).chaModelSheetSubtitleDefault
                                      : (active.provider.isNotEmpty
                                            ? Strings.of(
                                                ctx,
                                              ).chaModelSheetSubtitleActive(
                                                friendlyModelName(active.model),
                                                active.provider,
                                              )
                                            : Strings.of(
                                                ctx,
                                              ).chaModelSheetSubtitleActiveOnly(
                                                friendlyModelName(active.model),
                                              )),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: TextField(
                            key: const ValueKey('chat-model-search'),
                            textInputAction: TextInputAction.search,
                            onChanged: (value) {
                              setSheet(() => modelQuery = value);
                            },
                            decoration: InputDecoration(
                              hintText: Strings.of(ctx).modelSearchHint,
                              prefixIcon: const Icon(Icons.search_rounded),
                              isDense: true,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                Strings.of(ctx).chaSessionReasoningLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: colors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 6),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final effort
                                        in DesktopReasoningEffort.values)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: ChoiceChip(
                                          label: Text(effort.wire),
                                          selected:
                                              _selectedReasoning == effort,
                                          onSelected:
                                              _settingModel ||
                                                  !reasoningSupported
                                              ? null
                                              : (_) async {
                                                  await _applySessionReasoning(
                                                    effort,
                                                  );
                                                  if (ctx.mounted) {
                                                    setSheet(() {});
                                                  }
                                                },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (!reasoningSupported)
                                Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: Text(
                                    Strings.of(
                                      ctx,
                                    ).chaModelReasoningUnavailable,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text(
                                    Strings.of(ctx).chaSessionFastLabel,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                  const Spacer(),
                                  SegmentedButton<DesktopFastMode>(
                                    segments: [
                                      ButtonSegment(
                                        value: DesktopFastMode.normal,
                                        label: Text(
                                          Strings.of(ctx).chaSessionFastNormal,
                                        ),
                                      ),
                                      ButtonSegment(
                                        value: DesktopFastMode.fast,
                                        label: Text(
                                          Strings.of(ctx).chaSessionFastEnabled,
                                        ),
                                      ),
                                    ],
                                    selected: {
                                      _selectedFastMode ??
                                          DesktopFastMode.normal,
                                    },
                                    onSelectionChanged:
                                        _settingModel || !fastSupported
                                        ? null
                                        : (selection) async {
                                            await _applySessionFastMode(
                                              selection.single,
                                            );
                                            if (ctx.mounted) setSheet(() {});
                                          },
                                    showSelectedIcon: false,
                                  ),
                                ],
                              ),
                              if (!fastSupported)
                                Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: Text(
                                    Strings.of(ctx).chaModelFastUnavailable,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // Bridge ausente (solo se pudo listar el alias del
                        // gateway): ofrece instalarlo para ver TODOS los modelos.
                        if (!loading && _modelSource == _ModelSource.gateway)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: InkWell(
                              onTap: () => _promptInstallBridge(ctx),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: colors.surface,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: colors.accent),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.download_for_offline_outlined,
                                      color: colors.accent,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        Strings.of(
                                          context,
                                        ).chatInstallBridgeModels,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: colors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right,
                                      color: colors.textSecondary,
                                      size: 18,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (_settingModel)
                          LinearProgressIndicator(
                            minHeight: 2,
                            backgroundColor: colors.surface,
                            color: colors.accent,
                          ),
                        if (loading)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else if (snap.hasError)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                            child: Text(
                              '${Strings.of(ctx).chaModelSheetError}\n\n${snap.error}',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: colors.textSecondary,
                              ),
                            ),
                          )
                        else if (providers.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                            child: Text(
                              Strings.of(ctx).chaModelSheetEmpty,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: colors.textSecondary,
                              ),
                            ),
                          )
                        else if (visibleProviders.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
                            child: Text(
                              Strings.of(ctx).modelSearchEmpty,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: colors.textSecondary,
                              ),
                            ),
                          )
                        else
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final p in visibleProviders) ...[
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      12,
                                      16,
                                      4,
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          (p.name.isNotEmpty ? p.name : p.slug)
                                              .toUpperCase(),
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                            // Encabezado de proveedor en el color
                                            // del tema; se distingue por el texto
                                            // (mayúsculas + negrita), no por marca.
                                            color: colors.accent,
                                          ),
                                        ),
                                        if (p.isCurrent) ...[
                                          const SizedBox(width: 6),
                                          Icon(
                                            Icons.bolt,
                                            size: 13,
                                            color: colors.accent,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  for (final modelId in p.models)
                                    _modelTile(
                                      ctx,
                                      setSheet,
                                      colors,
                                      provider: p,
                                      modelId: modelId,
                                      isActive:
                                          _selectedProvider == p.slug &&
                                          _selectedModel == modelId,
                                    ),
                                ],
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    ).whenComplete(() => _modelOptionsFuture = null);
  }

  Widget _modelTile(
    BuildContext sheetCtx,
    void Function(void Function()) setSheet,
    HermesThemeColors colors, {
    required ModelProvider provider,
    required String modelId,
    required bool isActive,
  }) {
    final desktopProvider = _desktopModelCatalog?.providerFor(provider.slug);
    final desktopOption = desktopProvider?.optionFor(modelId);
    final isUsable =
        _modelSource != _ModelSource.desktop ||
        (desktopOption != null && !desktopOption.unavailable);
    final unavailableLabel = Strings.of(sheetCtx).chaModelUnavailable;
    final dotColor = !isUsable
        ? colors.textDisabled
        : isActive
        ? colors.accent
        : colors.textSecondary;
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive && isUsable ? dotColor : Colors.transparent,
              border: Border.all(
                color: dotColor,
                width: isActive && isUsable ? 0 : 1.5,
              ),
            ),
          ),
        ),
      ),
      title: Text(
        friendlyModelName(modelId),
        style: TextStyle(
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          color: !isUsable
              ? colors.textDisabled
              : isActive
              ? colors.accent
              : colors.textPrimary,
        ),
      ),
      subtitle: Text(
        isUsable ? modelId : '$modelId · $unavailableLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
      ),
      trailing: !isUsable
          ? Icon(Icons.block_outlined, color: colors.textDisabled, size: 18)
          : isActive
          ? Icon(Icons.check, color: colors.accent)
          : desktopOption?.pricing?.free == true
          ? Icon(Icons.savings_outlined, color: colors.success, size: 18)
          : null,
      onTap: _settingModel || isActive || !isUsable
          ? null
          : () => _applyModel(sheetCtx, setSheet, provider, modelId),
    );
  }

  /// Cambia el modelo del runtime actual o lo captura para el primer submit.
  Future<void> _applyModel(
    BuildContext sheetCtx,
    void Function(void Function()) setSheet,
    ModelProvider provider,
    String modelId,
  ) async {
    FocusScope.of(sheetCtx).unfocus();
    if (sheetCtx.mounted) setSheet(() => _settingModel = true);
    var applied = false;
    try {
      applied = await _applySessionModelSelection(
        provider,
        modelId,
        dialogContext: sheetCtx,
      );
    } finally {
      if (sheetCtx.mounted) setSheet(() => _settingModel = false);
    }
    if (applied && sheetCtx.mounted) Navigator.pop(sheetCtx);
  }
  // ─── Permisos por sesión (badge + selector) ───────────────────────────────

  Color _modeColor(ApprovalMode m, HermesThemeColors colors) => switch (m) {
    ApprovalMode.yolo => colors.error,
    ApprovalMode.readOnly => colors.textSecondary,
    ApprovalMode.conservative => colors.warning,
    _ => colors.accent,
  };

  /// (label, color) para el segmento de modo de la píldora combinada
  /// contexto+modo, o `null` cuando el modo es el normal (nada que destacar).
  /// Misma condición "prominent" que usaba el antiguo pill de la AppBar
  /// (YOLO / solo lectura / override por sesión).
  (String, Color)? _modeFlag(HermesThemeColors colors) {
    final policy = context
        .findAncestorStateOfType<HermesAppState>()
        ?.approvalPolicy;
    if (policy == null) return null;
    final override = policy.sessionMode(widget.session.id);
    final effective = policy.effectiveMode(widget.session.id);
    final prominent =
        effective == ApprovalMode.yolo ||
        effective == ApprovalMode.readOnly ||
        override != null;
    if (!prominent) return null;
    return (effective.label, _modeColor(effective, colors));
  }

  /// Lista de opciones de modo (radio buttons), compartida por el sheet
  /// independiente (menú ⋮ → "Permisos") y la sección de modo embebida en el
  /// popover de contexto — una sola fuente de verdad para evitar duplicar el
  /// bucle de `ListTile`s en dos sitios. [dismissHost] cierra la superficie
  /// que aloja esta lista (el sheet o el popover) antes de aplicar el modo.
  List<Widget> _approvalModeOptionTiles({
    required BuildContext ctx,
    required ApprovalPolicyService policy,
    required HermesThemeColors colors,
    required VoidCallback dismissHost,
  }) {
    final s = Strings.of(ctx);
    final override = policy.sessionMode(widget.session.id);
    // null = usar global; los demás = override de sesión.
    final options = <(ApprovalMode?, String, String)>[
      (null, s.chaModeGlobalTitle, s.chaModeGlobalSub),
      (ApprovalMode.yolo, 'YOLO', s.chaModeYoloSub),
      (
        ApprovalMode.interactive,
        s.chaModeInteractiveTitle,
        s.chaModeInteractiveSub,
      ),
      (
        ApprovalMode.conservative,
        s.chaModeConservativeTitle,
        s.chaModeConservativeSub,
      ),
      (ApprovalMode.readOnly, s.chaModeReadOnlyTitle, s.chaModeReadOnlySub),
    ];
    return [
      for (final (mode, title, sub) in options)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            (override == mode)
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            color: mode == null ? colors.accent : _modeColor(mode, colors),
          ),
          title: Text(title),
          subtitle: Text(
            sub,
            style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
          ),
          onTap: () async {
            dismissHost();
            await _selectSessionMode(policy, mode);
          },
        ),
    ];
  }

  void _showModeSheet(ApprovalPolicyService policy) {
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('chat-mode-dialog'),
      maxWidth: 560,
      builder: (ctx) {
        final colors = Theme.of(ctx).hermes;
        final s = Strings.of(ctx);
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 10),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.chaModeSheetTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      s.chaModeSheetEffective(
                        policy.effectiveMode(widget.session.id).label,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ..._approvalModeOptionTiles(
              ctx: ctx,
              policy: policy,
              colors: colors,
              dismissHost: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  /// Sección de modo embebida al final del popover de contexto (ver
  /// `showSessionContextPopover`'s `modeSectionBuilder`): mismo contenido que
  /// `_showModeSheet`, reutilizado vía `_approvalModeOptionTiles` en vez de
  /// duplicar el listado. [closePopover] es el `onClose` del propio popover.
  Widget _buildApprovalModeSection(
    BuildContext ctx,
    VoidCallback closePopover,
  ) {
    final policy = context
        .findAncestorStateOfType<HermesAppState>()
        ?.approvalPolicy;
    if (policy == null) return const SizedBox.shrink();
    final colors = Theme.of(ctx).hermes;
    final s = Strings.of(ctx);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.chaModeSheetTitle,
          style: Theme.of(
            ctx,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          s.chaModeSheetEffective(
            policy.effectiveMode(widget.session.id).label,
          ),
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        ..._approvalModeOptionTiles(
          ctx: ctx,
          policy: policy,
          colors: colors,
          dismissHost: closePopover,
        ),
      ],
    );
  }

  Future<void> _selectSessionMode(
    ApprovalPolicyService policy,
    ApprovalMode? mode,
  ) async {
    // Activar YOLO por sesión: App Lock (si está) + confirmación fuerte.
    if (mode == ApprovalMode.yolo) {
      final app = context.findAncestorStateOfType<HermesAppState>();
      final lock = app?.appLock;
      if (lock != null && lock.enabled) {
        final ok = await LockScreen.verify(
          context,
          lock,
          reason: Strings.of(context).chaYoloLockReason,
        );
        if (!ok || !mounted) return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) {
          final s = Strings.of(context);
          return AlertDialog(
            title: Text(s.chaYoloTitle),
            content: Text(s.chaYoloBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.chaCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.chaActivate),
              ),
            ],
          );
        },
      );
      if (confirmed != true || !mounted) return;
    }
    // El modo se evalúa EN VIVO en cada `approval.request` (no se manda al
    // agente al iniciar el run), así que el cambio se aplica de inmediato,
    // incluso a las aprobaciones que falten del run en curso. Se persiste para
    // esta sesión (sobrevive a reinicios).
    final wasSending = _sending;
    policy.setSessionMode(widget.session.id, mode);
    if (!mounted) return;
    setState(() {});
    if (wasSending) {
      final label = policy.effectiveMode(widget.session.id).label;
      HermesNotice.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaModeApplied(label)),
            duration: const Duration(seconds: 3),
          ),
          kind: HermesNoticeKind.success,
        );
    }
  }

  VoiceService? get _voice => _voiceService;

  // ── Dictado por voz ──────────────────────────────────────────────────
  bool _transcribing = false;
  String _dictationPartial = '';
  String _dictationBase = '';
  String _dictationOriginal = '';
  bool _dictationSendInFlight = false;
  Completer<void>? _dictationCompletion;

  Future<void> _startDictation() async {
    final voice = _voice;
    if (voice == null) return;
    final perf = Stopwatch()..start();
    debugPrint('[VOICE-PERF] dictation.button.tap');
    // Cancela cualquier red de seguridad pendiente del dictado ANTERIOR: si no,
    // su _stopFallback (4s) podía dispararse a mitad de este nuevo dictado y
    // resetearlo (el 2º dictado "se paraba solo"). También cierra una sesión STT
    // previa que siguiera viva.
    _stopFallback?.cancel();
    _stopFallback = null;
    if (_sttSub != null) {
      await _sttSub!.cancel();
      _sttSub = null;
      await voice.stopDictation();
    }
    if (voice.settings.sttEngine == SttEngineKind.hermesServer) {
      final preparation = voice.beginHermesServerDictationPreparation(
        owner: this,
      );
      final prefs = await SharedPreferences.getInstance();
      final configuration = await configureHermesServerDictation(
        voice: voice,
        owner: this,
        preparation: preparation,
        connection: widget.connection,
        preferences: prefs,
        profile: _effectiveSessionProfile,
      );
      if (!mounted) {
        voice.cancelHermesServerDictationPreparation(preparation);
        voice.disableHermesServerDictation(owner: this);
        return;
      }
      if (configuration ==
          HermesServerDictationConfigurationResult.superseded) {
        return;
      }
      if (configuration !=
          HermesServerDictationConfigurationResult.configured) {
        await _showVoiceUnavailable(
          const SttCheck(
            SttStatus.needsServerConfig,
            SttEngineKind.hermesServer,
          ),
        );
        return;
      }
    } else {
      voice.disableHermesServerDictation(owner: this);
    }
    final check = await voice.checkStt(forComposerDictation: true);
    debugPrint(
      '[VOICE-PERF] dictation.stt_check.ready_ms=${perf.elapsedMilliseconds} '
      'status=${check.status.name}',
    );
    if (!check.ready) {
      if (mounted) await _showVoiceUnavailable(check);
      return;
    }
    if (!await voice.prepareForMicrophoneCapture()) return;
    // El dictado transforma el mismo composer sin desmontar su TextField. Si el
    // teclado ya estaba abierto conserva la conexión IME; tocar el micrófono no
    // debe cerrarlo ni abrirlo por sorpresa.
    _dictationOriginal = _textController.text;
    _dictationBase = _textController.text.trimRight();
    _dictationCompletion = Completer<void>();
    setState(() {
      _isRecording = true;
      _transcribing = false;
      _dictationPartial = '';
      _dictationSendInFlight = false;
    });
    debugPrint(
      '[VOICE-PERF] dictation.ui.listening_ms=${perf.elapsedMilliseconds}',
    );
    _listenDictation();
  }

  /// Abre (o reabre) un tramo de escucha del dictado. El texto del tramo se
  /// concatena a [_dictationBase] (lo acumulado de tramos previos / lo ya escrito).
  void _listenDictation() {
    final voice = _voice;
    if (voice == null) return;
    _sttSub = voice
        .startDictation(continuous: true, forComposerDictation: true)
        .listen(
          (r) {
            if (!mounted) return;
            if (!r.isFinal) {
              var partial = r.text.trim();
              if (VoiceResponsePolicy.isLikelySttHallucination(partial)) {
                partial = '';
              }
              if (partial != _dictationPartial) {
                setState(() => _dictationPartial = partial);
              }
              return;
            }
            var t = r.text.trim();
            // Descarta alucinaciones típicas del STT sobre silencio ("gracias",
            // "suscríbete", "thanks for watching"…) para no ensuciar el dictado.
            if (VoiceResponsePolicy.isLikelySttHallucination(t)) t = '';
            setState(() {
              _dictationPartial = '';
              if (t.isNotEmpty) {
                _dictationBase = _joinDictation(_dictationBase, t);
              }
            });
          },
          onError: (e) {
            if (mounted) {
              _commitPendingDictationPartial();
              _resetDictation();
              _materializeDictation();
              HermesNotice.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    Strings.of(context).chaDictationError(humanizeApiError(e)),
                  ),
                ),
                kind: HermesNoticeKind.error,
              );
            }
            if (!mounted) _resetDictation();
          },
          onDone: _onDictationSegmentDone,
        );
  }

  /// Fin de un tramo de escucha (el motor cierra el turno tras una pausa, o el
  /// usuario pulsó parar). NO reabrimos el micro automáticamente: el dictado lo
  /// controla el usuario. Paramos y conservamos lo transcrito; para seguir
  /// dictando, vuelve a pulsar el micro y se reanuda AÑADIENDO a lo ya escrito
  /// (_dictationBase = texto actual al arrancar). Así el micro no "sigue
  /// escribiendo" solo con alucinaciones del STT sobre ruido/silencio.
  void _onDictationSegmentDone() {
    if (!_isRecording && !_transcribing) return;
    _commitPendingDictationPartial();
    _resetDictation();
    _materializeDictation();
  }

  String _joinDictation(String base, String segment) {
    final cleanBase = base.trimRight();
    final cleanSegment = segment.trim();
    if (cleanBase.isEmpty) return cleanSegment;
    if (cleanSegment.isEmpty) return cleanBase;
    return '$cleanBase $cleanSegment';
  }

  void _setComposerText(String text) {
    _textController.text = text;
    _textController.selection = TextSelection.collapsed(offset: text.length);
  }

  void _materializeDictation() => _setComposerText(_dictationBase);

  /// Si el motor cierra sin emitir un resultado final, usa el último parcial
  /// retenido en memoria. El usuario solo lo ve después de parar.
  void _commitPendingDictationPartial() {
    var partial = _dictationPartial.trim();
    if (VoiceResponsePolicy.isLikelySttHallucination(partial)) partial = '';
    if (partial.isNotEmpty) {
      _dictationBase = _joinDictation(_dictationBase, partial);
    }
    _dictationPartial = '';
  }

  /// El usuario pulsa "parar": con Whisper esto dispara la transcripción (el
  /// resultado llega por el stream); con el sistema cierra el reconocimiento.
  Future<void> _stopDictation() async {
    final voice = _voice;
    if (voice == null) return;
    if (_transcribing) return;
    final hasPendingText =
        _dictationPartial.trim().isNotEmpty ||
        _dictationOriginal.trimRight() != _dictationBase.trimRight();
    final perf = Stopwatch()..start();
    debugPrint(
      '[VOICE-PERF] dictation.stop.request '
      'pending_text=$hasPendingText '
      'records_then_transcribes=${voice.sttRecordsThenTranscribes}',
    );
    if (mounted) setState(() => _transcribing = true);
    // El fallback empieza antes de esperar al motor: un backend que tarda en
    // cerrar no puede dejar la fila de dictado bloqueada indefinidamente.
    _stopFallback?.cancel();
    _stopFallback = Timer(const Duration(seconds: 4), () {
      if (mounted && (_isRecording || _transcribing)) {
        _commitPendingDictationPartial();
        _resetDictation();
        _materializeDictation();
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).chaVoiceNotRecognized)),
          kind: HermesNoticeKind.warning,
        );
      }
    });
    await voice.stopDictation();
    debugPrint(
      '[VOICE-PERF] dictation.stop.completed_ms=${perf.elapsedMilliseconds}',
    );
  }

  Future<void> _cancelDictation() async {
    if (!_isRecording || _dictationSendInFlight) return;
    _stopFallback?.cancel();
    _stopFallback = null;
    final subscription = _sttSub;
    _sttSub = null;
    if (subscription != null) unawaited(subscription.cancel());
    _resetDictation();
    _setComposerText(_dictationOriginal);
    // Cancel descarta el tramo y vuelve a reposo en el mismo frame. El teardown
    // acústico puede terminar después sin reescribir el borrador restaurado.
    await _voice?.cancelDictation();
  }

  Future<void> _sendDictation() async {
    if (!_isRecording || _dictationSendInFlight) return;
    setState(() => _dictationSendInFlight = true);
    final completion = _dictationCompletion;
    try {
      if (!_transcribing) {
        final stop = _stopDictation();
        if (completion != null && !completion.isCompleted) {
          await Future.any<void>([stop, completion.future]);
        } else {
          await stop;
        }
      }
      if (completion != null && !completion.isCompleted) {
        await completion.future.timeout(
          const Duration(milliseconds: 4300),
          onTimeout: () {
            if (mounted && (_isRecording || _transcribing)) {
              _commitPendingDictationPartial();
              _resetDictation();
              _materializeDictation();
            }
          },
        );
      }
      if (!mounted) return;
      await _sendMessage();
    } finally {
      if (mounted) {
        setState(() => _dictationSendInFlight = false);
      } else {
        _dictationSendInFlight = false;
      }
    }
  }

  /// Cierra el dictado al ENVIAR: corta la suscripción primero (para que ningún
  /// evento posterior re-escriba el composer ya limpiado) y suelta el micro/WS
  /// del motor en segundo plano, descartando su resultado final.
  void _finishDictationForSend() {
    if (!_isRecording && _sttSub == null) return;
    _commitPendingDictationPartial();
    _sttSub?.cancel();
    _sttSub = null;
    unawaited(_voice?.stopDictation());
    _resetDictation();
    _materializeDictation();
  }

  void _resetDictation() {
    _stopFallback?.cancel();
    _stopFallback = null;
    _sttSub?.cancel();
    _sttSub = null;
    final completion = _dictationCompletion;
    _dictationCompletion = null;
    if (mounted) {
      setState(() {
        _isRecording = false;
        _transcribing = false;
        _dictationPartial = '';
      });
      _onComposerChanged();
    }
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  /// El dictado no puede arrancar: en vez de fallar en silencio, explica la
  /// causa concreta y ofrece un atajo a Ajustes › Voz (descargar Whisper, etc.).
  Future<void> _showVoiceUnavailable(SttCheck check) async {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final (String title, String body, String cta) = switch (check.status) {
      SttStatus.needsWhisperModel => (
        str.chaVoiceNeedWhisperTitle,
        str.chaVoiceNeedWhisperBody,
        str.chaVoiceSettingsCta,
      ),
      SttStatus.needsSherpaModel => (
        str.chaVoiceNeedsModelTitle,
        str.chaVoiceNeedsModelBody,
        str.chaVoiceSettingsCta,
      ),
      SttStatus.needsServerConfig => (
        str.chaVoiceNeedsServerTitle,
        str.chaVoiceNeedsServerBody,
        str.chaVoiceSettingsCta,
      ),
      // A-013 (spec 028): con el permiso denegado, mandar a Ajustes › Voz era
      // un callejón sin salida (allí no hay ningún control de permiso). El CTA
      // re-pide el permiso al sistema reintentando el dictado; el cuerpo ya
      // explica la ruta manual si el SO suprime el diálogo (denegación
      // permanente) — no hay plugin para abrir los ajustes de la app.
      SttStatus.needsMicPermission => (
        str.chaVoiceNeedMicTitle,
        str.chaVoiceNeedMicBody,
        str.chaVoiceAllowMic,
      ),
      SttStatus.systemUnavailable => (
        str.chaVoiceNoSystemTitle,
        str.chaVoiceNoSystemBody,
        str.chaVoiceWhisperCta,
      ),
      SttStatus.ready => ('', '', ''),
    };
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        icon: Icon(Icons.mic_off_rounded, color: colors.accent, size: 28),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        content: Text(
          body,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              str.chaVoiceNotNow,
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          FilledButton.icon(
            icon: Icon(
              check.status == SttStatus.needsMicPermission
                  ? Icons.mic_rounded
                  : Icons.settings_voice_rounded,
              size: 16,
            ),
            label: Text(cta),
            onPressed: () {
              Navigator.pop(ctx);
              if (check.status == SttStatus.needsMicPermission) {
                // Reintentar el dictado vuelve a solicitar el permiso de
                // micrófono al sistema (lo pide el motor STT al arrancar).
                _startDictation();
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => VoiceSettingsScreen(
                    connection: widget.connection,
                    profile: _effectiveSessionProfile,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Map<String, dynamic>? _assistantMessageForAnswer(String answer) {
    for (final message in _messages) {
      if (message['role'] != 'assistant' || message['_pipeline'] == true) {
        continue;
      }
      final content = (message['content'] as String?) ?? '';
      if (splitReasoning(content).answer == answer) return message;
    }
    return null;
  }

  String _readAloudMessageKey(Map<String, dynamic>? message, String answer) {
    return chatReadAloudMessageKey(widget.session.id, message, answer);
  }

  String _readAloudRevision(String answer) => _stableChatReadAloudHash(answer);

  /// Alterna la sesión de lectura de una burbuja concreta. El servicio decide
  /// si el gesto pausa/reanuda o detiene/reinicia según la preferencia.
  Future<void> _toggleReadAloud(
    Map<String, dynamic> message,
    String text,
  ) async {
    final voice = _voice;
    if (voice == null || text.trim().isEmpty) return;
    try {
      await voice.toggleReadAloud(
        messageKey: _readAloudMessageKey(message, text),
        revision: _readAloudRevision(text),
        markdown: text,
      );
    } catch (e) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(
                context,
              ).chaVoiceError(localizedVoiceError(Strings.of(context), e)),
            ),
          ),
          kind: HermesNoticeKind.error,
        );
      }
    }
  }

  /// Engancha la única superficie pública de voz local.
  void _attachVoiceSurface(HermesAppState app) {
    if (!kVoiceRuntimeEnabled) return;
    final VoiceUiSurface wanted = app.voiceConvo;
    if (identical(wanted, _vc)) return;
    // No cambiar de pipeline con una sesión de voz activa (se haría un lío de
    // listeners); el cambio aplica en la siguiente entrada al modo voz.
    if (_vc?.active ?? false) return;
    _vc?.removeListener(_onVoiceState);
    _vcUnavailableSub?.cancel();
    _vc = wanted;
    _vc!.addListener(_onVoiceState);
    _vcUnavailableSub = _vc!.unavailable.listen((check) {
      if (mounted) _showVoiceUnavailable(check);
    });
  }

  // ── Modo voz manos libres (delega en el controlador local global) ──
  /// Abre el modo voz para ESTA sesión. La orquestación entera (bucle, fases,
  /// TTS) vive en el servicio global, así que sobrevive a la navegación y al 2º
  /// plano. La pantalla solo abre y proyecta el VoiceStage.
  /// Ofrece el modo de voz nativo Desktop (spec 048/US5) para esta conexión:
  /// sonda cacheada de `/api/audio/*`, consentimiento único por identidad de
  /// servidor y activación del enrutado en VoiceService. Devuelve `false` si
  /// el usuario eligió servidor y esa ruta no está lista: en ese caso Voz no
  /// puede arrancar usando motores locales a escondidas.
  Future<bool> _maybeOfferNativeVoice(HermesAppState app) async {
    DashboardClient? discoveryClient;
    final connection = widget.connection;
    final preparation = app.voice.beginNativeVoicePreparation(owner: this);
    if (preparation == null) return false;
    _nativeVoicePreparation = preparation;
    try {
      final prefs = await SharedPreferences.getInstance();
      final dashboard = DashboardClient.lazy(widget.connection);
      discoveryClient = dashboard;
      final profile = _effectiveSessionProfile;
      final identity = nativeVoicePreferenceIdentity(
        dashboard.baseUrl,
        profile: profile,
      );
      final mode = NativeVoiceModeStore(prefs).read(identity);
      if (mode != NativeVoiceMode.server) {
        app.voice.cancelNativeVoicePreparation(preparation);
        app.voice.enableOnDeviceVoice();
        debugPrint(
          '[VOICE-PERF] voice.route.selected=phone status=ready '
          'stt=${app.voice.effectiveConversationSttEngine.id} '
          'tts=${app.voice.effectiveConversationTtsEngine.id}',
        );
        return true;
      }
      final consentStore = NativeVoiceConsentStore(prefs);
      final consent = consentStore.read(identity);
      if (consent != NativeVoiceConsent.accepted) {
        debugPrint(
          '[VOICE-PERF] voice.route.selected=server status=blocked_consent',
        );
        return false;
      }

      final capabilityStore = NativeVoiceCapabilityStore(prefs);
      var capability = capabilityStore.read(identity);
      if (capability == null || !capabilityStore.isFresh(capability)) {
        capability = await probeNativeVoiceCapability(
          statusOf: (endpoint) =>
              dashboard.probeAudioEndpoint(endpoint, profile: profile),
        );
        await capabilityStore.write(identity, capability);
      }
      if (!capability.ok) {
        debugPrint(
          '[VOICE-PERF] voice.route.selected=server status=unavailable',
        );
        return false;
      }

      // Transfiere el cliente que resolvió capacidad, elección y consentimiento
      // a la sesión para evitar relogins por cada operación STT/TTS.
      discoveryClient = null;
      final configured = await configureAcceptedNativeVoiceSession(
        voice: app.voice,
        connection: widget.connection,
        preferences: prefs,
        profile: profile,
        owner: this,
        preparation: preparation,
        isStillCurrent: () =>
            mounted &&
            !_disposed &&
            identical(_nativeVoicePreparation, preparation) &&
            identical(widget.connection, connection) &&
            _effectiveSessionProfile == profile,
        dashboardClient: dashboard,
      );
      debugPrint(
        '[VOICE-PERF] voice.route.selected=server '
        'status=${configured ? 'ready' : 'unavailable'}',
      );
      return configured;
    } catch (e) {
      debugPrint(
        '[voice-stab] oferta de voz nativa omitida (${e.runtimeType})',
      );
      return false;
    } finally {
      app.voice.cancelNativeVoicePreparation(preparation);
      if (identical(_nativeVoicePreparation, preparation)) {
        _nativeVoicePreparation = null;
      }
      discoveryClient?.close();
    }
  }

  Future<void> _enterVoiceMode() async {
    if (!kVoiceRuntimeEnabled) return;
    await _profileReady;
    final outboxRecoveryAvailable = await _initialOutboxRead.future;
    if (!mounted) return;
    if (!outboxRecoveryAvailable) {
      _showOutboxUnavailable();
      return;
    }
    final perf = Stopwatch()..start();
    debugPrint('[VOICE-PERF] voice.button.tap');
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (app == null) return;
    await app.serializeVoiceEntry(() => _enterVoiceModeSerialized(app, perf));
  }

  Future<void> _enterVoiceModeSerialized(
    HermesAppState app,
    Stopwatch perf,
  ) async {
    if (!mounted) return;
    // El runtime de Voz es global. Resolver consentimiento, capacidades o ruta
    // desde otro chat antes de mirar su propietario podía sustituir los
    // callbacks STT/TTS de la conversación que seguía viva. El owner siempre
    // gana antes de cualquier await o mutación de VoiceService.
    if (await _resumeActiveVoiceSessionIfAny(app)) return;
    if (!mounted) return;
    if (!app.voice.voiceDisclosureAccepted) {
      final choice = await showVoiceDisclosureDialog(context);
      if (!mounted || choice == null) return;
      await app.voice.acceptVoiceDisclosure(
        continueWhenLocked: choice == VoiceDisclosureChoice.continueWhenLocked,
      );
      if (!mounted) return;
    }
    // El diálogo anterior permite navegación concurrente; vuelve a cerrar la
    // carrera antes de configurar la ruta elegida por esta pantalla.
    if (await _resumeActiveVoiceSessionIfAny(app)) return;
    // Spec 048/US5: si el servidor de esta conexión ofrece los motores de voz
    // de Desktop, resuélvelo (con consentimiento único) ANTES del checkStt,
    // que debe reflejar el motor que de verdad se usará.
    final selectedRouteReady = await _maybeOfferNativeVoice(app);
    if (!mounted) return;
    if (!selectedRouteReady) {
      if (await _resumeActiveVoiceSessionIfAny(app)) return;
      await _showVoiceUnavailable(
        const SttCheck(SttStatus.needsServerConfig, SttEngineKind.server),
      );
      return;
    }
    // Android 14+ no permite crear un FGS `microphone` antes de que
    // RECORD_AUDIO esté concedido. `vc.enter()` publica `active` de forma
    // síncrona y el listener global puede arrancar ese FGS inmediatamente para
    // la continuidad bloqueada, así que resolver el STT DESPUÉS de entrar deja
    // una carrera entre el diálogo de permiso y el servicio. Comprobarlo aquí
    // mantiene el orden exigido: aviso → permiso → sesión/FGS.
    final check = await app.voice.checkStt();
    debugPrint(
      '[VOICE-PERF] voice.stt_check.ready_ms=${perf.elapsedMilliseconds} '
      'status=${check.status.name}',
    );
    if (!mounted) return;
    if (await _resumeActiveVoiceSessionIfAny(app)) return;
    if (!mounted) return;
    if (!check.ready) {
      await _showVoiceUnavailable(check);
      return;
    }
    final vc = _vc;
    if (vc == null) return;
    // Quita el foco del campo de texto y cierra el teclado: si no, el cursor
    // parpadeante se cuela por encima del overlay del modo voz.
    FocusScope.of(context).unfocus();
    await vc.enter(
      chat: _chat,
      model: _selectedModel,
      profile: _effectiveSessionProfile,
      allowTransportFallback: _firstSubmitConfig.allowTransportFallback,
      // En el primer turno por voz, fija el título de la sesión a partir del
      // texto dictado (igual que el envío por teclado).
      onBeforeSend: _persistAutoTitleIfNeeded,
    );
    if (!mounted) return;
    debugPrint(
      '[VOICE-PERF] voice.overlay.entered_ms=${perf.elapsedMilliseconds}',
    );
  }

  Future<bool> _resumeActiveVoiceSessionIfAny(HermesAppState app) async {
    _attachVoiceSurface(app);
    final vc = _vc;
    if (vc == null || !vc.active) return false;
    if (vc.ownsChat(_chat)) {
      vc.resumeOverlay();
    } else {
      await _returnToActiveVoiceSession();
    }
    return true;
  }

  Future<void> _returnToActiveVoiceSession() async {
    final voice = _vc;
    final owner = voice?.ownerChat;
    if (voice == null || owner == null || !mounted) return;
    if (identical(owner, _chat)) {
      voice.resumeOverlay();
      return;
    }
    voice.resumeOverlay();
    final session = Session(
      id: owner.sessionId,
      title: owner.sessionTitle,
      model: '',
      source: 'mobile',
      messageCount: owner.messages.length,
      isActive: owner.isStreaming,
      preview: '',
      startedAt: 0,
      lineageRootId: owner.logicalSessionId,
      profile: owner.sessionProfile,
    );
    await openChatFromHome<void>(
      context,
      builder: (_) =>
          ChatScreen(connection: owner.connection, session: session),
    );
  }

  /// Proyección móvil de Voz: Blobatar, una línea causal y controles mínimos.
  /// Nunca pinta el transcript del usuario ni la respuesta final completa.
  Widget _voiceConversationSurface() {
    // La llamada está gated por `_voiceForThisSession`. Durante el teardown
    // puede existir un único frame sin superficie: se oculta en vez de volver
    // a montar la UI Jarvis retirada.
    if (_vc == null) return const SizedBox.shrink();
    final vc = _vc!;
    final phase = vc.phase;
    final strings = Strings.of(context);
    final phaseLabel = switch (phase) {
      VoicePhase.listening => strings.chaVoiceListeningLabel,
      VoicePhase.transcribing => strings.chaVoiceTranscribingLabel,
      VoicePhase.thinking => strings.chaVoiceThinkingLabel,
      VoicePhase.speaking => strings.chaVoiceSpeakingLabel,
      VoicePhase.toolCall => switch (voiceToolActivity(vc.activeTool ?? '')) {
        VoiceToolActivity.search => strings.chaVoicePhaseSearching,
        VoiceToolActivity.browse => strings.chaVoicePhaseBrowsing,
        VoiceToolActivity.read => strings.chaVoicePhaseReviewing,
        VoiceToolActivity.write => strings.chaVoicePhaseWriting,
        VoiceToolActivity.execute => strings.chaVoicePhaseExecuting,
        VoiceToolActivity.install ||
        VoiceToolActivity.remove => strings.chaVoicePhaseApplying,
        VoiceToolActivity.coordinate => strings.chaVoicePhaseCoordinating,
        VoiceToolActivity.check => strings.chaVoicePhaseChecking,
        null => strings.chaVoicePhaseWorking,
      },
      VoicePhase.waitingPermission => strings.chaVoiceWaitingLabel,
      VoicePhase.idle => strings.chaVoiceIdleLabel,
    };
    final stageState = vc.note != null && phase == VoicePhase.idle
        ? VoiceStageState.error
        : vc.userPaused
        ? VoiceStageState.paused
        : switch (phase) {
            VoicePhase.listening => VoiceStageState.listening,
            VoicePhase.transcribing => VoiceStageState.transcribing,
            VoicePhase.thinking => VoiceStageState.thinking,
            VoicePhase.toolCall => VoiceStageState.toolCall,
            VoicePhase.speaking => VoiceStageState.speaking,
            VoicePhase.waitingPermission => VoiceStageState.waiting,
            VoicePhase.idle => VoiceStageState.loading,
          };
    final safeNote = vc.note?.trim() ?? '';
    final label = voiceActivityLineLabel(
      // User pause clears `note`; automatic safety pauses keep a fixed local
      // explanation and must not collapse into the ambiguous “Paused”.
      paused: vc.userPaused && safeNote.isEmpty,
      pausedLabel: strings.chaVoicePausedLabel,
      publicCommentary: vc.publicCommentary,
      fallbackLabel: safeNote.isEmpty ? phaseLabel : safeNote,
    );
    final voiceProfile = widget.missionBotProfile;
    final profileName = voiceProfile?.name.trim().isNotEmpty == true
        ? voiceProfile!.name
        : _effectiveSessionProfile;
    final configuredFace = voiceProfile?.botShape;
    final voiceFace = configuredFace == null
        ? null
        : HermesBlobatarFaceVisual.tryParse(
            shapeWire: configuredFace,
            profileName: profileName,
          );
    final fallbackFace = HermesBlobatarFaceVisual.tryParse(
      shapeWire: HermesBlobatarFaceVisual.buildWire()!,
      profileName: profileName,
    )!;
    return KeyedSubtree(
      key: const ValueKey('voice-conversation-surface'),
      child: VoiceStage(
        state: stageState,
        statusLabel: label,
        faceVisual: voiceFace ?? fallbackFace,
        labels: VoiceStageLabels(
          finishListening: strings.chaVoiceFinishListening,
          pause: strings.chaVoicePause,
          resume: strings.chaVoicePlay,
          stopAndTalk: strings.chaVoiceStopAndTalk,
          cancel: strings.chaVoiceCancelRun,
          retry: strings.chaVoiceRetry,
          review: strings.chaVoiceViewApproval,
          close: strings.chaVoiceExitTooltip,
        ),
        micLevel: phase == VoicePhase.listening ? _voice?.micLevel : null,
        onFinishListening: phase == VoicePhase.listening && vc.whisper
            ? vc.finishListening
            : null,
        onPause: phase == VoicePhase.waitingPermission
            ? null
            : vc.pauseConversation,
        onResume: vc.userPaused ? vc.playConversation : null,
        // Siempre disponible mientras el turno voz está activo (thinking,
        // toolCall o speaking): con el monitor full-duplex armado el gesto
        // manual sigue siendo útil como respaldo y `stopAndTalk` es
        // idempotente (requestManualInterruptionCapture ya desarma el barge-in
        // y drena el TTS antes de abrir la captura manual).
        onStopAndTalk: vc.stopAndTalk,
        onCancel: vc.backendActive ? vc.cancelBackend : null,
        onRetry: stageState == VoiceStageState.error ? vc.retry : null,
        onReview: phase == VoicePhase.waitingPermission
            ? () {
                vc.pauseForApproval();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _scrollToBottom();
                });
              }
            : null,
        // Terminar es distinto de minimizar: la flecha del AppBar conserva la
        // conversación; este control explícito sí libera STT/TTS.
        onClose: () => unawaited(vc.exit()),
      ),
    );
  }

  Widget _buildVoiceReturnBar(
    HermesThemeColors colors, {
    required bool ownsCurrentChat,
  }) {
    final strings = Strings.of(context);
    final ownerTitle = _vc?.ownerChat?.sessionTitle.trim() ?? '';
    final label = ownsCurrentChat || ownerTitle.isEmpty
        ? strings.chaVoiceReturnOverlay
        : strings.chaVoiceActiveElsewhere(ownerTitle);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Material(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('voice-return-overlay'),
            onTap: ownsCurrentChat
                ? _vc?.resumeOverlay
                : () => unawaited(_returnToActiveVoiceSession()),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(Icons.mic_rounded, size: 20, color: colors.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      ownsCurrentChat
                          ? Icons.arrow_upward_rounded
                          : Icons.open_in_new_rounded,
                      size: 19,
                      color: colors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Estado de Stop respaldado por el ACK exacto del runtime.
  Widget _buildStopStatusStrip(HermesThemeColors colors) {
    final stop = _chat.stopConfirmationState;
    if (stop == StopConfirmationState.idle ||
        (_confirmedStopStatusVisible && _confirmedStopStatusDismissed)) {
      return const SizedBox.shrink();
    }
    final strings = Strings.of(context);
    final remainingBackgroundTasks = _chat.backgroundStopRemainingTasks;
    final backgroundStopWarning =
        remainingBackgroundTasks != null && remainingBackgroundTasks > 0;
    final label = _chat.backgroundStopVerificationInFlight
        ? strings.chaStopStopping
        : backgroundStopWarning
        ? strings.chaBackgroundWorkRemaining(remainingBackgroundTasks)
        : switch (stop) {
            StopConfirmationState.stopping => strings.chaStopStopping,
            StopConfirmationState.retrying => strings.chaStopRetrying,
            StopConfirmationState.confirmed =>
              _chat.stopConfirmationOnlyBackground
                  ? strings.chaBackgroundWorkStopped
                  : strings.chaStopConfirmed,
            StopConfirmationState.failed => strings.chaStopFailed,
            StopConfirmationState.idle => '',
          };
    final waiting =
        _chat.backgroundStopVerificationInFlight ||
        stop == StopConfirmationState.stopping ||
        stop == StopConfirmationState.retrying;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Semantics(
        liveRegion: true,
        label: label,
        child: Row(
          key: const ValueKey('chat-stop-status-strip'),
          children: [
            if (waiting)
              const SizedBox.square(
                key: ValueKey('chat-stop-status-icon'),
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else
              Icon(
                backgroundStopWarning
                    ? Icons.warning_amber_rounded
                    : stop == StopConfirmationState.failed
                    ? Icons.error_outline_rounded
                    : Icons.stop_circle_outlined,
                key: const ValueKey('chat-stop-status-icon'),
                size: 14,
                color: backgroundStopWarning
                    ? colors.warning
                    : stop == StopConfirmationState.failed
                    ? colors.error
                    : colors.textSecondary,
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
            if (stop == StopConfirmationState.failed && !backgroundStopWarning)
              TextButton(
                key: const ValueKey('chat-stop-retry'),
                onPressed: _cancelStream,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: Text(strings.chaStopRetry),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendGoalAction(String action) async {
    try {
      await _chat.sendGoalAction(action);
    } catch (_) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaGoalActionFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<void> _showGoalSheet(SessionGoalSnapshot goal) async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('chat-goal-dialog'),
      maxWidth: 560,
      builder: (sheetContext) {
        Widget section(String title, String body) {
          if (body.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body),
              ],
            ),
          );
        }

        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            Text(
              goal.title.isEmpty ? s.chaGoalSheetTitle : goal.title,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            section(s.chaGoalSheetOutcome, goal.outcome),
            section(s.chaGoalSheetVerification, goal.verification),
            section(s.chaGoalSheetConstraints, goal.constraints),
            section(s.chaGoalSheetBoundaries, goal.boundaries),
            section(s.chaGoalSheetStopWhen, goal.stopWhen),
            if (goal.subgoals.isNotEmpty)
              section(s.chaGoalSheetSubgoals, goal.subgoals.join('\n')),
            if (goal.gates.isNotEmpty)
              section(
                s.chaGoalSheetGates,
                goal.gates
                    .map(
                      (g) =>
                          '${g.command} (${g.attempts}/${g.maxRetries + 1}'
                          '${g.lastExitCode == null ? '' : ', exit ${g.lastExitCode}'})',
                    )
                    .join('\n'),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (goal.isActive)
                  OutlinedButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_sendGoalAction('goal.pause'));
                    },
                    child: Text(s.chaGoalActionPause),
                  ),
                if (goal.isPaused)
                  OutlinedButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_sendGoalAction('goal.resume'));
                    },
                    child: Text(s.chaGoalActionResume),
                  ),
                if (goal.isWaiting)
                  OutlinedButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_sendGoalAction('goal.unwait'));
                    },
                    child: Text(s.chaGoalActionResumeNow),
                  ),
                if (!goal.isDone)
                  TextButton(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: sheetContext,
                        builder: (dialogContext) => AlertDialog(
                          title: Text(s.chaGoalClearConfirmTitle),
                          content: Text(s.chaGoalClearConfirmBody),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              child: Text(
                                MaterialLocalizations.of(
                                  dialogContext,
                                ).cancelButtonLabel,
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(true),
                              child: Text(s.chaGoalActionClear),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                        unawaited(_sendGoalAction('goal.clear'));
                      }
                    },
                    child: Text(s.chaGoalActionClear),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Resultado de una tarea de `prompt.background` (Agent Center). Una sola
  /// línea, sin `ListTile` ni chevron — tocar abre el texto completo, la X
  /// descarta sin verlo. Si hay más de una pendiente, se muestra la más
  /// reciente con un contador; las demás esperan su turno.
  Widget _buildBackgroundTaskStrip(HermesThemeColors colors) {
    final outcomes = _chat.backgroundTaskOutcomes;
    if (outcomes.isEmpty) return const SizedBox.shrink();
    final s = Strings.of(context);
    final taskId = outcomes.keys.last;
    final outcome = outcomes[taskId]!;
    final extra = outcomes.length - 1;
    final label = extra > 0
        ? '${outcome.isError ? s.chaBackgroundTaskErrorShort : s.chaBackgroundTaskDoneShort} (+$extra)'
        : (outcome.isError
              ? s.chaBackgroundTaskErrorShort
              : s.chaBackgroundTaskDoneShort);
    final color = outcome.isError ? colors.error : colors.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
      child: Semantics(
        liveRegion: true,
        label: label,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            children: [
              Icon(
                outcome.isError
                    ? Icons.error_outline_rounded
                    : Icons.task_alt_rounded,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () =>
                      unawaited(_showBackgroundTaskResult(taskId, outcome)),
                  child: Text(
                    label,
                    key: const ValueKey('chat-background-primary-label'),
                    maxLines: 1,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: color),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                iconSize: 16,
                // Objetivo táctil real de 44dp aunque el icono visible sea de
                // 16dp: `BoxConstraints()` vacío colapsaba el hit-test al
                // tamaño del icono, justo al lado del composer.
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                tooltip: s.inAppDismiss,
                onPressed: () => _chat.dismissBackgroundTaskOutcome(taskId),
                icon: Icon(Icons.close_rounded, color: colors.textDisabled),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showBackgroundTaskResult(
    String taskId,
    ({String text, bool isError}) outcome,
  ) async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('chat-background-task-result'),
      maxWidth: 560,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              outcome.isError
                  ? s.chaBackgroundTaskError
                  : s.chaBackgroundTaskDone,
              style: Theme.of(sheetContext).textTheme.titleSmall?.copyWith(
                color: outcome.isError ? colors.error : colors.accent,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              outcome.text,
              style: Theme.of(sheetContext).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
    _chat.dismissBackgroundTaskOutcome(taskId);
  }

  /// composer, no como burbujas apiladas, y pueden cancelarse antes de enviarse.
  Widget _buildQueueStrip(HermesThemeColors colors) {
    final queuedEntries = _chat.queuedEntries;
    final queuedCount = queuedEntries.length;
    if (queuedCount == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _queueExpanded,
            child: InkWell(
              key: const ValueKey('chat-queue-toggle'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _queueExpanded = !_queueExpanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 14,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      _chat.queueParked
                          ? Strings.of(
                              context,
                            ).chaQueuedPausedCount(queuedCount)
                          : Strings.of(context).chaQueuedCount(queuedCount),
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _chat.queueParked
                            ? Strings.of(context).chaQueueParkedNote
                            : Strings.of(context).chaQueuedNote,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.textDisabled,
                        ),
                      ),
                    ),
                    Icon(
                      _queueExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: colors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_chat.queueParked)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('chat-queue-resume'),
                onPressed: _chat.resumeParkedQueue,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(Strings.of(context).chaQueueResume),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ),
          if (_queueExpanded) ...[
            Divider(
              height: 1,
              thickness: 0.5,
              color: colors.divider.withValues(alpha: 0.38),
            ),
            for (var i = 0; i < queuedEntries.length; i++) ...[
              _QueuedRow(
                entry: queuedEntries[i],
                attachmentNames: queuedEntries[i].attachments
                    .map((item) => item.name)
                    .toList(growable: false),
                busy: _chat.isStreaming,
                transportCanSteer: _chat.canSteerLiveTurn,
                editingId: _editingQueuedEntryId,
                onEdit: () => unawaited(_editQueuedEntry(queuedEntries[i])),
                onSteer: () =>
                    unawaited(_steerQueuedEntry(queuedEntries[i].id)),
                onSendNow: () =>
                    unawaited(_chat.sendQueuedNow(queuedEntries[i].id)),
                onDelete: () => unawaited(
                  _chat.cancelQueuedByIdentity(queuedEntries[i].id),
                ),
              ),
              if (i != queuedEntries.length - 1)
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 23,
                  color: colors.divider.withValues(alpha: 0.26),
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildComposerDictationAction(
    HermesThemeColors colors, {
    required bool dictationInteractive,
  }) {
    if (_isRecording) {
      if (_transcribing) {
        return Semantics(
          key: const ValueKey('recording'),
          liveRegion: true,
          label: Strings.of(context).chaVoiceTranscribingLabel,
          child: SizedBox.square(
            key: const ValueKey('dictation-transcribing'),
            dimension: 48,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceVariant.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 36,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return Semantics(
        key: const ValueKey('recording'),
        button: true,
        label: Strings.of(context).chaStopDictationTooltip,
        child: SizedBox.square(
          key: const ValueKey('dictation-stop'),
          dimension: 48,
          child: Center(
            child: HermesTactileAction(
              icon: Icons.stop_rounded,
              iconSize: 17,
              semanticLabel: Strings.of(context).chaStopDictationTooltip,
              onPressed: _stopDictation,
              backgroundColor: colors.surfaceVariant.withValues(alpha: 0.9),
              foregroundColor: colors.textPrimary,
              size: 36,
            ),
          ),
        ),
      );
    }

    if (dictationInteractive) {
      return HermesTactileAction(
        key: const ValueKey('mic'),
        icon: Icons.mic_none_rounded,
        onPressed: _startDictation,
        semanticLabel: _textController.text.trim().isEmpty
            ? Strings.of(context).chaVoiceDictationTooltip
            : Strings.of(context).chaContinueDictationTooltip,
        backgroundColor: Colors.transparent,
        foregroundColor: colors.textPrimary,
        size: 44,
        iconSize: 25,
        visual: HermesTactileActionVisual.quiet,
      );
    }

    return const SizedBox.shrink(key: ValueKey('no-mic'));
  }

  Widget _buildDictationCancelAction(HermesThemeColors colors) {
    return SizedBox.square(
      key: const ValueKey('dictation-cancel'),
      dimension: 48,
      child: HermesTactileAction(
        icon: Icons.close_rounded,
        iconSize: 30,
        semanticLabel: Strings.of(context).chaCancel,
        onPressed: _dictationSendInFlight ? null : _cancelDictation,
        backgroundColor: Colors.transparent,
        foregroundColor: colors.textPrimary,
        size: 44,
        visual: HermesTactileActionVisual.quiet,
      ),
    );
  }

  Widget _buildDictationSendAction(HermesThemeColors colors) {
    final enabled =
        !_dictationSendInFlight &&
        (_dictationBase.trim().isNotEmpty ||
            _dictationPartial.trim().isNotEmpty);
    return SizedBox.square(
      key: const ValueKey('dictation-send'),
      dimension: 48,
      child: Center(
        child: HermesTactileAction(
          icon: Icons.arrow_upward_rounded,
          iconSize: 23,
          semanticLabel: Strings.of(context).chaSendTooltip,
          onPressed: enabled ? _sendDictation : null,
          backgroundColor: enabled
              ? Colors.white
              : colors.surfaceVariant.withValues(alpha: 0.72),
          foregroundColor: enabled ? Colors.black : colors.textDisabled,
          enabled: enabled,
          size: 42,
        ),
      ),
    );
  }

  Widget _buildComposerPrimaryAction(HermesThemeColors colors) {
    final showStop = _chat.canStopSessionWork && _nothingToSend;
    return AnimatedSwitcher(
      key: const ValueKey('composer-primary-action-switcher'),
      duration: _reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => AnimatedBuilder(
        animation: animation,
        child: FadeTransition(opacity: animation, child: child),
        builder: (context, child) => Transform.scale(
          scale: animation.value,
          transformHitTests: false,
          child: IgnorePointer(
            ignoring: animation.status == AnimationStatus.reverse,
            child: child,
          ),
        ),
      ),
      child:
          (kVoiceRuntimeEnabled &&
              _allowsDedicatedVoiceLaunch &&
              _nothingToSend &&
              !showStop &&
              !_composerSubmissionInFlight &&
              !_compressingSession &&
              !_isRecording)
          ? KeyedSubtree(
              key: const ValueKey('voice'),
              child: HermesTactileAction(
                icon: Icons.graphic_eq_rounded,
                semanticLabel: Strings.of(context).chaVoiceModeTooltip,
                onPressed: widget.connection.readOnly ? null : _enterVoiceMode,
                backgroundColor: colors.secondary,
                foregroundColor: colors.onAccent,
                enabled: !widget.connection.readOnly,
                size: 42,
                iconSize: 23,
              ),
            )
          : KeyedSubtree(
              key: ValueKey(showStop ? 'stop' : 'send'),
              child: _SendButton(
                // Sin lanzadera mientras compacta: la barra de compactación
                // sobre el compositor es la única señal viva.
                busy:
                    !showStop &&
                    !_compressingSession &&
                    (_composerSubmissionInFlight || _attachmentSubmitting),
                mode: showStop ? _SendMode.stop : _SendMode.send,
                enabled: showStop
                    ? _chat.gatewayConnected
                    : !_interactiveMessageRefreshPending &&
                          !_composerSubmissionInFlight &&
                          !_attachmentSubmitting &&
                          !_compressingSession &&
                          !_attachmentMutationInFlight &&
                          !_nothingToSend,
                onSend: _sendMessage,
                onQueue: _sending || _chat.hasAuthoritativePassiveRemoteActivity
                    ? () => _sendMessage(queueOnly: true)
                    : null,
                onStop: _cancelStream,
              ),
            ),
    );
  }

  Future<void> _checkRuntimeOwnership() async {
    if (_chat.ownershipRecheckInFlight || !_chat.ownershipRecheckAvailable) {
      return;
    }
    await _fetchMessages(passiveOnly: true);
    if (!mounted || !_chat.conflictReadOnly) return;
    await _chat.recheckRuntimeOwnership();
  }

  Widget _buildRuntimeOwnershipBanner() {
    final strings = Strings.of(context);
    final checking = _chat.ownershipRecheckInFlight;
    final colors = Theme.of(context).hermes;
    return Container(
      key: const ValueKey('chat-runtime-ownership-banner'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.chaRuntimeOwnershipTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            strings.chaRuntimeOwnershipMessage,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          TextButton(
            key: const ValueKey('chat-runtime-ownership-check'),
            onPressed: checking || !_chat.ownershipRecheckAvailable
                ? null
                : _checkRuntimeOwnership,
            child: Text(
              checking
                  ? strings.chaRuntimeOwnershipChecking
                  : strings.chaRuntimeOwnershipCheck,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    widget.performanceProbe?.composerBuilds++;
    final colors = Theme.of(context).hermes;
    if (widget.connection.readOnly) {
      // Mantiene la misma huella y superficie que el composer para no convertir
      // un estado persistente en una alerta separada del lugar al que afecta.
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
        color: colors.background,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HermesComposerSurface(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                unfocusedHorizontalInset: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          Strings.of(context).readOnlyNotice,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _buildFloatingStatusPill(colors),
            ],
          ),
        ),
      );
    }
    // Preparar el siguiente turno (texto, pegar o adjuntos) debe seguir siendo
    // posible mientras Hermes responde. Solo se cierra el `+` durante estados
    // locales que podrían mezclar el lote que se está enviando o subiendo.
    final attachmentInteractive =
        !_interactiveMessageRefreshPending &&
        !_composerSubmissionInFlight &&
        !_attachmentSubmitting &&
        !_compressingSession;
    // El dictado es otra forma de rellenar el mismo composer. Debe seguir
    // disponible mientras Hermes piensa o ejecuta herramientas; al enviarlo se
    // aplica la misma cola de siguiente turno que al texto escrito.
    final dictationInteractive =
        !_interactiveMessageRefreshPending &&
        !_attachmentSubmitting &&
        !_compressingSession;
    final slashPalette = !_slashPaletteVisible
        ? null
        // Part of the composer's tap region: picking a command (even with a
        // mouse) never blurs the field and hides the palette mid-tap.
        : TextFieldTapRegion(
            child: _SlashPalette(
              commands: _slashSuggestions,
              onPick: _pickSlash,
            ),
          );
    final floatingPalette =
        slashPalette ??
        (_isRecording || _transcribing || _navigationDrawerOpen
            ? null
            : ChatMentionPalette(
                controller: _textController,
                focusNode: _textFocusNode,
                connectionId: widget.connection.id,
                profile: _effectiveSessionProfile,
              ));
    // Composer premium (referencia live-chat): contenedor con borde sutil,
    // campo sin marco y fila inferior de acciones con send cuadrado ámbar.
    //
    // La lectura de `viewInsets`/orientación vive en un `Builder` propio: así
    // solo este subárbol se reconstruye con cada frame de la animación del
    // teclado, en vez de suscribir el State completo (y con él el transcript)
    // a `MediaQuery.of`.
    return Builder(
      builder: (imeContext) {
        // En horizontal el IME ocupa más de media pantalla. El composer normal
        // (campo de hasta cuatro líneas + fila de acciones + SafeArea) puede
        // quedar más alto que el viewport restante y provocar un RenderFlex
        // overflow.
        final compactIme =
            MediaQuery.viewInsetsOf(imeContext).bottom > 0 &&
            MediaQuery.orientationOf(imeContext) == Orientation.landscape;
        return Container(
          key: const ValueKey('chat-composer-host'),
          padding: compactIme
              ? const EdgeInsets.fromLTRB(12, 2, 12, 3)
              : const EdgeInsets.fromLTRB(14, 4, 14, 10),
          color: colors.background,
          child: SafeArea(
            bottom: !compactIme,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HermesComposerSurface(
                  focused: _textFocusNode.hasFocus,
                  unfocusedHorizontalInset: 12,
                  padding: compactIme
                      ? const EdgeInsets.symmetric(horizontal: 4)
                      : EdgeInsets.zero,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_pendingAttachments.isNotEmpty)
                        _AttachmentPreviewStrip(
                          key: const ValueKey('composer-attachment-preview'),
                          attachments: _pendingAttachments,
                          onRemove: (localId) =>
                              unawaited(_removePendingAttachment(localId)),
                          onRetry: (localId) =>
                              unawaited(_retryPendingAttachment(localId)),
                        ),
                      Row(
                        key: const ValueKey('composer-input-row'),
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (!_isRecording)
                            AttachmentSourceMenuButton(
                              key: const ValueKey('composer-add'),
                              semanticLabel: Strings.of(
                                context,
                              ).chaAttachTooltip,
                              onSelected: (source) =>
                                  unawaited(_selectAttachmentSource(source)),
                              enabled: attachmentInteractive,
                            ),
                          if (_isRecording) _buildDictationCancelAction(colors),
                          Expanded(
                            child: SizedBox(
                              height: _isRecording
                                  ? _dictationComposerHeight
                                  : null,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  ExcludeSemantics(
                                    excluding: _isRecording,
                                    child: CallbackShortcuts(
                                      bindings: {
                                        const SingleActivator(
                                          LogicalKeyboardKey.enter,
                                          control: true,
                                        ): _composerKeyboardSubmit,
                                        const SingleActivator(
                                          LogicalKeyboardKey.enter,
                                          meta: true,
                                        ): _composerKeyboardSubmit,
                                      },
                                      child: TextField(
                                        controller: _textController,
                                        focusNode: _textFocusNode,
                                        style: _isRecording
                                            ? const TextStyle(
                                                color: Colors.transparent,
                                              )
                                            : null,
                                        cursorColor: _isRecording
                                            ? Colors.transparent
                                            : null,
                                        decoration: InputDecoration(
                                          hintText: _attachmentSubmitting
                                              ? Strings.of(
                                                  context,
                                                ).chaUploadingAttachment
                                              : _pendingAttachments.isNotEmpty
                                              ? Strings.of(
                                                  context,
                                                ).chaHintSystem
                                              : Strings.of(context).chaHintUser,
                                          hintStyle: TextStyle(
                                            color: _isRecording
                                                ? Colors.transparent
                                                : colors.textSecondary,
                                            fontSize: 14,
                                          ),
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          disabledBorder: InputBorder.none,
                                          contentPadding: EdgeInsets.fromLTRB(
                                            4,
                                            compactIme ? 10 : 12,
                                            4,
                                            _isRecording
                                                ? _dictationWaveHeight + 8
                                                : (compactIme ? 10 : 12),
                                          ),
                                          isDense: true,
                                        ),
                                        minLines: 1,
                                        maxLines: compactIme ? 2 : 4,
                                        textCapitalization:
                                            TextCapitalization.sentences,
                                        keyboardType: TextInputType.multiline,
                                        contentInsertionConfiguration:
                                            ContentInsertionConfiguration(
                                              allowedMimeTypes: const [
                                                'image/png',
                                                'image/jpeg',
                                                'image/gif',
                                                'image/webp',
                                              ],
                                              onContentInserted: (content) =>
                                                  unawaited(
                                                    _insertKeyboardContent(
                                                      content,
                                                    ),
                                                  ),
                                            ),
                                        textInputAction:
                                            TextInputAction.newline,
                                        // A retained invocation may keep focus without
                                        // authorizing edits or a second submission.
                                        readOnly: _compressingSession,
                                        // El usuario puede preparar texto y abrir el
                                        // teclado mientras el transcript interactivo
                                        // termina de publicar. El envío se mantiene
                                        // bloqueado abajo hasta entonces; adjuntar y
                                        // dictar siguen cerrados porque mezclarían el
                                        // lote en vuelo.
                                        enabled:
                                            !_attachmentSubmitting &&
                                            (!_compressingSession ||
                                                _compressionDraftFocusRetained),
                                      ),
                                    ),
                                  ),
                                  if (_isRecording && _voice != null)
                                    SizedBox(
                                      key: const ValueKey(
                                        'dictation-recording-area',
                                      ),
                                      height: _dictationComposerHeight,
                                      child: Center(
                                        child: IgnorePointer(
                                          child: _DictationVisualizer(
                                            key: const ValueKey(
                                              'dictation-visualizer',
                                            ),
                                            level: _voice!.micLevel,
                                            color: colors.textSecondary,
                                            mutedColor: colors.textDisabled,
                                            transcribing: _transcribing,
                                            listeningLabel: Strings.of(
                                              context,
                                            ).chaVoiceListeningLabel,
                                            transcribingLabel: Strings.of(
                                              context,
                                            ).chaVoiceTranscribingLabel,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          _buildComposerDictationAction(
                            colors,
                            dictationInteractive: dictationInteractive,
                          ),
                          if (_isRecording) _buildDictationSendAction(colors),
                          if (!_isRecording) ...[
                            const SizedBox(width: 2),
                            SizedBox.square(
                              dimension: 48,
                              child: Center(
                                child: _buildComposerPrimaryAction(colors),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                )._withComposerPalette(floatingPalette),
                _buildFloatingStatusPill(colors),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Pastilla de compactación: vive en la pila flotante del transcript, justo
  /// encima del composer, así que el transcript reserva su alto medido y
  /// nunca tapa el último mensaje ni el composer. Entra y sale con un fundido.
  Widget _buildCompactionPill() {
    final compaction =
        _compaction.current ??
        (_compressingSession || _chat.desktopRestoredCompressionRunning
            ? CompactionProgress(
                startedAt: _chat.desktopCompactionStartedAt ?? DateTime.now(),
                manual: true,
                messagesBefore: _chat.desktopCompactionMessagesBefore,
                tokensBefore: _chat.desktopCompactionTokensBefore,
              )
            : null);
    return AnimatedSwitcher(
      duration: _reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.bottomCenter,
        children: [...previous, ?current],
      ),
      child: compaction == null
          ? const SizedBox.shrink(key: ValueKey('compaction-pill-empty'))
          // One key for live and done: the pill morphs in place (no
          // cross-fade between two pills); only appearing/leaving animates.
          : Padding(
              key: const ValueKey('compaction-pill'),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: AnimatedSize(
                duration: _reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: CompactionDock(compaction: compaction),
              ),
            ),
    );
  }

  /// Píldora combinada contexto+modo flotando bajo el composer (ver mockup
  /// aprobado "v8 · estado debajo del input"): sustituye a los antiguos
  /// `_buildModeBadge` + `SessionContextPopoverButton` de la AppBar. Oculta
  /// en Bot Chat, igual que ocultaban esos widgets antes.
  /// Sigue abriendo el mismo `showSessionContextPopover`; la sección de modo
  /// se reutiliza de `_buildApprovalModeSection` en vez de duplicarla.
  Widget _buildFloatingStatusPill(HermesThemeColors colors) {
    if (_isBotChatSurface) {
      return const SizedBox.shrink();
    }
    final flag = _modeFlag(colors);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: SessionContextPopoverButton(
          key: const ValueKey('chat-status-pill'),
          metrics: _sessionContextMetrics,
          loadBreakdown: _loadSessionContextDetails,
          onMetricsSnapshot: (metrics) {
            if (_disposed || !mounted) return;
            _commitSessionContextMetrics(metrics);
          },
          modeLabel: flag?.$1,
          modeColor: flag?.$2,
          modeSectionBuilder: _buildApprovalModeSection,
          compressionCount: _chatBound
              ? _chat.desktopSessionCompressionCount
              : 0,
        ),
      ),
    );
  }

  Widget _buildBody() => KeyedSubtree(
    key: const ValueKey('chat-stable-body'),
    child: _buildBodyContent(),
  );

  Widget _buildBodyContent() {
    final colors = Theme.of(context).hermes;
    if (_messages.isEmpty &&
        (_interactiveMessageRefreshPending || !_chat.messagesLoaded) &&
        _error == null) {
      // Estado de carga con la mascota (006): si la presencia está activa, el
      // Companion "piensa" mientras carga; si está apagada, cae al spinner.
      final app = context.findAncestorStateOfType<HermesAppState>();
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CompanionStatusIndicator(
              companion: app?.companion,
              mood: HermesSparkMood.thinking,
              size: 88,
            ),
            const SizedBox(height: 14),
            Text(
              Strings.of(context).commonLoading,
              style: TextStyle(color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_error != null && _messages.isEmpty) {
      // A-201 (spec 028): estado de error según la plantilla §14 del design
      // system — card `error` alpha 0.08 con borde 0.3, mensaje conciso en
      // español y reintento con HermesSecondaryButton. La excepción cruda
      // queda solo en el detalle plegado.
      final str = Strings.of(context);
      final kind = classifyChatError(_error!);
      final kindLabel = switch (kind) {
        ChatErrorKind.connection => str.chaErrConnection,
        ChatErrorKind.model => str.chaErrModel,
        ChatErrorKind.tool => str.chaErrTool,
        ChatErrorKind.local => str.chaErrLocal,
        ChatErrorKind.localColdStart => str.chaErrLocalColdStart,
        ChatErrorKind.firstTokenTimeout => str.chaErrFirstTokenTimeout,
        ChatErrorKind.searchToolUnavailable => str.chaErrSearchToolUnavailable,
        ChatErrorKind.sessionTooLarge => str.chaErrSessionTooLarge,
        ChatErrorKind.unknown => str.chaErrUnknown,
      };
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            decoration: BoxDecoration(
              color: colors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.error.withValues(alpha: 0.3)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 32, color: colors.error),
                const SizedBox(height: 12),
                Text(
                  str.chaMessagesError,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  kindLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: colors.textSecondary,
                  ),
                ),
                if (_showErrorDetail) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.4,
                      fontFamily: 'monospace',
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                HermesSecondaryButton(
                  icon: Icons.refresh_rounded,
                  label: str.chaRetry,
                  color: colors.error,
                  onTap: _fetchMessages,
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _showErrorDetail = !_showErrorDetail),
                  child: Text(
                    _showErrorDetail
                        ? str.chaErrHideDetails
                        : str.chaErrViewDetails,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_messages.isEmpty) {
      return KeyedSubtree(
        key: const ValueKey('chat-empty-state'),
        child: _EmptyChatState(model: _activeModelLabel, agentName: _agentName),
      );
    }

    final entries = _currentListEntries;
    pruneMessageAnchorCache(_messageAnchors, _messages);

    final transcript = ListenableBuilder(
      listenable: Listenable.merge([
        _activityPillExtent,
        _scrollToBottomVisibility,
      ]),
      builder: (context, _) {
        final overlayExtent =
            _activityPillExtent.value +
            (_scrollToBottomVisibility.value ? 48 : 0);
        return ChatScrollInteractionGuard(
          onPointerDown: _pauseStreamingFollow,
          onPointerMove: _trackStreamingScrollInteraction,
          onPointerUp: _finishStreamingScrollInteraction,
          onPointerCancel: _cancelStreamingScrollInteraction,
          child: ListView.builder(
            controller: _scrollController,
            // En `reverse:true` el asistente vivo crece por debajo del contenido
            // que el lector está mirando. Conservar el mismo offset numérico hace
            // que ese contenido suba una línea por cada reflow. Mientras el usuario
            // haya pausado el seguimiento, compensa el cambio de extensión dentro
            // del propio layout del viewport: no cancela el drag ni ejecuta saltos
            // tardíos que compitan con el dedo.
            physics: _ChatStreamingViewportPhysics(
              lock: _streamingViewportLock,
            ),
            // Deja aire real bajo la última respuesta. Con solo 4 dp el cierre del
            // texto quedaba pegado al compositor y parecía visualmente recortado.
            // `bottom` reserva la altura medida de toda la pila flotante y de la
            // flecha cuando está visible. Así ninguna fila tapa el último mensaje,
            // aunque cambie de alto o convivan varias actividades.
            padding: EdgeInsets.only(bottom: 12 + overlayExtent),
            reverse: true,
            // Precarga ~1 pantalla extra fuera del viewport: al seguir el stream no
            // se materializan entradas frías en medio de un frame de scroll.
            scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
            itemCount: entries.length,
            // Una selección que sale del viewport no debe retener el RenderObject
            // (y con él todo un árbol Markdown) indefinidamente. Copiar el mensaje
            // completo sigue disponible en su cabecera y la selección visible se
            // mantiene dentro de cada bloque virtualizado.
            addAutomaticKeepAlives: false,
            // No usar GlobalKey por índice: un rewind cambia los slots de golpe y
            // reparentar un árbol todavía dependiente del diálogo puede disparar
            // `_dependents.isEmpty` en Flutter. Las anclas de respuesta son
            // RenderObjects ligeros que no reutilizan el árbol Markdown.
            itemBuilder: (context, index) {
              final entry = entries[index];
              if (entry is _RetainedTerminalErrorChatListEntry) {
                return _buildRetainedTerminalErrorEntry(entry);
              }
              final plan = entry.sourcePlan;
              final assistantSlice = entry is _AssistantSliceChatListEntry
                  ? entry.slice
                  : null;
              final sourceMessages = _sourceMessagesForRenderPlan(plan);
              final reportsPreservedTurnInsertion = sourceMessages.any(
                _readerPreservedTurnInsertions.contains,
              );
              final unit = _materializeRenderUnit(plan);
              final child = _buildRenderUnit(
                unit,
                assistantSlice: assistantSlice,
              );
              final assistantMessage =
                  unit is Map<String, dynamic> &&
                      unit['role'] == 'assistant' &&
                      unit['_pipeline'] != true
                  ? unit
                  : null;
              final ownsAnchor = assistantSlice?.showHeader ?? true;
              Widget result = child;
              if (ownsAnchor) {
                result = ChatAnswerAnchor(
                  onLayout: (anchor) {
                    for (final message in sourceMessages) {
                      _messageAnchors[message] = anchor;
                    }
                  },
                  onDetach: (anchor) {
                    for (final message in sourceMessages) {
                      if (identical(_messageAnchors[message], anchor)) {
                        _messageAnchors.remove(message);
                      }
                    }
                  },
                  child: child,
                );
              }
              if (assistantSlice != null && assistantMessage != null) {
                result = KeyedSubtree(
                  key: ValueKey((assistantMessage, assistantSlice.index)),
                  child: result,
                );
              }
              // Entrada suave del mensaje NUEVO: solo el más reciente (índice 0, la
              // lista es reverse). El turno que esta superficie ya presentó queda
              // fuera: su host crece por streaming y un translate adicional de 8 px
              // se percibe como un pequeño tirón si el usuario empieza a leer o
              // arrastrar. La guarda sobrevive al terminal para que cancelación,
              // error o una reconciliación tardía tampoco animen de nuevo la fila.
              final key = _entranceKey(unit);
              final belongsToSurfaceTurn =
                  _surfaceTurnSerial == _assistantEntranceSerial &&
                  (_chat.isStreaming || _surfaceTurnTerminal);
              if (index == 0 && key != null && !belongsToSurfaceTurn) {
                result = MotionEntrance(
                  key: ValueKey<Object>(key),
                  child: result,
                );
              }
              if (reportsPreservedTurnInsertion) {
                result = _SurfaceTurnInitialExtentReporter(
                  onInitialExtent: _streamingViewportLock.record,
                  child: result,
                );
              }
              // Cada mensaje repinta en su propia capa: el host vivo a 30 Hz (y el
              // reveal gradual) no invalida la rasterización del historial visible.
              // El host vivo/retenido queda fuera: su geometría la mide el lock del
              // viewport y una capa intermedia rompe esa medición.
              final keepsLiveHost =
                  assistantMessage != null &&
                  _messageKeepsLiveHost(assistantMessage);
              final isLiveHead =
                  _chat.isStreaming &&
                  _messages.isNotEmpty &&
                  identical(unit, _messages.first);
              if (!keepsLiveHost && !isLiveHead) {
                result = RepaintBoundary(child: result);
              }
              final durableEntryIds = sourceMessages
                  .map((message) {
                    final messageId = canonicalTranscriptMessageId(message);
                    if (messageId != null) return 'message:$messageId';
                    final rowId = canonicalTranscriptRowId(message);
                    return rowId == null ? null : 'row:$rowId';
                  })
                  .whereType<String>()
                  .toList(growable: false);
              if (durableEntryIds.length == sourceMessages.length) {
                // This must remain the outermost list child. Sliver reconciliation
                // can then retain the complete bubble subtree even when refresh
                // replaces its source Map or runtime presentation wrappers change.
                result = KeyedSubtree(
                  key: ValueKey<Object>((
                    'chat-render-entry',
                    durableEntryIds.join('\u0000'),
                    assistantSlice?.index,
                  )),
                  child: result,
                );
              }
              return result;
            },
          ),
        );
      },
    );
    return ChatRefreshStatusOverlay(
      loading: _interactiveMessageRefreshPending,
      errorMessage: _error == null
          ? null
          : Strings.of(context).chaMessagesError,
      // Bajo el botón «cargar anteriores» (8 + 48 + 8) cuando está a la vista.
      errorTopInset: _chat.hasEarlierMessages ? 64 : 8,
      child: transcript,
    );
  }

  Widget _buildRetainedTerminalErrorEntry(
    _RetainedTerminalErrorChatListEntry entry,
  ) {
    final assistant = _messages[entry.assistantPlan.messageIndex];
    final error = _messages[entry.errorPlan.messageIndex];
    final compact = _chatPreferences.density == TranscriptDensity.compact;
    final child = _wrapLiveAssistantViewport(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildLiveAssistantHost(compact: compact),
          _buildRenderUnit(error),
        ],
      ),
    );
    return ChatAnswerAnchor(
      onLayout: (anchor) => _messageAnchors[assistant] = anchor,
      onDetach: (anchor) {
        if (identical(_messageAnchors[assistant], anchor)) {
          _messageAnchors.remove(assistant);
        }
      },
      child: child,
    );
  }

  Object _materializeRenderUnit(ChatRenderUnitPlan plan) {
    switch (plan) {
      case ChatMessageUnitPlan(:final messageIndex):
        return _messages[messageIndex];
      case ChatUserTurnUnitPlan(
        :final primaryMessageIndex,
        :final supplementMessageIndexes,
      ):
        final group = _UserTurnGroup(_messages[primaryMessageIndex]);
        group.supplements.addAll(
          supplementMessageIndexes.map((index) => _messages[index]),
        );
        return group;
      case ChatToolActivityUnitPlan(:final events):
        return events;
    }
  }

  List<Map<String, dynamic>> _sourceMessagesForRenderPlan(
    ChatRenderUnitPlan plan,
  ) {
    final indexes = switch (plan) {
      ChatMessageUnitPlan(:final messageIndex) => [messageIndex],
      ChatUserTurnUnitPlan(
        :final primaryMessageIndex,
        :final supplementMessageIndexes,
      ) =>
        [primaryMessageIndex, ...supplementMessageIndexes],
      ChatToolActivityUnitPlan(:final messageIndexes) => messageIndexes,
    };
    return [for (final index in indexes) _messages[index]];
  }

  /// Stable key for the newest-row entrance. Durable transcript coordinates are
  /// preferred; identityless rows use bounded display fields. Map identity is
  /// never part of the key, so an identical passive refresh cannot remount the
  /// entrance animation or invalidate viewport anchors.
  Object? _entranceKey(Object unit) {
    final message = unit is _UserTurnGroup
        ? unit.primary
        : unit is Map<String, dynamic>
        ? unit
        : null;
    if (message == null || message['_pipeline'] == true) return null;
    final messageId = canonicalTranscriptMessageId(message);
    if (messageId != null) return ('message', messageId);
    final rowId = canonicalTranscriptRowId(message);
    if (rowId != null) return ('row', rowId);
    if (message['role'] == 'assistant') {
      return (widget.session.logicalId, _assistantEntranceSerial);
    }
    return (
      'idless',
      message['role']?.toString() ?? '',
      message['content']?.toString() ?? '',
      message['timestamp']?.toString() ?? '',
    );
  }

  bool get _turnWaitsForUser =>
      _chat.pendingApproval != null || _chat.pendingInteractivePrompt != null;

  HermesSparkMood _liveCompanionMood() {
    final transport = _chat.transportStatus.state;
    if (transport == ChatTransportState.offline ||
        transport == ChatTransportState.reconnecting) {
      return HermesSparkMood.offline;
    }
    if (_turnWaitsForUser) return HermesSparkMood.waiting;
    return switch (_pipelineState) {
      ChatPipelineState.connecting => HermesSparkMood.connecting,
      ChatPipelineState.waiting => HermesSparkMood.waiting,
      _ => HermesSparkMood.thinking,
    };
  }

  Widget _buildActiveThinkingState() {
    // La compresión no es actividad del modelo. Mostrar a la vez esta tarjeta,
    // el estado del composer y el uso de contexto hacía que una operación
    // indeterminada pareciese bloqueada. El composer conserva el único estado
    // vivo hasta que Desktop reconcilia el transcript.
    if (_compressingSession) return const SizedBox.shrink();
    return ValueListenableBuilder<ChatTransportStatus>(
      valueListenable: _chat.transportStatusListenable,
      builder: (context, _, _) {
        final mood = _liveCompanionMood();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [_AssistantLiveHeader(agentName: _agentName, mood: mood)],
        );
      },
    );
  }

  Widget _buildRenderUnit(
    Object unit, {
    _AssistantRenderSlice? assistantSlice,
  }) {
    final compact = _chatPreferences.density == TranscriptDensity.compact;
    // Grupo de actividad: TODAS las llamadas/resultados/aprobaciones de un
    // tramo consecutivo en un solo desplegable colapsado.
    if (unit is List<ChatEventInfo>) {
      return ToolActivityGroup(events: unit);
    }

    // Las indicaciones enviadas durante el turno pertenecen visualmente a la
    // petición que ya estaba ejecutándose. Se presentan dentro de una única
    // burbuja compacta en lugar de apilar mensajes de usuario independientes.
    if (unit is _UserTurnGroup) {
      final rawContent = (unit.primary['content'] as String?) ?? '';
      final content = projectedUserVisibleContent(unit.primary);
      final systemChip = _jobChipLabel(content);
      if (systemChip != null && unit.supplements.isEmpty) {
        return _SystemBlobChip(label: systemChip, raw: content);
      }
      final parsedContent = _parseUserContent(content);
      final supplements = unit.supplements
          .map(projectedUserVisibleContent)
          .where((text) => text.trim().isNotEmpty)
          .toList();
      if (parsedContent.text.trim().isEmpty &&
          parsedContent.attachments.isEmpty &&
          supplements.isEmpty) {
        return const SizedBox.shrink();
      }
      return _UserMessage(
        content: content,
        verbose: _devDiagnostics,
        metadata: unit.primary,
        compact: compact,
        supplements: supplements,
        onEdit:
            content == rawContent &&
                unit.supplements.isEmpty &&
                _canEditUserMessage(unit.primary)
            ? (bubbleWidth) => _editUserMessage(unit.primary, bubbleWidth)
            : null,
        editing: identical(unit.primary, _editingUserMessageTarget),
        editingText: _editingUserMessageText,
        editingWidth: _editingUserMessageWidth,
        editSaving: _editingRewriteSubmitted,
        onCancelEdit: _cancelUserMessageEdit,
        onSaveEdit: (text) => unawaited(_saveUserMessageEdit(text)),
      );
    }

    final msg = unit as Map<String, dynamic>;
    final role = (msg['role'] as String?) ?? 'assistant';
    var content = (msg['content'] as String?) ?? '';
    final sourceContent = content;
    // Un turno que primero piensa/llama herramientas y luego responde llega en
    // varias filas del servidor: la fila solo-traza se funde en el desplegable
    // de la respuesta que la sigue (una cabecera, un «Completado ⌄»).
    final traceMerge = role == 'assistant' ? _traceMergeFor(msg) : null;
    if (traceMerge?.hidden ?? false) return const SizedBox.shrink();
    final metadataMsg = traceMerge?.merged ?? msg;

    final historicalSubagents = historicalSubagentCompletionOf(msg);
    if (historicalSubagents != null) {
      return Padding(
        key: ValueKey<String>(
          'subagent-completion-${historicalSubagents.completionKey}',
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: SubagentCompletionCard(data: historicalSubagents),
      );
    }

    final timelineEvent = _timelineSystemEventPresentation(context, msg);
    if (timelineEvent != null) {
      return _TimelineSystemEventRow(
        title: timelineEvent.title,
        detail: timelineEvent.detail,
        icon: timelineEvent.icon,
        raw: content,
        titleMaxLines: msg['display_kind'] == 'process_complete' ? 2 : null,
      );
    }

    // Blob de SISTEMA (preámbulo de cron/skill o resumen de compactación) en
    // CUALQUIER rol: el de compactación a veces llega como role=assistant (no
    // user), por eso no bastaba con el chip de _UserMessage. Se muestra un chip
    // limpio en vez del muro de texto.
    final systemChip = _jobChipLabel(content);
    if (systemChip != null) {
      return _SystemBlobChip(label: systemChip, raw: content);
    }

    // Error bubble with retry
    if (role == 'assistant_error') {
      final prompt = (msg['_prompt'] as String?) ?? _lastPrompt;
      return _ErrorBubble(
        error: activeChatStoredErrorUiMessage(content),
        onRetry: _chat.conflictReadOnly
            ? null
            : () => unawaited(_retryLastPrompt(prompt)),
        prompt: prompt,
        onRestartGateway: _restartGatewayFromChat,
        onNewSession: _chat.conflictReadOnly ? null : _newChat,
      );
    }

    final isPipeline = msg['_pipeline'] == true;
    final hasUnifiedActivity =
        normalizeAssistantActivityTrace(
          msg[assistantActivityTraceKey],
        ).isNotEmpty ||
        (msg['reasoning'] is String &&
            (msg['reasoning'] as String).trim().isNotEmpty);
    final isCancelled = msg['_cancelled'] == true;
    // El mensaje en curso es el más nuevo (índice 0) mientras hay streaming.
    // Solo en él aplicamos el normalizador visual de Markdown incompleto.
    final isStreaming =
        _chat.isStreaming &&
        role == 'assistant' &&
        _messages.isNotEmpty &&
        identical(unit, _messages.first);

    final messageKeepsLiveHost =
        role == 'assistant' &&
        _messageKeepsLiveHost(unit) &&
        _liveAssistantFrame.value != null;
    if ((isStreaming || messageKeepsLiveHost) && _liveAssistantMaterialized) {
      return _wrapLiveAssistantViewport(
        _buildLiveAssistantHost(compact: compact),
      );
    }

    // El revelado gradual solo recorta el frame visual mientras seguimos el
    // fondo. Al pausar el seguimiento se pinta siempre todo lo ya recibido:
    // hacer scroll o pulsar la flecha nunca puede borrar/restaurar texto.
    if (isStreaming &&
        _autoFollowStreaming &&
        !_reduceMotion &&
        _revealedChars < content.length) {
      content = content.substring(0, _revealedChars);
    }

    // Placeholder del turno activo: la ThinkingTraceCard en vivo agrega el
    // progreso del turno en curso (los eventos reales se agruparán al
    // refrescar tras completar).
    if (role == 'assistant' &&
        isPipeline &&
        content.trim().isEmpty &&
        !hasUnifiedActivity) {
      // Un placeholder interno puede sobrevivir a una reconciliación tardía.
      // Nunca lo proyectamos como actividad si ya no es la cabeza viva del
      // chat: _trace pertenece al turno actual, no al mensaje histórico.
      if (!_chat.isStreaming ||
          _messages.isEmpty ||
          !identical(unit, _messages.first)) {
        return const SizedBox.shrink();
      }
      return _buildActiveThinkingState();
    }

    final operationalProjection = role == 'assistant'
        ? _projectOperationalArtifacts(
            context,
            isStreaming ? content : sourceContent,
          )
        : AssistantOperationalProjection(visibleMarkdown: content);
    final displayContent = role == 'assistant'
        ? operationalProjection.visibleMarkdown
        : content;
    if (role == 'assistant' &&
        isStreaming &&
        displayContent.trim().isEmpty &&
        !hasUnifiedActivity) {
      return _buildActiveThinkingState();
    }
    // Los resúmenes de delegación son cortos y necesitan una proyección
    // editorial única para mantener el mapeo Subagente N estable. El resto de
    // mensajes conserva la virtualización habitual.
    final displaySlice = operationalProjection.hasTechnicalDetails
        ? null
        : assistantSlice;
    if (role == 'assistant' && !isStreaming && !isCancelled && !isPipeline) {
      final terminalAnswer = projectAssistantSuggestions(
        splitReasoning(displayContent).answer,
      ).body;
      _scheduleGeneratedArtifactIndex(msg, terminalAnswer);
    }
    final spokenAnswer = role == 'assistant'
        ? GeneratedMediaService.stripDirectives(
            displaySlice?.plan.split.answer ??
                splitReasoning(displayContent).answer,
          )
        : '';
    final readAloudMessageKey = role == 'assistant'
        ? _readAloudMessageKey(msg, spokenAnswer)
        : null;
    final suggestionsEnabled =
        role == 'assistant' &&
        canOfferAssistantSuggestions(
          isLatestAssistant: _isLatestAssistant(msg),
          isTerminal: !isStreaming && !isCancelled,
          chatBusy:
              _interactiveMessageRefreshPending ||
              _sending ||
              _attachmentSubmitting ||
              _compressingSession,
          writable: !widget.connection.readOnly,
          composerEmpty: _textController.text.trim().isEmpty,
          attachmentsEmpty: _pendingAttachments.isEmpty,
        );
    final terminalProjection = role == 'assistant'
        ? _terminalAssistantProjectionFor(
            content: displayContent,
            slice: displaySlice,
            suggestionsEnabled: suggestionsEnabled,
          )
        : null;
    // Nunca una burbuja vacía: una respuesta terminada sin texto visible, sin
    // medios y cuya traza no tiene nada que desplegar (solo herramientas puente
    // de Hermes, sin razonamiento ni tareas) no pinta ni siquiera la cabecera.
    if (role == 'assistant' &&
        !isStreaming &&
        !isCancelled &&
        !isPipeline &&
        msg['_stopped'] != true &&
        displayContent.trim().isEmpty &&
        operationalProjection.technicalDetails.isEmpty &&
        _structuredGeneratedImages(msg).isEmpty &&
        _structuredGeneratedVideos(msg).isEmpty &&
        !_assistantActivityEvents(context, msg, '').any(
          (event) =>
              event.kind == ChatTraceEventKind.reasoning ||
              !isInternalActivityLabel(event.label),
        ) &&
        !(msg['reasoning'] is String &&
            (msg['reasoning'] as String).trim().isNotEmpty)) {
      return const SizedBox.shrink();
    }
    if (role == 'assistant' && isCancelled && content.isNotEmpty) {
      // El parcial cancelado largo llega ya troceado (displaySlice): cada
      // slice pinta su parte y solo el cierre lleva la marca 'cancelled'.
      return _AssistantMessageWithMark(
        content: displayContent,
        mark: 'cancelled',
        verbose: _devDiagnostics,
        metadata: msg,
        linkCache: _linkCache,
        fetchLinkPreview: _fetchLinkPreview,
        firstUrl: _firstUrl,
        agentName: _agentName,
        slice: displaySlice,
        terminalProjection: terminalProjection,
        technicalDetails: operationalProjection.technicalDetails,
        onRegenerate: _isLatestAssistant(msg) ? _regenerateLastResponse : null,
      );
    }
    if (role == 'assistant') {
      widget.performanceProbe?.terminalAssistantBuilds++;
    }
    return _MessageBubble(
      content: displayContent,
      isUser: role == 'user',
      verbose: _devDiagnostics,
      metadata: metadataMsg,
      linkCache: _linkCache,
      fetchLinkPreview: _fetchLinkPreview,
      firstUrl: _firstUrl,
      performanceProbe: widget.performanceProbe,
      onSpeak:
          role == 'assistant' && !isStreaming && spokenAnswer.trim().isNotEmpty
          // Lee la respuesta final, nunca el razonamiento interno (`<think>`).
          ? () => _toggleReadAloud(msg, spokenAnswer)
          : null,
      readAloud: _voice?.readAloud,
      readAloudMessageKey: readAloudMessageKey,
      readAloudStopBehavior:
          _voice?.settings.readAloudStopBehavior ??
          ReadAloudStopBehavior.pauseAndResume,
      agentName: _agentName,
      isStreaming: isStreaming,
      companionMood: isStreaming || isPipeline ? _liveCompanionMood() : null,
      waitingForUser: (isStreaming || isPipeline) && _turnWaitsForUser,
      assistantSlice: displaySlice,
      terminalProjection: terminalProjection,
      technicalDetails: operationalProjection.technicalDetails,
      onEdit: role == 'user' && _canEditUserMessage(msg)
          ? (bubbleWidth) => _editUserMessage(msg, bubbleWidth)
          : null,
      editing: role == 'user' && identical(msg, _editingUserMessageTarget),
      editingText: _editingUserMessageText,
      editingWidth: _editingUserMessageWidth,
      editSaving: _editingRewriteSubmitted,
      onCancelEdit: _cancelUserMessageEdit,
      onSaveEdit: (text) => unawaited(_saveUserMessageEdit(text)),
      onRegenerate: role == 'assistant' && _isLatestAssistant(msg)
          ? _regenerateLastResponse
          : null,
      onSuggestionSelected: suggestionsEnabled
          ? (suggestion) => _useAssistantSuggestion(msg, suggestion)
          : null,
      compact: compact,
    );
  }

  Widget _buildLiveAssistantHost({required bool compact}) {
    return _LiveAssistantHost(
      key: ValueKey((
        'live-assistant',
        widget.session.logicalId,
        _assistantEntranceSerial,
      )),
      frame: _liveAssistantFrame,
      onBuild: () => widget.performanceProbe?.liveAssistantBuilds++,
      builder: (context, frame) =>
          _buildLiveAssistantMessage(frame, compact: compact),
    );
  }

  Widget _wrapLiveAssistantViewport(Widget child) {
    return KeyedSubtree(
      key: chatLiveAssistantViewportKey,
      child: _LiveAssistantExtentReporter(
        onExtentDelta: _streamingViewportLock.record,
        child: child,
      ),
    );
  }

  Widget _buildLiveAssistantMessage(
    _LiveAssistantFrame frame, {
    required bool compact,
  }) {
    final projection = _projectOperationalArtifacts(context, frame.content);
    final hasUnifiedActivity =
        normalizeAssistantActivityTrace(
          frame.metadata[assistantActivityTraceKey],
        ).isNotEmpty ||
        (frame.metadata['reasoning'] is String &&
            (frame.metadata['reasoning'] as String).trim().isNotEmpty);
    if (frame.isStreaming &&
        projection.visibleMarkdown.trim().isEmpty &&
        !hasUnifiedActivity) {
      return _buildActiveThinkingState();
    }
    if (!frame.isStreaming &&
        frame.metadata['_cancelled'] == true &&
        projection.visibleMarkdown.trim().isNotEmpty) {
      return _AssistantMessageWithMark(
        content: projection.visibleMarkdown,
        mark: 'cancelled',
        verbose: _devDiagnostics,
        metadata: frame.metadata,
        linkCache: _linkCache,
        fetchLinkPreview: _fetchLinkPreview,
        firstUrl: _firstUrl,
        agentName: _agentName,
        technicalDetails: projection.technicalDetails,
        onRegenerate: _isLatestAssistant(frame.metadata)
            ? _regenerateLastResponse
            : null,
      );
    }
    return _MessageBubble(
      content: projection.visibleMarkdown,
      isUser: false,
      verbose: _devDiagnostics,
      metadata: frame.metadata,
      linkCache: _linkCache,
      fetchLinkPreview: _fetchLinkPreview,
      firstUrl: _firstUrl,
      readAloud: _voice?.readAloud,
      readAloudStopBehavior:
          _voice?.settings.readAloudStopBehavior ??
          ReadAloudStopBehavior.pauseAndResume,
      agentName: _agentName,
      isStreaming: frame.isStreaming,
      companionMood: frame.isStreaming ? _liveCompanionMood() : null,
      waitingForUser: frame.isStreaming && _turnWaitsForUser,
      compact: compact,
      performanceProbe: widget.performanceProbe,
    );
  }

  _AssistantTerminalProjection _terminalAssistantProjectionFor({
    required String content,
    required _AssistantRenderSlice? slice,
    required bool suggestionsEnabled,
  }) {
    final sliceKey = switch (slice?.body) {
      _AssistantMarkdownChunk(:final data) => 'markdown:${slice!.index}:$data',
      _AssistantGeneratedImageChunk(:final basename) =>
        'image:${slice!.index}:$basename',
      _AssistantGeneratedMediaChunk(:final reference) =>
        'media:${slice!.index}:${sha256.convert(utf8.encode(reference.source))}',
      null => '',
    };
    final key = _AssistantTerminalProjectionKey(
      sourceContent: content,
      sliceKey: sliceKey,
      suggestionsEnabled: suggestionsEnabled,
    );
    final cached = _assistantTerminalProjections.remove(key);
    if (cached != null) {
      _assistantTerminalProjections[key] = cached;
      return cached;
    }

    widget.performanceProbe?.terminalProjectionComputations++;
    final split =
        slice?.plan.split ??
        ReasoningSplit(
          reasoning: '',
          answer: finalizedPublicAssistantText(content),
        );
    final suggestions = suggestionsEnabled && (slice?.showFooter ?? true)
        ? projectAssistantSuggestions(split.answer)
        : AssistantSuggestionsProjection(body: split.answer);
    final blocks = <_ProjectedAssistantBlock>[];

    void addMarkdown(String source, {required bool structured}) {
      if (source.trim().isEmpty) return;
      final prepared = structured
          ? source
          : prepareAssistantAnswerStructure(source);
      final normalized = normalizeStreamingMarkdown(
        escapePathGlobs(prepared),
        isStreaming: false,
      );
      var firstSegment = true;
      for (final segment in splitAnswerTables(normalized)) {
        if (!firstSegment) blocks.add(const _ProjectedAssistantGap());
        firstSegment = false;
        switch (segment) {
          case MarkdownSegment(:final text):
            if (text.trim().isNotEmpty) {
              blocks.add(_ProjectedAssistantMarkdown(text));
            }
          case TableSegment(:final rows):
            blocks.add(_ProjectedAssistantTable(rows));
        }
      }
    }

    final body = slice?.body;
    switch (body) {
      case _AssistantMarkdownChunk(:final data):
        addMarkdown(
          suggestions.hasSuggestions
              ? stripAssistantSuggestionsFromTerminalChunk(data)
              : data,
          structured: true,
        );
      case _AssistantGeneratedImageChunk(:final basename):
        blocks.add(_ProjectedAssistantImage(basename));
      case _AssistantGeneratedMediaChunk(:final reference):
        blocks.add(_ProjectedAssistantMedia(reference));
      case null:
        for (final mediaSegment in GeneratedMediaService.parseSegments(
          suggestions.body,
        )) {
          switch (mediaSegment) {
            case GeneratedMediaFileSegment(:final reference):
              blocks.add(_ProjectedAssistantMedia(reference));
            case GeneratedMediaTextSegment(:final text):
              for (final imageSegment in GeneratedImageService.segments(text)) {
                switch (imageSegment) {
                  case ImageSegment(:final basename):
                    blocks.add(_ProjectedAssistantImage(basename));
                  case TextSegment(:final text):
                    addMarkdown(text, structured: false);
                }
              }
          }
        }
    }

    final projection = _AssistantTerminalProjection(
      split: split,
      suggestions: suggestions,
      blocks: List.unmodifiable(blocks),
    );
    _assistantTerminalProjections[key] = projection;
    while (_assistantTerminalProjections.length >
        _assistantTerminalProjectionCacheLimit) {
      _assistantTerminalProjections.remove(
        _assistantTerminalProjections.keys.first,
      );
    }
    return projection;
  }

  void _scheduleGeneratedArtifactIndex(
    Map<String, dynamic> message,
    String terminalAnswer,
  ) {
    if (terminalAnswer.trim().isEmpty) return;
    final fingerprint = Object.hash(
      terminalAnswer.length,
      terminalAnswer.hashCode,
    );
    if (_generatedArtifactFingerprints[message] == fingerprint) return;
    _generatedArtifactFingerprints[message] = fingerprint;

    // El registro se actualiza después del frame: nunca notificamos listeners
    // durante el build del transcript. Solo se llega aquí para respuestas
    // terminales, así que tampoco se escanea el fence creciente por token.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      for (final artifact in GeneratedArtifactMarkdownScanner.scan(
        terminalAnswer,
      )) {
        _generatedArtifactRegistry.upsert(
          _generatedArtifactScope,
          artifact.detection,
          artifact.content,
        );
      }
    });

    if (_generatedArtifactFingerprints.length > 512) {
      final live = Set<Map<String, dynamic>>.identity()..addAll(_messages);
      _generatedArtifactFingerprints.removeWhere(
        (candidate, _) => !live.contains(candidate),
      );
    }
  }
}

/// Elemento hoja que observa `MediaQuery.viewInsets.bottom` y avisa a su
/// dueño en cada cambio, sin propagar la dependencia hacia arriba.
///
/// [child] se devuelve tal cual (misma instancia), así que una reconstrucción
/// de este widget por un cambio de insets no reconstruye el subárbol: solo se
/// dispara el callback. Sustituye a la lectura de `MediaQuery.of` que hacía
/// `_ChatScreenState.didChangeDependencies`, la cual convertía cada frame de
/// la animación del teclado en un build completo de la pantalla de chat.
class _KeyboardInsetWatcher extends StatefulWidget {
  final ValueChanged<double> onBottomInset;

  final Widget child;

  const _KeyboardInsetWatcher({
    required this.onBottomInset,
    required this.child,
  });

  @override
  State<_KeyboardInsetWatcher> createState() => _KeyboardInsetWatcherState();
}

class _KeyboardInsetWatcherState extends State<_KeyboardInsetWatcher> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onBottomInset(MediaQuery.viewInsetsOf(context).bottom);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Superficie común de los avisos en flujo bajo la cabecera del chat: tarjeta
/// neutra con filete (mismos tokens que el aviso flotante y las pastillas), el
/// estado lo lleva solo el glifo. Sin relleno ni borde de color.
class _ChatNoticeSurface extends StatelessWidget {
  const _ChatNoticeSurface({
    required this.icon,
    required this.iconColor,
    required this.message,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final String message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: EdgeInsets.fromLTRB(14, 9, trailing == null ? 14 : 4, 9),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider.withValues(alpha: 0.78)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 12.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _DesktopAuthRequiredBanner extends StatelessWidget {
  const _DesktopAuthRequiredBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      key: const ValueKey('chat-dashboard-auth-required'),
      container: true,
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: _ChatNoticeSurface(
          icon: Icons.lock_outline_rounded,
          iconColor: colors.warning,
          message: message,
        ),
      ),
    );
  }
}

class _CoreReadPartialCoverageNotice extends StatelessWidget {
  const _CoreReadPartialCoverageNotice({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      key: const ValueKey('core-read-partial-coverage-notice'),
      container: true,
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: _ChatNoticeSurface(
          icon: Icons.account_tree_outlined,
          iconColor: colors.warning,
          message: message,
          trailing: IconButton(
            key: const ValueKey('core-read-partial-coverage-dismiss'),
            tooltip: Strings.of(context).commonClose,
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
            iconSize: 18,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _LocalTranscriptTruncationNotice extends StatelessWidget {
  const _LocalTranscriptTruncationNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      key: const ValueKey('local-transcript-truncation-notice'),
      container: true,
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: _ChatNoticeSurface(
          icon: Icons.history_toggle_off_rounded,
          iconColor: colors.warning,
          message: message,
        ),
      ),
    );
  }
}

class _EditQueuedEntrySheet extends StatefulWidget {
  final String initialText;

  const _EditQueuedEntrySheet({required this.initialText});

  @override
  State<_EditQueuedEntrySheet> createState() => _EditQueuedEntrySheetState();
}

class _EditQueuedEntrySheetState extends State<_EditQueuedEntrySheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  void _releaseFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.hasFocus) focus.unfocus();
  }

  void _close([String? result]) {
    _releaseFocus();
    Navigator.of(context).pop(result);
  }

  @override
  void deactivate() {
    _releaseFocus();
    super.deactivate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final body = SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => _close(),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    strings.chaQueueEdit,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceVariant.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.42),
                ),
              ),
              child: TextField(
                key: const ValueKey('queued-message-editor-field'),
                controller: _controller,
                autofocus: true,
                minLines: 2,
                maxLines: 8,
                decoration: InputDecoration(
                  hintText: strings.chaEditHint,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 15,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 74),
          ],
        ),
      ),
    );
    return Stack(
      children: [
        body,
        Positioned(
          left: 16,
          right: 16,
          bottom: 18,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => _close(),
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  minimumSize: const Size(0, 46),
                ),
                onPressed: () => _close(_controller.text.trim()),
                child: Text(strings.chaEditApply),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UserTurnGroup {
  final Map<String, dynamic> primary;
  final List<Map<String, dynamic>> supplements = [];

  _UserTurnGroup(this.primary);
}

enum _BotChatHeaderAction { model, controls }

/// Cabecera del Bot Chat: avatar + nombre del bot + estado vivo, con el mismo
/// protagonismo que la cabecera de una Room. El modelo y los controles viven
/// en el overflow, siguiendo el patrón del plugin oficial Hermes Bot Mode.
class _BotChatAppBarTitle extends StatelessWidget {
  final AgentProfile? profile;
  final String fallbackName;
  final ChatActivityKind? activity;
  final MissionProfileAvatarCache? avatarCache;

  const _BotChatAppBarTitle({
    required this.profile,
    required this.fallbackName,
    required this.activity,
    required this.avatarCache,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final profile = this.profile;
    final name = profile != null && profile.name.isNotEmpty
        ? profile.name
        : fallbackName;
    final displayName = profile?.botTitle ?? name;
    final statusLabel = switch (activity) {
      ChatActivityKind.thinking => english ? 'Thinking' : 'Pensando',
      ChatActivityKind.usingTools => english ? 'Working' : 'Trabajando',
      ChatActivityKind.responding => english ? 'Responding' : 'Respondiendo',
      ChatActivityKind.awaitingApproval =>
        english ? 'Approval required' : 'Aprobación requerida',
      null => null,
    };
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
      child: Row(
        children: [
          MissionProfileAvatar(
            key: ValueKey('bot-chat-avatar-$name'),
            profileName: name,
            hasAvatar: profile?.hasAvatar ?? false,
            cache: avatarCache,
            size: 30,
            shape: profile?.botShape,
            colorHex: profile?.botColorHex,
            imageKind: profile?.botImageKind,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17.5,
                    letterSpacing: -0.15,
                  ),
                ),
                Text(
                  [
                    if (displayName != name || statusLabel == null) '@$name',
                    ?statusLabel,
                  ].join(' · '),
                  key: const ValueKey('bot-chat-header-subtitle'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11.5,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension _ComposerPalettePlacement on Widget {
  Widget _withComposerPalette(Widget? palette) =>
      _ComposerPaletteOverlay(palette: palette, child: this);
}

class _ComposerPaletteOverlay extends StatefulWidget {
  final Widget child;
  final Widget? palette;

  const _ComposerPaletteOverlay({required this.child, required this.palette});

  @override
  State<_ComposerPaletteOverlay> createState() =>
      _ComposerPaletteOverlayState();
}

class _ComposerPaletteOverlayState extends State<_ComposerPaletteOverlay> {
  final _controller = OverlayPortalController();
  final _link = LayerLink();
  final _targetKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Mantener el portal montado evita un frame intermedio al abrir la paleta y,
    // sobre todo, no reemplaza el TextField que conserva el ownership del IME.
    _controller.show();
  }

  @override
  Widget build(BuildContext context) {
    final targetRenderObject = _targetKey.currentContext?.findRenderObject();
    final targetTop =
        targetRenderObject is RenderBox &&
            targetRenderObject.hasSize &&
            targetRenderObject.attached
        ? targetRenderObject.localToGlobal(Offset.zero).dy
        : MediaQuery.sizeOf(context).height;
    final paletteMaxHeight = math.max(0.0, targetTop - 8);
    return LayoutBuilder(
      builder: (context, constraints) => OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) => Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            child: SizedBox(
              width: constraints.maxWidth,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: paletteMaxHeight),
                child: widget.palette ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(
          key: _targetKey,
          link: _link,
          child: widget.child,
        ),
      ),
    );
  }
}

class _SlashAccentTextEditingController extends TextEditingController {
  TextRange? slashCommandRange() {
    final parsed = parseSlashCommand(value.text);
    if (parsed == null) return null;
    final text = value.text;
    final start = text.length - text.trimLeft().length;
    final trimmed = text.trimLeft();
    final sp = trimmed.indexOf(RegExp(r'\s'));
    final end = start + (sp == -1 ? trimmed.length : sp);
    return TextRange(start: start, end: end);
  }

  TextRange composingRange(TextEditingValue value, bool withComposing) {
    final range = value.composing;
    if (!withComposing || !value.isComposingRangeValid || range.isCollapsed) {
      return TextRange.empty;
    }
    return range;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    final slashRange = slashCommandRange();
    if (text.isEmpty || slashRange == null) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final composing = composingRange(value, withComposing);
    final cuts = <int>{0, slashRange.start, slashRange.end, text.length};
    if (!composing.isCollapsed) {
      cuts
        ..add(composing.start)
        ..add(composing.end);
    }
    final orderedCuts = cuts.toList()..sort();
    final spans = <InlineSpan>[];
    for (var index = 0; index < orderedCuts.length - 1; index++) {
      final start = orderedCuts[index];
      final end = orderedCuts[index + 1];
      if (start == end) continue;
      var segmentStyle = style;
      if (start >= slashRange.start && end <= slashRange.end) {
        segmentStyle = (segmentStyle ?? const TextStyle()).copyWith(
          color: Theme.of(context).hermes.accent,
        );
      }
      if (!composing.isCollapsed &&
          start >= composing.start &&
          end <= composing.end) {
        segmentStyle = (segmentStyle ?? const TextStyle()).merge(
          const TextStyle(decoration: TextDecoration.underline),
        );
      }
      spans.add(
        TextSpan(text: text.substring(start, end), style: segmentStyle),
      );
    }
    return TextSpan(style: style, children: spans);
  }
}

/// Paleta de comandos slash: aparece sobre el compositor al escribir `/…` y
/// lista los comandos que coinciden. Tocar uno lo ejecuta o rellena su nombre.
class _SlashPalette extends StatelessWidget {
  final List<SlashCommand> commands;
  final ValueChanged<SlashCommand> onPick;

  const _SlashPalette({required this.commands, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      key: const ValueKey('chat-slash-palette'),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 9),
      constraints: const BoxConstraints(maxHeight: 224),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.divider.withValues(alpha: 0.72)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Material(
          color: Colors.transparent,
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 5),
            itemCount: commands.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: 58,
              color: colors.divider.withValues(alpha: 0.45),
            ),
            itemBuilder: (ctx, i) {
              final command = commands[i];
              return InkWell(
                key: ValueKey('chat-slash-command-${command.name}'),
                onTap: () => onPick(command),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 14, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.accent.withValues(alpha: 0.11),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.accent.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Text(
                          '/',
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: colors.accent,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '/${command.name}',
                                    style: TextStyle(
                                      color: colors.accent,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (command.argHint.isNotEmpty)
                                    TextSpan(
                                      text: '  ${command.argHint}',
                                      style: TextStyle(
                                        color: colors.textSecondary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              command.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 12.5,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Compact strip shown above the input bar when a file is staged.
/// Shows a thumbnail for images or a document icon for other files.
/// Reflects the real per-item state; remove and retry never affect siblings.
class _AttachmentPreviewStrip extends StatelessWidget {
  final List<AttachmentDraft> attachments;
  final ValueChanged<String>? onRemove;
  final ValueChanged<String>? onRetry;

  const _AttachmentPreviewStrip({
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // A horizontal scroll view shrink-wraps to its content, and the composer
    // column centres its children: one or two thumbs ended up floating in the
    // middle of the input. Take the full width and pin the row to the start
    // edge (RTL-aware) so attachments stack from the leading side.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < attachments.length; index++) ...[
                if (index > 0) const SizedBox(width: 10),
                Builder(
                  builder: (context) {
                    final attachment = attachments[index];
                    final hasLocalImage =
                        attachment.isImage &&
                        attachment.localPath.isNotEmpty &&
                        File(attachment.localPath).existsSync();
                    final previewable =
                        hasLocalImage &&
                        (attachment.uploadState ==
                                AttachmentUploadState.pending ||
                            attachment.uploadState ==
                                AttachmentUploadState.error);
                    final changing =
                        attachment.uploadState ==
                        AttachmentUploadState.uploading;
                    final openPreview = previewable
                        ? () => showImageViewer(
                            context,
                            File(attachment.localPath),
                          )
                        : null;
                    return Semantics(
                      container: changing || previewable,
                      explicitChildNodes: changing || previewable,
                      liveRegion:
                          changing ||
                          attachment.uploadState == AttachmentUploadState.error,
                      label: changing
                          ? Strings.of(
                              context,
                            ).chaAttachmentUploadInProgress(attachment.name)
                          : previewable
                          ? Strings.of(
                              context,
                            ).chaPreviewAttachment(attachment.name)
                          : null,
                      button: previewable,
                      onTap: openPreview,
                      child: AttachmentCard(
                        key: ValueKey('attachment-card-${attachment.localId}'),
                        name: attachment.name,
                        mimeType: attachment.mimeType,
                        sizeLabel: attachment.formattedSize,
                        thumbnailFile: hasLocalImage
                            ? File(attachment.localPath)
                            : null,
                        showUploadState: true,
                        uploadState: attachment.uploadState,
                        onTap: openPreview,
                        onRetry:
                            attachment.uploadState ==
                                    AttachmentUploadState.error &&
                                attachment.localId.isNotEmpty &&
                                onRetry != null
                            ? () => onRetry!(attachment.localId)
                            : null,
                        onRemove: attachment.localId.isEmpty || onRemove == null
                            ? null
                            : () => onRemove!(attachment.localId),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Welcome state shown when the session has no messages yet.
/// Terminal-style prompt with a blinking block cursor.
class _EmptyChatState extends StatelessWidget {
  final String model;
  final String agentName;

  const _EmptyChatState({required this.model, this.agentName = 'hermes'});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - t)),
              child: child,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // El chat forma parte de la presencia completa. En off,
              // minimal o con Companion deshabilitado no se reserva espacio
              // ni se introduce un fallback que contradiga la preferencia.
              Builder(
                builder: (ctx) {
                  final companion = ctx
                      .findAncestorStateOfType<HermesAppState>()
                      ?.companion;
                  if (companion == null) return const SizedBox.shrink();
                  return AnimatedBuilder(
                    animation: companion,
                    builder: (context, _) {
                      if (!companion.isInitialized ||
                          !companion.enabled ||
                          !companion.presenceLevel.showsStatusPresence) {
                        return const SizedBox.shrink();
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CompanionMessagePresence(
                            companion: companion,
                            mood: HermesSparkMood.idle,
                            size: 120,
                            animateIdle: true,
                          ),
                          const SizedBox(height: 18),
                        ],
                      );
                    },
                  );
                },
              ),
              Text(
                agentName,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  color: colors.accent,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    Strings.of(context).chaEmptyPrompt,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.textSecondary,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(width: 3),
                  _BlinkingCursor(
                    key: const ValueKey('empty-chat-blink-clock'),
                    color: colors.accent,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cursor de terminal que parpadea (▍). Usado en el chat vacío para dar un
/// toque animado al "Escríbeme para empezar".
class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({super.key, required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with WidgetsBindingObserver {
  static const Duration _blinkInterval = Duration(milliseconds: 550);

  Timer? _clock;
  bool _visible = true;
  bool _reduceMotion = false;
  bool _tickerModeEnabled = true;
  bool _appActive = true;
  int _debugBlinkCount = 0;

  bool get debugClockActive => _clock?.isActive ?? false;
  int get debugBlinkCount => _debugBlinkCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final changed =
        _reduceMotion != reduced || _tickerModeEnabled != tickerEnabled;
    _reduceMotion = reduced;
    _tickerModeEnabled = tickerEnabled;
    if (changed || _clock == null) _syncClock();
  }

  bool get _shouldBlink =>
      mounted && _appActive && _tickerModeEnabled && !_reduceMotion;

  void _syncClock({bool notify = false}) {
    _clock?.cancel();
    _clock = null;
    final visibilityChanged = !_visible;
    _visible = true;
    if (_shouldBlink) {
      _clock = Timer.periodic(_blinkInterval, (_) {
        if (!_shouldBlink) {
          _syncClock(notify: true);
          return;
        }
        setState(() {
          _visible = !_visible;
          _debugBlinkCount++;
        });
      });
    }
    if (notify && visibilityChanged && mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    _syncClock(notify: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _clock = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      key: const ValueKey('empty-chat-cursor'),
      opacity: _visible ? 1.0 : 0.0,
      child: Text('▍', style: TextStyle(fontSize: 13, color: widget.color)),
    );
  }
}

/// Tipo de error inferido a partir del mensaje, para encabezar la burbuja con
/// una causa concreta (no un "error" genérico).
// Alias locales para mantener compatibilidad con el código existente de esta
// pantalla sin renombrar cada uso (_ErrorKind → ChatErrorKind).
typedef _ErrorKind = ChatErrorKind;
final _classifyError = classifyChatError;

/// Error bubble shown when the stream fails — inline with retry button.
///
/// Diferencia el tipo de error (conexión/modelo/herramienta/local/desconocido)
/// usando únicamente el copy público ya saneado por ActiveChat.
class _ErrorBubble extends StatefulWidget {
  final String error;
  final String prompt;
  final VoidCallback? onRetry;

  /// Acción opcional para reiniciar el gateway (se ofrece en errores de
  /// "agente colgado"/conexión, donde el servidor puede estar atascado).
  final VoidCallback? onRestartGateway;

  /// Abre una sesión nueva; se ofrece cuando la sesión ya no cabe en el
  /// contexto del modelo (reintentar repetiría el mismo fallo).
  final VoidCallback? onNewSession;

  const _ErrorBubble({
    required this.error,
    required this.prompt,
    required this.onRetry,
    this.onRestartGateway,
    this.onNewSession,
  });

  @override
  State<_ErrorBubble> createState() => _ErrorBubbleState();
}

class _ErrorBubbleState extends State<_ErrorBubble> {
  bool _expanded = false;

  String _kindLabel(_ErrorKind kind, Strings s) => switch (kind) {
    _ErrorKind.connection => s.chaErrConnection,
    _ErrorKind.model => s.chaErrModel,
    _ErrorKind.tool => s.chaErrTool,
    _ErrorKind.local => s.chaErrLocal,
    _ErrorKind.localColdStart => s.chaErrLocalColdStart,
    _ErrorKind.firstTokenTimeout => s.chaErrFirstTokenTimeout,
    _ErrorKind.searchToolUnavailable => s.chaErrSearchToolUnavailable,
    _ErrorKind.sessionTooLarge => s.chaErrSessionTooLarge,
    _ErrorKind.unknown => s.chaErrUnknown,
  };

  String? _kindHint(_ErrorKind kind, Strings s) => switch (kind) {
    _ErrorKind.connection => s.chaErrHintConnection,
    _ErrorKind.model => s.chaErrHintModel,
    _ErrorKind.tool => null,
    _ErrorKind.local => s.chaErrHintLocal,
    _ErrorKind.localColdStart => s.chaErrHintLocalColdStart,
    _ErrorKind.firstTokenTimeout => s.chaErrHintFirstTokenTimeout,
    _ErrorKind.searchToolUnavailable => s.chaErrHintSearchToolUnavailable,
    _ErrorKind.sessionTooLarge => s.chaErrHintSessionTooLarge,
    _ErrorKind.unknown => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final kind = _classifyError(widget.error);
    final summary = widget.error.length > 140
        ? '${widget.error.substring(0, 140)}…'
        : widget.error;
    final hasMore = widget.error.length > 140 || widget.error.contains('\n');

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 56, top: 11, bottom: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _AssistantHeaderCompanion(
                  mood: HermesSparkMood.error,
                  animate: false,
                ),
                Text(
                  '▸ hermes',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.error,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: colors.error.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.error.withValues(alpha: 0.18)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(kind.icon, size: 14, color: colors.error),
                    const SizedBox(width: 6),
                    Text(
                      _kindLabel(kind, str),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: colors.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _expanded ? widget.error : summary,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: colors.error.withValues(alpha: 0.92),
                    fontFamily: _expanded ? 'monospace' : null,
                  ),
                ),
                if (_kindHint(kind, str) != null && !_expanded) ...[
                  const SizedBox(height: 4),
                  Text(
                    _kindHint(kind, str)!,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
                const SizedBox(height: 8),
                // A-114 (spec 028): las acciones de recuperación pasan a
                // targets ≥48dp con rol de botón (eran texto de 11px con
                // ~25dp tocables); el visual compacto se conserva.
                Row(
                  children: [
                    if (kind == _ErrorKind.sessionTooLarge &&
                        widget.onNewSession != null)
                      _ErrorBubbleAction(
                        label: Strings.of(context).chaNewChatTooltip,
                        color: colors.error,
                        onTap: widget.onNewSession!,
                      )
                    else if (widget.onRetry != null)
                      _ErrorBubbleAction(
                        label: Strings.of(context).chaRetry,
                        color: colors.error,
                        onTap: widget.onRetry!,
                      ),
                    // En errores de "agente colgado"/conexión, ofrecer reiniciar
                    // el gateway del servidor (puede estar atascado).
                    if (widget.onRestartGateway != null &&
                        (kind == _ErrorKind.firstTokenTimeout ||
                            kind == _ErrorKind.connection)) ...[
                      const SizedBox(width: 8),
                      _ErrorBubbleAction(
                        label: Strings.of(context).chaRestartGateway,
                        color: colors.error,
                        onTap: widget.onRestartGateway,
                      ),
                    ],
                    if (hasMore) ...[
                      const SizedBox(width: 8),
                      _ErrorBubbleAction(
                        label: _expanded
                            ? Strings.of(context).chaErrHideDetails
                            : Strings.of(context).chaErrViewDetails,
                        color: colors.textSecondary,
                        outlined: false,
                        onTap: () => setState(() => _expanded = !_expanded),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Acción compacta de la tarjeta de error. A-114 (spec 028): rol de botón y
/// target táctil ≥48dp para TalkBack/motricidad reducida; el visual sigue
/// siendo la pastilla pequeña de siempre.
class _ErrorBubbleAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final bool outlined;

  const _ErrorBubbleAction({
    required this.label,
    required this.onTap,
    required this.color,
    this.outlined = true,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: outlined
                  ? BoxDecoration(
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              child: Text(label, style: TextStyle(fontSize: 11, color: color)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Assistant message with a subtle status mark (e.g. "cancelled").
class _AssistantMessageWithMark extends StatelessWidget {
  final String content;
  final String mark;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final Map<String, _LinkPreviewData?> linkCache;
  final Future<void> Function(String url) fetchLinkPreview;
  final String? Function(String text) firstUrl;
  final String agentName;
  final _AssistantRenderSlice? slice;
  final _AssistantTerminalProjection? terminalProjection;
  final List<String> technicalDetails;
  final VoidCallback? onRegenerate;

  const _AssistantMessageWithMark({
    required this.content,
    required this.mark,
    required this.linkCache,
    required this.fetchLinkPreview,
    required this.firstUrl,
    this.verbose = false,
    this.metadata = const {},
    this.agentName = 'hermes',
    this.slice,
    this.terminalProjection,
    this.technicalDetails = const [],
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _AssistantMessage(
          content: content,
          verbose: verbose,
          metadata: metadata,
          linkCache: linkCache,
          fetchLinkPreview: fetchLinkPreview,
          firstUrl: firstUrl,
          agentName: agentName,
          slice: slice,
          terminalProjection: terminalProjection,
          technicalDetails: technicalDetails,
          onRegenerate: onRegenerate,
        ),
        // La marca pertenece al mensaje completo: en un render troceado solo la
        // lleva el slice de cierre, no cada fragmento.
        if (slice?.showFooter ?? true)
          Padding(
            padding: const EdgeInsets.only(left: 14, bottom: 4),
            child: Text(
              mark,
              style: TextStyle(fontSize: 10, color: colors.textDisabled),
            ),
          ),
      ],
    );
  }
}

/// Modo del botón principal del composer.
/// - [send]: envío normal (idle).
/// - [stop]: el agente responde; el borrador del turno siguiente no sustituye Stop.
enum _SendMode { send, stop }

class _SendButton extends StatefulWidget {
  final _SendMode mode;

  /// A-017 (spec 028): con el campo vacío la flecha se pinta atenuada y no
  /// responde — antes lucía activa (ámbar + glow) pero el tap no hacía nada.
  final bool enabled;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback? onQueue;
  final VoidCallback onStop;

  const _SendButton({
    required this.mode,
    required this.onSend,
    required this.onStop,
    this.onQueue,
    this.enabled = true,
    this.busy = false,
  });

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  void _handleTap() {
    if (!widget.enabled) return;
    HapticFeedback.lightImpact();
    if (widget.mode == _SendMode.stop) {
      widget.onStop();
    } else {
      widget.onSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isStop = widget.mode == _SendMode.stop;
    final s = Strings.of(context);
    final tooltip = widget.busy
        ? s.chaUploadingAttachment
        : switch (widget.mode) {
            _SendMode.send => s.chaSendTooltip,
            _SendMode.stop => s.chaStopTooltip,
          };
    final icon = switch (widget.mode) {
      _SendMode.send => Icons.arrow_upward,
      _SendMode.stop => Icons.stop_rounded,
    };
    final bg = !widget.enabled ? colors.surfaceVariant : colors.accent;
    final fg = !widget.enabled ? colors.textDisabled : colors.onAccent;
    if (widget.busy) {
      return Semantics(
        label: tooltip,
        liveRegion: true,
        child: SizedBox.square(
          dimension: 42,
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.textSecondary,
            ),
          ),
        ),
      );
    }

    final onQueue = widget.onQueue;
    return HermesTactileAction(
      icon: icon,
      iconSize: isStop ? 21 : 19,
      semanticLabel: tooltip,
      onPressed: widget.enabled ? _handleTap : null,
      onLongPress: isStop || !widget.enabled || onQueue == null
          ? null
          : () {
              HapticFeedback.lightImpact();
              onQueue();
            },
      backgroundColor: bg,
      foregroundColor: fg,
      enabled: widget.enabled,
      size: 42,
    );
  }
}

class _LiveAssistantFrame {
  final int turnSerial;
  final String content;
  final Map<String, dynamic> metadata;
  final bool isStreaming;

  const _LiveAssistantFrame({
    required this.turnSerial,
    required this.content,
    required this.metadata,
    required this.isStreaming,
  });
}

class _LiveAssistantHost extends StatelessWidget {
  final ValueListenable<_LiveAssistantFrame?> frame;
  final Widget Function(BuildContext context, _LiveAssistantFrame frame)
  builder;
  final VoidCallback? onBuild;

  const _LiveAssistantHost({
    super.key,
    required this.frame,
    required this.builder,
    this.onBuild,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_LiveAssistantFrame?>(
      valueListenable: frame,
      builder: (context, value, _) {
        onBuild?.call();
        if (value == null) return const SizedBox.shrink();
        return builder(context, value);
      },
    );
  }
}

/// Prefijo ya cerrado de la respuesta viva. Su contenido no vuelve a cambiar
/// mientras el modelo escribe la cola, así que el parseo de CommonMark y el
/// resaltado de sus bloques `pre` se ejecutan UNA vez por prefijo nuevo en vez
/// de en cada frame del streaming: mientras [data] y el tema no cambien, build
/// devuelve la MISMA instancia de widget y el subtree no se reconstruye.
class _StableStreamingMarkdown extends StatefulWidget {
  /// Segmento ya preparado ([prepareAssistantAnswerStructure]) y escapado
  /// ([escapePathGlobs]); la reparación por bloque se aplica aquí dentro.
  final String data;
  final Widget Function(String data) markdown;
  final ChatPerformanceProbe? performanceProbe;

  const _StableStreamingMarkdown({
    required this.data,
    required this.markdown,
    this.performanceProbe,
  });

  @override
  State<_StableStreamingMarkdown> createState() =>
      _StableStreamingMarkdownState();
}

class _StableStreamingMarkdownState extends State<_StableStreamingMarkdown> {
  String? _source;
  ThemeData? _theme;
  Widget? _rendered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cached = _rendered;
    if (cached != null && _source == widget.data && identical(_theme, theme)) {
      return cached;
    }
    widget.performanceProbe?.liveStableProjectionComputations++;
    _source = widget.data;
    _theme = theme;
    return _rendered = widget.markdown(
      normalizeStableStreamingPrefix(widget.data),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final Map<String, _LinkPreviewData?> linkCache;
  final Future<void> Function(String url) fetchLinkPreview;
  final String? Function(String text) firstUrl;

  final VoidCallback? onSpeak;
  final ValueListenable<ReadAloudSnapshot>? readAloud;
  final String? readAloudMessageKey;
  final ReadAloudStopBehavior readAloudStopBehavior;
  final String agentName;
  final bool isStreaming;
  final HermesSparkMood? companionMood;
  final bool waitingForUser;
  final _AssistantRenderSlice? assistantSlice;
  final _AssistantTerminalProjection? terminalProjection;
  final List<String> technicalDetails;
  final ValueChanged<double>? onEdit;
  final bool editing;
  final String? editingText;
  final double? editingWidth;
  final bool editSaving;
  final VoidCallback? onCancelEdit;
  final ValueChanged<String>? onSaveEdit;
  final VoidCallback? onRegenerate;
  final AssistantSuggestionCallback? onSuggestionSelected;
  final bool compact;
  final ChatPerformanceProbe? performanceProbe;

  const _MessageBubble({
    required this.content,
    required this.isUser,
    required this.linkCache,
    required this.fetchLinkPreview,
    required this.firstUrl,
    this.verbose = false,
    this.metadata = const {},
    this.onSpeak,
    this.readAloud,
    this.readAloudMessageKey,
    this.readAloudStopBehavior = ReadAloudStopBehavior.pauseAndResume,
    this.agentName = 'hermes',
    this.isStreaming = false,
    this.companionMood,
    this.waitingForUser = false,
    this.assistantSlice,
    this.terminalProjection,
    this.technicalDetails = const [],
    this.onEdit,
    this.editing = false,
    this.editingText,
    this.editingWidth,
    this.editSaving = false,
    this.onCancelEdit,
    this.onSaveEdit,
    this.onRegenerate,
    this.onSuggestionSelected,
    this.compact = false,
    this.performanceProbe,
  });

  @override
  Widget build(BuildContext context) {
    return isUser
        ? _UserMessage(
            content: content,
            verbose: verbose,
            metadata: metadata,
            onEdit: onEdit,
            editing: editing,
            editingText: editingText,
            editingWidth: editingWidth,
            editSaving: editSaving,
            onCancelEdit: onCancelEdit,
            onSaveEdit: onSaveEdit,
            compact: compact,
          )
        : _AssistantMessage(
            content: content,
            verbose: verbose,
            metadata: metadata,
            linkCache: linkCache,
            fetchLinkPreview: fetchLinkPreview,
            firstUrl: firstUrl,
            onSpeak: onSpeak,
            readAloud: readAloud,
            readAloudMessageKey: readAloudMessageKey,
            readAloudStopBehavior: readAloudStopBehavior,
            agentName: agentName,
            isStreaming: isStreaming,
            companionMood: companionMood,
            waitingForUser: waitingForUser,
            slice: assistantSlice,
            terminalProjection: terminalProjection,
            technicalDetails: technicalDetails,
            onRegenerate: onRegenerate,
            onSuggestionSelected: onSuggestionSelected,
            compact: compact,
            performanceProbe: performanceProbe,
          );
  }
}

/// Frontera estable de selección para un único mensaje terminado.
///
/// `MarkdownBody(selectable: true)` convierte cada bloque en un `EditableText`.
/// En una lista invertida Android intenta entonces hacer `bringIntoView` al
/// mostrar el menú y desplaza el mensaje bajo el dedo. Una región por mensaje
/// mantiene el Markdown como `Text.rich`, permite selección parcial y no toca el
/// scroll. Al deshabilitar la región se limpia la selección de forma explícita;
/// durante el desmontaje se deja que Flutter retire primero el Overlay y se
/// conserva una limpieza final defensiva en [dispose].
@visibleForTesting
class ChatMessageSelectionArea extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Object? selectionIdentity;

  const ChatMessageSelectionArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.selectionIdentity,
  });

  @override
  State<ChatMessageSelectionArea> createState() =>
      _ChatMessageSelectionAreaState();
}

class _ChatMessageSelectionAreaState extends State<ChatMessageSelectionArea> {
  final GlobalKey<SelectionAreaState> _selectionAreaKey =
      GlobalKey<SelectionAreaState>();

  void _clearSelection() {
    final area = _selectionAreaKey.currentState;
    if (area == null) return;
    final region = area.selectableRegion;
    region.hideToolbar();
    region.clearSelection();
  }

  @override
  void didUpdateWidget(ChatMessageSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.enabled && !widget.enabled) ||
        oldWidget.selectionIdentity != widget.selectionIdentity) {
      _clearSelection();
    }
  }

  @override
  void dispose() {
    _clearSelection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return SelectionArea(
      key: _selectionAreaKey,
      magnifierConfiguration: TextMagnifierConfiguration.disabled,
      child: widget.child,
    );
  }
}

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
  final kind = effectiveUserDisplayKind(message);
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
    case 'process_complete':
      // El runtime ya redactó el título compacto; el payload completo queda en
      // `raw` (copiable), nunca impreso como burbuja.
      final rawMetadata = message['display_metadata'];
      final metadata = rawMetadata is Map ? rawMetadata : const {};
      final displayText = metadata['display_text'];
      final title = displayText is String ? displayText.trim() : '';
      return (
        title: title.isNotEmpty ? title : strings.chaTimelineProcessFinished,
        detail: null,
        icon: Icons.terminal_rounded,
      );
    case 'model_switch':
      return (
        title: strings.chaTimelineModelChanged,
        detail: null,
        icon: Icons.swap_horiz_rounded,
      );
    case 'compression_result':
      final rawMetadata = message['display_metadata'];
      if (rawMetadata is! Map) return null;
      final noop = rawMetadata['noop'] == true;
      final beforeMessages = rawMetadata['before_messages'];
      final afterMessages = rawMetadata['after_messages'];
      final beforeTokens = rawMetadata['before_tokens'];
      final afterTokens = rawMetadata['after_tokens'];
      if (beforeMessages is! int ||
          afterMessages is! int ||
          beforeTokens is! int ||
          afterTokens is! int) {
        return null;
      }
      return (
        title: noop
            ? strings.chaCompressionNoop(
                beforeMessages,
                beforeTokens.toString(),
              )
            : strings.chaCompressionCompleted,
        detail: noop
            ? null
            : strings.chaCompressionSuccess(
                beforeMessages,
                afterMessages,
                beforeTokens.toString(),
                afterTokens.toString(),
              ),
        icon: Icons.compress_rounded,
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
  raw = stripBotMentionNote(raw);
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

/// Chip limpio que sustituye a un blob de SISTEMA (preámbulo de cron/skill o
/// resumen de compactación) en el chat. Mantener pulsado copia el contenido
/// crudo (para depurar). Se usa para cualquier rol (user o assistant).
class _SystemBlobChip extends StatelessWidget {
  final String label;
  final String raw;
  const _SystemBlobChip({required this.label, required this.raw});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    return Padding(
      padding: const EdgeInsets.only(left: 56, right: 12, top: 11, bottom: 3),
      child: Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: raw));
            HermesNotice.of(context).showSnackBar(
              SnackBar(
                content: Text(Strings.of(context).chaCopied),
                duration: const Duration(seconds: 1),
              ),
              kind: HermesNoticeKind.success,
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 15, color: colors.accent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Evento durable del transcript con tratamiento editorial, no una burbuja.
/// El contenido interno solo queda accesible mediante pulsación larga para
/// diagnóstico; rutas, roles y payloads nunca se vuelcan en el chat.
class _TimelineSystemEventRow extends StatelessWidget {
  final String title;
  final String? detail;
  final IconData icon;
  final String raw;
  final int? titleMaxLines;

  const _TimelineSystemEventRow({
    required this.title,
    required this.detail,
    required this.icon,
    required this.raw,
    this.titleMaxLines,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final semanticLabel = [
      title,
      if (detail case final value? when value.trim().isNotEmpty) value,
    ].join('. ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      child: Semantics(
        label: semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: raw));
            HermesNotice.of(context).showSnackBar(
              SnackBar(
                content: Text(Strings.of(context).chaCopied),
                duration: const Duration(seconds: 1),
              ),
              kind: HermesNoticeKind.success,
            );
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(
                    icon,
                    size: 16,
                    color: colors.textSecondary.withValues(alpha: 0.72),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: titleMaxLines,
                        overflow: titleMaxLines == null
                            ? null
                            : TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (detail case final value?
                          when value.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          value,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary.withValues(alpha: 0.72),
                            fontSize: 12,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
Future<void> _openMarkdownLink(BuildContext context, String? href) async {
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

class _UserMessage extends StatelessWidget {
  final String content;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final List<String> supplements;
  final ValueChanged<double>? onEdit;
  final bool editing;
  final String? editingText;
  final double? editingWidth;
  final bool editSaving;
  final VoidCallback? onCancelEdit;
  final ValueChanged<String>? onSaveEdit;
  final bool compact;

  const _UserMessage({
    required this.content,
    this.verbose = false,
    this.metadata = const {},
    this.supplements = const [],
    this.onEdit,
    this.editing = false,
    this.editingText,
    this.editingWidth,
    this.editSaving = false,
    this.onCancelEdit,
    this.onSaveEdit,
    this.compact = false,
  });

  Widget _buildAttachmentCards(
    BuildContext context,
    List<_ParsedAttachment> attachments,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final attachment in attachments)
          Builder(
            builder: (context) {
              final historyReference = attachment.historyReference;
              if (historyReference != null) {
                return AttachmentHistoryCard(
                  key: ValueKey(
                    'history-attachment-${historyReference.index}-'
                    '${historyReference.storageKey}',
                  ),
                  name: attachment.name,
                  sizeLabel: attachment.sizeLabel,
                  reference: historyReference,
                );
              }
              final imgPath = attachment.imagePath;
              final imgFile = (imgPath != null && File(imgPath).existsSync())
                  ? File(imgPath)
                  : null;
              return AttachmentCard(
                name: attachment.name,
                mimeType: '',
                sizeLabel: attachment.sizeLabel,
                thumbnailFile: imgFile,
                onTap: imgFile != null
                    ? () => showImageViewer(context, imgFile)
                    : null,
              );
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;

    // Los blobs de sistema (cron/skill/compactación) los intercepta el
    // renderizador central (_buildRenderUnit → _SystemBlobChip), antes de llegar
    // aquí, así que en este punto `content` ya es un mensaje real del usuario.
    final List<String> metaLines = _buildMetaLines(verbose, metadata);
    final timestamp = _formatMessageTimestamp(metadata);
    final parsed = _parseUserContent(content);
    final bubbleMeasureKey = GlobalKey();

    return ChatMessageSelectionArea(
      enabled: !editing,
      selectionIdentity: metadata['message_id'] ?? metadata['id'] ?? metadata,
      child: Padding(
        padding: EdgeInsets.only(
          left: 56,
          right: 12,
          top: compact ? 5 : 11,
          bottom: compact ? 1 : 3,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            KeyedSubtree(
              key: const ValueKey('user-message-bubble'),
              child: Container(
                key: bubbleMeasureKey,
                // Mientras se edita la burbuja se ensancha al ancho máximo de
                // una burbuja normal (alineada a la derecha) para que el texto
                // tenga sitio, en vez de quedarse con el ancho del original.
                width: editing ? double.infinity : null,
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: compact ? 8 : 11,
                ),
                // Burbuja estilo Claude: panel suave uniforme, redondeado, SIN
                // borde. El mensaje del agente va en texto plano; el del usuario
                // en esta burbuja sutil.
                decoration: BoxDecoration(
                  color: colors.surfaceVariant.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: editing
                    ? InlineMessageEditor(
                        initialText: editingText ?? parsed.text.trim(),
                        saving: editSaving,
                        attachments: parsed.attachments.isEmpty
                            ? null
                            : _buildAttachmentCards(
                                context,
                                parsed.attachments,
                              ),
                        onCancel: onCancelEdit!,
                        onSave: onSaveEdit!,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (metaLines.isNotEmpty)
                            _MetaBlock(lines: metaLines, onDark: true),
                          if (parsed.attachments.isNotEmpty)
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: parsed.text.isNotEmpty ? 8 : 0,
                              ),
                              child: _buildAttachmentCards(
                                context,
                                parsed.attachments,
                              ),
                            ),
                          if (parsed.text.isNotEmpty)
                            MarkdownBody(
                              data: parsed.text,
                              selectable: false,
                              // Respeta los saltos de línea simples (CommonMark los
                              // colapsaría en espacios → texto "todo junto").
                              softLineBreak: true,
                              onTapLink: (text, href, title) =>
                                  _openMarkdownLink(context, href),
                              styleSheet: _userSheet(theme, colors),
                            ),
                          if (supplements.isNotEmpty) ...[
                            const SizedBox(height: 11),
                            Divider(
                              height: 1,
                              color: colors.divider.withValues(alpha: 0.45),
                            ),
                            const SizedBox(height: 9),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.add_comment_outlined,
                                  size: 14,
                                  color: colors.accent,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    Strings.of(
                                      context,
                                    ).chaSteerSupplementsLabel,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            for (
                              var index = 0;
                              index < supplements.length;
                              index++
                            )
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: index == supplements.length - 1
                                      ? 0
                                      : 7,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 2,
                                      height: 18,
                                      margin: const EdgeInsets.only(
                                        top: 2,
                                        right: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: colors.accent.withValues(
                                          alpha: 0.55,
                                        ),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        supplements[index],
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.35,
                                          color: colors.textPrimary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ],
                      ),
              ),
            ),
            if (!editing)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onEdit != null)
                    IconButton(
                      onPressed: () {
                        final box =
                            bubbleMeasureKey.currentContext?.findRenderObject()
                                as RenderBox?;
                        if (box != null && box.hasSize) {
                          onEdit!(box.size.width);
                        }
                      },
                      tooltip: Strings.of(context).chaEditMessage,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: Icon(
                        Icons.edit_outlined,
                        size: 15,
                        color: colors.textSecondary,
                      ),
                    ),
                  // A-104 (spec 028): acción con nombre para TalkBack y target
                  // de 48dp (el icono visual sigue siendo discreto).
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: userMessageClipboardText(parsed.text),
                        ),
                      );
                      HermesNotice.of(context).showSnackBar(
                        SnackBar(
                          content: Text(Strings.of(context).chaCopied),
                          duration: Duration(seconds: 1),
                        ),
                        kind: HermesNoticeKind.success,
                      );
                    },
                    tooltip: Strings.of(context).chaCopyMessage,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: Icon(
                      Icons.copy_rounded,
                      size: 13,
                      color: colors.textSecondary,
                    ),
                  ),
                  if (timestamp != null) _MessageTimestamp(timestamp),
                ],
              ),
          ],
        ),
      ),
    );
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
  final enhanced = structured
      ? answer
      : prepareAssistantAnswerStructure(answer);
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
@visibleForTesting
String prepareAssistantAnswerStructure(String answer) =>
    enhanceCommandBlocks(tidyAssistantMarkdown(flattenInlineHtml(answer)));

@visibleForTesting
void validateRemoteChatImageTransport(Uri uri) {
  TransportPrivacy.requireAllowed(uri.toString());
}

@visibleForTesting
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

List<ChatTraceEvent> _assistantActivityEvents(
  BuildContext context,
  Map<String, dynamic> metadata,
  String legacyReasoning,
) {
  final s = Strings.of(context);
  final normalized = normalizeAssistantActivityTrace(
    metadata[assistantActivityTraceKey],
  );
  final events = <ChatTraceEvent>[];
  var hasReasoning = false;
  for (var index = 0; index < normalized.length; index++) {
    final step = normalized[index];
    final kind = switch (step['kind']) {
      'reasoning' => ChatTraceEventKind.reasoning,
      'skill' => ChatTraceEventKind.skill,
      _ => ChatTraceEventKind.tool,
    };
    hasReasoning |= kind == ChatTraceEventKind.reasoning;
    final preview = kind == ChatTraceEventKind.reasoning
        ? step['text']?.toString() ?? ''
        : '';
    final label = kind == ChatTraceEventKind.reasoning
        ? s.chatActivityReasoning
        : step['label']?.toString().trim() ?? '';
    if (label.isEmpty) continue;
    final measured = ActivityStep.fromTrace(step, index: index);
    events.add(
      ChatTraceEvent(
        id: step['id']?.toString() ?? 'activity-$index',
        label: label,
        status: step['status']?.toString() ?? 'completed',
        preview: preview,
        kind: kind,
        detail: measured?.detail,
        startedAt: measured?.startedAt,
        duration: measured?.duration,
      ),
    );
  }
  if (!hasReasoning && legacyReasoning.trim().isNotEmpty) {
    events.insert(
      0,
      ChatTraceEvent(
        id: 'reasoning',
        label: s.chatActivityReasoning,
        status: metadata['_pipeline'] == true ? 'running' : 'completed',
        preview: legacyReasoning.trim(),
        kind: ChatTraceEventKind.reasoning,
      ),
    );
  }
  return events;
}

Duration? _assistantActivityDuration(Map<String, dynamic> metadata) {
  final raw = metadata['_activity_duration_seconds'];
  if (raw is! num || !raw.isFinite || raw <= 0 || raw > 604800) return null;
  return Duration(milliseconds: (raw * 1000).round());
}

const double _assistantHeaderCompanionSize = 44;

class _AssistantHeaderCompanion extends StatelessWidget {
  const _AssistantHeaderCompanion({required this.mood, required this.animate});

  final HermesSparkMood mood;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (app == null) return const SizedBox.shrink();
    final companion = app.companion;
    return AnimatedBuilder(
      animation: companion,
      builder: (context, _) {
        final visible =
            companion.isInitialized &&
            companion.enabled &&
            companion.presenceLevel.showsStatusPresence;
        if (!visible) return const SizedBox.shrink();
        return SizedBox(
          width: 50,
          height: _assistantHeaderCompanionSize,
          child: Align(
            alignment: Alignment.centerLeft,
            child: CompanionStatusIndicator(
              key: const ValueKey('assistant-header-companion'),
              companion: companion,
              mood: mood,
              size: _assistantHeaderCompanionSize,
              animate: animate,
            ),
          ),
        );
      },
    );
  }
}

/// Cabecera de un mensaje del asistente: la mascota (o la inicial, sin
/// presencia) + título en acento + la segunda línea que pase el llamador.
class _AssistantAvatarHeader extends StatelessWidget {
  const _AssistantAvatarHeader({
    required this.name,
    required this.mood,
    required this.animate,
    this.subtitle,
    this.actions = const [],
  });

  final String name;
  final HermesSparkMood mood;
  final bool animate;
  final Widget? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    Widget header(Widget? mascot) => MessageAvatarHeader(
      name: name,
      mascot: mascot,
      subtitle: subtitle,
      actions: actions,
    );
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (app == null) return header(null);
    final companion = app.companion;
    return AnimatedBuilder(
      animation: companion,
      builder: (context, _) {
        final visible =
            companion.isInitialized &&
            companion.enabled &&
            companion.presenceLevel.showsStatusPresence;
        return header(
          visible
              ? CompanionStatusIndicator(
                  key: const ValueKey('assistant-header-companion'),
                  companion: companion,
                  mood: mood,
                  size: kAvatarMascotSize,
                  animate: animate,
                )
              : null,
        );
      },
    );
  }
}

/// Cabecera del turno en vivo antes de que haya texto: el estado lo cuenta la
/// pastilla sobre el compositor; aquí, una sola palabra apagada.
class _AssistantLiveHeader extends StatelessWidget {
  const _AssistantLiveHeader({required this.agentName, required this.mood});

  final String agentName;
  final HermesSparkMood mood;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 16, 0),
      child: _AssistantAvatarHeader(
        name: agentName,
        mood: mood,
        animate: true,
        subtitle: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            Strings.of(context).liveHeaderWorking,
            key: const ValueKey('assistant-header-working'),
            style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  final String content;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final Map<String, _LinkPreviewData?> linkCache;
  final Future<void> Function(String url) fetchLinkPreview;
  final String? Function(String text) firstUrl;
  final VoidCallback? onSpeak;
  final ValueListenable<ReadAloudSnapshot>? readAloud;
  final String? readAloudMessageKey;
  final ReadAloudStopBehavior readAloudStopBehavior;
  final String agentName;
  final bool isStreaming;
  final HermesSparkMood? companionMood;
  final bool waitingForUser;
  final _AssistantRenderSlice? slice;
  final _AssistantTerminalProjection? terminalProjection;
  final List<String> technicalDetails;
  final VoidCallback? onRegenerate;
  final AssistantSuggestionCallback? onSuggestionSelected;
  final bool compact;
  final ChatPerformanceProbe? performanceProbe;

  const _AssistantMessage({
    required this.content,
    required this.linkCache,
    required this.fetchLinkPreview,
    required this.firstUrl,
    this.verbose = false,
    this.metadata = const {},
    this.onSpeak,
    this.readAloud,
    this.readAloudMessageKey,
    this.readAloudStopBehavior = ReadAloudStopBehavior.pauseAndResume,
    this.agentName = 'hermes',
    this.isStreaming = false,
    this.companionMood,
    this.waitingForUser = false,
    this.slice,
    this.terminalProjection,
    this.technicalDetails = const [],
    this.onRegenerate,
    this.onSuggestionSelected,
    this.compact = false,
    this.performanceProbe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;

    final List<String> metaLines = _buildMetaLines(verbose, metadata);
    final timestamp = _formatMessageTimestamp(metadata);

    final parsedSplit =
        terminalProjection?.split ??
        slice?.plan.split ??
        splitReasoning(content);
    final split = mergeStructuredReasoning(
      ReasoningSplit(reasoning: '', answer: parsedSplit.answer),
      {'reasoning': metadata['reasoning']},
    );
    final showHeader = slice?.showHeader ?? true;
    final showFooter = slice?.showFooter ?? true;
    final activityEvents = _assistantActivityEvents(
      context,
      metadata,
      split.reasoning,
    );
    final activityActive =
        activityEvents.isNotEmpty &&
        (isStreaming || metadata['_pipeline'] == true);
    final stopped = metadata['_stopped'] == true;
    final activityOutcome = traceOutcome(
      events: activityEvents,
      active: activityActive,
      stopped: stopped,
    );
    final headerMood =
        companionMood ??
        switch (activityOutcome) {
          TraceOutcome.working => HermesSparkMood.thinking,
          TraceOutcome.stopped => HermesSparkMood.idle,
          TraceOutcome.failed => HermesSparkMood.error,
          TraceOutcome.completed ||
          TraceOutcome.recovered => HermesSparkMood.success,
        };
    final headerAnimated = isStreaming || metadata['_pipeline'] == true;
    final showTrace = showHeader && (activityEvents.isNotEmpty || stopped);
    final structuredImages = _structuredGeneratedImages(metadata);
    final structuredVideos = _structuredGeneratedVideos(metadata);
    final textualGeneratedBasenames = <String, int>{};
    final textualGeneratedVideoSources = <String, int>{};
    if (structuredImages.isNotEmpty) {
      for (final segment in GeneratedImageService.segments(
        split.answer,
      ).whereType<ImageSegment>()) {
        final key = segment.basename.toLowerCase();
        textualGeneratedBasenames[key] =
            (textualGeneratedBasenames[key] ?? 0) + 1;
      }
    }
    if (structuredVideos.isNotEmpty) {
      for (final segment in GeneratedMediaService.parseSegments(
        split.answer,
      ).whereType<GeneratedMediaFileSegment>()) {
        final reference = segment.reference;
        if (reference.kind != GeneratedMediaKind.video) continue;
        textualGeneratedVideoSources[reference.source] =
            (textualGeneratedVideoSources[reference.source] ?? 0) + 1;
      }
    }
    final structuredFooterImages = showFooter
        ? structuredImages
              .where((ref) {
                final basename = ref.basename;
                if (ref.kind != GeneratedImageSourceKind.serverCache ||
                    basename == null) {
                  return true;
                }
                final key = basename.toLowerCase();
                final remaining = textualGeneratedBasenames[key] ?? 0;
                if (remaining <= 0) return true;
                textualGeneratedBasenames[key] = remaining - 1;
                return false;
              })
              .toList(growable: false)
        : const <_StructuredGeneratedImage>[];
    final structuredFooterVideos = showFooter
        ? structuredVideos
              .where((ref) {
                final source = ref.reference.source;
                final remaining = textualGeneratedVideoSources[source] ?? 0;
                if (remaining <= 0) return true;
                textualGeneratedVideoSources[source] = remaining - 1;
                return false;
              })
              .toList(growable: false)
        : const <_StructuredGeneratedVideo>[];
    String stripStructuredEchoes(String text) =>
        _stripStructuredGeneratedImageEchoes(text, structuredImages);
    final suggestionProjection =
        terminalProjection?.suggestions ??
        (!isStreaming && showFooter && onSuggestionSelected != null
            ? projectAssistantSuggestions(split.answer)
            : AssistantSuggestionsProjection(body: split.answer));
    final answer = suggestionProjection.body;

    // Un bloque de Markdown de la respuesta, con la presentación de siempre.
    // El [data] ya viene normalizado por [buildAssistantAnswerBlocks].
    MarkdownBody markdownWidget(String data) => MarkdownBody(
      data: data,
      selectable: false,
      // CommonMark conserva los párrafos (líneas en blanco) y trata un salto
      // simple como espacio. Mostrar cada salto interno del modelo partía
      // frases después de paréntesis y hacía la respuesta demasiado estrecha.
      softLineBreak: false,
      onTapLink: (text, href, title) => _openMarkdownLink(context, href),
      sizedImageBuilder: (config) => _GatedChatImage(
        uri: config.uri,
        width: config.width,
        height: config.height,
        colors: colors,
      ),
      styleSheet: _assistantSheet(context, data),
      builders: {'pre': _PreCodeBuilder()},
    );

    /// Reparte un segmento vivo en prefijo estable cacheable + cola mutable.
    /// Solo la cola se reconstruye en cada frame; el prefijo conserva el mismo
    /// widget mientras su contenido no cambie (ni parseo ni resaltado nuevos).
    Iterable<Widget> streamingSplitWidgets(String text) sync* {
      final prepared = prepareAssistantAnswerStructure(text);
      final escaped = escapePathGlobs(prepared);
      final tailStart = streamingMarkdownTailStart(escaped);
      if (tailStart <= 0) {
        yield markdownWidget(
          normalizeStreamingMarkdown(escaped, isStreaming: true),
        );
        return;
      }
      final tail = normalizeStreamingMarkdown(
        escaped.substring(tailStart),
        isStreaming: true,
      );
      final stable = escaped.substring(0, tailStart);
      if (stable.trim().isNotEmpty) {
        yield _StableStreamingMarkdown(
          data: stable,
          markdown: markdownWidget,
          performanceProbe: performanceProbe,
        );
        if (tail.trim().isNotEmpty) {
          // La costura reproduce el blockSpacing (10) que separa esos bloques
          // cuando todo el segmento vive en un único MarkdownBody.
          yield const SizedBox(height: 10);
        }
      }
      if (tail.trim().isNotEmpty) yield markdownWidget(tail);
    }

    Iterable<Widget> structuredVideoWidgets() sync* {
      for (final ref in structuredFooterVideos) {
        yield _GeneratedMediaSlot(key: ref.widgetKey, reference: ref.reference);
      }
    }

    Iterable<Widget> answerWidgets() sync* {
      final projected = terminalProjection;
      if (projected != null) {
        var generatedMediaOrdinal = 0;
        for (final block in projected.blocks) {
          switch (block) {
            case _ProjectedAssistantMarkdown(:final data):
              final visible = stripStructuredEchoes(data);
              if (visible.trim().isNotEmpty) yield markdownWidget(visible);
            case _ProjectedAssistantTable(:final rows):
              yield MarkdownTable(
                rows: rows,
                onLinkTap: (href) => _openMarkdownLink(context, href),
              );
            case _ProjectedAssistantImage(:final basename):
              final ref = _StructuredGeneratedImage.textPath(basename);
              yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
            case _ProjectedAssistantMedia(:final reference):
              yield _GeneratedMediaSlot(
                key: _generatedMediaWidgetKey(
                  reference,
                  generatedMediaOrdinal++,
                ),
                reference: reference,
              );
            case _ProjectedAssistantGap():
              yield const SizedBox(height: 4);
          }
        }
        for (final ref in structuredFooterImages) {
          yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
        }
        yield* structuredVideoWidgets();
        return;
      }
      final renderSlice = slice;
      if (renderSlice != null) {
        switch (renderSlice.body) {
          case _AssistantGeneratedImageChunk(:final basename):
            final ref = _StructuredGeneratedImage.textPath(basename);
            yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
          case _AssistantGeneratedMediaChunk(:final reference):
            yield _GeneratedMediaSlot(
              key: _generatedMediaWidgetKey(reference, renderSlice.index),
              reference: reference,
            );
          case _AssistantMarkdownChunk(:final data):
            yield* buildAssistantAnswerBlocks(
              stripStructuredEchoes(data),
              isStreaming: false,
              structured: true,
              markdown: markdownWidget,
              callout: (block) => CalloutCard(
                kind: block.kind,
                title: block.title,
                body: block.body,
              ),
              onLinkTap: (href) => _openMarkdownLink(context, href),
            );
        }
        for (final ref in structuredFooterImages) {
          yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
        }
        yield* structuredVideoWidgets();
        return;
      }
      var generatedMediaOrdinal = 0;
      for (final mediaSegment in GeneratedMediaService.parseSegments(answer)) {
        if (mediaSegment is GeneratedMediaFileSegment) {
          yield _GeneratedMediaSlot(
            key: _generatedMediaWidgetKey(
              mediaSegment.reference,
              generatedMediaOrdinal++,
            ),
            reference: mediaSegment.reference,
          );
          continue;
        }
        final mediaText = (mediaSegment as GeneratedMediaTextSegment).text;
        for (final segment in GeneratedImageService.segments(mediaText)) {
          if (segment is ImageSegment) {
            final ref = _StructuredGeneratedImage.textPath(segment.basename);
            yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
            continue;
          }
          final text = stripStructuredEchoes((segment as TextSegment).text);
          if (text.trim().isEmpty) continue;
          // Respuesta viva larga: el prefijo de bloques cerrados se proyecta una
          // sola vez por contenido; cada frame solo normaliza y parsea la cola
          // mutable. El texto resultante es byte a byte el mismo que el de la
          // ruta de bloque único (las reparaciones son independientes por bloque).
          if (isStreaming && text.length >= _liveAssistantStableSplitMinChars) {
            yield* streamingSplitWidgets(text);
            continue;
          }
          yield* buildAssistantAnswerBlocks(
            text,
            isStreaming: isStreaming,
            markdown: markdownWidget,
            callout: (block) => CalloutCard(
              kind: block.kind,
              title: block.title,
              body: block.body,
            ),
            onLinkTap: (href) => _openMarkdownLink(context, href),
          );
        }
      }
      for (final ref in structuredFooterImages) {
        yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
      }
      yield* structuredVideoWidgets();
    }

    // La copia completa vive en la cabecera y la selección parcial en la región
    // exterior. El Markdown permanece como texto normal: ningún párrafo crea un
    // EditableText que pueda mover el scroll al mostrar sus tiradores.
    return ChatMessageSelectionArea(
      enabled: !isStreaming,
      selectionIdentity: metadata['message_id'] ?? metadata['id'] ?? metadata,
      child: Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 16,
          top: showHeader ? (compact ? 5 : 11) : 0,
          bottom: showFooter ? (compact ? 1 : 3) : 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: showTrace
                    ? ThinkingTraceCard(
                        key: const ValueKey('assistant-activity-trace'),
                        events: activityEvents,
                        active: isStreaming || metadata['_pipeline'] == true,
                        liveInPill: true,
                        headline: Strings.of(context).chatActivityThinking,
                        activeMood: headerMood,
                        waitingForUser: activityActive && waitingForUser,
                        stopped: stopped,
                        duration: _assistantActivityDuration(metadata),
                        headerBuilder: (context, summary, details) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _AssistantAvatarHeader(
                              name: agentName,
                              mood: headerMood,
                              animate: headerAnimated,
                              subtitle: summary,
                              actions: [
                                if (onSpeak != null &&
                                    readAloudMessageKey != null) ...[
                                  const SizedBox(width: 6),
                                  ReadAloudButton(
                                    messageKey: readAloudMessageKey!,
                                    state: readAloud,
                                    stopBehavior: readAloudStopBehavior,
                                    onPressed: onSpeak,
                                  ),
                                ],
                                Semantics(
                                  button: true,
                                  label: Strings.of(context).chaCopyMessage,
                                  excludeSemantics: true,
                                  child: Tooltip(
                                    message: Strings.of(context).chaCopyMessage,
                                    child: InkWell(
                                      onTap: () {
                                        Clipboard.setData(
                                          ClipboardData(
                                            text: markdownToClipboardText(
                                              GeneratedMediaService.stripDirectives(
                                                answer,
                                              ),
                                            ),
                                          ),
                                        );
                                        HermesNotice.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              Strings.of(context).chaCopied,
                                            ),
                                            duration: Duration(seconds: 1),
                                          ),
                                          kind: HermesNoticeKind.success,
                                        );
                                      },
                                      borderRadius: BorderRadius.circular(24),
                                      child: SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: Center(
                                          child: Icon(
                                            Icons.copy_rounded,
                                            size: 16,
                                            color: colors.textSecondary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (onRegenerate != null)
                                  Semantics(
                                    button: true,
                                    label: Strings.of(context).chaRegenerate,
                                    excludeSemantics: true,
                                    child: Tooltip(
                                      message: Strings.of(
                                        context,
                                      ).chaRegenerate,
                                      child: InkWell(
                                        onTap: onRegenerate,
                                        borderRadius: BorderRadius.circular(24),
                                        child: SizedBox(
                                          width: 48,
                                          height: 48,
                                          child: Center(
                                            child: Icon(
                                              Icons.refresh_rounded,
                                              size: 18,
                                              color: colors.textSecondary,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            details,
                          ],
                        ),
                      )
                    : _AssistantAvatarHeader(
                        name: agentName,
                        mood: headerMood,
                        animate: headerAnimated,
                        actions: [
                          if (onSpeak != null &&
                              readAloudMessageKey != null) ...[
                            const SizedBox(width: 6),
                            ReadAloudButton(
                              messageKey: readAloudMessageKey!,
                              state: readAloud,
                              stopBehavior: readAloudStopBehavior,
                              onPressed: onSpeak,
                            ),
                          ],
                          Semantics(
                            button: true,
                            label: Strings.of(context).chaCopyMessage,
                            excludeSemantics: true,
                            child: Tooltip(
                              message: Strings.of(context).chaCopyMessage,
                              child: InkWell(
                                onTap: () {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text: markdownToClipboardText(
                                        GeneratedMediaService.stripDirectives(
                                          answer,
                                        ),
                                      ),
                                    ),
                                  );
                                  HermesNotice.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        Strings.of(context).chaCopied,
                                      ),
                                      duration: Duration(seconds: 1),
                                    ),
                                    kind: HermesNoticeKind.success,
                                  );
                                },
                                borderRadius: BorderRadius.circular(24),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Center(
                                    child: Icon(
                                      Icons.copy_rounded,
                                      size: 16,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (onRegenerate != null)
                            Semantics(
                              button: true,
                              label: Strings.of(context).chaRegenerate,
                              excludeSemantics: true,
                              child: Tooltip(
                                message: Strings.of(context).chaRegenerate,
                                child: InkWell(
                                  onTap: onRegenerate,
                                  borderRadius: BorderRadius.circular(24),
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Center(
                                      child: Icon(
                                        Icons.refresh_rounded,
                                        size: 18,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            if (showHeader && metaLines.isNotEmpty)
              _MetaBlock(lines: metaLines, onDark: false),
            if (answer.isNotEmpty) ...answerWidgets(),
            if (showFooter && technicalDetails.isNotEmpty)
              _AssistantTechnicalDetails(details: technicalDetails),
            if (showFooter && suggestionProjection.hasSuggestions)
              HermesSuggestions(
                suggestions: suggestionProjection.suggestions,
                onSelected: onSuggestionSelected!,
              ),
            if (showFooter && metadata['show_link_preview'] == true)
              Builder(
                builder: (ctx) {
                  final first = firstUrl(
                    GeneratedMediaService.stripDirectives(answer),
                  );
                  if (first == null) return const SizedBox.shrink();
                  return _LinkPreviewLoader(
                    url: first,
                    linkCache: linkCache,
                    fetchLinkPreview: fetchLinkPreview,
                  );
                },
              ),
            if (showFooter && timestamp != null) _MessageTimestamp(timestamp),
          ],
        ),
      ),
    );
  }
}

/// IDs y envelopes operativos conservados bajo demanda.
///
/// La respuesta cotidiana muestra etiquetas humanas. Este disclosure permite
/// diagnosticar o copiar los valores originales sin convertirlos en el
/// headline del mensaje ni depender de selección de texto inestable.
class _AssistantTechnicalDetails extends StatefulWidget {
  final List<String> details;

  const _AssistantTechnicalDetails({required this.details});

  @override
  State<_AssistantTechnicalDetails> createState() =>
      _AssistantTechnicalDetailsState();
}

class _AssistantTechnicalDetailsState
    extends State<_AssistantTechnicalDetails> {
  bool _expanded = false;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.details.join('\n')));
    HapticFeedback.selectionClick();
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).chaCopied),
        duration: const Duration(milliseconds: 900),
      ),
      kind: HermesNoticeKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: strings.ieTechnicalDetails,
            excludeSemantics: true,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 15,
                        color: colors.textDisabled,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        strings.ieTechnicalDetails,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 17,
                          color: colors.textDisabled,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 22, right: 2, bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: SingleChildScrollView(
                        primary: false,
                        child: Text(
                          widget.details.join('\n'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.45,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: strings.chaCopyMessage,
                    excludeSemantics: true,
                    child: IconButton(
                      onPressed: () => _copy(context),
                      tooltip: strings.chaCopyMessage,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: Icon(
                        Icons.copy_rounded,
                        size: 15,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
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
            throw const FormatException('imagen del servidor sin nombre');
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

/// Canonical `MEDIA:` attachment rendered from the authenticated managed-file
/// API. The server path never appears in visible UI and the downloaded copy is
/// kept in app-private storage.
class _GeneratedMediaSlot extends StatefulWidget {
  final GeneratedMediaReference reference;
  const _GeneratedMediaSlot({super.key, required this.reference});

  @override
  State<_GeneratedMediaSlot> createState() => _GeneratedMediaSlotState();
}

class _GeneratedMediaSlotState extends State<_GeneratedMediaSlot> {
  String _downloadErrorLabel(BuildContext context, Object error) {
    final strings = Strings.of(context);
    if (error is DashboardAuthException &&
        error.code == DashboardAuthFailureCode.rateLimited) {
      return strings.dashboardAuthRateLimited;
    }
    if (error is DashboardHttpException) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        return strings.genMediaDenied;
      }
      if (error.statusCode == 404) return strings.genMediaUnavailable;
    }
    final message = error.toString().toLowerCase();
    if (message.contains('exceeds') || message.contains('too large')) {
      return strings.genMediaTooLarge;
    }
    if (message.contains('incomplete') ||
        message.contains('before content-length')) {
      return strings.genMediaIncomplete;
    }
    return strings.genMediaError;
  }

  Future<void> _open(
    BuildContext context,
    File file,
    int length,
    VoidCallback onOpenExternal,
    VoidCallback onShare,
    VoidCallback onSave,
  ) async {
    final isPdf =
        widget.reference.mimeType == 'application/pdf' ||
        widget.reference.displayName.toLowerCase().endsWith('.pdf');
    if (!isPdf) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => GeneratedFileViewerScreen(
            name: widget.reference.displayName,
            mimeType: widget.reference.mimeType,
            sizeBytes: length,
            onOpenWith: onOpenExternal,
            onShare: onShare,
            onSave: onSave,
          ),
        ),
      );
      return;
    }
    try {
      final digest = (await sha256.bind(file.openRead()).first).toString();
      var reference = AttachmentHistoryReference(
        index: 0,
        storageKey: digest,
        type: AttachmentType.document,
        mimeType: widget.reference.mimeType,
        sizeBytes: length,
        sha256Hex: digest,
      );
      var previewFile = file;
      if (widget.reference.mimeType == 'application/pdf' ||
          widget.reference.displayName.toLowerCase().endsWith('.pdf')) {
        final persisted = await AttachmentUploader.persistForHistory(
          AttachmentDraft(
            type: AttachmentType.document,
            name: widget.reference.displayName,
            mimeType: widget.reference.mimeType,
            sizeBytes: length,
            localPath: file.path,
          ),
          index: 0,
        );
        if (persisted != null) {
          final resolved = await AttachmentUploader.resolveHistoryReference(
            persisted,
          );
          if (resolved != null) {
            reference = persisted;
            previewFile = resolved;
          }
        }
      }
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => AttachmentBytesPreviewScreen(
            name: widget.reference.displayName,
            sizeLabel: _formatGeneratedFileBytes(length),
            reference: reference,
            file: previewFile,
            onOpenExternal: onOpenExternal,
            onShare: onShare,
            onSave: onSave,
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).genMediaError)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_ChatScreenState>();
    if (state == null) return const SizedBox.shrink();
    return GeneratedMediaAttachmentCard(
      reference: widget.reference,
      autoLoad:
          widget.reference.sourceKind == GeneratedMediaSourceKind.serverPath,
      load: (onProgress, isCancelled) => state.downloadGeneratedMedia(
        widget.reference,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
      errorLabelBuilder: _downloadErrorLabel,
      onOpen: _open,
      readyBuilder:
          (context, file, sizeBytes, onOpenExternal, onShare, onSave) {
            if (widget.reference.mimeType == 'application/pdf' ||
                widget.reference.displayName.toLowerCase().endsWith('.pdf')) {
              return GeneratedPdfPreviewCard(
                file: file,
                name: widget.reference.displayName,
                sizeBytes: sizeBytes,
                onOpen: () => _open(
                  context,
                  file,
                  sizeBytes,
                  onOpenExternal,
                  onShare,
                  onSave,
                ),
                onShare: onShare,
                onSave: onSave,
              );
            }
            return switch (widget.reference.kind) {
              GeneratedMediaKind.image => GeneratedImageCard(
                status: GeneratedImageStatus.ready,
                file: file,
              ),
              GeneratedMediaKind.video => GeneratedVideoCard(file: file),
              GeneratedMediaKind.audio || GeneratedMediaKind.file => null,
            };
          },
    );
  }
}

String _formatGeneratedFileBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
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

List<String> _buildMetaLines(bool verbose, Map<String, dynamic> metadata) {
  if (!verbose) return const [];
  final role = metadata['role']?.toString().trim();
  return ['role: ${role == null || role.isEmpty ? 'unknown' : role}'];
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

class _MessageTimestamp extends StatelessWidget {
  final String value;

  const _MessageTimestamp(this.value);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
      child: Text(
        value,
        // A-202 (spec 028): timestamps en mono (§8/§3); A-112: textSecondary
        // para que el texto informativo llegue a 4.5:1.
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          color: colors.textSecondary,
        ),
      ),
    );
  }
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

class _MetaBlock extends StatelessWidget {
  final List<String> lines;
  final bool onDark;
  const _MetaBlock({required this.lines, required this.onDark});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        // Ambas burbujas son oscuras ahora; el bloque meta se distingue por
        // un velo negro sutil en las dos variantes.
        color: Colors.black.withValues(alpha: onDark ? 0.25 : 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: lines
            .map(
              (l) => Text(
                l,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            )
            .toList(),
      ),
    );
  }
}

/// Fila compacta para un seguimiento pendiente: comparte el eje del composer,
/// no ocupa un turno visual y se puede retirar antes del envío automático.
class _QueuedRow extends StatelessWidget {
  final QueuedEntryView entry;
  final List<String> attachmentNames;
  final bool busy;
  final bool transportCanSteer;
  final String? editingId;
  final VoidCallback onEdit;
  final VoidCallback onSteer;
  final VoidCallback onSendNow;
  final VoidCallback onDelete;

  const _QueuedRow({
    required this.entry,
    this.attachmentNames = const [],
    required this.busy,
    required this.transportCanSteer,
    required this.editingId,
    required this.onEdit,
    required this.onSteer,
    required this.onSendNow,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final preview = entry.text.length > 72
        ? '${entry.text.substring(0, 72)}…'
        : entry.text;
    final isEditing = editingId == entry.id;
    final accepted = entry.kind == QueuedEntryKind.desktopAccepted;
    final editEnabled = !accepted && (editingId == null || isEditing);
    final canSteer =
        busy &&
        transportCanSteer &&
        entry.isSteerable &&
        !isEditing &&
        !accepted;
    final sendLabel = busy ? strings.chaQueueSendNext : strings.chaQueueSend;
    Widget action({
      required String keyName,
      required String label,
      required IconData icon,
      required VoidCallback? onPressed,
    }) => Semantics(
      key: ValueKey(keyName),
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: IconButton(
        onPressed: onPressed,
        tooltip: label,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 17, color: colors.textSecondary),
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Icon(
            Icons.subdirectory_arrow_right_rounded,
            size: 16,
            color: colors.textDisabled,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (preview.trim().isNotEmpty)
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.25,
                      color: colors.textSecondary,
                    ),
                  ),
                if (entry.blocked)
                  Text(
                    Strings.of(context).chatQueueBlockedRetry,
                    key: ValueKey('chat-queue-blocked-${entry.id}'),
                    style: TextStyle(fontSize: 10.5, color: colors.warning),
                  ),
                if (attachmentNames.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: attachmentNames
                        .map(
                          (name) => Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: colors.textDisabled,
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
              ],
            ),
          ),
          action(
            keyName: 'chat-queue-edit-${entry.id}',
            label: strings.chaQueueEdit,
            icon: Icons.edit_outlined,
            onPressed: editEnabled ? onEdit : null,
          ),
          if (canSteer)
            action(
              keyName: 'chat-queue-steer-${entry.id}',
              label: strings.chaQueueSteer,
              icon: Icons.turn_right_rounded,
              onPressed: onSteer,
            ),
          action(
            keyName: 'chat-queue-send-now-${entry.id}',
            label: sendLabel,
            icon: Icons.keyboard_return_rounded,
            onPressed: isEditing || accepted ? null : onSendNow,
          ),
          action(
            keyName: 'chat-queue-delete-${entry.id}',
            label: strings.chaQueueDelete,
            icon: Icons.delete_outline_rounded,
            onPressed: accepted ? null : onDelete,
          ),
        ],
      ),
    );
  }
}

/// Reserves [gap] pixels BELOW its child, but only while the child actually
/// occupies height.
///
/// The floating activity pill (`ActivityPillHost`, the one pill for everything
/// live) collapses to `SizedBox.shrink` when there is nothing to report, so a
/// plain `Padding` would keep its breathing room reserved forever and leave the
/// scroll-to-bottom arrow stranded [gap] pixels above its resting offset.
/// Resolving it during layout (instead of measuring in one frame and
/// repositioning in the next) means the arrow never jumps and never spends a
/// frame sitting under a pill.
class _BottomGapWhenVisible extends SingleChildRenderObjectWidget {
  const _BottomGapWhenVisible({
    required this.gap,
    required Widget super.child,
    this.onExtent,
  });

  final double gap;

  /// Recibe el alto total (pastilla + hueco) tras cada layout; 0 si colapsa.
  final ValueChanged<double>? onExtent;

  @override
  _RenderBottomGapWhenVisible createRenderObject(BuildContext context) =>
      _RenderBottomGapWhenVisible(gap, onExtent);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBottomGapWhenVisible renderObject,
  ) {
    renderObject
      ..gap = gap
      ..onExtent = onExtent;
  }
}

class _RenderBottomGapWhenVisible extends RenderShiftedBox {
  _RenderBottomGapWhenVisible(this._gap, this.onExtent) : super(null);

  double _gap;
  ValueChanged<double>? onExtent;
  double? _reportedExtent;

  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  Size _measure(BoxConstraints constraints, ChildLayouter layoutChild) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final childSize = layoutChild(child, constraints);
    if (childSize.height <= 0) return constraints.constrain(childSize);
    return constraints.constrain(
      Size(childSize.width, childSize.height + _gap),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _measure(constraints, ChildLayoutHelper.dryLayoutChild);

  @override
  void performLayout() {
    size = _measure(constraints, ChildLayoutHelper.layoutChild);
    final child = this.child;
    if (child != null) {
      (child.parentData! as BoxParentData).offset = Offset.zero;
    }
    final height = size.height;
    if (height != _reportedExtent) {
      _reportedExtent = height;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onExtent?.call(height),
      );
    }
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    final child = this.child;
    if (child == null) return 0;
    final height = child.getMinIntrinsicHeight(width);
    return height <= 0 ? height : height + _gap;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    final child = this.child;
    if (child == null) return 0;
    final height = child.getMaxIntrinsicHeight(width);
    return height <= 0 ? height : height + _gap;
  }
}

class _ScrollToBottomButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ScrollToBottomButton({required this.onTap, super.key});

  @override
  Widget build(BuildContext context) => _ChatScrollButton(
    onTap: onTap,
    label: Strings.of(context).chaScrollToBottom,
    icon: Icons.keyboard_arrow_down,
    iconSize: 20,
  );
}

class _ChatTopButton extends StatefulWidget {
  const _ChatTopButton({
    required this.controller,
    required this.hasEarlierMessages,
    required this.loading,
    required this.contentChanges,
    required this.transcriptOverlayExtent,
    required this.onLoadEarlier,
  });

  final ScrollController controller;
  final bool hasEarlierMessages;
  final bool loading;
  final Listenable contentChanges;
  final ValueGetter<double> transcriptOverlayExtent;
  final VoidCallback onLoadEarlier;

  @override
  State<_ChatTopButton> createState() => _ChatTopButtonState();
}

class _ChatTopButtonState extends State<_ChatTopButton> {
  // La flecha de subir es solo para cargar historial real, no un atajo
  // genérico de "ir arriba" dentro de lo ya cargado: su visibilidad refleja
  // únicamente hasEarlierMessages (la señal real del backend de que hay más
  // que pedir), nunca la posición del scroll dentro de lo ya visible — ni
  // controller ni contentChanges intervienen en si se muestra o no.
  bool get _visible => widget.hasEarlierMessages;

  void _activate() {
    if (!widget.hasEarlierMessages) return;
    widget.onLoadEarlier();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 120),
      transitionBuilder: (child, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final exiting = animation.status == AnimationStatus.reverse;
          return IgnorePointer(
            ignoring: exiting,
            child: ExcludeSemantics(
              excluding: exiting,
              child: FadeTransition(
                opacity: animation,
                alwaysIncludeSemantics: !exiting,
                child: child,
              ),
            ),
          );
        },
        child: child,
      ),
      child: _visible
          ? _ChatScrollButton(
              key: const ValueKey('chat-load-earlier'),
              onTap: widget.loading ? null : _activate,
              label: Strings.of(context).chaLoadEarlierMessages,
              icon: Icons.keyboard_arrow_up_rounded,
              iconSize: 20,
              loading: widget.loading,
            )
          : const SizedBox.shrink(key: ValueKey('chat-top-button-hidden')),
    ),
  );
}

class _ChatScrollButton extends StatelessWidget {
  final VoidCallback? onTap;
  final String label;
  final IconData icon;
  final double iconSize;
  final bool loading;

  const _ChatScrollButton({
    super.key,
    required this.onTap,
    required this.label,
    required this.icon,
    this.iconSize = 18,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Nombre y rol para TalkBack + target táctil de 48dp; el círculo visual se
    // mantiene discreto para no tapar la respuesta.
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colors.divider.withValues(alpha: 0.55),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: loading
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.accent,
                        ),
                      )
                    : Icon(icon, size: iconSize, color: colors.accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ancla visual de un mensaje del asistente. Al ser un RenderObject ligero no
/// mueve ni reutiliza el árbol Markdown cuando cambia el último turno.
@visibleForTesting
class ChatAnswerAnchor extends SingleChildRenderObjectWidget {
  final ValueChanged<RenderBox> onLayout;
  final ValueChanged<RenderBox>? onDetach;

  const ChatAnswerAnchor({
    super.key,
    required this.onLayout,
    this.onDetach,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      ChatAnswerAnchorRenderBox(onLayout, onDetach);

  @override
  void updateRenderObject(
    BuildContext context,
    ChatAnswerAnchorRenderBox renderObject,
  ) {
    renderObject
      ..onLayout = onLayout
      ..onDetach = onDetach;
  }
}

@visibleForTesting
class ChatAnswerAnchorRenderBox extends RenderProxyBox {
  ValueChanged<RenderBox> onLayout;
  ValueChanged<RenderBox>? onDetach;
  double? laidOutHeight;

  ChatAnswerAnchorRenderBox(this.onLayout, this.onDetach);

  @override
  void performLayout() {
    super.performLayout();
    laidOutHeight = size.height;
    onLayout(this);
  }

  @override
  void detach() {
    onDetach?.call(this);
    super.detach();
  }
}

/// Detecta la intención de leer antes de que Flutter determine la dirección del
/// scroll. Es pública solo para cubrir la regresión con un widget test.
@visibleForTesting
class ChatScrollInteractionGuard extends StatelessWidget {
  final Widget child;
  final PointerDownEventListener onPointerDown;
  final PointerMoveEventListener? onPointerMove;
  final PointerUpEventListener? onPointerUp;
  final PointerCancelEventListener? onPointerCancel;

  const ChatScrollInteractionGuard({
    super.key,
    required this.child,
    required this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
    this.onPointerCancel,
  });

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: onPointerDown,
    onPointerMove: onPointerMove,
    onPointerUp: onPointerUp,
    onPointerCancel: onPointerCancel,
    child: child,
  );
}

/// Mantiene el contenido visible anclado cuando el primer hijo de una lista
/// invertida aumenta de altura durante streaming.
///
/// Flutter conserva por defecto `pixels`; en un chat `reverse:true`, sin
/// embargo, el contenido nuevo se inserta entre ese offset y el fondo. Sumar el
/// crecimiento real del asistente conserva la misma coordenada visual. La
/// corrección ocurre en `adjustPositionForNewDimensions`, antes de pintar y sin
/// sustituir la actividad de scroll activa.
class _ChatStreamingViewportPhysics extends ScrollPhysics {
  final _ChatStreamingViewportLock lock;

  const _ChatStreamingViewportPhysics({required this.lock, super.parent});

  @override
  _ChatStreamingViewportPhysics applyTo(ScrollPhysics? ancestor) {
    return _ChatStreamingViewportPhysics(
      lock: lock,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final inherited = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final overlayDelta = lock.takeOverlayExtentChange();
    if (!lock.enabled) {
      lock.clear();
      return (inherited + overlayDelta)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    lock.record(overlayDelta);
    final anchorCorrection = lock.consumeAnchorVisualCorrection();
    if (anchorCorrection != null) {
      lock.clear();
      return (newPosition.pixels + anchorCorrection)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    final metricsDelta =
        newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
    if (lock.consumeStructuralChange(metricsDelta)) {
      lock.clear();
      return (newPosition.pixels + metricsDelta)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    final reportedDelta = lock.take();
    if (lock.consumeReportedStructuralChange(reportedDelta)) {
      return (newPosition.pixels + reportedDelta)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    if (!reportedDelta.isFinite || reportedDelta.abs() < 0.01) {
      return inherited;
    }
    // Padding, separadores y redondeo del sliver pueden añadir unos pocos px
    // fuera del RenderBox medido. Solo usa el delta global cuando coincide de
    // forma ESTRECHA con el crecimiento reportado; una tolerancia amplia (64)
    // dejaba pasar el ruido de ESTIMACIÓN del sliver con historial
    // virtualizado (~36 px al insertar las filas del turno) y el viewport
    // derivaba hacia el fondo mientras el lector leía.
    final extentDelta =
        metricsDelta.isFinite &&
            (metricsDelta - reportedDelta).abs() <= 8 &&
            metricsDelta.sign == reportedDelta.sign
        ? metricsDelta
        : reportedDelta;
    final corrected = newPosition.pixels + extentDelta;
    return corrected
        .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
        .toDouble();
  }
}

class _ChatStreamingViewportLock {
  double _pendingExtentDelta = 0;
  double _pendingOverlayExtentDelta = 0;
  bool _structuralChangePending = false;
  bool _reportedStructuralChangePending = false;
  double? _anchorVisualOffset;
  RenderBox? Function()? _anchorVisualLookup;
  bool enabled = false;

  void enable() => enabled = true;

  void disable() {
    enabled = false;
    _structuralChangePending = false;
    _reportedStructuralChangePending = false;
    _pendingOverlayExtentDelta = 0;
    _clearAnchorVisualChange();
    clear();
  }

  void expectStructuralChange() {
    if (!enabled) return;
    _structuralChangePending = true;
    _reportedStructuralChangePending = false;
    _clearAnchorVisualChange();
    clear();
  }

  void expectReportedStructuralChange() {
    if (!enabled) return;
    _structuralChangePending = false;
    _reportedStructuralChangePending = true;
    _clearAnchorVisualChange();
    clear();
  }

  bool expectAnchorVisualChange(
    RenderBox anchor,
    RenderBox? Function() lookup,
  ) {
    if (!enabled) return false;
    final offset = _visualOffsetInViewport(anchor);
    if (offset == null) return false;
    _structuralChangePending = false;
    _reportedStructuralChangePending = false;
    _anchorVisualOffset = offset;
    _anchorVisualLookup = lookup;
    clear();
    return true;
  }

  bool consumeStructuralChange(double metricsDelta) {
    if (!_structuralChangePending ||
        !metricsDelta.isFinite ||
        metricsDelta.abs() < 0.01) {
      return false;
    }
    _structuralChangePending = false;
    return true;
  }

  void expireStructuralChange() => _structuralChangePending = false;

  bool consumeReportedStructuralChange(double reportedDelta) {
    if (!_reportedStructuralChangePending) return false;
    _reportedStructuralChangePending = false;
    return reportedDelta.isFinite && reportedDelta.abs() >= 0.01;
  }

  void expireReportedStructuralChange() {
    _reportedStructuralChangePending = false;
  }

  double? consumeAnchorVisualCorrection() {
    final previous = _anchorVisualOffset;
    final lookup = _anchorVisualLookup;
    if (previous == null || lookup == null) return null;
    final next = _visualOffsetInViewport(lookup());
    if (next == null) return null;
    _clearAnchorVisualChange();
    final correction = previous - next;
    return correction.isFinite && correction.abs() >= 0.01 ? correction : 0;
  }

  void expireAnchorVisualChange() => _clearAnchorVisualChange();

  static double? _visualOffsetInViewport(RenderBox? anchor) {
    if (anchor == null || !anchor.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(anchor);
    if (viewport == null || !viewport.attached) return null;

    // `getTransformTo` no es seguro aquí: en una lista invertida pide el
    // `size` del hijo directo del sliver mientras el viewport aún está dentro
    // de `performLayout`. El ancla ya guardó su propia altura al terminar su
    // layout, así que reconstruimos la traslación sin leer otro RenderBox.
    var current = anchor as RenderObject;
    var innerOffset = Offset.zero;
    RenderBox? sliverChild;
    RenderSliverMultiBoxAdaptor? sliver;
    while (true) {
      final parent = current.parent;
      if (parent == null) break;
      if (parent is RenderSliverMultiBoxAdaptor && current is RenderBox) {
        sliver = parent;
        sliverChild = current;
        break;
      }
      final parentData = current.parentData;
      if (parentData is BoxParentData) {
        innerOffset += parentData.offset;
      }
      current = parent;
    }
    if (sliver == null || sliverChild == null) return null;
    final geometry = sliver.geometry;
    final layoutOffset = sliver.childScrollOffset(sliverChild);
    final anchorHeight = anchor is ChatAnswerAnchorRenderBox
        ? anchor.laidOutHeight
        : null;
    if (geometry == null || layoutOffset == null || anchorHeight == null) {
      return null;
    }
    final mainAxisPosition = layoutOffset - sliver.constraints.scrollOffset;
    final childPaintOffset = switch (sliver.constraints.axisDirection) {
      AxisDirection.down => mainAxisPosition,
      AxisDirection.up =>
        geometry.paintExtent - anchorHeight - mainAxisPosition,
      _ => null,
    };
    if (childPaintOffset == null) return null;
    final offset = MatrixUtils.transformPoint(
      sliver.getTransformTo(viewport),
      Offset(innerOffset.dx, childPaintOffset + innerOffset.dy),
    ).dy;
    return offset.isFinite ? offset : null;
  }

  void _clearAnchorVisualChange() {
    _anchorVisualOffset = null;
    _anchorVisualLookup = null;
  }

  void record(double delta) {
    if (delta.isFinite) {
      _pendingExtentDelta += delta;
    }
  }

  void recordOverlayExtentChange(double delta) {
    if (delta.isFinite) {
      _pendingOverlayExtentDelta += delta;
    }
  }

  double takeOverlayExtentChange() {
    final delta = _pendingOverlayExtentDelta;
    _pendingOverlayExtentDelta = 0;
    return delta;
  }

  double take() {
    final delta = _pendingExtentDelta;
    _pendingExtentDelta = 0;
    return delta;
  }

  void clear() => _pendingExtentDelta = 0;
}

class _LiveAssistantExtentReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onExtentDelta;

  const _LiveAssistantExtentReporter({
    required this.onExtentDelta,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _LiveAssistantExtentRenderBox(onExtentDelta);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _LiveAssistantExtentRenderBox renderObject,
  ) {
    renderObject.onExtentDelta = onExtentDelta;
  }
}

class _LiveAssistantExtentRenderBox extends RenderProxyBox {
  ValueChanged<double> onExtentDelta;
  double? _previousExtent;

  _LiveAssistantExtentRenderBox(this.onExtentDelta);

  @override
  void performLayout() {
    super.performLayout();
    final previous = _previousExtent;
    final next = size.height;
    _previousExtent = next;
    // La primera altura TAMBIÉN es un delta: un turno que materializa su host
    // vivo con el lector arriba (seguimiento congelado o turno en segundo
    // plano) crece el extent desde cero y sin ese reporte el texto leído
    // derivaría. Con el lock inactivo el delta se descarta en el propio
    // ajuste del viewport, así que el seguimiento normal no nota el cambio.
    onExtentDelta(next - (previous ?? 0));
  }
}

/// Mide una fila recién insertada una sola vez.
///
/// A diferencia del reporter del asistente vivo, aquí la primera altura sí es
/// un delta: la fila no existía en el frame anterior. Se usa únicamente al
/// encadenar un turno mientras el lector conserva un ancla terminal.
class _SurfaceTurnInitialExtentReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onInitialExtent;

  const _SurfaceTurnInitialExtentReporter({
    required this.onInitialExtent,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SurfaceTurnInitialExtentRenderBox(onInitialExtent);

  @override
  void updateRenderObject(
    BuildContext context,
    _SurfaceTurnInitialExtentRenderBox renderObject,
  ) {
    renderObject.onInitialExtent = onInitialExtent;
  }
}

class _SurfaceTurnInitialExtentRenderBox extends RenderProxyBox {
  ValueChanged<double> onInitialExtent;
  bool _reported = false;

  _SurfaceTurnInitialExtentRenderBox(this.onInitialExtent);

  @override
  void performLayout() {
    super.performLayout();
    if (_reported) return;
    _reported = true;
    onInitialExtent(size.height);
  }
}

/// Alinea el principio de una respuesta con la parte superior del historial,
/// incluso cuando la respuesta es más alta que toda la pantalla.
@visibleForTesting
Future<void> scrollChatAnswerToStart(
  RenderObject targetObject,
  ScrollPosition position, {
  Duration duration = chatNavigationDuration,
}) async {
  final target = chatAnswerStartOffset(targetObject, position);
  if (target == null) return;
  if (duration == Duration.zero) {
    position.jumpTo(target);
    return;
  }
  await position.animateTo(
    target,
    duration: duration,
    curve: chatNavigationCurve,
  );
}

@visibleForTesting
double? chatAnswerStartOffset(
  RenderObject targetObject,
  ScrollPosition position,
) {
  final viewport = RenderAbstractViewport.maybeOf(targetObject);
  if (viewport == null) return null;
  return viewport
      // El historial usa `reverse:true`: alignment 1 coloca el borde visual
      // superior del mensaje en la parte superior del viewport.
      .getOffsetToReveal(targetObject, 1)
      .offset
      .clamp(position.minScrollExtent, position.maxScrollExtent);
}

/// Los dos saltos del historial comparten ritmo para que subir y bajar se
/// sientan como la misma interacción, sin arranques o frenadas bruscas.
@visibleForTesting
const chatNavigationDuration = Duration(milliseconds: 320);

@visibleForTesting
const chatNavigationCurve = Curves.easeOutCubic;

MarkdownStyleSheet _userSheet(ThemeData theme, HermesThemeColors colors) {
  final fg = colors.textPrimary;
  return MarkdownStyleSheet(
    p: theme.textTheme.bodyMedium?.copyWith(color: fg, height: 1.4),
    code: TextStyle(
      backgroundColor: fg.withValues(alpha: 0.12),
      fontFamily: 'monospace',
      fontSize: 13,
      color: fg,
    ),
    codeblockDecoration: BoxDecoration(
      color: fg.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
    ),
    a: TextStyle(
      color: fg.withValues(alpha: 0.85),
      decoration: TextDecoration.underline,
      decorationColor: fg.withValues(alpha: 0.5),
    ),
    h1: theme.textTheme.headlineSmall?.copyWith(color: fg),
    h2: theme.textTheme.titleLarge?.copyWith(color: fg),
    h3: theme.textTheme.titleMedium?.copyWith(color: fg),
    blockquote: TextStyle(
      color: fg.withValues(alpha: 0.75),
      fontStyle: FontStyle.italic,
    ),
    blockquoteDecoration: BoxDecoration(
      color: fg.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
    ),
    em: theme.textTheme.bodyMedium?.copyWith(
      fontStyle: FontStyle.italic,
      color: fg,
    ),
    strong: theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.bold,
      color: fg,
    ),
  );
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
    final operationalProjection = _projectOperationalArtifacts(context, data);
    // Misma ruta que el chat: separa y descarta razonamiento; solo el answer
    // público puede llegar al árbol de widgets.
    final parsedSplit = isStreaming
        ? splitReasoning(operationalProjection.visibleMarkdown)
        : ReasoningSplit(
            reasoning: '',
            answer: finalizedPublicAssistantText(
              operationalProjection.visibleMarkdown,
            ),
          );
    final split = ReasoningSplit(reasoning: '', answer: parsedSplit.answer);
    final blocks = split.answer.isEmpty
        ? const <Widget>[]
        : buildAssistantAnswerBlocks(
            split.answer,
            isStreaming: isStreaming,
            markdown: (d) => MarkdownBody(
              data: d,
              selectable: false,
              softLineBreak: false,
              styleSheet: _assistantSheet(context, d),
              builders: {'pre': _PreCodeBuilder()},
            ),
            callout: (b) =>
                CalloutCard(kind: b.kind, title: b.title, body: b.body),
            onLinkTap: (href) => _openMarkdownLink(context, href),
          );

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

MarkdownStyleSheet _assistantSheet(BuildContext context, String data) {
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

const double _dictationComposerHeight = 48;
const double _dictationWaveHeight = 28;

/// Visualizador compacto del dictado. La onda ocupa una franja reservada bajo
/// los parciales visibles en el campo. No graba ni procesa audio; solo observa
/// [VoiceService.micLevel].
class _DictationVisualizer extends StatefulWidget {
  const _DictationVisualizer({
    required this.level,
    required this.color,
    required this.mutedColor,
    required this.transcribing,
    required this.listeningLabel,
    required this.transcribingLabel,
    super.key,
  });

  final ValueListenable<double> level;
  final Color color;
  final Color mutedColor;
  final bool transcribing;
  final String listeningLabel;
  final String transcribingLabel;

  @override
  State<_DictationVisualizer> createState() => _DictationVisualizerState();
}

class _DictationVisualizerState extends State<_DictationVisualizer>
    with WidgetsBindingObserver {
  static const _barCount = 48;
  static const _frameInterval = Duration(microseconds: 33334);
  final ValueNotifier<List<double>> _samples = ValueNotifier(
    List<double>.filled(_barCount, 0),
  );
  Timer? _sampleTimer;
  bool _tickerModeEnabled = true;
  bool _appActive = true;

  bool get _shouldSampleLevel =>
      !widget.transcribing && _tickerModeEnabled && _appActive;

  @visibleForTesting
  bool get debugClockActive => _sampleTimer?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncSampleClock();
  }

  @override
  void didUpdateWidget(_DictationVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transcribing != widget.transcribing) {
      _syncSampleClock();
    }
  }

  void _syncSampleClock() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    if (!_shouldSampleLevel) return;
    _sampleTimer = Timer.periodic(_frameInterval, (_) {
      if (!_shouldSampleLevel) {
        _syncSampleClock();
        return;
      }
      final raw = widget.level.value.clamp(0.0, 1.0).toDouble();
      // Solo amplifica la representación visual: no modifica el PCM ni lo que
      // recibe el motor STT. El pequeño noise gate mantiene el silencio plano.
      final sample = ((raw - 0.018) / 0.42).clamp(0.0, 1.0).toDouble();
      final history = _samples.value;
      _samples.value = <double>[...history.skip(1), sample];
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    _syncSampleClock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sampleTimer?.cancel();
    _samples.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.transcribing
        ? widget.transcribingLabel
        : widget.listeningLabel;
    return Semantics(
      key: const ValueKey('dictation-status-semantics'),
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: SizedBox(
          key: const ValueKey('dictation-wave-history'),
          width: double.infinity,
          height: _dictationWaveHeight,
          child: SizedBox(
            key: const ValueKey('dictation-bars'),
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('dictation-bars-paint'),
                painter: _DictationBarsPainter(
                  samples: _samples,
                  color: widget.color,
                  mutedColor: widget.mutedColor,
                  transcribing: widget.transcribing,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DictationBarsPainter extends CustomPainter {
  const _DictationBarsPainter({
    required this.samples,
    required this.color,
    required this.mutedColor,
    required this.transcribing,
  }) : super(repaint: samples);

  final ValueListenable<List<double>> samples;
  final Color color;
  final Color mutedColor;
  final bool transcribing;

  @override
  void paint(Canvas canvas, Size size) {
    final history = samples.value;
    if (history.isEmpty || size.isEmpty) return;
    final barCount = history.length;
    final slotWidth = size.width / barCount;
    final barWidth = math.min(3.2, math.max(1.7, slotWidth * 0.52));
    final paint = Paint();
    for (var index = 0; index < barCount; index++) {
      final sample = history[index].clamp(0.0, 1.0).toDouble();
      final barHeight = 3.2 + sample * (_dictationWaveHeight - 3.2);
      final recency = index / math.max(1, barCount - 1);
      paint.color = transcribing
          ? mutedColor.withValues(alpha: 0.32)
          : color.withValues(alpha: 0.5 + recency * 0.4);
      final rect = Rect.fromLTWH(
        slotWidth * (index + 0.5) - barWidth / 2,
        (_dictationWaveHeight - barHeight) / 2,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DictationBarsPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      oldDelegate.color != color ||
      oldDelegate.mutedColor != mutedColor ||
      oldDelegate.transcribing != transcribing;
}

/// Tira fina bajo el AppBar del chat que indica el perfil de agente activo.
/// Puramente informativa: el gateway sirve un único home, así que el perfil se
/// refleja en el chat por su modelo (aplicado al activarlo en Perfiles); el chip
/// recuerda al usuario qué perfil está en contexto.
class _ProfileContextChip extends StatelessWidget
    implements PreferredSizeWidget {
  const _ProfileContextChip({required this.label, required this.colors});

  final String label;
  final HermesThemeColors colors;

  @override
  Size get preferredSize => const Size.fromHeight(30);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      alignment: Alignment.center,
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_rounded, size: 12, color: colors.accent),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps an existing transcript mounted while a manual refresh is in flight or
/// reports a failure. Initial loads without history still use the full states.
class ChatRefreshStatusOverlay extends StatelessWidget {
  const ChatRefreshStatusOverlay({
    required this.loading,
    required this.errorMessage,
    required this.child,
    this.errorTopInset = 8,
    super.key,
  });

  final bool loading;
  final String? errorMessage;
  final Widget child;

  /// Distancia del aviso de error al borde superior del transcript. El chat la
  /// sube para dejar libre el botón «cargar anteriores» cuando está a la vista.
  final double errorTopInset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (loading)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Semantics(
              key: const ValueKey('chat-refresh-progress'),
              liveRegion: true,
              label: MaterialLocalizations.of(
                context,
              ).refreshIndicatorSemanticLabel,
              child: ExcludeSemantics(
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: colors.accent,
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          ),
        if (errorMessage != null)
          Positioned(
            top: errorTopInset,
            left: 12,
            right: 12,
            child: Center(
              child: Semantics(
                key: const ValueKey('chat-refresh-error'),
                liveRegion: true,
                label: errorMessage,
                child: ExcludeSemantics(
                  // Misma superficie neutra que el resto de avisos: el error
                  // lo lleva el glifo, no un relleno rojo con texto blanco.
                  child: Material(
                    color: colors.surface,
                    elevation: 10,
                    shadowColor: Colors.black.withValues(alpha: 0.45),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: colors.divider.withValues(alpha: 0.78),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            size: 16,
                            color: colors.error,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              errorMessage!,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
