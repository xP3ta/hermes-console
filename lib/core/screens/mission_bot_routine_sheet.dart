import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart'
    show HermesSchedule, hermesFormatNextRun, showHermesScheduleBuilder;
import '../theme/app_theme.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/mission_profile_avatar.dart';

@immutable
final class MissionBotRoutineDraft {
  final String name;
  final String prompt;
  final String schedule;

  const MissionBotRoutineDraft({
    required this.name,
    required this.prompt,
    required this.schedule,
  });
}

typedef MissionBotRoutineSubmit =
    Future<void> Function(MissionBotRoutineDraft draft);

/// Explicit labels for the guided routine sheet.
///
/// Keeping copy injectable lets Mission Control use its own localization
/// source without coupling this focused component to Cron's full editor copy.
@immutable
final class MissionBotRoutineSheetCopy {
  final String title;
  final String description;
  final String botLabel;
  final String whatLabel;
  final String whatHint;
  final String whatRequired;
  final String whenLabel;
  final String customScheduleLabel;
  final String customScheduleHint;
  final String customScheduleRequired;
  final String moreOptions;
  final String optionalNameLabel;
  final String optionalNameHint;
  final String create;
  final String creating;
  final String genericError;
  final String dailyAtNine;
  final String weekdaysAtNine;
  final String weeklyMondayAtNine;
  final String monthlyAtNine;
  final String hourly;
  final String everyFifteenMinutes;
  final String custom;

  const MissionBotRoutineSheetCopy({
    required this.title,
    required this.description,
    required this.botLabel,
    required this.whatLabel,
    required this.whatHint,
    required this.whatRequired,
    required this.whenLabel,
    required this.customScheduleLabel,
    required this.customScheduleHint,
    required this.customScheduleRequired,
    required this.moreOptions,
    required this.optionalNameLabel,
    required this.optionalNameHint,
    required this.create,
    required this.creating,
    required this.genericError,
    required this.dailyAtNine,
    required this.weekdaysAtNine,
    required this.weeklyMondayAtNine,
    required this.monthlyAtNine,
    required this.hourly,
    required this.everyFifteenMinutes,
    required this.custom,
  });

  static const es = MissionBotRoutineSheetCopy(
    title: 'Nueva rutina',
    description: 'Programa algo para que este bot lo haga por ti.',
    botLabel: 'Bot',
    whatLabel: 'Qué',
    whatHint: 'Describe qué debe hacer',
    whatRequired: 'Escribe qué debe hacer el bot.',
    whenLabel: 'Cuándo',
    customScheduleLabel: 'Expresión cron',
    customScheduleHint: '0 9 * * *',
    customScheduleRequired: 'Escribe una expresión cron.',
    moreOptions: 'Más opciones',
    optionalNameLabel: 'Nombre opcional',
    optionalNameHint: 'Por ejemplo, Resumen de la mañana',
    create: 'Crear rutina',
    creating: 'Creando…',
    genericError: 'No se pudo crear la rutina. Inténtalo de nuevo.',
    dailyAtNine: 'Cada día · 09:00',
    weekdaysAtNine: 'Días laborables · 09:00',
    weeklyMondayAtNine: 'Cada lunes · 09:00',
    monthlyAtNine: 'Cada mes · día 1, 09:00',
    hourly: 'Cada hora',
    everyFifteenMinutes: 'Cada 15 minutos',
    custom: 'Personalizado',
  );

  static const en = MissionBotRoutineSheetCopy(
    title: 'New routine',
    description: 'Schedule something for this bot to do for you.',
    botLabel: 'Bot',
    whatLabel: 'What',
    whatHint: 'Describe what it should do',
    whatRequired: 'Describe what the bot should do.',
    whenLabel: 'When',
    customScheduleLabel: 'Cron expression',
    customScheduleHint: '0 9 * * *',
    customScheduleRequired: 'Enter a cron expression.',
    moreOptions: 'More options',
    optionalNameLabel: 'Optional name',
    optionalNameHint: 'For example, Morning brief',
    create: 'Create routine',
    creating: 'Creating…',
    genericError: 'The routine could not be created. Try again.',
    dailyAtNine: 'Every day · 09:00',
    weekdaysAtNine: 'Weekdays · 09:00',
    weeklyMondayAtNine: 'Every Monday · 09:00',
    monthlyAtNine: 'Every month · day 1, 09:00',
    hourly: 'Every hour',
    everyFifteenMinutes: 'Every 15 minutes',
    custom: 'Custom',
  );

  static MissionBotRoutineSheetCopy forLocale(Locale locale) =>
      locale.languageCode == 'en' ? en : es;
}

class MissionBotRoutineSheet extends StatefulWidget {
  final String botProfile;
  final String? botDisplayName;
  final MissionBotRoutineSubmit onCreate;
  final VoidCallback? onClose;
  final MissionBotRoutineSheetCopy? copy;
  final bool botHasAvatar;
  final MissionProfileAvatarCache? avatarCache;
  final String? botShape;
  final String? botColorHex;
  final String? botImageKind;

  const MissionBotRoutineSheet({
    required this.botProfile,
    required this.onCreate,
    this.botDisplayName,
    this.onClose,
    this.copy,
    this.botHasAvatar = false,
    this.avatarCache,
    this.botShape,
    this.botColorHex,
    this.botImageKind,
    super.key,
  });

  @override
  State<MissionBotRoutineSheet> createState() => _MissionBotRoutineSheetState();
}

class _MissionBotRoutineSheetState extends State<MissionBotRoutineSheet> {
  final _promptController = TextEditingController();
  final _nameController = TextEditingController();

  /// Spec 080: the schedule comes from the shared schedule builder.
  String _cron = '0 9 * * *';
  bool _showMore = false;
  bool _submitting = false;
  String? _promptError;
  String? _submitError;

  MissionBotRoutineSheetCopy get _copy =>
      widget.copy ??
      MissionBotRoutineSheetCopy.forLocale(Localizations.localeOf(context));

  @override
  void dispose() {
    _promptController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _close() {
    if (_submitting) return;
    final callback = widget.onClose;
    if (callback != null) {
      callback();
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _pickSchedule() async {
    if (_submitting) return;
    final cron = await showHermesScheduleBuilder(context, initialCron: _cron);
    if (cron == null || !mounted) return;
    setState(() {
      _cron = cron;
      _submitError = null;
    });
  }

  /// Human label of [_cron]; falls back to the injected copy for the
  /// default when the host has no app localizations.
  String _scheduleLabel(MissionBotRoutineSheetCopy copy) {
    final s = Localizations.of<Strings>(context, Strings);
    if (s == null) {
      // Never the raw cron: without app strings only the default is known.
      return _cron == '0 9 * * *' ? copy.dailyAtNine : copy.custom;
    }
    return HermesSchedule.parse(_cron).describe(s);
  }

  String? _nextLabel() {
    final s = Localizations.of<Strings>(context, Strings);
    if (s == null) return null;
    final next = HermesSchedule.parse(_cron).nextRun(DateTime.now());
    return next == null ? null : s.schNextRun(hermesFormatNextRun(s, next));
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final prompt = _promptController.text.trim();
    final promptError = prompt.isEmpty ? _copy.whatRequired : null;
    if (promptError != null) {
      setState(() {
        _promptError = promptError;
        _submitError = null;
      });
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _promptError = null;
      _submitError = null;
    });
    try {
      await widget.onCreate(
        MissionBotRoutineDraft(
          name: _nameController.text.trim(),
          prompt: prompt,
          schedule: _cron,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _submitError = _copy.genericError);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    final colors = Theme.of(context).hermes;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 17, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        copy.title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.35,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      copy.description,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('mission-routine-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: _submitting ? null : _close,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.divider),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('mission-routine-scroll'),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LockedBotIdentity(
                  profile: widget.botProfile,
                  displayName: widget.botDisplayName,
                  label: copy.botLabel,
                  hasAvatar: widget.botHasAvatar,
                  avatarCache: widget.avatarCache,
                  shape: widget.botShape,
                  colorHex: widget.botColorHex,
                  imageKind: widget.botImageKind,
                ),
                const SizedBox(height: 20),
                HermesField(
                  key: const ValueKey('mission-routine-prompt'),
                  controller: _promptController,
                  label: copy.whatLabel,
                  hint: copy.whatHint,
                  minLines: 3,
                  maxLines: 6,
                  autofocus: true,
                  errorText: _promptError,
                  onChanged: (_) {
                    if (_promptError == null && _submitError == null) return;
                    setState(() {
                      _promptError = null;
                      _submitError = null;
                    });
                  },
                ),
                const SizedBox(height: 18),
                _FieldLabel(copy.whenLabel),
                _ScheduleRow(
                  label: _scheduleLabel(copy),
                  next: _nextLabel(),
                  onTap: _submitting ? null : _pickSchedule,
                ),
                const SizedBox(height: 16),
                Semantics(
                  button: true,
                  expanded: _showMore,
                  child: InkWell(
                    key: const ValueKey('mission-routine-more-options'),
                    onTap: _submitting
                        ? null
                        : () => setState(() => _showMore = !_showMore),
                    borderRadius: BorderRadius.circular(HermesRadii.field),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.tune_rounded,
                              size: 18,
                              color: colors.textSecondary,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                copy.moreOptions,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              _showMore
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              color: colors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (_showMore) ...[
                  const SizedBox(height: 8),
                  HermesField(
                    key: const ValueKey('mission-routine-name'),
                    controller: _nameController,
                    label: copy.optionalNameLabel,
                    hint: copy.optionalNameHint,
                  ),
                ],
                if (_submitError != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const ValueKey('mission-routine-submit-error'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(HermesRadii.field),
                      ),
                      child: Text(
                        _submitError!,
                        style: TextStyle(color: colors.error, height: 1.35),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Divider(height: 1, color: colors.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 11, 20, 15),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              key: const ValueKey('mission-routine-submit'),
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.textDisabled,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Flexible(child: Text(copy.creating)),
                      ],
                    )
                  : Text(copy.create),
            ),
          ),
        ),
      ],
    );
  }
}

class _LockedBotIdentity extends StatelessWidget {
  final String profile;
  final String? displayName;
  final String label;
  final bool hasAvatar;
  final MissionProfileAvatarCache? avatarCache;
  final String? shape;
  final String? colorHex;
  final String? imageKind;

  const _LockedBotIdentity({
    required this.profile,
    required this.displayName,
    required this.label,
    required this.hasAvatar,
    required this.avatarCache,
    required this.shape,
    required this.colorHex,
    required this.imageKind,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final visibleName = displayName?.trim();
    final hasDisplayName =
        visibleName != null && visibleName.isNotEmpty && visibleName != profile;
    return Semantics(
      key: const ValueKey('mission-routine-bot'),
      container: true,
      label: '$label, ${hasDisplayName ? '$visibleName, ' : ''}@$profile',
      readOnly: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(HermesRadii.card),
          border: Border.all(color: colors.divider.withValues(alpha: 0.65)),
        ),
        child: Row(
          children: [
            MissionProfileAvatar(
              profileName: profile,
              hasAvatar: hasAvatar,
              cache: avatarCache,
              size: 34,
              shape: shape,
              colorHex: colorHex,
              imageKind: imageKind,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    hasDisplayName ? '$visibleName · @$profile' : '@$profile',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.lock_outline_rounded,
              size: 18,
              color: colors.textDisabled,
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;

  const _FieldLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, bottom: 6),
      child: Text(
        label,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

/// "When" row: the human schedule + next run, opening the schedule builder.
class _ScheduleRow extends StatelessWidget {
  final String label;
  final String? next;
  final VoidCallback? onTap;

  const _ScheduleRow({required this.label, this.next, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Material(
      color: colors.surfaceVariant.withValues(alpha: .35),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: const ValueKey('mission-routine-schedule'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 20,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (next != null)
                        Text(
                          next!,
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.textDisabled,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
