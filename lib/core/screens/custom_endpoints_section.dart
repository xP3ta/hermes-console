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
import '../services/active_profile_scope.dart';
import '../widgets/read_only.dart';
import '../services/custom_endpoints_api.dart';
import '../widgets/provider_logo.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesListRow, HermesListSection;
import 'external_provider_screen.dart';
import '../feedback/feedback_policy.dart';

enum _SavedEndpointAction { activate, delete }

class CustomEndpointsSection extends StatefulWidget {
  const CustomEndpointsSection({
    required this.connection,
    required this.dashboard,
    this.profile = '',
    this.profileScope,
    this.requireSupported = false,
    this.onChanged,
    this.reloadToken,
    this.seed,
    this.onLoaded,
    this.inUse,
    this.probeClientForTesting,
    super.key,
  });

  /// Whether the profile runs on [endpoint] (its main model, a fallback or
  /// an auxiliary task). One in use is not deleted: the user is told to
  /// choose another model first.
  final bool Function(CustomEndpoint endpoint)? inUse;

  /// The last list the server returned for this profile, shown until this
  /// read answers so a reopen does not start empty. Display only: nothing
  /// can be done to a seeded row before the server has answered.
  final List<CustomEndpoint>? seed;

  /// The list the server just returned, for the caller to keep.
  final ValueChanged<List<CustomEndpoint>>? onLoaded;

  final SavedConnection connection;

  /// Owned by the caller; this section never closes it.
  final DashboardClient dashboard;
  final String profile;
  final ActiveProfileScope? profileScope;

  /// Degraded inventory cannot imply support or config authorization.
  final bool requireSupported;

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
  bool _loadFailed = false;
  int _loadGeneration = 0;
  int _authorityGeneration = 0;
  List<CustomEndpoint> _endpoints = const [];
  bool _busy = false;
  final Map<String, GlobalKey> _menuAnchors = {};

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
        !identical(oldWidget.connection, widget.connection) ||
        !identical(oldWidget.dashboard, widget.dashboard) ||
        oldWidget.profileScope != widget.profileScope ||
        oldWidget.requireSupported != widget.requireSupported) {
      _load();
    }
  }

  Future<void> _load({bool retireActions = true}) async {
    if (retireActions) _authorityGeneration++;
    final connection = widget.connection;
    final dashboard = widget.dashboard;
    final profile = widget.profile;
    final generation = ++_loadGeneration;
    final ticket = widget.profileScope?.capture();
    bool current() =>
        mounted &&
        identical(connection, widget.connection) &&
        identical(dashboard, widget.dashboard) &&
        profile == widget.profile &&
        generation == _loadGeneration &&
        (ticket?.isCurrent ?? true);
    setState(() {
      _supported = null;
      _loadFailed = false;
      _endpoints = widget.seed ?? const [];
      _pruneMenuAnchors();
    });
    try {
      final catalog = await dashboard.listCustomEndpoints(profile: profile);
      if (!current()) return;
      setState(() {
        _supported = catalog != null;
        _endpoints = catalog?.endpoints ?? const [];
        _pruneMenuAnchors();
      });
      if (catalog != null) widget.onLoaded?.call(catalog.endpoints);
    } catch (_) {
      if (!current()) return;
      setState(() {
        _supported = false;
        _loadFailed = true;
        _endpoints = const [];
        _pruneMenuAnchors();
      });
    }
  }

  /// Drops the menu anchor keys of endpoints that are no longer listed, so a
  /// long session of deletes and refreshes does not accumulate dead keys.
  void _pruneMenuAnchors() {
    final ids = {
      if (_supported != false)
        for (final endpoint in _endpoints) endpoint.id,
    };
    _menuAnchors.removeWhere((id, _) => !ids.contains(id));
  }

  @visibleForTesting
  Set<String> get debugMenuAnchorIds => {..._menuAnchors.keys};

  ({
    SavedConnection connection,
    DashboardClient dashboard,
    String profile,
    bool Function() isCurrent,
  })
  _actionLease() {
    final connection = widget.connection;
    final dashboard = widget.dashboard;
    final profile = widget.profile;
    final scope = widget.profileScope;
    final ticket = scope?.capture();
    final generation = _authorityGeneration;
    final admitted =
        !connection.readOnly &&
        !_loadFailed &&
        _supported != null &&
        (!widget.requireSupported || _supported == true);
    bool current() =>
        mounted &&
        admitted &&
        !widget.connection.readOnly &&
        identical(connection, widget.connection) &&
        identical(dashboard, widget.dashboard) &&
        profile == widget.profile &&
        scope == widget.profileScope &&
        generation == _authorityGeneration &&
        (ticket?.isCurrent ?? true) &&
        (ticket == null || ticket.owner == Session.profileOwner(profile));
    return (
      connection: connection,
      dashboard: dashboard,
      profile: profile,
      isCurrent: current,
    );
  }

  Future<void> _afterChange(bool Function() current) async {
    if (!current()) return;
    await _load(retireActions: false);
    if (current()) widget.onChanged?.call();
  }

  void _showError(Object error) {
    if (!mounted) return;
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.error, humanizeExternalProviderError(error));
  }

  Future<void> _openForm({
    CustomEndpoint? endpoint,
    required ({
      SavedConnection connection,
      DashboardClient dashboard,
      String profile,
      bool Function() isCurrent,
    })
    lease,
  }) async {
    if (!lease.isCurrent()) {
      if (mounted && widget.connection.readOnly) showReadOnlyNotice(context);
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ExternalProviderScreen(
          connection: lease.connection,
          profile: lease.profile,
          profileScope: widget.profileScope,
          dashboard: lease.dashboard,
          actionAuthority: lease.isCurrent,
          endpoint: endpoint,
          isEditing: endpoint != null,
          probeClientForTesting: widget.probeClientForTesting,
        ),
      ),
    );
    if (changed == true && lease.isCurrent()) {
      await _afterChange(lease.isCurrent);
    }
  }

  Future<void> _activate(
    CustomEndpoint endpoint,
    ({
      SavedConnection connection,
      DashboardClient dashboard,
      String profile,
      bool Function() isCurrent,
    })
    lease,
  ) async {
    if (!lease.isCurrent() || _busy) {
      if (mounted && widget.connection.readOnly) showReadOnlyNotice(context);
      return;
    }
    setState(() => _busy = true);
    try {
      await DashboardClient.guardedWrite(
        lease.isCurrent,
        () => lease.dashboard.activateCustomEndpoint(
          endpoint.id,
          profile: lease.profile,
        ),
      );
      if (mounted && lease.isCurrent()) await _afterChange(lease.isCurrent);
    } catch (error) {
      if (lease.isCurrent()) _showError(error);
    } finally {
      // This write retains busy ownership across revocation; no successor can
      // start until its own completion releases the lease.
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(
    CustomEndpoint endpoint,
    ({
      SavedConnection connection,
      DashboardClient dashboard,
      String profile,
      bool Function() isCurrent,
    })
    lease,
  ) async {
    if (!lease.isCurrent() || _busy) {
      if (mounted && widget.connection.readOnly) showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    if (widget.inUse?.call(endpoint) ?? false) {
      AppFeedback.of(context).notify(
        FeedbackKind.error,
        s.mdlProviderInUse(endpoint.name),
        warning: true,
        noticeKey: const ValueKey('models-provider-in-use'),
      );
      return;
    }
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.mdlEndpointDeleteTitle(endpoint.name),
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
    if (confirmed != true || !lease.isCurrent() || _busy) return;
    setState(() => _busy = true);
    try {
      await DashboardClient.guardedWrite(
        lease.isCurrent,
        () => lease.dashboard.deleteCustomEndpoint(
          endpoint.id,
          profile: lease.profile,
        ),
      );
      if (mounted && lease.isCurrent()) await _afterChange(lease.isCurrent);
    } catch (error) {
      if (lease.isCurrent()) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMenu(
    CustomEndpoint endpoint,
    GlobalKey anchor,
    ({
      SavedConnection connection,
      DashboardClient dashboard,
      String profile,
      bool Function() isCurrent,
    })
    lease,
  ) async {
    // The lease is captured with the callback, before menu/dialog awaits.
    if (_busy) return;
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
    if (!lease.isCurrent() || _busy) return;
    switch (action) {
      case _SavedEndpointAction.activate:
        await _activate(endpoint, lease);
      case _SavedEndpointAction.delete:
        await _delete(endpoint, lease);
      case null:
        break;
    }
  }

  Widget _endpointRow(CustomEndpoint endpoint) {
    final lease = _actionLease();
    final s = Strings.of(context);
    final hasActions =
        !endpoint.isCurrent || endpoint.source != 'direct-config';
    return HermesListRow(
      key: ValueKey('saved-endpoint-${endpoint.id}'),
      leading: ProviderLogo(
        provider: endpoint.id,
        providerName: endpoint.name,
        size: 20,
        selected: endpoint.isCurrent,
      ),
      title: endpoint.name,
      selected: endpoint.isCurrent,
      subtitle: [
        Uri.tryParse(endpoint.baseUrl)?.host ?? endpoint.baseUrl,
        endpoint.model,
        if (endpoint.hasApiKey) s.mdlEndpointKeySet,
        if (endpoint.isCurrent) s.mdlEndpointCurrent,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      onTap: _busy ? null : () => _openForm(endpoint: endpoint, lease: lease),
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
                  onPressed: _busy
                      ? null
                      : () => _openMenu(endpoint, anchor, lease),
                );
              },
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final addLease = _actionLease();
    return Column(
      key: const ValueKey('models-custom-endpoints'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesListSection(
          title: s.mdlCustomEndpoints,
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          children: [
            // Seeded rows are shown until the server answers; a failed read
            // shows none.
            if (_supported != false)
              for (final endpoint in _endpoints) _endpointRow(endpoint),
            HermesListRow(
              key: const ValueKey('custom-endpoint-add'),
              icon: Icons.add_link_rounded,
              title: s.mdlAddEndpoint,
              subtitle: s.mdlAddEndpointSubtitle,
              enabled:
                  !_busy &&
                  !_loadFailed &&
                  _supported != null &&
                  (!widget.requireSupported || _supported == true),
              onTap:
                  _busy ||
                      _loadFailed ||
                      _supported == null ||
                      (widget.requireSupported && _supported != true)
                  ? null
                  : () => _openForm(lease: addLease),
            ),
          ],
        ),
      ],
    );
  }
}
