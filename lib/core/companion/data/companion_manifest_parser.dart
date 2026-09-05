import 'dart:convert';

import '../models/companion.dart';
import '../models/companion_animation_state.dart';

/// Error de validación de un `pet.json`.
class CompanionManifestException implements Exception {
  final String message;
  CompanionManifestException(this.message);

  @override
  String toString() => 'CompanionManifestException: $message';
}

/// Parsea y valida un `pet.json` (contenido) a un [Companion].
///
/// Contrato: docs/PETDEX_CONTRACT.md.
/// Lanza [CompanionManifestException] ante cualquier inconsistencia; quien
/// llama (el repositorio) hace fallback a `HermesSparkMascot` (FR-012).
class CompanionManifestParser {
  static final RegExp _slugPattern = RegExp(r'^[a-z0-9-]+$');

  /// [assetDir] es el directorio del asset (p. ej. `assets/companions/boba`).
  /// [slug] es el nombre de la carpeta, que debe coincidir con el manifest.
  static Companion parse(
    String jsonString, {
    required String assetDir,
    required String slug,
    CompanionOrigin origin = CompanionOrigin.base,
  }) {
    final Map<String, dynamic> map;
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        throw CompanionManifestException('the root is not a JSON object');
      }
      map = decoded;
    } on FormatException catch (e) {
      throw CompanionManifestException('invalid JSON: ${e.message}');
    }

    final manifestSlug = (map['slug'] as String?)?.trim() ?? '';
    if (manifestSlug.isEmpty) {
      throw CompanionManifestException('falta "slug"');
    }
    if (!_slugPattern.hasMatch(manifestSlug)) {
      throw CompanionManifestException('slug con caracteres no permitidos');
    }
    if (manifestSlug != slug) {
      throw CompanionManifestException(
          'slug "$manifestSlug" does not match folder "$slug"');
    }

    final grid = map['grid'];
    if (grid is! Map<String, dynamic>) {
      throw CompanionManifestException('falta "grid"');
    }
    final frameWidth = _int(grid['frameWidth'], 'grid.frameWidth');
    final frameHeight = _int(grid['frameHeight'], 'grid.frameHeight');
    final cols = _int(grid['cols'], 'grid.cols');
    final rows = _int(grid['rows'], 'grid.rows');
    if (frameWidth <= 0 || frameHeight <= 0 || cols <= 0 || rows <= 0) {
      throw CompanionManifestException('invalid "grid" dimensions');
    }

    final fps = _num(map['fps'], 'fps').toDouble();
    if (fps <= 0) {
      throw CompanionManifestException('"fps" debe ser > 0');
    }

    final spritesheet = (map['spritesheet'] as String?)?.trim();
    if (spritesheet == null || spritesheet.isEmpty) {
      throw CompanionManifestException('falta "spritesheet"');
    }

    final statesRaw = map['states'];
    if (statesRaw is! Map<String, dynamic>) {
      throw CompanionManifestException('falta "states"');
    }
    final states = <CompanionAnimationState, RowSpec>{};
    statesRaw.forEach((key, value) {
      final state = companionStateFromId(key);
      if (state == null) return; // ignora estados desconocidos (tolerante)
      if (value is! Map<String, dynamic>) {
        throw CompanionManifestException('state "$key" is not an object');
      }
      final row = _int(value['row'], 'states.$key.row');
      final frameCount = _int(value['frameCount'], 'states.$key.frameCount');
      final loop = value['loop'] as bool? ?? state.loopsByDefault;
      if (row < 0 || row >= rows) {
        throw CompanionManifestException('estado "$key": "row" fuera de rango');
      }
      if (frameCount <= 0 || frameCount > cols) {
        throw CompanionManifestException(
            'estado "$key": "frameCount" fuera de rango');
      }
      states[state] = RowSpec(row: row, frameCount: frameCount, loop: loop);
    });

    if (!states.containsKey(CompanionAnimationState.idle)) {
      throw CompanionManifestException('"states" debe incluir "idle"');
    }

    // Filas de animación extra (opcional): animaciones sin estado nombrado.
    // Tolerante: una entrada inválida se ignora (no rompe la mascota).
    final extraRows = <RowSpec>[];
    final extraRaw = map['extraRows'];
    if (extraRaw is List) {
      for (final item in extraRaw) {
        if (item is! Map<String, dynamic>) continue;
        final row = item['row'];
        final frameCount = item['frameCount'];
        if (row is! int || frameCount is! int) continue;
        if (row < 0 || row >= rows || frameCount <= 0 || frameCount > cols) {
          continue;
        }
        final rawLabel =
            (item['name'] as String?)?.trim() ?? (item['label'] as String?)?.trim();
        extraRows.add(RowSpec(
          row: row,
          frameCount: frameCount,
          loop: item['loop'] as bool? ?? false,
          label: (rawLabel != null && rawLabel.isNotEmpty) ? rawLabel : null,
        ));
      }
    }

    final name = (map['name'] as String?)?.trim();
    // Un `pet.json` del sandbox puede declarar su origen (`generated` vs
    // `imported`); si lo hace, tiene prioridad sobre el [origin] por defecto.
    final effectiveOrigin =
        companionOriginFromId(map['origin'] as String?) ?? origin;
    return Companion(
      slug: manifestSlug,
      name: (name != null && name.isNotEmpty) ? name : manifestSlug,
      author: (map['author'] as String?)?.trim() ?? 'unknown',
      license: (map['license'] as String?)?.trim() ?? 'unknown',
      spritesheetAsset: '$assetDir/$spritesheet',
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      cols: cols,
      rows: rows,
      fps: fps,
      states: states,
      extraRows: extraRows,
      origin: effectiveOrigin,
    );
  }

  static int _int(dynamic value, String field) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw CompanionManifestException('"$field" debe ser un entero');
  }

  static num _num(dynamic value, String field) {
    if (value is num) return value;
    throw CompanionManifestException('"$field" must be numeric');
  }
}
