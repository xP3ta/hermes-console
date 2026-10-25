import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/admin_integrations_copy.dart';
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
    'i18n131AiA2aIntro',
    'i18n131AiA2aNotPublished',
    'i18n131AiA2aStateConnected',
    'i18n131AiA2aStateConnecting',
    'i18n131AiA2aStateDisabled',
    'i18n131AiA2aStateDisconnected',
    'i18n131AiA2aStateFatal',
    'i18n131AiA2aStateGatewayStopped',
    'i18n131AiA2aStateNotConfigured',
    'i18n131AiA2aStateOther',
    'i18n131AiA2aStatePendingRestart',
    'i18n131AiA2aStateRetrying',
    'i18n131AiA2aStateStartupFailed',
    'i18n131AiA2aTitle',
    'i18n131AiA2aUnavailable',
    'i18n131AiActive',
    'i18n131AiAddMcp',
    'i18n131AiAddMcpBody',
    'i18n131AiAddVariable',
    'i18n131AiAddWebhook',
    'i18n131AiAddWebhookBody',
    'i18n131AiArguments',
    'i18n131AiArgumentsHint',
    'i18n131AiAuthHeader',
    'i18n131AiAuthNone',
    'i18n131AiAuthOauth',
    'i18n131AiAuthentication',
    'i18n131AiAuthorize',
    'i18n131AiBearerHint',
    'i18n131AiBearerToken',
    'i18n131AiCancel',
    'i18n131AiClose',
    'i18n131AiCommand',
    'i18n131AiCommandHint',
    'i18n131AiConfigured',
    'i18n131AiCopied',
    'i18n131AiCopy',
    'i18n131AiCreateMcp',
    'i18n131AiCreateWebhook',
    'i18n131AiDelete',
    'i18n131AiDeleteWebhookBody',
    'i18n131AiDeleteWebhookTitle',
    'i18n131AiDeliverOnly',
    'i18n131AiDeliverOnlyHint',
    'i18n131AiDelivery',
    'i18n131AiDeliveryLabelDiscord',
    'i18n131AiDeliveryLabelEmail',
    'i18n131AiDeliveryLabelGithubComment',
    'i18n131AiDeliveryLabelLog',
    'i18n131AiDeliveryLabelSlack',
    'i18n131AiDeliveryLabelTelegram',
    'i18n131AiDescription',
    'i18n131AiDescriptionHint',
    'i18n131AiDisable',
    'i18n131AiDone',
    'i18n131AiDuplicateWebhook',
    'i18n131AiEnable',
    'i18n131AiEnableWarningBody',
    'i18n131AiEnableWarningTitle',
    'i18n131AiEnableWebhooks',
    'i18n131AiEndpointHint',
    'i18n131AiEndpointUrl',
    'i18n131AiEntryBody',
    'i18n131AiEntryTitle',
    'i18n131AiEnvironment',
    'i18n131AiEnvironmentHint',
    'i18n131AiEvents',
    'i18n131AiEventsHint',
    'i18n131AiForbidden',
    'i18n131AiHttp',
    'i18n131AiInactive',
    'i18n131AiIncompleteEnvironment',
    'i18n131AiInvalidForm',
    'i18n131AiInvalidResponse',
    'i18n131AiManualMcpUnavailable',
    'i18n131AiMcpCreated',
    'i18n131AiMcpFormTitle',
    'i18n131AiMcpIntro',
    'i18n131AiMcpTab',
    'i18n131AiMoreOptions',
    'i18n131AiName',
    'i18n131AiNameHint',
    'i18n131AiNoMcpPut',
    'i18n131AiNoWebhooks',
    'i18n131AiNotConfigured',
    'i18n131AiOauthApproved',
    'i18n131AiOauthBody',
    'i18n131AiOauthError',
    'i18n131AiOauthExpired',
    'i18n131AiOauthTitle',
    'i18n131AiOauthToolsOne',
    'i18n131AiOauthToolsOther',
    'i18n131AiOauthUnknown',
    'i18n131AiOauthWaiting',
    'i18n131AiOpenBrowser',
    'i18n131AiOpeningBrowserFailed',
    'i18n131AiPrompt',
    'i18n131AiPromptHint',
    'i18n131AiReadOnly',
    'i18n131AiRefresh',
    'i18n131AiRejected',
    'i18n131AiRemoveVariable',
    'i18n131AiRetry',
    'i18n131AiRunning',
    'i18n131AiScreenTitle',
    'i18n131AiSecretBody',
    'i18n131AiSecretTitle',
    'i18n131AiSectionLabel',
    'i18n131AiServerTab',
    'i18n131AiSkills',
    'i18n131AiSkillsHint',
    'i18n131AiStdio',
    'i18n131AiStopped',
    'i18n131AiTransport',
    'i18n131AiUnavailable',
    'i18n131AiUnsupported',
    'i18n131AiVariableName',
    'i18n131AiVariableValue',
    'i18n131AiWebhookCreated',
    'i18n131AiWebhookDeleted',
    'i18n131AiWebhookFormTitle',
    'i18n131AiWebhookLoadFailed',
    'i18n131AiWebhookSecret',
    'i18n131AiWebhookSubtitleAllEvents',
    'i18n131AiWebhookSubtitleFormat',
    'i18n131AiWebhookUrl',
    'i18n131AiWebhooksDisabled',
    'i18n131AiWebhooksDisabledBody',
    'i18n131AiWebhooksEnabled',
    'i18n131AiWebhooksEnabledRestarting',
    'i18n131AiWebhooksIntro',
    'i18n131AiWebhooksNeedRestart',
    'i18n131AiWebhooksTab',
    'i18n131AiWebhooksUnavailable',
  };
  const languages = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
  for (final lang in languages) {
    test('$lang AdminIntegrationsCopy ARB family has exact keys and arguments', () {
      final source = _catalog('es');
      final target = _catalog(lang);
      final family = target.keys.where((key) => key.startsWith('i18n131Ai')).toSet();
      expect(family, expectedKeys);
      expect(source.keys.where((key) => key.startsWith('i18n131Ai')).toSet(),
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
    testWidgets('$lang AdminIntegrationsCopy preserves copy, branches and fallback', (tester) async {
      late AdminIntegrationsCopy copy;
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        localeResolutionCallback: (locale, _) =>
            Locale(resolveNotificationLang(locale?.languageCode)),
        home: Builder(builder: (context) {
          copy = AdminIntegrationsCopy.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();
      final tools = switch (lang) {
        "de" => ["0 Werkzeuge verfügbar", "1 Werkzeug verfügbar", "2 Werkzeuge verfügbar"],
        "fr" => ["0 outils disponibles", "1 outil disponible", "2 outils disponibles"],
        "it" => ["0 strumenti disponibili", "1 strumento disponibile", "2 strumenti disponibili"],
        "ja" => ["ツール0個を利用可能", "ツール1個を利用可能", "ツール2個を利用可能"],
        "ko" => ["도구 0개 사용 가능", "도구 1개 사용 가능", "도구 2개 사용 가능"],
        "zh" => ["0个可用工具", "1个可用工具", "2个可用工具"],
        'es' => ['0 herramientas disponibles', '1 herramienta disponible',
                 '2 herramientas disponibles'],
        'pt' => ['0 ferramentas disponíveis', '1 ferramenta disponível',
                 '2 ferramentas disponíveis'],
        _ => ['0 tools available', '1 tool available', '2 tools available'],
      };
      for (var count = 0; count <= 2; count++) {
        expect(copy.oauthTools(count), tools[count]);
      }
      expect(copy.deliveryLabel('custom_channel'), 'custom_channel');
      final expectedTitle = switch (lang) {
        "de" => "Serverintegrationen",
        "fr" => "Intégrations du serveur",
        "it" => "Integrazioni del server",
        "ja" => "サーバー連携",
        "ko" => "서버 연동",
        "zh" => "服务器集成",
        'es' => 'Integraciones del servidor',
        'pt' => 'Integrações do servidor',
        _ => 'Server integrations',
      };
      expect(copy.screenTitle, expectedTitle);
      final events = switch (lang) {
        "de" => "alle Ereignisse",
        "fr" => "tous les événements",
        "it" => "tutti gli eventi",
        "ja" => "すべてのイベント",
        "ko" => "모든 이벤트",
        "zh" => "所有事件",
        'es' => 'todos los eventos', 'pt' => 'todos os eventos', _ => 'all events',
      };
      final expectedAllEvents = switch (lang) {
        "de" => "custom_channel · alle Ereignisse",
        "fr" => "custom_channel · tous les événements",
        "it" => "custom_channel · tutti gli eventi",
        "ja" => "custom_channel・すべてのイベント",
        "ko" => "custom_channel · 모든 이벤트",
        "zh" => "custom_channel · 所有事件",
        _ => 'custom_channel · $events',
      };
      final expectedSelectedEvents = switch (lang) {
        "de" => "custom_channel · event.one, event.two",
        "fr" => "custom_channel · event.one, event.two",
        "it" => "custom_channel · event.one, event.two",
        "ja" => "custom_channel・event.one, event.two",
        "ko" => "custom_channel · event.one, event.two",
        "zh" => "custom_channel · event.one, event.two",
        _ => 'custom_channel · event.one, event.two',
      };
      expect(copy.webhookSubtitle('custom_channel', []), expectedAllEvents);
      expect(copy.webhookSubtitle('custom_channel', ['event.one', 'event.two']),
          expectedSelectedEvents);
      final expectedUnavailable = switch (lang) {
        "de" => "Status nicht verfügbar",
        "fr" => "État indisponible",
        "it" => "Stato non disponibile",
        "ja" => "状態を取得できません",
        "ko" => "상태 확인 불가",
        "zh" => "状态不可用",
        'es' => 'Estado no disponible', 'pt' => 'Status indisponível',
        _ => 'Status unavailable',
      };
      expect(copy.a2aState('new_remote_state'), expectedUnavailable);
    });
  }
}
