import '../../l10n/app_localizations.dart';
import '../models/session_artifact.dart';

String artifactNameCopy(Strings strings, SessionArtifact artifact) {
  if (artifact.hasExplicitDisplayName) return artifact.displayName;
  return switch (artifact.kind) {
    SessionArtifactKind.image => strings.sa1215KindImage,
    SessionArtifactKind.file => strings.sa1215KindFile,
    SessionArtifactKind.document => strings.i18n131P6Document,
    SessionArtifactKind.generated => strings.i18n131P6GeneratedArtifact,
    SessionArtifactKind.toolResult => strings.i18n131P6ToolResult,
    SessionArtifactKind.unknown => strings.i18n131P6Artifact,
  };
}
