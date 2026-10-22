import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

/// Typed facade over the i18n131Ai ARB family.
final class AdminIntegrationsCopy {
  final Strings _strings;

  const AdminIntegrationsCopy._(this._strings);

  factory AdminIntegrationsCopy.of(BuildContext context) =>
      AdminIntegrationsCopy._(Strings.of(context));

  String get screenTitle => _strings.i18n131AiScreenTitle;
  String get entryTitle => _strings.i18n131AiEntryTitle;
  String get entryBody => _strings.i18n131AiEntryBody;
  String get sectionLabel => _strings.i18n131AiSectionLabel;
  String get mcpTab => _strings.i18n131AiMcpTab;
  String get webhooksTab => _strings.i18n131AiWebhooksTab;
  String get serverTab => _strings.i18n131AiServerTab;
  String get readOnly => _strings.i18n131AiReadOnly;
  String get refresh => _strings.i18n131AiRefresh;
  String get retry => _strings.i18n131AiRetry;
  String get cancel => _strings.i18n131AiCancel;
  String get close => _strings.i18n131AiClose;
  String get done => _strings.i18n131AiDone;
  String get copy => _strings.i18n131AiCopy;
  String get copied => _strings.i18n131AiCopied;
  String get delete => _strings.i18n131AiDelete;
  String get moreOptions => _strings.i18n131AiMoreOptions;

  String get mcpIntro => _strings.i18n131AiMcpIntro;
  String get addMcp => _strings.i18n131AiAddMcp;
  String get addMcpBody => _strings.i18n131AiAddMcpBody;
  String get noMcpPut => _strings.i18n131AiNoMcpPut;
  String get manualMcpUnavailable => _strings.i18n131AiManualMcpUnavailable;
  String get mcpFormTitle => _strings.i18n131AiMcpFormTitle;
  String get transport => _strings.i18n131AiTransport;
  String get stdio => _strings.i18n131AiStdio;
  String get http => _strings.i18n131AiHttp;
  String get name => _strings.i18n131AiName;
  String get nameHint => _strings.i18n131AiNameHint;
  String get command => _strings.i18n131AiCommand;
  String get commandHint => _strings.i18n131AiCommandHint;
  String get arguments => _strings.i18n131AiArguments;
  String get argumentsHint => _strings.i18n131AiArgumentsHint;
  String get environment => _strings.i18n131AiEnvironment;
  String get environmentHint => _strings.i18n131AiEnvironmentHint;
  String get variableName => _strings.i18n131AiVariableName;
  String get variableValue => _strings.i18n131AiVariableValue;
  String get addVariable => _strings.i18n131AiAddVariable;
  String get removeVariable => _strings.i18n131AiRemoveVariable;
  String get endpointUrl => _strings.i18n131AiEndpointUrl;
  String get endpointHint => _strings.i18n131AiEndpointHint;
  String get authentication => _strings.i18n131AiAuthentication;
  String get authNone => _strings.i18n131AiAuthNone;
  String get authHeader => _strings.i18n131AiAuthHeader;
  String get authOauth => _strings.i18n131AiAuthOauth;
  String get bearerToken => _strings.i18n131AiBearerToken;
  String get bearerHint => _strings.i18n131AiBearerHint;
  String get createMcp => _strings.i18n131AiCreateMcp;
  String get mcpCreated => _strings.i18n131AiMcpCreated;
  String get invalidForm => _strings.i18n131AiInvalidForm;
  String get incompleteEnvironment => _strings.i18n131AiIncompleteEnvironment;
  String get authorize => _strings.i18n131AiAuthorize;

  String get oauthTitle => _strings.i18n131AiOauthTitle;
  String get oauthBody => _strings.i18n131AiOauthBody;
  String get openBrowser => _strings.i18n131AiOpenBrowser;
  String get openingBrowserFailed => _strings.i18n131AiOpeningBrowserFailed;
  String get oauthWaiting => _strings.i18n131AiOauthWaiting;
  String get oauthApproved => _strings.i18n131AiOauthApproved;
  String get oauthError => _strings.i18n131AiOauthError;
  String get oauthExpired => _strings.i18n131AiOauthExpired;
  String get oauthUnknown => _strings.i18n131AiOauthUnknown;
  String oauthTools(int count) => count == 1
      ? _strings.i18n131AiOauthToolsOne(count)
      : _strings.i18n131AiOauthToolsOther(count);

  String get webhooksIntro => _strings.i18n131AiWebhooksIntro;
  String get webhooksUnavailable => _strings.i18n131AiWebhooksUnavailable;
  String get webhookLoadFailed => _strings.i18n131AiWebhookLoadFailed;
  String get webhooksDisabled => _strings.i18n131AiWebhooksDisabled;
  String get webhooksDisabledBody => _strings.i18n131AiWebhooksDisabledBody;
  String get enableWebhooks => _strings.i18n131AiEnableWebhooks;
  String get enableWarningTitle => _strings.i18n131AiEnableWarningTitle;
  String get enableWarningBody => _strings.i18n131AiEnableWarningBody;
  String get enable => _strings.i18n131AiEnable;
  String get disable => _strings.i18n131AiDisable;
  String get webhooksEnabledRestarting => _strings.i18n131AiWebhooksEnabledRestarting;
  String get webhooksEnabled => _strings.i18n131AiWebhooksEnabled;
  String get webhooksNeedRestart => _strings.i18n131AiWebhooksNeedRestart;
  String get addWebhook => _strings.i18n131AiAddWebhook;
  String get addWebhookBody => _strings.i18n131AiAddWebhookBody;
  String get noWebhooks => _strings.i18n131AiNoWebhooks;
  String get webhookFormTitle => _strings.i18n131AiWebhookFormTitle;
  String get description => _strings.i18n131AiDescription;
  String get descriptionHint => _strings.i18n131AiDescriptionHint;
  String get prompt => _strings.i18n131AiPrompt;
  String get promptHint => _strings.i18n131AiPromptHint;
  String get events => _strings.i18n131AiEvents;
  String get eventsHint => _strings.i18n131AiEventsHint;
  String get skills => _strings.i18n131AiSkills;
  String get skillsHint => _strings.i18n131AiSkillsHint;
  String get delivery => _strings.i18n131AiDelivery;
  String get deliverOnly => _strings.i18n131AiDeliverOnly;
  String get deliverOnlyHint => _strings.i18n131AiDeliverOnlyHint;
  String deliveryLabel(String value) => switch (value) {
    'log' => _strings.i18n131AiDeliveryLabelLog,
    'telegram' => _strings.i18n131AiDeliveryLabelTelegram,
    'discord' => _strings.i18n131AiDeliveryLabelDiscord,
    'slack' => _strings.i18n131AiDeliveryLabelSlack,
    'email' => _strings.i18n131AiDeliveryLabelEmail,
    'github_comment' => _strings.i18n131AiDeliveryLabelGithubComment,
    _ => value,
  };
  String get createWebhook => _strings.i18n131AiCreateWebhook;
  String get webhookCreated => _strings.i18n131AiWebhookCreated;
  String get duplicateWebhook => _strings.i18n131AiDuplicateWebhook;
  String get secretTitle => _strings.i18n131AiSecretTitle;
  String get secretBody => _strings.i18n131AiSecretBody;
  String get webhookUrl => _strings.i18n131AiWebhookUrl;
  String get webhookSecret => _strings.i18n131AiWebhookSecret;
  String get deleteWebhookTitle => _strings.i18n131AiDeleteWebhookTitle;
  String get deleteWebhookBody => _strings.i18n131AiDeleteWebhookBody;
  String get webhookDeleted => _strings.i18n131AiWebhookDeleted;
  String webhookSubtitle(String deliver, List<String> events) {
    final eventText = events.isEmpty
        ? _strings.i18n131AiWebhookSubtitleAllEvents
        : events.join(', ');
    return _strings.i18n131AiWebhookSubtitleFormat(deliveryLabel(deliver), eventText);
  }

  String get a2aIntro => _strings.i18n131AiA2aIntro;
  String get a2aUnavailable => _strings.i18n131AiA2aUnavailable;
  String get a2aNotPublished => _strings.i18n131AiA2aNotPublished;
  String get a2aTitle => _strings.i18n131AiA2aTitle;
  String get configured => _strings.i18n131AiConfigured;
  String get notConfigured => _strings.i18n131AiNotConfigured;
  String get running => _strings.i18n131AiRunning;
  String get stopped => _strings.i18n131AiStopped;
  String get active => _strings.i18n131AiActive;
  String get inactive => _strings.i18n131AiInactive;
  String a2aState(String state) => switch (state) {
    'connected' => _strings.i18n131AiA2aStateConnected,
    'connecting' => _strings.i18n131AiA2aStateConnecting,
    'retrying' => _strings.i18n131AiA2aStateRetrying,
    'pending_restart' => _strings.i18n131AiA2aStatePendingRestart,
    'not_configured' => _strings.i18n131AiA2aStateNotConfigured,
    'gateway_stopped' => _strings.i18n131AiA2aStateGatewayStopped,
    'startup_failed' => _strings.i18n131AiA2aStateStartupFailed,
    'disconnected' => _strings.i18n131AiA2aStateDisconnected,
    'fatal' => _strings.i18n131AiA2aStateFatal,
    'disabled' => _strings.i18n131AiA2aStateDisabled,
    _ => _strings.i18n131AiA2aStateOther,
  };

  String get unsupported => _strings.i18n131AiUnsupported;
  String get forbidden => _strings.i18n131AiForbidden;
  String get unavailable => _strings.i18n131AiUnavailable;
  String get invalidResponse => _strings.i18n131AiInvalidResponse;
  String get rejected => _strings.i18n131AiRejected;
}
