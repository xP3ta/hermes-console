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
    'i18n131TasksEffortLabel_none',
    'i18n131TasksEffortLabel_minimal',
    'i18n131TasksEffortLabel_low',
    'i18n131TasksEffortLabel_medium',
    'i18n131TasksEffortLabel_high',
    'i18n131TasksEffortLabel_xhigh',
    'i18n131TasksEffortLabel_max',
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
    expect(lookupStrings(const Locale('de')).i18n131TasksBulkPartialTitle, "Some tasks were not changed");
    expect(lookupStrings(const Locale('fr')).i18n131TasksBulkPartialTitle, "Some tasks were not changed");
    expect(lookupStrings(const Locale('it')).i18n131TasksBulkPartialTitle, "Some tasks were not changed");
    expect(lookupStrings(const Locale('ja')).i18n131TasksBulkPartialTitle, "Some tasks were not changed");
    expect(lookupStrings(const Locale('ko')).i18n131TasksBulkPartialTitle, "Some tasks were not changed");
    expect(lookupStrings(const Locale('zh')).i18n131TasksBulkPartialTitle, "Some tasks were not changed");
    expect(lookupStrings(const Locale('es')).i18n131TasksBulkPartial(3, 3), "3 archivadas; 3 no se pudieron cambiar.");
    expect(lookupStrings(const Locale('en')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksBulkPartial(3, 3), "3 arquivadas; 3 não puderam ser alteradas.");
    expect(lookupStrings(const Locale('de')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('it')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksBulkPartial(3, 3), "3 archived; 3 could not be changed.");
    expect(lookupStrings(const Locale('es')).i18n131TasksActionUnavailable, "Esta operación no está disponible en el servidor.");
    expect(lookupStrings(const Locale('en')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksActionUnavailable, "Esta operação não está disponível no servidor.");
    expect(lookupStrings(const Locale('de')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('it')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksActionUnavailable, "This operation is not available on the server.");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecify, "Especificar");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecify, "Especificar");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecify, "Specify");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecifyTitle, "Especificar tarea");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecifyTitle, "Especificar tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecifyTitle, "Specify task");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecifyBody, "Hermes usará el modelo auxiliar para completar esta tarea de triage. Puede tardar varios minutos.");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecifyBody, "O Hermes usará o modelo auxiliar para detalhar esta tarefa de triagem. Pode levar vários minutos.");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecifyBody, "Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.");
    expect(lookupStrings(const Locale('es')).i18n131TasksSpecifyStarted, "La tarea se ha especificado.");
    expect(lookupStrings(const Locale('en')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSpecifyStarted, "A tarefa foi especificada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('it')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSpecifyStarted, "The task was specified.");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecompose, "Descomponer");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecompose, "Decompor");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecompose, "Decompose");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecomposeTitle, "Descomponer en subtareas");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecomposeTitle, "Decompor em subtarefas");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecomposeTitle, "Decompose into child tasks");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecomposeBody, "Hermes creará un grafo de subtareas y las asignará a perfiles compatibles. Puede tardar varios minutos.");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecomposeBody, "O Hermes criará um grafo de subtarefas e as atribuirá a perfis compatíveis. Pode levar vários minutos.");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecomposeBody, "Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.");
    expect(lookupStrings(const Locale('es')).i18n131TasksDecomposeResult(3), "Descomposición completada: 3 subtareas.");
    expect(lookupStrings(const Locale('en')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDecomposeResult(3), "Decomposição concluída: 3 subtarefas.");
    expect(lookupStrings(const Locale('de')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('it')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDecomposeResult(3), "Decomposition complete: 3 child tasks.");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentTooLarge, "El adjunto supera el límite oficial de 25 MiB.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentTooLarge, "O anexo excede o limite oficial de 25 MiB.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentTooLarge, "The attachment exceeds the official 25 MiB limit.");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentUnavailable, "Android no pudo proporcionar este archivo.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentUnavailable, "O Android não pôde fornecer este arquivo.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentUnavailable, "Android could not provide this file.");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentUploaded, "Adjunto subido.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentUploaded, "Anexo enviado.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentUploaded, "Attachment uploaded.");
    expect(lookupStrings(const Locale('es')).i18n131TasksSaveAttachment, "Guardar adjunto");
    expect(lookupStrings(const Locale('en')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('pt')).i18n131TasksSaveAttachment, "Salvar anexo");
    expect(lookupStrings(const Locale('de')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('fr')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('it')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('ja')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('ko')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('zh')).i18n131TasksSaveAttachment, "Save attachment");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentSaved, "Adjunto guardado.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentSaved, "Anexo salvo.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentSaved, "Attachment saved.");
    expect(lookupStrings(const Locale('es')).i18n131TasksDeleteAttachment, "Eliminar adjunto");
    expect(lookupStrings(const Locale('en')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDeleteAttachment, "Excluir anexo");
    expect(lookupStrings(const Locale('de')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('it')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDeleteAttachment, "Delete attachment");
    expect(lookupStrings(const Locale('es')).i18n131TasksDeleteAttachmentBody("value {other}"), "¿Eliminar «value {other}» del servidor? Esta acción no se puede deshacer.");
    expect(lookupStrings(const Locale('en')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDeleteAttachmentBody("value {other}"), "Excluir “value {other}” do servidor? Esta ação não pode ser desfeita.");
    expect(lookupStrings(const Locale('de')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('it')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDeleteAttachmentBody("value {other}"), "Delete “value {other}” from the server? This cannot be undone.");
    expect(lookupStrings(const Locale('es')).i18n131TasksDelete, "Eliminar");
    expect(lookupStrings(const Locale('en')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('pt')).i18n131TasksDelete, "Excluir");
    expect(lookupStrings(const Locale('de')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('fr')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('it')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('ja')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('ko')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('zh')).i18n131TasksDelete, "Delete");
    expect(lookupStrings(const Locale('es')).i18n131TasksAttachmentDeleted, "Adjunto eliminado.");
    expect(lookupStrings(const Locale('en')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAttachmentDeleted, "Anexo excluído.");
    expect(lookupStrings(const Locale('de')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('it')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAttachmentDeleted, "Attachment deleted.");
    expect(lookupStrings(const Locale('es')).i18n131TasksWorkerLog, "Log del worker");
    expect(lookupStrings(const Locale('en')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('pt')).i18n131TasksWorkerLog, "Log do worker");
    expect(lookupStrings(const Locale('de')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('fr')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('it')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('ja')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('ko')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('zh')).i18n131TasksWorkerLog, "Worker log");
    expect(lookupStrings(const Locale('es')).i18n131TasksNoLog, "Esta tarea todavía no tiene log.");
    expect(lookupStrings(const Locale('en')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksNoLog, "Esta tarefa ainda não tem log.");
    expect(lookupStrings(const Locale('de')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('it')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksNoLog, "This task does not have a log yet.");
    expect(lookupStrings(const Locale('es')).i18n131TasksLogTruncated, "Se muestra únicamente la cola más reciente del log.");
    expect(lookupStrings(const Locale('en')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksLogTruncated, "Apenas o trecho mais recente do log é exibido.");
    expect(lookupStrings(const Locale('de')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('it')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksLogTruncated, "Only the most recent log tail is shown.");
    expect(lookupStrings(const Locale('es')).i18n131TasksRunInspection, "Estado de la ejecución");
    expect(lookupStrings(const Locale('en')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('pt')).i18n131TasksRunInspection, "Estado da execução");
    expect(lookupStrings(const Locale('de')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('fr')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('it')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('ja')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('ko')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('zh')).i18n131TasksRunInspection, "Run inspection");
    expect(lookupStrings(const Locale('es')).i18n131TasksAlive, "Activo");
    expect(lookupStrings(const Locale('en')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('pt')).i18n131TasksAlive, "Ativo");
    expect(lookupStrings(const Locale('de')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('fr')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('it')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('ja')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('ko')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('zh')).i18n131TasksAlive, "Alive");
    expect(lookupStrings(const Locale('es')).i18n131TasksYes, "Sí");
    expect(lookupStrings(const Locale('en')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('pt')).i18n131TasksYes, "Sim");
    expect(lookupStrings(const Locale('de')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('fr')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('it')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('ja')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('ko')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('zh')).i18n131TasksYes, "Yes");
    expect(lookupStrings(const Locale('es')).i18n131TasksStatus, "Estado");
    expect(lookupStrings(const Locale('en')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('pt')).i18n131TasksStatus, "Estado");
    expect(lookupStrings(const Locale('de')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('fr')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('it')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('ja')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('ko')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('zh')).i18n131TasksStatus, "Status");
    expect(lookupStrings(const Locale('es')).i18n131TasksThreads, "Hilos");
    expect(lookupStrings(const Locale('en')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('pt')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('de')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('fr')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('it')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('ja')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('ko')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('zh')).i18n131TasksThreads, "Threads");
    expect(lookupStrings(const Locale('es')).i18n131TasksReason, "Motivo");
    expect(lookupStrings(const Locale('en')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReason, "Motivo");
    expect(lookupStrings(const Locale('de')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('it')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReason, "Reason");
    expect(lookupStrings(const Locale('es')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('en')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('pt')).i18n131TasksError, "Erro");
    expect(lookupStrings(const Locale('de')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('fr')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('it')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('ja')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('ko')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('zh')).i18n131TasksError, "Error");
    expect(lookupStrings(const Locale('es')).i18n131TasksTerminate, "Terminar");
    expect(lookupStrings(const Locale('en')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTerminate, "Encerrar");
    expect(lookupStrings(const Locale('de')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('it')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTerminate, "Terminate");
    expect(lookupStrings(const Locale('es')).i18n131TasksTerminateTitle, "Terminar ejecución");
    expect(lookupStrings(const Locale('en')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTerminateTitle, "Encerrar execução");
    expect(lookupStrings(const Locale('de')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('it')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTerminateTitle, "Terminate run");
    expect(lookupStrings(const Locale('es')).i18n131TasksTerminateBody(3), "Se detendrá el worker de la ejecución #3 y la tarea volverá a la cola. ¿Continuar?");
    expect(lookupStrings(const Locale('en')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTerminateBody(3), "O worker da execução #3 será interrompido e a tarefa voltará para a fila. Continuar?");
    expect(lookupStrings(const Locale('de')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('it')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTerminateBody(3), "The worker for run #3 will stop and the task will return to the queue. Continue?");
    expect(lookupStrings(const Locale('es')).i18n131TasksRunTerminated, "Ejecución terminada y reencolada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksRunTerminated, "Execução encerrada e reenfileirada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('it')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksRunTerminated, "Run terminated and requeued.");
    expect(lookupStrings(const Locale('es')).i18n131TasksReclaim, "Recuperar");
    expect(lookupStrings(const Locale('en')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReclaim, "Recuperar");
    expect(lookupStrings(const Locale('de')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('it')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReclaim, "Reclaim");
    expect(lookupStrings(const Locale('es')).i18n131TasksReclaimTitle, "Recuperar tarea atascada");
    expect(lookupStrings(const Locale('en')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReclaimTitle, "Recuperar tarefa travada");
    expect(lookupStrings(const Locale('de')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('it')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReclaimTitle, "Reclaim stuck task");
    expect(lookupStrings(const Locale('es')).i18n131TasksReclaimBody, "Se detendrá el worker actual y la tarea volverá a «En cola». Úsalo solo si la ejecución está atascada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReclaimBody, "O worker atual será interrompido e a tarefa voltará para “Em fila”. Use apenas se a execução estiver travada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('it')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReclaimBody, "The current worker will stop and the task will return to the queue. Use this only for a stuck run.");
    expect(lookupStrings(const Locale('es')).i18n131TasksTaskReclaimed, "Tarea recuperada y reencolada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTaskReclaimed, "Tarefa recuperada e reenfileirada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('it')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTaskReclaimed, "Task reclaimed and requeued.");
    expect(lookupStrings(const Locale('es')).i18n131TasksChooseProfile, "Elegir perfil");
    expect(lookupStrings(const Locale('en')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('pt')).i18n131TasksChooseProfile, "Escolher perfil");
    expect(lookupStrings(const Locale('de')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('fr')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('it')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('ja')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('ko')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('zh')).i18n131TasksChooseProfile, "Choose profile");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassign, "Reasignar");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassign, "Reatribuir");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassign, "Reassign");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassignTitle, "Reasignar tarea");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassignTitle, "Reatribuir tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassignTitle, "Reassign task");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassignBodyReclaims("value {other}"), "La tarea se asignará a «value {other}». El worker actual se detendrá primero.");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassignBodyReclaims("value {other}"), "A tarefa será atribuída a “value {other}”. O worker atual será interrompido primeiro.");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassignBodyReclaims("value {other}"), "The task will be assigned to “value {other}”. The current worker will be stopped first.");
    expect(lookupStrings(const Locale('es')).i18n131TasksReassignBody("value {other}"), "La tarea se asignará a «value {other}».");
    expect(lookupStrings(const Locale('en')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReassignBody("value {other}"), "A tarefa será atribuída a “value {other}”.");
    expect(lookupStrings(const Locale('de')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('it')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReassignBody("value {other}"), "The task will be assigned to “value {other}”.");
    expect(lookupStrings(const Locale('es')).i18n131TasksTaskReassigned, "Tarea reasignada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksTaskReassigned, "Tarefa reatribuída.");
    expect(lookupStrings(const Locale('de')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('it')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksTaskReassigned, "Task reassigned.");
    expect(lookupStrings(const Locale('es')).i18n131TasksModelOptionsUnavailable, "Este servidor no publica opciones de modelo para Kanban.");
    expect(lookupStrings(const Locale('en')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksModelOptionsUnavailable, "Este servidor não publica opções de modelo para o Kanban.");
    expect(lookupStrings(const Locale('de')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('it')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksModelOptionsUnavailable, "This server does not publish Kanban model options.");
    expect(lookupStrings(const Locale('es')).i18n131TasksChooseModel, "Modelo para esta tarea");
    expect(lookupStrings(const Locale('en')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('pt')).i18n131TasksChooseModel, "Modelo para esta tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('fr')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('it')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('ja')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('ko')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('zh')).i18n131TasksChooseModel, "Model for this task");
    expect(lookupStrings(const Locale('es')).i18n131TasksInheritModel, "Heredar modelo del perfil");
    expect(lookupStrings(const Locale('en')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('pt')).i18n131TasksInheritModel, "Herdar modelo do perfil");
    expect(lookupStrings(const Locale('de')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('fr')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('it')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('ja')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('ko')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('zh')).i18n131TasksInheritModel, "Inherit model from profile");
    expect(lookupStrings(const Locale('es')).i18n131TasksReasoningEffort, "Esfuerzo de razonamiento");
    expect(lookupStrings(const Locale('en')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('pt')).i18n131TasksReasoningEffort, "Esforço de raciocínio");
    expect(lookupStrings(const Locale('de')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('fr')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('it')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('ja')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('ko')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('zh')).i18n131TasksReasoningEffort, "Reasoning effort");
    expect(lookupStrings(const Locale('es')).i18n131TasksInheritEffort, "Heredar esfuerzo del perfil");
    expect(lookupStrings(const Locale('en')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('pt')).i18n131TasksInheritEffort, "Herdar esforço do perfil");
    expect(lookupStrings(const Locale('de')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('fr')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('it')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('ja')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('ko')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('zh')).i18n131TasksInheritEffort, "Inherit effort from profile");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabel_none, "Desactivado");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabel_none, "Off");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabel_none, "Desativado");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabel_none, "Off");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabel_none, "Off");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabel_none, "Off");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabel_none, "Off");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabel_none, "Off");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabel_none, "Off");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabel_minimal, "Mínimo");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabel_minimal, "Minimal");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabel_minimal, "Mínimo");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabel_minimal, "Minimal");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabel_minimal, "Minimal");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabel_minimal, "Minimal");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabel_minimal, "Minimal");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabel_minimal, "Minimal");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabel_minimal, "Minimal");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabel_low, "Bajo");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabel_low, "Low");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabel_low, "Baixo");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabel_low, "Low");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabel_low, "Low");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabel_low, "Low");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabel_low, "Low");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabel_low, "Low");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabel_low, "Low");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabel_medium, "Medio");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabel_medium, "Medium");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabel_medium, "Médio");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabel_medium, "Medium");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabel_medium, "Medium");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabel_medium, "Medium");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabel_medium, "Medium");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabel_medium, "Medium");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabel_medium, "Medium");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabel_high, "Alto");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabel_high, "High");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabel_high, "Alto");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabel_high, "High");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabel_high, "High");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabel_high, "High");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabel_high, "High");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabel_high, "High");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabel_high, "High");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabel_xhigh, "Muy alto");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabel_xhigh, "XHigh");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabel_xhigh, "Muito alto");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabel_xhigh, "XHigh");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabel_xhigh, "XHigh");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabel_xhigh, "XHigh");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabel_xhigh, "XHigh");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabel_xhigh, "XHigh");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabel_xhigh, "XHigh");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabel_max, "Máximo");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabel_max, "Max");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabel_max, "Máximo");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabel_max, "Max");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabel_max, "Max");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabel_max, "Max");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabel_max, "Max");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabel_max, "Max");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabel_max, "Max");
    expect(lookupStrings(const Locale('es')).i18n131TasksApplyModelTitle, "Aplicar configuración de modelo");
    expect(lookupStrings(const Locale('en')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('pt')).i18n131TasksApplyModelTitle, "Aplicar configuração de modelo");
    expect(lookupStrings(const Locale('de')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('fr')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('it')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('ja')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('ko')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('zh')).i18n131TasksApplyModelTitle, "Apply model configuration");
    expect(lookupStrings(const Locale('es')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Modelo: value {other}\nRazonamiento: value {other}");
    expect(lookupStrings(const Locale('en')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('pt')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Modelo: value {other}\nRaciocínio: value {other}");
    expect(lookupStrings(const Locale('de')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('fr')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('it')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('ja')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('ko')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('zh')).i18n131TasksApplyModelBody("value {other}", "value {other}"), "Model: value {other}\nReasoning: value {other}");
    expect(lookupStrings(const Locale('es')).i18n131TasksApply, "Aplicar");
    expect(lookupStrings(const Locale('en')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('pt')).i18n131TasksApply, "Aplicar");
    expect(lookupStrings(const Locale('de')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('fr')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('it')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('ja')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('ko')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('zh')).i18n131TasksApply, "Apply");
    expect(lookupStrings(const Locale('es')).i18n131TasksModelApplied, "Configuración de modelo aplicada.");
    expect(lookupStrings(const Locale('en')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('pt')).i18n131TasksModelApplied, "Configuração de modelo aplicada.");
    expect(lookupStrings(const Locale('de')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('fr')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('it')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('ja')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('ko')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('zh')).i18n131TasksModelApplied, "Model configuration applied.");
    expect(lookupStrings(const Locale('es')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('en')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('pt')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('de')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('fr')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('it')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('ja')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('ko')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('zh')).i18n131TasksNo, "No");
    expect(lookupStrings(const Locale('es')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('en')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('pt')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('de')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('fr')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('it')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('ja')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('ko')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('zh')).i18n131TasksMemory, "RAM");
    expect(lookupStrings(const Locale('es')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('en')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('pt')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('de')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('fr')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('it')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('ja')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('ko')).i18n131TasksEffortLabelUltra, "Ultra");
    expect(lookupStrings(const Locale('zh')).i18n131TasksEffortLabelUltra, "Ultra");
  });
}
