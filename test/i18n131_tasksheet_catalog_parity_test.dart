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
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "The task could not be assigned. Try again.");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "The task could not be assigned. Try again.");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "The task could not be assigned. Try again.");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "The task could not be assigned. Try again.");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "The task could not be assigned. Try again.");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetTheTaskCouldNotBeAssignedTry, "The task could not be assigned. Try again.");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetLow, "Baja");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetLow, "Baixa");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetLow, "Low");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetNormal, "Normal");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetHigh, "Alta");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetHigh, "Alta");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetHigh, "High");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetAssignTask, "Encargar tarea");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetAssignTask, "Atribuir tarefa");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetAssignTask, "Assign task");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetWhat, "Qué");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetWhat, "O quê");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetWhat, "What");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetWhatShouldThisProfileDo, "¿Qué debe hacer este perfil?");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetWhatShouldThisProfileDo, "O que este perfil deve fazer?");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetWhatShouldThisProfileDo, "What should this profile do?");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetDescribeTheTask, "Describe la tarea.");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetDescribeTheTask, "Descreva a tarefa.");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetDescribeTheTask, "Describe the task.");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetWhyOptional, "Para qué (opcional)");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetWhyOptional, "Por quê (opcional)");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetWhyOptional, "Why (optional)");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetAddContextOrTheExpectedResult, "Añade contexto o el resultado esperado.");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetAddContextOrTheExpectedResult, "Adicione contexto ou o resultado esperado.");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetAddContextOrTheExpectedResult, "Add context or the expected result.");
    expect(lookupStrings(const Locale('es')).i18n131TaskSheetPriority, "Prioridad");
    expect(lookupStrings(const Locale('en')).i18n131TaskSheetPriority, "Priority");
    expect(lookupStrings(const Locale('pt')).i18n131TaskSheetPriority, "Prioridade");
    expect(lookupStrings(const Locale('de')).i18n131TaskSheetPriority, "Priority");
    expect(lookupStrings(const Locale('fr')).i18n131TaskSheetPriority, "Priority");
    expect(lookupStrings(const Locale('it')).i18n131TaskSheetPriority, "Priority");
    expect(lookupStrings(const Locale('ja')).i18n131TaskSheetPriority, "Priority");
    expect(lookupStrings(const Locale('ko')).i18n131TaskSheetPriority, "Priority");
    expect(lookupStrings(const Locale('zh')).i18n131TaskSheetPriority, "Priority");
  });
}
