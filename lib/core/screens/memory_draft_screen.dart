import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/bridge_client.dart';
import '../services/bridge_manager.dart';
import '../services/command_risk.dart';
import '../services/memory_draft_store.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import 'bridge_config_screen.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';

/// Editor LOCAL de un archivo de memoria.
///
/// La API actual no permite guardar memoria remotamente: este editor guarda
/// un borrador local (autosave) que se puede copiar, exportar a un archivo
/// .md o descartar. Nunca muestra un "guardar remoto" ni finge sincronizar.
class MemoryDraftScreen extends StatefulWidget {
  final String connectionId;
  final String fileName; // sin extensión, p.ej. "memory" / "user"
  final String? profile;

  const MemoryDraftScreen({
    required this.connectionId,
    required this.fileName,
    this.profile,
    super.key,
  });

  @override
  State<MemoryDraftScreen> createState() => _MemoryDraftScreenState();
}

class _MemoryDraftScreenState extends State<MemoryDraftScreen> {
  MemoryDraftStore? _store;
  final _ctrl = TextEditingController();
  Timer? _saveDebounce;
  DateTime? _updatedAt;
  bool _loaded = false;

  // Mobile Bridge (opcional, autodetectado desde el host del gateway): si está
  // conectado y soporta escritura, se ofrece "aplicar"; si no, borrador local.
  BridgeManager? _mgr;
  BridgeState _bridge = BridgeState.unknown;
  bool _applying = false;
  bool _loadingFromServer = false;
  bool _bridgeProbed = false;
  // Evita auto-cargar del servidor más de una vez por apertura.
  bool _serverAutoLoadDone = false;

  BridgeManager get _bridgeMgr =>
      _mgr ??= context.findAncestorStateOfType<HermesAppState>()!.bridgeManager;

  /// Destino allowlisted del bridge según el archivo del editor.
  String get _bridgeTarget {
    final f = widget.fileName.toLowerCase();
    if (f.contains('soul')) return 'soul';
    if (f.contains('persona')) return 'persona';
    if (f.contains('user')) return 'user';
    return 'memory';
  }

  bool get _hasSecondaryProfileScope {
    final profile = widget.profile?.trim() ?? '';
    return profile.isNotEmpty && profile != 'default';
  }

  bool get _bridgeCanWrite {
    if (_hasSecondaryProfileScope) return false;
    final c = _bridge.caps;
    if (!_bridge.connected || c.readOnly) return false;
    // `soul` usa soul_write; persona/user/memory usan memory_write.
    return _bridgeTarget == 'soul' ? c.soulWrite : c.memoryWrite;
  }

  bool get _bridgeCanRead =>
      !_hasSecondaryProfileScope && _bridge.connected && _bridge.caps.fileRead;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // El sondeo necesita el contexto (BridgeManager del ancestro): se hace aquí,
    // una sola vez, no en initState.
    if (!_bridgeProbed) {
      _bridgeProbed = true;
      _probeBridge();
    }
  }

  Future<void> _probeBridge() async {
    var st = await _bridgeMgr.probe(widget.connectionId);
    // Autoprovisión: si el bridge corre pero falta token, intenta obtenerlo con
    // la API key del gateway (sin que el usuario teclee nada).
    if (st.status == BridgeStatus.needsToken) {
      if (await _bridgeMgr.tryProvision(widget.connectionId)) {
        st = await _bridgeMgr.probe(widget.connectionId);
      }
    }
    if (!mounted) return;
    setState(() => _bridge = st);
    _maybeAutoLoadFromServer();
  }

  /// Si el bridge puede leer y el borrador local está vacío, carga el contenido
  /// real del servidor (una sola vez) para editarlo en vez de empezar de cero.
  void _maybeAutoLoadFromServer() {
    if (_serverAutoLoadDone) return;
    if (!_loaded || !_bridgeCanRead) return; // espera a tener ambos listos
    if (_ctrl.text.trim().isNotEmpty) {
      // Hay borrador local: no lo pisamos; el usuario puede recargar a mano.
      _serverAutoLoadDone = true;
      return;
    }
    _serverAutoLoadDone = true;
    _loadFromServer(confirmIfDirty: false, silent: true);
  }

  /// Carga el contenido actual del servidor en el editor. Con [confirmIfDirty]
  /// pide confirmación si el borrador local tiene contenido (para no perderlo).
  Future<void> _loadFromServer({
    bool confirmIfDirty = true,
    bool silent = false,
  }) async {
    if (!_bridgeCanRead) return;
    if (confirmIfDirty && _ctrl.text.trim().isNotEmpty) {
      // Suelta el foco antes del diálogo (higiene anti `_dependents`).
      FocusManager.instance.primaryFocus?.unfocus();
      final colors = Theme.of(context).hermes;
      final s = Strings.of(context);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.memReloadTitle),
          content: Text(s.memReloadContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.memCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                s.memReload,
                style: TextStyle(color: colors.onAccent),
              ),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final client = await _bridgeMgr.clientFor(widget.connectionId);
    if (client == null || !mounted) return;
    setState(() => _loadingFromServer = true);
    try {
      final res = await client.read(_bridgeTarget);
      final content = (res['content'] ?? '').toString();
      if (!mounted) return;
      _ctrl.text = content; // dispara autosave vía el listener
      if (!silent) {
        final exists = res['exists'] == true;
        final s = Strings.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              exists
                  ? s.memLoadedFromServer('${res['size']}')
                  : s.memFileNotOnServer,
            ),
          ),
        );
      }
    } on BridgeException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).memBridgeError(e.message)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).memLoadFailed(e.toString())),
          ),
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _loadingFromServer = false);
    }
  }

  Future<void> _configureBridge() async {
    // Se presenta como RUTA del Navigator (no showDialog): un diálogo con
    // TextField enfocado dispara el assert `_dependents.isEmpty` al cerrarse.
    final derived = _bridgeMgr.derivedUrlFor(widget.connectionId) ?? '';
    final result = await Navigator.of(context).push<BridgeConfigResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BridgeConfigScreen(
          initialUrl: _bridge.url.isNotEmpty ? _bridge.url : derived,
          derivedUrl: derived,
        ),
      ),
    );
    if (result == null || !mounted) return;
    // Si la URL coincide con la derivada, se guarda en modo autodetección.
    final override = result.url.trim() == derived ? '' : result.url.trim();
    await _bridgeMgr.save(
      widget.connectionId,
      token: result.token,
      urlOverride: override,
    );
    if (!mounted) return;
    setState(() => _serverAutoLoadDone = false);
    await _probeBridge();
    if (mounted) {
      final s = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _bridge.connected
                ? s.memBridgeConnectedSnack(
                    _bridgeCanWrite ? s.memYes : s.memNo,
                  )
                : _bridge.running
                ? s.memBridgeInvalidToken
                : s.memBridgeConnFailed(_bridge.url),
          ),
        ),
      );
    }
  }

  Future<void> _applyToServer() async {
    if (!_bridgeCanWrite) return;
    // Política de aprobación: Solo-lectura bloquea; YOLO aplica directo; los
    // demás modos muestran el diff + App Lock (confirmación rica de memoria).
    final gate = approvalGate(
      context,
      instanceId: widget.connectionId,
      readOnlyInstance: false, // _bridgeCanWrite ya excluyó instancia readOnly
      risk: CommandRisk.medium,
      patternKey: 'memory_write',
    );
    if (gate == ActionGate.blocked) {
      showReadOnlyNotice(context);
      return;
    }
    final client = await _bridgeMgr.clientFor(widget.connectionId);
    if (client == null || !mounted) return;
    try {
      if (gate == ActionGate.ask) {
        // 1) dry-run para obtener el diff sin tocar nada.
        final preview = await client.write(
          file: _bridgeTarget,
          content: _ctrl.text,
          dryRun: true,
        );
        if (!mounted) return;
        final diff = (preview['diff'] ?? '').toString();
        final confirmed = await _confirmDiff(diff);
        if (confirmed != true || !mounted) return;

        // 2) App Lock antes de aplicar (acción sensible).
        final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
        if (lock != null && lock.enabled) {
          final ok = await LockScreen.verify(
            context,
            lock,
            reason: Strings.of(context).memApplyReason,
          );
          if (!ok || !mounted) return;
        }
      }

      // 3) aplicar de verdad (con backup en el servidor).
      setState(() => _applying = true);
      final res = await client.write(file: _bridgeTarget, content: _ctrl.text);
      if (!mounted) return;
      final backup = res['backup_id'];
      final s = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            backup != null
                ? s.memAppliedWithBackup(backup.toString())
                : s.memApplied,
          ),
        ),
      );
    } on BridgeException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).memBridgeError(e.message)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).memApplyFailed(e.toString())),
          ),
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<bool?> _confirmDiff(String diff) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.memApplyDiffTitle(_bridgeTarget)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              diff.isEmpty ? s.memNoDiff : diff,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.memCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.memApply),
          ),
        ],
      ),
    );
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final store = MemoryDraftStore(prefs);
    if (!mounted) return;
    setState(() {
      _store = store;
      _ctrl.text =
          store.read(
            widget.connectionId,
            widget.fileName,
            profile: widget.profile,
          ) ??
          '';
      _updatedAt = store.updatedAt(
        widget.connectionId,
        widget.fileName,
        profile: widget.profile,
      );
      _loaded = true;
    });
    _ctrl.addListener(_scheduleSave);
    // Si el bridge ya se detectó antes que el borrador local, intenta ahora.
    _maybeAutoLoadFromServer();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), _saveNow);
  }

  Future<void> _saveNow() async {
    final store = _store;
    if (store == null) return;
    await store.write(
      widget.connectionId,
      widget.fileName,
      _ctrl.text,
      profile: widget.profile,
    );
    if (!mounted) return;
    setState(
      () => _updatedAt = store.updatedAt(
        widget.connectionId,
        widget.fileName,
        profile: widget.profile,
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _ctrl.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(Strings.of(context).memCopied)));
  }

  Future<void> _export() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/memory_draft_${widget.fileName}_$ts.md');
      await file.writeAsString(_ctrl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Strings.of(context).memExported(file.path),
            style: const TextStyle(fontSize: 11),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).memExportFailed(e.toString())),
        ),
      );
    }
  }

  Future<void> _discard() async {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.memDiscardTitle),
        content: Text(s.memDiscardContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.memCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.memDiscard, style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    _saveDebounce?.cancel();
    _ctrl.removeListener(_scheduleSave);
    await _store?.delete(
      widget.connectionId,
      widget.fileName,
      profile: widget.profile,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// Mensaje + icono del banner según el estado autodetectado del bridge.
  ({String text, IconData icon}) _bridgeBanner(Strings s) {
    switch (_bridge.status) {
      case BridgeStatus.connected:
        if (_bridgeCanWrite) {
          return (
            text: s.memBridgeConnectedRW,
            icon: Icons.cloud_done_outlined,
          );
        }
        return (text: s.memBridgeConnectedRO, icon: Icons.cloud_done_outlined);
      case BridgeStatus.needsToken:
        return (
          text: s.memBridgeNeedsToken(_bridge.url),
          icon: Icons.cloud_queue,
        );
      case BridgeStatus.authFailed:
        return (text: s.memBridgeAuthFailed, icon: Icons.cloud_off_outlined);
      case BridgeStatus.unreachable:
        return (
          text: s.memBridgeUnreachable(_bridge.url),
          icon: Icons.cloud_off_outlined,
        );
      case BridgeStatus.notConfigured:
        return (text: s.memBridgeNotConfigured, icon: Icons.cloud_off_outlined);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.fileName}.md',
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
                _bridgeCanWrite ? s.memBadgeBridge : s.memBadgeDraft,
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
              _bridge.connected
                  ? Icons.cloud_done_outlined
                  : _bridge.running
                  ? Icons.cloud_queue
                  : Icons.cloud_off_outlined,
              color: _bridge.connected
                  ? colors.success
                  : _bridge.running
                  ? colors.accent
                  : colors.textSecondary,
            ),
            tooltip: s.memConfigureBridge,
            onPressed: _configureBridge,
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Builder(
                    builder: (ctx) {
                      final b = _bridgeBanner(Strings.of(ctx));
                      return HermesInfoBanner(b.text, icon: b.icon);
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
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: colors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: s.memEditorHint(widget.fileName),
                        hintStyle: TextStyle(
                          fontSize: 12.5,
                          color: colors.textDisabled,
                        ),
                      ),
                    ),
                  ),
                ),
                // Barra de acciones: estado de autosave + copiar/exportar/descartar.
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: colors.divider.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _updatedAt == null
                                  ? Icons.radio_button_unchecked
                                  : Icons.check_circle_outline,
                              size: 12,
                              color: _updatedAt == null
                                  ? colors.textDisabled
                                  : colors.success.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _updatedAt == null
                                  ? s.memUnsaved
                                  : s.memAutosaved(
                                      TimeOfDay.fromDateTime(
                                        _updatedAt!,
                                      ).format(context),
                                    ),
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 0.4,
                                color: colors.textDisabled,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            children: [
                              if (_bridgeCanRead) ...[
                                HermesSecondaryButton(
                                  label: _loadingFromServer
                                      ? s.memButtonLoading
                                      : s.memButtonReload,
                                  icon: Icons.cloud_download_outlined,
                                  onTap: _loadingFromServer
                                      ? null
                                      : () => _loadFromServer(),
                                ),
                                const SizedBox(width: 7),
                              ],
                              if (_bridgeCanWrite) ...[
                                HermesSecondaryButton(
                                  label: _applying
                                      ? s.memButtonApplying
                                      : s.memButtonApply,
                                  icon: Icons.cloud_upload_outlined,
                                  color: colors.accent,
                                  onTap: _applying ? null : _applyToServer,
                                ),
                                const SizedBox(width: 7),
                              ],
                              HermesSecondaryButton(
                                label: s.memButtonCopy,
                                icon: Icons.copy_outlined,
                                onTap: _copy,
                              ),
                              const SizedBox(width: 7),
                              HermesSecondaryButton(
                                label: s.memButtonExport,
                                icon: Icons.ios_share_outlined,
                                onTap: _export,
                              ),
                              const SizedBox(width: 7),
                              HermesSecondaryButton(
                                label: s.memButtonDiscard,
                                icon: Icons.delete_outline,
                                color: colors.error.withValues(alpha: 0.85),
                                onTap: _discard,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
