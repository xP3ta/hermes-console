import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/admin_integrations.dart';
import '../models/desktop_control_center.dart';
import '../services/desktop_control_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/mcp_provisioning_surface.dart';
import 'admin_integrations_copy.dart';
import 'admin_integrations_screen.dart';
import 'lock_screen.dart';

enum _ExtensionsSection { plugins, tools, mcp }

final class _Captured<T> {
  final T? value;
  final Object? error;

  const _Captured.value(this.value) : error = null;
  const _Captured.error(this.error) : value = null;
}

Future<_Captured<T>> _capture<T>(Future<T> future) async {
  try {
    return _Captured<T>.value(await future);
  } catch (error) {
    return _Captured<T>.error(error);
  }
}

/// Mobile control centre for Hermes Agent plugins, toolsets and MCP.
///
/// Runtime inventory/toggles keep using the TUI JSON-RPC contract. Optional
/// installation and removal use the authenticated Dashboard API exposed by
/// [HermesExtensionManagementGateway]. Legacy gateways therefore keep their
/// existing surface instead of receiving fabricated capabilities.
class ExtensionsCenterScreen extends StatefulWidget {
  final HermesDesktopControlGateway gateway;
  final String runtimeSessionId;
  final bool readOnly;
  final Future<void> Function()? disposeGateway;

  const ExtensionsCenterScreen({
    required this.gateway,
    this.runtimeSessionId = '',
    this.readOnly = false,
    this.disposeGateway,
    super.key,
  });

  @override
  State<ExtensionsCenterScreen> createState() => _ExtensionsCenterScreenState();
}

class _ExtensionsCenterScreenState extends State<ExtensionsCenterScreen> {
  ExtensionsInventory? _inventory;
  Object? _failure;
  List<DesktopPluginManagementEntry> _managedPlugins = const [];
  List<DesktopMcpServerEntry> _mcpServers = const [];
  List<DesktopMcpCatalogEntry> _mcpCatalog = const [];
  Object? _pluginManagementFailure;
  Object? _mcpServersFailure;
  Object? _mcpCatalogFailure;
  bool _loading = true;
  final Set<String> _busyActions = {};
  _ExtensionsSection _section = _ExtensionsSection.plugins;
  bool _activeOnly = false;
  String _query = '';

  HermesExtensionManagementGateway? get _management =>
      widget.gateway is HermesExtensionManagementGateway
      ? widget.gateway as HermesExtensionManagementGateway
      : null;

  HermesMcpProvisioningGateway? get _provisioning =>
      widget.gateway is HermesMcpProvisioningGateway
      ? widget.gateway as HermesMcpProvisioningGateway
      : null;

  bool get _hasAdminIntegrations =>
      widget.gateway is HermesMcpProvisioningGateway ||
      widget.gateway is HermesWebhookManagementGateway ||
      widget.gateway is HermesServerPlatformCapabilitiesGateway;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ExtensionsCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.runtimeSessionId != widget.runtimeSessionId) {
      _inventory = null;
      _failure = null;
      _managedPlugins = const [];
      _mcpServers = const [];
      _mcpCatalog = const [];
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    final close = widget.disposeGateway;
    if (close != null) unawaited(close());
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }

    final inventoryFuture = _capture(
      widget.gateway.extensionsInventory(
        runtimeSessionId: widget.runtimeSessionId,
      ),
    );
    final management = _management;
    final pluginsFuture = management == null
        ? Future.value(
            const _Captured<List<DesktopPluginManagementEntry>>.value([]),
          )
        : _capture(management.managedPlugins());
    final serversFuture = management == null
        ? Future.value(const _Captured<List<DesktopMcpServerEntry>>.value([]))
        : _capture(management.mcpServers());
    final catalogFuture = management == null
        ? Future.value(const _Captured<List<DesktopMcpCatalogEntry>>.value([]))
        : _capture(management.mcpCatalog());

    final inventoryResult = await inventoryFuture;
    final pluginsResult = await pluginsFuture;
    final serversResult = await serversFuture;
    final catalogResult = await catalogFuture;
    if (!mounted) return;

    setState(() {
      if (inventoryResult.value != null) _inventory = inventoryResult.value;
      _failure = inventoryResult.error;
      if (pluginsResult.value != null) {
        _managedPlugins = pluginsResult.value!;
      }
      if (serversResult.value != null) _mcpServers = serversResult.value!;
      if (catalogResult.value != null) _mcpCatalog = catalogResult.value!;
      _pluginManagementFailure = pluginsResult.error;
      _mcpServersFailure = serversResult.error;
      _mcpCatalogFailure = catalogResult.error;
      _loading = false;
    });
  }

  Future<bool> _confirmChange({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) async {
    if (widget.readOnly) return false;
    final colors = Theme.of(context).hermes;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Strings.of(context).commonCancel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: Colors.white,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return approved == true;
  }

  Future<bool> _verifyLock(String reason) async {
    if (!mounted || widget.readOnly) return false;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock == null) return true;
    return LockScreen.verify(context, lock, reason: reason);
  }

  Future<void> _togglePlugin(DesktopPluginEntry plugin, bool enabled) async {
    final actionId = 'plugin:${plugin.name}';
    if (widget.readOnly || _busyActions.contains(actionId)) return;
    final strings = Strings.of(context);
    final title = enabled
        ? strings.extensionsCenterEnablePluginTitle
        : strings.extensionsCenterDisablePluginTitle;
    final approved = await _confirmChange(
      title: title,
      body: strings.extensionsCenterChangeBody(
        enabled
            ? strings.extensionsCenterWillEnable
            : strings.extensionsCenterWillDisable,
        _safeRemoteText(plugin.name, strings),
        strings.extensionsCenterOnInstance,
      ),
      action: strings.extensionsCenterConfirmChange,
    );
    if (!approved || !await _verifyLock(title) || !mounted) return;
    await _runAction(
      actionId,
      () => widget.gateway.setPluginEnabled(plugin.name, enabled),
    );
  }

  Future<void> _toggleToolset(DesktopToolsetEntry toolset, bool enabled) async {
    final actionId = 'toolset:${toolset.name}';
    if (widget.readOnly || _busyActions.contains(actionId)) return;
    final strings = Strings.of(context);
    final scope = widget.runtimeSessionId.trim().isEmpty
        ? strings.extensionsCenterForInstance
        : strings.extensionsCenterForConversation;
    final approved = await _confirmChange(
      title: enabled
          ? strings.extensionsCenterEnableToolsetTitle
          : strings.extensionsCenterDisableToolsetTitle,
      body: strings.extensionsCenterChangeBody(
        enabled
            ? strings.extensionsCenterWillEnable
            : strings.extensionsCenterWillDisable,
        _safeRemoteText(toolset.name, strings),
        scope,
      ),
      action: strings.extensionsCenterConfirmChange,
    );
    if (!approved || !mounted) return;
    await _runAction(
      actionId,
      () => widget.gateway.setToolsetEnabled(
        toolset.name,
        enabled,
        runtimeSessionId: widget.runtimeSessionId,
      ),
    );
  }

  Future<void> _reloadMcp() async {
    const actionId = 'reload:mcp';
    if (widget.readOnly || _busyActions.contains(actionId)) return;
    final strings = Strings.of(context);
    final approved = await _confirmChange(
      title: strings.extensionsCenterReloadTitle,
      body: strings.extensionsCenterReloadBody,
      action: strings.extensionsCenterReloadNow,
    );
    if (!approved || !mounted) return;
    await _runAction(
      actionId,
      () => widget.gateway.reloadMcp(
        runtimeSessionId: widget.runtimeSessionId,
        confirmed: true,
      ),
      success: strings.extensionsCenterReloaded,
    );
  }

  Future<void> _runAction(
    String actionId,
    Future<void> Function() action, {
    String? success,
  }) async {
    if (!mounted || _busyActions.contains(actionId)) return;
    setState(() => _busyActions.add(actionId));
    try {
      await action();
      await _load();
      if (!mounted || success == null) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(success)),
        kind: HermesNoticeKind.success,
      );
    } catch (error) {
      if (!mounted) return;
      _showMutationFailure(error);
    } finally {
      if (mounted) setState(() => _busyActions.remove(actionId));
    }
  }

  Future<void> _installPlugin() async {
    final management = _management;
    if (management == null || widget.readOnly) return;
    final draft = await showHermesFloatingSurface<_PluginInstallDraft>(
      context: context,
      surfaceKey: const ValueKey('extensions-plugin-install-surface'),
      maxWidth: 520,
      builder: (_) => const _PluginInstallSheet(),
    );
    if (!mounted || draft == null) return;
    final strings = Strings.of(context);
    final source = _safeRemoteText(draft.identifier, strings);
    final approved = await _confirmChange(
      title: strings.extensionsCenterPluginInstallConfirmTitle,
      body: strings.extensionsCenterPluginInstallConfirmBody(source),
      action: strings.extensionsCenterPluginInstallAction,
    );
    if (!approved ||
        !await _verifyLock(strings.extensionsCenterPluginInstallConfirmTitle) ||
        !mounted) {
      return;
    }
    const actionId = 'plugin:install';
    setState(() => _busyActions.add(actionId));
    try {
      final result = await management.installPlugin(
        draft.identifier,
        enable: draft.enableAfterInstall,
      );
      await _load();
      if (!mounted) return;
      final notice = result.notices.isEmpty
          ? strings.extensionsCenterPluginInstalled
          : strings.extensionsCenterPluginInstalledWithNotice;
      HermesNotice.of(
        context,
      ).showSnackBar(SnackBar(content: Text(notice)));
    } catch (error) {
      if (mounted) _showMutationFailure(error);
    } finally {
      if (mounted) setState(() => _busyActions.remove(actionId));
    }
  }

  Future<void> _updatePlugin(DesktopPluginEntry plugin) async {
    final management = _management;
    if (management == null || widget.readOnly) return;
    final strings = Strings.of(context);
    final title = strings.extensionsCenterPluginUpdateTitle;
    final approved = await _confirmChange(
      title: title,
      body: strings.extensionsCenterPluginUpdateBody(
        _safeRemoteText(plugin.name, strings),
      ),
      action: strings.extensionsCenterPluginUpdateAction,
    );
    if (!approved || !await _verifyLock(title) || !mounted) return;
    await _runAction(
      'plugin:update:${plugin.name}',
      () => management.updatePlugin(plugin.name),
      success: strings.extensionsCenterPluginUpdated,
    );
  }

  Future<void> _removePlugin(DesktopPluginEntry plugin) async {
    final management = _management;
    if (management == null || widget.readOnly) return;
    final strings = Strings.of(context);
    final title = strings.extensionsCenterPluginRemoveTitle;
    final approved = await _confirmChange(
      title: title,
      body: strings.extensionsCenterPluginRemoveBody(
        _safeRemoteText(plugin.name, strings),
      ),
      action: strings.commonDelete,
      destructive: true,
    );
    if (!approved || !await _verifyLock(title) || !mounted) return;
    await _runAction(
      'plugin:remove:${plugin.name}',
      () => management.removePlugin(plugin.name),
      success: strings.extensionsCenterPluginRemoved,
    );
  }

  Future<void> _openMcpCatalog() async {
    if (_management == null || _mcpCatalog.isEmpty) return;
    final selected = await showHermesFloatingSurface<DesktopMcpCatalogEntry>(
      context: context,
      surfaceKey: const ValueKey('extensions-mcp-catalog-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.86,
      builder: (_) => _McpCatalogSheet(entries: _mcpCatalog),
    );
    if (!mounted || selected == null) return;
    await _installMcp(selected);
  }

  Future<void> _installMcp(DesktopMcpCatalogEntry entry) async {
    final management = _management;
    if (management == null || widget.readOnly) return;
    final environment = await showHermesFloatingSurface<Map<String, String>>(
      context: context,
      surfaceKey: const ValueKey('extensions-mcp-install-review-surface'),
      maxWidth: 560,
      builder: (_) => _McpInstallReviewSheet(entry: entry),
    );
    if (!mounted || environment == null) return;
    final strings = Strings.of(context);
    if (!await _verifyLock(strings.extensionsCenterMcpInstallTitle) ||
        !mounted) {
      return;
    }

    final actionId = 'mcp:install:${entry.name}';
    setState(() => _busyActions.add(actionId));
    try {
      final result = await management.installMcpCatalogEntry(
        entry.name,
        environment: environment,
      );
      await _load();
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.background
                ? strings.extensionsCenterMcpInstallStarted
                : strings.extensionsCenterMcpInstalled,
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showMutationFailure(error);
    } finally {
      if (mounted) setState(() => _busyActions.remove(actionId));
    }
  }

  Future<void> _toggleMcp(DesktopMcpServerEntry server, bool enabled) async {
    final management = _management;
    if (management == null || widget.readOnly) return;
    final strings = Strings.of(context);
    final title = enabled
        ? strings.extensionsCenterMcpEnableTitle
        : strings.extensionsCenterMcpDisableTitle;
    final approved = await _confirmChange(
      title: title,
      body: strings.extensionsCenterMcpToggleBody(
        _safeRemoteText(server.name, strings),
      ),
      action: strings.extensionsCenterConfirmChange,
    );
    if (!approved || !await _verifyLock(title) || !mounted) return;
    await _runAction('mcp:toggle:${server.name}', () async {
      await management.setMcpServerEnabled(server.name, enabled);
      await widget.gateway.reloadMcp(
        runtimeSessionId: widget.runtimeSessionId,
        confirmed: true,
      );
    });
  }

  Future<void> _removeMcp(DesktopMcpServerEntry server) async {
    final management = _management;
    if (management == null || widget.readOnly) return;
    final strings = Strings.of(context);
    final title = strings.extensionsCenterMcpRemoveTitle;
    final approved = await _confirmChange(
      title: title,
      body: strings.extensionsCenterMcpRemoveBody(
        _safeRemoteText(server.name, strings),
      ),
      action: strings.commonDelete,
      destructive: true,
    );
    if (!approved || !await _verifyLock(title) || !mounted) return;
    await _runAction('mcp:remove:${server.name}', () async {
      await management.removeMcpServer(server.name);
      await widget.gateway.reloadMcp(
        runtimeSessionId: widget.runtimeSessionId,
        confirmed: true,
      );
    }, success: strings.extensionsCenterMcpRemoved);
  }

  Future<void> _testMcp(DesktopMcpServerEntry server) async {
    final management = _management;
    if (management == null) return;
    final actionId = 'mcp:test:${server.name}';
    if (_busyActions.contains(actionId)) return;
    setState(() => _busyActions.add(actionId));
    try {
      final result = await management.testMcpServer(server.name);
      if (!mounted) return;
      final strings = Strings.of(context);
      final message = result.ok
          ? strings.extensionsCenterMcpTestSuccess(result.toolCount)
          : result.authorizationRequired
          ? strings.extensionsCenterMcpTestNeedsAuth
          : strings.extensionsCenterMcpTestFailed;
      HermesNotice.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) _showMutationFailure(error);
    } finally {
      if (mounted) setState(() => _busyActions.remove(actionId));
    }
  }

  Future<void> _authorizeMcp(DesktopMcpServerEntry server) async {
    final provisioning = _provisioning;
    final actionId = 'mcp:authorize:${server.name}';
    if (provisioning == null ||
        widget.readOnly ||
        _busyActions.contains(actionId)) {
      return;
    }
    final copy = AdminIntegrationsCopy.of(context);
    if (!await _verifyLock(copy.authorize) || !mounted) return;
    setState(() => _busyActions.add(actionId));
    McpOAuthFlow? flow;
    try {
      flow = await provisioning.startMcpOAuth(server.name);
    } catch (error) {
      if (mounted) _showMutationFailure(error);
    } finally {
      if (mounted) setState(() => _busyActions.remove(actionId));
    }
    if (!mounted || flow == null) return;
    await showMcpOAuthFlowSurface(
      context: context,
      gateway: provisioning,
      initialFlow: flow,
    );
    if (mounted) await _load();
  }

  Future<void> _openAdminIntegrations() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => AdminIntegrationsScreen(
        gateway: widget.gateway,
        readOnly: widget.readOnly,
      ),
    ),
  );

  void _showMutationFailure(Object error) {
    final strings = Strings.of(context);
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(_extensionsMutationFailureText(error, strings))),
      kind: HermesNoticeKind.error,
    );
  }

  List<DesktopPluginEntry> _plugins(ExtensionsInventory inventory) {
    final query = _query.trim().toLowerCase();
    final plugins = inventory.plugins
        .where((plugin) {
          if (_activeOnly && !plugin.enabled) return false;
          if (query.isEmpty) return true;
          return [
            plugin.name,
            plugin.version,
            plugin.description,
            plugin.source,
          ].any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
    return [...plugins]..sort((a, b) {
      final active = (b.enabled ? 1 : 0).compareTo(a.enabled ? 1 : 0);
      return active != 0
          ? active
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  List<DesktopToolsetEntry> _toolsets(ExtensionsInventory inventory) {
    final query = _query.trim().toLowerCase();
    final toolsets = inventory.toolsets
        .where((toolset) {
          if (_activeOnly && !toolset.enabled) return false;
          if (query.isEmpty) return true;
          return [
            toolset.name,
            toolset.description,
            ...toolset.tools,
          ].any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
    return [...toolsets]..sort((a, b) {
      final active = (b.enabled ? 1 : 0).compareTo(a.enabled ? 1 : 0);
      return active != 0
          ? active
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  List<DesktopMcpServerEntry> _visibleMcpServers() {
    final query = _query.trim().toLowerCase();
    final servers = _mcpServers
        .where((server) {
          if (_activeOnly && !server.enabled) return false;
          if (query.isEmpty) return true;
          return [
            server.name,
            server.transport,
            server.endpointLabel,
          ].any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
    return [...servers]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void _selectSection(_ExtensionsSection section) {
    setState(() {
      _section = section;
      _query = '';
      _activeOnly = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final inventory = _inventory;
    final plugins = inventory == null
        ? const <DesktopPluginEntry>[]
        : _plugins(inventory);
    final toolsets = inventory == null
        ? const <DesktopToolsetEntry>[]
        : _toolsets(inventory);
    final mcpServers = _visibleMcpServers();
    final visibleCount = switch (_section) {
      _ExtensionsSection.plugins => plugins.length,
      _ExtensionsSection.tools => toolsets.length,
      _ExtensionsSection.mcp => mcpServers.length,
    };
    final totalCount = switch (_section) {
      _ExtensionsSection.plugins => inventory?.plugins.length ?? 0,
      _ExtensionsSection.tools => inventory?.toolsets.length ?? 0,
      _ExtensionsSection.mcp => _mcpServers.length,
    };

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Text(strings.extensionsCenterTitle),
        actions: [
          IconButton(
            tooltip: strings.extensionsCenterRefreshTooltip,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && inventory == null
            ? const Center(child: CircularProgressIndicator())
            : _failure != null && inventory == null
            ? _ExtensionsFailure(
                message: _extensionsFailureText(_failure!, strings),
                onRetry: _load,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 6, bottom: 30),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Text(
                        strings.extensionsCenterIntro,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ),
                    if (widget.readOnly)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: _ExtensionsNotice(
                          text: strings.extensionsCenterReadOnlyNotice,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: HermesSegmentedControl<_ExtensionsSection>(
                        value: _section,
                        onChanged: _selectSection,
                        segments: [
                          HermesSegment(
                            key: const ValueKey('extensions-section-plugins'),
                            value: _ExtensionsSection.plugins,
                            label: strings.extensionsCenterPluginsSection,
                          ),
                          HermesSegment(
                            key: const ValueKey('extensions-section-tools'),
                            value: _ExtensionsSection.tools,
                            label: strings.extensionsCenterToolsSection,
                          ),
                          HermesSegment(
                            key: const ValueKey('extensions-section-mcp'),
                            value: _ExtensionsSection.mcp,
                            label: strings.extensionsCenterMcpSection,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                      child: HermesSearchField(
                        key: ValueKey('extensions-search-${_section.name}'),
                        hintText: strings.extensionsCenterSearchHint,
                        clearTooltip: strings.extensionsCenterClearSearch,
                        onChanged: (value) => setState(() => _query = value),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                      child: Row(
                        children: [
                          FilterChip(
                            key: const ValueKey('extensions-active-only'),
                            label: Text(strings.extensionsCenterActiveOnly),
                            selected: _activeOnly,
                            onSelected: (selected) =>
                                setState(() => _activeOnly = selected),
                          ),
                          const Spacer(),
                          Text(
                            strings.extensionsCenterResultCount(
                              visibleCount,
                              totalCount,
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    switch (_section) {
                      _ExtensionsSection.plugins => _buildPlugins(
                        plugins,
                        inventory,
                      ),
                      _ExtensionsSection.tools => _buildTools(
                        toolsets,
                        inventory,
                      ),
                      _ExtensionsSection.mcp => _buildMcp(mcpServers),
                    },
                    if (_failure != null && inventory != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                        child: Text(
                          strings.extensionsCenterStaleInventory(
                            _extensionsFailureText(_failure!, strings),
                          ),
                          style: TextStyle(color: colors.warning, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildPlugins(
    List<DesktopPluginEntry> plugins,
    ExtensionsInventory? inventory,
  ) {
    final strings = Strings.of(context);
    final controls = {for (final entry in _managedPlugins) entry.name: entry};
    final management = _management;
    final widgets = <Widget>[
      if (management != null && _pluginManagementFailure == null)
        HermesListSection(
          children: [
            HermesListRow(
              key: const ValueKey('extensions-install-plugin'),
              icon: Icons.add_circle_outline_rounded,
              title: strings.extensionsCenterAddPlugin,
              subtitle: strings.extensionsCenterAddPluginSubtitle,
              enabled: !widget.readOnly,
              onTap: widget.readOnly ? null : _installPlugin,
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        )
      else
        _ManagementNotice(
          text: _managementNoticeText(_pluginManagementFailure, strings),
        ),
      if (inventory == null || inventory.plugins.isEmpty)
        HermesEmptyState(
          compact: true,
          icon: Icons.extension_off_outlined,
          title: strings.extensionsCenterPluginsEmpty,
          body: strings.extensionsCenterPluginsEmptyBody,
        )
      else if (plugins.isEmpty)
        HermesEmptyState(
          compact: true,
          icon: Icons.filter_alt_off_outlined,
          title: strings.extensionsCenterNoMatches,
          body: strings.extensionsCenterNoMatchesBody,
        )
      else
        HermesListSection(
          title: strings.extensionsCenterInstalledSection,
          children: [
            for (final plugin in plugins)
              _PluginRow(
                plugin: plugin,
                control: controls[plugin.name],
                readOnly: widget.readOnly,
                busy: _busyActions.any((id) => id.endsWith(':${plugin.name}')),
                onChanged: (enabled) => _togglePlugin(plugin, enabled),
                onUpdate: () => _updatePlugin(plugin),
                onRemove: () => _removePlugin(plugin),
              ),
          ],
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }

  Widget _buildTools(
    List<DesktopToolsetEntry> toolsets,
    ExtensionsInventory? inventory,
  ) {
    final strings = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesListSection(
          title: strings.extensionsCenterAddToolsTitle,
          children: [
            HermesListRow(
              icon: Icons.extension_outlined,
              title: strings.extensionsCenterAddToolsViaPlugin,
              subtitle: strings.extensionsCenterAddToolsViaPluginBody,
              onTap: () => _selectSection(_ExtensionsSection.plugins),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
            HermesListRow(
              icon: Icons.hub_outlined,
              title: strings.extensionsCenterAddToolsViaMcp,
              subtitle: strings.extensionsCenterAddToolsViaMcpBody,
              onTap: () => _selectSection(_ExtensionsSection.mcp),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        if (inventory == null || inventory.toolsets.isEmpty)
          HermesEmptyState(
            compact: true,
            icon: Icons.handyman_outlined,
            title: strings.extensionsCenterToolsEmpty,
            body: strings.extensionsCenterToolsEmptyBody,
          )
        else if (toolsets.isEmpty)
          HermesEmptyState(
            compact: true,
            icon: Icons.filter_alt_off_outlined,
            title: strings.extensionsCenterNoMatches,
            body: strings.extensionsCenterNoMatchesBody,
          )
        else
          HermesListSection(
            title: strings.extensionsCenterAvailableToolsets,
            children: [
              for (final toolset in toolsets)
                _ToolsetRow(
                  toolset: toolset,
                  readOnly: widget.readOnly,
                  busy: _busyActions.contains('toolset:${toolset.name}'),
                  onChanged: (enabled) => _toggleToolset(toolset, enabled),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildMcp(List<DesktopMcpServerEntry> servers) {
    final strings = Strings.of(context);
    final adminCopy = AdminIntegrationsCopy.of(context);
    final management = _management;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasAdminIntegrations)
          HermesListSection(
            children: [
              HermesListRow(
                key: const ValueKey('extensions-admin-integrations'),
                icon: Icons.admin_panel_settings_outlined,
                title: adminCopy.entryTitle,
                subtitle: adminCopy.entryBody,
                onTap: _openAdminIntegrations,
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        if (management != null && _mcpCatalogFailure == null)
          HermesListSection(
            children: [
              HermesListRow(
                key: const ValueKey('extensions-open-mcp-catalog'),
                icon: Icons.add_circle_outline_rounded,
                title: strings.extensionsCenterMcpCatalogAction,
                subtitle: strings.extensionsCenterMcpCatalogSubtitle(
                  _mcpCatalog.length,
                ),
                enabled: !widget.readOnly && _mcpCatalog.isNotEmpty,
                onTap: widget.readOnly || _mcpCatalog.isEmpty
                    ? null
                    : _openMcpCatalog,
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          )
        else
          _ManagementNotice(
            text: _managementNoticeText(_mcpCatalogFailure, strings),
          ),
        if (management != null && _mcpServersFailure == null) ...[
          if (_mcpServers.isEmpty)
            HermesEmptyState(
              compact: true,
              icon: Icons.hub_outlined,
              title: strings.extensionsCenterMcpNoServers,
              body: strings.extensionsCenterMcpNoServersBody,
              primaryLabel: _mcpCatalog.isEmpty
                  ? null
                  : strings.extensionsCenterMcpCatalogAction,
              onPrimary: _mcpCatalog.isEmpty ? null : _openMcpCatalog,
            )
          else if (servers.isEmpty)
            HermesEmptyState(
              compact: true,
              icon: Icons.filter_alt_off_outlined,
              title: strings.extensionsCenterNoMatches,
              body: strings.extensionsCenterNoMatchesBody,
            )
          else
            HermesListSection(
              title: strings.extensionsCenterMcpConfiguredSection,
              children: [
                for (final server in servers)
                  _McpServerRow(
                    server: server,
                    readOnly: widget.readOnly,
                    busy: _busyActions.any(
                      (id) => id.endsWith(':${server.name}'),
                    ),
                    onChanged: (enabled) => _toggleMcp(server, enabled),
                    onTest: () => _testMcp(server),
                    onAuthorize: () => _authorizeMcp(server),
                    canAuthorize:
                        _provisioning != null && server.auth == 'oauth',
                    onRemove: () => _removeMcp(server),
                  ),
              ],
            ),
        ] else if (management != null)
          _ManagementNotice(
            text: _managementNoticeText(_mcpServersFailure, strings),
          ),
        HermesListSection(
          title: strings.extensionsCenterMcpRuntimeSection,
          children: [
            HermesListRow(
              key: const ValueKey('extensions-reload-mcp'),
              icon: Icons.sync_rounded,
              title: strings.extensionsCenterReloadTitle,
              subtitle: strings.extensionsCenterReloadDescription,
              enabled: !widget.readOnly && !_busyActions.contains('reload:mcp'),
              onTap: widget.readOnly || _busyActions.contains('reload:mcp')
                  ? null
                  : _reloadMcp,
              trailing: _busyActions.contains('reload:mcp')
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _PluginRow extends StatelessWidget {
  final DesktopPluginEntry plugin;
  final DesktopPluginManagementEntry? control;
  final bool readOnly;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onUpdate;
  final VoidCallback onRemove;

  const _PluginRow({
    required this.plugin,
    required this.control,
    required this.readOnly,
    required this.busy,
    required this.onChanged,
    required this.onUpdate,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final subtitle = [
      if (plugin.version.isNotEmpty)
        strings.extensionsCenterPluginVersion(
          _safeRemoteText(plugin.version, strings),
        ),
      if (plugin.description.isNotEmpty)
        _safeRemoteText(plugin.description, strings),
      if (control?.authRequired == true)
        strings.extensionsCenterPluginAuthRequired,
    ].join(' · ');
    final hasMenu = control?.canUpdate == true || control?.canRemove == true;

    return HermesListRow(
      icon: Icons.extension_outlined,
      title: _safeRemoteText(plugin.name, strings),
      subtitle: subtitle,
      trailing: busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  key: ValueKey('plugin-toggle-${plugin.name}'),
                  value: plugin.enabled,
                  onChanged: readOnly ? null : onChanged,
                ),
                if (hasMenu)
                  PopupMenuButton<String>(
                    tooltip: strings.commonMoreOptions,
                    onSelected: (action) {
                      if (action == 'update') onUpdate();
                      if (action == 'remove') onRemove();
                    },
                    itemBuilder: (_) => [
                      if (control?.canUpdate == true)
                        PopupMenuItem(
                          value: 'update',
                          child: Text(
                            strings.extensionsCenterPluginUpdateAction,
                          ),
                        ),
                      if (control?.canRemove == true)
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(
                            strings.extensionsCenterPluginRemoveAction,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}

class _ToolsetRow extends StatelessWidget {
  final DesktopToolsetEntry toolset;
  final bool readOnly;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _ToolsetRow({
    required this.toolset,
    required this.readOnly,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final detail = toolset.description.isEmpty
        ? strings.extensionsCenterToolCount(toolset.toolCount)
        : strings.extensionsCenterToolCountWithDescription(
            toolset.toolCount,
            _safeRemoteText(toolset.description, strings),
          );
    return HermesListRow(
      icon: Icons.handyman_outlined,
      title: _safeRemoteText(toolset.name, strings),
      subtitle: detail,
      trailing: busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Switch(
              key: ValueKey('toolset-toggle-${toolset.name}'),
              value: toolset.enabled,
              onChanged: readOnly ? null : onChanged,
            ),
    );
  }
}

class _McpServerRow extends StatelessWidget {
  final DesktopMcpServerEntry server;
  final bool readOnly;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onTest;
  final VoidCallback onAuthorize;
  final bool canAuthorize;
  final VoidCallback onRemove;

  const _McpServerRow({
    required this.server,
    required this.readOnly,
    required this.busy,
    required this.onChanged,
    required this.onTest,
    required this.onAuthorize,
    required this.canAuthorize,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final detail = [
      if (server.transport.isNotEmpty)
        _safeRemoteText(server.transport, strings),
      if (server.endpointLabel.isNotEmpty)
        _safeRemoteText(server.endpointLabel, strings),
      if (server.toolCount != null)
        strings.extensionsCenterMcpToolCount(server.toolCount!),
    ].join(' · ');
    return HermesListRow(
      icon: Icons.hub_outlined,
      title: _safeRemoteText(server.name, strings),
      subtitle: detail,
      trailing: busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  key: ValueKey('mcp-toggle-${server.name}'),
                  value: server.enabled,
                  onChanged: readOnly ? null : onChanged,
                ),
                PopupMenuButton<String>(
                  tooltip: strings.commonMoreOptions,
                  onSelected: (action) {
                    if (action == 'test') onTest();
                    if (action == 'authorize') onAuthorize();
                    if (action == 'remove') onRemove();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'test',
                      child: Text(strings.extensionsCenterMcpTestAction),
                    ),
                    if (canAuthorize && !readOnly)
                      PopupMenuItem(
                        value: 'authorize',
                        child: Text(
                          AdminIntegrationsCopy.of(context).authorize,
                        ),
                      ),
                    if (!readOnly)
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(strings.extensionsCenterMcpRemoveAction),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _PluginInstallDraft {
  final String identifier;
  final bool enableAfterInstall;

  const _PluginInstallDraft({
    required this.identifier,
    required this.enableAfterInstall,
  });
}

class _PluginInstallSheet extends StatefulWidget {
  const _PluginInstallSheet();

  @override
  State<_PluginInstallSheet> createState() => _PluginInstallSheetState();
}

class _PluginInstallSheetState extends State<_PluginInstallSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _enable = true;
  bool _showError = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final identifier = _controller.text.trim();
    if (!isSafePluginInstallIdentifier(identifier)) {
      setState(() => _showError = true);
      return;
    }
    Navigator.pop(
      context,
      _PluginInstallDraft(identifier: identifier, enableAfterInstall: _enable),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            strings.extensionsCenterPluginInstallTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            strings.extensionsCenterPluginInstallRisk,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 18),
          TextField(
            key: const ValueKey('extensions-plugin-identifier'),
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_showError) setState(() => _showError = false);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: strings.extensionsCenterPluginIdentifierLabel,
              hintText: strings.extensionsCenterPluginIdentifierHint,
              errorText: _showError
                  ? strings.extensionsCenterPluginIdentifierInvalid
                  : null,
            ),
          ),
          const SizedBox(height: 10),
          HermesSwitchTile(
            contentPadding: EdgeInsets.zero,
            title: strings.extensionsCenterPluginEnableAfterInstall,
            value: _enable,
            onChanged: (value) => setState(() => _enable = value),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.arrow_forward_rounded, size: 19),
            label: Text(strings.extensionsCenterPluginReviewAction),
          ),
        ],
      ),
    );
  }
}

class _McpCatalogSheet extends StatefulWidget {
  final List<DesktopMcpCatalogEntry> entries;

  const _McpCatalogSheet({required this.entries});

  @override
  State<_McpCatalogSheet> createState() => _McpCatalogSheetState();
}

class _McpCatalogSheetState extends State<_McpCatalogSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final query = _query.trim().toLowerCase();
    final entries = widget.entries
        .where((entry) {
          if (query.isEmpty) return true;
          return [
            entry.name,
            entry.description,
            entry.source,
          ].any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  strings.extensionsCenterMcpCatalogTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: strings.commonClose,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: HermesSearchField(
            hintText: strings.extensionsCenterMcpCatalogSearchHint,
            clearTooltip: strings.extensionsCenterClearSearch,
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? HermesEmptyState(
                  compact: true,
                  icon: Icons.search_off_rounded,
                  title: strings.extensionsCenterNoMatches,
                  body: strings.extensionsCenterNoMatchesBody,
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    HermesListSection(
                      children: [
                        for (final entry in entries)
                          HermesListRow(
                            icon: entry.transport == 'http'
                                ? Icons.language_rounded
                                : Icons.terminal_rounded,
                            title: _safeRemoteText(entry.name, strings),
                            subtitle: _safeRemoteText(
                              entry.description,
                              strings,
                            ),
                            enabled: !entry.installed,
                            onTap: entry.installed
                                ? null
                                : () => Navigator.pop(context, entry),
                            trailing: entry.installed
                                ? Text(
                                    strings.extensionsCenterMcpInstalledBadge,
                                  )
                                : const Icon(Icons.chevron_right_rounded),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _McpInstallReviewSheet extends StatefulWidget {
  final DesktopMcpCatalogEntry entry;

  const _McpInstallReviewSheet({required this.entry});

  @override
  State<_McpInstallReviewSheet> createState() => _McpInstallReviewSheetState();
}

class _McpInstallReviewSheetState extends State<_McpInstallReviewSheet> {
  final Map<String, TextEditingController> _controllers = {};
  final Set<String> _missing = {};

  @override
  void initState() {
    super.initState();
    for (final requirement in widget.entry.requiredEnv) {
      _controllers[requirement.name] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.clear();
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  void _submit() {
    final missing = <String>{};
    final environment = <String, String>{};
    for (final requirement in widget.entry.requiredEnv) {
      final value = _controllers[requirement.name]?.text ?? '';
      if (requirement.required && value.isEmpty) {
        missing.add(requirement.name);
      }
      if (value.isNotEmpty) environment[requirement.name] = value;
    }
    if (missing.isNotEmpty) {
      setState(() {
        _missing
          ..clear()
          ..addAll(missing);
      });
      return;
    }
    Navigator.pop(context, environment);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final endpoint = entry.url.isNotEmpty
        ? entry.url
        : [
            entry.command,
            ...entry.args,
          ].where((part) => part.isNotEmpty).join(' ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  strings.extensionsCenterMcpInstallTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 5),
                Text(
                  _safeRemoteText(entry.name, strings),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (entry.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _safeRemoteText(entry.description, strings),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _ReviewValue(
                  label: strings.extensionsCenterMcpSourceLabel,
                  value: entry.source,
                ),
                _ReviewValue(
                  label: strings.extensionsCenterMcpTransportLabel,
                  value: entry.transport,
                ),
                if (endpoint.isNotEmpty)
                  _ReviewValue(
                    label: strings.extensionsCenterMcpEndpointLabel,
                    value: endpoint,
                  ),
                if (entry.bootstrap.isNotEmpty)
                  _ReviewValue(
                    label: strings.extensionsCenterMcpBootstrapLabel,
                    value: entry.bootstrap.join(' · '),
                  ),
                if (entry.requiredEnv.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    strings.extensionsCenterMcpCredentialsTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    strings.extensionsCenterMcpCredentialsBody,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final requirement in entry.requiredEnv) ...[
                    TextField(
                      key: ValueKey('mcp-env-${requirement.name}'),
                      controller: _controllers[requirement.name],
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) {
                        if (_missing.remove(requirement.name)) setState(() {});
                      },
                      decoration: InputDecoration(
                        labelText: requirement.prompt.isEmpty
                            ? requirement.name
                            : _safeRemoteText(requirement.prompt, strings),
                        helperText: requirement.name,
                        errorText: _missing.contains(requirement.name)
                            ? strings.extensionsCenterMcpRequiredValue
                            : null,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
                const SizedBox(height: 10),
                Text(
                  strings.extensionsCenterMcpInstallRisk,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.warning),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.download_rounded, size: 19),
              label: Text(strings.extensionsCenterMcpInstallAction),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReviewValue extends StatelessWidget {
  final String label;
  final String value;

  const _ReviewValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 94,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              _safeRemoteText(value, strings),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textPrimary,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExtensionsNotice extends StatelessWidget {
  final String text;

  const _ExtensionsNotice({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.075),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.lock_outline_rounded, color: colors.warning, size: 19),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManagementNotice extends StatelessWidget {
  final String text;

  const _ManagementNotice({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: colors.textSecondary,
            size: 18,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExtensionsFailure extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ExtensionsFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => HermesEmptyState(
    icon: Icons.extension_off_outlined,
    title: Strings.of(context).extensionsCenterFailureTitle,
    body: message,
    primaryLabel: Strings.of(context).commonRetry,
    primaryIcon: Icons.refresh_rounded,
    onPrimary: onRetry,
  );
}

String _managementNoticeText(Object? failure, Strings strings) {
  if (failure == null) {
    return strings.extensionsCenterManagementUnsupported;
  }
  if (failure is DesktopControlFailure &&
      failure.kind == DesktopControlFailureKind.unsupported) {
    return strings.extensionsCenterManagementUnsupported;
  }
  if (failure is DesktopControlFailure &&
      failure.kind == DesktopControlFailureKind.forbidden) {
    return strings.extensionsCenterManagementForbidden;
  }
  return strings.extensionsCenterManagementUnavailable;
}

String _extensionsFailureText(Object failure, Strings strings) {
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported =>
        strings.extensionsCenterFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        strings.extensionsCenterFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        strings.extensionsCenterFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        strings.extensionsCenterFailureUnavailable,
      DesktopControlFailureKind.rejected =>
        strings.extensionsCenterFailureRejected,
    };
  }
  return strings.extensionsCenterFailureUnknown;
}

String _extensionsMutationFailureText(Object failure, Strings strings) {
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported =>
        strings.extensionsCenterMutationFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        strings.extensionsCenterMutationFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        strings.extensionsCenterMutationFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        strings.extensionsCenterMutationFailureUnavailable,
      DesktopControlFailureKind.rejected =>
        strings.extensionsCenterMutationFailureRejected,
    };
  }
  return strings.extensionsCenterMutationFailureUnknown;
}

String _safeRemoteText(String value, Strings strings) {
  var result = value;
  final unixHostPath = RegExp(
    r'(^|[\s(\[])/(?:home|private|users|root|srv|var|etc|opt|mnt|tmp|data|run)(?:/[^\s)\],;]+)+',
    caseSensitive: false,
    multiLine: true,
  );
  result = result.replaceAllMapped(
    unixHostPath,
    (match) =>
        '${match.group(1) ?? ''}${strings.desktopCenterServerPathRedacted}',
  );
  final windowsHostPath = RegExp(
    r'(^|[\s(\[])[a-z]:\\(?:[^\s)\],;]+\\)*[^\s)\],;]+',
    caseSensitive: false,
    multiLine: true,
  );
  result = result.replaceAllMapped(
    windowsHostPath,
    (match) =>
        '${match.group(1) ?? ''}${strings.desktopCenterServerPathRedacted}',
  );
  result = result.replaceAll(
    RegExp(
      r'\b(?:sk|ghp|glpat|xoxb|xoxp|xoxa|xoxr)[-_][a-z0-9_-]{6,}\b',
      caseSensitive: false,
    ),
    strings.desktopCenterSecretRedacted,
  );
  return result;
}
