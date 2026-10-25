import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131DetailReadOnly',
    'i18n131DetailObjective',
    'i18n131DetailResult',
    'i18n131DetailLatestSummary',
    'i18n131DetailDiagnostics',
    'i18n131DetailDependencies',
    'i18n131DetailParents',
    'i18n131DetailChildren',
    'i18n131DetailBlockedBy',
    'i18n131DetailBlocks',
    'i18n131DetailChildResults',
    'i18n131DetailComments',
    'i18n131DetailNoComments',
    'i18n131DetailSomeone',
    'i18n131DetailAddComment',
    'i18n131DetailMessageWorker',
    'i18n131DetailSend',
    'i18n131DetailAttachments',
    'i18n131DetailNoAttachments',
    'i18n131DetailUploadAttachment',
    'i18n131DetailDownload',
    'i18n131DetailDeleteAttachment',
    'i18n131DetailRuns',
    'i18n131DetailRun',
    'i18n131DetailInspect',
    'i18n131DetailTerminate',
    'i18n131DetailLog',
    'i18n131DetailActivity',
    'i18n131DetailShowAll',
    'i18n131DetailShowLess',
    'i18n131DetailOperations',
    'i18n131DetailModel',
    'i18n131DetailInheritModel',
    'i18n131DetailReassign',
    'i18n131DetailReclaim',
    'i18n131DetailSpecify',
    'i18n131DetailDecompose',
    'i18n131DetailNotifyWhenDone',
    'i18n131DetailMuteNotifications',
    'i18n131DetailMuteNotificationsSub'
  };
  Map<String, int> arguments(String value) {
    final result = <String, int>{};
    for (final match in RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}').allMatches(value)) {
      result.update(match.group(0)!, (n) => n + 1, ifAbsent: () => 1);
    }
    return result;
  }
  final catalogs = <String, Map<String, dynamic>>{
    for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'])
      lang: jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
          as Map<String, dynamic>,
  };
  test('exact class keys and placeholder multiplicity in all nine locales', () {
    for (final catalog in catalogs.values) {
      expect(catalog.keys.where((key) => key.startsWith('i18n131Detail')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131DetailReadOnly, "Esta instancia está en modo solo lectura.");
    expect(lookupStrings(const Locale('en')).i18n131DetailReadOnly, "This instance is read-only.");
    expect(lookupStrings(const Locale('pt')).i18n131DetailReadOnly, "Esta instância está em modo somente leitura.");
    expect(lookupStrings(const Locale('de')).i18n131DetailReadOnly, "Diese Instanz ist schreibgeschützt.");
    expect(lookupStrings(const Locale('fr')).i18n131DetailReadOnly, "Cette instance est en lecture seule.");
    expect(lookupStrings(const Locale('it')).i18n131DetailReadOnly, "Questa istanza è in sola lettura.");
    expect(lookupStrings(const Locale('ja')).i18n131DetailReadOnly, "このインスタンスは読み取り専用です。");
    expect(lookupStrings(const Locale('ko')).i18n131DetailReadOnly, "이 인스턴스는 읽기 전용입니다.");
    expect(lookupStrings(const Locale('zh')).i18n131DetailReadOnly, "此实例为只读模式。");
    expect(lookupStrings(const Locale('es')).i18n131DetailObjective, "Objetivo · leer completo");
    expect(lookupStrings(const Locale('en')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('pt')).i18n131DetailObjective, "Objetivo · ler tudo");
    expect(lookupStrings(const Locale('de')).i18n131DetailObjective, "Ziel · alles lesen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailObjective, "Objectif · tout lire");
    expect(lookupStrings(const Locale('it')).i18n131DetailObjective, "Obiettivo · leggi tutto");
    expect(lookupStrings(const Locale('ja')).i18n131DetailObjective, "目的・全文表示");
    expect(lookupStrings(const Locale('ko')).i18n131DetailObjective, "목표 · 전체 보기");
    expect(lookupStrings(const Locale('zh')).i18n131DetailObjective, "目标 · 查看全文");
    expect(lookupStrings(const Locale('es')).i18n131DetailResult, "Resultado");
    expect(lookupStrings(const Locale('en')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('pt')).i18n131DetailResult, "Resultado");
    expect(lookupStrings(const Locale('de')).i18n131DetailResult, "Ergebnis");
    expect(lookupStrings(const Locale('fr')).i18n131DetailResult, "Résultat");
    expect(lookupStrings(const Locale('it')).i18n131DetailResult, "Risultato");
    expect(lookupStrings(const Locale('ja')).i18n131DetailResult, "結果");
    expect(lookupStrings(const Locale('ko')).i18n131DetailResult, "결과");
    expect(lookupStrings(const Locale('zh')).i18n131DetailResult, "结果");
    expect(lookupStrings(const Locale('es')).i18n131DetailLatestSummary, "Último resumen");
    expect(lookupStrings(const Locale('en')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('pt')).i18n131DetailLatestSummary, "Último resumo");
    expect(lookupStrings(const Locale('de')).i18n131DetailLatestSummary, "Neueste Zusammenfassung");
    expect(lookupStrings(const Locale('fr')).i18n131DetailLatestSummary, "Dernier résumé");
    expect(lookupStrings(const Locale('it')).i18n131DetailLatestSummary, "Ultimo riepilogo");
    expect(lookupStrings(const Locale('ja')).i18n131DetailLatestSummary, "最新の要約");
    expect(lookupStrings(const Locale('ko')).i18n131DetailLatestSummary, "최근 요약");
    expect(lookupStrings(const Locale('zh')).i18n131DetailLatestSummary, "最新摘要");
    expect(lookupStrings(const Locale('es')).i18n131DetailDiagnostics, "Diagnósticos");
    expect(lookupStrings(const Locale('en')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDiagnostics, "Diagnósticos");
    expect(lookupStrings(const Locale('de')).i18n131DetailDiagnostics, "Diagnose");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('it')).i18n131DetailDiagnostics, "Diagnostica");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDiagnostics, "診断");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDiagnostics, "진단");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDiagnostics, "诊断");
    expect(lookupStrings(const Locale('es')).i18n131DetailDependencies, "Dependencias");
    expect(lookupStrings(const Locale('en')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDependencies, "Dependências");
    expect(lookupStrings(const Locale('de')).i18n131DetailDependencies, "Abhängigkeiten");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDependencies, "Dépendances");
    expect(lookupStrings(const Locale('it')).i18n131DetailDependencies, "Dipendenze");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDependencies, "依存関係");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDependencies, "의존 관계");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDependencies, "依赖关系");
    expect(lookupStrings(const Locale('es')).i18n131DetailParents, "Depende de");
    expect(lookupStrings(const Locale('en')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('pt')).i18n131DetailParents, "Depende de");
    expect(lookupStrings(const Locale('de')).i18n131DetailParents, "Hängt ab von");
    expect(lookupStrings(const Locale('fr')).i18n131DetailParents, "Dépend de");
    expect(lookupStrings(const Locale('it')).i18n131DetailParents, "Dipende da");
    expect(lookupStrings(const Locale('ja')).i18n131DetailParents, "依存先");
    expect(lookupStrings(const Locale('ko')).i18n131DetailParents, "선행 작업");
    expect(lookupStrings(const Locale('zh')).i18n131DetailParents, "依赖任务");
    expect(lookupStrings(const Locale('es')).i18n131DetailChildren, "Desbloquea");
    expect(lookupStrings(const Locale('en')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('pt')).i18n131DetailChildren, "Desbloqueia");
    expect(lookupStrings(const Locale('de')).i18n131DetailChildren, "Gibt frei");
    expect(lookupStrings(const Locale('fr')).i18n131DetailChildren, "Débloque");
    expect(lookupStrings(const Locale('it')).i18n131DetailChildren, "Sblocca");
    expect(lookupStrings(const Locale('ja')).i18n131DetailChildren, "完了すると進められるタスク");
    expect(lookupStrings(const Locale('ko')).i18n131DetailChildren, "후속 작업");
    expect(lookupStrings(const Locale('zh')).i18n131DetailChildren, "可解锁的任务");
    expect(lookupStrings(const Locale('es')).i18n131DetailBlockedBy, "Bloqueada por");
    expect(lookupStrings(const Locale('en')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('pt')).i18n131DetailBlockedBy, "Bloqueada por");
    expect(lookupStrings(const Locale('de')).i18n131DetailBlockedBy, "Blockiert durch");
    expect(lookupStrings(const Locale('fr')).i18n131DetailBlockedBy, "Bloqué par");
    expect(lookupStrings(const Locale('it')).i18n131DetailBlockedBy, "Bloccata da");
    expect(lookupStrings(const Locale('ja')).i18n131DetailBlockedBy, "進行を妨げているタスク");
    expect(lookupStrings(const Locale('ko')).i18n131DetailBlockedBy, "진행을 막는 작업");
    expect(lookupStrings(const Locale('zh')).i18n131DetailBlockedBy, "受阻于");
    expect(lookupStrings(const Locale('es')).i18n131DetailBlocks, "Bloquea");
    expect(lookupStrings(const Locale('en')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('pt')).i18n131DetailBlocks, "Bloqueia");
    expect(lookupStrings(const Locale('de')).i18n131DetailBlocks, "Blockiert");
    expect(lookupStrings(const Locale('fr')).i18n131DetailBlocks, "Bloque");
    expect(lookupStrings(const Locale('it')).i18n131DetailBlocks, "Blocca");
    expect(lookupStrings(const Locale('ja')).i18n131DetailBlocks, "進行を妨げている先");
    expect(lookupStrings(const Locale('ko')).i18n131DetailBlocks, "진행을 막고 있는 작업");
    expect(lookupStrings(const Locale('zh')).i18n131DetailBlocks, "阻塞的任务");
    expect(lookupStrings(const Locale('es')).i18n131DetailChildResults, "Subtareas");
    expect(lookupStrings(const Locale('en')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('pt')).i18n131DetailChildResults, "Subtarefas");
    expect(lookupStrings(const Locale('de')).i18n131DetailChildResults, "Teilaufgaben");
    expect(lookupStrings(const Locale('fr')).i18n131DetailChildResults, "Sous-tâches");
    expect(lookupStrings(const Locale('it')).i18n131DetailChildResults, "Sottoattività");
    expect(lookupStrings(const Locale('ja')).i18n131DetailChildResults, "子タスク");
    expect(lookupStrings(const Locale('ko')).i18n131DetailChildResults, "하위 작업");
    expect(lookupStrings(const Locale('zh')).i18n131DetailChildResults, "子任务");
    expect(lookupStrings(const Locale('es')).i18n131DetailComments, "Comentarios");
    expect(lookupStrings(const Locale('en')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('pt')).i18n131DetailComments, "Comentários");
    expect(lookupStrings(const Locale('de')).i18n131DetailComments, "Kommentare");
    expect(lookupStrings(const Locale('fr')).i18n131DetailComments, "Commentaires");
    expect(lookupStrings(const Locale('it')).i18n131DetailComments, "Commenti");
    expect(lookupStrings(const Locale('ja')).i18n131DetailComments, "コメント");
    expect(lookupStrings(const Locale('ko')).i18n131DetailComments, "댓글");
    expect(lookupStrings(const Locale('zh')).i18n131DetailComments, "评论");
    expect(lookupStrings(const Locale('es')).i18n131DetailNoComments, "Todavía no hay comentarios.");
    expect(lookupStrings(const Locale('en')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('pt')).i18n131DetailNoComments, "Ainda não há comentários.");
    expect(lookupStrings(const Locale('de')).i18n131DetailNoComments, "Noch keine Kommentare.");
    expect(lookupStrings(const Locale('fr')).i18n131DetailNoComments, "Aucun commentaire pour le moment.");
    expect(lookupStrings(const Locale('it')).i18n131DetailNoComments, "Nessun commento presente.");
    expect(lookupStrings(const Locale('ja')).i18n131DetailNoComments, "コメントはまだありません。");
    expect(lookupStrings(const Locale('ko')).i18n131DetailNoComments, "아직 댓글이 없습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131DetailNoComments, "暂无评论。");
    expect(lookupStrings(const Locale('es')).i18n131DetailSomeone, "Alguien");
    expect(lookupStrings(const Locale('en')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('pt')).i18n131DetailSomeone, "Alguém");
    expect(lookupStrings(const Locale('de')).i18n131DetailSomeone, "Jemand");
    expect(lookupStrings(const Locale('fr')).i18n131DetailSomeone, "Quelqu’un");
    expect(lookupStrings(const Locale('it')).i18n131DetailSomeone, "Qualcuno");
    expect(lookupStrings(const Locale('ja')).i18n131DetailSomeone, "誰か");
    expect(lookupStrings(const Locale('ko')).i18n131DetailSomeone, "누군가");
    expect(lookupStrings(const Locale('zh')).i18n131DetailSomeone, "有人");
    expect(lookupStrings(const Locale('es')).i18n131DetailAddComment, "Añadir comentario");
    expect(lookupStrings(const Locale('en')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('pt')).i18n131DetailAddComment, "Adicionar comentário");
    expect(lookupStrings(const Locale('de')).i18n131DetailAddComment, "Kommentar hinzufügen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailAddComment, "Ajouter un commentaire");
    expect(lookupStrings(const Locale('it')).i18n131DetailAddComment, "Aggiungi un commento");
    expect(lookupStrings(const Locale('ja')).i18n131DetailAddComment, "コメントを追加");
    expect(lookupStrings(const Locale('ko')).i18n131DetailAddComment, "댓글 추가");
    expect(lookupStrings(const Locale('zh')).i18n131DetailAddComment, "添加评论");
    expect(lookupStrings(const Locale('es')).i18n131DetailMessageWorker, "Enviar una nota al worker");
    expect(lookupStrings(const Locale('en')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('pt')).i18n131DetailMessageWorker, "Enviar uma nota ao worker");
    expect(lookupStrings(const Locale('de')).i18n131DetailMessageWorker, "Dem Worker schreiben");
    expect(lookupStrings(const Locale('fr')).i18n131DetailMessageWorker, "Envoyer un message à l’exécutant");
    expect(lookupStrings(const Locale('it')).i18n131DetailMessageWorker, "Invia un messaggio al processo di lavoro");
    expect(lookupStrings(const Locale('ja')).i18n131DetailMessageWorker, "ワーカーにメッセージ");
    expect(lookupStrings(const Locale('ko')).i18n131DetailMessageWorker, "워커에게 메시지 보내기");
    expect(lookupStrings(const Locale('zh')).i18n131DetailMessageWorker, "向执行进程发送消息");
    expect(lookupStrings(const Locale('es')).i18n131DetailSend, "Enviar");
    expect(lookupStrings(const Locale('en')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('pt')).i18n131DetailSend, "Enviar");
    expect(lookupStrings(const Locale('de')).i18n131DetailSend, "Senden");
    expect(lookupStrings(const Locale('fr')).i18n131DetailSend, "Envoyer");
    expect(lookupStrings(const Locale('it')).i18n131DetailSend, "Invia");
    expect(lookupStrings(const Locale('ja')).i18n131DetailSend, "送信");
    expect(lookupStrings(const Locale('ko')).i18n131DetailSend, "보내기");
    expect(lookupStrings(const Locale('zh')).i18n131DetailSend, "发送");
    expect(lookupStrings(const Locale('es')).i18n131DetailAttachments, "Adjuntos");
    expect(lookupStrings(const Locale('en')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('pt')).i18n131DetailAttachments, "Anexos");
    expect(lookupStrings(const Locale('de')).i18n131DetailAttachments, "Anhänge");
    expect(lookupStrings(const Locale('fr')).i18n131DetailAttachments, "Pièces jointes");
    expect(lookupStrings(const Locale('it')).i18n131DetailAttachments, "Allegati");
    expect(lookupStrings(const Locale('ja')).i18n131DetailAttachments, "添付ファイル");
    expect(lookupStrings(const Locale('ko')).i18n131DetailAttachments, "첨부 파일");
    expect(lookupStrings(const Locale('zh')).i18n131DetailAttachments, "附件");
    expect(lookupStrings(const Locale('es')).i18n131DetailNoAttachments, "No hay adjuntos.");
    expect(lookupStrings(const Locale('en')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('pt')).i18n131DetailNoAttachments, "Não há anexos.");
    expect(lookupStrings(const Locale('de')).i18n131DetailNoAttachments, "Keine Anhänge.");
    expect(lookupStrings(const Locale('fr')).i18n131DetailNoAttachments, "Aucune pièce jointe.");
    expect(lookupStrings(const Locale('it')).i18n131DetailNoAttachments, "Nessun allegato.");
    expect(lookupStrings(const Locale('ja')).i18n131DetailNoAttachments, "添付ファイルはありません。");
    expect(lookupStrings(const Locale('ko')).i18n131DetailNoAttachments, "첨부 파일이 없습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131DetailNoAttachments, "暂无附件。");
    expect(lookupStrings(const Locale('es')).i18n131DetailUploadAttachment, "Subir adjunto");
    expect(lookupStrings(const Locale('en')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('pt')).i18n131DetailUploadAttachment, "Enviar anexo");
    expect(lookupStrings(const Locale('de')).i18n131DetailUploadAttachment, "Anhang hochladen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailUploadAttachment, "Envoyer une pièce jointe");
    expect(lookupStrings(const Locale('it')).i18n131DetailUploadAttachment, "Carica allegato");
    expect(lookupStrings(const Locale('ja')).i18n131DetailUploadAttachment, "添付ファイルをアップロード");
    expect(lookupStrings(const Locale('ko')).i18n131DetailUploadAttachment, "첨부 파일 업로드");
    expect(lookupStrings(const Locale('zh')).i18n131DetailUploadAttachment, "上传附件");
    expect(lookupStrings(const Locale('es')).i18n131DetailDownload, "Descargar");
    expect(lookupStrings(const Locale('en')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDownload, "Baixar");
    expect(lookupStrings(const Locale('de')).i18n131DetailDownload, "Herunterladen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDownload, "Télécharger");
    expect(lookupStrings(const Locale('it')).i18n131DetailDownload, "Scarica");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDownload, "ダウンロード");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDownload, "다운로드");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDownload, "下载");
    expect(lookupStrings(const Locale('es')).i18n131DetailDeleteAttachment, "Eliminar adjunto");
    expect(lookupStrings(const Locale('en')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDeleteAttachment, "Excluir anexo");
    expect(lookupStrings(const Locale('de')).i18n131DetailDeleteAttachment, "Anhang löschen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDeleteAttachment, "Supprimer la pièce jointe");
    expect(lookupStrings(const Locale('it')).i18n131DetailDeleteAttachment, "Elimina allegato");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDeleteAttachment, "添付ファイルを削除");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDeleteAttachment, "첨부 파일 삭제");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDeleteAttachment, "删除附件");
    expect(lookupStrings(const Locale('es')).i18n131DetailRuns, "Ejecuciones");
    expect(lookupStrings(const Locale('en')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('pt')).i18n131DetailRuns, "Execuções");
    expect(lookupStrings(const Locale('de')).i18n131DetailRuns, "Ausführungen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailRuns, "Exécutions");
    expect(lookupStrings(const Locale('it')).i18n131DetailRuns, "Esecuzioni");
    expect(lookupStrings(const Locale('ja')).i18n131DetailRuns, "実行履歴");
    expect(lookupStrings(const Locale('ko')).i18n131DetailRuns, "실행 내역");
    expect(lookupStrings(const Locale('zh')).i18n131DetailRuns, "运行记录");
    expect(lookupStrings(const Locale('es')).i18n131DetailRun, "Ejecución");
    expect(lookupStrings(const Locale('en')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('pt')).i18n131DetailRun, "Execução");
    expect(lookupStrings(const Locale('de')).i18n131DetailRun, "Ausführung");
    expect(lookupStrings(const Locale('fr')).i18n131DetailRun, "Exécution");
    expect(lookupStrings(const Locale('it')).i18n131DetailRun, "Esecuzione");
    expect(lookupStrings(const Locale('ja')).i18n131DetailRun, "実行");
    expect(lookupStrings(const Locale('ko')).i18n131DetailRun, "실행");
    expect(lookupStrings(const Locale('zh')).i18n131DetailRun, "运行");
    expect(lookupStrings(const Locale('es')).i18n131DetailInspect, "Inspeccionar");
    expect(lookupStrings(const Locale('en')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('pt')).i18n131DetailInspect, "Inspecionar");
    expect(lookupStrings(const Locale('de')).i18n131DetailInspect, "Prüfen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailInspect, "Inspecter");
    expect(lookupStrings(const Locale('it')).i18n131DetailInspect, "Ispeziona");
    expect(lookupStrings(const Locale('ja')).i18n131DetailInspect, "確認");
    expect(lookupStrings(const Locale('ko')).i18n131DetailInspect, "점검");
    expect(lookupStrings(const Locale('zh')).i18n131DetailInspect, "检查");
    expect(lookupStrings(const Locale('es')).i18n131DetailTerminate, "Terminar ejecución");
    expect(lookupStrings(const Locale('en')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('pt')).i18n131DetailTerminate, "Encerrar execução");
    expect(lookupStrings(const Locale('de')).i18n131DetailTerminate, "Ausführung beenden");
    expect(lookupStrings(const Locale('fr')).i18n131DetailTerminate, "Arrêter l’exécution");
    expect(lookupStrings(const Locale('it')).i18n131DetailTerminate, "Termina esecuzione");
    expect(lookupStrings(const Locale('ja')).i18n131DetailTerminate, "実行を停止");
    expect(lookupStrings(const Locale('ko')).i18n131DetailTerminate, "실행 종료");
    expect(lookupStrings(const Locale('zh')).i18n131DetailTerminate, "终止运行");
    expect(lookupStrings(const Locale('es')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('en')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('pt')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('de')).i18n131DetailLog, "Protokoll");
    expect(lookupStrings(const Locale('fr')).i18n131DetailLog, "Journal");
    expect(lookupStrings(const Locale('it')).i18n131DetailLog, "Registro");
    expect(lookupStrings(const Locale('ja')).i18n131DetailLog, "ログ");
    expect(lookupStrings(const Locale('ko')).i18n131DetailLog, "로그");
    expect(lookupStrings(const Locale('zh')).i18n131DetailLog, "日志");
    expect(lookupStrings(const Locale('es')).i18n131DetailActivity, "Actividad");
    expect(lookupStrings(const Locale('en')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('pt')).i18n131DetailActivity, "Atividade");
    expect(lookupStrings(const Locale('de')).i18n131DetailActivity, "Aktivität");
    expect(lookupStrings(const Locale('fr')).i18n131DetailActivity, "Activité");
    expect(lookupStrings(const Locale('it')).i18n131DetailActivity, "Attività recenti");
    expect(lookupStrings(const Locale('ja')).i18n131DetailActivity, "アクティビティ");
    expect(lookupStrings(const Locale('ko')).i18n131DetailActivity, "활동");
    expect(lookupStrings(const Locale('zh')).i18n131DetailActivity, "动态");
    expect(lookupStrings(const Locale('es')).i18n131DetailShowAll, "Mostrar toda");
    expect(lookupStrings(const Locale('en')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('pt')).i18n131DetailShowAll, "Mostrar tudo");
    expect(lookupStrings(const Locale('de')).i18n131DetailShowAll, "Alle anzeigen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailShowAll, "Tout afficher");
    expect(lookupStrings(const Locale('it')).i18n131DetailShowAll, "Mostra tutto");
    expect(lookupStrings(const Locale('ja')).i18n131DetailShowAll, "すべて表示");
    expect(lookupStrings(const Locale('ko')).i18n131DetailShowAll, "모두 보기");
    expect(lookupStrings(const Locale('zh')).i18n131DetailShowAll, "显示全部");
    expect(lookupStrings(const Locale('es')).i18n131DetailShowLess, "Mostrar menos");
    expect(lookupStrings(const Locale('en')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('pt')).i18n131DetailShowLess, "Mostrar menos");
    expect(lookupStrings(const Locale('de')).i18n131DetailShowLess, "Weniger anzeigen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailShowLess, "Afficher moins");
    expect(lookupStrings(const Locale('it')).i18n131DetailShowLess, "Mostra meno");
    expect(lookupStrings(const Locale('ja')).i18n131DetailShowLess, "表示を減らす");
    expect(lookupStrings(const Locale('ko')).i18n131DetailShowLess, "간략히 보기");
    expect(lookupStrings(const Locale('zh')).i18n131DetailShowLess, "收起");
    expect(lookupStrings(const Locale('es')).i18n131DetailOperations, "Operaciones");
    expect(lookupStrings(const Locale('en')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('pt')).i18n131DetailOperations, "Operações");
    expect(lookupStrings(const Locale('de')).i18n131DetailOperations, "Aktionen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailOperations, "Opérations");
    expect(lookupStrings(const Locale('it')).i18n131DetailOperations, "Operazioni");
    expect(lookupStrings(const Locale('ja')).i18n131DetailOperations, "操作");
    expect(lookupStrings(const Locale('ko')).i18n131DetailOperations, "작업 관리");
    expect(lookupStrings(const Locale('zh')).i18n131DetailOperations, "操作");
    expect(lookupStrings(const Locale('es')).i18n131DetailModel, "Modelo de esta tarea");
    expect(lookupStrings(const Locale('en')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('pt')).i18n131DetailModel, "Modelo desta tarefa");
    expect(lookupStrings(const Locale('de')).i18n131DetailModel, "Aufgabenmodell");
    expect(lookupStrings(const Locale('fr')).i18n131DetailModel, "Modèle de la tâche");
    expect(lookupStrings(const Locale('it')).i18n131DetailModel, "Modello dell’attività");
    expect(lookupStrings(const Locale('ja')).i18n131DetailModel, "タスクのモデル");
    expect(lookupStrings(const Locale('ko')).i18n131DetailModel, "작업 모델");
    expect(lookupStrings(const Locale('zh')).i18n131DetailModel, "任务模型");
    expect(lookupStrings(const Locale('es')).i18n131DetailInheritModel, "Heredar del perfil");
    expect(lookupStrings(const Locale('en')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('pt')).i18n131DetailInheritModel, "Herdar do perfil");
    expect(lookupStrings(const Locale('de')).i18n131DetailInheritModel, "Vom Profil übernehmen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailInheritModel, "Hériter du profil");
    expect(lookupStrings(const Locale('it')).i18n131DetailInheritModel, "Eredita dal profilo");
    expect(lookupStrings(const Locale('ja')).i18n131DetailInheritModel, "プロフィールから継承");
    expect(lookupStrings(const Locale('ko')).i18n131DetailInheritModel, "프로필에서 상속");
    expect(lookupStrings(const Locale('zh')).i18n131DetailInheritModel, "继承配置档");
    expect(lookupStrings(const Locale('es')).i18n131DetailReassign, "Reasignar");
    expect(lookupStrings(const Locale('en')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('pt')).i18n131DetailReassign, "Reatribuir");
    expect(lookupStrings(const Locale('de')).i18n131DetailReassign, "Neu zuweisen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailReassign, "Réattribuer");
    expect(lookupStrings(const Locale('it')).i18n131DetailReassign, "Riassegna");
    expect(lookupStrings(const Locale('ja')).i18n131DetailReassign, "再割り当て");
    expect(lookupStrings(const Locale('ko')).i18n131DetailReassign, "재배정");
    expect(lookupStrings(const Locale('zh')).i18n131DetailReassign, "重新分配");
    expect(lookupStrings(const Locale('es')).i18n131DetailReclaim, "Recuperar y reencolar");
    expect(lookupStrings(const Locale('en')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('pt')).i18n131DetailReclaim, "Recuperar e reenfileirar");
    expect(lookupStrings(const Locale('de')).i18n131DetailReclaim, "Zurückholen und erneut einreihen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailReclaim, "Récupérer et remettre en file d’attente");
    expect(lookupStrings(const Locale('it')).i18n131DetailReclaim, "Recupera e rimetti in coda");
    expect(lookupStrings(const Locale('ja')).i18n131DetailReclaim, "回収してキューに戻す");
    expect(lookupStrings(const Locale('ko')).i18n131DetailReclaim, "회수 후 대기열에 추가");
    expect(lookupStrings(const Locale('zh')).i18n131DetailReclaim, "回收并重新入队");
    expect(lookupStrings(const Locale('es')).i18n131DetailSpecify, "Especificar");
    expect(lookupStrings(const Locale('en')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('pt')).i18n131DetailSpecify, "Especificar");
    expect(lookupStrings(const Locale('de')).i18n131DetailSpecify, "Präzisieren");
    expect(lookupStrings(const Locale('fr')).i18n131DetailSpecify, "Préciser");
    expect(lookupStrings(const Locale('it')).i18n131DetailSpecify, "Definisci");
    expect(lookupStrings(const Locale('ja')).i18n131DetailSpecify, "具体化");
    expect(lookupStrings(const Locale('ko')).i18n131DetailSpecify, "구체화");
    expect(lookupStrings(const Locale('zh')).i18n131DetailSpecify, "细化");
    expect(lookupStrings(const Locale('es')).i18n131DetailDecompose, "Descomponer");
    expect(lookupStrings(const Locale('en')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDecompose, "Decompor");
    expect(lookupStrings(const Locale('de')).i18n131DetailDecompose, "Aufteilen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDecompose, "Décomposer");
    expect(lookupStrings(const Locale('it')).i18n131DetailDecompose, "Scomponi");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDecompose, "分解");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDecompose, "분할");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDecompose, "拆分");
    expect(lookupStrings(const Locale('es')).i18n131DetailNotifyWhenDone, "Avisarme cuando termine");
    expect(lookupStrings(const Locale('en')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('pt')).i18n131DetailNotifyWhenDone, "Avisar quando terminar");
    expect(lookupStrings(const Locale('de')).i18n131DetailNotifyWhenDone, "Bei Abschluss benachrichtigen");
    expect(lookupStrings(const Locale('fr')).i18n131DetailNotifyWhenDone, "Me prévenir à la fin");
    expect(lookupStrings(const Locale('it')).i18n131DetailNotifyWhenDone, "Avvisami al completamento");
    expect(lookupStrings(const Locale('ja')).i18n131DetailNotifyWhenDone, "完了時に通知");
    expect(lookupStrings(const Locale('ko')).i18n131DetailNotifyWhenDone, "완료 시 알림");
    expect(lookupStrings(const Locale('zh')).i18n131DetailNotifyWhenDone, "完成时通知我");
    expect(lookupStrings(const Locale('es')).i18n131DetailMuteNotifications, "Silenciar notificaciones");
    expect(lookupStrings(const Locale('en')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('pt')).i18n131DetailMuteNotifications, "Silenciar notificações");
    expect(lookupStrings(const Locale('de')).i18n131DetailMuteNotifications, "Benachrichtigungen stummschalten");
    expect(lookupStrings(const Locale('fr')).i18n131DetailMuteNotifications, "Couper les notifications");
    expect(lookupStrings(const Locale('it')).i18n131DetailMuteNotifications, "Silenzia notifiche");
    expect(lookupStrings(const Locale('ja')).i18n131DetailMuteNotifications, "通知を無効にする");
    expect(lookupStrings(const Locale('ko')).i18n131DetailMuteNotifications, "알림 끄기");
    expect(lookupStrings(const Locale('zh')).i18n131DetailMuteNotifications, "关闭通知");
    expect(lookupStrings(const Locale('es')).i18n131DetailMuteNotificationsSub, "No avisar de cambios de estado de esta tarea, aunque los resultados de Kanban estén activados");
    expect(lookupStrings(const Locale('en')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
    expect(lookupStrings(const Locale('pt')).i18n131DetailMuteNotificationsSub, "Não avisar sobre mudanças de estado desta tarefa, mesmo com os resultados do Kanban ativados");
    expect(lookupStrings(const Locale('de')).i18n131DetailMuteNotificationsSub, "Keine Statusänderungen dieser Aufgabe melden, auch wenn Kanban-Ergebnisse aktiviert sind");
    expect(lookupStrings(const Locale('fr')).i18n131DetailMuteNotificationsSub, "Ne pas signaler les changements d’état de cette tâche, même si les résultats Kanban sont activés");
    expect(lookupStrings(const Locale('it')).i18n131DetailMuteNotificationsSub, "Non notificare i cambiamenti di stato di questa attività, anche se i risultati Kanban sono abilitati");
    expect(lookupStrings(const Locale('ja')).i18n131DetailMuteNotificationsSub, "Kanbanの結果通知が有効でも、このタスクの状態変更は通知しません");
    expect(lookupStrings(const Locale('ko')).i18n131DetailMuteNotificationsSub, "칸반 결과 알림이 켜져 있어도 이 작업의 상태 변경은 알리지 않습니다");
    expect(lookupStrings(const Locale('zh')).i18n131DetailMuteNotificationsSub, "即使已启用看板结果通知，也不通知此任务的状态变化");
  });
}
