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
  bridge,
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
      SettingsSection.bridge => s.setSecBridge,
      SettingsSection.data => s.setSecData,
      SettingsSection.about => s.setSecAbout,
    };
