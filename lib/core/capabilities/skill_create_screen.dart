// New skill: name, optional category, a short description and the
// instructions. The phone writes the SKILL.md header itself so the user never
// has to type frontmatter; the server validates again and decides.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../feedback/feedback_policy.dart';
import '../services/command_risk.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/form_page.dart';
import 'capabilities_repository.dart';
import 'capability_ui.dart';
import 'spp_copy.dart';
import 'spp_safety.dart';

class SkillCreateScreen extends StatefulWidget {
  final CapabilitiesRepository repository;
  final String instanceId;
  final bool readOnly;

  /// `<server label> · <profile>`: where the skill will be created.
  final String destinationLabel;

  const SkillCreateScreen({
    super.key,
    required this.repository,
    this.instanceId = '',
    this.readOnly = false,
    this.destinationLabel = '',
  });

  @override
  State<SkillCreateScreen> createState() => _SkillCreateScreenState();
}

class _SkillCreateScreenState extends State<SkillCreateScreen> {
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _description = TextEditingController();
  final _body = TextEditingController();
  bool _busy = false;
  bool _showErrors = false;

  @override
  void initState() {
    super.initState();
    for (final controller in [_name, _category, _description, _body]) {
      controller.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _name.text.trim().isNotEmpty ||
      _category.text.trim().isNotEmpty ||
      _description.text.trim().isNotEmpty ||
      _body.text.trim().isNotEmpty;

  String get _content => sppSkillTemplate(
    name: _name.text,
    description: _description.text,
    body: _body.text.trim(),
  );

  SppSkillIssue? get _nameIssue => sppCheckSkillName(_name.text);
  SppSkillIssue? get _categoryIssue => sppCheckSkillCategory(_category.text);
  SppSkillIssue? get _descriptionIssue =>
      sppCheckSkillDescription(_description.text);
  SppSkillIssue? get _bodyIssue => _body.text.trim().isEmpty
      ? SppSkillIssue.contentNoBody
      : sppCheckSkillContent(_content);

  bool get _valid =>
      _nameIssue == null &&
      _categoryIssue == null &&
      _descriptionIssue == null &&
      _bodyIssue == null;

  Future<void> _submit() async {
    if (_busy) return;
    if (!_valid) {
      setState(() => _showErrors = true);
      return;
    }
    final s = Strings.of(context);
    final notices = AppFeedback.of(context);
    final name = _name.text.trim();
    setState(() => _busy = true);
    try {
      final ok = await confirmMutatingAction(
        context,
        instanceId: widget.instanceId,
        readOnlyInstance: widget.readOnly,
        risk: CommandRisk.high,
        title: s.sppCreateConfirmTitle(name),
        detail: [
          if (widget.destinationLabel.isNotEmpty)
            s.cphConfirmDestination(widget.destinationLabel),
          s.sppCreateConfirmBody,
        ].join('\n'),
      );
      if (!ok || !mounted) return;
      await widget.repository.createSkill(
        name,
        _content,
        category: _category.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(name);
    } catch (error) {
      if (mounted) {
        notices.notify(FeedbackKind.error, capabilityFailureMessage(s, error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _error(SppSkillIssue? issue, {bool always = false}) {
    if (issue == null || !(_showErrors || always)) return null;
    return sppSkillIssueText(Strings.of(context), issue);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final descriptionLength = _description.text.trim().length;
    return HermesFormPage(
      bodyKey: const ValueKey('spp-create-body'),
      title: s.sppNewSkillTitle,
      submitLabel: s.sppCreate,
      submitKey: const ValueKey('spp-create-submit'),
      dirty: _dirty,
      busy: _busy,
      onSubmit: _submit,
      children: [
        HermesInlineNotice(
          icon: Icons.info_outline_rounded,
          message: s.sppNewSkillIntro,
        ),
        const SizedBox(height: HermesSpace.x4),
        TextField(
          key: const ValueKey('spp-create-name'),
          controller: _name,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: s.sppSkillNameLabel,
            helperText: s.sppSkillNameHelp,
            errorText: _error(_nameIssue, always: _name.text.isNotEmpty),
          ),
        ),
        const SizedBox(height: HermesSpace.x3),
        TextField(
          key: const ValueKey('spp-create-category'),
          controller: _category,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: s.sppSkillCategoryLabel,
            errorText: _error(
              _categoryIssue,
              always: _category.text.isNotEmpty,
            ),
          ),
        ),
        const SizedBox(height: HermesSpace.x3),
        TextField(
          key: const ValueKey('spp-create-description'),
          controller: _description,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: s.sppSkillDescriptionLabel,
            helperText: s.sppSkillDescriptionHelp,
            counterText: s.sppCharCount(
              descriptionLength,
              sppSkillNewDescriptionMax,
            ),
            errorText: _error(
              _descriptionIssue,
              always: descriptionLength > sppSkillNewDescriptionMax,
            ),
          ),
        ),
        const SizedBox(height: HermesSpace.x3),
        TextField(
          key: const ValueKey('spp-create-body-field'),
          controller: _body,
          enabled: !_busy,
          keyboardType: TextInputType.multiline,
          minLines: 8,
          maxLines: null,
          decoration: InputDecoration(
            labelText: s.sppSkillInstructionsLabel,
            alignLabelWithHint: true,
            errorText: _error(_bodyIssue),
          ),
          style: HermesType.text.copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }
}
