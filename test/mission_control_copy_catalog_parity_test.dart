import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/mission_control_copy.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart'
    show resolveNotificationLang;
import 'package:hermes_android/l10n/app_localizations.dart';

Map<String, dynamic> _catalog(String lang) =>
    jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
        as Map<String, dynamic>;

Map<String, int> _arguments(String text) {
  final result = <String, int>{};
  for (final match in RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}').allMatches(text)) {
    result.update(match.group(0)!, (count) => count + 1, ifAbsent: () => 1);
  }
  return result;
}

void main() {
  const expectedKeys = <String>{
    'i18n131McActiveNow',
    'i18n131McActivity',
    'i18n131McActivityLabelSessionUpdated',
    'i18n131McActivityLabelTaskBlocked',
    'i18n131McActivityLabelTaskCompleted',
    'i18n131McActivityLabelTaskCreated',
    'i18n131McActivityLabelTaskStarted',
    'i18n131McAdvanced',
    'i18n131McAgentCreated',
    'i18n131McAgentDescriptionHint',
    'i18n131McAgentDescriptionLabel',
    'i18n131McAgentNameHint',
    'i18n131McAgentNameInvalid',
    'i18n131McAgentNameLabel',
    'i18n131McAgentNameTaken',
    'i18n131McAgentTitleHint',
    'i18n131McAgentTitleLabel',
    'i18n131McAllAgents',
    'i18n131McApprovals',
    'i18n131McAttentionSummaryOne',
    'i18n131McAttentionSummaryOther',
    'i18n131McBlocked',
    'i18n131McBotChat',
    'i18n131McBotDisplayName',
    'i18n131McBotDisplayNameHint',
    'i18n131McBotEditorSaveFailed',
    'i18n131McBotEditorSaved',
    'i18n131McBotRosterUpdateFailed',
    'i18n131McBotSpriteEmpty',
    'i18n131McBotSpriteHint',
    'i18n131McBotSpriteLoadFailed',
    'i18n131McBotSpriteSearchHint',
    'i18n131McBotSpriteUnsupported',
    'i18n131McChooseProfiles',
    'i18n131McChooseSharedMembers',
    'i18n131McClearSearch',
    'i18n131McCloneFresh',
    'i18n131McCloneFromLabel',
    'i18n131McCreateAgentError',
    'i18n131McCreateAgentSubmit',
    'i18n131McCreateAgentSubtitle',
    'i18n131McCreateOrganization',
    'i18n131McDelete',
    'i18n131McDeleteOrganizationBody',
    'i18n131McDeleteOrganizationTitle',
    'i18n131McEditBotTitle',
    'i18n131McEditOrganization',
    'i18n131McInput',
    'i18n131McLoading',
    'i18n131McManagerLabel',
    'i18n131McMemory',
    'i18n131McModelInherited',
    'i18n131McModelLabel',
    'i18n131McNeedsYou',
    'i18n131McNewAgent',
    'i18n131McNoBots',
    'i18n131McNoMatchingAgents',
    'i18n131McNoSkillsLabel',
    'i18n131McOrganizationHint',
    'i18n131McOrganizationName',
    'i18n131McOutput',
    'i18n131McProfilesUnavailable',
    'i18n131McProviderLabel',
    'i18n131McReasoning',
    'i18n131McRefresh',
    'i18n131McRetry',
    'i18n131McReview',
    'i18n131McRoomRefreshFailed',
    'i18n131McSearchAgents',
    'i18n131McShareAuthHint',
    'i18n131McShareAuthLabel',
    'i18n131McSharedRoomName',
    'i18n131McShowLess',
    'i18n131McSkills',
    'i18n131McSoul',
    'i18n131McSoulOptionalHint',
    'i18n131McSoulOptionalLabel',
    'i18n131McStaleProfiles',
    'i18n131McStatusApprovalRequired',
    'i18n131McStatusBlocked',
    'i18n131McStatusError',
    'i18n131McStatusIdle',
    'i18n131McStatusResponding',
    'i18n131McStatusThinking',
    'i18n131McStatusWorking',
    'i18n131McTasks',
    'i18n131McTokens',
    'i18n131McUnattributedSessionsOne',
    'i18n131McUnattributedSessionsOther',
    'i18n131McUnknown',
    'i18n131McUsage',
    'i18n131McWorking',
    'i18n131McWorkspaceAgentCountOne',
    'i18n131McWorkspaceAgentCountOther',
    'i18n131McWorkspaces',
  };
  const languages = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
  for (final lang in languages) {
    test('$lang MissionControlCopy ARB family has exact keys and arguments', () {
      final source = _catalog('es');
      final target = _catalog(lang);
      final family = target.keys.where((key) => key.startsWith('i18n131Mc')).toSet();
      expect(family, expectedKeys);
      expect(source.keys.where((key) => key.startsWith('i18n131Mc')).toSet(),
          expectedKeys);
      for (final key in expectedKeys) {
        expect(target[key], isA<String>(), reason: '$lang:$key');
        final value = target[key] as String;
        expect(value.trim(), isNotEmpty, reason: '$lang:$key');
        expect(_arguments(value), _arguments(source[key] as String),
            reason: '$lang:$key');
      }
    });
  }

  for (final lang in [...languages, 'xx']) {
    testWidgets('$lang MissionControlCopy preserves copy, branches and fallback', (tester) async {
      late MissionControlCopy copy;
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        localeResolutionCallback: (locale, _) =>
            Locale(resolveNotificationLang(locale?.languageCode)),
        home: Builder(builder: (context) {
          copy = MissionControlCopy.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();
      final profiles = switch (lang) {
        "de" => ["0 Profile", "1 Profil", "2 Profile"],
        "fr" => ["0 profils", "1 profil", "2 profils"],
        "it" => ["0 profili", "1 profilo", "2 profili"],
        "ja" => ["プロフィール0件", "プロフィール1件", "プロフィール2件"],
        "ko" => ["프로필 0개", "프로필 1개", "프로필 2개"],
        "zh" => ["0个配置档", "1个配置档", "2个配置档"],
        'es' => ['0 perfiles', '1 perfil', '2 perfiles'],
        'pt' => ['0 perfis', '1 perfil', '2 perfis'],
        _ => ['0 profiles', '1 profile', '2 profiles'],
      };
      final approvals = switch (lang) {
        "de" => ["0 Genehmigungen · 2 blockiert", "1 Genehmigung · 2 blockiert", "2 Genehmigungen · 2 blockiert"],
        "fr" => ["0 autorisations · blocages : 2", "1 autorisation · blocages : 2", "2 autorisations · blocages : 2"],
        "it" => ["0 approvazioni · 2 bloccati", "1 approvazione · 2 bloccati", "2 approvazioni · 2 bloccati"],
        "ja" => ["承認0件・進行不可2件", "承認1件・進行不可2件", "承認2件・進行不可2件"],
        "ko" => ["승인 0건 · 차단 2건", "승인 1건 · 차단 2건", "승인 2건 · 차단 2건"],
        "zh" => ["0项待审批 · 2项受阻", "1项待审批 · 2项受阻", "2项待审批 · 2项受阻"],
        'es' => ['0 aprobaciones · 2 bloqueados', '1 aprobación · 2 bloqueados',
                 '2 aprobaciones · 2 bloqueados'],
        'pt' => ['0 aprovações · 2 bloqueados', '1 aprovação · 2 bloqueados',
                 '2 aprovações · 2 bloqueados'],
        _ => ['0 approvals · 2 blocked', '1 approval · 2 blocked',
              '2 approvals · 2 blocked'],
      };
      for (var count = 0; count <= 2; count++) {
        expect(copy.workspaceAgentCount(count), profiles[count]);
        expect(copy.attentionSummary(count, 2), approvals[count]);
      }
      expect(copy.activityLabel('unrecognized_event'), 'unrecognized_event');
      final expectedUnknown = switch (lang) {
        "de" => "Unbekannt",
        "fr" => "Inconnu",
        "it" => "Sconosciuto",
        "ja" => "不明",
        "ko" => "알 수 없음",
        "zh" => "未知",
        'es' => 'Desconocido', 'pt' => 'Desconhecido', _ => 'Unknown',
      };
      expect(copy.status('unrecognized_status'), expectedUnknown);
      final detail = "literal {name}\n'quoted'";
      final error = switch (lang) {
        "de" => "Das Profil konnte nicht erstellt werden: $detail",
        "fr" => "Impossible de créer le profil : $detail",
        "it" => "Impossibile creare il profilo: $detail",
        "ja" => "プロフィールを作成できませんでした：$detail",
        "ko" => "프로필을 만들지 못했습니다: $detail",
        "zh" => "无法创建配置档：$detail",
        'es' => 'No se pudo crear el perfil: $detail',
        'pt' => 'Não foi possível criar o perfil: $detail',
        _ => 'Could not create the profile: $detail',
      };
      expect(copy.createAgentError(detail), error);
      final sessions = switch (lang) {
        "de" => ["Bei 1 Sitzung wurde kein zugehöriges Profil angegeben. Sie zählt nur zur Gesamtnutzung.", "Bei 2 Sitzungen wurde kein zugehöriges Profil angegeben. Sie zählen nur zur Gesamtnutzung."],
        "fr" => ["1 session n’indique aucun profil propriétaire. Elle est comptabilisée uniquement dans l’utilisation globale.", "2 sessions n’indiquent aucun profil propriétaire. Elles sont comptabilisées uniquement dans l’utilisation globale."],
        "it" => ["1 sessione non ha indicato il profilo proprietario. È inclusa solo nell’utilizzo complessivo.", "2 sessioni non hanno indicato il profilo proprietario. Sono incluse solo nell’utilizzo complessivo."],
        "ja" => ["1件のセッションで所有プロフィールが公開されていません。全体の使用量にのみ含まれます。", "2件のセッションで所有プロフィールが公開されていません。全体の使用量にのみ含まれます。"],
        "ko" => ["세션 1개의 소유 프로필이 공개되지 않았습니다. 전체 사용량에만 포함됩니다.", "세션 2개의 소유 프로필이 공개되지 않았습니다. 전체 사용량에만 포함됩니다."],
        "zh" => ["1个会话未提供所属配置档，仅计入总用量。", "2个会话未提供所属配置档，仅计入总用量。"],
        'es' => ["1 sesión no publicó su perfil propietario. Solo se incluyen en el uso global.", "2 sesiones no publicaron su perfil propietario. Solo se incluyen en el uso global."],
        'pt' => ["1 sessão não publicou o perfil proprietário. Elas são incluídas apenas no uso geral.", "2 sessões não publicaram o perfil proprietário. Elas são incluídas apenas no uso geral."],
        _ => ["1 session did not publish a profile owner. They are included only in overall usage.", "2 sessions did not publish a profile owner. They are included only in overall usage."],
      };
      expect(copy.unattributedSessions(1), sessions[0]);
      expect(copy.unattributedSessions(2), sessions[1]);
    });
  }
}
