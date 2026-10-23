import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Reviewed brands, protocols, syntax examples and native cognates.
  const identicalValues = <String, Set<String>>{
    "de": {
      "i18n131P6BadgeAudio", // AUDIO: German media label.
      "i18n131P6BadgeCode", // CODE: German source-code label.
      "i18n131P6BadgeVideo", // VIDEO: German media label.
      "i18n131P6Host", // Host: established computing term in German.
      "i18n131DurationSeconds",
      "i18n131McAgentNameLabel",
      "i18n131McSoulOptionalLabel",
      "i18n131McSoul",
      "i18n131AiServerTab",
      "i18n131AiTransport",
      "i18n131AiName",
      "i18n131AiVariableName",
      "i18n131AiMcpTab",
      "i18n131AiWebhooksTab",
      "i18n131AiHttp",
      "i18n131AiA2aTitle",
      "i18n131AiDeliveryLabelTelegram",
      "i18n131AiDeliveryLabelDiscord",
      "i18n131AiDeliveryLabelSlack",
      "i18n131AiWebhookSubtitleFormat",
      "i18n131TasksStatus",
      "i18n131TasksThreads",
      "i18n131TasksEffortLabelMinimal",
      "i18n131TaskSheetNormal",
      "i18n131CreateOptional",
      "i18n131RoutineCustomScheduleHint",
    },
    "fr": {
      "i18n131P6Animations", // Animations: native French plural.
      "i18n131P6BadgeAudio", // AUDIO: French media label.
      "i18n131P6BadgeCode", // CODE: native French word for source code.
      "i18n131P6Document", // Document: native French noun.
      "i18n131DurationSeconds",
      "i18n131McAgentDescriptionLabel",
      "i18n131McActivityLabelSessionUpdated",
      "i18n131McSoul",
      "i18n131AiTransport",
      "i18n131AiArguments",
      "i18n131AiVariableName",
      "i18n131AiDescription",
      "i18n131AiMcpTab",
      "i18n131AiWebhooksTab",
      "i18n131AiHttp",
      "i18n131AiA2aTitle",
      "i18n131AiDeliveryLabelTelegram",
      "i18n131AiDeliveryLabelDiscord",
      "i18n131AiDeliveryLabelSlack",
      "i18n131AiWebhookSubtitleFormat",
      "i18n131TasksEffortLabelMinimal",
      "i18n131TasksMemory",
      "i18n131TasksEffortLabelUltra",
      "i18n131DetailDiagnostics",
      "i18n131ProfileImage",
      "i18n131ProfileDescription",
      "i18n131CreateImage",
      "i18n131RoutineCustomScheduleHint",
    },
    "it": {
      "i18n131P6BadgeAudio", // AUDIO: Italian media label.
      "i18n131P6BadgeVideo", // VIDEO: Italian media label.
      "i18n131P6Host", // Host: established computing term in Italian.
      "i18n131P6LogDebug", // debug: established Italian diagnostic level.
      "i18n131DurationSeconds",
      "i18n131McSoul",
      "i18n131AiServerTab",
      "i18n131AiDeliveryLabelEmail",
      "i18n131AiMcpTab",
      "i18n131AiHttp",
      "i18n131AiA2aTitle",
      "i18n131AiDeliveryLabelTelegram",
      "i18n131AiDeliveryLabelDiscord",
      "i18n131AiDeliveryLabelSlack",
      "i18n131AiWebhookSubtitleFormat",
      "i18n131TasksNo",
      "i18n131TasksMemory",
      "i18n131RoutineCustomScheduleHint",
    },
    "ja": {
      "i18n131McSoul",
      "i18n131AiMcpTab",
      "i18n131AiHttp",
      "i18n131AiA2aTitle",
      "i18n131AiDeliveryLabelTelegram",
      "i18n131AiDeliveryLabelDiscord",
      "i18n131AiDeliveryLabelSlack",
      "i18n131TasksMemory",
      "i18n131RoutineCustomScheduleHint",
    },
    "ko": {
      "i18n131McAgentNameHint",
      "i18n131AiEndpointUrl",
      "i18n131AiMcpTab",
      "i18n131AiHttp",
      "i18n131AiA2aTitle",
      "i18n131AiDeliveryLabelTelegram",
      "i18n131AiDeliveryLabelDiscord",
      "i18n131AiDeliveryLabelSlack",
      "i18n131AiWebhookSubtitleFormat",
      "i18n131TasksMemory",
      "i18n131RoutineCustomScheduleHint",
    },
    "zh": {
      "i18n131McAgentNameHint",
      "i18n131AiMcpTab",
      "i18n131AiHttp",
      "i18n131AiA2aTitle",
      "i18n131AiDeliveryLabelTelegram",
      "i18n131AiDeliveryLabelDiscord",
      "i18n131AiDeliveryLabelSlack",
      "i18n131AiWebhookSubtitleFormat",
      "i18n131RoutineCustomScheduleHint",
    },
  };
  final draft = RegExp(r'English (?:stub|draft)|draft pending', caseSensitive: false);
  final english = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
      as Map<String, dynamic>;
  for (final lang in ['de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    test('$lang has no pending i18n131 translation drafts', () {
      final catalog = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
          as Map<String, dynamic>;
      final sameAsEnglish = catalog.keys.where((key) =>
          key.startsWith('i18n131') && catalog[key] == english[key]).toSet();
      expect(sameAsEnglish, identicalValues[lang],
          reason: '$lang must not gain unreviewed English copies');
      for (final key in catalog.keys.where((key) => key.startsWith('i18n131'))) {
        final metadata = catalog['@$key'] as Map<String, dynamic>?;
        final description = metadata?['description'] as String? ?? '';
        expect(draft.hasMatch(description), isFalse, reason: '$lang:$key');
      }
    });
  }
}
