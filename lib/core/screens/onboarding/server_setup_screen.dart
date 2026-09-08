// Asistente progresivo para preparar Hermes o volver a mostrar su QR. Enseña
// una sola decisión y un solo artefacto cada vez; los puertos y servicios se
// relegan a detalles técnicos.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/connection_manager.dart';
import '../../services/pairing_link.dart';
import '../../services/server_setup_generator.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_ui.dart';
import '../instance_edit_screen.dart';
import '../qr_scan_screen.dart';

enum ServerSetupMode { prepare, showQr }

class ServerSetupScreen extends StatefulWidget {
  final ConnectionManager connManager;

  /// Se llama cuando se ha creado una conexión (para cerrar el onboarding).
  final VoidCallback? onDone;
  final ServerSetupMode mode;

  const ServerSetupScreen({
    required this.connManager,
    this.onDone,
    this.mode = ServerSetupMode.prepare,
    super.key,
  });

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  ServerHostPlatform? _platform;
  bool _commandCopied = false;
  bool _agentGuidanceExpanded = false;

  // Estado de los desplegables del paso 1.
  bool _detailsExpanded = false;
  void _copy(String text, String toast) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
  }

  void _copyCommand(String text, String toast) {
    _copy(text, toast);
    if (!_commandCopied) setState(() => _commandCopied = true);
  }

  /// Única entrada del paso 3 (U-34): abre el escáner —que integra también
  /// "pegar del portapapeles" para quien recibe el enlace por texto— y conecta
  /// con el resultado precargando el alta.
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

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final link = PairingLink.tryParse(data?.text?.trim() ?? '');
    if (!mounted) return;
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).connectNoLinkInClipboard)),
      );
      return;
    }
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final str = Strings.of(context);
    final showQrOnly = widget.mode == ServerSetupMode.showQr;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        title: Text(showQrOnly ? str.setupShowQrTitle : str.setupPrepareTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            _SetupDiagram(colors: colors),
            const SizedBox(height: 22),
            Text(
              showQrOnly ? str.setupShowQrIntro : str.setupPrepareIntro,
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            _StepHeader(
              step: 1,
              total: 3,
              label: str.setupChooseServerPlatform,
            ),
            _PlatformSelector(
              colors: colors,
              selected: _platform,
              onSelected: (value) => setState(() {
                _platform = value;
                _commandCopied = false;
              }),
            ),
            if (_platform == ServerHostPlatform.windows) ...[
              const SizedBox(height: 10),
              HermesInfoBanner(
                str.setupWslPowerShellHint,
                icon: Icons.terminal_rounded,
              ),
            ],
            if (_platform != null) ...[
              _StepHeader(
                step: 2,
                total: 3,
                label: showQrOnly
                    ? str.setupCopyPairCommand
                    : str.setupCopyRunCommand,
              ),
              _SetupProcessPreview(commandCopied: _commandCopied),
              const SizedBox(height: 12),
              _ArtifactCard(
                colors: colors,
                text: showQrOnly
                    ? ServerSetupGenerator.pairCommandFor(_platform!)
                    : ServerSetupGenerator.setupCommandFor(_platform!),
              ),
              const SizedBox(height: 10),
              HermesPrimaryButton(
                label: str.setupCopyCommand,
                icon: Icons.copy_rounded,
                onTap: () => _copyCommand(
                  showQrOnly
                      ? ServerSetupGenerator.pairCommandFor(_platform!)
                      : ServerSetupGenerator.setupCommandFor(_platform!),
                  str.qrCmdCopied,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                showQrOnly ? str.setupRunPairBody : str.setupRunCommandHint,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: colors.textSecondary,
                ),
              ),
              if (!showQrOnly) ...[
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: () => setState(
                    () => _agentGuidanceExpanded = !_agentGuidanceExpanded,
                  ),
                  icon: Icon(
                    _agentGuidanceExpanded
                        ? Icons.expand_less_rounded
                        : Icons.help_outline_rounded,
                    size: 18,
                  ),
                  label: Text(str.setupUseHermesInstead),
                ),
                if (_agentGuidanceExpanded) ...[
                  Text(
                    str.setupAgentStepBody,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _ArtifactCard(
                    colors: colors,
                    text: ServerSetupGenerator.agentPromptFor(_platform!),
                  ),
                  const SizedBox(height: 10),
                  HermesSecondaryButton(
                    label: str.setupCopyPrompt,
                    icon: Icons.copy_rounded,
                    onTap: () => _copy(
                      ServerSetupGenerator.agentPromptFor(_platform!),
                      str.setupPromptCopied,
                    ),
                  ),
                ],
              ],
              _StepHeader(step: 3, total: 3, label: str.setupSeeQr),
              Text(
                showQrOnly ? str.setupSeeQrBody : str.setupSshResultBody,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              HermesInfoBanner(
                str.setupPairingSecretAtEntry,
                icon: Icons.key_rounded,
                key: const ValueKey('setup-pairing-secret-at-entry'),
              ),
              const SizedBox(height: 12),
              HermesPrimaryButton(
                label: str.setupISeeQr,
                icon: Icons.qr_code_scanner_rounded,
                onTap: _scanQr,
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _pasteLink,
                  icon: const Icon(Icons.content_paste_rounded, size: 17),
                  label: Text(str.qrPasteInstead),
                ),
              ),
            ],
            const SizedBox(height: 18),
            HermesInfoBanner(
              str.setupQrSecurity,
              icon: Icons.lock_outline_rounded,
            ),
            const SizedBox(height: 4),
            _ExpandableDetails(
              colors: colors,
              label: str.setupWhatItDoes,
              expanded: _detailsExpanded,
              onToggle: () =>
                  setState(() => _detailsExpanded = !_detailsExpanded),
              bullets: [
                str.setupBulletInstall,
                str.setupBulletToken,
                str.setupBulletPort(ServerSetupGenerator.bridgePort),
                str.setupBulletLink,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlatformSelector extends StatelessWidget {
  const _PlatformSelector({
    required this.colors,
    required this.selected,
    required this.onSelected,
  });

  final HermesThemeColors colors;
  final ServerHostPlatform? selected;
  final ValueChanged<ServerHostPlatform> onSelected;

  @override
  Widget build(BuildContext context) {
    final str = Strings.of(context);
    final labels = <ServerHostPlatform, String>{
      ServerHostPlatform.linux: str.setupPlatformLinux,
      ServerHostPlatform.macos: str.setupPlatformMacos,
      ServerHostPlatform.windows: str.setupPlatformWindows,
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: labels.entries
          .map(
            (entry) => ChoiceChip(
              label: Text(entry.value),
              selected: selected == entry.key,
              onSelected: (_) => onSelected(entry.key),
              selectedColor: colors.accent.withValues(alpha: 0.18),
              side: BorderSide(
                color: selected == entry.key ? colors.accent : colors.divider,
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _SetupDiagram extends StatelessWidget {
  const _SetupDiagram({required this.colors});

  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final str = Strings.of(context);
    return Semantics(
      label: str.connectDiagramSemantics,
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.dns_rounded, color: colors.accent, size: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(
                Icons.arrow_forward_rounded,
                color: colors.textDisabled,
                size: 20,
              ),
            ),
            Icon(Icons.qr_code_2_rounded, color: colors.accent, size: 44),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(
                Icons.arrow_forward_rounded,
                color: colors.textDisabled,
                size: 20,
              ),
            ),
            Icon(Icons.smartphone_rounded, color: colors.accent, size: 32),
          ],
        ),
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.colors, required this.text});

  final HermesThemeColors colors;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 170),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(HermesRadii.field),
        border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11.5,
            height: 1.4,
            color: colors.accentHover,
          ),
        ),
      ),
    );
  }
}

/// Encabezado de paso numerado. Para TalkBack anuncia "Paso N de M" como
/// encabezado, de forma que el orden del flujo es navegable por cabeceras.
class _StepHeader extends StatelessWidget {
  final int step;
  final int total;
  final String label;

  const _StepHeader({
    required this.step,
    required this.total,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: Strings.of(
        context,
      ).setupStepSemantics(step, total, label.split('·').last.trim()),
      child: ExcludeSemantics(
        child: HermesSectionHeader(
          label,
          padding: const EdgeInsets.fromLTRB(2, 24, 2, 10),
        ),
      ),
    );
  }
}

/// Vista previa honesta del proceso del script. Solo la copia se puede observar
/// desde el móvil antes del emparejado; el resto se verifica de verdad después
/// de escanear el QR, durante el diagnóstico automático de la instancia.
class _SetupProcessPreview extends StatelessWidget {
  final bool commandCopied;

  const _SetupProcessPreview({required this.commandCopied});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final stages = [
      s.setupProgressCheck,
      s.setupProgressServices,
      s.setupProgressNetwork,
      s.setupProgressQr,
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(HermesRadii.group),
        border: Border.all(color: colors.divider.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.setupProgressTitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: commandCopied ? 0.25 : 0,
              minHeight: 5,
              color: colors.accent,
              backgroundColor: colors.divider.withValues(alpha: 0.3),
            ),
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < stages.length; index++) ...[
            Row(
              children: [
                Icon(
                  index == 0 && commandCopied
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 15,
                  color: index == 0 && commandCopied
                      ? colors.success
                      : colors.textDisabled,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stages[index],
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            if (index != stages.length - 1) const SizedBox(height: 7),
          ],
          const SizedBox(height: 10),
          Text(
            s.setupProgressVerificationNote,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: colors.textDisabled,
            ),
          ),
        ],
      ),
    );
  }
}

/// Desplegable ligero "qué hace exactamente" con viñetas — la letra pequeña
/// honesta bajo la nota de confianza del paso 1.
class _ExpandableDetails extends StatelessWidget {
  final HermesThemeColors colors;
  final String label;
  final bool expanded;
  final VoidCallback onToggle;
  final List<String> bullets;

  const _ExpandableDetails({
    required this.colors,
    required this.label,
    required this.expanded,
    required this.onToggle,
    required this.bullets,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 15,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final b in bullets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '·  ',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: colors.accentHover,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            b,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
