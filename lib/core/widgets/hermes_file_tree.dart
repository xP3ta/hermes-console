import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum HermesFileTreeNodeKind { directory, file }

@immutable
class HermesFileTreeNode {
  const HermesFileTreeNode({
    required this.id,
    required this.name,
    required this.kind,
    this.children = const [],
  });

  final String id;
  final String name;
  final HermesFileTreeNodeKind kind;
  final List<HermesFileTreeNode> children;

  bool get isDirectory => kind == HermesFileTreeNodeKind.directory;
}

final class _FlatTreeLine {
  const _FlatTreeLine(this.depth, this.name, this.explicitDirectory);

  final int depth;
  final String name;
  final bool explicitDirectory;
}

final class _MutableTreeNode {
  _MutableTreeNode({
    required this.id,
    required this.name,
    required this.explicitDirectory,
  });

  final String id;
  final String name;
  final bool explicitDirectory;
  final List<_MutableTreeNode> children = [];

  HermesFileTreeNode freeze() => HermesFileTreeNode(
    id: id,
    name: name,
    kind: explicitDirectory || children.isNotEmpty
        ? HermesFileTreeNodeKind.directory
        : HermesFileTreeNodeKind.file,
    children: children.map((child) => child.freeze()).toList(growable: false),
  );
}

/// Convierte únicamente un bloque explícito `tree`/`filetree` en una
/// jerarquía local. No consulta rutas ni interpreta prosa Markdown.
List<HermesFileTreeNode>? parseHermesFileTree(
  String source, {
  int maxNodes = 300,
  int maxDepth = 12,
  int maxNameLength = 160,
}) {
  final flat = <_FlatTreeLine>[];
  for (final raw in source.split('\n')) {
    if (flat.length >= maxNodes) break;
    final line = raw.replaceAll('\t', '    ').trimRight();
    if (line.trim().isEmpty) continue;

    var depth = 0;
    var name = line.trimLeft();
    final branch = RegExp(r'(├──|└──|\|--|`--)\s*').firstMatch(line);
    if (branch != null) {
      final prefix = line.substring(0, branch.start);
      depth = (prefix.length ~/ 4) + 1;
      name = line.substring(branch.end);
    } else {
      final leading = line.length - name.length;
      depth = leading ~/ 2;
    }

    if (depth > maxDepth || name.isEmpty) return null;
    final explicitDirectory = name.endsWith('/');
    if (explicitDirectory) name = name.substring(0, name.length - 1);
    name = name.trim();
    if (name.isEmpty || name == '..' || (name == '.' && flat.isNotEmpty)) {
      return null;
    }
    if (name.length > maxNameLength) {
      name = '${name.substring(0, maxNameLength - 1)}…';
    }
    flat.add(_FlatTreeLine(depth, name, explicitDirectory));
  }
  if (flat.isEmpty) return null;

  // Un árbol copiado de terminal suele empezar por `.` y después ramas. El
  // punto no aporta una fila útil, pero sí actúa como raíz para su profundidad.
  final roots = <_MutableTreeNode>[];
  final stack = <_MutableTreeNode>[];
  var nextId = 0;
  for (var index = 0; index < flat.length; index++) {
    final entry = flat[index];
    final isDotRoot = index == 0 && entry.depth == 0 && entry.name == '.';
    if (isDotRoot) continue;
    final normalizedDepth = flat.first.name == '.' && entry.depth > 0
        ? entry.depth - 1
        : entry.depth;
    if (normalizedDepth > stack.length) return null;
    while (stack.length > normalizedDepth) {
      stack.removeLast();
    }

    final node = _MutableTreeNode(
      id: 'tree-${nextId++}',
      name: entry.name,
      explicitDirectory: entry.explicitDirectory,
    );
    if (normalizedDepth == 0) {
      roots.add(node);
    } else {
      stack[normalizedDepth - 1].children.add(node);
    }
    stack.add(node);
  }

  if (roots.isEmpty) return null;
  return roots.map((node) => node.freeze()).toList(growable: false);
}

class HermesFileTree extends StatefulWidget {
  const HermesFileTree({required this.nodes, super.key});

  final List<HermesFileTreeNode> nodes;

  @override
  State<HermesFileTree> createState() => _HermesFileTreeState();
}

class _HermesFileTreeState extends State<HermesFileTree> {
  late Set<String> _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = <String>{};
    void expandDirectories(HermesFileTreeNode node) {
      if (node.isDirectory) _expanded.add(node.id);
      for (final child in node.children) {
        expandDirectories(child);
      }
    }

    for (final node in widget.nodes) {
      expandDirectories(node);
    }
  }

  @override
  void didUpdateWidget(covariant HermesFileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    final validIds = <String>{};
    void collect(HermesFileTreeNode node) {
      validIds.add(node.id);
      for (final child in node.children) {
        collect(child);
      }
    }

    for (final node in widget.nodes) {
      collect(node);
    }
    _expanded = _expanded.intersection(validIds);
  }

  void _toggle(String id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
  }

  List<Widget> _rows(
    BuildContext context,
    List<HermesFileTreeNode> nodes,
    int depth,
  ) {
    final rows = <Widget>[];
    for (final node in nodes) {
      final expanded = _expanded.contains(node.id);
      rows.add(_FileTreeRow(node: node, depth: depth, expanded: expanded));
      if (node.isDirectory && expanded) {
        rows.addAll(_rows(context, node.children, depth + 1));
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          key: const ValueKey('hermes-file-tree'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _rows(context, widget.nodes, 0),
        ),
      ),
    );
  }
}

class _FileTreeRow extends StatelessWidget {
  const _FileTreeRow({
    required this.node,
    required this.depth,
    required this.expanded,
  });

  final HermesFileTreeNode node;
  final int depth;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final state = context.findAncestorStateOfType<_HermesFileTreeState>();
    final icon = node.isDirectory
        ? expanded
              ? HIcons.folder_open_outlined
              : HIcons.folder_outlined
        : _fileIcon(node.name);

    return Semantics(
      button: node.isDirectory,
      expanded: node.isDirectory ? expanded : null,
      label: node.name,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: node.isDirectory ? () => state?._toggle(node.id) : null,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 42),
            child: Padding(
              padding: EdgeInsets.fromLTRB(8 + depth * 18, 5, 8, 5),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: node.isDirectory
                        ? Icon(
                            expanded
                                ? HIcons.keyboard_arrow_down_rounded
                                : HIcons.keyboard_arrow_right_rounded,
                            size: 18,
                            color: colors.textSecondary,
                          )
                        : null,
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    icon,
                    size: 19,
                    color: node.isDirectory
                        ? colors.accentHover
                        : colors.textSecondary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        fontWeight: node.isDirectory
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

IconData _fileIcon(String name) {
  final extension = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  return switch (extension) {
    'md' || 'txt' || 'rst' => HIcons.description_outlined,
    'png' || 'jpg' || 'jpeg' || 'webp' || 'gif' => HIcons.image_outlined,
    'json' || 'yaml' || 'yml' || 'toml' => HIcons.data_object_rounded,
    'dart' || 'py' || 'js' || 'ts' || 'rs' || 'kt' => HIcons.code_rounded,
    _ => HIcons.insert_drive_file_outlined,
  };
}
