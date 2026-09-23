import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';
import 'bridge_editor_mixin.dart';
import '../widgets/hermes_app_bar.dart';

/// Editor/visor genérico de un archivo real del servidor vía Mobile Bridge.
///
/// Sirve para destinos que no tienen pantalla propia: `cron` (editable, JSON
/// validado en el servidor) y `config` (solo lectura con secretos enmascarados).
/// Carga el contenido real al abrir; «aplicar» guarda con backup+diff+App Lock.
class BridgeFileEditorScreen extends StatefulWidget {
  final String connectionId;
  final String target; // 'cron', 'config', …
  final String titleLabel; // p.ej. 'jobs.json'
  final bool readOnly; // config: solo lectura
  final String lockReason;

  const BridgeFileEditorScreen({
    required this.connectionId,
    required this.target,
    required this.titleLabel,
    this.readOnly = false,
    this.lockReason = '',
    super.key,
  });

  @override
  State<BridgeFileEditorScreen> createState() => _BridgeFileEditorScreenState();
}

class _BridgeFileEditorScreenState extends State<BridgeFileEditorScreen>
    with BridgeEditorMixin<BridgeFileEditorScreen> {
  final _ctrl = TextEditingController();

  @override
  String get bridgeConnectionId => widget.connectionId;
  @override
  String get bridgeTarget => widget.target;
  @override
  TextEditingController get bridgeController => _ctrl;
  @override
  String get bridgeLockReason => widget.lockReason.isEmpty
      ? Strings.of(context).bfeApplyChanges
      : widget.lockReason;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    probeBridgeOnce();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _editable => !widget.readOnly && bridgeCanWrite;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.titleLabel,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: colors.accent.withValues(alpha: 0.4)),
              ),
              child: Text(
                widget.readOnly
                    ? Strings.of(context).bfeReadOnlyBadge
                    : Strings.of(context).bfeServerBadge,
                style: TextStyle(
                  fontSize: 9.5,
                  letterSpacing: 0.5,
                  color: colors.accentHover,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              bridgeIcon,
              color: bridge.connected
                  ? colors.success
                  : bridge.running
                  ? colors.accent
                  : colors.textSecondary,
            ),
            tooltip: Strings.of(context).soulConfigBridge,
            onPressed: configureBridge,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Builder(
              builder: (_) {
                final b = bridgeBanner(
                  localFallback: Strings.of(context)
                      .bfeConfigureBody(widget.titleLabel),
                );
                final text = widget.readOnly && bridge.connected
                    ? Strings.of(context).bfeReadOnlyView
                    : b.text;
                return HermesInfoBanner(text, icon: b.icon);
              },
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                readOnly: widget.readOnly,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: colors.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: bridge.connected
                      ? null
                      : Strings.of(context).bfeNoBridgeConnected,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ),
          if (bridgeCanRead || _editable)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.divider.withValues(alpha: 0.55))),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: [
                        if (bridgeCanRead) ...[
                          HermesSecondaryButton(
                            label: bridgeLoading
                                ? Strings.of(context).commonLoading
                                : Strings.of(context).commonReload,
                            icon: Icons.cloud_download_outlined,
                            onTap: bridgeLoading ? null : () => loadFromServer(),
                          ),
                          const SizedBox(width: 7),
                        ],
                        if (bridgeCanRead)
                          HermesSecondaryButton(
                            label: Strings.of(context).commonCopy,
                            icon: Icons.copy_outlined,
                            onTap: () async {
                              await Clipboard.setData(
                                ClipboardData(text: _ctrl.text),
                              );
                              if (context.mounted) {
                                HermesNotice.of(context).showSnackBar(
                                  SnackBar(content: Text(Strings.of(context).bfeCopied)),
                                  kind: HermesNoticeKind.success,
                                );
                              }
                            },
                          ),
                        if (_editable) ...[
                          const SizedBox(width: 7),
                          HermesSecondaryButton(
                            label: bridgeApplying
                                ? Strings.of(context).bfeApplying
                                : Strings.of(context).bfeApply,
                            icon: Icons.cloud_upload_outlined,
                            color: colors.accent,
                            onTap: bridgeApplying ? null : applyToServer,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
