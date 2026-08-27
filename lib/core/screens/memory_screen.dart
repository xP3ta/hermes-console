// Memory system status — GET /api/memory (Dashboard port 9119).
//
// Shows the active memory provider, all available providers, and
// the size of the built-in memory files (memory.md, user.md).
//
// NOTE on write API: /api/memory is GET-only. The dashboard exposes no
// POST/PUT endpoint for writing memory files. A "backup" action serialises
// the API response JSON and saves it to getApplicationDocumentsDirectory()
// via path_provider.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/connection_manager.dart';
import '../services/memory_draft_store.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import 'memory_draft_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/feature_dependency_notice.dart';
import 'instance_edit_screen.dart';

class MemoryScreen extends StatefulWidget {
  final SavedConnection connection;
  final String? profileOverride;
  const MemoryScreen({
    required this.connection,
    this.profileOverride,
    super.key,
  });

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late DashboardClient _client;
  MemoryInfo? _info;
  bool _loading = true;
  String? _error;
  DashboardDependencyFailure _dependencyFailure =
      DashboardDependencyFailure.other;
  bool _backingUp = false;
  MemoryDraftStore? _drafts;

  // Local filter applied over providers + builtin files
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.lazy(widget.connection);
    _filterController.addListener(() {
      setState(() => _filter = _filterController.text);
    });
    _load();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _drafts = MemoryDraftStore(prefs));
    });
  }

  String get _profile => widget.profileOverride?.trim() ?? '';

  bool _hasDraft(String name) =>
      _drafts?.exists(widget.connection.id, name, profile: _profile) ?? false;

  Future<void> _openDraft(String name) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoryDraftScreen(
          connectionId: widget.connection.id,
          fileName: name,
          profile: _profile,
        ),
      ),
    );
    if (mounted) setState(() {}); // refresca el indicador de borrador
  }

  @override
  void dispose() {
    _client.close();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _dependencyFailure = DashboardDependencyFailure.other;
    });
    try {
      final info = await _client.getMemoryInfo(profile: _profile);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = localizedApiError(Strings.of(context), e);
        _dependencyFailure = classifyDashboardDependencyFailure(e);
        _loading = false;
      });
    }
  }

  Future<void> _configureDependencies() async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (app == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(
          connManager: app.connManager,
          initial: widget.connection,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _backup() async {
    final info = _info;
    if (info == null || _backingUp) return;
    setState(() => _backingUp = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final fileName = 'memory_backup_$timestamp.json';
      final file = File('${dir.path}/$fileName');

      final payload = {
        'backup_at': DateTime.now().toIso8601String(),
        'connection': widget.connection.host,
        'active': info.active,
        'providers': info.providers
            .map(
              (p) => {
                'name': p.name,
                'description': p.description,
                'configured': p.configured,
              },
            )
            .toList(),
        'builtin_files': info.builtinFiles,
      };

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'backup guardado: ${file.path}',
            style: const TextStyle(fontSize: 11),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Strings.of(context).memBackupSaveError(e.toString()),
            style: const TextStyle(fontSize: 11),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  List<MemoryProvider> get _filteredProviders {
    final info = _info;
    if (info == null) return [];
    if (_filter.isEmpty) return info.providers;
    final q = _filter.toLowerCase();
    return info.providers.where((p) {
      return p.name.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q);
    }).toList();
  }

  Map<String, int> get _filteredBuiltinFiles {
    final info = _info;
    if (info == null) return {};
    if (_filter.isEmpty) return info.builtinFiles;
    final q = _filter.toLowerCase();
    return Map.fromEntries(
      info.builtinFiles.entries.where((e) => e.key.toLowerCase().contains(q)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(Strings.of(context).memTitle),
            if (_profile.isNotEmpty)
              Text(
                '@$_profile',
                style: TextStyle(fontSize: 11, color: colors.accent),
              )
            else if (_info != null)
              Text(
                '${_info!.configuredCount} / ${_info!.providers.length} configuradas',
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
          ],
        ),
        actions: [
          if (_info != null)
            IconButton(
              icon: _backingUp
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.textSecondary,
                      ),
                    )
                  : const Icon(Icons.archive_outlined),
              tooltip: Strings.of(context).memBackupJson,
              onPressed: _backingUp ? null : _backup,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: TuiLoader());
    }
    if (_error != null) {
      return _buildError();
    }
    if (_info == null) {
      return const Center(child: TuiLoader());
    }
    return _buildContent(_info!);
  }

  Widget _buildError() {
    final s = Strings.of(context);
    final needsDashboard =
        _dependencyFailure == DashboardDependencyFailure.credentials;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: FeatureDependencyNotice(
        noticeId:
            'memory-${needsDashboard ? 'dashboard' : 'load'}-${widget.connection.id}',
        kind: needsDashboard
            ? FeatureDependencyKind.dashboard
            : FeatureDependencyKind.gateway,
        title: needsDashboard
            ? s.dependencyDashboardTitle
            : s.dependencyLoadFailedTitle,
        message: needsDashboard
            ? s.dependencyDashboardBody
            : s.dependencyLoadFailedBody(_error!),
        primaryActionLabel: needsDashboard ? s.dependencyConfigure : null,
        onPrimaryAction: needsDashboard ? _configureDependencies : null,
        retryLabel: s.dependencyRetry,
        onRetry: _load,
        dismissible: false,
      ),
    );
  }

  Widget _buildContent(MemoryInfo info) {
    final colors = Theme.of(context).hermes;
    final filteredProviders = _filteredProviders;
    final filteredFiles = _filteredBuiltinFiles;

    final sorted = [...filteredProviders]
      ..sort((a, b) {
        if (a.name == info.active) return -1;
        if (b.name == info.active) return 1;
        if (a.configured && !b.configured) return -1;
        if (!a.configured && b.configured) return 1;
        return a.name.compareTo(b.name);
      });

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          // Search/filter bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _filterController,
              style: TextStyle(fontSize: 13, color: colors.textPrimary),
              decoration: InputDecoration(
                hintText: 'filtrar providers y archivos…',
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: colors.textSecondary,
                ),
                suffixIcon: _filter.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          size: 16,
                          color: colors.textSecondary,
                        ),
                        onPressed: () => _filterController.clear(),
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 12,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Only show active section when not filtering (it's always visible)
                if (_filter.isEmpty) ...[
                  _buildActiveSection(info, colors),
                  const SizedBox(height: 16),
                ],
                if (filteredFiles.isNotEmpty) ...[
                  _buildBuiltinFilesSection(filteredFiles, colors),
                  const SizedBox(height: 16),
                ],
                if (sorted.isNotEmpty)
                  _buildProvidersSection(sorted, info.active, colors)
                else if (_filter.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        'sin coincidencias para "$_filter"',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textDisabled,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveSection(MemoryInfo info, HermesThemeColors colors) {
    final active = info.activeProvider;
    return Card(
      color: colors.surfaceVariant.withValues(alpha: 0.35),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.psychology, size: 18, color: colors.accent),
                const SizedBox(width: 8),
                Text(
                  Strings.of(context).memActiveProviderLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textSecondary,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: colors.success,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  info.active.isEmpty
                      ? Strings.of(context).memNoneValue
                      : info.active,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            if (active != null && active.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                active.description,
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
              ),
            ],
            const SizedBox(height: 12),
            // Honest note about write API
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.55),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 13,
                    color: colors.textDisabled,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      Strings.of(context).memReadOnlyNote,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textDisabled,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBuiltinFilesSection(
    Map<String, int> files,
    HermesThemeColors colors,
  ) {
    return Card(
      color: colors.surfaceVariant.withValues(alpha: 0.35),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.article_outlined,
                  size: 18,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  Strings.of(context).memBuiltinFiles,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textSecondary,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...files.entries.map((e) {
              final kb = (e.value / 1024).toStringAsFixed(1);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => _showFileDetail(e.key, e.value, colors),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${e.key}.md',
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.textPrimary,
                              ),
                            ),
                            if (_hasDraft(e.key)) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.edit_note_outlined,
                                size: 14,
                                color: colors.accentHover,
                              ),
                            ],
                          ],
                        ),
                        Row(
                          children: [
                            Text(
                              '$kb KB',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textSecondary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.info_outline,
                              size: 14,
                              color: colors.textDisabled,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  void _showFileDetail(String name, int bytes, HermesThemeColors colors) {
    final kb = (bytes / 1024).toStringAsFixed(2);
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('memory-file-detail-surface'),
      maxWidth: 520,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$name.md',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            _DetailRow(
              label: Strings.of(context).memSize,
              value: '$kb KB ($bytes bytes)',
              colors: colors,
            ),
            _DetailRow(
              label: Strings.of(context).memFormat,
              value: 'Markdown',
              colors: colors,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.55),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 13,
                    color: colors.textDisabled,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      Strings.of(context).memNoFileEndpoint,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textDisabled,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openDraft(name);
                },
                icon: Icon(
                  Icons.edit_note_outlined,
                  size: 18,
                  color: colors.accentHover,
                ),
                label: Text(
                  _hasDraft(name)
                      ? Strings.of(context).memOpenDraft
                      : Strings.of(context).memCreateDraft,
                  style: TextStyle(fontSize: 13, color: colors.accentHover),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colors.accent.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProvidersSection(
    List<MemoryProvider> sorted,
    String active,
    HermesThemeColors colors,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            Strings.of(context).memProvidersSection,
            style: TextStyle(
              fontSize: 12,
              color: colors.textSecondary,
              letterSpacing: 0.6,
            ),
          ),
        ),
        ...sorted.map(
          (provider) => _buildProviderTile(provider, active, colors),
        ),
      ],
    );
  }

  Widget _buildProviderTile(
    MemoryProvider provider,
    String active,
    HermesThemeColors colors,
  ) {
    final isActive = provider.name == active;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: colors.surfaceVariant.withValues(alpha: 0.35),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(
                provider.configured
                    ? (isActive
                          ? Icons.check_circle
                          : Icons.check_circle_outline)
                    : Icons.radio_button_unchecked,
                size: 16,
                color: isActive
                    ? colors.success
                    : provider.configured
                    ? colors.accent
                    : colors.textDisabled,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          provider.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: isActive
                                ? colors.accent
                                : colors.textPrimary,
                          ),
                        ),
                      ),
                      if (isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.success.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'active',
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.success,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      else if (!provider.configured)
                        Text(
                          'not configured',
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.textDisabled,
                          ),
                        ),
                    ],
                  ),
                  if (provider.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      provider.description,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final HermesThemeColors colors;

  const _DetailRow({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
