import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/memory/constellation_graph.dart';

Map<String, dynamic> _graph(List<Object?> nodes, [Object? edges]) => {
  'nodes': nodes,
  'edges': edges ?? const <Object?>[],
};

void main() {
  group('constellationKindOf', () {
    test('maps the server kinds and sends anything else to other', () {
      expect(constellationKindOf('memory'), ConstellationKind.memory);
      expect(constellationKindOf(' Skill '), ConstellationKind.skill);
      expect(constellationKindOf('session'), ConstellationKind.other);
      expect(constellationKindOf(null), ConstellationKind.other);
    });
  });

  group('ConstellationGraph.fromJson', () {
    test('reads kind, first line of the label and weight', () {
      final graph = ConstellationGraph.fromJson(
        _graph([
          {'id': 'a', 'label': 'Prefers short\nsecond line', 'kind': 'memory'},
          {'id': 'b', 'label': 'deploy', 'kind': 'skill', 'uses': 12},
          {'id': 'c', 'kind': 'tool'},
          {'id': '', 'label': 'no id'},
          {'id': 'a', 'label': 'duplicate'},
          'not a map',
        ]),
      );
      expect(graph.nodes.map((n) => n.id), ['a', 'b', 'c']);
      expect(graph.nodes[0].label, 'Prefers short');
      expect(graph.nodes[0].kind, ConstellationKind.memory);
      expect(graph.nodes[1].weight, 12);
      expect(graph.nodes[0].weight, 1);
      expect(graph.nodes[2].label, 'c');
      expect(graph.nodes[2].kind, ConstellationKind.other);
      expect(graph.total, 3);
    });

    test('keeps edges by id or object end, once, and never to nowhere', () {
      final graph = ConstellationGraph.fromJson(
        _graph(
          [
            {'id': 'a', 'kind': 'memory'},
            {'id': 'b', 'kind': 'skill'},
            {'id': 'c', 'kind': 'skill'},
          ],
          [
            {'source': 'a', 'target': 'b'},
            {'from': 'b', 'to': 'a'},
            {
              'source': {'id': 'a'},
              'target': {'id': 'c'},
            },
            {'source': 'a', 'target': 'zzz'},
            {'source': 'a', 'target': 'a'},
            'not a map',
          ],
        ),
      );
      expect(graph.edges.length, 2);
      expect(graph.edgesDerived, isFalse);
      expect(graph.edges.every((e) => e.a < e.b), isTrue);
    });

    test('without edges it draws the nearest neighbours and says so', () {
      final graph = ConstellationGraph.fromJson(
        _graph([
          for (var i = 0; i < 6; i++)
            {'id': 'n$i', 'kind': i.isEven ? 'memory' : 'skill'},
        ]),
      );
      expect(graph.edgesDerived, isTrue);
      expect(graph.edges, isNotEmpty);
      final linked = <int>{
        for (final edge in graph.edges) ...[edge.a, edge.b],
      };
      expect(linked.length, graph.nodes.length);
    });

    test('keeps the heaviest nodes when there are too many', () {
      final graph = ConstellationGraph.fromJson(
        _graph([
          for (var i = 0; i < 349; i++) {'id': 'n$i', 'uses': 1 + i % 5},
          {'id': 'heavy', 'uses': 999},
        ]),
      );
      expect(graph.total, 350);
      expect(graph.nodes.length, ConstellationGraph.maxNodes);
      expect(graph.nodes.any((n) => n.id == 'heavy'), isTrue);
    });

    test('lays every node inside the unit sphere, the same way each time', () {
      final json = _graph(
        [
          for (var i = 0; i < 40; i++)
            {
              'id': 'n$i',
              'kind': ['memory', 'skill', 'x'][i % 3],
            },
        ],
        [
          for (var i = 1; i < 40; i++) {'source': 'n${i - 1}', 'target': 'n$i'},
        ],
      );
      final first = ConstellationGraph.fromJson(json);
      final second = ConstellationGraph.fromJson(json);
      for (var i = 0; i < first.nodes.length; i++) {
        final n = first.nodes[i];
        expect(
          math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z),
          lessThanOrEqualTo(1 + 1e-9),
        );
        expect(second.nodes[i].x, n.x);
        expect(second.nodes[i].y, n.y);
        expect(second.nodes[i].z, n.z);
      }
    });

    test('an answer without nodes is an empty graph, not an error', () {
      expect(ConstellationGraph.fromJson(const {}).isEmpty, isTrue);
      expect(ConstellationGraph.fromJson(const {'nodes': 'x'}).isEmpty, isTrue);
      expect(ConstellationGraph.fromJson(_graph(const [])).edges, isEmpty);
    });
  });
}
