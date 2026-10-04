import '../../l10n/app_localizations.dart';
import '../models/server_toolset.dart';
import 'server_config_labels.dart';
import 'server_config_pages.dart';

/// A section of the main Settings screen a search result can lead to.
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

enum SettingsSearchKind {
  page,
  field,
  tools,
  toolset,
  diagnostics,
  settingsSection,
}

/// One thing a search can lead to: an Advanced page, a field of one, the
/// toolsets, a toolset, Diagnostics, or a section of the main Settings screen.
final class SettingsSearchEntry {
  final SettingsSearchKind kind;
  final String title;
  final String? subtitle;
  final ServerConfigPage? page;
  final String? path;
  final String? toolset;
  final SettingsSection? settingsSection;
  final String _haystack;

  SettingsSearchEntry._({
    required this.kind,
    required this.title,
    required List<String> text,
    this.subtitle,
    this.page,
    this.path,
    this.toolset,
    this.settingsSection,
  }) : _haystack = _normalize([title, ...text].join(' '));
}

/// Builds the index from what is already loaded: the app's own titles and the
/// `description` and path of the schema fields. Nothing here reads the network.
List<SettingsSearchEntry> buildSettingsSearchIndex({
  required Strings s,
  required Map<String, dynamic> schema,
  List<ServerToolset> toolsets = const [],
  bool diagnostics = false,
}) {
  final entries = <SettingsSearchEntry>[];
  for (final page in ServerConfigPage.values) {
    final fields = serverConfigFieldsOf(page, schema);
    if (fields.isEmpty) continue;
    final pageTitle = serverConfigPageTitle(s, page);
    entries.add(
      SettingsSearchEntry._(
        kind: SettingsSearchKind.page,
        title: pageTitle,
        subtitle: serverConfigPageSubtitle(s, page),
        text: [serverConfigPageSubtitle(s, page)],
        page: page,
      ),
    );
    for (final field in fields) {
      entries.add(
        SettingsSearchEntry._(
          kind: SettingsSearchKind.field,
          title: serverConfigFieldTitle(s, field),
          subtitle: pageTitle,
          text: [
            pageTitle,
            ?field.description,
            field.path.replaceAll(RegExp(r'[._]'), ' '),
          ],
          page: page,
          path: field.path,
        ),
      );
    }
  }
  entries.add(
    SettingsSearchEntry._(
      kind: SettingsSearchKind.tools,
      title: s.drawerTools,
      subtitle: s.adv1215SubTools,
      text: [s.adv1215SubTools],
    ),
  );
  for (final toolset in toolsets) {
    entries.add(
      SettingsSearchEntry._(
        kind: SettingsSearchKind.toolset,
        title: toolset.label,
        subtitle: s.drawerTools,
        text: [?toolset.description, toolset.name, s.drawerTools],
        toolset: toolset.name,
      ),
    );
  }
  if (diagnostics) {
    entries.add(
      SettingsSearchEntry._(
        kind: SettingsSearchKind.diagnostics,
        title: s.sd1215Diagnostics,
        subtitle: s.sd1215DiagnosticsSub,
        text: [s.sd1215DiagnosticsSub],
      ),
    );
  }
  for (final section in SettingsSection.values) {
    entries.add(
      SettingsSearchEntry._(
        kind: SettingsSearchKind.settingsSection,
        title: settingsSectionTitle(s, section),
        text: [
          if (section == SettingsSection.security) ...[
            s.setSecurity,
            s.setPermissions,
            s.setServerConfig,
          ],
        ],
        settingsSection: section,
      ),
    );
  }
  return entries;
}

/// The entries whose text has every word of [query], title matches first.
/// Case and accents do not matter; an empty query finds nothing.
List<SettingsSearchEntry> searchSettings(
  List<SettingsSearchEntry> index,
  String query,
) {
  final words = _normalize(query).split(' ').where((w) => w.isNotEmpty);
  if (words.isEmpty) return const [];
  final hits = [
    for (final entry in index)
      if (words.every(entry._haystack.contains)) entry,
  ];
  bool inTitle(SettingsSearchEntry e) {
    final title = _normalize(e.title);
    return words.every(title.contains);
  }

  return [...hits.where(inTitle), ...hits.where((e) => !inTitle(e))];
}

const _accents = {
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
};

String _normalize(String text) {
  final lower = text.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    out.write(_accents[char] ?? char);
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}
