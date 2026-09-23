import 'capability_descriptor.dart';
import 'desktop_compression_outcome.dart';
import 'desktop_compression_result.dart';

enum CommandCategory {
  session,
  context,
  navigation,
  agent,
  tools,
  project,
  extension,
}

enum CommandOrigin { native, typedAdapter, catalog, completion, legacy }

enum CommandSurface { inline, sheet, picker, navigation, remote, unavailable }

enum CommandExecutorKind { native, typedRpc, slashExec, dispatch, legacy }

enum CommandArgumentKind { none, freeText, enumeration }

final class CommandArgumentSpec {
  final CommandArgumentKind kind;
  final String? hint;
  final bool required;
  final int maxLength;
  final Set<String> allowedValues;

  factory CommandArgumentSpec({
    required CommandArgumentKind kind,
    String? hint,
    bool required = false,
    int maxLength = 500,
    Iterable<String> allowedValues = const [],
  }) {
    if (maxLength < 0 || maxLength > 4096) {
      throw const FormatException('invalid command argument limit');
    }
    final values = <String>{};
    for (final value in allowedValues) {
      final safe = _boundedText(value, 64);
      if (safe == null) {
        throw const FormatException('invalid command argument option');
      }
      values.add(safe);
      if (values.length > 128) {
        throw const FormatException('too many command argument options');
      }
    }
    if (kind == CommandArgumentKind.enumeration && values.isEmpty) {
      throw const FormatException('enumeration requires options');
    }
    if (kind == CommandArgumentKind.none && (required || values.isNotEmpty)) {
      throw const FormatException('argument-free command has argument rules');
    }
    return CommandArgumentSpec._(
      kind: kind,
      hint: _boundedText(hint, 96),
      required: required,
      maxLength: maxLength,
      allowedValues: Set<String>.unmodifiable(values),
    );
  }

  const CommandArgumentSpec._({
    required this.kind,
    required this.hint,
    required this.required,
    required this.maxLength,
    required this.allowedValues,
  });

  String validate(String raw) {
    final value = raw.trim();
    if (required && value.isEmpty) {
      throw const FormatException('command argument is required');
    }
    if (kind == CommandArgumentKind.none && value.isNotEmpty) {
      throw const FormatException('command does not accept arguments');
    }
    if (value.length > maxLength) {
      throw const FormatException('command argument is too long');
    }
    if (kind == CommandArgumentKind.enumeration && value.isNotEmpty) {
      final match = allowedValues.any(
        (candidate) => candidate.toLowerCase() == value.toLowerCase(),
      );
      if (!match) throw const FormatException('unsupported command argument');
    }
    return value;
  }
}

/// Descriptor inmutable que separa presentación, política y ejecución.
final class CommandDescriptor {
  static final RegExp _namePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

  final String canonicalName;
  final Set<String> aliases;
  final String title;
  final String description;
  final CommandCategory category;
  final CommandOrigin origin;
  final CommandSurface surface;
  final CommandArgumentSpec? argumentSpec;
  final CommandExecutorKind executor;
  final String? capabilityKey;
  final OperationScope scope;
  final OperationRisk risk;
  final CapabilityState availability;
  final String? unavailableReason;
  final String? catalogRevision;

  factory CommandDescriptor({
    required String canonicalName,
    Iterable<String> aliases = const [],
    String? title,
    String description = '',
    required CommandCategory category,
    required CommandOrigin origin,
    required CommandSurface surface,
    CommandArgumentSpec? argumentSpec,
    required CommandExecutorKind executor,
    String? capabilityKey,
    required OperationScope scope,
    required OperationRisk risk,
    required CapabilityState availability,
    String? unavailableReason,
    String? catalogRevision,
  }) {
    final canonical = normalizeName(canonicalName);
    final normalizedAliases = <String>{};
    for (final alias in aliases) {
      final normalized = normalizeName(alias);
      if (normalized != canonical) normalizedAliases.add(normalized);
      if (normalizedAliases.length > 64) {
        throw const FormatException('too many command aliases');
      }
    }
    final safeCapability = capabilityKey == null
        ? null
        : _capabilityKey(capabilityKey);
    return CommandDescriptor._(
      canonicalName: canonical,
      aliases: Set<String>.unmodifiable(normalizedAliases),
      title: _boundedText(title, 96) ?? '/$canonical',
      description: _boundedText(description, 240) ?? '',
      category: category,
      origin: origin,
      surface: surface,
      argumentSpec: argumentSpec,
      executor: executor,
      capabilityKey: safeCapability,
      scope: scope,
      risk: risk,
      availability: availability,
      unavailableReason: _boundedIdentifier(unavailableReason, 64),
      catalogRevision: _boundedIdentifier(catalogRevision, 96),
    );
  }

  const CommandDescriptor._({
    required this.canonicalName,
    required this.aliases,
    required this.title,
    required this.description,
    required this.category,
    required this.origin,
    required this.surface,
    required this.argumentSpec,
    required this.executor,
    required this.capabilityKey,
    required this.scope,
    required this.risk,
    required this.availability,
    required this.unavailableReason,
    required this.catalogRevision,
  });

  static String normalizeName(String raw) {
    var value = raw.trim();
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    value = value.toLowerCase();
    if (!_namePattern.hasMatch(value)) {
      throw const FormatException('invalid command name');
    }
    return value;
  }

  static String? tryNormalizeName(Object? raw) {
    if (raw is! String) return null;
    try {
      return normalizeName(raw);
    } on FormatException {
      return null;
    }
  }

  int get precedence => switch (origin) {
    CommandOrigin.native => 5,
    CommandOrigin.typedAdapter => 4,
    CommandOrigin.catalog => 3,
    CommandOrigin.completion => 2,
    CommandOrigin.legacy => 1,
  };

  bool isSemanticallyCompatibleWith(CommandDescriptor other) {
    if (canonicalName != other.canonicalName || scope != other.scope) {
      return false;
    }
    if (capabilityKey != null &&
        other.capabilityKey != null &&
        capabilityKey == other.capabilityKey) {
      return true;
    }
    if ({origin, other.origin}.contains(CommandOrigin.typedAdapter) &&
        {origin, other.origin}.contains(CommandOrigin.catalog)) {
      // Un adapter tipado puede curar el comando publicado, pero solo cuando
      // ambos conservan su ámbito y nombre canónico.
      return true;
    }
    return executor == other.executor &&
        surface == other.surface &&
        risk == other.risk;
  }

  CommandDescriptor copyWith({
    Iterable<String>? aliases,
    String? title,
    String? description,
    CommandCategory? category,
    CommandOrigin? origin,
    CommandSurface? surface,
    CommandArgumentSpec? argumentSpec,
    CommandExecutorKind? executor,
    String? capabilityKey,
    OperationScope? scope,
    OperationRisk? risk,
    CapabilityState? availability,
    String? unavailableReason,
    String? catalogRevision,
  }) => CommandDescriptor(
    canonicalName: canonicalName,
    aliases: aliases ?? this.aliases,
    title: title ?? this.title,
    description: description ?? this.description,
    category: category ?? this.category,
    origin: origin ?? this.origin,
    surface: surface ?? this.surface,
    argumentSpec: argumentSpec ?? this.argumentSpec,
    executor: executor ?? this.executor,
    capabilityKey: capabilityKey ?? this.capabilityKey,
    scope: scope ?? this.scope,
    risk: risk ?? this.risk,
    availability: availability ?? this.availability,
    unavailableReason: unavailableReason ?? this.unavailableReason,
    catalogRevision: catalogRevision ?? this.catalogRevision,
  );
}

enum CommandExecutionState {
  draft,
  validating,
  awaitingConfirmation,
  executing,
  succeeded,
  failed,
  superseded,
  cancelled,
}

enum CommandOutputKind {
  none,
  systemText,
  navigation,
  statePatch,
  remotePayload,
}

enum CommandFailureKind {
  validation,
  unavailable,
  forbidden,
  conflict,
  timeout,
  transport,
  remote,
  malformed,
  superseded,
  cancelled,
}

final class CommandFailure {
  final CommandFailureKind kind;
  final int? code;
  final bool retryable;

  const CommandFailure({required this.kind, this.code, this.retryable = false});
}

final class CommandExecutionRequest {
  final String executionId;
  final CommandDescriptor command;
  final String rawArguments;
  final String connectionId;
  final String? runtimeSessionId;
  final String? storedSessionId;
  final String? lineageRootId;
  final int connectionEpoch;
  final int sessionEpoch;
  final String? confirmationId;
  final DateTime createdAt;

  factory CommandExecutionRequest({
    required String executionId,
    required CommandDescriptor command,
    String rawArguments = '',
    required String connectionId,
    String? runtimeSessionId,
    String? storedSessionId,
    String? lineageRootId,
    required int connectionEpoch,
    required int sessionEpoch,
    String? confirmationId,
    required DateTime createdAt,
  }) {
    final safeExecutionId = _boundedIdentifier(executionId, 128);
    final safeConnectionId = _boundedIdentifier(connectionId, 128);
    if (safeExecutionId == null || safeConnectionId == null) {
      throw const FormatException('invalid command execution identity');
    }
    if (connectionEpoch < 0 || sessionEpoch < 0) {
      throw const FormatException('invalid command execution epoch');
    }
    final runtime = _boundedIdentifier(runtimeSessionId, 512);
    if (command.scope == OperationScope.session && runtime == null) {
      throw const FormatException('runtime session is required');
    }
    final arguments =
        command.argumentSpec?.validate(rawArguments) ??
        _validateDefaultArguments(rawArguments);
    return CommandExecutionRequest._(
      executionId: safeExecutionId,
      command: command,
      rawArguments: arguments,
      connectionId: safeConnectionId,
      runtimeSessionId: runtime,
      storedSessionId: _boundedIdentifier(storedSessionId, 512),
      lineageRootId: _boundedIdentifier(lineageRootId, 512),
      connectionEpoch: connectionEpoch,
      sessionEpoch: sessionEpoch,
      confirmationId: _boundedIdentifier(confirmationId, 128),
      createdAt: createdAt.toUtc(),
    );
  }

  const CommandExecutionRequest._({
    required this.executionId,
    required this.command,
    required this.rawArguments,
    required this.connectionId,
    required this.runtimeSessionId,
    required this.storedSessionId,
    required this.lineageRootId,
    required this.connectionEpoch,
    required this.sessionEpoch,
    required this.confirmationId,
    required this.createdAt,
  });
}

final class CommandExecutionResult {
  final CommandOutputKind outputKind;
  final String? userMessage;
  final String? remoteRevision;
  final CommandFailure? error;

  const CommandExecutionResult({
    required this.outputKind,
    this.userMessage,
    this.remoteRevision,
    this.error,
  });
}

/// Entrada remota ya acotada del catálogo Desktop.
final class CommandCatalogEntry {
  final String canonicalName;
  final Set<String> aliases;
  final String description;
  final CommandCategory category;
  final String categoryKey;
  final String categoryLabel;
  final OperationScope scope;
  final OperationRisk risk;

  const CommandCatalogEntry._({
    required this.canonicalName,
    required this.aliases,
    required this.description,
    required this.category,
    required this.categoryKey,
    required this.categoryLabel,
    required this.scope,
    required this.risk,
  });

  CommandDescriptor toDescriptor({String? revision}) => CommandDescriptor(
    canonicalName: canonicalName,
    aliases: aliases,
    description: description,
    category: category,
    origin: CommandOrigin.catalog,
    surface: CommandSurface.remote,
    argumentSpec: CommandArgumentSpec(
      kind: CommandArgumentKind.freeText,
      maxLength: 500,
    ),
    executor: CommandExecutorKind.slashExec,
    capabilityKey: 'slash.exec',
    scope: scope,
    risk: risk,
    availability: CapabilityState.available,
    catalogRevision: revision,
  );
}

final class CommandCatalogCategory {
  final String key;
  final String label;

  const CommandCatalogCategory({required this.key, required this.label});
}

/// Payload tipado y limitado de `commands.catalog`.
final class DesktopCommandCatalog {
  static const int maxCommands = 500;
  static const int maxCategories = 32;

  final List<CommandCatalogEntry> commands;
  final List<CommandCatalogCategory> categories;
  final bool partial;
  final String? warning;
  final int? skillCount;
  final String? revision;

  const DesktopCommandCatalog._({
    required this.commands,
    required this.categories,
    required this.partial,
    this.warning,
    this.skillCount,
    this.revision,
  });

  factory DesktopCommandCatalog.fromJson(Object? value) {
    if (value is! Map) {
      return const DesktopCommandCatalog._(
        commands: [],
        categories: [],
        partial: true,
      );
    }
    final json = Map<Object?, Object?>.from(value);
    final accumulator = _CatalogAccumulator();
    if (_exceedsNesting(json, 4)) accumulator.partial = true;

    final rawCategories = json['categories'];
    if (rawCategories != null && rawCategories is! List) {
      accumulator.partial = true;
    } else if (rawCategories is List) {
      if (rawCategories.length > maxCategories) accumulator.partial = true;
      for (final raw in rawCategories.take(maxCategories)) {
        if (raw is! Map) {
          accumulator.partial = true;
          continue;
        }
        final category = Map<Object?, Object?>.from(raw);
        final rawKey = category['id'] ?? category['name'];
        final key = _categoryKey(rawKey);
        final label =
            _boundedText(
              category['label'] ?? category['name'] ?? category['id'],
              96,
            ) ??
            key;
        accumulator.addCategory(key, label);
        accumulator.addPairs(category['pairs'], key, label);
        accumulator.addDescriptors(category['commands'], key, label);
      }
    }

    accumulator.addDescriptors(json['commands'], null, null);
    accumulator.addPairs(json['pairs'], null, null);
    accumulator.addCanon(json['canon']);

    final rawSkillCount = json['skill_count'];
    final skillCount = rawSkillCount is int && rawSkillCount >= 0
        ? rawSkillCount.clamp(0, 100000)
        : null;
    final revision = _boundedIdentifier(
      json['revision'] ?? json['catalog_revision'],
      96,
    );
    return DesktopCommandCatalog._(
      commands: List<CommandCatalogEntry>.unmodifiable(accumulator.build()),
      categories: List<CommandCatalogCategory>.unmodifiable(
        accumulator.categories.values,
      ),
      partial: accumulator.partial,
      warning: _boundedText(json['warning'], 240),
      skillCount: skillCount,
      revision: revision,
    );
  }
}

final class SlashCompletionSuggestion {
  final String replacement;
  final String display;
  final String meta;
  final int replaceFrom;

  const SlashCompletionSuggestion({
    required this.replacement,
    required this.display,
    required this.meta,
    required this.replaceFrom,
  });
}

/// Respuesta tipada y acotada de `complete.slash`.
final class SlashCompletionBatch {
  static const int maxSuggestions = 50;

  final String input;
  final List<SlashCompletionSuggestion> suggestions;
  final bool partial;

  const SlashCompletionBatch._({
    required this.input,
    required this.suggestions,
    required this.partial,
  });

  factory SlashCompletionBatch.fromJson(
    Object? value, {
    required String input,
  }) {
    if (value is! Map) {
      return SlashCompletionBatch._(
        input: input,
        suggestions: const [],
        partial: true,
      );
    }
    final json = Map<Object?, Object?>.from(value);
    final items = json['items'];
    if (items is! List) {
      return SlashCompletionBatch._(
        input: input,
        suggestions: const [],
        partial: items != null,
      );
    }
    var partial = items.length > maxSuggestions;
    final fallbackReplaceFrom = _validReplaceFrom(json['replace_from'], input);
    final suggestions = <SlashCompletionSuggestion>[];
    for (final raw in items.take(maxSuggestions)) {
      if (raw is! Map) {
        partial = true;
        continue;
      }
      final item = Map<Object?, Object?>.from(raw);
      final replacement = _boundedText(item['value'] ?? item['text'], 256);
      final replaceFrom = _validReplaceFrom(
        item['replace_from'] ?? fallbackReplaceFrom,
        input,
      );
      if (replacement == null || replaceFrom == null) {
        partial = true;
        continue;
      }
      suggestions.add(
        SlashCompletionSuggestion(
          replacement: replacement,
          display: _boundedText(item['display'], 256) ?? replacement,
          meta: _boundedText(item['meta'], 240) ?? '',
          replaceFrom: replaceFrom,
        ),
      );
    }
    return SlashCompletionBatch._(
      input: input,
      suggestions: List<SlashCompletionSuggestion>.unmodifiable(suggestions),
      partial: partial,
    );
  }
}

enum DesktopCommandDispatchKind { output, send, skill, error, none }

enum DesktopCommandAcceptance { accepted, rejected, unknown }

/// Compression certainty is separate from human-facing command acceptance.
/// No affirmative legacy reply proves completion of the durable operation.
enum LegacyCompressionEvidence { ambiguous, terminalRejected }

/// Respuesta operacional saneada de `slash.exec` o `command.dispatch`.
final class DesktopCommandRpcResult {
  final DesktopCommandDispatchKind kind;
  final DesktopCommandAcceptance accepted;
  final LegacyCompressionEvidence compressionEvidence;
  final String? output;
  final String? message;
  final String? notice;
  final String? target;
  final String? commandName;
  final DesktopCompressionLegacyEvidence compressionWireEvidence;

  const DesktopCommandRpcResult({
    required this.kind,
    required this.accepted,
    this.compressionEvidence = LegacyCompressionEvidence.ambiguous,
    this.output,
    this.message,
    this.notice,
    this.target,
    this.commandName,
    this.compressionWireEvidence =
        const DesktopCompressionLegacyEvidence.unknown(),
  });

  factory DesktopCommandRpcResult.fromJson(
    Object? value, {
    DesktopCompressionLegacyEvidence compressionWireEvidence =
        const DesktopCompressionLegacyEvidence.unknown(),
  }) {
    if (value is! Map) {
      throw const FormatException('invalid command response');
    }
    final json = Map<Object?, Object?>.from(value);
    final type = json['type'];
    final output = _boundedText(json['output'], 4000);
    final message = _boundedText(json['message'], 8000);
    final notice = _boundedText(json['notice'] ?? json['warning'], 1000);
    final target = CommandDescriptor.tryNormalizeName(json['target']);
    final commandName = CommandDescriptor.tryNormalizeName(json['name']);
    final kind = switch (type) {
      'exec' || 'plugin' => DesktopCommandDispatchKind.output,
      'send' || 'prefill' || 'alias' => DesktopCommandDispatchKind.send,
      'skill' => DesktopCommandDispatchKind.skill,
      'error' => DesktopCommandDispatchKind.error,
      _ when output != null => DesktopCommandDispatchKind.output,
      _ => DesktopCommandDispatchKind.none,
    };
    final status = json['status'];
    final accepted = switch ((json['accepted'], status, kind)) {
      // `accepted: false` with `status: pending` is a real, distinct wire
      // shape: the legacy gateway saw the command but hasn't settled it yet
      // (queued, still working) — not a rejection. Collapsing it to
      // `rejected` made it indistinguishable from a genuine "no", which
      // matters for callers (like /compress) that treat those two
      // differently.
      (false, 'pending', _) => DesktopCommandAcceptance.unknown,
      (false, _, _) => DesktopCommandAcceptance.rejected,
      (_, 'rejected' || 'failed' || 'error', _) =>
        DesktopCommandAcceptance.rejected,
      (_, _, DesktopCommandDispatchKind.error) =>
        DesktopCommandAcceptance.rejected,
      _ => DesktopCommandAcceptance.accepted,
    };
    return DesktopCommandRpcResult(
      kind: kind,
      accepted: accepted,
      compressionEvidence: _compressionEvidence(json),
      output: output,
      message: message,
      notice: notice,
      target: target,
      commandName: commandName,
      compressionWireEvidence: compressionWireEvidence,
    );
  }

  static LegacyCompressionEvidence _compressionEvidence(
    Map<Object?, Object?> json,
  ) {
    // A closed rejection envelope: execution/output/pending, unknown fields,
    // malformed values and conflicting positive acceptance all fail closed.
    // Human message/notice content is never interpreted as protocol authority.
    const fields = {
      'accepted',
      'type',
      'status',
      'message',
      'notice',
      'warning',
    };
    final accepted = json['accepted'];
    final type = json['type'];
    final status = json['status'];
    if (json.keys.any((key) => !fields.contains(key)) ||
        (json.containsKey('accepted') && accepted != false) ||
        (json.containsKey('type') && type != 'error' && type != 'none') ||
        (json.containsKey('status') && status != 'rejected') ||
        const [
          'message',
          'notice',
          'warning',
        ].any((key) => json.containsKey(key) && json[key] is! String)) {
      return LegacyCompressionEvidence.ambiguous;
    }
    return accepted == false || status == 'rejected'
        ? LegacyCompressionEvidence.terminalRejected
        : LegacyCompressionEvidence.ambiguous;
  }
}

enum DesktopCommandRoute { sessionCompress, slashExec, commandDispatch }

/// Resultado del adapter de Desktop. [arg] es efímero y se excluye siempre de
/// [diagnosticFields]; nunca debe interpolarse en logs o errores.
final class DesktopCommandDispatch {
  final String commandName;
  final String arg;
  final String sessionId;
  final int connectionEpoch;
  final int sessionEpoch;
  final DesktopCommandRoute attemptedRoute;
  final bool fallbackUsed;
  final DesktopCommandDispatchKind dispatchKind;
  final String? output;
  final DesktopCommandAcceptance accepted;
  final CommandFailure? failure;
  final DesktopCompressionStatus? compressionStatus;
  final DesktopCompressionResult? compressionResult;

  const DesktopCommandDispatch({
    required this.commandName,
    required this.arg,
    required this.sessionId,
    required this.connectionEpoch,
    required this.sessionEpoch,
    required this.attemptedRoute,
    required this.fallbackUsed,
    required this.dispatchKind,
    required this.accepted,
    this.output,
    this.failure,
    this.compressionStatus,
    this.compressionResult,
  });

  Map<String, Object?> get diagnosticFields => <String, Object?>{
    'command_name': commandName,
    'route': attemptedRoute.name,
    'fallback_used': fallbackUsed,
    'dispatch_kind': dispatchKind.name,
    'accepted': accepted.name,
    if (compressionStatus != null)
      'compression_status': compressionStatus!.name,
    if (failure?.code != null) 'error_code': failure!.code,
    if (failure != null) 'error_class': failure!.kind.name,
  };
}

final class _CatalogAccumulator {
  final Map<String, _MutableCatalogEntry> entries = {};
  final Map<String, CommandCatalogCategory> categories = {};
  final Map<String, String> aliases = {};
  bool partial = false;

  void addCategory(String key, String label) {
    if (categories.containsKey(key)) return;
    if (categories.length >= DesktopCommandCatalog.maxCategories) {
      partial = true;
      return;
    }
    categories[key] = CommandCatalogCategory(key: key, label: label);
  }

  void addPairs(Object? raw, String? categoryKey, String? categoryLabel) {
    if (raw == null) return;
    if (raw is! List) {
      partial = true;
      return;
    }
    if (raw.length > DesktopCommandCatalog.maxCommands * 2) partial = true;
    for (final pair in raw.take(DesktopCommandCatalog.maxCommands * 2)) {
      if (pair is! List || pair.isEmpty) {
        partial = true;
        continue;
      }
      addEntry(
        name: pair[0],
        description: pair.length > 1 ? pair[1] : '',
        categoryKey: categoryKey,
        categoryLabel: categoryLabel,
      );
    }
  }

  void addDescriptors(Object? raw, String? categoryKey, String? categoryLabel) {
    if (raw == null) return;
    if (raw is! List) {
      partial = true;
      return;
    }
    if (raw.length > DesktopCommandCatalog.maxCommands * 2) partial = true;
    for (final item in raw.take(DesktopCommandCatalog.maxCommands * 2)) {
      if (item is! Map) {
        partial = true;
        continue;
      }
      final descriptor = Map<Object?, Object?>.from(item);
      addEntry(
        name: descriptor['name'] ?? descriptor['command'],
        description: descriptor['description'] ?? descriptor['meta'] ?? '',
        categoryKey: descriptor['category']?.toString() ?? categoryKey,
        categoryLabel: categoryLabel,
        scope: descriptor['scope'],
        risk: descriptor['risk'],
        rawAliases: descriptor['aliases'],
      );
    }
  }

  void addEntry({
    required Object? name,
    required Object? description,
    String? categoryKey,
    String? categoryLabel,
    Object? scope,
    Object? risk,
    Object? rawAliases,
  }) {
    final canonical = CommandDescriptor.tryNormalizeName(name);
    if (canonical == null) {
      partial = true;
      return;
    }
    final existing = entries[canonical];
    if (existing == null &&
        entries.length >= DesktopCommandCatalog.maxCommands) {
      partial = true;
      return;
    }
    final key = _categoryKey(categoryKey);
    final label = _boundedText(categoryLabel, 96) ?? _categoryLabel(key);
    addCategory(key, label);
    final safeDescription = _boundedText(description, 240) ?? '';
    if (description is String && description.trim().length > 240) {
      partial = true;
    }
    final entry =
        existing ??
        _MutableCatalogEntry(
          canonicalName: canonical,
          description: safeDescription,
          categoryKey: key,
          categoryLabel: label,
          scope: operationScopeFromWire(scope),
          risk: operationRiskFromWire(risk),
        );
    if (existing == null) entries[canonical] = entry;
    if (entry.description.isEmpty && safeDescription.isNotEmpty) {
      entry.description = safeDescription;
    }
    if (rawAliases is List) {
      for (final rawAlias in rawAliases.take(64)) {
        final alias = CommandDescriptor.tryNormalizeName(rawAlias);
        if (alias == null) {
          partial = true;
        } else if (alias != canonical) {
          entry.aliases.add(alias);
        }
      }
      if (rawAliases.length > 64) partial = true;
    } else if (rawAliases != null) {
      partial = true;
    }
  }

  void addCanon(Object? raw) {
    if (raw == null) return;
    if (raw is! Map) {
      partial = true;
      return;
    }
    var scanned = 0;
    for (final item in raw.entries) {
      if (scanned++ >= 2048) {
        partial = true;
        break;
      }
      final alias = CommandDescriptor.tryNormalizeName(item.key);
      final canonical = CommandDescriptor.tryNormalizeName(item.value);
      if (alias == null || canonical == null) {
        partial = true;
        continue;
      }
      if (alias != canonical) aliases[alias] = canonical;
    }
  }

  List<CommandCatalogEntry> build() {
    for (final item in aliases.entries) {
      entries[item.value]?.aliases.add(item.key);
    }
    return entries.values.map((entry) => entry.build()).toList(growable: false);
  }
}

final class _MutableCatalogEntry {
  final String canonicalName;
  final Set<String> aliases = {};
  String description;
  final String categoryKey;
  final String categoryLabel;
  final OperationScope scope;
  final OperationRisk risk;

  _MutableCatalogEntry({
    required this.canonicalName,
    required this.description,
    required this.categoryKey,
    required this.categoryLabel,
    required this.scope,
    required this.risk,
  });

  CommandCatalogEntry build() => CommandCatalogEntry._(
    canonicalName: canonicalName,
    aliases: Set<String>.unmodifiable(aliases),
    description: description,
    category: _commandCategory(categoryKey),
    categoryKey: categoryKey,
    categoryLabel: categoryLabel,
    scope: scope,
    risk: risk,
  );
}

CommandCategory _commandCategory(String raw) => switch (raw) {
  'session' => CommandCategory.session,
  'context' => CommandCategory.context,
  'navigation' => CommandCategory.navigation,
  'agent' || 'agents' => CommandCategory.agent,
  'tool' || 'tools' => CommandCategory.tools,
  'project' || 'projects' => CommandCategory.project,
  _ => CommandCategory.extension,
};

String _categoryKey(Object? raw) {
  final value = raw?.toString().trim().toLowerCase() ?? '';
  if (RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(value)) return value;
  return 'extension';
}

String _categoryLabel(String key) => switch (key) {
  'session' => 'Session',
  'context' => 'Context',
  'navigation' => 'Navigation',
  'agent' || 'agents' => 'Agent',
  'tool' || 'tools' => 'Tools',
  'project' || 'projects' => 'Project',
  _ => 'Extensions',
};

int? _validReplaceFrom(Object? value, String input) {
  if (value is! int || value < 0 || value > input.length) return null;
  return value;
}

bool _exceedsNesting(Object? value, int maxDepth) {
  final stack = <(Object?, int)>[(value, 0)];
  var visited = 0;
  while (stack.isNotEmpty) {
    final (current, depth) = stack.removeLast();
    if (++visited > 10000) return true;
    if (current is Map) {
      if (depth > maxDepth && current.isNotEmpty) return true;
      for (final child in current.values) {
        if (child is Map || child is List) stack.add((child, depth + 1));
      }
    } else if (current is List) {
      if (depth > maxDepth && current.isNotEmpty) return true;
      for (final child in current) {
        if (child is Map || child is List) stack.add((child, depth + 1));
      }
    }
  }
  return false;
}

String _validateDefaultArguments(String raw) {
  final value = raw.trim();
  if (value.length > 500) {
    throw const FormatException('command argument is too long');
  }
  return value;
}

String _capabilityKey(String raw) {
  final value = raw.trim().toLowerCase();
  if (!RegExp(r'^[a-z][a-z0-9_.-]{0,127}$').hasMatch(value)) {
    throw const FormatException('invalid capability key');
  }
  return value;
}

String? _boundedIdentifier(Object? value, int maxLength) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > maxLength) return null;
  if (trimmed.contains(RegExp(r'[\x00-\x1F\x7F]'))) return null;
  return trimmed;
}

String? _boundedText(Object? value, int maxLength) {
  if (value is! String) return null;
  final cleaned = value
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
      .trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= maxLength
      ? cleaned
      : cleaned.substring(0, maxLength);
}
