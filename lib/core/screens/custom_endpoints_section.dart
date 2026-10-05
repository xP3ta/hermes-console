// Custom endpoints section of the Models screen.
//
// Mirrors Desktop's Settings → Providers → custom endpoints tab
// (apps/desktop/src/app/settings/custom-endpoints-settings.tsx): the saved
// OpenAI-compatible endpoints of the active profile, each with activate and
// delete, plus "Add endpoint". Adding or editing opens
// [ExternalProviderScreen], which is only the form.

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../l10n/app_localizations.dart';
import '../design/modal.dart'
    show
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        showHermesDialog,
        showHermesMenu;
import '../services/connection_manager.dart';
import '../services/custom_endpoints_api.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesListRow, HermesListSection;
import 'external_provider_screen.dart';

enum _SavedEndpointAction { activate, delete }

class CustomEndpointsSection extends StatefulWidget {
  const CustomEndpointsSection({
    required this.connection,
    required this.dashboard,
    this.profile = '',
    this.onChanged,
    this.reloadToken,
    this.probeClientForTesting,
    super.key,
  });

  final SavedConnection connection;

  /// Owned by the caller; this section never closes it.
  final DashboardClient dashboard;
  final String profile;

  /// Called after an endpoint was saved, activated or deleted, so the caller
  /// can reload the active model and the provider list.
  final VoidCallback? onChanged;

  /// A new value reloads the saved endpoints (pull to refresh).
  final Object? reloadToken;

  @visibleForTesting
  final http.Client? probeClientForTesting;

  @override
  State<CustomEndpointsSection> createState() => CustomEndpointsSectionState();
}

@visibleForTesting
class CustomEndpointsSectionState extends State<CustomEndpointsSection> {
  bool? _supported;
  List<CustomEndpoint> _endpoints = const [];
  bool _busy = false;
  final Map<String, GlobalKey> _menuAnchors = {};

  bool get _isLocal => widget.connection.kind == InstanceKind.localhost;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CustomEndpointsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile ||
        oldWidget.reloadToken != widget.reloadToken ||
        oldWidget.connection.id != widget.connection.id) {
      _load();
    }
  }

  Future<void> _load() async {
    final profile = widget.profile;
    try {
      final catalog = await widget.dashboard.listCustomEndpoints(
        profile: profile,
      );
      if (!mounted || profile != widget.profile) return;
      setState(() {
        _supported = catalog != null;
        _endpoints = catalog?.endpoints ?? const [];
        _pruneMenuAnchors();
      });
    } catch (_) {
      if (!mounted || profile != widget.profile) return;
      setState(() {
        _supported = false;
        _endpoints = const [];
        _pruneMenuAnchors();
      });
    }
  }

  /// Drops the menu anchor keys of endpoints that are no longer listed, so a
  /// long session of deletes and refreshes does not accumulate dead keys.
  void _pruneMenuAnchors() {
    final ids = {
      if (_supported == true)
        for (final endpoint in _endpoints) endpoint.id,
    };
    _menuAnchors.removeWhere((id, _) => !ids.contains(id));
  }

  @visibleForTesting
  Set<String> get debugMenuAnchorIds => {..._menuAnchors.keys};

  Future<void> _afterChange() async {
    await _load();
    widget.onChanged?.call();
  }

  void _showError(Object error) {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(humanizeExternalProviderError(error))),
      kind: HermesNoticeKind.error,
    );
  }

  Future<void> _openForm({CustomEndpoint? endpoint}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ExternalProviderScreen(
          connection: widget.connection,
          profile: widget.profile,
          dashboard: widget.dashboard,
          endpoint: endpoint,
          isEditing: endpoint != null,
          probeClientForTesting: widget.probeClientForTesting,
        ),
      ),
    );
    if (changed == true && mounted) await _afterChange();
  }

  Future<void> _activate(CustomEndpoint endpoint) async {
    setState(() => _busy = true);
    try {
      await widget.dashboard.activateCustomEndpoint(
        endpoint.id,
        profile: widget.profile,
      );
      if (mounted) await _afterChange();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(CustomEndpoint endpoint) async {
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.mdlEndpointDeleteTitle(endpoint.name),
      message: s.mdlEndpointDeleteBody,
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.mdlEndpointDelete,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.dashboard.deleteCustomEndpoint(
        endpoint.id,
        profile: widget.profile,
      );
      if (mounted) await _afterChange();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMenu(CustomEndpoint endpoint, GlobalKey anchor) async {
    final s = Strings.of(context);
    final action = await showHermesMenu<_SavedEndpointAction>(
      context: context,
      anchorKey: anchor,
      actions: [
        if (!endpoint.isCurrent)
          HermesAction(
            value: _SavedEndpointAction.activate,
            label: s.mdlEndpointActivate,
          ),
        if (endpoint.source != 'direct-config')
          HermesAction(
            value: _SavedEndpointAction.delete,
            label: s.mdlEndpointDelete,
            destructive: true,
          ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _SavedEndpointAction.activate:
        await _activate(endpoint);
      case _SavedEndpointAction.delete:
        await _delete(endpoint);
      case null:
        break;
    }
  }

  Widget _endpointRow(CustomEndpoint endpoint) {
    final s = Strings.of(context);
    final hasActions =
        !endpoint.isCurrent || endpoint.source != 'direct-config';
    return HermesListRow(
      key: ValueKey('saved-endpoint-${endpoint.id}'),
      icon: Icons.dns_outlined,
      title: endpoint.name,
      selected: endpoint.isCurrent,
      subtitle: [
        Uri.tryParse(endpoint.baseUrl)?.host ?? endpoint.baseUrl,
        endpoint.model,
        if (endpoint.hasApiKey) s.mdlEndpointKeySet,
        if (endpoint.isCurrent) s.mdlEndpointCurrent,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      onTap: _busy ? null : () => _openForm(endpoint: endpoint),
      trailing: hasActions
          ? Builder(
              builder: (context) {
                final anchor = _menuAnchors.putIfAbsent(
                  endpoint.id,
                  GlobalKey.new,
                );
                return IconButton(
                  tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                  icon: Icon(Icons.more_vert, key: anchor),
                  onPressed: _busy ? null : () => _openMenu(endpoint, anchor),
                );
              },
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Column(
      key: const ValueKey('models-custom-endpoints'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesListSection(
          title: s.mdlCustomEndpoints,
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          children: [
            if (_supported == true)
              for (final endpoint in _endpoints) _endpointRow(endpoint),
            HermesListRow(
              key: const ValueKey('custom-endpoint-add'),
              icon: Icons.add_link_rounded,
              title: s.mdlAddEndpoint,
              subtitle: s.mdlAddEndpointSubtitle,
              onTap: _busy ? null : () => _openForm(),
            ),
          ],
        ),
        if (!_isLocal)
          Padding(
            key: const ValueKey('custom-endpoints-server-hint'),
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              s.mdlCustomEndpointsServerHint,
              style: TextStyle(fontSize: 11, color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}
