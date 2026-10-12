// Connector policy rules, ported from Hermes Desktop's `join.ts` and
// `derive-tools.ts`. Pure data and functions: the screen only renders what
// these answer, and only the member layer is ever written.
//
// Layers: `org` and `role` are locks the member cannot change; `member` is
// the user's own rules. A policy without a member layer is read-only.

enum PolicyLayerKind { org, role, member }

enum PolicyMode { unrestricted, denyAll, allow, deny, unknown }

final class PolicyLayer {
  final PolicyLayerKind kind;
  final String revision;
  final PolicyMode mode;

  /// `allow` mode: the connectors that stay on.
  final Set<String> connectors;

  /// `deny` mode: the connectors that are off.
  final Set<String> disabledConnectors;

  /// Connector slug → tool slugs switched off.
  final Map<String, Set<String>> tools;
  final Set<String> tagsEnable;
  final Set<String> tagsDisable;

  const PolicyLayer({
    required this.kind,
    required this.revision,
    required this.mode,
    this.connectors = const {},
    this.disabledConnectors = const {},
    this.tools = const {},
    this.tagsEnable = const {},
    this.tagsDisable = const {},
  });

  static Set<String> _strings(Object? value) => value is List
      ? {
          for (final item in value)
            if (item is String && item.isNotEmpty) item,
        }
      : const {};

  static PolicyLayer? tryParse(Object? json) {
    if (json is! Map) return null;
    final kind = switch (json['kind']) {
      'org' => PolicyLayerKind.org,
      'role' => PolicyLayerKind.role,
      'member' => PolicyLayerKind.member,
      _ => null,
    };
    final body = json['body'];
    if (kind == null || body is! Map) return null;
    final mode = switch (body['mode']) {
      'unrestricted' => PolicyMode.unrestricted,
      'deny-all' => PolicyMode.denyAll,
      'allow' => PolicyMode.allow,
      'deny' => PolicyMode.deny,
      _ => PolicyMode.unknown,
    };
    final rawTools = body['tools'];
    final tags = body['tags'];
    return PolicyLayer(
      kind: kind,
      revision: json['revision'] is String ? json['revision'] as String : '',
      mode: mode,
      connectors: _strings(body['connectors']),
      disabledConnectors: _strings(body['disabled_connectors']),
      tools: rawTools is Map
          ? {
              for (final entry in rawTools.entries)
                if (entry.key is String)
                  entry.key as String: _strings(entry.value),
            }
          : const {},
      tagsEnable: tags is Map ? _strings(tags['enable']) : const {},
      tagsDisable: tags is Map ? _strings(tags['disable']) : const {},
    );
  }

  /// Whether this layer lets [slug] through at the connector level.
  bool allowsConnector(String slug) => switch (mode) {
    PolicyMode.unrestricted => true,
    PolicyMode.denyAll => false,
    PolicyMode.allow => connectors.contains(slug),
    PolicyMode.deny => !disabledConnectors.contains(slug),
    // Cannot be verified: a lock fails closed, the member layer is
    // read-only anyway.
    PolicyMode.unknown => kind == PolicyLayerKind.member,
  };
}

typedef ConnectorSwitchState = ({bool enabled, bool locked});

final class ConnectorPolicy {
  final List<PolicyLayer> layers;

  const ConnectorPolicy(this.layers);

  factory ConnectorPolicy.fromJson(Map<String, dynamic> json) {
    final raw = json['layers'];
    return ConnectorPolicy([
      if (raw is List) ...raw.map(PolicyLayer.tryParse).nonNulls,
    ]);
  }

  PolicyLayer? get member {
    for (final layer in layers) {
      if (layer.kind == PolicyLayerKind.member) return layer;
    }
    return null;
  }

  Iterable<PolicyLayer> get _locks =>
      layers.where((layer) => layer.kind != PolicyLayerKind.member);

  /// Member rules exist and are understood; otherwise everything is read-only.
  bool get writable {
    final layer = member;
    return layer != null && layer.mode != PolicyMode.unknown;
  }

  /// Revision the next write must quote (the member layer's).
  String? get memberRevision => member?.revision;

  ConnectorSwitchState connectorState(String slug) {
    final locked = _locks.any((layer) => !layer.allowsConnector(slug));
    final memberAllows = member?.allowsConnector(slug) ?? true;
    return (enabled: !locked && memberAllows, locked: locked);
  }

  bool toolLocked(String slug, ConnectorTool tool) {
    for (final layer in _locks) {
      if (layer.tools[slug]?.contains(tool.slug) ?? false) return true;
      if (tool.hints.any(layer.tagsDisable.contains)) return true;
      if (layer.tagsEnable.isNotEmpty &&
          !tool.hints.any(layer.tagsEnable.contains)) {
        return true;
      }
    }
    return false;
  }

  Set<String> memberDisabledTools(String slug) => {...?member?.tools[slug]};

  /// A tool is on when no lock covers it and the draft has not switched it
  /// off.
  bool toolEnabled(String slug, ConnectorTool tool, Set<String> draft) =>
      !toolLocked(slug, tool) && !draft.contains(tool.slug);
}

enum ToolFacet { read, write, destructive, unclassified }

final class ConnectorTool {
  final String slug;
  final String name;
  final String description;
  final ToolFacet facet;
  final List<String> hints;
  final bool deprecated;

  const ConnectorTool({
    required this.slug,
    required this.name,
    this.description = '',
    this.facet = ToolFacet.unclassified,
    this.hints = const [],
    this.deprecated = false,
  });

  factory ConnectorTool.fromJson(Map<String, dynamic> json) {
    final slug = json['slug'] is String ? json['slug'] as String : '';
    final name = json['name'] is String ? json['name'] as String : '';
    final hints = json['hints'];
    return ConnectorTool(
      slug: slug,
      name: name.isEmpty ? slug : name,
      description: json['description'] is String
          ? json['description'] as String
          : '',
      facet: switch (json['facet']) {
        'read' => ToolFacet.read,
        'write' => ToolFacet.write,
        'destructive' => ToolFacet.destructive,
        _ => ToolFacet.unclassified,
      },
      hints: hints is List ? hints.whereType<String>().toList() : const [],
      deprecated: json['deprecated'] == true,
    );
  }
}

final class ToolGroup {
  final ToolFacet facet;
  final List<ConnectorTool> tools;

  const ToolGroup(this.facet, this.tools);
}

/// Visible tools per facet in a fixed order; deprecated tools are left out
/// (they stay in the draft untouched).
List<ToolGroup> groupToolsByFacet(List<ConnectorTool> tools) => [
  for (final facet in ToolFacet.values)
    if (tools.any((t) => t.facet == facet && !t.deprecated))
      ToolGroup(facet, [
        for (final tool in tools)
          if (tool.facet == facet && !tool.deprecated) tool,
      ]),
];

/// The full `disabled_tools` list a Save sends: everything in the draft,
/// including entries the screen does not show.
List<String> disabledToolsToSave(Set<String> draft) => draft.toList()..sort();
