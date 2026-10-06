import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../services/memory_draft_store.dart';
import '../design/hermes_design.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';

/// Borrador LOCAL de un archivo de memoria, de versiones anteriores.
///
/// La memoria se edita en el servidor por entradas (MemoryEntriesScreen).
/// Este editor solo conserva un borrador local ya existente (autosave) para
/// copiarlo, exportarlo a un .md o descartarlo. Nunca escribe en el servidor.
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

  @override
  void initState() {
    super.initState();
    _init();
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
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).memCopied)),
      kind: HermesNoticeKind.success,
    );
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
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Strings.of(context).memExported(file.path),
            style: const TextStyle(fontSize: 11),
          ),
          duration: const Duration(seconds: 4),
        ),
        kind: HermesNoticeKind.success,
      );
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).memExportFailed(e.toString())),
        ),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<void> _discard() async {
    final s = Strings.of(context);
    final confirm = await showHermesDialog<bool>(
      context: context,
      title: s.memDiscardTitle,
      message: s.memDiscardContent,
      actions: [
        HermesDialogAction(
          label: s.memCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.memDiscard,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
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
                s.memBadgeDraft,
                style: TextStyle(
                  fontSize: 9.5,
                  letterSpacing: 0.5,
                  color: colors.accentHover,
                ),
              ),
            ),
          ],
        ),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: HermesInfoBanner(
                    s.memDraftLegacyNote,
                    icon: Icons.cloud_off_outlined,
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
                          color: colors.textTertiary,
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
                                color: colors.textTertiary,
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
