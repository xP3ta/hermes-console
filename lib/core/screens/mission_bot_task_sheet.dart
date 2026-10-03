import 'package:flutter/material.dart';

import '../widgets/mission_profile_avatar.dart';

enum MissionBotTaskPriority { low, normal, high }

final class MissionBotTaskDraft {
  final String title;
  final String body;
  final MissionBotTaskPriority priority;

  const MissionBotTaskDraft({
    required this.title,
    required this.body,
    required this.priority,
  });
}

typedef MissionBotTaskSubmit = Future<void> Function(MissionBotTaskDraft draft);

class MissionBotTaskSheet extends StatefulWidget {
  final String displayName;
  final String profileName;
  final MissionBotTaskSubmit onSubmit;
  final bool hasAvatar;
  final MissionProfileAvatarCache? avatarCache;
  final String? botShape;
  final String? botColorHex;
  final String? botImageKind;

  const MissionBotTaskSheet({
    required this.displayName,
    required this.profileName,
    required this.onSubmit,
    this.hasAvatar = false,
    this.avatarCache,
    this.botShape,
    this.botColorHex,
    this.botImageKind,
    super.key,
  });

  @override
  State<MissionBotTaskSheet> createState() => _MissionBotTaskSheetState();
}

class _MissionBotTaskSheetState extends State<MissionBotTaskSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  MissionBotTaskPriority _priority = MissionBotTaskPriority.normal;
  bool _submitting = false;
  bool _showValidation = false;
  String? _submissionError;

  bool get _english =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'en';

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _showValidation = true;
      _submissionError = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final draft = MissionBotTaskDraft(
      title: _titleController.text.trim(),
      body: _bodyController.text.trim(),
      priority: _priority,
    );
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(draft);
      if (!mounted) return;
      await Navigator.maybePop(context, draft);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submissionError = _english
            ? 'The task could not be assigned. Try again.'
            : 'No se pudo encargar la tarea. Inténtalo de nuevo.';
      });
    }
  }

  String _priorityLabel(MissionBotTaskPriority priority) => switch (priority) {
    MissionBotTaskPriority.low => _english ? 'Low' : 'Baja',
    MissionBotTaskPriority.normal => _english ? 'Normal' : 'Normal',
    MissionBotTaskPriority.high => _english ? 'High' : 'Alta',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = widget.displayName.trim().isEmpty
        ? widget.profileName.trim()
        : widget.displayName.trim();
    return SafeArea(
      top: false,
      child: Form(
        key: _formKey,
        autovalidateMode: _showValidation
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        child: ListView(
          key: const ValueKey('mission-bot-task-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _english ? 'Assign task' : 'Encargar tarea',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              key: const ValueKey('mission-bot-task-fixed-bot'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Row(
                children: [
                  MissionProfileAvatar(
                    profileName: widget.profileName,
                    hasAvatar: widget.hasAvatar,
                    cache: widget.avatarCache,
                    size: 40,
                    shape: widget.botShape,
                    colorHex: widget.botColorHex,
                    imageKind: widget.botImageKind,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '@${widget.profileName.trim()}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              key: const ValueKey('mission-bot-task-title'),
              controller: _titleController,
              enabled: !_submitting,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              maxLength: 160,
              decoration: InputDecoration(
                labelText: _english ? 'What' : 'Qué',
                hintText: _english
                    ? 'What should this profile do?'
                    : '¿Qué debe hacer este perfil?',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return _english ? 'Describe the task.' : 'Describe la tarea.';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('mission-bot-task-body'),
              controller: _bodyController,
              enabled: !_submitting,
              textCapitalization: TextCapitalization.sentences,
              minLines: 3,
              maxLines: 5,
              maxLength: 1200,
              decoration: InputDecoration(
                labelText: _english ? 'Why (optional)' : 'Para qué (opcional)',
                hintText: _english
                    ? 'Add context or the expected result.'
                    : 'Añade contexto o el resultado esperado.',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _english ? 'Priority' : 'Prioridad',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              key: const ValueKey('mission-bot-task-priority'),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final priority in MissionBotTaskPriority.values)
                  ChoiceChip(
                    key: ValueKey('mission-bot-task-priority-${priority.name}'),
                    label: Text(_priorityLabel(priority)),
                    selected: _priority == priority,
                    onSelected: _submitting
                        ? null
                        : (selected) {
                            if (!selected) return;
                            setState(() => _priority = priority);
                          },
                  ),
              ],
            ),
            if (_submissionError != null) ...[
              const SizedBox(height: 14),
              Semantics(
                liveRegion: true,
                child: Text(
                  _submissionError!,
                  key: const ValueKey('mission-bot-task-error'),
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('mission-bot-task-submit'),
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_english ? 'Assign task' : 'Encargar tarea'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
