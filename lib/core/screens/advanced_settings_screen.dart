import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../capabilities/capabilities_adapters.dart';
import '../capabilities/capabilities_repository.dart';
import '../capabilities/server_diagnostics_models.dart';
import '../capabilities/server_diagnostics_probe.dart';
import '../design/page.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import 'server_diagnostics_screen.dart';

/// Settings › Advanced: server settings kept out of the main Settings list.
///
/// For now it holds the read-only Diagnostics entry. It reads three cheap
/// routes when it opens to decide whether Diagnostics exists on this server;
/// nothing is read when Settings opens and nothing is launched.
class AdvancedSettingsScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;

  /// Repository for a profile; the default talks to the Dashboard.
  @visibleForTesting
  final CapabilitiesRepository Function(String profile)? repositoryFor;

  /// Reader of the live MCP state, handed to Diagnostics.
  @visibleForTesting
  final Future<List<McpServerStatus>?> Function(CapabilitiesRepository repo)?
  mcpReader;

  const AdvancedSettingsScreen({
    super.key,
    required this.connection,
    required this.connManager,
    this.repositoryFor,
    this.mcpReader,
  });

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  DashboardClient? _client;
  late final ActiveProfileScope _scope = ActiveProfileScope.of(
    widget.connManager,
    widget.connection.id,
  );
  DiagnosticsAvailability? _availability;
  bool _probing = true;

  CapabilitiesRepository _repoFor(String profile) {
    final custom = widget.repositoryFor;
    if (custom != null) return custom(profile);
    final client = _client ??= DashboardClient.lazy(widget.connection);
    return CapabilitiesRepository(
      rest: DashboardCapabilitiesRest(
        client,
        readOnly: widget.connection.readOnly,
      ),
      profile: profile,
    );
  }

  @override
  void initState() {
    super.initState();
    _scope.addListener(_probe);
    _probe();
  }

  @override
  void dispose() {
    _scope.removeListener(_probe);
    _client?.close();
    super.dispose();
  }

  Future<void> _probe() async {
    final ticket = _scope.capture();
    setState(() {
      _probing = true;
      _availability = null;
    });
    final result = await probeDiagnostics(_repoFor(ticket.name));
    // A late answer of another profile is not this screen's.
    if (!mounted || !ticket.isCurrent) return;
    setState(() {
      _availability = result;
      _probing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final availability = _availability;
    return HermesPage(
      title: s.sd1215Advanced,
      children: [
        if (_probing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: TuiLoader()),
          )
        else if (availability != null && availability.any)
          HermesGroup(
            children: [
              HermesNavRow(
                icon: Icons.monitor_heart_outlined,
                title: s.sd1215Diagnostics,
                subtitle: s.sd1215DiagnosticsSub,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ServerDiagnosticsScreen(
                      connection: widget.connection,
                      connManager: widget.connManager,
                      availability: availability,
                      repositoryFor: widget.repositoryFor,
                      mcpReader: widget.mcpReader,
                    ),
                  ),
                ),
              ),
            ],
          )
        else
          HermesInfoBanner(s.sd1215NothingToShow),
      ],
    );
  }
}
