import '../models/activity_snapshot.dart';

// How a step of the turn is named, shared by the activity view and the Bot
// Chat header.

/// What a step is called in the activity view and in the Bot Chat header.
///
/// The same names the working line under the assistant uses: a skill load
/// reads as its skill (without the `category/` prefix), anything else as
/// the tool plus its safe, already projected detail.
String activityStepTitle(ActivityStep step) {
  final label = step.label.trim();
  final detail = step.detail?.trim();
  if (step.kind == ActivityStepKind.skill) {
    return label.split('/').last.trim();
  }
  if (isSkillLoadTool(label) && detail != null && detail.isNotEmpty) {
    final skill = detail.split(' → ').first.split('/').last.trim();
    if (skill.isNotEmpty) return skill;
  }
  if (detail == null || detail.isEmpty) return label;
  return '$label · $detail';
}

/// Whether [step] is a skill (loaded or declared), for its gerund.
bool activityStepIsSkill(ActivityStep step) =>
    step.kind == ActivityStepKind.skill ||
    (isSkillLoadTool(step.label) && (step.detail?.trim().isNotEmpty ?? false));
