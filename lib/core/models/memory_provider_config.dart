import 'dart:convert';

/// The settings a memory provider plugin declares, as the Dashboard serves
/// them (`GET /api/memory/providers/{name}/config?surface=declared`,
/// Hermes `hermes_cli/web_routers/memory_providers.py`). The fields are the
/// plugin's own: Console writes none by hand. Hermes Desktop reads the same
/// payload (`apps/desktop/src/types/hermes.ts` `MemoryProviderConfig`).
enum MemoryProviderFieldKind {
  text,
  select,
  secret,
  bool,
  number,
  json;

  static MemoryProviderFieldKind parse(Object? value) => switch (value) {
    'select' => select,
    'secret' => secret,
    'bool' => bool,
    'number' => number,
    'json' => json,
    _ => text,
  };
}

class MemoryProviderFieldOption {
  const MemoryProviderFieldOption({
    required this.value,
    required this.label,
    this.description = '',
  });

  final String value;
  final String label;
  final String description;
}

class MemoryProviderField {
  const MemoryProviderField({
    required this.key,
    required this.label,
    required this.kind,
    this.description = '',
    this.info = '',
    this.placeholder = '',
    this.inline = true,
    this.group = '',
    this.options = const [],
    this.value = '',
    this.isSet = false,
  });

  final String key;
  final String label;
  final MemoryProviderFieldKind kind;
  final String description;
  final String info;
  final String placeholder;

  /// Shown in the compact panel; the rest only in the full configuration.
  final bool inline;
  final String group;
  final List<MemoryProviderFieldOption> options;

  /// Edited as text, like Desktop (`field-control.tsx`: "Values are edited
  /// as strings; the backend coerces them to native types"). Never the
  /// value of a secret: the server does not send it.
  final String value;

  /// A secret has a stored value (which is never sent to the app).
  final bool isSet;

  bool get isSecret => kind == MemoryProviderFieldKind.secret;

  MemoryProviderField copyWith({bool? isSet}) => MemoryProviderField(
    key: key,
    label: label,
    kind: kind,
    description: description,
    info: info,
    placeholder: placeholder,
    inline: inline,
    group: group,
    options: options,
    value: value,
    isSet: isSet ?? this.isSet,
  );

  static String _text(Object? value) => value is String ? value : '';

  /// A value the server sent as something other than text, as the text an
  /// input shows for it.
  static String _asText(Object? value) => switch (value) {
    null => '',
    String text => text,
    bool flag => flag ? 'true' : 'false',
    num number => '$number',
    _ => jsonEncode(value),
  };

  static MemoryProviderField? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = _text(raw['key']);
    // A field without `inline` is the older payload, whose save also
    // activates the provider: not this surface.
    if (key.isEmpty || raw['inline'] is! bool) return null;
    final kind = MemoryProviderFieldKind.parse(raw['kind']);
    final label = _text(raw['label']);
    return MemoryProviderField(
      key: key,
      label: label.isEmpty ? key : label,
      kind: kind,
      description: _text(raw['description']),
      info: _text(raw['info']),
      placeholder: _text(raw['placeholder']),
      inline: raw['inline'] as bool,
      group: _text(raw['group']),
      options: [
        if (raw['options'] is List)
          for (final option in raw['options'] as List)
            if (option is Map && option['value'] is String)
              MemoryProviderFieldOption(
                value: option['value'] as String,
                label: _text(option['label']).isEmpty
                    ? option['value'] as String
                    : _text(option['label']),
                description: _text(option['description']),
              ),
      ],
      value: kind == MemoryProviderFieldKind.secret
          ? ''
          : _asText(raw['value']),
      isSet: raw['is_set'] == true,
    );
  }
}

class MemoryProviderConfig {
  const MemoryProviderConfig({
    required this.name,
    required this.label,
    required this.fields,
    this.docsUrl = '',
  });

  final String name;
  final String label;
  final String docsUrl;
  final List<MemoryProviderField> fields;

  List<MemoryProviderField> get inlineFields => [
    for (final field in fields)
      if (field.inline) field,
  ];

  List<MemoryProviderField> get secretFields => [
    for (final field in fields)
      if (field.isSecret) field,
  ];

  /// Desktop shows «Full config…» only when a field is not inline
  /// (`provider-config-panel.tsx:111`).
  bool get hasFullConfig => fields.any((field) => !field.inline);

  /// Fields in declared order under their group, groups in first-seen
  /// order; a field without one goes under [fallback] (Desktop
  /// `provider-config-modal.tsx` `groupFields`).
  List<(String, List<MemoryProviderField>)> grouped(String fallback) {
    final groups = <(String, List<MemoryProviderField>)>[];
    for (final field in fields) {
      final name = field.group.isEmpty ? fallback : field.group;
      final at = groups.indexWhere((group) => group.$1 == name);
      if (at < 0) {
        groups.add((name, [field]));
      } else {
        groups[at].$2.add(field);
      }
    }
    return groups;
  }

  /// Null when the answer is not the declared surface: a server from
  /// before it ignores `surface=declared` and answers the older payload
  /// (it carries `setup` and no `docs_url`), whose save has other effects.
  static MemoryProviderConfig? tryParse(Map<String, dynamic> json) {
    if (json.containsKey('setup') || json['docs_url'] is! String) return null;
    final rawFields = json['fields'];
    if (rawFields is! List) return null;
    final fields = <MemoryProviderField>[];
    for (final raw in rawFields) {
      final field = MemoryProviderField.tryParse(raw);
      if (field == null) return null;
      fields.add(field);
    }
    final name = json['name'] is String ? json['name'] as String : '';
    final label = json['label'] is String ? json['label'] as String : '';
    return MemoryProviderConfig(
      name: name,
      label: label.isEmpty ? name : label,
      docsUrl: json['docs_url'] as String,
      fields: fields,
    );
  }
}

/// `GET /api/memory/providers/{name}/oauth/status` (Hermes
/// `hermes_cli/memory_oauth.py`; Desktop `MemoryProviderOAuthStatus`).
class MemoryProviderOAuthStatus {
  const MemoryProviderOAuthStatus({
    required this.state,
    this.detail = '',
    this.connected = false,
    this.auth,
  });

  /// `idle | pending | connected | error`.
  final String state;
  final String detail;
  final bool connected;

  /// `apikey`, `oauth` or null.
  final String? auth;

  factory MemoryProviderOAuthStatus.fromJson(Map<String, dynamic> json) =>
      MemoryProviderOAuthStatus(
        state: json['state'] is String ? json['state'] as String : 'idle',
        detail: json['detail'] is String ? json['detail'] as String : '',
        connected: json['connected'] == true,
        auth: json['auth'] is String ? json['auth'] as String : null,
      );
}

/// Names that mean "no external provider" (Desktop `settings/helpers.ts`
/// `CORE_MEMORY_PROVIDER_SENTINELS`).
bool isExternalMemoryProvider(Object? value) =>
    value is String &&
    !const {
      '',
      'default',
      'builtin',
      'built-in',
      'none',
    }.contains(value.trim().toLowerCase());
