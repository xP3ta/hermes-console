import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/profile_pet.dart';
import '../models/companion.dart';
import 'companion_import_service.dart';
import 'companion_manifest_parser.dart';

/// Descubre y carga las mascotas "Companion" empaquetadas en
/// `assets/companions/<slug>/` y, opcionalmente, las **importadas** por el
/// usuario en un directorio del sandbox de la app. Solo lee assets/ficheros
/// locales; no hace red.
class CompanionRepository {
  static const String _root = 'assets/companions';

  final AssetBundle _bundle;

  /// Resuelve (de forma perezosa) el directorio donde viven las mascotas
  /// importadas. `null` → no hay importación (comportamiento de Fase A: solo
  /// base). Inyectado en producción con `path_provider`; en tests se pasa un
  /// directorio temporal o se omite.
  final Future<Directory> Function()? importedRootProvider;
  final CompanionImportService profilePetImportService;

  /// Serializa la promoción del pequeño índice durable. La materialización
  /// puede ocurrir en paralelo, pero dos respuestas `pet.changed` no deben
  /// pisarse al publicar qué revisión está lista para restaurar.
  Future<void> _profilePetIndexGate = Future<void>.value();

  CompanionRepository({
    AssetBundle? bundle,
    this.importedRootProvider,
    this.profilePetImportService = const CompanionImportService(),
  }) : _bundle = bundle ?? rootBundle;

  static final RegExp _remoteSlugPattern = RegExp(r'^[a-z0-9-]{1,64}$');

  /// Última revisión remota cacheada y todavía legible para este scope/slug.
  Future<String?> cachedProfilePetRevision({
    required String connectionId,
    required String profileId,
    required String slug,
  }) async {
    if (!_validRemoteSlug(slug)) return null;
    final scopeRoot = await _profilePetScopeRoot(
      connectionId: connectionId,
      profileId: profileId,
      create: false,
    );
    if (scopeRoot == null) return null;
    final index = await _readProfilePetIndex(scopeRoot);
    final revision = index[slug];
    if (!_validRevision(revision)) return null;
    final cached = await loadCachedProfilePet(
      connectionId: connectionId,
      profileId: profileId,
      slug: slug,
      revision: revision!,
    );
    return cached == null ? null : revision;
  }

  /// Carga una revisión exacta sin escanear ni mezclar mascotas de otro perfil.
  Future<Companion?> loadCachedProfilePet({
    required String connectionId,
    required String profileId,
    required String slug,
    required String revision,
  }) async {
    if (!_validRemoteSlug(slug) || !_validRevision(revision)) return null;
    final scopeRoot = await _profilePetScopeRoot(
      connectionId: connectionId,
      profileId: profileId,
      create: false,
    );
    if (scopeRoot == null) return null;
    final assetRoot = Directory(
      '${scopeRoot.path}/${_profilePetAssetKey(connectionId, profileId, slug, revision)}',
    );
    final petDir = Directory('${assetRoot.path}/$slug');
    final manifest = File('${petDir.path}/pet.json');
    if (!await manifest.exists()) return null;
    try {
      final jsonString = await manifest.readAsString();
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map || decoded['remoteRevision'] != revision) return null;
      final companion = CompanionManifestParser.parse(
        jsonString,
        assetDir: petDir.path,
        slug: slug,
        origin: CompanionOrigin.remote,
      );
      if (!companion.isValid || !companion.isRemote) return null;
      return await profilePetImportService.validateMaterializedProfilePet(
            companion,
          )
          ? companion
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Reutiliza caché válida o materializa una revisión nueva. Nunca activa ni
  /// persiste la selección; esa transacción pertenece al controller tras
  /// revalidar epoch/generación.
  Future<Companion> materializeProfilePet(
    ProfilePetInfo info, {
    required String connectionId,
    required String profileId,
  }) async {
    if (!_validRemoteSlug(info.slug) ||
        !_validRevision(info.spritesheetRevision)) {
      throw CompanionImportException('invalid remote identity');
    }
    final cached = await loadCachedProfilePet(
      connectionId: connectionId,
      profileId: profileId,
      slug: info.slug,
      revision: info.spritesheetRevision,
    );
    if (cached != null) return cached;
    if (info.usesCachedSpritesheet || !info.hasSpritesheetPayload) {
      throw CompanionImportException(
        'the gateway omitted an atlas that is not cached',
      );
    }

    final scopeRoot = await _profilePetScopeRoot(
      connectionId: connectionId,
      profileId: profileId,
      create: true,
    );
    if (scopeRoot == null) {
      throw CompanionImportException('remote pet cache unavailable');
    }
    final assetRoot = Directory(
      '${scopeRoot.path}/${_profilePetAssetKey(connectionId, profileId, info.slug, info.spritesheetRevision)}',
    );
    final materialized = await profilePetImportService.materializeProfilePet(
      info,
      storageRoot: assetRoot,
    );
    if (!materialized.isValid || !materialized.isRemote) {
      throw CompanionImportException(
        'the materialized remote pet is not valid',
      );
    }
    return materialized;
  }

  /// Publica una revisión solo después de que el controller haya revalidado
  /// scope/epoch/generación. También repara un índice ausente si el directorio
  /// revisionado sobrevivió a un cierre entre materialización y promoción.
  Future<void> promoteProfilePetRevision({
    required String connectionId,
    required String profileId,
    required String slug,
    required String revision,
  }) async {
    final previous = _profilePetIndexGate;
    final gate = Completer<void>();
    _profilePetIndexGate = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // Un fallo anterior no bloquea permanentemente futuras promociones.
      }
      final cached = await loadCachedProfilePet(
        connectionId: connectionId,
        profileId: profileId,
        slug: slug,
        revision: revision,
      );
      if (cached == null) {
        throw CompanionImportException(
          'the remote revision failed pre-promotion validation',
        );
      }
      final scopeRoot = await _profilePetScopeRoot(
        connectionId: connectionId,
        profileId: profileId,
        create: true,
      );
      if (scopeRoot == null) {
        throw CompanionImportException(
          'remote pet cache unavailable',
        );
      }
      final index = await _readProfilePetIndex(scopeRoot);
      index[slug] = revision;
      await _writeProfilePetIndex(scopeRoot, index);
    } finally {
      gate.complete();
    }
  }

  Future<Directory?> _profilePetScopeRoot({
    required String connectionId,
    required String profileId,
    required bool create,
  }) async {
    if (connectionId.trim().isEmpty) return null;
    final root = await importedRoot();
    if (root == null) return null;
    final scope = Directory(
      '${root.path}/.profile-pets/${_hash([connectionId, profileId])}',
    );
    if (create && !await scope.exists()) await scope.create(recursive: true);
    return await scope.exists() ? scope : null;
  }

  Future<Map<String, String>> _readProfilePetIndex(Directory root) async {
    final file = File('${root.path}/index.json');
    if (!await file.exists()) return {};
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return {};
      return {
        for (final entry in raw.entries)
          if (_validRemoteSlug(entry.key.toString()) &&
              _validRevision(entry.value?.toString()))
            entry.key.toString(): entry.value.toString(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeProfilePetIndex(
    Directory root,
    Map<String, String> index,
  ) async {
    final target = File('${root.path}/index.json');
    final tmp = File(
      '${root.path}/.index-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await tmp.writeAsString(jsonEncode(index), flush: true);
      await tmp.rename(target.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  String _profilePetAssetKey(
    String connectionId,
    String profileId,
    String slug,
    String revision,
  ) => _hash([connectionId, profileId, slug, revision]);

  String _hash(List<String> parts) =>
      sha256.convert(utf8.encode(jsonEncode(parts))).toString();

  bool _validRemoteSlug(String slug) => _remoteSlugPattern.hasMatch(slug);

  bool _validRevision(String? revision) =>
      revision != null &&
      revision.isNotEmpty &&
      revision.length <= 256 &&
      !revision.contains(RegExp(r'[\x00-\x1f\x7f]'));

  /// Directorio de mascotas importadas ya resuelto (creándolo si hace falta), o
  /// `null` si no hay importación configurada.
  Future<Directory?> importedRoot() async {
    final provider = importedRootProvider;
    if (provider == null) return null;
    final dir = await provider();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Lista los slugs disponibles (carpetas con `pet.json`), ordenados.
  Future<List<String>> availableSlugs() async {
    final manifest = await AssetManifest.loadFromAssetBundle(_bundle);
    final slugs = <String>{};
    for (final asset in manifest.listAssets()) {
      if (asset.startsWith('$_root/') && asset.endsWith('/pet.json')) {
        // assets/companions/<slug>/pet.json
        final parts = asset.split('/');
        if (parts.length >= 4) slugs.add(parts[2]);
      }
    }
    final list = slugs.toList()..sort();
    return list;
  }

  /// Carga una mascota por slug. Devuelve `null` si falta o es inválida, para
  /// permitir el fallback a `HermesSparkMascot` (FR-012) sin crashear.
  Future<Companion?> load(String slug) async {
    final dir = '$_root/$slug';
    try {
      final jsonString = await _bundle.loadString('$dir/pet.json');
      return CompanionManifestParser.parse(
        jsonString,
        assetDir: dir,
        slug: slug,
      );
    } catch (e) {
      debugPrint(
        '[companion-repo] excepción silenciada (se devuelve null): $e',
      );
      return null;
    }
  }

  /// Carga todas las mascotas válidas disponibles: las base (assets) y, si hay
  /// directorio de importación, las importadas por el usuario.
  Future<List<Companion>> loadAll() async {
    final slugs = await availableSlugs();
    final companions = <Companion>[];
    for (final slug in slugs) {
      final companion = await load(slug);
      if (companion != null) companions.add(companion);
    }
    companions.addAll(await _loadImported());
    return companions;
  }

  /// Carga las mascotas importadas escaneando `<importedRoot>/<slug>/pet.json`.
  /// Tolerante a fallos: una mascota importada inválida se ignora (no rompe la
  /// carga de las demás).
  Future<List<Companion>> _loadImported() async {
    final root = await importedRoot();
    if (root == null) return const [];
    final result = <Companion>[];
    final List<FileSystemEntity> entries;
    try {
      entries = await root.list().toList();
    } catch (e) {
      debugPrint(
        '[companion-repo] excepción silenciada (se devuelve lista vacía): $e',
      );
      return const [];
    }
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final slug = entry.path.split(Platform.pathSeparator).last;
      // Ignora el dir temporal de una importación a medio camino.
      if (slug.startsWith('.import-')) continue;
      final manifest = File('${entry.path}/pet.json');
      if (!await manifest.exists()) continue;
      try {
        final jsonString = await manifest.readAsString();
        final companion = CompanionManifestParser.parse(
          jsonString,
          assetDir: entry.path,
          slug: slug,
          origin: CompanionOrigin.imported,
        );
        if (companion.isValid) result.add(companion);
      } catch (_) {
        // pet.json corrupto/incoherente → se omite esa mascota.
      }
    }
    return result;
  }
}
