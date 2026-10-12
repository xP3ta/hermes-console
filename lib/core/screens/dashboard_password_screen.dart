import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../services/connection_manager.dart';
import '../services/dashboard_login_capabilities.dart';
import '../theme/app_theme.dart';
import '../utils/transport_privacy.dart';
import '../widgets/dashboard_password_help.dart';
import '../widgets/hermes_ui.dart' show HermesField, HermesPrimaryButton;

/// Hermes has password login, but no authenticated password-change call
/// (dashboard_auth/routes.py offers login, logout, ws-ticket and native
/// exchange only). The password is replaced on the computer, with the setup
/// helper's line shown by [showDashboardPasswordHelp]; this screen then
/// verifies the new one with a fresh sign-in and saves it in the existing
/// atomic Keystore transaction.
class DashboardPasswordScreen extends StatefulWidget {
  const DashboardPasswordScreen({
    required this.connection,
    required this.connManager,
    required this.authorityCurrent,
    super.key,
  });
  final SavedConnection connection;
  final ConnectionManager connManager;
  final bool Function() authorityCurrent;

  @override
  State<DashboardPasswordScreen> createState() =>
      _DashboardPasswordScreenState();
}

class _DashboardPasswordScreenState extends State<DashboardPasswordScreen> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _consent = false;
  bool _loading = true;
  String Function(Strings)? _error;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    try {
      final secrets = await widget.connManager.getDashboardSecrets(
        widget.connection.id,
      );
      if (mounted) {
        setState(() {
          _user.text = secrets.username ?? '';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = (s) => s.sPasswordSaveFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _requiresConsent {
    final url = widget.connection.effectiveDashboardUrl;
    if (TransportPrivacy.classify(url) !=
        TransportPrivacyClass.privateCleartext) {
      return false;
    }
    final host = Uri.tryParse(url)?.host ?? '';
    return host != 'localhost' &&
        !(InternetAddress.tryParse(host)?.isLoopback ?? false);
  }

  bool get _valid =>
      mounted && widget.authorityCurrent() && !widget.connection.readOnly;

  Future<void> _verifyAndSave() async {
    if (_busy || !_valid || (_requiresConsent && !_consent)) return;
    final user = _user.text.trim();
    final password = _password.text;
    if (user.isEmpty || password.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    DashboardClient? client;
    var verified = false;
    try {
      TransportPrivacy.requireAllowed(widget.connection.effectiveDashboardUrl);
      client = DashboardClient.forConnection(
        widget.connection,
        secrets: DashboardSecrets(username: user, password: password),
      );
      await client.authenticateExistingPassword(fresh: true);
      if (!_valid) {
        if (mounted) {
          setState(() => _error = (s) => s.dashboardSetupAuthorityChanged);
        }
        return;
      }
      await client.apiGet('auth/me');
      if (!_valid) {
        if (mounted) {
          setState(() => _error = (s) => s.dashboardSetupAuthorityChanged);
        }
        return;
      }
      verified = true;
      await widget.connManager.setDashboardSecrets(
        widget.connection.id,
        username: user,
        password: password,
      );
      await widget.connManager.saveCapabilities(
        widget.connection.id,
        capabilitiesAfterDashboardLogin(
          widget.connManager.loadCapabilities(widget.connection.id),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = (s) =>
                  verified ? s.sPasswordSaveFailed : s.sPasswordRejected,
        );
      }
    } finally {
      client?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final blocked =
        TransportPrivacy.classify(widget.connection.effectiveDashboardUrl) ==
        TransportPrivacyClass.publicCleartext;
    return PopScope(
      canPop: !_busy,
      child: HermesPage(
        title: s.sPasswordTitle,
        children: [
          Text(
            s.sPasswordComputer,
            style: HermesType.text.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: HermesSpace.x4),
          HermesListGroup(
            children: [
              HermesListRow(
                key: const ValueKey('dashboard-password-how'),
                title: s.sPasswordHow,
                icon: Icons.terminal,
                onTap: () => showDashboardPasswordHelp(context),
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x6),
          HermesField(
            fieldKey: const ValueKey('dashboard-password-user'),
            controller: _user,
            label: s.commonUser,
            autocorrect: false,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: HermesSpace.x4),
          HermesField(
            fieldKey: const ValueKey('dashboard-password-new'),
            controller: _password,
            label: s.sPasswordNew,
            obscure: true,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            helperText: s.sPasswordStrength,
            onChanged: (_) => setState(() {}),
          ),
          if (_requiresConsent)
            CheckboxListTile(
              key: const ValueKey('dashboard-password-http-consent'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _consent,
              title: Text(s.dashboardSetupCredentialConsent),
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _consent = v == true),
            ),
          if (_error != null || blocked)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: HermesSpace.x4),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  blocked ? s.commonCleartextPublic : _error!(s),
                  key: const ValueKey('dashboard-password-error'),
                  style: HermesType.text.copyWith(color: colors.error),
                ),
              ),
            ),
          const SizedBox(height: HermesSpace.x6),
          HermesPrimaryButton(
            key: const ValueKey('dashboard-password-verify'),
            label: _busy ? s.commonLoading : s.sPasswordVerify,
            onTap:
                _busy ||
                    _loading ||
                    blocked ||
                    !_valid ||
                    _password.text.isEmpty ||
                    _user.text.trim().isEmpty ||
                    (_requiresConsent && !_consent)
                ? null
                : _verifyAndSave,
          ),
        ],
      ),
    );
  }
}
