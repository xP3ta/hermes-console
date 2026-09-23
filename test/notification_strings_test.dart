import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotifL10n', () {
    test('es=true devuelve español; es=false inglés (sin idioma mezclado)', () {
      const es = NotifL10n(true);
      const en = NotifL10n(false);
      expect(es.approvalTitle, 'Hermes necesita tu atención');
      expect(en.approvalTitle, 'Hermes needs your attention');
      expect(es.runCompleted, 'Ejecución completada');
      expect(en.runCompleted, 'Run completed');
      expect(es.cronCompleted, 'Cron completado');
      expect(en.cronFailed, 'Cron failed');
      expect(es.actOpen, 'Abrir');
      expect(en.actOpen, 'Open');
      expect(es.privateTitle, 'Nueva actividad en Hermes');
      expect(en.privateBody, 'Open the app to view the details.');
      expect(es.voiceCardListening, 'Escuchando');
      expect(en.voiceCardListening, 'Listening');
      expect(es.voiceCardPaused, 'En pausa');
      expect(en.voiceCardPaused, 'Paused');
      expect(es.voiceCardWaitingApproval, 'Necesita aprobación');
      expect(en.voiceCardWaitingApproval, 'Needs approval');
      expect(es.voiceCardMicActive, 'Micrófono activo');
      expect(en.voiceCardMicActive, 'Microphone active');
      expect(es.voiceCardMicPaused, 'Micrófono pausado');
      expect(en.voiceCardMicPaused, 'Microphone paused');
      expect(es.voiceCardOrbDescription, 'Estado de voz de Hermes');
      expect(en.voiceCardOrbDescription, 'Hermes voice status');
      expect(es.voiceCardDurationDescription, 'Duración de la conversación');
      expect(en.voiceCardDurationDescription, 'Conversation duration');
      expect(es.voiceOpenHintActive, 'Sigue hablando · toca para abrir Hermes');
      expect(en.voiceOpenHintPaused, 'Tap Continue or tap to open Hermes');
      expect(es.voiceOpenHintApproval, 'Pulsa Revisar para aprobar en Hermes');
      expect(es.voicePause, 'Pausar');
      expect(en.voicePause, 'Pause');
      expect(es.voiceContinue, 'Continuar');
      expect(en.voiceContinue, 'Continue');
      expect(es.voiceReviewApproval, 'Revisar');
      expect(en.voiceReviewApproval, 'Review');
      expect(es.voiceEnd, 'Terminar');
      expect(en.voiceEnd, 'End');
      expect(es.voiceEndConversation, 'Terminar conversación');
      expect(en.voiceEndConversation, 'End conversation');
    });

    test('todos los canales tienen nombre y descripción localizados', () {
      const es = NotifL10n(true);
      const en = NotifL10n(false);
      // Transferencias y operaciones locales ya no son literales en inglés
      // fijos: siguen el idioma de la app como el resto de canales.
      expect(es.chTransfers, 'Transferencias');
      expect(en.chTransfers, 'Transfers');
      expect(es.chOperations, 'Operaciones locales');
      expect(en.chOperations, 'Local operations');
      for (final t in [es, en]) {
        for (final text in [
          t.chApprovals,
          t.chApprovalsDesc,
          t.chReplies,
          t.chRepliesDesc,
          t.chRuns,
          t.chRunsDesc,
          t.chTransfers,
          t.chTransfersDesc,
          t.chOperations,
          t.chOperationsDesc,
          t.chVoice,
          t.chVoiceDesc,
          t.bgChannel,
          t.bgChannelDesc,
        ]) {
          expect(text.trim(), isNotEmpty);
        }
      }
      expect(es.chOperationsDesc, isNot(en.chOperationsDesc));
    });

    test('el resumen del grupo cuenta los avisos activos', () {
      const es = NotifL10n(true);
      const en = NotifL10n(false);
      expect(es.groupSummaryCount(3), '3 avisos recientes');
      expect(en.groupSummaryCount(3), '3 recent alerts');
    });

    test('replyTitle nombra la sesión cuando se conoce', () {
      const es = NotifL10n(true);
      const en = NotifL10n(false);
      expect(es.replyTitle('Backup'), 'Hermes respondió en Backup');
      expect(es.replyTitle(null), 'Hermes respondió');
      expect(es.replyTitle('  '), 'Hermes respondió');
      expect(es.replyReadyBody, 'Respuesta lista. Toca para abrir.');
      expect(en.replyReadyBody, 'Reply ready. Tap to open.');
    });

    test('of() resuelve el idioma desde app_locale', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'es'});
      expect(NotifL10n.of(await SharedPreferences.getInstance()).es, isTrue);
      SharedPreferences.setMockInitialValues({'app_locale': 'en'});
      expect(NotifL10n.of(await SharedPreferences.getInstance()).es, isFalse);
    });
  });
}
