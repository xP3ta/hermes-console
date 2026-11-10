// Skills, plugins and MCP: the words for the checks of `spp_safety.dart` and
// the labels of origins. One place, all through `Strings`.
import '../../l10n/app_localizations.dart';
import 'capability_models.dart';
import 'spp_safety.dart';

String sppSkillIssueText(Strings s, SppSkillIssue issue) => switch (issue) {
  SppSkillIssue.nameEmpty => s.sppSkillNameEmpty,
  SppSkillIssue.nameChars => s.sppSkillNameChars,
  SppSkillIssue.nameTooLong => s.sppSkillNameTooLong(sppSkillNameMax),
  SppSkillIssue.categoryChars => s.sppSkillCategoryChars,
  SppSkillIssue.descriptionEmpty => s.sppSkillDescriptionEmpty,
  SppSkillIssue.descriptionTooLong => s.sppSkillDescriptionTooLong(
    sppSkillNewDescriptionMax,
  ),
  SppSkillIssue.contentEmpty => s.sppSkillContentEmpty,
  SppSkillIssue.contentNoFrontmatter => s.sppSkillContentNoFrontmatter,
  SppSkillIssue.contentUnclosed => s.sppSkillContentUnclosed,
  SppSkillIssue.contentNoName => s.sppSkillContentNoName,
  SppSkillIssue.contentNoDescription => s.sppSkillContentNoDescription,
  SppSkillIssue.contentNoBody => s.sppSkillContentNoBody,
  SppSkillIssue.contentTooLong => s.sppSkillContentTooLong(sppSkillContentMax),
  SppSkillIssue.contentNul => s.sppSkillContentNul,
};

String sppMcpIssueText(Strings s, SppMcpIssue issue) => switch (issue) {
  SppMcpIssue.nameEmpty => s.sppMcpNameEmpty,
  SppMcpIssue.nameChars => s.sppMcpNameChars,
  SppMcpIssue.urlEmpty => s.sppMcpUrlEmpty,
  SppMcpIssue.urlScheme => s.sppMcpUrlScheme,
  SppMcpIssue.urlHost => s.sppMcpUrlHost,
  SppMcpIssue.urlUserInfo => s.sppMcpUrlUserInfo,
  SppMcpIssue.urlQuery => s.sppMcpUrlQuery,
  SppMcpIssue.urlFragment => s.sppMcpUrlFragment,
  SppMcpIssue.commandEmpty => s.sppMcpCommandEmpty,
  SppMcpIssue.commandControl => s.sppMcpCommandControl,
  SppMcpIssue.commandTooLong => s.sppMcpCommandTooLong,
  SppMcpIssue.commandSpaces => s.sppMcpCommandSpaces,
  SppMcpIssue.commandShell => s.sppMcpCommandShell,
};

/// Where an installed skill or plugin comes from, in words. Empty when the
/// server states nothing.
String sppOriginLabel(Strings s, CapabilityItem item) => sppOriginWord(
  s,
  item.kind == CapabilityKind.skill ? item.provenance : item.origin,
);

/// [sppOriginLabel] for a bare origin word (`bundled`, `user`…).
String sppOriginWord(Strings s, String raw) {
  return switch (raw.toLowerCase()) {
    '' => '',
    'bundled' || 'builtin' || 'built-in' => s.sppOriginBundled,
    'user' || 'agent' || 'local' => s.sppOriginUser,
    'hub' => s.sppOriginHub,
    'git' => s.sppOriginGit,
    'external' => s.sppOriginExternal,
    // Only a plain word is an origin; a path or a URL is not shown.
    final other when RegExp(r'^[a-z][a-z0-9_-]{0,23}$').hasMatch(other) =>
      capabilityLabel(other),
    _ => '',
  };
}
