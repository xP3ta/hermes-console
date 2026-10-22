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
    expect(lookupStrings(const Locale('de')).i18n131DetailReadOnly, "This instance is read-only.");
    expect(lookupStrings(const Locale('fr')).i18n131DetailReadOnly, "This instance is read-only.");
    expect(lookupStrings(const Locale('it')).i18n131DetailReadOnly, "This instance is read-only.");
    expect(lookupStrings(const Locale('ja')).i18n131DetailReadOnly, "This instance is read-only.");
    expect(lookupStrings(const Locale('ko')).i18n131DetailReadOnly, "This instance is read-only.");
    expect(lookupStrings(const Locale('zh')).i18n131DetailReadOnly, "This instance is read-only.");
    expect(lookupStrings(const Locale('es')).i18n131DetailObjective, "Objetivo · leer completo");
    expect(lookupStrings(const Locale('en')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('pt')).i18n131DetailObjective, "Objetivo · ler tudo");
    expect(lookupStrings(const Locale('de')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('fr')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('it')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('ja')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('ko')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('zh')).i18n131DetailObjective, "Objective · read all");
    expect(lookupStrings(const Locale('es')).i18n131DetailResult, "Resultado");
    expect(lookupStrings(const Locale('en')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('pt')).i18n131DetailResult, "Resultado");
    expect(lookupStrings(const Locale('de')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('fr')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('it')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('ja')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('ko')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('zh')).i18n131DetailResult, "Result");
    expect(lookupStrings(const Locale('es')).i18n131DetailLatestSummary, "Último resumen");
    expect(lookupStrings(const Locale('en')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('pt')).i18n131DetailLatestSummary, "Último resumo");
    expect(lookupStrings(const Locale('de')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('fr')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('it')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('ja')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('ko')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('zh')).i18n131DetailLatestSummary, "Latest summary");
    expect(lookupStrings(const Locale('es')).i18n131DetailDiagnostics, "Diagnósticos");
    expect(lookupStrings(const Locale('en')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDiagnostics, "Diagnósticos");
    expect(lookupStrings(const Locale('de')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('it')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDiagnostics, "Diagnostics");
    expect(lookupStrings(const Locale('es')).i18n131DetailDependencies, "Dependencias");
    expect(lookupStrings(const Locale('en')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDependencies, "Dependências");
    expect(lookupStrings(const Locale('de')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('it')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDependencies, "Dependencies");
    expect(lookupStrings(const Locale('es')).i18n131DetailParents, "Depende de");
    expect(lookupStrings(const Locale('en')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('pt')).i18n131DetailParents, "Depende de");
    expect(lookupStrings(const Locale('de')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('fr')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('it')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('ja')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('ko')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('zh')).i18n131DetailParents, "Depends on");
    expect(lookupStrings(const Locale('es')).i18n131DetailChildren, "Desbloquea");
    expect(lookupStrings(const Locale('en')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('pt')).i18n131DetailChildren, "Desbloqueia");
    expect(lookupStrings(const Locale('de')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('fr')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('it')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('ja')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('ko')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('zh')).i18n131DetailChildren, "Unblocks");
    expect(lookupStrings(const Locale('es')).i18n131DetailBlockedBy, "Bloqueada por");
    expect(lookupStrings(const Locale('en')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('pt')).i18n131DetailBlockedBy, "Bloqueada por");
    expect(lookupStrings(const Locale('de')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('fr')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('it')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('ja')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('ko')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('zh')).i18n131DetailBlockedBy, "Blocked by");
    expect(lookupStrings(const Locale('es')).i18n131DetailBlocks, "Bloquea");
    expect(lookupStrings(const Locale('en')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('pt')).i18n131DetailBlocks, "Bloqueia");
    expect(lookupStrings(const Locale('de')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('fr')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('it')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('ja')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('ko')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('zh')).i18n131DetailBlocks, "Blocks");
    expect(lookupStrings(const Locale('es')).i18n131DetailChildResults, "Subtareas");
    expect(lookupStrings(const Locale('en')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('pt')).i18n131DetailChildResults, "Subtarefas");
    expect(lookupStrings(const Locale('de')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('fr')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('it')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('ja')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('ko')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('zh')).i18n131DetailChildResults, "Child tasks");
    expect(lookupStrings(const Locale('es')).i18n131DetailComments, "Comentarios");
    expect(lookupStrings(const Locale('en')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('pt')).i18n131DetailComments, "Comentários");
    expect(lookupStrings(const Locale('de')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('fr')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('it')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('ja')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('ko')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('zh')).i18n131DetailComments, "Comments");
    expect(lookupStrings(const Locale('es')).i18n131DetailNoComments, "Todavía no hay comentarios.");
    expect(lookupStrings(const Locale('en')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('pt')).i18n131DetailNoComments, "Ainda não há comentários.");
    expect(lookupStrings(const Locale('de')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('fr')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('it')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('ja')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('ko')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('zh')).i18n131DetailNoComments, "No comments yet.");
    expect(lookupStrings(const Locale('es')).i18n131DetailSomeone, "Alguien");
    expect(lookupStrings(const Locale('en')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('pt')).i18n131DetailSomeone, "Alguém");
    expect(lookupStrings(const Locale('de')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('fr')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('it')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('ja')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('ko')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('zh')).i18n131DetailSomeone, "Someone");
    expect(lookupStrings(const Locale('es')).i18n131DetailAddComment, "Añadir comentario");
    expect(lookupStrings(const Locale('en')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('pt')).i18n131DetailAddComment, "Adicionar comentário");
    expect(lookupStrings(const Locale('de')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('fr')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('it')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('ja')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('ko')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('zh')).i18n131DetailAddComment, "Add a comment");
    expect(lookupStrings(const Locale('es')).i18n131DetailMessageWorker, "Enviar una nota al worker");
    expect(lookupStrings(const Locale('en')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('pt')).i18n131DetailMessageWorker, "Enviar uma nota ao worker");
    expect(lookupStrings(const Locale('de')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('fr')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('it')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('ja')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('ko')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('zh')).i18n131DetailMessageWorker, "Message the worker");
    expect(lookupStrings(const Locale('es')).i18n131DetailSend, "Enviar");
    expect(lookupStrings(const Locale('en')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('pt')).i18n131DetailSend, "Enviar");
    expect(lookupStrings(const Locale('de')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('fr')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('it')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('ja')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('ko')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('zh')).i18n131DetailSend, "Send");
    expect(lookupStrings(const Locale('es')).i18n131DetailAttachments, "Adjuntos");
    expect(lookupStrings(const Locale('en')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('pt')).i18n131DetailAttachments, "Anexos");
    expect(lookupStrings(const Locale('de')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('fr')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('it')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('ja')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('ko')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('zh')).i18n131DetailAttachments, "Attachments");
    expect(lookupStrings(const Locale('es')).i18n131DetailNoAttachments, "No hay adjuntos.");
    expect(lookupStrings(const Locale('en')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('pt')).i18n131DetailNoAttachments, "Não há anexos.");
    expect(lookupStrings(const Locale('de')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('fr')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('it')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('ja')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('ko')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('zh')).i18n131DetailNoAttachments, "No attachments.");
    expect(lookupStrings(const Locale('es')).i18n131DetailUploadAttachment, "Subir adjunto");
    expect(lookupStrings(const Locale('en')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('pt')).i18n131DetailUploadAttachment, "Enviar anexo");
    expect(lookupStrings(const Locale('de')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('fr')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('it')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('ja')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('ko')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('zh')).i18n131DetailUploadAttachment, "Upload attachment");
    expect(lookupStrings(const Locale('es')).i18n131DetailDownload, "Descargar");
    expect(lookupStrings(const Locale('en')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDownload, "Baixar");
    expect(lookupStrings(const Locale('de')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('it')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDownload, "Download");
    expect(lookupStrings(const Locale('es')).i18n131DetailDeleteAttachment, "Eliminar adjunto");
    expect(lookupStrings(const Locale('en')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDeleteAttachment, "Excluir anexo");
    expect(lookupStrings(const Locale('de')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('it')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('es')).i18n131DetailRuns, "Ejecuciones");
    expect(lookupStrings(const Locale('en')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('pt')).i18n131DetailRuns, "Execuções");
    expect(lookupStrings(const Locale('de')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('fr')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('it')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('ja')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('ko')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('zh')).i18n131DetailRuns, "Runs");
    expect(lookupStrings(const Locale('es')).i18n131DetailRun, "Ejecución");
    expect(lookupStrings(const Locale('en')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('pt')).i18n131DetailRun, "Execução");
    expect(lookupStrings(const Locale('de')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('fr')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('it')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('ja')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('ko')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('zh')).i18n131DetailRun, "Run");
    expect(lookupStrings(const Locale('es')).i18n131DetailInspect, "Inspeccionar");
    expect(lookupStrings(const Locale('en')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('pt')).i18n131DetailInspect, "Inspecionar");
    expect(lookupStrings(const Locale('de')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('fr')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('it')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('ja')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('ko')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('zh')).i18n131DetailInspect, "Inspect");
    expect(lookupStrings(const Locale('es')).i18n131DetailTerminate, "Terminar ejecución");
    expect(lookupStrings(const Locale('en')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('pt')).i18n131DetailTerminate, "Encerrar execução");
    expect(lookupStrings(const Locale('de')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('fr')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('it')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('ja')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('ko')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('zh')).i18n131DetailTerminate, "Terminate run");
    expect(lookupStrings(const Locale('es')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('en')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('pt')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('de')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('fr')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('it')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('ja')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('ko')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('zh')).i18n131DetailLog, "Log");
    expect(lookupStrings(const Locale('es')).i18n131DetailActivity, "Actividad");
    expect(lookupStrings(const Locale('en')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('pt')).i18n131DetailActivity, "Atividade");
    expect(lookupStrings(const Locale('de')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('fr')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('it')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('ja')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('ko')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('zh')).i18n131DetailActivity, "Activity");
    expect(lookupStrings(const Locale('es')).i18n131DetailShowAll, "Mostrar toda");
    expect(lookupStrings(const Locale('en')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('pt')).i18n131DetailShowAll, "Mostrar tudo");
    expect(lookupStrings(const Locale('de')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('fr')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('it')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('ja')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('ko')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('zh')).i18n131DetailShowAll, "Show all");
    expect(lookupStrings(const Locale('es')).i18n131DetailShowLess, "Mostrar menos");
    expect(lookupStrings(const Locale('en')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('pt')).i18n131DetailShowLess, "Mostrar menos");
    expect(lookupStrings(const Locale('de')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('fr')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('it')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('ja')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('ko')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('zh')).i18n131DetailShowLess, "Show less");
    expect(lookupStrings(const Locale('es')).i18n131DetailOperations, "Operaciones");
    expect(lookupStrings(const Locale('en')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('pt')).i18n131DetailOperations, "Operações");
    expect(lookupStrings(const Locale('de')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('fr')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('it')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('ja')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('ko')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('zh')).i18n131DetailOperations, "Operations");
    expect(lookupStrings(const Locale('es')).i18n131DetailModel, "Modelo de esta tarea");
    expect(lookupStrings(const Locale('en')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('pt')).i18n131DetailModel, "Modelo desta tarefa");
    expect(lookupStrings(const Locale('de')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('fr')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('it')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('ja')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('ko')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('zh')).i18n131DetailModel, "Task model");
    expect(lookupStrings(const Locale('es')).i18n131DetailInheritModel, "Heredar del perfil");
    expect(lookupStrings(const Locale('en')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('pt')).i18n131DetailInheritModel, "Herdar do perfil");
    expect(lookupStrings(const Locale('de')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('fr')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('it')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('ja')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('ko')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('zh')).i18n131DetailInheritModel, "Inherit from profile");
    expect(lookupStrings(const Locale('es')).i18n131DetailReassign, "Reasignar");
    expect(lookupStrings(const Locale('en')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('pt')).i18n131DetailReassign, "Reatribuir");
    expect(lookupStrings(const Locale('de')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('fr')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('it')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('ja')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('ko')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('zh')).i18n131DetailReassign, "Reassign");
    expect(lookupStrings(const Locale('es')).i18n131DetailReclaim, "Recuperar y reencolar");
    expect(lookupStrings(const Locale('en')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('pt')).i18n131DetailReclaim, "Recuperar e reenfileirar");
    expect(lookupStrings(const Locale('de')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('fr')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('it')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('ja')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('ko')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('zh')).i18n131DetailReclaim, "Reclaim and requeue");
    expect(lookupStrings(const Locale('es')).i18n131DetailSpecify, "Especificar");
    expect(lookupStrings(const Locale('en')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('pt')).i18n131DetailSpecify, "Especificar");
    expect(lookupStrings(const Locale('de')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('fr')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('it')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('ja')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('ko')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('zh')).i18n131DetailSpecify, "Specify");
    expect(lookupStrings(const Locale('es')).i18n131DetailDecompose, "Descomponer");
    expect(lookupStrings(const Locale('en')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('pt')).i18n131DetailDecompose, "Decompor");
    expect(lookupStrings(const Locale('de')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('fr')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('it')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('ja')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('ko')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('zh')).i18n131DetailDecompose, "Decompose");
    expect(lookupStrings(const Locale('es')).i18n131DetailNotifyWhenDone, "Avisarme cuando termine");
    expect(lookupStrings(const Locale('en')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('pt')).i18n131DetailNotifyWhenDone, "Avisar quando terminar");
    expect(lookupStrings(const Locale('de')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('fr')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('it')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('ja')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('ko')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('zh')).i18n131DetailNotifyWhenDone, "Notify me when it's done");
    expect(lookupStrings(const Locale('es')).i18n131DetailMuteNotifications, "Silenciar notificaciones");
    expect(lookupStrings(const Locale('en')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('pt')).i18n131DetailMuteNotifications, "Silenciar notificações");
    expect(lookupStrings(const Locale('de')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('fr')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('it')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('ja')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('ko')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('zh')).i18n131DetailMuteNotifications, "Mute notifications");
    expect(lookupStrings(const Locale('es')).i18n131DetailMuteNotificationsSub, "No avisar de cambios de estado de esta tarea, aunque los resultados de Kanban estén activados");
    expect(lookupStrings(const Locale('en')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
    expect(lookupStrings(const Locale('pt')).i18n131DetailMuteNotificationsSub, "Não avisar sobre mudanças de estado desta tarefa, mesmo com os resultados do Kanban ativados");
    expect(lookupStrings(const Locale('de')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
    expect(lookupStrings(const Locale('fr')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
    expect(lookupStrings(const Locale('it')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
    expect(lookupStrings(const Locale('ja')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
    expect(lookupStrings(const Locale('ko')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
    expect(lookupStrings(const Locale('zh')).i18n131DetailMuteNotificationsSub, "Don't notify status changes for this task, even if Kanban results are enabled");
  });
}
