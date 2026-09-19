import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Tarjeta redondeada que agrupa las filas de "Personalizar" en las
/// pantallas de crear/editar bot, como en el mockup del rediseño de Bots:
/// un único contenedor con separadores finos entre filas en vez de
/// encabezados de sección sueltos repartidos por la página.
class BotSettingsGroup extends StatelessWidget {
  const BotSettingsGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i != 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            color: colors.divider.withValues(alpha: 0.5),
          ),
        );
      }
      rows.add(children[i]);
    }
    // Material (no Container/DecoratedBox) para que las filas puedan
    // contener controles basados en ListTile (p. ej. HermesSwitchTile en la
    // fila de Skills) sin perder sus ripples de tinta: un DecoratedBox con
    // color de fondo entre un ListTile y su Material ancestro los oculta.
    return Material(
      color: colors.surfaceVariant.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

/// Fila colapsable de [BotSettingsGroup]: tocarla alterna entre un resumen
/// compacto ("etiqueta — valor actual") y los controles reales de edición.
/// Empieza expandida por defecto para no ocultar los controles existentes
/// tras un toque adicional; el gesto de plegar es real, no solo decorativo.
class BotSettingsRow extends StatefulWidget {
  const BotSettingsRow({
    required this.label,
    required this.child,
    this.summary,
    this.initiallyExpanded = true,
    this.expanded,
    this.onToggle,
    this.rowKey,
    super.key,
  });

  final String label;
  final String? summary;
  final Widget child;
  final bool initiallyExpanded;

  /// Cuando no es `null`, el estado de plegado pasa a estar controlado por
  /// el padre (por ejemplo, cuando también alimenta un flag de "sin
  /// guardar"), y [onToggle] debe actualizarlo. Si es `null`, la fila
  /// gestiona su propio estado interno a partir de [initiallyExpanded].
  final bool? expanded;
  final ValueChanged<bool>? onToggle;
  final Key? rowKey;

  @override
  State<BotSettingsRow> createState() => _BotSettingsRowState();
}

class _BotSettingsRowState extends State<BotSettingsRow> {
  late bool _internalExpanded = widget.initiallyExpanded;

  bool get _expanded => widget.expanded ?? _internalExpanded;

  void _toggle() {
    final next = !_expanded;
    final onToggle = widget.onToggle;
    if (onToggle != null) {
      onToggle(next);
    } else {
      setState(() => _internalExpanded = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: widget.rowKey,
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                if (widget.summary != null && !_expanded)
                  Expanded(
                    child: Text(
                      widget.summary!,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13.5,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 6),
                Icon(
                  _expanded ? Icons.expand_less : Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: widget.child,
          ),
      ],
    );
  }
}
