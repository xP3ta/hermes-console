import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';

import 'dart:async';
import 'dart:convert';

import '../services/startup_destination.dart';
import '../services/dock_preferences_store.dart';

import 'package:http/http.dart' as http;

import '../app_header_title.dart';
import '../models/session_category.dart';
import '../services/chat_draft_store.dart';
import '../services/connection_manager.dart';

import '../services/font_size_service.dart';
import '../services/local_transcript_store.dart';
import '../services/session_deletion.dart';
import '../services/turn_outbox_store.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/theme_profile_adapter.dart';
import '../theme/theme_profile_store.dart';
import '../utils/api_error.dart';
import '../utils/transport_privacy.dart';

import '../services/bridge_update_service.dart';
import '../services/hermes_update_monitor.dart';
import '../../main.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_update_card.dart';
import '../widgets/read_only.dart';
import 'about_screen.dart';
import 'bridge_file_editor_screen.dart';
import 'lock_screen.dart';
import 'gateway_manager_screen.dart';
import 'instance_edit_screen.dart';
import 'local_instance_control_screen.dart';
import 'models_screen.dart';
import 'permissions_screen.dart';
import 'security_info_screen.dart';
import 'themes_screen.dart';
import 'dock_settings_screen.dart';
import 'notification_settings_screen.dart';
import 'voice_settings_screen.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../widgets/hermes_app_bar.dart';
import '../widgets/diagnostic_bundle_tile.dart';

/// Estado del único canal que consume Hermes Console.
///
/// `/api/status` también publica conectores de terceros configurados en el
/// servidor. No forman parte de esta aplicación y no deben aparecer como un
/// fallo de Hermes Console. La app se comunica exclusivamente por
/// `api_server`, por lo que la UI aplica una allowlist explícita.
Map<String, String> currentGatewayPlatformStates(Map<String, dynamic>? status) {
  final raw = status?['gateway_platforms'];
  if (raw is! Map) return const {};
  final result = <String, String>{};
  for (final entry in raw.entries) {
    if (entry.key.toString() != 'api_server') continue;
    final value = entry.value;
    final state = (value is Map ? value['state'] : value).toString();
    result['api_server'] = state;
  }
  return result;
}

/// Reserva inferior que necesita una lista scrolleable para que el dock
/// flotante no le tape el final.
///
/// El dock se pinta como overlay (ver `GeneralDockShell`: un `Stack` con el
/// `body` debajo y el `Dock` encima) y NO reserva hueco por sí mismo. Ajustes
/// no aplicaba ninguna reserva, así que su última sección ("Acerca de")
/// quedaba detrás del dock (confirmado en dispositivo real). El cálculo es el
/// mismo que ya usa Inicio: alto de la barra (48) + su separación del borde
/// (12) + el `lift` máximo del estilo "Flotante" (6) + el inset seguro
/// inferior del sistema + un margen de aire.
///
/// Con el interruptor global "Usar dock flotante" apagado el dock no existe,
/// así que no se reserva nada: dejar el hueco muerto sería el bug opuesto.
@visibleForTesting
double dockScrollReservation(BuildContext context, {required bool useDock}) =>
    useDock ? 48 + 12 + 6 + MediaQuery.paddingOf(context).bottom + 16 : 0;

/// Presentación de la fila de temas en Ajustes. Mantenerla pura evita que un
/// id personalizado pase por `presetById` y se anuncie falsamente como Amber.
final class SettingsThemePresentation {
  final String name;
  final HermesThemeColors colors;
  final int total;

  const SettingsThemePresentation({
    required this.name,
    required this.colors,
    required this.total,
  });
}

SettingsThemePresentation settingsThemePresentation(
  ThemeProfileStoreSnapshot snapshot,
) {
  final custom = snapshot.customById(snapshot.activeProfileId);
  final preset = AppTheme.presetById(snapshot.activeProfileId);
  return SettingsThemePresentation(
    name: custom?.name ?? preset.name,
    colors: custom == null
        ? preset.colors
        : ThemeProfileAdapter.colorsFromProfile(custom),
    total: AppTheme.presets.length + snapshot.customProfiles.length,
  );
}

class SettingsScreen extends StatelessWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  @visibleForTesting
  final Future<bool> Function()? verifyHistoryCleanupForTesting;
  const SettingsScreen({
    required this.connection,
    required this.connManager,
    @visibleForTesting this.verifyHistoryCleanupForTesting,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // El título hereda el titleTextStyle del tema (mono bold accentHover),
    // igual que Voz y Notificaciones: sin estilos locales (spec 028 A-203).
    //
    // La pantalla se reconstruye al cambiar la instancia ACTIVA (mismo patrón
    // que HomeDashboardScreen) y también ante ediciones materiales de una
    // instancia con el mismo id. La revisión forma parte de la key de
    // autocompresión para cerrar el cliente anterior y volver a cargar URL,
    // auth, permisos y schema sin tener que reabrir Ajustes.
    return ValueListenableBuilder<String?>(
      valueListenable: connManager.activeConnectionId,
      builder: (context, activeId, _) {
        final id =
            activeId ??
            connManager.prefs.getString(ConnectionManager.lastConnKey) ??
            connection.id;
        return ValueListenableBuilder<int>(
          valueListenable: connManager.activeProfileRevisionFor(id),
          builder: (context, _, _) {
            return ValueListenableBuilder<int>(
              valueListenable: connManager.connectionsRevision,
              builder: (context, _, _) {
                return ValueListenableBuilder<int>(
                  valueListenable: connManager.connectionRevisionFor(id),
                  builder: (context, _, _) {
                    // The per-connection revision deliberately arrives before
                    // the global revision. Resolve from persisted state here,
                    // rather than retaining the connection captured by the
                    // outer builder, so the first replacement repository has
                    // the new endpoint/auth/read-only metadata.
                    final matches = connManager.getConnections().where(
                      (candidate) => candidate.id == id,
                    );
                    final conn = matches.isEmpty ? connection : matches.first;
                    return _buildBody(context, conn);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, SavedConnection conn) {
    return Scaffold(
      appBar: HermesAppBar(title: Text(Strings.of(context).setTitle)),
      // Ajustes es una pantalla de navegación de nivel superior alcanzable
      // en 1 salto desde Inicio: sin el dock aquí, el usuario lo veía
      // "desaparecer" al salir de Inicio/Mission Control (bug confirmado en
      // dispositivo real). `includeSettingsAction: false` evita apilar
      // Ajustes sobre sí misma si el usuario toca el propio item.
      body: GeneralDockShell(
        connection: conn,
        connManager: connManager,
        includeSettingsAction: false,
        // El dock se pinta ENCIMA de este cuerpo, así que la lista tiene que
        // reservar su hueco o la última sección ("Acerca de") queda detrás de
        // la barra. `ListenableBuilder` es necesario porque el interruptor
        // "Usar dock flotante" vive en esta misma pantalla: al apagarlo la
        // reserva debe desaparecer sin salir y volver a entrar.
        body: ListenableBuilder(
          listenable: DockPreferencesController.instance.listenable,
          builder: (context, _) => ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              dockScrollReservation(
                context,
                useDock: DockPreferencesController.instance.value.useDock,
              ),
            ),
            children: [
              // Orden de secciones: de lo esencial (a qué instancia hablas) a lo
              // avanzado, con voz y notificaciones como apartados propios en vez
              // de filas sueltas dentro de "chat" (spec 028 U-08).
              _SectionHeader(Strings.of(context).setSecConnection),
              _ConnectionCard(connection: conn, connManager: connManager),
              _SectionHeader(Strings.of(context).setSecAppearance),
              HermesGroup(
                children: [
                  _ThemesEntry(),
                  _FontStyleEntry(),
                  _LanguageEntry(),
                  _HeaderTitleField(),
                  _UseDockTile(),
                  _DockTile(),
                  _StartupDestinationTile(),
                ],
              ),
              _SectionHeader(Strings.of(context).setSecChat),
              HermesGroup(
                children: [
                  _ActiveModelTile(key: ValueKey(conn.id), connection: conn),
                ],
              ),
              _SectionHeader(Strings.of(context).voiceTitle),
              HermesGroup(children: [_VoiceTile(connection: conn)]),
              _SectionHeader(Strings.of(context).notifTitle),
              HermesGroup(children: [_NotificationsTile()]),
              _SectionHeader(Strings.of(context).setSecSecurity),
              HermesGroup(
                children: [
                  HermesNavRow(
                    icon: Icons.shield_outlined,
                    title: Strings.of(context).setSecurity,
                    subtitle: Strings.of(context).setSecuritySub,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            SecurityInfoScreen(connManager: connManager),
                      ),
                    ),
                  ),
                  HermesNavRow(
                    icon: Icons.verified_user_outlined,
                    title: Strings.of(context).setPermissions,
                    subtitle: Strings.of(context).setPermissionsSub,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PermissionsScreen(connection: conn),
                      ),
                    ),
                  ),
                  HermesNavRow(
                    icon: Icons.tune_outlined,
                    title: Strings.of(context).setServerConfig,
                    subtitle: Strings.of(context).setServerConfigSub,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BridgeFileEditorScreen(
                          connectionId: conn.id,
                          target: Strings.of(context).setSecConfig,
                          titleLabel: 'config.yaml',
                          readOnly: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              _SectionHeader(Strings.of(context).setSecSystem),
              _MaintenanceSection(
                key: ValueKey('maint-${conn.id}'),
                connection: conn,
                connManager: connManager,
              ),
              _SectionHeader(Strings.of(context).setSecBridge),
              HermesGroup(children: [_BridgeAutoUpdateTile(connection: conn)]),
              _SectionHeader(Strings.of(context).setSecData),
              HermesGroup(
                children: [
                  DiagnosticBundleTile(
                    controller: DiagnosticBundleController(
                      manager: connManager,
                    ),
                  ),
                ],
              ),
              HistoryCleanupSection(
                key: ValueKey('history-cleanup-${conn.id}'),
                connection: conn,
                connManager: connManager,
                verifyHistoryCleanupForTesting: verifyHistoryCleanupForTesting,
              ),
              _OrphanDataTile(connManager: connManager),
              _SectionHeader(Strings.of(context).setSecAbout),
              _AboutCard(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return HermesSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(2, 22, 2, 10),
    );
  }
}

/// Contenedor único de una sección: UNA superficie sutil con las filas
/// separadas por líneas finas, en vez de una caja por ajuste. Es la base del
/// look minimalista (menos cajas, más aire y jerarquía limpia).
/// Campo de preferencia (sin caja propia): título + nota breve + selector. Va
/// dentro de un [HermesGroup]; el aire y los separadores los pone el grupo.
class _PrefField extends StatelessWidget {
  final String title;
  final String caption;
  final Widget child;
  const _PrefField({
    required this.title,
    required this.caption,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Opción seleccionable SIN borde: la elegida lleva un relleno sutil de acento;
/// las demás son solo texto. Mucho menos ruido que un chip con borde por opción.
class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // TalkBack necesita rol y estado: sin esto solo lee la etiqueta y no hay
    // forma de saber cuál está elegida. El target táctil sube a ≥48dp sin
    // engordar la píldora visual (spec 028 A-106).
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            widthFactor: 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                color: selected
                    ? colors.accent.withValues(alpha: 0.16)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? colors.accentHover : colors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Entrada compacta de Temas en Ajustes: muestra una vista previa del tema
/// activo y abre el apartado completo (galería en cuadrícula, Oscuros/Claros).
class _ThemesEntry extends StatefulWidget {
  @override
  State<_ThemesEntry> createState() => _ThemesEntryState();
}

class _ThemesEntryState extends State<_ThemesEntry> {
  Future<void> _open() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ThemesScreen()));
    if (mounted) setState(() {}); // refresca el nombre/preview al volver
  }

  @override
  Widget build(BuildContext context) {
    final root = context.findAncestorStateOfType<HermesAppState>();
    if (root == null) {
      final preset = AppTheme.presetById(AppTheme.defaultThemeId);
      return _buildEntry(
        context,
        activeName: preset.name,
        previewColors: preset.colors,
        total: AppTheme.presets.length,
      );
    }
    return ValueListenableBuilder(
      valueListenable: root.themeProfiles,
      builder: (context, snapshot, _) {
        final presentation = settingsThemePresentation(snapshot);
        return _buildEntry(
          context,
          activeName: presentation.name,
          previewColors: presentation.colors,
          total: presentation.total,
        );
      },
    );
  }

  Widget _buildEntry(
    BuildContext context, {
    required String activeName,
    required HermesThemeColors previewColors,
    required int total,
  }) {
    final colors = Theme.of(context).hermes;
    return InkWell(
      onTap: _open,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Mini-swatch del tema activo (compacto, sin overflow).
            _ThemeSwatch(colors: previewColors),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Strings.of(context).themesTitle,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                      children: [
                        TextSpan(text: Strings.of(context).setActivePrefix),
                        TextSpan(
                          text: activeName,
                          style: TextStyle(
                            color: colors.accentHover,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(
                          text: Strings.of(context).setThemesAvailable(total),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 18, color: colors.textDisabled),
          ],
        ),
      ),
    );
  }
}

/// Swatch compacto del tema: fondo + dot acento + dos barras de texto.
class _ThemeSwatch extends StatelessWidget {
  final HermesThemeColors colors;
  const _ThemeSwatch({required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      width: 84,
      height: 56,
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.divider),
      ),
      padding: const EdgeInsets.all(9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              _bar(c.accent, 30, 4),
            ],
          ),
          const SizedBox(height: 7),
          _bar(c.textPrimary, 54, 4),
          const SizedBox(height: 5),
          _bar(c.textSecondary, 38, 4),
        ],
      ),
    );
  }

  Widget _bar(Color color, double w, double h) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

/// Selector de estilo de fuente global. Un desplegable evita convertir un
/// catálogo amplio en dos o tres filas de chips y mantiene el ajuste integrado
/// con la superficie/colores del tema activo.
class _FontStyleEntry extends StatefulWidget {
  @override
  State<_FontStyleEntry> createState() => _FontStyleEntryState();
}

class _FontStyleEntryState extends State<_FontStyleEntry> {
  String _currentId() {
    final root = context.findAncestorStateOfType<HermesAppState>();
    return root?.fontId.value ?? AppFonts.defaultId;
  }

  Future<void> _select(String id) async {
    final root = context.findAncestorStateOfType<HermesAppState>();
    await root?.setFontId(id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentId();
    final colors = Theme.of(context).hermes;
    return _PrefField(
      title: Strings.of(context).setFontStyle,
      caption: Strings.of(context).setAppliesInstantly,
      child: DropdownButtonFormField<String>(
        key: ValueKey('settings-font-$current'),
        initialValue: AppFonts.byId(current).id,
        isExpanded: true,
        menuMaxHeight: 420,
        dropdownColor: colors.surface,
        borderRadius: BorderRadius.circular(14),
        icon: Icon(
          Icons.keyboard_arrow_down_rounded,
          color: colors.textSecondary,
        ),
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        selectedItemBuilder: (context) => [
          for (final font in AppFonts.all)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                font.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppFonts.resolvedFamily(font),
                  color: colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ),
        ],
        items: [
          for (final font in AppFonts.all)
            DropdownMenuItem(
              value: font.id,
              child: Text(
                font.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppFonts.resolvedFamily(font),
                  color: colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ),
        ],
        onChanged: (id) {
          if (id != null) _select(id);
        },
      ),
    );
  }
}

/// Selector de tamaño de texto global. Mismo patrón/estilo que [_FontStyleEntry]:
/// aplica al instante (reactivo vía `HermesAppState.fontSize` → `MediaQuery
/// .textScaler`) y persiste en SharedPreferences. Afecta a TODA la app a la vez,
/// no pantalla por pantalla.
class _TextSizeEntry extends StatefulWidget {
  @override
  State<_TextSizeEntry> createState() => _TextSizeEntryState();
}

class _TextSizeEntryState extends State<_TextSizeEntry> {
  FontSizeService? _svc() =>
      context.findAncestorStateOfType<HermesAppState>()?.fontSize;

  Future<void> _select(double scale) async {
    await _svc()?.setScale(scale);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = _svc()?.scale ?? 1.0;
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return _PrefField(
      title: strings.setTextSize,
      caption: strings.setAppliesInstantly,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            strings.setTextSizePreview,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14 * current,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Slider(
            key: const ValueKey('text-size-slider'),
            min: FontSizeService.minScale,
            max: FontSizeService.maxScale,
            divisions: FontSizeService.divisions,
            value: FontSizeService.normalize(current),
            label: '${(current * 100).round()} %',
            onChanged: _select,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  strings.setTextSizeSmaller,
                  style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
                Text(
                  strings.setTextSizeStandard,
                  style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
                Text(
                  strings.setTextSizeLarger,
                  style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector de idioma de la app. Mismo patrón/estilo que [_FontStyleEntry]:
/// aplica al instante (reactivo vía `HermesAppState.localeId`) y persiste. Por
/// defecto sigue el idioma del sistema. La migración de textos a i18n es
/// incremental, así que de momento solo cambian los ya traducidos.
class _LanguageEntry extends StatefulWidget {
  @override
  State<_LanguageEntry> createState() => _LanguageEntryState();
}

class _LanguageEntryState extends State<_LanguageEntry> {
  String _currentId() {
    final root = context.findAncestorStateOfType<HermesAppState>();
    return root?.localeId.value ?? AppLocales.defaultId;
  }

  Future<void> _select(String id) async {
    final root = context.findAncestorStateOfType<HermesAppState>();
    await root?.setLocaleId(id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentId();
    return _PrefField(
      title: Strings.of(context).setLanguage,
      caption: Strings.of(context).setLanguageNote,
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final o in AppLocales.all)
            _Choice(
              // "Sistema/System" se localiza; los idiomas concretos se muestran
              // siempre en su nombre nativo (Español, English).
              label: o.id == 'system'
                  ? Strings.of(context).setLanguageSystem
                  : o.label,
              selected: o.id == current,
              onTap: () => _select(o.id),
            ),
        ],
      ),
    );
  }
}

class _VoiceTile extends StatelessWidget {
  const _VoiceTile({required this.connection});

  final SavedConnection connection;

  @override
  Widget build(BuildContext context) {
    return HermesNavRow(
      icon: Icons.record_voice_over_outlined,
      title: Strings.of(context).setVoiceTitle,
      subtitle: Strings.of(context).setVoice,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VoiceSettingsScreen(connection: connection),
        ),
      ),
    );
  }
}

/// Interruptor GLOBAL (no por perfil, a diferencia de todo lo demás en
/// `DockSettingsScreen`): apaga por completo el dock flotante en toda la
/// app. Activado por defecto. Vive aquí, junto al resto de ajustes de
/// apariencia, en vez de dentro de Ajustes › Dock, porque "usar o no dock"
/// es una decisión previa a personalizarlo.
class _UseDockTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final controller = DockPreferencesController.instance;
    return ListenableBuilder(
      listenable: controller.listenable,
      // `Material(type: transparency)`: ver el comentario equivalente en
      // `dock_settings_screen.dart` sobre `HermesGroup` + `HermesSwitchTile`
      // sin un `Material` propio de por medio.
      builder: (context, _) => Material(
        type: MaterialType.transparency,
        child: HermesSwitchTile(
          controlKey: const ValueKey('settings-use-dock'),
          title: strings.settingsUseDockTitle,
          subtitle: strings.settingsUseDockSubtitle,
          value: controller.value.useDock,
          onChanged: (value) => unawaited(controller.setUseDock(value)),
        ),
      ),
    );
  }
}

class _StartupDestinationTile extends StatefulWidget {
  @override
  State<_StartupDestinationTile> createState() =>
      _StartupDestinationTileState();
}

class _StartupDestinationTileState extends State<_StartupDestinationTile> {
  StartupDestination? _destination;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final loaded = await StartupDestinationStore.load();
    if (!mounted) return;
    setState(() => _destination = loaded);
  }

  Future<void> _set(bool openBots) async {
    final next = openBots ? StartupDestination.bots : StartupDestination.home;
    setState(() => _destination = next);
    await StartupDestinationStore.save(next);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Material(
      type: MaterialType.transparency,
      child: HermesSwitchTile(
        controlKey: const ValueKey('settings-startup-bots'),
        title: strings.settingsStartupBotsTitle,
        subtitle: strings.settingsStartupBotsSubtitle,
        value: _destination == StartupDestination.bots,
        onChanged: _destination == null ? null : (v) => unawaited(_set(v)),
      ),
    );
  }
}

class _DockTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return HermesNavRow(
      icon: Icons.dashboard_customize_outlined,
      title: Strings.of(context).dockSettingsTitle,
      subtitle: Strings.of(context).dockSettingsSubtitle,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DockSettingsScreen()),
      ),
    );
  }
}

class _NotificationsTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return HermesNavRow(
      icon: Icons.notifications_active_outlined,
      title: Strings.of(context).setNotifications,
      subtitle: Strings.of(context).setNotificationsSub,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
      ),
    );
  }
}

class _HeaderTitleField extends StatelessWidget {
  Future<void> _edit(BuildContext context, String current) async {
    final colors = Theme.of(context).hermes;
    // showDialog + TextField → pantallazo rojo (_dependents.isEmpty).
    // Se usa ruta dedicada como workaround.
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (ctx) =>
            _HeaderTitleEditScreen(initial: current, colors: colors),
      ),
    );
    if (result == null || !context.mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;
    // Una sola fuente reactiva para la fila y para Home/Sesiones/Chat. Antes
    // Ajustes mantenía una copia en un TextEditingController: la carga async no
    // reconstruía el Text y podía seguir mostrando HERMES CONSOLE aunque la
    // cabecera ya hubiese cambiado correctamente.
    await setHeaderTitle(prefs, result);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ValueListenableBuilder<String>(
      valueListenable: headerTitleNotifier,
      builder: (context, title, _) => InkWell(
        onTap: () => _edit(context, title),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Icon(
                Icons.drive_file_rename_outline_rounded,
                size: 20,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Strings.of(context).setHeaderTitle,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.accentHover,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.edit_outlined, size: 16, color: colors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  const _ConnectionCard({required this.connection, required this.connManager});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return HermesGroup(
      children: [
        // Fila informativa (no navegable): instancia activa + URL.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Icon(Icons.router_outlined, size: 20, color: colors.accentHover),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            connection.label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        if (connection.readOnly) ...[
                          const SizedBox(width: 8),
                          const ReadOnlyBadge(compact: true),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      connection.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        HermesNavRow(
          icon: Icons.lan_outlined,
          title: Strings.of(context).setManageInstances,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GatewayManagerScreen(connManager: connManager),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActiveModelTile extends StatefulWidget {
  final SavedConnection connection;
  const _ActiveModelTile({super.key, required this.connection});

  @override
  State<_ActiveModelTile> createState() => _ActiveModelTileState();
}

class _ActiveModelTileState extends State<_ActiveModelTile> {
  late final DashboardClient _client;
  // null = desconocido: mejor sin subtítulo que un valor congelado.
  String? _model;

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.lazy(widget.connection);
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// Lee el modelo activo real de /api/model/info (la misma fuente que usa el
  /// chat). Antes se leía la pref 'selected_model', que nada escribe, y el
  /// tile mostraba "hermes-agent" para siempre (spec 028 A-022).
  Future<void> _load() async {
    try {
      final info = await _client.getModelInfo();
      if (!mounted) return;
      setState(() => _model = info.model);
    } catch (e) {
      debugPrint('[settings] no se pudo leer el modelo activo: $e');
      if (mounted) setState(() => _model = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HermesNavRow(
      icon: Icons.smart_toy_outlined,
      title: Strings.of(context).setActiveModelLabel,
      subtitle: _model,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ModelsScreen(connection: widget.connection),
        ),
      ).then((_) => _load()),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "Vaciar conversaciones": qué se vacía, y de verdad
// ─────────────────────────────────────────────────────────────────────────────

/// Ámbitos que el usuario puede elegir vaciar.
///
/// Antes la acción era única y SOLO limpiaba el estado local del perfil
/// (borradores, transcripciones, turnos pendientes): las sesiones seguían
/// existiendo en el servidor, así que al refrescar la lista volvían y "no se
/// borraban todas". Además no había forma de elegir entre chats normales y
/// automatizaciones (Cron), que es lo que pedía el mantenedor.
@visibleForTesting
final class HistoryCleanupSelection {
  final bool chats;
  final bool automations;

  const HistoryCleanupSelection({
    required this.chats,
    required this.automations,
  });

  static const HistoryCleanupSelection chatsOnly = HistoryCleanupSelection(
    chats: true,
    automations: false,
  );

  bool get isEmpty => !chats && !automations;

  /// Solo los chats normales son dueños del estado local del perfil
  /// (borradores/transcripciones/outbox son por perfil, no por origen): vaciar
  /// únicamente Cron NO debe arrastrarse el borrador de un chat normal.
  bool get clearsLocalProfileState => chats;

  HistoryCleanupSelection copyWith({bool? chats, bool? automations}) =>
      HistoryCleanupSelection(
        chats: chats ?? this.chats,
        automations: automations ?? this.automations,
      );
}

/// Una sesión cuenta como automatización si Hermes Agent la publica con un
/// origen de automatización o si es un informe programado (`cron_<job>_…`).
/// Se reutiliza el mismo criterio que la biblioteca de conversaciones
/// ([SessionCategoryScope]) para que el filtro "Automatización" de la lista y
/// esta limpieza no puedan discrepar.
@visibleForTesting
bool isAutomationSessionRow(Session session) =>
    session.isJob || AutomationSessionSources.contains(session.source);

/// IDs a borrar en el servidor, hojas primero.
///
/// Un DELETE de la raíz antes que sus continuaciones convierte a la siguiente
/// hija en una sesión principal nueva que reaparece en la lista: ese era otro
/// motivo real de "no se borran todas". Se reutiliza
/// [sessionLineageDeleteOrder] (el mismo orden que usa el borrado de una sola
/// conversación) y se filtra al ámbito elegido, para que elegir solo Cron no
/// arrastre un chat normal ni al contrario.
@visibleForTesting
List<String> historyCleanupDeleteOrder(
  Iterable<Session> sessions,
  HistoryCleanupSelection selection,
) {
  if (selection.isEmpty) return const <String>[];
  final all = sessions.toList(growable: false);
  final selected = all
      .where((session) => !session.isDraftOnly)
      .where(
        (session) => isAutomationSessionRow(session)
            ? selection.automations
            : selection.chats,
      )
      .toList(growable: false);
  final selectedIds = {for (final session in selected) session.id};
  final order = <String>[];
  final seen = <String>{};
  for (final session in selected) {
    final parentId = session.parentSessionId;
    if (parentId != null && parentId.isNotEmpty) continue;
    for (final id in sessionLineageDeleteOrder(session.id, all)) {
      if (selectedIds.contains(id) && seen.add(id)) order.add(id);
    }
  }
  // Una fila elegida cuyo padre ya no publica el servidor no cuelga de
  // ninguna raíz visible: se borra igualmente al final en vez de quedarse
  // para siempre.
  for (final session in selected) {
    if (seen.add(session.id)) order.add(session.id);
  }
  return order;
}

/// Resultado del borrado remoto. `rejected` son sesiones que el servidor
/// respondió OK pero no borró (las recrea un canal activo): se cuentan aparte
/// para no anunciar un éxito que no ocurrió. `skipped` son las filas que ya
/// no se intentaron porque el usuario canceló el lote a mitad.
@visibleForTesting
final class RemoteConversationClearSummary {
  final int deleted;
  final int rejected;
  final int failed;
  final int skipped;
  final bool cancelled;

  const RemoteConversationClearSummary({
    required this.deleted,
    required this.rejected,
    required this.failed,
    this.skipped = 0,
    this.cancelled = false,
  });

  static const RemoteConversationClearSummary none =
      RemoteConversationClearSummary(deleted: 0, rejected: 0, failed: 0);

  int get attempted => deleted + rejected + failed;

  /// Filas que el ámbito elegido seleccionó de verdad. `0` significa que no
  /// había NADA que borrar (no que la operación no se ejecutase): se anuncia,
  /// porque salir en silencio se leía como "no ha pasado nada".
  int get total => attempted + skipped;

  bool get allSucceeded => rejected == 0 && failed == 0 && !cancelled;
}

/// Borra en el servidor, en orden seguro, informando del avance. Cada fila se
/// aísla: un rechazo o un error de red no aborta el resto de la limpieza.
///
/// [isCancelled] se consulta ANTES de emitir cada DELETE: el borrado que ya
/// está en vuelo termina (no se puede deshacer a medias), pero no se empieza
/// ninguno nuevo. Sin este gancho un lote de 200 conversaciones era un viaje
/// sin retorno en cuanto se confirmaba el ámbito.
@visibleForTesting
Future<RemoteConversationClearSummary> clearRemoteConversations({
  required List<String> deleteOrder,
  required Future<bool> Function(String sessionId) deleteSession,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  var deleted = 0;
  var rejected = 0;
  var failed = 0;
  var cancelled = false;
  for (var index = 0; index < deleteOrder.length; index++) {
    if (isCancelled?.call() ?? false) {
      cancelled = true;
      break;
    }
    final result = await deleteRemoteSession(
      deleteOrder[index],
      delete: deleteSession,
    );
    switch (result.status) {
      case RemoteSessionDeleteStatus.deleted:
        deleted += 1;
      case RemoteSessionDeleteStatus.rejected:
        rejected += 1;
      case RemoteSessionDeleteStatus.failed:
        failed += 1;
    }
    onProgress?.call(index + 1, deleteOrder.length);
  }
  return RemoteConversationClearSummary(
    deleted: deleted,
    rejected: rejected,
    failed: failed,
    skipped: deleteOrder.length - (deleted + rejected + failed),
    cancelled: cancelled,
  );
}

/// Elección explícita de ámbito antes de vaciar. Pública para poder blindarla
/// con widget tests sin levantar toda la pantalla de Ajustes.
@visibleForTesting
class HistoryCleanupScopeDialog extends StatefulWidget {
  const HistoryCleanupScopeDialog({
    this.initial = HistoryCleanupSelection.chatsOnly,
    super.key,
  });

  final HistoryCleanupSelection initial;

  @override
  State<HistoryCleanupScopeDialog> createState() =>
      _HistoryCleanupScopeDialogState();
}

class _HistoryCleanupScopeDialogState extends State<HistoryCleanupScopeDialog> {
  late HistoryCleanupSelection _selection = widget.initial;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return AlertDialog(
      title: Text(s.setClearConvos),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            key: const ValueKey('history-cleanup-scope-chats'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _selection.chats,
            title: Text(s.slFilterAll),
            onChanged: (value) => setState(
              () => _selection = _selection.copyWith(chats: value ?? false),
            ),
          ),
          CheckboxListTile(
            key: const ValueKey('history-cleanup-scope-automations'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _selection.automations,
            title: Text(s.slFilterAutomation),
            subtitle: Text(
              s.slFilterReports,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
            onChanged: (value) => setState(
              () =>
                  _selection = _selection.copyWith(automations: value ?? false),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.commonCancel),
        ),
        TextButton(
          key: const ValueKey('history-cleanup-scope-confirm'),
          onPressed: _selection.isEmpty
              ? null
              : () => Navigator.pop(context, _selection),
          child: Text(s.commonDelete, style: TextStyle(color: colors.error)),
        ),
      ],
    );
  }
}

@visibleForTesting
class HistoryCleanupSection extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  final Future<bool> Function()? verifyHistoryCleanupForTesting;

  /// Cliente del Gateway con el que se borran las sesiones del servidor. Solo
  /// se inyecta en tests; en producción se construye (y se cierra) por cada
  /// limpieza a partir de la instancia activa.
  final ApiClient? remoteClientOverride;

  const HistoryCleanupSection({
    required this.connection,
    required this.connManager,
    this.verifyHistoryCleanupForTesting,
    @visibleForTesting this.remoteClientOverride,
    super.key,
  });

  @override
  State<HistoryCleanupSection> createState() => _HistoryCleanupSectionState();
}

class _HistoryCleanupSectionState extends State<HistoryCleanupSection> {
  bool _clearingNormal = false;
  // Avance del borrado remoto (filas borradas / total): el usuario veía solo
  // un spinner sin saber si estaba pasando algo.
  int _remoteDone = 0;
  int _remoteTotal = 0;
  // Cancelación pedida por el usuario sobre el lote en curso.
  bool _cancelRequested = false;

  /// Aviso de que la limpieza terminó SIN hacer nada y por qué.
  ///
  /// Varias salidas anticipadas (instancia cambiada, ámbito sin filas)
  /// devolvían sin decir absolutamente nada: el mantenedor tocaba "vaciar",
  /// no pasaba nada y no había explicación posible en pantalla.
  void _showCleanupNotice(String message) {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  String _summaryMessage(
    Strings s,
    LocalConversationClearSummary? result,
    RemoteConversationClearSummary remote,
  ) {
    final parts = <String>[];
    if (remote.cancelled) {
      // Cancelado a mitad: lo primero que hay que decir es cuántas se
      // borraron ya y cuántas se han quedado donde estaban.
      parts.add(s.chaStatusCancelled);
      parts.add(
        s.crnCleanupPartial(
          remote.deleted,
          remote.skipped + remote.rejected + remote.failed,
        ),
      );
    } else if (remote.total == 0) {
      // Cero filas en el ámbito elegido. Antes esto se anunciaba como
      // "0 conversaciones borradas" (o se tapaba con el recuento local) y se
      // leía como un fallo mudo.
      parts.add(s.slEmptyFilter);
    } else {
      if (remote.deleted > 0) parts.add(s.setConvosCleared(remote.deleted));
      if (remote.rejected > 0 || remote.failed > 0) {
        parts.add(
          s.crnCleanupPartial(remote.deleted, remote.rejected + remote.failed),
        );
      }
    }
    if (result != null) {
      if (result.transcripts.removed > 0) {
        parts.add(s.setLocalConvosCleared(result.transcripts.removed));
      }
      parts.add(s.setDraftsCleared(result.drafts.removed));
      if (result.outbox.removed > 0) {
        parts.add(s.setPendingTurnsCleared(result.outbox.removed));
      }
      if (result.localFailureCount > 0) {
        parts.add(s.setLocalClearFailures(result.localFailureCount));
      }
    }
    if (parts.isEmpty) parts.add(s.setConvosCleared(0));
    return parts.join(' · ');
  }

  Future<bool> Function() _captureHistoryCleanupVerifier() {
    final override = widget.verifyHistoryCleanupForTesting;
    if (override != null) return override;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    final reason = Strings.of(context).setVerifyToClear;
    return () => lock == null
        ? Future<bool>.value(true)
        : LockScreen.verify(context, lock, reason: reason);
  }

  Future<bool> _authorizeHistoryCleanup({
    required SavedConnection targetConnection,
    required Future<bool> Function() verifier,
  }) async {
    final allowed = await authorizeHistoryCleanup(
      readOnly: targetConnection.readOnly,
      verifyAppLock: verifier,
    );
    if (!mounted) return false;
    // La instancia activa cambió mientras se pedía App Lock: no se toca la
    // instancia nueva, pero se DICE, en vez de no hacer nada en silencio.
    if (widget.connection.id != targetConnection.id) {
      _showCleanupNotice(_connectionLostMessage());
      return false;
    }
    if (!allowed && targetConnection.readOnly) {
      showReadOnlyNotice(context);
    }
    return allowed;
  }

  /// "No se pudo vaciar: sin conexión con el gateway". Cubre las dos formas
  /// reales de perder el destino a mitad de la operación: cambiar de instancia
  /// activa y quedarse sin el gateway con el que se empezó.
  String _connectionLostMessage() {
    final s = Strings.of(context);
    return s.setClearError(s.slNoGateway);
  }

  /// Corta el lote en curso. El DELETE en vuelo termina; los siguientes no se
  /// emiten y el resumen cuenta solo lo que se borró de verdad.
  void _requestCancelNormal() {
    if (!_clearingNormal || _cancelRequested) return;
    setState(() => _cancelRequested = true);
  }

  /// Borra en el SERVIDOR las conversaciones del ámbito elegido.
  ///
  /// Esta es la mitad que faltaba: la acción solo limpiaba el estado local del
  /// perfil, así que las sesiones seguían en el servidor y volvían a aparecer
  /// en la lista al refrescar ("no se suelen eliminar todas"). Se pide
  /// `includeChildren` porque el servidor pliega las continuaciones dentro de
  /// su padre y, sin verlas, quedaban huérfanas y reaparecían como filas
  /// principales nuevas.
  Future<RemoteConversationClearSummary> _clearRemote({
    required SavedConnection targetConnection,
    required String targetProfile,
    required HistoryCleanupSelection selection,
  }) async {
    final override = widget.remoteClientOverride;
    final client =
        override ??
        ApiClient(
          baseUrl: targetConnection.baseUrl,
          apiKey: targetConnection.apiKey,
          connectionId: targetConnection.id,
        );
    try {
      final sessions = await client.getSessions(
        includeChildren: true,
        profile: targetProfile,
      );
      final order = historyCleanupDeleteOrder(sessions, selection);
      if (order.isEmpty) return RemoteConversationClearSummary.none;
      if (mounted) {
        setState(() {
          _remoteDone = 0;
          _remoteTotal = order.length;
        });
      }
      return await clearRemoteConversations(
        deleteOrder: order,
        deleteSession: (sessionId) =>
            client.deleteSession(sessionId, profile: targetProfile),
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _remoteDone = done;
            _remoteTotal = total;
          });
        },
        // Cancelar desde la propia fila: mientras el lote avanza, el botón
        // de la fila levanta esta bandera y el bucle deja de emitir DELETEs.
        isCancelled: () => _cancelRequested || !mounted,
      );
    } finally {
      if (override == null) client.close();
    }
  }

  Future<void> _clearNormal() async {
    if (_clearingNormal) return;
    final targetConnection = widget.connection;
    final targetProfile = Session.profileOwner(
      widget.connManager.activeProfileFor(targetConnection.id),
    );
    final verifier = _captureHistoryCleanupVerifier();
    setState(() {
      _clearingNormal = true;
      _cancelRequested = false;
    });

    try {
      if (!await _authorizeHistoryCleanup(
        targetConnection: targetConnection,
        verifier: verifier,
      )) {
        return;
      }
      if (!mounted) return;
      // Elección explícita de ámbito: chats normales, automatizaciones (Cron)
      // o ambos. Antes la acción era única y Cron quedaba siempre fuera.
      final selection = await showDialog<HistoryCleanupSelection>(
        context: context,
        builder: (_) => const HistoryCleanupScopeDialog(),
      );
      if (!mounted) return;
      // Cancelar en el diálogo (o no elegir ámbito) es una decisión del
      // usuario: se sale sin ruido. Perder la instancia destino NO lo es.
      if (selection == null || selection.isEmpty) return;
      if (widget.connection.id != targetConnection.id) {
        _showCleanupNotice(_connectionLostMessage());
        return;
      }

      final remote = await _clearRemote(
        targetConnection: targetConnection,
        targetProfile: targetProfile,
        selection: selection,
      );
      if (!mounted) return;
      // La instancia activa cambió DESPUÉS de haber borrado en el servidor:
      // antes se salía aquí en silencio, sin invalidar la lista y sin decir
      // cuántas se habían borrado ya. Ese es el "no se eliminaron, no sé qué
      // ocurre": el borrado sí había pasado, pero nadie lo contaba. Ahora se
      // informa y se invalida igual, y solo se omite la parte local (que
      // pertenece al perfil de la instancia que ya no está en pantalla).
      final connectionChanged = widget.connection.id != targetConnection.id;
      if (connectionChanged) {
        if (remote.deleted > 0) {
          historyCleanupInvalidations.publish(
            connectionId: targetConnection.id,
            scope: HistoryCleanupScope.normalConversations,
          );
        }
        final s = Strings.of(context);
        _showCleanupNotice(
          '${_connectionLostMessage()} · ${s.setConvosCleared(remote.deleted)}',
        );
        return;
      }

      LocalConversationClearSummary? result;
      // Cancelado a mitad: NO se arrastra además el estado local del perfil.
      // Pedir parar tiene que parar todo lo que no se haya hecho ya.
      if (selection.clearsLocalProfileState && !remote.cancelled) {
        result = await clearProfileLocalConversationState(
          connectionId: targetConnection.id,
          profile: targetProfile,
          clearDrafts: ({required String profile}) async {
            final prefs = await SharedPreferences.getInstance();
            return ChatDraftStore(
              prefs,
            ).deleteForProfile(targetConnection.id, profile);
          },
          clearTranscripts: ({required String profile}) =>
              LocalTranscriptStore.deleteForProfile(
                targetConnection.id,
                profile,
              ),
          clearOutbox: ({required String profile}) =>
              TurnOutboxStore().deleteForProfile(targetConnection.id, profile),
          clearGlobalActivity:
              ({required String connectionId, required String profile}) async {
                final aggregate = context
                    .findAncestorStateOfType<HermesAppState>()
                    ?.activeChats
                    .globalActivity;
                aggregate?.clearProfile(connectionId, profile);
                await aggregate?.flushJournal();
              },
        );
      }
      if (!mounted) return;
      if ((result?.hasChanges ?? false) || remote.deleted > 0) {
        historyCleanupInvalidations.publish(
          connectionId: targetConnection.id,
          scope: HistoryCleanupScope.normalConversations,
        );
      }
      final allSucceeded =
          (result?.allSucceeded ?? true) && remote.allSucceeded;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(_summaryMessage(Strings.of(context), result, remote)),
          duration: Duration(seconds: allSucceeded ? 3 : 5),
        ),
      );
    } catch (e) {
      // Las fuentes locales se aíslan dentro del coordinador; este fallback
      // cubre el listado/borrado remoto y los fallos al preparar la operación.
      if (!mounted) return;
      final s = Strings.of(context);
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.setClearError(localizedApiError(s, e)))),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _clearingNormal = false;
          _cancelRequested = false;
          _remoteDone = 0;
          _remoteTotal = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return HistoryCleanupActionList(
      readOnly: widget.connection.readOnly,
      clearingNormal: _clearingNormal,
      onClearNormal: _clearNormal,
      remoteProgress: _remoteTotal == 0
          ? null
          : (done: _remoteDone, total: _remoteTotal),
      // Solo se ofrece cancelar cuando hay un lote remoto en vuelo y todavía
      // queda algo por emitir. Tras pedirlo, el botón desaparece (el DELETE en
      // curso ya no se puede parar) y vuelve el spinner.
      onCancelNormal: _clearingNormal && _remoteTotal > 0 && !_cancelRequested
          ? _requestCancelNormal
          : null,
    );
  }
}

@visibleForTesting
class HistoryCleanupActionList extends StatelessWidget {
  final bool readOnly;
  final bool clearingNormal;
  final VoidCallback onClearNormal;

  /// Filas borradas / total mientras la limpieza remota está en curso. Null
  /// cuando no hay borrado remoto en marcha.
  final ({int done, int total})? remoteProgress;

  /// Corta el lote en curso. Null cuando no hay nada que cancelar.
  final VoidCallback? onCancelNormal;

  const HistoryCleanupActionList({
    required this.readOnly,
    required this.clearingNormal,
    required this.onClearNormal,
    this.remoteProgress,
    this.onCancelNormal,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return HermesGroup(
      children: [
        _HistoryCleanupActionRow(
          actionKey: const ValueKey('history-cleanup-normal'),
          icon: Icons.forum_outlined,
          title: s.setClearConvos,
          // La acción ahora PREGUNTA qué vaciar: el subtítulo anuncia la
          // elección en vez de prometer que Cron se conserva siempre.
          subtitle: '${s.slFilterAll} · ${s.slFilterAutomation}',
          busy: clearingNormal,
          progress: remoteProgress,
          onCancel: onCancelNormal,
          onTap: readOnly || clearingNormal ? null : onClearNormal,
        ),
      ],
    );
  }
}

class _HistoryCleanupActionRow extends StatelessWidget {
  final Key actionKey;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool busy;
  final VoidCallback? onTap;

  /// Avance determinista de una operación por lotes (filas hechas / total).
  final ({int done, int total})? progress;

  /// Corta el lote en curso. Solo se pinta mientras [progress] está activo:
  /// es el único momento en el que queda algo por emitir que se pueda parar.
  final VoidCallback? onCancel;
  // true (por defecto) conserva el tinte error de las acciones de borrado de
  // historial; false lo usa como fila de mantenimiento neutra (p. ej.
  // limpiar datos huérfanos), sin sonar tan alarmante como "eliminar".
  final bool destructive;

  const _HistoryCleanupActionRow({
    required this.actionKey,
    required this.icon,
    required this.title,
    required this.busy,
    required this.onTap,
    this.subtitle,
    this.progress,
    this.onCancel,
    this.destructive = true,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final foreground = onTap == null
        ? colors.textDisabled
        : (destructive ? colors.error : colors.textPrimary);
    final showProgress = progress != null && progress!.total > 0;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: actionKey,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            // El avance NO va dentro de la columna de texto: creciendo ahí
            // hacía que el `Row` (alineado al centro) recolocara el icono de
            // la izquierda y el spinner de la derecha respecto al título, y la
            // fila se veía descuadrada frente a sus vecinas del grupo.
            // Aquí la fila icono/título/trailing conserva EXACTAMENTE su
            // geometría de reposo y el avance se añade como una banda debajo.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // La banda de avance se suma a la altura del grupo, así que
                // la fila icono/título necesita su propio alto mínimo (64 del
                // `ConstrainedBox` menos los 11+11 de padding): sin él el
                // bloque de texto se recolocaba unos píxeles al aparecer y
                // desaparecer la banda.
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 42),
                  child: Row(
                    children: [
                      Icon(icon, size: 21, color: foreground),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                color: foreground,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle!,
                                style: TextStyle(
                                  color: onTap == null
                                      ? colors.textDisabled
                                      : colors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // El trailing mantiene su ancho en los tres estados
                      // (chevron 19 / spinner 20): cancelar vive en la banda
                      // de avance, así el texto no se reflowea al arrancar.
                      if (busy)
                        const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(Icons.chevron_right, size: 19, color: foreground),
                    ],
                  ),
                ),
                // Crecer de golpe y encogerse de golpe al terminar era la otra
                // mitad del descuadre: la sección entera saltaba.
                AnimatedSize(
                  duration: Motion.duration(context, Motion.base),
                  curve: Motion.size,
                  alignment: Alignment.topCenter,
                  child: !showProgress
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            children: [
                              // Barra real de avance: un spinner no dice si un
                              // lote de 200 va por la 3 o por la 190.
                              Expanded(
                                child: ClipRRect(
                                  key: const ValueKey(
                                    'history-cleanup-progress',
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    minHeight: 4,
                                    value: progress!.done / progress!.total,
                                    backgroundColor: colors.divider,
                                    color: colors.accent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '${progress!.done}/${progress!.total}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.textSecondary,
                                ),
                              ),
                              if (onCancel != null)
                                IconButton(
                                  key: const ValueKey('history-cleanup-cancel'),
                                  icon: Icon(
                                    Icons.close,
                                    size: 16,
                                    color: colors.textSecondary,
                                  ),
                                  // Objetivo táctil real de 44dp aunque el
                                  // icono visible sea de 16dp.
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 44,
                                    minHeight: 44,
                                  ),
                                  tooltip: s.commonCancel,
                                  onPressed: onCancel,
                                )
                              else
                                // El hueco del botón se reserva igual: al
                                // aceptarse la cancelación la banda no puede
                                // encogerse de golpe.
                                const SizedBox.square(dimension: 44),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OrphanDataTile extends StatefulWidget {
  final ConnectionManager connManager;
  const _OrphanDataTile({required this.connManager});

  @override
  State<_OrphanDataTile> createState() => _OrphanDataTileState();
}

class _OrphanDataTileState extends State<_OrphanDataTile> {
  bool _cleaning = false;

  Future<void> _clean() async {
    setState(() => _cleaning = true);
    try {
      final removed = await widget.connManager.pruneOrphanData();
      if (!mounted) return;
      final s = Strings.of(context);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            removed == 0 ? s.secNoOrphans : s.secOrphansRemoved(removed),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).secCleanFailed(e.toString())),
        ),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fila compacta coherente con el resto de la pantalla en vez de un
    // ListTile genérico: reutiliza _HistoryCleanupActionRow.
    return HermesPanel(
      child: _HistoryCleanupActionRow(
        actionKey: const ValueKey('orphan-data-clean'),
        icon: Icons.cleaning_services_outlined,
        title: Strings.of(context).secOrphanTitle,
        subtitle: Strings.of(context).secOrphanSubtitle,
        busy: _cleaning,
        onTap: _cleaning ? null : _clean,
        destructive: false,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "Actualizar Hermes": progreso real y confirmación honesta
// ─────────────────────────────────────────────────────────────────────────────

/// Fases observables de una actualización de Hermes.
@visibleForTesting
enum HermesUpdateStep {
  /// POST /api/hermes/update en vuelo.
  requesting,

  /// El servidor aceptó la orden y está ejecutando `hermes update`.
  applying,

  /// El gateway dejó de responder: se está reiniciando.
  restarting,

  /// El gateway volvió; se comprueba si la versión nueva está viva.
  verifying,

  /// Versión nueva confirmada.
  done,

  /// El servidor recibió la orden pero la app no pudo probar la versión nueva.
  unverified,
}

/// Ventana durante la que se insiste en PROBAR que la versión cambió antes de
/// conformarse con "el POST devolvió 2xx".
@visibleForTesting
const Duration hermesUpdateVerifyGrace = Duration(seconds: 45);

/// Estado del indicador de progreso de la actualización.
@visibleForTesting
final class HermesUpdateProgress {
  final HermesUpdateStep step;
  final int elapsedSeconds;

  const HermesUpdateProgress({required this.step, this.elapsedSeconds = 0});

  /// Pasos que se pintan como recorrido (los terminales no añaden un paso).
  static const List<HermesUpdateStep> track = <HermesUpdateStep>[
    HermesUpdateStep.requesting,
    HermesUpdateStep.applying,
    HermesUpdateStep.restarting,
    HermesUpdateStep.verifying,
  ];

  int get totalSteps => track.length;

  int get stepNumber => switch (step) {
    HermesUpdateStep.requesting => 1,
    HermesUpdateStep.applying => 2,
    HermesUpdateStep.restarting => 3,
    HermesUpdateStep.verifying => 4,
    HermesUpdateStep.done || HermesUpdateStep.unverified => track.length,
  };

  double get fraction => stepNumber / totalSteps;

  bool get finished =>
      step == HermesUpdateStep.done || step == HermesUpdateStep.unverified;

  /// Etiqueta del paso. Reutiliza los textos ya traducidos del flujo de
  /// actualización/reinicio para no inventar copy sin traducir.
  String label(Strings s) => switch (step) {
    HermesUpdateStep.requesting => s.setUpdateHermes,
    HermesUpdateStep.applying => s.setUpdateStarted,
    HermesUpdateStep.restarting => s.setGatewayRestarting,
    HermesUpdateStep.verifying => s.setCheckingStatus,
    HermesUpdateStep.done => s.setHermesUpdated,
    HermesUpdateStep.unverified => s.setUpdateUnconfirmed,
  };
}

/// Veredicto de una pasada de sondeo tras pedir la actualización.
@visibleForTesting
enum HermesUpdateVerdict { keepWaiting, confirmed, unverified }

/// Decide si una lectura de `/api/status` PRUEBA que la actualización se
/// aplicó.
///
/// Bug que arregla: bastaba con que el POST devolviese 2xx
/// (`responseConfirmed`) para que la PRIMERA lectura del estado —a los 3 s,
/// con el gateway todavía en la versión anterior— se diese por buena. La app
/// anunciaba "Hermes actualizado a vX" con la versión VIEJA y, al saltarse por
/// completo el `checkUpdate` de verificación, una actualización que no se
/// había aplicado quedaba como un éxito. Ahora la confirmación exige
/// evidencia: la versión cambió, o el propio servidor dice que ya no hay
/// actualización pendiente.
@visibleForTesting
HermesUpdateVerdict classifyHermesUpdatePoll({
  required bool gatewayRunning,
  required String previousVersion,
  required String observedVersion,
  required bool? updateStillAvailable,
  required bool responseConfirmed,
  required Duration elapsed,
  Duration graceWindow = hermesUpdateVerifyGrace,
}) {
  if (!gatewayRunning) return HermesUpdateVerdict.keepWaiting;
  final versionChanged =
      previousVersion.isNotEmpty &&
      observedVersion.isNotEmpty &&
      observedVersion != previousVersion;
  if (versionChanged || updateStillAvailable == false) {
    return HermesUpdateVerdict.confirmed;
  }
  // Sin evidencia: si el servidor confirmó la orden no tiene sentido esperar
  // los 3 minutos completos, pero tampoco se anuncia como aplicada.
  if (responseConfirmed && elapsed >= graceWindow) {
    return HermesUpdateVerdict.unverified;
  }
  return HermesUpdateVerdict.keepWaiting;
}

/// Indicador de progreso real (barra + paso n/N), no un spinner: el usuario
/// no tenía forma de saber si "Actualizar Hermes" estaba haciendo algo.
@visibleForTesting
class HermesUpdateProgressPanel extends StatelessWidget {
  const HermesUpdateProgressPanel({required this.progress, super.key});

  final HermesUpdateProgress progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final tone = switch (progress.step) {
      HermesUpdateStep.done => colors.success,
      HermesUpdateStep.unverified => colors.warning,
      _ => colors.accent,
    };
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    progress.step == HermesUpdateStep.done
                        ? Icons.check_circle_outline
                        : progress.step == HermesUpdateStep.unverified
                        ? Icons.help_outline_rounded
                        : Icons.system_update_alt,
                    size: 18,
                    color: tone,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      progress.label(s),
                      style: TextStyle(fontSize: 13, color: colors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${progress.stepNumber}/${progress.totalSteps}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                key: const ValueKey('hermes-update-progress-bar'),
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  minHeight: 5,
                  value: progress.fraction,
                  backgroundColor: colors.divider,
                  color: tone,
                ),
              ),
              if (!progress.finished) ...[
                const SizedBox(height: 6),
                Text(
                  '${progress.elapsedSeconds}s',
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Tarjeta de actualización de Hermes (hermes update vía Dashboard API).
/// Muestra versión actual y, si hay update, permite aplicarla con doble
/// Sección de mantenimiento del servidor: diagnóstico (estado real vía
/// /api/status), actualización de Hermes (un único flujo claro) y reinicio
/// del gateway como acción separada. Lectura segura; las acciones mutantes
/// (actualizar / reiniciar) piden confirmación explícita + App Lock.
class _MaintenanceSection extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  const _MaintenanceSection({
    super.key,
    required this.connection,
    required this.connManager,
  });

  @override
  State<_MaintenanceSection> createState() => _MaintenanceSectionState();
}

class _MaintenanceSectionState extends State<_MaintenanceSection> {
  late SavedConnection _connection;
  late DashboardClient _client;
  bool _loading = true;
  bool _busy = false; // actualizar o reiniciar en curso
  String? _error;
  Map<String, dynamic>? _status; // /api/status
  Map<String, dynamic>? _update; // /api/hermes/update/check
  HermesUpdatePresentation? _updateFailure;
  bool _hermesAutoUpdate = false; // toggle de auto-actualización de Hermes
  bool _waitingGateway = false; // esperando que el gateway vuelva tras reinicio
  HermesUpdateProgress? _updateProgress; // progreso real de "Actualizar Hermes"

  bool _requiresDashboardAccess(Object error) {
    if (error is DashboardHttpException) {
      return error.statusCode == 401 || error.statusCode == 403;
    }
    if (error is! DashboardAuthException) return false;
    return error.code != DashboardAuthFailureCode.rateLimited &&
        error.code != DashboardAuthFailureCode.loginFailed;
  }

  @override
  void initState() {
    super.initState();
    _connection = widget.connection;
    _client = DashboardClient.lazy(_connection);
    BridgeUpdateService.hermesAutoUpdateEnabled().then((v) {
      if (mounted) setState(() => _hermesAutoUpdate = v);
    });
    _refresh();
    // Actualización lanzada antes de salir de Ajustes y aún sin resultado:
    // se retoma su progreso en vez de ofrecer lanzar otra.
    final pending = HermesUpdateSession.of(_connection.id);
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_presentHermesUpdate(pending));
      });
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// Lee `/api/status` (PÚBLICO) directo, sin pasar por la sesión del Dashboard.
  /// Devuelve null si no responde. Permite ver el estado del servidor aunque el
  /// Dashboard tenga su propio login.
  Future<Map<String, dynamic>?> _publicServerStatus() async {
    try {
      final base = _connection.effectiveDashboardUrl.replaceAll(
        RegExp(r'/+$'),
        '',
      );
      final res = await http
          .get(Uri.parse(TransportPrivacy.requireAllowed('$base/api/status')))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      return data is Map<String, dynamic> ? data : null;
    } catch (e) {
      debugPrint('[settings] status unavailable (${e.runtimeType})');
      return null;
    }
  }

  Future<void> _refresh({bool forceUpdate = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _updateFailure = null;
    });
    try {
      // El estado es lo crítico; el check de update es best-effort.
      Map<String, dynamic> status;
      try {
        status = await _client.getServerStatus();
      } catch (e) {
        // `getServerStatus` pasa por la sesión del Dashboard (que puede tener su
        // propio login). Pero `/api/status` es PÚBLICO: lo leemos directo para
        // ver el estado (versión, gateway, si hay update) aunque el login del
        // dashboard no esté disponible.
        final pub = await _publicServerStatus();
        if (pub == null) rethrow;
        status = pub;
      }
      Map<String, dynamic>? update;
      HermesUpdatePresentation? updateFailure;
      try {
        update = await _client.checkUpdate(force: forceUpdate);
      } catch (e) {
        debugPrint(
          '[settings] no se pudo comprobar actualización de Hermes: $e',
        );
        update = null;
        final fallbackVersion = (status['version'] ?? '—').toString();
        if (_requiresDashboardAccess(e)) {
          updateFailure = HermesUpdatePresentation.dashboardAccessRequired(
            fallbackVersion: fallbackVersion,
          );
        } else if (e is! DashboardHttpException || e.statusCode != 404) {
          updateFailure = HermesUpdatePresentation.checkFailed(
            fallbackVersion: fallbackVersion,
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _update = update;
        _updateFailure = updateFailure;
        _loading = false;
      });
      _maybeAutoUpdateHermes();
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _error = s.contains('401')
            ? Strings.of(context).setDashTokenNote
            : s.contains('SocketException') || s.contains('timed out')
            ? Strings.of(context).setServerUnreachable
            : Strings.of(context).setStatusCheckError;
        _loading = false;
      });
    }
  }

  Future<void> _configureDashboardAccess() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => InstanceEditScreen(
          connManager: widget.connManager,
          initial: _connection,
        ),
      ),
    );
    if (!mounted) return;

    SavedConnection? refreshed;
    for (final connection in widget.connManager.getConnections()) {
      if (connection.id == _connection.id) {
        refreshed = connection;
        break;
      }
    }
    if (refreshed != null) _connection = refreshed;
    _client.close();
    _client = DashboardClient.lazy(_connection);
    await _refresh(forceUpdate: true);
  }

  Future<bool> _confirmLock(String reason) async {
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock != null && lock.enabled) {
      final ok = await LockScreen.verify(context, lock, reason: reason);
      if (!ok) return false;
    }
    return true;
  }

  /// Tras una actualización/reinicio, el gateway se cae unos segundos. En vez de
  /// un delay fijo (que dejaba la app pillada), sondeamos `/api/status` (público)
  /// con reintentos hasta que vuelva a estar "running", mostrando un estado
  /// "reiniciando". Así el corte no se nota y la app se recupera sola.
  ///
  /// Con [waitForUpdate] la vuelta del gateway NO basta: hay que probar que la
  /// versión nueva está viva (ver [classifyHermesUpdatePoll]). Cada pasada
  /// publica además el paso actual en [_updateProgress].
  Future<bool> _waitForGatewayBack({
    Duration timeout = const Duration(minutes: 3),
    bool waitForUpdate = false,
    bool updateResponseConfirmed = false,
    String previousVersion = '',
  }) async {
    if (mounted) setState(() => _waitingGateway = true);
    final started = DateTime.now();
    final deadline = started.add(timeout);
    var confirmed = false;
    try {
      while (mounted && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 3));
        if (!mounted) break;
        Map<String, dynamic>? status;
        try {
          status = await _publicServerStatus();
        } catch (_) {
          // gateway aún reiniciando: seguimos esperando sin romper.
          status = null;
        }
        final running =
            status != null &&
            (status['gateway_running'] == true ||
                status['gateway_state'] == 'running');
        if (!running) {
          if (waitForUpdate) {
            _publishUpdateStep(HermesUpdateStep.restarting, started);
          }
          continue;
        }
        if (!waitForUpdate) {
          confirmed = true;
          if (mounted) setState(() => _status = status);
          break;
        }
        _publishUpdateStep(HermesUpdateStep.verifying, started);
        final observedVersion = (status['version'] ?? '').toString().trim();
        final versionChanged =
            previousVersion.isNotEmpty &&
            observedVersion.isNotEmpty &&
            observedVersion != previousVersion;
        // Se verifica SIEMPRE que no haya cambio de versión, también cuando el
        // POST devolvió 2xx: ese atajo era justo lo que dejaba pasar una
        // actualización no aplicada como un éxito.
        bool? updateStillAvailable;
        if (!versionChanged) {
          try {
            final check = await _client.checkUpdate(force: true);
            final available = check['update_available'];
            updateStillAvailable = available is bool ? available : null;
          } catch (_) {
            // El Dashboard puede estar rotando su sesión durante el reinicio:
            // sin dato, se sigue esperando en vez de afirmar nada.
            updateStillAvailable = null;
          }
        }
        final verdict = classifyHermesUpdatePoll(
          gatewayRunning: true,
          previousVersion: previousVersion,
          observedVersion: observedVersion,
          updateStillAvailable: updateStillAvailable,
          responseConfirmed: updateResponseConfirmed,
          elapsed: DateTime.now().difference(started),
        );
        if (verdict == HermesUpdateVerdict.confirmed) {
          confirmed = true;
          if (mounted) setState(() => _status = status);
          break;
        }
        if (verdict == HermesUpdateVerdict.unverified) break;
      }
    } finally {
      if (mounted) setState(() => _waitingGateway = false);
      if (mounted) await _refresh(forceUpdate: waitForUpdate);
    }
    return confirmed;
  }

  void _publishUpdateStep(HermesUpdateStep step, DateTime started) {
    if (!mounted) return;
    setState(() {
      _updateProgress = HermesUpdateProgress(
        step: step,
        elapsedSeconds: DateTime.now().difference(started).inSeconds,
      );
    });
  }

  bool _hermesAutoTriggered = false;

  /// Fuentes de datos para seguir la actualización. Usan un cliente propio
  /// (no el de la pantalla) porque la sesión sobrevive a este widget.
  HermesUpdateProbes _updateProbes(HermesUpdateSession session) {
    final connection = _connection;
    final client = DashboardClient.lazy(connection);
    session.result.whenComplete(client.close);
    Future<Map<String, dynamic>?> publicStatus() async {
      try {
        final base = connection.effectiveDashboardUrl.replaceAll(
          RegExp(r'/+$'),
          '',
        );
        final res = await http
            .get(Uri.parse(TransportPrivacy.requireAllowed('$base/api/status')))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) return null;
        final data = jsonDecode(res.body);
        return data is Map<String, dynamic> ? data : null;
      } catch (_) {
        return null;
      }
    }

    return HermesUpdateProbes(
      actionStatus: () async {
        try {
          return await client.getUpdateActionStatus();
        } on DashboardHttpException catch (e) {
          if (e.statusCode == 404) throw const HermesUpdateEndpointMissing();
          rethrow;
        }
      },
      serverStatus: publicStatus,
      updateStillAvailable: () async {
        try {
          final check = await client.checkUpdate(force: true);
          final available = check['update_available'];
          return available is bool ? available : null;
        } catch (_) {
          return null;
        }
      },
    );
  }

  /// Si el toggle de auto-actualización de Hermes está activo y hay una versión
  /// nueva, la aplica automáticamente (una vez por carga de pantalla). No aplica
  /// al agente local.
  Future<void> _maybeAutoUpdateHermes() async {
    if (_hermesAutoTriggered) return;
    if (_busy || HermesUpdateSession.isActive(widget.connection.id)) return;
    if (_update?['update_available'] != true) return;
    if (widget.connection.onDeviceLoopback) return;
    // Instancia solo-lectura: la auto-actualización se salta en silencio.
    if (widget.connection.readOnly) return;
    if (!await BridgeUpdateService.hermesAutoUpdateEnabled()) return;
    if (!mounted) return;
    // Con App Lock activo, aplicar en auto lanzaría una pantalla de desbloqueo
    // que el usuario no pidió: esta pasada se salta en silencio y la
    // actualización queda disponible como acción manual (spec 028 A-023).
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock != null && lock.enabled) return;
    _hermesAutoTriggered = true;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).setUpdatingHermesAuto)),
    );
    await _applyUpdate(auto: true);
  }

  Future<void> _applyUpdate({bool auto = false}) async {
    // Acción mutante: respeta el modo solo-lectura, como "Borrar
    // conversaciones" (spec 028 A-024). En auto no hay gesto del usuario al
    // que responder, así que se salta sin aviso.
    if (widget.connection.readOnly) {
      if (!auto) showReadOnlyNotice(context);
      return;
    }
    final colors = Theme.of(context).hermes;
    // El agente local NO se actualiza por el endpoint del dashboard
    // (`hermes update`): en el dispositivo ese flujo reinstala el perfil amplio
    // `.[termux-all]` server-side, tarda muchísimo y devuelve 500 dejando la
    // instalación a medias (lo que luego rompía al reparar). Para local,
    // redirigimos a la vía robusta: Reparar/Reinstalar desde el panel del agente
    // local (perfil base + compilación Rust en serie).
    if (widget.connection.onDeviceLoopback) {
      if (auto) return; // la auto-actualización no aplica al agente local
      // Aviso accionable: explica por qué y abre directamente el panel local
      // (Reparar/Reinstalar), la vía robusta para actualizar el agente on-device.
      final goPanel = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          title: Text(Strings.of(context).setUpdateLocalTitle),
          content: Text(
            Strings.of(context).setUpdateLocalBody,
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(Strings.of(context).commonClose),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(Strings.of(context).setOpenLocalPanel),
            ),
          ],
        ),
      );
      if (goPanel == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LocalInstanceControlScreen(
              connection: widget.connection,
              connManager: widget.connManager,
            ),
          ),
        );
        if (mounted) await _refresh(forceUpdate: true);
      }
      return;
    }
    final behind = (_update?['behind'] as num?)?.toInt() ?? 0;
    final method = (_update?['install_method'] ?? 'git').toString();
    // En modo auto saltamos la confirmación (el usuario optó por automático),
    // pero el App Lock de abajo se mantiene como salvaguarda.
    if (!auto) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          title: Text(Strings.of(context).setUpdateHermes),
          content: Text(
            Strings.of(
              context,
            ).setUpdateBody(behind > 0 ? ' ($behind commits)' : '', method),
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(Strings.of(context).commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(Strings.of(context).setUpdate),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    if (auto) {
      // En auto no se lanza un prompt de App Lock no solicitado: si el candado
      // está activo se salta esta pasada en silencio (spec 028 A-023).
      final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
      if (lock != null && lock.enabled) return;
    } else if (!await _confirmLock(Strings.of(context).setVerifyToUpdate) ||
        !mounted) {
      return;
    }

    final session = HermesUpdateSession.reserve(
      widget.connection.id,
      previousVersion: (_status?['version'] ?? '').toString().trim(),
    );
    if (session == null) {
      _snack(Strings.of(context).setUpdateAlreadyRunning);
      return;
    }
    // La instancia queda reservada ANTES del POST: desde aquí ninguna otra
    // acción automática de la app debe tocar sus servicios.
    unawaited(_presentHermesUpdate(session));
    final DashboardUpdateApplyResult applyResult;
    try {
      applyResult = await _client.applyUpdate();
    } catch (e) {
      final message = switch (e) {
        DashboardUpdateRefused refused => refused.message,
        StateError error => error.message.toString(),
        FormatException error => error.message.toString(),
        _ => e.toString().replaceFirst('Exception: ', ''),
      };
      session.abandon(
        HermesUpdateResult(HermesUpdateOutcome.failed, detail: message),
      );
      return;
    }
    session
      ..actionId = applyResult.actionId
      ..responseConfirmed = applyResult.responseConfirmed;
    if (mounted) {
      _snack(
        applyResult.alreadyRunning
            ? Strings.of(context).setUpdateAlreadyRunning
            : Strings.of(context).setUpdateStarted,
      );
    }
    unawaited(session.track(_updateProbes(session)));
  }

  /// Muestra el progreso de una sesión de actualización (recién lanzada o
  /// retomada al volver a Ajustes) y su resultado. El seguimiento real vive
  /// en [HermesUpdateSession]: si esta pantalla se cierra, sigue y libera la
  /// instancia en cuanto Hermes da un resultado.
  Future<void> _presentHermesUpdate(HermesUpdateSession session) async {
    void publish() {
      if (!mounted) return;
      setState(() {
        _updateProgress = HermesUpdateProgress(
          step: switch (session.step.value) {
            HermesUpdateSessionStep.requesting => HermesUpdateStep.requesting,
            HermesUpdateSessionStep.applying => HermesUpdateStep.applying,
            HermesUpdateSessionStep.restarting => HermesUpdateStep.restarting,
            HermesUpdateSessionStep.verifying => HermesUpdateStep.verifying,
          },
          elapsedSeconds: session.elapsedSeconds,
        );
      });
    }

    session.step.addListener(publish);
    // Refresca el contador de segundos aunque el paso no cambie.
    final ticker = Timer.periodic(const Duration(seconds: 1), (_) => publish());
    if (mounted) setState(() => _busy = true);
    publish();
    final HermesUpdateResult result;
    try {
      result = await session.result;
    } finally {
      ticker.cancel();
      session.step.removeListener(publish);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _refresh(forceUpdate: true);
    if (!mounted) return;
    final s = Strings.of(context);
    switch (result.outcome) {
      case HermesUpdateOutcome.failed:
        setState(() => _updateProgress = null);
        final detail = result.detail;
        _snack(
          s.setUpdateError(
            detail == null || detail.isEmpty
                ? s.setUpdateFailedNoDetail
                : detail,
          ),
        );
        return;
      case HermesUpdateOutcome.partial:
        setState(
          () => _updateProgress = const HermesUpdateProgress(
            step: HermesUpdateStep.unverified,
          ),
        );
        _snack(s.setUpdatePartial);
      case HermesUpdateOutcome.unverified:
        setState(
          () => _updateProgress = const HermesUpdateProgress(
            step: HermesUpdateStep.unverified,
          ),
        );
        _snack(s.setUpdateUnconfirmed);
      case HermesUpdateOutcome.confirmed:
        setState(
          () => _updateProgress = const HermesUpdateProgress(
            step: HermesUpdateStep.done,
          ),
        );
        final nv = (result.version ?? _status?['version'] ?? '')
            .toString()
            .trim();
        _snack(nv.isEmpty ? s.setHermesUpdated : s.setHermesUpdatedTo(nv));
        // Con la actualización cerrada se comprueba el bridge bajo la misma
        // preferencia.
        unawaited(
          BridgeUpdateService.maintainIfEnabled(widget.connection, force: true),
        );
    }
    // El panel terminal queda unos segundos y luego desaparece.
    await Future.delayed(const Duration(seconds: 6));
    if (mounted) setState(() => _updateProgress = null);
  }

  Future<void> _restartGateway() async {
    // Acción mutante: respeta el modo solo-lectura (spec 028 A-024).
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    if (HermesUpdateGuard.isActive(widget.connection.id)) {
      _snack(Strings.of(context).setUpdateAlreadyRunning);
      return;
    }
    final colors = Theme.of(context).hermes;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(Strings.of(context).setRestartGateway),
        content: Text(
          Strings.of(context).setRestartGatewayBody,
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(Strings.of(context).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(Strings.of(context).setRestart),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    if (!await _confirmLock(Strings.of(context).setVerifyToRestart) ||
        !mounted) {
      return;
    }

    setState(() => _busy = true);
    try {
      await _client.restartGateway();
      if (!mounted) return;
      _snack(Strings.of(context).setGatewayRestarting);
      // Espera resiliente a que el gateway vuelva (en vez de un delay fijo que
      // dejaba la app pillada si el reinicio tardaba).
      await _waitForGatewayBack();
      if (mounted) _snack(Strings.of(context).setGatewayRestarted);
    } catch (e) {
      if (mounted) _snack(Strings.of(context).setRestartError(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _migrateConfig() async {
    // Acción mutante: respeta el modo solo-lectura (spec 028 A-024).
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final colors = Theme.of(context).hermes;
    final cur = _status?['config_version'];
    final latest = _status?['latest_config_version'];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(Strings.of(context).setUpdateConfigSchema),
        content: Text(
          Strings.of(context).setMigrateBody('$cur', '$latest'),
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(Strings.of(context).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(Strings.of(context).setUpdate),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    if (!await _confirmLock(Strings.of(context).setVerifyToMigrate) ||
        !mounted) {
      return;
    }

    setState(() => _busy = true);
    try {
      final res = await _client.migrateConfig();
      if (!mounted) return;
      if (res['ok'] == true) {
        _snack(Strings.of(context).setMigrateStarted);
        // Es detached: esperamos y refrescamos para confirmar el nuevo número.
        await Future.delayed(const Duration(seconds: 4));
        if (!mounted) return;
        await _refresh();
        if (mounted && !_configOutdated) {
          _snack(Strings.of(context).setConfigUpToDate);
        }
      } else {
        _snack(Strings.of(context).setMigrateFailed);
      }
    } catch (e) {
      // Falla suave: nada se rompe, el agente sigue en la versión anterior.
      if (mounted) _snack(Strings.of(context).setMigrateError(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    HermesNotice.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Diagnóstico derivado de /api/status ──────────────────────────────

  bool get _gatewayUp => _status?['gateway_running'] == true;

  Map<String, String> get _platforms {
    return currentGatewayPlatformStates(_status);
  }

  bool get _configOutdated {
    final cur = (_status?['config_version'] as num?)?.toInt();
    final latest = (_status?['latest_config_version'] as num?)?.toInt();
    return cur != null && latest != null && cur < latest;
  }

  /// Estados de plataforma del gateway ("connected"…) en español legible; los
  /// desconocidos se muestran crudos como fallback (spec 028 A-026).
  String _platformStateEs(String state) => switch (state) {
    'connected' => 'conectada',
    'disconnected' => 'desconectada',
    'connecting' => 'conectando',
    'error' => 'con error',
    'starting' => 'arrancando',
    'stopped' => 'detenida',
    _ => state,
  };

  /// Lista de avisos legibles; vacía = todo en orden. La versión del esquema de
  /// config NO es un aviso: el agente funciona igual y solo indica que hay un
  /// esquema más nuevo disponible (migración opcional y aditiva).
  ///
  /// En el agente LOCAL on-device el gateway (multiplexer WS de plataformas) no
  /// se arranca: el chat va por el Mobile Bridge, no por el gateway. Por eso
  /// `gateway_running: false` es lo NORMAL en local y no debe figurar como
  /// aviso (era un falso positivo: "1 aviso, gateway detenido").
  List<String> get _warnings {
    final w = <String>[];
    if (!_gatewayUp && !widget.connection.onDeviceLoopback) {
      w.add(Strings.of(context).setGatewayNotRunning);
    }
    for (final e in _platforms.entries) {
      if (e.value != 'connected') {
        w.add(
          Strings.of(
            context,
          ).setPlatformStatus(e.key, _platformStateEs(e.value)),
        );
      }
    }
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Filas compactas coherentes con el resto de la pantalla en vez de
    // ListTile genérico.
    if (_loading) {
      return HermesPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Text(
                Strings.of(context).setCheckingStatus,
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return HermesPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cloud_off_outlined, size: 21, color: colors.error),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Strings.of(context).setStatusUnavailable,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.refresh, color: colors.textSecondary),
                tooltip: Strings.of(context).commonRetry,
                onPressed: () => _refresh(forceUpdate: true),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _diagnosticsCard(colors),
        const SizedBox(height: 8),
        _updateCard(),
        // Progreso real de la actualización (barra + paso n/N). Si no hay
        // actualización en curso pero el gateway está volviendo (p. ej. tras
        // "Reiniciar gateway"), se conserva el aviso simple de reinicio.
        if (_updateProgress != null) ...[
          const SizedBox(height: 8),
          HermesUpdateProgressPanel(progress: _updateProgress!),
        ] else if (_waitingGateway) ...[
          const SizedBox(height: 8),
          _restartingBanner(colors),
        ],
        // La auto-actualización de Hermes va por el endpoint del dashboard, que
        // no aplica al agente local (ese se actualiza desde su propio panel).
        if (!widget.connection.onDeviceLoopback) ...[
          const SizedBox(height: 8),
          _hermesAutoUpdateTile(colors),
        ],
        // "Reiniciar gateway" reconecta plataformas del multiplexer; en el
        // agente local on-device no hay gateway ni plataformas, así que la
        // acción no aplica (para reiniciar el agente local está su panel).
        if (!widget.connection.onDeviceLoopback) ...[
          const SizedBox(height: 8),
          _restartCard(colors),
        ],
      ],
    );
  }

  Widget _diagnosticsCard(HermesThemeColors colors) {
    final warnings = _warnings;
    final ok = warnings.isEmpty;
    final version = (_status?['version'] ?? '—').toString();
    final sessions = (_status?['active_sessions'] as num?)?.toInt() ?? 0;

    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: ok ? colors.success : colors.warning,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: 10),
                Text(
                  ok
                      ? Strings.of(context).setAllGood
                      : Strings.of(context).setWarningsCount(warnings.length),
                  style: TextStyle(
                    color: ok ? colors.success : colors.warning,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                if (_busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: Icon(
                      Icons.refresh,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                    tooltip: Strings.of(context).setReloadStatus,
                    onPressed: () => _refresh(forceUpdate: true),
                  ),
              ],
            ),
            SizedBox(height: 10),
            // En local el gateway no aplica (el chat va por el bridge); lo que
            // importa es que el agente local responda. `_status != null` aquí
            // significa que el dashboard contestó → agente arriba.
            if (widget.connection.onDeviceLoopback)
              _diagRow(
                colors,
                Strings.of(context).statusLocalAgent,
                Strings.of(context).setStatusRunning,
                true,
              )
            else
              _diagRow(
                colors,
                'gateway',
                _gatewayUp
                    ? Strings.of(context).setStatusRunning
                    : Strings.of(context).setStatusStopped,
                _gatewayUp,
              ),
            for (final e in _platforms.entries)
              _diagRow(
                colors,
                e.key,
                _platformStateEs(e.value),
                e.value == 'connected',
              ),
            _diagRow(
              colors,
              Strings.of(context).setSecConfig,
              _configOutdated
                  ? Strings.of(context).setConfigOutdated(
                      '${_status?['config_version']}',
                      '${_status?['latest_config_version']}',
                    )
                  : Strings.of(context).setStatusUpToDate,
              true,
              neutral: _configOutdated,
            ),
            if (_configOutdated) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _migrateConfig,
                  icon: Icon(
                    Icons.sync_rounded,
                    size: 16,
                    color: colors.accent,
                  ),
                  label: Text(
                    Strings.of(context).setUpdateSchemaShort(
                      '${_status?['config_version']}',
                      '${_status?['latest_config_version']}',
                    ),
                    style: TextStyle(fontSize: 12.5, color: colors.accent),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: colors.accent.withValues(alpha: 0.5),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  Strings.of(context).setAddsNewOptions,
                  style: TextStyle(fontSize: 11, color: colors.textDisabled),
                ),
              ),
            ],
            _diagRow(
              colors,
              Strings.of(context).setActiveSessions,
              sessions == 0
                  ? Strings.of(context).setActiveSessionsIdle
                  : Strings.of(context).setActiveSessionsRunning(sessions),
              true,
              neutral: true,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 13,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      Strings.of(context).setActiveSessionsNote,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _diagRow(
              colors,
              Strings.of(context).setVersionRow,
              version,
              true,
              neutral: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _diagRow(
    HermesThemeColors colors,
    String label,
    String value,
    bool good, {
    bool neutral = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
          ),
          if (!neutral) ...[
            Icon(
              good ? Icons.check_circle : Icons.error_outline,
              size: 14,
              color: good ? colors.success : colors.warning,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                color: neutral
                    ? colors.textSecondary
                    : (good ? colors.textPrimary : colors.warning),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Aviso mientras el gateway se reinicia tras una actualización: la app espera
  /// con reintentos a que vuelva (ver _waitForGatewayBack) en vez de quedarse
  /// pillada.
  Widget _restartingBanner(HermesThemeColors colors) {
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                Strings.of(context).setRestartingBanner,
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Política común de auto-actualización para Hermes + Mobile Bridge.
  /// MergeSemantics: el switch y su texto se anuncian como un único control en
  /// TalkBack (spec 028 A-107, spec 035).
  Widget _hermesAutoUpdateTile(HermesThemeColors colors) {
    return HermesPanel(
      child: MergeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.system_update_alt, size: 20, color: colors.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Strings.of(context).setHermesAutoUpdateTitle,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      Strings.of(context).setHermesAutoUpdateSub,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _hermesAutoUpdate,
                onChanged: (v) async {
                  setState(() => _hermesAutoUpdate = v);
                  await BridgeUpdateService.setHermesAutoUpdate(v);
                  if (v) _maybeAutoUpdateHermes();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _updateCard() {
    return HermesUpdateCard(
      presentation:
          _updateFailure ??
          HermesUpdatePresentation.fromPayload(
            _update,
            fallbackVersion: (_status?['version'] ?? '—').toString(),
          ),
      isLocal: _connection.onDeviceLoopback,
      busy: _busy,
      onApply: _applyUpdate,
      onConfigureDashboard: _configureDashboardAccess,
    );
  }

  Widget _restartCard(HermesThemeColors colors) {
    // Fila compacta coherente con el resto de la pantalla en vez de un
    // ListTile genérico: reutiliza _HistoryCleanupActionRow.
    return HermesPanel(
      child: _HistoryCleanupActionRow(
        actionKey: const ValueKey('maintenance-restart-gateway'),
        icon: Icons.restart_alt,
        title: Strings.of(context).setRestartGateway,
        subtitle: Strings.of(context).setReconnectsPlatforms,
        busy: false,
        onTap: _busy ? null : _restartGateway,
        destructive: false,
      ),
    );
  }
}

class _AboutCard extends StatefulWidget {
  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() => _version = '${info.version}+${info.buildNumber}');
    } catch (e) {
      debugPrint('[settings] no se pudo leer PackageInfo: $e');
      setState(() => _version = '1.0.0');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fila compacta coherente con el resto de la pantalla en vez de un
    // ListTile genérico: reutiliza _HistoryCleanupActionRow.
    return HermesPanel(
      child: _HistoryCleanupActionRow(
        actionKey: const ValueKey('about-hermes-console'),
        icon: Icons.info_outline,
        title: 'Hermes Console',
        subtitle: Strings.of(
          context,
        ).setClientVersion(_version.isNotEmpty ? _version : '…'),
        busy: false,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AboutScreen()),
        ),
        destructive: false,
      ),
    );
  }
}

class _HeaderTitleEditScreen extends StatefulWidget {
  const _HeaderTitleEditScreen({required this.initial, required this.colors});
  final String initial;
  final HermesThemeColors colors;

  @override
  State<_HeaderTitleEditScreen> createState() => _HeaderTitleEditScreenState();
}

class _HeaderTitleEditScreenState extends State<_HeaderTitleEditScreen> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: Text(
          Strings.of(context).setHeaderTitle,
          style: TextStyle(color: colors.textPrimary),
        ),
        leading: TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            Strings.of(context).commonCancel,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ),
        leadingWidth: 90,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: Text(
              Strings.of(context).commonSave,
              style: TextStyle(
                color: colors.accent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          maxLength: 16,
          textCapitalization: TextCapitalization.characters,
          style: TextStyle(color: colors.textPrimary),
          decoration: InputDecoration(
            hintText: 'HERMES CONSOLE',
            hintStyle: TextStyle(color: colors.textDisabled),
            counterStyle: TextStyle(color: colors.textSecondary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: colors.divider),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: colors.accent, width: 2),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
    );
  }
}

/// Estado y acción manual del Mobile Bridge. La política automática se controla
/// una sola vez en Sistema y cubre Hermes + Bridge (spec 035).
class _BridgeAutoUpdateTile extends StatefulWidget {
  /// En instancias locales (on-device) el bridge NO se descarga ni depende de
  /// este control: el agente local lo redespliega solo desde los assets del APK
  /// en cada conexión (`ensureFreshBridge`).
  final SavedConnection connection;
  const _BridgeAutoUpdateTile({required this.connection});

  bool get local => connection.onDeviceLoopback;

  @override
  State<_BridgeAutoUpdateTile> createState() => _BridgeAutoUpdateTileState();
}

class _BridgeAutoUpdateTileState extends State<_BridgeAutoUpdateTile> {
  bool _checking = false;
  bool _updating = false;
  BridgeUpdateCheck _check = BridgeUpdateCheck.none;
  String? _updateDetail;

  @override
  void initState() {
    super.initState();
    if (widget.local) return; // en local no hay toggle: no cargamos la pref
    _load();
  }

  @override
  void didUpdateWidget(covariant _BridgeAutoUpdateTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection.id != widget.connection.id) {
      _check = BridgeUpdateCheck.none;
      _updateDetail = null;
      if (!widget.local) _load();
    }
  }

  Future<void> _load() async {
    final enabled = await BridgeUpdateService.automaticUpdatesEnabled();
    if (!mounted) return;
    await _refresh(updateIfEnabled: enabled, allowRemote: enabled);
  }

  Future<void> _refresh({
    bool updateIfEnabled = false,
    bool allowRemote = false,
  }) async {
    if (_checking || _updating || widget.local) return;
    setState(() => _checking = true);
    final check = await BridgeUpdateService.check(
      widget.connection,
      allowRemote: allowRemote,
    );
    if (!mounted) return;
    setState(() {
      _check = check;
      _checking = false;
    });
    if (updateIfEnabled && check.outdated && !widget.connection.readOnly) {
      await _updateNow(automatic: true);
    }
  }

  Future<void> _updateNow({bool automatic = false}) async {
    if (_updating || widget.connection.readOnly) return;
    setState(() {
      _updating = true;
      _updateDetail = null;
    });
    final result = await BridgeUpdateService.update(
      widget.connection,
      automatic: automatic,
      onProgress: (message) {
        if (mounted) setState(() => _updateDetail = message);
      },
    );
    if (!mounted) return;
    setState(() {
      _updating = false;
      _updateDetail = result.detail;
    });
    if (result.ok) await _refresh(allowRemote: true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (widget.local) {
      // Nota honesta: el bridge local se mantiene fresco automaticamente.
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 20, color: colors.success),
            const SizedBox(width: 15),
            Expanded(
              child: Text(
                Strings.of(context).setBridgeLocalAutoFresh,
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    final s = Strings.of(context);
    final status = _updating
        ? (_updateDetail ?? s.bridgeUpdating)
        : _checking
        ? s.setBridgeChecking
        : !_check.reachable
        ? s.setBridgeStatusUnavailable
        : _check.outdated
        ? s.bridgeUpdateAvailable(
            _check.installed ?? '?',
            _check.available ?? BridgeUpdateService.packagedVersion,
          )
        : s.setBridgeStatusCurrent(_check.installed ?? '?');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.system_update_alt, size: 20, color: colors.accent),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.setBridgeAutoUpdateTitle,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  s.setBridgeAutoUpdateSub,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    if (_checking || _updating) ...[
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                      const SizedBox(width: 7),
                    ] else ...[
                      Icon(
                        _check.reachable && !_check.outdated
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 14,
                        color: _check.reachable && !_check.outdated
                            ? colors.success
                            : colors.textSecondary,
                      ),
                      const SizedBox(width: 7),
                    ],
                    Expanded(
                      child: Text(
                        widget.connection.readOnly
                            ? s.setBridgeReadOnly
                            : status,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    if (_check.outdated &&
                        !_updating &&
                        !widget.connection.readOnly)
                      TextButton(
                        onPressed: _updateNow,
                        child: Text(s.setBridgeUpdateNow),
                      )
                    else if (!_checking && !_updating)
                      IconButton(
                        tooltip: s.commonRefresh,
                        onPressed: () => _refresh(allowRemote: true),
                        icon: const Icon(Icons.refresh, size: 18),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
