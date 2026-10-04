// Opens a catalog deep link: one read of the connected server's own catalog,
// then the regular catalog detail (disclosure + install confirmation). The
// link never installs by itself and never chooses a profile.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/connection.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart'
    show ConnectionManager, DashboardClient;
import '../services/tui_gateway_client.dart';
import '../widgets/hermes_notice.dart';
import 'capabilities_adapters.dart';
import 'capabilities_repository.dart';
import 'capability_detail_screen.dart';
import 'capability_models.dart';
import 'catalog_deep_link.dart';

/// Tells the user a catalog link was refused, once the app can show it. The
/// notice controller is resolved first and the inbox's flag is consumed only
/// when it exists, so a navigator still being built never swallows the report.
bool reportCatalogOverflow(
  CatalogDeepLinkInbox inbox, {
  required NavigatorState? navigator,
  required bool locked,
  required bool onboarding,
  required bool connected,
}) {
  final notices = HermesNotice.ofNavigator(navigator);
  if (navigator == null || notices == null) return false;
  if (!inbox.takeOverflow(
    locked: locked,
    onboarding: onboarding,
    connected: connected,
  )) {
    return false;
  }
  notices.show(
    message: Strings.of(navigator.context).cphLinkQueueFull,
    kind: HermesNoticeKind.warning,
  );
  return true;
}

/// Shows [action] on [navigator]. Notices (invalid / Git links) are only an
/// explanation: nothing is read or sent.
Future<void> openCatalogDeepLink({
  required NavigatorState navigator,
  required ConnectionManager connManager,
  required SavedConnection connection,
  required CatalogDeepLinkAction action,
}) async {
  final context = navigator.context;
  final notices = HermesNotice.ofNavigator(navigator);
  final s = Strings.of(context);
  if (action is CatalogLinkNotice) {
    notices?.show(
      message: action.kind == CatalogLinkNoticeKind.gitRepository
          ? s.cphLinkGit
          : s.cphLinkInvalid,
      kind: HermesNoticeKind.warning,
    );
    return;
  }
  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => CatalogDeepLinkScreen(
        connManager: connManager,
        connection: connection,
        action: action,
      ),
    ),
  );
}

class CatalogDeepLinkScreen extends StatefulWidget {
  final ConnectionManager connManager;
  final SavedConnection connection;
  final CatalogDeepLinkAction action;

  const CatalogDeepLinkScreen({
    super.key,
    required this.connManager,
    required this.connection,
    required this.action,
  });

  @override
  State<CatalogDeepLinkScreen> createState() => _CatalogDeepLinkScreenState();
}

class _CatalogDeepLinkScreenState extends State<CatalogDeepLinkScreen> {
  late final DashboardClient _dashboard = DashboardClient.lazy(
    widget.connection,
  );
  late final TuiGatewayClient _gateway = TuiGatewayClient(
    widget.connection,
    dashboard: _dashboard,
  );
  late final ActiveProfileScope _scope = ActiveProfileScope.of(
    widget.connManager,
    widget.connection.id,
  );
  late final ProfileReadTicket _ticket = _scope.capture();
  late final String _profile = widget.connManager.activeProfileFor(
    widget.connection.id,
  );
  late final CapabilitiesRepository _repository = CapabilitiesRepository(
    rest: DashboardCapabilitiesRest(
      _dashboard,
      readOnly: widget.connection.readOnly,
    ),
    rpc: gatewayCapabilitiesRpc(_gateway),
    profile: _profile,
  );
  late final CatalogDestination _destination = CatalogDestination(
    connectionId: widget.connection.id,
    profile: _profile,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void dispose() {
    unawaited(_gateway.close());
    _dashboard.close();
    super.dispose();
  }

  CatalogDestination _active() => CatalogDestination(
    connectionId: widget.connManager.activeConnectionId.value ?? '',
    profile: widget.connManager.activeProfileFor(widget.connection.id),
  );

  bool get _destinationStillValid =>
      _ticket.isCurrent && _destination.sameAs(_active());

  String get _label {
    final profile = _profile.trim().isEmpty ? 'default' : _profile.trim();
    return '${widget.connection.label} · $profile';
  }

  void _leave(
    String message, {
    HermesNoticeKind kind = HermesNoticeKind.warning,
  }) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final notices = HermesNotice.ofNavigator(navigator);
    navigator.pop();
    notices?.show(message: message, kind: kind);
  }

  void _show(CapabilityItem item) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => CapabilityDetailScreen(
          item: item,
          repository: _repository,
          readOnly: widget.connection.readOnly,
          instanceId: widget.connection.id,
          destinationLabel: _label,
          destinationStillValid: () => _destinationStillValid,
        ),
      ),
    );
  }

  Future<void> _resolve() async {
    final s = Strings.of(context);
    final action = widget.action;
    final CatalogLinkTarget target;
    switch (action) {
      case PluginCatalogInstallLink():
        target = await resolveCatalogLinkTarget(_repository, action);
      case SkillInstallLink():
        target = await resolveSkillLinkTarget(_repository, action);
      default:
        return _leave(s.cphLinkInvalid);
    }
    if (!mounted || !_ticket.isCurrent) return;
    switch (target) {
      case CatalogLinkShow(:final item):
        _show(item);
      case CatalogLinkLeave(:final reason, :final name):
        switch (reason) {
          case CatalogLinkLeaveReason.unknown:
            _leave(s.cphLinkUnknown(name));
          case CatalogLinkLeaveReason.alreadyInstalled:
            _leave(s.cphLinkAlready(name), kind: HermesNoticeKind.info);
          case CatalogLinkLeaveReason.unavailable:
            _leave(s.cphLinkUnavailable, kind: HermesNoticeKind.error);
        }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Semantics(
        label: Strings.of(context).cphTitle,
        child: const CircularProgressIndicator(),
      ),
    ),
  );
}
