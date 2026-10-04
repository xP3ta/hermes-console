import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart' show HermesSelectRow;
import '../design/list.dart' show HermesListRow;
import '../design/modal.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesOption,
        showHermesFormDialog,
        showHermesOptions;
import '../design/page.dart';
import '../models/server_toolset.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/server_config_repository.dart'
    show ServerConfigException, ServerConfigFailureKind;
import '../services/server_toolsets_repository.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart' show showHermesConfirmDialog;
import '../widgets/hermes_ui.dart';

/// How a toolsets screen gets its repository for a profile.
typedef ServerToolsetsFactory =
    ServerToolsetsRepository Function(String profile, {required bool writable});

/// What both toolsets screens need: the profile ticket and a repository per
/// profile, on one Dashboard client closed with the screen.
mixin _ToolsetsAccess<T extends StatefulWidget> on State<T> {
  SavedConnection get connection;
  ConnectionManager get connManager;
  ServerToolsetsFactory? get toolsetsFor;

  DashboardClient? _client;
  late final ActiveProfileScope scope = ActiveProfileScope.of(
    connManager,
    connection.id,
  );
  late ProfileReadTicket ticket;
  late ServerToolsetsRepository repo;

  bool get readOnly =>
      connection.readOnly ||
      connManager.loadCapabilities(connection.id).configWrite == CapState.no;

  void openRepo() {
    ticket = scope.capture();
    final writable = !readOnly;
    repo =
        toolsetsFor?.call(ticket.name, writable: writable) ??
        ServerToolsetsRepository(
          _client ??= DashboardClient.lazy(connection),
          profile: ticket.name,
          writable: writable,
        );
  }

  void closeClient() => _client?.close();

  bool get isCurrent => mounted && ticket.isCurrent;

  String failureText(Strings s, Object error) {
    final kind = error is ServerConfigException ? error.kind : null;
    return switch (kind) {
      ServerConfigFailureKind.unconfirmed => s.adv1215SaveUnconfirmed,
      ServerConfigFailureKind.authentication ||
      ServerConfigFailureKind.permissionDenied ||
      ServerConfigFailureKind.readOnly => s.adv1215SaveDenied,
      _ => s.adv1215SaveFailed,
    };
  }
}

/// Settings › Advanced › Tools: the server's toolsets with their switches.
/// Tapping a row opens its detail.
class ServerToolsetsScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;

  @visibleForTesting
  final ServerToolsetsFactory? toolsetsFor;

  const ServerToolsetsScreen({
    super.key,
    required this.connection,
    required this.connManager,
    this.toolsetsFor,
  });

  @override
  State<ServerToolsetsScreen> createState() => _ServerToolsetsScreenState();
}

class _ServerToolsetsScreenState extends State<ServerToolsetsScreen>
    with _ToolsetsAccess<ServerToolsetsScreen> {
  @override
  SavedConnection get connection => widget.connection;
  @override
  ConnectionManager get connManager => widget.connManager;
  @override
  ServerToolsetsFactory? get toolsetsFor => widget.toolsetsFor;

  List<ServerToolset>? _rows;
  ServerConfigFailureKind? _failure;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    scope.addListener(_onProfileChanged);
    _open();
  }

  @override
  void dispose() {
    scope.removeListener(_onProfileChanged);
    closeClient();
    super.dispose();
  }

  void _onProfileChanged() {
    setState(() {
      _rows = null;
      _failure = null;
      _busy.clear();
    });
    _open();
  }

  void _open() {
    openRepo();
    unawaited(_load());
  }

  Future<void> _load() async {
    final mine = ticket;
    try {
      final rows = await repo.list();
      if (!mounted || !mine.isCurrent) return;
      setState(() {
        _rows = rows;
        _failure = null;
      });
    } on ServerConfigException catch (error) {
      if (!mounted || !mine.isCurrent) return;
      setState(() => _failure = error.kind);
    }
  }

  Future<void> _toggle(ServerToolset row, bool enabled) async {
    final s = Strings.of(context);
    final notices = HermesNotice.of(context);
    final rows = _rows ?? const <ServerToolset>[];
    if (!enabled && rows.where((r) => r.enabled).length == 1) {
      final confirmed = await showHermesConfirmDialog(
        context: context,
        title: s.adv1215ToolsLastTitle,
        message: s.adv1215ToolsLastBody,
        confirmLabel: s.adv1215ToolsLastConfirm,
        cancelLabel: s.commonCancel,
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    final mine = ticket;
    setState(() => _busy.add(row.name));
    try {
      final result = await repo.setEnabled(row.name, enabled);
      if (!mounted || !mine.isCurrent) return;
      setState(() => _rows = result.toolsets);
      if (result.postSetupStarted) {
        notices.show(message: s.voiceServerSetupRunning);
      }
    } on ServerConfigException catch (error) {
      if (!mounted || !mine.isCurrent) return;
      notices.show(
        message: failureText(s, error),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted && mine.isCurrent) setState(() => _busy.remove(row.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final rows = _rows;
    final children = <Widget>[
      if (readOnly) ...[
        HermesInfoBanner(s.chaCompressionConfigReadOnly),
        const SizedBox(height: 12),
      ],
    ];
    if (rows == null && _failure == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: TuiLoader()),
        ),
      );
    } else if (rows == null) {
      children.add(
        HermesInfoBanner(
          _failure == ServerConfigFailureKind.unsupported
              ? s.adv1215Unsupported
              : s.adv1215LoadFailed,
        ),
      );
    } else if (rows.isEmpty) {
      children.add(HermesInfoBanner(s.adv1215ToolsNone));
    } else {
      children.add(
        HermesGroup(
          children: [
            for (final row in rows)
              HermesListRow(
                key: ValueKey('adv1215-toolset-${row.name}'),
                title: row.label,
                subtitle: row.available
                    ? row.description
                    : s.adv1215ToolUnavailable,
                trailing: Switch(
                  value: row.enabled,
                  onChanged: readOnly || _busy.contains(row.name)
                      ? null
                      : (next) => unawaited(_toggle(row, next)),
                ),
                showChevron: false,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ToolsetDetailScreen(
                      connection: widget.connection,
                      connManager: widget.connManager,
                      toolset: row,
                      toolsetsFor: widget.toolsetsFor,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return HermesPage(
      title: s.drawerTools,
      onRefresh: _load,
      children: children,
    );
  }
}

/// One toolset: its providers, the model of the active one and the keys it
/// needs. Only shown content the server has: a toolset without a category
/// says there is nothing to configure.
class ToolsetDetailScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  final ServerToolset toolset;

  @visibleForTesting
  final ServerToolsetsFactory? toolsetsFor;

  const ToolsetDetailScreen({
    super.key,
    required this.connection,
    required this.connManager,
    required this.toolset,
    this.toolsetsFor,
  });

  @override
  State<ToolsetDetailScreen> createState() => _ToolsetDetailScreenState();
}

class _ToolsetDetailScreenState extends State<ToolsetDetailScreen>
    with _ToolsetsAccess<ToolsetDetailScreen> {
  @override
  SavedConnection get connection => widget.connection;
  @override
  ConnectionManager get connManager => widget.connManager;
  @override
  ServerToolsetsFactory? get toolsetsFor => widget.toolsetsFor;

  ToolsetConfig? _config;
  ToolsetModels? _models;
  ServerConfigFailureKind? _failure;
  bool _busy = false;

  String get _name => widget.toolset.name;

  @override
  void initState() {
    super.initState();
    scope.addListener(_onProfileChanged);
    _open();
  }

  @override
  void dispose() {
    scope.removeListener(_onProfileChanged);
    closeClient();
    super.dispose();
  }

  void _onProfileChanged() {
    setState(() {
      _config = null;
      _models = null;
      _failure = null;
      _busy = false;
    });
    _open();
  }

  void _open() {
    openRepo();
    unawaited(_load());
  }

  Future<void> _load() async {
    final mine = ticket;
    try {
      final config = await repo.config(_name);
      ToolsetModels? models;
      if (config.hasCategory) {
        try {
          models = await repo.models(_name);
        } on ServerConfigException {
          models = null;
        }
      }
      if (!mounted || !mine.isCurrent) return;
      setState(() {
        _config = config;
        _models = models;
        _failure = null;
      });
    } on ServerConfigException catch (error) {
      if (!mounted || !mine.isCurrent) return;
      setState(() => _failure = error.kind);
    }
  }

  Future<void> _write(Future<void> Function() action) async {
    final s = Strings.of(context);
    final notices = HermesNotice.of(context);
    final mine = ticket;
    setState(() => _busy = true);
    try {
      await action();
    } on ServerConfigException catch (error) {
      if (!mounted || !mine.isCurrent) return;
      notices.show(
        message: failureText(s, error),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted && mine.isCurrent) setState(() => _busy = false);
    }
  }

  Future<void> _chooseProvider(ToolsetProvider provider) => _write(() async {
    final mine = ticket;
    final config = await repo.setProvider(_name, provider.name);
    if (mounted && mine.isCurrent) setState(() => _config = config);
  });

  Future<void> _chooseModel(String model) => _write(() async {
    final mine = ticket;
    final models = await repo.setModel(_name, model);
    if (mounted && mine.isCurrent) setState(() => _models = models);
  });

  Future<void> _pickModel(BuildContext context) async {
    final models = _models;
    if (models == null) return;
    final picked = await showHermesOptions<String>(
      context: context,
      title: Strings.of(context).adv1215ToolModel,
      selected: models.current,
      options: [
        for (final model in models.models)
          HermesOption<String>(value: model.id, label: model.display),
      ],
    );
    if (picked == null || picked == models.current || !mounted) return;
    await _chooseModel(picked);
  }

  Future<void> _enterKey(BuildContext context, ToolsetEnvVar variable) async {
    final s = Strings.of(context);
    final text = TextEditingController();
    try {
      final confirmed = await showHermesFormDialog<bool>(
        context: context,
        title: variable.key,
        message: variable.prompt,
        actions: [
          HermesDialogAction(
            label: s.commonCancel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(label: s.commonSave, value: true),
        ],
        enabled: (save) => !save || text.text.trim().isNotEmpty,
        body: (context, setState) => TextField(
          controller: text,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(hintText: s.adv1215ToolKeyHint),
          onChanged: (_) => setState(() {}),
        ),
      );
      final value = text.text;
      if (confirmed != true || value.trim().isEmpty || !mounted) return;
      await _write(() async {
        final mine = ticket;
        final config = await repo.saveCredentials(_name, {variable.key: value});
        if (mounted && mine.isCurrent) setState(() => _config = config);
      });
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => text.dispose());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final config = _config;
    final children = <Widget>[
      if (readOnly) ...[
        HermesInfoBanner(s.chaCompressionConfigReadOnly),
        const SizedBox(height: 12),
      ],
    ];
    if (config == null && _failure == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: TuiLoader()),
        ),
      );
    } else if (config == null) {
      children.add(
        HermesInfoBanner(
          _failure == ServerConfigFailureKind.unsupported
              ? s.adv1215Unsupported
              : s.adv1215LoadFailed,
        ),
      );
    } else if (!config.hasCategory) {
      children.add(HermesInfoBanner(s.adv1215ToolNothing));
    } else {
      final editable = !readOnly && !_busy;
      final active = config.providers.where((p) => p.isActive).firstOrNull;
      if (config.providers.isNotEmpty) {
        children
          ..add(HermesSectionHeader(s.adv1215ToolProviders))
          ..add(
            HermesGroup(
              children: [
                for (final provider in config.providers)
                  HermesListRow(
                    key: ValueKey('adv1215-provider-${provider.name}'),
                    title: provider.name,
                    subtitle: provider.requiresNousAuth
                        ? s.adv1215ToolNeedsNous
                        : [
                            provider.badge,
                            provider.tag,
                            provider.status,
                          ].whereType<String>().join(' · ').nullIfEmpty,
                    trailing: provider.isActive
                        ? const Icon(Icons.check_rounded, size: 20)
                        : null,
                    showChevron: false,
                    onTap: editable && !provider.isActive
                        ? () => unawaited(_chooseProvider(provider))
                        : null,
                  ),
              ],
            ),
          );
      }
      final models = _models;
      if (models != null && models.hasModels && models.models.isNotEmpty) {
        final current = models.models
            .where((m) => m.id == models.current)
            .firstOrNull;
        children
          ..add(HermesSectionHeader(s.adv1215ToolModel))
          ..add(
            HermesGroup(
              children: [
                HermesSelectRow(
                  key: const ValueKey('adv1215-toolset-model'),
                  title: s.adv1215ToolModel,
                  value: current?.display ?? models.current ?? '—',
                  onTap: editable ? () => unawaited(_pickModel(context)) : null,
                ),
              ],
            ),
          );
      }
      if (active != null && active.envVars.isNotEmpty) {
        children
          ..add(HermesSectionHeader(s.adv1215ToolCredentials))
          ..add(
            HermesGroup(
              children: [
                for (final variable in active.envVars)
                  HermesListRow(
                    key: ValueKey('adv1215-env-${variable.key}'),
                    title: variable.key,
                    subtitle: variable.prompt,
                    value: variable.isSet
                        ? s.adv1215ToolKeySet
                        : s.adv1215ToolKeyUnset,
                    onTap: editable
                        ? () => unawaited(_enterKey(context, variable))
                        : null,
                  ),
              ],
            ),
          );
      }
    }
    return HermesPage(
      title: widget.toolset.label,
      onRefresh: _load,
      children: children,
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
