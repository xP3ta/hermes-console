// Capabilities hub (skills · plugins · MCP · connectors) — data models.
//
// Mirrors Hermes Desktop's Capabilities catalog
// (`apps/desktop/src/app/capabilities/catalog/catalog-data.ts`) but reads the
// profile's OWN backend (Dashboard REST + gateway RPC) instead of the 63 MB
// public CDN snapshot, so what Console shows is exactly what the server has.

/// What a catalog row installs.
enum CapabilityKind { skill, plugin, mcp }

/// Trust of a catalog source, derived from the server's own labels
/// (skills `trust_level`, plugin `tier`, optional skills = official).
enum CapabilityTrust { official, trusted, community, local, unknown }

String _text(Object? value, {int max = 600}) {
  if (value == null) return '';
  final raw = value is String ? value : (value is num ? '$value' : '');
  final clean = raw.replaceAll(RegExp(r'[\u0000-\u0008\u000B-\u001F]'), '');
  final trimmed = clean.trim();
  return trimmed.length > max ? '${trimmed.substring(0, max)}…' : trimmed;
}

List<String> _strings(Object? value, {int maxRows = 60, int max = 200}) {
  if (value is! List) return const [];
  return value
      .take(maxRows)
      .map((item) => _text(item, max: max))
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

List<Map<String, dynamic>> _rows(Object? value, {int max = 2000}) {
  if (value is! List) return const [];
  return value
      .take(max)
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList(growable: false);
}

/// `software-development` → `Software development`; domains stay verbatim.
String capabilityLabel(String value) {
  if (value.isEmpty || value.contains('.')) return value;
  final words = value.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  if (words.isEmpty) return value;
  return words[0].toUpperCase() + words.substring(1);
}

CapabilityTrust _trustOf(String raw) => switch (raw.toLowerCase()) {
  'official' ||
  'builtin' ||
  'built-in' ||
  'bundled' ||
  'optional' => CapabilityTrust.official,
  'trusted' || 'verified' || 'featured' => CapabilityTrust.trusted,
  'community' => CapabilityTrust.community,
  'local' || 'agent' || 'user' || 'git' => CapabilityTrust.local,
  _ => CapabilityTrust.unknown,
};

/// Required credential of an MCP catalog entry (names + prompts only).
final class CapabilityEnvField {
  final String name;
  final String prompt;
  final bool required;

  const CapabilityEnvField({
    required this.name,
    this.prompt = '',
    this.required = true,
  });
}

/// One row of the unified catalog / installed list.
final class CapabilityItem {
  final CapabilityKind kind;

  /// Stable identity inside the hub: `<kind>:<source>:<identifier>`.
  final String id;
  final String name;
  final String description;
  final String category;
  final String source;
  final CapabilityTrust trust;
  final String author;
  final String version;

  /// What the install endpoint takes (hub identifier, plugin catalog name,
  /// MCP catalog name). Empty = not installable from Console.
  final String installId;

  /// Name used by toggle / uninstall / remove endpoints once installed.
  final String installedName;
  final bool installed;
  final bool? enabled;
  final bool updateAvailable;

  /// Skill provenance (`hub`, `bundled`, `agent`); only hub skills uninstall.
  final String provenance;
  final bool canRemove;
  final List<String> tags;
  final List<String> tools;
  final List<String> requirements;
  final List<CapabilityEnvField> env;
  final String transport;
  final String command;
  final String url;
  final String docsUrl;

  const CapabilityItem({
    required this.kind,
    required this.id,
    required this.name,
    this.description = '',
    this.category = '',
    this.source = '',
    this.trust = CapabilityTrust.unknown,
    this.author = '',
    this.version = '',
    this.installId = '',
    this.installedName = '',
    this.installed = false,
    this.enabled,
    this.updateAvailable = false,
    this.provenance = '',
    this.canRemove = false,
    this.tags = const [],
    this.tools = const [],
    this.requirements = const [],
    this.env = const [],
    this.transport = '',
    this.command = '',
    this.url = '',
    this.docsUrl = '',
  });

  CapabilityItem copyWith({
    bool? installed,
    bool? enabled,
    bool? updateAvailable,
    String? installedName,
    String? provenance,
    bool? canRemove,
    String? version,
  }) => CapabilityItem(
    kind: kind,
    id: id,
    name: name,
    description: description,
    category: category,
    source: source,
    trust: trust,
    author: author,
    version: version ?? this.version,
    installId: installId,
    installedName: installedName ?? this.installedName,
    installed: installed ?? this.installed,
    enabled: enabled ?? this.enabled,
    updateAvailable: updateAvailable ?? this.updateAvailable,
    provenance: provenance ?? this.provenance,
    canRemove: canRemove ?? this.canRemove,
    tags: tags,
    tools: tools,
    requirements: requirements,
    env: env,
    transport: transport,
    command: command,
    url: url,
    docsUrl: docsUrl,
  );

  String get searchText => [
    name,
    description,
    category,
    source,
    author,
    ...tags,
    ...tools,
  ].join(' ').toLowerCase();

  /// `GET /api/skills` row (installed skill of the profile).
  static CapabilityItem? installedSkill(Map<String, dynamic> json) {
    final name = _text(json['name'], max: 160);
    if (name.isEmpty) return null;
    final provenance = _text(json['provenance'], max: 20).toLowerCase();
    return CapabilityItem(
      kind: CapabilityKind.skill,
      id: 'skill:installed:$name',
      name: name,
      description: _text(json['description']),
      category: _text(json['category'], max: 80),
      source: provenance == 'bundled'
          ? 'built-in'
          : provenance == 'hub'
          ? 'hub'
          : 'local',
      trust: provenance == 'bundled'
          ? CapabilityTrust.official
          : provenance == 'hub'
          ? CapabilityTrust.unknown
          : CapabilityTrust.local,
      installedName: name,
      installed: true,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : null,
      provenance: provenance,
      canRemove: provenance == 'hub',
    );
  }

  /// `GET /api/skills/hub/official` or `/hub/search` row.
  static CapabilityItem? hubSkill(
    Map<String, dynamic> json, {
    bool official = false,
    Set<String> installedIdentifiers = const {},
  }) {
    final name = _text(json['name'], max: 160);
    final identifier = _text(json['identifier'], max: 300);
    if (name.isEmpty || identifier.isEmpty) return null;
    final source = official ? 'official' : _text(json['source'], max: 80);
    final trustRaw = official ? 'official' : _text(json['trust_level']);
    return CapabilityItem(
      kind: CapabilityKind.skill,
      id: 'skill:$source:$identifier',
      name: name,
      description: _text(json['description']),
      category: _text(json['category'], max: 80),
      source: source,
      trust: _trustOf(trustRaw.isEmpty ? source : trustRaw),
      installId: identifier,
      installedName: name,
      installed:
          json['installed'] == true ||
          installedIdentifiers.contains(identifier),
      tags: _strings(json['tags']),
      docsUrl: _text(json['repo'], max: 400),
      provenance: 'hub',
      canRemove: true,
    );
  }

  /// `GET /api/dashboard/plugins/catalog` entry.
  static CapabilityItem? catalogPlugin(Map<String, dynamic> json) {
    final name = _text(json['name'], max: 160);
    if (name.isEmpty) return null;
    final caps = json['capabilities'] is Map
        ? Map<String, dynamic>.from(json['capabilities'] as Map)
        : const <String, dynamic>{};
    final tier = _text(json['tier'], max: 40);
    final title = _text(json['title'], max: 160);
    final status = _text(json['runtime_status'], max: 40).toLowerCase();
    final installed = json['installed'] == true;
    return CapabilityItem(
      kind: CapabilityKind.plugin,
      id: 'plugin:$tier:$name',
      name: title.isNotEmpty ? title : name,
      description: _text(json['description']),
      category: _text(json['category'], max: 80),
      source: tier.isEmpty ? 'community' : tier,
      trust: _trustOf(tier.isEmpty ? 'community' : tier),
      author: _text(json['maintainer'], max: 120),
      version: _text(json['version'], max: 60),
      installId: name,
      installedName: name,
      installed: installed,
      enabled: installed ? status == 'enabled' : null,
      updateAvailable: json['update_available'] == true,
      tools: _strings(caps['provides_tools']),
      requirements: _strings(caps['requires_env']),
      docsUrl: _text(json['docs_url'], max: 400).isNotEmpty
          ? _text(json['docs_url'], max: 400)
          : _text(json['repo'], max: 400),
      canRemove: installed,
    );
  }

  /// `GET /api/dashboard/plugins/hub` row (installed agent plugin).
  static CapabilityItem? installedPlugin(Map<String, dynamic> json) {
    final name = _text(json['name'], max: 160);
    if (name.isEmpty) return null;
    final status = _text(json['runtime_status'], max: 40).toLowerCase();
    final source = _text(json['source'], max: 40);
    return CapabilityItem(
      kind: CapabilityKind.plugin,
      id: 'plugin:installed:$name',
      name: name,
      description: _text(json['description']),
      source: source,
      trust: _trustOf(source),
      version: _text(json['version'], max: 60),
      installedName: name,
      installed: true,
      enabled: status == 'enabled',
      canRemove: json['can_remove'] == true,
      updateAvailable: false,
    );
  }

  /// `GET /api/mcp/catalog` entry.
  static CapabilityItem? catalogMcp(Map<String, dynamic> json) {
    final name = _text(json['name'], max: 160);
    if (name.isEmpty) return null;
    final env = _rows(json['required_env'], max: 40)
        .map(
          (row) => CapabilityEnvField(
            name: _text(row['name'], max: 128),
            prompt: _text(row['prompt'], max: 240),
            required: row['required'] != false,
          ),
        )
        .where((field) => field.name.isNotEmpty)
        .toList(growable: false);
    final installed = json['installed'] == true;
    return CapabilityItem(
      kind: CapabilityKind.mcp,
      id: 'mcp:catalog:$name',
      name: name,
      description: _text(json['description']),
      category: 'mcp',
      source: _text(json['source'], max: 80).isEmpty
          ? 'official'
          : _text(json['source'], max: 80),
      trust: CapabilityTrust.official,
      installId: name,
      installedName: name,
      installed: installed,
      enabled: installed ? json['enabled'] == true : null,
      env: env,
      requirements: env.map((field) => field.name).toList(growable: false),
      transport: _text(json['transport'], max: 20).toLowerCase(),
      command: [
        _text(json['command'], max: 400),
        ..._strings(json['args'], max: 200),
      ].where((part) => part.isNotEmpty).join(' '),
      url: _text(json['url'], max: 400),
      canRemove: installed,
    );
  }

  /// `GET /api/mcp/servers` row (configured MCP server).
  static CapabilityItem? mcpServer(Map<String, dynamic> json) {
    final name = _text(json['name'], max: 160);
    if (name.isEmpty) return null;
    final url = _text(json['url'], max: 400);
    final command = [
      _text(json['command'], max: 400),
      ..._strings(json['args'], max: 200),
    ].where((part) => part.isNotEmpty).join(' ');
    final tools = json['tools'];
    final source = _text(json['source'], max: 20);
    return CapabilityItem(
      kind: CapabilityKind.mcp,
      id: 'mcp:server:$name',
      name: name,
      source: source.isEmpty ? 'config' : source,
      trust: CapabilityTrust.local,
      installedName: name,
      installed: true,
      enabled: json['enabled'] != false,
      transport: _text(json['transport'], max: 20).toLowerCase(),
      command: command,
      url: url,
      tools: tools is List ? _strings(tools) : const [],
      // Plugin-owned servers are removed with their plugin.
      canRemove: source != 'plugin',
      description: _text(json['auth'], max: 40).toLowerCase() == 'oauth'
          ? 'oauth'
          : '',
    );
  }
}

/// Filters of the catalog (AND across groups, like Desktop's facets).
final class CapabilityFilter {
  final CapabilityKind? kind;
  final String category;
  final CapabilityTrust? trust;
  final bool installedOnly;
  final String query;

  const CapabilityFilter({
    this.kind,
    this.category = '',
    this.trust,
    this.installedOnly = false,
    this.query = '',
  });

  bool get isEmpty =>
      kind == null &&
      category.isEmpty &&
      trust == null &&
      !installedOnly &&
      query.trim().isEmpty;

  CapabilityFilter copyWith({
    CapabilityKind? kind,
    bool clearKind = false,
    String? category,
    CapabilityTrust? trust,
    bool clearTrust = false,
    bool? installedOnly,
    String? query,
  }) => CapabilityFilter(
    kind: clearKind ? null : (kind ?? this.kind),
    category: category ?? this.category,
    trust: clearTrust ? null : (trust ?? this.trust),
    installedOnly: installedOnly ?? this.installedOnly,
    query: query ?? this.query,
  );
}

List<CapabilityItem> filterCapabilities(
  Iterable<CapabilityItem> items,
  CapabilityFilter filter,
) {
  final terms = filter.query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  return items
      .where(
        (item) =>
            (filter.kind == null || item.kind == filter.kind) &&
            (filter.category.isEmpty || item.category == filter.category) &&
            (filter.trust == null || item.trust == filter.trust) &&
            (!filter.installedOnly || item.installed) &&
            terms.every(item.searchText.contains),
      )
      .toList(growable: false);
}

/// Category facet values with counts, most common first.
List<(String, int)> capabilityCategories(Iterable<CapabilityItem> items) {
  final counts = <String, int>{};
  for (final item in items) {
    if (item.category.isEmpty) continue;
    counts[item.category] = (counts[item.category] ?? 0) + 1;
  }
  final out = counts.entries.map((e) => (e.key, e.value)).toList();
  out.sort((a, b) {
    final byCount = b.$2.compareTo(a.$2);
    return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
  });
  return out;
}

/// Merges the profile's installed skills into the official catalog: an
/// official row whose skill is installed flips to installed and inherits the
/// real enabled flag; installed skills that are not in the catalog are kept.
List<CapabilityItem> mergeSkills({
  required List<CapabilityItem> installed,
  required List<CapabilityItem> official,
}) {
  final byName = {for (final skill in installed) skill.name: skill};
  final used = <String>{};
  final merged = <CapabilityItem>[];
  for (final entry in official) {
    final local = byName[entry.name];
    if (local != null) {
      used.add(local.name);
      merged.add(
        entry.copyWith(
          installed: true,
          enabled: local.enabled,
          provenance: local.provenance,
          canRemove: local.provenance == 'hub',
        ),
      );
    } else {
      merged.add(entry);
    }
  }
  for (final skill in installed) {
    if (!used.contains(skill.name)) merged.add(skill);
  }
  return merged;
}

/// Server action (`/api/actions/{name}/status`) snapshot.
final class CapabilityActionStatus {
  final String name;
  final bool running;
  final int? exitCode;
  final List<String> lines;

  const CapabilityActionStatus({
    required this.name,
    required this.running,
    this.exitCode,
    this.lines = const [],
  });

  factory CapabilityActionStatus.fromJson(Map<String, dynamic> json) =>
      CapabilityActionStatus(
        name: _text(json['name'], max: 200),
        running: json['running'] == true,
        exitCode: json['exit_code'] is int ? json['exit_code'] as int : null,
        lines: _strings(json['lines'], maxRows: 400, max: 400),
      );

  bool get succeeded => !running && exitCode == 0;

  /// Last meaningful log line — the subprocess's real error.
  String get tail {
    for (final line in lines.reversed) {
      final value = line.trim();
      if (value.isEmpty || value.startsWith('===')) continue;
      return value.length > 200 ? '${value.substring(0, 200)}…' : value;
    }
    return '';
  }

  // Ported 1:1 from Desktop (`hermes_cli/skills_hub.py::_scan_block_message`).
  static final RegExp _blockedCurrent = RegExp(
    r'Not installed:\s+the security scan found\s+(?:(\d+)\s+)?high-risk\s+pattern',
    caseSensitive: false,
  );
  static final RegExp _blockedUnverified = RegExp(
    r'never installs\s+unverified',
    caseSensitive: false,
  );
  static final RegExp _blockedLegacy = RegExp(
    r'Installation blocked:.*?\(([a-z_-]+) source \+ ([a-z_]+) verdict, (\d+) findings?\)',
    caseSensitive: false,
  );

  /// `hermes skills install` refusing through the security scan gate.
  bool get blockedByScan => lines.any(
    (line) =>
        _blockedCurrent.hasMatch(line) ||
        _blockedUnverified.hasMatch(line) ||
        _blockedLegacy.hasMatch(line),
  );

  /// High-risk finding count when the log states one.
  int? get scanFindings {
    for (final line in lines.reversed) {
      final raw =
          _blockedCurrent.firstMatch(line)?.group(1) ??
          _blockedLegacy.firstMatch(line)?.group(3);
      final count = raw == null ? null : int.tryParse(raw);
      if (count != null) return count;
    }
    return null;
  }
}

/// Plugin mutation answer (`/api/dashboard/agent-plugins/...`).
final class PluginMutationResult {
  final bool ok;
  final bool consentRequired;
  final List<String> deltaLines;
  final List<String> warnings;

  /// Env names the plugin still needs (names only, never values).
  final List<String> missingEnv;
  final List<String> knownIssues;
  final List<String> pythonDependencies;

  /// One `name: error` line per live MCP server that did not connect.
  final List<String> mcpNotices;
  final bool restartRequired;
  final bool? gatewayReloaded;

  const PluginMutationResult({
    required this.ok,
    this.consentRequired = false,
    this.deltaLines = const [],
    this.warnings = const [],
    this.missingEnv = const [],
    this.knownIssues = const [],
    this.pythonDependencies = const [],
    this.mcpNotices = const [],
    this.restartRequired = false,
    this.gatewayReloaded,
  });

  factory PluginMutationResult.fromJson(Map<String, dynamic> json) {
    final activation = json['activation'];
    final live = activation is Map ? activation['live_now'] : null;
    final servers = live is Map
        ? _rows(live['mcp_servers'], max: 40)
        : const [];
    return PluginMutationResult(
      ok: json['ok'] == true,
      consentRequired: json['consent_required'] == true,
      deltaLines: _strings(json['delta_lines'], max: 300),
      warnings: _strings(json['warnings'], max: 300),
      missingEnv: _strings(json['missing_env'], max: 120),
      knownIssues: _strings(json['known_issues'], max: 300),
      pythonDependencies: _strings(json['python_dependencies'], max: 120),
      mcpNotices: [
        for (final server in servers)
          if (server['connected'] == false)
            [
              _text(server['name'], max: 80),
              _text(server['error'], max: 200),
            ].where((part) => part.isNotEmpty).join(': '),
      ].where((line) => line.isNotEmpty).toList(growable: false),
      restartRequired: json['restart_required'] == true,
      gatewayReloaded: json['gateway_reloaded'] is bool
          ? json['gateway_reloaded'] as bool
          : null,
    );
  }
}

/// One row of `plugins.manage list` (installed plugins of the hub profile).
final class InstalledPluginRow {
  final String name;
  final String key;
  final String catalogName;
  final String installedSha;
  final bool enabled;
  final bool updateAvailable;

  const InstalledPluginRow({
    required this.name,
    this.key = '',
    this.catalogName = '',
    this.installedSha = '',
    this.enabled = true,
    this.updateAvailable = false,
  });

  static InstalledPluginRow? tryParse(Map<String, dynamic> json) {
    final name = _text(json['name'], max: 120);
    if (name.isEmpty) return null;
    final status = _text(json['status'], max: 40).toLowerCase();
    return InstalledPluginRow(
      name: name,
      key: _text(json['key'], max: 120),
      catalogName: _text(json['catalog_name'], max: 120),
      installedSha: _text(json['installed_sha'], max: 64),
      enabled: status != 'disabled' && status != 'off',
      updateAvailable: json['update_available'] == true,
    );
  }
}

extension InstalledPluginRows on List<InstalledPluginRow> {
  /// Desktop rule: `catalog_name` first, plugin name second.
  InstalledPluginRow? match({required String catalogName, String? name}) {
    for (final row in this) {
      if (row.catalogName.isNotEmpty && row.catalogName == catalogName) {
        return row;
      }
    }
    final wanted = name ?? catalogName;
    for (final row in this) {
      if (row.name == wanted || row.key == wanted) return row;
    }
    return null;
  }
}

/// Hosted connector (Nous account connectors: `connectors.*`).
enum ConnectorAvailability { available, signedOut, unavailable, unsupported }

final class HostedConnector {
  final String slug;
  final String name;
  final String description;
  final String category;
  final bool connected;
  final bool enabled;
  final String status;
  final String statusReason;
  final List<String> connectionIds;

  const HostedConnector({
    required this.slug,
    required this.name,
    this.description = '',
    this.category = '',
    this.connected = false,
    this.enabled = true,
    this.status = '',
    this.statusReason = '',
    this.connectionIds = const [],
  });
}

final class HostedConnectorsSnapshot {
  final ConnectorAvailability availability;
  final List<HostedConnector> connectors;

  const HostedConnectorsSnapshot({
    required this.availability,
    this.connectors = const [],
  });

  /// Joins `connectors.list`, `connectors.catalog` and `connectors.accounts`
  /// like Desktop's `joinHostedConnectors` (catalog order, list state).
  factory HostedConnectorsSnapshot.join({
    required Map<String, dynamic> list,
    Map<String, dynamic> catalog = const {},
    Map<String, dynamic> accounts = const {},
  }) {
    if (list['available'] != true) {
      return const HostedConnectorsSnapshot(
        availability: ConnectorAvailability.unavailable,
      );
    }
    final state = {
      for (final row in _rows(list['connectors']))
        if (_text(row['connector'], max: 120).isNotEmpty)
          _text(row['connector'], max: 120): row,
    };
    final accountsBySlug = <String, List<String>>{};
    for (final row in _rows(accounts['accounts'])) {
      final slug = _text(row['connector'], max: 120);
      final id = _text(row['connection_id'], max: 200);
      if (slug.isEmpty || id.isEmpty) continue;
      accountsBySlug.putIfAbsent(slug, () => []).add(id);
    }
    final seen = <String>{};
    final out = <HostedConnector>[];
    HostedConnector build(String slug, Map<String, dynamic>? meta) {
      final row = state[slug] ?? const <String, dynamic>{};
      final name = _text(meta?['name'], max: 120);
      return HostedConnector(
        slug: slug,
        name: name.isEmpty ? capabilityLabel(slug) : name,
        description: _text(meta?['description']),
        category: _text(meta?['category'], max: 80),
        connected: row['connected'] == true,
        enabled: row['enabled'] != false,
        status: _text(row['connection_status'], max: 40),
        statusReason: _text(row['status_reason'], max: 240),
        connectionIds: accountsBySlug[slug] ?? const [],
      );
    }

    for (final meta in _rows(catalog['connectors'])) {
      final slug = _text(meta['slug'], max: 120);
      if (slug.isEmpty || !seen.add(slug)) continue;
      out.add(build(slug, meta));
    }
    for (final slug in state.keys) {
      if (seen.add(slug)) out.add(build(slug, null));
    }
    return HostedConnectorsSnapshot(
      availability: ConnectorAvailability.available,
      connectors: out,
    );
  }
}

/// Account connect operation (`connectors.connect` / `operation.status`).
final class ConnectOperation {
  final String opId;
  final int seq;
  final bool settled;
  final String settledBy;
  final Uri? connectUrl;
  final Map<String, String> targetStates;
  final List<String> connectionIds;

  const ConnectOperation({
    required this.opId,
    required this.seq,
    required this.settled,
    this.settledBy = '',
    this.connectUrl,
    this.targetStates = const {},
    this.connectionIds = const [],
  });

  factory ConnectOperation.fromJson(Map<String, dynamic> json) {
    Uri? link;
    final states = <String, String>{};
    final ids = <String>[];
    for (final target in _rows(json['targets'], max: 40)) {
      final name = _text(target['name'], max: 120);
      if (name.isNotEmpty) states[name] = _text(target['state'], max: 40);
      final id = _text(target['connection_id'], max: 200);
      if (id.isNotEmpty) ids.add(id);
      final raw = _text(target['connect_url'], max: 4096);
      final uri = raw.isEmpty ? null : Uri.tryParse(raw);
      if (link == null &&
          uri != null &&
          uri.scheme.toLowerCase() == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        link = uri;
      }
    }
    return ConnectOperation(
      opId: _text(json['op_id'], max: 200),
      seq: json['seq'] is int ? json['seq'] as int : 0,
      settled: json['settled'] == true,
      settledBy: _text(json['settled_by'], max: 40),
      connectUrl: link,
      targetStates: states,
      connectionIds: ids,
    );
  }

  bool get allConnected =>
      targetStates.isNotEmpty &&
      targetStates.values.every((state) => state == 'connected');

  /// Keeps the link of the previous snapshot unless the server reissued it.
  ConnectOperation carryLinkFrom(ConnectOperation previous) =>
      seq < previous.seq
      ? previous
      : ConnectOperation(
          opId: opId,
          seq: seq,
          settled: settled,
          settledBy: settledBy,
          connectUrl: connectUrl ?? previous.connectUrl,
          targetStates: targetStates,
          connectionIds: connectionIds.isEmpty
              ? previous.connectionIds
              : connectionIds,
        );
}
