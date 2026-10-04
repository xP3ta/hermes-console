import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart';
import '../design/list.dart';
import '../design/modal.dart';
import '../design/page.dart';
import '../services/server_config_repository.dart';
import '../services/server_toolsets_repository.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart' show HermesInfoBanner;
import '../widgets/server_config_field_row.dart' show ServerConfigTextEditor;

/// Settings › Advanced › Tools: the server's toolsets, each with a switch.
///
/// Opening the page reads the list once, then each toolset's config one after
/// the other to learn which ones have options (the chevron only appears for
/// those). Every change is written and re-read before it shows.
class ServerToolsetsScreen extends StatefulWidget {
  const ServerToolsetsScreen({
    required this.repository,
    required this.writable,
    this.isCurrent,
    super.key,
  });

  final ServerToolsetsRepository repository;
  final bool writable;
  final bool Function()? isCurrent;

  @override
  State<ServerToolsetsScreen> createState() => _ServerToolsetsScreenState();
}

class _ServerToolsetsScreenState extends State<ServerToolsetsScreen> {
  List<ServerToolset>? _toolsets;
  final Map<String, bool> _hasOptions = {};
  final Set<String> _busy = {};
  bool _failed = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final rows = await widget.repository.list(isCurrent: widget.isCurrent);
      if (_disposed || rows == null) return;
      setState(() => _toolsets = rows);
      for (final row in rows) {
        if (_disposed) return;
        try {
          final config = await widget.repository.config(
            row.name,
            isCurrent: widget.isCurrent,
          );
          if (_disposed) return;
          if (config != null) {
            setState(() => _hasOptions[row.name] = config.hasCategory);
          }
        } on ServerConfigException {
          // A toolset whose options cannot be read simply has no chevron.
        }
      }
    } on ServerConfigException {
      if (!_disposed) setState(() => _failed = true);
    }
  }

  Future<void> _toggle(ServerToolset toolset, bool value) async {
    if (_busy.contains(toolset.name)) return;
    final s = Strings.of(context);
    final notices = HermesNotice.of(context);
    final rows = _toolsets ?? const [];
    final isLast =
        !value &&
        rows.where((t) => t.enabled).length == 1 &&
        rows.any((t) => t.name == toolset.name && t.enabled);
    if (isLast) {
      final ok = await showHermesDialog<bool>(
        context: context,
        title: s.ad1215LastToolTitle,
        message: s.ad1215LastToolBody,
        actions: [
          HermesDialogAction(label: s.commonCancel, value: false),
          HermesDialogAction(
            label: s.ad1215Disable,
            value: true,
            style: HermesDialogActionStyle.destructive,
          ),
        ],
      );
      if (ok != true || _disposed) return;
    }
    setState(() => _busy.add(toolset.name));
    try {
      final result = await widget.repository.setEnabled(
        toolset.name,
        value,
        isCurrent: widget.isCurrent,
      );
      if (_disposed) return;
      if (result.outcome == ServerConfigSaveOutcome.stale) return;
      setState(() {
        final seen = result.enabled ?? toolset.enabled;
        _toolsets = [
          for (final t in _toolsets ?? const <ServerToolset>[])
            if (t.name == toolset.name) _withEnabled(t, seen) else t,
        ];
      });
      if (result.outcome == ServerConfigSaveOutcome.mismatch) {
        notices.showSnackBar(
          SnackBar(content: Text(s.ad1215SaveFailed)),
          kind: HermesNoticeKind.error,
        );
      } else if (result.postSetupStarted != null) {
        notices.showSnackBar(
          SnackBar(content: Text(s.ad1215Installing)),
          kind: HermesNoticeKind.info,
        );
      }
    } on ServerConfigException {
      if (!_disposed) {
        notices.showSnackBar(
          SnackBar(content: Text(s.ad1215SaveFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (!_disposed) setState(() => _busy.remove(toolset.name));
    }
  }

  static ServerToolset _withEnabled(ServerToolset t, bool enabled) =>
      ServerToolset(
        name: t.name,
        label: t.label,
        description: t.description,
        enabled: enabled,
        available: t.available,
        configured: t.configured,
      );

  void _open(ServerToolset toolset) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ServerToolsetDetailScreen(
          toolset: toolset,
          repository: widget.repository,
          writable: widget.writable,
          isCurrent: widget.isCurrent,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final rows = _toolsets;
    return HermesPage(
      title: s.ad1215PageTools,
      children: [
        if (!widget.writable) HermesInfoBanner(s.readOnlyNotice),
        if (_failed)
          HermesListGroup(
            children: [
              HermesListRow(
                title: s.ad1215LoadFailed,
                icon: Icons.refresh,
                onTap: () => unawaited(_load()),
              ),
            ],
          )
        else if (rows == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: TuiLoader()),
          )
        else
          HermesListGroup(
            children: [
              for (final toolset in rows)
                HermesListRow(
                  key: ValueKey('toolset-${toolset.name}'),
                  title: toolset.label,
                  subtitle: toolset.description,
                  subtitleMaxLines: 2,
                  showChevron: false,
                  onTap: _hasOptions[toolset.name] == true
                      ? () => _open(toolset)
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        key: ValueKey('toolset-switch-${toolset.name}'),
                        value: toolset.enabled,
                        onChanged:
                            widget.writable && !_busy.contains(toolset.name)
                            ? (value) => unawaited(_toggle(toolset, value))
                            : null,
                      ),
                      if (_hasOptions[toolset.name] == true)
                        const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Providers, model and credentials of one toolset (only for toolsets whose
/// config reports `has_category`).
class ServerToolsetDetailScreen extends StatefulWidget {
  const ServerToolsetDetailScreen({
    required this.toolset,
    required this.repository,
    required this.writable,
    this.isCurrent,
    super.key,
  });

  final ServerToolset toolset;
  final ServerToolsetsRepository repository;
  final bool writable;
  final bool Function()? isCurrent;

  @override
  State<ServerToolsetDetailScreen> createState() =>
      _ServerToolsetDetailScreenState();
}

class _ServerToolsetDetailScreenState extends State<ServerToolsetDetailScreen> {
  ToolsetConfig? _config;
  ToolsetModels? _models;
  bool _failed = false;
  bool _busy = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final config = await widget.repository.config(
        widget.toolset.name,
        isCurrent: widget.isCurrent,
      );
      if (_disposed || config == null) return;
      setState(() => _config = config);
      try {
        final models = await widget.repository.models(
          widget.toolset.name,
          isCurrent: widget.isCurrent,
        );
        if (!_disposed && models != null) setState(() => _models = models);
      } on ServerConfigException {
        // No model list for this toolset.
      }
    } on ServerConfigException {
      if (!_disposed) setState(() => _failed = true);
    }
  }

  void _say(String text, HermesNoticeKind kind) {
    HermesNotice.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)), kind: kind);
  }

  Future<void> _reread() async {
    final config = await widget.repository.config(
      widget.toolset.name,
      isCurrent: widget.isCurrent,
    );
    if (!_disposed && config != null) setState(() => _config = config);
  }

  Future<void> _chooseProvider(ToolsetProvider provider) async {
    if (_busy || provider.isActive) return;
    final s = Strings.of(context);
    setState(() => _busy = true);
    try {
      final result = await widget.repository.setProvider(
        widget.toolset.name,
        provider.name,
        isCurrent: widget.isCurrent,
      );
      if (_disposed) return;
      if (result.outcome == ServerConfigSaveOutcome.stale) return;
      if (result.outcome == ServerConfigSaveOutcome.mismatch) {
        _say(s.ad1215SaveFailed, HermesNoticeKind.error);
      } else if (result.needsNousAuth) {
        _say(s.ad1215NeedsNous, HermesNoticeKind.warning);
      }
      await _reread();
    } on ServerConfigException {
      if (!_disposed) _say(s.ad1215SaveFailed, HermesNoticeKind.error);
    } finally {
      if (!_disposed) setState(() => _busy = false);
    }
  }

  Future<void> _chooseModel() async {
    final models = _models;
    if (models == null || _busy) return;
    final s = Strings.of(context);
    final choice = await showHermesOptions<String>(
      context: context,
      title: s.ad1215Model,
      selected: models.current,
      options: [
        for (final m in models.models)
          HermesOption(value: m.id, label: m.display),
      ],
    );
    if (choice == null || choice == models.current || _disposed) return;
    setState(() => _busy = true);
    try {
      final result = await widget.repository.setModel(
        widget.toolset.name,
        choice,
        isCurrent: widget.isCurrent,
      );
      if (_disposed || result.outcome == ServerConfigSaveOutcome.stale) return;
      if (result.outcome == ServerConfigSaveOutcome.mismatch) {
        _say(s.ad1215SaveFailed, HermesNoticeKind.error);
      }
      final fresh = await widget.repository.models(
        widget.toolset.name,
        isCurrent: widget.isCurrent,
      );
      if (!_disposed && fresh != null) setState(() => _models = fresh);
    } on ServerConfigException {
      if (!_disposed) _say(s.ad1215SaveFailed, HermesNoticeKind.error);
    } finally {
      if (!_disposed) setState(() => _busy = false);
    }
  }

  Future<void> _editKey(ToolsetEnvVar variable) async {
    final s = Strings.of(context);
    var value = '';
    final save = await showHermesFormDialog<bool>(
      context: context,
      title: variable.prompt ?? variable.key,
      actions: [
        HermesDialogAction(label: s.commonCancel, value: false),
        HermesDialogAction(label: s.commonSave, value: true),
      ],
      enabled: (save) => !save || value.trim().isNotEmpty,
      body: (context, setState) => ServerConfigTextEditor(
        initial: '',
        obscure: true,
        hintText: s.ad1215KeyField(variable.key),
        onChanged: (text) => setState(() => value = text),
      ),
    );
    final secret = value.trim();
    value = '';
    if (save != true || secret.isEmpty || _disposed) return;
    setState(() => _busy = true);
    try {
      await widget.repository.saveEnv(widget.toolset.name, {
        variable.key: secret,
      });
      await _reread();
    } on ServerConfigException {
      if (!_disposed) _say(s.ad1215SaveFailed, HermesNoticeKind.error);
    } finally {
      if (!_disposed) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final config = _config;
    final models = _models;
    final active = config?.providers.where((p) => p.isActive).firstOrNull;
    final canEdit = widget.writable && !_busy;
    return HermesPage(
      title: widget.toolset.label,
      children: [
        if (!widget.writable) HermesInfoBanner(s.readOnlyNotice),
        if (_failed)
          HermesListGroup(
            children: [
              HermesListRow(
                title: s.ad1215LoadFailed,
                icon: Icons.refresh,
                onTap: () => unawaited(_load()),
              ),
            ],
          )
        else if (config == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: TuiLoader()),
          )
        else ...[
          if (config.providers.isNotEmpty) ...[
            HermesSectionHeader(s.ad1215Provider),
            HermesListGroup(
              children: [
                for (final provider in config.providers)
                  HermesListRow(
                    key: ValueKey('toolset-provider-${provider.name}'),
                    title: provider.name,
                    subtitle: [
                      ?provider.badge,
                      ?provider.status,
                      if (provider.requiresNousAuth) s.ad1215NeedsNous,
                    ].join(' · '),
                    showChevron: false,
                    trailing: provider.isActive
                        ? const Icon(Icons.check)
                        : null,
                    onTap: canEdit && !provider.isActive
                        ? () => unawaited(_chooseProvider(provider))
                        : null,
                  ),
              ],
            ),
          ],
          if (models != null &&
              models.hasModels &&
              models.models.isNotEmpty) ...[
            HermesSectionHeader(s.ad1215Model),
            HermesListGroup(
              children: [
                HermesSelectRow(
                  key: const ValueKey('toolset-model'),
                  title: s.ad1215Model,
                  value:
                      models.models
                          .where((m) => m.id == models.current)
                          .map((m) => m.display)
                          .firstOrNull ??
                      models.current ??
                      '—',
                  onTap: canEdit ? () => unawaited(_chooseModel()) : null,
                ),
              ],
            ),
          ],
          if (active != null && active.envVars.isNotEmpty) ...[
            HermesSectionHeader(s.ad1215Credentials),
            HermesListGroup(
              children: [
                for (final variable in active.envVars)
                  HermesSelectRow(
                    key: ValueKey('toolset-env-${variable.key}'),
                    title: variable.prompt ?? variable.key,
                    value: variable.isSet ? s.ad1215KeySet : s.ad1215KeyMissing,
                    onTap: canEdit ? () => unawaited(_editKey(variable)) : null,
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}
