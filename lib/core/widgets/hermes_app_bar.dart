import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// AppBar de Hermes: idéntico al [AppBar] de Material salvo que, en los temas
/// de estética terminal (los que piden [HermesThemeColors.uppercaseTitles] —
/// Dracula, Hermes Console, Fósforo), muestra el título de pantalla en
/// MAYÚSCULAS. Es un reemplazo directo de `AppBar`: misma API para los
/// parámetros que usamos en la app.
///
/// Solo transforma el título cuando es un [Text] simple; si es un widget
/// compuesto (Row, Column, pill…) lo deja intacto. El estilo del título
/// (color de acento, peso y tracking) lo sigue aportando `appBarTheme`.
class HermesAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HermesAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.bottom,
    this.centerTitle,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.scrolledUnderElevation,
    this.titleSpacing,
    this.shape,
    this.surfaceTintColor,
    this.iconTheme,
    this.titleTextStyle,
    this.systemOverlayStyle,
    this.automaticallyImplyLeading = true,
  });

  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final bool? centerTitle;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double? elevation;
  final double? scrolledUnderElevation;
  final double? titleSpacing;
  final ShapeBorder? shape;
  final Color? surfaceTintColor;
  final IconThemeData? iconTheme;
  final TextStyle? titleTextStyle;
  final SystemUiOverlayStyle? systemOverlayStyle;
  final bool automaticallyImplyLeading;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0.0));

  @override
  Widget build(BuildContext context) {
    final upper = Theme.of(context).hermes.uppercaseTitles;
    final resolvedTitle = upper ? _applyUppercase(title) : title;

    return AppBar(
      title: resolvedTitle,
      leading: leading,
      actions: actions,
      bottom: bottom,
      centerTitle: centerTitle,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      elevation: elevation,
      scrolledUnderElevation: scrolledUnderElevation,
      titleSpacing: titleSpacing,
      shape: shape,
      surfaceTintColor: surfaceTintColor,
      iconTheme: iconTheme,
      titleTextStyle: titleTextStyle,
      systemOverlayStyle: systemOverlayStyle,
      automaticallyImplyLeading: automaticallyImplyLeading,
    );
  }

  /// Pone el título en MAYÚSCULAS. Soporta el [Text] simple y los títulos
  /// compuestos de dos líneas ([Column]/[Row]): en esos solo transforma el
  /// primer [Text] (el título), dejando intacto el subtítulo.
  Widget? _applyUppercase(Widget? w) {
    if (w is Text) return _upText(w);
    if (w is Column) {
      var done = false;
      return Column(
        key: w.key,
        mainAxisAlignment: w.mainAxisAlignment,
        mainAxisSize: w.mainAxisSize,
        crossAxisAlignment: w.crossAxisAlignment,
        textDirection: w.textDirection,
        verticalDirection: w.verticalDirection,
        textBaseline: w.textBaseline,
        children: w.children.map((c) {
          if (!done && c is Text && c.data != null) {
            done = true;
            return _upText(c);
          }
          return c;
        }).toList(),
      );
    }
    if (w is Row) {
      var done = false;
      return Row(
        key: w.key,
        mainAxisAlignment: w.mainAxisAlignment,
        mainAxisSize: w.mainAxisSize,
        crossAxisAlignment: w.crossAxisAlignment,
        textDirection: w.textDirection,
        verticalDirection: w.verticalDirection,
        textBaseline: w.textBaseline,
        children: w.children.map((c) {
          if (!done && c is Text && c.data != null) {
            done = true;
            return _upText(c);
          }
          return c;
        }).toList(),
      );
    }
    return w;
  }

  Text _upText(Text t) => Text(
    (t.data ?? '').toUpperCase(),
    style: t.style,
    textAlign: t.textAlign,
    overflow: t.overflow,
    maxLines: t.maxLines,
    softWrap: t.softWrap,
    semanticsLabel: t.semanticsLabel ?? t.data,
  );
}
