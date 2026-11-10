import '../../l10n/app_localizations.dart';

/// A section of the main Settings screen (also a deep-link target).
enum SettingsSection {
  connection,
  appearance,
  chat,
  voice,
  notifications,
  security,
  system,
  data,
  about,
}

String settingsSectionTitle(Strings s, SettingsSection section) =>
    switch (section) {
      SettingsSection.connection => s.setSecConnection,
      SettingsSection.appearance => s.setSecAppearance,
      SettingsSection.chat => s.setSecChat,
      SettingsSection.voice => s.voiceTitle,
      SettingsSection.notifications => s.notifTitle,
      SettingsSection.security => s.setSecSecurity,
      SettingsSection.system => s.setSecSystem,
      SettingsSection.data => s.setSecData,
      SettingsSection.about => s.setSecAbout,
    };

/// The title of the screen that shows only [section]: capitalised and
/// complete, unlike the lower-case caption of the section inside the list.
String settingsSectionScreenTitle(Strings s, SettingsSection section) =>
    switch (section) {
      SettingsSection.connection => s.ssxTitleConnection,
      SettingsSection.appearance => s.ssxTitleAppearance,
      SettingsSection.chat => s.ssxTitleChat,
      SettingsSection.voice => s.voiceTitle,
      SettingsSection.notifications => s.notifTitle,
      SettingsSection.security => s.ssxTitleSecurity,
      SettingsSection.system => s.ssxTitleSystem,
      SettingsSection.data => s.ssxTitleData,
      SettingsSection.about => s.ssxTitleAbout,
    };
