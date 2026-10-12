// Composer de nueva ejecución con plantillas.
//
// Reemplaza el AlertDialog de "instrucción libre" por una superficie flotante:
//   - Tarjetas de plantilla (predefinidas + propias). Tap rellena el campo;
//     el botón ▷ lanza directamente (si la plantilla ya está lista).
//   - Crear / editar / borrar plantillas propias (persisten vía RunTemplateStore).
//   - Un campo de instrucción editable y un botón "Lanzar".
//
// La ruta flotante posee su propio FocusScope para evitar el crash
// _dependents.isEmpty al cerrar editores con TextField.
//
// `showRunComposer` devuelve el prompt final a ejecutar, o null si se cancela.
// Es reutilizable por cualquier pantalla de ejecuciones (RunsTab, Task Center).
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/run_template.dart';
import '../services/run_template_store.dart';
import '../theme/app_theme.dart';
import 'form_page.dart';
import 'hermes_premium_ui.dart';
import 'hermes_ui.dart' show HermesField;

/// Plantillas predefinidas, construidas localizadas (es/en) a partir de los
/// Strings de la app. Las que dejan el prompt "abierto" (terminan en ':')
/// invitan a completar; el resto pueden lanzarse directamente.
List<RunTemplate> builtinRunTemplates(Strings s) => [
      RunTemplate(
        id: 'b_summarize',
        name: s.runTplSummarizeName,
        description: s.runTplSummarizeDesc,
        prompt: s.runTplSummarizePrompt,
        iconKey: 'summarize',
        builtin: true,
      ),
      RunTemplate(
        id: 'b_file',
        name: s.runTplFileName,
        description: s.runTplFileDesc,
        prompt: s.runTplFilePrompt,
        iconKey: 'file',
        builtin: true,
      ),
      RunTemplate(
        id: 'b_search',
        name: s.runTplSearchName,
        description: s.runTplSearchDesc,
        prompt: s.runTplSearchPrompt,
        iconKey: 'search',
        builtin: true,
      ),
      RunTemplate(
        id: 'b_command',
        name: s.runTplCommandName,
        description: s.runTplCommandDesc,
        prompt: s.runTplCommandPrompt,
        iconKey: 'terminal',
        builtin: true,
      ),
      RunTemplate(
        id: 'b_explain',
        name: s.runTplExplainName,
        description: s.runTplExplainDesc,
        prompt: s.runTplExplainPrompt,
        iconKey: 'code',
        builtin: true,
      ),
      RunTemplate(
        id: 'b_status',
        name: s.runTplStatusName,
        description: s.runTplStatusDesc,
        prompt: s.runTplStatusPrompt,
        iconKey: 'dashboard',
        builtin: true,
      ),
      RunTemplate(
        id: 'b_free',
        name: s.runTplFreeName,
        description: s.runTplFreeDesc,
        prompt: '',
        iconKey: 'edit',
        builtin: true,
      ),
    ];

/// Abre el composer y devuelve el prompt a lanzar (o null si se cancela).
Future<String?> showRunComposer(
  BuildContext context,
  RunTemplateStore store,
) {
  return showHermesFloatingSurface<String>(
    context: context,
    surfaceKey: const ValueKey('run-composer-surface'),
    maxWidth: 680,
    maxHeightFactor: 0.9,
    builder: (_) => _RunComposer(store: store),
  );
}

IconData _templateIcon(String key) {
  switch (key) {
    case 'summarize':
      return Icons.summarize_outlined;
    case 'file':
      return Icons.note_add_outlined;
    case 'search':
      return Icons.search;
    case 'terminal':
      return Icons.terminal;
    case 'code':
      return Icons.code;
    case 'dashboard':
      return Icons.dashboard_outlined;
    case 'edit':
      return Icons.edit_outlined;
    default:
      return Icons.bolt;
  }
}

class _RunComposer extends StatefulWidget {
  final RunTemplateStore store;
  const _RunComposer({required this.store});

  @override
  State<_RunComposer> createState() => _RunComposerState();
}

class _RunComposerState extends State<_RunComposer> {
  final TextEditingController _ctrl = TextEditingController();
  String? _selectedId;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _applyTemplate(RunTemplate t) {
    setState(() {
      _selectedId = t.id;
      _ctrl.text = t.prompt;
      // Cursor al final para empezar a completar de inmediato.
      _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    });
  }

  /// Variables {nombre} presentes en un texto (únicas, en orden de aparición).
  static final RegExp _varRe = RegExp(r'\{([a-zA-Z0-9_]+)\}');
  List<String> _extractVars(String text) {
    final seen = <String>[];
    for (final m in _varRe.allMatches(text)) {
      final v = m.group(1)!;
      if (!seen.contains(v)) seen.add(v);
    }
    return seen;
  }

  Future<void> _launch(String prompt) async {
    var text = prompt.trim();
    if (text.isEmpty) return;
    final vars = _extractVars(text);
    if (vars.isNotEmpty) {
      final values = await _askVariables(vars);
      if (values == null || !mounted) return; // cancelado
      values.forEach((k, v) => text = text.replaceAll('{$k}', v));
      text = text.trim();
      if (text.isEmpty) return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(text);
  }

  /// Pide un valor por cada variable {x}. Devuelve el mapa, o null si se cancela.
  Future<Map<String, String>?> _askVariables(List<String> vars) {
    // _VariablesSheet posee y libera los controllers en su propio dispose():
    // liberarlos tras el await (como antes) provocaba el crash _dependents.isEmpty
    // al re-escuchar un controller destruido durante la animación de cierre.
    return showHermesFloatingSurface<Map<String, String>>(
      context: context,
      surfaceKey: const ValueKey('run-template-variables-surface'),
      maxWidth: 560,
      maxHeightFactor: 0.88,
      builder: (_) => _VariablesSheet(vars: vars),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final templates = [...builtinRunTemplates(s), ...widget.store.custom];
    RunTemplate? selected;
    for (final t in templates) {
      if (t.id == _selectedId) {
        selected = t;
        break;
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.rocket_launch_outlined,
                    size: 18, color: colors.accent),
                const SizedBox(width: 8),
                Text(
                  s.runComposerTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              s.runComposerSubtitle,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in templates)
                  _TemplateChip(
                    template: t,
                    selected: t.id == _selectedId,
                    onTap: () => _applyTemplate(t),
                    onLaunch: t.isReadyToLaunch ? () => _launch(t.prompt) : null,
                    onEdit: t.builtin ? null : () => _editTemplate(t),
                  ),
                _AddTemplateChip(label: s.runTplNew, onTap: () => _editTemplate(null)),
              ],
            ),
            if (selected != null && selected.description.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                selected.description,
                style: TextStyle(
                    fontSize: 11.5,
                    fontStyle: FontStyle.italic,
                    color: colors.textSecondary),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              autofocus: false,
              maxLines: 6,
              minLines: 3,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: s.runComposerHint,
                alignLabelWithHint: true,
                filled: true,
                fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: colors.divider.withValues(alpha: 0.55)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: colors.divider.withValues(alpha: 0.55)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(s.commonCancel),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style:
                        FilledButton.styleFrom(backgroundColor: colors.accent),
                    onPressed: () => _launch(_ctrl.text),
                    icon: const Icon(Icons.rocket_launch,
                        size: 16, color: Colors.black),
                    label: Text(s.runComposerLaunch,
                        style: const TextStyle(color: Colors.black)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Crea ([existing]==null) o edita una plantilla propia en una ruta con foco
  /// seguro. Persiste y refresca la lista.
  Future<void> _editTemplate(RunTemplate? existing) async {
    final result = await pushHermesFormPage<RunTemplate>(
      context,
      name: 'run-template-editor',
      builder: (_) => _TemplateEditor(existing: existing),
    );
    if (result == null) return;
    if (result.name == _kDeleteSentinel) {
      await widget.store.remove(existing!.id);
    } else if (existing == null) {
      await widget.store.add(result);
    } else {
      await widget.store.update(result);
    }
    if (mounted) setState(() {});
  }
}

/// Centinela interno para señalar borrado desde el editor de plantilla.
const String _kDeleteSentinel = ' DELETE';

class _TemplateChip extends StatelessWidget {
  final RunTemplate template;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLaunch;
  final VoidCallback? onEdit;

  const _TemplateChip({
    required this.template,
    required this.selected,
    required this.onTap,
    this.onLaunch,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onEdit,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.12)
              : colors.surfaceVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? colors.accent.withValues(alpha: 0.6)
                : colors.divider.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_templateIcon(template.iconKey),
                size: 15, color: selected ? colors.accent : colors.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                template.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (onLaunch != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onLaunch,
                child: Icon(Icons.play_arrow_rounded,
                    size: 20, color: colors.accent),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddTemplateChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _AddTemplateChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: colors.accent.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 15, color: colors.accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editor de plantilla propia. Devuelve la plantilla creada/editada, una con
/// name==_kDeleteSentinel como señal de borrado, o null si se cancela.
class _TemplateEditor extends StatefulWidget {
  final RunTemplate? existing;
  const _TemplateEditor({this.existing});

  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _promptCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _promptCtrl = TextEditingController(text: widget.existing?.prompt ?? '');
    _nameCtrl.addListener(_changed);
    _promptCtrl.addListener(_changed);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _canSave =>
      _nameCtrl.text.trim().isNotEmpty && _promptCtrl.text.trim().isNotEmpty;

  void _save() {
    final name = _nameCtrl.text.trim();
    final prompt = _promptCtrl.text;
    if (name.isEmpty || prompt.trim().isEmpty) return;
    Navigator.of(context).pop(
      (widget.existing ??
              RunTemplate(
                id: RunTemplateStore.newId(),
                name: name,
                prompt: prompt,
                iconKey: 'bolt',
              ))
          .copyWith(name: name, prompt: prompt),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final editing = widget.existing != null;
    return HermesFormPage(
      bodyKey: const ValueKey('run-template-editor-surface'),
      title: editing ? s.runTplEditTitle : s.runTplNewTitle,
      submitLabel: s.runTplSave,
      submitKey: const ValueKey('run-template-editor-save'),
      onSubmit: _canSave ? _save : null,
      dirty:
          _nameCtrl.text != (widget.existing?.name ?? '') ||
          _promptCtrl.text != (widget.existing?.prompt ?? ''),
      children: [
        const SizedBox(height: 4),
        HermesField(
          fieldKey: const ValueKey('run-template-editor-name'),
          controller: _nameCtrl,
          label: s.runTplNameLabel,
          autofocus: !editing,
        ),
        const SizedBox(height: 16),
        HermesField(
          fieldKey: const ValueKey('run-template-editor-prompt'),
          controller: _promptCtrl,
          label: s.runTplBodyLabel,
          keyboardType: TextInputType.multiline,
          minLines: 6,
          maxLines: null,
        ),
        if (editing) ...[
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('run-template-editor-delete'),
              onPressed: () => Navigator.of(context).pop(
                const RunTemplate(id: '', name: _kDeleteSentinel, prompt: ''),
              ),
              icon: Icon(Icons.delete_outline, size: 18, color: colors.error),
              label: Text(
                s.runTplDelete,
                style: TextStyle(color: colors.error),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Superficie para completar las variables {x}. Posee los controllers
/// y los libera en dispose() (patrón seguro contra el crash _dependents.isEmpty,
/// que ocurría al liberarlos tras el await mientras el sheet aún se cerraba).
class _VariablesSheet extends StatefulWidget {
  final List<String> vars;
  const _VariablesSheet({required this.vars});

  @override
  State<_VariablesSheet> createState() => _VariablesSheetState();
}

class _VariablesSheetState extends State<_VariablesSheet> {
  late final Map<String, TextEditingController> _ctrls;

  @override
  void initState() {
    super.initState();
    _ctrls = {for (final v in widget.vars) v: TextEditingController()};
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.runVarTitle,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary),
          ),
          const SizedBox(height: 12),
          for (final v in widget.vars) ...[
            TextField(
              controller: _ctrls[v],
              autofocus: v == widget.vars.first,
              decoration: InputDecoration(labelText: v),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.accent),
            onPressed: () => Navigator.of(context).pop(
              {for (final e in _ctrls.entries) e.key: e.value.text.trim()},
            ),
            child: Text(s.runComposerLaunch,
                style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }
}
