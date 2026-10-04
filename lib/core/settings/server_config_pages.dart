/// The pages of Settings › Advanced and which server config field each one
/// shows: the Desktop table (`config-subpages.ts`) with its prefixes, and the
/// fields that are never shown.
library;

/// A page of Settings › Advanced backed by config fields.
enum ServerConfigPage {
  main,
  behavior,
  projects,
  shell,
  files,
  network,
  context,
  conversation,
  runtime,
}

/// How a field is edited. `object` and unknown types are never listed.
enum ServerConfigFieldType { boolean, select, number, string, list }

/// One editable field the schema brought for a page.
final class ServerConfigField {
  final String path;
  final ServerConfigFieldType type;
  final String? description;
  final List<String> options;

  const ServerConfigField({
    required this.path,
    required this.type,
    this.description,
    this.options = const [],
  });
}

class _PageRule {
  final Set<String> fields;
  final List<String> prefixes;

  const _PageRule({this.fields = const {}, this.prefixes = const []});

  bool owns(String path) =>
      fields.contains(path) || prefixes.any(path.startsWith);
}

const _rules = <ServerConfigPage, _PageRule>{
  ServerConfigPage.main: _PageRule(
    fields: {
      'model',
      'model_context_length',
      'agent.reasoning_effort',
      'agent.service_tier',
    },
    prefixes: ['model.'],
  ),
  ServerConfigPage.behavior: _PageRule(
    fields: {'display.personality', 'timezone', 'display.show_reasoning'},
  ),
  ServerConfigPage.projects: _PageRule(
    fields: {'terminal.cwd'},
    prefixes: ['desktop.repo_scan_'],
  ),
  ServerConfigPage.shell: _PageRule(
    fields: {'terminal.persistent_shell', 'terminal.env_passthrough'},
  ),
  ServerConfigPage.files: _PageRule(
    fields: {'code_execution.mode', 'file_read_max_chars'},
  ),
  ServerConfigPage.network: _PageRule(
    fields: {
      'browser.allow_private_urls',
      'browser.auto_local_for_private_urls',
    },
  ),
  ServerConfigPage.context: _PageRule(
    prefixes: ['context.', 'compression.', 'auxiliary.compression.'],
  ),
  ServerConfigPage.conversation: _PageRule(
    fields: {
      'voice.voice_chat_mode',
      'voice.max_recording_seconds',
      'voice.client_direct',
    },
    prefixes: ['voice.gpt_live.'],
  ),
  ServerConfigPage.runtime: _PageRule(
    fields: {'agent.max_turns', 'agent.api_max_retries', 'agent.service_tier'},
  ),
};

final _secretHint = RegExp(r'key|token|secret|password|api_');

bool _isTableField(String path) =>
    _rules.values.any((rule) => rule.fields.contains(path));

/// The page that owns [path]. Empty for the model (the picker changes it), for
/// what is never shown and for anything that is in no table row. Like Desktop's
/// `configSubpageForField`, the first matching page wins: `agent.service_tier`
/// is in two rows of the table but is edited on Main only.
List<ServerConfigPage> serverConfigPagesOf(String path) {
  if (_excluded(path)) return const [];
  for (final page in ServerConfigPage.values) {
    if (_rules[page]!.owns(path)) return [page];
  }
  return const [];
}

/// Whether a path is never shown, whatever page claims it. The explicit
/// fields of the table are exempt from the secret-name check: the rule is
/// about prefixes that could hide credentials.
bool _excluded(String path) =>
    path == 'model' ||
    (!_isTableField(path) && _secretHint.hasMatch(path.toLowerCase()));

/// The fields of [page] the `/api/config/schema` response brought, in schema
/// order, without `object` fields, secrets or types the editor cannot render.
List<ServerConfigField> serverConfigFieldsOf(
  ServerConfigPage page,
  Map<String, dynamic> schema,
) {
  final raw = schema['fields'];
  if (raw is! Map) return const [];
  final rule = _rules[page]!;
  final fields = <ServerConfigField>[];
  for (final entry in raw.entries) {
    final path = entry.key;
    final spec = entry.value;
    if (path is! String || spec is! Map) continue;
    if (!rule.owns(path) || _excluded(path)) continue;
    if (serverConfigPagesOf(path).first != page) continue;
    final field = _parseField(path, spec);
    if (field != null) fields.add(field);
  }
  return fields;
}

/// The pages that have at least one field in [schema], in page order.
List<ServerConfigPage> serverConfigPagesWithFields(
  Map<String, dynamic> schema,
) => [
  for (final page in ServerConfigPage.values)
    if (serverConfigFieldsOf(page, schema).isNotEmpty) page,
];

ServerConfigField? _parseField(String path, Map spec) {
  final description = spec['description'];
  final text = description is String && description.trim().isNotEmpty
      ? description.trim()
      : null;
  final options = _options(spec['options']);
  final type = switch (spec['type']) {
    'boolean' => ServerConfigFieldType.boolean,
    'number' => ServerConfigFieldType.number,
    'list' => ServerConfigFieldType.list,
    'string' => ServerConfigFieldType.string,
    // A select with nothing to pick from is a plain string.
    'select' =>
      options.isEmpty
          ? ServerConfigFieldType.string
          : ServerConfigFieldType.select,
    _ => null,
  };
  if (type == null) return null;
  return ServerConfigField(
    path: path,
    type: type,
    description: text,
    options: type == ServerConfigFieldType.select ? options : const [],
  );
}

List<String> _options(Object? raw) => raw is List
    ? [
        for (final option in raw)
          if (option is String || option is num || option is bool)
            option.toString(),
      ]
    : const [];
