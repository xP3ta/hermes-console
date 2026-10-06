import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../services/credential_pool_api.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/console_loader.dart';

class CredentialPoolScreen extends StatefulWidget {
  final SavedConnection connection;
  final String profile;
  final DashboardClient? clientForTesting;

  const CredentialPoolScreen({
    required this.connection,
    required this.profile,
    this.clientForTesting,
    super.key,
  });

  @override
  State<CredentialPoolScreen> createState() => _CredentialPoolScreenState();
}

class _CredentialPoolScreenState extends State<CredentialPoolScreen> {
  late final DashboardClient _client;
  late final bool _ownsClient;
  CredentialPool? _pool;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.clientForTesting == null;
    _client =
        widget.clientForTesting ?? DashboardClient.lazy(widget.connection);
    _load();
  }

  Future<void> _load() async {
    try {
      final pool = await _client.getCredentialPool(profile: widget.profile);
      if (mounted) setState(() => _pool = pool ?? const CredentialPool([]));
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final pool = _pool;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.mdlCredentialPoolTitle)),
      body: _error != null
          ? HermesEmptyState(
              icon: Icons.error_outline,
              title: s.commonErrorTitle,
              body: s.mdlCredentialPoolLoadError,
            )
          : pool == null
          ? const Center(child: ConsoleLoader.large())
          : pool.providers.isEmpty
          ? HermesEmptyState(
              icon: Icons.key_off_outlined,
              title: s.mdlCredentialPoolEmptyTitle,
              body: s.mdlCredentialPoolEmptyBody,
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (final provider in pool.providers)
                  HermesListSection(
                    title: provider.provider,
                    children: [
                      for (final entry in provider.entries)
                        HermesListRow(
                          key: ValueKey(
                            'credential-${provider.provider}-${entry.index}',
                          ),
                          icon: Icons.key_outlined,
                          title: entry.label.trim().isEmpty
                              ? s.mdlCredentialPoolKeyNumber(entry.index)
                              : entry.label,
                          subtitle: s.mdlCredentialPoolEntryDetails(
                            entry.authType,
                            entry.source,
                            entry.lastStatus,
                            entry.requestCount,
                            entry.priority,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}
