import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/bridge_client.dart';
import '../services/bridge_manager.dart';
import '../widgets/hermes_notice.dart';
import 'bridge_config_screen.dart';
import 'lock_screen.dart';

/// Lógica común de un editor respaldado por el Mobile Bridge: autodetección,
/// autoprovisión del token, leer el contenido real del servidor, recargar y
/// aplicar con diff + backup + App Lock. La usan los editores de SOUL, cron…
/// (el editor de memoria implementa lo mismo de forma autónoma).
///
/// La clase que la usa debe proveer [bridgeConnectionId], [bridgeTarget] y
/// [bridgeController], llamar a [probeBridge] en `didChangeDependencies`, y
/// pintar [bridgeBanner]/botones usando [bridgeCanRead]/[bridgeCanWrite].
mixin BridgeEditorMixin<T extends StatefulWidget> on State<T> {
  String get bridgeConnectionId;
  String get bridgeTarget;
  TextEditingController get bridgeController;
  String get bridgeLockReason;

  BridgeManager? _mgr;
  BridgeState bridge = BridgeState.unknown;
  bool bridgeApplying = false;
  bool bridgeLoading = false;
  bool _bridgeAutoLoadDone = false;
  bool _bridgeProbed = false;

  BridgeManager get bridgeManager =>
      _mgr ??= context.findAncestorStateOfType<HermesAppState>()!.bridgeManager;

  bool get bridgeCanWrite {
    final c = bridge.caps;
    if (!bridge.connected || c.readOnly) return false;
    // Usa el mapa de destinos del servidor (memory/user/soul/persona/cron…).
    // Fallback por compatibilidad si el bridge no envió `targets`.
    if (c.writableTargets.isNotEmpty) return c.canWriteTarget(bridgeTarget);
    return bridgeTarget == 'soul' ? c.soulWrite : c.memoryWrite;
  }

  bool get bridgeCanRead => bridge.connected && bridge.caps.fileRead;

  /// Llamar una vez (idempotente) desde `didChangeDependencies`.
  void probeBridgeOnce() {
    if (_bridgeProbed) return;
    _bridgeProbed = true;
    probeBridge();
  }

  Future<void> probeBridge() async {
    var st = await bridgeManager.probe(bridgeConnectionId);
    // Autoprovisión: si corre pero falta token, obtenerlo con la gateway key.
    if (st.status == BridgeStatus.needsToken) {
      if (await bridgeManager.tryProvision(bridgeConnectionId)) {
        st = await bridgeManager.probe(bridgeConnectionId);
      }
    }
    if (!mounted) return;
    setState(() => bridge = st);
    _maybeAutoLoadFromServer();
  }

  /// La pantalla puede desactivar la auto-carga desde el bridge (que SIEMPRE
  /// apunta al home default y NO scopea por perfil). P.ej. el editor de SOUL por
  /// perfil carga vía Dashboard scoped y no debe ser pisado por el contenido del
  /// default — ni permitir que «aplicar» escriba al default por error.
  bool get bridgeAutoLoadEnabled => true;

  void _maybeAutoLoadFromServer() {
    if (_bridgeAutoLoadDone || !bridgeCanRead) return;
    if (!bridgeAutoLoadEnabled) {
      _bridgeAutoLoadDone = true; // la pantalla gestiona la carga (scoped)
      return;
    }
    if (bridgeController.text.trim().isNotEmpty) {
      _bridgeAutoLoadDone = true; // hay borrador: no pisarlo
      return;
    }
    _bridgeAutoLoadDone = true;
    loadFromServer(confirmIfDirty: false, silent: true);
  }

  Future<void> loadFromServer({
    bool confirmIfDirty = true,
    bool silent = false,
  }) async {
    if (!bridgeCanRead) return;
    final s = Strings.of(context);
    if (confirmIfDirty && bridgeController.text.trim().isNotEmpty) {
      FocusManager.instance.primaryFocus?.unfocus();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.bfeReloadTitle),
          content: Text(s.bfeReloadBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(s.commonReload),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final client = await bridgeManager.clientFor(bridgeConnectionId);
    if (client == null || !mounted) return;
    setState(() => bridgeLoading = true);
    try {
      final res = await client.read(bridgeTarget);
      final content = (res['content'] ?? '').toString();
      if (!mounted) return;
      bridgeController.text = content;
      if (!silent) {
        final exists = res['exists'] == true;
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(exists
                ? s.bfeLoadedBytes(res['size'])
                : s.bfeFileNotOnServer),
          ),
        );
      }
    } on BridgeException catch (e) {
      _snack(s.bfeBridgeError(e.message));
    } catch (e) {
      _snack(s.bfeLoadError(e));
    } finally {
      client.close();
      if (mounted) setState(() => bridgeLoading = false);
    }
  }

  Future<void> applyToServer() async {
    if (!bridgeCanWrite) return;
    final s = Strings.of(context);
    final client = await bridgeManager.clientFor(bridgeConnectionId);
    if (client == null || !mounted) return;
    try {
      final preview = await client.write(
        file: bridgeTarget,
        content: bridgeController.text,
        dryRun: true,
      );
      if (!mounted) return;
      final diff = (preview['diff'] ?? '').toString();
      final confirmed = await _confirmDiff(diff, s);
      if (confirmed != true || !mounted) return;

      final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
      if (lock != null && lock.enabled) {
        final ok = await LockScreen.verify(context, lock,
            reason: bridgeLockReason);
        if (!ok || !mounted) return;
      }

      setState(() => bridgeApplying = true);
      final res =
          await client.write(file: bridgeTarget, content: bridgeController.text);
      if (!mounted) return;
      final backup = res['backup_id'];
      _snack(backup != null
          ? s.bfeAppliedWithBackup(backup)
          : s.bfeAppliedOk);
    } on BridgeException catch (e) {
      _snack(s.bfeBridgeError(e.message));
    } catch (e) {
      _snack(s.bfeApplyError(e));
    } finally {
      client.close();
      if (mounted) setState(() => bridgeApplying = false);
    }
  }

  Future<bool?> _confirmDiff(String diff, Strings s) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.bfeApplyTitle(bridgeTarget)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              diff.isEmpty ? s.bfeNoDiff : diff,
              style: const TextStyle( fontSize: 11.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.soulApply),
          ),
        ],
      ),
    );
  }

  Future<void> configureBridge() async {
    final s = Strings.of(context);
    final derived = bridgeManager.derivedUrlFor(bridgeConnectionId) ?? '';
    final result = await Navigator.of(context).push<BridgeConfigResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BridgeConfigScreen(
          initialUrl: bridge.url.isNotEmpty ? bridge.url : derived,
          derivedUrl: derived,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final override = result.url.trim() == derived ? '' : result.url.trim();
    await bridgeManager.save(bridgeConnectionId,
        token: result.token, urlOverride: override);
    if (!mounted) return;
    _bridgeAutoLoadDone = false;
    await probeBridge();
    if (mounted) {
      _snack(bridge.connected
          ? (bridgeCanWrite
              ? s.bfeBridgeConnectedWrite
              : s.bfeBridgeConnectedNoWrite)
          : bridge.running
          ? s.bfeBridgeTokenInvalid
          : s.bfeBridgeConnectFailed(bridge.url));
    }
  }

  ({String text, IconData icon}) bridgeBanner({required String localFallback}) {
    final s = Strings.of(context);
    switch (bridge.status) {
      case BridgeStatus.connected:
        return (
          text: bridgeCanWrite
              ? s.bfeBannerConnectedWrite
              : s.bfeBannerConnectedReadOnly,
          icon: Icons.cloud_done_outlined,
        );
      case BridgeStatus.needsToken:
        return (
          text: s.bfeBannerNeedsToken(bridge.url),
          icon: Icons.cloud_queue,
        );
      case BridgeStatus.authFailed:
        return (
          text: s.bfeBannerAuthFailed,
          icon: Icons.cloud_off_outlined,
        );
      case BridgeStatus.unreachable:
        final base = s.bfeBannerUnreachable(bridge.url);
        return (
          // Adjunta la causa real (rechazado/timeout/DNS/TLS/HTTP) en vez de
          // un genérico "no responde": el usuario sabe qué arreglar.
          text: bridge.errorDetail.isNotEmpty
              ? '$base\n${bridge.errorDetail}'
              : base,
          icon: Icons.cloud_off_outlined,
        );
      case BridgeStatus.notConfigured:
        return (text: localFallback, icon: Icons.cloud_off_outlined);
    }
  }

  IconData get bridgeIcon => bridge.connected
      ? Icons.cloud_done_outlined
      : bridge.running
      ? Icons.cloud_queue
      : Icons.cloud_off_outlined;

  void _snack(String msg) {
    if (mounted) {
      HermesNotice.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}
