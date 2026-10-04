import '../../l10n/app_localizations.dart';
import 'server_config_pages.dart';

/// Title of a page of Settings › Advanced.
String serverConfigPageTitle(Strings s, ServerConfigPage page) =>
    switch (page) {
      ServerConfigPage.main => s.adv1215PageMain,
      ServerConfigPage.behavior => s.adv1215PageBehavior,
      ServerConfigPage.projects => s.drawerProjects,
      ServerConfigPage.shell => s.adv1215PageShell,
      ServerConfigPage.files => s.adv1215PageFiles,
      ServerConfigPage.network => s.adv1215PageNetwork,
      ServerConfigPage.context => s.adv1215PageContext,
      ServerConfigPage.conversation => s.i18n1215Conversation,
      ServerConfigPage.runtime => s.adv1215PageRuntime,
    };

/// One line under the title of a page row.
String serverConfigPageSubtitle(Strings s, ServerConfigPage page) =>
    switch (page) {
      ServerConfigPage.main => s.adv1215SubMain,
      ServerConfigPage.behavior => s.adv1215SubBehavior,
      ServerConfigPage.projects => s.adv1215SubProjects,
      ServerConfigPage.shell => s.adv1215SubShell,
      ServerConfigPage.files => s.adv1215SubFiles,
      ServerConfigPage.network => s.adv1215SubNetwork,
      ServerConfigPage.context => s.adv1215SubContext,
      ServerConfigPage.conversation => s.adv1215SubConversation,
      ServerConfigPage.runtime => s.adv1215SubRuntime,
    };

/// The app's own title of a field, when it has one.
String? serverConfigOwnTitle(Strings s, String path) => switch (path) {
  'model_context_length' => s.adv1215FieldContextLength,
  'agent.reasoning_effort' => s.kanban020ReasoningEffort,
  'agent.service_tier' => s.adv1215FieldServiceTier,
  'display.personality' => s.adv1215FieldPersonality,
  'timezone' => s.adv1215FieldTimezone,
  'display.show_reasoning' => s.adv1215FieldShowReasoning,
  'terminal.cwd' => s.adv1215FieldCwd,
  'terminal.persistent_shell' => s.adv1215FieldPersistentShell,
  'terminal.env_passthrough' => s.adv1215FieldEnvPassthrough,
  'code_execution.mode' => s.adv1215FieldCodeExecution,
  'file_read_max_chars' => s.adv1215FieldFileReadMax,
  'browser.allow_private_urls' => s.adv1215FieldPrivateUrls,
  'browser.auto_local_for_private_urls' => s.adv1215FieldLocalBrowser,
  'voice.voice_chat_mode' => s.adv1215FieldVoiceChatMode,
  'voice.max_recording_seconds' => s.adv1215FieldMaxRecording,
  'voice.client_direct' => s.adv1215FieldClientDirect,
  'agent.max_turns' => s.adv1215FieldMaxTurns,
  'agent.api_max_retries' => s.adv1215FieldApiRetries,
  _ => null,
};

/// What the row calls itself: the app's own title, else the schema's
/// description, else the path.
String serverConfigFieldTitle(Strings s, ServerConfigField field) =>
    serverConfigOwnTitle(s, field.path) ?? field.description ?? field.path;
