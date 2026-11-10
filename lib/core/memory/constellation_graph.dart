// The learning graph (GET /api/learning/graph) as a small 3D constellation.
//
// Pure Dart, no Flutter: the server sends `nodes` (id, label, kind…) and
// `edges`; this file reads them defensively, keeps the heaviest nodes when
// there are too many, and lays them out in 3D once, so the view only has to
// rotate and project.
import 'dart:math' as math;

/// What a node is: it sets its colour and the filter it belongs to.
enum ConstellationKind { memory, skill, other }

/// The kind a server `kind` string stands for; anything unknown is [other].
ConstellationKind constellationKindOf(Object? raw) {
  switch ('$raw'.trim().toLowerCase()) {
    case 'memory':
      return ConstellationKind.memory;
    case 'skill':
      return ConstellationKind.skill;
    default:
      return ConstellationKind.other;
  }
}

/// One star. [x], [y], [z] are laid out inside a sphere of radius 1.
class ConstellationNode {
  const ConstellationNode({
    required this.id,
    required this.label,
    required this.kind,
    required this.weight,
    required this.x,
    required this.y,
    required this.z,
    this.source = '',
  });

  final String id;
  final String label;
  final ConstellationKind kind;

  /// The memory file the server says a memory node lives in (`memory` or
  /// `profile`); empty for every other node.
  final String source;

  /// How much it is used (1 when the server says nothing): sets its size.
  final double weight;
  final double x;
  final double y;
  final double z;
}

/// A line between two stars, by index in [ConstellationGraph.nodes];
/// [a] is always smaller than [b].
class ConstellationEdge {
  const ConstellationEdge(this.a, this.b);

  final int a;
  final int b;
}

class ConstellationGraph {
  const ConstellationGraph({
    required this.nodes,
    required this.edges,
    required this.total,
    required this.edgesDerived,
  });

  /// The stars drawn: at most [maxNodes].
  final List<ConstellationNode> nodes;
  final List<ConstellationEdge> edges;

  /// How many nodes the server sent (may be more than [nodes]).
  final int total;

  /// True when the server sent no edges and the lines are only the nearest
  /// neighbours, drawn so the stars do not float alone.
  final bool edgesDerived;

  bool get isEmpty => nodes.isEmpty;

  /// A phone keeps 60 frames a second with this many stars.
  static const int maxNodes = 300;

  factory ConstellationGraph.fromJson(Map<String, dynamic> json) {
    final records = <_RawNode>[];
    final seen = <String>{};
    final rawNodes = json['nodes'];
    if (rawNodes is List) {
      for (final node in rawNodes) {
        if (node is! Map) continue;
        final id = '${node['id'] ?? ''}'.trim();
        if (id.isEmpty || !seen.add(id)) continue;
        final first = '${node['label'] ?? node['name'] ?? id}'
            .split('\n')
            .first
            .trim();
        records.add(
          _RawNode(
            id,
            first.isEmpty ? id : first,
            constellationKindOf(node['kind']),
            _weightOf(node),
            '${node['memorySource'] ?? ''}'.trim(),
          ),
        );
      }
    }
    final total = records.length;

    final List<_RawNode> kept;
    if (records.length > maxNodes) {
      final order = List<int>.generate(records.length, (i) => i)
        ..sort((a, b) {
          final byWeight = records[b].weight.compareTo(records[a].weight);
          return byWeight != 0 ? byWeight : a.compareTo(b);
        });
      final keep = order.take(maxNodes).toList()..sort();
      kept = [for (final i in keep) records[i]];
    } else {
      kept = records;
    }

    final count = kept.length;
    final index = <String, int>{for (var i = 0; i < count; i++) kept[i].id: i};
    final pairs = <int>{};
    final edges = <ConstellationEdge>[];
    void add(int a, int b) {
      if (a == b) return;
      final lo = math.min(a, b);
      final hi = math.max(a, b);
      if (pairs.add(lo * count + hi)) edges.add(ConstellationEdge(lo, hi));
    }

    final rawEdges = json['edges'] ?? json['links'];
    if (rawEdges is List) {
      for (final edge in rawEdges) {
        if (edge is! Map) continue;
        final a = index[_endpointId(edge['source'] ?? edge['from'])];
        final b = index[_endpointId(edge['target'] ?? edge['to'])];
        if (a != null && b != null) add(a, b);
      }
    }

    final xs = List<double>.filled(count, 0);
    final ys = List<double>.filled(count, 0);
    final zs = List<double>.filled(count, 0);
    _layout(kept, edges, xs, ys, zs);

    var derived = false;
    if (edges.isEmpty && count > 1) {
      derived = true;
      for (var i = 0; i < count; i++) {
        var first = -1;
        var second = -1;
        var firstD = double.infinity;
        var secondD = double.infinity;
        for (var j = 0; j < count; j++) {
          if (j == i) continue;
          final dx = xs[i] - xs[j];
          final dy = ys[i] - ys[j];
          final dz = zs[i] - zs[j];
          final d = dx * dx + dy * dy + dz * dz;
          if (d < firstD) {
            second = first;
            secondD = firstD;
            first = j;
            firstD = d;
          } else if (d < secondD) {
            second = j;
            secondD = d;
          }
        }
        if (first >= 0) add(i, first);
        if (second >= 0) add(i, second);
      }
    }

    return ConstellationGraph(
      nodes: [
        for (var i = 0; i < count; i++)
          ConstellationNode(
            id: kept[i].id,
            label: kept[i].label,
            kind: kept[i].kind,
            weight: kept[i].weight,
            source: kept[i].source,
            x: xs[i],
            y: ys[i],
            z: zs[i],
          ),
      ],
      edges: edges,
      total: total,
      edgesDerived: derived,
    );
  }

  static const _weightKeys = ['uses', 'usage', 'use_count', 'count', 'weight'];

  static double _weightOf(Map node) {
    for (final key in _weightKeys) {
      final value = node[key];
      if (value is num && value.isFinite && value > 0) return value.toDouble();
    }
    return 1;
  }

  /// An edge end is an id, or (d3 style) an object that carries one.
  static String _endpointId(Object? raw) {
    if (raw is Map) return '${raw['id'] ?? ''}'.trim();
    return '${raw ?? ''}'.trim();
  }

  /// Three kinds, three clouds; the edges then pull what is linked together
  /// and every pair pushes apart. Deterministic for the same graph, and
  /// scaled at the end so the farthest star sits at radius 1.
  static void _layout(
    List<_RawNode> nodes,
    List<ConstellationEdge> edges,
    List<double> x,
    List<double> y,
    List<double> z,
  ) {
    final n = nodes.length;
    if (n == 0) return;
    final random = math.Random(n * 7919 + edges.length);
    const centers = [
      [0.9, 0.0, 0.0],
      [-0.45, 0.78, 0.0],
      [-0.45, -0.78, 0.0],
    ];
    for (var i = 0; i < n; i++) {
      final center = centers[nodes[i].kind.index];
      x[i] = center[0] + (random.nextDouble() - 0.5);
      y[i] = center[1] + (random.nextDouble() - 0.5);
      z[i] = center[2] + (random.nextDouble() - 0.5);
    }
    if (n > 1) {
      final steps = n > 200 ? 60 : 90;
      final fx = List<double>.filled(n, 0);
      final fy = List<double>.filled(n, 0);
      final fz = List<double>.filled(n, 0);
      for (var step = 0; step < steps; step++) {
        final cool = 1 - step / steps;
        for (var i = 0; i < n; i++) {
          fx[i] = -x[i] * 0.01;
          fy[i] = -y[i] * 0.01;
          fz[i] = -z[i] * 0.01;
        }
        for (var i = 0; i < n; i++) {
          for (var j = i + 1; j < n; j++) {
            final dx = x[i] - x[j];
            final dy = y[i] - y[j];
            final dz = z[i] - z[j];
            final push = 0.012 / (dx * dx + dy * dy + dz * dz + 0.02);
            fx[i] += dx * push;
            fy[i] += dy * push;
            fz[i] += dz * push;
            fx[j] -= dx * push;
            fy[j] -= dy * push;
            fz[j] -= dz * push;
          }
        }
        for (final edge in edges) {
          final dx = x[edge.b] - x[edge.a];
          final dy = y[edge.b] - y[edge.a];
          final dz = z[edge.b] - z[edge.a];
          final d = math.sqrt(dx * dx + dy * dy + dz * dz) + 1e-6;
          final pull = (d - 0.35) * 0.05 / d;
          fx[edge.a] += dx * pull;
          fy[edge.a] += dy * pull;
          fz[edge.a] += dz * pull;
          fx[edge.b] -= dx * pull;
          fy[edge.b] -= dy * pull;
          fz[edge.b] -= dz * pull;
        }
        for (var i = 0; i < n; i++) {
          final dx = fx[i] * cool;
          final dy = fy[i] * cool;
          final dz = fz[i] * cool;
          final length = math.sqrt(dx * dx + dy * dy + dz * dz);
          final limit = length > 0.08 ? 0.08 / length : 1.0;
          x[i] += dx * limit;
          y[i] += dy * limit;
          z[i] += dz * limit;
        }
      }
    }
    var cx = 0.0;
    var cy = 0.0;
    var cz = 0.0;
    for (var i = 0; i < n; i++) {
      cx += x[i];
      cy += y[i];
      cz += z[i];
    }
    cx /= n;
    cy /= n;
    cz /= n;
    var radius = 1e-6;
    for (var i = 0; i < n; i++) {
      x[i] -= cx;
      y[i] -= cy;
      z[i] -= cz;
      radius = math.max(
        radius,
        math.sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i]),
      );
    }
    for (var i = 0; i < n; i++) {
      x[i] /= radius;
      y[i] /= radius;
      z[i] /= radius;
    }
  }
}

class _RawNode {
  const _RawNode(this.id, this.label, this.kind, this.weight, this.source);

  final String id;
  final String label;
  final ConstellationKind kind;
  final double weight;
  final String source;
}
