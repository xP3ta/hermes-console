import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/connector_policy.dart';

Map<String, dynamic> _layer(
  String kind,
  Map<String, dynamic> body, {
  String revision = '01HZX0000000000000000000AA',
}) => {'kind': kind, 'revision': revision, 'body': body};

ConnectorPolicy _policy(List<Map<String, dynamic>> layers) =>
    ConnectorPolicy.fromJson({'layers': layers});

ConnectorTool _tool(
  String slug, {
  String facet = 'read',
  List<String> hints = const [],
  bool deprecated = false,
}) => ConnectorTool.fromJson({
  'slug': slug,
  'name': slug,
  'description': '',
  'facet': facet,
  'hints': hints,
  'deprecated': deprecated,
});

void main() {
  group('layers', () {
    test('member layer is writable, org and role are locks', () {
      final policy = _policy([
        _layer('org', {'mode': 'unrestricted'}, revision: 'ORG'),
        _layer('member', {'mode': 'unrestricted'}, revision: 'MEM'),
      ]);
      expect(policy.writable, isTrue);
      expect(policy.memberRevision, 'MEM');
    });

    test('no member layer means read-only', () {
      final policy = _policy([
        _layer('org', {'mode': 'unrestricted'}),
      ]);
      expect(policy.writable, isFalse);
      expect(policy.memberRevision, isNull);
    });

    test('an unknown mode on the member layer is never written to', () {
      final policy = _policy([
        _layer('member', {'mode': 'mystery'}),
      ]);
      expect(policy.writable, isFalse);
    });

    test('unknown layer kinds are ignored, junk input is tolerated', () {
      final policy = _policy([
        _layer('galaxy', {'mode': 'deny-all'}),
      ]);
      expect(policy.layers, isEmpty);
      expect(ConnectorPolicy.fromJson(const {}).layers, isEmpty);
    });
  });

  group('connector switch', () {
    test('no member layer: on unless an org layer blocks it', () {
      final policy = _policy([
        _layer('org', {'mode': 'unrestricted'}),
      ]);
      final state = policy.connectorState('gmail');
      expect(state.enabled, isTrue);
      expect(state.locked, isFalse);
    });

    test('member allow list and deny list', () {
      final allow = _policy([
        _layer('member', {
          'mode': 'allow',
          'connectors': ['github'],
          'tools': <String, dynamic>{},
        }),
      ]);
      expect(allow.connectorState('github').enabled, isTrue);
      expect(allow.connectorState('gmail').enabled, isFalse);
      expect(allow.connectorState('gmail').locked, isFalse);

      final deny = _policy([
        _layer('member', {
          'mode': 'deny',
          'disabled_connectors': ['github'],
          'tools': <String, dynamic>{},
        }),
      ]);
      expect(deny.connectorState('github').enabled, isFalse);
      expect(deny.connectorState('gmail').enabled, isTrue);
    });

    test('member deny-all switches everything off without locking', () {
      final policy = _policy([
        _layer('member', {'mode': 'deny-all'}),
      ]);
      expect(policy.connectorState('github').enabled, isFalse);
      expect(policy.connectorState('github').locked, isFalse);
    });

    test('org or role layers that do not allow it lock the switch', () {
      final orgAllow = _policy([
        _layer('org', {
          'mode': 'allow',
          'connectors': ['github'],
          'tools': <String, dynamic>{},
        }),
        _layer('member', {'mode': 'unrestricted'}),
      ]);
      expect(orgAllow.connectorState('github').locked, isFalse);
      expect(orgAllow.connectorState('gmail').locked, isTrue);
      expect(orgAllow.connectorState('gmail').enabled, isFalse);

      final roleDeny = _policy([
        _layer('role', {
          'mode': 'deny',
          'disabled_connectors': ['gmail'],
          'tools': <String, dynamic>{},
        }),
        _layer('member', {'mode': 'unrestricted'}),
      ]);
      expect(roleDeny.connectorState('gmail').locked, isTrue);

      final orgDenyAll = _policy([
        _layer('org', {'mode': 'deny-all'}),
      ]);
      expect(orgDenyAll.connectorState('github').locked, isTrue);
    });
  });

  group('tools', () {
    test('a tool listed by a non-member layer is locked and off', () {
      final policy = _policy([
        _layer('org', {
          'mode': 'deny',
          'disabled_connectors': <String>[],
          'tools': {
            'github': ['delete_repo'],
          },
        }),
        _layer('member', {'mode': 'unrestricted'}),
      ]);
      final locked = _tool('delete_repo');
      final free = _tool('list_repos');
      expect(policy.toolLocked('github', locked), isTrue);
      expect(policy.toolLocked('gmail', locked), isFalse);
      expect(policy.toolLocked('github', free), isFalse);
      expect(policy.toolEnabled('github', locked, const {}), isFalse);
      expect(policy.toolEnabled('github', free, const {}), isTrue);
    });

    test('tag rules lock by hints: disable matches, enable must match', () {
      final disable = _policy([
        _layer('org', {
          'mode': 'deny',
          'disabled_connectors': <String>[],
          'tools': <String, dynamic>{},
          'tags': {
            'disable': ['destructive'],
          },
        }),
      ]);
      expect(
        disable.toolLocked('x', _tool('a', hints: ['destructive', 'write'])),
        isTrue,
      );
      expect(disable.toolLocked('x', _tool('b', hints: ['read'])), isFalse);

      final enable = _policy([
        _layer('role', {
          'mode': 'deny',
          'disabled_connectors': <String>[],
          'tools': <String, dynamic>{},
          'tags': {
            'enable': ['read'],
          },
        }),
      ]);
      expect(enable.toolLocked('x', _tool('a', hints: ['read'])), isFalse);
      expect(enable.toolLocked('x', _tool('b', hints: ['write'])), isTrue);
      expect(enable.toolLocked('x', _tool('c')), isTrue);

      final emptyEnable = _policy([
        _layer('role', {
          'mode': 'deny',
          'disabled_connectors': <String>[],
          'tools': <String, dynamic>{},
          'tags': {'enable': <String>[]},
        }),
      ]);
      expect(emptyEnable.toolLocked('x', _tool('d')), isFalse);
    });

    test('member rules never lock; they switch tools off', () {
      final policy = _policy([
        _layer('member', {
          'mode': 'deny',
          'disabled_connectors': <String>[],
          'tools': {
            'github': ['list_repos'],
          },
        }),
      ]);
      final tool = _tool('list_repos');
      expect(policy.toolLocked('github', tool), isFalse);
      expect(policy.memberDisabledTools('github'), {'list_repos'});
      expect(policy.toolEnabled('github', tool, const {'list_repos'}), isFalse);
      // The draft decides, not the stored list.
      expect(policy.toolEnabled('github', tool, const {}), isTrue);
    });

    test('deprecated tools are hidden and facets group in a fixed order', () {
      final tools = [
        _tool('a', facet: 'write'),
        _tool('b', facet: 'read'),
        _tool('c', facet: 'destructive'),
        _tool('d', facet: 'weird'),
        _tool('e', facet: 'read', deprecated: true),
      ];
      final groups = groupToolsByFacet(tools);
      expect(groups.map((g) => g.facet), [
        ToolFacet.read,
        ToolFacet.write,
        ToolFacet.destructive,
        ToolFacet.unclassified,
      ]);
      expect(groups.expand((g) => g.tools).map((t) => t.slug), [
        'b',
        'a',
        'c',
        'd',
      ]);
    });
  });

  test('saving keeps member-disabled tools the screen cannot show', () {
    final policy = _policy([
      _layer('member', {
        'mode': 'deny',
        'disabled_connectors': <String>[],
        'tools': {
          'github': ['old_deprecated', 'list_repos'],
        },
      }),
    ]);
    final draft = {...policy.memberDisabledTools('github')}
      ..remove('list_repos')
      ..add('create_issue');
    expect(
      disabledToolsToSave(draft),
      unorderedEquals(['old_deprecated', 'create_issue']),
    );
    expect(disabledToolsToSave(draft), orderedEquals(draft.toList()..sort()));
  });
}
