import '../../l10n/app_localizations.dart';

// Desktop's own copy for the fields and platforms it knows
// (`i18n/en.ts` `messaging.fieldCopy`, `app/messaging/index.tsx`
// `PLATFORM_INTRO`). Anything else falls back to what the server says.

/// Desktop `fieldCopy(...).label`, or null to use the server prompt.
String? messagingFieldLabel(Strings s, String key) => switch (key) {
  'TELEGRAM_BOT_TOKEN' => s.msgPlatFTelegramBotTokenLabel,
  'TELEGRAM_ALLOWED_USERS' => s.msgPlatFTelegramAllowedUsersLabel,
  'TELEGRAM_PROXY' => s.msgPlatFTelegramProxyLabel,
  'DISCORD_BOT_TOKEN' => s.msgPlatFDiscordBotTokenLabel,
  'DISCORD_ALLOWED_USERS' => s.msgPlatFDiscordAllowedUsersLabel,
  'DISCORD_REPLY_TO_MODE' => s.msgPlatFDiscordReplyToModeLabel,
  'DISCORD_ALLOW_ALL_USERS' => s.msgPlatFDiscordAllowAllUsersLabel,
  'DISCORD_HOME_CHANNEL' => s.msgPlatFDiscordHomeChannelLabel,
  'DISCORD_HOME_CHANNEL_NAME' => s.msgPlatFDiscordHomeChannelNameLabel,
  'BLUEBUBBLES_ALLOW_ALL_USERS' => s.msgPlatFBluebubblesAllowAllUsersLabel,
  'MATTERMOST_ALLOW_ALL_USERS' => s.msgPlatFMattermostAllowAllUsersLabel,
  'MATTERMOST_HOME_CHANNEL' => s.msgPlatFMattermostHomeChannelLabel,
  'QQ_ALLOW_ALL_USERS' => s.msgPlatFQqAllowAllUsersLabel,
  'QQBOT_HOME_CHANNEL' => s.msgPlatFQqbotHomeChannelLabel,
  'QQBOT_HOME_CHANNEL_NAME' => s.msgPlatFQqbotHomeChannelNameLabel,
  'SLACK_BOT_TOKEN' => s.msgPlatFSlackBotTokenLabel,
  'SLACK_APP_TOKEN' => s.msgPlatFSlackAppTokenLabel,
  'SLACK_ALLOWED_USERS' => s.msgPlatFSlackAllowedUsersLabel,
  'MATTERMOST_URL' => s.msgPlatFMattermostUrlLabel,
  'MATTERMOST_TOKEN' => s.msgPlatFMattermostTokenLabel,
  'MATTERMOST_ALLOWED_USERS' => s.msgPlatFMattermostAllowedUsersLabel,
  'MATRIX_HOMESERVER' => s.msgPlatFMatrixHomeserverLabel,
  'MATRIX_ACCESS_TOKEN' => s.msgPlatFMatrixAccessTokenLabel,
  'MATRIX_USER_ID' => s.msgPlatFMatrixUserIdLabel,
  'MATRIX_ALLOWED_USERS' => s.msgPlatFMatrixAllowedUsersLabel,
  'SIGNAL_HTTP_URL' => s.msgPlatFSignalHttpUrlLabel,
  'SIGNAL_ACCOUNT' => s.msgPlatFSignalAccountLabel,
  'SIGNAL_ALLOWED_USERS' => s.msgPlatFSignalAllowedUsersLabel,
  'WHATSAPP_ENABLED' => s.msgPlatFWhatsappEnabledLabel,
  'WHATSAPP_MODE' => s.msgPlatFWhatsappModeLabel,
  'WHATSAPP_ALLOWED_USERS' => s.msgPlatFWhatsappAllowedUsersLabel,
  _ => null,
};

/// Desktop `fieldCopy(...).help`, or null to use the server description.
String? messagingFieldHelp(Strings s, String key) => switch (key) {
  'TELEGRAM_BOT_TOKEN' => s.msgPlatFTelegramBotTokenHelp,
  'TELEGRAM_ALLOWED_USERS' => s.msgPlatFTelegramAllowedUsersHelp,
  'TELEGRAM_PROXY' => s.msgPlatFTelegramProxyHelp,
  'DISCORD_BOT_TOKEN' => s.msgPlatFDiscordBotTokenHelp,
  'DISCORD_ALLOWED_USERS' => s.msgPlatFDiscordAllowedUsersHelp,
  'DISCORD_REPLY_TO_MODE' => s.msgPlatFDiscordReplyToModeHelp,
  'DISCORD_ALLOW_ALL_USERS' => s.msgDiscordEveryoneHelp,
  'DISCORD_HOME_CHANNEL' => s.msgPlatFDiscordHomeChannelHelp,
  'DISCORD_HOME_CHANNEL_NAME' => s.msgPlatFDiscordHomeChannelNameHelp,
  'BLUEBUBBLES_ALLOW_ALL_USERS' => s.msgPlatFBluebubblesAllowAllUsersHelp,
  'QQBOT_HOME_CHANNEL' => s.msgPlatFQqbotHomeChannelHelp,
  'SLACK_BOT_TOKEN' => s.msgPlatFSlackBotTokenHelp,
  'SLACK_APP_TOKEN' => s.msgPlatFSlackAppTokenHelp,
  'SLACK_ALLOWED_USERS' => s.msgPlatFSlackAllowedUsersHelp,
  'MATTERMOST_ALLOWED_USERS' => s.msgPlatFMattermostAllowedUsersHelp,
  'MATRIX_ALLOWED_USERS' => s.msgPlatFMatrixAllowedUsersHelp,
  'SIGNAL_HTTP_URL' => s.msgPlatFSignalHttpUrlHelp,
  'SIGNAL_ACCOUNT' => s.msgPlatFSignalAccountHelp,
  'SIGNAL_ALLOWED_USERS' => s.msgPlatFSignalAllowedUsersHelp,
  'WHATSAPP_ENABLED' => s.msgPlatFWhatsappEnabledHelp,
  'WHATSAPP_ALLOWED_USERS' => s.msgPlatFWhatsappAllowedUsersHelp,
  _ => null,
};

/// Desktop `fieldCopy(...).placeholder`, or null to use the prompt.
String? messagingFieldHint(Strings s, String key) => switch (key) {
  'TELEGRAM_BOT_TOKEN' => s.msgPlatFTelegramBotTokenHint,
  'SLACK_BOT_TOKEN' => s.msgPlatFSlackBotTokenHint,
  'SLACK_APP_TOKEN' => s.msgPlatFSlackAppTokenHint,
  'MATTERMOST_URL' => s.msgPlatFMattermostUrlHint,
  'MATRIX_HOMESERVER' => s.msgPlatFMatrixHomeserverHint,
  'MATRIX_USER_ID' => s.msgPlatFMatrixUserIdHint,
  'SIGNAL_HTTP_URL' => s.msgPlatFSignalHttpUrlHint,
  _ => null,
};

/// Desktop `introCopy`, or null to use the server description.
String? messagingPlatformIntro(Strings s, String id) => switch (id) {
  'telegram' => s.msgPlatIntroTelegram,
  'discord' => s.msgPlatIntroDiscord,
  'slack' => s.msgPlatIntroSlack,
  'mattermost' => s.msgPlatIntroMattermost,
  'matrix' => s.msgPlatIntroMatrix,
  'signal' => s.msgPlatIntroSignal,
  'whatsapp' => s.msgPlatIntroWhatsapp,
  'bluebubbles' => s.msgPlatIntroBluebubbles,
  'homeassistant' => s.msgPlatIntroHomeassistant,
  'email' => s.msgPlatIntroEmail,
  'sms' => s.msgPlatIntroSms,
  'dingtalk' => s.msgPlatIntroDingtalk,
  'feishu' => s.msgPlatIntroFeishu,
  'wecom' => s.msgPlatIntroWecom,
  'wecom_callback' => s.msgPlatIntroWecomCallback,
  'weixin' => s.msgPlatIntroWeixin,
  'qqbot' => s.msgPlatIntroQqbot,
  'api_server' => s.msgPlatIntroApiServer,
  'webhook' => s.msgPlatIntroWebhook,
  _ => null,
};
