// "Tu constelación": the agent's learning graph as a star map you can turn,
// zoom and tap. Opened from the Memory screen; it asks the server for the
// graph only when it opens, so the Memory screen itself stays as it was.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/ambient_backdrop.dart' show hermesTonalButtonStyle;
import '../design/tokens.dart' show HermesRadius, HermesSpace, HermesType;
import '../memory/constellation_graph.dart';
import '../memory/constellation_view.dart';
import '../theme/constellation_tokens.dart';
import '../theme/motion.dart' show HermesMotion;

class ConstellationScreen extends StatefulWidget {
  const ConstellationScreen({
    required this.loadGraph,
    this.onEditNode,
    super.key,
  });

  /// Opens the editor for a memory node; true when it changed something, so
  /// the map is read again. Null hides the edit action.
  final Future<bool> Function(ConstellationNode node)? onEditNode;

  /// The raw learning graph (`nodes`, `edges`) as the server sends it.
  final Future<Map<String, dynamic>> Function() loadGraph;

  @override
  State<ConstellationScreen> createState() => _ConstellationScreenState();
}

class _ConstellationScreenState extends State<ConstellationScreen> {
  final ConstellationViewController _controller = ConstellationViewController();
  final Set<ConstellationKind> _visible = {...ConstellationKind.values};
  ConstellationGraph? _graph;
  ConstellationNode? _selected;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _graph = null;
      _selected = null;
      _failed = false;
    });
    try {
      final minimum = Future<void>.delayed(ConstellationTokens.minimumLoad);
      final json = await widget.loadGraph();
      final graph = ConstellationGraph.fromJson(json);
      await minimum;
      if (!mounted) return;
      setState(() => _graph = graph);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  String _kindLabel(ConstellationKind kind, Strings s) {
    switch (kind) {
      case ConstellationKind.memory:
        return s.constellationKindMemory;
      case ConstellationKind.skill:
        return s.constellationKindSkill;
      case ConstellationKind.other:
        return s.constellationKindOther;
    }
  }

  bool _canEdit(ConstellationNode node) =>
      widget.onEditNode != null &&
      node.kind == ConstellationKind.memory &&
      node.id.startsWith('memory:') &&
      (node.source == 'memory' || node.source == 'profile');

  Future<void> _edit(ConstellationNode node) async {
    final changed = await widget.onEditNode!(node);
    if (changed && mounted) await _load();
  }

  void _toggle(ConstellationKind kind) {
    setState(() {
      if (_visible.contains(kind)) {
        // Never hide every kind: the map would be empty and look broken.
        if (_visible.length > 1) _visible.remove(kind);
      } else {
        _visible.add(kind);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final graph = _graph;
    return Scaffold(
      backgroundColor: constellationNight,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody(s, graph)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(bottom: false, child: _buildTopBar(s, graph)),
          ),
          if (graph != null && !graph.isEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: _buildBottom(s, graph)),
            ),
        ],
      ),
    );
  }

  Widget _buildTopBar(Strings s, ConstellationGraph? graph) {
    final count = graph == null || graph.isEmpty
        ? ''
        : (graph.total > graph.nodes.length
              ? '${graph.nodes.length} / ${graph.total}'
              : '${graph.nodes.length}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x2,
        HermesSpace.x2,
        HermesSpace.x4,
        0,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 20,
              color: Colors.white,
            ),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: HermesSpace.x1),
          Expanded(
            child: Text(
              s.constellationTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: HermesType.titleSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            count,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: HermesType.supportSize,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Strings s, ConstellationGraph? graph) {
    final muted = TextStyle(
      color: Colors.white.withValues(alpha: 0.7),
      fontSize: HermesType.valueSize,
    );
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(s.dependencyLoadFailedTitle, style: muted),
            const SizedBox(height: HermesSpace.x3),
            FilledButton.tonal(
              style: hermesTonalButtonStyle,
              onPressed: _load,
              child: Text(s.dependencyRetry),
            ),
          ],
        ),
      );
    }
    if (graph == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ConstellationLoader(),
            const SizedBox(height: HermesSpace.x4),
            Text(s.constellationLoading, style: muted),
          ],
        ),
      );
    }
    if (graph.isEmpty) {
      return Center(child: Text(s.constellationEmpty, style: muted));
    }
    return Semantics(
      container: true,
      label: s.constellationHint,
      child: ConstellationView(
        graph: graph,
        visibleKinds: _visible,
        controller: _controller,
        onSelected: (node) => setState(() => _selected = node),
      ),
    );
  }

  Widget _buildBottom(Strings s, ConstellationGraph graph) {
    final present = [
      for (final kind in ConstellationKind.values)
        if (graph.nodes.any((node) => node.kind == kind)) kind,
    ];
    final selected = _selected;
    return Padding(
      padding: const EdgeInsets.all(HermesSpace.x3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected != null) ...[
            _buildDetail(s, selected),
            const SizedBox(height: HermesSpace.x3),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Wrap(
                  spacing: HermesSpace.x2,
                  runSpacing: HermesSpace.x2,
                  children: [for (final kind in present) _buildChip(s, kind)],
                ),
              ),
              IconButton(
                tooltip: s.constellationRecenter,
                icon: const Icon(
                  Icons.center_focus_strong_outlined,
                  color: Colors.white,
                ),
                onPressed: _controller.recenter,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDetail(Strings s, ConstellationNode node) {
    return Container(
      padding: const EdgeInsets.all(HermesSpace.x4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(HermesRadius.card),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: constellationColorOf(node.kind),
            ),
          ),
          const SizedBox(width: HermesSpace.x3),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: HermesType.bodySize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _kindLabel(node.kind, s),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: HermesType.supportSize,
                  ),
                ),
              ],
            ),
          ),
          if (_canEdit(node))
            TextButton(
              key: const ValueKey('constellation-edit-node'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => _edit(node),
              child: Text(s.memShareEditNode),
            ),
        ],
      ),
    );
  }

  Widget _buildChip(Strings s, ConstellationKind kind) {
    final on = _visible.contains(kind);
    final label = _kindLabel(kind, s);
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      onTap: () => _toggle(kind),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggle(kind),
        child: AnimatedOpacity(
          opacity: on ? 1 : 0.4,
          duration: HermesMotion.fast,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x3,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(HermesRadius.tag),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: constellationColorOf(kind),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: HermesType.captionSize,
                    fontWeight: FontWeight.w600,
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
