// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors

/// `model_catalog.excluded_providers` of a Hermes profile: provider ids (or
/// aliases, in any case) Hermes leaves out of every model list it builds —
/// the Dashboard's, Desktop's, the TUI's and the CLI's
/// (`hermes_cli/inventory.py`, `model_switch_providers.py`).
///
/// It is how a provider whose credential belongs to another program on the
/// server (the GitHub or Claude Code login) is taken out: Hermes cannot sign
/// that program out, and must not.
library;

/// The list of a `GET /api/config` answer, as written. An answer that is not
/// a configuration object is a failed read, never "nothing excluded".
List<String> excludedProvidersOfConfigAnswer(Map<String, dynamic> answer) {
  // The Dashboard client wraps a non-object JSON answer as `{data: …}`.
  if (answer.length == 1 && answer.containsKey('data')) {
    throw const FormatException('Invalid configuration response');
  }
  final catalog = answer['model_catalog'];
  final list = catalog is Map ? catalog['excluded_providers'] : null;
  return [
    if (list is List)
      for (final item in list)
        if (item != null && item.toString().trim().isNotEmpty)
          item.toString().trim(),
  ];
}

bool _same(String a, String b) => a.trim().toLowerCase() == b.toLowerCase();

/// Whether [list] names [slug] (Hermes compares them case-insensitively).
bool excludesProvider(List<String> list, String slug) =>
    list.any((item) => _same(item, slug));

/// [list] with [slug] added; unchanged when it is already named.
List<String> withProviderExcluded(List<String> list, String slug) =>
    excludesProvider(list, slug) ? list : [...list, slug];

/// [list] without [slug]; every other entry keeps its place and spelling.
List<String> withProviderIncluded(List<String> list, String slug) => [
  for (final item in list)
    if (!_same(item, slug)) item,
];

/// The sparse patch that stores [list]: only this one list is sent, so the
/// server's deep merge leaves every other setting as it is.
Map<String, dynamic> excludedProvidersPatch(List<String> list) => {
  'model_catalog': {'excluded_providers': list},
};
