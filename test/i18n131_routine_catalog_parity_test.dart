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
    expect(lookupStrings(const Locale('de')).i18n131RoutineTitle, "Neue Routine");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineTitle, "Nouvelle routine");
    expect(lookupStrings(const Locale('it')).i18n131RoutineTitle, "Nuova routine");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineTitle, "新しいルーチン");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineTitle, "새 루틴");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineTitle, "新建例行任务");
    expect(lookupStrings(const Locale('es')).i18n131RoutineDescription, "Programa algo para que este perfil lo haga por ti.");
    expect(lookupStrings(const Locale('en')).i18n131RoutineDescription, "Schedule something for this profile to do for you.");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineDescription, "Programe algo para este perfil fazer por você.");
    expect(lookupStrings(const Locale('de')).i18n131RoutineDescription, "Plane etwas, das dieses Profil für dich erledigen soll.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineDescription, "Planifie une action que ce profil effectuera pour toi.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineDescription, "Programma un’attività che questo profilo svolgerà per te.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineDescription, "このプロフィールに実行させる内容と日時を設定します。");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineDescription, "이 프로필이 수행할 작업을 예약하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineDescription, "安排此配置档为你执行任务。");
    expect(lookupStrings(const Locale('es')).i18n131RoutineBotLabel, "Perfil");
    expect(lookupStrings(const Locale('en')).i18n131RoutineBotLabel, "Profile");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineBotLabel, "Perfil");
    expect(lookupStrings(const Locale('de')).i18n131RoutineBotLabel, "Profil");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineBotLabel, "Profil");
    expect(lookupStrings(const Locale('it')).i18n131RoutineBotLabel, "Profilo");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineBotLabel, "プロフィール");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineBotLabel, "프로필");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineBotLabel, "配置档");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhatLabel, "Qué");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhatLabel, "What");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhatLabel, "O quê");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhatLabel, "Was");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhatLabel, "Quoi");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhatLabel, "Cosa");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhatLabel, "内容");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhatLabel, "할 일");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhatLabel, "任务内容");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhatHint, "Describe qué debe hacer");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhatHint, "Describe what it should do");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhatHint, "Descreva o que ele deve fazer");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhatHint, "Beschreibe, was es tun soll");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhatHint, "Décris ce qu’il doit faire");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhatHint, "Descrivi cosa deve fare");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhatHint, "実行させる内容を入力");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhatHint, "수행할 작업을 설명하세요");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhatHint, "描述要执行的任务");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhatRequired, "Escribe qué debe hacer el perfil.");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhatRequired, "Describe what the profile should do.");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhatRequired, "Escreva o que o perfil deve fazer.");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhatRequired, "Beschreibe, was das Profil tun soll.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhatRequired, "Décris ce que le profil doit faire.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhatRequired, "Descrivi cosa dovrebbe fare il profilo.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhatRequired, "プロフィールに実行させる内容を入力してください。");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhatRequired, "프로필이 수행할 작업을 설명하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhatRequired, "请描述希望此配置档执行的任务。");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWhenLabel, "Cuándo");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWhenLabel, "When");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWhenLabel, "Quando");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWhenLabel, "Wann");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWhenLabel, "Quand");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWhenLabel, "Quando");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWhenLabel, "実行日時");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWhenLabel, "실행 시점");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWhenLabel, "执行时间");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCustomScheduleLabel, "Expresión cron");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCustomScheduleLabel, "Cron expression");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCustomScheduleLabel, "Expressão cron");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCustomScheduleLabel, "Cron-Ausdruck");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCustomScheduleLabel, "Expression cron");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCustomScheduleLabel, "Espressione cron");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCustomScheduleLabel, "cron式");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCustomScheduleLabel, "크론 표현식");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCustomScheduleLabel, "Cron表达式");
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
    expect(lookupStrings(const Locale('de')).i18n131RoutineCustomScheduleRequired, "Gib einen Cron-Ausdruck ein.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCustomScheduleRequired, "Saisis une expression cron.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCustomScheduleRequired, "Inserisci un’espressione cron.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCustomScheduleRequired, "cron式を入力してください。");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCustomScheduleRequired, "크론 표현식을 입력하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCustomScheduleRequired, "请输入Cron表达式。");
    expect(lookupStrings(const Locale('es')).i18n131RoutineMoreOptions, "Más opciones");
    expect(lookupStrings(const Locale('en')).i18n131RoutineMoreOptions, "More options");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineMoreOptions, "Mais opções");
    expect(lookupStrings(const Locale('de')).i18n131RoutineMoreOptions, "Weitere Optionen");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineMoreOptions, "Plus d’options");
    expect(lookupStrings(const Locale('it')).i18n131RoutineMoreOptions, "Altre opzioni");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineMoreOptions, "その他のオプション");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineMoreOptions, "추가 옵션");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineMoreOptions, "更多选项");
    expect(lookupStrings(const Locale('es')).i18n131RoutineOptionalNameLabel, "Nombre opcional");
    expect(lookupStrings(const Locale('en')).i18n131RoutineOptionalNameLabel, "Optional name");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineOptionalNameLabel, "Nome opcional");
    expect(lookupStrings(const Locale('de')).i18n131RoutineOptionalNameLabel, "Optionaler Name");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineOptionalNameLabel, "Nom facultatif");
    expect(lookupStrings(const Locale('it')).i18n131RoutineOptionalNameLabel, "Nome facoltativo");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineOptionalNameLabel, "名前（任意）");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineOptionalNameLabel, "이름(선택 사항)");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineOptionalNameLabel, "名称（可选）");
    expect(lookupStrings(const Locale('es')).i18n131RoutineOptionalNameHint, "Por ejemplo, Resumen de la mañana");
    expect(lookupStrings(const Locale('en')).i18n131RoutineOptionalNameHint, "For example, Morning brief");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineOptionalNameHint, "Por exemplo, Resumo da manhã");
    expect(lookupStrings(const Locale('de')).i18n131RoutineOptionalNameHint, "Zum Beispiel: Morgenübersicht");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineOptionalNameHint, "Par exemple, Point du matin");
    expect(lookupStrings(const Locale('it')).i18n131RoutineOptionalNameHint, "Ad esempio, Riepilogo del mattino");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineOptionalNameHint, "例：朝のまとめ");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineOptionalNameHint, "예: 아침 브리핑");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineOptionalNameHint, "例如：晨间简报");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCreate, "Crear rutina");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCreate, "Create routine");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCreate, "Criar rotina");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCreate, "Routine erstellen");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCreate, "Créer la routine");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCreate, "Crea routine");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCreate, "ルーチンを作成");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCreate, "루틴 만들기");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCreate, "创建例行任务");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCreating, "Creando…");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCreating, "Creating…");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCreating, "Criando…");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCreating, "Wird erstellt…");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCreating, "Création…");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCreating, "Creazione…");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCreating, "作成中…");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCreating, "생성 중…");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCreating, "正在创建…");
    expect(lookupStrings(const Locale('es')).i18n131RoutineGenericError, "No se pudo crear la rutina. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131RoutineGenericError, "The routine could not be created. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineGenericError, "Não foi possível criar a rotina. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131RoutineGenericError, "Die Routine konnte nicht erstellt werden. Versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineGenericError, "Impossible de créer la routine. Réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131RoutineGenericError, "Impossibile creare la routine. Riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineGenericError, "ルーチンを作成できませんでした。再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineGenericError, "루틴을 만들지 못했습니다. 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineGenericError, "无法创建例行任务，请重试。");
    expect(lookupStrings(const Locale('es')).i18n131RoutineDailyAtNine, "Cada día · 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineDailyAtNine, "Every day · 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineDailyAtNine, "Todo dia · 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineDailyAtNine, "Täglich · 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineDailyAtNine, "Tous les jours · 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineDailyAtNine, "Ogni giorno · 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineDailyAtNine, "毎日・09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineDailyAtNine, "매일 · 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineDailyAtNine, "每天 · 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWeekdaysAtNine, "Días laborables · 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWeekdaysAtNine, "Weekdays · 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWeekdaysAtNine, "Dias úteis · 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWeekdaysAtNine, "Montag bis Freitag · 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWeekdaysAtNine, "Du lundi au vendredi · 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWeekdaysAtNine, "Dal lunedì al venerdì · 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWeekdaysAtNine, "月〜金・09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWeekdaysAtNine, "평일 · 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWeekdaysAtNine, "每周一至周五 · 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineWeeklyMondayAtNine, "Cada lunes · 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineWeeklyMondayAtNine, "Every Monday · 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineWeeklyMondayAtNine, "Toda segunda-feira · 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineWeeklyMondayAtNine, "Jeden Montag · 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineWeeklyMondayAtNine, "Tous les lundis · 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineWeeklyMondayAtNine, "Ogni lunedì · 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineWeeklyMondayAtNine, "毎週月曜日・09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineWeeklyMondayAtNine, "매주 월요일 · 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineWeeklyMondayAtNine, "每周一 · 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineMonthlyAtNine, "Cada mes · día 1, 09:00");
    expect(lookupStrings(const Locale('en')).i18n131RoutineMonthlyAtNine, "Every month · day 1, 09:00");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineMonthlyAtNine, "Todo mês · dia 1, 09:00");
    expect(lookupStrings(const Locale('de')).i18n131RoutineMonthlyAtNine, "Jeden Monat · am 1., 09:00");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineMonthlyAtNine, "Tous les mois · le 1er à 09:00");
    expect(lookupStrings(const Locale('it')).i18n131RoutineMonthlyAtNine, "Ogni mese · giorno 1, 09:00");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineMonthlyAtNine, "毎月1日・09:00");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineMonthlyAtNine, "매월 · 1일 09:00");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineMonthlyAtNine, "每月1日 · 09:00");
    expect(lookupStrings(const Locale('es')).i18n131RoutineHourly, "Cada hora");
    expect(lookupStrings(const Locale('en')).i18n131RoutineHourly, "Every hour");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineHourly, "A cada hora");
    expect(lookupStrings(const Locale('de')).i18n131RoutineHourly, "Jede Stunde");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineHourly, "Toutes les heures");
    expect(lookupStrings(const Locale('it')).i18n131RoutineHourly, "Ogni ora");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineHourly, "1時間ごと");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineHourly, "매시간");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineHourly, "每小时");
    expect(lookupStrings(const Locale('es')).i18n131RoutineEveryFifteenMinutes, "Cada 15 minutos");
    expect(lookupStrings(const Locale('en')).i18n131RoutineEveryFifteenMinutes, "Every 15 minutes");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineEveryFifteenMinutes, "A cada 15 minutos");
    expect(lookupStrings(const Locale('de')).i18n131RoutineEveryFifteenMinutes, "Alle 15 Minuten");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineEveryFifteenMinutes, "Toutes les 15 minutes");
    expect(lookupStrings(const Locale('it')).i18n131RoutineEveryFifteenMinutes, "Ogni 15 minuti");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineEveryFifteenMinutes, "15分ごと");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineEveryFifteenMinutes, "15분마다");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineEveryFifteenMinutes, "每15分钟");
    expect(lookupStrings(const Locale('es')).i18n131RoutineCustom, "Personalizado");
    expect(lookupStrings(const Locale('en')).i18n131RoutineCustom, "Custom");
    expect(lookupStrings(const Locale('pt')).i18n131RoutineCustom, "Personalizado");
    expect(lookupStrings(const Locale('de')).i18n131RoutineCustom, "Benutzerdefiniert");
    expect(lookupStrings(const Locale('fr')).i18n131RoutineCustom, "Personnalisé");
    expect(lookupStrings(const Locale('it')).i18n131RoutineCustom, "Personalizzata");
    expect(lookupStrings(const Locale('ja')).i18n131RoutineCustom, "カスタム");
    expect(lookupStrings(const Locale('ko')).i18n131RoutineCustom, "직접 설정");
    expect(lookupStrings(const Locale('zh')).i18n131RoutineCustom, "自定义");
  });
}
