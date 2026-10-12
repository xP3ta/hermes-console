import '../../l10n/app_localizations.dart';
import 'activity_snapshot.dart';
import 'tool_name.dart';

/// What a tool step is called on screen, the same on every surface: the turn
/// in the transcript, the header pill and its panel, «Último turno», the
/// Conversaciones row, the Home card and the home-screen widget.
///
/// The wording is Hermes Desktop's (`assistant.tool.titles` in its i18n,
/// resolved by `toolMeta` in `fallback-model/index.ts`): each known tool has
/// a phrase while it runs, the verb alone for when its target follows, and a
/// phrase once it is done. Desktop's Spanish writes the running phrase as an
/// infinitive («Ejecutar comando»); here it keeps the gerund of the English
/// original («Ejecutando comando»), because it is read as a status.
///
/// Desktop titles 25 tools and draws others as cards. The rest of what
/// Hermes ships (`toolsets.py` and the tool registry: delegation, kanban,
/// the browser family, video, the desktop surface, messaging platforms…)
/// has Console's own titles in the same three forms and the same voice, so
/// none of them reads as an id or as English inside a Spanish screen.
///
/// Order of precedence, as Desktop:
///  1. the gateway's own label of an MCP or connector call («GitHub · create
///     issue»), from the event's `labels` or rebuilt from the name by the
///     same rule (`tools/tool_labels.py label_for_tool_name`);
///  2. the tool's title;
///  3. the registered name in plain words («Some New Tool»), never an id.
String toolStepTitle(
  Strings s,
  String tool, {
  required bool running,
  bool hasDetail = false,
  String? gatewayTitle,
}) {
  final given = gatewayTitle?.trim() ?? '';
  if (given.isNotEmpty) return given;
  final name = canonicalToolName(tool);
  final appAction = toolAppActionLabel(name);
  if (appAction != null) return appAction;
  final key = _titleKey(name);
  // Trimmed: in the catalogues every case text starts with a space. A case
  // that is one bare word (`execute_code{Scripting}`) is written exactly
  // like a placeholder, and the catalogue parity check reads it as one.
  if (running) {
    final phrase = (hasDetail ? s.ctToolAction(key) : s.ctToolPending(key))
        .trim();
    if (phrase.isNotEmpty) return phrase;
  } else {
    final action = hasDetail ? s.ctToolDoneAction(key).trim() : '';
    if (action.isNotEmpty) return action;
    final phrase = s.ctToolDone(key).trim();
    if (phrase.isNotEmpty) return phrase;
  }
  // Not an id (a display name some source already wrote): it stays as it is.
  if (!_toolId.hasMatch(name)) return name;
  final plain = _plainToolName(s, name);
  return running ? s.ctToolRunning(plain.toLowerCase()) : plain;
}

final _toolId = RegExp(r'^[a-z][a-z0-9_]*$');

/// The name of a step of a turn on screen: a tool or a skill load in
/// Desktop's words, a skill by its own name, reasoning by its section name.
String activityStepTitle(Strings s, ActivityStep step) => switch (step.kind) {
  ActivityStepKind.reasoning => s.chatActivityReasoning,
  ActivityStepKind.skill => step.label,
  ActivityStepKind.tool => toolOrSkillStepTitle(
    s,
    step.label,
    running: step.isRunning,
    detail: step.detail,
    gatewayTitle: step.title,
  ),
};

/// [toolStepTitle], or [skillStepTitle] for a skill load.
String toolOrSkillStepTitle(
  Strings s,
  String tool, {
  required bool running,
  String? detail,
  String? gatewayTitle,
}) => isSkillActivityTool(tool)
    ? skillStepTitle(s, tool, running: running, detail: detail)
    : toolStepTitle(
        s,
        tool,
        running: running,
        hasDetail: detail != null && detail.isNotEmpty,
        gatewayTitle: gatewayTitle,
      );

/// A skill load (`skill_view`, `skills_list`) in Desktop's words
/// (`skill-activity.ts`): loading the skill, or reading one of its files.
String skillStepTitle(
  Strings s,
  String tool, {
  required bool running,
  String? detail,
}) {
  if (canonicalToolName(tool) == 'skills_list') {
    return running ? s.ctSkillListing : s.ctSkillListed;
  }
  final resource = detail != null && detail.contains(' → ');
  if (running) return resource ? s.ctSkillReadingResource : s.ctSkillLoading;
  return resource ? s.ctSkillReadResource : s.ctSkillLoaded;
}

/// The tools Desktop words as a skill load.
bool isSkillActivityTool(String tool) {
  final name = canonicalToolName(tool);
  return name == 'skill_view' || name == 'skills_list';
}

/// Registered names that share the title of another: a tool Hermes renamed
/// (old transcripts keep the old name) or one Desktop titles under its own
/// name for it.
const _titleAliases = <String, String>{
  'todo_list': 'todo',
  'cronjob_manage': 'cronjob',
  'process': 'process_manage',
  'session_search': 'session_search_recall',
};

String _titleKey(String name) => _titleAliases[name] ?? name;

/// Desktop's `titleForTool`: the name in words, with the `browser_`/`web_`
/// family spelled as a prefix.
String _plainToolName(Strings s, String name) {
  String words(String value) => value
      .split('_')
      .where((word) => word.isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
  for (final (prefix, label) in [
    ('browser_', s.ctToolPrefixBrowser),
    ('web_', s.ctToolPrefixWeb),
  ]) {
    if (name.startsWith(prefix) && name.length > prefix.length) {
      return '$label ${words(name.substring(prefix.length))}';
    }
  }
  final plain = words(name);
  return plain.isEmpty ? name : plain;
}

const _appTitles = <String, String>{
  'discord': 'Discord',
  'figma': 'Figma',
  'github': 'GitHub',
  'gmail': 'Gmail',
  'googlecalendar': 'Google Calendar',
  'googledocs': 'Google Docs',
  'googledrive': 'Google Drive',
  'jira': 'Jira',
  'linear': 'Linear',
  'notion': 'Notion',
  'outlook': 'Outlook',
  'slack': 'Slack',
  'stripe_mcp': 'Stripe',
  'todoist': 'Todoist',
};

final _wordBreak = RegExp('[-_]+');

String _appTitle(String slug) {
  final known = _appTitles[slug.toLowerCase()];
  if (known != null) return known;
  final words = slug.split(_wordBreak).where((word) => word.isNotEmpty);
  final title = words
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
  return title.isEmpty ? slug : title;
}

String _actionPhrase(String tool, [String app = '']) {
  var text = tool;
  final prefix = '${app.replaceAll('-', '_').toUpperCase()}_';
  if (app.isNotEmpty && text.toUpperCase().startsWith(prefix)) {
    text = text.substring(prefix.length);
  }
  return text
      .split(_wordBreak)
      .where((word) => word.isNotEmpty)
      .join(' ')
      .toLowerCase();
}

/// «App · action» of an MCP (`mcp__<server>__<tool>`) or connector
/// (`connectors__<app>__<tool>`) call, as the gateway labels it; null for
/// any other tool.
String? toolAppActionLabel(String tool) {
  final name = canonicalToolName(tool);
  final String app;
  final String action;
  if (name.startsWith('connectors__')) {
    final parts = name.split('__');
    if (parts.length < 3 || parts[1].isEmpty) return null;
    final rest = parts.sublist(2).join('__');
    if (rest.isEmpty) return null;
    app = _appTitle(parts[1]);
    action = _actionPhrase(rest, parts[1]);
  } else if (name.startsWith('mcp__')) {
    final rest = name.substring('mcp__'.length);
    final separator = rest.indexOf('__');
    if (separator <= 0 || separator + 2 >= rest.length) return null;
    app = _appTitle(rest.substring(0, separator));
    action = _actionPhrase(rest.substring(separator + 2));
  } else {
    return null;
  }
  return action.isEmpty ? app : '$app · $action';
}

/// The gateway's label of each call of a tool event, by position: a bridged
/// `tool_call` carries one per wrapped call. Only an MCP or connector label
/// is a title here; a built-in tool keeps its own (see [toolStepTitle]).
List<String?> gatewayToolTitles(Object? labels) {
  if (labels is! List) return const [];
  return [
    for (final entry in labels.take(64))
      if (entry is Map &&
          (entry['kind'] == 'mcp' || entry['kind'] == 'connector') &&
          entry['text'] is String &&
          (entry['text'] as String).trim().isNotEmpty &&
          (entry['text'] as String).length <= 120)
        (entry['text'] as String).trim()
      else
        null,
  ];
}

/// What a run of tools did, as Desktop groups it (`run-summary.ts`). The
/// order is the order of the folded summary.
enum ToolRunCategory {
  edit,
  explore,
  search,
  read,
  browse,
  interact,
  analyze,
  run,
  delegate,
  other,
}

const _fileEditTools = {'edit_file', 'patch', 'write_file'};

const _toolCategories = <String, ToolRunCategory>{
  'browser_navigate': ToolRunCategory.browse,
  'delegate_task': ToolRunCategory.delegate,
  'execute_code': ToolRunCategory.run,
  'list_files': ToolRunCategory.explore,
  'read_file': ToolRunCategory.explore,
  'search_files': ToolRunCategory.explore,
  'session_search_recall': ToolRunCategory.search,
  'terminal': ToolRunCategory.run,
  'vision_analyze': ToolRunCategory.analyze,
  'web_extract': ToolRunCategory.read,
  'web_search': ToolRunCategory.search,
  'session_search': ToolRunCategory.search,
  'x_search': ToolRunCategory.search,
};

ToolRunCategory toolRunCategory(String tool) {
  final name = canonicalToolName(tool);
  if (_fileEditTools.contains(name)) return ToolRunCategory.edit;
  return _toolCategories[name] ??
      (name.startsWith('browser_')
          ? ToolRunCategory.interact
          : ToolRunCategory.other);
}

/// The folded summary of a finished run: what was done, counted by kind
/// («3 comandos», «2 búsquedas», «1 archivo editado»), in Desktop's order.
List<String> toolRunSummary(Strings s, Iterable<String> tools) {
  final counts = <ToolRunCategory, int>{};
  for (final tool in tools) {
    final category = toolRunCategory(tool);
    counts[category] = (counts[category] ?? 0) + 1;
  }
  return [
    for (final category in ToolRunCategory.values)
      if (counts[category] case final count?)
        switch (category) {
          ToolRunCategory.edit => s.ctRunEdited(count),
          ToolRunCategory.explore => s.ctRunExplored(count),
          ToolRunCategory.search => s.ctRunSearches(count),
          ToolRunCategory.read => s.ctRunRead(count),
          ToolRunCategory.browse => s.ctRunOpened(count),
          ToolRunCategory.interact => s.ctRunBrowserActions(count),
          ToolRunCategory.analyze => s.ctRunAnalyzed(count),
          ToolRunCategory.run => s.ctRunCommands(count),
          ToolRunCategory.delegate => s.ctRunDelegated(count),
          ToolRunCategory.other => s.ctRunTools(count),
        },
  ];
}
