import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import '../data/companion_import_service.dart';
import '../models/companion.dart';
import 'hatch_provider.dart';
import 'prompt_safety.dart';
import 'package:flutter/foundation.dart';

/// Orquesta la incubación (Hatch) de una mascota **estática**:
/// prompt → moderación → proveedor → validación → materialización local.
///
/// La imagen generada se guarda **tal cual** como un único frame `idle`
/// (el `pet.json` declara el frame = dimensiones reales de la imagen); NO se
/// generan otros estados ni animación. La escritura es atómica y reutiliza
/// [CompanionImportService] (sin duplicar). Es offline salvo lo que haga el
/// propio proveedor.
class HatchService {
  final CompanionImportService importService;
  final PromptSafety safety;

  const HatchService({
    this.importService = const CompanionImportService(),
    this.safety = const PromptSafety(),
  });

  /// Genera y materializa una mascota `generated`. Devuelve la [Companion].
  ///
  /// - Lanza [PromptRejectedException] si la moderación rechaza el prompt.
  /// - Lanza [HatchException] si la generación/validación falla.
  /// - [protectedSlugs]: slugs de base (nunca se sobrescriben).
  /// - [existingSlugs]: slugs ya presentes (para no pisar otra mascota).
  Future<Companion> hatch({
    required HatchProvider provider,
    required String prompt,
    required Directory storageRoot,
    Set<String> protectedSlugs = const {},
    Set<String> existingSlugs = const {},
  }) async {
    final clean = safety.sanitize(prompt); // puede lanzar PromptRejectedException

    final HatchResult result = await provider.generate(HatchRequest(clean));

    final dims = await _decodeDims(result.imageBytes);
    if (dims == null) {
      throw HatchException('The generated image is not valid.');
    }
    final (w, h) = dims;
    if (w <= 0 || h <= 0) {
      throw HatchException('The generated image has invalid dimensions.');
    }

    final slug = _uniqueSlug(_slugFromPrompt(clean), protectedSlugs, existingSlugs);
    final manifest = <String, dynamic>{
      'slug': slug,
      'name': _nameFromPrompt(clean),
      'spritesheet': result.fileName,
      'grid': {'frameWidth': w, 'frameHeight': h, 'cols': 1, 'rows': 1},
      'fps': 1,
      'states': {
        'idle': {'row': 0, 'frameCount': 1, 'loop': true},
      },
      'author': result.author ?? 'Hatch',
      'license': 'user-generated',
      'origin': 'generated',
    };

    return importService.writePack(
      manifestJson: json.encode(manifest),
      spriteFileName: result.fileName,
      spriteBytes: result.imageBytes,
      storageRoot: storageRoot,
      origin: CompanionOrigin.generated,
      protectedSlugs: protectedSlugs,
    );
  }

  /// Decodifica el ancho/alto de la imagen vía `dart:ui` (sin re-encodear).
  Future<(int, int)?> _decodeDims(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      return (img.width, img.height);
    } catch (e) {
      debugPrint('[hatch] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  static String _slugFromPrompt(String prompt) {
    var s = prompt
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (s.length > 40) s = s.substring(0, 40).replaceAll(RegExp(r'-$'), '');
    return s.isEmpty ? 'mascota' : s;
  }

  static String _nameFromPrompt(String prompt) {
    final t = prompt.trim();
    final base = t.length > 28 ? '${t.substring(0, 28).trim()}…' : t;
    return base.isEmpty ? 'Mascota generada' : base;
  }

  static String _uniqueSlug(
      String base, Set<String> protectedSlugs, Set<String> existing) {
    final taken = {...protectedSlugs, ...existing};
    if (!taken.contains(base)) return base;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base-$i';
      if (!taken.contains(candidate)) return candidate;
    }
    return '$base-${DateTime.now().microsecondsSinceEpoch}';
  }
}
