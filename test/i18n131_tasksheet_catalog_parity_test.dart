import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131TaskSheetTheTaskCouldNotBeAssignedTry',
    'i18n131TaskSheetLow',
    'i18n131TaskSheetNormal',
    'i18n131TaskSheetHigh',
    'i18n131TaskSheetAssignTask',
    'i18n131TaskSheetWhat',
    'i18n131TaskSheetWhatShouldThisProfileDo',
    'i18n131TaskSheetDescribeTheTask',
    'i18n131TaskSheetWhyOptional',
    'i18n131TaskSheetAddContextOrTheExpectedResult',
    'i18n131TaskSheetPriority'
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
      expect(catalog.keys.where((key) => key.startsWith('i18n131TaskSheet')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "No se pudo encargar la tarea. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "The task could not be assigned. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "Não foi possível atribuir a tarefa. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "Die Aufgabe konnte nicht zugewiesen werden. Versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "Impossible d’attribuer la tâche. Réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "Impossibile assegnare l’attività. Riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "タスクを割り当てできませんでした。再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "작업을 배정하지 못했습니다. 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "无法分配任务，请重试。");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetLow, "Baja");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetLow, "Baixa");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetLow, "Niedrig");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetLow, "Faible");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetLow, "Bassa");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetLow, "低");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetLow, "낮음");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetLow, "低");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetNormal, "Normale");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetNormal, "Normale");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetNormal, "通常");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetNormal, "보통");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetNormal, "普通");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetHigh, "Alta");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetHigh, "Alta");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetHigh, "Hoch");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetHigh, "Élevée");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetHigh, "Alta");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetHigh, "高");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetHigh, "높음");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetHigh, "高");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetAssignTask, "Encargar tarea");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetAssignTask, "Atribuir tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetAssignTask, "Aufgabe zuweisen");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetAssignTask, "Attribuer la tâche");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetAssignTask, "Assegna attività");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetAssignTask, "タスクを割り当て");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetAssignTask, "작업 배정");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetAssignTask, "分配任务");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetWhat, "Qué");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetWhat, "O quê");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetWhat, "Was");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetWhat, "Quoi");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetWhat, "Cosa");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetWhat, "内容");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetWhat, "할 일");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetWhat, "任务内容");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetWhatShouldThisProfileDo, "¿Qué debe hacer este perfil?");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetWhatShouldThisProfileDo, "O que este perfil deve fazer?");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetWhatShouldThisProfileDo, "Was soll dieses Profil tun?");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetWhatShouldThisProfileDo, "Que doit faire ce profil ?");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetWhatShouldThisProfileDo, "Cosa dovrebbe fare questo profilo?");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetWhatShouldThisProfileDo, "このプロフィールに何をさせますか？");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetWhatShouldThisProfileDo, "이 프로필이 어떤 일을 할까요?");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetWhatShouldThisProfileDo, "希望此配置档做什么？");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetDescribeTheTask, "Describe la tarea.");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetDescribeTheTask, "Descreva a tarefa.");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetDescribeTheTask, "Beschreibe die Aufgabe.");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetDescribeTheTask, "Décris la tâche.");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetDescribeTheTask, "Descrivi l’attività.");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetDescribeTheTask, "タスクの内容を入力してください。");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetDescribeTheTask, "작업을 설명하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetDescribeTheTask, "描述任务。");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetWhyOptional, "Para qué (opcional)");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetWhyOptional, "Por quê (opcional)");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetWhyOptional, "Warum (optional)");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetWhyOptional, "Pourquoi (facultatif)");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetWhyOptional, "Perché (facoltativo)");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetWhyOptional, "目的（任意）");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetWhyOptional, "이유(선택 사항)");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetWhyOptional, "原因（可选）");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetAddContextOrTheExpectedResult, "Añade contexto o el resultado esperado.");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetAddContextOrTheExpectedResult, "Adicione contexto ou o resultado esperado.");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetAddContextOrTheExpectedResult, "Ergänze den Kontext oder das erwartete Ergebnis.");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetAddContextOrTheExpectedResult, "Ajoute du contexte ou le résultat attendu.");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetAddContextOrTheExpectedResult, "Aggiungi il contesto o il risultato atteso.");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetAddContextOrTheExpectedResult, "背景や期待する結果を入力してください。");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetAddContextOrTheExpectedResult, "배경이나 예상 결과를 추가하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetAddContextOrTheExpectedResult, "补充背景或预期结果。");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetPriority, "Prioridad");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetPriority, "Priority");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetPriority, "Prioridade");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetPriority, "Priorität");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetPriority, "Priorité");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetPriority, "Priorità");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetPriority, "優先度");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetPriority, "우선순위");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetPriority, "优先级");
  });
}
