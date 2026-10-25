// Notification copy is available in background isolates without BuildContext.
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

import 'strings/notif_es.dart';
import 'strings/notif_en.dart';
import 'strings/notif_pt.dart';
import 'strings/notif_de.dart';
import 'strings/notif_fr.dart';
import 'strings/notif_it.dart';
import 'strings/notif_ja.dart';
import 'strings/notif_ko.dart';
import 'strings/notif_zh.dart';

const Map<String, Map<String, String>> notificationCatalogs = {
  'es': notifEs,
  'en': notifEn,
  'pt': notifPt,
  'de': notifDe,
  'fr': notifFr,
  'it': notifIt,
  'ja': notifJa,
  'ko': notifKo,
  'zh': notifZh,
};

/// Shared language resolution for background copy and context-free callers.
String resolveNotificationLang(String? preference, {Locale? deviceLocale}) {
  final code = preference == null || preference == 'system'
      ? (deviceLocale ?? PlatformDispatcher.instance.locale).languageCode
      : preference;
  final lang = code.toLowerCase().split(RegExp('[-_]')).first;
  return notificationCatalogs.containsKey(lang) ? lang : 'en';
}

/// Substitute once so user-provided braces never become another argument.
String notificationMessage(
  String lang,
  String key, {
  Map<String, Object> args = const {},
  Map<String, String>? translations,
}) {
  final text = (translations ?? notificationCatalogs[lang])?[key] ??
      notificationCatalogs['en']![key]!;
  return text.replaceAllMapped(RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}'),
      (match) => args[match.group(1)]?.toString() ?? match.group(0)!);
}

class NotifL10n {
  final String lang;

  /// Accept historical boolean callers, including the optional Portuguese flag.
  const NotifL10n(Object language, [bool portuguese = false])
      : lang = portuguese || language == 'pt' ? 'pt'
          : language == true || language == 'es' ? 'es'
          : language == 'de' ? 'de'
          : language == 'fr' ? 'fr'
          : language == 'it' ? 'it'
          : language == 'ja' ? 'ja'
          : language == 'ko' ? 'ko'
          : language == 'zh' ? 'zh'
          : 'en';

  bool get es => lang == 'es';
  bool get pt => lang == 'pt';

  factory NotifL10n.of(SharedPreferences prefs, {Locale? deviceLocale}) =>
      NotifL10n(resolveNotificationLang(prefs.getString('app_locale'),
          deviceLocale: deviceLocale));

  String message(String key, [Map<String, Object> args = const {}]) =>
      notificationMessage(lang, key, args: args);

  // ── Marca / genéricos ─────────────────────────────────────────────────────
  String get brand => message('brand');
  String get privateTitle =>
      message('privateTitle');
  String get privateBody =>
      message('privateBody');

  /// Resumen del grupo con el número real de avisos activos (más concreto que
  /// "varios" y estable a la vista en la bandeja).
  String groupSummaryCount(int n) =>
      message('groupSummaryCount', {'n': n});

  // ── Canales (nombre + descripción) ────────────────────────────────────────
  String get chApprovals => message('chApprovals');
  String get chApprovalsDesc => message('chApprovalsDesc');
  String get chReplies => message('chReplies');
  String get chRepliesDesc => message('chRepliesDesc');
  String get chRuns => message('chRuns');
  String get chRunsDesc => message('chRunsDesc');
  String get chTransfers => message('chTransfers');
  String get chTransfersDesc => message('chTransfersDesc');
  String get chVoice => message('chVoice');
  String get chVoiceDesc => message('chVoiceDesc');
  String get chOperations =>
      message('chOperations');
  String get chOperationsDesc => message('chOperationsDesc');

  // ── Aprobaciones ──────────────────────────────────────────────────────────
  String get approvalTitle => message('approvalTitle');
  String approvalBody(String tool, String where) => message('approvalBody');

  // ── Ejecuciones ───────────────────────────────────────────────────────────
  String get runCompleted => message('runCompleted');
  String get runFailed => message('runFailed');

  // ── Actividad en otra superficie (Desktop / otra Console / TUI) ──────────
  String get sessionActivityFinishedTitle => message('sessionActivityFinishedTitle');
  String get sessionActivityFailedTitle => message('sessionActivityFailedTitle');
  String get sessionActivityInterruptedTitle => message('sessionActivityInterruptedTitle');
  String get sessionActivityBody => message('sessionActivityBody');

  // ── Tarea en segundo plano (prompt.background / background.complete) ─────
  String get backgroundTaskFinishedTitle => message('backgroundTaskFinishedTitle');
  String get backgroundTaskFailedTitle => message('backgroundTaskFailedTitle');
  String get backgroundTaskBody => message('backgroundTaskBody');
  String get cronCompleted => message('cronCompleted');
  String get cronFailed => message('cronFailed');
  String get kanbanCompleted =>
      message('kanbanCompleted');
  String get kanbanBlocked =>
      message('kanbanBlocked');
  String get kanbanNeedsAttention => message('kanbanNeedsAttention');
  String get kanbanUpdated =>
      message('kanbanUpdated');
  String get kanbanCrashed => message('kanbanCrashed');
  String get kanbanTimedOut => message('kanbanTimedOut');
  String get kanbanGaveUp =>
      message('kanbanGaveUp');
  String get kanbanBlockLoop => message('kanbanBlockLoop');

  // ── Standing goals ────────────────────────────────────────────────────────
  String get goalDone =>
      message('goalDone');
  String get goalPaused => message('goalPaused');
  String get goalBlocked =>
      message('goalBlocked');
  String get goalWaiting =>
      message('goalWaiting');
  String goalBody(String title) =>
      title.isEmpty ? message('goalBody') : title;

  // ── Respuestas ────────────────────────────────────────────────────────────
  String replyTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) {
      return message('replyTitle');
    }
    return message('replyTitle2', {'s': s});
  }

  String get replyReadyBody => message('replyReadyBody');

  String replyFailedTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) {
      return message('replyFailedTitle');
    }
    return message('replyFailedTitle2', {'s': s});
  }

  String get replyFailedBody => message('replyFailedBody');

  // ── Agente local ──────────────────────────────────────────────────────────
  String get localInstalled => message('localInstalled');
  String get localInstallError => message('localInstallError');
  String get localInstalledBody => message('localInstalledBody');
  String get localInstallErrorBody => message('localInstallErrorBody');
  String get localRemoved => message('localRemoved');
  String get localRemoveError => message('localRemoveError');
  String get localRemovedBody => message('localRemovedBody');
  String get localRemoveErrorBody => message('localRemoveErrorBody');

  // ── Prueba ────────────────────────────────────────────────────────────────
  String get testTitle => message('testTitle');
  String get testBody => message('testBody');

  // ── Acciones ──────────────────────────────────────────────────────────────
  String get actOpen => message('actOpen');

  // ── Servicio en segundo plano (foreground service) ────────────────────────
  String get bgChannel => message('bgChannel');
  String get bgChannelDesc => message('bgChannelDesc');
  String get bgActive => message('bgActive');

  /// The fixed card while Console stays connected with the app closed.
  String get bgConnected => message('bgConnected');
  String get bgStop => message('bgStop');

  // ── Modo voz (estados) ────────────────────────────────────────────────────
  String get voiceTitle => message('voiceTitle');
  String get vListening => message('vListening');
  String get vTranscribing => message('vTranscribing');
  String get vThinking => message('vThinking');
  String get vTool => message('vTool');
  String get vWaitingApproval => message('vWaitingApproval');
  String get vSpeaking => message('vSpeaking');
  String get vError => message('vError');
  String get voiceActive => message('voiceActive');
  String get voicePaused => message('voicePaused');
  String get voiceWaitingApproval => message('voiceWaitingApproval');
  String get voiceOpenHintActive => message('voiceOpenHintActive');
  String get voiceOpenHintPaused => message('voiceOpenHintPaused');
  String get voiceOpenHintApproval => message('voiceOpenHintApproval');
  String get voiceCardListening =>
      message('voiceCardListening');
  String get voiceCardPaused => message('voiceCardPaused');
  String get voiceCardWaitingApproval => message('voiceCardWaitingApproval');
  String get voiceCardMicActive => message('voiceCardMicActive');
  String get voiceCardMicPaused => message('voiceCardMicPaused');
  String get voiceCardOrbDescription => message('voiceCardOrbDescription');
  String get voiceCardDurationDescription => message('voiceCardDurationDescription');
  String get voicePause => message('voicePause');
  String get voiceContinue => message('voiceContinue');
  String get voiceReviewApproval => message('voiceReviewApproval');
  String get voiceEnd => message('voiceEnd');
  String get voiceEndConversation => message('voiceEndConversation');
  String get readAloudPlaying => message('readAloudPlaying');
  String get readAloudPaused => message('readAloudPaused');

  /// Fallback para el nombre de la herramienta en curso cuando el servidor
  /// no envió una etiqueta legible (NotifL10n está disponible sin contexto).
  String get tool => message('tool');
}
