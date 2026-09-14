/// Categorías estables de la biblioteca publicadas por Hermes Desktop 0.20.
enum SessionCategory { chats, automation, all }

/// Fuentes que Hermes Agent 0.20 considera automatización.
///
/// El orden es canónico porque también se usa al serializar `sources` y
/// `exclude_sources`; no se añaden heurísticas por nombre o prefijo.
abstract final class AutomationSessionSources {
  static const List<String> values = <String>[
    'cron',
    'kanban',
    'subagent',
    'tool',
    'acp',
    'hermes_flow',
    'vulcan_delegate',
    'webhook',
  ];

  static const Set<String> _set = <String>{
    'cron',
    'kanban',
    'subagent',
    'tool',
    'acp',
    'hermes_flow',
    'vulcan_delegate',
    'webhook',
  };

  static bool contains(String source) => _set.contains(source.trim());
}

extension SessionCategoryScope on SessionCategory {
  List<String> get sources => switch (this) {
    SessionCategory.automation => AutomationSessionSources.values,
    SessionCategory.chats || SessionCategory.all => const <String>[],
  };

  List<String> get excludeSources => switch (this) {
    SessionCategory.chats => AutomationSessionSources.values,
    SessionCategory.automation || SessionCategory.all => const <String>[],
  };

  bool includesSource(String source) => switch (this) {
    SessionCategory.chats => !AutomationSessionSources.contains(source),
    SessionCategory.automation => AutomationSessionSources.contains(source),
    SessionCategory.all => true,
  };
}
