import '../models/capability_descriptor.dart';
import '../models/command_descriptor.dart';

enum RegistrySourceState { ready, partial, legacy, failed, offline }

enum RegistryErrorKind { malformed, unavailable, unauthorized, transport }

enum CommandResolutionKind { found, unknown, conflict }

final class CommandCategoryView {
  final CommandCategory category;
  final List<CommandDescriptor> descriptors;

  const CommandCategoryView({
    required this.category,
    required this.descriptors,
  });
}

final class CommandRegistrySnapshot {
  final String connectionId;
  final BackendIdentity backendIdentity;
  final Map<String, CommandDescriptor> descriptors;
  final Map<String, String> aliases;
  final Set<String> conflicts;
  final List<CommandCategoryView> categories;
  final DateTime fetchedAt;
  final int revision;
  final RegistrySourceState sourceState;
  final RegistryErrorKind? errorKind;

  const CommandRegistrySnapshot({
    required this.connectionId,
    required this.backendIdentity,
    required this.descriptors,
    required this.aliases,
    required this.conflicts,
    required this.categories,
    required this.fetchedAt,
    required this.revision,
    required this.sourceState,
    this.errorKind,
  });
}

final class CommandResolution {
  final CommandResolutionKind kind;
  final CommandDescriptor? descriptor;
  final bool matchedAlias;

  const CommandResolution._(
    this.kind, {
    this.descriptor,
    this.matchedAlias = false,
  });
}

/// Merge determinista de comandos nativos, adapters, catálogo y legacy.
///
/// Las completions viven fuera del índice ejecutable: pueden sugerir un nombre,
/// pero nunca conceden `available` ni convierten un comando desconocido en uno
/// ejecutable.
final class CommandRegistry {
  final String connectionId;
  final BackendIdentity backendIdentity;
  final DateTime Function() _now;

  final List<CommandDescriptor> _nativeAndAdapters;
  final List<CommandDescriptor> _legacy;
  List<CommandDescriptor> _catalog = const [];
  List<CommandDescriptor> _completionSuggestions = const [];

  Map<String, CommandDescriptor> _descriptors = const {};
  Map<String, String> _aliases = const {};
  Set<String> _conflicts = const {};
  RegistrySourceState _sourceState;
  RegistryErrorKind? _errorKind;
  DateTime _fetchedAt;
  int _revision = 0;

  CommandRegistry({
    required this.connectionId,
    required this.backendIdentity,
    Iterable<CommandDescriptor> nativeDescriptors = const [],
    Iterable<CommandDescriptor> legacyDescriptors = const [],
    DateTime Function()? now,
  }) : _nativeAndAdapters = List.unmodifiable(nativeDescriptors),
       _legacy = List.unmodifiable(legacyDescriptors),
       _now = now ?? DateTime.now,
       _sourceState = legacyDescriptors.isEmpty
           ? RegistrySourceState.ready
           : RegistrySourceState.legacy,
       _fetchedAt = (now ?? DateTime.now)().toUtc() {
    if (connectionId.trim().isEmpty) {
      throw const FormatException('invalid command registry connection');
    }
    _rebuild();
  }

  CommandRegistrySnapshot get snapshot {
    final grouped = <CommandCategory, List<CommandDescriptor>>{};
    for (final descriptor in _descriptors.values) {
      grouped.putIfAbsent(descriptor.category, () => []).add(descriptor);
    }
    final categories = <CommandCategoryView>[];
    for (final category in CommandCategory.values) {
      final values = grouped[category];
      if (values == null || values.isEmpty) continue;
      values.sort((a, b) => a.title.compareTo(b.title));
      categories.add(
        CommandCategoryView(
          category: category,
          descriptors: List<CommandDescriptor>.unmodifiable(values),
        ),
      );
    }
    return CommandRegistrySnapshot(
      connectionId: connectionId,
      backendIdentity: backendIdentity,
      descriptors: _descriptors,
      aliases: _aliases,
      conflicts: _conflicts,
      categories: List<CommandCategoryView>.unmodifiable(categories),
      fetchedAt: _fetchedAt,
      revision: _revision,
      sourceState: _sourceState,
      errorKind: _errorKind,
    );
  }

  List<CommandDescriptor> get completionSuggestions => _completionSuggestions;

  void replaceCatalog(DesktopCommandCatalog catalog) {
    _catalog = List<CommandDescriptor>.unmodifiable(
      catalog.commands.map(
        (entry) => entry.toDescriptor(revision: catalog.revision),
      ),
    );
    _sourceState = catalog.partial
        ? RegistrySourceState.partial
        : RegistrySourceState.ready;
    _errorKind = catalog.partial ? RegistryErrorKind.malformed : null;
    _fetchedAt = _now().toUtc();
    _rebuild();
  }

  void replaceCompletions(SlashCompletionBatch batch) {
    final suggestions = <CommandDescriptor>[];
    final seen = <String>{};
    for (final suggestion in batch.suggestions) {
      final token = suggestion.replacement.trim().split(RegExp(r'\s+')).first;
      final canonical = CommandDescriptor.tryNormalizeName(token);
      if (canonical == null || !seen.add(canonical)) continue;

      final resolution = resolve(canonical);
      final known = resolution.descriptor;
      suggestions.add(
        CommandDescriptor(
          canonicalName: known?.canonicalName ?? canonical,
          aliases: known?.aliases ?? const [],
          title: suggestion.display,
          description: suggestion.meta,
          category: known?.category ?? CommandCategory.extension,
          origin: CommandOrigin.completion,
          surface: known?.surface ?? CommandSurface.remote,
          argumentSpec:
              known?.argumentSpec ??
              CommandArgumentSpec(kind: CommandArgumentKind.freeText),
          executor: known?.executor ?? CommandExecutorKind.slashExec,
          capabilityKey: known?.capabilityKey ?? 'slash.exec',
          scope: known?.scope ?? OperationScope.session,
          risk: known?.risk ?? OperationRisk.medium,
          // Completion solo sugiere. La ejecución vuelve a resolver catálogo o
          // adapter y nunca usa esta disponibilidad.
          availability: CapabilityState.unknown,
          unavailableReason: 'completion_requires_validation',
        ),
      );
    }
    _completionSuggestions = List.unmodifiable(suggestions);
    _revision++;
  }

  CommandResolution resolve(String rawName) {
    final normalized = CommandDescriptor.tryNormalizeName(rawName);
    if (normalized == null) {
      return const CommandResolution._(CommandResolutionKind.unknown);
    }
    if (_conflicts.contains(normalized)) {
      return CommandResolution._(
        CommandResolutionKind.conflict,
        descriptor: _descriptors[normalized],
      );
    }
    final exact = _descriptors[normalized];
    if (exact != null) {
      return CommandResolution._(
        CommandResolutionKind.found,
        descriptor: exact,
      );
    }
    final canonical = _aliases[normalized];
    if (canonical == null) {
      return const CommandResolution._(CommandResolutionKind.unknown);
    }
    if (_conflicts.contains(canonical) || _conflicts.contains(normalized)) {
      return CommandResolution._(
        CommandResolutionKind.conflict,
        descriptor: _descriptors[canonical],
        matchedAlias: true,
      );
    }
    return CommandResolution._(
      CommandResolutionKind.found,
      descriptor: _descriptors[canonical],
      matchedAlias: true,
    );
  }

  void markFailed(RegistryErrorKind errorKind, {bool offline = false}) {
    _sourceState = offline
        ? RegistrySourceState.offline
        : RegistrySourceState.failed;
    _errorKind = errorKind;
    _fetchedAt = _now().toUtc();
    _revision++;
  }

  void _rebuild() {
    final byNameAndOrigin = <String, Map<CommandOrigin, CommandDescriptor>>{};
    for (final descriptor in <CommandDescriptor>[
      ..._legacy,
      ..._catalog,
      ..._nativeAndAdapters,
    ]) {
      final byOrigin = byNameAndOrigin.putIfAbsent(
        descriptor.canonicalName,
        () => {},
      );
      final previous = byOrigin[descriptor.origin];
      if (previous == null ||
          descriptor.description.length > previous.description.length) {
        byOrigin[descriptor.origin] = descriptor;
      }
    }

    final descriptors = <String, CommandDescriptor>{};
    final conflicts = <String>{};
    for (final item in byNameAndOrigin.entries) {
      final candidates = item.value.values.toList()
        ..sort((a, b) => b.precedence.compareTo(a.precedence));
      final winner = candidates.first;
      final incompatible = candidates
          .skip(1)
          .any((candidate) => !winner.isSemanticallyCompatibleWith(candidate));
      if (incompatible) {
        conflicts.add(item.key);
        descriptors[item.key] = winner.copyWith(
          surface: CommandSurface.unavailable,
          availability: CapabilityState.forbidden,
          unavailableReason: 'semantic_conflict',
        );
      } else {
        final aliases = <String>{
          for (final candidate in candidates) ...candidate.aliases,
        };
        descriptors[item.key] = winner.copyWith(aliases: aliases);
      }
    }

    final aliases = <String, String>{};
    final aliasOwners = <String, Set<String>>{};
    for (final descriptor in descriptors.values) {
      for (final alias in descriptor.aliases) {
        if (descriptors.containsKey(alias)) continue;
        aliasOwners.putIfAbsent(alias, () => {}).add(descriptor.canonicalName);
      }
    }
    for (final item in aliasOwners.entries) {
      if (item.value.length == 1) {
        aliases[item.key] = item.value.single;
      } else {
        conflicts.add(item.key);
        conflicts.addAll(item.value);
      }
    }

    _descriptors = Map.unmodifiable(descriptors);
    _aliases = Map.unmodifiable(aliases);
    _conflicts = Set.unmodifiable(conflicts);
    _revision++;
  }
}
