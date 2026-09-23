import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../models/admin_integrations.dart';
import '../services/desktop_control_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/mcp_provisioning_surface.dart';
import '../widgets/webhook_admin_surfaces.dart';
import 'admin_integrations_copy.dart';
import 'lock_screen.dart';

enum AdminIntegrationsSection { mcp, webhooks, server }

class AdminIntegrationsScreen extends StatefulWidget {
  final HermesDesktopControlGateway gateway;
  final bool readOnly;
  final AdminIntegrationsSection initialSection;
  final McpExternalUriLauncher? oauthLauncher;
  final List<Duration>? oauthPollDelays;

  const AdminIntegrationsScreen({
    required this.gateway,
    this.readOnly = false,
    this.initialSection = AdminIntegrationsSection.mcp,
    this.oauthLauncher,
    this.oauthPollDelays,
    super.key,
  });

  @override
  State<AdminIntegrationsScreen> createState() =>
      _AdminIntegrationsScreenState();
}

class _AdminIntegrationsScreenState extends State<AdminIntegrationsScreen> {
  late AdminIntegrationsSection _section;
  WebhookSnapshot? _webhooks;
  Object? _webhooksFailure;
  bool _loadingWebhooks = false;
  A2aServerCapability? _a2a;
  Object? _a2aFailure;
  bool _loadingA2a = false;
  bool _a2aLoaded = false;
  bool _addingMcp = false;
  bool _enablingWebhooks = false;
  bool _creatingWebhook = false;
  final Set<String> _busyWebhooks = {};

  HermesMcpProvisioningGateway? get _mcpGateway =>
      widget.gateway is HermesMcpProvisioningGateway
      ? widget.gateway as HermesMcpProvisioningGateway
      : null;

  HermesWebhookManagementGateway? get _webhookGateway =>
      widget.gateway is HermesWebhookManagementGateway
      ? widget.gateway as HermesWebhookManagementGateway
      : null;

  HermesServerPlatformCapabilitiesGateway? get _platformGateway =>
      widget.gateway is HermesServerPlatformCapabilitiesGateway
      ? widget.gateway as HermesServerPlatformCapabilitiesGateway
      : null;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    unawaited(_loadCurrentSection());
  }

  @override
  void didUpdateWidget(covariant AdminIntegrationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway == widget.gateway) return;
    _webhooks = null;
    _webhooksFailure = null;
    _a2a = null;
    _a2aFailure = null;
    _a2aLoaded = false;
    unawaited(_loadCurrentSection(force: true));
  }

  Future<void> _loadCurrentSection({bool force = false}) => switch (_section) {
    AdminIntegrationsSection.mcp => Future<void>.value(),
    AdminIntegrationsSection.webhooks => _loadWebhooks(force: force),
    AdminIntegrationsSection.server => _loadA2a(force: force),
  };

  void _selectSection(AdminIntegrationsSection section) {
    if (_section == section) return;
    setState(() => _section = section);
    unawaited(_loadCurrentSection());
  }

  Future<bool> _verifyLock(String reason) async {
    if (!mounted || widget.readOnly) return false;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock == null) return true;
    return LockScreen.verify(context, lock, reason: reason);
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) async {
    final colors = Theme.of(context).hermes;
    final copy = AdminIntegrationsCopy.of(context);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(copy.cancel),
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

  void _showNotice(String message) {
    if (!mounted) return;
    HermesNotice.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showFailure(Object error) {
    _showNotice(_failureText(error, AdminIntegrationsCopy.of(context)));
  }

  Future<void> _addMcp() async {
    final gateway = _mcpGateway;
    if (gateway == null || widget.readOnly || _addingMcp) return;
    final draft = await showHermesFloatingSurface<McpServerDraft>(
      context: context,
      surfaceKey: const ValueKey('mcp-manual-create-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.9,
      builder: (_) => const McpServerDraftSurface(),
    );
    if (!mounted || draft == null) return;
    final copy = AdminIntegrationsCopy.of(context);
    if (!await _verifyLock(copy.addMcp) || !mounted) return;

    setState(() => _addingMcp = true);
    var created = false;
    try {
      await gateway.addMcpServer(draft);
      created = true;
      if (mounted) _showNotice(copy.mcpCreated);
    } catch (error) {
      if (mounted) _showFailure(error);
    }

    McpOAuthFlow? flow;
    if (created && draft.auth == McpAuthMode.oauth) {
      try {
        flow = await gateway.startMcpOAuth(draft.name);
      } catch (error) {
        if (mounted) _showFailure(error);
      }
    }
    if (mounted) setState(() => _addingMcp = false);
    if (!mounted || flow == null) return;
    await showMcpOAuthFlowSurface(
      context: context,
      gateway: gateway,
      initialFlow: flow,
      launcher: widget.oauthLauncher,
      pollDelays: widget.oauthPollDelays,
    );
  }

  Future<void> _loadWebhooks({bool force = false}) async {
    final gateway = _webhookGateway;
    if (gateway == null || _loadingWebhooks) return;
    if (!force && _webhooks != null && _webhooksFailure == null) return;
    setState(() {
      _loadingWebhooks = true;
      _webhooksFailure = null;
    });
    try {
      final snapshot = await gateway.webhookSnapshot();
      if (!mounted) return;
      setState(() => _webhooks = snapshot);
    } catch (error) {
      if (!mounted) return;
      setState(() => _webhooksFailure = error);
    } finally {
      if (mounted) setState(() => _loadingWebhooks = false);
    }
  }

  Future<void> _enableWebhooks() async {
    final gateway = _webhookGateway;
    if (gateway == null || widget.readOnly || _enablingWebhooks) return;
    final copy = AdminIntegrationsCopy.of(context);
    final approved = await _confirm(
      title: copy.enableWarningTitle,
      body: copy.enableWarningBody,
      action: copy.enable,
    );
    if (!approved || !await _verifyLock(copy.enableWarningTitle) || !mounted) {
      return;
    }
    setState(() => _enablingWebhooks = true);
    try {
      final result = await gateway.enableWebhooks();
      if (!mounted) return;
      _showNotice(
        result.restartStarted
            ? copy.webhooksEnabledRestarting
            : result.needsRestart
            ? copy.webhooksNeedRestart
            : copy.webhooksEnabled,
      );
      await _loadWebhooks(force: true);
    } catch (error) {
      if (mounted) _showFailure(error);
    } finally {
      if (mounted) setState(() => _enablingWebhooks = false);
    }
  }

  Future<void> _createWebhook() async {
    final gateway = _webhookGateway;
    if (gateway == null || widget.readOnly || _creatingWebhook) return;
    final draft = await showHermesFloatingSurface<WebhookDraft>(
      context: context,
      surfaceKey: const ValueKey('webhook-create-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.9,
      builder: (_) => const WebhookDraftSurface(),
    );
    if (!mounted || draft == null) return;
    final copy = AdminIntegrationsCopy.of(context);
    setState(() => _creatingWebhook = true);
    try {
      await _loadWebhooks(force: true);
      if (!mounted) return;
      if (_webhooksFailure case final failure?) {
        _showFailure(failure);
        return;
      }
      if (_webhooks?.routes.any((route) => route.name == draft.name) == true) {
        _showNotice(copy.duplicateWebhook);
        return;
      }
      if (!await _verifyLock(copy.addWebhook) || !mounted) return;

      WebhookCreateReceipt? receipt;
      try {
        receipt = await gateway.createWebhook(draft);
      } catch (error) {
        if (mounted) _showFailure(error);
      }
      if (!mounted || receipt == null) return;
      final oneShotReceipt = receipt;
      setState(() => _creatingWebhook = false);
      await showHermesFloatingSurface<void>(
        context: context,
        surfaceKey: const ValueKey('webhook-receipt-surface'),
        maxWidth: 560,
        barrierDismissible: false,
        builder: (_) => WebhookReceiptSurface(receipt: oneShotReceipt),
      );
      if (!mounted) return;
      _showNotice(copy.webhookCreated);
      await _loadWebhooks(force: true);
    } finally {
      if (mounted && _creatingWebhook) {
        setState(() => _creatingWebhook = false);
      }
    }
  }

  Future<void> _toggleWebhook(WebhookRoute route, bool enabled) async {
    final gateway = _webhookGateway;
    final actionId = 'toggle:${route.name}';
    if (gateway == null ||
        widget.readOnly ||
        _busyWebhooks.contains(actionId)) {
      return;
    }
    final copy = AdminIntegrationsCopy.of(context);
    if (!await _verifyLock(enabled ? copy.enable : copy.disable) || !mounted) {
      return;
    }
    setState(() => _busyWebhooks.add(actionId));
    try {
      await gateway.setWebhookEnabled(route.name, enabled);
      await _loadWebhooks(force: true);
    } catch (error) {
      if (mounted) _showFailure(error);
    } finally {
      if (mounted) setState(() => _busyWebhooks.remove(actionId));
    }
  }

  Future<void> _deleteWebhook(WebhookRoute route) async {
    final gateway = _webhookGateway;
    final actionId = 'delete:${route.name}';
    if (gateway == null ||
        widget.readOnly ||
        _busyWebhooks.contains(actionId)) {
      return;
    }
    final copy = AdminIntegrationsCopy.of(context);
    final approved = await _confirm(
      title: copy.deleteWebhookTitle,
      body: copy.deleteWebhookBody,
      action: copy.delete,
      destructive: true,
    );
    if (!approved || !await _verifyLock(copy.deleteWebhookTitle) || !mounted) {
      return;
    }
    setState(() => _busyWebhooks.add(actionId));
    try {
      await gateway.removeWebhook(route.name);
      if (mounted) _showNotice(copy.webhookDeleted);
      await _loadWebhooks(force: true);
    } catch (error) {
      if (mounted) _showFailure(error);
    } finally {
      if (mounted) setState(() => _busyWebhooks.remove(actionId));
    }
  }

  Future<void> _loadA2a({bool force = false}) async {
    final gateway = _platformGateway;
    if (gateway == null || _loadingA2a) return;
    if (!force && _a2aLoaded && _a2aFailure == null) return;
    setState(() {
      _loadingA2a = true;
      _a2aFailure = null;
    });
    try {
      final capability = await gateway.a2aServerCapability();
      if (!mounted) return;
      setState(() {
        _a2a = capability;
        _a2aLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _a2aFailure = error);
    } finally {
      if (mounted) setState(() => _loadingA2a = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AdminIntegrationsCopy.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Text(copy.screenTitle),
        actions: [
          IconButton(
            tooltip: copy.refresh,
            onPressed: () => _loadCurrentSection(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: HermesSegmentedControl<AdminIntegrationsSection>(
                value: _section,
                semanticLabel: copy.sectionLabel,
                onChanged: _selectSection,
                segments: [
                  HermesSegment(
                    key: const ValueKey('admin-integrations-mcp'),
                    value: AdminIntegrationsSection.mcp,
                    label: copy.mcpTab,
                  ),
                  HermesSegment(
                    key: const ValueKey('admin-integrations-webhooks'),
                    value: AdminIntegrationsSection.webhooks,
                    label: copy.webhooksTab,
                  ),
                  HermesSegment(
                    key: const ValueKey('admin-integrations-server'),
                    value: AdminIntegrationsSection.server,
                    label: copy.serverTab,
                  ),
                ],
              ),
            ),
            if (widget.readOnly)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: _InlineNotice(
                  icon: Icons.lock_outline_rounded,
                  text: copy.readOnly,
                ),
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 170),
                child: KeyedSubtree(
                  key: ValueKey(_section),
                  child: switch (_section) {
                    AdminIntegrationsSection.mcp => _buildMcp(copy),
                    AdminIntegrationsSection.webhooks => _buildWebhooks(copy),
                    AdminIntegrationsSection.server => _buildServer(copy),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMcp(AdminIntegrationsCopy copy) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
    children: [
      _IntroText(text: copy.mcpIntro),
      const SizedBox(height: 12),
      if (_mcpGateway == null)
        HermesEmptyState(
          compact: true,
          icon: Icons.link_off_rounded,
          title: copy.manualMcpUnavailable,
          body: copy.unsupported,
        )
      else
        HermesListSection(
          children: [
            HermesListRow(
              key: const ValueKey('admin-add-mcp'),
              icon: Icons.add_circle_outline_rounded,
              title: copy.addMcp,
              subtitle: copy.addMcpBody,
              enabled: !widget.readOnly && !_addingMcp,
              onTap: widget.readOnly || _addingMcp ? null : _addMcp,
              trailing: _addingMcp
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      const SizedBox(height: 12),
      _InlineNotice(icon: Icons.shield_outlined, text: copy.noMcpPut),
    ],
  );

  Widget _buildWebhooks(AdminIntegrationsCopy copy) {
    final gateway = _webhookGateway;
    if (gateway == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _IntroText(text: copy.webhooksIntro),
          HermesEmptyState(
            compact: true,
            icon: Icons.webhook_outlined,
            title: copy.webhooksUnavailable,
            body: copy.unsupported,
          ),
        ],
      );
    }
    if (_loadingWebhooks && _webhooks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final failure = _webhooksFailure;
    if (failure != null && _webhooks == null) {
      return HermesEmptyState(
        icon: Icons.webhook_outlined,
        title: copy.webhookLoadFailed,
        body: _failureText(failure, copy),
        primaryLabel: copy.retry,
        primaryIcon: Icons.refresh_rounded,
        onPrimary: () => _loadWebhooks(force: true),
      );
    }
    final snapshot = _webhooks;
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: () => _loadWebhooks(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _IntroText(text: copy.webhooksIntro),
          if (failure != null) ...[
            const SizedBox(height: 8),
            _InlineNotice(
              icon: Icons.warning_amber_rounded,
              text: _failureText(failure, copy),
            ),
          ],
          if (!snapshot.enabled) ...[
            HermesEmptyState(
              compact: true,
              icon: Icons.power_settings_new_rounded,
              title: copy.webhooksDisabled,
              body: copy.webhooksDisabledBody,
              primaryLabel: copy.enableWebhooks,
              primaryIcon: Icons.power_settings_new_rounded,
              onPrimary: widget.readOnly || _enablingWebhooks
                  ? null
                  : _enableWebhooks,
            ),
          ] else ...[
            if (snapshot.baseUri case final uri?) ...[
              const SizedBox(height: 8),
              _InlineNotice(
                icon: Icons.link_rounded,
                text: uri.toString(),
                monospace: true,
              ),
            ],
            HermesListSection(
              children: [
                HermesListRow(
                  key: const ValueKey('admin-add-webhook'),
                  icon: Icons.add_circle_outline_rounded,
                  title: copy.addWebhook,
                  subtitle: copy.addWebhookBody,
                  enabled: !widget.readOnly && !_creatingWebhook,
                  onTap: widget.readOnly || _creatingWebhook
                      ? null
                      : _createWebhook,
                  trailing: _creatingWebhook
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            if (snapshot.routes.isEmpty)
              HermesEmptyState(
                compact: true,
                icon: Icons.webhook_outlined,
                title: copy.noWebhooks,
                body: copy.addWebhookBody,
              )
            else
              HermesListSection(
                children: [
                  for (final route in snapshot.routes)
                    _WebhookRow(
                      route: route,
                      copy: copy,
                      readOnly: widget.readOnly,
                      busy: _busyWebhooks.any(
                        (action) => action.endsWith(':${route.name}'),
                      ),
                      onChanged: (enabled) => _toggleWebhook(route, enabled),
                      onDelete: () => _deleteWebhook(route),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildServer(AdminIntegrationsCopy copy) {
    final gateway = _platformGateway;
    if (gateway == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _IntroText(text: copy.a2aIntro),
          HermesEmptyState(
            compact: true,
            icon: Icons.hub_outlined,
            title: copy.a2aUnavailable,
            body: copy.unsupported,
          ),
        ],
      );
    }
    if (_loadingA2a && _a2a == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final failure = _a2aFailure;
    if (failure != null && _a2a == null) {
      return HermesEmptyState(
        icon: Icons.hub_outlined,
        title: copy.a2aUnavailable,
        body: _failureText(failure, copy),
        primaryLabel: copy.retry,
        primaryIcon: Icons.refresh_rounded,
        onPrimary: () => _loadA2a(force: true),
      );
    }
    final capability = _a2a;
    return RefreshIndicator(
      onRefresh: () => _loadA2a(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _IntroText(text: copy.a2aIntro),
          if (capability == null)
            HermesEmptyState(
              compact: true,
              icon: Icons.hub_outlined,
              title: copy.a2aNotPublished,
              body: copy.a2aIntro,
            )
          else
            HermesListSection(
              children: [
                Semantics(
                  key: const ValueKey('admin-a2a-capability'),
                  container: true,
                  excludeSemantics: true,
                  label: [
                    copy.a2aTitle,
                    capability.enabled ? copy.active : copy.inactive,
                    capability.configured
                        ? copy.configured
                        : copy.notConfigured,
                    capability.gatewayRunning ? copy.running : copy.stopped,
                    copy.a2aState(capability.state),
                  ].join(', '),
                  child: HermesListRow(
                    icon: Icons.device_hub_rounded,
                    title: copy.a2aTitle,
                    subtitle: [
                      capability.enabled ? copy.active : copy.inactive,
                      capability.configured
                          ? copy.configured
                          : copy.notConfigured,
                      capability.gatewayRunning ? copy.running : copy.stopped,
                      copy.a2aState(capability.state),
                    ].join(' · '),
                    trailing: Icon(
                      capability.gatewayRunning
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _WebhookRow extends StatelessWidget {
  final WebhookRoute route;
  final AdminIntegrationsCopy copy;
  final bool readOnly;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onDelete;

  const _WebhookRow({
    required this.route,
    required this.copy,
    required this.readOnly,
    required this.busy,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => HermesListRow(
    icon: Icons.webhook_outlined,
    title: route.name,
    subtitle: copy.webhookSubtitle(route.deliver, route.events),
    trailing: busy
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                key: ValueKey('webhook-toggle-${route.name}'),
                value: route.enabled,
                onChanged: readOnly ? null : onChanged,
              ),
              if (!readOnly)
                PopupMenuButton<String>(
                  tooltip: copy.moreOptions,
                  onSelected: (action) {
                    if (action == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'delete', child: Text(copy.delete)),
                  ],
                ),
            ],
          ),
  );
}

class _IntroText extends StatelessWidget {
  final String text;

  const _IntroText({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).hermes.textSecondary,
        height: 1.4,
      ),
    ),
  );
}

class _InlineNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool monospace;

  const _InlineNotice({
    required this.icon,
    required this.text,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.textSecondary, size: 19),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: monospace ? 3 : null,
                overflow: monospace ? TextOverflow.ellipsis : null,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                  fontFamily: monospace ? 'monospace' : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _failureText(Object error, AdminIntegrationsCopy copy) {
  if (error is DesktopControlFailure) {
    return switch (error.kind) {
      DesktopControlFailureKind.unsupported => copy.unsupported,
      DesktopControlFailureKind.forbidden => copy.forbidden,
      DesktopControlFailureKind.unavailable => copy.unavailable,
      DesktopControlFailureKind.invalidResponse => copy.invalidResponse,
      DesktopControlFailureKind.rejected => copy.rejected,
    };
  }
  return copy.unavailable;
}
