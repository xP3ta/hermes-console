import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../../main.dart';
import '../../companion/companion_links.dart';
import '../../companion/data/companion_import_service.dart';
import '../../companion/models/companion.dart';
import '../../companion/models/companion_animation_state.dart';
import '../../companion/models/companion_display_settings.dart';
import '../../companion/models/companion_presence_level.dart';
import '../../companion/render/companion_preview.dart';
import '../../widgets/hermes_notice.dart';
import 'companion_playground_screen.dart';
import 'petdex_gallery_screen.dart';
import '../../companion/render/spritesheet_renderer.dart';
import '../../companion/state/companion_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_ui.dart';

/// Función de apertura de enlaces externos (inyectable para tests). Devuelve
/// `true` si el sistema aceptó abrir la URL.
typedef UrlLauncher = Future<bool> Function(Uri uri);

/// Selector de un ZIP de mascota (inyectable para tests). Devuelve los bytes del
/// fichero elegido, o `null` si el usuario canceló.
typedef ZipPicker = Future<Uint8List?> Function();

/// Pantalla propia "Mascotas" (Companion) — Fase B / US1 (MVP).
///
/// Espacio dedicado para ver las mascotas instaladas, previsualizar la
/// seleccionada en grande, elegir cuál está activa y activar/desactivar el
/// Companion globalmente. Es una capa **puramente cosmética y local**: no toca
/// voz, runtime ni gateway, y no hace ninguna petición de red.
///
/// Reutiliza por completo el stack de Fase A: [CompanionController] (estado +
/// persistencia), [CompanionPreview] (render del sprite propio de cada mascota)
/// y los modelos existentes. El logo Hermes NUNCA aparece aquí como mascota: la
/// opción por defecto es el Spark ([CompanionPreview] con `companion: null`).
class MascotasScreen extends StatelessWidget {
  /// Controller inyectable (tests). En producción es `null` y se resuelve desde
  /// el [HermesAppState] ancestro (patrón de Fase A).
  final CompanionController? controller;

  /// Lanzador de enlaces externos inyectable (tests). En producción usa
  /// `url_launcher` en modo navegador externo.
  final UrlLauncher? launcher;

  /// Override del estado de verificación del enlace de Petdex (tests). En
  /// producción usa la constante [kPetdexUrlVerified].
  final bool? petdexVerified;

  /// Selector de ZIP inyectable (tests). En producción usa `file_picker`.
  final ZipPicker? picker;

  const MascotasScreen({
    super.key,
    this.controller,
    this.launcher,
    this.petdexVerified,
    this.picker,
  });

  static Future<bool> _defaultLauncher(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// Selector real: abre el explorador de archivos y devuelve los bytes del ZIP
  /// elegido. Sin red: solo lee un fichero local que el usuario selecciona.
  static Future<Uint8List?> _defaultPicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.first.bytes;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final controller =
        this.controller ??
        context.findAncestorStateOfType<HermesAppState>()?.companion;
    return Scaffold(
      appBar: HermesAppBar(title: Text(Strings.of(context).petScreenTitle)),
      body: controller == null
          ? _UnavailableState(colors: colors)
          : AnimatedBuilder(
              animation: controller,
              builder: (context, _) => _MascotasBody(
                controller: controller,
                colors: colors,
                launcher: launcher ?? _defaultLauncher,
                petdexVerified: petdexVerified ?? kPetdexUrlVerified,
                picker: picker ?? _defaultPicker,
              ),
            ),
    );
  }
}

class _MascotasBody extends StatefulWidget {
  const _MascotasBody({
    required this.controller,
    required this.colors,
    required this.launcher,
    required this.petdexVerified,
    required this.picker,
  });

  final CompanionController controller;
  final HermesThemeColors colors;
  final UrlLauncher launcher;
  final bool petdexVerified;
  final ZipPicker picker;

  @override
  State<_MascotasBody> createState() => _MascotasBodyState();
}

class _MascotasBodyState extends State<_MascotasBody> {
  /// Estado de animación que el probador está reproduciendo en el preview, o
  /// `null` para el estado de reposo (`idle`). Es **efímero y local**: no toca
  /// el estado global del Companion ni el runtime del agente.
  CompanionAnimationState? _testState;
  Timer? _testTimer;

  double? _sizeDraft;
  String? _speedDraftSlug;
  double? _speedDraft;

  /// Fila de animación EXTRA que está reproduciendo el probador (las que no
  /// tienen un estado nombrado), o `null`. Efímera y local.
  RowSpec? _testRow;

  /// Índice de la animación EXTRA activa (para resaltar su chip), o `null`.
  int? _testExtraIndex;

  /// Modo bucle del probador: si está activo, la animación elegida se repite
  /// hasta que se elija otra o se pulse Detener (no toca el estado global).
  bool _loop = false;

  /// Tamaño base del preview grande; el preset de escala lo multiplica. El box
  /// contenedor es fijo y mayor, así cambiar S/M/L no descuadra el layout.
  static const double _previewBase = 100;
  static const double _previewBox = 150;

  CompanionController get controller => widget.controller;
  HermesThemeColors get colors => widget.colors;

  @override
  void dispose() {
    _testTimer?.cancel();
    super.dispose();
  }

  /// Selecciona una mascota cancelando cualquier prueba de animación en curso.
  void _select(String? slug) {
    _testTimer?.cancel();
    setState(() {
      _testState = null;
      _testRow = null;
      _testExtraIndex = null;
      _speedDraftSlug = null;
      _speedDraft = null;
    });
    controller.select(slug);
  }

  /// Detiene cualquier prueba en curso y vuelve a reposo (idle).
  void _stopTest() {
    _testTimer?.cancel();
    setState(() {
      _testState = null;
      _testRow = null;
      _testExtraIndex = null;
    });
  }

  /// Cambia el modo bucle. Al cambiarlo se detiene la prueba en curso para no
  /// dejar una animación en un estado ambiguo entre modos.
  void _setLoop(bool value) {
    if (value == _loop) return;
    _testTimer?.cancel();
    setState(() {
      _loop = value;
      _testState = null;
      _testRow = null;
      _testExtraIndex = null;
    });
  }

  /// Reproduce un estado de animación en el preview (local/efímero).
  ///
  /// - **Bucle ON**: se repite hasta elegir otra o pulsar Detener.
  /// - **Bucle OFF**: los estados de ciclo natural (idle/run/waiting) se
  ///   mantienen; los one-shot (wave/failed/jump) revierten tras su duración
  ///   real (frames/fps). Respeta reduce-motion (el renderer pinta estático).
  void _playTest(CompanionAnimationState state, Companion companion) {
    final row = companion.states[state];
    if (row == null) return;
    _testTimer?.cancel();
    setState(() {
      _testState = state;
      _testExtraIndex = null;
      // En bucle forzamos loop (incluso wave/failed); si no, dejamos que el
      // renderer use la fila real del estado.
      _testRow = _loop ? row.copyWith(loop: true) : null;
    });
    if (_loop || state.loopsByDefault) {
      return; // bucle/ciclo natural: no revertir
    }
    _scheduleRevert(row.frameCount, companion.fps);
  }

  /// Reproduce una animación EXTRA (sin estado nombrado) en el preview.
  void _playTestRow(int index, Companion companion) {
    if (index < 0 || index >= companion.extraRows.length) return;
    final row = companion.extraRows[index];
    _testTimer?.cancel();
    setState(() {
      _testState = null;
      _testExtraIndex = index;
      _testRow = row.copyWith(loop: _loop);
    });
    if (_loop) return;
    _scheduleRevert(row.frameCount, companion.fps);
  }

  /// Programa el regreso a reposo (idle) tras la duración de una animación
  /// one-shot.
  void _scheduleRevert(int? frameCount, double fps) {
    final ms = (frameCount == null || fps <= 0)
        ? 800
        : ((frameCount / fps) * 1000).round() + 200;
    _testTimer = Timer(Duration(milliseconds: ms < 400 ? 400 : ms), () {
      if (mounted) {
        setState(() {
          _testState = null;
          _testRow = null;
          _testExtraIndex = null;
        });
      }
    });
  }

  void _previewSize(double value) {
    setState(() => _sizeDraft = value);
  }

  Future<void> _commitSize(double value) async {
    await controller.setSizeMultiplier(value);
    if (!mounted) return;
    setState(() => _sizeDraft = null);
  }

  void _previewAnimationSpeed(String slug, double value) {
    setState(() {
      _speedDraftSlug = slug;
      _speedDraft = value;
    });
  }

  Future<void> _commitAnimationSpeed(String slug, double value) async {
    await controller.setAnimationSpeed(value, slug: slug);
    if (!mounted) return;
    setState(() {
      _speedDraftSlug = null;
      _speedDraft = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final available = controller.available;
    final selectedSlug = controller.selectedSlug;
    Companion? selectedCompanion;
    for (final c in available) {
      if (c.slug == selectedSlug) selectedCompanion = c;
    }
    final selectedName =
        selectedCompanion?.name ?? Strings.of(context).petDefaultName;
    final sizeMultiplier = _sizeDraft ?? controller.sizeMultiplier;
    final animationSpeed = _speedDraftSlug == selectedCompanion?.slug
        ? (_speedDraft ?? controller.animationSpeed)
        : controller.animationSpeed;
    final previewSize = _previewBase * sizeMultiplier;
    final visiblePresence = controller.enabled
        ? controller.presenceLevel
        : CompanionPresenceLevel.off;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Una única preview grande. Antes se repetía una mascota pequeña sobre
        // esta misma superficie sin aportar información adicional.
        Container(
          padding: const EdgeInsets.symmetric(vertical: 24),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              SizedBox(
                width: _previewBox,
                height: _previewBox,
                child: Center(
                  child: _buildPreviewSprite(
                    selectedCompanion,
                    previewSize,
                    animationSpeed,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                selectedName,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (selectedCompanion != null) ...[
                const SizedBox(height: 2),
                Text(
                  selectedCompanion.author,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionLabel(Strings.of(context).petSectionPresence),
        _PresenceLevelSelector(
          colors: colors,
          current: visiblePresence,
          onSelect: controller.setVisibilityLevel,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 9, 4, 0),
          child: Text(
            _presenceDescription(Strings.of(context), visiblePresence),
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ),
        HermesSwitchTile(
          controlKey: const ValueKey('pet-show-on-home'),
          value: controller.showOnHome,
          onChanged: controller.setShowOnHome,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          secondary: Icon(Icons.home_outlined, color: colors.textSecondary),
          title: Strings.of(context).petShowOnHomeTitle,
          subtitle: Strings.of(context).petShowOnHomeSubtitle,
        ),
        const SizedBox(height: 20),
        _sectionLabel(Strings.of(context).petSectionSize),
        _CompanionSlider(
          key: const ValueKey('pet-size-slider'),
          colors: colors,
          value: sizeMultiplier,
          min: CompanionDisplaySettings.minSizeMultiplier,
          max: CompanionDisplaySettings.maxSizeMultiplier,
          divisions: 14,
          leadingLabel: Strings.of(context).petSizeSmall,
          trailingLabel: Strings.of(context).petSizeLarge,
          valueLabel: '${(sizeMultiplier * 100).round()}%',
          semanticLabel: Strings.of(context).petSizeSliderSemantics,
          onChanged: _previewSize,
          onChangeEnd: _commitSize,
        ),
        const SizedBox(height: 20),
        Material(
          key: const ValueKey('pet-advanced-options'),
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            onExpansionChanged: (expanded) {
              if (!expanded) _stopTest();
            },
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            iconColor: colors.accent,
            collapsedIconColor: colors.textSecondary,
            title: Text(
              Strings.of(context).petAdvancedTitle,
              style: TextStyle(color: colors.textPrimary),
            ),
            subtitle: Text(
              Strings.of(context).petAdvancedSubtitle,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            children: [
              if (selectedCompanion != null) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    Strings.of(context).petAnimationSpeed,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                _CompanionSlider(
                  key: ValueKey(
                    'pet-animation-speed-${selectedCompanion.slug}',
                  ),
                  colors: colors,
                  value: animationSpeed,
                  min: CompanionDisplaySettings.minAnimationSpeed,
                  max: CompanionDisplaySettings.maxAnimationSpeed,
                  divisions: 20,
                  leadingLabel: Strings.of(context).petSpeedSlow,
                  trailingLabel: Strings.of(context).petSpeedFast,
                  valueLabel: '${animationSpeed.toStringAsFixed(2)}×',
                  semanticLabel: Strings.of(context).petAnimationSpeedSemantics,
                  onChanged: (value) =>
                      _previewAnimationSpeed(selectedCompanion!.slug, value),
                  onChangeEnd: (value) =>
                      _commitAnimationSpeed(selectedCompanion!.slug, value),
                ),
                const SizedBox(height: 8),
              ],
              HermesSwitchTile(
                value: controller.roamingEnabled,
                onChanged: visiblePresence == CompanionPresenceLevel.off
                    ? null
                    : controller.setRoamingEnabled,
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  Icons.directions_walk_rounded,
                  color: visiblePresence == CompanionPresenceLevel.off
                      ? colors.textDisabled
                      : colors.accent,
                ),
                title: Strings.of(context).petRoamingTitle,
                subtitle: Strings.of(context).petRoamingSubtitle,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _openPlayground,
                  icon: const Icon(Icons.open_in_full, size: 18),
                  label: Text(Strings.of(context).petFullscreen),
                ),
              ),
              _AnimationTester(
                colors: colors,
                companion: selectedCompanion,
                active: _testState,
                activeExtraIndex: _testExtraIndex,
                loop: _loop,
                onPlay: _playTest,
                onPlayRow: _playTestRow,
                onToggleLoop: _setLoop,
                onStop: _stopTest,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionLabel(Strings.of(context).petSectionChoose),
        // Opción por defecto (Spark) + cada mascota instalada.
        _MascotaTile(
          colors: colors,
          companion: null,
          name: Strings.of(context).petDefaultName,
          subtitle: Strings.of(context).petDefaultSubtitle,
          selected: selectedSlug == null,
          onTap: () => _select(null),
        ),
        for (final c in available)
          _MascotaTile(
            colors: colors,
            companion: c,
            name: c.name,
            subtitle: c.author,
            selected: c.slug == selectedSlug,
            onTap: () => _select(c.slug),
            // Borrar solo para importadas (Fase B.2). Las base están protegidas
            // y no muestran ningún control de borrado (sin UI muerta).
            onDelete: c.origin == CompanionOrigin.imported
                ? () => _confirmDelete(c)
                : null,
          ),
        const SizedBox(height: 20),
        // Importación de una mascota custom LOCAL (un ZIP con pet.json +
        // spritesheet). 100% local: no hay red ni subida. La validación estricta
        // vive en CompanionImportService.
        _sectionLabel(Strings.of(context).petSectionImport),
        _ImportButton(colors: colors, onTap: _importPet),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 8),
          child: Text(
            Strings.of(context).petImportHint,
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ),
        const SizedBox(height: 20),
        // Enlace a la galería externa Petdex (abre el navegador). No descarga
        // nada. Mientras la URL no esté verificada, queda pendiente.
        _sectionLabel(Strings.of(context).petGallerySection),
        // Galería remota in-app (manifest petdex-v1.json): buscar e instalar
        // directamente. Descarga solo el ZIP de la mascota elegida.
        _PetdexGalleryButton(colors: colors, onTap: _openPetdexGallery),
        const SizedBox(height: 10),
        _PetdexLink(
          colors: colors,
          verified: widget.petdexVerified,
          onTap: _openPetdex,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 8),
          child: Text(
            Strings.of(context).petBrowserHint,
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Abre el playground a pantalla completa para lucir las animaciones.
  void _openPlayground() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CompanionPlaygroundScreen(controller: controller),
      ),
    );
  }

  /// Abre la galería remota de Petdex (in-app) para buscar e instalar mascotas.
  void _openPetdexGallery() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PetdexGalleryScreen(controller: controller),
      ),
    );
  }

  /// Importa una mascota custom local desde un ZIP elegido por el usuario.
  /// Delega la validación/almacenamiento en el controller (que usa
  /// [CompanionImportService]). No hay red ni subida; ante datos inválidos
  /// muestra un aviso claro y no instala nada.
  Future<void> _importPet() async {
    final messenger = HermesNotice.maybeOf(context);
    final str = Strings.of(context);
    Uint8List? bytes;
    try {
      bytes = await widget.picker();
    } catch (e) {
      debugPrint('[mascotas] no se pudo abrir el selector de archivos: $e');
      bytes = null;
    }
    if (bytes == null) return; // cancelado por el usuario
    try {
      final pet = await controller.importFromZipBytes(bytes);
      messenger?.showSnackBar(
        SnackBar(content: Text(str.petImportedSnack(pet.name))),
        kind: HermesNoticeKind.success,
      );
    } on CompanionImportException catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text(str.petImportFailed(e.message))),
        kind: HermesNoticeKind.error,
      );
    } catch (e) {
      debugPrint('[mascotas] fallo inesperado al importar mascota: $e');
      messenger?.showSnackBar(
        SnackBar(content: Text(str.petImportFailedGeneric)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  /// Abre Petdex en el navegador externo. Si la URL aún no está verificada
  /// ([kPetdexUrlVerified] == false), NO abre nada y avisa de que está
  /// pendiente. Nunca descarga ni hace peticiones propias.
  Future<void> _openPetdex() async {
    final messenger = HermesNotice.maybeOf(context);
    final strCantOpen = Strings.of(context).petdexCantOpen;
    if (!widget.petdexVerified) {
      messenger?.showSnackBar(
        SnackBar(content: Text(Strings.of(context).petdexLinkPending)),
        kind: HermesNoticeKind.warning,
      );
      return;
    }
    bool ok = false;
    try {
      ok = await widget.launcher(Uri.parse(kPetdexUrl));
    } catch (e) {
      debugPrint('[mascotas] no se pudo abrir Petdex en el navegador: $e');
      ok = false;
    }
    if (!ok) {
      messenger?.showSnackBar(
        SnackBar(content: Text(strCantOpen)),
        kind: HermesNoticeKind.warning,
      );
    }
  }

  /// Pide confirmación y elimina una mascota importada. Las base nunca llegan
  /// aquí (no exponen control de borrado); aun así el controller las protege.
  Future<void> _confirmDelete(Companion companion) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          Strings.of(context).petDeleteTitle,
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          Strings.of(context).petDeleteConfirm(companion.name),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(
              Strings.of(context).commonCancel,
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(
              Strings.of(context).commonDelete,
              style: TextStyle(color: colors.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _testTimer?.cancel();
      setState(() => _testState = null);
      await controller.delete(companion.slug);
    }
  }

  /// Preview del sprite: usa el estado de prueba si la mascota lo declara; en
  /// caso contrario reposo (`idle`). Para la opción por defecto, el Spark.
  Widget _buildPreviewSprite(
    Companion? companion,
    double size,
    double animationSpeed,
  ) {
    if (companion == null) {
      return CompanionPreview(
        companion: null,
        size: size,
        accent: colors.accent,
      );
    }
    final state =
        (_testState != null && companion.states.containsKey(_testState))
        ? _testState!
        : CompanionAnimationState.idle;
    return SpritesheetRenderer(
      companion: companion,
      state: state,
      size: size,
      overrideRow: _testRow,
      speedMultiplier: animationSpeed,
    );
  }

  String _presenceDescription(Strings strings, CompanionPresenceLevel level) {
    return switch (level) {
      CompanionPresenceLevel.off => strings.petPresenceOffDescription,
      CompanionPresenceLevel.minimal => strings.petPresenceMinimalDescription,
      CompanionPresenceLevel.full => strings.petPresenceFullDescription,
    };
  }

  // Header de sección canónico del design system; se conserva el padding
  // compacto original de esta pantalla (spec 028 A-213).
  Widget _sectionLabel(String text) => HermesSectionHeader(
    text,
    padding: const EdgeInsets.only(left: 4, bottom: 8),
  );
}

class _CompanionSlider extends StatelessWidget {
  const _CompanionSlider({
    super.key,
    required this.colors,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.leadingLabel,
    required this.trailingLabel,
    required this.valueLabel,
    required this.semanticLabel,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final HermesThemeColors colors;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String leadingLabel;
  final String trailingLabel;
  final String valueLabel;
  final String semanticLabel;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final safeValue = value.clamp(min, max).toDouble();
    return Semantics(
      label: semanticLabel,
      value: valueLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    leadingLabel,
                    style: TextStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                  const Spacer(),
                  Text(
                    valueLabel,
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    trailingLabel,
                    style: TextStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                ],
              ),
              Slider(
                value: safeValue,
                min: min,
                max: max,
                divisions: divisions,
                activeColor: colors.accent,
                inactiveColor: colors.divider,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Selector del nivel de presencia (006): Apagada / Mínima / Completa.
class _PresenceLevelSelector extends StatelessWidget {
  const _PresenceLevelSelector({
    required this.colors,
    required this.current,
    required this.onSelect,
  });

  final HermesThemeColors colors;
  final CompanionPresenceLevel current;
  final ValueChanged<CompanionPresenceLevel> onSelect;

  String _labelFor(Strings strings, CompanionPresenceLevel level) {
    return switch (level) {
      CompanionPresenceLevel.off => strings.petPresenceOff,
      CompanionPresenceLevel.minimal => strings.petPresenceMinimal,
      CompanionPresenceLevel.full => strings.petPresenceFull,
    };
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Row(
      children: [
        for (final level in CompanionPresenceLevel.values) ...[
          Expanded(
            child: _SegmentPill(
              colors: colors,
              label: _labelFor(strings, level),
              semanticsLabel: strings.petPresenceSemantics(
                _labelFor(strings, level),
              ),
              selected: level == current,
              onTap: () => onSelect(level),
            ),
          ),
          if (level != CompanionPresenceLevel.values.last)
            const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _SegmentPill extends StatelessWidget {
  const _SegmentPill({
    required this.colors,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onTap,
  });

  final HermesThemeColors colors;
  final String label;
  final String semanticsLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      child: Material(
        color: selected
            ? colors.accent.withValues(alpha: 0.16)
            : colors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? colors.accent : colors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Probador de animaciones: un botón por estado. Los estados que la mascota
/// activa no declara aparecen deshabilitados (no se inventa `jump`).
class _AnimationTester extends StatelessWidget {
  const _AnimationTester({
    required this.colors,
    required this.companion,
    required this.active,
    required this.activeExtraIndex,
    required this.loop,
    required this.onPlay,
    required this.onPlayRow,
    required this.onToggleLoop,
    required this.onStop,
  });

  final HermesThemeColors colors;
  final Companion? companion;
  final CompanionAnimationState? active;
  final int? activeExtraIndex;
  final bool loop;
  final void Function(CompanionAnimationState, Companion) onPlay;
  final void Function(int, Companion) onPlayRow;
  final ValueChanged<bool> onToggleLoop;
  final VoidCallback onStop;

  /// Etiqueta legible de una animación EXTRA: usa el nombre del `pet.json` si
  /// existe; si no, un genérico "Extra N" (1-based).
  static String _extraLabel(Strings str, List<RowSpec> extras, int i) =>
      extras[i].label ?? str.petExtraAnim(i + 1);

  /// Orden fijo mostrado en el probador.
  static const List<CompanionAnimationState> _order = [
    CompanionAnimationState.idle,
    CompanionAnimationState.run,
    CompanionAnimationState.waiting,
    CompanionAnimationState.wave,
    CompanionAnimationState.failed,
    CompanionAnimationState.jump,
  ];

  static String _labelFor(Strings str, CompanionAnimationState s) {
    switch (s) {
      case CompanionAnimationState.idle:
        return str.petAnimIdle;
      case CompanionAnimationState.run:
        return str.petAnimRun;
      case CompanionAnimationState.waiting:
        return str.petAnimWait;
      case CompanionAnimationState.wave:
        return str.petAnimGreet;
      case CompanionAnimationState.failed:
        return str.petAnimFail;
      case CompanionAnimationState.jump:
        return str.petAnimJump;
      case CompanionAnimationState.review:
        return str.petAnimCheck;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pet = companion;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final bool playing = active != null || activeExtraIndex != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pet == null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              Strings.of(context).petTryHint,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
          ),
        if (pet != null) ...[
          // Controles: Bucle + Detener. Bucle se deshabilita con reduce-motion
          // (el preview se queda estático, sin animación infinita).
          Row(
            children: [
              // Un solo nodo de accesibilidad: TalkBack anuncia "Bucle" junto
              // al estado del toggle, no un switch anónimo (spec 028 A-107).
              MergeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      key: const Key('companion-loop-switch'),
                      value: loop && !reduceMotion,
                      onChanged: reduceMotion ? null : onToggleLoop,
                    ),
                    Text(
                      Strings.of(context).petLoop,
                      style: TextStyle(
                        color: reduceMotion
                            ? colors.textDisabled
                            : colors.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: playing ? onStop : null,
                icon: Icon(
                  Icons.stop_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
                label: Text(
                  Strings.of(context).petStop,
                  style: TextStyle(
                    color: playing ? colors.textPrimary : colors.textDisabled,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final state in _order)
              _TesterChip(
                colors: colors,
                label: _labelFor(Strings.of(context), state),
                enabled: pet != null && pet.states.containsKey(state),
                active: active == state,
                onTap: (pet != null && pet.states.containsKey(state))
                    ? () => onPlay(state, pet)
                    : null,
              ),
            // Animaciones EXTRA detectadas en el spritesheet (sin estado
            // nombrado): nombre del pet.json si existe, o "Extra N".
            if (pet != null)
              for (int i = 0; i < pet.extraRows.length; i++)
                _TesterChip(
                  colors: colors,
                  label: _extraLabel(Strings.of(context), pet.extraRows, i),
                  enabled: true,
                  active: activeExtraIndex == i,
                  onTap: () => onPlayRow(i, pet),
                ),
          ],
        ),
        if (pet != null && reduceMotion) ...[
          const SizedBox(height: 8),
          Text(
            Strings.of(context).petReducedMotion,
            style: TextStyle(color: colors.textSecondary, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _TesterChip extends StatelessWidget {
  const _TesterChip({
    required this.colors,
    required this.label,
    required this.enabled,
    required this.active,
    required this.onTap,
  });

  final HermesThemeColors colors;
  final String label;
  final bool enabled;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color border;
    final Color fg;
    if (!enabled) {
      border = colors.divider;
      fg = colors.textDisabled;
    } else if (active) {
      border = colors.accent;
      fg = colors.accent;
    } else {
      border = colors.divider;
      fg = colors.textPrimary;
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: Strings.of(context).petAnimationSemantics(label),
      child: Material(
        color: active && enabled
            ? colors.accent.withValues(alpha: 0.16)
            : colors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: border, width: active && enabled ? 1.5 : 1),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: active && enabled
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MascotaTile extends StatelessWidget {
  const _MascotaTile({
    required this.colors,
    required this.companion,
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.onDelete,
  });

  final HermesThemeColors colors;
  final Companion? companion;
  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  /// Acción de borrado. Solo se provee para mascotas importadas; para las base
  /// es `null` → no se muestra ningún control de borrado (sin UI muerta).
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: ListTile(
          onTap: onTap,
          // Expone la mascota activa también por semántica (TalkBack anuncia
          // "seleccionado"), no solo por borde ámbar + check (spec 028 A-119).
          selected: selected,
          leading: SizedBox(
            width: 44,
            height: 44,
            // Preview del sprite PROPIO de esta mascota (no de la activa, no logo).
            child: CompanionPreview(
              companion: companion,
              size: 44,
              accent: colors.accent,
            ),
          ),
          title: Text(name, style: TextStyle(color: colors.textPrimary)),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Borrar: solo presente para importadas (onDelete != null).
              if (onDelete != null)
                IconButton(
                  icon: Icon(Icons.delete_outline, color: colors.textSecondary),
                  tooltip: Strings.of(context).petDeleteTitle,
                  onPressed: onDelete,
                ),
              selected
                  ? Icon(Icons.check_circle, color: colors.accent)
                  : Icon(
                      Icons.radio_button_unchecked,
                      color: colors.textDisabled,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fila "Ver Petdex". Cuando la URL no está verificada se muestra atenuada con
/// la nota de pendiente (pero sigue siendo pulsable para mostrar el aviso).
class _PetdexLink extends StatelessWidget {
  const _PetdexLink({
    required this.colors,
    required this.verified,
    required this.onTap,
  });

  final HermesThemeColors colors;
  final bool verified;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.divider),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          Icons.open_in_new,
          color: verified ? colors.accent : colors.textDisabled,
        ),
        title: Text(
          Strings.of(context).petViewPetdex,
          style: TextStyle(color: colors.textPrimary),
        ),
        subtitle: Text(
          verified
              ? Strings.of(context).petViewPetdexSubVerified
              : Strings.of(context).petViewPetdexSubPending,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      ),
    );
  }
}

/// Fila "Explorar galería Petdex": abre la galería remota in-app (manifest
/// `petdex-v1.json`) para buscar e instalar mascotas. Descarga solo el ZIP de
/// la mascota elegida y la valida con el pipeline local.
class _PetdexGalleryButton extends StatelessWidget {
  const _PetdexGalleryButton({required this.colors, required this.onTap});

  final HermesThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.divider),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(Icons.travel_explore, color: colors.accent),
        title: Text(
          Strings.of(context).petExplorePetdex,
          style: TextStyle(color: colors.textPrimary),
        ),
        subtitle: Text(
          Strings.of(context).petExploreSub,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
        trailing: Icon(Icons.chevron_right, color: colors.textSecondary),
      ),
    );
  }
}

/// Fila "Importar mascota": abre el selector de archivos para elegir un ZIP
/// local (`pet.json` + spritesheet). Solo local; no hay red ni subida.
class _ImportButton extends StatelessWidget {
  const _ImportButton({required this.colors, required this.onTap});

  final HermesThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.divider),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(Icons.file_upload_outlined, color: colors.accent),
        title: Text(
          Strings.of(context).petImportTitle,
          style: TextStyle(color: colors.textPrimary),
        ),
        subtitle: Text(
          Strings.of(context).petImportSubtitle,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      ),
    );
  }
}

class _UnavailableState extends StatelessWidget {
  const _UnavailableState({required this.colors});

  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          Strings.of(context).petsUnavailable,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textSecondary),
        ),
      ),
    );
  }
}
