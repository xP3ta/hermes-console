import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_header_title.dart';
import '../services/chat_draft_store.dart';
import '../services/connection_manager.dart';
import '../services/cron_repository.dart';
import '../services/font_size_service.dart';
import '../services/local_transcript_store.dart';
import '../services/session_deletion.dart';
import '../services/turn_outbox_store.dart';
import '../theme/app_theme.dart';
import '../theme/theme_profile_adapter.dart';
import '../theme/theme_profile_store.dart';
import '../utils/api_error.dart';
import '../services/bridge_update_service.dart';
import '../../main.dart';
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
    // que HomeDashboardScreen): sin esto, `connection` es una foto fija del
    // constructor y, tras activar otra instancia en "Gestionar instancias",
    // Ajustes seguía enseñando la config (y el modelo) de la anterior hasta
    // salir y volver a entrar (spec 028).
    return ValueListenableBuilder<String?>(
      valueListenable: connManager.activeConnectionId,
      builder: (context, activeId, _) {
        final id =
            activeId ??
            connManager.prefs.getString(ConnectionManager.lastConnKey);
        final matches = connManager.getConnections().where((c) => c.id == id);
        final conn = matches.isEmpty ? connection : matches.first;
        return _buildBody(context, conn);
      },
    );
  }

  Widget _buildBody(BuildContext context, SavedConnection conn) {
    return Scaffold(
      appBar: HermesAppBar(title: Text(Strings.of(context).setTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                controller: DiagnosticBundleController(manager: connManager),
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

@visibleForTesting
class HistoryCleanupSection extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  final Future<bool> Function()? verifyHistoryCleanupForTesting;

  const HistoryCleanupSection({
    required this.connection,
    required this.connManager,
    this.verifyHistoryCleanupForTesting,
    super.key,
  });

  @override
  State<HistoryCleanupSection> createState() => _HistoryCleanupSectionState();
}

class _HistoryCleanupSectionState extends State<HistoryCleanupSection> {
  bool _clearingNormal = false;
  bool _clearingCron = false;

  String _summaryMessage(Strings s, ClearConversationsSummary result) {
    final parts = <String>[];
    final remote = result.remote;
    if (remote == null) {
      parts.add(s.setRemoteClearUnavailable);
    } else if (remote.allDeleted) {
      parts.add(s.setConvosCleared(remote.deleted));
    } else {
      parts.add(
        s.setConvosClearedPartial(
          remote.deleted,
          remote.rejected,
          remote.failed,
        ),
      );
    }
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
    if (!mounted || widget.connection.id != targetConnection.id) return false;
    if (!allowed && targetConnection.readOnly) {
      showReadOnlyNotice(context);
    }
    return allowed;
  }

  Future<void> _clearNormal() async {
    if (_clearingNormal || _clearingCron) return;
    final targetConnection = widget.connection;
    final verifier = _captureHistoryCleanupVerifier();
    final activeChats = context
        .findAncestorStateOfType<HermesAppState>()
        ?.activeChats;
    setState(() => _clearingNormal = true);

    ApiClient? client;
    var normalSessions = <Session>[];
    try {
      if (!await _authorizeHistoryCleanup(
        targetConnection: targetConnection,
        verifier: verifier,
      )) {
        return;
      }
      if (!mounted || widget.connection.id != targetConnection.id) return;
      final colors = Theme.of(context).hermes;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(Strings.of(dialogContext).setClearConvos),
          content: Text(Strings.of(dialogContext).setClearConvosBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(Strings.of(dialogContext).commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                Strings.of(dialogContext).commonDelete,
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        ),
      );
      if (confirm != true ||
          !mounted ||
          widget.connection.id != targetConnection.id) {
        return;
      }

      client = ApiClient(
        baseUrl: targetConnection.baseUrl,
        apiKey: targetConnection.apiKey,
        connectionId: targetConnection.id,
      );
      final prefs = await SharedPreferences.getInstance();
      final result = await clearConversationsAndLocalState(
        loadSessions: ({bool includeChildren = false}) async {
          final sessions = await client!.getSessions(
            includeChildren: includeChildren,
          );
          normalSessions = sessionsSafeForBulkDelete(sessions);
          return sessions;
        },
        deleteSession: client.deleteSession,
        clearDrafts: () =>
            ChatDraftStore(prefs).deleteForConnection(targetConnection.id),
        clearTranscripts: () =>
            LocalTranscriptStore.deleteForConnection(targetConnection.id),
        clearOutbox: () =>
            TurnOutboxStore().deleteForConnection(targetConnection.id),
        onRemoteSessionDeleted: (sessionId) async {
          if (activeChats == null) return;
          var profile = '';
          for (final session in normalSessions) {
            if (session.id == sessionId) {
              profile = session.profile ?? '';
              break;
            }
          }
          await activeChats.clearCancelledTurnsForSession(
            connectionId: targetConnection.id,
            profile: profile,
            sessionId: sessionId,
          );
        },
      );
      if (!mounted) return;
      if (result.hasChanges) {
        historyCleanupInvalidations.publish(
          connectionId: targetConnection.id,
          scope: HistoryCleanupScope.normalConversations,
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_summaryMessage(Strings.of(context), result)),
          duration: Duration(seconds: result.allSucceeded ? 3 : 5),
        ),
      );
    } catch (e) {
      // Las fuentes remotas/locales se aíslan dentro del coordinador. Este
      // fallback solo cubre fallos inesperados al preparar la operación.
      if (!mounted) return;
      final s = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.setClearError(localizedApiError(s, e)))),
      );
    } finally {
      client?.close();
      if (mounted) setState(() => _clearingNormal = false);
    }
  }

  Future<void> _clearCron() async {
    if (_clearingNormal || _clearingCron) return;
    final targetConnection = widget.connection;
    final targetProfile = widget.connManager.activeProfileFor(
      targetConnection.id,
    );
    final verifier = _captureHistoryCleanupVerifier();
    setState(() => _clearingCron = true);

    DashboardClient? client;
    try {
      if (!await _authorizeHistoryCleanup(
        targetConnection: targetConnection,
        verifier: verifier,
      )) {
        return;
      }
      client = DashboardClient.lazy(targetConnection);
      final repository = CronRepository(client, profile: targetProfile);
      final preview = await repository.previewConversationCleanup();
      if (!mounted) return;
      final s = Strings.of(context);
      if (preview.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(s.crnCleanupEmpty)));
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Text(s.crnCleanupTitle),
          content: Text(s.crnCleanupBody(preview.count)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(s.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).hermes.error,
              ),
              child: Text(s.commonDelete),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          widget.connection.id != targetConnection.id) {
        return;
      }

      final result = await repository.deleteCronConversations(preview);
      if (!mounted) return;
      if (result.deleted > 0) {
        historyCleanupInvalidations.publish(
          connectionId: targetConnection.id,
          scope: HistoryCleanupScope.cronResults,
        );
      }
      final message = result.preserved == 0
          ? s.crnCleanupDone(result.deleted)
          : s.crnCleanupPartial(result.deleted, result.preserved);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      final s = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.crnCleanupFailed(localizedApiError(s, error))),
          backgroundColor: Theme.of(context).hermes.warning,
        ),
      );
    } finally {
      client?.close();
      if (mounted) setState(() => _clearingCron = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HistoryCleanupActionList(
      readOnly: widget.connection.readOnly,
      clearingNormal: _clearingNormal,
      clearingCron: _clearingCron,
      onClearNormal: _clearNormal,
      onClearCron: _clearCron,
    );
  }
}

@visibleForTesting
class HistoryCleanupActionList extends StatelessWidget {
  final bool readOnly;
  final bool clearingNormal;
  final bool clearingCron;
  final VoidCallback onClearNormal;
  final VoidCallback onClearCron;

  const HistoryCleanupActionList({
    required this.readOnly,
    required this.clearingNormal,
    required this.clearingCron,
    required this.onClearNormal,
    required this.onClearCron,
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
          subtitle: s.setClearConvosSub,
          busy: clearingNormal,
          onTap: readOnly || clearingNormal || clearingCron
              ? null
              : onClearNormal,
        ),
        _HistoryCleanupActionRow(
          actionKey: const ValueKey('history-cleanup-cron'),
          icon: Icons.schedule_outlined,
          title: s.crnCleanupTitle,
          busy: clearingCron,
          onTap: readOnly || clearingNormal || clearingCron
              ? null
              : onClearCron,
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

  const _HistoryCleanupActionRow({
    required this.actionKey,
    required this.icon,
    required this.title,
    required this.busy,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final foreground = onTap == null ? colors.textDisabled : colors.error;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: actionKey,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            removed == 0 ? s.secNoOrphans : s.secOrphansRemoved(removed),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).secCleanFailed(e.toString())),
        ),
      );
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return HermesPanel(
      child: ListTile(
        leading: Icon(
          Icons.cleaning_services_outlined,
          color: colors.textSecondary,
        ),
        title: Text(Strings.of(context).secOrphanTitle),
        subtitle: Text(
          Strings.of(context).secOrphanSubtitle,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        trailing: _cleaning
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: _cleaning ? null : _clean,
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
          .get(Uri.parse('$base/api/status'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      return data is Map<String, dynamic> ? data : null;
    } catch (e) {
      debugPrint('[settings] no se pudo leer /api/status público: $e');
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
  Future<bool> _waitForGatewayBack({
    Duration timeout = const Duration(minutes: 3),
    bool waitForUpdate = false,
    bool updateResponseConfirmed = false,
    String previousVersion = '',
  }) async {
    if (mounted) setState(() => _waitingGateway = true);
    final deadline = DateTime.now().add(timeout);
    var sawRestart = false;
    var confirmed = false;
    try {
      while (mounted && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 3));
        try {
          final s = await _publicServerStatus();
          if (s == null) {
            sawRestart = true;
            continue;
          }
          final running =
              s['gateway_running'] == true || s['gateway_state'] == 'running';
          if (!running) {
            sawRestart = true;
            continue;
          }
          final version = (s['version'] ?? '').toString().trim();
          final versionChanged =
              previousVersion.isNotEmpty &&
              version.isNotEmpty &&
              version != previousVersion;
          var updateNoLongerAvailable = false;
          if (waitForUpdate && !updateResponseConfirmed && !versionChanged) {
            try {
              final check = await _client.checkUpdate(force: true);
              updateNoLongerAvailable = check['update_available'] == false;
            } catch (_) {
              // El Dashboard puede estar rotando su sesión durante el reinicio.
              // /api/status seguirá siendo la fuente de recuperación.
            }
          }
          if (!waitForUpdate ||
              updateResponseConfirmed ||
              versionChanged ||
              updateNoLongerAvailable ||
              (previousVersion.isEmpty && sawRestart)) {
            confirmed = true;
            if (mounted) setState(() => _status = s);
            break;
          }
        } catch (_) {
          // gateway aún reiniciando: seguimos esperando sin romper.
          sawRestart = true;
        }
      }
    } finally {
      if (mounted) setState(() => _waitingGateway = false);
      if (mounted) await _refresh(forceUpdate: waitForUpdate);
    }
    return confirmed;
  }

  bool _hermesAutoTriggered = false;

  /// Si el toggle de auto-actualización de Hermes está activo y hay una versión
  /// nueva, la aplica automáticamente (una vez por carga de pantalla). No aplica
  /// al agente local.
  Future<void> _maybeAutoUpdateHermes() async {
    if (_hermesAutoTriggered) return;
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
    ScaffoldMessenger.of(context).showSnackBar(
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

    setState(() => _busy = true);
    try {
      final previousVersion = (_status?['version'] ?? '').toString().trim();
      final applyResult = await _client.applyUpdate();
      if (!mounted) return;
      _snack(Strings.of(context).setUpdateStarted);
      // La actualización reinicia el gateway: en vez de un delay fijo (que dejaba
      // la app "pillada" si el reinicio tardaba), esperamos con reintentos a que
      // el gateway vuelva, mostrando "reiniciando". Así el corte no se nota.
      final confirmed = await _waitForGatewayBack(
        waitForUpdate: true,
        updateResponseConfirmed: applyResult.responseConfirmed,
        previousVersion: previousVersion,
      );
      if (!mounted) return;
      if (!confirmed) {
        _snack(Strings.of(context).setUpdateUnconfirmed);
        return;
      }
      // Aviso EXPLÍCITO de éxito al terminar (tras volver el gateway). _refresh
      // dentro de _waitForGatewayBack ya actualizó _status con la versión nueva.
      if (!mounted) return;
      final nv = (_status?['version'] ?? '').toString().trim();
      _snack(
        nv.isEmpty
            ? Strings.of(context).setHermesUpdated
            : Strings.of(context).setHermesUpdatedTo(nv),
      );
      // El bridge tiene su propio canal validado. Al terminar el agente
      // comprobamos también ese compañero bajo la misma preferencia.
      await BridgeUpdateService.maintainIfEnabled(
        widget.connection,
        force: true,
      );
    } catch (e) {
      if (mounted) {
        final message = switch (e) {
          StateError error => error.message.toString(),
          FormatException error => error.message.toString(),
          _ => e.toString().replaceFirst('Exception: ', ''),
        };
        _snack(Strings.of(context).setUpdateError(message));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restartGateway() async {
    // Acción mutante: respeta el modo solo-lectura (spec 028 A-024).
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
    if (_loading) {
      return HermesPanel(
        child: ListTile(
          leading: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(
            Strings.of(context).setCheckingStatus,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ),
      );
    }
    if (_error != null) {
      return HermesPanel(
        child: ListTile(
          leading: Icon(Icons.cloud_off_outlined, color: colors.error),
          title: Text(
            Strings.of(context).setStatusUnavailable,
            style: TextStyle(color: colors.textPrimary),
          ),
          subtitle: Text(
            _error!,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          trailing: IconButton(
            icon: Icon(Icons.refresh, color: colors.textSecondary),
            tooltip: Strings.of(context).commonRetry,
            onPressed: () => _refresh(forceUpdate: true),
          ),
        ),
      );
    }

    return Column(
      children: [
        _diagnosticsCard(colors),
        const SizedBox(height: 8),
        _updateCard(),
        if (_waitingGateway) ...[
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
    return HermesPanel(
      child: ListTile(
        leading: Icon(Icons.restart_alt, color: colors.textSecondary),
        title: Text(
          Strings.of(context).setRestartGateway,
          style: TextStyle(color: colors.textPrimary),
        ),
        subtitle: Text(
          Strings.of(context).setReconnectsPlatforms,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        trailing: Icon(Icons.chevron_right, color: colors.textDisabled),
        onTap: _busy ? null : _restartGateway,
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
    final colors = Theme.of(context).hermes;
    return HermesPanel(
      child: ListTile(
        leading: Icon(Icons.info_outline, color: colors.textSecondary),
        title: const Text(
          'Hermes Console',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          Strings.of(
            context,
          ).setClientVersion(_version.isNotEmpty ? _version : '…'),
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        trailing: Icon(Icons.chevron_right, color: colors.textDisabled),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AboutScreen()),
        ),
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
