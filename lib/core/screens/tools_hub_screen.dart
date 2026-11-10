import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/dock_config.dart' show DockItemId;
import '../services/connection_manager.dart';
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart' show HermesGroup, HermesPanel;
import '../feedback/feedback_policy.dart';

String _withInitialUppercase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

@immutable
class HermesToolDestination {
  const HermesToolDestination({
    required this.id,
    required this.group,
    required this.icon,
    required this.label,
    required this.builder,
    this.enabled = true,
    this.disabledReason,
    this.value,
    this.subtitle,
    this.beforeOpen,
    this.onOpen,
  });

  final String id;
  final String group;
  final IconData icon;
  final String label;
  final WidgetBuilder builder;
  final bool enabled;
  final String? disabledReason;

  /// A figure the row already knows (a count, a host total), shown at its
  /// end; null when there is none and the row shows only its title.
  final String? value;

  /// A second line under the label (what the entry is, or how to start).
  final String? subtitle;

  /// Runs before the screen opens and is awaited. An entry whose screen
  /// follows the app's active profile uses it to make its profile the active
  /// one, in plain sight (see the profile hub); another uses it to ask a
  /// section of the settings to scroll into view.
  final Future<void> Function()? beforeOpen;

  /// Opens the entry by itself: it needs a screen this list cannot build
  /// (the bot's card needs the Bots screen). The list calls it instead of
  /// pushing [builder], after [beforeOpen].
  final VoidCallback? onOpen;
}

/// Opens [destination] from a list of destinations: says why when it cannot
/// be opened, runs its [HermesToolDestination.beforeOpen] (awaited) and then
/// pushes its screen. One path for every list of destinations, so a row
/// behaves the same wherever it is.
Future<void> openHermesToolDestination(
  BuildContext context,
  HermesToolDestination destination,
) async {
  if (!destination.enabled) {
    HermesNotice.of(context).hideCurrentSnackBar();
    AppFeedback.notify(
      context,
      FeedbackKind.error,
      destination.disabledReason ?? Strings.of(context).drawerNeedInstance,
      warning: true,
      duration: const Duration(seconds: 3),
    );
    return;
  }
  final before = destination.beforeOpen;
  if (before != null) {
    await before();
    if (!context.mounted) return;
  }
  final opensItself = destination.onOpen;
  if (opensItself != null) {
    opensItself();
    return;
  }
  unawaited(
    Navigator.of(context).push(MaterialPageRoute(builder: destination.builder)),
  );
}

/// Lista agrupada y con buscador de destinos de Hermes.
///
/// Desde 1.4.0 ya no es la pestaña «Herramientas» (se repartió entre Ajustes
/// de la app y el perfil de cada bot): es el componente de lista de Ajustes
/// de la app, que lo llena con sus grupos. Conserva el buscador, las filas de
/// 52 dp con su estado deshabilitado y el dock.
class ToolsHubScreen extends StatefulWidget {
  const ToolsHubScreen({
    required this.destinations,
    this.connection,
    this.connManager,
    this.title,
    this.searchHint,
    this.opener,
    this.bodyLayout,
    super.key,
  });

  final List<HermesToolDestination> destinations;

  /// Opens a row. Null: its screen full width ([openHermesToolDestination]).
  /// A wide-window layout with a detail pane picks the pane for the rows that
  /// belong in it and defers to [openHermesToolDestination] for the rest.
  final Future<void> Function(
    BuildContext context,
    HermesToolDestination destination,
  )?
  opener;

  /// Lays the list out beside something else (a detail pane). Null: the list
  /// alone. The dock then gives it the full width beside its rail.
  final Widget Function(BuildContext context, Widget list)? bodyLayout;

  /// The screen's title; [Strings.drawerTools] when null.
  final String? title;

  /// The search box's hint; [Strings.drawerToolsSearch] when null.
  final String? searchHint;

  /// Ambos opcionales y usados juntos: cuando están presentes, envuelven
  /// esta pantalla con [GeneralDockShell] (mismo dock flotante que ya usan
  /// Ajustes y la lista de sesiones). Herramientas no tiene un concepto
  /// natural de "crear" propio, así que el "+" del dock aquí cae al
  /// fallback genérico de `GeneralDockShell` (nueva conversación) en vez de
  /// abrir algo contextual. Null en call sites sin conexión activa: el hub
  /// sigue funcionando igual (ya degrada sus filas vía `enabled`), solo sin
  /// el dock.
  final SavedConnection? connection;
  final ConnectionManager? connManager;

  @override
  State<ToolsHubScreen> createState() => _ToolsHubScreenState();
}

class _ToolsHubScreenState extends State<ToolsHubScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<HermesToolDestination> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.destinations;
    return widget.destinations
        .where(
          (destination) =>
              destination.label.toLowerCase().contains(query) ||
              destination.group.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _open(HermesToolDestination destination) =>
      (widget.opener ?? openHermesToolDestination)(context, destination);

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final grouped = <String, List<HermesToolDestination>>{};
    for (final destination in _filtered) {
      grouped.putIfAbsent(destination.group, () => []).add(destination);
    }

    return Scaffold(
      appBar: HermesAppBar(
        title: Text(widget.title ?? strings.drawerTools),
        titleBadge: grouped.isEmpty
            ? null
            : HermesTitleBadge(
                strings.screenProfileToolsGroups(grouped.length),
                key: const ValueKey('tools-groups-count'),
              ),
      ),
      body: _wrapWithDock(
        (bottomClearance) => SafeArea(
          top: false,
          child: ListView(
            clipBehavior: hermesUnderHeader,
            key: const ValueKey('tools-hub-list'),
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 16, 16, 28 + bottomClearance),
            children: [
              HermesPanel(
                child: TextField(
                  key: const ValueKey('tools-search'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  textInputAction: TextInputAction.search,
                  style: TextStyle(fontSize: 15, color: colors.textPrimary),
                  decoration: InputDecoration(
                    hintText: widget.searchHint ?? strings.drawerToolsSearch,
                    hintStyle: TextStyle(color: colors.textSecondary),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 21,
                      color: colors.textSecondary,
                    ),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).deleteButtonTooltip,
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (grouped.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 56),
                  child: Column(
                    children: [
                      Icon(
                        Icons.search_off_rounded,
                        size: 34,
                        color: colors.textDisabled,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        strings.drawerToolsEmpty,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final entry in grouped.entries) ...[
                  HermesToolGroupLabel(entry.key),
                  HermesToolGroup(destinations: entry.value, onOpen: _open),
                ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _wrapWithDock(Widget Function(double bottomClearance) buildBody) {
    final connection = widget.connection;
    final connManager = widget.connManager;
    final layout = widget.bodyLayout;
    Widget laidOut(double bottomClearance) => layout == null
        ? buildBody(bottomClearance)
        : layout(context, buildBody(bottomClearance));
    if (connection == null || connManager == null) return laidOut(0);
    return GeneralDockShell(
      connection: connection,
      connManager: connManager,
      paneLayout: layout != null,
      // The list is Ajustes: its dock item is the selected one, and tapping
      // it again does not stack a copy.
      currentDestination: DockItemId.settings,
      bodyBuilder: (_, bottomClearance) => laidOut(bottomClearance),
    );
  }
}

/// Caption of a group of rows.
class HermesToolGroupLabel extends StatelessWidget {
  const HermesToolGroupLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 7),
      child: Text(
        _withInitialUppercase(label),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

/// One box of rows.
class HermesToolGroup extends StatelessWidget {
  const HermesToolGroup({
    required this.destinations,
    required this.onOpen,
    super.key,
  });

  final List<HermesToolDestination> destinations;
  final ValueChanged<HermesToolDestination> onOpen;

  @override
  Widget build(BuildContext context) {
    return HermesGroup(
      children: [
        for (final destination in destinations)
          HermesToolRow(
            destination: destination,
            onTap: () => onOpen(destination),
          ),
      ],
    );
  }
}

/// One 52 dp row: icon tile, label, optional figure, chevron.
class HermesToolRow extends StatelessWidget {
  const HermesToolRow({
    required this.destination,
    required this.onTap,
    super.key,
  });

  final HermesToolDestination destination;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final foreground = destination.enabled
        ? colors.textPrimary
        : colors.textDisabled;
    final value = destination.value;
    final iconColor = destination.enabled
        ? colors.textSecondary
        : colors.textDisabled;

    return Semantics(
      key: ValueKey<String>('tool-semantics-${destination.id}'),
      button: true,
      enabled: destination.enabled,
      hint: destination.enabled ? null : destination.disabledReason,
      onTap: destination.enabled ? onTap : null,
      child: InkWell(
        key: ValueKey<String>('tool-${destination.id}'),
        onTap: onTap,
        excludeFromSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(HermesRadius.control),
                  ),
                  child: SizedBox.square(
                    dimension: 34,
                    child: Icon(destination.icon, size: 19, color: iconColor),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _withInitialUppercase(destination.label),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: foreground),
                      ),
                      if (destination.subtitle != null &&
                          destination.subtitle!.isNotEmpty)
                        Text(
                          destination.subtitle!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                if (value != null && destination.enabled) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: HermesType.valueSize,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                Icon(
                  destination.enabled
                      ? Icons.chevron_right_rounded
                      : Icons.block_rounded,
                  size: 20,
                  color: destination.enabled
                      ? colors.textSecondary
                      : colors.textDisabled,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
