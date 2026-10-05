export '../widgets/chat/chat_markdown_body.dart'
    show
        buildAssistantAnswerBlocks,
        isAllowedMarkdownLinkScheme,
        prepareAssistantAnswerStructure,
        validateRemoteChatImageRedirect,
        validateRemoteChatImageTransport;
export '../widgets/chat/chat_message_selection_area.dart';

import '../models/bot_mention.dart';
import '../models/composer_reference.dart';
import '../utils/large_paste.dart';
import '../widgets/chat_mention_palette.dart';
import '../widgets/chat/composer_reference_palette.dart';
import '../widgets/chat/pasted_text_editor.dart';
import '../services/message_reaction_prefs.dart';
import '../services/terminal_availability.dart';
import '../widgets/chat/chat_markdown_body.dart';
import '../widgets/chat/message_reaction_bar.dart';
import 'terminal_pane_screen.dart';
import '../widgets/chat/chat_message_frame.dart';
import '../widgets/chat/console_composer.dart';
import '../widgets/chat/chat_message_selection_area.dart';
// Chat screen with real-time streaming via REST API.
// Uses REST endpoints: POST /api/sessions/{id}/chat and
// GET /api/sessions/{id}/messages.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, mapEquals, visibleForTesting;
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
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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
import '../models/cron_run_write_gate.dart';
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
import '../models/session_live_status.dart';
import '../models/session_artifact.dart';
import '../models/subagent_activity.dart';
import '../models/tool_output.dart';
import '../navigation/chat_route.dart';
import '../models/desktop_control_center.dart' show SessionGoalSnapshot;
import '../services/hermes_update_monitor.dart';
import '../services/active_chat_service.dart';
import '../services/cold_start_store.dart';
import '../services/approval_policy.dart';
import 'chat_content_screen.dart';
import 'image_viewer_screen.dart';
import '../services/compaction_tracker.dart';
import '../services/session_reconciler.dart';
import '../services/artifact_export_service.dart';
import '../services/attachment_uploader.dart';
import '../services/command_risk.dart';
import '../services/bridge_client.dart';
import '../services/bridge_update_service.dart';
import '../services/chat_content_extractor.dart';
import '../services/chat_draft_store.dart';
import '../services/chat_preference_store.dart';
import '../services/desktop_gateway_capabilities.dart';
import '../services/composer_completion_scheduler.dart';
import '../services/mission_bot_chat_store.dart';
import '../services/notifications/notification_service.dart';
import '../services/recent_interrupt_guard.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/turn_outbox_store.dart';
import '../services/generated_image_service.dart';
import '../services/generated_media_service.dart';
import '../services/generated_artifact_registry.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/dashboard_session_timeline.dart';
import '../services/session_archive.dart';
import '../services/session_artifact_download_service.dart';
import '../services/session_config_reducer.dart';
import '../services/session_deletion.dart';
import '../services/model_picker_loader.dart';
import '../services/model_presets_store.dart';
import '../services/shared_gateway_pool.dart';
import '../services/subagent_live_watch.dart';
import '../services/subagent_transcript_projection.dart';
import '../services/tui_gateway_client.dart'
    show TuiGatewayClient, TuiGatewayRpcError;
import '../widgets/chat_connection_recovery_row.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/inline_message_editor.dart';
import '../widgets/recovered_turn_banner.dart';
import '../widgets/stale_running_session_banner.dart';
import '../widgets/user_server_attachment_card.dart';
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
import '../utils/session_title.dart';
import '../utils/short_server_path.dart';
import '../utils/voice_error.dart';
import '../utils/chat_error.dart';
import '../utils/turn_control.dart';
import '../utils/byte_bounded_lru_cache.dart';
import '../utils/chat_turn.dart';
import '../utils/chat_read_marker.dart';
import '../utils/markdown_clipboard.dart';
import '../utils/responsive.dart';
import '../utils/slash_commands.dart';
import '../utils/assistant_content.dart';
import '../utils/assistant_operational_artifacts.dart';
import '../utils/assistant_suggestions.dart';
import '../utils/generated_artifact_markdown_scanner.dart';
import '../utils/streaming_normalizer.dart';
import 'activity_screen.dart';
import 'cron_screen.dart';
import 'extensions_center_screen.dart';
import 'memory_screen.dart';
import 'models_screen.dart';
import '../models/provider_auth_failure.dart';
import '../widgets/provider_reauth.dart';
import '../widgets/turn_error_copy.dart';
import '../models/turn_error_surface.dart';
import 'recovery_center_screen.dart';
import 'soul_screen.dart';
import 'tasks_screen.dart';
import 'chat_prompt_index.dart';
import 'chat_render_projection.dart';
import '../widgets/action_approval.dart';
import '../widgets/agent_task_widgets.dart';
import '../widgets/attachment_card.dart';
import '../widgets/attachment_history_preview.dart';
import '../widgets/artifact_viewer/artifact_viewer_screen.dart';
import '../widgets/attachment_source_sheet.dart';
import '../widgets/generated_image_card.dart';
import '../widgets/generated_video_card.dart';
import '../widgets/generated_artifact_viewer.dart';
import '../widgets/callout_card.dart';
import '../utils/unified_diff.dart';
import '../widgets/chat_connection_card.dart';
import '../widgets/chat_event_cards.dart';
import '../widgets/chat/tool_output_cards.dart';
import '../widgets/chat_control_sheet.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/profile_scope.dart' show appActiveProfileScope;
import '../widgets/hermes_bot_face.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_suggestions.dart';
import '../widgets/message_avatar_header.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_spark_mascot.dart';
import '../widgets/interactive_prompt_card.dart';
import '../widgets/markdown_table.dart';
import '../widgets/mission_profile_avatar.dart';
import '../bots/ui/bot_identity.dart';
import '../bots/ui/roster/living_bot_face.dart';
import '../bots/ui/room/room_widgets.dart' show RoomSeparator;
import '../widgets/motion_entrance.dart';
import '../widgets/subagent_activity_card.dart';
import '../design/modal.dart'
    show
        showHermesDialog,
        showHermesMenu,
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle;
import 'subagent_detail_screen.dart'
    show SubagentTranscriptPage, subagentIsLive;
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
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/chat_find_bar.dart';
import '../widgets/chat_prompt_sheet.dart';
import '../utils/transcript_search.dart';

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
    final mediaKind = entry['media_kind'];
    // `tool_media`: any file a text tool result announced with `MEDIA:`.
    final anyKind = mediaKind == 'tool_media';
    if (!anyKind && mediaKind != GeneratedMediaKind.video.name) continue;
    final toolCallId = entry['tool_call_id'];
    final source = entry['source'];
    if (toolCallId is! String ||
        toolCallId.trim().isEmpty ||
        source is! String) {
      continue;
    }
    final reference = GeneratedMediaService.referenceFromSource(source);
    if (reference == null ||
        (!anyKind && reference.kind != GeneratedMediaKind.video)) {
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
  prompts,
  content,
  branch,
  artifacts,
  details,
  cron,
  recovery,
  extensions,
  terminal,
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

  // Familia Claude: "claude-familia-major[-.]minor[-fecha][-variante]" →
  // "Familia major.minor[ Variante]". The minor is one or two digits so a
  // date pin (`claude-sonnet-4-20250514`) is never read as a version, and a
  // dotted OpenRouter id (`anthropic/claude-sonnet-4.6`) is recognised too.
  final claude =
      RegExp(
        r'^claude-(opus|sonnet|haiku)-(\d+)(?:[.-](\d{1,2})(?!\d))?',
      ).firstMatch(lower) ??
      RegExp(
        r'^claude-(\d+)(?:[.-](\d))?-(opus|sonnet|haiku)',
      ).firstMatch(lower);
  if (claude != null) {
    final legacy = RegExp(r'^\d').hasMatch(claude.group(1)!);
    final family = legacy ? claude.group(3)! : claude.group(1)!;
    final major = legacy ? claude.group(1)! : claude.group(2)!;
    final minor = legacy ? claude.group(2) : claude.group(3);
    final capitalized = family[0].toUpperCase() + family.substring(1);
    final version = minor == null ? major : '$major.$minor';
    final rest = lower
        .substring(claude.end)
        .replaceFirst(RegExp(r'-\d{8}'), '');
    final variant = RegExp(
      r'^-(fast|thinking|preview|latest|flash)\b',
    ).firstMatch(rest)?.group(1);
    final tag = variant == null
        ? ''
        : ' ${variant[0].toUpperCase()}${variant.substring(1)}';
    return '$capitalized $version$tag';
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
      chatCodeHighlightCacheLength();

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

  /// cs1215: reopened by the app on a cold start because it was the last
  /// foreground route. A session that turned out deleted returns to Home.
  final bool restoredFromColdStart;

  /// Carpeta del servidor donde debe arrancar un chat NUEVO abierto desde un
  /// proyecto o worktree. Viaja en `session.create` como `cwd` +
  /// `cwd_explicit`, igual que Desktop; null para un chat sin carpeta.
  final String? newChatWorkspace;

  /// Dashboard client for the provider sign-in started from a credential
  /// error; tests inject a fake Dashboard.
  @visibleForTesting
  final DashboardClient Function(SavedConnection connection)?
  providerReauthClientFactory;

  /// Dashboard client for the optional prompt index read by the Prompts list;
  /// tests inject a fake Dashboard.
  @visibleForTesting
  final DashboardClient Function(SavedConnection connection)?
  promptTimelineClientFactory;

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

  /// Replaces the Dashboard fetch of server-side user attachments
  /// (`@image:`/`@file:` lines) in widget tests.
  @visibleForTesting
  final Future<void> Function(String path, File destination)?
  userServerMediaFetcher;

  /// Replaces the HTTP fallbacks of the model picker (Mobile Bridge,
  /// Dashboard, gateway model list) in widget tests.
  @visibleForTesting
  final Map<ModelPickerSource, ModelPickerFallback>? modelPickerFallbacks;

  const ChatScreen({
    required this.connection,
    required this.session,
    this.initialPrompt,
    this.initialAttachmentSource,
    this.initialDictation = false,
    this.initialVoiceMode = false,
    this.requestComposerFocus = false,
    this.initialStoredSessionId,
    this.restoredFromColdStart = false,
    this.newChatWorkspace,
    this.providerReauthClientFactory,
    this.promptTimelineClientFactory,
    this.missionAvatarCache,
    this.missionBotProfile,
    this.performanceProbe,
    this.attachmentMaterializer,
    this.attachmentPrivateCopyDeleter,
    this.cancelStreamOverride,
    this.sendAttemptObserver,
    this.draftStoreOverride,
    this.userServerMediaFetcher,
    this.modelPickerFallbacks,
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

  /// Debounced transport loss shared by the recovery row, the activity pill
  /// headline and the companion mood, so a socket blip shorter than the grace
  /// never flashes "connection lost" on any of them.
  final ChatTransportVisibility _transportVisibility =
      ChatTransportVisibility();
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
  Object? _lastSessionConfigPresentation;
  (bool, int, int, int, int)? _activityPresentationFingerprint;
  (bool, bool, bool) _lastAwaitsUnseenInput = (false, false, false);
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

  /// View-only verdict for a cron run that never closed and that the
  /// scheduler no longer owns (Desktop `open-cron-run.ts`, #88443).
  /// Re-evaluated from every authoritative session read and before each send.
  late bool _cronRunReadOnly =
      CronRunWriteGate.appliesTo(widget.session) &&
      CronRunWriteGate.readOnlyFor(widget.session);
  late final LocalConversationLifecycle _localConversationLifecycle;

  bool _editingUserMessage = false;
  Map<String, dynamic>? _editingUserMessageTarget;
  double? _editingUserMessageWidth;
  String? _editingUserMessageText;

  /// Text the user rewrote and tried to save. A failed save keeps it in the
  /// open editor instead of throwing it away.
  String? _editingUserMessageDraft;
  int? _editingUserMessageOrdinal;
  String? _editingQueuedEntryId;
  bool _editingRewriteSubmitted = false;
  List<Map<String, dynamic>>? _editingMessagesSnapshot;
  ChatPipelineState? _editingPipelineSnapshot;

  /// Congela la proyección visual mientras el editor está abierto. El agente
  /// puede avanzar en segundo plano, pero su respuesta no aparece mientras se
  /// edita: Cancelar revela el progreso real y Guardar rebobina el turno.
  List<Map<String, dynamic>> get _messages {
    final editing = _editingMessagesSnapshot;
    if (editing != null) return editing;
    final scheduler = SchedulerBinding.instance;
    final inFramePipeline =
        scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks;
    final cached = _frameMessagesSnapshot;
    if (cached != null &&
        inFramePipeline &&
        identical(_frameMessagesChat, _chat)) {
      return cached;
    }
    final probe = widget.performanceProbe;
    if (probe != null) probe.publicTranscriptReads += 1;
    final messages = _chat.messages;
    // While a turn streams, every read is a full privacy/editorial projection
    // of the whole transcript, and one build reads it once or more per row.
    // Inside the build/layout/paint pipeline nothing can mutate the service
    // (events arrive asynchronously, and the list entries already index into
    // this same snapshot), so reuse it until the frame ends. Event handlers
    // and post-frame callbacks run outside that phase and always read fresh.
    if (inFramePipeline) {
      _frameMessagesSnapshot = messages;
      _frameMessagesChat = _chat;
      if (!_frameMessagesClearScheduled) {
        _frameMessagesClearScheduled = true;
        scheduler.addPostFrameCallback((_) {
          _frameMessagesClearScheduled = false;
          _frameMessagesSnapshot = null;
          _frameMessagesChat = null;
        });
      }
    }
    return messages;
  }

  List<Map<String, dynamic>>? _frameMessagesSnapshot;
  ActiveChat? _frameMessagesChat;
  bool _frameMessagesClearScheduled = false;

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
    _editingUserMessageDraft = null;
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
  int _hydrationAnchorSerial = 0;
  bool _messageRefreshReanchorScheduled = false;
  ForegroundConversationReader? _passiveConversationReader;
  bool _chatRouteVisible = false;

  /// The chat was on top when the App Lock screen covered it: it is what the
  /// user sees once they unlock.
  bool _coveredByAppLock = false;

  /// The chat (connection|session) this stretch in front already asked to
  /// clear. Covering it with the lock screen does not end the stretch: what
  /// the user had seen is cleared after unlock, and the screen coming back
  /// from under the lock does not clear again.
  String? _ownNotificationsClearedFor;
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
  // Mirrors `_chat.durableSessionsChangeRevision`: consumed in `_onChatEvent`
  // to route a `sessions.changed` broadcast into the passive conversation
  // reader's durable-chat-id-scoped path, so the OPEN transcript reconciles
  // (busy/reconnect/id-promotion aware) the same way the session list does.
  int _seenDurableSessionsChangeRevision = 0;
  // Set when a `sessions.changed` tick requests a reconciliation read;
  // consumed (and cleared) by `_refreshPassiveTranscript`, which then treats
  // it as real evidence of a durable change rather than a guess — bypassing
  // the runtime-ownership polling optimization the same way an observed
  // remote-turn settlement already does.
  bool _durableTranscriptReadPending = false;
  SubagentPresentationOwnerToken? _subagentPresentationOwner;
  int _viewerAttachGeneration = 0;

  /// A-201 (spec 028): la excepción cruda del error de carga solo se muestra
  /// bajo demanda ("ver detalles"), nunca como cuerpo del estado de error.
  bool _showErrorDetail = false;

  // La cobertura es una advertencia de esta vista, no un bloqueo ni estado
  // durable del transcript. El lector puede descartarla y seguir cargando
  // páginas anteriores al llegar al extremo del timeline.
  bool _coreReadCoverageNoticeDismissed = false;

  // El error de refresco superpuesto sobre un transcript ya visible es solo
  // informativo (el historial sigue ahí). Cerrarlo lo oculta hasta el
  // siguiente fallo de carga, que vuelve a mostrarlo.
  bool _refreshErrorNoticeDismissed = false;

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

  /// The subagent detail page covers this chat, which drops the chat's own
  /// presentation lease (route no longer current). The detail holds its own
  /// lease so the authoritative roster and controls stay valid under it.
  VoidCallback _acquireSubagentDetailLease() {
    if (_disposed || !_chatBound) return () {};
    final chat = _chat;
    final SubagentPresentationOwnerToken token;
    try {
      token = chat.acquireSubagentForegroundPresentation();
    } on StateError {
      return () {};
    }
    unawaited(chat.refreshSubagents());
    var released = false;
    return () {
      if (released) return;
      released = true;
      chat.releaseSubagentForegroundPresentation(token);
    };
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
  // One debounced, cancellable lookup per keystroke burst while the slash
  // palette is open; closing it (trigger gone, blur, dispose) cancels.
  late final ComposerCompletionScheduler<_SlashLookup> _slashCompletions =
      ComposerCompletionScheduler<_SlashLookup>(fetch: _fetchSlashLookup);
  // Who answers composer completions (Desktop `scopeKey`): the bound runtime,
  // or the profile a new-chat draft is routed to. Every slash key carries it.
  String? _completionScope;
  // `@` references (`complete.path`), same debounce/cancel contract. The key
  // carries the runtime the listing is asked of and answered for, so another
  // session's tree is never served; a listing expires like Desktop's (15 s).
  late final ComposerCompletionScheduler<PathCompletionBatch>
  _referenceCompletions = ComposerCompletionScheduler<PathCompletionBatch>(
    fetch: _fetchReferences,
    cacheTtl: const Duration(seconds: 15),
  );
  List<PathCompletionItem> _referenceItems = const [];
  String? _referenceKey;
  late final List<TextInputFormatter> _composerInputFormatters = [
    LargePasteFormatter(
      enabled: () => _largePasteAttachable,
      onLargePaste: _onLargePaste,
    ),
    ComposerReferenceFormatter(
      enabled: () => _chatBound && _chat.supportsDesktopPathCompletion,
    ),
  ];
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
  // Turno recuperado que se anuncia en el aviso en flujo sobre el composer.
  // Solo se pinta mientras siga siendo el `_preparedTurn` vigente.
  PreparedTurn? _recoveredTurnNotice;
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
  // Identity of the submission holding [_composerSubmissionInFlight]. A
  // `/compress` hands the slot back as soon as it is dispatched (its own
  // fence takes over), so its late `finally` must not release a successor.
  int _composerSubmissionClaim = 0;
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
    if (value) {
      _beginAwayFromBottom();
    } else {
      _endAwayFromBottom();
    }
  }

  // Mensajes llegados mientras el lector está lejos del fondo. Se fija el
  // último mensaje visible al apartarse y solo se recuenta cuando llega
  // contenido (eventos estructurales o el primer token de una respuesta),
  // nunca por frame ni por scroll.
  final ValueNotifier<int> _newWhileAway = ValueNotifier(0);

  // True only while the entry landing walks the lazy list up to the first
  // unread row. Each walk step is a real scroll offset; painting them would
  // show the transcript jumping upward screen by screen before it lands.
  final ValueNotifier<bool> _transcriptConcealed = ValueNotifier(false);

  // Sticky prompt: the prompt of the turn whose reply spans the viewport top.
  // Recomputed at most once per frame (post-frame, scheduled from the scroll
  // listener and from a new transcript snapshot), reading only the attached
  // anchors plus the snapshot the last build used: never a transcript walk
  // and never a screen setState.
  final ValueNotifier<Map<String, dynamic>?> _stickyPrompt = ValueNotifier(
    null,
  );
  List<Map<String, dynamic>> _stickySource = const [];
  Map<Map<String, dynamic>, int>? _stickyIndex;

  /// Laid-out slices of long replies that own no reader anchor, with the
  /// message they belong to. Only the sticky prompt reads it.
  final Map<RenderBox, Map<String, dynamic>> _stickySliceAnchors =
      Map<RenderBox, Map<String, dynamic>>.identity();
  bool _stickyUpdateScheduled = false;

  void _scheduleStickyPromptUpdate() {
    if (_stickyUpdateScheduled || _disposed) return;
    _stickyUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickyUpdateScheduled = false;
      if (_disposed || !mounted) return;
      final next =
          _findOpen ||
              _transcriptConcealed.value ||
              !_scrollController.hasClients ||
              _stickySource.isEmpty
          ? null
          : _stickyPromptCandidate();
      if (!identical(_stickyPrompt.value, next)) _stickyPrompt.value = next;
    });
  }

  /// True for user rows painted as a system chip (kanban work, skill
  /// invocation, compaction hand-off, job notices): they are not prompts.
  bool _isSystemChipRow(Map<String, dynamic> message) =>
      _jobChipLabel(message['content'] as String, Strings.of(context)) != null;

  /// The prompt to pin, or null when the reply at the top has none loaded or
  /// the prompt's own bubble is (partly) on screen.
  Map<String, dynamic>? _stickyPromptCandidate() {
    Map<String, dynamic>? topMessage;
    var topOffset = double.infinity;
    void consider(RenderBox anchor, Map<String, dynamic> message) {
      final top = _ChatStreamingViewportLock._visualOffsetInViewport(anchor);
      final height = anchor is ChatAnswerAnchorRenderBox
          ? anchor.laidOutHeight
          : null;
      if (top == null || height == null || top + height <= 0) return;
      if (top < topOffset) {
        topOffset = top;
        topMessage = message;
      }
    }

    for (final entry in _messageAnchors.entries) {
      consider(entry.value, entry.key);
    }
    for (final entry in _stickySliceAnchors.entries) {
      consider(entry.key, entry.value);
    }
    if (topMessage == null || topOffset > chatPromptActiveSlack) return null;
    final source = _stickySource;
    var index = _stickyIndex;
    if (index == null) {
      index = Map<Map<String, dynamic>, int>.identity();
      for (var i = 0; i < source.length; i++) {
        index[source[i]] = i;
      }
      _stickyIndex = index;
    }
    final topIndex = index[topMessage];
    if (topIndex == null) return null;
    final promptIndex = stickyPromptIndex(
      source,
      topIndex,
      isSystemRow: _isSystemChipRow,
    );
    if (promptIndex == null) return null;
    final prompt = source[promptIndex];
    final promptAnchor = _messageAnchors[prompt];
    final promptTop = _ChatStreamingViewportLock._visualOffsetInViewport(
      promptAnchor,
    );
    final promptHeight = promptAnchor is ChatAnswerAnchorRenderBox
        ? promptAnchor.laidOutHeight
        : null;
    if (promptTop != null &&
        promptHeight != null &&
        promptTop + promptHeight > 0) {
      return null;
    }
    return prompt;
  }

  Future<void> _revealStickyPrompt(Map<String, dynamic> prompt) async {
    final target = chatRefreshFindAnchorMessage(prompt, _messages) ?? prompt;
    _freezeStreamingFollow();
    await _revealTranscriptMessage(target);
  }

  /// Walk budget of the entry landing: long enough to build a first unread
  /// row several screens up, short enough (~330 ms) that a blank transcript
  /// never reads as a broken screen.
  static const int _entryLandingWalkFrames = 20;

  // "New since you left": device-local read marker per conversation (Hermes
  // keeps none for sessions), mirroring the Room's `lastSeenSeq`.
  SharedPreferences? _lastReadPrefs;
  String? _lastReadKeyOnEntry;
  bool _newSinceResolved = false;
  Map<String, dynamic>? _newSinceFirstUnread;
  String? _newSinceFirstUnreadKey;

  String get _lastReadPrefsKey =>
      'chat_last_read_v1.${widget.connection.id}.${widget.session.logicalId}';

  /// Resolves the divider once, on the first transcript that contains the
  /// stored marker, and lands on the first unread row if it is off screen.
  void _resolveNewSinceYouLeft() {
    if (_newSinceResolved || _disposed || !_chatBound) return;
    final markerKey = _lastReadKeyOnEntry;
    if (markerKey == null) {
      _newSinceResolved = true;
      return;
    }
    final messages = _messages;
    if (messages.isEmpty || !_chat.messagesLoaded) return;
    final found = chatUnreadSinceStoredMarker(messages, markerKey);
    if (found == null && _newSinceMarkerMayBeOlder()) {
      unawaited(_pageBackForNewSinceMarker());
      return;
    }
    _newSinceResolved = true;
    final firstUnread = found?.oldestNew;
    if (found == null || firstUnread == null) return;
    _newSinceFirstUnread = firstUnread;
    _newSinceFirstUnreadKey = chatReadMarkerKey(firstUnread);
    final unread = found.count;
    final newestRead = found.newestRead;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_landOnNewSinceYouLeft(firstUnread, newestRead, unread));
    });
    setState(() {});
  }

  /// The opening page holds only the newest rows (Desktop parity), so the
  /// stored marker can sit in an older page. Look for it as deep as the
  /// former 500-row opening page read, never further: a marker that is
  /// gone (rewound, compacted away) must not walk the whole history.
  static const int _newSinceLookbackRows = 500;
  bool _newSincePagingBack = false;

  bool _newSinceMarkerMayBeOlder() =>
      _chat.hasEarlierMessages &&
      !_chat.earlierMessagesLoadFailed &&
      _chat.messages.length < _newSinceLookbackRows;

  /// Loads older pages through the same contiguous backfill as scrolling to
  /// the top (rows are only ever prepended in order), then resolves again.
  Future<void> _pageBackForNewSinceMarker() async {
    if (_newSincePagingBack) return;
    _newSincePagingBack = true;
    try {
      final before = _chat.messages.length;
      await _chat.loadEarlierMessages(continuePastInvisible: true);
      if (_disposed || !mounted) return;
      if (_chat.messages.length == before) {
        // No progress: stop looking instead of retrying in a loop.
        _newSinceResolved = true;
        return;
      }
    } finally {
      _newSincePagingBack = false;
    }
    _resolveNewSinceYouLeft();
  }

  Future<void> _landOnNewSinceYouLeft(
    Map<String, dynamic> firstUnread,
    Map<String, dynamic> newestRead,
    int unread,
  ) async {
    if (_disposed || !mounted || !_scrollController.hasClients) return;
    var position = _scrollController.position;
    var anchor = _messageAnchors[firstUnread];
    double? target;
    if (anchor != null && anchor.attached) {
      target = chatAnswerStartOffset(anchor, position);
      // Its top is already on screen: stay at the bottom.
      if (target == null || target <= position.pixels) return;
    } else {
      // The reversed list is lazy: a first unread row far above the bottom
      // has no render object yet. Walk up to it with the transcript hidden,
      // so the reader sees one move (bottom, then the landing) instead of
      // every intermediate screen of the walk. The concealment is released
      // in the same frame as the final jump, or at the bottom if the walk
      // fails or runs out of budget.
      _freezeStreamingFollow();
      _transcriptConcealed.value = true;
      try {
        final reached = await _materializeTranscriptAnchor(
          firstUnread,
          stillWanted: () => !_disposed,
          maxFrames: _entryLandingWalkFrames,
          // The list keeps a 1000 px cache on both sides: a step of one
          // viewport plus that cache still builds every row it passes.
          stepExtent: (position) => position.viewportDimension + 1000,
        );
        anchor = _messageAnchors[firstUnread];
        position = _scrollController.hasClients
            ? _scrollController.position
            : position;
        target = reached == true && anchor != null && anchor.attached
            ? chatAnswerStartOffset(anchor, position)
            : null;
        if (target == null) {
          if (_scrollController.hasClients) {
            _scrollController.position.jumpTo(
              _scrollController.position.minScrollExtent,
            );
          }
          return;
        }
      } finally {
        if (!_disposed) _transcriptConcealed.value = false;
      }
    }
    // One jump, before the reader has seen the bottom settle: no animation
    // that would read as a second movement after the route transition.
    _freezeStreamingFollow();
    // The jump button appears with the landing and pads the list bottom by
    // its 48 dp. Show it while still at the bottom (no compensation is
    // recorded there) and include its extent in the single jump, so the
    // divider lands at the top in one frame instead of sliding 48 dp.
    final buttonExtent = _scrollToBottomVisibility.value ? 0.0 : 48.0;
    _showScrollToBottom = true;
    position.jumpTo(target + buttonExtent);
    if (_scrollToBottomVisibility.value) {
      _awayMarker = newestRead;
      _awayMarkerKey = chatReadMarkerKey(newestRead);
      _awayCountableBaseline = _countableMessages() - unread;
      _newWhileAway.value = unread;
    }
  }

  bool _isNewSinceFirstUnread(Map<String, dynamic> message) {
    final target = _newSinceFirstUnread;
    if (target == null) return false;
    if (identical(message, target)) return true;
    final key = _newSinceFirstUnreadKey;
    return key != null && chatReadMarkerKey(message) == key;
  }

  /// Marks the newest loaded message as read for the next entry.
  void _persistLastRead() {
    final prefs = _lastReadPrefs;
    if (prefs == null || !_chatBound) return;
    final key = chatReadMarkerForLeaving(_messages);
    if (key == null) return;
    unawaited(prefs.setString(_lastReadPrefsKey, key));
  }

  Map<String, dynamic>? _awayMarker;
  String? _awayMarkerKey;
  int _awayCountableBaseline = 0;

  int _countableMessages() {
    var total = 0;
    for (final message in _messages) {
      if (chatReadMarkerCountable(message)) total++;
    }
    return total;
  }

  void _beginAwayFromBottom() {
    if (!_chatBound) return;
    final marker = chatNewestCountableMessage(_messages);
    _awayMarker = marker;
    _awayMarkerKey = marker == null ? null : chatReadMarkerKey(marker);
    _awayCountableBaseline = _countableMessages();
    _newWhileAway.value = 0;
  }

  void _endAwayFromBottom() {
    _awayMarker = null;
    _awayMarkerKey = null;
    _awayCountableBaseline = 0;
    _newWhileAway.value = 0;
  }

  void _recountNewWhileAway({bool olderHistoryOnly = false}) {
    if (_disposed || !_scrollToBottomVisibility.value) return;
    if (olderHistoryOnly) {
      // Older rows extend the far end: they are never news for the reader,
      // only the baseline of the fallback count moves with them.
      final total = _countableMessages();
      _awayCountableBaseline = total - _newWhileAway.value;
      return;
    }
    final messages = _messages;
    final found = chatMessagesNewerThanMarker(
      messages,
      marker: _awayMarker,
      key: _awayMarkerKey,
    );
    final int count;
    if (found != null) {
      count = found.count;
    } else {
      // The marker row was replaced by a copy without a durable id (an
      // optimistic prompt reconciled by the server). The number of countable
      // rows added since leaving the bottom still holds.
      var total = 0;
      for (final message in messages) {
        if (chatReadMarkerCountable(message)) total++;
      }
      count = math.max(total - _awayCountableBaseline, _newWhileAway.value);
    }
    _newWhileAway.value = math.max(count, 0);
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

  // Búsqueda dentro del chat. Mientras la barra está abierta el seguimiento
  // del fondo queda suspendido: saltar a un resultado no puede competir con
  // el streaming ni con la hidratación. Cerrar la barra lo restaura.
  bool _findOpen = false;
  String _findInitialQuery = '';
  String _findQuery = '';
  int _findEpoch = 0;
  final TranscriptSearchIndex _findIndex = TranscriptSearchIndex();
  List<Map<String, dynamic>> _findMatchMessages = const [];
  List<TranscriptMatch> _findMatches = const [];
  final ValueNotifier<ChatFindStatus> _findStatus = ValueNotifier(
    const ChatFindStatus(),
  );
  final ValueNotifier<Map<String, dynamic>?> _findActiveMessage = ValueNotifier(
    null,
  );
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
    _autoFollowStreaming = readerIsAtBottom && !_findOpen;
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
    // Sin UI visible (app en segundo plano) no hay nada que animar: el texto
    // se revela entero y el timer de 30 Hz no despierta al isolate.
    if (!_chat.isStreaming ||
        !_autoFollowStreaming ||
        _reduceMotion ||
        !_appInForeground) {
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
    _transcriptConcealed.addListener(_scheduleStickyPromptUpdate);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadSharedArchive());
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
    _textFocusNode.onKeyEvent = _onComposerKeyEvent;
    unawaited(_restoreDraftAndRunInitialAction());
  }

  /// Physical keyboard: Arrow Up in an EMPTY composer brings back the last
  /// message sent in this chat, caret at the end. With text, or while a
  /// suggestion palette is open, the key keeps its normal behaviour. The
  /// palette guards cover suggestions that arrive late, after a send already
  /// cleared the text; an `@` mention always needs text, so the empty check
  /// covers it.
  KeyEventResult _onComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (_textController.text.isNotEmpty ||
        _slashPaletteVisible ||
        _referencePaletteVisible ||
        _isRecording ||
        _transcribing) {
      return KeyEventResult.ignored;
    }
    final recalled = _lastSentUserText();
    if (recalled == null) return KeyEventResult.ignored;
    _textController.value = TextEditingValue(
      text: recalled,
      selection: TextSelection.collapsed(offset: recalled.length),
    );
    return KeyEventResult.handled;
  }

  /// Test hook: puts the composer in the states where Arrow Up must keep its
  /// normal behaviour even with an empty text (late palette rows, dictation).
  @visibleForTesting
  void setComposerKeyGuardsForTesting({
    List<SlashCommand>? slashSuggestions,
    List<PathCompletionItem>? referenceItems,
    bool? recording,
    bool? transcribing,
  }) {
    setState(() {
      if (slashSuggestions != null) _slashSuggestions = slashSuggestions;
      if (referenceItems != null) _referenceItems = referenceItems;
      if (recording != null) _isRecording = recording;
      if (transcribing != null) _transcribing = transcribing;
    });
  }

  /// Text of the newest real user turn (rows are stored newest first).
  String? _lastSentUserText() {
    for (final message in _chat.messages) {
      if (!isRealUserTurn(message)) continue;
      final text = _parseUserContent(
        (message['content'] ?? '').toString(),
      ).text.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  void _onComposerFocusChanged() {
    if (!_textFocusNode.hasFocus) {
      _slashCompletions.cancel();
      _closeReferencePalette();
    }
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

  /// Bot Chat replies are attributed to the bot, never "Hermes" (spec 070 S2).
  String? get _botDisplayName {
    if (!_isBotChatSurface) return null;
    final profile = widget.missionBotProfile;
    final name =
        profile?.botTitle ??
        (profile != null && profile.name.isNotEmpty
            ? profile.name
            : Session.profileOwner(widget.session.profile));
    return name.trim().isEmpty ? null : name.trim();
  }

  String get _assistantName => _botDisplayName ?? _agentName;

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
    final submittedLink = draft.submittedTurnClientTurnId;
    if (submittedLink != null &&
        (_chatBound ? _chat.activeTurnDelivery : null) == null) {
      // La outbox se escribe siempre antes del enlace. Sin registro de ese
      // turno, ya se resolvió (entregado y retirado): el lote no se ofrece de
      // nuevo. Con registro, decide la reconciliación normal de abajo. Con una
      // entrega viva no se lee storage: el servicio posee esa frontera.
      final pending = await outbox.loadAllForChat(
        widget.connection.id,
        widget.session.id,
        profile: _recoveryProfile,
      );
      if (!mounted) return;
      if (!pending.any((turn) => turn.clientTurnId == submittedLink)) {
        await store.clear(
          widget.connection.id,
          _draftRecoverySessionId,
          profile: _recoveryProfile,
          onlySubmittedTurnClientTurnId: submittedLink,
        );
        if (!mounted) return;
        draft = const ChatDraft(text: '', attachments: []);
      }
    }
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
    // Mientras se reconcilia y se restaura la cola, el settle por transcript
    // no puede liquidar este turno: al terminar, la restauración lo volvería
    // a instalar ya borrado y dejaría la cola suspendida. Se programa una sola
    // vez al final, sobre el estado ya restaurado.
    _composerTurnRestoreInFlight = true;
    try {
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
    } finally {
      _composerTurnRestoreInFlight = false;
    }
    if (!mounted) return;
    final reconciledDelivery = _chatBound ? _chat.activeTurnDelivery : null;
    if (reconciledDelivery != null) {
      _observeAttachmentDelivery(reconciledDelivery);
    }
    // Otro dueño (descartar, un envío nuevo) pudo retirar o sustituir el turno
    // durante la espera: nunca se reinstala uno que ya no es el vigente.
    if (!identical(_preparedTurn, loaded)) return;
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
    // El borrador guardado puede ser trabajo NUEVO del usuario (escrito tras
    // el fallo o mientras el turno seguía pendiente). Ese borrador manda: el
    // turno recuperado se ofrece en el aviso y nunca sustituye al borrador.
    final draftIsOtherWork =
        _hasDraftContent(draft) &&
        !prepared.matchesBatch(
          text: draft.text.trim(),
          attachments: draft.attachments,
          model: prepared.model,
          profile: prepared.profile,
        );
    if (draftIsOtherWork && recoverPrepared) {
      // Un envío todavía en vuelo lo posee el servicio: sin aviso de descarte
      // que pudiera retirar su outbox a mitad de vuelo. Si ya falló (ambiguo o
      // rechazado), el aviso ofrece el turno sin tocar el borrador.
      final stillInFlight =
          liveDelivery != null &&
          (prepared.state == PreparedTurnState.prepared ||
              prepared.state == PreparedTurnState.submitting);
      if (!stillInFlight) _showHiddenRecoveredTurn(prepared);
      return;
    }
    if (draftIsOtherWork) {
      // ACK ya persistido: solo se compacta el registro terminal; el borrador
      // nuevo del usuario no se toca.
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
  bool _composerTurnRestoreInFlight = false;
  Timer? _composerTurnSettleRetryTimer;

  /// Resuelve como entregado el turno del composer cuya confirmación se
  /// perdió si el transcript durable lo demuestra. No toca el turno en vuelo,
  /// no restaura el borrador ni reenvía; ante cualquier duda lo deja pendiente.
  void _scheduleComposerTurnTranscriptSettle() {
    final prepared = _preparedTurn;
    if (_composerTurnSettleInFlight ||
        _composerTurnRestoreInFlight ||
        _disposed ||
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
    if (!delivered) {
      // El freno de 5 s descartó la comprobación sin leer el transcript: no es
      // evidencia de nada. Reintenta una vez vencido el freno en vez de
      // esperar a un evento que quizá no llegue.
      final retryDelay = _chat.composerTurnSettleThrottleRemaining;
      if (retryDelay != null && mounted && identical(_preparedTurn, prepared)) {
        _composerTurnSettleRetryTimer?.cancel();
        _composerTurnSettleRetryTimer = Timer(retryDelay, () {
          _composerTurnSettleRetryTimer = null;
          if (!mounted || _disposed) return;
          _scheduleComposerTurnTranscriptSettle();
        });
      }
      return;
    }
    if (!mounted || !identical(_preparedTurn, prepared)) return;
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
    // Aviso en flujo (encima del composer), no en el carril superior: allí
    // tapaba el menú y el selector de modelo y truncaba el texto.
    setState(() => _recoveredTurnNotice = prepared);
  }

  String _recoveredTurnMessage(PreparedTurn prepared) {
    final ambiguous = prepared.state == PreparedTurnState.ambiguous;
    final acknowledged =
        prepared.state == PreparedTurnState.accepted ||
        prepared.state == PreparedTurnState.running;
    final english = Localizations.localeOf(context).languageCode == 'en';
    return ambiguous
        ? Strings.of(context).chaAmbiguousRestored
        : acknowledged
        ? english
              ? 'Hermes could not reattach a turn that may still be running. Send retries the check; discard only after verifying Hermes because this does not cancel the remote turn.'
              : 'Hermes no pudo reanexar un turno que aún podría seguir activo. Enviar repite la comprobación; descarta solo tras verificar Hermes porque esto no cancela el turno remoto.'
        : english
        ? 'A pending turn was recovered. Discard the recovery to continue.'
        : 'Se recuperó un turno pendiente. Descarta la recuperación para continuar.';
  }

  /// True cuando el composer contiene trabajo del usuario distinto del lote
  /// recuperado. Ese borrador manda: nunca se pisa con el turno recuperado.
  bool _composerHoldsOtherDraft(PreparedTurn prepared) {
    final text = _textController.text;
    if (text.trim().isEmpty && _pendingAttachments.isEmpty) return false;
    return !prepared.matchesBatch(
      text: text.trim(),
      attachments: List<AttachmentDraft>.of(_pendingAttachments),
      model: prepared.model,
      profile: prepared.profile,
    );
  }

  /// Devuelve el turno recuperado al composer solo si está vacío: un borrador
  /// distinto del usuario jamás se sustituye.
  Future<void> _restoreRecoveredTurnIntoComposer(PreparedTurn prepared) async {
    if (!mounted ||
        !prepared.restoresComposer ||
        _preparedTurn?.storageId != prepared.storageId ||
        _textController.text.isNotEmpty ||
        _pendingAttachments.isNotEmpty) {
      return;
    }
    final link = prepared.state == PreparedTurnState.failedBeforeAcceptance
        ? prepared.clientTurnId
        : null;
    _restoringDraft = true;
    setState(() {
      _composerPreparedTurnClientTurnId = link;
      _textController.value = TextEditingValue(
        text: prepared.text,
        selection: TextSelection.collapsed(offset: prepared.text.length),
      );
      _pendingAttachments
        ..clear()
        ..addAll(prepared.attachments);
    });
    _restoringDraft = false;
    _syncProducerAttachmentRetention();
    _draftTimer?.cancel();
    await _saveDraftSnapshot(
      prepared.text,
      prepared.attachments,
      preparedTurnClientTurnId: link,
      preparedTurnAuthorityCaptured: true,
    );
  }

  Widget? _buildRecoveredTurnBanner() {
    final notice = _recoveredTurnNotice;
    final current = _preparedTurn;
    if (notice == null ||
        current == null ||
        current.storageId != notice.storageId ||
        current.state == PreparedTurnState.terminal) {
      return null;
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _textController,
      builder: (context, _, _) {
        final str = Strings.of(context);
        final restorable = current.restoresComposer;
        final composerEmpty =
            _textController.text.isEmpty && _pendingAttachments.isEmpty;
        return RecoveredTurnBanner(
          message: _recoveredTurnMessage(current),
          keepsDraftHint: restorable && _composerHoldsOtherDraft(current)
              ? str.chaRecoveredKeepsDraft
              : null,
          restoreLabel: restorable ? str.chaRestoreRecovered : null,
          onRestore: restorable && composerEmpty
              ? () => unawaited(_restoreRecoveredTurnIntoComposer(current))
              : null,
          discardLabel: str.chaDiscardRecovered,
          onDiscard: () => unawaited(_discardRecoveredTurn(current)),
          dismissTooltip: str.chaRecoveredDismiss,
          onDismiss: () => setState(() => _recoveredTurnNotice = null),
        );
      },
    );
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
    if (mounted && _recoveredTurnNotice?.storageId == prepared.storageId) {
      setState(() => _recoveredTurnNotice = null);
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
    String? submittedTurnClientTurnId,
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
        submittedTurnClientTurnId: submittedTurnClientTurnId,
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

  /// Clears the saved draft of a turn that was queued after this route was
  /// disposed, but only while that draft is still exactly the queued batch:
  /// newer content written for the same session is never touched.
  Future<void> _clearQueuedDraftAfterLeaving(
    String text,
    List<AttachmentDraft> attachments,
  ) async {
    if (widget.connection.readOnly) return;
    try {
      final store =
          _draftStore ??
          widget.draftStoreOverride ??
          ChatDraftStore(await SharedPreferences.getInstance());
      final sessionId = _draftRecoverySessionId;
      final profile = _recoveryProfile;
      final stored = await store.load(
        widget.connection.id,
        sessionId,
        profile: profile,
      );
      if (stored.text != text ||
          !_sameAttachmentDrafts(stored.attachments, attachments)) {
        return;
      }
      await store.clear(widget.connection.id, sessionId, profile: profile);
    } catch (error) {
      debugPrint('[chat-draft] queued cleanup failed (${error.runtimeType})');
    }
  }

  /// Retira el borrador que sigue siendo el lote exacto de un turno ya
  /// aceptado. No depende de esta pantalla: tras salir antes del ACK el
  /// lifecycle ya no admite escrituras y `_clearDraft` no puede actuar. El
  /// store solo borra si el enlace coincide, así que nunca pisa texto nuevo, y
  /// sigue respetando las vallas de borrado de sesión/conexión.
  Future<void> _clearSubmittedTurnDraft(String clientTurnId) async {
    if (widget.connection.readOnly) return;
    try {
      final store =
          _draftStore ??
          widget.draftStoreOverride ??
          ChatDraftStore(await SharedPreferences.getInstance());
      final ids = <String>{
        widget.session.id,
        ?_normalCanonicalDraftId,
        if (_chatBound) ?_chat.createdDraftSessionId,
      }..removeWhere((id) => id.isEmpty);
      for (final id in ids) {
        await store.clear(
          widget.connection.id,
          id,
          profile: _recoveryProfile,
          onlySubmittedTurnClientTurnId: clientTurnId,
        );
      }
    } catch (error) {
      debugPrint(
        '[chat-draft] submitted-turn cleanup failed (${error.runtimeType})',
      );
    }
  }

  /// The connection's shared [SessionArchive], loaded when the chat opens so
  /// a confirmed delete can be recorded without an await.
  SessionArchive? _sharedArchive;

  Future<void> _loadSharedArchive() async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, widget.connection.id);
    if (!mounted) return;
    _sharedArchive = archive;
    // Opening a session marks it read on the server, from whichever surface
    // opened it (Desktop `clearUnreadOnOpen`: every open, only when unread).
    unawaited(archive.markSessionReadOnOpen(widget.session));
  }

  /// Records the server-confirmed delete in the store every list filters
  /// with. Synchronous when the store is loaded (the normal case).
  void _markDeletedInSharedStore() {
    final deletedIds = [_chat.serverSessionId];
    final archive = _sharedArchive;
    if (archive != null) {
      unawaited(
        archive.markSessionDeleted(widget.session, sessionIds: deletedIds),
      );
      return;
    }
    final session = widget.session;
    final connectionId = widget.connection.id;
    unawaited(() async {
      final prefs = await SharedPreferences.getInstance();
      final loaded = await SessionArchive.load(prefs, connectionId);
      await loaded.markSessionDeleted(session, sessionIds: deletedIds);
    }());
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
    final suggestions = slashSuggestionsFor(
      text,
      Strings.of(context),
      sideAgents: _chat.canRunSideAgents,
      branch: _chat.canBranchChat,
    );
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
    _syncComposerCompletionScope();
    _refreshSlashCompletion(text);
    _refreshReferenceQuery();
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
        _rememberRemoteSlashNames(
          catalog.commands.map((entry) => entry.canonicalName),
        );
      }
      return catalog;
    } catch (_) {
      return null;
    }
  }

  void _refreshReferenceQuery() {
    final runtime = _chatBound ? _chat.desktopRuntimeSessionId : null;
    final query =
        _textFocusNode.hasFocus &&
            runtime != null &&
            runtime.isNotEmpty &&
            _chat.supportsDesktopPathCompletion
        ? composerReferenceQuery(_textController.value)
        : null;
    if (query == null) {
      _closeReferencePalette();
      return;
    }
    final key = '$runtime\n${query.word}';
    if (key == _referenceKey) return;
    _referenceKey = key;
    _referenceCompletions.schedule(key, _applyReferences);
  }

  void _closeReferencePalette() {
    _referenceCompletions.cancel();
    _referenceKey = null;
    if (_referenceItems.isNotEmpty && mounted && !_disposed) {
      setState(() => _referenceItems = const []);
    }
  }

  Future<PathCompletionBatch?> _fetchReferences(String key) {
    final split = key.indexOf('\n');
    return _chat.completeDesktopPath(
      key.substring(split + 1),
      runtimeSessionId: key.substring(0, split),
    );
  }

  void _applyReferences(String key, PathCompletionBatch? batch) {
    if (_disposed || !mounted) return;
    // A rotation no chat event announced yet still retires this answer and
    // asks the new runtime instead.
    _syncComposerCompletionScope();
    if (key != _referenceKey) return;
    final items = batch?.items ?? const <PathCompletionItem>[];
    if (items.isEmpty && _referenceItems.isEmpty) return;
    setState(() => _referenceItems = items);
  }

  void _pickReference(PathCompletionItem item) {
    final query = composerReferenceQuery(_textController.value);
    if (query == null) return;
    _textController.value = applyReferencePick(
      _textController.value,
      query,
      item,
    );
  }

  void _descendReference(PathCompletionItem item) {
    final query = composerReferenceQuery(_textController.value);
    if (query == null) return;
    _textController.value = applyReferenceDescend(
      _textController.value,
      query,
      item,
    );
  }

  bool get _referencePaletteVisible =>
      _referenceItems.isNotEmpty &&
      _textFocusNode.hasFocus &&
      !_isRecording &&
      !_transcribing &&
      !_navigationDrawerOpen;

  String get _composerCompletionScope {
    final runtime = _chatBound ? _chat.desktopRuntimeSessionId : null;
    return runtime != null && runtime.isNotEmpty
        ? 'runtime:$runtime'
        : 'profile:$_effectiveSessionProfile';
  }

  /// A runtime bind/rotation or profile change retires every completion keyed
  /// to the previous scope: pending lookups, memoised answers and rows.
  void _syncComposerCompletionScope() {
    final scope = _composerCompletionScope;
    final previous = _completionScope;
    _completionScope = scope;
    if (previous == null || previous == scope) return;
    _slashCompletions
      ..cancel()
      ..clearCache();
    _forgetRuntimeSlashNames();
    _referenceCompletions
      ..cancel()
      ..clearCache();
    _referenceKey = null;
    if (_disposed || !mounted) return;
    if (_referenceItems.isNotEmpty) {
      setState(() => _referenceItems = const []);
    }
    _refreshReferenceQuery();
    final text = _textController.text;
    final local = slashSuggestionsFor(
      text,
      Strings.of(context),
      sideAgents: _chat.canRunSideAgents,
      branch: _chat.canBranchChat,
    );
    setState(() => _slashSuggestions = local);
    _refreshSlashCompletion(text);
  }

  void _refreshSlashCompletion(String text) {
    if (_textFocusNode.hasFocus &&
        text.startsWith('/') &&
        !text.contains(RegExp(r'\s')) &&
        text.length <= 65) {
      _slashCompletions.schedule(
        '$_composerCompletionScope\n$text',
        _applySlashLookup,
      );
    } else {
      _slashCompletions.cancel();
    }
  }

  Future<_SlashLookup?> _fetchSlashLookup(String key) async {
    final split = key.indexOf('\n');
    final scope = key.substring(0, split);
    final input = key.substring(split + 1);
    if (scope != _composerCompletionScope) return null;
    final catalog = await _loadDesktopCommandCatalog();
    SlashCompletionBatch? completion;
    try {
      completion = await _chat.completeDesktopSlash(
        input,
        runtimeSessionId: scope.startsWith('runtime:')
            ? scope.substring('runtime:'.length)
            : null,
        profile: scope.startsWith('profile:')
            ? scope.substring('profile:'.length)
            : '',
      );
    } catch (_) {
      // El catálogo sigue siendo un fallback válido para Gateway modernos que
      // no publiquen complete.slash.
    }
    if (catalog == null && completion == null) return null;
    return _SlashLookup(catalog: catalog, completion: completion);
  }

  void _applySlashLookup(String key, _SlashLookup? lookup) {
    final split = key.indexOf('\n');
    final input = key.substring(split + 1);
    if (_disposed ||
        !mounted ||
        lookup == null ||
        key.substring(0, split) != _composerCompletionScope ||
        _textController.text != input) {
      return;
    }
    final merged = mergeSlashSuggestions(
      input: input,
      local: slashSuggestionsFor(
        input,
        Strings.of(context),
        sideAgents: _chat.canRunSideAgents,
        branch: _chat.canBranchChat,
      ),
      catalog: lookup.catalog,
      completion: lookup.completion,
    );
    _rememberRemoteSlashNames(
      merged
          .where((command) => command.action == SlashAction.remote)
          .map((command) => command.name),
    );
    setState(() => _slashSuggestions = merged);
  }

  /// Names complete.slash offered belong to the scope that answered: another
  /// runtime or profile may not have that skill, so only the gateway-wide
  /// catalog survives a scope change.
  void _forgetRuntimeSlashNames() {
    final controller = _textController;
    if (controller is! _SlashAccentTextEditingController) return;
    controller.remoteCommandNames = Set<String>.unmodifiable({
      for (final entry
          in _desktopCommandCatalog?.commands ?? const <CommandCatalogEntry>[])
        entry.canonicalName,
    });
  }

  /// Lets the composer paint a server command or skill with the same accent as
  /// a local one (owner preference), only once the server has named it.
  void _rememberRemoteSlashNames(Iterable<String> names) {
    final controller = _textController;
    if (controller is! _SlashAccentTextEditingController) return;
    final next = {...controller.remoteCommandNames, ...names};
    if (next.length == controller.remoteCommandNames.length) return;
    controller.remoteCommandNames = Set<String>.unmodifiable(next);
    if (mounted && !_disposed) setState(() {});
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
      // A REST fallback cannot carry the workspace; failing is more honest
      // than silently starting the project chat in another folder.
      allowTransportFallback:
          widget.connection.kind == InstanceKind.localhost &&
          widget.connection.onDeviceLoopback &&
          !resumesStoredBotChat &&
          !createsBotChat &&
          _newChatWorkspace == null,
      workspace: _newChatWorkspace,
    );
  }

  Future<ModelPresetsStore> _modelPresetsStore() async => ModelPresetsStore(
    await SharedPreferences.getInstance(),
    connectionId: widget.connection.id,
  );

  Future<void> _rememberCurrentModelPreset({
    DesktopReasoningEffort? effort,
    DesktopFastMode? fast,
  }) async {
    final selection = _selectedModelPair;
    if (selection == null) return;
    final store = await _modelPresetsStore();
    await store.merge(
      selection.providerSlug,
      selection.modelId,
      effort: effort,
      fast: fast,
    );
  }

  Future<void> _applySelectedModelPreset(String provider, String model) async {
    final store = await _modelPresetsStore();
    final preset = store.read(provider, model);
    if (preset == null) return;
    final capabilities = _desktopModelCatalog
        ?.optionFor(provider, model)
        ?.capabilities;
    await applyModelPresetForCapabilities(
      preset: preset,
      capabilities: capabilities,
      applyEffort: (effort) => _applySessionReasoning(
        effort,
        acquireRuntime: false,
        rememberPreset: false,
      ),
      applyFast: (fast) => _applySessionFastMode(
        fast,
        acquireRuntime: false,
        rememberPreset: false,
      ),
    );
  }

  String? get _newChatWorkspace {
    final workspace = widget.newChatWorkspace?.trim() ?? '';
    return workspace.isEmpty ? null : workspace;
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

  /// mk1215: catalog painted from the picker cache while [_modelOptionsFuture]
  /// revalidates it in the background (stale-while-revalidate).
  (ModelActiveInfo, List<ModelProvider>)? _modelOptionsPainted;

  ModelPickerCache get _modelPickerCache => _chatService.modelPickerCache;
  String get _modelPickerKey =>
      ModelPickerCache.key(widget.connection.id, _chat.sessionProfile);

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

  /// Identity of every pending session-config change, so a `config.set`
  /// transition (sending → accepted/rejected) repaints the chrome even when
  /// `session.info` itself did not change.
  Object get _sessionConfigPresentation => Object.hashAll([
    for (final key in DesktopSessionConfigKey.values)
      if (_chat.pendingSessionConfigChange(key) case final change?)
        (change.requestEpoch, change.status, change.deferred),
  ]);

  /// Model id whose `config.set` Hermes queued for the next turn (mid-turn
  /// switch). Cleared when that turn starts.
  String? _deferredModelId;

  /// md1215: the header shows the picked model while `config.set` is in
  /// flight, or while Hermes holds it for the next message.
  bool get _modelChangePending {
    if (!_chatBound) return false;
    final change = _chat.pendingSessionConfigChange(
      DesktopSessionConfigKey.model,
    );
    if (change?.status == SessionConfigChangeStatus.sending) return true;
    final deferred = _deferredModelId;
    return deferred != null &&
        deferred == (_displayedSessionModel?.modelId ?? _activeModel?.model);
  }

  /// Etiqueta corta del modelo activo para el AppBar (p.ej. "GPT-5.5"). Cae a un
  /// texto neutro mientras carga o si el Dashboard no está accesible.
  String get _activeModelLabel {
    final model = _headerModelId;
    if (model == null) return Strings.of(context).chaModelServer;
    return friendlyModelName(model);
  }

  /// Model id the session chrome paints, or null for the server default.
  String? get _headerModelId {
    // md1215: a draft without a runtime sends `_selectedModel` with its first
    // message; showing the server default instead read as "it did not change".
    final staged =
        _chatBound &&
            !_chat.hasDesktopRuntime &&
            _selectedModel.isNotEmpty &&
            _selectedModel != 'hermes-agent'
        ? _selectedModel
        : null;
    final model =
        _displayedSessionModel?.modelId ?? staged ?? _activeModel?.model;
    if (model == null || model.isEmpty || model == 'hermes-agent') {
      return null;
    }
    return model;
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
        _applyCronRunVerdict(snapshot);
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

  void _applyCronRunVerdict(Session row) {
    if (!CronRunWriteGate.appliesTo(widget.session)) return;
    final readOnly = CronRunWriteGate.readOnlyFor(row);
    if (readOnly == _cronRunReadOnly) return;
    if (mounted) {
      setState(() => _cronRunReadOnly = readOnly);
    } else {
      _cronRunReadOnly = readOnly;
    }
  }

  /// Desktop `refreshCronRunWriteGate`: re-reads the run's authoritative row
  /// right before a send. A row that cannot be read refuses the send (fail
  /// closed): a message into a possibly dead cron run is the misroute this
  /// gate exists to prevent.
  Future<bool> _cronRunAllowsSend() async {
    if (!CronRunWriteGate.appliesTo(widget.session)) return true;
    try {
      final row = await _chat.loadPersistedSessionSnapshot();
      if (_disposed || !mounted || row == null) return false;
      _applyCronRunVerdict(row);
      return !_cronRunReadOnly;
    } catch (error) {
      debugPrint('[chat] cron run row unavailable (${error.runtimeType})');
      return false;
    }
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

  /// Lee el modelo activo para pintar el badge del AppBar. Con runtime vivo,
  /// `session.info` es la fuente. Sin él (mk1215), el catálogo ya cacheado del
  /// selector o `model.options` sin sesión por el socket del gateway, como
  /// Desktop. Abrir, volver o reanudar el chat nunca llama al Mobile Bridge ni
  /// al Dashboard: solo el selector abierto recurre a ellos.
  Future<void> _loadActiveModel() async {
    if (!_chatBound) {
      // initState: el chat se enlaza en didChangeDependencies, justo después.
      await null;
      if (!mounted || !_chatBound) return;
    }
    if (_chat.hasDesktopRuntime) {
      _syncDesktopSessionConfig();
      if (_activeModel?.model.isNotEmpty == true) return;
    }
    final key = _modelPickerKey;
    var catalog = _modelPickerCache.peek(key)?.result;
    if (catalog == null &&
        !_modelPickerCache.isCoolingDown(key, ModelPickerSource.socket)) {
      catalog = await _socketModelPickerResult(connectedOnly: true);
      if (catalog != null && catalog.hasModels) {
        _modelPickerCache.write(key, catalog);
      }
    }
    if (catalog == null || !mounted || _chat.hasDesktopRuntime) return;
    final info = catalog.info;
    // Punto 2 (spec 028): no mostrar como activo el model.default del
    // servidor si NINGÚN proveedor tiene credencial detrás.
    if (info.model.isEmpty || !catalog.providers.any((p) => p.authenticated)) {
      return;
    }
    if (catalog.source == ModelPickerSource.gateway) return;
    setState(() => _activeModel = info);
    _chatService.updateHomeWidgetSessionMetadata(
      _chat,
      model: info.model,
      provider: info.provider,
    );
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
      // The cached catalog marks the old model as current: repaint it at
      // once on the next open but revalidate it.
      _modelPickerCache.invalidate(_modelPickerKey);
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

  String get userServerMediaScope =>
      '${widget.connection.id}\u0000$_effectiveSessionProfile';

  /// Fetches a user attachment that Hermes persisted as an `@image:`/`@file:`
  /// server path into the app-private media cache. Managed-files download is
  /// tried first; images outside the managed root fall back to `/api/media`
  /// (Hermes' images/screenshots/cache roots).
  Future<File> downloadUserServerAttachment(GeneratedMediaReference reference) {
    final profile = _effectiveSessionProfile;
    final testFetcher = widget.userServerMediaFetcher;
    final maxBytes = reference.kind == GeneratedMediaKind.image
        ? GeneratedMediaService.maxImageBytes
        : GeneratedMediaService.maxFileBytes;
    return GeneratedMediaService.ensureDownloaded(
      userServerMediaScope,
      reference,
      fetchServerPathToFile: (path, destination) async {
        if (testFetcher != null) return testFetcher(path, destination);
        final client = DashboardClient.lazy(widget.connection);
        try {
          await client.apiDownloadToFile(
            'files/download?path=${Uri.encodeQueryComponent(path)}',
            destination,
            maxBytes: maxBytes,
            profile: profile,
          );
        } on DashboardHttpException catch (error) {
          if (reference.kind != GeneratedMediaKind.image ||
              (error.statusCode != 400 && error.statusCode != 403)) {
            rethrow;
          }
          final media = await client.apiGet(
            'media?path=${Uri.encodeQueryComponent(path)}',
          );
          final dataUrl = media['data_url'];
          final data = dataUrl is String && dataUrl.startsWith('data:')
              ? Uri.tryParse(dataUrl)?.data
              : null;
          if (data == null || !data.isBase64) rethrow;
          await destination.writeAsBytes(data.contentAsBytes(), flush: true);
        } finally {
          client.close();
        }
      },
    );
  }

  /// Same scope the generated-media disk cache is keyed by.
  String get generatedMediaCacheScope =>
      '${widget.connection.id}\u0000$_effectiveSessionProfile';

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
    final cacheScope = generatedMediaCacheScope;
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
    final result = await _loadModelPickerResult();
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null;
    }
    return _withoutHiddenModels(result, prefs);
  }

  /// Respeta lo que el usuario ocultó en la pantalla de Modelos (spec 028 U-05):
  /// esas mismas claves de SharedPreferences se aplican también aquí, para que
  /// el selector del chat no muestre proveedores/modelos que el usuario quitó
  /// de la vista. Proveedores = slugs; modelos = "slug/modelId".
  (ModelActiveInfo, List<ModelProvider>) _withoutHiddenModels(
    ModelPickerResult result,
    SharedPreferences? prefs,
  ) {
    final info = result.info;
    final providers = result.providers;
    if (prefs == null) return (info, providers);
    try {
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

  /// Fuente de la que vino el catálogo: decide por dónde se persiste la
  /// selección y qué filas son elegibles.
  void _adoptModelPickerResult(ModelPickerResult result) {
    _modelSource = switch (result.source) {
      ModelPickerSource.socket => _ModelSource.desktop,
      ModelPickerSource.bridge => _ModelSource.bridge,
      ModelPickerSource.dashboard => _ModelSource.dashboard,
      ModelPickerSource.gateway => _ModelSource.gateway,
    };
    _desktopModelCatalog = result.desktopCatalog;
  }

  /// mk1215: como Desktop, `model.options` por el socket del gateway primero
  /// (con o sin runtime). Bridge y Dashboard solo como respaldo, en paralelo y
  /// con un plazo corto; la lista del gateway al final. Gane quien gane, el
  /// catálogo queda cacheado por conexión y perfil, y una fuente que falla se
  /// recuerda un rato para no reintentarla en cada apertura.
  Future<ModelPickerResult> _loadModelPickerResult() async {
    ModelPickerSourceLoader fallback(
      ModelPickerSource source,
      Future<(ModelActiveInfo, List<ModelProvider>)?> Function() read,
    ) => () async {
      final result = await read();
      if (result == null) return null;
      return ModelPickerResult(
        info: result.$1,
        providers: result.$2,
        source: source,
      );
    };

    final result = await loadModelPickerCatalog(
      cache: _modelPickerCache,
      key: _modelPickerKey,
      sources: {
        ModelPickerSource.socket: _socketModelPickerResult,
        ModelPickerSource.bridge: fallback(
          ModelPickerSource.bridge,
          _bridgeModelOptions,
        ),
        ModelPickerSource.dashboard: fallback(
          ModelPickerSource.dashboard,
          _dashboardModelOptions,
        ),
        ModelPickerSource.gateway: fallback(
          ModelPickerSource.gateway,
          _gatewayModelOptions,
        ),
      },
    );
    if (mounted) _adoptModelPickerResult(result);
    return result;
  }

  /// Catálogo del Dashboard (con su propio login si lo exige): solo los
  /// proveedores autenticados con modelos. Una lista vacía no gana a otra
  /// fuente, pero se muestra como «sin modelos» si nadie más responde.
  Future<(ModelActiveInfo, List<ModelProvider>)?>
  _dashboardModelOptions() async {
    final fake = widget.modelPickerFallbacks?[ModelPickerSource.dashboard];
    if (fake != null) return fake();
    final client = DashboardClient.lazy(widget.connection);
    try {
      final info = await client.getModelInfo();
      final providers = await client.getModelOptions();
      final usable = providers
          .where((p) => p.authenticated && p.models.isNotEmpty)
          .toList();
      return (info, usable);
    } finally {
      client.close();
    }
  }

  Future<ModelPickerResult?> _socketModelPickerResult({
    bool connectedOnly = false,
  }) async {
    final catalog = await _desktopSessionModelOptions(
      connectedOnly: connectedOnly,
    );
    if (catalog == null) return null;
    return ModelPickerResult(
      info: catalog.$1,
      providers: catalog.$2,
      source: ModelPickerSource.socket,
      desktopCatalog: catalog.$3,
    );
  }

  Future<(ModelActiveInfo, List<ModelProvider>, DesktopModelCatalog)?>
  _desktopSessionModelOptions({bool connectedOnly = false}) async {
    // mk1215: without a runtime the catalog is read sessionless; an already
    // connected shared socket saves the chat's own handshake.
    final warm = SharedGatewayPool.instance.acquireIfConnected(
      widget.connection,
    );
    try {
      final catalog = await _chat.loadDesktopModelCatalog(
        warmGateway: warm?.client,
        connectedOnly: connectedOnly,
      );
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
      return (
        ModelActiveInfo(
          model: catalog.currentModel ?? _selectedModel,
          provider: catalog.currentProvider ?? _selectedProvider,
          effectiveContextLength: 0,
        ),
        providers,
        catalog,
      );
    } catch (_) {
      return null;
    } finally {
      warm?.release();
    }
  }

  /// Catálogo de modelos vía Mobile Bridge. El token se auto-provisiona desde la
  /// API key del gateway (`/bridge/provision`), así basta UNA credencial y no se
  /// depende del login del Dashboard. Devuelve null si no hay bridge (el llamante
  /// cae al Dashboard). El bridge devuelve la misma forma que `/api/model/options`.
  Future<(ModelActiveInfo, List<ModelProvider>)?> _bridgeModelOptions() async {
    final fake = widget.modelPickerFallbacks?[ModelPickerSource.bridge];
    if (fake != null) return fake().then((r) => r, onError: (Object _) => null);
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
    final fake = widget.modelPickerFallbacks?[ModelPickerSource.gateway];
    if (fake != null) return fake().then((r) => r, onError: (Object _) => null);
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
      _lastReadPrefs = app.connManager.prefs;
      _lastReadKeyOnEntry = app.connManager.prefs.getString(_lastReadPrefsKey);
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
      _chat.transportStatusListenable.addListener(_syncTransportVisibility);
      _lastObservesRemoteTurnAfterReconnect =
          _chat.observesRemoteTurnAfterReconnect;
      _syncTransportVisibility();
      _transportVisibility.addListener(_onTransportVisibilityChanged);
      _seenDurableSessionsChangeRevision = _chat.durableSessionsChangeRevision;
      // The viewed mark only advances after a successful passive read (see
      // _refreshPassiveTranscript): a screen that leaves before its read
      // lands, or whose read fails, leaves the change unseen for the next.
      final unseenDurableStoreChange =
          _chat.durableSessionsChangeRevision !=
          _chat.viewedDurableSessionsChangeRevision;
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
        _resolveNewSinceYouLeft();
        if (unseenDurableStoreChange && !_chat.isStreaming) {
          // re1215: `sessions.changed` reached this chat while no screen
          // watched it (the end of a turn the user walked away from, or
          // Desktop going on). Nothing consumed those ticks, so the rows
          // stayed unread until a tap on «load earlier» re-read the tail.
          // Re-entry delivers them now, through the same tail-probe gate.
          _durableTranscriptReadPending = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_disposed || !mounted) return;
            _syncPassiveTranscriptRefresh(refreshNow: true);
          });
        }
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
    if (_disposed || !mounted || bottomInset <= 0 || _findOpen) return;
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
    if (visible) _rememberColdStartRoute();
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
      _clearOwnChatNotifications();
    } else {
      if (!_coveredByAppLock) _ownNotificationsClearedFor = null;
      final marked = _markedNotificationSessionId;
      if (marked != null && notif.visibleSessionId == marked) {
        notif.visibleSessionId = null;
      }
      _markedNotificationSessionId = null;
    }
  }

  /// The user sees this chat (on top, app in front): the reply
  /// notifications it already has in the tray are read. A reply posted while
  /// the app is in the background stays until the user comes back to it.
  /// Under App Lock nothing is cleared until unlock, and only if this chat
  /// is then in front (see [ChatNotificationReadSync]).
  void _clearOwnChatNotifications({bool resumed = false}) {
    if (!_chatBound || !_appInForeground) return;
    if (!_chatRouteVisible && !_coveredByAppLock) return;
    final notif = _chatService.notifications;
    final chat = _chat;
    final sessionId = chat.serverSessionId;
    if (notif == null || sessionId.isEmpty) return;
    final key = '${chat.connection.id}|$sessionId';
    if (_ownNotificationsClearedFor == key && !resumed) return;
    _ownNotificationsClearedFor = key;
    unawaited(
      notif.clearChatNotifications(
        connId: chat.connection.id,
        profile: chat.sessionProfile,
        sessionId: sessionId,
        // Notifications posted before a compression rotation carry an
        // earlier id of this same chat.
        aliases: {
          ...widget.session.identityIds,
          chat.sessionId,
          ?chat.storedSessionId,
          chat.desktopCompactionLineageId,
        },
        stillWanted: () =>
            mounted &&
            !_disposed &&
            _chatBound &&
            identical(_chat, chat) &&
            _appInForeground &&
            (ModalRoute.of(context)?.isCurrent ?? false),
      ),
    );
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
    // Polling stopped (route covered, background, runtime change): the next
    // start refreshes immediately, so the eventless ladder starts over.
    _eventlessBackstopIndex = 0;
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

  /// Fallback cadence when the backend does not announce change events:
  /// 5 s → 15 s → 30 s instead of a fixed 5 s, reset once events return.
  static const _eventlessBackstopDelays = [5, 15, 30];
  int _eventlessBackstopIndex = 0;

  Duration _adaptiveBackstopDelay() {
    if (!_chat.desktopChangeEventsAvailable) {
      final index = _eventlessBackstopIndex.clamp(
        0,
        _eventlessBackstopDelays.length - 1,
      );
      _eventlessBackstopIndex = index + 1;
      return Duration(seconds: _eventlessBackstopDelays[index]);
    }
    _eventlessBackstopIndex = 0;
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
    // The gateway owner is backing off after a transport loss: pause instead
    // of issuing RPCs, and resume once its backoff elapses.
    final backoff = _chat.desktopReconnectBackoffRemaining;
    if (backoff > Duration.zero) {
      _scheduleAdaptiveSnapshot(
        backoff + const Duration(milliseconds: 50),
        subagents: subagents,
        processes: processes,
        control: control,
      );
      return;
    }
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
    // `sessions.changed` is direct evidence the durable store moved — unlike
    // the roster-derived heuristics below, it does not depend on catching
    // another surface's turn while it is still `busy`. A fast turn on
    // Desktop can complete before this client's next roster poll, leaving
    // `remoteSurfaceOwnsLiveTurn` false even though state.db just changed;
    // without this bypass such a reply would sit unread until an unrelated
    // event happened to trigger a passive read.
    final durableChangeConfirmed = _durableTranscriptReadPending;
    // Store changes up to this revision were broadcast before this read
    // started, so a read that succeeds has reconciled them.
    final durableRevisionAtStart = _chat.durableSessionsChangeRevision;
    final ownedLiveTurn = _chat.remoteSurfaceOwnsLiveTurn;
    await _chat.refreshPassiveRemoteActivity();
    if (!_canProbePassiveRemoteActivity) return true;
    // El sondeo ya cumplió su parte; el transcript durable no se lee mientras
    // el turno siga vivo (una lectura así reaparece como burbuja duplicada).
    if (_chat.isStreaming) return true;
    // Another surface's assistant is not in REST until the turn ends. The
    // busy poll therefore never sees the reply; fetch once more on idle.
    final remoteTurnSettled = ownedLiveTurn && !_chat.remoteSurfaceOwnsLiveTurn;
    if (!_canPassivelyRefreshTranscript &&
        !remoteTurnSettled &&
        !durableChangeConfirmed) {
      return true;
    }
    if (!_composerEmpty &&
        !_chat.remoteSurfaceOwnsLiveTurn &&
        !remoteTurnSettled &&
        !durableChangeConfirmed) {
      return true;
    }
    // A large chat's newest page is megabytes, and `sessions.changed` fires
    // for any session every couple of seconds while an agent works. Read the
    // newest durable row first; when it and the local projection match the
    // last published page, the full page cannot add anything.
    final probe = await _chat.probePassiveDurableTail();
    if (!_canProbePassiveRemoteActivity) return true;
    if (probe != null && probe.unchanged && !_chat.isStreaming) {
      _durableTranscriptReadPending = false;
      _markDurableRevisionViewed(durableRevisionAtStart);
      return true;
    }
    final fetched = await _fetchMessages(passiveOnly: true);
    _chat.confirmPassiveDurableTail(fetched ? probe?.tail : null);
    // Only retire the pending flag on a successful read — a transient
    // failure (disconnect/network blip) must keep bypassing the runtime-
    // ownership gate on the reader's own retry, or the signal would be lost
    // the moment the first attempt fails.
    if (fetched) {
      _durableTranscriptReadPending = false;
      _markDurableRevisionViewed(durableRevisionAtStart);
    }
    return fetched;
  }

  /// re1215: record on the chat, which outlives this screen, that the
  /// durable store has been reconciled up to [revision]. Only a successful
  /// read calls this, so a change a screen never read stays pending for the
  /// next screen that binds the chat.
  void _markDurableRevisionViewed(int revision) {
    if (_disposed || !_chatBound) return;
    if (revision > _chat.viewedDurableSessionsChangeRevision) {
      _chat.viewedDurableSessionsChangeRevision = revision;
    }
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
    _coveredByAppLock = false;
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
    // The App Lock gate pushes its screen only once `locked` is set.
    _coveredByAppLock =
        context
            .findAncestorStateOfType<HermesAppState>()
            ?.appLock
            .locked
            .value ??
        false;
    _markChatVisible(false); // la tapó otra pantalla
  }

  @override
  void didPop() {
    _invalidateOwnedNativeVoicePreparation();
    _markChatVisible(false); // esta pantalla se va
    _forgetColdStartRoute();
  }

  /// cs1215: remembers this chat as the connection's last foreground route,
  /// so a cold start reopens it (identifiers only, encrypted). A chat that
  /// does not exist on the server yet is not remembered.
  void _rememberColdStartRoute() {
    if (!_chatBound || _disposed) return;
    final store = _chatService.coldStartStore;
    if (store == null) return;
    final storedId = _chat.storedSessionId;
    final durable = storedId != null && storedId.isNotEmpty
        ? storedId
        : widget.session.isUnpersistedMobileDraft
        ? null
        : _chat.serverSessionId;
    if (!_isBotChatSurface && (durable == null || durable.isEmpty)) return;
    unawaited(
      store
          .rememberRoute(
            ColdStartRoute(
              kind: _isBotChatSurface
                  ? ColdStartRouteKind.bot
                  : ColdStartRouteKind.chat,
              connectionId: widget.connection.id,
              profile: _chat.sessionProfile,
              sessionId: durable ?? '',
              source: widget.session.source,
            ),
          )
          .catchError((Object error) {
            debugPrint('[cold-start] route not saved (${error.runtimeType})');
          }),
    );
  }

  /// This chat left the stack: forget it as the remembered route, so the
  /// surface below (Home, Bot Mode) is what a cold start shows.
  void _forgetColdStartRoute() {
    if (!_chatBound) return;
    final store = _chatService.coldStartStore;
    if (store == null) return;
    final ids = <String>{
      widget.session.id,
      _chat.sessionId,
      _chat.serverSessionId,
      if (_chat.storedSessionId != null) _chat.storedSessionId!,
    };
    unawaited(
      store
          .forgetRoute(
            widget.connection.id,
            when: (route) =>
                (route.kind == ColdStartRouteKind.chat ||
                    route.kind == ColdStartRouteKind.bot) &&
                ids.contains(route.sessionId),
          )
          .catchError((Object _) {}),
    );
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
    // ss1215: until the first resume/activate answer, a session that is
    // already running on the server shows its remembered state (roster plus
    // the last visit), so opening it never paints an empty pill first.
    final provisional = _chat.provisionalLiveStatus;
    if (provisional != null && provisional.turnLive && !_turnLive) {
      return _provisionalActivitySnapshot(provisional);
    }
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
          ? (_chat.turnClockOrigin ?? _turnActivityStartedAt)
          : null,
      headline: turnActive ? _traceHeadline() : null,
      waitingForUser: turnActive && (_turnWaitsForUser || _chat.needsInput),
      noActivityHint: turnActive && _chat.noActivityHint,
      current: steps.current,
      done: steps.done,
      tasks: _chat.agentTasks,
      processes: activity.processes,
      schedules: activity.schedules,
      goal: activity.goal,
      processesStale: _chat.backgroundProcessesStale,
      subagentsStale: _chat.subagentLivenessStale,
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

  ActivitySnapshot _provisionalActivitySnapshot(SessionLiveStatus status) {
    final s = Strings.of(context);
    final tool = status.toolLabel;
    return ActivitySnapshot(
      turnActive: true,
      tasksActive: true,
      // ps1215: the remembered turn start keeps the timer counting from the
      // real start on reopen instead of showing no timer (or 0:00).
      turnStartedAt: _chat.provisionalTurnStartedAt,
      headline: switch (status.phase) {
        SessionLivePhase.responding => s.chaPipelineStreaming,
        SessionLivePhase.thinking => s.chaPipelineThinking,
        _ => s.ss1215StatusWorking,
      },
      waitingForUser: status.phase == SessionLivePhase.waitingForUser,
      current: tool == null
          ? null
          : ActivityStep(
              id: 'ss1215-provisional',
              kind: ActivityStepKind.tool,
              label: tool,
              status: ActivityStepStatus.running,
              detail: status.toolDetail,
            ),
      tasks: status.tasks,
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
    return _chat.wallNow().difference(startedAt) >= const Duration(seconds: 2);
  }

  void _syncTurnActivityClock() {
    if (_chat.isStreaming) {
      // Un solo origen por turno: los tics posteriores no deben reiniciarlo o
      // el contador volvería a cero en cada herramienta.
      //
      // ps1215: el origen vive en el ActiveChat, que sobrevive a salir del
      // chat; esta pantalla solo lo lee. Antes era un campo de la pantalla y
      // volver a entrar en un turno en marcha reiniciaba el contador a 0:00.
      // El chat usa el inicio real del turno del gateway cuando lo conoce
      // (snapshot de resume, `message.start`); al terminar el turno lo borra.
      _turnActivityStartedAt = _chat.anchorTurnClock();
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

  /// `toolProgress` arrives once per reasoning/thinking delta and per tool
  /// progress tick: reasoning models stream hundreds per second. Each one used
  /// to run the full handler (transcript projections, render invalidation and
  /// a screen setState), so a burst cost several whole-transcript projections
  /// per frame in a long chat. A burst is coalesced into one handler run per
  /// frame. Any other event flushes the pending one first, so ordering is
  /// kept and terminal/approval transitions still paint immediately; the
  /// timer covers the case where no frame is produced (app in background).
  ///
  /// `subagentActivity` is coalesced too, but leading-edge: a busy child
  /// relays several `subagent.tool`/`thinking` events per frame, yet the
  /// first one of a frame (and the repair nudges sent as `subagentActivity`)
  /// must still be handled synchronously so the card and the repair debounce
  /// start from the event itself. The rest of that frame collapse into one
  /// trailing pass. That pass is the `toolProgress` one minus the segment
  /// boundary, so a pending `toolProgress` covers it and a pending
  /// `subagentActivity` is upgraded when `toolProgress` joins the same frame.
  ActiveChatEvent? _coalescedPending;
  Timer? _toolProgressFlushTimer;
  bool _subagentLeadingEdgeUsed = false;

  void _onChatEvent(ActiveChatEvent event) {
    if (_disposed || !mounted) return;
    _syncComposerCompletionScope();
    if (event == ActiveChatEvent.subagentActivity &&
        !_subagentLeadingEdgeUsed &&
        _coalescedPending == null) {
      _subagentLeadingEdgeUsed = true;
      SchedulerBinding.instance.scheduleFrameCallback(
        (_) => _subagentLeadingEdgeUsed = false,
      );
    } else if (event == ActiveChatEvent.toolProgress ||
        event == ActiveChatEvent.subagentActivity) {
      final pending = _coalescedPending;
      if (pending != null) {
        if (event == ActiveChatEvent.toolProgress) _coalescedPending = event;
        return;
      }
      _coalescedPending = event;
      SchedulerBinding.instance.scheduleFrameCallback(
        (_) => _flushPendingToolProgress(),
      );
      _toolProgressFlushTimer = Timer(
        const Duration(milliseconds: 34),
        _flushPendingToolProgress,
      );
      return;
    }
    _flushPendingToolProgress();
    if (_disposed || !mounted) return;
    _handleChatEvent(event);
  }

  void _flushPendingToolProgress() {
    final pending = _coalescedPending;
    if (pending == null) return;
    _coalescedPending = null;
    // No frame may follow (app in background): reopen the leading edge.
    _subagentLeadingEdgeUsed = false;
    _toolProgressFlushTimer?.cancel();
    _toolProgressFlushTimer = null;
    if (_disposed || !mounted) return;
    _handleChatEvent(pending);
  }

  void _syncTransportVisibility() {
    if (_disposed) return;
    _transportVisibility.update(
      status: _chat.transportStatus,
      activeTurn: _chat.isStreaming,
      authRequired: _chat.dashboardAuthRequired,
      appForeground: _appInForeground,
    );
    // cq1215: the pill headline of a post-cut viewer follows the transport
    // (connecting vs. watching a running turn). A reconnect inside the grace
    // window changes no visibility edge, so repaint on this edge too.
    final observing = _chat.observesRemoteTurnAfterReconnect;
    if (observing != _lastObservesRemoteTurnAfterReconnect) {
      _lastObservesRemoteTurnAfterReconnect = observing;
      if (mounted) setState(() {});
    }
  }

  bool _lastObservesRemoteTurnAfterReconnect = false;

  void _onTransportVisibilityChanged() {
    if (_disposed || !mounted) return;
    setState(() {});
  }

  void _handleChatEvent(ActiveChatEvent event) {
    if (_findOpen && event != ActiveChatEvent.token) _scheduleFindRefresh();
    _syncTransportVisibility();
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
      // A queued model switch is applied by Hermes at this turn's start.
      _deferredModelId = null;
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
    // `sessions.changed` is the same session-less broadcast Desktop already
    // reconciles its open pane on (see wiring.tsx#refreshActiveTranscript):
    // Desktop treats it as an unconditional reconcile trigger and lets its
    // own message-signature gate (sessionMessagesSignature) turn a no-change
    // tick into a no-op REST diff. Console received the event and refreshed
    // the session list/roster but never the open transcript; mirror Desktop
    // by feeding it into the same passive-read trigger as a recovery-class
    // event, gated by the existing busy/foreground/route checks so a
    // mid-stream tick defers instead of clobbering a live turn.
    final durableSessionsChangeRevision = _chat.durableSessionsChangeRevision;
    final sessionsChangedTick =
        durableSessionsChangeRevision != _seenDurableSessionsChangeRevision;
    if (sessionsChangedTick) {
      _seenDurableSessionsChangeRevision = durableSessionsChangeRevision;
      _durableTranscriptReadPending = true;
    }
    // re1215: the `sessionInfo` that only carries a `sessions.changed` tick
    // goes through the reader's 10 s gap (see notifyDurableStoreChanged):
    // another session writing every 2 s must not poll this chat every 2 s.
    final storeChangeOnly =
        sessionsChangedTick &&
        event == ActiveChatEvent.sessionInfo &&
        !passiveTerminalEvent &&
        !passiveRuntimeEvent;
    _syncPassiveTranscriptRefresh(
      refreshNow:
          !storeChangeOnly &&
          (sessionsChangedTick ||
              passiveTerminalEvent ||
              passiveRecoveryEvent ||
              passiveRuntimeEvent),
      recoveryConverging:
          !storeChangeOnly && (passiveRecoveryEvent || sessionsChangedTick),
      terminal: passiveTerminalEvent,
    );
    if (storeChangeOnly && _canProbePassiveRemoteActivity) {
      _passiveConversationReader?.notifyDurableStoreChanged();
    }
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
        // Fuera de un turno `_autoFollowStreaming` sigue en true aunque el
        // lector haya subido: decide por la posición medida ANTES del relayout.
        final readerWasAtBottom = _isNearBottom;
        _resolveNewSinceYouLeft();
        _anchorReaderAcrossServiceHydration();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // La hidratación diferida del historial (0.20) o una compactación
          // pueden aterrizar a mitad de stream con el lector arriba. Solo
          // reengancha el fondo si el seguimiento sigue activo; si el usuario
          // pausó el seguimiento para leer, la hidratación no le roba la vista.
          if (mounted && _autoFollowStreaming && readerWasAtBottom) {
            _scrollToBottom(animate: false);
          }
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
      final awaitsUnseenInput = (
        _chat.awaitsUnseenInput,
        _chat.openRequestRecoveryFailed,
        _chat.openRequestRecoveryInFlight,
      );
      if (contextCompacting) {
        _sessionContextAwaitingPostCompactionMetrics = true;
      }
      final invalidateAfterCompaction =
          _sessionContextAwaitingPostCompactionMetrics && !contextCompacting;
      // md1215: config.set publishes `sessionInfo` without touching
      // `session.info`; the pending pick must still repaint the header now.
      final configPresentation = _sessionConfigPresentation;
      contextOnlySessionInfo =
          _desktopRuntimePresentationFingerprint != null &&
          _desktopRuntimePresentationFingerprint == presentationFingerprint &&
          _lastDesktopCompacting == compacting &&
          _lastDesktopCompressionPresentation == compressionPresentation &&
          _activityPresentationFingerprint == activityPresentation &&
          _lastSessionConfigPresentation == configPresentation &&
          _lastAwaitsUnseenInput == awaitsUnseenInput;
      _lastAwaitsUnseenInput = awaitsUnseenInput;
      _lastSessionConfigPresentation = configPresentation;
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
      if (event == ActiveChatEvent.earlierMessagesLoaded) {
        _recountNewWhileAway(olderHistoryOnly: true);
      } else if (event != ActiveChatEvent.sessionInfo &&
          event != ActiveChatEvent.responseMetrics) {
        _recountNewWhileAway();
      }
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
      case ActiveChatEvent.dashboardAuthChanged:
        // A background read (resume, settle, recovery) found the profile
        // unreachable on both routes.
        if (_chat.profileTranscriptAccessBlocked) {
          _showProfileTranscriptAccessError();
        }
        break;
      case ActiveChatEvent.sessionInfo:
      case ActiveChatEvent.goalUpdated:
      // The generic setState above already repaints _buildGoalStrip; no
      // extra behavior (scrolling, etc.) is needed for a status change.
      case ActiveChatEvent.backgroundTaskComplete:
      case ActiveChatEvent.reactionsChanged:
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
  Future<void> _openConnectionLink(Uri uri) async {
    _chat.noteConnectionLinkOpened();
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // The card keeps its Open link action; nothing to undo.
    }
  }

  void _answerConnection(Future<void> Function() answer) {
    unawaited(answer().catchError((Object _) {}));
  }

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
    _composerTurnSettleRetryTimer?.cancel();
    _composerTurnSettleRetryTimer = null;
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
    _persistLastRead();
    _chatSub?.cancel();
    _chatSub = null;
    if (_chatBound) {
      _chat.transportStatusListenable.removeListener(_syncTransportVisibility);
    }
    _transportVisibility.removeListener(_onTransportVisibilityChanged);
    _transportVisibility.dispose();
    _toolProgressFlushTimer?.cancel();
    _toolProgressFlushTimer = null;
    _coalescedPending = null;
    _attachmentDelivery?.removeAttachmentListener(_attachmentListener);
    _attachmentDelivery = null;
    // El modo voz YA NO se destruye al cerrar la pantalla: vive en el servicio
    // global y debe sobrevivir a la navegación (el agente sigue hablando y al
    // volver retomas la conversación). Solo nos desuscribimos de su estado.
    _vc?.removeListener(_onVoiceState);
    _voice?.voiceConsent.removeListener(_onVoicePreferenceChanged);
    _vcUnavailableSub?.cancel();
    _slashCompletions.dispose();
    _referenceCompletions.dispose();
    _stopFallback?.cancel();
    _stopConfirmationDismissTimer?.cancel();
    // Detén SOLO el dictado del composer (el de esta pantalla), no el TTS del
    // modo voz: ese debe seguir si está hablando en segundo plano.
    String? dictatedDraft;
    if (_isRecording) {
      _commitPendingDictationPartial();
      if (_dictationBase != _dictationOriginal.trimRight()) {
        dictatedDraft = _dictationBase;
      }
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
        dictatedDraft ?? _textController.text,
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
    _newWhileAway.dispose();
    _transcriptConcealed
      ..removeListener(_scheduleStickyPromptUpdate)
      ..dispose();
    _stickyPrompt.dispose();
    _findStatus.dispose();
    _findActiveMessage.dispose();
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
    if (_chatBound) _syncTransportVisibility();
    if (!wasInForeground && _appInForeground) {
      _clearOwnChatNotifications(resumed: true);
    }
    // Coming back from the browser leg of a connector: read the accounts now.
    if (!wasInForeground && _appInForeground && _chatBound) {
      _chat.connectionAppResumed();
    }
    if (wasInForeground != _appInForeground) {
      _viewerAttachGeneration += 1;
      _cancelSessionContextBootstrapRetry();
    }
    if (!_appInForeground && (_streamingRevealTimer?.isActive ?? false)) {
      _advanceStreamingReveal();
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
      _persistLastRead();
      // cs1215: a chat created during this visit has a durable id now.
      if (_chatRouteVisible) _rememberColdStartRoute();
      // A setup that began while this route owned the foreground cannot regain
      // authority after an asynchronous dashboard response. This only revokes
      // the opaque preparation; an already-active opted-in conversation stays
      // under the global controller's lifecycle policy.
      _invalidateOwnedNativeVoicePreparation();
      // No dependas del debounce si Android congela o termina el proceso justo
      // después de mandar la app al fondo. Persistimos el estado exacto del
      // composer (texto + adjuntos) antes de perder tiempo de ejecución.
      _draftTimer?.cancel();
      if (_isRecording && !_transcribing) {
        final voice = _voice;
        if (voice != null && voice.sttRecordsThenTranscribes) {
          // El audio ya grabado se transcribe y llega por la suscripción viva.
          unawaited(_stopDictation());
        } else {
          _commitPendingDictationPartial();
          _voice?.stopDictation();
          _resetDictation();
          _materializeDictation();
        }
      }
      if (!_composerSubmissionInFlight &&
          _failedTurnDiscardInFlightId == null) {
        unawaited(
          _saveDraftSnapshot(
            _textController.text,
            List<AttachmentDraft>.of(_pendingAttachments),
          ),
        );
      }
    }
    // Al volver a primer plano, repinta la configuración conocida sin mutarla.
    if (state == AppLifecycleState.resumed) {
      _loadActiveModel();
      if (_chatBound) {
        unawaited(_chat.warmDesktopGatewayForAutomaticBootstrap());
        if (!wasInForeground) _relaunchViewerAttachOnResume();
      }
    }
  }

  Future<void>? _resumeViewerAttach;
  int? _resumeViewerAttachGeneration;

  /// Un corte con la app en segundo plano retira el runtime y nada volvía a
  /// enlazarlo al reanudar: sin runtime no hay `process.list`/`subagent.list`
  /// y la pastilla se apagaba con Hermes trabajando. Relanza una sola vez
  /// (coalescido) el attach del visor y re-sincroniza el sondeo. Nunca durante
  /// un turno vivo (la convergencia no adopta runtimes no probados) ni con la
  /// recuperación cerrada por un error terminal.
  void _relaunchViewerAttachOnResume() {
    // Coalesce solo dentro de la misma generación: un paso intermedio por
    // inactive invalida el attach en vuelo y debe poder relanzarse.
    if ((_resumeViewerAttach != null &&
            _resumeViewerAttachGeneration == _viewerAttachGeneration) ||
        _disposed ||
        !mounted ||
        !_chatRouteVisible ||
        !_appInForeground ||
        !_chat.attachesDesktopRuntimeOnLoad ||
        _chat.desktopRuntimeSessionId != null ||
        _chat.isStreaming ||
        _chat.desktopViewerRecoveryClosed) {
      return;
    }
    late final Future<void> attach;
    attach = _ensureDesktopRuntimeAndBootstrapContext().whenComplete(() {
      if (identical(_resumeViewerAttach, attach)) _resumeViewerAttach = null;
      if (!_disposed && mounted) _syncSubagentPolling();
    });
    _resumeViewerAttach = attach;
    _resumeViewerAttachGeneration = _viewerAttachGeneration;
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
    _scheduleStickyPromptUpdate();
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
          _findOpen ||
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
        _findOpen ||
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
    // Already at the newest row, or bouncing past it: a jump would cut the
    // spring (and a held drag) with a one-frame snap to the edge.
    final position = _scrollController.position;
    if (position.pixels <= position.minScrollExtent) return;
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
    final streamingHead = _chat.isStreaming;
    if (cached != null &&
        cached.canReuseFor(messages, streamingHead: streamingHead)) {
      return cached;
    }
    widget.performanceProbe?.renderProjectionBuilds++;
    return _renderProjection = ChatRenderProjection.build(
      messages,
      streamingHead: streamingHead,
    );
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
    final content = _joinResponseGroupText(
      _responseGroupTextPrefix(_olderResponseGroupRows(message)),
      (message['content'] as String?) ?? '',
    );
    if (content.length <= _assistantChunkMaxChars ||
        _jobChipLabel(content, Strings.of(context)) != null ||
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

  /// Bubble closest to the centre of the viewport: the text the reader is
  /// looking at, used to keep it in place across a transcript replacement.
  ({Map<String, dynamic> message, RenderBox anchor})?
  _readerViewportAnchorCandidate() {
    if (!_scrollController.hasClients || _isNearBottom) return null;
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
    if (selectedMessage == null || selectedAnchor == null) return null;
    return (message: selectedMessage, anchor: selectedAnchor);
  }

  void _beginMessageRefreshViewportAnchor(int refreshEpoch) {
    _cancelMessageRefreshViewportAnchor();
    final candidate = _readerViewportAnchorCandidate();
    if (candidate == null) return;
    final selectedMessage = candidate.message;
    final selectedAnchor = candidate.anchor;

    if (!_messages.any((message) => identical(message, selectedMessage))) {
      return;
    }

    RenderBox? lookup() {
      if (_messageRefreshAnchorEpoch != refreshEpoch) return null;
      final message = chatRefreshFindAnchorMessage(selectedMessage, _messages);
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

  /// A transcript replaced by the service outside a screen-owned read
  /// (resume reconciliation, another surface's finished turn, compaction)
  /// inserts rows below the reader in the reversed list. Without an anchor the
  /// numeric offset is kept and the text being read jumps up by the height of
  /// the new rows. Anchor the bubble being read for the next layout only.
  void _anchorReaderAcrossServiceHydration() {
    if (_chat.isStreaming || _streamingViewportLock.enabled) return;
    final candidate = _readerViewportAnchorCandidate();
    if (candidate == null) return;
    final selected = candidate.message;
    final serial = ++_hydrationAnchorSerial;
    RenderBox? lookup() {
      if (_hydrationAnchorSerial != serial) return null;
      final message = chatRefreshFindAnchorMessage(selected, _messages);
      return message == null ? null : _messageAnchors[message];
    }

    _streamingViewportLock.enable();
    if (!_streamingViewportLock.expectAnchorVisualChange(
      candidate.anchor,
      lookup,
    )) {
      _streamingViewportLock.disable();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _hydrationAnchorSerial != serial) return;
      _hydrationAnchorSerial++;
      // Another owner (a new turn, a refresh) may have taken the lock during
      // this frame; release it only if nothing else claimed it since.
      if (!_chat.isStreaming && _messageRefreshAnchorEpoch == null) {
        _streamingViewportLock.disable();
      }
    });
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
    // Neither the profile's gateway route nor the Dashboard serves this
    // transcript: polling stops until the user retries.
    if (passiveOnly && _chat.profileTranscriptAccessBlocked) {
      _showProfileTranscriptAccessError();
      return false;
    }
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
      // ss1215: whatever this load proved (or failed to prove), the
      // remembered status no longer stands in for it.
      if (!passiveOnly) _chat.settleProvisionalLiveStatus();
      if (_disposed || !mounted || refreshEpoch != _messageRefreshEpoch) {
        return false;
      }
      // Rows already on screen can survive a refused read: the error stays.
      if (_chat.profileTranscriptAccessBlocked) {
        _showProfileTranscriptAccessError();
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
      // Also after a reopen painted cached rows first: the marker is resolved
      // against the first loaded transcript, not against the cached preview.
      _resolveNewSinceYouLeft();
      return true;
    } catch (e) {
      if (!passiveOnly) _chat.settleProvisionalLiveStatus();
      if (_disposed || !mounted || refreshEpoch != _messageRefreshEpoch) {
        return false;
      }
      _cancelMessageRefreshViewportAnchor();
      if (e is ProfileTranscriptAccessRequired) {
        _showProfileTranscriptAccessError();
        return false;
      }
      if (passiveOnly) return false;
      final errStr = e.toString();
      if (errStr.contains('404') || errStr.contains('not found')) {
        final isUnpersistedMobileChat =
            widget.session.source == 'mobile' &&
            widget.session.messageCount == 0 &&
            _messages.isEmpty;
        // cs1215: rows painted from the cold-start cache are not evidence
        // that the session still exists.
        final onlyCachedRows = _chat.showingCachedTranscript;
        // Hermes Desktop drops a verifiably gone id (its transcript AND its
        // row 404) to a fresh draft instead of an error; a 404 on the
        // transcript alone keeps the stable error with retry.
        final storedSessionGone =
            !isUnpersistedMobileChat &&
            (_messages.isEmpty || onlyCachedRows) &&
            await _storedSessionIsGone();
        if (_disposed || !mounted || refreshEpoch != _messageRefreshEpoch) {
          return false;
        }
        if (storedSessionGone) {
          _chat.discardCachedTranscript();
          unawaited(
            _chatService.forgetColdStartSession(
              connectionId: widget.connection.id,
              profile: _chat.sessionProfile,
              sessionId: _chat.serverSessionId,
            ),
          );
          if (widget.restoredFromColdStart) {
            // The remembered chat was deleted elsewhere: back to Home, never
            // a draft that silently replaces it.
            HermesNotice.of(context).showSnackBar(
              SnackBar(content: Text(Strings.of(context).chaSessionGone)),
              kind: HermesNoticeKind.warning,
            );
            unawaited(Navigator.of(context).maybePop());
            return false;
          }
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
            _refreshErrorNoticeDismissed = false;
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
        _refreshErrorNoticeDismissed = false;
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

  /// One actionable error for a named profile whose transcript neither route
  /// serves; repeated failures never stack notices.
  void _showProfileTranscriptAccessError() {
    if (_disposed || !mounted) return;
    final marker = const ProfileTranscriptAccessRequired().toString();
    if (_error == marker) return;
    setState(() {
      _error = marker;
      _refreshErrorNoticeDismissed = false;
    });
  }

  /// Retry from the load error: a blocked profile gets one more Dashboard
  /// attempt; any other error simply reloads.
  Future<bool> _retryMessagesAfterError() {
    _chat.retryProfileTranscriptAccess();
    return _fetchMessages();
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
    // A compression in flight no longer refuses the send: `_sendMessageOnce`
    // routes it to the queue, which holds it until the compression ends.
    if (_composerSubmissionInFlight ||
        _attachmentSubmitting ||
        _attachmentMutationInFlight) {
      return false;
    }
    // Claim the in-flight slot BEFORE any await: two same-tick sends (double
    // tap) must never both pass the guard above and submit twice.
    _composerSubmissionInFlight = true;
    final claim = ++_composerSubmissionClaim;
    try {
      // Queuing behind a compression must never interrupt it.
      if (!_compressingSession) {
        await _recentInterrupt.interruptBeforeSend(_chat.cancel);
      }
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
      final ownsSlot = claim == _composerSubmissionClaim;
      if (mounted) {
        setState(() {
          if (ownsSlot) _composerSubmissionInFlight = false;
          if (submitsAttachment) _attachmentSubmitting = false;
        });
      } else {
        if (ownsSlot) _composerSubmissionInFlight = false;
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
    final cronRunAllowsSend = await _cronRunAllowsSend();
    if (!mounted) return false;
    if (!cronRunAllowsSend) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).au1215CronRunSendBlocked)),
        kind: HermesNoticeKind.warning,
      );
      return false;
    }
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
    // Commands cannot wait in the queue, and running one now could start a
    // second /compress over the one in flight. The text stays in the composer.
    if (!skipSlashRouting &&
        _compressingSession &&
        rawComposerText.startsWith('/')) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(str.cq1215CommandWaitsForCompaction)),
        kind: HermesNoticeKind.warning,
      );
      return false;
    }
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
        await _executeSlash(
          local.command,
          local.arg,
          fromComposerSubmission: true,
        );
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
        // A skill installed after the catalog was cached is still named by
        // complete.slash; the server owns it, as on Desktop.
        final controller = _textController;
        if (controller is _SlashAccentTextEditingController &&
            controller.remoteCommandNames.contains(invocation.name)) {
          await _executeSlash(
            SlashCommand.remote(name: invocation.name, description: ''),
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
    final waitsForCompression = _compressingSession;
    // Every queued composer turn is written to the encrypted outbox before the
    // composer is cleared. This preserves FIFO across process death and keeps a
    // rejected head visible for explicit retry instead of dropping it.
    if (_sending || waitsForExternalOwner || waitsForCompression) {
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
      if (!mounted) {
        // The route closed while the enqueue was in flight. The turn is now
        // durable in the queue, so its saved draft must not come back on
        // reopen as a second copy of the same prompt.
        if (usesComposerState) {
          await _clearQueuedDraftAfterLeaving(
            composerTextAtSubmit,
            attachments,
          );
        }
        return true;
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
          ..showSnackBar(
            SnackBar(
              content: Text(
                waitsForCompression && !_sending
                    ? str.cq1215QueuedUntilCompacted
                    : str.chaSteerQueued,
              ),
            ),
          );
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

    // La outbox ya es durable: desde aquí el borrador cifrado se atribuye a
    // este intento exacto. Si la pantalla muere antes del ACK, el ACK (o el
    // siguiente restore) lo retira por identidad sin depender del widget.
    if (textOverride == null &&
        _textController.text == composerTextAtSubmit &&
        _sameAttachmentDrafts(_pendingAttachments, attachments)) {
      _draftTimer?.cancel();
      unawaited(
        _saveDraftSnapshot(
          composerTextAtSubmit,
          attachments,
          submittedTurnClientTurnId: prepared.clientTurnId,
        ),
      );
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
      // Si el usuario escribió otro borrador mientras el turno estaba en vuelo,
      // ese borrador es suyo: ni se enlaza al intento fallido (vaciarlo no
      // debe descartar el turno) ni se sobrescribe con el lote fallido, que
      // sigue a salvo en la outbox cifrada.
      final composerHoldsOtherWork =
          mounted &&
          (_textController.text.isNotEmpty || _pendingAttachments.isNotEmpty) &&
          !(_textController.text == composerTextAtSubmit &&
              _sameAttachmentDrafts(_pendingAttachments, attachments));
      _composerPreparedTurnClientTurnId =
          !composerHoldsOtherWork &&
              delivery.current.state ==
                  PreparedTurnState.failedBeforeAcceptance &&
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
      if (usesComposerState && composerHoldsOtherWork) {
        _draftTimer?.cancel();
        await _saveDraftSnapshot(
          _textController.text,
          List<AttachmentDraft>.of(_pendingAttachments),
          preparedTurnAuthorityCaptured: true,
        );
      } else if (usesComposerState) {
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
    // Si la pantalla se cerró antes del ACK, `_clearDraft` no puede escribir.
    // El borrado condicionado solo retira el lote enlazado a este turno.
    await _clearSubmittedTurnDraft(prepared.clientTurnId);
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

  bool _providerReauthRunning = false;

  /// "Compactar conversación" on the card: the `/compress` the composer
  /// already runs. That flow takes over the composer text, so a draft the user
  /// was typing is put back afterwards.
  Future<void> _compressFromError() async {
    final draft = _textController.text;
    await _compressDesktopSession('');
    if (draft.isNotEmpty && mounted) _restoreSlashInvocation(draft);
  }

  /// "Editar mensaje" on the card: opens the edit of the message the failed
  /// turn answered, or null when it cannot be edited.
  VoidCallback? _editMessageOfError(Map<String, dynamic> error) {
    var foundError = false;
    Map<String, dynamic>? target;
    for (final message in _messages) {
      if (identical(message, error)) {
        foundError = true;
        continue;
      }
      if (foundError && isRealUserTurn(message)) {
        target = message;
        break;
      }
    }
    // The card may hold a projected copy of its row: the newest user turn is
    // then the one the failure answered.
    if (!foundError) {
      for (final message in _messages) {
        if (isRealUserTurn(message)) {
          target = message;
          break;
        }
      }
    }
    final user = target;
    if (user == null || !_canEditUserMessage(user)) return null;
    return () {
      if (!mounted) return;
      _editUserMessage(user, MediaQuery.sizeOf(context).width * 0.85);
    };
  }

  /// Billing action: Nous opens the existing Models/account screen; another
  /// provider opens its `https` billing page in the system browser.
  VoidCallback? _openBillingAction(TurnBillingBlock? billing) {
    if (billing == null) return null;
    if (billing.isNous) {
      return () => _pushScreen(ModelsScreen(connection: widget.connection));
    }
    final url = billing.billingUrl;
    if (url == null) return null;
    return () => unawaited(
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    );
  }

  /// Free-tier sign-in is only offered when the Accounts catalog of this
  /// chat's profile lists `nous`, so it never opens a dead flow.
  Future<bool> _freeTierSignInAvailable() async {
    final client = (widget.providerReauthClientFactory ?? DashboardClient.lazy)(
      widget.connection,
    );
    final rows = await client.getOAuthProviders(
      profile: Session.profileOwner(_chat.sessionProfile),
    );
    return rows.any((row) => row['id'] == 'nous');
  }

  void _signInFreeTier() => unawaited(
    _reauthProvider(
      const ProviderAuthFailure(
        provider: 'nous',
        label: 'Nous',
        kind: ProviderAuthKind.oauth,
      ),
    ),
  );

  /// "Volver a iniciar sesión" / "Revisar la clave" on a provider credential
  /// failure. After a successful sign-in the turn can be retried in place.
  Future<void> _reauthProvider(
    ProviderAuthFailure failure, {
    VoidCallback? onRetry,
  }) async {
    if (_providerReauthRunning) return;
    setState(() => _providerReauthRunning = true);
    // Identidad del fallo que se ofrece reintentar. El flujo de inicio de
    // sesión y el aviso posterior duran minutos: si entretanto el turno se
    // reconcilia, se reintenta o falla otro, ese Retry ya no le corresponde.
    final retryChat = _chat;
    final failedTurn = onRetry == null
        ? null
        : retryChat.currentFailedTurnToken;
    var renewed = false;
    try {
      renewed = await runProviderReauth(
        context: context,
        connection: widget.connection,
        failure: failure,
        profile: Session.profileOwner(_chat.sessionProfile),
        clientFactory: widget.providerReauthClientFactory,
      );
    } finally {
      if (mounted) setState(() => _providerReauthRunning = false);
    }
    if (!renewed || !mounted) return;
    if (failure.origin == ProviderAuthOrigin.compaction) {
      _chat.dismissCompactionAuthFailure();
    }
    final s = Strings.of(context);
    final label = failure.label.isEmpty ? failure.provider : failure.label;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(s.hr1215SignedInAgain(label)),
        duration: const Duration(seconds: 10),
        action: onRetry == null || failedTurn == null
            ? null
            : SnackBarAction(
                label: s.chaRetry,
                onPressed: () {
                  if (!mounted ||
                      !identical(_chat, retryChat) ||
                      !_isSameFailedTurn(
                        retryChat.currentFailedTurnToken,
                        failedTurn,
                      )) {
                    return;
                  }
                  onRetry();
                },
              ),
      ),
      kind: HermesNoticeKind.success,
    );
  }

  static bool _isSameFailedTurn(Object? current, Object captured) =>
      current is String ? current == captured : identical(current, captured);

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
    // Reintentar reenvía el composer. Si el usuario ya escribió OTRO borrador,
    // reintentar mandaría ese borrador en lugar del turno fallido y lo
    // retiraría del editor. Se conserva intacto y no se reintenta nada.
    // «Otro» se decide con el lote completo (texto y adjuntos): el mismo texto
    // con adjuntos distintos también es otro borrador.
    final retryTarget = _preparedTurn;
    final composerText = _textController.text.trim();
    final composerIsRetryBatch =
        retryTarget != null && retryTarget.restoresComposer
        ? !_composerHoldsOtherDraft(retryTarget)
        : composerText == prompt.trim() && _pendingAttachments.isEmpty;
    if ((composerText.isNotEmpty || _pendingAttachments.isNotEmpty) &&
        !composerIsRetryBatch) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaRetryKeepsDraft)),
        kind: HermesNoticeKind.warning,
      );
      return;
    }
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
        // Queued by the gateway behind the live reply: it has no durable row
        // yet, so a rewrite of it could only fail.
        message['_desktopAcceptedQueued'] == true ||
        ordinal == null ||
        parsed.text.trim().isEmpty ||
        !_attachmentsCanBeReused(parsed.attachments)) {
      return false;
    }
    return true;
  }

  /// Filas más antiguas (más antigua primero) que comparten burbuja con
  /// [msg] en el mismo turno, o vacío si [msg] no ancla un grupo de respuesta.
  List<Map<String, dynamic>> _olderResponseGroupRows(
    Map<String, dynamic> msg, {
    bool liveHead = false,
  }) {
    final projection = _currentRenderProjection;
    // A live frame may still carry the map of a previous flush; while the turn
    // streams it always stands for the head row.
    final index = projection.messageIndexOf(msg) ?? (liveHead ? 0 : null);
    if (index == null) return const [];
    final members = projection.responseGroupMembers(index);
    if (members == null) return const [];
    final messages = _messages;
    return [for (var i = members.length - 1; i > 0; i--) messages[members[i]]];
  }

  /// Metadatos de la burbuja única de un turno (Desktop `ResponseMessages`):
  /// traza, texto y medios de todas las filas del grupo, más antiguas primero.
  /// [head] sustituye a la fila más nueva (p. ej. el frame vivo recortado).
  Map<String, dynamic> _responseGroupMetadata(
    Map<String, dynamic> msg, {
    Map<String, dynamic>? head,
  }) {
    final older = _olderResponseGroupRows(msg, liveHead: head != null);
    if (older.isEmpty) return head ?? msg;
    final newest = head ?? msg;
    // La copia fusionada se reutiliza mientras las filas de origen no cambien:
    // su identidad alimenta la selección de texto y no debe variar por frame.
    final cached = _responseGroupCache[msg];
    if (cached != null &&
        identical(cached.head, newest) &&
        cached.sources.length == older.length &&
        Iterable<int>.generate(
          older.length,
        ).every((i) => identical(cached.sources[i], older[i]))) {
      return cached.merged;
    }
    final merged = mergeAssistantResponseGroup([...older, newest]);
    if (_responseGroupCache.length > 64) _responseGroupCache.clear();
    _responseGroupCache[msg] = (sources: older, head: newest, merged: merged);
    return merged;
  }

  final Map<
    Map<String, dynamic>,
    ({
      List<Map<String, dynamic>> sources,
      Map<String, dynamic> head,
      Map<String, dynamic> merged,
    })
  >
  _responseGroupCache = Map.identity();

  /// Texto visible de las filas anteriores del grupo, en orden.
  static String _responseGroupTextPrefix(List<Map<String, dynamic>> older) => [
    for (final row in older)
      if (row['content'] is String &&
          (row['content'] as String).trim().isNotEmpty)
        row['content'] as String,
  ].join('\n\n');

  static String _joinResponseGroupText(String prefix, String content) =>
      prefix.isEmpty
      ? content
      : content.trim().isEmpty
      ? prefix
      : '$prefix\n\n$content';

  /// pt1215: durable tool outputs (diffs, terminal output) by tool id, built
  /// lazily from the internal transcript and reused while it is unchanged.
  Map<String, ToolOutputRecord> _durableToolOutputs = const {};
  Object? _durableToolOutputsSource;

  ToolOutputRecord? _toolOutputFor(String toolId) {
    final live = _chat.toolOutputs[toolId];
    if (live != null) return live;
    // While a turn streams the transcript changes every flush; the live
    // ledger covers the running turn and history keeps its last index.
    if (!_chat.isStreaming) {
      final source = _messages;
      if (!identical(source, _durableToolOutputsSource)) {
        _durableToolOutputsSource = source;
        _durableToolOutputs = indexDurableToolOutputs(
          _chat.contentHistoryTranscript,
          toolResultsKey: assistantToolResultEvidenceKey,
        );
      }
    }
    return _durableToolOutputs[toolId];
  }

  /// While a sent message is being edited the composer and the queue strip
  /// ignore touches and screen readers (the existing dim stays).
  Widget _lockWhileEditing(Widget child) => IgnorePointer(
    ignoring: _editingUserMessage,
    child: ExcludeSemantics(excluding: _editingUserMessage, child: child),
  );

  /// How many user turns come after [ordinal]: editing there removes them.
  int _laterTurnsAfter(int? ordinal) {
    if (ordinal == null) return 0;
    final latest = _currentRenderProjection.latestUserMessage;
    final latestOrdinal = latest == null
        ? null
        : _currentRenderProjection.userOrdinalFor(latest);
    if (latestOrdinal == null || latestOrdinal <= ordinal) return 0;
    return latestOrdinal - ordinal;
  }

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

  /// A failed save leaves the editor open with the rewritten text, ready to
  /// retry or cancel, instead of closing it and losing what the user typed.
  void _keepFailedEditOpen(String edited) {
    if (_editingUserMessageTarget == null) {
      _clearUserMessageEditingState();
      _restoreFailedEditToComposer(edited);
      return;
    }
    _editingUserMessageDraft = edited;
    _editingRewriteSubmitted = false;
  }

  /// The editor already closed when the rewrite started, so a late rejection
  /// has no editor to go back to: hand the text to an empty composer instead
  /// of dropping it. A composer the user is already typing in is not touched.
  void _restoreFailedEditToComposer(String edited) {
    if (_textController.text.trim().isNotEmpty) return;
    _textController.value = TextEditingValue(
      text: edited,
      selection: TextSelection.collapsed(offset: edited.length),
    );
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
    // Saving while a reply streams interrupts that reply: ask first, and keep
    // the editor open if the user backs out.
    if (_chat.isStreaming) {
      final str = Strings.of(context);
      final confirmed = await showHermesConfirmDialog(
        context: context,
        title: str.tc1215EditStopsReplyTitle,
        message: str.tc1215EditStopsReplyBody,
        confirmLabel: str.tc1215EditStopsReplyConfirm,
        cancelLabel: str.commonCancel,
        destructive: true,
      );
      if (!confirmed || !mounted || _editingRewriteSubmitted) return;
    }
    setState(() => _editingRewriteSubmitted = true);

    final nativeAttachments = parsed.attachments.isEmpty
        ? const <AttachmentDraft>[]
        : await _resolveAttachmentsForEdit(parsed.attachments);
    if (!mounted) return;
    if (nativeAttachments == null) {
      setState(() => _keepFailedEditOpen(edited));
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
      if (failed) {
        _keepFailedEditOpen(edited);
      } else if (_editingMessagesSnapshot == null) {
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
    // The editor holds the row so the drain cannot send the old text while it
    // is open. If the drain already took the row there is nothing to edit.
    if (entry.sending || !_chat.holdQueuedTurn(entry.id)) {
      _showQueueActionFailed(Strings.of(context).chaQueueEditFailed);
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
    var saved = true;
    if (mounted &&
        edited != null &&
        edited.trim().isNotEmpty &&
        edited.trim() != entry.text) {
      saved = await _chat.editQueuedTurn(entry.id, edited);
    }
    _chat.releaseQueuedTurn(entry.id);
    if (!mounted) return;
    setState(() => _editingQueuedEntryId = null);
    if (!saved) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaQueueEditFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<void> _sendQueuedEntryNow(QueuedEntryView entry) async {
    final strings = Strings.of(context);
    // Sending now while a reply streams stops that reply: say so first.
    if (_chat.isStreaming) {
      final confirmed = await showHermesConfirmDialog(
        context: context,
        title: strings.tc1215QueueStopAndSendTitle,
        message: strings.tc1215QueueStopAndSendBody,
        confirmLabel: strings.tc1215EditStopsReplyConfirm,
        cancelLabel: strings.commonCancel,
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    if (await _chat.sendQueuedNow(entry.id) || !mounted) return;
    _showQueueActionFailed(
      entry.missingAttachment
          ? strings.q1215QueueMissingAttachment
          : strings.chaQueueSendNowFailed,
    );
  }

  Future<void> _moveQueuedEntry(String id, {required bool up}) async {
    if (await _chat.moveQueuedTurn(id, up: up) || !mounted) return;
    _showQueueActionFailed(Strings.of(context).tc1215QueueMoveFailed);
  }

  Future<void> _deleteQueuedEntry(String id) async {
    if (await _chat.cancelQueuedByIdentity(id) || !mounted) return;
    _showQueueActionFailed(Strings.of(context).chaQueueDeleteFailed);
  }

  void _showQueueActionFailed(String message) {
    HermesNotice.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message)),
        kind: HermesNoticeKind.error,
      );
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
  Future<void> _executeSlash(
    SlashCommand cmd,
    String arg, {
    bool fromComposerSubmission = false,
  }) async {
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
      final consumed = await _compressDesktopSession(
        arg,
        fromComposerSubmission: fromComposerSubmission,
      );
      if (!mounted || !consumed) return;
      _consumeSlashInvocation(invocation);
      return;
    }
    if (cmd.action == SlashAction.btw || cmd.action == SlashAction.background) {
      final invocation = _textController.text;
      final consumed = await _runSideSlash(cmd, arg);
      if (!mounted || !consumed) return;
      _consumeSlashInvocation(invocation);
      return;
    }
    if (cmd.action == SlashAction.branch) {
      final invocation = _textController.text;
      final opened = await _branchChat();
      if (!mounted || !opened) return;
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
        final connManager = context
            .findAncestorStateOfType<HermesAppState>()!
            .connManager;
        _pushScreen(
          buildCapabilitiesHub(
            connection: widget.connection,
            connManager: connManager,
            capabilities: connManager.loadCapabilities(widget.connection.id),
          ),
        );
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
      case SlashAction.find:
        _openFind(initialQuery: arg);
      case SlashAction.unavailable:
        return;
      case SlashAction.btw:
      case SlashAction.background:
      case SlashAction.branch:
      case SlashAction.remote:
        // Se manejan antes de limpiar el compositor para conservarlo si fallan.
        return;
    }
  }

  /// `/btw` and `/bg`: one direct request, allowed while a reply streams and
  /// never queued. Returns whether the composer text was consumed; the generic
  /// slash path takes over (and clears it itself) when the server lacks the
  /// method.
  Future<bool> _runSideSlash(SlashCommand cmd, String arg) async {
    final str = Strings.of(context);
    final isBtw = cmd.action == SlashAction.btw;
    if (arg.trim().isEmpty) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(isBtw ? str.tc1215BtwUsage : str.tc1215BgUsage)),
        kind: HermesNoticeKind.warning,
      );
      return false;
    }
    final outcome = isBtw
        ? await _chat.askSideQuestion(arg)
        : await _chat.startBackgroundPrompt(arg);
    if (!mounted) return false;
    switch (outcome) {
      case SideCommandOutcome.started:
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(isBtw ? str.tc1215BtwStarted : str.tc1215BgStarted),
          ),
          kind: HermesNoticeKind.success,
        );
        return true;
      case SideCommandOutcome.unsupported:
        await _executeRemoteSlash(
          SlashCommand.remote(name: cmd.name, description: ''),
          arg,
        );
        return false;
      case SideCommandOutcome.readOnly:
        showReadOnlyNotice(context);
        return false;
      case SideCommandOutcome.usage:
      case SideCommandOutcome.failed:
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(str.tc1215SideFailed)),
          kind: HermesNoticeKind.error,
        );
        return false;
    }
  }

  /// Branches the live chat (up to [fromMessage], or the whole chat) and opens
  /// the child on top of this one; the parent stays open and untouched.
  /// Returns whether the child opened.
  Future<bool> _branchChat({Map<String, dynamic>? fromMessage}) async {
    final outcome = await _chat.branchChat(fromMessage: fromMessage);
    if (!mounted) return false;
    final str = Strings.of(context);
    if (outcome.opened) {
      final childId = outcome.storedSessionId;
      if (childId == null || childId.isEmpty) return false;
      final child = Session(
        id: childId,
        title: outcome.title ?? '',
        model: '',
        source: 'mobile',
        messageCount: outcome.messageCount,
        isActive: true,
        preview: '',
        startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
        parentSessionId: _chat.sessionId,
        profile: _effectiveSessionProfile,
      );
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                ChatScreen(connection: widget.connection, session: child),
          ),
        ),
      );
      return true;
    }
    final message = switch (outcome.status) {
      BranchStatus.busy => str.tc1215BranchStopFirst,
      BranchStatus.noRuntime => str.tc1215BranchNoRuntime,
      BranchStatus.nothingToBranch => str.tc1215BranchNothing,
      BranchStatus.targetNotFound => str.tc1215BranchTargetMissing,
      BranchStatus.readOnly => str.readOnlyNotice,
      BranchStatus.unsupported || BranchStatus.failed => str.tc1215BranchFailed,
      // A second tap while one branch is pending does nothing.
      BranchStatus.inFlight || BranchStatus.opened => null,
    };
    if (message != null) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(message)),
        kind:
            outcome.status == BranchStatus.busy ||
                outcome.status == BranchStatus.nothingToBranch
            ? HermesNoticeKind.warning
            : HermesNoticeKind.error,
      );
    }
    return false;
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

  Future<bool> _compressDesktopSession(
    String focusTopic, {
    bool fromComposerSubmission = false,
  }) async {
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
      _slashSuggestions = const [];
      _textController.clear();
      // From here `_compressingSession` fences the composer: what the user
      // types next is queued behind the compression, so the submit slot that
      // carried this `/compress` is released now instead of minutes later.
      // Only that slot: a palette pick never owns someone else's send.
      if (fromComposerSubmission) {
        _composerSubmissionInFlight = false;
        _composerSubmissionClaim++;
      }
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
        // El composer ya es editable durante la compactación (lo escrito va a
        // la cola); la única pregunta es si el texto se restaura. Para eso,
        // `compressionStatus` es la
        // señal fiable en la ruta nativa (`pending` es lo único genuinamente
        // incierto; aborted/lock_held son un rechazo real). La ruta legacy
        // nunca la toca — ahí `accepted` es la señal: unknown == genuinamente
        // pendiente/incierto (pending, o un fallo de transporte donde no se
        // sabe si el backend llegó a aceptarlo), rejected == rechazo
        // definitivo, igual que un mensaje normal rechazado.
        final fenced = result.compressionStatus != null
            ? result.compressionStatus == DesktopCompressionStatus.pending
            : result.accepted != DesktopCommandAcceptance.rejected;
        _restoreComposerFocusAfterCompression();
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

  void _restoreComposerFocusAfterCompression() {
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
      // Without a live runtime the lookup falls back to the other catalogs and
      // _applyModelDirect stages or refuses exactly like the model sheet does.
      if (!_chat.hasDesktopRuntime) {
        await _chat.ensureDesktopRuntime(acquireForExplicitAction: true);
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
      await _applySelectedModelPreset(provider.slug, modelId);
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
              content: Text(
                confirmation.confirmMessage ?? str.chaModelChangeConfirmBody,
              ),
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

    final deferred = result.deferred;
    if (mounted) setState(() => _deferredModelId = deferred ? modelId : null);
    await _rememberSessionModel(
      provider.slug,
      modelId,
      updateEffectiveDisplay: false,
    );
    await _applySelectedModelPreset(provider.slug, modelId);
    if (mounted) {
      final name = friendlyModelName(modelId);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deferred
                ? str.md1215ModelNextMessage(name)
                : str.chaModelActive(name),
          ),
        ),
      );
    }
    return true;
  }

  Future<void> _applySessionReasoning(
    DesktopReasoningEffort effort, {
    bool acquireRuntime = true,
    bool rememberPreset = true,
  }) async {
    final str = Strings.of(context);
    if (!_chat.hasDesktopRuntime && acquireRuntime) {
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
      if (rememberPreset) {
        await _rememberCurrentModelPreset(effort: effort);
      }
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
    if (rememberPreset) {
      await _rememberCurrentModelPreset(effort: effort);
    }
  }

  Future<void> _applySessionFastMode(
    DesktopFastMode mode, {
    bool acquireRuntime = true,
    bool rememberPreset = true,
  }) async {
    final str = Strings.of(context);
    if (!_chat.hasDesktopRuntime && acquireRuntime) {
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
      if (rememberPreset) {
        await _rememberCurrentModelPreset(fast: mode);
      }
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
    if (rememberPreset) {
      await _rememberCurrentModelPreset(fast: mode);
    }
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
          for (final c in slashCommands(
            Strings.of(context),
            sideAgents: _chat.canRunSideAgents,
            branch: _chat.canBranchChat,
          ))
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

  Future<void> _openTerminal() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TerminalPaneScreen(
          connection: widget.connection,
          profile: Session.profileOwner(widget.session.profile),
          chat: _chat,
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

    final terminalGateway = _chat.terminalGateway;
    if (terminalGateway != null && _chat.desktopRuntimeSessionId != null) {
      unawaited(
        TerminalAvailability.confirm(
          widget.connection,
          terminalGateway,
          profile: Session.profileOwner(widget.session.profile),
        ),
      );
    }

    final action = await showHermesFloatingSurface<_ChatControlAction>(
      context: context,
      surfaceKey: const ValueKey('chat-control-dialog'),
      maxWidth: 480,
      builder: (dialogContext) {
        void select(_ChatControlAction action) =>
            Navigator.of(dialogContext).pop(action);

        // The Terminal row appears once the server has confirmed shell.exec.
        return ValueListenableBuilder<int>(
          valueListenable: TerminalAvailability.changes,
          builder: (context, _, _) => ChatControlSheet(
          labels: ChatControlLabels(
            title: strings.chaControlTitle,
            scope: strings.chaControlScope,
            sessionSection: strings.chaControlSectionSession,
            toolsSection: strings.chaControlSectionTools,
            dangerSection: strings.chaControlSectionDanger,
            permissions: strings.chaPermissionsTitle,
            refresh: strings.chaUpdateTitle,
            artifacts: strings.chaArtifactsAction,
            content: strings.sa1215ContentAction,
            prompts: strings.pj1215PromptsAction,
            branch: strings.tc1215BranchChat,
            details: strings.chaSessionDetailsAction,
            cron: strings.crnOpenFromConversation,
            recovery: strings.chaControlRecovery,
            extensions: strings.drawerExtensions,
            terminal: strings.termTitle,
            delete: strings.sesDelete,
            readOnly: strings.statusReadOnly,
            releaseDesktop: strings.chaControlReleaseDesktop,
            releaseUnavailable: strings.chaRuntimeReleaseUnavailable,
          ),
          conversationTitle: localizedSessionTitle(strings, widget.session),
          readOnly: sessionReadOnly,
          showReleaseDesktop: _chat.showReleaseToDesktopControl,
          releaseDesktopEnabled: _chat.canReleaseToDesktop,
          releaseInFlight: _chat.runtimeReleaseInFlight,
          showDetails: _devDiagnostics,
          showCron: widget.session.isJob,
          onPermissions: () => select(_ChatControlAction.permissions),
          onRefresh: () => select(_ChatControlAction.refresh),
          onArtifacts: () => select(_ChatControlAction.artifacts),
          onContent: () => select(_ChatControlAction.content),
          onPrompts: () => select(_ChatControlAction.prompts),
          onBranch: _chat.canBranchChat
              ? () => select(_ChatControlAction.branch)
              : null,
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
          onTerminal:
              _chat.desktopRuntimeSessionId == null ||
                  _chat.terminalGateway == null ||
                  !TerminalAvailability.offered(widget.connection)
              ? null
              : () => select(_ChatControlAction.terminal),
          onReleaseDesktop: () => select(_ChatControlAction.releaseDesktop),
          onDelete: () => select(_ChatControlAction.delete),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ChatControlAction.permissions:
        if (policy != null) _showModeSheet(policy);
      case _ChatControlAction.refresh:
        unawaited(_fetchMessages());
      case _ChatControlAction.prompts:
        unawaited(_showPromptSheet());
      case _ChatControlAction.content:
        unawaited(_openChatContent());
      case _ChatControlAction.branch:
        unawaited(_branchChat());
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
      case _ChatControlAction.terminal:
        unawaited(_openTerminal());
      case _ChatControlAction.releaseDesktop:
        unawaited(_releaseRuntimeForDesktop());
      case _ChatControlAction.delete:
        unawaited(_deleteCurrentChat());
    }
  }

  /// Epoch of the open prompt list: a read that answers after the sheet was
  /// closed (or the screen left) is dropped.
  int _promptSheetEpoch = 0;

  /// Rows the "Prompts" backfill may load to reach an unloaded prompt, the
  /// same bound as the new-since-you-left lookback.
  static const int _promptBackfillRows = 500;

  /// Pages of the Dashboard index one open of the list may read.
  static const int _promptIndexMaxPages = 3;

  /// Lists the chat's prompts and reveals the chosen one. The loaded ones are
  /// derived once per open; when older history exists, the Dashboard prompt
  /// index adds the unloaded ones (one read on open, more only on request).
  Future<void> _showPromptSheet() async {
    final strings = Strings.of(context);
    final epoch = ++_promptSheetEpoch;
    final entries = deriveChatPromptEntries(
      _messages,
      isSystemRow: _isSystemChipRow,
    );
    final tops = <double?>[
      for (final entry in entries)
        _ChatStreamingViewportLock._visualOffsetInViewport(
          _messageAnchors[entry.message],
        ),
    ];
    final active = activeChatPromptIndex(tops);
    final oldestLoaded = _messages.isEmpty
        ? null
        : chatPromptRowId(_messages.last);
    final remote = <({int rowId, String preview})>[];
    var items = mergeChatPromptItems(
      entries,
      remote,
      oldestLoadedRowId: oldestLoaded,
    );
    var hasMore = false;
    var loading = _chat.hasEarlierMessages;
    var pages = 0;
    int? cursor;
    bool open() => mounted && epoch == _promptSheetEpoch;

    ChatPromptSheetModel snapshot() => ChatPromptSheetModel(
      previews: [for (final item in items) item.preview],
      activeIndex: active,
      hasMore: hasMore,
      loading: loading,
    );

    final model = ValueNotifier<ChatPromptSheetModel>(snapshot());

    // One client for the whole sheet, closed with it; one read at a time.
    DashboardClient? indexClient;
    var reading = false;

    Future<void> readIndexPage() async {
      if (reading) return;
      reading = true;
      loading = true;
      model.value = snapshot();
      try {
        final client = indexClient ??=
            widget.promptTimelineClientFactory?.call(widget.connection) ??
            DashboardClient.lazy(widget.connection);
        final page = await client.getSessionTimelinePage(
          _chat.storedSessionId ?? widget.session.id,
          profile: ProfileReadTicket.fixed(widget.session.profile ?? '').name,
          afterRowId: cursor,
        );
        if (!open()) return;
        if (page == null) {
          hasMore = false;
        } else {
          remote.addAll([
            for (final entry in page.entries)
              (rowId: entry.rowId, preview: entry.preview),
          ]);
          pages += 1;
          cursor = page.nextCursor;
          hasMore = page.hasMore && pages < _promptIndexMaxPages;
        }
      } on Object {
        // An optional read: the loaded prompts stay usable.
        if (!open()) return;
        hasMore = false;
      }
      reading = false;
      loading = false;
      items = mergeChatPromptItems(
        entries,
        remote,
        oldestLoadedRowId: oldestLoaded,
      );
      model.value = snapshot();
    }

    if (loading) unawaited(readIndexPage());
    final picked = await showHermesFloatingSurface<int>(
      context: context,
      surfaceKey: const ValueKey('chat-prompt-dialog'),
      maxWidth: 480,
      builder: (dialogContext) => ChatPromptSheet(
        title: strings.pj1215PromptsAction,
        emptyLabel: strings.pj1215PromptsEmpty,
        moreLabel: strings.chaLoadEarlierMessages,
        model: model,
        onSelect: (index) => Navigator.of(dialogContext).pop(index),
        onMore: () {
          if (!loading) unawaited(readIndexPage());
        },
      ),
    );
    if (epoch == _promptSheetEpoch) _promptSheetEpoch++;
    indexClient?.close();
    if (!mounted || picked == null || picked >= items.length) return;
    final item = items[picked];
    var target = item.message;
    if (target == null) {
      final rowId = item.rowId;
      target = rowId == null ? null : await _loadPromptByRowId(rowId);
      if (!mounted) return;
      if (target == null) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).sa1215LoadOlderFailed)),
          kind: HermesNoticeKind.warning,
        );
        return;
      }
    }
    final live = chatRefreshFindAnchorMessage(target, _messages) ?? target;
    _freezeStreamingFollow();
    final revealed = await _revealTranscriptMessage(live);
    if (revealed == false && mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).artifactSourceUnavailable)),
        kind: HermesNoticeKind.warning,
      );
    }
  }

  /// Loads earlier pages, contiguously and within [_promptBackfillRows], until
  /// the row with the durable [rowId] is part of the transcript. Null when it
  /// was not reached: the reader stays where they were.
  Future<Map<String, dynamic>?> _loadPromptByRowId(int rowId) async {
    Map<String, dynamic>? find() {
      for (final message in _messages) {
        if (chatPromptRowId(message) == rowId) return message;
      }
      return null;
    }

    final startLength = _messages.length;
    while (mounted) {
      final found = find();
      if (found != null) return found;
      if (!_chat.hasEarlierMessages ||
          _messages.length - startLength >= _promptBackfillRows) {
        return null;
      }
      final before = _messages.length;
      await _loadEarlierMessages();
      if (_messages.length <= before) return find();
    }
    return null;
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

  /// sa1215: per-chat «Archivos y enlaces» (Desktop Artifacts view scoped to
  /// this conversation). Reads the loaded transcript; older pages load only
  /// on the screen's explicit action.
  Future<void> _openChatContent() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChatContentScreen(
          transcript: () => _chat.contentHistoryTranscript,
          hasOlder: () => _chat.hasEarlierMessages,
          loadOlder: () =>
              _chat.loadEarlierMessages(continuePastInvisible: true),
          onOpenFile: _openChatContentFile,
          launchExternal: (uri) =>
              launchUrl(uri, mode: LaunchMode.externalApplication),
        ),
      ),
    );
  }

  Future<void> _openChatContentFile(ChatContentItem item) async {
    final navigator = Navigator.of(context);
    final value = item.value;
    if (value.startsWith('data:')) {
      final data = Uri.tryParse(value)?.data;
      if (data == null || item.kind != ChatContentKind.image) {
        throw const ChatContentUnreachable();
      }
      await navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(
            imageUrl: item.label,
            imageBytes: data.contentAsBytes(),
          ),
        ),
      );
      return;
    }
    final reference = GeneratedMediaService.referenceFromSource(value);
    if (reference == null) throw const ChatContentUnreachable();
    final file = reference.sourceKind == GeneratedMediaSourceKind.https
        ? await downloadGeneratedMedia(reference)
        : await downloadUserServerAttachment(reference);
    if (!mounted) return;
    if (reference.kind == GeneratedMediaKind.image &&
        !reference.displayName.toLowerCase().endsWith('.svg')) {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await navigator.push<void>(
        MaterialPageRoute(
          builder: (_) =>
              ImageViewerScreen(imageUrl: file.path, imageBytes: bytes),
        ),
      );
      return;
    }
    final length = await file.length();
    if (!mounted) return;
    await openArtifactViewer(
      context,
      name: reference.displayName,
      mimeType: reference.mimeType,
      file: file,
      sizeBytes: length,
      onOpenExternal: () => unawaited(
        openGeneratedMediaExternally(
          file,
          mimeType: reference.mimeType,
          expectedSize: length,
        ).catchError((Object _) {}),
      ),
      onShare: () => unawaited(shareMediaFile(file).catchError((Object _) {})),
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
    final revealed = await _revealTranscriptMessage(target);
    if (revealed == false && mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).artifactSourceUnavailable)),
        kind: HermesNoticeKind.warning,
      );
    }
  }

  /// Desplaza el historial hasta que [target] quede alineado arriba. Devuelve
  /// true si lo alcanzó, false si recorrió todo sin materializarlo y null si la
  /// pantalla o el scroll desaparecieron a mitad del recorrido.
  /// [stillWanted] permite a un llamador abandonar el recorrido cuando otro
  /// posterior (p. ej. el siguiente resultado de búsqueda) lo sustituye.
  Future<bool?> _revealTranscriptMessage(
    Map<String, dynamic> target, {
    bool Function()? stillWanted,
  }) async {
    bool live() =>
        mounted &&
        _scrollController.hasClients &&
        (stillWanted == null || stillWanted());
    if (!live()) return null;
    final reached = await _materializeTranscriptAnchor(
      target,
      stillWanted: stillWanted,
    );
    if (reached != true) return reached;
    final anchor = _messageAnchors[target];
    if (anchor == null || !anchor.attached || !live()) return null;
    await scrollChatAnswerToStart(
      anchor,
      _scrollController.position,
      duration: _reduceMotion ? Duration.zero : chatNavigationDuration,
    );
    return true;
  }

  /// Walks the lazy reversed history from the bottom up until [target] has a
  /// laid-out anchor. True when it is attached (possibly without moving),
  /// false after reaching the top without building it, null when the screen
  /// or scroll went away or [stillWanted] withdrew the walk.
  Future<bool?> _materializeTranscriptAnchor(
    Map<String, dynamic> target, {
    bool Function()? stillWanted,
    int maxFrames = 80,
    double Function(ScrollPosition position)? stepExtent,
  }) async {
    bool live() =>
        mounted &&
        _scrollController.hasClients &&
        (stillWanted == null || stillWanted());
    bool attached() => _messageAnchors[target]?.attached ?? false;
    if (!live()) return null;
    if (attached()) return true;
    // Read the position after every frame: entering the chat can still swap
    // the list's scrollable (loading state → transcript), which disposes the
    // position a caller captured before the walk.
    var position = _scrollController.position;
    position.jumpTo(position.minScrollExtent);
    await SchedulerBinding.instance.endOfFrame;
    if (!live()) return null;
    if (attached()) return true;

    for (var attempt = 0; attempt < maxFrames; attempt++) {
      if (!live()) return null;
      position = _scrollController.position;
      if (position.pixels >= position.maxScrollExtent - 1) break;
      final step =
          stepExtent?.call(position) ?? position.viewportDimension * 0.9;
      position.jumpTo(
        (position.pixels + step).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await SchedulerBinding.instance.endOfFrame;
      if (!live()) return null;
      if (attached()) return true;
    }
    return false;
  }

  void _openFind({String initialQuery = ''}) {
    if (_findOpen) {
      if (initialQuery.trim().isNotEmpty) _applyFindQuery(initialQuery);
      return;
    }
    // Suspende el seguimiento del fondo con la misma ruta que un lector que
    // pausa el stream con el dedo; en reposo basta con desactivar la bandera.
    _freezeStreamingFollow();
    setState(() {
      _findOpen = true;
      _findInitialQuery = initialQuery.trim();
      _autoFollowStreaming = false;
    });
    if (_findInitialQuery.isNotEmpty) _applyFindQuery(_findInitialQuery);
  }

  void _closeFind() {
    if (!_findOpen) return;
    _findEpoch++;
    _findQuery = '';
    _findMatches = const [];
    _findMatchMessages = const [];
    _findIndex.clear();
    _findStatus.value = const ChatFindStatus();
    _findActiveMessage.value = null;
    setState(() => _findOpen = false);
    // Restaura el comportamiento normal: quien está en el fondo vuelve a
    // seguirlo; quien quedó leyendo arriba conserva su vista y la flecha.
    if (!_isNearBottom) {
      _showScrollToBottom = true;
      return;
    }
    if (_chat.isStreaming) {
      _streamingViewportLock.disable();
      _autoFollowStreaming = true;
      _revealedChars = _chat.assistantContent.length;
      _showScrollToBottom = false;
      _publishLiveAssistantFrame();
      _scheduleLiveFollowFrame();
    } else if (_liveAssistantMaterialized) {
      _scheduleTerminalLiveHostRelease();
    } else {
      _autoFollowStreaming = true;
    }
  }

  bool _findRefreshScheduled = false;

  void _scheduleFindRefresh() {
    if (_findRefreshScheduled) return;
    _findRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findRefreshScheduled = false;
      if (_disposed || !mounted || !_findOpen) return;
      _recomputeFindMatches(keepCurrent: true);
    });
  }

  void _recomputeFindMatches({required bool keepCurrent}) {
    final previousStatus = _findStatus.value;
    final previousIndex = previousStatus.current;
    final previousMessage = previousIndex == null
        ? null
        : _findMatchMessages[previousIndex];
    final previousMatch = previousIndex == null
        ? null
        : _findMatches[previousIndex];
    final messages = _messages;
    final matches = _findIndex.search(messages, _findQuery);
    _findMatches = matches;
    _findMatchMessages = [for (final m in matches) messages[m.messageIndex]];
    int? current = matches.isEmpty ? null : 0;
    if (keepCurrent && previousMessage != null && previousMatch != null) {
      for (var i = 0; i < matches.length; i++) {
        if (identical(_findMatchMessages[i], previousMessage) &&
            matches[i].start == previousMatch.start) {
          current = i;
          break;
        }
      }
    }
    _publishFindStatus(current);
  }

  void _publishFindStatus(int? current, {bool searchingOlder = false}) {
    _findStatus.value = ChatFindStatus(
      query: _findQuery,
      total: _findMatches.length,
      current: current,
      canSearchOlder: _chat.hasEarlierMessages,
      searchingOlder: searchingOlder,
    );
    _findActiveMessage.value = current == null
        ? null
        : _findMatchMessages[current];
  }

  void _applyFindQuery(String query) {
    if (!_findOpen) return;
    _findEpoch++;
    _findQuery = query;
    _recomputeFindMatches(keepCurrent: false);
    unawaited(_revealCurrentFindMatch());
  }

  Future<void> _revealCurrentFindMatch() async {
    final current = _findStatus.value.current;
    if (current == null) return;
    final epoch = _findEpoch;
    final source = _findMatchMessages[current];
    final projection = _currentRenderProjection;
    final messages = _messages;
    var target = source;
    final sourceIndex = messages.indexWhere((m) => identical(m, source));
    if (sourceIndex >= 0) {
      final renderIndex = projection.nearestRenderableMessageIndex(sourceIndex);
      if (renderIndex != null) target = messages[renderIndex];
    }
    if (epoch != _findEpoch) return;
    await _revealTranscriptMessage(
      target,
      stillWanted: () => _findOpen && epoch == _findEpoch,
    );
  }

  void _stepFindMatch(int delta) {
    final status = _findStatus.value;
    final current = status.current;
    if (current == null || status.total == 0) return;
    _findEpoch++;
    _publishFindStatus((current + delta) % status.total);
    unawaited(_revealCurrentFindMatch());
  }

  /// Pagina historial anterior (la misma paginación del botón «cargar
  /// anteriores») hasta encontrar la consulta o agotar el historial.
  Future<void> _searchOlderFindMessages() async {
    if (!_findOpen || _findQuery.trim().isEmpty) return;
    final epoch = ++_findEpoch;
    _publishFindStatus(null, searchingOlder: true);
    while (mounted &&
        !_disposed &&
        _findOpen &&
        epoch == _findEpoch &&
        _chat.hasEarlierMessages) {
      final before = _messages.length;
      await _loadEarlierMessages();
      if (!mounted || _disposed || !_findOpen || epoch != _findEpoch) return;
      _findMatches = _findIndex.search(_messages, _findQuery);
      if (_findMatches.isNotEmpty) break;
      // Sin progreso (fallo de red): no reintentes en bucle.
      if (_messages.length == before) break;
    }
    if (!mounted || _disposed || !_findOpen || epoch != _findEpoch) return;
    _recomputeFindMatches(keepCurrent: false);
    // Deja que la carga conserve primero el viewport del lector (su ajuste
    // post-frame) y solo entonces recorre la lista hasta el resultado.
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted || _disposed || !_findOpen || epoch != _findEpoch) return;
    unawaited(_revealCurrentFindMatch());
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

  /// Watch en directo del hijo para su pantalla de detalle. El chat presta su
  /// propio gateway y su perfil fijado (nunca el activo global); un cambio de
  /// perfil activo también la invalida y la pantalla cae al tail sondeado.
  SubagentLiveWatch? _openSubagentLiveWatch(SubagentActivity activity) {
    final lease = _chat.subagentWatchLease(activity);
    final childSessionId = activity.childSessionId?.trim();
    if (lease == null || childSessionId == null || childSessionId.isEmpty) {
      return null;
    }
    final scope = appActiveProfileScope(context, widget.connection.id);
    final ticket = scope?.capture();
    return SubagentLiveWatch(
      gateway: lease.gateway,
      childSessionId: childSessionId,
      profile: lease.profile,
      isCurrent: () => lease.isCurrent() && (ticket?.isCurrent ?? true),
      // A profile switch with no event after it must still end the watch.
      invalidation: scope,
      childIsLive: () {
        final current = _currentSubagentActivity(activity.key);
        return current != null && subagentIsLive(current);
      },
    );
  }

  /// Carga la sesión hija solo tras una acción explícita. La ruta recibe una
  /// copia solo lectura de la conexión para que inspeccionar el transcript no
  /// pueda enviar prompts, duplicar ni borrar la conversación del subagente.
  Future<void> _openSubagentConversation(SubagentActivity activity) async {
    final childSessionId = activity.childSessionId?.trim();
    if (childSessionId == null ||
        childSessionId.isEmpty ||
        _openingSubagentSessionIds.contains(childSessionId)) {
      return;
    }
    final readOnlyConnection = widget.connection.copyWith(readOnly: true);
    final strings = Strings.of(context);
    final goal = activity.goalPreview?.trim() ?? '';
    // Spec 080: the child conversation opens as a read-only transcript page
    // (no composer, no duplicate/archive/delete), not the generic session
    // "profile". The loader uses a read-only connection copy.
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SubagentTranscriptPage(
          title: goal.isEmpty
              ? strings.subagentUiTranscriptTitle
              : goal.split('\n').first,
          load: () async {
            final client = ApiClient(
              baseUrl: readOnlyConnection.baseUrl,
              apiKey: readOnlyConnection.apiKey,
              connectionId: readOnlyConnection.id,
            );
            try {
              // Opening (or retrying) the page is an explicit action: it may
              // try the Dashboard once more for a blocked named profile.
              _chat.retryProfileTranscriptAccess();
              return await _chat.loadChildTranscript(
                childSessionId,
                gateway: client,
              );
            } finally {
              client.close();
            }
          },
        ),
      ),
    );
  }

  /// La confirmación y el pending son por hijo. El reducer conserva el estado
  /// actual hasta que Hermes emita un evento autoritativo de cancelación.
  Future<bool> _confirmInterruptSubagent(SubagentActivity activity) async {
    if (_chat.isSubagentInterruptPending(activity)) return false;
    final strings = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('subagent-stop-dialog'),
      title: strings.subagentUiStopTitle,
      message: strings.subagentUiStopBody,
      actions: [
        HermesDialogAction(
          label: strings.subagentUiCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('subagent-stop-confirm'),
          label: strings.subagentUiStopConfirm,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
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
          content: Text(
            s.sesDeleteContent(localizedSessionTitle(s, widget.session)),
          ),
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
        reason: s.sesDeleteContent(localizedSessionTitle(s, widget.session)),
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
        // Shared store first, before the local cleanup's awaits: Home,
        // Conversations and the drawer drop the row in this same turn,
        // whichever screen opened this chat.
        onRemoteDeleted: _markDeletedInSharedStore,
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
    // ss1215: the headline only speaks when no step is running (a running
    // tool names itself). «Ejecutando herramientas…» with none listed read
    // as a pill out of sync with its own panel; between steps the agent is
    // thinking, as the list and Home say.
    // A provider wait the core explained ("⏳ waiting on provider…") is the
    // turn's status line until the provider answers.
    final providerWait = _pipelineState == ChatPipelineState.connecting
        ? null
        : _chat.providerWaitText;
    final activityHeadline =
        providerWait ??
        switch (_pipelineState) {
          // cq1215: a post-cut viewer stays `connecting` for the rest of the
          // turn; with the socket back it is watching a running turn.
          ChatPipelineState.connecting
              when _chat.observesRemoteTurnAfterReconnect =>
            s.ss1215StatusWorking,
          ChatPipelineState.connecting => s.chaPipelineConnecting,
          ChatPipelineState.streaming => s.chaPipelineStreaming,
          _ => s.chaPipelineThinking,
        };
    return chatActivityHeadlineForTransport(
      transportLossVisible: _transportVisibility.visible,
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

  /// A large paste can become an attachment while the `+` could attach one.
  bool get _largePasteAttachable =>
      !widget.connection.readOnly &&
      !_interactiveMessageRefreshPending &&
      !_composerSubmissionInFlight &&
      !_attachmentSubmitting &&
      !_compressingSession;

  /// Longest wait for a paste's private copy. Past it the paste simply stays
  /// in the field as text and send is no longer held by it.
  static const Duration _largePasteAttachTimeout = Duration(seconds: 15);

  void _onLargePaste(String text, int offset) {
    // The paste already sits in the field, which stays its only durable copy
    // (draft, dispose, send) until the chip exists; only then does it leave.
    unawaited(
      _serializeAttachmentMutation(() => _attachPastedText(text, offset)),
    );
  }

  Future<void> _attachPastedText(String text, int offset) async {
    final bytes = utf8.encode(text);
    final batchBytes = _pendingAttachments.fold<int>(
      0,
      (sum, item) => sum + item.sizeBytes,
    );
    AttachmentDraft? persisted;
    File? source;
    if (!_attachmentSubmitting &&
        pendingAttachmentLimitViolation(
              sizeBytes: bytes.length,
              itemLimit: AttachmentUploader.maxTextBytes,
              currentBatchBytes: batchBytes,
            ) ==
            null) {
      final name = pastedContentFileName();
      final file = source = File(
        '${Directory.systemTemp.path}/hermes-paste-${const Uuid().v4()}.txt',
      );
      try {
        await file.writeAsBytes(bytes, flush: true);
        // Re-typed: a materializer may return a non-nullable future, whose
        // timeout could not yield null.
        final pending = _materializeAttachment(
          AttachmentDraft(
            localId: const Uuid().v4(),
            type: AttachmentType.document,
            name: name,
            mimeType: 'text/plain',
            sizeBytes: bytes.length,
            localPath: file.path,
          ),
        ).then<AttachmentDraft?>((copy) => copy);
        persisted = await pending.timeout(
          _largePasteAttachTimeout,
          onTimeout: () {
            // A copy that shows up late is never attached: discard it.
            unawaited(
              pending.then((late) async {
                if (late != null) await _deletePrivateAttachmentCopy(late);
              }, onError: (Object _) {}),
            );
            return null;
          },
        );
      } catch (_) {
        persisted = null;
      } finally {
        if (persisted?.localPath != file.path) await _deleteQuietly(file);
      }
    }
    final attached = persisted;
    if (attached == null) return;
    final at = mounted && !_disposed
        ? pastedRunOffset(_textController.text, text, near: offset)
        : -1;
    if (at < 0) {
      // Disposed, or the user edited the pasted run meanwhile: the field copy
      // is the one the user sees, so the chip is dropped instead.
      await _deletePrivateAttachmentCopy(attached);
      if (source != null && attached.localPath == source.path) {
        await _deleteQuietly(source);
      }
      return;
    }
    _textController.value = removePastedRun(
      _textController.value,
      at,
      text.length,
    );
    setState(() => _pendingAttachments.add(attached));
    _scheduleDraftSave();
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Expands a collapsed paste to edit it; only while it is still a local
  /// draft no delivery has taken.
  Future<void> _openPastedText(String localId) async {
    final index = _pendingAttachments.indexWhere(
      (item) => item.localId == localId,
    );
    if (index < 0) return;
    final attachment = _pendingAttachments[index];
    final delivery = _chatBound ? _chat.activeTurnDelivery : null;
    if (attachment.uploadState != AttachmentUploadState.pending ||
        (delivery?.current.attachments.any((item) => item.localId == localId) ??
            false)) {
      return;
    }
    final String original;
    try {
      original = await File(attachment.localPath).readAsString();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final edited = await showPastedTextEditor(context, original);
    if (!mounted || _disposed || edited == null || edited == original) return;
    if (edited.trim().isEmpty) {
      await _removePendingAttachment(localId);
      return;
    }
    await _serializeAttachmentMutation(() async {
      final current = _pendingAttachments.indexWhere(
        (item) => item.localId == localId,
      );
      if (current < 0 ||
          _pendingAttachments[current].uploadState !=
              AttachmentUploadState.pending) {
        return;
      }
      final bytes = utf8.encode(edited);
      if (bytes.length > AttachmentUploader.maxTextBytes) return;
      try {
        await File(attachment.localPath).writeAsBytes(bytes, flush: true);
      } catch (_) {
        return;
      }
      if (!mounted || _disposed) return;
      setState(() {
        _pendingAttachments[current] = _pendingAttachments[current].copyWith(
          sizeBytes: bytes.length,
        );
      });
      _scheduleDraftSave();
    });
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
    final scaffold = _KeyboardInsetWatcher(
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
            // The header/Bots dot mirror the live chat transport instead of
            // always claiming the instance is online.
            : ValueListenableBuilder<ChatTransportStatus>(
                valueListenable: _chat.transportStatusListenable,
                builder: (context, transport, _) => HermesDrawer(
                  connection: widget.connection,
                  connManager: connManager,
                  current: DrawerSection.chat,
                  connected: transport.isConnected,
                ),
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
                  sessionModel: _headerModelId,
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
                              if (_modelChangePending) ...[
                                const SizedBox(width: 5),
                                Tooltip(
                                  key: const ValueKey('md1215-model-pending'),
                                  message: str.md1215ModelPending,
                                  child: Icon(
                                    Icons.schedule_rounded,
                                    size: 14,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
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
                        case _BotChatHeaderAction.find:
                          _openFind();
                        case _BotChatHeaderAction.model:
                          _showModelSheet();
                        case _BotChatHeaderAction.controls:
                          unawaited(_showChatControlSheet());
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        key: const ValueKey('bot-chat-find-action'),
                        value: _BotChatHeaderAction.find,
                        child: Row(
                          children: [
                            const Icon(Icons.search_rounded, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                str.cs1215FindAction,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
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
                  IconButton(
                    key: const ValueKey('chat-find-trigger'),
                    icon: const Icon(Icons.search_rounded),
                    tooltip: str.cs1215FindAction,
                    onPressed: _openFind,
                  ),
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
                          if (_chat.dashboardAuthNoticeVisible)
                            _DesktopAuthRequiredBanner(
                              message: str.chaDesktopAuthRequiredBanner,
                              onDismiss: () =>
                                  setState(_chat.dismissDashboardAuthNotice),
                            ),
                          ValueListenableBuilder<ChatTransportStatus>(
                            valueListenable: _chat.transportStatusListenable,
                            builder: (_, status, _) =>
                                ChatConnectionRecoveryRow(
                                  visibility: _transportVisibility,
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
                          if (_chat.awaitsUnseenInput)
                            _AwaitingUnseenInputNotice(
                              message: _chat.openRequestRecoveryFailed
                                  ? str.cq1215QuestionNotRecovered
                                  : str.cr1215AwaitingUnseenInput,
                              actionLabel: _chat.openRequestRecoveryFailed
                                  ? str.cq1215RetryQuestion
                                  : str.cr1215ShowQuestion,
                              busy: _chat.openRequestRecoveryInFlight,
                              onShow: () =>
                                  unawaited(_chat.rehydrateOpenRequests()),
                              stopLabel: _chat.openRequestRecoveryFailed
                                  ? str.cq1215StopTurn
                                  : null,
                              onStop: () => unawaited(_cancelStream()),
                            ),
                          if (_chat.localTranscriptTruncationNoticeVisible)
                            _LocalTranscriptTruncationNotice(
                              message: str.chaLocalTranscriptTruncated,
                              onDismiss: () => setState(
                                _chat.dismissLocalTranscriptTruncationNotice,
                              ),
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
                          if (_findOpen)
                            ChatFindBar(
                              status: _findStatus,
                              initialQuery: _findInitialQuery,
                              onQueryChanged: _applyFindQuery,
                              onOlder: () => _stepFindMatch(1),
                              onNewer: () => _stepFindMatch(-1),
                              onSearchOlderMessages: () =>
                                  unawaited(_searchOlderFindMessages()),
                              onClose: _closeFind,
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
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: ListenableBuilder(
                                    listenable: Listenable.merge([
                                      _stickyPrompt,
                                      _transcriptConcealed,
                                    ]),
                                    builder: (context, _) {
                                      final prompt = _stickyPrompt.value;
                                      if (prompt == null ||
                                          _findOpen ||
                                          _transcriptConcealed.value) {
                                        return const SizedBox.shrink();
                                      }
                                      return Semantics(
                                        button: true,
                                        label: str.pj1215StickyPromptLabel,
                                        child: GestureDetector(
                                          key: const ValueKey(
                                            'chat-sticky-prompt',
                                          ),
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => unawaited(
                                            _revealStickyPrompt(prompt),
                                          ),
                                          // The user bubble is translucent
                                          // by design; pinned over the reply
                                          // it showed the text underneath.
                                          // Like Desktop's sticky prompt,
                                          // the reply is hidden behind it:
                                          // an opaque field of the screen
                                          // background.
                                          child: ColoredBox(
                                            color: Theme.of(
                                              context,
                                            ).scaffoldBackgroundColor,
                                            child: ClipRect(
                                              child: ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                      maxHeight: 96,
                                                    ),
                                                child: SingleChildScrollView(
                                                  physics:
                                                      const NeverScrollableScrollPhysics(),
                                                  child: IgnorePointer(
                                                    child: ExcludeSemantics(
                                                      child: _UserMessage(
                                                        content:
                                                            prompt['content']
                                                                as String,
                                                        compact: true,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
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
                                                        newMessages:
                                                            _newWhileAway,
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
                                              // ps1215: the same clock the
                                              // chat measures the turn with.
                                              clock: _chat.wallNow,
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
                                                canTail: _chat.canTailSubagent,
                                                delegationControl:
                                                    _chat.delegationControl,
                                                parentTitle:
                                                    widget.session.title,
                                                acquirePresentation:
                                                    _acquireSubagentDetailLease,
                                                isInterruptPending: _chat
                                                    .isSubagentInterruptPending,
                                                appForeground:
                                                    _appInForeground &&
                                                    _chatRouteVisible,
                                                openLiveWatch:
                                                    _openSubagentLiveWatch,
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
                                ?_buildRecoveredTurnBanner(),
                                if (_chat.compactionAuthFailure
                                    case final compactionAuth?)
                                  ProviderAuthBanner(
                                    failure: compactionAuth,
                                    onAction: _providerReauthRunning
                                        ? null
                                        : () => unawaited(
                                            _reauthProvider(compactionAuth),
                                          ),
                                    onDismiss:
                                        _chat.dismissCompactionAuthFailure,
                                  ),
                                if (_chat.offerStaleResumedSessionStop)
                                  StaleRunningSessionBanner(
                                    enabled: _chat.gatewayConnected,
                                    onStop: _cancelStream,
                                    onDismiss: _chat
                                        .dismissStaleResumedSessionStopOffer,
                                  ),
                                // Ownership conflicts keep the transcript and composer
                                // mounted while fencing every mutation.
                                // Cerrar el aviso solo lo compacta a una línea: el
                                // estado de solo lectura sigue a la vista.
                                if (_chat.conflictReadOnly)
                                  _chat.ownershipConflictNoticeVisible
                                      ? _buildRuntimeOwnershipBanner()
                                      : _buildRuntimeOwnershipCompactIndicator(),
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
                                if (_chat.desktopContinuationNoticeVisible)
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
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          4,
                                          4,
                                          4,
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.desktop_windows_outlined,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                Strings.of(
                                                  context,
                                                ).chatContinueOnDesktop,
                                              ),
                                            ),
                                            _ChatNoticeDismissButton(
                                              key: const ValueKey(
                                                'desktop-continuation-dismiss',
                                              ),
                                              onPressed: () => setState(
                                                _chat
                                                    .dismissDesktopContinuationNotice,
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
                                _lockWhileEditing(_buildQueueStrip(colors)),
                                if ((_vc?.active ?? false) && !showVoiceSurface)
                                  _buildVoiceReturnBar(
                                    colors,
                                    ownsCurrentChat: voiceSessionActive,
                                  ),
                                if (!showVoiceSurface)
                                  Opacity(
                                    opacity: _editingUserMessage ? 0.62 : 1,
                                    child: _lockWhileEditing(_buildInputBar()),
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
    return _BotChatIdentity(
      profile: botSurface ? widget.missionBotProfile : null,
      avatarCache: botSurface ? widget.missionAvatarCache : null,
      child: scaffold,
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
        final result = ModelPickerResult(
          info: catalog.$1,
          providers: catalog.$2,
          source: ModelPickerSource.bridge,
        );
        _modelPickerCache
          ..noteSuccess(_modelPickerKey, ModelPickerSource.bridge)
          ..write(_modelPickerKey, result);
        _adoptModelPickerResult(result);
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
      final ok = await _bridgeModelOptions() != null;
      if (ok && mounted) {
        // A repaired Bridge must not wait out its failure cooldown.
        _modelPickerCache.noteSuccess(
          _modelPickerKey,
          ModelPickerSource.bridge,
        );
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  void _showModelSheet() {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    // mk1215: un catálogo cacheado se pinta al instante; si está caducado se
    // revalida en segundo plano. Si ya hay runtime, `session.info` sigue
    // siendo la única fuente del badge efectivo.
    final cached = _modelPickerCache.peek(_modelPickerKey);
    if (cached != null) {
      _adoptModelPickerResult(cached.result);
      _modelOptionsPainted = _withoutHiddenModels(
        cached.result,
        _lastReadPrefs,
      );
      if (cached.fresh) {
        _modelOptionsFuture ??= Future.value(_modelOptionsPainted!);
      }
    }
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
                  initialData: _modelOptionsPainted,
                  builder: (ctx, snap) {
                    // A failed background refresh keeps the painted catalog.
                    final data = snap.data ?? _modelOptionsPainted;
                    final loading =
                        data == null &&
                        snap.connectionState == ConnectionState.waiting;
                    final active = _chat.hasDesktopRuntime
                        ? _activeModel
                        : data?.$1;
                    final providers = data?.$2 ?? const <ModelProvider>[];
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
                        else if (data == null && snap.hasError)
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
                                          _isSelectedProvider(p.slug) &&
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
    ).whenComplete(() {
      _modelOptionsFuture = null;
      _modelOptionsPainted = null;
    });
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

  /// md1215: `session.info` names a user-defined endpoint `custom:<key>`
  /// while its catalog row uses the bare key; resolve through the catalog's
  /// aliases like Desktop does so the active row is recognised.
  bool _isSelectedProvider(String slug) =>
      _selectedProvider == slug ||
      _desktopModelCatalog?.providerFor(_selectedProvider)?.slug == slug;

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
  bool _dictationStarting = false;
  Completer<void>? _dictationCompletion;

  /// Plazo máximo para recibir el final tras pulsar parar. Los motores que
  /// graban y transcriben al parar (Whisper local, servidor Hermes) tardan lo
  /// que dure el audio y ya acotan su propia transcripción; cortar antes
  /// descartaba lo dictado con un falso «no se reconoció voz».
  Duration _dictationStopBudget(VoiceService voice) =>
      voice.sttRecordsThenTranscribes
      ? const Duration(minutes: 3)
      : const Duration(seconds: 4);

  Future<void> _startDictation() async {
    final voice = _voice;
    if (voice == null) return;
    // Los `await` previos a escuchar dejan el micro pulsable: un segundo toque
    // abría otra escucha y dejaba la primera huérfana.
    if (_dictationStarting || _isRecording) return;
    _dictationStarting = true;
    try {
      await _startDictationGuarded(voice);
    } finally {
      _dictationStarting = false;
    }
  }

  Future<void> _startDictationGuarded(VoiceService voice) async {
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
    // The STT check can wait on the runtime permission prompt. If the chat
    // closed meanwhile, never open a capture nobody owns or can stop.
    if (!mounted || _disposed) return;
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
    if (!mounted || (!_isRecording && !_transcribing)) return;
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

  /// Vuelca lo dictado al composer. Si el usuario escribió mientras el motor
  /// grababa o esperaba al servidor, su texto se conserva y lo dictado se
  /// inserta en el punto donde empezó el dictado; reemplazarlo por
  /// [_dictationBase] borraba lo tecleado durante una transcripción lenta.
  void _materializeDictation() {
    final current = _textController.text;
    final origin = _dictationOriginal.trimRight();
    var text = _dictationBase;
    if (current != _dictationOriginal) {
      final dictated = _dictationBase.startsWith(origin)
          ? _dictationBase.substring(origin.length).trim()
          : _dictationBase.trim();
      if (!current.startsWith(origin)) {
        text = _joinDictation(current, dictated);
      } else {
        final typed = current.substring(origin.length).trim();
        text = _joinDictation(_joinDictation(origin, dictated), typed);
      }
    }
    _setComposerText(text);
  }

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
    _stopFallback = Timer(_dictationStopBudget(voice), () {
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
        final voice = _voice;
        await completion.future.timeout(
          (voice == null
                  ? const Duration(seconds: 4)
                  : _dictationStopBudget(voice)) +
              const Duration(milliseconds: 300),
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
                        _chat.queueParkedAfterCompression
                            ? Strings.of(
                                context,
                              ).cq1215QueueParkedAfterCompaction
                            // A stuck head is the more useful note: resuming a
                            // queue from a previous run would not send it either.
                            : _chat.queueParkedFromPreviousSession &&
                                  !_queueHeadStuck(queuedEntries)
                            ? Strings.of(
                                context,
                              ).lo1216QueueParkedFromPreviousSession
                            : _chat.queueParked &&
                                  !_chat.queueParkedFromPreviousSession
                            ? Strings.of(context).chaQueueParkedNote
                            : _queueHeadStuck(queuedEntries)
                            ? Strings.of(context).q1215QueueHeadStuckNote
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
                onPressed: _resumeParkedQueue,
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
                retryExhausted: _queuedRetryExhausted(queuedEntries[i]),
                attachmentNames: queuedEntries[i].attachments
                    .map((item) => item.name)
                    .toList(growable: false),
                busy: _chat.isStreaming,
                transportCanSteer: _chat.canSteerLiveTurn,
                editingId: _editingQueuedEntryId,
                onEdit: () => unawaited(_editQueuedEntry(queuedEntries[i])),
                canMoveUp: _queueEntryMovable(queuedEntries, i, up: true),
                canMoveDown: _queueEntryMovable(queuedEntries, i, up: false),
                onMove: (up) =>
                    unawaited(_moveQueuedEntry(queuedEntries[i].id, up: up)),
                onSteer: () =>
                    unawaited(_steerQueuedEntry(queuedEntries[i].id)),
                onSendNow: () =>
                    unawaited(_sendQueuedEntryNow(queuedEntries[i])),
                onDelete: () =>
                    unawaited(_deleteQueuedEntry(queuedEntries[i].id)),
                onAbandon: () =>
                    unawaited(_abandonUncertainQueued(queuedEntries[i])),
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

  /// Whether row [index] can swap places with its neighbour: neither row may
  /// be the one being sent, already on the server or of unknown delivery.
  bool _queueEntryMovable(
    List<QueuedEntryView> entries,
    int index, {
    required bool up,
  }) {
    final other = index + (up ? -1 : 1);
    if (other < 0 || other >= entries.length) return false;
    bool movable(QueuedEntryView entry) =>
        entry.kind != QueuedEntryKind.desktopAccepted &&
        !entry.sending &&
        !entry.serverAccepted &&
        !entry.deliveryUnknown &&
        !entry.stopWaitingAvailable;
    return movable(entries[index]) && movable(entries[other]);
  }

  /// Nothing is running and the first queued row will not go on its own
  /// (unconfirmed, left over from an earlier run, attachment missing, retries
  /// used up). The header must not promise it will be sent "when the turn
  /// ends". A row merely `blocked` may have a retry scheduled, so it does not
  /// count by itself.
  bool _queueHeadStuck(List<QueuedEntryView> entries) {
    if (_chat.isStreaming || entries.isEmpty) return false;
    final head = entries.first;
    if (head.kind == QueuedEntryKind.desktopAccepted) return false;
    return head.stopWaitingAvailable ||
        head.missingAttachment ||
        _queuedRetryExhausted(head);
  }

  /// The entry used up its automatic retries on a healthy socket and will
  /// not go on its own until the user retries it.
  bool _queuedRetryExhausted(QueuedEntryView entry) {
    if (entry.kind == QueuedEntryKind.desktopAccepted) return false;
    final retryKey = entry.id.startsWith('prepared:')
        ? entry.id.substring('prepared:'.length)
        : entry.id;
    return _chat.queuedRetriesExhausted.contains(retryKey);
  }

  Future<void> _abandonUncertainQueued(QueuedEntryView entry) async {
    final strings = Strings.of(context);
    final confirmed = await showHermesConfirmDialog(
      context: context,
      title: strings.chatQueueAbandonTitle,
      message: entry.serverAccepted
          ? strings.q1215QueueAbandonAcceptedBody
          : strings.chatQueueAbandonBody,
      confirmLabel: strings.chatQueueAbandonConfirm,
      cancelLabel: strings.commonCancel,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    if (await _chat.abandonUncertainQueuedTurn(entry.id) || !mounted) return;
    _showQueueActionFailed(Strings.of(context).q1215QueueAbandonFailed);
  }

  void _resumeParkedQueue() {
    if (_chat.resumeParkedQueue()) return;
    _showQueueActionFailed(Strings.of(context).q1215QueueResumeFailed);
  }

  ConsoleComposerDictation _composerDictation({
    required bool dictationInteractive,
  }) => ConsoleComposerDictation(
    recording: _isRecording,
    transcribing: _transcribing,
    interactive: dictationInteractive,
    level: _voice?.micLevel,
    cancelEnabled: !_dictationSendInFlight,
    sendEnabled:
        !_dictationSendInFlight &&
        (_dictationBase.trim().isNotEmpty ||
            _dictationPartial.trim().isNotEmpty),
    onStart: _startDictation,
    onStop: _stopDictation,
    onCancel: _cancelDictation,
    onSend: _sendDictation,
  );

  Widget? _composerVoiceModeAction(HermesThemeColors colors, bool showStop) {
    if (!(kVoiceRuntimeEnabled &&
        _allowsDedicatedVoiceLaunch &&
        _nothingToSend &&
        !showStop &&
        !_composerSubmissionInFlight &&
        !_compressingSession &&
        !_isRecording)) {
      return null;
    }
    return HermesTactileAction(
      icon: Icons.graphic_eq_rounded,
      semanticLabel: Strings.of(context).chaVoiceModeTooltip,
      onPressed: widget.connection.readOnly ? null : _enterVoiceMode,
      backgroundColor: colors.secondary,
      foregroundColor: colors.onAccent,
      enabled: !widget.connection.readOnly,
      size: 42,
      iconSize: 23,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    strings.chaRuntimeOwnershipTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
              _ChatNoticeDismissButton(
                key: const ValueKey('chat-runtime-ownership-dismiss'),
                onPressed: () => setState(_chat.dismissOwnershipConflictNotice),
              ),
            ],
          ),
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

  /// Resto visible del aviso de conflicto tras cerrarlo: una sola línea con el
  /// título y «comprobar de nuevo», para que el composer vallado nunca quede
  /// sin explicación. No reabre el aviso largo ni toca la valla.
  Widget _buildRuntimeOwnershipCompactIndicator() {
    final strings = Strings.of(context);
    final checking = _chat.ownershipRecheckInFlight;
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: true,
      label: strings.chaRuntimeOwnershipTitle,
      child: Padding(
        key: const ValueKey('chat-runtime-ownership-compact'),
        padding: const EdgeInsets.fromLTRB(18, 2, 8, 0),
        child: Row(
          children: [
            Icon(Icons.lock_outline_rounded, size: 16, color: colors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  strings.chaRuntimeOwnershipTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
            ),
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
      ),
    );
  }

  Widget _buildInputBar() {
    widget.performanceProbe?.composerBuilds++;
    final colors = Theme.of(context).hermes;
    if (widget.connection.readOnly || _cronRunReadOnly) {
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
                          widget.connection.readOnly
                              ? Strings.of(context).readOnlyNotice
                              : Strings.of(context).au1215CronRunViewOnly,
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
    final mentionPalette =
        _isRecording || _transcribing || _navigationDrawerOpen
        ? null
        : ChatMentionPalette(
            controller: _textController,
            focusNode: _textFocusNode,
            connectionId: widget.connection.id,
            profile: _effectiveSessionProfile,
          );
    final referencePalette = !_referencePaletteVisible
        ? null
        : TextFieldTapRegion(
            child: ComposerReferencePalette(
              items: _referenceItems,
              onPick: _pickReference,
              onDescend: _descendReference,
            ),
          );
    final floatingPalette =
        slashPalette ??
        (referencePalette == null
            ? mentionPalette
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(child: referencePalette),
                  ?mentionPalette,
                ],
              ));
    final showStop = _chat.canStopSessionWork && _nothingToSend;
    // Composer premium compartido (ConsoleComposer): contenedor con borde
    // sutil, campo sin marco y fila de acciones con send cuadrado.
    return ConsoleComposer(
      controller: _textController,
      focusNode: _textFocusNode,
      palette: floatingPalette,
      inputFormatters: _composerInputFormatters,
      onOpenPastedText: (localId) => unawaited(_openPastedText(localId)),
      reduceMotion: _reduceMotion,
      attachments: _pendingAttachments,
      onRemoveAttachment: (localId) =>
          unawaited(_removePendingAttachment(localId)),
      onRetryAttachment: (localId) =>
          unawaited(_retryPendingAttachment(localId)),
      onAttach: (source) => unawaited(_selectAttachmentSource(source)),
      attachEnabled: attachmentInteractive,
      dictation: _composerDictation(dictationInteractive: dictationInteractive),
      hintText: _attachmentSubmitting
          ? Strings.of(context).chaUploadingAttachment
          : _pendingAttachments.isNotEmpty
          ? Strings.of(context).chaHintSystem
          : _botDisplayName != null
          ? Strings.of(context).botChatComposerHint(_botDisplayName!)
          : Strings.of(context).chaHintUser,
      onKeyboardSubmit: _composerKeyboardSubmit,
      // Pegar una imagen desde el teclado es adjuntar: cerrado mientras
      // compacta, igual que el `+`.
      onContentInserted: _compressingSession
          ? null
          : (content) => unawaited(_insertKeyboardContent(content)),
      // Mientras compacta se puede escribir y poner en cola el siguiente
      // turno; la cola lo retiene hasta que termine. La invocación `/compress`
      // ya salió del composer y un comando escrito ahora no se ejecuta
      // (`_sendMessageOnce`), así que no hay segundo envío. Adjuntar y dictar
      // siguen cerrados porque mezclarían el lote en vuelo.
      fieldEnabled: !_attachmentSubmitting,
      voiceModeAction: _composerVoiceModeAction(colors, showStop),
      showStop: showStop,
      // Sin lanzadera mientras compacta: la barra de compactación sobre el
      // compositor es la única señal viva.
      busy:
          !showStop &&
          !_compressingSession &&
          (_composerSubmissionInFlight || _attachmentSubmitting),
      stopEnabled: _chat.gatewayConnected,
      sendEnabled:
          !_interactiveMessageRefreshPending &&
          !_composerSubmissionInFlight &&
          !_attachmentSubmitting &&
          !_attachmentMutationInFlight &&
          !_nothingToSend,
      onSend: (_, _) => _sendMessage(),
      onQueue:
          _sending ||
              _chat.hasAuthoritativePassiveRemoteActivity ||
              _compressingSession
          ? () => _sendMessage(queueOnly: true)
          : null,
      onStop: _cancelStream,
      footer: _buildFloatingStatusPill(colors),
    );
  }

  /// Compactación en curso o recién terminada, o `null`. Se pinta dentro de
  /// la mini píldora de contexto+modo bajo el composer (tp1216), no en una
  /// pastilla flotante aparte.
  CompactionProgress? get _visibleCompaction =>
      _compaction.current ??
      (_chatBound &&
              (_compressingSession || _chat.desktopRestoredCompressionRunning)
          ? CompactionProgress(
              startedAt: _chat.desktopCompactionStartedAt ?? DateTime.now(),
              manual: true,
              messagesBefore: _chat.desktopCompactionMessagesBefore,
              tokensBefore: _chat.desktopCompactionTokensBefore,
            )
          : null);

  /// Píldora combinada contexto+modo flotando bajo el composer (ver mockup
  /// aprobado "v8 · estado debajo del input"): sustituye a los antiguos
  /// `_buildModeBadge` + `SessionContextPopoverButton` de la AppBar. Oculta
  /// en Bot Chat, igual que ocultaban esos widgets antes.
  /// Sigue abriendo el mismo `showSessionContextPopover`; la sección de modo
  /// se reutiliza de `_buildApprovalModeSection` en vez de duplicarla.
  Widget _buildFloatingStatusPill(HermesThemeColors colors) {
    final compaction = _visibleCompaction;
    if (_isBotChatSurface) {
      // Sin píldora de contexto: la compactación nunca se queda sin señal.
      return compaction == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: CompactionInlineIndicator(compaction: compaction),
              ),
            );
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
          compaction: compaction,
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
        ChatErrorKind.profileDashboardAccess =>
          str.chaErrProfileDashboardAccess,
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
                  onTap: _retryMessagesAfterError,
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
        child: _EmptyChatState(
          model: _activeModelLabel,
          agentName: _assistantName,
          workspace: _newChatWorkspace,
        ),
      );
    }

    final entries = _currentListEntries;
    final snapshot = _messages;
    pruneMessageAnchorCache(_messageAnchors, snapshot);
    if (!identical(snapshot, _stickySource)) {
      _stickySource = snapshot;
      _stickyIndex = null;
      _scheduleStickyPromptUpdate();
    }

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
              Widget child = _wrapFindHighlight(
                _buildRenderUnit(unit, assistantSlice: assistantSlice),
                unit: unit,
                sourceMessages: sourceMessages,
              );
              child = _wrapReactions(
                child,
                unit: unit,
                assistantSlice: assistantSlice,
              );
              if (_newSinceFirstUnread != null &&
                  (assistantSlice?.showHeader ?? true) &&
                  sourceMessages.any(_isNewSinceFirstUnread)) {
                // Inside the row (not a list entry of its own): indices and
                // the reader anchors keep their slots, and the landing jump
                // aligns the divider with the top of the screen.
                child = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RoomSeparator(
                      key: const ValueKey('chat-new-since-divider'),
                      label: Strings.of(context).sc1215NewSinceYouLeft,
                      highlight: true,
                    ),
                    child,
                  ],
                );
              }
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
                    var added = false;
                    for (final message in sourceMessages) {
                      if (!identical(_messageAnchors[message], anchor)) {
                        _messageAnchors[message] = anchor;
                        added = true;
                      }
                    }
                    if (added) _scheduleStickyPromptUpdate();
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
              } else if (sourceMessages.isNotEmpty) {
                // A later slice of a long reply: it has no reader anchor of
                // its own, but when it spans the viewport top the sticky
                // prompt needs to know which reply it belongs to.
                final replyMessage = sourceMessages.first;
                result = ChatAnswerAnchor(
                  onLayout: (anchor) {
                    if (identical(_stickySliceAnchors[anchor], replyMessage)) {
                      return;
                    }
                    _stickySliceAnchors[anchor] = replyMessage;
                    _scheduleStickyPromptUpdate();
                  },
                  onDetach: (anchor) => _stickySliceAnchors.remove(anchor),
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
              // A response group grows at its newest row; its oldest row is
              // the stable identity, so a joining row never replays the
              // entrance nor remounts the bubble.
              final groupStart =
                  plan is ChatMessageUnitPlan && sourceMessages.length > 1
                  ? sourceMessages.last
                  : null;
              final key = _entranceKey(groupStart ?? unit);
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
              final durableEntryIds =
                  (groupStart == null ? sourceMessages : [groupStart])
                      .map((message) {
                        final messageId = canonicalTranscriptMessageId(message);
                        if (messageId != null) return 'message:$messageId';
                        final rowId = canonicalTranscriptRowId(message);
                        return rowId == null ? null : 'row:$rowId';
                      })
                      .whereType<String>()
                      .toList(growable: false);
              if (durableEntryIds.length ==
                  (groupStart == null ? sourceMessages.length : 1)) {
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
      cachedLabel: _chat.showingCachedTranscript
          ? Strings.of(context).cs1215CachedTranscript
          : null,
      errorMessage: _error == null || _refreshErrorNoticeDismissed
          ? null
          : classifyChatError(_error!) == ChatErrorKind.profileDashboardAccess
          ? Strings.of(context).chaErrProfileDashboardAccess
          : Strings.of(context).chaMessagesError,
      onDismissError: () => setState(() => _refreshErrorNoticeDismissed = true),
      // Bajo el botón «cargar anteriores» (8 + 48 + 8) cuando está a la vista.
      errorTopInset: _chat.hasEarlierMessages ? 64 : 8,
      // Always in the tree so hiding never rebuilds the list or loses its
      // scroll position; laid out while hidden so the landing walk can build
      // rows, but neither painted nor touchable.
      child: ValueListenableBuilder<bool>(
        valueListenable: _transcriptConcealed,
        builder: (context, concealed, child) => Visibility(
          visible: !concealed,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: child!,
        ),
        child: transcript,
      ),
    );
  }

  /// Resaltado del resultado actual de la búsqueda. Envuelve solo el
  /// contenido de filas estables: el host vivo del streaming queda fuera para
  /// no interponer nada en la geometría que mide el lock del viewport.
  /// Reaction row under a persisted message, only while the user has turned
  /// reactions on and the connection can store them. Live rows that have no
  /// transcript id yet get the row once they are persisted.
  Widget _wrapReactions(
    Widget child, {
    required Object unit,
    required _AssistantRenderSlice? assistantSlice,
  }) {
    if (unit is! Map<String, dynamic>) return child;
    if (assistantSlice != null && !assistantSlice.showFooter) return child;
    final role = unit['role'];
    if ((role != 'user' && role != 'assistant') || unit['_pipeline'] == true) {
      return child;
    }
    final rowId = canonicalTranscriptRowId(unit);
    if (rowId == null) return child;
    return ListenableBuilder(
      listenable: MessageReactionPrefs.shared,
      child: child,
      builder: (context, child) {
        if (!MessageReactionPrefs.shared.enabled) return child!;
        if (!_chat.canReact) {
          // Hidden until the server has confirmed message.react. ActiveChat
          // asks on connect and when the preference turns on, never a build.
          return child!;
        }
        final reactions = _chat.reactionsFor(rowId);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            child!,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: role == 'user'
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: MessageReactionBar(
                  key: ValueKey('message-reactions-$rowId'),
                  reactions: reactions,
                  addTooltip: Strings.of(context).reactAdd,
                  onPick: (emoji) => _react(rowId, emoji),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _react(int rowId, String emoji) async {
    try {
      await _chat.reactToMessage(rowId: rowId, emoji: emoji);
    } catch (_) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).reactFailed)),
        kind: HermesNoticeKind.warning,
      );
    }
  }

  Widget _wrapFindHighlight(
    Widget child, {
    required Object unit,
    required List<Map<String, dynamic>> sourceMessages,
  }) {
    if (!_findOpen) return child;
    final messages = _messages;
    if (_chat.isStreaming &&
        messages.isNotEmpty &&
        identical(unit, messages.first)) {
      return child;
    }
    if (unit is Map<String, dynamic> && _messageKeepsLiveHost(unit)) {
      return child;
    }
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _findActiveMessage,
      builder: (context, active, child) => ChatFindMatchHighlight(
        active:
            active != null && sourceMessages.any((m) => identical(m, active)),
        semanticLabel: Strings.of(context).cs1215CurrentMatchLabel,
        child: child!,
      ),
      child: child,
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
      onLayout: (anchor) {
        if (identical(_messageAnchors[assistant], anchor)) return;
        _messageAnchors[assistant] = anchor;
        _scheduleStickyPromptUpdate();
      },
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

  /// "Branch from here" for [message] when the chat can branch and the row is
  /// part of the server's user/assistant history. Reached by long-pressing the
  /// assistant header: the text itself keeps its own long-press selection and
  /// the action buttons keep their tooltips.
  VoidCallback? _branchFromHereFor(Map<String, dynamic> message) {
    if (!_chat.canBranchChat ||
        !isBranchHistoryRow(message) ||
        message['_optimistic'] == true) {
      return null;
    }
    return () async {
      final strings = Strings.of(context);
      final chosen = await showHermesMenu<bool>(
        context: context,
        surfaceKey: const ValueKey('chat-message-menu'),
        actions: [
          HermesAction<bool>(
            key: const ValueKey('chat-message-branch'),
            value: true,
            label: strings.tc1215BranchFromHere,
            icon: Icons.call_split_rounded,
          ),
        ],
      );
      if (chosen == true && mounted) {
        unawaited(_branchChat(fromMessage: message));
      }
    };
  }

  List<Map<String, dynamic>> _sourceMessagesForRenderPlan(
    ChatRenderUnitPlan plan,
  ) {
    final indexes = switch (plan) {
      // Every row of a response group keeps its own anchor, find highlight
      // and unread marker, newest first.
      ChatMessageUnitPlan(:final memberIndexesNewestFirst) =>
        memberIndexesNewestFirst,
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
      _chat.pendingApproval != null ||
      _chat.pendingInteractivePrompt != null ||
      _chat.awaitsUnseenInput;

  HermesSparkMood _liveCompanionMood() {
    if (_transportVisibility.visible && !_chat.dashboardAuthRequired) {
      return HermesSparkMood.offline;
    }
    if (_turnWaitsForUser) return HermesSparkMood.waiting;
    return switch (_pipelineState) {
      ChatPipelineState.connecting
          when _chat.observesRemoteTurnAfterReconnect =>
        HermesSparkMood.thinking,
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
    return ListenableBuilder(
      listenable: _transportVisibility,
      builder: (context, _) {
        final mood = _liveCompanionMood();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _AssistantLiveHeader(agentName: _assistantName, mood: mood),
          ],
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
      final systemChip = _jobChipLabel(content, Strings.of(context));
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
        editingDraft: _editingUserMessageDraft,
        editingWidth: _editingUserMessageWidth,
        editSaving: _editingRewriteSubmitted,
        editingLaterTurns: _laterTurnsAfter(_editingUserMessageOrdinal),
        onCancelEdit: _cancelUserMessageEdit,
        onSaveEdit: (text) => unawaited(_saveUserMessageEdit(text)),
      );
    }

    final msg = unit as Map<String, dynamic>;
    final role = (msg['role'] as String?) ?? 'assistant';
    var content = (msg['content'] as String?) ?? '';
    final rawContent = content;
    // Un turno del agente llega en varias filas (herramientas, razonamiento,
    // texto intermedio y final). Como Desktop, todas comparten UNA burbuja:
    // una cabecera, un «Pensó ⌄» con todas las herramientas y el texto al
    // final. [msg] es la fila más nueva y conserva acciones e identidad.
    final groupRows = role == 'assistant'
        ? _olderResponseGroupRows(msg)
        : const <Map<String, dynamic>>[];
    final metadataMsg = groupRows.isEmpty ? msg : _responseGroupMetadata(msg);
    final groupPrefix = _responseGroupTextPrefix(groupRows);
    final sourceContent = _joinResponseGroupText(groupPrefix, content);

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

    // Aviso de fin de proceso en segundo plano: Hermes lo guarda como
    // `role=user`; igual que Desktop se pinta como aviso compacto con la salida
    // plegada, nunca como burbuja de la persona.
    if (role == 'user' && effectiveUserDisplayKind(msg) == 'process_complete') {
      final carrier = parseBackgroundProcessCarrier(sourceContent.trimRight());
      if (carrier != null) {
        return _ProcessNotificationRow(carrier: carrier, raw: sourceContent);
      }
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
    final systemChip = _jobChipLabel(content, Strings.of(context));
    if (systemChip != null) {
      return _SystemBlobChip(label: systemChip, raw: content);
    }

    // Error bubble with retry
    if (role == 'assistant_error') {
      final prompt = (msg['_prompt'] as String?) ?? _lastPrompt;
      final authFailure = ProviderAuthFailure.fromJson(
        msg[providerAuthFailureKey],
      );
      final onRetry = _chat.conflictReadOnly || widget.connection.readOnly
          ? null
          : () => unawaited(_retryLastPrompt(prompt));
      final surface = TurnErrorSurface.parse(msg[turnErrorSurfaceKey]);
      final billing = TurnBillingBlock.parse(msg[turnBillingBlockKey]);
      final failedTurn = _chat.currentFailedTurnToken;
      final retryChat = _chat;
      final readOnly = _chat.conflictReadOnly || widget.connection.readOnly;
      return ChatErrorBubble(
        error: activeChatStoredErrorUiMessage(content),
        onRetry: onRetry,
        prompt: prompt,
        onRestartGateway: _restartGatewayFromChat,
        onNewSession: _chat.conflictReadOnly ? null : _newChat,
        authFailure: authFailure,
        onReauth: authFailure == null || _providerReauthRunning
            ? null
            : () => unawaited(_reauthProvider(authFailure, onRetry: onRetry)),
        surface: surface,
        billing: billing,
        onCompress: readOnly ? null : () => unawaited(_compressFromError()),
        onChooseModel: readOnly ? null : _showModelSheet,
        onEditMessage: _editMessageOfError(msg),
        onOpenBilling: _openBillingAction(billing),
        onSignInFreeTier: readOnly ? null : _signInFreeTier,
        freeTierSignInAvailable: _freeTierSignInAvailable,
        // A retry may only be armed on the failed turn that is still the last
        // one; a different chat, profile or failed turn drops it.
        canArmRetry:
            onRetry != null &&
            failedTurn != null &&
            _chat.state == ChatPipelineState.failed,
        retryScope: (
          retryChat,
          Session.profileOwner(_chat.sessionProfile),
          failedTurn,
        ),
        onScheduledRetry: onRetry == null || failedTurn == null
            ? null
            : () {
                if (!mounted ||
                    !identical(_chat, retryChat) ||
                    _chat.state != ChatPipelineState.failed ||
                    !_isSameFailedTurn(
                      retryChat.currentFailedTurnToken,
                      failedTurn,
                    )) {
                  return;
                }
                onRetry();
              },
        now: _chat.wallNow,
        composerProvider: _chat.desktopRuntimeInfo.provider,
        composerModel: _chat.desktopRuntimeInfo.model,
      );
    }

    final isPipeline = msg['_pipeline'] == true;
    final hasUnifiedActivity =
        normalizeAssistantActivityTrace(
          metadataMsg[assistantActivityTraceKey],
        ).isNotEmpty ||
        (metadataMsg['reasoning'] is String &&
            (metadataMsg['reasoning'] as String).trim().isNotEmpty);
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
    content = _joinResponseGroupText(groupPrefix, content);

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
        _structuredGeneratedImages(metadataMsg).isEmpty &&
        _structuredGeneratedVideos(metadataMsg).isEmpty &&
        !_assistantActivityEvents(context, metadataMsg, '').any(
          (event) =>
              event.kind == ChatTraceEventKind.reasoning ||
              !isInternalActivityLabel(event.label),
        ) &&
        !(metadataMsg['reasoning'] is String &&
            (metadataMsg['reasoning'] as String).trim().isNotEmpty)) {
      return const SizedBox.shrink();
    }
    if (role == 'assistant' && isCancelled && content.isNotEmpty) {
      // El parcial cancelado largo llega ya troceado (displaySlice): cada
      // slice pinta su parte y solo el cierre lleva la marca 'cancelled'.
      return _AssistantMessageWithMark(
        content: displayContent,
        mark: _AssistantMessageMark.cancelled,
        verbose: _devDiagnostics,
        metadata: msg,
        linkCache: _linkCache,
        fetchLinkPreview: _fetchLinkPreview,
        firstUrl: _firstUrl,
        agentName: _assistantName,
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
      agentName: _assistantName,
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
      editingDraft: _editingUserMessageDraft,
      editingWidth: _editingUserMessageWidth,
      editSaving: _editingRewriteSubmitted,
      editingLaterTurns: _laterTurnsAfter(_editingUserMessageOrdinal),
      onCancelEdit: _cancelUserMessageEdit,
      onSaveEdit: (text) => unawaited(_saveUserMessageEdit(text)),
      onRegenerate: role == 'assistant' && _isLatestAssistant(msg)
          ? _regenerateLastResponse
          : null,
      onBranch: _branchFromHereFor(msg),
      onSuggestionSelected: suggestionsEnabled
          ? (suggestion) => _useAssistantSuggestion(msg, suggestion)
          : null,
      connectionCard: role == 'assistant'
          ? _connectionCardFor(metadataMsg)
          : null,
      compact: compact,
      toolOutputs: role == 'assistant' ? _toolOutputFor : null,
      latestReplyText:
          role == 'assistant' &&
              groupPrefix.isNotEmpty &&
              rawContent.trim().isNotEmpty
          ? () => projectAssistantSuggestions(
              splitReasoning(rawContent).answer,
            ).body
          : null,
      showChangedFiles:
          role == 'assistant' &&
          !isStreaming &&
          !isPipeline &&
          _isLatestAssistant(msg),
    );
  }

  _ConnectionCardBinding? _connectionCardFor(Map<String, dynamic> metadata) {
    final request = _chat.connectionRequest;
    if (request == null) return null;
    final belongsToMessage = normalizeAssistantActivityTrace(
      metadata[assistantActivityTraceKey],
    ).any((step) => step['id']?.toString() == request.toolCallId);
    if (!belongsToMessage) return null;
    return _ConnectionCardBinding(
      toolCallId: request.toolCallId,
      card: ChatConnectionCard(
        request: request,
        canAct: _chat.canActOnConnection,
        onOpenLink: _openConnectionLink,
        onSkip: (name) =>
            _answerConnection(() => _chat.skipConnectionTarget(name)),
        onContinue: () => _answerConnection(_chat.continueConnection),
      ),
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
    // El turno vivo es la fila más nueva de su grupo de respuesta: las filas
    // ya cerradas del mismo turno siguen en ESTA burbuja, que crece en su
    // sitio en lugar de apilar otra cabecera.
    final groupRows = _olderResponseGroupRows(
      frame.metadata,
      liveHead: frame.isStreaming,
    );
    final metadata = groupRows.isEmpty
        ? frame.metadata
        : _responseGroupMetadata(frame.metadata, head: frame.metadata);
    final projection = _projectOperationalArtifacts(
      context,
      _joinResponseGroupText(
        _responseGroupTextPrefix(groupRows),
        frame.content,
      ),
    );
    final hasUnifiedActivity =
        normalizeAssistantActivityTrace(
          metadata[assistantActivityTraceKey],
        ).isNotEmpty ||
        (metadata['reasoning'] is String &&
            (metadata['reasoning'] as String).trim().isNotEmpty);
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
        mark: _AssistantMessageMark.cancelled,
        verbose: _devDiagnostics,
        metadata: frame.metadata,
        linkCache: _linkCache,
        fetchLinkPreview: _fetchLinkPreview,
        firstUrl: _firstUrl,
        agentName: _assistantName,
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
      metadata: metadata,
      linkCache: _linkCache,
      fetchLinkPreview: _fetchLinkPreview,
      firstUrl: _firstUrl,
      readAloud: _voice?.readAloud,
      readAloudStopBehavior:
          _voice?.settings.readAloudStopBehavior ??
          ReadAloudStopBehavior.pauseAndResume,
      agentName: _assistantName,
      isStreaming: frame.isStreaming,
      companionMood: frame.isStreaming ? _liveCompanionMood() : null,
      waitingForUser: frame.isStreaming && _turnWaitsForUser,
      connectionCard: _connectionCardFor(metadata),
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
          // El envoltorio ya anuncia [message] como etiqueta del aviso; solo el
          // cierre ([trailing]) queda como nodo accesible propio.
          ExcludeSemantics(child: Icon(icon, size: 18, color: iconColor)),
          const SizedBox(width: 10),
          Expanded(
            child: ExcludeSemantics(
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
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Cierre común de los avisos en flujo del chat: X con tooltip «Cerrar»,
/// área táctil de 48 dp y etiqueta accesible aunque el icono sea compacto.
class _ChatNoticeDismissButton extends StatelessWidget {
  const _ChatNoticeDismissButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = Strings.of(context).commonClose;
    // Nodo propio: sin `container` su etiqueta se fundiría con la del aviso.
    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      child: IconButton(
        onPressed: onPressed,
        tooltip: label,
        icon: const Icon(Icons.close_rounded),
        iconSize: 18,
        color: Theme.of(context).hermes.textSecondary,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    );
  }
}

class _DesktopAuthRequiredBanner extends StatelessWidget {
  const _DesktopAuthRequiredBanner({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      key: const ValueKey('chat-dashboard-auth-required'),
      container: true,
      liveRegion: true,
      label: message,
      child: _ChatNoticeSurface(
        icon: Icons.lock_outline_rounded,
        iconColor: colors.warning,
        message: message,
        trailing: _ChatNoticeDismissButton(
          key: const ValueKey('chat-dashboard-auth-dismiss'),
          onPressed: onDismiss,
        ),
      ),
    );
  }
}

/// Hermes reports the turn as waiting on the user but no question card is
/// on screen (the request frame died with a socket). Honest copy instead of
/// a busy spinner, plus an action that asks the server for the open request.
class _AwaitingUnseenInputNotice extends StatelessWidget {
  const _AwaitingUnseenInputNotice({
    required this.message,
    required this.actionLabel,
    required this.onShow,
    required this.onStop,
    this.busy = false,
    this.stopLabel,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onShow;
  final VoidCallback onStop;
  final bool busy;

  /// cq1215: set once a recovery came back empty, so the notice offers the
  /// existing interrupt next to Retry instead of a button that does nothing.
  final String? stopLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final style = TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: colors.accentText,
    );
    final show = TextButton(
      key: const ValueKey('chat-awaiting-unseen-input-show'),
      onPressed: busy ? null : onShow,
      style: style,
      child: Text(actionLabel),
    );
    final stop = stopLabel;
    return Semantics(
      key: const ValueKey('chat-awaiting-unseen-input'),
      container: true,
      liveRegion: true,
      label: message,
      child: _ChatNoticeSurface(
        icon: Icons.help_outline_rounded,
        iconColor: colors.warning,
        message: message,
        trailing: stop == null
            ? show
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  show,
                  TextButton(
                    key: const ValueKey('chat-awaiting-unseen-input-stop'),
                    onPressed: busy ? null : onStop,
                    style: style,
                    child: Text(stop),
                  ),
                ],
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
      child: _ChatNoticeSurface(
        icon: Icons.account_tree_outlined,
        iconColor: colors.warning,
        message: message,
        trailing: _ChatNoticeDismissButton(
          key: const ValueKey('core-read-partial-coverage-dismiss'),
          onPressed: onDismiss,
        ),
      ),
    );
  }
}

class _LocalTranscriptTruncationNotice extends StatelessWidget {
  const _LocalTranscriptTruncationNotice({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      key: const ValueKey('local-transcript-truncation-notice'),
      container: true,
      liveRegion: true,
      label: message,
      child: _ChatNoticeSurface(
        icon: Icons.history_toggle_off_rounded,
        iconColor: colors.warning,
        message: message,
        trailing: _ChatNoticeDismissButton(
          key: const ValueKey('local-transcript-truncation-dismiss'),
          onPressed: onDismiss,
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
                child: Text(strings.commonCancel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  minimumSize: const Size(0, 46),
                ),
                onPressed: () => _close(_controller.text.trim()),
                // Saving only rewrites the queued text; it stays in the queue.
                child: Text(strings.commonSave),
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

enum _BotChatHeaderAction { find, model, controls }

/// Cabecera del Bot Chat: avatar + nombre del bot + estado vivo, con el mismo
/// protagonismo que la cabecera de una Room. El modelo y los controles viven
/// en el overflow, siguiendo el patrón del plugin oficial Hermes Bot Mode.
String? _modelLabel(AgentProfile? profile) {
  final model = profile?.model.trim() ?? '';
  return model.isEmpty ? null : model;
}

class _BotChatAppBarTitle extends StatelessWidget {
  final AgentProfile? profile;
  final String fallbackName;
  final ChatActivityKind? activity;
  final MissionProfileAvatarCache? avatarCache;

  /// Model of this session as the regular chat header shows it; the profile
  /// default is only a fallback before the session reports one.
  final String? sessionModel;

  const _BotChatAppBarTitle({
    required this.profile,
    required this.fallbackName,
    required this.activity,
    required this.avatarCache,
    this.sessionModel,
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
          profile == null
              ? MissionProfileAvatar(
                  key: ValueKey('bot-chat-avatar-$name'),
                  profileName: name,
                  hasAvatar: false,
                  cache: avatarCache,
                  size: 32,
                )
              // The same living face as the roster: it breathes, blinks and
              // looks around; it reads a line while the bot works.
              : LivingBotFace(
                  key: ValueKey('bot-chat-avatar-$name'),
                  profileName: profile.name,
                  profile: profile,
                  avatarCache: avatarCache,
                  signal: switch (activity) {
                    ChatActivityKind.thinking => BotFaceSignal.thinking,
                    ChatActivityKind.usingTools => BotFaceSignal.working,
                    ChatActivityKind.responding => BotFaceSignal.speaking,
                    ChatActivityKind.awaitingApproval =>
                      BotFaceSignal.attention,
                    null => BotFaceSignal.idle,
                  },
                  size: 32,
                  entrance: false,
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
                    ?statusLabel ??
                        (sessionModel == null
                            ? _modelLabel(profile)
                            : friendlyModelName(sessionModel!)),
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

final class _SlashLookup {
  final DesktopCommandCatalog? catalog;
  final SlashCompletionBatch? completion;

  const _SlashLookup({this.catalog, this.completion});
}

class _SlashAccentTextEditingController extends TextEditingController {
  /// Server commands and skills this chat's gateway publishes; they get the
  /// same accent as local commands once the catalog or a completion names
  /// them.
  Set<String> remoteCommandNames = const <String>{};

  TextRange? slashCommandRange() {
    final known =
        parseSlashCommand(value.text) != null ||
        switch (parseSlashInvocation(value.text)) {
          final invocation? => remoteCommandNames.contains(invocation.name),
          null => false,
        };
    if (!known) return null;
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
    final slashRange = text.isEmpty ? null : slashCommandRange();
    // Complete `@file:`/`@folder:`/`@url:` references read as the same accent
    // token Desktop renders as a chip.
    final accentRanges = <TextRange>[
      ?slashRange,
      ...composerReferenceRanges(text),
    ];
    if (text.isEmpty || accentRanges.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final composing = composingRange(value, withComposing);
    final cuts = <int>{0, text.length};
    for (final range in accentRanges) {
      cuts
        ..add(range.start)
        ..add(range.end);
    }
    if (!composing.isCollapsed) {
      cuts
        ..add(composing.start)
        ..add(composing.end);
    }
    final orderedCuts = cuts.toList()..sort();
    final accent = Theme.of(context).hermes.accent;
    final spans = <InlineSpan>[];
    for (var index = 0; index < orderedCuts.length - 1; index++) {
      final start = orderedCuts[index];
      final end = orderedCuts[index + 1];
      if (start == end) continue;
      var segmentStyle = style;
      if (accentRanges.any(
        (range) => start >= range.start && end <= range.end,
      )) {
        segmentStyle = (segmentStyle ?? const TextStyle()).copyWith(
          color: accent,
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
    final firstSkill = commands.indexWhere((command) => command.isSkill);
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
              final row = _row(colors, command);
              if (!command.isSkill || i != firstSkill) return row;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    key: const ValueKey('chat-slash-skills-header'),
                    padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 14, 2),
                    child: Text(
                      Strings.of(ctx).t1215SlashSkillsHeader,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  row,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _row(HermesThemeColors colors, SlashCommand command) {
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
              child: command.isSkill
                  ? Icon(Icons.bolt_rounded, size: 18, color: colors.accent)
                  : Text(
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
  }
}

/// Welcome state shown when the session has no messages yet.
/// Terminal-style prompt with a blinking block cursor.
class _EmptyChatState extends StatelessWidget {
  final String model;
  final String agentName;
  final String? workspace;

  const _EmptyChatState({
    required this.model,
    this.agentName = 'hermes',
    this.workspace,
  });

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
              if (workspace case final folder?) ...[
                const SizedBox(height: 14),
                ConstrainedBox(
                  key: const ValueKey('pj1215-chat-workspace'),
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 14,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          Strings.of(
                            context,
                          ).pj1215ChatWorkspace(shortServerPath(folder)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
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
@visibleForTesting
class ChatErrorBubble extends StatefulWidget {
  final String error;
  final String prompt;
  final VoidCallback? onRetry;

  /// Acción opcional para reiniciar el gateway (se ofrece en errores de
  /// "agente colgado"/conexión, donde el servidor puede estar atascado).
  final VoidCallback? onRestartGateway;

  /// Abre una sesión nueva; se ofrece cuando la sesión ya no cabe en el
  /// contexto del modelo (reintentar repetiría el mismo fallo).
  final VoidCallback? onNewSession;

  /// The provider rejected its credential: the card names it and offers the
  /// fix (sign in again / check the key) before Retry, as Desktop does.
  final ProviderAuthFailure? authFailure;
  final VoidCallback? onReauth;

  /// What the gateway said failed (`error_surface`) and, for a provider out of
  /// credit, its `billing` block. With either, the card follows the recovery
  /// plan; without them it is the text-classified card of older servers.
  final TurnErrorSurface? surface;
  final TurnBillingBlock? billing;

  /// Recovery handlers the plan may offer; a null one is never painted.
  final VoidCallback? onCompress;
  final VoidCallback? onChooseModel;
  final VoidCallback? onEditMessage;
  final VoidCallback? onOpenBilling;

  /// Free-tier sign-in: only painted when [freeTierSignInAvailable] answers
  /// true (checked once, when the details open).
  final VoidCallback? onSignInFreeTier;
  final Future<bool> Function()? freeTierSignInAvailable;

  /// A usage-limit retry may be armed only while the failed turn is the last
  /// one; [retryScope] changing (another chat or profile) drops an armed retry.
  final bool canArmRetry;
  final Object? retryScope;

  /// What an armed retry runs when its time comes; defaults to [onRetry]. The
  /// screen guards it so it only resends the turn the card belongs to.
  final VoidCallback? onScheduledRetry;

  /// Clock and app version, replaceable in tests.
  final DateTime Function()? now;
  final String? composerProvider;
  final String? composerModel;
  final Future<String> Function()? appVersion;

  const ChatErrorBubble({
    super.key,
    required this.error,
    required this.prompt,
    required this.onRetry,
    this.onRestartGateway,
    this.onNewSession,
    this.authFailure,
    this.onReauth,
    this.surface,
    this.billing,
    this.onCompress,
    this.onChooseModel,
    this.onEditMessage,
    this.onOpenBilling,
    this.onSignInFreeTier,
    this.freeTierSignInAvailable,
    this.canArmRetry = false,
    this.retryScope,
    this.onScheduledRetry,
    this.now,
    this.composerProvider,
    this.composerModel,
    this.appVersion,
  });

  @override
  State<ChatErrorBubble> createState() => _ErrorBubbleState();
}

class _ErrorBubbleState extends State<ChatErrorBubble> {
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
    _ErrorKind.profileDashboardAccess => s.chaErrProfileDashboardAccess,
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
    _ErrorKind.profileDashboardAccess => null,
    _ErrorKind.unknown => null,
  };

  @override
  Widget build(BuildContext context) {
    // The gateway named what failed: the card follows its recovery plan. Older
    // servers send no surface and keep the text-classified card below.
    if (widget.surface != null || widget.billing != null) {
      return _PlannedErrorCard(bubble: widget);
    }
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final kind = _classifyError(widget.error);
    final authFailure = widget.authFailure;
    final summary = authFailure != null
        ? providerAuthBody(str, authFailure)
        : widget.error.length > 140
        ? '${widget.error.substring(0, 140)}…'
        : widget.error;
    final hasMore =
        authFailure != null ||
        widget.error.length > 140 ||
        widget.error.contains('\n');

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
                    Icon(
                      authFailure != null ? Icons.key_off_rounded : kind.icon,
                      size: 14,
                      color: colors.error,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        authFailure != null
                            ? providerAuthTitle(str, authFailure)
                            : _kindLabel(kind, str),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: colors.error,
                        ),
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
                if (authFailure == null &&
                    _kindHint(kind, str) != null &&
                    !_expanded) ...[
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
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    if (authFailure != null)
                      _ErrorBubbleAction(
                        key: const ValueKey('hr1215-error-reauth'),
                        label: providerAuthActionLabel(str, authFailure),
                        color: colors.error,
                        onTap: widget.onReauth,
                      ),
                    if (kind == _ErrorKind.sessionTooLarge &&
                        widget.onNewSession != null &&
                        authFailure == null)
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
                        authFailure == null &&
                        (kind == _ErrorKind.firstTokenTimeout ||
                            kind == _ErrorKind.connection))
                      _ErrorBubbleAction(
                        label: Strings.of(context).chaRestartGateway,
                        color: colors.error,
                        onTap: widget.onRestartGateway,
                      ),
                    if (hasMore)
                      _ErrorBubbleAction(
                        label: _expanded
                            ? Strings.of(context).chaErrHideDetails
                            : Strings.of(context).chaErrViewDetails,
                        color: colors.textSecondary,
                        outlined: false,
                        onTap: () => setState(() => _expanded = !_expanded),
                      ),
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

/// Error card driven by the gateway's `error_surface`: what failed, one
/// visible recovery action, the rest behind the details, the usage-limit reset
/// and "Copiar detalles".
class _PlannedErrorCard extends StatefulWidget {
  final ChatErrorBubble bubble;

  const _PlannedErrorCard({required this.bubble});

  @override
  State<_PlannedErrorCard> createState() => _PlannedErrorCardState();
}

/// Whether [a] and [b] show the same failed turn of the same chat/profile.
bool _sameFailure(ChatErrorBubble a, ChatErrorBubble b) =>
    a.retryScope == b.retryScope &&
    a.error == b.error &&
    a.prompt == b.prompt &&
    mapEquals(a.surface?.toJson(), b.surface?.toJson()) &&
    mapEquals(a.billing?.toJson(), b.billing?.toJson());

class _PlannedErrorCardState extends State<_PlannedErrorCard>
    with WidgetsBindingObserver {
  bool _expanded = false;

  /// The single armed retry of a usage limit. Local only: it never outlives
  /// the card, the failed turn, the chat/profile or the app in the foreground.
  Timer? _armTimer;
  Timer? _tickTimer;
  double? _armedResetsAt;

  /// `null` until the user opens the details of a free-tier failure.
  bool? _freeTierSignInOffered;
  bool _freeTierChecked = false;

  /// Bumped when this slot starts showing another failure, so the answer of a
  /// check started for the previous one is dropped.
  int _failureGeneration = 0;

  ChatErrorBubble get _bubble => widget.bubble;
  bool get _armed => _armTimer != null;
  DateTime _now() => (_bubble.now ?? DateTime.now)();

  TurnErrorSurface get _surface =>
      _bubble.surface ??
      const TurnErrorSurface(
        layer: 'billing',
        code: 'billing',
        retryable: false,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(_PlannedErrorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.bubble;
    if (!_sameFailure(old, _bubble)) {
      _failureGeneration++;
      _expanded = false;
      _freeTierChecked = false;
      _freeTierSignInOffered = null;
    }
    if (_armed &&
        (!_bubble.canArmRetry ||
            _bubble.retryScope != old.retryScope ||
            _bubble.surface?.resetsAt != old.surface?.resetsAt)) {
      _disarm();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _armed) _disarm();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _armTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  void _arm(double resetsAt, Duration delay) {
    _armTimer?.cancel();
    _tickTimer?.cancel();
    _armedResetsAt = resetsAt;
    _armTimer = Timer(delay, _fire);
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    setState(() {});
  }

  void _disarm() {
    _armTimer?.cancel();
    _tickTimer?.cancel();
    _armTimer = null;
    _tickTimer = null;
    _armedResetsAt = null;
    if (mounted) setState(() {});
  }

  /// Local one-second tick for the visible countdown; no network.
  void _tick() {
    if (!mounted) return;
    // A route over the chat (an opaque page) turns this subtree's tickers off.
    if (!TickerMode.valuesOf(context).enabled) {
      _disarm();
      return;
    }
    setState(() {});
  }

  void _fire() {
    if (!mounted || !_armed) return;
    final retry = _bubble.onScheduledRetry ?? _bubble.onRetry;
    final allowed = _bubble.canArmRetry && TickerMode.valuesOf(context).enabled;
    _disarm();
    if (allowed) retry?.call();
  }

  void _toggleDetails() {
    setState(() => _expanded = !_expanded);
    if (!_expanded || _freeTierChecked) return;
    final check = _bubble.freeTierSignInAvailable;
    if (!_surface.isFreeTier ||
        check == null ||
        _bubble.onSignInFreeTier == null) {
      return;
    }
    _freeTierChecked = true;
    final generation = _failureGeneration;
    check().then<void>(
      (offered) {
        if (mounted && generation == _failureGeneration) {
          setState(() => _freeTierSignInOffered = offered);
        }
      },
      onError: (Object _) {
        if (mounted && generation == _failureGeneration) {
          setState(() => _freeTierSignInOffered = false);
        }
      },
    );
  }

  Future<void> _copyDetails() async {
    final notices = HermesNotice.of(context);
    final copied = Strings.of(context).te1215DetailsCopied;
    String version;
    try {
      version = await (_bubble.appVersion ?? appVersionLabel)();
    } catch (_) {
      version = 'unknown';
    }
    final text = formatErrorDiagnostics(
      now: _now(),
      surface: _bubble.surface,
      composerProvider: _bubble.composerProvider,
      composerModel: _bubble.composerModel,
      appVersion: version,
      error: _bubble.error,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    notices.showSnackBar(
      SnackBar(content: Text(copied)),
      kind: HermesNoticeKind.success,
    );
  }

  /// The actions the plan allows and the screen can run, most relevant first.
  List<({String name, String label, VoidCallback onTap})> _actions(
    Strings s,
    ErrorRecoveryPlan plan,
  ) {
    final out = <({String name, String label, VoidCallback onTap})>[];
    final billing = _bubble.billing;
    final onBilling = _bubble.onOpenBilling;
    if (billing != null && onBilling != null) {
      out.add((
        name: 'billing',
        label: billing.isNous ? s.te1215BillingNous : s.te1215BillingLink,
        onTap: onBilling,
      ));
    }
    for (final action in errorRecoveryActions(plan)) {
      final VoidCallback? handler = switch (action) {
        ErrorRecoveryAction.signInAgain || ErrorRecoveryAction.updateApiKey =>
          _bubble.authFailure == null ? null : _bubble.onReauth,
        ErrorRecoveryAction.compress => _bubble.onCompress,
        ErrorRecoveryAction.chooseModel ||
        ErrorRecoveryAction.switchProvider => _bubble.onChooseModel,
        ErrorRecoveryAction.editMessage => _bubble.onEditMessage,
        ErrorRecoveryAction.retry => _bubble.onRetry,
        ErrorRecoveryAction.startNewSession => _bubble.onNewSession,
        ErrorRecoveryAction.signInFreeTier =>
          _freeTierSignInOffered == true ? _bubble.onSignInFreeTier : null,
      };
      // Choosing a model and switching provider open the same picker.
      if (handler == null ||
          out.any((entry) => identical(entry.onTap, handler))) {
        continue;
      }
      out.add((
        name: action.name,
        label: errorRecoveryActionLabel(s, action),
        onTap: handler,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final surface = _surface;
    final billing = _bubble.billing;
    final authFailure = _bubble.authFailure;
    final plan = errorRecoveryPlan(surface: surface, authFailure: authFailure);
    final copy = turnErrorCopy(s, surface);
    final title = billing != null
        ? s.te1215BillingTitle(billing.providerLabel)
        : authFailure != null
        ? providerAuthTitle(s, authFailure)
        : copy.title;
    final errorText = _bubble.error;
    final summary = billing != null
        ? billing.firstLine
        : authFailure != null
        ? providerAuthBody(s, authFailure)
        : surface.isFreeTier && surface.message != null
        ? surface.message!
        : copy.hint ??
              (errorText.length > 140
                  ? '${errorText.substring(0, 140)}…'
                  : errorText);

    final now = _now();
    final reset = plan.retry ? formatLimitReset(surface.resetsAt, now) : null;
    final delay = reset == null
        ? null
        : scheduledRetryDelay(surface.resetsAt, now);
    final canSchedule =
        delay != null && _bubble.canArmRetry && _bubble.onRetry != null;
    final armedReset = _armed ? formatLimitReset(_armedResetsAt, now) : null;

    final actions = _actions(s, plan);
    final primary = actions.isEmpty ? null : actions.first;
    final secondary = actions.skip(1).toList(growable: false);

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
                    Icon(
                      authFailure != null
                          ? Icons.key_off_rounded
                          : _classifyError(errorText).icon,
                      size: 14,
                      color: colors.error,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: colors.error,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _expanded ? errorText : summary,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: colors.error.withValues(alpha: 0.92),
                    fontFamily: _expanded ? 'monospace' : null,
                  ),
                ),
                if (reset != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    s.te1215ResetsAt(reset.clock, reset.remaining),
                    key: const ValueKey('te1215-error-resets'),
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
                if (armedReset != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    key: const ValueKey('te1215-error-armed'),
                    children: [
                      Flexible(
                        child: Text(
                          s.te1215RetryArmed(
                            armedReset.clock,
                            armedReset.remaining,
                          ),
                          style: TextStyle(fontSize: 11, color: colors.error),
                        ),
                      ),
                      _ErrorBubbleAction(
                        key: const ValueKey('te1215-error-cancel-arm'),
                        label: s.chaCancel,
                        color: colors.textSecondary,
                        outlined: false,
                        onTap: _disarm,
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    if (primary != null)
                      _ErrorBubbleAction(
                        // The sign-in / key action keeps the key it always had.
                        key: ValueKey(
                          primary.name ==
                                      ErrorRecoveryAction.signInAgain.name ||
                                  primary.name ==
                                      ErrorRecoveryAction.updateApiKey.name
                              ? 'hr1215-error-reauth'
                              : 'te1215-error-primary',
                        ),
                        label: primary.label,
                        color: colors.error,
                        onTap: primary.onTap,
                      ),
                    _ErrorBubbleAction(
                      key: const ValueKey('te1215-error-details-toggle'),
                      label: _expanded
                          ? s.chaErrHideDetails
                          : s.chaErrViewDetails,
                      color: colors.textSecondary,
                      outlined: false,
                      onTap: _toggleDetails,
                    ),
                  ],
                ),
                if (_expanded)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      for (final action in secondary)
                        _ErrorBubbleAction(
                          key: ValueKey(
                            action.name ==
                                        ErrorRecoveryAction.signInAgain.name ||
                                    action.name ==
                                        ErrorRecoveryAction.updateApiKey.name
                                ? 'hr1215-error-reauth'
                                : 'te1215-error-action-${action.name}',
                          ),
                          label: action.label,
                          color: colors.error,
                          onTap: action.onTap,
                        ),
                      if (canSchedule && !_armed && reset != null)
                        _ErrorBubbleAction(
                          key: const ValueKey('te1215-error-arm'),
                          label: s.te1215RetryAt(reset.clock),
                          color: colors.error,
                          onTap: () => _arm(surface.resetsAt!, delay),
                        ),
                      _ErrorBubbleAction(
                        key: const ValueKey('te1215-error-copy'),
                        label: s.te1215CopyDetails,
                        color: colors.textSecondary,
                        outlined: false,
                        onTap: () => unawaited(_copyDetails()),
                      ),
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
    super.key,
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
            // Shrink to the pill: inside the card's Wrap an unbounded Center
            // would take a whole line per action.
            widthFactor: 1,
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

/// Estado terminal que se marca bajo una respuesta. Se localiza al pintar;
/// nunca se muestra el identificador interno.
enum _AssistantMessageMark { cancelled }

/// Assistant message with a subtle status mark (e.g. "Cancelado").
class _AssistantMessageWithMark extends StatelessWidget {
  final String content;
  final _AssistantMessageMark mark;
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
    final strings = Strings.of(context);
    final markLabel = switch (mark) {
      _AssistantMessageMark.cancelled => strings.tg1215TurnCancelled,
    };
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
              markLabel,
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
  final String? editingDraft;
  final double? editingWidth;
  final bool editSaving;
  final int editingLaterTurns;
  final VoidCallback? onBranch;
  final VoidCallback? onCancelEdit;
  final ValueChanged<String>? onSaveEdit;
  final VoidCallback? onRegenerate;
  final AssistantSuggestionCallback? onSuggestionSelected;
  final _ConnectionCardBinding? connectionCard;
  final bool compact;
  final ChatPerformanceProbe? performanceProbe;
  final ToolOutputLookup? toolOutputs;
  final String Function()? latestReplyText;
  final bool showChangedFiles;

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
    this.editingDraft,
    this.editingWidth,
    this.editSaving = false,
    this.editingLaterTurns = 0,
    this.onBranch,
    this.onCancelEdit,
    this.onSaveEdit,
    this.onRegenerate,
    this.onSuggestionSelected,
    this.connectionCard,
    this.compact = false,
    this.performanceProbe,
    this.toolOutputs,
    this.latestReplyText,
    this.showChangedFiles = false,
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
            editingDraft: editingDraft,
            editingWidth: editingWidth,
            editSaving: editSaving,
            editingLaterTurns: editingLaterTurns,
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
            onBranch: onBranch,
            onSuggestionSelected: onSuggestionSelected,
            connectionCard: connectionCard,
            compact: compact,
            performanceProbe: performanceProbe,
            toolOutputs: toolOutputs,
            latestReplyText: latestReplyText,
            showChangedFiles: showChangedFiles,
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

  /// Server copy persisted by Hermes as an `@image:`/`@file:` line. Used when
  /// the private local copy is missing (reinstall, other device, eviction).
  final UserServerAttachmentRef? serverRef;
  const _ParsedAttachment(
    this.name,
    this.sizeLabel, {
    this.historyReference,
    this.imagePath,
    this.serverRef,
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

String? _jobChipLabel(String raw, Strings strings) {
  if (_kanbanWorkRe.hasMatch(raw)) return strings.i18n1215KanbanTask;
  final skill = _invokedSkillName(raw);
  if (skill != null) return strings.m1215SkillChip(skill);
  final t = raw.trimLeft();
  // Handoff de compactación sin mensaje real detrás → chip discreto.
  if (t.startsWith('[CONTEXT COMPACTION') &&
      _stripContextCompaction(raw).trim().isEmpty) {
    return strings.i18n1215PreviousContext;
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
    return strings.i18n1215ScheduledTask;
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
    case 'side_answer':
      // Local `/btw` or `/bg` answer: the header is the title, the answer the
      // body (the full Desktop-format line stays in `content` for copy/export).
      final rawMetadata = message['display_metadata'];
      final metadata = rawMetadata is Map ? rawMetadata : const {};
      final question = metadata['question'];
      final asked = question is String ? question.trim() : '';
      final answer = metadata['answer'];
      final taskId = message['_btwTaskId'];
      final isBackground = metadata['kind'] == 'bg';
      return (
        title: isBackground
            ? (taskId is String && taskId.isNotEmpty
                  ? strings.tc1215BgAnswerTitle(taskId)
                  : 'bg')
            : asked.isEmpty
            ? strings.tc1215BtwAnswerNoQuestion
            : strings.tc1215BtwAnswerTitle(asked),
        detail: answer is String
            ? answer
            : (message['content'] ?? '').toString(),
        icon: metadata['is_error'] == true
            ? Icons.error_outline_rounded
            : isBackground
            ? Icons.task_alt_rounded
            : Icons.chat_bubble_outline_rounded,
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

typedef _ParsedUserContent = ({
  List<_ParsedAttachment> attachments,
  String text,
});

/// Bounded memo: every rebuild of a user bubble re-reads its content, and the
/// transcript content of a row never changes in place.
final LinkedHashMap<String, _ParsedUserContent> _parsedUserContentMemo =
    LinkedHashMap<String, _ParsedUserContent>();
const int _parsedUserContentMemoLimit = 256;

_ParsedUserContent _parseUserContent(String raw) {
  final cached = _parsedUserContentMemo.remove(raw);
  if (cached != null) {
    _parsedUserContentMemo[raw] = cached;
    return cached;
  }
  final parsed = _parseUserContentUncached(raw);
  _parsedUserContentMemo[raw] = parsed;
  while (_parsedUserContentMemo.length > _parsedUserContentMemoLimit) {
    _parsedUserContentMemo.remove(_parsedUserContentMemo.keys.first);
  }
  return parsed;
}

bool _parsedAttachmentIsImage(_ParsedAttachment attachment) =>
    attachment.historyReference?.type == AttachmentType.image ||
    (attachment.historyReference == null &&
        attachmentKindFor(attachment.name, '') == AttachmentKind.image);

/// Pairs Hermes' `@image:`/`@file:` lines with the `[📎 …]` markers of the same
/// send (same kind, same order) so one attachment renders once; unmatched
/// lines become standalone chips.
List<_ParsedAttachment> _withServerRefs(
  List<_ParsedAttachment> attachments,
  List<UserServerAttachmentRef> serverRefs,
) {
  if (serverRefs.isEmpty) return attachments;
  final images = serverRefs.where((ref) => ref.isImage).toList();
  final files = serverRefs.where((ref) => !ref.isImage).toList();
  final paired = <_ParsedAttachment>[
    for (final attachment in attachments)
      switch (_parsedAttachmentIsImage(attachment) ? images : files) {
        final pool when pool.isNotEmpty => _ParsedAttachment(
          attachment.name,
          attachment.sizeLabel,
          historyReference: attachment.historyReference,
          imagePath: attachment.imagePath,
          serverRef: pool.removeAt(0),
        ),
        _ => attachment,
      },
  ];
  for (final ref in serverRefs) {
    if (images.contains(ref) || files.contains(ref)) {
      paired.add(_ParsedAttachment(ref.displayName, '', serverRef: ref));
    }
  }
  return List<_ParsedAttachment>.unmodifiable(paired);
}

_ParsedUserContent _parseUserContentUncached(String raw) {
  final parsed = _parseUserContentMarkers(raw);
  final serverRefs = parsed.serverRefs;
  if (serverRefs.isEmpty) {
    return (attachments: parsed.attachments, text: parsed.text);
  }
  var text = parsed.text.trim();
  // Native-vision turns flatten each image part to a `[screenshot]` line; the
  // lifted `@image:` ref already stands for it (Desktop drops it too).
  if (serverRefs.any((ref) => ref.isImage)) {
    text = text
        .split('\n')
        .where((line) => line.trim() != '[screenshot]')
        .join('\n')
        .trim();
  }
  return (
    attachments: _withServerRefs(parsed.attachments, serverRefs),
    text: text,
  );
}

({
  List<_ParsedAttachment> attachments,
  String text,
  List<UserServerAttachmentRef> serverRefs,
})
_parseUserContentMarkers(String raw) {
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
  final serverRefs = <UserServerAttachmentRef>[];
  final kept = <String>[];
  for (final l in raw.split('\n')) {
    final reference = AttachmentHistoryReference.tryParseMarker(l);
    if (reference != null) {
      historyReferences.putIfAbsent(reference.index, () => reference);
      continue;
    }
    final serverRef = UserServerAttachmentRef.tryParseLine(l);
    if (serverRef != null) {
      serverRefs.add(serverRef);
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
  if (lines.isEmpty) {
    return (attachments: const [], text: '', serverRefs: serverRefs);
  }

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
    return (
      attachments: const [],
      text: lines.join('\n'),
      serverRefs: serverRefs,
    );
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
  return (
    attachments: parsedAttachments,
    text: rest.join('\n').trim(),
    serverRefs: serverRefs,
  );
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
/// Aviso compacto de un proceso en segundo plano terminado. La cabecera
/// resume estado y código; la salida solo se muestra al desplegarla.
class _ProcessNotificationRow extends StatefulWidget {
  final BackgroundProcessCarrier carrier;
  final String raw;

  const _ProcessNotificationRow({required this.carrier, required this.raw});

  @override
  State<_ProcessNotificationRow> createState() =>
      _ProcessNotificationRowState();
}

class _ProcessNotificationRowState extends State<_ProcessNotificationRow> {
  bool _expanded = false;

  String _statusLabel(Strings strings) => switch (widget.carrier.status) {
    BackgroundProcessCarrierStatus.completed => strings.tg1215ProcessCompleted,
    BackgroundProcessCarrierStatus.exited =>
      widget.carrier.failed
          ? strings.tg1215ProcessExited
          : strings.tg1215ProcessCompleted,
    BackgroundProcessCarrierStatus.terminated =>
      strings.tg1215ProcessTerminated,
    BackgroundProcessCarrierStatus.lost => strings.tg1215ProcessLost,
    BackgroundProcessCarrierStatus.failedToStart =>
      strings.tg1215ProcessFailedToStart,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final strings = Strings.of(context);
    final carrier = widget.carrier;
    final title = [
      _statusLabel(strings),
      if (carrier.exitCode != '?')
        strings.tg1215ProcessExitCode(carrier.exitCode),
    ].join(' · ');
    // El comando y la salida pueden llevar rutas o prompts privados: solo se
    // construyen cuando la persona despliega el aviso.
    final output = carrier.output.trimRight();
    final details = [
      '\$ ${carrier.command}',
      output.isEmpty ? strings.tg1215ProcessNoOutput : output,
    ].join('\n\n');
    final failed = carrier.failed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: title,
            hint: _expanded
                ? strings.tg1215ProcessHideOutput
                : strings.tg1215ProcessShowOutput,
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: widget.raw));
                HermesNotice.of(context).showSnackBar(
                  SnackBar(
                    content: Text(strings.chaCopied),
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
                        Icons.terminal_rounded,
                        size: 16,
                        color: failed
                            ? colors.error.withValues(alpha: 0.8)
                            : colors.textSecondary.withValues(alpha: 0.72),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.textSecondary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: colors.textSecondary.withValues(alpha: 0.72),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Container(
              margin: const EdgeInsets.only(left: 28, top: 2, bottom: 6),
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.5),
                ),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  details,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.35,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

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

/// Last laid-out size of a user bubble, read when its edit button is tapped.
final class _BubbleSizeHolder {
  Size? size;
}

class _BubbleSizeReporter extends SingleChildRenderObjectWidget {
  const _BubbleSizeReporter({required this.holder, super.child});

  final _BubbleSizeHolder holder;

  @override
  _RenderBubbleSizeReporter createRenderObject(BuildContext context) =>
      _RenderBubbleSizeReporter(holder);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBubbleSizeReporter renderObject,
  ) {
    renderObject.holder = holder;
  }
}

class _RenderBubbleSizeReporter extends RenderProxyBox {
  _RenderBubbleSizeReporter(this._holder);

  _BubbleSizeHolder _holder;
  set holder(_BubbleSizeHolder value) {
    if (identical(value, _holder)) return;
    _holder = value;
    if (hasSize) value.size = size;
  }

  @override
  void performLayout() {
    super.performLayout();
    _holder.size = size;
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
  final String? editingDraft;
  final double? editingWidth;
  final bool editSaving;
  final int editingLaterTurns;
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
    this.editingDraft,
    this.editingWidth,
    this.editSaving = false,
    this.editingLaterTurns = 0,
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
              final serverRef = attachment.serverRef;
              final chatState = serverRef == null
                  ? null
                  : context.findAncestorStateOfType<_ChatScreenState>();
              if (serverRef != null && chatState != null) {
                return UserServerAttachmentCard(
                  name: attachment.name,
                  sizeLabel: attachment.sizeLabel,
                  localReference: historyReference,
                  serverRef: serverRef,
                  cacheScope: chatState.userServerMediaScope,
                  loader: chatState.downloadUserServerAttachment,
                );
              }
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
    // No GlobalKey here: a fresh key on every build remounted the inline
    // editor below it on each chat rebuild (streaming, presence, timers) and
    // wiped what the user was typing. The bubble reports its laid-out size
    // into a plain holder instead.
    final bubbleSize = _BubbleSizeHolder();

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
              child: _BubbleSizeReporter(
                holder: bubbleSize,
                child: Container(
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
                          draftText: editingDraft,
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
                                    openChatMarkdownLink(context, href),
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
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
            ),
            if (editing && editingLaterTurns > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  Strings.of(context).tc1215EditLaterTurns(editingLaterTurns),
                  key: const ValueKey('chat-edit-later-turns'),
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
            if (!editing)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onEdit != null)
                    IconButton(
                      onPressed: () {
                        final size = bubbleSize.size;
                        if (size != null) onEdit!(size.width);
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
                  if (timestamp != null) ChatMessageTimestamp(timestamp),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

List<ChatTraceEvent> _assistantActivityEvents(
  BuildContext context,
  Map<String, dynamic> metadata,
  String legacyReasoning, {
  ToolOutputLookup? toolOutputs,
}) {
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
        memory: MemoryWrite.fromStep(step[memoryWriteStepKey]),
        output: _settledToolOutput(step, label, toolOutputs),
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

typedef ToolOutputLookup = ToolOutputRecord? Function(String toolId);

/// Only a settled step of a tool that can leave a diff/terminal output asks
/// the lookup, so ordinary traces never touch the durable index.
ToolOutputRecord? _settledToolOutput(
  Map<String, dynamic> step,
  String label,
  ToolOutputLookup? lookup,
) {
  if (lookup == null || step['status'] == 'running') return null;
  if (!isFileEditToolName(label) && !terminalOutputToolNames.contains(label)) {
    return null;
  }
  final id = step['id'];
  return id is String && id.isNotEmpty ? lookup(id) : null;
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

const double _botMessageFaceSize = 34;

/// Bot Chat identity for descendants (assistant message headers): the bot
/// whose chat this is. Absent in normal chats.
class _BotChatIdentity extends InheritedWidget {
  const _BotChatIdentity({
    required this.profile,
    required this.avatarCache,
    required super.child,
  });

  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;

  static _BotChatIdentity? maybeOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_BotChatIdentity>();
    return scope?.profile == null ? null : scope;
  }

  @override
  bool updateShouldNotify(_BotChatIdentity oldWidget) =>
      !identical(profile, oldWidget.profile) ||
      avatarCache != oldWidget.avatarCache;
}

/// Cabecera de un mensaje del asistente: la mascota (o la inicial, sin
/// presencia) + título en acento + la segunda línea que pase el llamador.
/// Opens the "Branch from here" menu on a long-press of an assistant header,
/// outside the selectable text.
class _BranchLongPress extends StatelessWidget {
  const _BranchLongPress({required this.onLongPress, required this.child});

  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) => onLongPress == null
      ? child
      : GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: onLongPress,
          child: child,
        );
}

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
    Widget header(Widget? mascot) => ChatMessageHeader(
      name: name,
      avatar: mascot,
      subtitle: subtitle,
      actions: actions,
    );
    // Bot Chat: every assistant message wears the bot's own face (same as
    // the header and the roster), never the Hermes companion.
    final bot = _BotChatIdentity.maybeOf(context);
    if (bot != null) {
      final profile = bot.profile!;
      return ChatMessageHeader(
        name: name,
        nameColor: botIdentityColor(profile, avatarCache: bot.avatarCache),
        // Only the live turn moves; history keeps a static face so a long
        // Bot Chat never runs one ticker per message.
        avatar: animate
            ? LivingBotFace(
                key: ValueKey('assistant-header-bot-face-${profile.name}'),
                profileName: profile.name,
                profile: profile,
                avatarCache: bot.avatarCache,
                signal: BotFaceSignal.speaking,
                size: _botMessageFaceSize,
                entrance: false,
                expressiveness: 1.2,
              )
            : MissionProfileAvatar(
                key: ValueKey('assistant-header-bot-face-${profile.name}'),
                profileName: profile.name,
                hasAvatar: profile.botPaintsPhoto,
                cache: bot.avatarCache,
                size: _botMessageFaceSize,
                shape: profile.botFaceShape,
                colorHex: profile.botColorHex,
                imageKind: profile.botImageKind,
              ),
        subtitle: subtitle,
        actions: actions,
      );
    }
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

final class _ConnectionCardBinding {
  final String toolCallId;
  final Widget card;

  const _ConnectionCardBinding({required this.toolCallId, required this.card});
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
  final VoidCallback? onBranch;
  final AssistantSuggestionCallback? onSuggestionSelected;
  final _ConnectionCardBinding? connectionCard;
  final bool compact;
  final ChatPerformanceProbe? performanceProbe;
  final ToolOutputLookup? toolOutputs;

  /// The turn's newest reply alone, when earlier replies share this bubble
  /// (Desktop «copy message» vs «copy full response»). Read at copy time.
  final String Function()? latestReplyText;

  /// Close the turn with its «N files changed» card (Desktop shows it only
  /// on the newest settled reply).
  final bool showChangedFiles;

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
    this.onBranch,
    this.onSuggestionSelected,
    this.connectionCard,
    this.compact = false,
    this.performanceProbe,
    this.toolOutputs,
    this.latestReplyText,
    this.showChangedFiles = false,
  });

  static final RegExp _markdownSyntax = RegExp(r'[`*#\[_|>~]');

  /// Cheap gate for the long-press menu: an earlier reply in the bubble or
  /// any Markdown syntax, indented code blocks included. The scopes
  /// themselves are built on long press.
  bool _hasCopyScopes(String answer) =>
      latestReplyText != null ||
      _markdownSyntax.hasMatch(answer) ||
      markdownMayHaveCodeBlock(answer);

  /// Long-press copy scopes; only those that differ from a plain copy and
  /// have data are offered (no dead entries).
  List<ChatCopyScope> _copyScopes(BuildContext context, String answer) {
    final s = Strings.of(context);
    final raw = trimMarkdownBlankLines(
      GeneratedMediaService.stripDirectives(answer),
    );
    if (raw.isEmpty) return const [];
    final plain = markdownToClipboardText(raw);
    final latest = latestReplyText;
    final code = markdownCodeBlocks(raw);
    return [
      if (latest != null) ...[
        ChatCopyScope(
          label: s.tc1215CopyLatest,
          icon: Icons.short_text_rounded,
          text: () => markdownToClipboardText(
            GeneratedMediaService.stripDirectives(latest()),
          ),
        ),
        ChatCopyScope(
          label: s.tc1215CopyFull,
          icon: Icons.copy_all_rounded,
          text: () => plain,
        ),
      ] else
        ChatCopyScope(
          label: s.chaCopyMessage,
          icon: Icons.copy_rounded,
          text: () => plain,
        ),
      if (raw != plain)
        ChatCopyScope(
          label: s.tc1215CopyMarkdown,
          icon: Icons.notes_rounded,
          text: () => raw,
        ),
      if (code.isNotEmpty)
        ChatCopyScope(
          label: s.tc1215CopyCode(code.length),
          icon: Icons.code_rounded,
          text: () => code.join('\n\n'),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
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
      toolOutputs: toolOutputs,
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
    final changedFiles =
        showChangedFiles && showFooter && !headerAnimated && !stopped
        ? aggregateChangedFiles(activityEvents.map((event) => event.output))
        : const <FileDiff>[];
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
    Widget markdownWidget(String data) =>
        ChatMarkdownBlock(data: data, embeds: !isStreaming);

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
                onLinkTap: (href) => openChatMarkdownLink(context, href),
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
              onLinkTap: (href) => openChatMarkdownLink(context, href),
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
            onLinkTap: (href) => openChatMarkdownLink(context, href),
          );
        }
      }
      for (final ref in structuredFooterImages) {
        yield _GeneratedImageSlot(key: ref.widgetKey, reference: ref);
      }
      yield* structuredVideoWidgets();
    }

    Widget? branchable(Widget? header) => header == null
        ? null
        : _BranchLongPress(onLongPress: onBranch, child: header);

    // La copia completa vive en la cabecera y la selección parcial en la región
    // exterior. El Markdown permanece como texto normal: ningún párrafo crea un
    // EditableText que pueda mover el scroll al mostrar sus tiradores.
    List<Widget> headerActions() => [
      if (onSpeak != null && readAloudMessageKey != null) ...[
        const SizedBox(width: 6),
        ReadAloudButton(
          messageKey: readAloudMessageKey!,
          state: readAloud,
          stopBehavior: readAloudStopBehavior,
          onPressed: onSpeak,
        ),
      ],
      ChatCopyMessageButton(
        text: () => markdownToClipboardText(
          GeneratedMediaService.stripDirectives(answer),
        ),
        scopes: isStreaming || !_hasCopyScopes(answer)
            ? null
            : () => _copyScopes(context, answer),
      ),
      if (onRegenerate != null)
        ChatMessageActionButton(
          icon: Icons.refresh_rounded,
          label: Strings.of(context).chaRegenerate,
          onPressed: onRegenerate,
        ),
    ];

    // La copia completa vive en la cabecera y la selección parcial en la región
    // exterior. El Markdown permanece como texto normal: ningún párrafo crea un
    // EditableText que pueda mover el scroll al mostrar sus tiradores.
    return ChatMessageFrame(
      selectable: !isStreaming,
      selectionIdentity: metadata['message_id'] ?? metadata['id'] ?? metadata,
      padding: EdgeInsets.only(
        left: 12,
        right: 16,
        top: showHeader ? (compact ? 5 : 11) : 0,
        bottom: showFooter ? (compact ? 1 : 3) : 0,
      ),
      time: showFooter ? timestamp : null,
      header: branchable(
        !showHeader
            ? null
            : showTrace
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
                rowAttachments: connectionCard == null
                    ? const {}
                    : {connectionCard!.toolCallId: connectionCard!.card},
                headerBuilder: (context, summary, details) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AssistantAvatarHeader(
                      name: agentName,
                      mood: headerMood,
                      animate: headerAnimated,
                      subtitle: summary,
                      actions: headerActions(),
                    ),
                    details,
                  ],
                ),
              )
            : _AssistantAvatarHeader(
                name: agentName,
                mood: headerMood,
                animate: headerAnimated,
                actions: headerActions(),
              ),
      ),
      children: [
        if (showHeader && metaLines.isNotEmpty)
          _MetaBlock(lines: metaLines, onDark: false),
        if (answer.isNotEmpty) ...answerWidgets(),
        if (changedFiles.isNotEmpty) ChangedFilesCard(files: changedFiles),
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
      ],
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
      // In-app viewer: HTML/SVG in a locked WebView, Markdown/code/text and
      // images natively; anything else falls back to "Abrir con…"/Share.
      await openArtifactViewer(
        context,
        name: widget.reference.displayName,
        mimeType: widget.reference.mimeType,
        file: file,
        sizeBytes: length,
        onOpenExternal: onOpenExternal,
        onShare: onShare,
        onSave: onSave,
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
      // The lazy transcript disposes rows that scroll far away; this lets a
      // returning card (e.g. an HTML preview) come back ready, not reload.
      readyMemoKey: state.generatedMediaCacheScope,
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

List<String> _buildMetaLines(bool verbose, Map<String, dynamic> metadata) {
  if (!verbose) return const [];
  final role = metadata['role']?.toString().trim();
  return ['role: ${role == null || role.isEmpty ? 'unknown' : role}'];
}

String? _formatMessageTimestamp(Map<String, dynamic> metadata) =>
    formatChatMessageTime(
      metadata['created_at'] ?? metadata['timestamp'] ?? metadata['createdAt'],
    );

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
  final bool retryExhausted;
  final List<String> attachmentNames;
  final bool busy;
  final bool transportCanSteer;
  final String? editingId;
  final VoidCallback onEdit;
  final VoidCallback onSteer;
  final VoidCallback onSendNow;
  final VoidCallback onDelete;
  final VoidCallback onAbandon;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool>? onMove;

  const _QueuedRow({
    required this.entry,
    this.canMoveUp = false,
    this.canMoveDown = false,
    this.onMove,
    this.retryExhausted = false,
    this.attachmentNames = const [],
    required this.busy,
    required this.transportCanSteer,
    required this.editingId,
    required this.onEdit,
    required this.onSteer,
    required this.onSendNow,
    required this.onDelete,
    required this.onAbandon,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final canMove = onMove != null && (canMoveUp || canMoveDown);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: canMove
          ? () async {
              final up = await showHermesMenu<bool>(
                context: context,
                surfaceKey: ValueKey('chat-queue-menu-${entry.id}'),
                actions: [
                  if (canMoveUp)
                    HermesAction<bool>(
                      key: ValueKey('chat-queue-move-up-${entry.id}'),
                      value: true,
                      label: strings.tc1215QueueMoveUp,
                      icon: Icons.arrow_upward_rounded,
                    ),
                  if (canMoveDown)
                    HermesAction<bool>(
                      key: ValueKey('chat-queue-move-down-${entry.id}'),
                      value: false,
                      label: strings.tc1215QueueMoveDown,
                      icon: Icons.arrow_downward_rounded,
                    ),
                ],
              );
              if (up != null) onMove!(up);
            }
          : null,
      child: _buildRow(context),
    );
  }

  Widget _buildRow(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final preview = entry.text.length > 72
        ? '${entry.text.substring(0, 72)}…'
        : entry.text;
    final isEditing = editingId == entry.id;
    // Already on the server: edit/send/delete cannot act (and send-now would
    // cancel the running turn), so the row shows them disabled.
    final accepted =
        entry.kind == QueuedEntryKind.desktopAccepted || entry.serverAccepted;
    final editEnabled =
        !accepted && !entry.sending && (editingId == null || isEditing);
    final canSteer =
        busy &&
        transportCanSteer &&
        entry.isSteerable &&
        !isEditing &&
        !accepted;
    final sendLabel = busy
        ? strings.tc1215QueueStopAndSend
        : strings.chaQueueSend;
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
                if (entry.sending)
                  Text(
                    strings.tc1215QueueSending,
                    key: ValueKey('chat-queue-sending-${entry.id}'),
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colors.textDisabled,
                    ),
                  )
                else if (entry.deliveryUnknown)
                  Text(
                    Strings.of(context).chatQueueDeliveryUnknown,
                    key: ValueKey('chat-queue-unknown-${entry.id}'),
                    style: TextStyle(fontSize: 10.5, color: colors.warning),
                  )
                else if (entry.stopWaitingAvailable)
                  // Acknowledged in an earlier run; "retry" would promise an
                  // action this row does not have.
                  Text(
                    strings.q1215QueueAcceptedStale,
                    key: ValueKey('chat-queue-accepted-stale-${entry.id}'),
                    style: TextStyle(fontSize: 10.5, color: colors.warning),
                  )
                else if (entry.missingAttachment)
                  Text(
                    strings.q1215QueueMissingAttachment,
                    key: ValueKey('chat-queue-missing-attachment-${entry.id}'),
                    style: TextStyle(fontSize: 10.5, color: colors.warning),
                  )
                else if (entry.persistenceFailed)
                  Text(
                    strings.qp1215QueueNotStored,
                    key: ValueKey('chat-queue-not-stored-${entry.id}'),
                    style: TextStyle(fontSize: 10.5, color: colors.warning),
                  )
                else if (retryExhausted)
                  // qr1215: never silently stuck. Retrying is the same
                  // exactly-once send as the row's send action.
                  Semantics(
                    button: true,
                    excludeSemantics: true,
                    label: strings.qr1215QueueRetryExhausted,
                    onTap: isEditing ? null : onSendNow,
                    child: InkWell(
                      key: ValueKey('chat-queue-retry-exhausted-${entry.id}'),
                      onTap: isEditing ? null : onSendNow,
                      child: Text(
                        strings.qr1215QueueRetryExhausted,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: colors.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                else if (entry.blocked)
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
          if (entry.deliveryUnknown || entry.stopWaitingAvailable)
            // Edit/send/delete cannot act on a message that may already be
            // on the server; the one honest action is to stop waiting.
            action(
              keyName: 'chat-queue-abandon-${entry.id}',
              label: strings.chatQueueAbandon,
              icon: Icons.remove_circle_outline_rounded,
              onPressed: onAbandon,
            )
          else ...[
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
              onPressed: isEditing || accepted || entry.sending
                  ? null
                  : onSendNow,
            ),
            action(
              keyName: 'chat-queue-delete-${entry.id}',
              label: strings.chaQueueDelete,
              icon: Icons.delete_outline_rounded,
              onPressed: accepted ? null : onDelete,
            ),
          ],
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
  final ValueListenable<int> newMessages;
  const _ScrollToBottomButton({
    required this.onTap,
    required this.newMessages,
    super.key,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: newMessages,
    builder: (context, count, _) {
      final strings = Strings.of(context);
      final newLabel = count > 0 ? strings.sc1215NewMessages(count) : null;
      return _ChatScrollButton(
        onTap: onTap,
        label: newLabel == null
            ? strings.chaScrollToBottom
            : '${strings.chaScrollToBottom}, $newLabel',
        icon: Icons.keyboard_arrow_down,
        iconSize: 20,
        badge: newLabel,
      );
    },
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

  /// Short text shown next to the circle (e.g. "3 new"); the button keeps its
  /// 48 dp height so the transcript padding never changes with it.
  final String? badge;

  const _ChatScrollButton({
    super.key,
    required this.onTap,
    required this.label,
    required this.icon,
    this.iconSize = 18,
    this.loading = false,
    this.badge,
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
            width: badge == null ? 48 : null,
            height: 48,
            child: Center(
              widthFactor: 1,
              child: Container(
                width: badge == null ? 32 : null,
                height: 32,
                padding: badge == null
                    ? null
                    : const EdgeInsetsDirectional.only(start: 12, end: 8),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  shape: badge == null ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: badge == null
                      ? null
                      : BorderRadius.circular(16),
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
                    : badge == null
                    ? Icon(icon, size: iconSize, color: colors.accent)
                    : ExcludeSemantics(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              badge!,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colors.accent,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(icon, size: iconSize, color: colors.accent),
                          ],
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
    // Past an edge (the bounce region) the reader is AT that edge, not reading
    // a row above it: every correction below would clamp the overscroll to
    // the extent in one frame and the spring would snap instead of settling.
    // Keep the inherited (bouncing) position; the ballistic activity started
    // on release brings it back smoothly. Pending deltas are dropped because
    // they describe growth the reader is already riding with the edge.
    if (oldPosition.outOfRange) {
      lock.clear();
      return inherited;
    }
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
            markdown: (d) => ChatMarkdownBlock(data: d, embeds: !isStreaming),
            callout: (b) =>
                CalloutCard(kind: b.kind, title: b.title, body: b.body),
            onLinkTap: (href) => openChatMarkdownLink(context, href),
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
    this.onDismissError,
    this.cachedLabel,
    super.key,
  });

  final bool loading;
  final String? errorMessage;

  /// cs1215: the rows shown are the encrypted cold-start copy, not yet
  /// confirmed by the server.
  final String? cachedLabel;
  final Widget child;

  /// Con valor, el aviso de error muestra una X para cerrarlo.
  final VoidCallback? onDismissError;

  /// Distancia del aviso de error al borde superior del transcript. El chat la
  /// sube para dejar libre el botón «cargar anteriores» cuando está a la vista.
  final double errorTopInset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (cachedLabel != null)
          Positioned(
            // Below the error notice when both show: the copy is still the
            // unconfirmed cache whatever the read did.
            top: errorTopInset + (errorMessage == null ? 0 : 52),
            left: 12,
            right: 12,
            child: Center(
              child: Semantics(
                key: const ValueKey('chat-cached-transcript'),
                container: true,
                liveRegion: true,
                label: cachedLabel,
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colors.divider.withValues(alpha: 0.78),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.history,
                            size: 14,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            cachedLabel!,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
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
                container: true,
                liveRegion: true,
                label: errorMessage,
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
                    padding: EdgeInsets.fromLTRB(
                      12,
                      onDismissError == null ? 8 : 0,
                      onDismissError == null ? 12 : 0,
                      onDismissError == null ? 8 : 0,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(
                          child: Icon(
                            Icons.error_outline_rounded,
                            size: 16,
                            color: colors.error,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: ExcludeSemantics(
                            child: Text(
                              errorMessage!,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        if (onDismissError != null)
                          _ChatNoticeDismissButton(
                            key: const ValueKey('chat-refresh-error-dismiss'),
                            onPressed: onDismissError!,
                          ),
                      ],
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
