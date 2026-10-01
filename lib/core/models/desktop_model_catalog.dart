/// Catálogo defensivo de modelos expuesto por Hermes Desktop 0.19.
///
/// Los identificadores son opacos: si superan los límites estructurales o
/// contienen separadores de comando/controles se descartan, pero nunca se
/// normalizan ni se reinterpretan. El modelo retiene únicamente los campos que
/// necesita la UI; no conserva el payload original ni credenciales.
final class DesktopModelCatalog {
  static const int maxProviders = 128;
  static const int maxModelsPerProvider = 512;
  static const int maxModels = 2048;

  final String? currentModel;
  final String? currentProvider;
  final List<DesktopModelProvider> providers;

  const DesktopModelCatalog({
    this.currentModel,
    this.currentProvider,
    this.providers = const [],
  });

  factory DesktopModelCatalog.fromJson(Object? value) {
    final json = _map(value);
    if (json == null) return const DesktopModelCatalog();

    final currentModel = _opaqueIdentifier(json['model']);
    final currentProvider = _opaqueIdentifier(json['provider']);
    final rawProviders = json['providers'];
    if (rawProviders is! List) {
      return DesktopModelCatalog(
        currentModel: currentModel,
        currentProvider: currentProvider,
      );
    }

    final accumulators = <String, _ProviderAccumulator>{};
    var modelCount = 0;
    final providerRows = rawProviders.length < _maxProviderRowsScanned
        ? rawProviders.length
        : _maxProviderRowsScanned;
    for (var index = 0; index < providerRows; index++) {
      final row = _ProviderRow.tryParse(rawProviders[index]);
      if (row == null) continue;

      var accumulator = accumulators[row.slug];
      if (accumulator == null) {
        if (accumulators.length >= maxProviders) continue;
        accumulator = _ProviderAccumulator(row);
        accumulators[row.slug] = accumulator;
      } else {
        accumulator.mergeMetadata(row);
      }

      for (final option in row.options) {
        if (accumulator.containsModel(option.id)) {
          accumulator.mergeOption(option);
          continue;
        }
        if (modelCount >= maxModels ||
            accumulator.modelCount >= maxModelsPerProvider) {
          continue;
        }
        accumulator.addOption(option);
        modelCount++;
      }
    }

    return DesktopModelCatalog(
      currentModel: currentModel,
      currentProvider: currentProvider,
      providers: List<DesktopModelProvider>.unmodifiable(
        accumulators.values.map((item) => item.build()),
      ),
    );
  }

  /// Row for [slug]. Exact slug first; then, like Desktop's
  /// `catalogProviderMatches`, the display name or a published alias, because
  /// `session.info` reports user-defined endpoints as `custom:<key>` while
  /// the row's slug is the bare key (Hermes #87035).
  DesktopModelProvider? providerFor(String slug) {
    for (final provider in providers) {
      if (provider.slug == slug) return provider;
    }
    final wanted = slug.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    for (final provider in providers) {
      if (provider.name.toLowerCase() == wanted ||
          provider.aliases.contains(wanted)) {
        return provider;
      }
    }
    return null;
  }

  DesktopModelOption? optionFor(String providerSlug, String modelId) =>
      providerFor(providerSlug)?.optionFor(modelId);
}

final class DesktopModelProvider {
  final String slug;
  final String name;
  final bool isCurrent;

  /// `null` significa que el servidor no publicó estado de autenticación.
  final bool? authenticated;
  final String? authType;

  /// Solo el nombre validado de una variable; nunca su valor.
  final String? keyEnv;
  final String? warning;
  final bool isUserDefined;

  /// Lower-cased identities Hermes accepts for this endpoint (`aliases`).
  /// Used only to recognise the current provider, never sent back.
  final Set<String> aliases;

  /// `null` fuera de proveedores/catálogos que anuncian el tier.
  final bool? freeTier;
  final List<DesktopModelOption> options;
  final List<String> models;
  final List<String> unavailableModels;
  final Map<String, DesktopModelCapabilities> capabilities;
  final Map<String, DesktopModelPricing> pricing;

  DesktopModelProvider._({
    required this.slug,
    required this.name,
    required this.isCurrent,
    required this.authenticated,
    required this.authType,
    required this.keyEnv,
    required this.warning,
    required this.isUserDefined,
    required this.freeTier,
    required List<DesktopModelOption> options,
    Set<String> aliases = const {},
  }) : aliases = Set<String>.unmodifiable(aliases),
       options = List<DesktopModelOption>.unmodifiable(options),
       models = List<String>.unmodifiable(options.map((item) => item.id)),
       unavailableModels = List<String>.unmodifiable(
         options.where((item) => item.unavailable).map((item) => item.id),
       ),
       capabilities = Map<String, DesktopModelCapabilities>.unmodifiable({
         for (final option in options) option.id: option.capabilities,
       }),
       pricing = Map<String, DesktopModelPricing>.unmodifiable({
         for (final option in options)
           if (option.pricing != null) option.id: option.pricing!,
       });

  bool get hasWarning => warning != null;

  /// Ausencia de autenticación no se interpreta como permiso para usarlo.
  bool get isUsable => authenticated == true && !hasWarning;

  DesktopModelOption? optionFor(String modelId) {
    for (final option in options) {
      if (option.id == modelId) return option;
    }
    return null;
  }

  bool isModelUsable(String modelId) {
    final option = optionFor(modelId);
    return isUsable && option != null && !option.unavailable;
  }
}

final class DesktopModelOption {
  final String providerSlug;
  final String id;
  final bool unavailable;
  final DesktopModelCapabilities capabilities;
  final DesktopModelPricing? pricing;

  const DesktopModelOption({
    required this.providerSlug,
    required this.id,
    required this.unavailable,
    required this.capabilities,
    this.pricing,
  });
}

final class DesktopModelCapabilities {
  /// `null` significa desconocido, no `false`.
  final bool? fast;

  /// `null` significa desconocido, no `false`.
  final bool? reasoning;

  const DesktopModelCapabilities({this.fast, this.reasoning});

  bool get isKnown => fast != null || reasoning != null;

  DesktopModelCapabilities _fillMissingFrom(
    DesktopModelCapabilities fallback,
  ) => DesktopModelCapabilities(
    fast: fast ?? fallback.fast,
    reasoning: reasoning ?? fallback.reasoning,
  );

  static DesktopModelCapabilities parse(Object? value) {
    final json = _map(value);
    if (json == null) return const DesktopModelCapabilities();
    return DesktopModelCapabilities(
      fast: json['fast'] is bool ? json['fast'] as bool : null,
      reasoning: json['reasoning'] is bool ? json['reasoning'] as bool : null,
    );
  }
}

/// Precio meramente informativo ya formateado por Hermes (por millón de
/// tokens). Solo se admiten los cuatro campos públicos del contrato.
final class DesktopModelPricing {
  final String? input;
  final String? output;
  final String? cache;
  final bool? free;

  const DesktopModelPricing({this.input, this.output, this.cache, this.free});

  DesktopModelPricing _fillMissingFrom(DesktopModelPricing fallback) =>
      DesktopModelPricing(
        input: input ?? fallback.input,
        output: output ?? fallback.output,
        cache: cache ?? fallback.cache,
        free: free ?? fallback.free,
      );

  static DesktopModelPricing? tryParse(Object? value) {
    final json = _map(value);
    if (json == null) return null;
    final input = _priceLabel(json['input']);
    final output = _priceLabel(json['output']);
    final cache = _priceLabel(json['cache']);
    final free = json['free'] is bool ? json['free'] as bool : null;
    if (input == null && output == null && cache == null && free == null) {
      return null;
    }
    return DesktopModelPricing(
      input: input,
      output: output,
      cache: cache,
      free: free,
    );
  }
}

final class _ProviderRow {
  final String slug;
  final String name;
  final bool isCurrent;
  final bool? authenticated;
  final String? authType;
  final String? keyEnv;
  final String? warning;
  final bool isUserDefined;
  final bool? freeTier;
  final List<_OptionCandidate> options;
  final int authenticationRank;
  final int richness;
  final Set<String> aliases;

  const _ProviderRow({
    required this.slug,
    required this.name,
    required this.isCurrent,
    required this.authenticated,
    required this.authType,
    required this.keyEnv,
    required this.warning,
    required this.isUserDefined,
    required this.freeTier,
    required this.options,
    required this.authenticationRank,
    required this.richness,
    this.aliases = const {},
  });

  static _ProviderRow? tryParse(Object? value) {
    final json = _map(value);
    if (json == null) return null;
    final slug = _opaqueIdentifier(json['slug']);
    if (slug == null) return null;

    final rawModels = json['models'];
    if (rawModels != null && rawModels is! List) return null;
    final authenticated = json['authenticated'] is bool
        ? json['authenticated'] as bool
        : null;
    final authenticationRank = switch (authenticated) {
      true => 2,
      false => 1,
      null => 0,
    };
    final name = _boundedText(json['name'], _maxProviderNameLength) ?? slug;
    final authType = _boundedText(json['auth_type'], _maxAuthTypeLength);
    final keyEnv = _environmentVariableName(json['key_env']);
    final warning = _boundedText(json['warning'], _maxWarningLength);
    final isCurrent = json['is_current'] == true;
    final isUserDefined = json['is_user_defined'] == true;
    final freeTier = json['free_tier'] is bool
        ? json['free_tier'] as bool
        : null;

    final unavailableRaw = json['unavailable_models'];
    final unavailableKnown = unavailableRaw is List;
    final unavailable = <String>{};
    if (unavailableRaw is List) {
      final count = unavailableRaw.length < _maxModelRowsScanned
          ? unavailableRaw.length
          : _maxModelRowsScanned;
      for (var index = 0; index < count; index++) {
        final id = _opaqueIdentifier(unavailableRaw[index]);
        if (id != null &&
            unavailable.length < DesktopModelCatalog.maxModelsPerProvider) {
          unavailable.add(id);
        }
      }
    }

    final capabilities = _map(json['capabilities']);
    final pricing = _map(json['pricing']);
    final optionIds = <String>{};
    if (rawModels is List) {
      final count = rawModels.length < _maxModelRowsScanned
          ? rawModels.length
          : _maxModelRowsScanned;
      for (var index = 0; index < count; index++) {
        if (optionIds.length >= DesktopModelCatalog.maxModelsPerProvider) break;
        final id = _opaqueIdentifier(rawModels[index]);
        if (id != null) optionIds.add(id);
      }
    }

    var metadataCount = 0;
    if (name != slug) metadataCount++;
    if (authType != null) metadataCount++;
    if (keyEnv != null) metadataCount++;
    if (warning != null) metadataCount++;
    if (freeTier != null) metadataCount++;
    if (isCurrent) metadataCount++;
    if (isUserDefined) metadataCount++;
    final richness =
        authenticationRank * 1000000 + optionIds.length * 16 + metadataCount;
    final options = <_OptionCandidate>[
      for (final id in optionIds)
        _OptionCandidate(
          id: id,
          unavailable: unavailableKnown ? unavailable.contains(id) : null,
          capabilities: DesktopModelCapabilities.parse(capabilities?[id]),
          pricing: DesktopModelPricing.tryParse(pricing?[id]),
          authenticationRank: authenticationRank,
          richness: richness,
        ),
    ];

    return _ProviderRow(
      slug: slug,
      name: name,
      isCurrent: isCurrent,
      authenticated: authenticated,
      authType: authType,
      keyEnv: keyEnv,
      warning: warning,
      isUserDefined: isUserDefined,
      freeTier: freeTier,
      options: List<_OptionCandidate>.unmodifiable(options),
      authenticationRank: authenticationRank,
      richness: richness,
      aliases: _aliases(json['aliases']),
    );
  }
}

final class _ProviderAccumulator {
  _ProviderAccumulator(_ProviderRow first)
    : _primary = first,
      _authenticated = first.authenticated,
      _authenticationRank = first.authenticationRank,
      _isCurrent = first.isCurrent,
      _isUserDefined = first.isUserDefined,
      _freeTier = first.freeTier,
      _freeTierRank = first.freeTier == null ? -1 : first.authenticationRank,
      _freeTierRichness = first.freeTier == null ? -1 : first.richness,
      _warning = first.warning,
      _warningRank = first.warning == null ? -1 : first.authenticationRank;

  _ProviderRow _primary;
  bool? _authenticated;
  int _authenticationRank;
  bool _isCurrent;
  bool _isUserDefined;
  bool? _freeTier;
  int _freeTierRank;
  int _freeTierRichness;
  String? _warning;
  int _warningRank;
  final Map<String, _OptionCandidate> _options = {};
  final Set<String> _aliases = {};

  int get modelCount => _options.length;

  bool containsModel(String id) => _options.containsKey(id);

  void mergeMetadata(_ProviderRow row) {
    _aliases.addAll(row.aliases);
    if (row.richness > _primary.richness) _primary = row;
    _isCurrent = _isCurrent || row.isCurrent;
    _isUserDefined = _isUserDefined || row.isUserDefined;
    if (row.authenticationRank > _authenticationRank) {
      _authenticated = row.authenticated;
      _authenticationRank = row.authenticationRank;
    }
    if (row.warning != null &&
        (row.authenticationRank > _warningRank ||
            (row.authenticationRank == _warningRank &&
                row.warning!.length > (_warning?.length ?? 0)))) {
      _warning = row.warning;
      _warningRank = row.authenticationRank;
    }
    if (row.freeTier != null &&
        (row.authenticationRank > _freeTierRank ||
            (row.authenticationRank == _freeTierRank &&
                row.richness > _freeTierRichness))) {
      _freeTier = row.freeTier;
      _freeTierRank = row.authenticationRank;
      _freeTierRichness = row.richness;
    }
  }

  void addOption(_OptionCandidate option) {
    _options[option.id] = option;
  }

  void mergeOption(_OptionCandidate option) {
    final current = _options[option.id];
    if (current != null) _options[option.id] = current.merge(option);
  }

  DesktopModelProvider build() {
    final warning = _warningRank == _authenticationRank ? _warning : null;
    return DesktopModelProvider._(
      slug: _primary.slug,
      name: _primary.name,
      isCurrent: _isCurrent,
      authenticated: _authenticated,
      authType: _primary.authType,
      keyEnv: _primary.keyEnv,
      warning: warning,
      isUserDefined: _isUserDefined,
      freeTier: _freeTier,
      aliases: {..._primary.aliases, ..._aliases},
      options: [
        for (final option in _options.values)
          DesktopModelOption(
            providerSlug: _primary.slug,
            id: option.id,
            unavailable: option.unavailable == true,
            capabilities: option.capabilities,
            pricing: option.pricing,
          ),
      ],
    );
  }
}

final class _OptionCandidate {
  final String id;
  final bool? unavailable;
  final DesktopModelCapabilities capabilities;
  final DesktopModelPricing? pricing;
  final int authenticationRank;
  final int richness;

  const _OptionCandidate({
    required this.id,
    required this.unavailable,
    required this.capabilities,
    required this.pricing,
    required this.authenticationRank,
    required this.richness,
  });

  _OptionCandidate merge(_OptionCandidate other) {
    final otherWins = other.richness > richness;
    final primary = otherWins ? other : this;
    final fallback = otherWins ? this : other;
    final bool? mergedUnavailable;
    if (other.authenticationRank > authenticationRank) {
      mergedUnavailable = other.unavailable;
    } else if (other.authenticationRank < authenticationRank) {
      mergedUnavailable = unavailable;
    } else if (unavailable == true || other.unavailable == true) {
      mergedUnavailable = true;
    } else if (unavailable == false || other.unavailable == false) {
      mergedUnavailable = false;
    } else {
      mergedUnavailable = null;
    }
    final primaryPricing = primary.pricing;
    final fallbackPricing = fallback.pricing;
    return _OptionCandidate(
      id: id,
      unavailable: mergedUnavailable,
      capabilities: primary.capabilities._fillMissingFrom(
        fallback.capabilities,
      ),
      pricing: primaryPricing == null
          ? fallbackPricing
          : fallbackPricing == null
          ? primaryPricing
          : primaryPricing._fillMissingFrom(fallbackPricing),
      authenticationRank: primary.authenticationRank,
      richness: primary.richness,
    );
  }
}

Map<Object?, Object?>? _map(Object? value) => value is Map ? value : null;

const _maxAliases = 32;

Set<String> _aliases(Object? value) {
  if (value is! List) return const {};
  final aliases = <String>{};
  for (final raw in value.take(_maxAliases)) {
    if (raw is! String) continue;
    final alias = raw.trim().toLowerCase();
    if (alias.isEmpty ||
        alias.length > _maxIdentifierLength ||
        _identifierControl.hasMatch(alias)) {
      continue;
    }
    aliases.add(alias);
  }
  return aliases;
}

String? _opaqueIdentifier(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > _maxIdentifierLength ||
      value.startsWith('-') ||
      value.trim() != value ||
      _identifierWhitespace.hasMatch(value) ||
      _identifierControl.hasMatch(value) ||
      _hasCommandDelimiter(value)) {
    return null;
  }
  return value;
}

bool _hasCommandDelimiter(String value) {
  for (final codeUnit in value.codeUnits) {
    if (_commandDelimiterCodeUnits.contains(codeUnit)) return true;
  }
  return false;
}

String? _environmentVariableName(Object? value) {
  if (value is! String || value.length > _maxEnvironmentNameLength) {
    return null;
  }
  return _environmentName.hasMatch(value) ? value : null;
}

String? _boundedText(Object? value, int maxRunes) {
  if (value is! String) return null;
  final prefix = String.fromCharCodes(value.runes.take(maxRunes));
  final sanitized = prefix.replaceAll(_displayControl, ' ').trim();
  return sanitized.isEmpty ? null : sanitized;
}

String? _priceLabel(Object? value) {
  final text = _boundedText(value, _maxPriceLength);
  if (text == null) return null;
  if (text == 'free' || _numericPrice.hasMatch(text)) return text;
  return null;
}

const _maxProviderRowsScanned = 256;
const _maxModelRowsScanned = 1024;
const _maxIdentifierLength = 256;
const _maxProviderNameLength = 160;
const _maxWarningLength = 512;
const _maxAuthTypeLength = 64;
const _maxEnvironmentNameLength = 128;
const _maxPriceLength = 32;

final _identifierWhitespace = RegExp(r'\s', unicode: true);
final _identifierControl = RegExp(r'[\u0000-\u001f\u007f]');
final _displayControl = RegExp(r'[\u0000-\u001f\u007f]+');
final _environmentName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _numericPrice = RegExp(r'^\$?[0-9]+(?:\.[0-9]+)?$');
const _commandDelimiterCodeUnits = <int>{
  0x22, // "
  0x27, // '
  0x28, // (
  0x29, // )
  0x24, // $
  0x3b, // ;
  0x3c, // <
  0x3e, // >
  0x5c, // backslash
  0x60, // backtick
  0x7b, // {
  0x7c, // |
  0x7d, // }
  0x26, // &
};
