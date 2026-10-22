import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131TasksBulkPartialTitle',
    'i18n131TasksBulkPartial',
    'i18n131TasksActionUnavailable',
    'i18n131TasksSpecify',
    'i18n131TasksSpecifyTitle',
    'i18n131TasksSpecifyBody',
    'i18n131TasksSpecifyStarted',
    'i18n131TasksDecompose',
    'i18n131TasksDecomposeTitle',
    'i18n131TasksDecomposeBody',
    'i18n131TasksDecomposeResult',
    'i18n131TasksAttachmentTooLarge',
    'i18n131TasksAttachmentUnavailable',
    'i18n131TasksAttachmentUploaded',
    'i18n131TasksSaveAttachment',
    'i18n131TasksAttachmentSaved',
    'i18n131TasksDeleteAttachment',
    'i18n131TasksDeleteAttachmentBody',
    'i18n131TasksDelete',
    'i18n131TasksAttachmentDeleted',
    'i18n131TasksWorkerLog',
    'i18n131TasksNoLog',
    'i18n131TasksLogTruncated',
    'i18n131TasksRunInspection',
    'i18n131TasksAlive',
    'i18n131TasksYes',
    'i18n131TasksStatus',
    'i18n131TasksThreads',
    'i18n131TasksReason',
    'i18n131TasksError',
    'i18n131TasksTerminate',
    'i18n131TasksTerminateTitle',
    'i18n131TasksTerminateBody',
    'i18n131TasksRunTerminated',
    'i18n131TasksReclaim',
    'i18n131TasksReclaimTitle',
    'i18n131TasksReclaimBody',
    'i18n131TasksTaskReclaimed',
    'i18n131TasksChooseProfile',
    'i18n131TasksReassign',
    'i18n131TasksReassignTitle',
    'i18n131TasksReassignBodyReclaims',
    'i18n131TasksReassignBody',
    'i18n131TasksTaskReassigned',
    'i18n131TasksModelOptionsUnavailable',
    'i18n131TasksChooseModel',
    'i18n131TasksInheritModel',
    'i18n131TasksReasoningEffort',
    'i18n131TasksInheritEffort',
    'i18n131TasksEffortLabelNone',
    'i18n131TasksEffortLabelMinimal',
    'i18n131TasksEffortLabelLow',
    'i18n131TasksEffortLabelMedium',
    'i18n131TasksEffortLabelHigh',
    'i18n131TasksEffortLabelXhigh',
    'i18n131TasksEffortLabelMax',
    'i18n131TasksApplyModelTitle',
    'i18n131TasksApplyModelBody',
    'i18n131TasksApply',
    'i18n131TasksModelApplied',
    'i18n131TasksNo',
    'i18n131TasksMemory',
    'i18n131TasksEffortLabelUltra'
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
      expect(catalog.keys.where((key) => key.startsWith('i18n131Tasks')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131TasksBulkPartialTitle, "Algunas tareas no cambiaron");
    expect(lookupStrings(const Locale('en')).i18n131TasksBulkPartialTitle, "Some tasks were not changed");
    expect(lookupStrings(const Locale('pt')).i18n131TasksBulkPartialTitle, "Algumas tarefas não mudaram");
    expect(lookupStrings(const Locale('de')).i18n131TasksBulkPartialTitle, "Einige Aufgaben wurden nicht geändert");
    expect(lookupStrings(const Locale('fr')).i18n131TasksBulkPartialTitle, "Certaines tâches n’ont pas été modifiées");
    expect(lookupStrings(const Locale('it')).i18n131TasksBulkPartialTitle, "Alcune attività non sono state modificate");
    expect(lookupStrings(const Locale('ja')).i18n131TasksBulkPartialTitle, "一部のタスクを変更できませんでした");
    expect(lookupStrings(const Locale('ko')).i18n131TasksBulkPartialTitle, "일부 작업을 변경하지 못했습니다");
    expect(lookupStrings(const Locale('zh')).i18n131TasksBulkPartialTitle, "部分任务未更改");
    expect(lookupStrings(const Locale('es')).i18n131TasksBulkPartial(3, 3), "3 archivadas; 3 no se pudieron cambiar.");
    expect(lookupStrings(const Locale('en')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksBulkPartial(3, 3), "3 arquivadas; 3 não puderam ser alteradas.");
    expect(lookupStrings(const Locale('de')).i18n131TasksBulkPartial(3, 3), "3 archiviert; 3 konnten nicht geändert werden.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksBulkPartial(3, 3), "3 archivées ; 3 n’ont pas pu être modifiées.");
    expect(lookupStrings(const Locale('it')).i18n131TasksBulkPartial(3, 3), "3 archiviate; impossibile modificarne 3.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksBulkPartial(3, 3), "3件をアーカイブしました。3件は変更できませんでした。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksBulkPartial(3, 3), "3개 보관됨 · 3개 변경 실패");
    expect(lookupStrings(const Locale('zh')).i18n131TasksBulkPartial(3, 3), "已归档3项；3项无法更改。");
    expect(lookupStrings(const Locale('es')).i18n131TasksActionUnavailable, "Esta operación no está disponible en el servidor.");
    expect(lookupStrings(const Locale('en')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksActionUnavailable, "Esta operação não está disponível no servidor.");
    expect(lookupStrings(const Locale('de')).i18n131TasksActionUnavailable, "Dieser Vorgang ist auf dem Server nicht verfügbar.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksActionUnavailable, "Cette opération n’est pas disponible sur le serveur.");
    expect(lookupStrings(const Locale('it')).i18n131TasksActionUnavailable, "Questa operazione non è disponibile sul server.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksActionUnavailable, "このサーバーではこの操作を利用できません。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksActionUnavailable, "서버에서 이 작업을 지원하지 않습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksActionUnavailable, "服务器不支持此操作。");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecify, "Especificar");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecify, "Especificar");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecify, "Präzisieren");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecify, "Préciser");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecify, "Definisci");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecify, "具体化");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecify, "구체화");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecify, "细化");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecifyTitle, "Especificar tarea");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecifyTitle, "Especificar tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecifyTitle, "Aufgabe präzisieren");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecifyTitle, "Préciser la tâche");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecifyTitle, "Definisci attività");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecifyTitle, "タスクを具体化");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecifyTitle, "작업 구체화");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecifyTitle, "细化任务");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecifyBody, "Hermes usará el modelo auxiliar para completar esta tarea de triage. Puede tardar varios minutos.");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecifyBody, "O Hermes usará o modelo auxiliar para detalhar esta tarefa de triagem. Pode levar vários minutos.");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecifyBody, "Hermes wird diese zu sichtende Aufgabe mit dem Hilfsmodell ausarbeiten. Das kann mehrere Minuten dauern.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecifyBody, "Hermes utilisera le modèle auxiliaire pour détailler cette tâche de triage. Cela peut prendre plusieurs minutes.");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecifyBody, "Hermes userà il modello ausiliario per precisare questa attività di smistamento. Potrebbero volerci diversi minuti.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecifyBody, "Hermesが補助モデルを使って、このトリアージタスクの内容を具体化します。数分かかる場合があります。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecifyBody, "Hermes가 보조 모델을 사용하여 분류 단계의 작업을 구체화합니다. 몇 분 정도 걸릴 수 있습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecifyBody, "Hermes将使用辅助模型完善此待分类任务，可能需要几分钟。");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecifyStarted, "La tarea se ha especificado.");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecifyStarted, "A tarefa foi especificada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecifyStarted, "Die Aufgabe wurde präzisiert.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecifyStarted, "La tâche a été précisée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecifyStarted, "L’attività è stata definita.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecifyStarted, "タスクを具体化しました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecifyStarted, "작업이 구체화되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecifyStarted, "任务已细化。");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecompose, "Descomponer");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecompose, "Decompor");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecompose, "Aufteilen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecompose, "Décomposer");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecompose, "Scomponi");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecompose, "分解");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecompose, "분할");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecompose, "拆分");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecomposeTitle, "Descomponer en subtareas");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecomposeTitle, "Decompor em subtarefas");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecomposeTitle, "In Teilaufgaben aufteilen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecomposeTitle, "Décomposer en sous-tâches");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecomposeTitle, "Scomponi in sottoattività");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecomposeTitle, "子タスクに分解");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecomposeTitle, "하위 작업으로 분할");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecomposeTitle, "拆分为子任务");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecomposeBody, "Hermes creará un grafo de subtareas y las asignará a perfiles compatibles. Puede tardar varios minutos.");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecomposeBody, "O Hermes criará um grafo de subtarefas e as atribuirá a perfis compatíveis. Pode levar vários minutos.");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecomposeBody, "Hermes erstellt ein Teilaufgabendiagramm und weist es passenden Profilen zu. Das kann mehrere Minuten dauern.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecomposeBody, "Hermes créera un graphe de sous-tâches et les attribuera aux profils compatibles. Cela peut prendre plusieurs minutes.");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecomposeBody, "Hermes creerà un grafo di sottoattività e le assegnerà ai profili compatibili. Potrebbero volerci diversi minuti.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecomposeBody, "Hermesが子タスクのグラフを作成し、対応するプロフィールに振り分けます。数分かかる場合があります。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecomposeBody, "Hermes가 하위 작업 그래프를 만들고 호환되는 프로필에 배정합니다. 몇 분 정도 걸릴 수 있습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecomposeBody, "Hermes将创建子任务图并分配给兼容的配置档，可能需要几分钟。");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecomposeResult(3), "Descomposición completada: 3 subtareas.");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecomposeResult(3), "Decomposição concluída: 3 subtarefas.");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecomposeResult(3), "Aufteilung abgeschlossen: 3 Teilaufgaben.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecomposeResult(3), "Décomposition terminée : 3 sous-tâches.");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecomposeResult(3), "Scomposizione completata: 3 sottoattività.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecomposeResult(3), "分解が完了しました。子タスク3件。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecomposeResult(3), "분할 완료: 하위 작업 3개");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecomposeResult(3), "拆分完成：共3个子任务。");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentTooLarge, "El adjunto supera el límite oficial de 25 MiB.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentTooLarge, "O anexo excede o limite oficial de 25 MiB.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentTooLarge, "Der Anhang überschreitet die offizielle Grenze von 25 MiB.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentTooLarge, "La pièce jointe dépasse la limite officielle de 25 Mio.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentTooLarge, "L’allegato supera il limite ufficiale di 25 MiB.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentTooLarge, "添付ファイルが公式の上限25MiBを超えています。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentTooLarge, "첨부 파일이 공식 제한인 25 MiB를 초과합니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentTooLarge, "附件超过官方规定的25 MiB大小上限。");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentUnavailable, "Android no pudo proporcionar este archivo.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentUnavailable, "O Android não pôde fornecer este arquivo.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentUnavailable, "Android konnte diese Datei nicht bereitstellen.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentUnavailable, "Android n’a pas pu fournir ce fichier.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentUnavailable, "Android non ha potuto fornire questo file.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentUnavailable, "Androidからこのファイルを取得できませんでした。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentUnavailable, "Android에서 이 파일을 제공하지 못했습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentUnavailable, "Android无法提供此文件。");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentUploaded, "Adjunto subido.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentUploaded, "Anexo enviado.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentUploaded, "Anhang hochgeladen.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentUploaded, "Pièce jointe envoyée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentUploaded, "Allegato caricato.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentUploaded, "添付ファイルをアップロードしました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentUploaded, "첨부 파일이 업로드되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentUploaded, "附件已上传。");
    expect(lookupStrings(const Locale('es')).i18n131TasksSaveAttachment, "Guardar adjunto");
    expect(lookupStrings(const Locale('en')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSaveAttachment, "Salvar anexo");
    expect(lookupStrings(const Locale('de')).i18n131TasksSaveAttachment, "Anhang speichern");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSaveAttachment, "Enregistrer la pièce jointe");
    expect(lookupStrings(const Locale('it')).i18n131TasksSaveAttachment, "Salva allegato");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSaveAttachment, "添付ファイルを保存");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSaveAttachment, "첨부 파일 저장");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSaveAttachment, "保存附件");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentSaved, "Adjunto guardado.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentSaved, "Anexo salvo.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentSaved, "Anhang gespeichert.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentSaved, "Pièce jointe enregistrée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentSaved, "Allegato salvato.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentSaved, "添付ファイルを保存しました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentSaved, "첨부 파일이 저장되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentSaved, "附件已保存。");
    expect(lookupStrings(const Locale('es')).i18n131TasksDeleteAttachment, "Eliminar adjunto");
    expect(lookupStrings(const Locale('en')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDeleteAttachment, "Excluir anexo");
    expect(lookupStrings(const Locale('de')).i18n131TasksDeleteAttachment, "Anhang löschen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDeleteAttachment, "Supprimer la pièce jointe");
    expect(lookupStrings(const Locale('it')).i18n131TasksDeleteAttachment, "Elimina allegato");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDeleteAttachment, "添付ファイルを削除");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDeleteAttachment, "첨부 파일 삭제");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDeleteAttachment, "删除附件");
    expect(lookupStrings(const Locale('es')).i18n131TasksDeleteAttachmentBody("value {other}"), "¿Eliminar «value {other}» del servidor? Esta acción no se puede deshacer.");
    expect(lookupStrings(const Locale('en')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDeleteAttachmentBody("value {other}"), "Excluir “value {other}” do servidor? Esta ação não pode ser desfeita.");
    expect(lookupStrings(const Locale('de')).i18n131TasksDeleteAttachmentBody("value {other}"), "„value {other}“ vom Server löschen? Das kann nicht rückgängig gemacht werden.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDeleteAttachmentBody("value {other}"), "Supprimer « value {other} » du serveur ? Cette action est irréversible.");
    expect(lookupStrings(const Locale('it')).i18n131TasksDeleteAttachmentBody("value {other}"), "Eliminare “value {other}” dal server? Questa operazione è irreversibile.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDeleteAttachmentBody("value {other}"), "サーバーから「value {other}」を削除しますか？この操作は取り消せません。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDeleteAttachmentBody("value {other}"), "서버에서 “value {other}” 파일을 삭제할까요? 되돌릴 수 없습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDeleteAttachmentBody("value {other}"), "从服务器删除“value {other}”？此操作无法撤销。");
    expect(lookupStrings(const Locale('es')).i18n131TasksDelete, "Eliminar");
    expect(lookupStrings(const Locale('en')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDelete, "Excluir");
    expect(lookupStrings(const Locale('de')).i18n131TasksDelete, "Löschen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDelete, "Supprimer");
    expect(lookupStrings(const Locale('it')).i18n131TasksDelete, "Elimina");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDelete, "削除");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDelete, "삭제");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDelete, "删除");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentDeleted, "Adjunto eliminado.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentDeleted, "Anexo excluído.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentDeleted, "Anhang gelöscht.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentDeleted, "Pièce jointe supprimée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentDeleted, "Allegato eliminato.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentDeleted, "添付ファイルを削除しました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentDeleted, "첨부 파일이 삭제되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentDeleted, "附件已删除。");
    expect(lookupStrings(const Locale('es')).i18n131TasksWorkerLog, "Log del worker");
    expect(lookupStrings(const Locale('en')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('pt')).i18n131TasksWorkerLog, "Log do worker");
    expect(lookupStrings(const Locale('de')).i18n131TasksWorkerLog, "Worker-Protokoll");
    expect(lookupStrings(const Locale('fr')).i18n131TasksWorkerLog, "Journal de l’exécutant");
    expect(lookupStrings(const Locale('it')).i18n131TasksWorkerLog, "Registro del processo di lavoro");
    expect(lookupStrings(const Locale('ja')).i18n131TasksWorkerLog, "ワーカーログ");
    expect(lookupStrings(const Locale('ko')).i18n131TasksWorkerLog, "워커 로그");
    expect(lookupStrings(const Locale('zh')).i18n131TasksWorkerLog, "执行进程日志");
    expect(lookupStrings(const Locale('es')).i18n131TasksNoLog, "Esta tarea todavía no tiene log.");
    expect(lookupStrings(const Locale('en')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksNoLog, "Esta tarefa ainda não tem log.");
    expect(lookupStrings(const Locale('de')).i18n131TasksNoLog, "Für diese Aufgabe gibt es noch kein Protokoll.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksNoLog, "Cette tâche n’a pas encore de journal.");
    expect(lookupStrings(const Locale('it')).i18n131TasksNoLog, "Questa attività non ha ancora un registro.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksNoLog, "このタスクにはまだログがありません。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksNoLog, "아직 이 작업의 로그가 없습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksNoLog, "此任务暂无日志。");
    expect(lookupStrings(const Locale('es')).i18n131TasksLogTruncated, "Se muestra únicamente la cola más reciente del log.");
    expect(lookupStrings(const Locale('en')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksLogTruncated, "Apenas o trecho mais recente do log é exibido.");
    expect(lookupStrings(const Locale('de')).i18n131TasksLogTruncated, "Nur das jüngste Ende des Protokolls wird angezeigt.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksLogTruncated, "Seule la fin du journal la plus récente est affichée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksLogTruncated, "Viene mostrata solo la parte finale più recente del registro.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksLogTruncated, "ログの末尾の最新部分のみ表示しています。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksLogTruncated, "로그의 가장 최근 부분만 표시됩니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksLogTruncated, "仅显示日志末尾的最新内容。");
    expect(lookupStrings(const Locale('es')).i18n131TasksRunInspection, "Estado de la ejecución");
    expect(lookupStrings(const Locale('en')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('pt')).i18n131TasksRunInspection, "Estado da execução");
    expect(lookupStrings(const Locale('de')).i18n131TasksRunInspection, "Ausführung prüfen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksRunInspection, "Inspection de l’exécution");
    expect(lookupStrings(const Locale('it')).i18n131TasksRunInspection, "Ispeziona esecuzione");
    expect(lookupStrings(const Locale('ja')).i18n131TasksRunInspection, "実行状態の確認");
    expect(lookupStrings(const Locale('ko')).i18n131TasksRunInspection, "실행 상태 점검");
    expect(lookupStrings(const Locale('zh')).i18n131TasksRunInspection, "运行检查");
    expect(lookupStrings(const Locale('es')).i18n131TasksAlive, "Activo");
    expect(lookupStrings(const Locale('en')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAlive, "Ativo");
    expect(lookupStrings(const Locale('de')).i18n131TasksAlive, "Aktiv");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAlive, "Actif");
    expect(lookupStrings(const Locale('it')).i18n131TasksAlive, "Attivo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAlive, "稼働中");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAlive, "작동 중");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAlive, "运行中");
    expect(lookupStrings(const Locale('es')).i18n131TasksYes, "Sí");
    expect(lookupStrings(const Locale('en')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('pt')).i18n131TasksYes, "Sim");
    expect(lookupStrings(const Locale('de')).i18n131TasksYes, "Ja");
    expect(lookupStrings(const Locale('fr')).i18n131TasksYes, "Oui");
    expect(lookupStrings(const Locale('it')).i18n131TasksYes, "Sì");
    expect(lookupStrings(const Locale('ja')).i18n131TasksYes, "はい");
    expect(lookupStrings(const Locale('ko')).i18n131TasksYes, "예");
    expect(lookupStrings(const Locale('zh')).i18n131TasksYes, "是");
    expect(lookupStrings(const Locale('es')).i18n131TasksStatus, "Estado");
    expect(lookupStrings(const Locale('en')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('pt')).i18n131TasksStatus, "Estado");
    expect(lookupStrings(const Locale('de')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('fr')).i18n131TasksStatus, "État");
    expect(lookupStrings(const Locale('it')).i18n131TasksStatus, "Stato");
    expect(lookupStrings(const Locale('ja')).i18n131TasksStatus, "状態");
    expect(lookupStrings(const Locale('ko')).i18n131TasksStatus, "상태");
    expect(lookupStrings(const Locale('zh')).i18n131TasksStatus, "状态");
    expect(lookupStrings(const Locale('es')).i18n131TasksThreads, "Hilos");
    expect(lookupStrings(const Locale('en')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('pt')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('de')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('fr')).i18n131TasksThreads, "Fils d’exécution");
    expect(lookupStrings(const Locale('it')).i18n131TasksThreads, "Thread");
    expect(lookupStrings(const Locale('ja')).i18n131TasksThreads, "スレッド");
    expect(lookupStrings(const Locale('ko')).i18n131TasksThreads, "스레드");
    expect(lookupStrings(const Locale('zh')).i18n131TasksThreads, "线程");
    expect(lookupStrings(const Locale('es')).i18n131TasksReason, "Motivo");
    expect(lookupStrings(const Locale('en')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReason, "Motivo");
    expect(lookupStrings(const Locale('de')).i18n131TasksReason, "Grund");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReason, "Motif");
    expect(lookupStrings(const Locale('it')).i18n131TasksReason, "Motivo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReason, "理由");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReason, "이유");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReason, "原因");
    expect(lookupStrings(const Locale('es')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('en')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('pt')).i18n131TasksError, "Erro");
    expect(lookupStrings(const Locale('de')).i18n131TasksError, "Fehler");
    expect(lookupStrings(const Locale('fr')).i18n131TasksError, "Erreur");
    expect(lookupStrings(const Locale('it')).i18n131TasksError, "Errore");
    expect(lookupStrings(const Locale('ja')).i18n131TasksError, "エラー");
    expect(lookupStrings(const Locale('ko')).i18n131TasksError, "오류");
    expect(lookupStrings(const Locale('zh')).i18n131TasksError, "错误");
    expect(lookupStrings(const Locale('es')).i18n131TasksTerminate, "Terminar");
    expect(lookupStrings(const Locale('en')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTerminate, "Encerrar");
    expect(lookupStrings(const Locale('de')).i18n131TasksTerminate, "Beenden");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTerminate, "Arrêter");
    expect(lookupStrings(const Locale('it')).i18n131TasksTerminate, "Termina");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTerminate, "停止");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTerminate, "종료");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTerminate, "终止");
    expect(lookupStrings(const Locale('es')).i18n131TasksTerminateTitle, "Terminar ejecución");
    expect(lookupStrings(const Locale('en')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTerminateTitle, "Encerrar execução");
    expect(lookupStrings(const Locale('de')).i18n131TasksTerminateTitle, "Ausführung beenden");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTerminateTitle, "Arrêter l’exécution");
    expect(lookupStrings(const Locale('it')).i18n131TasksTerminateTitle, "Termina esecuzione");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTerminateTitle, "実行を停止");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTerminateTitle, "실행 종료");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTerminateTitle, "终止运行");
    expect(lookupStrings(const Locale('es')).i18n131TasksTerminateBody(3), "Se detendrá el worker de la ejecución #3 y la tarea volverá a la cola. ¿Continuar?");
    expect(lookupStrings(const Locale('en')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTerminateBody(3), "O worker da execução #3 será interrompido e a tarefa voltará para a fila. Continuar?");
    expect(lookupStrings(const Locale('de')).i18n131TasksTerminateBody(3), "Der Worker für Ausführung #3 wird gestoppt und die Aufgabe kommt zurück in die Warteschlange. Fortfahren?");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTerminateBody(3), "L’exécutant de l’exécution nº 3 s’arrêtera et la tâche retournera dans la file d’attente. Continuer ?");
    expect(lookupStrings(const Locale('it')).i18n131TasksTerminateBody(3), "Il processo di lavoro dell’esecuzione #3 verrà arrestato e l’attività tornerà in coda. Continuare?");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTerminateBody(3), "実行#3のワーカーを停止し、タスクをキューに戻します。続行しますか？");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTerminateBody(3), "실행 #3의 워커가 중지되고 작업이 대기열로 돌아갑니다. 계속할까요?");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTerminateBody(3), "运行#3的执行进程将停止，任务将重新入队。继续？");
    expect(lookupStrings(const Locale('es')).i18n131TasksRunTerminated, "Ejecución terminada y reencolada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksRunTerminated, "Execução encerrada e reenfileirada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksRunTerminated, "Ausführung beendet und erneut eingereiht.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksRunTerminated, "Exécution arrêtée et remise en file d’attente.");
    expect(lookupStrings(const Locale('it')).i18n131TasksRunTerminated, "Esecuzione terminata e rimessa in coda.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksRunTerminated, "実行を停止し、キューに戻しました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksRunTerminated, "실행이 종료되고 대기열에 다시 추가되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksRunTerminated, "运行已终止，任务已重新入队。");
    expect(lookupStrings(const Locale('es')).i18n131TasksReclaim, "Recuperar");
    expect(lookupStrings(const Locale('en')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReclaim, "Recuperar");
    expect(lookupStrings(const Locale('de')).i18n131TasksReclaim, "Zurückholen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReclaim, "Récupérer");
    expect(lookupStrings(const Locale('it')).i18n131TasksReclaim, "Recupera");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReclaim, "回収");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReclaim, "회수");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReclaim, "回收");
    expect(lookupStrings(const Locale('es')).i18n131TasksReclaimTitle, "Recuperar tarea atascada");
    expect(lookupStrings(const Locale('en')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReclaimTitle, "Recuperar tarefa travada");
    expect(lookupStrings(const Locale('de')).i18n131TasksReclaimTitle, "Festhängende Aufgabe zurückholen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReclaimTitle, "Récupérer la tâche bloquée");
    expect(lookupStrings(const Locale('it')).i18n131TasksReclaimTitle, "Recupera attività bloccata");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReclaimTitle, "停止したタスクを回収");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReclaimTitle, "멈춘 작업 회수");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReclaimTitle, "回收卡住的任务");
    expect(lookupStrings(const Locale('es')).i18n131TasksReclaimBody, "Se detendrá el worker actual y la tarea volverá a «En cola». Úsalo solo si la ejecución está atascada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReclaimBody, "O worker atual será interrompido e a tarefa voltará para “Em fila”. Use apenas se a execução estiver travada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksReclaimBody, "Der aktuelle Worker wird gestoppt und die Aufgabe kommt zurück in die Warteschlange. Nur bei einer festhängenden Ausführung verwenden.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReclaimBody, "L’exécutant actuel s’arrêtera et la tâche retournera dans la file d’attente. À utiliser uniquement pour une exécution bloquée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksReclaimBody, "Il processo di lavoro attuale verrà arrestato e l’attività tornerà in coda. Usa questa funzione solo per un’esecuzione bloccata.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReclaimBody, "現在のワーカーを停止し、タスクをキューに戻します。実行が行き詰まった場合にのみ使用してください。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReclaimBody, "현재 워커가 중지되고 작업이 대기열로 돌아갑니다. 실행이 멈춘 경우에만 사용하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReclaimBody, "当前执行进程将停止，任务将重新入队。仅用于卡住的运行。");
    expect(lookupStrings(const Locale('es')).i18n131TasksTaskReclaimed, "Tarea recuperada y reencolada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTaskReclaimed, "Tarefa recuperada e reenfileirada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksTaskReclaimed, "Aufgabe zurückgeholt und erneut eingereiht.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTaskReclaimed, "Tâche récupérée et remise en file d’attente.");
    expect(lookupStrings(const Locale('it')).i18n131TasksTaskReclaimed, "Attività recuperata e rimessa in coda.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTaskReclaimed, "タスクを回収し、キューに戻しました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTaskReclaimed, "작업이 회수되어 대기열에 다시 추가되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTaskReclaimed, "任务已回收并重新入队。");
    expect(lookupStrings(const Locale('es')).i18n131TasksChooseProfile, "Elegir perfil");
    expect(lookupStrings(const Locale('en')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('pt')).i18n131TasksChooseProfile, "Escolher perfil");
    expect(lookupStrings(const Locale('de')).i18n131TasksChooseProfile, "Profil auswählen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksChooseProfile, "Choisir un profil");
    expect(lookupStrings(const Locale('it')).i18n131TasksChooseProfile, "Scegli profilo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksChooseProfile, "プロフィールを選択");
    expect(lookupStrings(const Locale('ko')).i18n131TasksChooseProfile, "프로필 선택");
    expect(lookupStrings(const Locale('zh')).i18n131TasksChooseProfile, "选择配置档");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassign, "Reasignar");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassign, "Reatribuir");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassign, "Neu zuweisen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassign, "Réattribuer");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassign, "Riassegna");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassign, "再割り当て");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassign, "재배정");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassign, "重新分配");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassignTitle, "Reasignar tarea");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassignTitle, "Reatribuir tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassignTitle, "Aufgabe neu zuweisen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassignTitle, "Réattribuer la tâche");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassignTitle, "Riassegna attività");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassignTitle, "タスクを再割り当て");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassignTitle, "작업 재배정");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassignTitle, "重新分配任务");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassignBodyReclaims("value {other}"), "La tarea se asignará a «value {other}». El worker actual se detendrá primero.");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassignBodyReclaims("value {other}"), "A tarefa será atribuída a “value {other}”. O worker atual será interrompido primeiro.");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassignBodyReclaims("value {other}"), "Die Aufgabe wird „value {other}“ zugewiesen. Der aktuelle Worker wird zuerst gestoppt.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassignBodyReclaims("value {other}"), "La tâche sera attribuée à « value {other} ». L’exécutant actuel sera d’abord arrêté.");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassignBodyReclaims("value {other}"), "L’attività verrà assegnata a “value {other}”. Il processo di lavoro attuale verrà prima arrestato.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassignBodyReclaims("value {other}"), "タスクを「value {other}」に割り当てます。先に現在のワーカーを停止します。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassignBodyReclaims("value {other}"), "작업이 “value {other}”에 배정됩니다. 먼저 현재 워커가 중지됩니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassignBodyReclaims("value {other}"), "任务将分配给“value {other}”，当前执行进程会先停止。");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassignBody("value {other}"), "La tarea se asignará a «value {other}».");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassignBody("value {other}"), "A tarefa será atribuída a “value {other}”.");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassignBody("value {other}"), "Die Aufgabe wird „value {other}“ zugewiesen.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassignBody("value {other}"), "La tâche sera attribuée à « value {other} ».");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassignBody("value {other}"), "L’attività verrà assegnata a “value {other}”.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassignBody("value {other}"), "タスクを「value {other}」に割り当てます。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassignBody("value {other}"), "작업이 “value {other}”에 배정됩니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassignBody("value {other}"), "任务将分配给“value {other}”。");
    expect(lookupStrings(const Locale('es')).i18n131TasksTaskReassigned, "Tarea reasignada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTaskReassigned, "Tarefa reatribuída.");
    expect(lookupStrings(const Locale('de')).i18n131TasksTaskReassigned, "Aufgabe neu zugewiesen.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTaskReassigned, "Tâche réattribuée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksTaskReassigned, "Attività riassegnata.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTaskReassigned, "タスクを再割り当てしました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTaskReassigned, "작업이 재배정되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTaskReassigned, "任务已重新分配。");
    expect(lookupStrings(const Locale('es')).i18n131TasksModelOptionsUnavailable, "Este servidor no publica opciones de modelo para Kanban.");
    expect(lookupStrings(const Locale('en')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksModelOptionsUnavailable, "Este servidor não publica opções de modelo para o Kanban.");
    expect(lookupStrings(const Locale('de')).i18n131TasksModelOptionsUnavailable, "Dieser Server stellt keine Kanban-Modelloptionen bereit.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksModelOptionsUnavailable, "Ce serveur ne publie pas les options de modèle Kanban.");
    expect(lookupStrings(const Locale('it')).i18n131TasksModelOptionsUnavailable, "Questo server non espone le opzioni dei modelli Kanban.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksModelOptionsUnavailable, "このサーバーはKanbanのモデル設定を公開していません。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksModelOptionsUnavailable, "이 서버에서는 칸반 모델 옵션을 제공하지 않습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksModelOptionsUnavailable, "此服务器未提供看板模型选项。");
    expect(lookupStrings(const Locale('es')).i18n131TasksChooseModel, "Modelo para esta tarea");
    expect(lookupStrings(const Locale('en')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksChooseModel, "Modelo para esta tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TasksChooseModel, "Modell für diese Aufgabe");
    expect(lookupStrings(const Locale('fr')).i18n131TasksChooseModel, "Modèle pour cette tâche");
    expect(lookupStrings(const Locale('it')).i18n131TasksChooseModel, "Modello per questa attività");
    expect(lookupStrings(const Locale('ja')).i18n131TasksChooseModel, "このタスクのモデル");
    expect(lookupStrings(const Locale('ko')).i18n131TasksChooseModel, "이 작업에 사용할 모델");
    expect(lookupStrings(const Locale('zh')).i18n131TasksChooseModel, "此任务的模型");
    expect(lookupStrings(const Locale('es')).i18n131TasksInheritModel, "Heredar modelo del perfil");
    expect(lookupStrings(const Locale('en')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('pt')).i18n131TasksInheritModel, "Herdar modelo do perfil");
    expect(lookupStrings(const Locale('de')).i18n131TasksInheritModel, "Modell vom Profil übernehmen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksInheritModel, "Hériter du modèle du profil");
    expect(lookupStrings(const Locale('it')).i18n131TasksInheritModel, "Eredita il modello dal profilo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksInheritModel, "プロフィールのモデルを継承");
    expect(lookupStrings(const Locale('ko')).i18n131TasksInheritModel, "프로필의 모델 상속");
    expect(lookupStrings(const Locale('zh')).i18n131TasksInheritModel, "继承配置档模型");
    expect(lookupStrings(const Locale('es')).i18n131TasksReasoningEffort, "Esfuerzo de razonamiento");
    expect(lookupStrings(const Locale('en')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReasoningEffort, "Esforço de raciocínio");
    expect(lookupStrings(const Locale('de')).i18n131TasksReasoningEffort, "Denkaufwand");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReasoningEffort, "Effort de raisonnement");
    expect(lookupStrings(const Locale('it')).i18n131TasksReasoningEffort, "Livello di ragionamento");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReasoningEffort, "推論の強度");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReasoningEffort, "추론 수준");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReasoningEffort, "推理强度");
    expect(lookupStrings(const Locale('es')).i18n131TasksInheritEffort, "Heredar esfuerzo del perfil");
    expect(lookupStrings(const Locale('en')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('pt')).i18n131TasksInheritEffort, "Herdar esforço do perfil");
    expect(lookupStrings(const Locale('de')).i18n131TasksInheritEffort, "Denkaufwand vom Profil übernehmen");
    expect(lookupStrings(const Locale('fr')).i18n131TasksInheritEffort, "Hériter de l’effort du profil");
    expect(lookupStrings(const Locale('it')).i18n131TasksInheritEffort, "Eredita il livello dal profilo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksInheritEffort, "プロフィールの推論強度を継承");
    expect(lookupStrings(const Locale('ko')).i18n131TasksInheritEffort, "프로필의 추론 수준 상속");
    expect(lookupStrings(const Locale('zh')).i18n131TasksInheritEffort, "继承配置档强度");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelNone, "Desactivado");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelNone, "Off");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelNone, "Desativado");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelNone, "Aus");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelNone, "Désactivé");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelNone, "Disattivato");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelNone, "オフ");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelNone, "끄기");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelNone, "关闭");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelMinimal, "Mínimo");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelMinimal, "Minimal");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelMinimal, "Mínimo");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelMinimal, "Minimal");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelMinimal, "Minimal");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelMinimal, "Minimo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelMinimal, "最小");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelMinimal, "최소");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelMinimal, "最低");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelLow, "Bajo");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelLow, "Low");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelLow, "Baixo");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelLow, "Niedrig");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelLow, "Faible");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelLow, "Basso");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelLow, "低");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelLow, "낮음");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelLow, "低");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelMedium, "Medio");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelMedium, "Medium");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelMedium, "Médio");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelMedium, "Mittel");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelMedium, "Moyen");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelMedium, "Medio");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelMedium, "中");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelMedium, "보통");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelMedium, "中");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelHigh, "Alto");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelHigh, "High");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelHigh, "Alto");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelHigh, "Hoch");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelHigh, "Élevé");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelHigh, "Alto");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelHigh, "高");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelHigh, "높음");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelHigh, "高");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelXhigh, "Muy alto");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelXhigh, "XHigh");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelXhigh, "Muito alto");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelXhigh, "Sehr hoch");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelXhigh, "Très élevé");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelXhigh, "Molto alto");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelXhigh, "非常に高い");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelXhigh, "매우 높음");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelXhigh, "很高");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelMax, "Máximo");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelMax, "Max");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelMax, "Máximo");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelMax, "Maximal");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelMax, "Maximum");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelMax, "Massimo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelMax, "最大");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelMax, "최대");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelMax, "最大");
    expect(lookupStrings(const Locale('es')).i18n131TasksApplyModelTitle, "Aplicar configuración de modelo");
    expect(lookupStrings(const Locale('en')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('pt')).i18n131TasksApplyModelTitle, "Aplicar configuração de modelo");
    expect(lookupStrings(const Locale('de')).i18n131TasksApplyModelTitle, "Modellkonfiguration anwenden");
    expect(lookupStrings(const Locale('fr')).i18n131TasksApplyModelTitle, "Appliquer la configuration du modèle");
    expect(lookupStrings(const Locale('it')).i18n131TasksApplyModelTitle, "Applica configurazione del modello");
    expect(lookupStrings(const Locale('ja')).i18n131TasksApplyModelTitle, "モデル設定を適用");
    expect(lookupStrings(const Locale('ko')).i18n131TasksApplyModelTitle, "모델 설정 적용");
    expect(lookupStrings(const Locale('zh')).i18n131TasksApplyModelTitle, "应用模型配置");
    expect(lookupStrings(const Locale('es')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Modelo: value {other}\nRazonamiento: value {other}");
    expect(lookupStrings(const Locale('en')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('pt')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Modelo: value {other}\nRaciocínio: value {other}");
    expect(lookupStrings(const Locale('de')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Modell: value {other}\nDenkaufwand: value {other}");
    expect(lookupStrings(const Locale('fr')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Modèle : value {other}\nRaisonnement : value {other}");
    expect(lookupStrings(const Locale('it')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Modello: value {other}\nRagionamento: value {other}");
    expect(lookupStrings(const Locale('ja')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "モデル：value {other}\n推論：value {other}");
    expect(lookupStrings(const Locale('ko')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "모델: value {other}\n추론: value {other}");
    expect(lookupStrings(const Locale('zh')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "模型：value {other}\n推理强度：value {other}");
    expect(lookupStrings(const Locale('es')).i18n131TasksApply, "Aplicar");
    expect(lookupStrings(const Locale('en')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('pt')).i18n131TasksApply, "Aplicar");
    expect(lookupStrings(const Locale('de')).i18n131TasksApply, "Anwenden");
    expect(lookupStrings(const Locale('fr')).i18n131TasksApply, "Appliquer");
    expect(lookupStrings(const Locale('it')).i18n131TasksApply, "Applica");
    expect(lookupStrings(const Locale('ja')).i18n131TasksApply, "適用");
    expect(lookupStrings(const Locale('ko')).i18n131TasksApply, "적용");
    expect(lookupStrings(const Locale('zh')).i18n131TasksApply, "应用");
    expect(lookupStrings(const Locale('es')).i18n131TasksModelApplied, "Configuración de modelo aplicada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksModelApplied, "Configuração de modelo aplicada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksModelApplied, "Modellkonfiguration angewendet.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksModelApplied, "Configuration du modèle appliquée.");
    expect(lookupStrings(const Locale('it')).i18n131TasksModelApplied, "Configurazione del modello applicata.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksModelApplied, "モデル設定を適用しました。");
    expect(lookupStrings(const Locale('ko')).i18n131TasksModelApplied, "모델 설정이 적용되었습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksModelApplied, "模型配置已应用。");
    expect(lookupStrings(const Locale('es')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('en')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('pt')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('de')).i18n131TasksNo, "Nein");
    expect(lookupStrings(const Locale('fr')).i18n131TasksNo, "Non");
    expect(lookupStrings(const Locale('it')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('ja')).i18n131TasksNo, "いいえ");
    expect(lookupStrings(const Locale('ko')).i18n131TasksNo, "아니요");
    expect(lookupStrings(const Locale('zh')).i18n131TasksNo, "否");
    expect(lookupStrings(const Locale('es')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('en')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('pt')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('de')).i18n131TasksMemory, "Arbeitsspeicher");
    expect(lookupStrings(const Locale('fr')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('it')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('ja')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('ko')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('zh')).i18n131TasksMemory, "内存");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelUltra, "Extrem");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelUltra, "Estremo");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelUltra, "超高");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelUltra, "최상");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelUltra, "极高");
  });
}
