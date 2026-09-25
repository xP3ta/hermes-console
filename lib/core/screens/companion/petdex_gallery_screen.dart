import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../companion/data/companion_import_service.dart';
import '../../companion/data/petdex_remote_service.dart';
import '../../companion/state/companion_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_notice.dart';
import '../../widgets/hermes_premium_ui.dart';
import '../../widgets/hermes_ui.dart';

/// Galería remota de Petdex (Petdex remoto, contrato `petdex-v1.json`).
///
/// Lista **ligera** (nombre + autor) de las mascotas del manifest; la preview
/// del spritesheet y la descarga del ZIP ocurren **bajo demanda** al abrir el
/// detalle, para no bajar megas por cada fila. La instalación reutiliza el
/// pipeline validado de importación local ([CompanionController.importFromZipBytes]),
/// que infiere la geometría 192×208, valida y escribe de forma atómica.
class PetdexGalleryScreen extends StatefulWidget {
  final CompanionController controller;

  /// Inyectable en tests; en producción usa el cliente HTTP por defecto.
  final PetdexRemoteService? service;

  const PetdexGalleryScreen({
    required this.controller,
    this.service,
    super.key,
  });

  @override
  State<PetdexGalleryScreen> createState() => _PetdexGalleryScreenState();
}

class _PetdexGalleryScreenState extends State<PetdexGalleryScreen> {
  late final PetdexRemoteService _service =
      widget.service ?? PetdexRemoteService();
  late Future<List<PetdexRemotePet>> _future;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// Filtro por categoría del manifest (null = todas). El orden por defecto es
  /// el del manifest (Petdex lo entrega tipo "destacadas"/recientes).
  String? _kind;

  /// false = orden del manifest ("Destacadas"); true = alfabético A–Z.
  bool _alphabetical = false;
  final Set<String> _installing = {};

  /// Último fallo de instalación por slug, para mostrarlo DENTRO del sheet
  /// (el snackbar queda tapado por el modal) (spec 028 A-030).
  final Map<String, String> _installError = {};

  /// Revisión de estado de instalación: los sheets de detalle son rutas
  /// modales que NO se reconstruyen con los setState del screen, así que
  /// escuchan este notifier para reflejar el estado en vivo (spec 028 A-030).
  final ValueNotifier<int> _installRev = ValueNotifier(0);

  /// Categorías mostrables (valor del manifest; el label se localiza en render).
  static const List<String?> _kindFilters = [
    null,
    'character',
    'creature',
    'object',
  ];

  /// Label visible (localizado) de cada categoría del manifest.
  String _kindLabel(BuildContext context, String? kind) {
    switch (kind) {
      case 'character':
        return Strings.of(context).petdexFilterCharacters;
      case 'creature':
        return Strings.of(context).petdexFilterCreatures;
      case 'object':
        return Strings.of(context).petdexFilterObjects;
      default:
        return Strings.of(context).petdexFilterFeatured;
    }
  }

  @override
  void initState() {
    super.initState();
    _future = _service.fetchManifest();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _installRev.dispose();
    // Solo cerramos el cliente si lo creamos nosotros (no el inyectado).
    if (widget.service == null) _service.dispose();
    super.dispose();
  }

  void _reload() => setState(() => _future = _service.fetchManifest());

  List<PetdexRemotePet> _filter(List<PetdexRemotePet> all) {
    final q = _query.trim().toLowerCase();
    final kind = _kind;
    final out = all.where((p) {
      if (kind != null && p.kind != kind) return false;
      if (q.isEmpty) return true;
      return p.displayName.toLowerCase().contains(q) ||
          p.slug.toLowerCase().contains(q) ||
          p.author.toLowerCase().contains(q);
    }).toList();
    if (_alphabetical) {
      out.sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    }
    return out;
  }

  Future<void> _install(PetdexRemotePet pet, BuildContext sheetCtx) async {
    // Guarda de reentrada: taps repetidos no lanzan descargas+importaciones
    // concurrentes del mismo ZIP (spec 028 A-030).
    if (_installing.contains(pet.slug)) return;
    final messenger = HermesNotice.maybeOf(context);
    final str = Strings.of(context);
    _installError.remove(pet.slug);
    setState(() => _installing.add(pet.slug));
    _installRev.value++;
    try {
      final bytes = await _service.downloadPetZip(pet);
      final imported = await widget.controller.importFromZipBytes(
        bytes,
        authorOverride: pet.author,
      );
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text(str.petdexInstalled(imported.name))),
        kind: HermesNoticeKind.success,
      );
      // Cerrar SOLO el sheet, y solo si sigue abierto y es la ruta superior:
      // un pop a ciegas tras el await podía sacar al usuario de la galería
      // entera si ya había cerrado el sheet a mano (spec 028 A-030).
      if (sheetCtx.mounted) {
        final route = ModalRoute.of(sheetCtx);
        if (route != null && route.isCurrent) Navigator.of(sheetCtx).pop();
      }
    } on CompanionImportException catch (e) {
      _installError[pet.slug] = str.petdexInstallFailed(e.message);
      messenger?.showSnackBar(
        SnackBar(content: Text(str.petdexInstallFailed(e.message))),
        kind: HermesNoticeKind.error,
      );
    } on PetdexRemoteException catch (e) {
      _installError[pet.slug] = str.petdexDownloadFailed(e.message);
      messenger?.showSnackBar(
        SnackBar(content: Text(str.petdexDownloadFailed(e.message))),
        kind: HermesNoticeKind.error,
      );
    } catch (e) {
      debugPrint(
        '[petdex-gallery] excepción silenciada (se avisa al usuario y se sigue): $e',
      );
      _installError[pet.slug] = str.petdexInstallFailedGeneric;
      messenger?.showSnackBar(
        SnackBar(content: Text(str.petdexInstallFailedGeneric)),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) {
        setState(() => _installing.remove(pet.slug));
        _installRev.value++;
      }
    }
  }

  void _openDetail(PetdexRemotePet pet) {
    // Un fallo de una apertura anterior ya no es contexto vigente.
    if (!_installing.contains(pet.slug)) _installError.remove(pet.slug);
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('petdex-detail-surface'),
      maxWidth: 560,
      maxHeightFactor: 0.88,
      builder: (sheetCtx) {
        // Estado EN VIVO: el sheet se reconstruye con cada cambio de
        // instalación en vez de congelar el snapshot de apertura (A-030).
        return ValueListenableBuilder<int>(
          valueListenable: _installRev,
          builder: (_, _, _) => _PetdexDetailSheet(
            pet: pet,
            installing: _installing.contains(pet.slug),
            error: _installError[pet.slug],
            onInstall: () => _install(pet, sheetCtx),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(Strings.of(context).petdexGalleryTitle),
        actions: [
          IconButton(
            tooltip: _alphabetical
                ? Strings.of(context).petdexSortAlpha
                : Strings.of(context).petdexSortFeatured,
            icon: Icon(
              _alphabetical ? Icons.sort_by_alpha : Icons.auto_awesome,
            ),
            onPressed: () => setState(() => _alphabetical = !_alphabetical),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            // Campo relleno del design system (mismo estilo que HermesField),
            // en vez del outline genérico de Material.
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(color: colors.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: Strings.of(context).petdexSearchHint,
                hintStyle: TextStyle(
                  color: colors.textDisabled,
                  fontSize: 13.5,
                ),
                prefixIcon: Icon(
                  Icons.search,
                  size: 20,
                  color: colors.textSecondary,
                ),
                isDense: true,
                filled: true,
                fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HermesRadii.field),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HermesRadii.field),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HermesRadii.field),
                  borderSide: BorderSide(
                    color: colors.accent.withValues(alpha: 0.6),
                    width: 1.2,
                  ),
                ),
              ),
            ),
          ),
          // Filtro por categoría (el manifest no expone popularidad, así que
          // "Destacadas" usa el orden que entrega Petdex).
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _kindFilters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final kind = _kindFilters[i];
                final selected = _kind == kind;
                return ChoiceChip(
                  label: Text(_kindLabel(context, kind)),
                  selected: selected,
                  onSelected: (_) => setState(() => _kind = kind),
                );
              },
            ),
          ),
          Expanded(
            child: FutureBuilder<List<PetdexRemotePet>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError || !snap.hasData) {
                  return _ErrorState(colors: colors, onRetry: _reload);
                }
                final pets = _filter(snap.data!);
                if (pets.isEmpty) {
                  final hasFilters = _query.trim().isNotEmpty || _kind != null;
                  // Estado vacío estándar (DESIGN_DIRECTION §13): icono 48
                  // textDisabled + línea mono 13 textSecondary + acción.
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 48,
                          color: colors.textDisabled,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          Strings.of(context).petdexNoResults,
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (hasFilters) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {
                                _query = '';
                                _kind = null;
                              });
                            },
                            child: Text(Strings.of(context).petdexClearFilters),
                          ),
                        ],
                      ],
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
                      child: Text(
                        Strings.of(context).petdexResultCount(pets.length),
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: pets.length,
                        itemBuilder: (context, i) {
                          final pet = pets[i];
                          final busy = _installing.contains(pet.slug);
                          return ListTile(
                            leading: _PetdexThumb(
                              url: pet.spritesheetUrl.toString(),
                              colors: colors,
                            ),
                            title: Text(
                              pet.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              Strings.of(context).petdexByAuthor(pet.author),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    Icons.download_rounded,
                                    color: colors.accent,
                                    size: 20,
                                  ),
                            onTap: busy ? null : () => _openDetail(pet),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Miniatura del **primer frame** (192×208) del spritesheet, recortado del
/// sheet completo. Carga perezosa (solo filas visibles) y cacheada por Flutter;
/// si falla, muestra un icono en vez de romper la fila.
class _PetdexThumb extends StatelessWidget {
  final String url;
  final HermesThemeColors colors;
  const _PetdexThumb({required this.url, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 50,
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: FittedBox(
        fit: BoxFit.contain,
        child: ClipRect(
          child: SizedBox(
            // Un frame del grid estándar de Petdex/Fase A.
            width: 192,
            height: 208,
            child: Image.network(
              url,
              fit: BoxFit.none,
              alignment: Alignment.topLeft,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
              errorBuilder: (context, error, stack) => Center(
                child: Icon(Icons.pets, color: colors.textSecondary, size: 96),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final HermesThemeColors colors;
  final VoidCallback onRetry;
  const _ErrorState({required this.colors, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, color: colors.textSecondary, size: 36),
          const SizedBox(height: 12),
          Text(
            Strings.of(context).petdexLoadError,
            style: TextStyle(color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRetry,
            child: Text(Strings.of(context).commonRetry),
          ),
        ],
      ),
    );
  }
}

class _PetdexDetailSheet extends StatelessWidget {
  final PetdexRemotePet pet;
  final bool installing;

  /// Causa del último fallo de instalación, visible dentro del sheet
  /// (el snackbar del screen queda tapado por el modal) (spec 028 A-030).
  final String? error;
  final VoidCallback onInstall;

  const _PetdexDetailSheet({
    required this.pet,
    required this.installing,
    required this.onInstall,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pet.displayName,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            Strings.of(context).petdexByAuthor(pet.author),
            style: TextStyle(color: colors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          // Preview del spritesheet bajo demanda (una sola imagen). Si falla,
          // muestra un placeholder en vez de romper.
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180, maxWidth: 220),
              child: Image.network(
                pet.spritesheetUrl.toString(),
                fit: BoxFit.contain,
                // Preview acotado al cuadro de 220 dp de ancho (×3 de DPR): el
                // spritesheet remoto se decodifica reducido en memoria. Solo un
                // lado para conservar la proporción del sheet.
                cacheWidth: 660,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  );
                },
                errorBuilder: (context, error, stack) => SizedBox(
                  height: 120,
                  child: Center(
                    child: Icon(
                      Icons.image_not_supported_outlined,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: installing ? null : onInstall,
            icon: installing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded),
            label: Text(
              installing
                  ? Strings.of(context).petdexInstalling
                  : Strings.of(context).petdexInstallPet,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              style: TextStyle(color: colors.error, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            Strings.of(context).petdexDetailNote(pet.author),
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
