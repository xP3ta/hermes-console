import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131RoutineTitle',
    'i18n131RoutineDescription',
    'i18n131RoutineBotLabel',
    'i18n131RoutineWhatLabel',
    'i18n131RoutineWhatHint',
    'i18n131RoutineWhatRequired',
    'i18n131RoutineWhenLabel',
    'i18n131RoutineCustomScheduleLabel',
    'i18n131RoutineCustomScheduleHint',
    'i18n131RoutineCustomScheduleRequired',
    'i18n131RoutineMoreOptions',
    'i18n131RoutineOptionalNameLabel',
    'i18n131RoutineOptionalNameHint',
    'i18n131RoutineCreate',
    'i18n131RoutineCreating',
    'i18n131RoutineGenericError',
    'i18n131RoutineDailyAtNine',
    'i18n131RoutineWeekdaysAtNine',
    'i18n131RoutineWeeklyMondayAtNine',
    'i18n131RoutineMonthlyAtNine',
    'i18n131RoutineHourly',
    'i18n131RoutineEveryFifteenMinutes',
    'i18n131RoutineCustom'
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
      expect(catalog.keys.where((key) => key.startsWith('i18n131Routine')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131RoutineTitle, "Nueva rutina");
    expect(lookupStrings(const Locale('en')).i18n131RoutineTitle, "New routine");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineTitle, "Nova rotina");
    expect(lookupStrings(const Locale('de')).i18n131RoutineTitle, "New routine");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineTitle, "New routine");
    expect(lookupStrings(const Locale('it')).i18n131RoutineTitle, "New routine");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineTitle, "New routine");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineTitle, "New routine");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineTitle, "New routine");
    expect(lookupStrings(const Locale('es')).i18n131RoutineDescription, "Programa algo para que este perfil lo haga por ti.");
    expect(lookupStrings(const Locale('en')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineDescription, "Programe algo para este perfil fazer por você.");
    expect(lookupStrings(const Locale('de')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('es')).i18n131RoutineBotLabel, "Perfil");
    expect(lookupStrings(const Locale('en')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineBotLabel, "Perfil");
    expect(lookupStrings(const Locale('de')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('it')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhatLabel, "Qué");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhatLabel, "O quê");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhatHint, "Describe qué debe hacer");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhatHint, "Descreva o que ele deve fazer");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhatRequired, "Escribe qué debe hacer el perfil.");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhatRequired, "Escreva o que o perfil deve fazer.");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhenLabel, "Cuándo");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhenLabel, "Quando");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCustomScheduleLabel, "Expresión cron");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCustomScheduleLabel, "Expressão cron");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCustomScheduleHint, "0 9 * * *");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCustomScheduleRequired, "Escribe una expresión cron.");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCustomScheduleRequired, "Enter a cron expression.");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCustomScheduleRequired, "Escreva uma expressão cron.");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCustomScheduleRequired, "Enter a cron expression.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCustomScheduleRequired, "Enter a cron expression.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCustomScheduleRequired, "Enter a cron expression.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCustomScheduleRequired, "Enter a cron expression.");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCustomScheduleRequired, "Enter a cron expression.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCustomScheduleRequired, "Enter a cron expression.");
    expect(lookupStrings(const Locale('es')).i18n131RoutineMoreOptions, "Más opciones");
    expect(lookupStrings(const Locale('en')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineMoreOptions, "Mais opções");
    expect(lookupStrings(const Locale('de')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('it')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('es')).i18n131RoutineOptionalNameLabel, "Nombre opcional");
    expect(lookupStrings(const Locale('en')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineOptionalNameLabel, "Nome opcional");
    expect(lookupStrings(const Locale('de')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('it')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('es')).i18n131RoutineOptionalNameHint, "Por ejemplo, Resumen de la mañana");
    expect(lookupStrings(const Locale('en')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineOptionalNameHint, "Por exemplo, Resumo da manhã");
    expect(lookupStrings(const Locale('de')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('it')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCreate, "Crear rutina");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCreate, "Criar rotina");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCreating, "Creando…");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCreating, "Criando…");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('es')).i18n131RoutineGenericError, "No se pudo crear la rutina. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineGenericError, "Não foi possível criar a rotina. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('es')).i18n131RoutineDailyAtNine, "Cada día · 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineDailyAtNine, "Todo dia · 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWeekdaysAtNine, "Días laborables · 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWeekdaysAtNine, "Dias úteis · 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWeeklyMondayAtNine, "Cada lunes · 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWeeklyMondayAtNine, "Toda segunda-feira · 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineMonthlyAtNine, "Cada mes · día 1, 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineMonthlyAtNine, "Todo mês · dia 1, 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineHourly, "Cada hora");
    expect(lookupStrings(const Locale('en')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineHourly, "A cada hora");
    expect(lookupStrings(const Locale('de')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('it')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('es')).i18n131RoutineEveryFifteenMinutes, "Cada 15 minutos");
    expect(lookupStrings(const Locale('en')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineEveryFifteenMinutes, "A cada 15 minutos");
    expect(lookupStrings(const Locale('de')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('it')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCustom, "Personalizado");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCustom, "Custom");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCustom, "Personalizado");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCustom, "Custom");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCustom, "Custom");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCustom, "Custom");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCustom, "Custom");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCustom, "Custom");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCustom, "Custom");
  });
}
