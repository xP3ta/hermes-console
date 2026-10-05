// Memory system status — GET /api/memory (Dashboard port 9119).
//
// Shows the active memory provider, all available providers, and
// the size of the built-in memory files (memory.md, user.md).
//
// NOTE on write API: /api/memory is GET-only; the only write is
// POST /api/memory/reset (`{target: memory|user}`, always with an explicit
// `?profile=`), offered per built-in file behind a confirmation. A "backup"
// action serialises the API response JSON and saves it to
// getApplicationDocumentsDirectory() via path_provider.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/memory_draft_store.dart';
import '../design/hermes_design.dart' as d show HermesListRow;
import '../design/hermes_design.dart'
    show
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        showHermesDialog,
        showHermesMenu;
import '../design/hermes_design.dart'
    show
        HermesActionButton,
        HermesDetailScaffold,
        HermesInlineNotice,
        HermesListGroup,
        HermesSectionHeader,
        HermesSpace,
        HermesStatusText,
        HermesStatusTone;
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import 'memory_draft_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/profile_scope.dart';
import '../widgets/feature_dependency_notice.dart';
import 'instance_edit_screen.dart';

class MemoryScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Fixed profile (a bot card). Null follows the active profile.
  final String? profileOverride;

  /// Active profile source; defaults to the app's for [connection].
  final ActiveProfileScope? profileScope;
  final DashboardClient? dashboardClientForTesting;
  const MemoryScreen({
    required this.connection,
    this.profileOverride,
    this.profileScope,
    @visibleForTesting this.dashboardClientForTesting,
    super.key,
  });

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen>
    with ActiveProfileFollower<MemoryScreen> {
  late DashboardClient _client;
  MemoryInfo? _info;
  bool _loading = true;
  String? _error;
  DashboardDependencyFailure _dependencyFailure =
      DashboardDependencyFailure.other;
  bool _backingUp = false;
  MemoryDraftStore? _drafts;

  /// Cleared when the server answers 404/405 to a reset: the action is then
  /// hidden for the rest of this screen's life.
  bool _resetSupported = true;
  bool _resetting = false;

  // Local filter applied over providers + builtin files
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _client =
        widget.dashboardClientForTesting ??
        DashboardClient.lazy(widget.connection);
    _filterController.addListener(() {
      setState(() => _filter = _filterController.text);
    });
    final override = widget.profileOverride?.trim() ?? '';
    followActiveProfile(
      widget.profileScope ??
          appActiveProfileScope(context, widget.connection.id),
      fixedProfile: override.isEmpty ? null : override,
    );
    _load();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _drafts = MemoryDraftStore(prefs));
    });
  }

  @override
  void onActiveProfileChanged() => _load();

  String get _profile => scopedProfileName;

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
    final ticket = profileReadTicket();
    try {
      final info = await _client.getMemoryInfo(profile: ticket.name);
      // A read for the previous profile never lands on the new one.
      if (!mounted || !ticket.isCurrent) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || !ticket.isCurrent) return;
      setState(() {
        _error = localizedApiError(Strings.of(context), e);
        _dependencyFailure = classifyDashboardDependencyFailure(e);
        _loading = false;
      });
    }
  }

  bool get _canReset =>
      _resetSupported && !_resetting && !widget.connection.readOnly;

  Future<void> _resetFile(String key, GlobalKey anchor) async {
    final s = Strings.of(context);
    final target = key == 'user' ? 'user' : 'memory';
    final file = '${target.toUpperCase()}.md';
    final chosen = await showHermesMenu<bool>(
      context: context,
      anchorKey: anchor,
      actions: [
        HermesAction(
          key: const ValueKey('mem-file-reset'),
          value: true,
          label: s.memResetFile,
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (chosen != true || !mounted) return;
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.memResetConfirmTitle(file),
      message: s.memResetConfirmBody,
      actions: [
        HermesDialogAction(
          key: const ValueKey('mem-reset-cancel'),
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('mem-reset-confirm'),
          label: s.memResetFile,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    final notices = HermesNotice.of(context);
    // The server rejects an omitted profile once it hosts several, so the
    // default profile is named explicitly.
    final profile = _profile.isEmpty ? 'default' : _profile;
    setState(() => _resetting = true);
    try {
      final result = await _client.apiPost(
        'memory/reset?profile=${Uri.encodeQueryComponent(profile)}',
        body: {'target': target},
      );
      if (!mounted) return;
      final deleted = (result['deleted'] as List? ?? const [])
          .whereType<String>()
          .join(', ');
      notices.show(
        message: s.memResetDone(deleted.isEmpty ? file : deleted),
        kind: HermesNoticeKind.success,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      final status = e is DashboardHttpException ? e.statusCode : 0;
      if (status == 404 || status == 405) _resetSupported = false;
      notices.show(message: s.memResetFailed, kind: HermesNoticeKind.error);
    } finally {
      if (mounted) setState(() => _resetting = false);
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
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Strings.of(context).memoryBackupSaved(file.path),
            style: const TextStyle(fontSize: 11),
          ),
          duration: const Duration(seconds: 4),
        ),
        kind: HermesNoticeKind.success,
      );
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Strings.of(context).memBackupSaveError(e.toString()),
            style: const TextStyle(fontSize: 11),
          ),
        ),
        kind: HermesNoticeKind.error,
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
            // States which profile this memory belongs to.
            ProfileScopeLabel(
              profile: _profile,
              connectionId: widget.connection.id,
            ),
            if (_info != null)
              Text(
                Strings.of(context).memoryConfiguredCount(
                  _info!.configuredCount,
                  _info!.providers.length,
                ),
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
                hintText: Strings.of(context).memoryFilterHint,
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
                        Strings.of(context).memoryNoMatches(_filter),
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
                            if (_canReset &&
                                (e.key == 'memory' || e.key == 'user'))
                              _FileMoreButton(
                                fileKey: e.key,
                                onPressed: _resetFile,
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageCtx) => MemoryFileDetailPage(
          name: name,
          bytes: bytes,
          hasDraft: _hasDraft(name),
          onOpenDraft: () {
            Navigator.pop(pageCtx);
            _openDraft(name);
          },
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

  /// The server's own status when it sends one; otherwise today's
  /// «not configured» wording for providers that are not configured.
  String? _statusLabel(MemoryProvider provider) {
    final s = Strings.of(context);
    return switch (provider.status) {
      MemoryProviderStatus.ready => s.memStatusReady,
      MemoryProviderStatus.needsConfig => s.memStatusNeedsConfig,
      MemoryProviderStatus.unavailable => s.memStatusUnavailable,
      MemoryProviderStatus.missing => s.memStatusMissing,
      MemoryProviderStatus.unknown =>
        provider.configured ? null : s.memoryProviderNotConfigured,
    };
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
                      else if (_statusLabel(provider) != null)
                        Text(
                          _statusLabel(provider)!,
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

/// Overflow button of one built-in file row.
class _FileMoreButton extends StatefulWidget {
  final String fileKey;
  final void Function(String key, GlobalKey anchor) onPressed;

  _FileMoreButton({required this.fileKey, required this.onPressed})
    : super(key: ValueKey('mem-file-more-$fileKey'));

  @override
  State<_FileMoreButton> createState() => _FileMoreButtonState();
}

class _FileMoreButtonState extends State<_FileMoreButton> {
  final GlobalKey _anchor = GlobalKey();

  @override
  Widget build(BuildContext context) => IconButton(
    key: _anchor,
    tooltip: Strings.of(context).cphMore,
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    icon: const Icon(Icons.more_vert_rounded),
    onPressed: () => widget.onPressed(widget.fileKey, _anchor),
  );
}

/// Memory file detail (spec 080): one page scroll, one primary action.
class MemoryFileDetailPage extends StatelessWidget {
  final String name;
  final int bytes;
  final bool hasDraft;
  final VoidCallback onOpenDraft;

  const MemoryFileDetailPage({
    super.key = const ValueKey('memory-file-detail-page'),
    required this.name,
    required this.bytes,
    required this.hasDraft,
    required this.onOpenDraft,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final kb = (bytes / 1024).toStringAsFixed(2);
    return HermesDetailScaffold(
      listKey: const ValueKey('memory-file-detail'),
      title: '$name.md',
      status: hasDraft
          ? HermesStatusText(
              label: s.memBadgeDraft,
              tone: HermesStatusTone.active,
            )
          : null,
      primaryAction: HermesActionButton(
        key: const ValueKey('memory-file-open-draft'),
        primary: true,
        icon: Icons.edit_note_outlined,
        label: hasDraft ? s.memOpenDraft : s.memCreateDraft,
        onPressed: onOpenDraft,
      ),
      sections: [
        HermesSectionHeader(s.designDetails),
        HermesListGroup(
          dividerIndent: HermesSpace.rowH,
          children: [
            d.HermesListRow(
              title: s.memSize,
              value: '$kb KB ($bytes bytes)',
              showChevron: false,
            ),
            d.HermesListRow(
              title: s.memFormat,
              value: 'Markdown',
              showChevron: false,
            ),
          ],
        ),
        const SizedBox(height: HermesSpace.x3),
        HermesInlineNotice(message: s.memNoFileEndpoint),
      ],
    );
  }
}
