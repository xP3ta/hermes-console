import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/dock_config.dart' show DockItemId;
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';

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
  });

  final String id;
  final String group;
  final IconData icon;
  final String label;
  final WidgetBuilder builder;
  final bool enabled;
  final String? disabledReason;
}

/// Catálogo móvil de las superficies administrativas de Hermes.
///
/// El drawer conserva únicamente navegación cotidiana. Este hub mantiene todas
/// las rutas avanzadas accesibles sin convertir la barra lateral en una lista
/// de escritorio ni persistir acordeones entre aperturas.
class ToolsHubScreen extends StatefulWidget {
  const ToolsHubScreen({
    required this.destinations,
    this.connection,
    this.connManager,
    super.key,
  });

  final List<HermesToolDestination> destinations;

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

  void _open(HermesToolDestination destination) {
    if (!destination.enabled) {
      HermesNotice.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              destination.disabledReason ??
                  Strings.of(context).drawerNeedInstance,
            ),
            duration: const Duration(seconds: 3),
          ),
          kind: HermesNoticeKind.warning,
        );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: destination.builder));
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final grouped = <String, List<HermesToolDestination>>{};
    for (final destination in _filtered) {
      grouped.putIfAbsent(destination.group, () => []).add(destination);
    }

    return Scaffold(
      appBar: HermesAppBar(title: Text(strings.drawerTools)),
      body: _wrapWithDock(
        SafeArea(
          top: false,
          child: ListView(
            key: const ValueKey('tools-hub-list'),
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              TextField(
                key: const ValueKey('tools-search'),
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                style: TextStyle(fontSize: 15, color: colors.textPrimary),
                decoration: InputDecoration(
                  hintText: strings.drawerToolsSearch,
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
                  filled: true,
                  fillColor: colors.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: colors.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: colors.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: colors.accent, width: 1.4),
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
                  _ToolsGroupLabel(entry.key),
                  _ToolsGroup(destinations: entry.value, onOpen: _open),
                ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _wrapWithDock(Widget body) {
    final connection = widget.connection;
    final connManager = widget.connManager;
    if (connection == null || connManager == null) return body;
    return GeneralDockShell(
      connection: connection,
      connManager: connManager,
      currentDestination: DockItemId.tools,
      body: body,
    );
  }
}

class _ToolsGroupLabel extends StatelessWidget {
  const _ToolsGroupLabel(this.label);

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

class _ToolsGroup extends StatelessWidget {
  const _ToolsGroup({required this.destinations, required this.onOpen});

  final List<HermesToolDestination> destinations;
  final ValueChanged<HermesToolDestination> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < destinations.length; index++) ...[
            _ToolRow(
              destination: destinations[index],
              onTap: () => onOpen(destinations[index]),
            ),
            if (index != destinations.length - 1)
              Divider(
                height: 1,
                indent: 52,
                color: colors.divider.withValues(alpha: 0.7),
              ),
          ],
        ],
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.destination, required this.onTap});

  final HermesToolDestination destination;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final foreground = destination.enabled
        ? colors.textPrimary
        : colors.textDisabled;
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(destination.icon, size: 20, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    _withInitialUppercase(destination.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: foreground),
                  ),
                ),
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
