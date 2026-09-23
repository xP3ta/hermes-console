// Conexión remota guiada. La ruta principal evita preguntas técnicas: escanear
// un QR existente o preparar el servidor en tres pasos (SO → copiar → escanear).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/connection_manager.dart';
import '../../services/pairing_link.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_notice.dart';
import '../../widgets/hermes_ui.dart';
import '../instance_edit_screen.dart';
import '../qr_scan_screen.dart';
import 'server_setup_screen.dart';

class ConnectChooserScreen extends StatefulWidget {
  final ConnectionManager connManager;

  /// Se llama cuando se ha creado una conexión (para cerrar el onboarding).
  final VoidCallback? onDone;

  const ConnectChooserScreen({
    required this.connManager,
    this.onDone,
    super.key,
  });

  @override
  State<ConnectChooserScreen> createState() => _ConnectChooserScreenState();
}

class _ConnectChooserScreenState extends State<ConnectChooserScreen> {
  /// Enlace de emparejado pegado por el usuario (si lo hay).
  PairingLink? _detected;

  /// Lee el portapapeles SOLO bajo demanda (botón "Pegar enlace"): la lectura
  /// automática en initState disparaba el aviso del sistema "ha accedido al
  /// portapapeles" en cada apertura, sin gesto del usuario (spec 028 A-009).
  Future<void> _pasteLink() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final link = PairingLink.tryParse(data?.text ?? '');
      if (!mounted) return;
      if (link != null) {
        // Muestra la tarjeta con host:puerto para que el usuario confirme
        // antes de abrir el alta precargada.
        setState(() => _detected = link);
      } else {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).connectNoLinkInClipboard)),
          kind: HermesNoticeKind.warning,
        );
      }
    } catch (_) {
      // El portapapeles puede no estar disponible; sin detección, sin problema.
    }
  }

  Future<void> _openManual(BuildContext context) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(connManager: widget.connManager),
      ),
    );
    if (saved == true) widget.onDone?.call();
  }

  Future<void> _useDetected(BuildContext context) async {
    final link = _detected;
    if (link == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(
          connManager: widget.connManager,
          initialLink: link,
        ),
      ),
    );
    if (saved == true) widget.onDone?.call();
  }

  Future<void> _openSetup(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ServerSetupScreen(
          connManager: widget.connManager,
          onDone: widget.onDone,
        ),
      ),
    );
  }

  Future<void> _scanQr() async {
    final link = await Navigator.of(context).push<PairingLink>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (link == null || !mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(
          connManager: widget.connManager,
          initialLink: link,
        ),
      ),
    );
    if (saved == true) widget.onDone?.call();
  }

  Future<void> _openInstallGuide() async {
    final language = Localizations.localeOf(context).languageCode;
    final path = language == 'en' ? '/en/guia#instalar' : '/guia#instalar';
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse('https://hermes.xpetalab.dev$path'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).connectGuideOpenFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(title: Text(str.connectTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            _ConnectionDiagram(colors: colors),
            const SizedBox(height: 24),
            Text(
              str.connectSimpleQuestion,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              str.connectSimpleIntro,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            if (_detected != null) ...[
              _DetectedLinkCard(
                colors: colors,
                title: str.connectDetectedTitle,
                body:
                    '${str.connectDetectedBody}\n${_detected!.host}:${_detected!.port}',
                useLabel: str.connectDetectedUse,
                onUse: () => _useDetected(context),
              ),
              const SizedBox(height: 18),
            ],
            _ConnectCard(
              colors: colors,
              icon: Icons.qr_code_scanner_rounded,
              title: str.connectScanQr,
              body: str.connectScanQrBody,
              onTap: _scanQr,
            ),
            const SizedBox(height: 14),
            _ConnectCard(
              colors: colors,
              icon: Icons.auto_fix_high_rounded,
              title: str.connectPrepareServer,
              body: str.connectPrepareServerBody,
              onTap: () => _openSetup(context),
            ),
            const SizedBox(height: 14),
            Center(
              child: TextButton.icon(
                onPressed: _pasteLink,
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: Text(str.connectPasteLink),
                style: TextButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  minimumSize: const Size(48, 48),
                ),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: () => _openManual(context),
                icon: const Icon(Icons.tune_rounded, size: 16),
                label: Text(str.connectManualAdvanced),
                style: TextButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  minimumSize: const Size(48, 48),
                ),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: _openInstallGuide,
                child: Text(str.connectInstallHelp),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionDiagram extends StatelessWidget {
  const _ConnectionDiagram({required this.colors});

  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final str = Strings.of(context);
    Widget node(IconData icon, String label) => Expanded(
      child: Column(
        children: [
          Icon(icon, size: 30, color: colors.accent),
          const SizedBox(height: 7),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );

    return Semantics(
      label: str.connectDiagramSemantics,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: colors.surfaceVariant.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(HermesRadii.group),
            border: Border.all(color: colors.divider.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              node(Icons.dns_rounded, str.connectDiagramServer),
              Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: colors.textDisabled,
              ),
              node(Icons.qr_code_2_rounded, str.connectDiagramCode),
              Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: colors.textDisabled,
              ),
              node(Icons.smartphone_rounded, str.connectDiagramPhone),
            ],
          ),
        ),
      ),
    );
  }
}

/// Banner destacado cuando se detecta un enlace de emparejado en el portapapeles.
class _DetectedLinkCard extends StatelessWidget {
  final HermesThemeColors colors;
  final String title;
  final String body;
  final String useLabel;
  final VoidCallback onUse;

  const _DetectedLinkCard({
    required this.colors,
    required this.title,
    required this.body,
    required this.useLabel,
    required this.onUse,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.link_rounded, color: colors.accent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: HermesPrimaryButton(
              label: useLabel,
              icon: Icons.bolt_rounded,
              onTap: onUse,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  final HermesThemeColors colors;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  const _ConnectCard({
    required this.colors,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colors.divider.withValues(alpha: 0.22),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colors.accent, size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: colors.textSecondary),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              body,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
