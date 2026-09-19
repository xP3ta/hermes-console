// Editor de credenciales SSH por instancia. Importación fácil: host derivado
// del gateway, clave privada pegada o importada de archivo, passphrase opcional
// o contraseña. "Probar conexión" valida contra el servidor real (con TOFU).
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/connection_manager.dart';
import '../services/ssh_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/ssh_host_key_dialog.dart';

class SshCredentialsScreen extends StatefulWidget {
  final SavedConnection connection;
  const SshCredentialsScreen({required this.connection, super.key});

  @override
  State<SshCredentialsScreen> createState() => _SshCredentialsScreenState();
}

class _SshCredentialsScreenState extends State<SshCredentialsScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();

  SshAuthMethod _method = SshAuthMethod.key;
  bool _hadConfig = false;
  bool _obscurePass = true;
  bool _saving = false;
  bool _testing = false;
  String? _testOk;
  String? _testError;

  SshManager get _mgr =>
      context.findAncestorStateOfType<HermesAppState>()!.sshManager;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mgr = _mgr;
    final cfg = await mgr.loadConfig(widget.connection.id);
    if (!mounted) return;
    setState(() {
      _hadConfig = cfg != null;
      _hostCtrl.text =
          cfg?.host ?? (mgr.derivedHostFor(widget.connection.id) ?? '');
      _portCtrl.text = '${cfg?.port ?? SshManager.defaultPort}';
      _userCtrl.text = cfg?.username ?? '';
      _method = cfg?.method ?? SshAuthMethod.key;
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _keyCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _importKeyFile() async {
    final s = Strings.of(context);
    final res = await FilePicker.platform.pickFiles(withData: true);
    if (res == null || res.files.isEmpty) return;
    final bytes = res.files.first.bytes;
    if (bytes == null) return;
    try {
      final text = utf8.decode(bytes);
      setState(() => _keyCtrl.text = text.trim());
    } catch (e) {
      debugPrint(
        '[ssh-credentials] excepción silenciada (se avisa al usuario y se sigue): $e',
      );
      _snack(s.sshcNotText);
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  /// Valida el formulario y devuelve el mensaje de error, o null si OK.
  String? _validate() {
    if (_hostCtrl.text.trim().isEmpty) {
      return Strings.of(context).sshcMissingHost;
    }
    final port = int.tryParse(_portCtrl.text.trim());
    if (port == null || port < 1 || port > 65535) {
      return Strings.of(context).sshcInvalidPort;
    }
    if (_userCtrl.text.trim().isEmpty) {
      return Strings.of(context).sshcMissingUser;
    }
    if (_method == SshAuthMethod.password) {
      if (_passwordCtrl.text.isEmpty && !_hadConfig) {
        return Strings.of(context).sshcWritePassword;
      }
    } else {
      final hasNewKey = _keyCtrl.text.trim().isNotEmpty;
      if (!hasNewKey && !_hadConfig) return Strings.of(context).sshcPasteKey;
      if (hasNewKey) {
        final err = SshManager.validateKey(_keyCtrl.text, _passphraseCtrl.text);
        if (err != null) return err;
      }
    }
    return null;
  }

  /// Guarda en Keystore. Si un campo de secreto está vacío y ya había config,
  /// conserva el secreto anterior (pasa null).
  Future<bool> _persist() async {
    final err = _validate();
    if (err != null) {
      _snack(err);
      return false;
    }
    final hasNewKey = _keyCtrl.text.trim().isNotEmpty;
    final hasNewPass = _passwordCtrl.text.isNotEmpty;
    await _mgr.saveConfig(
      widget.connection.id,
      host: _hostCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      username: _userCtrl.text.trim(),
      method: _method,
      password: _method == SshAuthMethod.password && hasNewPass
          ? _passwordCtrl.text
          : null,
      privateKeyPem: _method == SshAuthMethod.key && hasNewKey
          ? _keyCtrl.text.trim()
          : null,
      passphrase: _method == SshAuthMethod.key && hasNewKey
          ? _passphraseCtrl.text
          : null,
    );
    _hadConfig = true;
    return true;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await _persist();
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      _snack(Strings.of(context).sshcSaved);
      Navigator.pop(context, true);
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testOk = null;
      _testError = null;
    });
    final saved = await _persist();
    if (!saved) {
      if (mounted) setState(() => _testing = false);
      return;
    }
    try {
      final client = await _mgr.connect(
        widget.connection.id,
        onHostKey: (p) => showSshHostKeyDialog(context, p),
      );
      await client.authenticated;
      final out = await client.run('echo hermes-ssh-ok && uname -sn');
      client.close();
      if (!mounted) return;
      setState(() {
        _testOk = utf8.decode(out).trim();
        _testing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testError = SshManager.describeError(e);
        _testing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isKey = _method == SshAuthMethod.key;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(title: Text(Strings.of(context).sshSetupTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          Text(
            widget.connection.label,
            style: TextStyle(
              fontSize: 13,
              color: colors.secondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _field(
                  colors,
                  _hostCtrl,
                  'Host',
                  hint: Strings.of(context).sshcHostHint,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _field(
                  colors,
                  _portCtrl,
                  Strings.of(context).commonPort,
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _field(
            colors,
            _userCtrl,
            Strings.of(context).commonUser,
            hint: 'p.ej. user',
          ),
          const SizedBox(height: 18),
          Text(
            Strings.of(context).sshcAuthMethod,
            style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
          ),
          const SizedBox(height: 8),
          SegmentedButton<SshAuthMethod>(
            segments: [
              ButtonSegment(
                value: SshAuthMethod.key,
                label: Text(Strings.of(context).sshcPrivateKey),
                icon: const Icon(Icons.vpn_key_outlined, size: 16),
              ),
              ButtonSegment(
                value: SshAuthMethod.password,
                label: Text(Strings.of(context).commonPassword),
                icon: const Icon(Icons.password_outlined, size: 16),
              ),
            ],
            selected: {_method},
            onSelectionChanged: (s) => setState(() => _method = s.first),
          ),
          const SizedBox(height: 16),
          if (isKey) ..._keyFields(colors) else _passwordField(colors),
          const SizedBox(height: 14),
          _securityNote(colors, isKey),
          if (_testOk != null) ...[
            const SizedBox(height: 14),
            _resultBox(colors, ok: true, text: _testOk!),
          ],
          if (_testError != null) ...[
            const SizedBox(height: 14),
            _resultBox(colors, ok: false, text: _testError!),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing || _saving ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 16),
                  label: Text(
                    _testing
                        ? Strings.of(context).sshcTesting
                        : Strings.of(context).sshcTest,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving || _testing ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 16),
                  label: Text(Strings.of(context).commonSave),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _keyFields(HermesThemeColors colors) {
    return [
      Row(
        children: [
          Text(
            Strings.of(context).sshcPrivateKeyPem,
            style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _importKeyFile,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: Text(
              Strings.of(context).sshcImportFile,
              style: TextStyle(fontSize: 12),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      TextField(
        controller: _keyCtrl,
        maxLines: 6,
        minLines: 3,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'monospace',
          color: colors.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: _hadConfig
              ? '•••• clave guardada — pega una nueva para reemplazar'
              : '-----BEGIN OPENSSH PRIVATE KEY-----',
          hintStyle: TextStyle(fontSize: 11.5, color: colors.textDisabled),
          filled: true,
          fillColor: colors.surfaceVariant.withValues(alpha: 0.4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      const SizedBox(height: 12),
      _field(
        colors,
        _passphraseCtrl,
        Strings.of(context).sshcPassphrase,
        obscure: true,
        optional: true,
      ),
    ];
  }

  Widget _passwordField(HermesThemeColors colors) {
    return HermesField(
      controller: _passwordCtrl,
      obscure: _obscurePass,
      autocorrect: false,
      enableSuggestions: false,
      label: Strings.of(context).commonPassword,
      hint: _hadConfig ? '•••• guardada — escribe para cambiar' : null,
      suffix: IconButton(
        icon: Icon(
          _obscurePass
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          size: 18,
          color: colors.textSecondary,
        ),
        onPressed: () => setState(() => _obscurePass = !_obscurePass),
      ),
    );
  }

  Widget _field(
    HermesThemeColors colors,
    TextEditingController ctrl,
    String label, {
    String? hint,
    bool obscure = false,
    bool optional = false,
    TextInputType? keyboardType,
  }) {
    return HermesField(
      controller: ctrl,
      obscure: obscure,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: keyboardType,
      label: label,
      hint: hint,
    );
  }

  Widget _securityNote(HermesThemeColors colors, bool isKey) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 15, color: colors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isKey
                  ? Strings.of(context).sshcRecommended
                  : Strings.of(context).sshcPasswordNote,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultBox(
    HermesThemeColors colors, {
    required bool ok,
    required String text,
  }) {
    final tone = ok ? colors.success : colors.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: tone,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ok ? Strings.of(context).sshcConnOk(text) : text,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                fontFamily: 'monospace',
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
