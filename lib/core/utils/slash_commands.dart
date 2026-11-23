/// Comandos slash del chat (estilo paleta de comandos).
///
/// Los comandos conocidos ejecutan una acción explícita de Console o del
/// catálogo Desktop. Ningún slash desconocido cae automáticamente al prompt.
library;

import '../../l10n/app_localizations.dart';
import '../models/command_descriptor.dart';

/// Qué hace un comando al ejecutarse (la lógica vive en el chat).
enum SlashAction {
  help,
  newChat,
  compress,
  model,
  skills,
  memory,
  soul,
  models,
  activity,
  kanban,
  find,
  btw,
  background,
  branch,
  steer,
  remote,
  unavailable,
}

class SlashCommand {
  /// Nombre sin la barra (p.ej. `model`).
  final String name;

  /// Pista de argumento mostrada en la paleta (p.ej. `[nombre]`).
  final String argHint;

  /// Descripción corta para la paleta.
  final String description;

  /// Acción a ejecutar.
  final SlashAction action;

  /// Si admite argumento (p.ej. `/model gpt-5`). Si true y no hay argumento,
  /// la app suele abrir un selector en su lugar.
  final bool takesArg;

  /// A server skill command (`complete.slash` kind `skill` or a catalog
  /// `skills` key); the palette groups these under their own header.
  final bool isSkill;

  /// An argument option (`/personality alice`): the composer text that
  /// picking it leaves. Null for a command row.
  final String? insertText;

  /// What an argument option row says (the server's `display`).
  final String? optionLabel;

  const SlashCommand({
    required this.name,
    required this.description,
    required this.action,
    this.argHint = '',
    this.takesArg = false,
    this.isSkill = false,
    this.insertText,
    this.optionLabel,
  });

  factory SlashCommand.remote({
    required String name,
    required String description,
    bool isSkill = false,
  }) => SlashCommand(
    name: name,
    description: description,
    action: SlashAction.remote,
    takesArg: true,
    isSkill: isSkill,
  );
}

/// Most rows the palette shows for one query: the bare `/` lists the server's
/// ranked catalog, skills included, so it needs room beyond the local list.
const int maxSlashPaletteRows = 40;

/// Merges the local palette with the server's live answer for [input]
/// (`complete.slash`, falling back to the `commands.catalog` prefix match when
/// the gateway lacks completion). Local commands lead, then server commands,
/// then skills (Desktop groups Commands before Skills, each keeping the
/// backend's relevance order). A suggestion never grants availability: the
/// send path re-resolves every remote name against the catalog.
List<SlashCommand> mergeSlashSuggestions({
  required String input,
  required List<SlashCommand> local,
  DesktopCommandCatalog? catalog,
  SlashCompletionBatch? completion,
  int limit = maxSlashPaletteRows,
}) {
  final byName = <String, SlashCommand>{
    for (final item in local) item.name: item,
  };
  final prefix = input.startsWith('/')
      ? input.substring(1).toLowerCase()
      : input.toLowerCase();
  final catalogByName = <String, CommandCatalogEntry>{
    for (final item in catalog?.commands ?? const <CommandCatalogEntry>[])
      item.canonicalName: item,
  };
  final skillNames = catalog?.skillNames ?? const <String>{};
  final commands = <SlashCommand>[];
  final skills = <SlashCommand>[];

  void offer(String name, String meta, bool skillKind) {
    if (isUnavailableSlashName(name) ||
        byName.containsKey(name) ||
        catalog?.offersInPalette(name) == false) {
      return;
    }
    final entry = catalogByName[name];
    final skill = skillKind || skillNames.contains(name);
    final command = SlashCommand.remote(
      name: name,
      description: entry?.description.isNotEmpty == true
          ? entry!.description
          : meta,
      isSkill: skill,
    );
    byName[name] = command;
    (skill ? skills : commands).add(command);
  }

  if (completion != null) {
    for (final item in completion.suggestions) {
      final name = CommandDescriptor.tryNormalizeName(
        item.replacement.trim().split(RegExp(r'\s+')).first,
      );
      if (name == null) continue;
      offer(name, item.meta, item.isSkill);
    }
  } else {
    for (final name in catalogByName.keys) {
      if (name.startsWith(prefix)) offer(name, '', false);
    }
  }
  final merged = <SlashCommand>[
    ...local.where((item) => byName[item.name] == item),
    ...commands,
    ...skills,
  ];
  return merged.length <= limit ? merged : merged.sublist(0, limit);
}

/// Longest composer text that still asks `complete.slash` for arguments.
const int maxSlashArgumentInput = 256;

/// The command whose argument is being typed (`/personality ali` gives
/// `personality`), or null. Desktop's argument stage: a command token, then
/// a space (`text-utils.ts` `SLASH_COMMAND_TRIGGER_RE`, `composer-utils.ts`
/// `slashArgStage`), here on one line.
String? slashArgumentCommand(String text) =>
    _slashArgumentStage.firstMatch(text)?.group(1)!.toLowerCase();

final RegExp _slashArgumentStage = RegExp(r'^/([A-Za-z][\w-]*)[ \t]+[^\n]*$');

/// Whether the palette stays open past the command name. Desktop
/// (`use-composer-trigger.ts` `refreshTrigger`) keeps completing only a
/// command whose catalog `argument_mode` is `options` or `mixed`; free text
/// (`text`) and a command with no argument close it. Console's own commands
/// run here and are never completed by the server.
bool slashArgumentPaletteApplies(String text, DesktopCommandCatalog? catalog) {
  final name = slashArgumentCommand(text);
  if (name == null || catalog == null || parseSlashCommand(text) != null) {
    return false;
  }
  final mode = catalog.argumentModeOf(name);
  return mode == 'options' || mode == 'mixed';
}

/// The rows of an argument answer of `complete.slash`. Hermes sends only the
/// argument (`alice` for `/personality alic`, `replace_from` 13); Desktop
/// (`use-slash-completions.ts`) puts back the typed text up to `replace_from`
/// so the pick is the whole `/personality alice`.
List<SlashCommand> slashArgumentSuggestions({
  required String input,
  required SlashCompletionBatch completion,
  int limit = maxSlashPaletteRows,
}) {
  final name = slashArgumentCommand(input);
  if (name == null) return const [];
  final rows = <SlashCommand>[];
  final seen = <String>{};
  for (final item in completion.suggestions) {
    if (item.replaceFrom <= 1 || item.replaceFrom > input.length) continue;
    final text = '${input.substring(0, item.replaceFrom)}${item.replacement}';
    if (!seen.add(text)) continue;
    rows.add(
      SlashCommand(
        name: name,
        description: item.meta,
        action: SlashAction.remote,
        insertText: text,
        optionLabel: item.display,
      ),
    );
    if (rows.length == limit) break;
  }
  return rows;
}

/// Catálogo de comandos conocidos (cliente). El orden es el de la paleta.
///
/// `/btw`, `/bg` and `/branch` only appear when the chat can run them
/// ([sideAgents], [branch]); typing them still routes correctly either way.
List<SlashCommand> slashCommands(
  Strings s, {
  bool sideAgents = false,
  bool branch = false,
}) => [
  SlashCommand(
    name: 'help',
    description: s.slashDescHelp,
    action: SlashAction.help,
  ),
  SlashCommand(
    name: 'model',
    argHint: '[nombre]',
    description: s.slashDescModel,
    action: SlashAction.model,
    takesArg: true,
  ),
  SlashCommand(
    name: 'new',
    description: s.slashDescNew,
    action: SlashAction.newChat,
  ),
  SlashCommand(
    name: 'clear',
    description: s.slashDescClear,
    action: SlashAction.newChat,
  ),
  SlashCommand(
    name: 'compress',
    argHint: s.slashArgCompress,
    description: s.slashDescCompress,
    action: SlashAction.compress,
    takesArg: true,
  ),
  SlashCommand(
    name: 'models',
    description: s.slashDescModels,
    action: SlashAction.models,
  ),
  SlashCommand(
    name: 'skills',
    description: s.slashDescSkills,
    action: SlashAction.skills,
  ),
  SlashCommand(
    name: 'memory',
    description: s.slashDescMemory,
    action: SlashAction.memory,
  ),
  SlashCommand(
    name: 'soul',
    description: s.slashDescSoul,
    action: SlashAction.soul,
  ),
  SlashCommand(
    name: 'kanban',
    description: s.slashDescKanban,
    action: SlashAction.kanban,
  ),
  SlashCommand(
    name: 'activity',
    description: s.slashDescActivity,
    action: SlashAction.activity,
  ),
  SlashCommand(
    name: 'find',
    argHint: s.cs1215SlashArg,
    description: s.cs1215SlashDesc,
    action: SlashAction.find,
    takesArg: true,
  ),
  SlashCommand(
    name: 'buscar',
    argHint: s.cs1215SlashArg,
    description: s.cs1215SlashDesc,
    action: SlashAction.find,
    takesArg: true,
  ),
  // `/steer <prompt>` (hermes_cli/commands.py `steer`): guidance for the
  // turn in flight, delivered after its next tool call.
  SlashCommand(
    name: 'steer',
    argHint: s.slashSteerArg,
    description: s.slashSteerDesc,
    action: SlashAction.steer,
    takesArg: true,
  ),
  if (sideAgents) ...[
    SlashCommand(
      name: 'btw',
      argHint: s.tc1215SlashArgBtw,
      description: s.tc1215SlashDescBtw,
      action: SlashAction.btw,
      takesArg: true,
    ),
    SlashCommand(
      name: 'bg',
      argHint: s.tc1215SlashArgBg,
      description: s.tc1215SlashDescBg,
      action: SlashAction.background,
      takesArg: true,
    ),
  ],
  if (branch)
    SlashCommand(
      name: 'branch',
      description: s.tc1215SlashDescBranch,
      action: SlashAction.branch,
    ),
];

/// Sugerencias mientras se escribe el nombre del comando: el texto empieza por
/// `/` y aún no tiene espacio ni salto (todavía no se escriben argumentos).
/// Devuelve lista vacía si no procede mostrar la paleta.
List<SlashCommand> slashSuggestionsFor(
  String text,
  Strings s, {
  bool sideAgents = false,
  bool branch = false,
}) {
  if (!slashPaletteApplies(text)) return const [];
  final q = text.substring(1).toLowerCase();
  final cmds = slashCommands(s, sideAgents: sideAgents, branch: branch);
  if (q.isEmpty) return cmds;
  return cmds.where((c) => c.name.startsWith(q)).toList();
}

/// Resultado de parsear el texto del compositor como comando ejecutable.
class ParsedSlash {
  final SlashCommand command;
  final String arg;
  const ParsedSlash(this.command, this.arg);
}

/// Token slash sintácticamente válido, exista o no en el registry local.
class SlashInvocation {
  final String name;
  final String arg;

  const SlashInvocation(this.name, this.arg);
}

/// Desktop's command rule (`@hermes/shared` `SLASH_COMMAND_RE`,
/// `chat-runtime.ts` `isSlashCommandText`): a `/` at the start, a bare name
/// with no second `/`, then a space or the end. `/usr/local` and a pasted
/// `/home/me/shot.png` are prose. Console also reads a name ending in a file
/// extension (`/notes.md`) as a path, never a command.
bool isSlashCommandText(String text) {
  final t = text.trimLeft();
  final match = _slashCommandText.firstMatch(t);
  if (match == null) return false;
  return !_fileExtension.hasMatch(match.group(1)!);
}

final RegExp _slashCommandText = RegExp(r'^/([^\s/]*)(?:\s|$)');
final RegExp _fileExtension = RegExp(r'\.[A-Za-z][A-Za-z0-9]{0,4}$');

/// The command palette is for a name being typed: `/` at the start, no
/// space or line break yet, and no second `/` (that is a path).
bool slashPaletteApplies(String text) =>
    text.startsWith('/') &&
    !text.contains(RegExp(r'\s')) &&
    !text.contains('/', 1);

SlashInvocation? parseSlashInvocation(String text) {
  final t = text.trim();
  if (!t.startsWith('/')) return null;
  final sp = t.indexOf(RegExp(r'\s'));
  final rawName = sp == -1 ? t.substring(1) : t.substring(1, sp);
  final name = rawName.toLowerCase();
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(name)) return null;
  final arg = sp == -1 ? '' : t.substring(sp + 1).trim();
  return SlashInvocation(name, arg);
}

/// Classifies a valid slash before any busy attachment queue decision.
bool shouldRouteSlashBeforeBusyAttachmentQueue(String text) =>
    isSlashCommandText(text.trim());

bool isUnavailableSlashName(String name) =>
    name.trim().replaceFirst(RegExp(r'^/+'), '').toLowerCase() == 'compact';

/// Parsea el texto como un comando **conocido**. Devuelve null si no empieza por
/// `/` o si el comando no está en el catálogo (en ese caso el llamador lo trata
/// como texto normal y lo envía al agente verbatim).
ParsedSlash? parseSlashCommand(String text) {
  final invocation = parseSlashInvocation(text);
  if (invocation == null) return null;
  final name = invocation.name;
  final arg = invocation.arg;
  const nameToAction = <String, SlashAction>{
    'help': SlashAction.help,
    'model': SlashAction.model,
    'new': SlashAction.newChat,
    'clear': SlashAction.newChat,
    'compress': SlashAction.compress,
    'compact': SlashAction.unavailable,
    'models': SlashAction.models,
    'skills': SlashAction.skills,
    'memory': SlashAction.memory,
    'soul': SlashAction.soul,
    'kanban': SlashAction.kanban,
    'activity': SlashAction.activity,
    'find': SlashAction.find,
    'buscar': SlashAction.find,
    'btw': SlashAction.btw,
    'bg': SlashAction.background,
    'background': SlashAction.background,
    'branch': SlashAction.branch,
    'steer': SlashAction.steer,
    // Its alias in Hermes (commands.py: aliases=("s",)).
    's': SlashAction.steer,
  };
  final action = nameToAction[name];
  if (action != null) {
    return ParsedSlash(
      SlashCommand(name: name, description: '', action: action),
      arg,
    );
  }
  return null;
}
