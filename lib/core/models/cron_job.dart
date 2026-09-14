import 'model_provider.dart';
import 'session.dart';

/// Estado efectivo de un trabajo programado según Hermes Desktop.
///
/// El campo explícito del servidor manda. Solo cuando no existe se deriva de
/// `enabled`, igual que `apps/desktop/src/app/cron/job-state.ts`.
enum CronJobState {
  enabled,
  scheduled,
  running,
  paused,
  disabled,
  error,
  completed,
  unknown;

  static CronJobState from(String? raw, {required bool enabled}) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) {
      return enabled ? CronJobState.scheduled : CronJobState.disabled;
    }
    return CronJobState.values.firstWhere(
      (value) => value.name == normalized,
      orElse: () => CronJobState.unknown,
    );
  }
}

class CronJob {
  final String id;
  final String name;
  final String prompt;
  final String script;
  final String deliver;
  final String model;
  final String provider;
  final String profile;
  final String scheduleExpression;
  final String scheduleDisplay;
  final String? lastError;
  final String lastStatus;
  final Object? lastRunAt;
  final Object? nextRunAt;
  final bool enabled;
  final bool noAgent;
  final CronJobState state;
  final Map<String, dynamic> raw;

  const CronJob({
    required this.id,
    required this.name,
    required this.prompt,
    required this.script,
    required this.deliver,
    required this.model,
    required this.provider,
    required this.profile,
    required this.scheduleExpression,
    required this.scheduleDisplay,
    required this.lastError,
    required this.lastStatus,
    required this.lastRunAt,
    required this.nextRunAt,
    required this.enabled,
    required this.noAgent,
    required this.state,
    required this.raw,
  });

  factory CronJob.fromJson(Map<String, dynamic> json) {
    final schedule = json['schedule'];
    final scheduleMap = schedule is Map
        ? schedule.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final enabled = json['enabled'] != false;
    final expression =
        _text(scheduleMap['expr']) ??
        (schedule is String ? _text(schedule) : null) ??
        _text(json['schedule_display']) ??
        '';
    final display =
        _text(json['schedule_display']) ??
        _text(scheduleMap['display']) ??
        expression;

    final lastStatus = _text(json['last_status']) ?? '';
    // The scheduler separates execution and delivery failures. Prefer the
    // fire error, then delivery error, so the operator sees a failing route
    // instead of a falsely healthy cron row.
    final lastError =
        _text(json['last_fire_error']) ??
        _text(json['last_delivery_error']) ??
        _text(json['last_error']);

    return CronJob(
      id: _text(json['id']) ?? '',
      name: _text(json['name']) ?? '',
      prompt: _text(json['prompt']) ?? '',
      script: _text(json['script']) ?? '',
      deliver: _text(json['deliver'] ?? json['delivery']) ?? 'local',
      model: _text(json['model']) ?? '',
      provider: _text(json['provider']) ?? '',
      profile: _text(json['profile']) ?? '',
      scheduleExpression: expression,
      scheduleDisplay: display,
      lastError: lastError,
      lastStatus: lastStatus,
      lastRunAt: json['last_run_at'],
      nextRunAt: json['next_run_at'],
      enabled: enabled,
      noAgent: json['no_agent'] == true,
      state: CronJobState.from(json['state']?.toString(), enabled: enabled),
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  bool get isScriptOnly => noAgent && script.isNotEmpty;

  /// Desktop treats the legacy `enabled: false` fallback (`disabled`) as a
  /// resumable job, just like the explicit modern `paused` state.
  bool get isPaused =>
      state == CronJobState.paused || state == CronJobState.disabled;

  /// Misma prioridad que `jobTitle()` de Hermes Desktop.
  String get title {
    if (name.isNotEmpty) return name;
    if (prompt.isNotEmpty) return _clip(prompt);
    if (script.isNotEmpty) return _clip(script);
    return id.isEmpty ? 'Cron job' : id;
  }

  String get preview => prompt.isNotEmpty ? prompt : script;

  static String _clip(String value) =>
      value.length > 60 ? '${value.substring(0, 60)}…' : value;
}

class CronDeliveryTarget {
  final String id;
  final String name;
  final bool homeTargetSet;
  final String? homeEnvVar;

  const CronDeliveryTarget({
    required this.id,
    required this.name,
    required this.homeTargetSet,
    this.homeEnvVar,
  });

  factory CronDeliveryTarget.fromJson(Map<String, dynamic> json) =>
      CronDeliveryTarget(
        id: _text(json['id']) ?? '',
        name: _text(json['name']) ?? _text(json['id']) ?? '',
        homeTargetSet: json['home_target_set'] != false,
        homeEnvVar: _text(json['home_env_var']),
      );

  static const local = CronDeliveryTarget(
    id: 'local',
    name: 'Local',
    homeTargetSet: true,
  );
}

enum AutomationBlueprintFieldType { text, enumValue, time, weekdays }

class AutomationBlueprintField {
  final String name;
  final AutomationBlueprintFieldType type;
  final String label;
  final String defaultValue;
  final List<String> options;
  final bool optional;
  final bool strict;
  final String help;

  const AutomationBlueprintField({
    required this.name,
    required this.type,
    required this.label,
    required this.defaultValue,
    required this.options,
    required this.optional,
    required this.strict,
    required this.help,
  });

  factory AutomationBlueprintField.fromJson(Map<String, dynamic> json) {
    final type = switch (_text(json['type'])) {
      'enum' => AutomationBlueprintFieldType.enumValue,
      'time' => AutomationBlueprintFieldType.time,
      'weekdays' => AutomationBlueprintFieldType.weekdays,
      _ => AutomationBlueprintFieldType.text,
    };
    return AutomationBlueprintField(
      name: _text(json['name']) ?? '',
      type: type,
      label: _text(json['label']) ?? _text(json['name']) ?? '',
      defaultValue: _text(json['default']) ?? '',
      options: (json['options'] as List? ?? const [])
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      optional: json['optional'] == true,
      strict: json['strict'] != false,
      help: _text(json['help']) ?? '',
    );
  }
}

class AutomationBlueprint {
  final String key;
  final String title;
  final String description;
  final String category;
  final List<String> tags;
  final List<AutomationBlueprintField> fields;

  const AutomationBlueprint({
    required this.key,
    required this.title,
    required this.description,
    required this.category,
    required this.tags,
    required this.fields,
  });

  factory AutomationBlueprint.fromJson(
    Map<String, dynamic> json,
  ) => AutomationBlueprint(
    key: _text(json['key']) ?? '',
    title: _text(json['title']) ?? _text(json['key']) ?? '',
    description: _text(json['description']) ?? '',
    category: _text(json['category']) ?? '',
    tags: (json['tags'] as List? ?? const [])
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false),
    fields: (json['fields'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (value) =>
              AutomationBlueprintField.fromJson(value.cast<String, dynamic>()),
        )
        .where((value) => value.name.isNotEmpty)
        .toList(growable: false),
  );

  Map<String, String> initialValues() => {
    for (final field in fields)
      field.name:
          field.name == 'deliver' &&
              (field.defaultValue.isEmpty || field.defaultValue == 'origin')
          ? 'local'
          : field.defaultValue,
  };
}

class CronEditorResources {
  final List<CronDeliveryTarget> deliveryTargets;
  final List<ModelProvider> modelProviders;
  final List<AutomationBlueprint> blueprints;

  const CronEditorResources({
    required this.deliveryTargets,
    required this.modelProviders,
    required this.blueprints,
  });
}

class CronRuns {
  final List<Session> sessions;
  final bool available;

  const CronRuns(this.sessions, {this.available = true});
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}
