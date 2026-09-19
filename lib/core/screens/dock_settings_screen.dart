import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/dock_config.dart';
import '../services/dock_preferences_store.dart';
import '../theme/app_theme.dart';
import '../widgets/dock_style.dart';
import '../widgets/hermes_ui.dart';

enum _DockTab { bots, general }

/// `persist: false` actualiza solo el valor en memoria (útil durante un
/// arrastre continuo, p.ej. el slider de transparencia — ver C4): la
/// escritura a disco real se hace en la siguiente llamada con
/// `persist: true` (el valor por defecto), normalmente al soltar.
typedef DockProfileUpdater =
    Future<void> Function(
      DockProfileConfig Function(DockProfileConfig) update, {
      bool persist,
    });

/// Ajustes › Dock: entorno real de personalización de los dos perfiles de
/// dock (Bots/General). Cada perfil guarda su propio orden de elementos,
/// visibilidad, elemento destacado, comportamiento de "Atrás" y estilo
/// (bordes/transparencia/profundidad) — nada se comparte entre perfiles.
class DockSettingsScreen extends StatefulWidget {
  const DockSettingsScreen({super.key});

  @override
  State<DockSettingsScreen> createState() => _DockSettingsScreenState();
}

class _DockSettingsScreenState extends State<DockSettingsScreen> {
  final _controller = DockPreferencesController.instance;
  _DockTab _tab = _DockTab.bots;

  Future<void> _updateProfile(
    DockProfileConfig Function(DockProfileConfig) update, {
    bool persist = true,
  }) => _tab == _DockTab.bots
      ? _controller.updateBots(update, persist: persist)
      : _controller.updateGeneral(update, persist: persist);

  Future<void> _reset() => _tab == _DockTab.bots
      ? _controller.resetBots()
      : _controller.resetGeneral();

  String _profileLabel(Strings strings) =>
      _tab == _DockTab.bots ? strings.dockProfileBots : strings.dockProfileGeneral;

  // "Restablecer" reseteaba solo el perfil activo sin decirlo ni pedir
  // confirmación: con dos perfiles delante (Bots/General) se lee como un
  // reset global (bug confirmado: D5). El label ya nombra el perfil
  // afectado y la confirmación lo repite explícitamente.
  Future<void> _confirmAndReset(BuildContext context) async {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final profile = _profileLabel(strings);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(strings.dockSettingsResetProfile(profile)),
        content: Text(
          strings.dockSettingsResetConfirmBody(profile),
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.dockSettingsReset),
          ),
        ],
      ),
    );
    if (confirmed == true) await _reset();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.dockSettingsTitle),
        actions: [
          TextButton(
            onPressed: () => unawaited(_confirmAndReset(context)),
            child: Text(strings.dockSettingsResetProfile(_profileLabel(strings))),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller.listenable,
        builder: (context, _) {
          final prefs = _controller.value;
          final profile = _tab == _DockTab.bots ? prefs.bots : prefs.general;
          return _DockSettingsBody(
            tab: _tab,
            profile: profile,
            onTabChanged: (tab) => setState(() => _tab = tab),
            onUpdate: _updateProfile,
          );
        },
      ),
    );
  }
}

class _DockSettingsBody extends StatelessWidget {
  final _DockTab tab;
  final DockProfileConfig profile;
  final ValueChanged<_DockTab> onTabChanged;
  final DockProfileUpdater onUpdate;

  const _DockSettingsBody({
    required this.tab,
    required this.profile,
    required this.onTabChanged,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final visibleCount = profile.items.where((i) => i.visible).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _Segmented<_DockTab>(
          height: 38,
          values: const [_DockTab.bots, _DockTab.general],
          selected: tab,
          labelOf: (t) => t == _DockTab.bots
              ? strings.dockProfileBots
              : strings.dockProfileGeneral,
          onChanged: onTabChanged,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
          child: Text(
            tab == _DockTab.bots
                ? strings.dockProfileBotsDescription
                : strings.dockProfileGeneralDescription,
            style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
          ),
        ),
        HermesSectionHeader(
          strings.dockItemsSectionTitle,
          trailing: Text(
            strings.dockItemsVisibleCount(visibleCount, profile.items.length),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: colors.textSecondary.withValues(alpha: 0.85),
            ),
          ),
        ),
        _DockItemList(profile: profile, tab: tab, onUpdate: onUpdate),
        HermesSectionHeader(strings.dockBehaviorSectionTitle),
        HermesGroup(
          children: [
            // `HermesGroup` pinta su propio fondo con color (un
            // `Container` con `BoxDecoration.color`) directamente por
            // encima de `HermesSwitchTile` (internamente, un tile con
            // ripple basado en `ListTile`); sin un `Material` de por medio,
            // Flutter detecta en depuración que el fondo/ripple del switch
            // quedaría invisible bajo ese `Container` (aviso real, no solo
            // de test). `Material(type: transparency)` no añade superficie
            // ni cambia nada visible: solo le da al switch el ancestro
            // `Material` más cercano que la propia guía de Flutter pide.
            Material(
              type: MaterialType.transparency,
              child: HermesSwitchTile(
                controlKey: const ValueKey('dock-settings-show-back'),
                title: strings.dockShowBackTitle,
                subtitle: strings.dockShowBackSubtitle,
                value: profile.showBackOnSubscreens,
                onChanged: (value) => unawaited(
                  onUpdate((p) => p.copyWith(showBackOnSubscreens: value)),
                ),
              ),
            ),
          ],
        ),
        // La vista previa vive pegada a "Estilo" (y no arriba del todo, junto
        // al resto de secciones) a propósito: es la sección donde de verdad
        // hace falta ver el efecto al instante de cada toque, sin tener que
        // volver a subir la pantalla ("toco algo abajo, algo cambia lejos
        // arriba" era justo la queja).
        HermesSectionHeader(strings.dockPreviewSectionTitle),
        _DockPreview(profile: profile),
        HermesSectionHeader(strings.dockStyleSectionTitle),
        _DockStyleEditor(profile: profile, onUpdate: onUpdate),
      ],
    );
  }
}

/// Vista previa en vivo: el mismo `DockBar`/`DockItemTile` que usa el dock
/// real, sin acciones, para que el resultado de tocar cualquier control de
/// esta pantalla se vea al instante.
class _DockPreview extends StatelessWidget {
  final DockProfileConfig profile;

  const _DockPreview({required this.profile});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final visual = resolveDockVisual(colors, profile.style);
    // La vista previa refleja el estado REAL del switch "Mostrar Atrás en
    // subpantallas": antes fijaba `showBack: false` a fuego, así que
    // tocarlo no cambiaba nada visible en la propia vista previa que está
    // justo encima (bug confirmado: D2).
    final slots = resolveDockSlots(
      visibleItems: profile.visibleItemIds,
      showBack: profile.showBackOnSubscreens,
    );
    // El primer item VISIBLE en el orden actual (no el primero del catálogo
    // completo, que puede estar oculto y entonces no resaltar nada) es el
    // que `resolveDockSlots` protege de la retirada al insertar "Atrás" —
    // ver su doc. Antes se comparaba contra `profile.items.first.id` sin
    // mirar visibilidad (bug confirmado: D3).
    final firstVisible = profile.visibleItemIds.isEmpty
        ? null
        : profile.visibleItemIds.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DockBar(
        style: profile.style,
        children: [
          for (final slot in slots)
            if (slot != null)
              DockItemTile(
                icon: dockItemVisual(slot).icon,
                selectedIcon: dockItemVisual(slot).selectedIcon,
                label: dockItemLabel(strings, slot),
                selected: slot == firstVisible,
                // Misma regla de acento que el dock real, leída de la misma
                // función compartida (`dockItemIsAccent`) en vez de repetir
                // aquí la condición: el acento es SIEMPRE el "+", y no está
                // ligado al primer item visible, que solo protege de la
                // retirada al insertar "Atrás", sin control manual en esta
                // UI.
                accent: dockItemIsAccent(slot),
                innerRadius: visual.innerRadius,
                // El dock real SIEMPRE usa `compact: true` (icono arriba,
                // etiqueta debajo); la vista previa pintaba la rama no
                // compacta (icono y etiqueta en línea), así que no
                // representaba de verdad cómo se ve el dock (bug
                // confirmado: D1).
                compact: true,
              ),
        ],
      ),
    );
  }
}

class _DockItemList extends StatelessWidget {
  final DockProfileConfig profile;
  final _DockTab tab;
  final DockProfileUpdater onUpdate;

  const _DockItemList({
    required this.profile,
    required this.tab,
    required this.onUpdate,
  });

  String? _subtitleFor(Strings strings, DockItemId id) {
    if (id != DockItemId.create) return null;
    return tab == _DockTab.bots
        ? strings.dockCreateBotsSubtitle
        : strings.dockCreateGeneralSubtitle;
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final items = profile.items;
    final visibleCount = items.where((i) => i.visible).length;
    // Altura por item derivada del escalado de texto activo en vez de un
    // valor fijo: a `textScale` alto (2.0x en el peor caso medido) el
    // contenido de cada fila (la etiqueta, sobre todo) ya no cabía en los
    // 54dp fijos y Flutter lanzaba overflow de layout real (bug confirmado,
    // MEDIDO: B1). El resto de la fila (icono/asa/switch) no escala, así
    // que crece con margen de sobra.
    final rowHeight = MediaQuery.textScalerOf(context).scale(54.0);
    return HermesGroup(
      children: [
        SizedBox(
          height: rowHeight * items.length,
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            onReorderItem: (oldIndex, newIndex) {
              final next = List<DockItemConfig>.from(items);
              final moved = next.removeAt(oldIndex);
              next.insert(newIndex, moved);
              unawaited(onUpdate((p) => p.copyWith(items: next)));
            },
            itemBuilder: (context, index) {
              final item = items[index];
              final visual = dockItemVisual(item.id);
              final itemLabel = dockItemLabel(strings, item.id);
              // Impide apagar el ÚLTIMO elemento visible: sin esto se podía
              // dejar un perfil entero sin ningún item, dejando una barra
              // flotante vacía y sin navegación (bug confirmado, MEDIDO:
              // A4). El switch se deshabilita (además de la señal visual
              // propia de un `Switch` inhabilitado, un tooltip explica por
              // qué al mantener pulsado/en hover).
              final isLastVisible = item.visible && visibleCount <= 1;
              return Container(
                key: ValueKey('dock-item-${item.id.name}'),
                height: rowHeight,
                decoration: index == items.length - 1
                    ? null
                    : BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: colors.divider.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                child: Row(
                  children: [
                    Semantics(
                      label: strings.dockItemDragHandleLabel(itemLabel),
                      child: ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          // Área táctil ampliada a 44dp (antes ~36dp, por
                          // debajo del mínimo de accesibilidad) sin cambiar
                          // el tamaño visual del icono (bug confirmado: B4).
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(
                            Icons.drag_indicator_rounded,
                            size: 20,
                            color: colors.textDisabled,
                          ),
                        ),
                      ),
                    ),
                    Icon(
                      visual.icon,
                      size: 21,
                      color: item.visible
                          ? colors.textPrimary
                          : colors.textDisabled,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            itemLabel,
                            // `maxLines`/`overflow`, antes ausentes: sin
                            // ellos, a `textScale` alto una etiqueta larga
                            // ("Scheduled tasks", "Herramientas"...) envuelve
                            // a una segunda línea y desborda la altura fija
                            // de la fila (`rowHeight`, ya escalada para UNA
                            // línea) — parte del overflow real medido en
                            // B1, junto con el resto del layout de esta
                            // pantalla.
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                              color: item.visible
                                  ? colors.textPrimary
                                  : colors.textDisabled,
                            ),
                          ),
                          if (_subtitleFor(strings, item.id) != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                _subtitleFor(strings, item.id)!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Sin control manual de "destacado": el usuario pidió
                    // explícitamente poder mostrar/ocultar/mover cualquier
                    // item sin un paso previo que "se lo robe" a otro
                    // ("no entiendo para qué quiero seleccionarlos, si
                    // simplemente se debería quitar o poner o moverlos").
                    // El elemento que nunca se retira al insertar "Atrás"
                    // se calcula solo, como el primer item visible (ver
                    // `resolveDockSlots`); no hace falta guardarlo aparte.
                    Tooltip(
                      message: isLastVisible
                          ? strings.dockItemsKeepOneVisible
                          : itemLabel,
                      child: Semantics(
                        label: itemLabel,
                        child: Switch(
                          value: item.visible,
                          onChanged: isLastVisible
                              ? null
                              : (value) => unawaited(
                                  onUpdate(
                                    (p) => p.copyWith(
                                      items: [
                                        for (final it in p.items)
                                          it.id == item.id
                                              ? it.copyWith(visible: value)
                                              : it,
                                      ],
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Sombra reducida y de escala fija para las miniaturas de `_StyleSwatch`:
/// las sombras reales de [resolveDockVisual] están calibradas para la barra
/// completa (48dp de alto, a ras del borde de la pantalla) y a esa escala
/// se ven bien, pero pintadas literalmente sobre una miniatura de ~24dp
/// dentro de una fila apretada de 3 se saldrían del recuadro y se
/// mancharían unas con otras. Mismo criterio (plano/elevado/flotante +
/// resplandor de cristal si hay transparencia), proporciones para el
/// tamaño pequeño.
List<BoxShadow> _swatchShadows(DockStyle style) {
  final transparency = style.transparency.clamp(0.0, 1.0);
  final base = switch (style.depth) {
    DockDepth.flat => const <BoxShadow>[],
    DockDepth.elevated => [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.3),
        blurRadius: 5,
        offset: const Offset(0, 2),
      ),
    ],
    DockDepth.floating => [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.38),
        blurRadius: 8,
        offset: const Offset(0, 3),
      ),
    ],
  };
  if (transparency <= 0) return base;
  return [
    ...base,
    BoxShadow(
      color: Colors.white.withValues(alpha: 0.05 + transparency * 0.09),
      blurRadius: 6 + transparency * 5,
    ),
  ];
}

/// Sección "Estilo": tres controles que antes eran genéricos y sin relación
/// visual con lo que le pasaba a la vista previa (dos segmentados de solo
/// texto y un slider numérico). Ahora cada opción de Bordes/Profundidad se
/// elige tocando una miniatura real — construida con el mismo
/// [resolveDockVisual] que pinta el dock de verdad — en vez de leer una
/// palabra ("Suave", "Elevado") sin more contexto visual.
class _DockStyleEditor extends StatelessWidget {
  final DockProfileConfig profile;
  final DockProfileUpdater onUpdate;

  const _DockStyleEditor({required this.profile, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final style = profile.style;

    return HermesGroup(
      children: [
        _StyleRow(
          label: strings.dockStyleBorderLabel,
          child: _swatchRow(context, [
            for (final shape in DockBorderShape.values)
              _StyleSwatch(
                selected: style.borderShape == shape,
                label: switch (shape) {
                  DockBorderShape.square => strings.dockStyleBorderSquare,
                  DockBorderShape.soft => strings.dockStyleBorderSoft,
                  DockBorderShape.rounded => strings.dockStyleBorderRounded,
                },
                candidate: style.copyWith(borderShape: shape),
                colors: colors,
                // `p.style.copyWith(...)`, no `style.copyWith(...)`: el
                // closure capturaba el `style` de ESTE build (`profile` en
                // el momento de construir el widget) en vez del `style`
                // ACTUAL del `p` recibido en la actualización — dos toques
                // rápidos en distintas dimensiones de estilo (borde,
                // transparencia, profundidad) se pisaban entre sí (bug
                // confirmado, E).
                onTap: () => unawaited(
                  onUpdate(
                    (p) => p.copyWith(style: p.style.copyWith(borderShape: shape)),
                  ),
                ),
              ),
          ]),
        ),
        _StyleRow(
          label: strings.dockStyleTransparencyLabel,
          trailing: _PercentPill(value: style.transparency),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: colors.accentText,
              inactiveTrackColor: colors.divider,
              thumbColor: colors.textPrimary,
              overlayColor: colors.accentText.withValues(alpha: 0.15),
              trackHeight: 4,
            ),
            child: Slider(
              value: style.transparency,
              // Pasos discretos navegables sin vista + anuncio del valor al
              // lector de pantalla mientras se arrastra: antes no tenía
              // `divisions` ni `label` (bug confirmado: B5).
              divisions: 10,
              label: '${(style.transparency * 100).round()} %',
              // `persist: false` en cada frame del arrastre: antes cada
              // `onChanged` escribía a `SharedPreferences`, cientos de
              // veces por segundo mientras se arrastraba el thumb (bug
              // confirmado: C4). El valor final se persiste una sola vez en
              // `onChangeEnd`.
              onChanged: (value) => unawaited(
                onUpdate(
                  (p) => p.copyWith(style: p.style.copyWith(transparency: value)),
                  persist: false,
                ),
              ),
              onChangeEnd: (value) => unawaited(
                onUpdate(
                  (p) => p.copyWith(style: p.style.copyWith(transparency: value)),
                ),
              ),
            ),
          ),
        ),
        _StyleRow(
          label: strings.dockStyleDepthLabel,
          child: _swatchRow(context, [
            for (final depth in DockDepth.values)
              _StyleSwatch(
                selected: style.depth == depth,
                label: switch (depth) {
                  DockDepth.flat => strings.dockStyleDepthFlat,
                  DockDepth.elevated => strings.dockStyleDepthElevated,
                  DockDepth.floating => strings.dockStyleDepthFloating,
                },
                candidate: style.copyWith(depth: depth),
                colors: colors,
                onTap: () => unawaited(
                  onUpdate(
                    (p) => p.copyWith(style: p.style.copyWith(depth: depth)),
                  ),
                ),
              ),
          ]),
        ),
      ],
    );
  }
}

/// Fila de miniaturas de Bordes/Profundidad: en línea (una `Expanded` por
/// opción) salvo que el escalado de texto supere ~1.3x, caso en el que ya no
/// caben una junto a otra sin desbordar (bug confirmado, MEDIDO: B1) y se
/// apilan en un `Wrap` en su lugar.
Widget _swatchRow(BuildContext context, List<Widget> swatches) {
  final scaled = MediaQuery.textScalerOf(context).scale(14.0) / 14.0;
  if (scaled > 1.3) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [for (final swatch in swatches) SizedBox(width: 140, child: swatch)],
    );
  }
  return Row(
    children: [
      for (var i = 0; i < swatches.length; i++) ...[
        if (i != 0) const SizedBox(width: 10),
        Expanded(child: swatches[i]),
      ],
    ],
  );
}

/// Fila de la sección Estilo: etiqueta (+ opcional indicador a la derecha,
/// como el % de transparencia) y el control debajo, agrupados con el mismo
/// padding que el resto de `HermesGroup` para que no se sienta como un
/// panel aparte.
class _StyleRow extends StatelessWidget {
  final String label;
  final Widget? trailing;
  final Widget child;

  const _StyleRow({required this.label, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Píldora con el porcentaje de transparencia actual, con el mismo acento
/// ámbar que el resto de la app usa para señalar el valor activo — en vez
/// del texto plano de antes.
class _PercentPill extends StatelessWidget {
  final double value;

  const _PercentPill({required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: colors.accentText.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${(value * 100).round()} %',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: colors.accentText,
        ),
      ),
    );
  }
}

/// Miniatura tocable de una opción de Bordes/Profundidad: una barra en
/// miniatura pintada con el [DockVisual] real que resultaría de elegirla
/// (mismo color/borde/radio que [DockBar]; solo la sombra se reduce de
/// escala, ver [_swatchShadows]), con su etiqueta debajo y un anillo de
/// acento cuando está seleccionada. Sustituye al segmentado de solo texto:
/// el usuario ve la forma/profundidad real en vez de adivinarla por la
/// palabra.
class _StyleSwatch extends StatelessWidget {
  final bool selected;
  final String label;

  /// Estilo candidato que resultaría de elegir esta opción (con el resto de
  /// dimensiones del perfil sin cambiar): de aquí salen tanto el
  /// [DockVisual] real (color/borde/radio) como la sombra en miniatura.
  final DockStyle candidate;
  final HermesThemeColors colors;
  final VoidCallback onTap;

  const _StyleSwatch({
    required this.selected,
    required this.label,
    required this.candidate,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final visual = resolveDockVisual(colors, candidate);
    final radius = visual.outerRadius.clamp(4.0, 13.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.accentText : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: visual.background,
                border: Border.all(color: visual.border),
                borderRadius: BorderRadius.circular(radius),
                boxShadow: _swatchShadows(candidate),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? colors.textPrimary : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Control segmentado genérico (perfil / bordes / profundidad): misma
/// píldora con relleno deslizante en las tres pantallas.
class _Segmented<T> extends StatelessWidget {
  final double height;
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  const _Segmented({
    required this.height,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          for (final value in values)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == selected ? colors.surfaceVariant : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    labelOf(value),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: value == selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: value == selected
                          ? colors.textPrimary
                          : colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
