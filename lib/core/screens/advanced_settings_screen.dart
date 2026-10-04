import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/list.dart';
import '../design/page.dart';
import '../services/active_profile_scope.dart';
import '../services/compression_config_repository.dart';
import '../services/connection_manager.dart';
import '../services/server_config_repository.dart';
import '../services/server_toolsets_repository.dart';
import '../settings/advanced_search.dart';
import '../settings/server_config_pages.dart';
import '../widgets/compression_config_card.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart' show HermesSearchField;
import '../widgets/hermes_ui.dart' show HermesInfoBanner;
import 'server_config_page_screen.dart';
import 'server_toolsets_screen.dart';
import 'voice_settings_screen.dart';

/// Compression fields the existing card owns on the Context page.
const _compressionCardFields = {
  'compression.enabled',
  'compression.threshold',
  'compression.target_ratio',
  'compression.protect_last_n',
  'compression.threshold_tokens',
  'compression.min_tail_user_messages',
  'compression.progress_notices',
};

/// Settings › Advanced: the server settings Desktop keeps on its configuration
/// pages, kept out of the main Settings list.
///
/// Nothing is read when Settings opens. Opening this screen reads the schema
/// and the config once (and the toolsets list once); each page only shows the
/// fields the schema brought, and a server without the routes shows nothing.
class AdvancedSettingsScreen extends StatefulWidget {
  const AdvancedSettingsScreen({
    required this.connection,
    required this.connManager,
    this.dashboardFactory,
    super.key,
  });

  final SavedConnection connection;
  final ConnectionManager connManager;

  /// Builds the Dashboard client; the default talks to the saved connection.
  @visibleForTesting
  final DashboardClient Function(SavedConnection connection)? dashboardFactory;

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  DashboardClient? _client;
  late final ActiveProfileScope _scope = ActiveProfileScope.of(
    widget.connManager,
    widget.connection.id,
  );
  final TextEditingController _search = TextEditingController();
  ProfileReadTicket? _ticket;
  ServerConfigRepository? _repo;
  ServerToolsetsRepository? _toolsRepo;
  ServerConfigSnapshot? _snapshot;
  bool _toolsAvailable = false;
  bool _loading = true;
  bool _unsupported = false;
  bool _failed = false;
  bool _disposed = false;
  String _query = '';

  DashboardClient get _dashboard => _client ??=
      (widget.dashboardFactory ?? DashboardClient.lazy)(widget.connection);

  bool get _writable {
    final caps = widget.connManager.loadCapabilities(widget.connection.id);
    return !widget.connection.readOnly && !caps.configWrite.isNo;
  }

  bool _isCurrent(ProfileReadTicket ticket) => !_disposed && ticket.isCurrent;

  @override
  void initState() {
    super.initState();
    _scope.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _disposed = true;
    _scope.removeListener(_reload);
    _search.dispose();
    _client?.close();
    super.dispose();
  }

  Future<void> _reload() async {
    final caps = widget.connManager.loadCapabilities(widget.connection.id);
    if (caps.configRead.isNo) {
      setState(() {
        _loading = false;
        _unsupported = true;
      });
      return;
    }
    final ticket = _scope.capture();
    _ticket = ticket;
    final profile = ticket.name;
    final repo = ServerConfigRepository(
      _dashboard,
      profile: profile,
      writable: _writable,
    );
    final tools = ServerToolsetsRepository(
      _dashboard,
      profile: profile,
      writable: _writable,
    );
    setState(() {
      _loading = true;
      _failed = false;
      _unsupported = false;
      _snapshot = null;
      _toolsAvailable = false;
      _repo = repo;
      _toolsRepo = tools;
    });
    ServerConfigSnapshot? snapshot;
    var unsupported = false;
    var failed = false;
    try {
      snapshot = await repo.load(isCurrent: () => _isCurrent(ticket));
    } on ServerConfigException catch (error) {
      unsupported = error.kind == ServerConfigFailure.unsupported;
      failed = !unsupported;
    }
    var toolsAvailable = false;
    if (!unsupported && !failed) {
      try {
        toolsAvailable =
            (await tools.list(isCurrent: () => _isCurrent(ticket))) != null;
      } on ServerConfigException {
        toolsAvailable = false;
      }
    }
    // A late answer of another profile belongs to nobody.
    if (!_isCurrent(ticket) || !identical(_ticket, ticket)) return;
    setState(() {
      _snapshot = snapshot;
      _toolsAvailable = toolsAvailable;
      _unsupported = unsupported;
      _failed = failed;
      _loading = false;
    });
  }

  List<ServerConfigField> _fieldsOf(ServerConfigPage page) {
    final all = _snapshot?.byPage[page] ?? const <ServerConfigField>[];
    if (page != ServerConfigPage.context) return all;
    return [
      for (final field in all)
        if (!_compressionCardFields.contains(field.path)) field,
    ];
  }

  List<ServerConfigPage> get _pages => [
    for (final page in ServerConfigPage.values)
      if (_snapshot?.byPage[page]?.isNotEmpty ?? false) page,
  ];

  List<AdvancedSearchEntry> _index(Strings s) => [
    for (final page in _pages)
      AdvancedSearchEntry(
        title: serverConfigPageTitle(s, page),
        target: AdvancedPageTarget(page),
      ),
    if (_toolsAvailable)
      AdvancedSearchEntry(
        title: s.ad1215PageTools,
        target: const AdvancedToolsTarget(),
      ),
    for (final field in _snapshot?.fields ?? const <ServerConfigField>[])
      AdvancedSearchEntry(
        title: field.description,
        group: serverConfigPageTitle(s, field.page),
        extra: [field.path],
        target: AdvancedFieldTarget(field.page, field.path),
      ),
  ];

  void _open(AdvancedTarget target, {String? highlight}) {
    final ticket = _ticket;
    final repo = _repo;
    if (ticket == null || repo == null) return;
    bool isCurrent() => _isCurrent(ticket);
    switch (target) {
      case AdvancedToolsTarget():
        final tools = _toolsRepo;
        if (tools == null) return;
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ServerToolsetsScreen(
              repository: tools,
              writable: _writable,
              isCurrent: isCurrent,
            ),
          ),
        );
      case AdvancedPageTarget(:final page):
        _openPage(page, repo, isCurrent, highlight);
      case AdvancedFieldTarget(:final page, :final path):
        _openPage(page, repo, isCurrent, path);
    }
  }

  void _openPage(
    ServerConfigPage page,
    ServerConfigRepository repo,
    bool Function() isCurrent,
    String? highlight,
  ) {
    final leading = <Widget>[];
    if (page == ServerConfigPage.context) {
      final compression = CompressionConfigRepository(
        _dashboard,
        profile: _ticket?.name,
        writable: _writable,
      );
      leading.add(
        CompressionConfigCard(
          canRead: true,
          canWrite: _writable,
          load: compression.load,
          save: compression.save,
          profile: _ticket?.name,
        ),
      );
    }
    if (page == ServerConfigPage.conversation) {
      leading.add(
        HermesListGroup(
          children: [
            Builder(
              builder: (context) => HermesListRow(
                icon: Icons.record_voice_over_outlined,
                title: Strings.of(context).ad1215OpenVoice,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => VoiceSettingsScreen(
                      connection: widget.connection,
                      profile: _ticket?.name,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ServerConfigPageScreen(
          page: page,
          fields: _fieldsOf(page),
          repository: repo,
          writable: _writable,
          leading: leading,
          isCurrent: isCurrent,
          highlightPath: highlight,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final results = searchAdvanced(_index(s), _query);
    final searching = _query.trim().isNotEmpty;
    return HermesPage(
      title: s.ad1215Title,
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: TuiLoader()),
          )
        else if (_failed)
          HermesListGroup(
            children: [
              HermesListRow(
                title: s.ad1215LoadFailed,
                icon: Icons.refresh,
                onTap: () => unawaited(_reload()),
              ),
            ],
          )
        else if (_unsupported)
          HermesInfoBanner(s.ad1215NoResults)
        else ...[
          HermesSearchField(
            controller: _search,
            hintText: s.ad1215SearchHint,
            clearTooltip: s.ad1215SearchClear,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          if (searching)
            if (results.isEmpty)
              HermesInfoBanner(s.ad1215NoResults)
            else
              HermesListGroup(
                children: [
                  for (final entry in results)
                    HermesListRow(
                      key: ValueKey(
                        'adv-result-${entry.extra.firstOrNull ?? entry.title}',
                      ),
                      title: entry.title,
                      subtitle: entry.group,
                      onTap: () => _open(entry.target),
                    ),
                ],
              )
          else
            HermesListGroup(
              children: [
                for (final page in _pages)
                  HermesListRow(
                    key: ValueKey('adv-page-${page.name}'),
                    icon: serverConfigPageIcon(page),
                    title: serverConfigPageTitle(s, page),
                    onTap: () => _open(AdvancedPageTarget(page)),
                  ),
                if (_toolsAvailable)
                  HermesListRow(
                    key: const ValueKey('adv-page-tools'),
                    icon: Icons.build_outlined,
                    title: s.ad1215PageTools,
                    onTap: () => _open(const AdvancedToolsTarget()),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}
