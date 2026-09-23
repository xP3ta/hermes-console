import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/bridge_client.dart';
import '../utils/api_error.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';

/// Resultado del alta de credenciales del Dashboard vía bridge.
class DashboardCredsResult {
  final String username;
  final String password;
  final String bridgeToken;
  const DashboardCredsResult(
    this.username,
    this.password, {
    required this.bridgeToken,
  });
}

/// Configura el login del Dashboard SIN SSH: usa primero el token guardado del
/// Bridge y, si falta o caducó, la API key del Gateway para provisionarlo. Lee
/// el usuario y FIJA una contraseña nueva en el servidor. Devuelve las
/// credenciales por `Navigator.pop` para que el editor las guarde y haga login
/// por cookie automáticamente.
class DashboardSetupScreen extends StatefulWidget {
  const DashboardSetupScreen({
    super.key,
    required this.bridgeUrl,
    required this.gatewayKey,
    this.bridgeToken = '',
  });

  /// URL del bridge y API key del Gateway usada solo como fallback de provisión.
  final String bridgeUrl;
  final String gatewayKey;

  /// Token ya guardado o recién leído del editor. Se prueba antes de llamar a
  /// /bridge/provision, para funcionar también cuando ese endpoint está
  /// deshabilitado tras el setup inicial.
  final String bridgeToken;

  @override
  State<DashboardSetupScreen> createState() => _DashboardSetupScreenState();
}

class _DashboardSetupScreenState extends State<DashboardSetupScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _pass2Ctrl = TextEditingController();

  bool _loading = true;
  bool _applying = false;
  String? _error;
  String? _bridgeToken;
  bool _passwordWasSet = false;
  bool _serverHadUsername = false;
  String _publicUrl = '';

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _pass2Ctrl.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var token = widget.bridgeToken.trim();
      if (token.isNotEmpty) {
        final existing = BridgeClient(baseUrl: widget.bridgeUrl, token: token);
        try {
          final caps = await existing.detect();
          if (!caps.online || !caps.authValid) token = '';
        } finally {
          existing.close();
        }
      }
      if (token.isEmpty && widget.gatewayKey.trim().isNotEmpty) {
        token =
            await BridgeClient.provision(
              widget.bridgeUrl,
              widget.gatewayKey.trim(),
            ) ??
            '';
      }
      if (token.isEmpty) {
        if (!mounted) return;
        throw Exception(Strings.of(context).dashProvisionFailed);
      }
      _bridgeToken = token;
      final client = BridgeClient(baseUrl: widget.bridgeUrl, token: token);
      try {
        final creds = await client.getDashboardCredentials();
        if (!mounted) return;
        setState(() {
          final existing = (creds['username'] ?? '').toString().trim();
          // Si el servidor ya tiene usuario, lo mostramos (no hay que adivinarlo).
          // Si no hay ninguno (Hermes recién montado), proponemos 'admin' editable.
          _userCtrl.text = existing.isNotEmpty ? existing : 'admin';
          _serverHadUsername = existing.isNotEmpty;
          _passwordWasSet = creds['password_set'] == true;
          _publicUrl = (creds['public_url'] ?? '').toString();
          _loading = false;
        });
      } finally {
        client.close();
      }
    } catch (e) {
      if (!mounted) return;
      final message = localizedApiError(Strings.of(context), e);
      setState(() {
        _error = message;
        _loading = false;
      });
    }
  }

  Future<void> _apply() async {
    final s = Strings.of(context);
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    if (pass.length < 4) {
      _snack(s.dashPwTooShort);
      return;
    }
    if (pass != _pass2Ctrl.text) {
      _snack(s.dashPwMismatch);
      return;
    }
    final token = _bridgeToken;
    if (token == null) return;
    setState(() => _applying = true);
    final client = BridgeClient(baseUrl: widget.bridgeUrl, token: token);
    try {
      final res = await client.setDashboardCredentials(
        username: user.isEmpty ? null : user,
        password: pass,
      );
      if (res['ok'] != true) {
        throw Exception(
          (res['error'] ?? res['message'] ?? s.dashSetFailed).toString(),
        );
      }
      final finalUser = (res['username'] ?? user).toString();
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(DashboardCredsResult(finalUser, pass, bridgeToken: token));
    } catch (e) {
      if (mounted) {
        _snack(s.commonError(localizedApiError(s, e)));
      }
    } finally {
      client.close();
      if (mounted) setState(() => _applying = false);
    }
  }

  void _snack(String m) {
    if (mounted) {
      HermesNotice.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Strings.of(context).dashAccessTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(error: _error!, onRetry: _probe)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(Strings.of(context).dashIntro),
                if (_publicUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Dashboard: $_publicUrl',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                HermesField(
                  controller: _userCtrl,
                  autocorrect: false,
                  label: Strings.of(context).commonUser,
                  helperText: _serverHadUsername
                      ? Strings.of(context).dashUserHelperDetected
                      : Strings.of(context).dashUserHelperNew,
                ),
                const SizedBox(height: 12),
                HermesField(
                  controller: _passCtrl,
                  obscure: true,
                  label: Strings.of(context).dashPwNew,
                  helperText: _passwordWasSet
                      ? Strings.of(context).dashPwHelperExists
                      : Strings.of(context).dashPwHelperNew,
                ),
                const SizedBox(height: 12),
                HermesField(
                  controller: _pass2Ctrl,
                  obscure: true,
                  label: Strings.of(context).dashPwRepeat,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _applying ? null : _apply,
                  icon: _applying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_reset),
                  label: Text(Strings.of(context).dashSetPwRestart),
                ),
                const SizedBox(height: 8),
                Text(
                  Strings.of(context).dashRestartNote,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              Strings.of(context).dashBridgeNeeded,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              child: Text(Strings.of(context).commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}
