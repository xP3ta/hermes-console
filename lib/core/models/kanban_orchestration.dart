String? _optionalText(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

final class KanbanOrchestration {
  final String? orchestratorProfile;
  final String? defaultAssignee;
  final bool autoDecompose;
  final String? resolvedOrchestratorProfile;
  final String? resolvedDefaultAssignee;
  final String? activeProfile;

  const KanbanOrchestration({
    this.orchestratorProfile,
    this.defaultAssignee,
    this.autoDecompose = false,
    this.resolvedOrchestratorProfile,
    this.resolvedDefaultAssignee,
    this.activeProfile,
  });

  factory KanbanOrchestration.fromJson(Map<String, dynamic> json) =>
      KanbanOrchestration(
        orchestratorProfile: _optionalText(json['orchestrator_profile']),
        defaultAssignee: _optionalText(json['default_assignee']),
        autoDecompose: json['auto_decompose'] == true,
        resolvedOrchestratorProfile: _optionalText(
          json['resolved_orchestrator_profile'],
        ),
        resolvedDefaultAssignee: _optionalText(
          json['resolved_default_assignee'],
        ),
        activeProfile: _optionalText(json['active_profile']),
      );
}

final class KanbanProfileDescriptionResult {
  final bool ok;
  final String? profile;
  final String description;

  const KanbanProfileDescriptionResult({
    required this.ok,
    this.profile,
    this.description = '',
  });

  factory KanbanProfileDescriptionResult.fromJson(Map<String, dynamic> json) =>
      KanbanProfileDescriptionResult(
        ok: json['ok'] == true,
        profile: _optionalText(json['profile']),
        description: json['description']?.toString() ?? '',
      );
}

final class KanbanAutoDescriptionResult {
  final bool ok;
  final String? profile;
  final String? reason;
  final String description;

  const KanbanAutoDescriptionResult({
    required this.ok,
    this.profile,
    this.reason,
    this.description = '',
  });

  factory KanbanAutoDescriptionResult.fromJson(Map<String, dynamic> json) =>
      KanbanAutoDescriptionResult(
        ok: json['ok'] == true,
        profile: _optionalText(json['profile']),
        reason: _optionalText(json['reason']),
        description: json['description']?.toString() ?? '',
      );
}
