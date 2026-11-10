// Keys: the profile's `.env` variables as the server lists them.
//
// `GET /api/env` answers one row per variable with a `redacted_value` for the
// ones that are set. That field is never read here: the model has no place to
// keep it, so a value (even a masked one) cannot reach the screen, a log or
// any state. What is kept is the name, whether it is set, and its metadata.

/// Longest value a key may carry. Far above any real token or certificate
/// line, and low enough to stop a pasted file from going out.
const int kEnvKeyValueMaxLength = 4096;

final RegExp _nameShape = RegExp(r'^[A-Z][A-Z0-9_]{0,127}$');

/// One variable of the profile's `.env`: metadata and state only.
class EnvKeyEntry {
  const EnvKeyEntry({
    required this.name,
    required this.isSet,
    this.category = '',
    this.description = '',
    this.custom = false,
  });

  final String name;
  final bool isSet;

  /// The server's own id for the group (`provider`, `tool`, `setting`...),
  /// `custom` for a variable the user added.
  final String category;
  final String description;
  final bool custom;
}

/// Reads the `GET /api/env` answer into entries sorted by name. Variables
/// that belong to a messaging platform (`channel_managed`) are left out: the
/// Messaging page owns them.
List<EnvKeyEntry> parseEnvKeys(Map<String, dynamic> json) {
  final entries = <EnvKeyEntry>[];
  json.forEach((name, row) {
    if (row is! Map || !_nameShape.hasMatch(name)) return;
    if (row['channel_managed'] == true) return;
    final custom = row['custom'] == true;
    final category = row['category'];
    final description = row['description'];
    entries.add(
      EnvKeyEntry(
        name: name,
        isSet: row['is_set'] == true,
        category: custom ? 'custom' : (category is String ? category : ''),
        description: description is String ? description : '',
        custom: custom,
      ),
    );
  });
  entries.sort((a, b) => a.name.compareTo(b.name));
  return entries;
}

/// Names of the messaging variables that are set. They are not listed (the
/// Messaging page owns them) but a key typed by hand under one of these names
/// would replace the real credential, so the sheet must ask first. Only names
/// are kept.
Set<String> setChannelManagedNames(Map<String, dynamic> json) => {
  for (final entry in json.entries)
    if (entry.value is Map &&
        (entry.value as Map)['channel_managed'] == true &&
        (entry.value as Map)['is_set'] == true &&
        _nameShape.hasMatch(entry.key))
      entry.key,
};

/// True when [name] is a variable name the server accepts.
bool isValidEnvKeyName(String name) => _nameShape.hasMatch(name);

/// Why a value cannot be sent; null when it can.
enum EnvKeyValueProblem { empty, control, edgeSpace, tooLong }

/// Checks a value before it goes anywhere: not empty, one line, no control
/// character (NUL, line breaks, tabs), no space at either end and at most
/// [kEnvKeyValueMaxLength] characters.
EnvKeyValueProblem? validateEnvKeyValue(String value) {
  if (value.isEmpty) return EnvKeyValueProblem.empty;
  if (value.length > kEnvKeyValueMaxLength) return EnvKeyValueProblem.tooLong;
  for (final unit in value.codeUnits) {
    if (unit < 0x20 || unit == 0x7f || unit == 0x2028 || unit == 0x2029) {
      return EnvKeyValueProblem.control;
    }
  }
  if (value != value.trim()) return EnvKeyValueProblem.edgeSpace;
  return null;
}

/// Entries after the search text, the status filter and the category.
List<EnvKeyEntry> filterEnvKeys(
  List<EnvKeyEntry> entries, {
  String query = '',
  bool? isSet,
  String? category,
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final e in entries)
      if ((isSet == null || e.isSet == isSet) &&
          (category == null || e.category == category) &&
          (q.isEmpty ||
              e.name.toLowerCase().contains(q) ||
              e.description.toLowerCase().contains(q)))
        e,
  ];
}
