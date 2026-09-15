import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/bridge_manager.dart';
import '../services/bridge_update_service.dart';
import '../services/bridge_version.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import 'platform_setup_commands.dart';

/// Aviso de compatibilidad mínima: si el bridge remoto es más viejo que el asset
/// de esta APK, ofrece resolver e instalar la mejor release validada.
class BridgeUpdateBanner extends StatelessWidget {
  const BridgeUpdateBanner({
    super.key,
    required this.bridge,
    required this.connection,
    required this.onUpdated,
  });

  final BridgeState bridge;
  final SavedConnection connection;

  /// Se llama tras verificar que el bridge ya corre la versión esperada (para
  /// que la pantalla recargue su contenido).
  final Future<void> Function() onUpdated;

  @override
  Widget build(BuildContext context) {
    final running = bridge.caps.version;
    if (!bridge.connected || !BridgeVersion.isOutdated(running)) {
      return const SizedBox.shrink();
    }
    // Bug real: usaba Theme.of(context).colorScheme en vez de `hermes`.
    final colors = Theme.of(context).hermes;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: colors.warning.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.system_update_alt, size: 20, color: colors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                Strings.of(
                  context,
                ).bridgeOutdated(running ?? '?', BridgeVersion.expected),
                style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: 8),
            if (!connection.readOnly)
              FilledButton(
                onPressed: () => _promptUpdate(context),
                child: Text(Strings.of(context).commonUpdate),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptUpdate(BuildContext context) async {
    // Acción manual explícita: el servicio prefiere self_update autenticado y
    // solo usa el instalador legacy para adquirir esa capacidad por primera vez.
    final progress = ValueNotifier<String>('…');
    var manualRequested = false;
    BuildContext? progressCtx;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) {
          progressCtx = dctx;
          return AlertDialog(
            title: Text(Strings.of(context).bridgeUpdateTitle),
            content: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: progress,
                    builder: (_, s, _) => Text(s),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  manualRequested = true;
                  Navigator.of(dctx).pop();
                  _showManualDialog(context);
                },
                child: Text(Strings.of(context).bridgeUpdateUseManual),
              ),
            ],
          );
        },
      ).then((_) => progressCtx = null),
    );

    late BridgeUpdateResult res;
    try {
      res = await BridgeUpdateService.update(
        connection,
        onProgress: (s) => progress.value = s,
      );
    } catch (e) {
      res = BridgeUpdateResult.failure(
        BridgeUpdateFailure.repairFailed,
        '${e.runtimeType}',
      );
    }
    if (!context.mounted) {
      progress.dispose();
      return;
    }
    if (progressCtx != null && progressCtx!.mounted) {
      Navigator.of(progressCtx!).pop();
    }
    progress.dispose();
    if (manualRequested) return; // el diálogo manual ya está abierto.

    if (res.ok) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).bridgeUpdated)),
      );
      await onUpdated();
      return;
    }
    if (!context.mounted) return;
    await _showManualDialog(context);
  }

  /// Fallback manual: enseña el curl del repo público con Copiar y Verificar.
  Future<void> _showManualDialog(BuildContext context) async {
    final verifying = ValueNotifier<bool>(false);
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(Strings.of(context).bridgeUpdateTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Strings.of(context).bridgeUpdateCmdBody),
              const SizedBox(height: 12),
              const PlatformSetupCommands(),
            ],
          ),
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: verifying,
            builder: (_, busy, _) => TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(dctx);
                      final nav = Navigator.of(dctx);
                      final strUpdated = Strings.of(dctx).bridgeUpdated;
                      final strStillOld = Strings.of(dctx).bridgeVerifyStillOld;
                      verifying.value = true;
                      final ok = await _verify();
                      verifying.value = false;
                      if (ok) {
                        nav.pop();
                        await onUpdated();
                        messenger.showSnackBar(
                          SnackBar(content: Text(strUpdated)),
                        );
                      } else {
                        messenger.showSnackBar(
                          SnackBar(content: Text(strStillOld)),
                        );
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(Strings.of(context).bridgeAlreadyRanVerify),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(Strings.of(context).commonClose),
          ),
        ],
      ),
    );
    verifying.dispose();
  }

  /// Re-sondea la versión del bridge; true si ya corre la esperada.
  Future<bool> _verify() async {
    try {
      final check = await BridgeUpdateService.check(
        connection,
        allowRemote: true,
      );
      return check.reachable && !check.outdated;
    } catch (e) {
      debugPrint(
        '[bridge-update-banner] excepción silenciada (se asume false): $e',
      );
      return false;
    }
  }
}
