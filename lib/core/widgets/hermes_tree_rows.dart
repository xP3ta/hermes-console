import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Carpetas primero y, dentro de cada grupo, por nombre sin distinguir
/// mayúsculas: el orden de un árbol de archivos.
int compareFileTreeNames({
  required bool aIsDirectory,
  required String aName,
  required bool bIsDirectory,
  required String bName,
}) {
  if (aIsDirectory != bIsDirectory) return aIsDirectory ? -1 : 1;
  return aName.toLowerCase().compareTo(bName.toLowerCase());
}

/// Una fila visible del árbol: [entry] en [path], a [depth] niveles de la raíz.
final class FileTreeRow<T> {
  const FileTreeRow({
    required this.entry,
    required this.path,
    required this.depth,
    required this.isDirectory,
    required this.expanded,
  });

  final T entry;
  final String path;
  final int depth;
  final bool isDirectory;

  /// Carpeta desplegada (sus hijos siguen a esta fila).
  final bool expanded;
}

/// Aplana un árbol de archivos a las filas visibles. [roots] ya viene
/// ordenado; [children] guarda los hijos ya cargados por ruta de carpeta, y
/// una carpeta de [expanded] sin hijos cargados todavía no muestra nada bajo
/// ella.
List<FileTreeRow<T>> flattenFileTree<T>({
  required List<T> roots,
  required String rootPath,
  required bool Function(T entry) isDirectory,
  required String Function(T entry) nameOf,
  required Set<String> expanded,
  required Map<String, List<T>> children,
  required String Function(String base, String name) join,
}) {
  final rows = <FileTreeRow<T>>[];
  void walk(List<T> level, String base, int depth) {
    for (final entry in level) {
      final path = join(base, nameOf(entry));
      final dir = isDirectory(entry);
      final open = dir && expanded.contains(path);
      rows.add(
        FileTreeRow<T>(
          entry: entry,
          path: path,
          depth: depth,
          isDirectory: dir,
          expanded: open,
        ),
      );
      if (open) walk(children[path] ?? const [], path, depth + 1);
    }
  }

  walk(roots, rootPath, 0);
  return rows;
}

/// Sangría por nivel de un hijo respecto a su carpeta.
const double hermesTreeIndent = 18;

/// Dibuja detrás de [child] la línea guía vertical de cada nivel por encima
/// de [depth], y deja [child] sangrado con [leading] más [depth] niveles.
class HermesTreeGuide extends StatelessWidget {
  const HermesTreeGuide({
    required this.depth,
    required this.child,
    this.leading = 0,
    super.key,
  });

  final int depth;
  final Widget child;

  /// Margen de la fila a nivel 0.
  final double leading;

  @override
  Widget build(BuildContext context) {
    if (depth <= 0) return child;
    final color = Theme.of(context).hermes.divider;
    return CustomPaint(
      painter: _GuidePainter(
        depth: depth,
        leading: leading,
        color: color,
        textDirection: Directionality.of(context),
      ),
      child: child,
    );
  }
}

class _GuidePainter extends CustomPainter {
  const _GuidePainter({
    required this.depth,
    required this.leading,
    required this.color,
    required this.textDirection,
  });

  final int depth;
  final double leading;
  final Color color;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var level = 0; level < depth; level++) {
      final offset = leading + level * hermesTreeIndent + hermesTreeIndent / 2;
      final x = textDirection == TextDirection.rtl
          ? size.width - offset
          : offset;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_GuidePainter old) =>
      old.depth != depth ||
      old.leading != leading ||
      old.color != color ||
      old.textDirection != textDirection;
}

/// Flecha que despliega o pliega una carpeta del árbol: gira un cuarto de
/// vuelta al abrirse (sin giro animado con «reducir movimiento»).
class HermesTreeToggle extends StatelessWidget {
  const HermesTreeToggle({
    required this.expanded,
    required this.onTap,
    this.color,
    super.key,
  });

  final bool expanded;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      button: true,
      expanded: expanded,
      label: expanded ? strings.motionTreeCollapse : strings.motionTreeExpand,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              child: Icon(
                Icons.chevron_right,
                size: 18,
                color: color ?? colors.textDisabled,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
