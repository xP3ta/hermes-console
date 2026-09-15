/// Modelo de configuración del dock flotante (v2).
///
/// Cada perfil ("bots" y "general") guarda su propia lista de elementos
/// (orden, visibilidad, destacado) y su propio [DockStyle] (bordes,
/// transparencia, profundidad): no se comparte estilo entre perfiles, según
/// corrección explícita del usuario sobre el primer draft.
library;

/// Forma de los bordes del dock y de sus elementos internos.
enum DockBorderShape {
  square,
  soft,
  rounded;

  /// Radio del contenedor exterior del dock, en dp.
  double get outerRadius => switch (this) {
    DockBorderShape.square => 4,
    DockBorderShape.soft => 12,
    DockBorderShape.rounded => 24,
  };

  /// Radio de cada celda/elemento interior: sigue al radio exterior con un
  /// margen fijo de 4dp, sin bajar de 0.
  double get innerRadius => (outerRadius - 4).clamp(0, outerRadius);

  static DockBorderShape parse(Object? value) => values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => DockBorderShape.soft,
  );
}

/// Profundidad visual del dock (sombra/superficie).
enum DockDepth {
  flat,
  elevated,
  floating;

  static DockDepth parse(Object? value) => values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => DockDepth.elevated,
  );
}

/// Identificadores estables de cada elemento que puede aparecer en un dock.
///
/// "back" no vive aquí: es contextual, se calcula en tiempo de navegación y
/// nunca se persiste como parte del catálogo de un perfil.
enum DockItemId {
  bots,
  work,
  create,
  home,
  settings,
  // Accesos directos opcionales: existen en el catálogo de AMBOS perfiles
  // pero ocultos por defecto (ver [defaultBots]/[defaultGeneral]); el
  // usuario los activa a mano desde Ajustes › Dock si los quiere en la
  // barra.
  cron,
  tasks,
  sessions,
  tools;

  static DockItemId? parse(Object? value) => values
      .cast<DockItemId?>()
      .firstWhere((candidate) => candidate?.name == value, orElse: () => null);
}

/// Estilo visual de un perfil de dock: bordes, transparencia y profundidad.
class DockStyle {
  static const schemaVersion = 1;

  final DockBorderShape borderShape;

  /// 0.0 = opaco, 1.0 = máxima transparencia (con desenfoque de fondo).
  final double transparency;
  final DockDepth depth;

  const DockStyle({
    this.borderShape = DockBorderShape.soft,
    this.transparency = 0.0,
    this.depth = DockDepth.elevated,
  });

  DockStyle copyWith({
    DockBorderShape? borderShape,
    double? transparency,
    DockDepth? depth,
  }) => DockStyle(
    borderShape: borderShape ?? this.borderShape,
    transparency: transparency ?? this.transparency,
    depth: depth ?? this.depth,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'border_shape': borderShape.name,
    'transparency': transparency,
    'depth': depth.name,
  };

  factory DockStyle.fromJson(Map<String, Object?>? json) {
    if (json == null || json['schema_version'] != schemaVersion) {
      return const DockStyle();
    }
    final rawTransparency = json['transparency'];
    final transparency = rawTransparency is num
        ? rawTransparency.toDouble().clamp(0.0, 1.0)
        : 0.0;
    return DockStyle(
      borderShape: DockBorderShape.parse(json['border_shape']),
      transparency: transparency,
      depth: DockDepth.parse(json['depth']),
    );
  }
}

/// Un elemento del catálogo de un perfil: qué es y si está visible.
///
/// El orden dentro de la lista del perfil ES el orden de aparición en el
/// dock; no hace falta un índice adicional.
class DockItemConfig {
  final DockItemId id;
  final bool visible;

  const DockItemConfig({required this.id, this.visible = true});

  DockItemConfig copyWith({bool? visible}) =>
      DockItemConfig(id: id, visible: visible ?? this.visible);

  Map<String, Object?> toJson() => {'id': id.name, 'visible': visible};

  static DockItemConfig? fromJson(Map<String, Object?> json) {
    final id = DockItemId.parse(json['id']);
    if (id == null) return null;
    return DockItemConfig(id: id, visible: json['visible'] != false);
  }
}

/// Configuración completa de un perfil de dock ("bots" o "general").
class DockProfileConfig {
  static const schemaVersion = 1;

  final List<DockItemConfig> items;

  /// Elemento destacado: nunca se retira aunque aparezca "Atrás" y no cabría
  /// el resto de elementos visibles.
  final DockItemId pinnedItemId;
  final bool showBackOnSubscreens;
  final DockStyle style;

  const DockProfileConfig({
    required this.items,
    required this.pinnedItemId,
    this.showBackOnSubscreens = true,
    this.style = const DockStyle(),
  });

  List<DockItemId> get visibleItemIds => [
    for (final item in items)
      if (item.visible) item.id,
  ];

  DockProfileConfig copyWith({
    List<DockItemConfig>? items,
    DockItemId? pinnedItemId,
    bool? showBackOnSubscreens,
    DockStyle? style,
  }) => DockProfileConfig(
    items: items ?? this.items,
    pinnedItemId: pinnedItemId ?? this.pinnedItemId,
    showBackOnSubscreens: showBackOnSubscreens ?? this.showBackOnSubscreens,
    style: style ?? this.style,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'items': [for (final item in items) item.toJson()],
    'pinned_item_id': pinnedItemId.name,
    'show_back_on_subscreens': showBackOnSubscreens,
    'style': style.toJson(),
  };

  factory DockProfileConfig.fromJson(
    Map<String, Object?>? json,
    DockProfileConfig fallback,
  ) {
    if (json == null || json['schema_version'] != schemaVersion) {
      return fallback;
    }
    final rawItems = json['items'];
    final parsedItems = <DockItemConfig>[];
    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map) {
          final asStringMap = <String, Object?>{
            for (final e in entry.entries)
              if (e.key is String) e.key as String: e.value,
          };
          final item = DockItemConfig.fromJson(asStringMap);
          if (item != null) parsedItems.add(item);
        }
      }
    }
    // Cualquier id del catálogo por defecto que falte en lo persistido (por
    // ejemplo, tras una actualización que añade un elemento nuevo) se agrega
    // al final, oculto, para no perder elementos futuros silenciosamente ni
    // reordenar lo que el usuario ya configuró.
    final knownIds = parsedItems.map((item) => item.id).toSet();
    for (final defaultItem in fallback.items) {
      if (!knownIds.contains(defaultItem.id)) {
        parsedItems.add(defaultItem.copyWith(visible: false));
      }
    }
    if (parsedItems.isEmpty) return fallback;
    final pinnedItemId =
        DockItemId.parse(json['pinned_item_id']) ?? fallback.pinnedItemId;
    return DockProfileConfig(
      items: parsedItems,
      pinnedItemId: pinnedItemId,
      showBackOnSubscreens: json['show_back_on_subscreens'] != false,
      style: DockStyle.fromJson(
        (json['style'] as Map?)?.cast<String, Object?>(),
      ),
    );
  }

  static DockProfileConfig defaultBots() => const DockProfileConfig(
    items: [
      // "Inicio" va primero: sin él, el perfil Bots no tenía forma de volver
      // al dashboard general desde el dock (confirmado en dispositivo real).
      DockItemConfig(id: DockItemId.home),
      DockItemConfig(id: DockItemId.bots),
      DockItemConfig(id: DockItemId.create),
      DockItemConfig(id: DockItemId.work),
      // Accesos directos opcionales: en el catálogo, ocultos de fábrica.
      DockItemConfig(id: DockItemId.cron, visible: false),
      DockItemConfig(id: DockItemId.tasks, visible: false),
      DockItemConfig(id: DockItemId.sessions, visible: false),
      DockItemConfig(id: DockItemId.tools, visible: false),
    ],
    pinnedItemId: DockItemId.create,
  );

  static DockProfileConfig defaultGeneral() => const DockProfileConfig(
    items: [
      DockItemConfig(id: DockItemId.home),
      DockItemConfig(id: DockItemId.create),
      DockItemConfig(id: DockItemId.bots),
      DockItemConfig(id: DockItemId.settings),
      DockItemConfig(id: DockItemId.work, visible: false),
      // Accesos directos opcionales: en el catálogo, ocultos de fábrica.
      DockItemConfig(id: DockItemId.cron, visible: false),
      DockItemConfig(id: DockItemId.tasks, visible: false),
      DockItemConfig(id: DockItemId.sessions, visible: false),
      DockItemConfig(id: DockItemId.tools, visible: false),
    ],
    pinnedItemId: DockItemId.create,
  );
}

/// Raíz persistida: un [DockProfileConfig] por perfil.
class DockPreferences {
  static const schemaVersion = 1;

  final DockProfileConfig bots;
  final DockProfileConfig general;

  const DockPreferences({required this.bots, required this.general});

  factory DockPreferences.defaults() => DockPreferences(
    bots: DockProfileConfig.defaultBots(),
    general: DockProfileConfig.defaultGeneral(),
  );

  DockPreferences copyWith({
    DockProfileConfig? bots,
    DockProfileConfig? general,
  }) => DockPreferences(
    bots: bots ?? this.bots,
    general: general ?? this.general,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'bots': bots.toJson(),
    'general': general.toJson(),
  };

  factory DockPreferences.fromJson(Map<String, Object?>? json) {
    final defaults = DockPreferences.defaults();
    if (json == null || json['schema_version'] != schemaVersion) {
      return defaults;
    }
    return DockPreferences(
      bots: DockProfileConfig.fromJson(
        (json['bots'] as Map?)?.cast<String, Object?>(),
        defaults.bots,
      ),
      general: DockProfileConfig.fromJson(
        (json['general'] as Map?)?.cast<String, Object?>(),
        defaults.general,
      ),
    );
  }
}

/// Calcula qué renderizar en cada hueco del dock: los elementos visibles del
/// perfil, en orden, con "Atrás" (representado como `null`) insertado en el
/// primer hueco cuando [showBack] es true.
///
/// El dock nunca cambia de tamaño: si hace falta sitio para "Atrás" se
/// retira el último elemento visible que no sea [pinnedItemId] (el
/// destacado nunca se retira). Al volver al nivel superior basta con volver
/// a llamar con `showBack: false` para recuperar la lista completa.
List<DockItemId?> resolveDockSlots({
  required List<DockItemId> visibleItems,
  required DockItemId pinnedItemId,
  required bool showBack,
}) {
  if (!showBack || visibleItems.isEmpty) return visibleItems;
  final result = List<DockItemId>.from(visibleItems);
  final removeIndex = result.lastIndexWhere((id) => id != pinnedItemId);
  result.removeAt(removeIndex == -1 ? result.length - 1 : removeIndex);
  return <DockItemId?>[null, ...result];
}
