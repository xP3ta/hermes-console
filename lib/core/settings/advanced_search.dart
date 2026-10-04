import 'server_config_pages.dart';

/// Where a search result leads in Settings › Advanced.
sealed class AdvancedTarget {
  const AdvancedTarget();
}

/// A config page, optionally scrolled to one field.
final class AdvancedFieldTarget extends AdvancedTarget {
  const AdvancedFieldTarget(this.page, this.path);

  final ServerConfigPage page;
  final String path;
}

final class AdvancedPageTarget extends AdvancedTarget {
  const AdvancedPageTarget(this.page);

  final ServerConfigPage page;
}

final class AdvancedToolsTarget extends AdvancedTarget {
  const AdvancedToolsTarget();
}

/// One searchable row, built from what is already loaded: page titles and the
/// schema descriptions of the fields. Searching never touches the network.
final class AdvancedSearchEntry {
  const AdvancedSearchEntry({
    required this.title,
    required this.target,
    this.extra = const [],
    this.group,
  });

  final String title;

  /// Extra words that also match (for example the dotted path).
  final List<String> extra;

  /// Title of the page the entry lives on, shown under the result.
  final String? group;
  final AdvancedTarget target;
}

/// Entries whose title, group or extra words contain every word of [query]
/// (case-insensitive, in any order). An empty query matches nothing.
List<AdvancedSearchEntry> searchAdvanced(
  List<AdvancedSearchEntry> entries,
  String query,
) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  return [
    for (final entry in entries)
      if (_matches(entry, words)) entry,
  ];
}

bool _matches(AdvancedSearchEntry entry, List<String> words) {
  final haystack = [
    entry.title,
    ?entry.group,
    ...entry.extra,
  ].join(' ').toLowerCase();
  return words.every(haystack.contains);
}
