/// Comandos slash del chat (estilo paleta de comandos).
///
/// Los comandos conocidos ejecutan una acción explícita de Console o del
/// catálogo Desktop. Ningún slash desconocido cae automáticamente al prompt.
library;

import '../../l10n/app_localizations.dart';

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

  const SlashCommand({
    required this.name,
    required this.description,
    required this.action,
    this.argHint = '',
    this.takesArg = false,
  });

  factory SlashCommand.remote({
    required String name,
    required String description,
  }) => SlashCommand(
    name: name,
    description: description,
    action: SlashAction.remote,
    takesArg: true,
  );
}

/// Catálogo de comandos conocidos (cliente). El orden es el de la paleta.
List<SlashCommand> slashCommands(Strings s) => [
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
];

/// Sugerencias mientras se escribe el nombre del comando: el texto empieza por
/// `/` y aún no tiene espacio ni salto (todavía no se escriben argumentos).
/// Devuelve lista vacía si no procede mostrar la paleta.
List<SlashCommand> slashSuggestionsFor(String text, Strings s) {
  if (!text.startsWith('/')) return const [];
  if (text.contains(' ') || text.contains('\n')) return const [];
  final q = text.substring(1).toLowerCase();
  final cmds = slashCommands(s);
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
    text.trim().startsWith('/');

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
